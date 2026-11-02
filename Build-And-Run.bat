@echo off
setlocal DisableDelayedExpansion

rem Use inbox 64-bit Windows PowerShell, including from a 32-bit launcher.
set "HGM_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "HGM_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

"%HGM_POWERSHELL%" -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0scripts\Build-And-Run.ps1" %*
set "HGM_EXIT_CODE=%ERRORLEVEL%"

if not "%HGM_EXIT_CODE%"=="0" (
    echo.
    echo Build or launch failed. The application was not started.
    pause
)
exit /b %HGM_EXIT_CODE%
