@echo off
rem  Pure ASCII on purpose: cmd.exe reads .cmd with the console codepage.
rem  A UTF-8 BOM would make this window flash and close.
setlocal
title HealthLink Share Link Generator

cd /d "%~dp0"

where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\分享链接.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\分享链接.ps1"
)

if %errorlevel% neq 0 (
    echo.
    echo   [FAILED] exit code %errorlevel%
    pause
)