@echo off
rem ============================================================
rem  IMPORTANT: this file must stay PURE ASCII (no Chinese).
rem  cmd.exe reads .bat/.cmd using the console codepage, so UTF-8
rem  Chinese text gets split and breaks parsing. All Chinese UI
rem  text lives in the .ps1 files instead (which REQURE a UTF-8 BOM).
rem  Do NOT add a BOM to this file either: cmd.exe would treat it as
rem  part of the first command and the window would flash and close.
rem ============================================================
setlocal
title HealthLink Server

cd /d "%~dp0"

echo.
echo   ================================================
echo      HealthLink  -  PC server
echo      Receives phone health data + live relay
echo   ================================================
echo.

rem ---- locate node ----
set "NODE_EXE="
where node >nul 2>&1 && set "NODE_EXE=node"

if not defined NODE_EXE (
  if exist "D:\Downloads\DevEco Studio\tools\node\node.exe" (
    set "NODE_EXE=D:\Downloads\DevEco Studio\tools\node\node.exe"
  )
)

if not defined NODE_EXE (
  echo   [ERROR] Node.js not found.
  echo.
  echo   Please install Node.js ^(18 or newer^): https://nodejs.org/
  echo   Then run this file again.
  echo.
  pause
  exit /b 1
)

rem ---- optional: --open  = open the panel in browser after start ----
set "OPEN_BROWSER=0"
if /i "%~1"=="--open" set "OPEN_BROWSER=1"

rem ---- real startup logic lives in tools\launcher-core.ps1 ----
rem  -ExecutionPolicy Bypass keeps this working on locked-down machines
rem  without changing any system setting.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\launcher-core.ps1" -NodePath "%NODE_EXE%" -OpenBrowser %OPEN_BROWSER%
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%EXITCODE%"=="0" (
  echo   [FAILED] launcher exit code %EXITCODE%
) else (
  echo   HealthLink stopped.
)
echo.
pause
exit /b %EXITCODE%
