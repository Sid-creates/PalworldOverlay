@echo off
setlocal
cd /d "%~dp0"
echo PalworldOverlay installer
echo If Node.js is missing it will be downloaded automatically.
echo If install fails on permissions, right-click this file and choose "Run as administrator".
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 (
  echo.
  echo Install failed. See messages above.
  echo Tip: right-click install.bat -^> Run as administrator, then try again.
  pause
  exit /b 1
)
echo.
pause
