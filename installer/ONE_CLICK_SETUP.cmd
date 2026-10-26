@echo off
chcp 65001 >nul
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required for this UTF-8 installer.
  echo Install it with: winget install --id Microsoft.PowerShell -e --source winget
  echo Then reopen this launcher.
  echo.
  pause
  exit /b 1
)
title Codex Multi-Model Manager - Setup
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
pause
