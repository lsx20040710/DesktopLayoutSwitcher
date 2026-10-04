@echo off
set "SCRIPT=%~dp0DesktopLayoutSwitcher.ps1"
start "" powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Gui
