@echo off
title Brave Manifest V3 Extension & Service Worker Recovery
color 0B
echo.
echo   ==============================================
echo     Brave Extension & Service Worker Recovery
echo   ==============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\Fix-BraveExtensions.ps1"
echo.
echo   ==============================================
echo   Press any key to exit...
pause > nul
