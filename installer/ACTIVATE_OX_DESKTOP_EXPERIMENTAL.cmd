@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh.exe^) is required.
  echo Install with: winget install --id Microsoft.PowerShell -e --source winget
  pause
  exit /b 1
)

pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\desktop-chat-provider.ps1" -Mode activate-ox
set EXITCODE=%ERRORLEVEL%
echo.
if not "%EXITCODE%"=="0" echo Activation failed with exit code %EXITCODE%.
pause
exit /b %EXITCODE%
