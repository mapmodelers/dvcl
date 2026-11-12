# tests/check-dv.ps1 <workspace> - checks dvcl's reading of real Diversion data (read-only):
# every commit of dv log parsed (id, author, date, description), dates readable, numbers in order,
# and for recent commits every changed-file line of dv show parsed, plus dv log <path> finding them.
# Report: tests\dv-check.log (gitignored, stays on this PC). Last line: summary.
param([string]$Workspace = (Get-Location).Path)
$ErrorActionPreference = 'Stop'
$tool = Split-Path -Parent $PSScriptRoot
. (Join-Path $tool 'src\DvclCore.ps1')
$root = Find-DvRoot $Workspace
if (-not $root) { throw ('not a Diversion workspace: ' + $Workspace) }
Set-DvRoot $root
$out = New-Object System.Collections.ArrayList
$bad = 0
function Note([string]$t) { [void]$out.Add($t) }
function Bad([string]$t) { $script:bad++; [void]$out.Add('BAD   ' + $t) }

$r = Invoke-Dv @('log', '-n', '1000', '--date', 'iso') $true
if ($r.Code -ne 0) { Bad ('dv log failed: ' + ($r.Lines -join ' | ')) }
$heads = @($r.Lines | Where-Object { $_ -match '^\s*commit\s+dv\.commit\.\d+' }).Count
$cs = @(Parse-Log $r.Lines)
Note ('log: ' + $r.Lines.Count + ' lines, ' + $heads + ' commit headers, ' + $cs.Count + ' parsed')
if ($cs.Count -ne $heads -or $cs.Count -eq 0) { Bad 'log: parsed count differs from commit headers' }
$prev = [int]::MaxValue
foreach ($c in $cs) {
    if (-not $c.Author) { Bad ($c.Id + ': no author') }
    if (-not $c.Desc) { Bad ($c.Id + ': no description') }
    $d = Format-CommitDate $c.Date
    if ($d -notmatch '^\d{4}-\d\d-\d\d \d\d:\d\d$') { Bad ($c.Id + ': date not readable: ' + $c.Date) }
    if ($c.Num -ge $prev) { Bad ($c.Id + ': not newest first') }
    $prev = $c.Num
}
$other = @($r.Lines | Where-Object { $_ -match '^\s*[A-Za-z]+\s*:' -and $_ -notmatch '^\s*(Author|Date)\s*:' } | Select-Object -First 5)
foreach ($l in $other) { Note ('log: other field line: ' + $l.Trim()) }
$multi = @($cs | Where-Object { $_.Desc -match "`n" }).Count
Note ('log: authors ' + ((@($cs | ForEach-Object { $_.Author }) | Sort-Object -Unique).Count) + ', multi-line descriptions ' + $multi + ', range ' + $(if ($cs.Count) { $cs[-1].Id + ' .. ' + $cs[0].Id } else { '-' }))

$kinds = @{}
$checked = 0
foreach ($c in @($cs | Select-Object -First 15)) {
    $s = Invoke-Dv @('show', $c.Id, '--name-status', '--color', 'never') $true
    if ($s.Code -ne 0) { Bad ($c.Id + ': dv show failed'); continue }
    $raw = @($s.Lines | Where-Object { $_ -match '^[A-Z]\d*\t' }).Count
    $fs = @(Parse-ShowFiles $s.Lines)
    if ($fs.Count -ne $raw) { Bad ($c.Id + ': ' + $raw + ' file lines, ' + $fs.Count + ' parsed') }
    foreach ($f in $fs) { $kinds[$f.Kind] = 1 + [int]$kinds[$f.Kind] }
    foreach ($l in @($s.Lines | Where-Object { $_ -match '^R\d*\t' } | Select-Object -First 2)) { Note ('show: rename line format: ' + ($l -replace '[^\t]+', 'x')) }
    # history of one changed file finds this commit
    if ($checked -lt 3 -and $fs.Count) {
        $p = ($fs | Where-Object { $_.Kind -ne 'D' } | Select-Object -First 1).Path
        if ($p) {
            $h = Invoke-Dv @('log', $p, '-n', '50', '--date', 'iso') $true
            $hc = @(Parse-Log $h.Lines)
            if (-not ($hc | Where-Object { $_.Id -eq $c.Id })) { Bad ($c.Id + ': history of one of its files does not list it') } else { $checked++ }
        }
    }
}
Note ('show: kinds ' + ((@($kinds.Keys | Sort-Object) | ForEach-Object { $_ + '=' + $kinds[$_] }) -join ' ') + '; file histories checked ' + $checked)
$sum = 'DV CHECK ' + (Get-Date -Format s) + ': ' + $cs.Count + ' commits, ' + $bad + ' problem(s)'
[void]$out.Add($sum)
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'dv-check.log') -Value $out -Encoding UTF8
$sum
