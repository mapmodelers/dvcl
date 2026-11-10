@echo off
rem tests\run.cmd [workspace] - offline selftest, then read-only checks on a Diversion workspace
rem (dvcl status + window self-check). Changes nothing. Report: tests\last-run.txt
setlocal
set "T=%~dp0.."
set "WS=%~1"
if "%WS%"=="" set "WS=%CD%"
set "OUT=%~dp0last-run.txt"
(
  echo ===VERSION===
  type "%T%\VERSION"
  echo ===SELFTEST===
  call "%T%\dvcl.cmd" selftest
  echo ===STATUS===
  pushd "%WS%"
  call "%T%\dvcl.cmd"
  popd
) > "%OUT%" 2>&1
if exist "%~dp0gui-selfcheck.txt" del "%~dp0gui-selfcheck.txt"
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%T%\src\dvcl-gui.ps1" "%WS%" -SelfCheck
echo ===GUI===>> "%OUT%"
if exist "%~dp0gui-selfcheck.txt" (type "%~dp0gui-selfcheck.txt" >> "%OUT%") else (echo GUI self-check wrote no report>> "%OUT%")
echo Report: %OUT%
