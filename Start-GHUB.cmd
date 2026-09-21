@echo off
setlocal
rem ============================================================
rem  G HUB ordered startup - launcher
rem  This file only launches the PowerShell script.
rem  All messages are printed by the script itself.
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_lghub_universal.ps1" %*
if errorlevel 1 (
    echo.
    echo Script exited with an error. Check the messages above.
    pause
)
endlocal
