@echo off
if exist "%~dp0DesktopLayoutSwitcher.exe" (
    start "" "%~dp0DesktopLayoutSwitcher.exe"
    exit /b
)
set "DLS_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "DLS_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
start "" "%DLS_POWERSHELL%" -STA -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "%~dp0DesktopLayoutSwitcher.ps1" -Action Gui
