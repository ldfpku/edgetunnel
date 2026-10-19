@echo off
rem One-click node setup (Windows): double-click to run. Extra arguments go to Setup-Nodes.ps1
rem (for example: setup-nodes.cmd -Prefix B   or   setup-nodes.cmd -ReportOnly).
setlocal
pushd "%~dp0"
if errorlevel 1 (
    echo Failed to access the script directory.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Nodes.ps1" %*
popd
