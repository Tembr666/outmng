import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Папка `Загрузки/OutMNG`, куда складываются принятые файлы.
///
/// На Linux `path_provider` не умеет отдавать Downloads, поэтому сначала
/// читаем XDG-настройки и `~/Downloads`. На Android/Windows используется
/// системная папка загрузок, с запасным вариантом — документы приложения.
Future<Directory> resolveOutMngDirectory() async {
  final base = await _resolveDownloadsBase();
  final directory = Directory(p.join(base.path, 'OutMNG'));
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}

Future<Directory> _resolveDownloadsBase() async {
  if (Platform.isLinux) {
    final xdg = await _linuxDownloads();
    if (xdg != null) return xdg;
  }
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads;
  } catch (_) {
    // Платформа не поддерживает getDownloadsDirectory.
  }
  return getApplicationDocumentsDirectory();
}

Future<Directory?> _linuxDownloads() async {
  final fromEnv = Platform.environment['XDG_DOWNLOAD_DIR'];
  if (fromEnv != null && fromEnv.trim().isNotEmpty) {
    return Directory(_expand(fromEnv.trim()));
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;

  final config = File(p.join(home, '.config', 'user-dirs.dirs'));
  if (await config.exists()) {
    try {
      for (final line in await config.readAsLines()) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('XDG_DOWNLOAD_DIR=')) continue;
        var value = trimmed.substring('XDG_DOWNLOAD_DIR='.length).trim();
        if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        }
        value = _expand(value);
        if (value.isNotEmpty) return Directory(value);
      }
    } catch (_) {
      // Битый конфиг — используем ~/Downloads.
    }
  }
  return Directory(p.join(home, 'Downloads'));
}

String _expand(String path) {
  final home = Platform.environment['HOME'] ?? '';
  return path.replaceAll(r'${HOME}', home).replaceAll(r'$HOME', home);
}
