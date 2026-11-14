@echo off
rem Builds and installs the dvcl link plugin into your Unreal engine (see install.ps1). Restart Unreal once after.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %ERRORLEVEL%
