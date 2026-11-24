import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';

/// Локальные настройки: своё имя устройства и псевдонимы чужих устройств.
///
/// Всё хранится только на этом устройстве и никуда не отправляется.
class SettingsService extends ChangeNotifier {
  static const String _ownNameKey = 'own_device_name';
  static const String _aliasesKey = 'device_aliases_v1';
  static const String _deviceIdKey = 'device_id_v1';

  SharedPreferences? _prefs;
  String? _ownName;
  String _deviceId = '';
  Map<String, String> _aliases = <String, String>{};

  bool get isLoaded => _prefs != null;

  /// Постоянный идентификатор этого устройства.
  ///
  /// Нужен, чтобы псевдонимы чужих устройств не терялись после перезапуска:
  /// соседи узнают нас по этому id в mDNS и `/info`.
  String get deviceId => _deviceId;

  /// Загружает настройки с диска (вызывается один раз при старте).
  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _ownName = _prefs?.getString(_ownNameKey);
      _deviceId = _prefs?.getString(_deviceIdKey)?.trim() ?? '';
      final raw = _prefs?.getString(_aliasesKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _aliases = <String, String>{
            for (final entry in decoded.entries)
              entry.key.toString(): entry.value.toString(),
          };
        }
      }
    } catch (_) {
      // Настройки недоступны — работаем с значениями по умолчанию.
    }
    if (_deviceId.isEmpty) {
      _deviceId = _generateDeviceId();
      try {
        await _prefs?.setString(_deviceIdKey, _deviceId);
      } catch (_) {
        // Идентификатор останется в памяти до закрытия приложения.
      }
    }
    notifyListeners();
  }

  static String _generateDeviceId() {
    final random = Random.secure();
    return List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Своё имя или запасное системное.
  String ownName(String fallback) {
    final value = _ownName?.trim();
    return value == null || value.isEmpty ? fallback : value;
  }

  bool get hasCustomOwnName => _ownName?.trim().isNotEmpty == true;

  Future<void> setOwnName(String name) async {
    final trimmed = name.trim();
    _ownName = trimmed.isEmpty ? null : trimmed;
    if (_ownName == null) {
      await _prefs?.remove(_ownNameKey);
    } else {
      await _prefs?.setString(_ownNameKey, _ownName!);
    }
    notifyListeners();
  }

  /// Имя устройства с учётом локального псевдонима.
  String displayName(Device device) {
    final alias = _aliases[device.id]?.trim();
    return alias == null || alias.isEmpty ? device.name : alias;
  }

  bool hasAlias(String deviceId) => _aliases.containsKey(deviceId);

  /// Задаёт или снимает псевдоним (`null`/пустая строка — снять).
  Future<void> setAlias(String deviceId, String? name) async {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      _aliases.remove(deviceId);
    } else {
      _aliases[deviceId] = trimmed;
    }
    await _saveAliases();
    notifyListeners();
  }

  Future<void> clearAliases() async {
    _aliases.clear();
    await _saveAliases();
    notifyListeners();
  }

  Future<void> _saveAliases() async {
    try {
      await _prefs?.setString(_aliasesKey, jsonEncode(_aliases));
    } catch (_) {
      // Не критично: псевдонимы останутся в памяти до закрытия.
    }
  }
}
