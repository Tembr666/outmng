import 'dart:io';

import 'package:flutter/services.dart';

/// Сохранение принятых файлов в системную папку «Загрузки» на Android.
///
/// На Android 10+ файл вставляется через MediaStore (без разрешений), поэтому
/// он сразу виден в «Загрузках» и галерее. На старых версиях — прямая запись
/// в `Download` при выданном разрешении. Если не получилось, возвращается
/// `null`, и приложение сохраняет файл в свою папку.
class AndroidDownloads {
  const AndroidDownloads._();

  static const MethodChannel _channel = MethodChannel('com.outmng/downloads');

  /// Сохраняет файл в общую папку «Загрузки». Возвращает отображаемый путь
  /// вида `Download/файл.ext` или `null`, если сохранить не удалось.
  static Future<String?> saveFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('saveToDownloads', {
        'path': sourcePath,
        'name': fileName,
        'mime': mimeType,
      });
    } catch (_) {
      return null;
    }
  }

  /// Путь к системной папке «Загрузки» (для отображения в интерфейсе).
  static Future<String?> downloadsPath() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getDownloadsPath');
    } catch (_) {
      return null;
    }
  }
}
