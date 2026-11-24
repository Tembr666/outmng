import 'package:flutter_test/flutter_test.dart';
import 'package:outmng/models/device.dart';
import 'package:outmng/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Своё имя сохраняется между запусками', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService();
    await settings.load();
    expect(settings.ownName('Linux'), 'Linux');

    await settings.setOwnName('  Мой ноутбук  ');
    expect(settings.ownName('Linux'), 'Мой ноутбук');

    final reloaded = SettingsService();
    await reloaded.load();
    expect(reloaded.ownName('Linux'), 'Мой ноутбук');

    await reloaded.setOwnName('');
    expect(reloaded.ownName('Linux'), 'Linux');
  });

  test('Идентификатор устройства не меняется между запусками', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final first = SettingsService();
    await first.load();
    final id = first.deviceId;
    expect(id, isNotEmpty);
    expect(id.length, 16);

    final second = SettingsService();
    await second.load();
    expect(second.deviceId, id);
  });

  test('Псевдонимы чужих устройств сохраняются и снимаются', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const device = Device(
      id: 'dev-1',
      name: 'Android',
      ip: '192.168.1.5',
      port: 53317,
      type: DeviceType.android,
    );

    final settings = SettingsService();
    await settings.load();
    expect(settings.displayName(device), 'Android');
    expect(settings.hasAlias(device.id), isFalse);

    await settings.setAlias(device.id, 'Телефон мамы');
    expect(settings.displayName(device), 'Телефон мамы');
    expect(settings.hasAlias(device.id), isTrue);

    final reloaded = SettingsService();
    await reloaded.load();
    expect(reloaded.displayName(device), 'Телефон мамы');

    await reloaded.setAlias(device.id, '   ');
    expect(reloaded.displayName(device), 'Android');
    expect(reloaded.hasAlias(device.id), isFalse);
  });
}
