# tests/integration.ps1 - end-to-end test of dvcl (CLI + engine) against a SCRATCH Diversion repo.
# Never touches your real repos: everything happens in -Repo (default %USERPROFILE%\dvcl-test),
# created on first run with `dv init` (one extra repo on your Diversion account; delete it when done).
# Each run works in its own folder run_<time>. Report: tests\last-report.txt (+ clipboard).
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\integration.ps1

param([string]$Repo = (Join-Path $env:USERPROFILE 'dvcl-test'))

$ErrorActionPreference = 'Continue'
$Tool   = Split-Path -Parent $PSScriptRoot
$Cli    = Join-Path $Tool 'src\dvcl-cli.ps1'
$Report = Join-Path $PSScriptRoot 'last-report.txt'
$Noise  = '\{\{spinner\}\}|^Sync in progress|^Queued filesystem|^Inbound changes|^Outbound changes|^Currently syncing|blob transfers|^Downloading |^Uploading |^Recently synced'
$script:lines = New-Object System.Collections.ArrayList
$script:pass = 0; $script:fail = 0

function Out-R([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c; [void]$script:lines.Add($t) }

function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++; Out-R ("PASS  " + $name) 'Green' }
    else { $script:fail++; Out-R ("FAIL  " + $name + "   " + $detail) 'Red' }
}

function Run-In-Repo([string]$label, [scriptblock]$sb) {
    $where = $Repo; if (-not (Test-Path -LiteralPath $where)) { $where = $Tool }
    Push-Location -LiteralPath $where
    try { $o = @(& $sb 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch $Noise }); $code = $LASTEXITCODE }
    finally { Pop-Location }
    Out-R ("  > " + $label + "   (exit " + $code + ")") 'DarkGray'
    foreach ($l in $o) { if ($l.Trim()) { Out-R ("      " + $l) 'DarkGray' } }
    return [pscustomobject]@{ Code = $code; Text = ($o -join "`n") }
}

function Dvcl {
    $a = @($args)
    return Run-In-Repo ("dvcl " + ($a -join ' ')) { & powershell -NoProfile -ExecutionPolicy Bypass -File $Cli @a }
}

function DvX {
    $a = @($args)
    return Run-In-Repo ("dv " + ($a -join ' ')) { & dv.exe @a }
}

function Pending-Paths {
    $r = DvX status --no-limit
    $set = @{}
    foreach ($l in ($r.Text -split "`n")) { if ($l -match '^\s+(\S.*)$') { $set[$Matches[1].Trim()] = 1 } }
    return $set
}

# The Diversion agent picks up file-system changes asynchronously: poll dv status until
# every expected path shows up (or timeout). Returns the pending set.
function Wait-Pending([string[]]$expect, [int]$timeoutSec = 45) {
    $t0 = Get-Date
    while ($true) {
        $set = Pending-Paths
        $missing = @($expect | Where-Object { -not $set.ContainsKey($_) })
        if ($missing.Count -eq 0) { Out-R ("  (agent saw all " + $expect.Count + " changes after " + [int]((Get-Date) - $t0).TotalSeconds + "s)") 'DarkGray'; return $set }
        if (((Get-Date) - $t0).TotalSeconds -gt $timeoutSec) { Out-R ("  (timeout, still missing: " + ($missing -join ', ') + ")") 'Yellow'; return $set }
        Start-Sleep -Seconds 3
    }
}

function Store {
    $f = Join-Path $Repo '.dvcl\changelists.json'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    return @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).changelists)
}

function Finish {
    Out-R ""
    Out-R ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
    ($script:lines -join "`r`n") | Set-Content -LiteralPath $Report -Encoding UTF8
    try { ($script:lines -join "`r`n") | Set-Clipboard } catch {}
    Out-R ("Report: " + $Report + " (also on the clipboard)")
    exit $script:fail
}

Out-R ("dvcl integration test   " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "   repo " + $Repo + "   tool " + $Tool)
Out-R ("dv: " + ((& dv.exe --version) 2>&1 | Out-String).Trim() + "   PowerShell " + $PSVersionTable.PSVersion)

# ---------------------------------------------------------------- 0. unit tests + launcher
$r = Run-In-Repo 'cmd /c dvcl.cmd help' { cmd /c ('"' + (Join-Path $Tool 'dvcl.cmd') + '" help') }
Check "launcher dvcl.cmd runs (execution policy bypassed)" ($r.Text -match 'dvcl - changelists for Diversion')

