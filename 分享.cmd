@echo off
setlocal
title HealthLink 分享链接

cd /d "%~dp0"

where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0分享.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0分享.ps1"
)

if %errorlevel% neq 0 (
    echo.
    echo   工具已退出（退出码 %errorlevel%）。
    pause
)
