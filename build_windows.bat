@echo off
rem ============================================================
rem  OutMNG - сборка Windows-версии
rem  Требования:
rem    1) Flutter SDK в PATH (проверка ниже)
rem    2) Visual Studio 2022 Community с workload
rem       "Desktop development with C++" (Разработка классических
rem       приложений на C++)
rem  Запускать двойным щелчком из этой папки.
rem ============================================================
chcp 65001 >nul
setlocal
cd /d "%~dp0outmng_src"

echo.
echo [1/4] Проверяем Flutter...
where flutter >nul 2>nul
if errorlevel 1 (
  echo.
  echo ОШИБКА: Flutter не найден в PATH.
  echo Установите Flutter SDK и добавьте папку flutter\bin в PATH:
  echo   https://docs.flutter.dev/get-started/install/windows
  echo После этого закройте и снова откройте это окно.
  echo.
  pause
  exit /b 1
)
call flutter --version
if errorlevel 1 goto :error

echo.
echo [2/4] Проверяем Visual Studio с C++ workload...
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSPATH="
if exist "%VSWHERE%" (
  for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
)
if not defined VSPATH (
  echo.
  echo ОШИБКА: не найдена Visual Studio 2022 с компонентом C++.
  echo Установите Visual Studio 2022 Community:
  echo   https://visualstudio.microsoft.com/vs/community/
  echo В установщике выберите workload
  echo   "Desktop development with C++" / "Разработка классических приложений на C++".
  echo Затем запустите этот файл снова.
  echo.
  pause
  exit /b 1
)
echo Найдена Visual Studio: %VSPATH%

echo.
echo [3/4] flutter pub get...
call flutter config --enable-windows-desktop >nul
call flutter pub get
if errorlevel 1 goto :error

echo.
echo [4/4] flutter build windows --release...
call flutter build windows --release
if errorlevel 1 goto :error

echo.
echo ============================================================
echo  ГОТОВО.
echo  Забирайте ВСЮ папку целиком:
echo    %CD%\build\windows\x64\runner\Release\
echo.
echo  ВАЖНО: копируйте всю папку Release, а не только outmng.exe.
echo  Без соседних DLL и папки data приложение не запустится.
echo ============================================================
echo.
pause
exit /b 0

:error
echo.
echo СБОРКА НЕ УДАЛАСЬ. Смотрите сообщение об ошибке выше.
echo.
pause
exit /b 1