# ---------------------------------------------------------------- 1. scratch repo
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.diversion'))) {
    New-Item -ItemType Directory -Force -Path $Repo | Out-Null
    Set-Content -LiteralPath (Join-Path $Repo '.dvignore') -Value "/.dvcl/" -Encoding ASCII
    $o = (& dv.exe init $Repo 'dvcl-test' -f 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch $Noise }) -join "`n"
    Out-R ("  > dv init " + $Repo + " dvcl-test -f`n      " + $o) 'DarkGray'
    Check "dv init scratch repo" (Test-Path -LiteralPath (Join-Path $Repo '.diversion'))
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.diversion'))) { Finish }
    [void](DvX commit -a -m "dvcl-test: ignore .dvcl")
}

$r = Dvcl selftest
Check "unit selftest (offline)" ($r.Code -eq 0 -and $r.Text -match ' 0 failed')

# fresh changelist store for each run (scratch repo only)
$storeFile = Join-Path $Repo '.dvcl\changelists.json'
if (Test-Path -LiteralPath $storeFile) { Remove-Item -LiteralPath $storeFile -Force }

$run = 'run_' + (Get-Date -Format 'yyyyMMdd_HHmmss')
$RunDir = Join-Path $Repo $run
New-Item -ItemType Directory -Force -Path (Join-Path $RunDir 'sub') | Out-Null
'base a' | Set-Content -LiteralPath (Join-Path $RunDir 'a.txt')
'base b' | Set-Content -LiteralPath (Join-Path $RunDir 'b.txt')
'base c' | Set-Content -LiteralPath (Join-Path $RunDir 'sub\c.txt')
'base d' | Set-Content -LiteralPath (Join-Path $RunDir 'del.txt')
$r = DvX commit -a -m ("dvcl-test baseline " + $run)
Check "baseline commit" ($r.Code -eq 0) $r.Text

# ---------------------------------------------------------------- 2. local changes
# Let the agent settle after the commit (it may still rewrite files from the new commit)
Start-Sleep -Seconds 10
[void](DvX status --no-limit)
'changed a' | Set-Content -LiteralPath (Join-Path $RunDir 'a.txt')
'changed b' | Set-Content -LiteralPath (Join-Path $RunDir 'b.txt')
'changed c' | Set-Content -LiteralPath (Join-Path $RunDir 'sub\c.txt')
Remove-Item -LiteralPath (Join-Path $RunDir 'del.txt')
'new 1' | Set-Content -LiteralPath (Join-Path $RunDir 'n1.txt')
'new 2' | Set-Content -LiteralPath (Join-Path $RunDir 'n2.txt')
function Disk-State { Out-R ("  disk: a=" + ((Get-Content -LiteralPath (Join-Path $RunDir 'a.txt') -EA SilentlyContinue) -join '') + " | del exists=" + (Test-Path -LiteralPath (Join-Path $RunDir 'del.txt')) + " | n1 exists=" + (Test-Path -LiteralPath (Join-Path $RunDir 'n1.txt'))) 'DarkGray' }
Disk-State
$six = @('a.txt', 'b.txt', 'sub/c.txt', 'del.txt', 'n1.txt', 'n2.txt')
$p = Wait-Pending @($six | ForEach-Object { "$run/$_" })
Disk-State
foreach ($f in $six) { Check ("pending: " + $f) ($p.ContainsKey("$run/$f")) }
if (@($six | Where-Object { -not $p.ContainsKey("$run/$_") }).Count -gt 0) { Out-R "Diversion did not report the test changes: stopping here (the rest would only cascade)." 'Yellow'; Finish }

$r = Dvcl
Check "list shows default with the 6 run files" ((([regex]::Matches($r.Text, [regex]::Escape($run + '/'))).Count -ge 6) -and $r.Text -match '== default')

