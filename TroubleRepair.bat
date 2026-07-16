@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

if not "%~1"=="" goto legacy

set "TROUBLE_REPAIR_ROOT=%~dp0"
set "WPF_EXE=%~dp0wpf\bin\Release\net10.0-windows\CoffeeDiagnose.exe"

if exist "%WPF_EXE%" (
  start "" "%WPF_EXE%"
  exit /b 0
)

where dotnet.exe >nul 2>nul
if errorlevel 1 goto legacy

dotnet build "%~dp0wpf\CoffeeDiagnose.csproj" -c Release --nologo --verbosity quiet
if errorlevel 1 goto legacy
if not exist "%WPF_EXE%" goto legacy

start "" "%WPF_EXE%"
exit /b 0

:legacy
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TroubleRepair.ps1" %*
exit /b %ERRORLEVEL%
