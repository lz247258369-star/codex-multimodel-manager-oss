@echo off
setlocal

where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh.exe^) is required.
  echo Install with: winget install --id Microsoft.PowerShell -e --source winget
  pause
  exit /b 1
)

set "SCRIPT=%~dp0scripts\visual-console-entry.ps1"
if not exist "%SCRIPT%" (
  echo Missing Visual Console entrypoint: %SCRIPT%
  pause
  exit /b 1
)

pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%"
exit /b %errorlevel%
