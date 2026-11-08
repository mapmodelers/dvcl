@echo off
rem dvcl - changelists for Diversion (command line). See: dvcl help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\dvcl-cli.ps1" %*
exit /b %ERRORLEVEL%
