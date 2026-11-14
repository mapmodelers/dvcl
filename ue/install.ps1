# ue\install.ps1 [<engine folder>] - builds the dvcl link plugin for your Unreal and installs it in
# the engine (Engine\Plugins\DvclLink), on by default, so it loads in every project without touching
# them. Restart Unreal once afterwards. Report: ue\install.log
param([string]$Engine = '')
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'install.log'
Set-Content -LiteralPath $log -Value ('dvcl link install ' + (Get-Date -Format s)) -Encoding UTF8
function Note([string]$t) { Add-Content -LiteralPath $log -Value $t -Encoding UTF8; Write-Output $t }

# Packaging drops EnabledByDefault and marks the plugin Installed (= off until enabled per project):
# an engine plugin on by default instead
function Set-PluginOn([string]$file) {
    $j = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    $j | Add-Member -NotePropertyName EnabledByDefault -NotePropertyValue $true -Force
    $j | Add-Member -NotePropertyName Installed -NotePropertyValue $false -Force
    Set-Content -LiteralPath $file -Value ($j | ConvertTo-Json -Depth 6) -Encoding UTF8
}

# the engine: given, else the running editor's, else the registry's / launcher's newest 5.x
if (-not $Engine) {
    $ed = @(Get-Process UnrealEditor -ErrorAction SilentlyContinue | Where-Object { $_.Path })
    if ($ed.Count) { $Engine = Split-Path (Split-Path (Split-Path (Split-Path $ed[0].Path))) }
}
if (-not $Engine) {
    $k = @(Get-ChildItem 'HKLM:\SOFTWARE\EpicGames\Unreal Engine' -ErrorAction SilentlyContinue | Sort-Object PSChildName -Descending)
    foreach ($x in $k) { $d = (Get-ItemProperty $x.PSPath -ErrorAction SilentlyContinue).InstalledDirectory; if ($d) { $Engine = $d; break } }
}
# else the Epic launcher's list of installed engines (newest 5.x)
if (-not $Engine) {
    $dat = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
    if (Test-Path -LiteralPath $dat) {
        $ue = @((Get-Content -LiteralPath $dat -Raw | ConvertFrom-Json).InstallationList | Where-Object { $_.AppName -like 'UE_5*' } | Sort-Object AppName -Descending)
        foreach ($x in $ue) { if (Test-Path (Join-Path $x.InstallLocation 'Engine\Build\BatchFiles\RunUAT.bat')) { $Engine = $x.InstallLocation; break } }
    }
}
if (-not $Engine -or -not (Test-Path (Join-Path $Engine 'Engine\Build\BatchFiles\RunUAT.bat'))) { Note ('FAIL no Unreal engine found (give its folder: install.ps1 "D:\...\UE_5.8")'); exit 1 }
Note ('engine: ' + $Engine)

$plugin = Join-Path $PSScriptRoot 'DvclLink\DvclLink.uplugin'
$out = Join-Path $env:TEMP 'dvcl-link-build'
if (Test-Path $out) { Remove-Item -LiteralPath $out -Recurse -Force }
$uat = Join-Path $Engine 'Engine\Build\BatchFiles\RunUAT.bat'
Note 'building (a few minutes)...'
$b = @(& cmd /c ('"' + $uat + '" BuildPlugin -Plugin="' + $plugin + '" -Package="' + $out + '" -TargetPlatforms=Win64 2>&1') | ForEach-Object { [string]$_ })
Add-Content -LiteralPath $log -Value $b -Encoding UTF8
if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $out 'Binaries\Win64'))) {
    Note ('FAIL build (exit ' + $LASTEXITCODE + '): ' + ((@($b | Where-Object { $_ -match 'error|Error|ERROR' }) | Select-Object -First 12) -join ' | '))
    exit 1
}
$dst = Join-Path $Engine 'Engine\Plugins\DvclLink'
foreach ($old in @($dst, (Join-Path $Engine 'Engine\Plugins\Marketplace\DvclLink'))) {
    if (Test-Path $old) {
        try { Remove-Item -LiteralPath $old -Recurse -Force } catch { Note ('FAIL the installed dvcl link is in use: close Unreal, run this again (' + $_.Exception.Message + ')'); exit 1 }
    }
}
Copy-Item -LiteralPath $out -Destination $dst -Recurse -Force
Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
Set-PluginOn (Join-Path $dst 'DvclLink.uplugin')
Note ('OK installed: ' + $dst + '   Restart Unreal once to load it.')
