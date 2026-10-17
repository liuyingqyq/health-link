@echo off
setlocal
title HealthLink 管理工具

cd /d "%~dp0"

echo.
echo   正在打开 HealthLink 管理工具...
echo.

rem 优先用 pwsh（PowerShell 7），退回 powershell 5.1
where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0管理.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0管理.ps1"
)

if %errorlevel% neq 0 (
    echo.
    echo   工具已退出（退出码 %errorlevel%）。
    pause
)
