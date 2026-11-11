# tests/screenshot.ps1 - README screenshot: builds a fake offline workspace "MyGame" (no Diversion call,
# nothing personal), opens dvcl on it, saves docs\screenshot.png. Your settings and repos are not touched.
param([string]$Base = (Join-Path $env:PUBLIC 'dvcl-demo'))
$ErrorActionPreference = 'Stop'
$tool = Split-Path -Parent $PSScriptRoot
. (Join-Path $tool 'src\DvclCore.ps1')
$root = Join-Path $Base 'MyGame'
if (Test-Path -LiteralPath $Base) { Remove-Item -LiteralPath $Base -Recurse -Force }
function MkF([string]$rel, [string]$txt) { $f = Full-Path $rel; [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($f)); [System.IO.File]::WriteAllText($f, $txt) }
[void][System.IO.Directory]::CreateDirectory((Join-Path $root '.diversion'))
Set-DvRoot $root
MkF '.dvignore' "Saved/*`nIntermediate/*`nDerivedDataCache/*`nBinaries/*`n"
foreach ($f in 'MyGame/MyGame.uproject', 'MyGame/Config/DefaultEngine.ini', 'MyGame/Content/Maps/Town/Town.umap',
    'MyGame/Content/Maps/Town/Geometry/SM_Town_Pack_01.uasset', 'MyGame/Content/Maps/Town/Geometry/SRC_Town_Pack_01.uasset',
    'MyGame/Content/Props/Bench/SM_Bench.uasset', 'MyGame/Content/Props/Lamp/SM_Lamp.uasset', 'MyGame/Content/Old/SM_Fence_Old.uasset',
    'MyGame/Content/__ExternalActors__/Maps/Town/4/BQ/7FQ2M0XK1C9RTB4LZ8WYEH.uasset') { MkF $f 'v1' }
$snap = Scan-Workspace
$paths = [string[]]@($snap.Keys | ForEach-Object { if ($snap[$_] -eq 'D') { $_ + '/' } else { $_ } })
[Array]::Sort($paths, [StringComparer]::Ordinal)
Write-Baseline @() 'dv.commit.12'
Save-LastHead 'main' 'dv.commit.12'
Save-DepotCache 'dv.commit.12' $paths
Set-OfflineFlag $true
Start-Sleep -Milliseconds 1200
foreach ($f in 'MyGame/Content/Maps/Town/Town.umap', 'MyGame/Content/Maps/Town/Geometry/SM_Town_Pack_01.uasset', 'MyGame/Content/Maps/Town/Geometry/SRC_Town_Pack_01.uasset', 'MyGame/Content/__ExternalActors__/Maps/Town/4/BQ/7FQ2M0XK1C9RTB4LZ8WYEH.uasset') { MkF $f 'v2 edited' }
foreach ($f in 'MyGame/Content/Props/Crate/SM_Crate.uasset', 'MyGame/Content/Props/Crate/T_Crate_BC.uasset', 'MyGame/Content/Props/Crate/T_Crate_N.uasset') { MkF $f 'new' }
Remove-Item -LiteralPath (Full-Path 'MyGame/Content/Old/SM_Fence_Old.uasset')
$pend = Get-OfflinePending
$c = New-CL 'town_blockout' 'town blockout'
Move-ToCL 'town_blockout' @($pend | Where-Object { $_.Path -like '*Town*' -or $_.Path -like '*Fence*' })
$out = Join-Path $tool 'docs\screenshot.png'
& powershell -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $tool 'src\dvcl-gui.ps1') $root -Shot $out
Remove-Item -LiteralPath $Base -Recurse -Force
Write-Host ('screenshot: ' + $out)
