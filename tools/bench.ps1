# Where dvcl spends its time on a real workspace (read-only): bench.ps1 <workspace> <out file>
param([string]$Ws, [string]$Out)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\DvclCore.ps1')
$L = New-Object System.Collections.Generic.List[string]
function B([string]$what, [scriptblock]$sb) { $sw = [Diagnostics.Stopwatch]::StartNew(); $r = & $sb; $L.Add(('{0,7} ms  {1}' -f [int]$sw.Elapsed.TotalMilliseconds, $what)); return $r }
Set-DvRoot $Ws
B 'Ensure-Scanner (load dll)' { [void](Ensure-Scanner) } | Out-Null
$known = B 'Read-LastStatus' { Read-LastStatus }
$base = B 'Read-Baseline' { Read-Baseline }
$now = B 'Scan-Workspace #1' { Scan-Workspace }
$L.Add('         scanner: ' + [DvclNative.Scanner]::Stats)
$now = B 'Scan-Workspace #2' { Scan-Workspace }
$L.Add('         scanner: ' + [DvclNative.Scanner]::Stats)
B 'Load-Db' { Load-Db } | Out-Null
$nf = 0; foreach ($c in $script:CLs) { $nf += $c.files.Count }
$L.Add('         ' + @($script:CLs).Count + ' changelists, ' + $nf + ' changelist entries, ' + @($known).Count + ' last-status, ' + $(if ($base) { $base.Count } else { 0 }) + ' baseline')
$pend = @($known)
B 'Get-CLItems all changelists' { foreach ($n in @('default') + @($script:CLs | ForEach-Object { $_.name })) { [void](Get-CLItems $pend $n) } } | Out-Null
B 'Kind-Letter x pending' { foreach ($p in $pend) { [void](Kind-Letter $p.Kind) } } | Out-Null
B 'Split-Ofpa pending' { [void](Split-Ofpa $pend) } | Out-Null
B 'gone check (baseline keys)' { [void]@($base.Keys | Where-Object { -not $now.ContainsKey($_) }) } | Out-Null
$L.Add('         workspace name saved: [' + (Ws-Name) + ']')
$br = B 'Branch-Rows' { @(Branch-Rows) }
$L.Add('         branch rows: ' + ((@($br) | ForEach-Object { [string]$_.Name + ' = [' + [string]$_.Workspaces + ']' }) -join ' | '))
$bj = B 'dvcl-branches.ps1 (window background job)' { & (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\dvcl-branches.ps1') -Workspace $Ws -Branch (Current-Branch) }
$L.Add('         background job: ' + @($bj.Rows).Count + ' rows, graph rows ' + @($bj.Graph.Rows).Count + ', error [' + [string]$bj.Error + ']')
[System.IO.File]::WriteAllLines($Out, [string[]]$L)
