import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/device.dart';

/// Минимальный mDNS/DNS-SD движок на чистом Dart.
///
/// Нужен потому, что пакет `nsd` не поддерживает Linux. Работает без Avahi:
/// сам отвечает на запросы `_outmng._tcp.local`, объявляет сервис и собирает
/// ответы соседей. Используется только на Linux.
class LinuxMdns {
  LinuxMdns({
    required this.id,
    required this.name,
    required this.port,
    required this.onDevice,
    required this.onDeviceLost,
    this.onError,
  });

  static const String _groupAddress = '224.0.0.251';
  static const int _mdnsPort = 5353;
  static const String _service = '_outmng._tcp';
  static const String _serviceFqdn = '$_service.local';

  final String id;
  final String name;
  final int port;
  final void Function(Device device) onDevice;
  final void Function(String deviceId) onDeviceLost;
  final void Function(String message)? onError;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _queryTimer;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  InternetAddress? _localIp;
  DateTime _lastResponse = DateTime.fromMillisecondsSinceEpoch(0);
  bool _running = false;

  final Map<String, _Peer> _peers = <String, _Peer>{};

  String get _instance => 'OutMNG-$id';
  String get _instanceFqdn => '$_instance.$_serviceFqdn';
  String get _hostFqdn => 'outmng-$id.local';

  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    try {
      _localIp = await _findLocalIp();
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _mdnsPort,
        reuseAddress: true,
        reusePort: true,
      );
      socket.multicastLoopback = true;
      try {
        socket.joinMulticast(InternetAddress(_groupAddress));
      } catch (_) {
        // Некоторые интерфейсы не поддерживают multicast — продолжаем.
      }
      _socket = socket;
      _subscription = socket.listen(
        _onSocketEvent,
        onError: (Object error) => _report('mDNS: $error'),
        onDone: () {},
      );
      _running = true;
      _announce();
      _query();
      _queryTimer = Timer.periodic(const Duration(seconds: 4), (_) => _query());
      _announceTimer = Timer.periodic(
        const Duration(seconds: 12),
        (_) => _announce(),
      );
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) => _prune());
    } catch (error) {
      _report('mDNS: $error');
    }
  }

  Future<void> stop() async {
    _running = false;
    _queryTimer?.cancel();
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _queryTimer = null;
    _announceTimer = null;
    _pruneTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    for (final peer in _peers.values) {
      final deviceId = peer.emittedId;
      if (deviceId != null) onDeviceLost(deviceId);
    }
    _peers.clear();
  }

  void _report(String message) {
    if (onError != null) onError!(message);
  }

  Future<InternetAddress?> _findLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final addresses =
          <InternetAddress>[
                for (final interface in interfaces) ...interface.addresses,
              ]
              .where((a) => !a.isLoopback && !a.address.startsWith('169.254.'))
              .toList();
      if (addresses.isEmpty) return null;
      addresses.sort((a, b) => _rank(b).compareTo(_rank(a)));
      return addresses.first;
    } catch (_) {
      return null;
    }
  }

  static int _rank(InternetAddress address) {
    if (address.address.startsWith('192.168.')) return 3;
    if (address.address.startsWith('10.')) return 2;
    if (address.address.startsWith('172.')) return 1;
    return 0;
  }

  void _onSocketEvent(RawSocketEvent event) {
    final socket = _socket;
    if (socket == null) return;
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) break;
      _handleDatagram(datagram.data, datagram.address, datagram.port);
    }
  }

  void _handleDatagram(Uint8List data, InternetAddress from, int fromPort) {
    final message = _DnsMessage.parse(data);
    if (message == null) return;
    if (message.isResponse) {
      _handleResponse(message, from);
    } else {
      _handleQuery(message, from, fromPort);
    }
  }

  void _handleQuery(_DnsMessage message, InternetAddress from, int fromPort) {
    var relevant = false;
    var unicast = false;
    for (final question in message.questions) {
      final q = question.name.toLowerCase();
      if (q == _serviceFqdn ||
          q == _instanceFqdn.toLowerCase() ||
          q == _hostFqdn.toLowerCase()) {
        relevant = true;
        if (question.unicastResponse) unicast = true;
      }
    }
    if (!relevant) return;
    final now = DateTime.now();
    if (now.difference(_lastResponse) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastResponse = now;
    _sendResponse(unicastTo: unicast ? from : null, unicastPort: fromPort);
  }

  void _handleResponse(_DnsMessage message, InternetAddress from) {
    final now = DateTime.now();
    for (final record in message.records) {
      final recordName = record.name.toLowerCase();
      switch (record.type) {
        case _DnsType.ptr:
          if (recordName != _serviceFqdn) continue;
          final target = record.targetName;
          if (target == null || target.isEmpty) continue;
          final peer = _peerFor(target, now);
          peer.seen = now;
        case _DnsType.srv:
          final target = record.targetName;
          if (target == null) continue;
          final peer = _peerFor(record.name, now);
          peer.port = record.srvPort;
          peer.host = target.toLowerCase();
          peer.seen = now;
        case _DnsType.txt:
          final peer = _peerFor(record.name, now);
          peer.txt = record.txt ?? <String, String>{};
          peer.seen = now;
        case _DnsType.a:
          final address = record.address;
          if (address == null) continue;
          final key = recordName;
          for (final peer in _peers.values) {
            if (peer.host == key) {
              peer.address = address;
              peer.seen = now;
            }
          }
      }
    }

    for (final peer in _peers.values) {
      if (peer.port == null) continue;
      final deviceId = peer.txt['id'] ?? peer.instance;
      if (deviceId == id) continue;
      final address = peer.address ?? from;
      final device = Device(
        id: deviceId,
        name: peer.txt['n']?.trim().isNotEmpty == true
            ? peer.txt['n']!.trim()
            : peer.instance,
        ip: address.address,
        port: peer.port!,
        type: DeviceType.parse(peer.txt['t']),
      );
      peer.emittedId = deviceId;
      onDevice(device);
    }
  }

  _Peer _peerFor(String instanceFqdn, DateTime now) {
    final key = instanceFqdn.toLowerCase();
    return _peers.putIfAbsent(
      key,
      () => _Peer(instance: _stripService(instanceFqdn), seen: now),
    );
  }

  static String _stripService(String fqdn) {
    final lower = fqdn.toLowerCase();
    const suffix = '.$_serviceFqdn';
    if (lower.endsWith(suffix)) {
      return fqdn.substring(0, fqdn.length - suffix.length);
    }
    return fqdn;
  }

  void _prune() {
    final now = DateTime.now();
    final expired = <String>[];
    _peers.forEach((key, peer) {
      if (now.difference(peer.seen) > const Duration(seconds: 35)) {
        expired.add(key);
      }
    });
    for (final key in expired) {
      final peer = _peers.remove(key);
      final deviceId = peer?.emittedId;
      if (deviceId != null) onDeviceLost(deviceId);
    }
  }

  void _query() {
    if (!_running) return;
    final writer = _DnsWriter();
    writer.u16(0); // id
    writer.u16(0); // flags: standard query
    writer.u16(1); // questions
    writer.u16(0);
    writer.u16(0);
    writer.u16(0);
    writer.name(_serviceFqdn);
    writer.u16(_DnsType.ptr);
    writer.u16(1); // class IN, multicast response
    _send(writer.takeBytes(), InternetAddress(_groupAddress), _mdnsPort);
  }

  void _announce() {
    if (!_running) return;
    _sendResponse();
  }

  void _sendResponse({
    InternetAddress? unicastTo,
    int unicastPort = _mdnsPort,
  }) {
    final socket = _socket;
    if (socket == null || !_running) return;
    final ip = _localIp;
    if (ip == null) return;

    final writer = _DnsWriter();
    writer.u16(0); // id
    writer.u16(0x8400); // response + authoritative
    writer.u16(0); // questions
    writer.u16(4); // answers
    writer.u16(0);
    writer.u16(0);

    // PTR: _outmng._tcp.local -> OutMNG-<id>._outmng._tcp.local
    writer.name(_serviceFqdn);
    writer.u16(_DnsType.ptr);
    writer.u16(1);
    writer.u32(120);
    final instanceBytes = _DnsWriter.encodeName(_instanceFqdn);
    writer.u16(instanceBytes.length);
    writer.raw(instanceBytes);

    // SRV: instance -> host:port
    writer.name(_instanceFqdn);
    writer.u16(_DnsType.srv);
    writer.u16(0x8001);
    writer.u32(120);
    final hostBytes = _DnsWriter.encodeName(_hostFqdn);
    writer.u16(6 + hostBytes.length);
    writer.u16(0); // priority
    writer.u16(0); // weight
    writer.u16(port);
    writer.raw(hostBytes);

    // TXT: id / name / type
    final txt = <String, String>{
      'id': id,
      'n': name,
      't': currentDeviceType.name,
    };
    final txtBytes = _encodeTxt(txt);
    writer.name(_instanceFqdn);
    writer.u16(_DnsType.txt);
    writer.u16(0x8001);
    writer.u32(120);
    writer.u16(txtBytes.length);
    writer.raw(txtBytes);

    // A: host -> IPv4
    writer.name(_hostFqdn);
    writer.u16(_DnsType.a);
    writer.u16(0x8001);
    writer.u32(120);
    writer.u16(4);
    writer.raw(ip.rawAddress);

    if (unicastTo != null) {
      _send(writer.takeBytes(), unicastTo, unicastPort);
    } else {
      _send(writer.takeBytes(), InternetAddress(_groupAddress), _mdnsPort);
    }
  }

  void _send(Uint8List packet, InternetAddress address, int targetPort) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(packet, address, targetPort);
    } catch (error) {
      _report('mDNS send: $error');
    }
  }

  static Uint8List _encodeTxt(Map<String, String> values) {
    final builder = BytesBuilder(copy: false);
    values.forEach((key, value) {
      final bytes = utf8.encode('$key=$value');
      if (bytes.length > 255) return;
      builder.addByte(bytes.length);
      builder.add(bytes);
    });
    return builder.takeBytes();
  }
}

