# tests\diag-link.ps1 <workspace> - why the open editor does not see the dvcl link (read-only).
# Report: tests\diag-link.log. Last line: summary.
param([string]$Workspace)
$tool = Split-Path -Parent $PSScriptRoot
. (Join-Path $tool 'src\DvclCore.ps1')
Set-DvRoot (Find-DvRoot $Workspace)
$o = New-Object System.Collections.ArrayList
$ed = @(Get-Process UnrealEditor -ErrorAction SilentlyContinue | Where-Object { $_.Path })
foreach ($e in $ed) { [void]$o.Add('editor pid ' + $e.Id + ' started ' + $e.StartTime.ToString('s') + ' ' + $e.Path) }
$eng = Find-UeEngine
$pd = Join-Path $eng 'Engine\Plugins\Marketplace\DvclLink'
[void]$o.Add('installed: ' + (Test-Path $pd) + ' | dll: ' + ((Get-ChildItem -LiteralPath (Join-Path $pd 'Binaries\Win64') -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + ' ' + $_.LastWriteTime.ToString('s') }) -join ', '))
$up = Join-Path $pd 'DvclLink.uplugin'
if (Test-Path $up) { [void]$o.Add('uplugin: ' + ((Get-Content -LiteralPath $up -Raw) -replace '\s+', ' ')) }
# the project file: plugin entries, engine plugins off by default?
$proj = @(Get-ChildItem -LiteralPath $script:Root -Filter *.uproject -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($proj.Count) {
    $j = Get-Content -LiteralPath $proj[0].FullName -Raw | ConvertFrom-Json
    [void]$o.Add('uproject ' + $proj[0].Name + ': DisableEnginePluginsByDefault=' + $j.DisableEnginePluginsByDefault + ' | plugins: ' + ((@($j.Plugins) | ForEach-Object { $_.Name + '=' + $_.Enabled }) -join ', '))
    $logd = Join-Path $proj[0].DirectoryName 'Saved\Logs'
    $lf = @(Get-ChildItem -LiteralPath $logd -Filter *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($lf.Count) { foreach ($l in @(Select-String -LiteralPath $lf[0].FullName -Pattern 'DvclLink|dvcl link' | Select-Object -First 12)) { [void]$o.Add('log | ' + $l.Line.Trim()) } }
}
$py = @"
import unreal
print('has DvclLinkLibrary %s' % hasattr(unreal, 'DvclLinkLibrary'))
try:
    names = unreal.PluginBlueprintLibrary.get_enabled_plugin_names()
    print('enabled DvclLink %s (of %d)' % ('DvclLink' in names, len(names)))
except Exception as e:
    print('plugins ? %s' % e)
try:
    c = unreal.load_class(None, '/Script/DvclLink.DvclLinkLibrary')
    print('class %s' % c)
except Exception as e:
    print('class ? %s' % e)
"@
$r = Invoke-Ue $py
foreach ($l in $r.Lines) { [void]$o.Add('ue | ' + $l) }
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'diag-link.log') -Value $o -Encoding UTF8
($o | Where-Object { $_ -notlike 'uplugin*' }) -join ' || '
