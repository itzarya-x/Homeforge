@echo off
:: Uninstall-SSHD.cmd - Double-click launcher to uninstall Windows SSH Server setup

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Install-SSHD.ps1"

:: Check for administrative privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Error: This script requires administrative privileges.
    echo Right-click and select "Run as administrator".
    pause
    exit /b 1
)

echo ==========================================
echo Uninstalling Windows SSH Server Setup
echo ==========================================
echo.

:: Launch PowerShell script in uninstall mode
PowerShell -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Uninstall -PauseOnExit

echo.
echo Uninstall finished.
pause