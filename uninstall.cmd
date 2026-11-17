@echo off
rem Removes dvcl from this PC: closes it, removes its desktop and Start menu shortcuts and dvcl.exe.
rem Asks before removing your dvcl settings. Workspaces keep their .dvcl folder (your changelists).
rem Unreal link: remove it first in dvcl (Tools - Unreal link - Remove).
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*dvcl-gui.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; foreach ($p in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) { Remove-Item -LiteralPath (Join-Path $p 'dvcl.lnk') -Force -ErrorAction SilentlyContinue }"
if exist dvcl.exe del /q dvcl.exe
if "%1"=="/q" goto done
choice /m "Also remove your dvcl settings (window layout, last workspace)"
if errorlevel 2 goto done
if exist "%APPDATA%\dvcl" rmdir /s /q "%APPDATA%\dvcl"
:done
echo dvcl removed. Your workspaces keep their .dvcl folder (changelists): delete it by hand if you no longer need it.
echo You can now delete this folder.
if not "%1"=="/q" pause
