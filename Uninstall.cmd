@echo off
setlocal
title Orbit Updater Uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
if errorlevel 1 pause
endlocal
