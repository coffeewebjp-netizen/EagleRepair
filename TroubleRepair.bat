@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TroubleRepair.ps1" %*
exit /b %ERRORLEVEL%
