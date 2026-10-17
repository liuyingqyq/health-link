@echo off
setlocal
cd /d "%~dp0"

set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"

echo ============================================
echo   HealthLink 手机端 HAP 构建
echo ============================================
echo.

rem 用 -ExecutionPolicy Bypass 避免"脚本未数字签名"的拦截
%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\build-phone.ps1" %*

echo.
pause
