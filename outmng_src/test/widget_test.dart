import 'package:flutter_test/flutter_test.dart';
import 'package:outmng/models/device.dart';
import 'package:outmng/services/transfer_service.dart';

void main() {
  test('Device сериализуется и парсится', () {
    const device = Device(
      id: 'abc',
      name: 'Ноутбук',
      ip: '192.168.1.10',
      port: 53317,
      type: DeviceType.linux,
    );
    final restored = Device.fromJson(device.toJson());
    expect(restored, device);
    expect(restored.endpoint, 'http://192.168.1.10:53317');
  });

  test('DeviceType.parse понимает типы и мусор', () {
    expect(DeviceType.parse('android'), DeviceType.android);
    expect(DeviceType.parse('WINDOWS'), DeviceType.windows);
    expect(DeviceType.parse('linux'), DeviceType.linux);
    expect(DeviceType.parse(null), DeviceType.unknown);
    expect(DeviceType.parse('plan9'), DeviceType.unknown);
  });

  test('Размер файла читается человеком', () {
    expect(TransferRecord.formatBytes(512), '512 Б');
    expect(TransferRecord.formatBytes(2048), '2.00 КБ');
    expect(TransferRecord.formatBytes(5 * 1024 * 1024), '5.00 МБ');
  });
}
