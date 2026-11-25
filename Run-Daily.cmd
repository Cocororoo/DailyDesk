@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0runner\Start-GameDailySuite.ps1" %*
if errorlevel 1 exit /b 1
