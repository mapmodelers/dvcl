@echo off
rem Builds dvcl.exe here and adds dvcl to the desktop and the Start menu. Run again after moving the folder.
setlocal
cd /d "%~dp0"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
"%CSC%" /nologo /target:winexe /out:dvcl.exe /win32icon:dvcl.ico src\launcher.cs
if errorlevel 1 ( echo Build failed. & pause & exit /b 1 )
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = New-Object -ComObject WScript.Shell; foreach ($p in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) { $l = $s.CreateShortcut((Join-Path $p 'dvcl.lnk')); $l.TargetPath = '%~dp0dvcl.exe'; $l.WorkingDirectory = '%~dp0'; $l.IconLocation = '%~dp0dvcl.ico'; $l.Description = 'Changelists for Diversion'; $l.Save() }"
echo dvcl installed: desktop and Start menu.
where dv >nul 2>&1 || echo NOTE: the Diversion dv command was not found. Install Diversion Desktop and sign in first.
if "%1"=="/q" exit /b 0
echo Opening dvcl: pick your Diversion workspace the first time.
start "" "%~dp0dvcl.exe"
pause
