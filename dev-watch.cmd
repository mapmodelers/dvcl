@echo off
rem dvcl dev watcher: start once and leave open. Runs only the actions listed in tools\watch.ps1 (tests, link build, release).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\watch.ps1"
