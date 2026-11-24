import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

import '../models/device.dart';
import 'linux_mdns.dart';

/// Поиск и объявление устройства в локальной сети через mDNS.
///
/// Сервис живёт ровно столько, сколько открыт главный экран: `start()` в
/// `initState`, `stop()`/`dispose()` в `dispose`.
class DiscoveryService {
  static const String serviceType = '_outmng._tcp';
  static const int defaultPort = 53317;

  final StreamController<List<Device>> _controller =
      StreamController<List<Device>>.broadcast();
  final Map<String, Device> _devices = <String, Device>{};

  nsd.Discovery? _discovery;
  nsd.Registration? _registration;
  nsd.ServiceListener? _listener;
  LinuxMdns? _linux;

  String _selfId = '';
  String _deviceName = '';
  DeviceType _deviceType = DeviceType.unknown;
  int _port = defaultPort;
  bool _running = false;
  String? _lastError;

  /// Поток найденных устройств (без самого себя).
  Stream<List<Device>> get devices => _controller.stream;

  List<Device> get currentDevices => _sorted();

  bool get isRunning => _running;

  String? get lastError => _lastError;

  String get selfId => _selfId;

  String get deviceName => _deviceName;

  int get port => _port;

  /// Запускает объявление себя и поиск соседей.
  Future<void> start({
    required String deviceName,
    required DeviceType deviceType,
    int port = defaultPort,
    String? deviceId,
  }) async {
    if (_running) return;
    _running = true;
    _deviceName = deviceName;
    _deviceType = deviceType;
    _port = port;
    final stableId = deviceId?.trim();
    _selfId = stableId == null || stableId.isEmpty ? randomMdnsId() : stableId;
    _lastError = null;
    _devices.clear();

    if (Platform.isLinux) {
      await _startLinux();
    } else {
      await _startNsd();
    }
    _emit();
  }

  Future<void> _startLinux() async {
    final engine = LinuxMdns(
      id: _selfId,
      name: _deviceName,
      port: _port,
      onDevice: _upsert,
      onDeviceLost: _removeById,
      onError: (message) => _lastError ??= message,
    );
    _linux = engine;
    await engine.start();
    if (!engine.isRunning) {
      _lastError ??= 'mDNS недоступен: не удалось занять UDP-порт 5353';
    }
  }

  Future<void> _startNsd() async {
    try {
      _registration = await nsd.register(
        nsd.Service(
          name: 'OutMNG-$_selfId',
          type: serviceType,
          port: _port,
          txt: <String, Uint8List?>{
            'id': Uint8List.fromList(utf8.encode(_selfId)),
            'n': Uint8List.fromList(utf8.encode(_deviceName)),
            't': Uint8List.fromList(utf8.encode(_deviceType.name)),
          },
        ),
      );
    } catch (error) {
      _lastError = 'mDNS-объявление недоступно: $error';
    }

    try {
      final discovery = await nsd.startDiscovery(
        serviceType,
        autoResolve: true,
        ipLookupType: nsd.IpLookupType.v4,
      );
      _discovery = discovery;
      _listener = (service, status) {
        _handleNsdService(service, status);
      };
      discovery.addServiceListener(_listener!);
      for (final service in discovery.services) {
        _handleNsdService(service, nsd.ServiceStatus.found);
      }
    } catch (error) {
      _lastError ??= 'mDNS-поиск недоступен: $error';
    }
  }

  void _handleNsdService(nsd.Service service, nsd.ServiceStatus status) {
    final txt = <String, String>{};
    service.txt?.forEach((key, value) {
      if (value != null) {
        txt[key] = utf8.decode(value, allowMalformed: true);
      }
    });
    final id = txt['id']?.trim().isNotEmpty == true
        ? txt['id']!.trim()
        : (service.name ?? '');
    if (id.isEmpty || id == _selfId) return;

    if (status == nsd.ServiceStatus.lost) {
      _removeById(id);
      return;
    }

    final address =
        _pickAddress(service.addresses) ??
        _pickAddress(<InternetAddress>[
          if (service.host != null)
            if (InternetAddress.tryParse(service.host!) != null)
              InternetAddress.tryParse(service.host!)!,
        ]);
    if (address == null) return;

    final name = txt['n']?.trim();
    _upsert(
      Device(
        id: id,
        name: name == null || name.isEmpty
            ? (service.name ?? address.address)
            : name,
        ip: address.address,
        port: service.port ?? _port,
        type: DeviceType.parse(txt['t']),
      ),
    );
  }

  static InternetAddress? _pickAddress(List<InternetAddress>? addresses) {
    if (addresses == null || addresses.isEmpty) return null;
    final ipv4 = addresses
        .where(
          (a) =>
              a.type == InternetAddressType.IPv4 &&
              !a.isLoopback &&
              !a.address.startsWith('169.254.'),
        )
        .toList();
    if (ipv4.isNotEmpty) return ipv4.first;
    return addresses.firstWhere(
      (a) => !a.isLoopback,
      orElse: () => addresses.first,
    );
  }

  void _upsert(Device device) {
    if (device.id == _selfId || device.ip.isEmpty) return;
    final previous = _devices[device.id];
    if (previous == device) return;
    _devices[device.id] = device;
    _emit();
  }

  void _removeById(String id) {
    if (_devices.remove(id) != null) _emit();
  }

  /// Перезапуск поиска (кнопка «обновить»).
  Future<void> restart() async {
    if (!_running) return;
    final name = _deviceName;
    final type = _deviceType;
    final id = _selfId;
    await stop();
    await start(deviceName: name, deviceType: type, port: _port, deviceId: id);
  }

  /// Останавливает поиск и снимает объявление сервиса.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    await _linux?.stop();
    _linux = null;

    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      final listener = _listener;
      if (listener != null) discovery.removeServiceListener(listener);
      try {
        await nsd.stopDiscovery(discovery);
      } catch (_) {
        // Уже остановлено платформой.
      }
    }
    _listener = null;

    final registration = _registration;
    _registration = null;
    if (registration != null) {
      try {
        await nsd.unregister(registration);
      } catch (_) {
        // Уже снято платформой.
      }
    }

    _devices.clear();
    _emit();
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(_sorted());
  }

  List<Device> _sorted() {
    final list = _devices.values.toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return List<Device>.unmodifiable(list);
  }
}
