@echo off
rem  Pure ASCII on purpose: cmd.exe reads .cmd with the console codepage,
rem  so non-ASCII text and a UTF-8 BOM both break parsing.
setlocal
title HealthLink Remote Share Wizard

cd /d "%~dp0"

where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0远程共享.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0远程共享.ps1"
)

if %errorlevel% neq 0 (
    echo.
    echo   [FAILED] exit code %errorlevel%
    pause
)