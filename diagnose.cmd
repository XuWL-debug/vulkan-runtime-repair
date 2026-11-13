@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-VulkanRuntime.ps1" -Mode Diagnose %*
echo.
pause