# ---------------------------------------------------------------- 3. changelists
$r = Dvcl new t1 "Test one"
Check "new t1" ($r.Code -eq 0 -and $r.Text -match "Created changelist 't1'")
$r = Dvcl new "spaced name" "Spaced"
Check "new with spaces -> slug spaced_name" ($r.Code -eq 0 -and $r.Text -match "spaced_name")
$r = Dvcl new t1 "dup"
Check "duplicate name refused" ($r.Code -ne 0)
$r = Dvcl add t1 "$run/a.txt" "$run/n1.txt"
Check "add 2 files by path" ($r.Text -match "Moved 2 file")
$r = Dvcl add t2 "$run/sub"
Check "add folder (auto-creates t2)" ($r.Text -match "Moved 1 file")
$r = Dvcl add t3 "$run/n2*"
Check "add wildcard" ($r.Text -match "Moved 1 file")
$r = Dvcl add t3 "$run/nothing_here"
Check "add with no match warns" ($r.Text -match "no pending file matches")
$r = Dvcl
Check "list groups t1/t2/t3" ($r.Text -match '== t1' -and $r.Text -match '== t2' -and $r.Text -match '== t3')
$s = Store
Check "store: t1 has 2 files" (@(@($s | Where-Object { $_.name -eq 't1' })[0].files).Count -eq 2)
$r = Dvcl desc t1 "Test one, edited"
$s = Store
Check "desc edit saved" ((@($s | Where-Object { $_.name -eq 't1' })[0].desc) -eq 'Test one, edited')

# ---------------------------------------------------------------- 4. shelve
$r = Dvcl shelve t1
$shelf1 = $null; if ($r.Text -match "as '([^']+)'") { $shelf1 = $Matches[1] }
Check "shelve t1" ($r.Code -eq 0 -and $shelf1) $r.Text
$p = Pending-Paths
Check "shelve keeps workspace changes" ($p.ContainsKey("$run/a.txt") -and $p.ContainsKey("$run/n1.txt"))
$r = Dvcl shelves
Check "shelves lists t1 shelf" ($shelf1 -and $r.Text -match [regex]::Escape($shelf1))

# ---------------------------------------------------------------- 5. revert (+ undo via backup shelf)
$r = Dvcl revert t2 -y
$backup = $null; if ($r.Text -match "unshelve (\S+)") { $backup = $Matches[1] }
Check "revert t2" ($r.Code -eq 0 -and $backup) $r.Text
Check "revert restored baseline content" (((Get-Content -LiteralPath (Join-Path $RunDir 'sub\c.txt')) -join '') -eq 'base c')
Check "revert removed empty t2" (-not (@(Store | Where-Object { $_.name -eq 't2' }).Count))
$r = Dvcl unshelve $backup
Check "unshelve command ok" ($r.Code -eq 0) $r.Text
# dv shelf apply returns before the agent has rewritten the files: wait for it
[void](Wait-Pending @("$run/sub/c.txt"))
Check "unshelve backup restores the change" ((((Get-Content -LiteralPath (Join-Path $RunDir 'sub\c.txt')) -join '') -eq 'changed c'))

# ---------------------------------------------------------------- 6. submit
$r = Dvcl submit t1 -y
Check "submit t1" ($r.Code -eq 0 -and $r.Text -match 'Submitted') $r.Text
$p = Pending-Paths
Check "submitted files no longer pending" (-not $p.ContainsKey("$run/a.txt") -and -not $p.ContainsKey("$run/n1.txt"))
Check "other files still pending" ($p.ContainsKey("$run/b.txt") -and $p.ContainsKey("$run/n2.txt") -and $p.ContainsKey("$run/sub/c.txt"))
Check "t1 closed after submit" (-not (@(Store | Where-Object { $_.name -eq 't1' }).Count))
$r = Dvcl submit t3
Check "submit refused without description" ($r.Code -ne 0 -and $r.Text -match 'no description')

# ---------------------------------------------------------------- 7. remove / delete / default submit
$r = Dvcl remove "$run/n2.txt"
Check "remove back to default" ($r.Text -match "Moved 1 file\(s\) to 'default'")
$r = Dvcl delete t3
Check "delete t3" ($r.Code -eq 0)
$r = Dvcl delete spaced_name
Check "delete spaced_name" ($r.Code -eq 0)
$r = Dvcl submit default ("dvcl-test rest " + $run) -y
Check "submit default" ($r.Code -eq 0 -and $r.Text -match 'Submitted') $r.Text
$p = Pending-Paths
Check "run folder fully committed" (-not @($p.Keys | Where-Object { $_ -like "$run/*" }).Count) (($p.Keys | Where-Object { $_ -like "$run/*" }) -join ', ')
Check "store empty at the end" (@(Store).Count -eq 0)

# ---------------------------------------------------------------- 8. cleanup test shelves
foreach ($sh in @($shelf1, $backup)) { if ($sh) { [void](DvX shelf delete $sh -f) } }
$r = Dvcl shelves
Check "test shelves deleted" (-not ($shelf1 -and $r.Text -match [regex]::Escape($shelf1)) -and -not ($backup -and $r.Text -match [regex]::Escape($backup)))

Finish
