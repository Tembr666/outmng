# OutMNG для Windows — сборка

В этой папке лежит полный исходник и всё для сборки `.exe`.
Собрать Windows-приложение можно только на Windows (или на GitHub Actions) —
это ограничение самого Flutter, а не проекта.

```
OutMNG-windows-kit/
├── build_windows.bat          ← двойной щелчок для сборки
├── README_WINDOWS.md          ← этот файл
├── .github/workflows/build-windows.yml
└── outmng_src/                ← исходник приложения
```

## Вариант 1. Собрать локально на Windows

### Шаг 1. Visual Studio 2022 Community + C++

1. Скачайте: <https://visualstudio.microsoft.com/vs/community/>
2. В установщике откройте вкладку **Workloads / Рабочие нагрузки**.
3. Отметьте **Desktop development with C++**
   («Разработка классических приложений на C++»).
4. Справа проверьте, что входят:
   - MSVC v143 — VS 2022 C++ x64/x86 build tools;
   - Windows 10/11 SDK;
   - C++ CMake tools for Windows.
5. Установите (это ~7–10 ГБ) и при необходимости перезагрузитесь.

### Шаг 2. Flutter SDK

1. Скачайте стабильный Flutter для Windows:
   <https://docs.flutter.dev/get-started/install/windows>
2. Распакуйте, например, в `C:\src\flutter`
   (не в `C:\Program Files` — нужны права на запись).
3. Добавьте `C:\src\flutter\bin` в переменную среды **Path**.
4. Откройте новый терминал и проверьте:

   ```bat
   flutter --version
   flutter doctor
   ```

   Пункт **Windows** в `flutter doctor` должен быть с галочкой.
   Если Visual Studio не видна — переустановите C++ workload.

### Шаг 3. Сборка

Запустите `build_windows.bat` двойным щелчком.

Скрипт сам:
- проверит Flutter в PATH;
- проверит Visual Studio с C++ workload;
- выполнит `flutter pub get`;
- выполнит `flutter build windows --release`.

Либо вручную из этой папки:

```bat
cd outmng_src
flutter pub get
flutter build windows --release
```

### Шаг 4. Забрать готовое приложение

Результат лежит здесь:

```
outmng_src\build\windows\x64\runner\Release\
```

**Забирайте всю папку `Release` целиком.** Внутри должны быть:

```
outmng.exe
flutter_windows.dll
несколько плагинов вида *_plugin.dll
data\
```

> ⚠️ **Важно:** если скопировать только `outmng.exe`, приложение НЕ запустится.
> Рядом обязательны все DLL и папка `data`. Можно скопировать папку `Release`
> на другой компьютер и запускать `outmng.exe` оттуда — устанавливать ничего
> не нужно.

## Вариант 2. Альтернатива без установки 10 ГБ на Windows-ПК: собрать через GitHub Actions

GitHub соберёт `.exe` на своей Windows-машине, вам останется скачать архив.

1. Создайте **пустой** репозиторий на GitHub (можно приватный).
2. В папке `OutMNG-windows-kit` выполните (замените `USER` и `REPO`):

   ```bash
   git init
   git add .
   git commit -m init
   git remote add origin https://github.com/USER/REPO.git
   git branch -M main
   git push -u origin main
   ```

3. Откройте на GitHub вкладку **Actions** → workflow **Build Windows**.
   Сборка запустится автоматически (или нажмите **Run workflow**).
4. Дождитесь зелёной галочки (~5–10 минут).
5. Откройте завершённый запуск → раздел **Artifacts** →
   скачайте **OutMNG-windows-x64**.
6. Распакуйте скачанный zip, внутри будет `OutMNG-windows-x64.zip`,
   а в нём — папка `Release`. Распакуйте и её.
   Запускайте `outmng.exe` **из папки `Release`**, не выдёргивая exe отдельно.

> В этом архиве workflow уже лежит по пути `.github/workflows/build-windows.yml`
> и настроен на подпапку `outmng_src`. Ничего менять не нужно.
> Сам репозиторий в рамках поставки не создавался — это делаете вы вручную.

## Что делает приложение

- Пока окно открыто — работает HTTP-сервер на порту 53317 и mDNS-объявление
  `_outmng._tcp`, поэтому другие устройства видят ПК в списке.
- Закрыли окно — процесс завершился, сервер и mDNS остановились.
  Фонового режима, трея и автозапуска нет.
- Принятые файлы сохраняются в `Загрузки\OutMNG`
  (`%USERPROFILE%\Downloads\OutMNG`).
- Своё имя меняется карандашом на верхней карточке и сразу видно другим
  устройствам. Чужие устройства можно переименовать только у себя (⋮ →
  «Переименовать») или скрыть из списка (⋮ → «Удалить», возвращает ↻).
- История отправлений и приёмов очищается значком метлы на экране передачи;
  сами файлы остаются в «Загрузках».
- USB: подключите Android-телефон кабелем, разрешите доступ к файлам,
  нажмите иконку USB в приложении и выберите устройство для импорта.
