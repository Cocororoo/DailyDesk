@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0dashboard\Start-Dashboard.ps1" %*
if errorlevel 1 (
    if "%~1"=="" pause
    exit /b 1
)
