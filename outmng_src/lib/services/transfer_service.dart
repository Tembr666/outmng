import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/device.dart';
import 'android_downloads.dart';
import 'storage.dart';

/// Направление передачи файла.
enum TransferDirection { sent, received }

/// Одна запись в истории передач (живёт только в памяти приложения).
@immutable
class TransferRecord {
  const TransferRecord({
    required this.name,
    required this.size,
    required this.direction,
    required this.peer,
    required this.time,
    required this.ok,
    this.path,
    this.error,
  });

  final String name;
  final int size;
  final TransferDirection direction;
  final String peer;
  final DateTime time;
  final bool ok;
  final String? path;
  final String? error;

  String get sizeLabel => formatBytes(size);

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    const units = <String>['КБ', 'МБ', 'ГБ', 'ТБ'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }
}

/// Результат отправки набора файлов.
class SendResult {
  const SendResult({
    required this.sent,
    required this.total,
    required this.errors,
  });

  final int sent;
  final int total;
  final List<String> errors;

  bool get allOk => sent == total && errors.isEmpty;
}

/// HTTP-сервер приёма файлов и клиент отправки.
///
/// Сервер поднимается только вместе с главным экраном и закрывается в
/// `dispose`. Порт по умолчанию — 53317, при занятости берётся следующий.
class TransferService extends ChangeNotifier {
  TransferService({Future<Directory> Function()? directoryResolver})
    : _directoryResolver = directoryResolver ?? resolveOutMngDirectory;

  static const int basePort = 53317;
  static const int _maxPortTries = 10;

  final Future<Directory> Function() _directoryResolver;

  HttpServer? _server;
  Directory? _downloadDir;
  Directory? _incomingDir;
  String _deviceName = 'OutMNG';
  String _deviceId = '';
  DeviceType _deviceType = DeviceType.unknown;
  String? _localIp;
  String? _error;
  int _port = basePort;
  bool _busy = false;
  String? _activeFile;
  double? _progress;
  DateTime _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
  final List<TransferRecord> _records = <TransferRecord>[];
  bool _disposed = false;

  bool get isRunning => _server != null;

  int get port => _port;

  String get deviceName => _deviceName;

  String? get localIp => _localIp;

  String? get error => _error;

  bool get isBusy => _busy;

  String? get activeFileName => _activeFile;

  double? get progress => _progress;

  /// История передач, новые сверху.
  List<TransferRecord> get records =>
      List<TransferRecord>.unmodifiable(_records.reversed);

  List<TransferRecord> get receivedRecords => List<TransferRecord>.unmodifiable(
    _records
        .where((r) => r.direction == TransferDirection.received)
        .toList()
        .reversed,
  );

  String get endpoint {
    final ip = _localIp;
    return ip == null ? 'порт $_port' : 'http://$ip:$_port';
  }

  /// Поднимает HTTP-сервер на всех интерфейсах.
  Future<void> startServer({
    required String deviceName,
    required DeviceType deviceType,
    String? deviceId,
  }) async {
    if (_server != null) return;
    _deviceName = deviceName;
    _deviceType = deviceType;
    final stableId = deviceId?.trim();
    _deviceId = stableId != null && stableId.isNotEmpty
        ? stableId
        : '${deviceName.hashCode.toRadixString(16)}-'
              '${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';
    _error = null;
    _localIp = await _resolveLocalIp();

    HttpServer? server;
    var chosenPort = basePort;
    for (var i = 0; i < _maxPortTries; i++) {
      final candidate = basePort + i;
      try {
        server = await shelf_io.serve(
          _handleRequest,
          InternetAddress.anyIPv4,
          candidate,
          shared: false,
        );
        chosenPort = candidate;
        break;
      } on SocketException {
        continue;
      } catch (error) {
        _error = 'Сервер: $error';
        break;
      }
    }

    if (server == null) {
      _error ??= 'Не удалось занять порт $basePort';
      _notify();
      return;
    }

    server.autoCompress = false;
    _server = server;
    _port = chosenPort;
    _notify();
  }

