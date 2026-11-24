# OutMNG

Минималистичное приложение для передачи файлов по Wi-Fi и USB между
Android, Linux и Windows в одной локальной сети.

## Главное правило

Приложение работает **только пока открыто окно**. Нет автозапуска, трея и
фоновых сервисов: закрыли окно — процесс завершился, HTTP-сервер и mDNS
остановились.

## Как это устроено

- `lib/main.dart` — точка входа, Material 3, светлая/тёмная темы.
- `lib/screens/device_list_screen.dart` — главный экран. Здесь в `initState`
  поднимаются HTTP-сервер и mDNS, в `dispose` — останавливаются.
- `lib/services/discovery_service.dart` — поиск и объявление `_outmng._tcp`.
  На Android/Windows используется `nsd`, на Linux — встроенный mDNS-движок
  (`lib/services/linux_mdns.dart`), потому что `nsd` не поддерживает Linux.
- `lib/services/transfer_service.dart` — `shelf`-сервер на порту 53317:
  `GET /info`, `POST /upload`; приём в `Загрузки/OutMNG`.
- `lib/services/usb_service.dart` — MTP: Windows через `flutter_mtp_picker`,
  Linux через смонтированные gvfs-точки, Android — заглушка.
- `lib/screens/transfer_screen.dart` — две кнопки: «Отправить» и «Принять»,
  плюс история файлов.

## Сборка

```bash
flutter pub get
flutter analyze
flutter build apk --release
flutter build linux --release
flutter build windows --release   # только на Windows
```

Готовые артефакты и инструкции — в папке `dist/` рядом с исходниками.
