@echo off
chcp 65001 >nul
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it with:
  echo winget install --id Microsoft.PowerShell -e --source winget
  pause
  exit /b 1
)
title Codex Multi-Model Manager - Health Check
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\health-check.ps1"
set HEALTH_EXIT=%ERRORLEVEL%
echo.
if "%HEALTH_EXIT%"=="2" (
  set /p DO_REPAIR=Health check found blockers. Run safe repair now? [y/N]: 
  if /I "%DO_REPAIR%"=="y" pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\health-check.ps1" -Repair
)
pause
