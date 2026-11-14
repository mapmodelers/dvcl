# tests\check-link.ps1 <workspace> <file> - the dvcl link round trip on one asset, without changing it:
# open editor found, plugin answers, file held before, released (not held), reloaded (held again).
# Last line: summary. Changes no file.
param([string]$Workspace, [string]$File)
$tool = Split-Path -Parent $PSScriptRoot
. (Join-Path $tool 'src\DvclCore.ps1')
Set-DvRoot (Find-DvRoot $Workspace)
$v = Invoke-Ue "import unreal`nprint(unreal.DvclLinkLibrary.version() if hasattr(unreal, 'DvclLinkLibrary') else 'DVCL nolink')"
$out = @('link: ' + $v.State + ' ' + (($v.Lines | Where-Object { $_ -notlike 'RESULT*' }) -join ' / '))
$before = Test-Locked $File
$r = Ue-Release @($File)
$after = Test-Locked $File
Ue-Reload @($File)
Start-Sleep -Milliseconds 500
$out += ('held before: ' + $before + ' | release: ' + $r.State + ' released=' + $r.Released.Count + ' unsaved=' + $r.Unsaved.Count + ' | held after release: ' + $after + ' | held after reload: ' + (Test-Locked $File))
$out -join ' || '