class _Peer {
  _Peer({required this.instance, required this.seen});

  final String instance;
  int? port;
  String? host;
  InternetAddress? address;
  Map<String, String> txt = <String, String>{};
  DateTime seen;
  String? emittedId;
}

abstract final class _DnsType {
  static const int a = 1;
  static const int ptr = 12;
  static const int txt = 16;
  static const int srv = 33;
}

class _DnsQuestion {
  const _DnsQuestion(this.name, this.type, this.unicastResponse);

  final String name;
  final int type;
  final bool unicastResponse;
}

class _DnsRecord {
  const _DnsRecord({
    required this.name,
    required this.type,
    this.targetName,
    this.srvPort,
    this.txt,
    this.address,
  });

  final String name;
  final int type;
  final String? targetName;
  final int? srvPort;
  final Map<String, String>? txt;
  final InternetAddress? address;
}

class _DnsMessage {
  _DnsMessage({
    required this.isResponse,
    required this.questions,
    required this.records,
  });

  final bool isResponse;
  final List<_DnsQuestion> questions;
  final List<_DnsRecord> records;

  static _DnsMessage? parse(Uint8List data) {
    if (data.length < 12) return null;
    final flags = _u16(data, 2);
    final isResponse = (flags & 0x8000) != 0;
    final questionCount = _u16(data, 4);
    final answerCount = _u16(data, 6);
    final authorityCount = _u16(data, 8);
    final additionalCount = _u16(data, 10);

    var offset = 12;
    final questions = <_DnsQuestion>[];
    for (var i = 0; i < questionCount; i++) {
      final name = _readName(data, offset);
      if (name == null) return null;
      offset = name.next;
      if (offset + 4 > data.length) return null;
      final type = _u16(data, offset);
      final qClass = _u16(data, offset + 2);
      offset += 4;
      questions.add(_DnsQuestion(name.value, type, (qClass & 0x8000) != 0));
    }

    final records = <_DnsRecord>[];
    final total = answerCount + authorityCount + additionalCount;
    for (var i = 0; i < total; i++) {
      final name = _readName(data, offset);
      if (name == null) break;
      offset = name.next;
      if (offset + 10 > data.length) break;
      final type = _u16(data, offset);
      final ttl = _u32(data, offset + 4);
      final dataLength = _u16(data, offset + 8);
      offset += 10;
      if (offset + dataLength > data.length) break;
      final dataEnd = offset + dataLength;
      if (ttl == 0) {
        offset = dataEnd;
        continue;
      }

      switch (type) {
        case _DnsType.ptr:
          final target = _readName(data, offset);
          if (target != null && target.next <= dataEnd) {
            records.add(
              _DnsRecord(
                name: name.value,
                type: type,
                targetName: target.value,
              ),
            );
          }
        case _DnsType.srv:
          if (offset + 6 <= dataEnd) {
            final srvPort = _u16(data, offset + 4);
            final target = _readName(data, offset + 6);
            if (target != null && target.next <= dataEnd) {
              records.add(
                _DnsRecord(
                  name: name.value,
                  type: type,
                  srvPort: srvPort,
                  targetName: target.value,
                ),
              );
            }
          }
        case _DnsType.txt:
          final txt = <String, String>{};
          var pos = offset;
          while (pos < dataEnd) {
            final length = data[pos];
            pos++;
            if (pos + length > dataEnd) break;
            final entry = utf8.decode(
              data.sublist(pos, pos + length),
              allowMalformed: true,
            );
            pos += length;
            final eq = entry.indexOf('=');
            if (eq <= 0) continue;
            txt[entry.substring(0, eq)] = entry.substring(eq + 1);
          }
          records.add(_DnsRecord(name: name.value, type: type, txt: txt));
        case _DnsType.a:
          if (dataLength == 4) {
            records.add(
              _DnsRecord(
                name: name.value,
                type: type,
                address: InternetAddress.fromRawAddress(
                  Uint8List.fromList(data.sublist(offset, offset + 4)),
                ),
              ),
            );
          }
      }
      offset = dataEnd;
    }

    return _DnsMessage(
      isResponse: isResponse,
      questions: questions,
      records: records,
    );
  }

