@echo off
rem dvcl - changelists for Diversion (command line). See: dvcl help
setlocal DisableDelayedExpansion
rem The arguments travel as one line, split by dvcl itself, so any text arrives as typed: ( ) & , ; : - "quotes"
set DVCL_LINE=%*
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\dvcl-cli.ps1"
exit /b %ERRORLEVEL%
