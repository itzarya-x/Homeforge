@echo off
:: Setup-SSHD.cmd - Double-click launcher for Windows SSH Server setup
:: Runs Install-SSHD.ps1 with required elevation and default options

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Install-SSHD.ps1"

:: Check for administrative privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Error: This script requires administrative privileges.
    echo Right-click and select "Run as administrator", or run:
    echo   PowerShell -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
    pause
    exit /b 1
)

echo ==========================================
echo Windows SSH Server Setup
echo ==========================================
echo.

:: Launch PowerShell script with default options
:: -NoFullAdmin by default (to avoid the password+full-admin tradeoff unless wanted)
PowerShell -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -NoFullAdmin -PauseOnExit

echo.
echo Setup finished.
pause