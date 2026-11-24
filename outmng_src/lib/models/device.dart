import 'dart:io' show Platform;

/// Тип устройства, участвующего в обмене файлами.
enum DeviceType {
  android,
  windows,
  linux,
  unknown;

  /// Разбирает значение из mDNS TXT-записи или HTTP `/info`.
  static DeviceType parse(String? raw) {
    final value = (raw ?? '').trim().toLowerCase();
    return switch (value) {
      'android' => DeviceType.android,
      'windows' => DeviceType.windows,
      'linux' => DeviceType.linux,
      _ => DeviceType.unknown,
    };
  }

  /// Короткая подпись для интерфейса.
  String get label => switch (this) {
    DeviceType.android => 'Android',
    DeviceType.windows => 'Windows',
    DeviceType.linux => 'Linux',
    DeviceType.unknown => 'Устройство',
  };
}

/// Тип текущей платформы.
DeviceType get currentDeviceType {
  if (Platform.isAndroid) return DeviceType.android;
  if (Platform.isWindows) return DeviceType.windows;
  if (Platform.isLinux) return DeviceType.linux;
  return DeviceType.unknown;
}

/// Устройство в локальной сети.
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    required this.type,
  });

  /// Уникальный идентификатор сессии (TXT-запись `id`).
  final String id;
  final String name;
  final String ip;
  final int port;
  final DeviceType type;

  /// Адрес HTTP-сервера устройства.
  String get endpoint => 'http://$ip:$port';

  Device copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    DeviceType? type,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      type: type ?? this.type,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'ip': ip,
    'port': port,
    'type': type.name,
  };

  factory Device.fromJson(Map<String, Object?> json) => Device(
    id: (json['id'] ?? '').toString(),
    name: (json['name'] ?? 'Устройство').toString(),
    ip: (json['ip'] ?? '').toString(),
    port: int.tryParse('${json['port'] ?? ''}') ?? 53317,
    type: DeviceType.parse(json['type']?.toString()),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Device &&
          other.id == id &&
          other.name == name &&
          other.ip == ip &&
          other.port == port &&
          other.type == type;

  @override
  int get hashCode => Object.hash(id, name, ip, port, type);

  @override
  String toString() => 'Device($name, $ip:$port, ${type.name})';
}
