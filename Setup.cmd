@echo off
setlocal
title Orbit Updater Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
if errorlevel 1 (
  echo.
  echo Setup did not complete. Review the message above and try again.
  pause
)
endlocal
