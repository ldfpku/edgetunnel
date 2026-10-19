@echo off
rem One-click setup: apply proxy settings, register the logon task, verify, summarize.
rem Double-click to run. Extra arguments are passed to Setup-Proxy.ps1 (e.g. -DryRun, -RepeatMinutes 30, -Uninstall).
setlocal
pushd "%~dp0"
if errorlevel 1 (
    echo Failed to access the setup directory.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Proxy.ps1" %*
popd
echo.
pause
