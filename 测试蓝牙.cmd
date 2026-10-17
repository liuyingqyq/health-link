@echo off
title HealthLink BLE Scan Test
cd /d "%~dp0"

echo.
echo   ==========================================================
echo     HealthLink  PC Bluetooth  -  find heart rate strap
echo   ==========================================================
echo.
echo   BEFORE you start, please make sure:
echo.
echo     1. The heart rate strap is ON YOUR ARM and touching skin
echo        (it only powers up / advertises when it detects skin)
echo.
echo     2. STOP the HealthLink app on your phone
echo        (a BLE device can only be held by ONE host at a time -
echo         if the phone holds it, the PC can never see it)
echo.
echo     3. Also turn off the phone's Bluetooth, or disconnect HW9
echo        in the phone's Bluetooth settings.
echo.
echo   Then this window will scan for 90 seconds and list what it finds.
echo   Put the strap right next to the PC.
echo.

pause

"pc\ble\bin\Release\net8.0-windows10.0.19041.0\win-x64\HealthLinkBle.exe" --verbose --scan-timeout 90

echo.
echo   Scan finished. Look for a line containing "180D" or "HW9".
echo.
pause