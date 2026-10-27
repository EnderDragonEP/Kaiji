@echo off
rem Build Kaiji:
rem   build.bat [args]          dist\Kaiji\Kaiji.exe; args go to PyInstaller (needs: pip install pyinstaller)
rem   build.bat android [args]  dist\Kaiji-release.apk, the Android app; args go to flutter build apk,
rem                             e.g. --split-per-abi (needs Flutter and the Android SDK, see mobile\README.md)
rem   build.bat all             both
setlocal
set "here=%~dp0"
cd /d "%here%"
if /i "%~1"=="android" goto android
if /i "%~1"=="all" goto all
call :exe %*
exit /b %errorlevel%

:android
rem the arguments after "android", as typed
set "rest=%*"
call :apk %rest:*android=%
exit /b %errorlevel%

:all
call :exe || exit /b 1
call :apk
exit /b %errorlevel%

:exe
python tools\make_ico.py build\Kaiji.ico || exit /b 1
pyinstaller --noconfirm --windowed --name Kaiji --icon "%here%build\Kaiji.ico" ^
  --collect-submodules kaiji_app ^
  --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtQuick ^
  %* Kaiji.pyw
exit /b

:apk
rem Flutter from PATH, or from %USERPROFILE%\flutter (where it was installed for Kaiji)
where flutter >nul 2>&1 || set "PATH=%USERPROFILE%\flutter\bin;%PATH%"
where flutter >nul 2>&1 || (echo Flutter isn't on PATH: see mobile\README.md & exit /b 1)
set "out=%here%mobile\build\app\outputs\flutter-apk"
rem clear out earlier APKs, so only what this build makes goes to dist
if exist "%out%\app-*.apk" del /q "%out%\app-*.apk"
pushd "%here%mobile"
call flutter build apk %*
if errorlevel 1 (popd & exit /b 1)
popd
if not exist dist mkdir dist
rem app-release.apk -> dist\Kaiji-release.apk, app-arm64-v8a-release.apk -> dist\Kaiji-arm64-v8a-release.apk
for %%f in ("%out%\app-*.apk") do for /f "tokens=1,* delims=-" %%a in ("%%~nxf") do (
  copy /y "%%f" "dist\Kaiji-%%b" >nul && echo Copied to dist\Kaiji-%%b
)
exit /b 0
