# tests/probe-offline.ps1 <workspace> <committed text file> [<shelf id to list>]
# What Diversion can do while workspace sync stays PAUSED (no upload of other changes):
# restore one file, create / delete a shelf, show a shelf's files, apply options.
# Touches only <committed text file> (changed, then restored; a backup copy puts it back if needed)
# and one temporary shelf (deleted at the end). Report: tests\probe-offline.log (stays on this PC).
param([string]$Workspace, [string]$File, [string]$ShelfId = '')
$ErrorActionPreference = 'Stop'
$out = New-Object System.Collections.ArrayList
$logf = Join-Path $PSScriptRoot 'probe-offline.log'
Set-Content -LiteralPath $logf -Value ('probe ' + (Get-Date -Format s)) -Encoding UTF8
# written line by line: an interrupted run still shows how far it got
function Note([string]$t) { [void]$out.Add($t); Add-Content -LiteralPath $logf -Value $t -Encoding UTF8 }
# with a time limit: a dv call that waits for sync while paused would hang forever
function DvT([string[]]$a, [int]$sec = 45) {
    $j = Start-Job -ScriptBlock { param($d, $x) Set-Location -LiteralPath $d; & dv @x 2>&1 | ForEach-Object { [string]$_ }; "EXIT $LASTEXITCODE" } -ArgumentList (Get-Location).Path, $a
    if (-not (Wait-Job $j -Timeout $sec)) { Stop-Job $j; Note ('$ dv ' + ($a -join ' ') + '   [TIMEOUT ' + $sec + 's: waits for sync]'); Remove-Job $j -Force; return @() }
    $o = @(Receive-Job $j); Remove-Job $j -Force
    Note ('$ dv ' + ($a -join ' ') + '   [' + ($o | Select-Object -Last 1) + ']')
    foreach ($l in ($o | Select-Object -First 40)) { Note ('  | ' + $l) }
    return $o
}
function Paused { $s = @(DvT @('status', '--nowait') 30); return [bool]($s -match 'paused') }
Set-Location -LiteralPath $Workspace
$full = Join-Path $Workspace $File
$bak = $full + '.dvclprobe.bak'
# an earlier run was stopped half way: put the file back first
if (Test-Path -LiteralPath $bak) { Copy-Item -LiteralPath $bak -Destination $full -Force; Note 'earlier interrupted run: file put back from its backup' }
Copy-Item -LiteralPath $full -Destination $bak -Force
$orig = (Get-FileHash -LiteralPath $full).Hash
try {
    Note ('paused at start: ' + (Paused))
    [void](DvT @('help', 'shelf') 20); [void](DvT @('help', 'restore') 20)
    if ($ShelfId) { [void](DvT @('shelf', 'show', $ShelfId) 30) }
    # 1. restore while paused
    Add-Content -LiteralPath $full -Value 'dvcl probe line'
    [void](DvT @('restore', $File))
    Start-Sleep -Seconds 2
    Note ('RESULT restore while paused: content back=' + ((Get-FileHash -LiteralPath $full).Hash -eq $orig) + ' still paused=' + (Paused))
    # 2. shelf create / delete while paused
    Add-Content -LiteralPath $full -Value 'dvcl probe line'
    $name = 'dvcl_probe_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $c = DvT @('shelf', 'create', $name, $File, '--no-reset')
    $id = ''; foreach ($l in $c) { if ($l -match '(dv\.shelf\.[0-9a-f-]+)') { $id = $Matches[1] } }
    Note ('RESULT shelf create while paused: id=' + $id + ' still paused=' + (Paused))
    if ($id) {
        [void](DvT @('shelf', 'show', $id) 30)
        Copy-Item -LiteralPath $bak -Destination $full -Force
        [void](DvT @('shelf', 'apply', $id, '--keep', '-f'))
        Start-Sleep -Seconds 2
        Note ('RESULT shelf apply while paused: probe line back=' + ([bool](Select-String -LiteralPath $full -SimpleMatch 'dvcl probe line' -Quiet)) + ' still paused=' + (Paused))
        [void](DvT @('shelf', 'delete', $id) 30)
    }
} finally {
    Copy-Item -LiteralPath $bak -Destination $full -Force
    Remove-Item -LiteralPath $bak -Force
    Note ('file put back: ' + ((Get-FileHash -LiteralPath $full).Hash -eq $orig) + '   paused at end: ' + (Paused))
}
($out | Where-Object { $_ -like 'RESULT*' -or $_ -like 'paused*' -or $_ -like 'file put back*' }) -join ' || '
