# tests\check-ignore.ps1 <workspace> - read-only: does dvcl's folder scan (offline mode) see the same
# files as Diversion? Compares the scan with Diversion's last pending list (.dvcl\last-status.tsv)
# and with the files Diversion has committed (dv ls, works offline). Changes nothing.
# Report: tests\check-ignore.log (gitignored, stays on this PC). Last line: summary.
param([string]$Workspace = (Get-Location).Path)
$ErrorActionPreference = 'Stop'
$tool = Split-Path -Parent $PSScriptRoot
. (Join-Path $tool 'src\DvclCore.ps1')
$root = Find-DvRoot $Workspace
if (-not $root) { throw ('not a Diversion workspace: ' + $Workspace) }
Set-DvRoot $root
$out = New-Object System.Collections.ArrayList
function Note([string]$t) { [void]$out.Add($t) }

# "!" rules in the ignore files (dvcl before 0.27 skipped them)
foreach ($f in @(Get-ChildItem -Path $root -Recurse -Depth 2 -Force -File -Include '.dvignore', '.gitignore' -ErrorAction SilentlyContinue)) {
    $neg = @(Get-Content -LiteralPath $f.FullName | Where-Object { $_.Trim().StartsWith('!') })
    Note ('ignore file ' + $f.FullName.Substring($root.Length).TrimStart('\') + ': ' + $neg.Count + ' "!" rule(s) ' + ($neg -join '  '))
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$scan = Scan-Workspace
Note ('scan: ' + $scan.Count + ' entries in ' + $sw.ElapsedMilliseconds + ' ms (native ' + [bool](Ensure-Scanner) + ')')

# 1. files Diversion listed as pending (last time online) that the scan hides
$known = Read-LastStatus
$hidden = @($known | Where-Object { (Kind-Letter $_.Kind) -ne 'D' -and -not $scan.ContainsKey($_.Path) -and [System.IO.File]::Exists((Full-Path $_.Path)) } | ForEach-Object { $_.Path })
Note ('Diversion pending list: ' + $known.Count + ' file(s); hidden by the scan: ' + $hidden.Count)
$hidden | Select-Object -First 15 | ForEach-Object { Note ('  hidden pending: ' + $_) }

# 2. committed files on disk that the scan hides (their offline edits would be missed)
$r = Invoke-Dv @('ls') $true
$depot = @()
if ($r.Code -eq 0) { $all = Parse-DepotLines $r.Lines; $depot = @($all | Where-Object { -not $_.EndsWith('/') }) }
Note ('dv ls: exit ' + $r.Code + ', ' + $depot.Count + ' committed file(s)')
$miss = @($depot | Where-Object { -not $scan.ContainsKey($_) -and [System.IO.File]::Exists((Full-Path $_)) })
Note ('committed files on disk hidden by the scan: ' + $miss.Count)
$miss | Select-Object -First 15 | ForEach-Object { Note ('  hidden committed: ' + $_) }

# 3. files the scan sees that Diversion neither has committed nor lists as pending (Diversion ignores them?)
$set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $depot) { [void]$set.Add($p) }
foreach ($p in $known) { [void]$set.Add($p.Path) }
$extra = @($scan.Keys | Where-Object { $scan[$_] -ne 'D' -and -not $set.Contains($_) })
Note ('scanned files Diversion does not know (new since, or ignored by Diversion): ' + $extra.Count)
$extra | Sort-Object | Select-Object -First 25 | ForEach-Object { Note ('  extra: ' + $_) }

$sum = 'check-ignore: hidden pending ' + $hidden.Count + ', hidden committed ' + $miss.Count + ', extra ' + $extra.Count + ' (scan ' + $scan.Count + ', depot ' + $depot.Count + ', pending ' + $known.Count + ')'
Note $sum
[System.IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'check-ignore.log'), [string[]]$out.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
$sum
