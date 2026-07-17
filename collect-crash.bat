@echo off
setlocal
cd /d "%~dp0"
echo PalworldOverlay crash collector
echo Copies UE4SS dumps, UE4SS.log, Unreal CrashContext, and bridge files into crash\
echo then makes a .zip you can send.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-crash.ps1" %*
if errorlevel 1 (
  echo.
  echo Collect failed. See messages above.
  pause
  exit /b 1
)
echo.
pause
