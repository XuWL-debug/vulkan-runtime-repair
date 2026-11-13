@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-VulkanRuntime.ps1" -Mode Fix %*
echo.
echo If the probe still fails, reinstall the full graphics driver with a clean/factory-reset install.
pause
