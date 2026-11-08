@echo off
rem dvcl-gui - changelist interface for Diversion.
rem Opens the workspace containing the current folder, else the last one used.
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\dvcl-gui.ps1" "%CD%."
