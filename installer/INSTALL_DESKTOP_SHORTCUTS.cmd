@echo off
setlocal

where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh.exe^) is required.
  echo Install with: winget install --id Microsoft.PowerShell -e --source winget
  pause
  exit /b 1
)

set "SCRIPT=%~dp0scripts\install-desktop-shortcuts.ps1"
if not exist "%SCRIPT%" (
  echo Missing shortcut installer script: %SCRIPT%
  pause
  exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%errorlevel%"
pause
exit /b %RC%
