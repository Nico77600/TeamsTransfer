@echo off
setlocal
set POWERSHELL_TELEMETRY_OPTOUT=1
rem Teams Transfer console launcher: checks the package, then starts the bundled or installed PowerShell 7 in STA mode (WPF needs it).
rem Extra arguments are passed on (for example -Demo for the offline demonstration with synthetic tenants).
set "PWSH=%~dp0powershell\pwsh.exe"
if not exist "%PWSH%" set "PWSH=pwsh.exe"
"%PWSH%" -NoLogo -NoProfile -Command "exit 0" >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7.4 or later was not found. Install it from https://aka.ms/powershell or extract the complete package, then start this file again.
  pause
  exit /b 1
)
if not exist "%~dp0Invoke-TeamsTransfer.ps1" (
  echo The package is incomplete: Invoke-TeamsTransfer.ps1 is missing. Extract the complete package before starting it.
  pause
  exit /b 1
)
if not exist "%~dp0lib\gui\Wpf.Ui.dll" (
  echo The console libraries are missing: run tools\Get-TeamsTransferDependencies.ps1 or use the complete release package.
  pause
  exit /b 1
)
rem A release package carries PackageIntegrity.psd1 and is verified by Invoke-TeamsTransfer.ps1 before anything runs. A source checkout needs -DevelopmentMode.
set "DEVMODE="
if not exist "%~dp0PackageIntegrity.psd1" set "DEVMODE=-DevelopmentMode"
"%PWSH%" -NoLogo -NoProfile -STA -File "%~dp0Invoke-TeamsTransfer.ps1" -Gui %DEVMODE% %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