  /// Останавливает сервер. Вызывается из `dispose` главного экрана.
  Future<void> stopServer() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
    _busy = false;
    _activeFile = null;
    _progress = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  void _notify() => notifyListeners();

  Future<Response> _handleRequest(Request request) async {
    final path = request.url.path;
    try {
      if (request.method == 'GET' && (path.isEmpty || path == 'info')) {
        return _json(<String, Object?>{
          'app': 'OutMNG',
          'version': 1,
          'id': _deviceId,
          'name': _deviceName,
          'type': _deviceType.name,
          'port': _port,
        });
      }
      if (request.method == 'GET' && path == 'health') {
        return _json(<String, Object?>{'ok': true});
      }
      if (request.method == 'POST' && path == 'upload') {
        return await _handleUpload(request);
      }
      return _json(<String, Object?>{'error': 'not found'}, status: 404);
    } catch (error) {
      return _json(<String, Object?>{'error': error.toString()}, status: 500);
    }
  }

  Response _json(Map<String, Object?> body, {int status = 200}) {
    return Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );
  }

  Future<Response> _handleUpload(Request request) async {
    var peer = _remoteAddress(request);
    final rawContentType = request.headers['content-type'] ?? '';
    final contentType = rawContentType.toLowerCase();
    final saved = <String>[];
    final android = Platform.isAndroid;
    final incomingDir = android
        ? await _ensureIncomingDir()
        : await _ensureDownloadDir();

    if (contentType.startsWith('multipart/form-data')) {
      final boundary = _boundaryOf(rawContentType);
      if (boundary == null) {
        return _json(<String, Object?>{'error': 'bad boundary'}, status: 400);
      }
      final total = request.contentLength;
      var received = 0;

      final body = request.read().map<List<int>>((chunk) => chunk);
      await for (final part in body.transform(
        MimeMultipartTransformer(boundary),
      )) {
        final disposition = part.headers['content-disposition'];
        final rawName = _filenameFromDisposition(disposition);
        if (rawName == null || rawName.trim().isEmpty) {
          if (_fieldNameFromDisposition(disposition) == 'from') {
            final bytes = await _readLimited(part, 256);
            final value = utf8.decode(bytes, allowMalformed: true).trim();
            if (value.isNotEmpty) peer = value;
          } else {
            await part.drain<void>();
          }
          continue;
        }
        final name = _sanitize(rawName);
        final target = await _uniqueFile(
          incomingDir,
          android ? '${DateTime.now().microsecondsSinceEpoch}_$name' : name,
        );
        final sink = target.openWrite();
        var size = 0;
        try {
          await for (final chunk in part) {
            sink.add(chunk);
            size += chunk.length;
            received += chunk.length;
            _reportProgress(received, total);
          }
        } finally {
          await sink.close();
        }
        await _storeReceived(target, name, size, peer, saved);
      }
      _resetProgress();
    } else {
      final rawName =
          request.url.queryParameters['name'] ?? request.headers['x-file-name'];
      if (rawName == null || rawName.trim().isEmpty) {
        return _json(<String, Object?>{
          'error': 'filename required',
        }, status: 400);
      }
      final name = _sanitize(rawName);
      final target = await _uniqueFile(
        incomingDir,
        android ? '${DateTime.now().microsecondsSinceEpoch}_$name' : name,
      );
      final sink = target.openWrite();
      var size = 0;
      final total = request.contentLength;
      try {
        await for (final chunk in request.read()) {
          sink.add(chunk);
          size += chunk.length;
          _reportProgress(size, total);
        }
      } finally {
        await sink.close();
      }
      await _storeReceived(target, name, size, peer, saved);
      _resetProgress();
    }

    return _json(<String, Object?>{
      'saved': saved.map((path) => p.basename(path)).toList(),
      'count': saved.length,
    });
  }

  /// Кладёт принятый файл в системные «Загрузки» (Android) или в папку
  /// приложения (desktop) и добавляет запись в историю.
  Future<void> _storeReceived(
    File target,
    String name,
    int size,
    String peer,
    List<String> saved,
  ) async {
    var displayPath = target.path;
    var displayName = name;

    if (Platform.isAndroid) {
      final publicPath = await AndroidDownloads.saveFile(
        sourcePath: target.path,
        fileName: name,
        mimeType: lookupMimeType(name) ?? 'application/octet-stream',
      );
      if (publicPath != null) {
        try {
          await target.delete();
        } catch (_) {
          // Временный файл удалится системой позже.
        }
        displayPath = publicPath;
        displayName = p.basename(publicPath);
      } else {
        try {
          final fallbackDir = await _ensureDownloadDir();
          final fallback = await _uniqueFile(fallbackDir, name);
          await target.rename(fallback.path);
          displayPath = fallback.path;
          displayName = p.basename(fallback.path);
        } catch (_) {
          // Оставляем файл во временной папке — он всё равно доступен.
        }
      }
    }

    saved.add(displayPath);
    _addRecord(
      TransferRecord(
        name: displayName,
        size: size,
        direction: TransferDirection.received,
        peer: peer,
        time: DateTime.now(),
        ok: true,
        path: displayPath,
      ),
    );
  }

  /// Отправляет файлы на устройство. Возвращает сводку.
  Future<SendResult> sendFiles(Device device, List<String> paths) async {
    if (_busy) {
      return const SendResult(
        sent: 0,
        total: 0,
        errors: <String>['Дождитесь завершения текущей передачи'],
      );
    }
    _busy = true;
    _activeFile = null;
    _progress = null;
    _notify();

    var sent = 0;
    final errors = <String>[];
    for (final path in paths) {
      final file = File(path);
      final name = p.basename(path);
      _activeFile = name;
      _notify();
      try {
        if (!await file.exists()) {
          throw StateError('файл не найден');
        }
        final size = await file.length();
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('http://${device.ip}:${device.port}/upload'),
        );
        request.fields['from'] = _deviceName;
        request.files.add(
          await http.MultipartFile.fromPath('files', path, filename: name),
        );
        final streamed = await request.send().timeout(
          const Duration(minutes: 60),
        );
        final response = await http.Response.fromStream(streamed);
        if (response.statusCode != 200) {
          final body = response.body.length > 200
              ? response.body.substring(0, 200)
              : response.body;
          throw StateError('HTTP ${response.statusCode}: $body');
        }
        _addRecord(
          TransferRecord(
            name: name,
            size: size,
            direction: TransferDirection.sent,
            peer: device.name,
            time: DateTime.now(),
            ok: true,
            path: path,
          ),
        );
        sent++;
      } catch (error) {
        _addRecord(
          TransferRecord(
            name: name,
            size: 0,
            direction: TransferDirection.sent,
            peer: device.name,
            time: DateTime.now(),
            ok: false,
            error: error.toString(),
          ),
        );
        errors.add('$name: $error');
      }
    }

    _busy = false;
    _activeFile = null;
    _progress = null;
    _notify();
    return SendResult(sent: sent, total: paths.length, errors: errors);
  }

  Future<String> downloadDirectoryPath() async {
    if (Platform.isAndroid) {
      final publicPath = await AndroidDownloads.downloadsPath();
      if (publicPath != null) return publicPath;
    }
    final dir = await _ensureDownloadDir();
    return dir.path;
  }

  /// Открывает папку загрузок в файловом менеджере (desktop).
  Future<bool> openDownloadFolder() async {
    final dir = await _ensureDownloadDir();
    try {
      if (Platform.isLinux) {
        await Process.run('xdg-open', <String>[dir.path]);
        return true;
      }
      if (Platform.isWindows) {
        await Process.run('explorer', <String>[dir.path]);
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<Directory> _ensureDownloadDir() async {
    final cached = _downloadDir;
    if (cached != null) return cached;
    final dir = await _directoryResolver();
    _downloadDir = dir;
    return dir;
  }

  Future<Directory> _ensureIncomingDir() async {
    final cached = _incomingDir;
    if (cached != null) return cached;
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'outmng_incoming'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _incomingDir = dir;
    return dir;
  }

  /// Очищает локальную историю принятых и отправленных файлов.
  /// Сами файлы на диске не трогает.
  void clearHistory() {
    if (_records.isEmpty) return;
    _records.clear();
    _notify();
  }

  /// Меняет имя, которое устройство показывает другим (mDNS, /info).
  void updateDeviceName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _deviceName) return;
    _deviceName = trimmed;
    _notify();
  }

  void _addRecord(TransferRecord record) {
    _records.add(record);
    if (_records.length > 300) {
      _records.removeRange(0, _records.length - 300);
    }
    _notify();
  }

  void _reportProgress(int received, int? total) {
    if (total == null || total <= 0) {
      _progress = null;
    } else {
      _progress = (received / total).clamp(0.0, 1.0);
    }
    final now = DateTime.now();
    if (now.difference(_lastProgressAt) > const Duration(milliseconds: 150)) {
      _lastProgressAt = now;
      _notify();
    }
  }

  void _resetProgress() {
    _progress = null;
    _activeFile = null;
    _notify();
  }

  static String _remoteAddress(Request request) {
    final info = request.context['shelf.io.connection_info'];
    if (info is HttpConnectionInfo) return info.remoteAddress.address;
    return '—';
  }

  static String? _boundaryOf(String contentType) {
    final match = RegExp(
      r'boundary="?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(contentType);
    return match?.group(1)?.trim();
  }

  static String? _fieldNameFromDisposition(String? header) {
    if (header == null || header.isEmpty) return null;
    final match = RegExp(
      r'(?:^|;)\s*name\s*=\s*"([^"]*)"',
      caseSensitive: false,
    ).firstMatch(header);
    return match?.group(1);
  }

  static Future<List<int>> _readLimited(
    Stream<List<int>> stream,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length >= limit) continue;
      final remaining = limit - builder.length;
      builder.add(
        chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
      );
    }
    return builder.takeBytes();
  }

  static String? _filenameFromDisposition(String? header) {
    if (header == null || header.isEmpty) return null;
    final encoded = RegExp(
      r"filename\*\s*=\s*(?:UTF-8'')?([^;]+)",
      caseSensitive: false,
    ).firstMatch(header);
    if (encoded != null) {
      final value = encoded.group(1)!.trim().replaceAll('"', '');
      try {
        return Uri.decodeComponent(value);
      } catch (_) {
        return value;
      }
    }
    final quoted = RegExp(
      r'filename\s*=\s*"([^"]*)"',
      caseSensitive: false,
    ).firstMatch(header);
    if (quoted != null) return quoted.group(1);
    final plain = RegExp(
      r'filename\s*=\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(header);
    return plain?.group(1)?.trim();
  }

  static String _sanitize(String raw) {
    var name = raw.replaceAll('\\', '/').split('/').last.trim();
    name = name.replaceAll(RegExp(r'[\x00-\x1F<>:"|?*]'), '_');
    if (name.isEmpty || name == '.' || name == '..') name = 'file';
    if (name.length > 180) {
      final extension = p.extension(name);
      final keep = 180 - extension.length;
      name = '${name.substring(0, keep > 0 ? keep : 1)}$extension';
    }
    return name;
  }

  static Future<File> _uniqueFile(Directory directory, String name) async {
    var candidate = File(p.join(directory.path, name));
    if (!await candidate.exists()) return candidate;
    final extension = p.extension(name);
    final base = p.basenameWithoutExtension(name);
    for (var i = 1; i < 1000; i++) {
      candidate = File(p.join(directory.path, '$base ($i)$extension'));
      if (!await candidate.exists()) return candidate;
    }
    return File(
      p.join(
        directory.path,
        '$base-${DateTime.now().millisecondsSinceEpoch}$extension',
      ),
    );
  }

  Future<String?> _resolveLocalIp() async {
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
      return addresses.first.address;
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
}
