# tests\check-build.ps1 <workspace> [<engine>] - builds the workspace's Unreal project editor target
# (what Unreal does when it compiles the project's C++), to check an engine plugin does not break it.
# Unreal must be closed. Report: tests\check-build.log. Last line: BUILD OK / BUILD FAIL <reason>.
param([string]$Workspace, [string]$Engine = '')
$tool = Split-Path -Parent $PSScriptRoot
$log = Join-Path $PSScriptRoot 'check-build.log'
$proj = @(Get-ChildItem -LiteralPath $Workspace -Filter *.uproject -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $proj.Count) { 'BUILD FAIL no .uproject found'; exit 1 }
if (-not (Test-Path -LiteralPath (Join-Path $proj[0].DirectoryName 'Source'))) { 'BUILD OK (blueprint-only project, nothing to compile)'; exit 0 }
if (-not $Engine) {
    $dat = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
    if (Test-Path -LiteralPath $dat) { $e = @((Get-Content -LiteralPath $dat -Raw | ConvertFrom-Json).InstallationList | Where-Object { $_.AppName -like 'UE_5*' } | Sort-Object AppName -Descending | Select-Object -First 1); if ($e.Count) { $Engine = $e[0].InstallLocation } }
}
$bat = Join-Path $Engine 'Engine\Build\BatchFiles\Build.bat'
if (-not (Test-Path -LiteralPath $bat)) { 'BUILD FAIL engine not found (give it: check-build.ps1 <workspace> <engine>)'; exit 1 }
$target = [System.IO.Path]::GetFileNameWithoutExtension($proj[0].Name) + 'Editor'
$out = @(& cmd /c ('"' + $bat + '" ' + $target + ' Win64 Development -Project="' + $proj[0].FullName + '" -WaitMutex 2>&1') | ForEach-Object { [string]$_ })
$code = $LASTEXITCODE
Set-Content -LiteralPath $log -Value $out -Encoding UTF8
$err = @($out | Where-Object { $_ -match 'RulesError|error [A-Z]+\d+|: error|Expecting to find a type' } | Select-Object -First 3)
if ($code -eq 0) { 'BUILD OK ' + $target } else { 'BUILD FAIL exit ' + $code + ': ' + ($err -join ' | ') ; exit 1 }
