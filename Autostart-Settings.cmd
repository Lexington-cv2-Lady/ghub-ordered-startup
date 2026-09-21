@echo off
setlocal
rem ============================================================
rem  G HUB autostart settings - launcher
rem  Opens an interactive menu (enable / disable / quit).
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ghub_autostart.ps1" %*
if errorlevel 1 (
    echo.
    echo Script exited with an error. Check the messages above.
    pause
)
endlocal
