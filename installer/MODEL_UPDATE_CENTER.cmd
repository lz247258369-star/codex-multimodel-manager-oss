@echo off
chcp 65001 >nul
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it with:
  echo winget install --id Microsoft.PowerShell -e --source winget
  pause
  exit /b 1
)
title Codex Multi-Model Manager - Model Update Center
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\model-update-center.ps1"
echo.
pause
