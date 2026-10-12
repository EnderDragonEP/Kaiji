@echo off
rem Build a standalone dist\Kaiji\Kaiji.exe (needs: pip install pyinstaller)
cd /d "%~dp0"
python tools\make_ico.py build\Kaiji.ico || exit /b 1
pyinstaller --noconfirm --windowed --name Kaiji --icon "%~dp0build\Kaiji.ico" ^
  --collect-submodules kaiji_app ^
  --exclude-module PySide6.QtWebEngineCore --exclude-module PySide6.QtQuick ^
  %* Kaiji.pyw
