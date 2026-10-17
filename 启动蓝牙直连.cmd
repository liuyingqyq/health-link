@echo off
rem  Pure ASCII on purpose (cmd.exe reads .cmd with the system codepage).
setlocal
title HealthLink - enable PC Bluetooth

cd /d "%~dp0"

echo.
echo   ============================================================
echo     HealthLink - connect heart rate strap directly to this PC
echo   ============================================================
echo.
echo   This enables the PC Bluetooth bridge so the server itself
echo   connects to your heart rate strap - no phone needed.
echo.

where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\pcble-toggle.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\pcble-toggle.ps1"
)

if %errorlevel% neq 0 (
    echo.
    echo   [FAILED] exit code %errorlevel%
    pause
)