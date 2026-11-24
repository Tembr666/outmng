import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_mtp_picker/flutter_mtp_picker.dart';
import 'package:path/path.dart' as p;

import 'storage.dart';

/// MTP-устройство, подключённое по USB.
class UsbDevice {
  const UsbDevice({required this.id, required this.name, this.mountPath});

  final String id;
  final String name;
  final String? mountPath;

  bool get isMounted => mountPath != null;
}

/// Результат импорта файлов с USB-устройства.
class UsbImportResult {
  const UsbImportResult({
    required this.files,
    required this.directory,
    this.error,
    this.cancelled = false,
  });

  final int files;
  final String directory;
  final String? error;
  final bool cancelled;
}

/// USB/MTP-обмен с Android-телефоном.
///
/// На Windows используется `flutter_mtp_picker`, на Linux — уже смонтированные
/// gvfs-точки (`/run/user/<uid>/gvfs/mtp:host=...`). На Android — заглушка:
/// телефон сам является MTP-устройством.
class UsbService {
  const UsbService();

  static bool get isSupported => Platform.isWindows || Platform.isLinux;

  static bool get isAndroid => Platform.isAndroid;

  /// Список подключённых по USB устройств.
  Future<List<UsbDevice>> listDevices() async {
    if (!isSupported) return const <UsbDevice>[];
    if (Platform.isWindows) return _listWindows();
    return _listLinux();
  }

  Future<List<UsbDevice>> _listWindows() async {
    try {
      final devices = await MtpPicker.getDevices();
      return devices
          .map((d) => UsbDevice(id: d.id, name: d.name))
          .toList(growable: false);
    } catch (_) {
      return const <UsbDevice>[];
    }
  }

  Future<List<UsbDevice>> _listLinux() async {
    final candidates = <Directory>[];
    final uid = await _userId();
    if (uid != null) {
      candidates.add(Directory('/run/user/$uid/gvfs'));
    }
    final user = Platform.environment['USER'];
    if (user != null && user.isNotEmpty) {
      candidates.add(Directory('/run/media/$user'));
      candidates.add(Directory('/media/$user'));
    }
    candidates.add(Directory('/media'));

    final result = <UsbDevice>[];
    final seen = <String>{};
    for (final root in candidates) {
      if (!await root.exists()) continue;
      try {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is! Directory) continue;
          final base = p.basename(entity.path);
          if (!_looksLikeMtp(base)) continue;
          if (!seen.add(entity.path)) continue;
          result.add(
            UsbDevice(
              id: entity.path,
              name: _prettyMtpName(base),
              mountPath: entity.path,
            ),
          );
        }
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  static bool _looksLikeMtp(String name) =>
      name.startsWith('mtp:') ||
      name.startsWith('mtp_') ||
      name.toLowerCase().contains('mtp');

  static String _prettyMtpName(String raw) {
    var name = raw;
    if (name.startsWith('mtp:host=')) {
      name = name.substring('mtp:host='.length);
    } else if (name.startsWith('mtp:')) {
      name = name.substring(4);
    }
    try {
      name = Uri.decodeComponent(name);
    } catch (_) {
      // Имя не URL-кодировано.
    }
    name = name.replaceAll('_', ' ').replaceAll('+', ' ').trim();
    return name.isEmpty ? 'USB-устройство' : name;
  }

  static Future<String?> _userId() async {
    final uid = Platform.environment['UID'];
    if (uid != null && uid.isNotEmpty) return uid;
    try {
      final result = await Process.run('id', <String>['-u']);
      final value = (result.stdout as String).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// Импортирует файлы с устройства в папку `Загрузки/OutMNG`.
  Future<UsbImportResult> importFiles(
    BuildContext context,
    UsbDevice device,
  ) async {
    final directory = await _ensureDownloadDir();
    if (Platform.isWindows) {
      if (!context.mounted) {
        return UsbImportResult(
          files: 0,
          directory: directory.path,
          cancelled: true,
        );
      }
      return _importWindows(context, device, directory);
    }
    return _importLinux(device, directory);
  }

  Future<UsbImportResult> _importWindows(
    BuildContext context,
    UsbDevice device,
    Directory directory,
  ) async {
    try {
      final selection = await MtpPicker.pickFolder(context);
      if (selection == null) {
        return UsbImportResult(
          files: 0,
          directory: directory.path,
          cancelled: true,
        );
      }
      final files = await MtpPicker.listMediaFiles(
        deviceId: selection.device.id,
        folderId: selection.folder.id,
        extensions: const <String>[
          'jpg',
          'jpeg',
          'png',
          'gif',
          'webp',
          'heic',
          'mp4',
          'mov',
          'mkv',
          'mp3',
          'wav',
          'pdf',
          'zip',
          'txt',
        ],
      );
      if (files.isEmpty) {
        return UsbImportResult(
          files: 0,
          directory: directory.path,
          error: 'В выбранной папке нет поддерживаемых файлов',
        );
      }
      final targets = <String, String>{
        for (final file in files)
          file.id: p.join(directory.path, _sanitize(file.name)),
      };
      final copied = await MtpPicker.copyFilesToLocal(
        deviceId: selection.device.id,
        files: targets,
      );
      return UsbImportResult(files: copied.length, directory: directory.path);
    } catch (error) {
      return UsbImportResult(
        files: 0,
        directory: directory.path,
        error: error.toString(),
      );
    }
  }

  Future<UsbImportResult> _importLinux(
    UsbDevice device,
    Directory directory,
  ) async {
    final root = device.mountPath;
    if (root == null) {
      return UsbImportResult(
        files: 0,
        directory: directory.path,
        error: 'Устройство не смонтировано',
      );
    }
    try {
      var copied = 0;
      await _copyTree(
        Directory(root),
        directory,
        depth: 0,
        onFile: () {
          copied++;
        },
      );
      return UsbImportResult(
        files: copied,
        directory: directory.path,
        error: copied == 0 ? 'На устройстве не найдено файлов' : null,
      );
    } catch (error) {
      return UsbImportResult(
        files: 0,
        directory: directory.path,
        error: error.toString(),
      );
    }
  }

  Future<void> _copyTree(
    Directory source,
    Directory target, {
    required int depth,
    required void Function() onFile,
  }) async {
    if (depth > 8) return;
    await for (final entity in source.list(followLinks: false)) {
      final base = p.basename(entity.path);
      if (base.startsWith('.')) continue;
      if (entity is File) {
        final fileTarget = await _uniqueFile(target, _sanitize(base));
        await entity.copy(fileTarget.path);
        onFile();
      } else if (entity is Directory) {
        await _copyTree(entity, target, depth: depth + 1, onFile: onFile);
      }
    }
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

  static String _sanitize(String raw) {
    var name = raw.replaceAll('\\', '/').split('/').last.trim();
    name = name.replaceAll(RegExp(r'[\x00-\x1F<>:"|?*]'), '_');
    return name.isEmpty ? 'file' : name;
  }

  static Future<Directory> _ensureDownloadDir() => resolveOutMngDirectory();
}
