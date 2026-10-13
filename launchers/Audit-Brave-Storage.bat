@echo off
title Chromium Extension Storage & Service Worker Forensic Audit
color 0A
echo.
echo   ==============================================
echo     Brave Extension Storage & SW Forensic Audit
echo   ==============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\Audit-BraveExtensionStorage.ps1"
echo.
echo   ==============================================
echo   Press any key to exit...
pause > nul
