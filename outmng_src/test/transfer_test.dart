import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:outmng/models/device.dart';
import 'package:outmng/services/linux_mdns.dart';
import 'package:outmng/services/transfer_service.dart';
import 'package:path/path.dart' as p;

void main() {
  test('HTTP-сервер принимает файл и отдаёт /info', () async {
    final temp = await Directory.systemTemp.createTemp('outmng_test_');
    final service = TransferService(
      directoryResolver: () async {
        final dir = Directory(p.join(temp.path, 'OutMNG'));
        await dir.create(recursive: true);
        return dir;
      },
    );
    await service.startServer(deviceName: 'Test', deviceType: DeviceType.linux);
    expect(service.isRunning, isTrue);

    final info = await http.get(
      Uri.parse('http://127.0.0.1:${service.port}/info'),
    );
    expect(info.statusCode, 200);
    final payload = jsonDecode(info.body) as Map<String, Object?>;
    expect(payload['app'], 'OutMNG');
    expect(payload['name'], 'Test');

    final source = File(p.join(temp.path, 'hello.txt'));
    await source.writeAsString('hello outmng');
    final result = await service.sendFiles(
      Device(
        id: 'self',
        name: 'Test',
        ip: '127.0.0.1',
        port: service.port,
        type: DeviceType.linux,
      ),
      <String>[source.path],
    );
    expect(result.errors, isEmpty, reason: result.errors.join('; '));
    expect(result.sent, 1);
    expect(service.receivedRecords, hasLength(1));
    expect(service.receivedRecords.first.name, 'hello.txt');

    final received = File(p.join(temp.path, 'OutMNG', 'hello.txt'));
    expect(await received.exists(), isTrue);
    expect(await received.readAsString(), 'hello outmng');

    service.clearHistory();
    expect(service.records, isEmpty);
    expect(await received.exists(), isTrue);

    await service.stopServer();
    service.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'Linux mDNS находит соседнее объявление',
    () async {
      final found = Completer<Device>();
      final first = LinuxMdns(
        id: 'aaaaaa',
        name: 'Первый',
        port: 53317,
        onDevice: (_) {},
        onDeviceLost: (_) {},
      );
      final second = LinuxMdns(
        id: 'bbbbbb',
        name: 'Второй',
        port: 53318,
        onDevice: (device) {
          if (!found.isCompleted) found.complete(device);
        },
        onDeviceLost: (_) {},
      );
      await first.start();
      await second.start();
      if (!first.isRunning || !second.isRunning) {
        await first.stop();
        await second.stop();
        return;
      }
      final device = await found.future.timeout(const Duration(seconds: 20));
      expect(device.id, 'aaaaaa');
      expect(device.name, 'Первый');
      expect(device.port, 53317);
      expect(device.ip, isNotEmpty);
      await first.stop();
      await second.stop();
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