  static int _u16(Uint8List data, int offset) =>
      (data[offset] << 8) | data[offset + 1];

  static int _u32(Uint8List data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];

  static _ReadName? _readName(Uint8List data, int offset) {
    final labels = <String>[];
    var position = offset;
    int? next;
    var jumps = 0;
    while (true) {
      if (position >= data.length) return null;
      final length = data[position];
      if (length == 0) {
        position++;
        break;
      }
      if ((length & 0xC0) == 0xC0) {
        if (position + 1 >= data.length) return null;
        final pointer = ((length & 0x3F) << 8) | data[position + 1];
        next ??= position + 2;
        if (pointer >= data.length || ++jumps > 32) return null;
        position = pointer;
        continue;
      }
      if ((length & 0xC0) != 0) return null;
      position++;
      if (position + length > data.length) return null;
      labels.add(
        utf8.decode(
          data.sublist(position, position + length),
          allowMalformed: true,
        ),
      );
      position += length;
    }
    return _ReadName(labels.join('.'), next ?? position);
  }
}

class _ReadName {
  const _ReadName(this.value, this.next);

  final String value;
  final int next;
}

class _DnsWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void u16(int value) {
    _builder.addByte((value >> 8) & 0xFF);
    _builder.addByte(value & 0xFF);
  }

  void u32(int value) {
    _builder.addByte((value >> 24) & 0xFF);
    _builder.addByte((value >> 16) & 0xFF);
    _builder.addByte((value >> 8) & 0xFF);
    _builder.addByte(value & 0xFF);
  }

  void raw(List<int> bytes) => _builder.add(bytes);

  void name(String fqdn) => _builder.add(encodeName(fqdn));

  Uint8List takeBytes() => _builder.takeBytes();

  static Uint8List encodeName(String fqdn) {
    final builder = BytesBuilder(copy: false);
    for (final label in fqdn.split('.')) {
      if (label.isEmpty) continue;
      final bytes = utf8.encode(label);
      final safe = bytes.length > 63 ? bytes.sublist(0, 63) : bytes;
      builder.addByte(safe.length);
      builder.add(safe);
    }
    builder.addByte(0);
    return builder.takeBytes();
  }
}

/// Локальное имя вида `OutMNG-1a2b3c`.
String randomMdnsId() {
  final random = Random.secure();
  final bytes = List<int>.generate(3, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
