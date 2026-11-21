# tools\watch-actions.ps1 - the actions the dvcl dev watcher may run (read again at every request, so a change
# here needs no watcher restart). Results: one digest line per step with DURATION_S (see tools\watch.ps1).
#   test          selftest + offline-scan check; restarts the dvcl window if all pass
#   full          every check the release runs (selftest, arguments, Diversion data, selection, window self-check)
#   close-unreal  asks the open Unreal editor to quit: refused if it holds unsaved changes (never killed)
#   open-unreal   opens the workspace's Unreal project
#   link          build + install the Unreal link: closes Unreal first (as close-unreal) and reopens it after
#   restart       restart the dvcl window
#   probe         read-only Diversion command help (dv log / branch / merge / show), to tests\probe-dv.log
#   timings       where the time goes: dv call durations from the workspace's dvcl log, to tests\timings.log
#   release       'full', then commit + tag (VERSION) + push, only if all pass and no private word is staged

function Local-Setting([string]$name) { $f = Join-Path $RunDir $name; if (Test-Path -LiteralPath $f) { return ([string](Get-Content -LiteralPath $f -TotalCount 1)).Trim() }; return '' }
function Step([string]$name, [scriptblock]$sb) {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $res = 'OK'; $info = ''
    try { $info = (@(& $sb) | ForEach-Object { [string]$_ }) -join ' | ' } catch { $res = 'FAIL'; $info = $_.Exception.Message }
    $line = 'STEP {0} {1} DURATION_S {2} :: {3}' -f $name, $res, [int]$sw.Elapsed.TotalSeconds, (($info -replace "`r?`n", ' | ') -replace '\s+', ' ')
    $script:Digest.Add($line); Write-Host $line
    return ($res -eq 'OK')
}
function Need-Workspace { $ws = Local-Setting 'workspace.txt'; if (-not $ws -or -not (Test-Path -LiteralPath $ws)) { throw 'no workspace: put its folder in _run\workspace.txt' }; return $ws }

function Do-Selftest {
    $o = @(cmd /c "`"$RepoDir\dvcl.cmd`" selftest" 2>&1 | ForEach-Object { [string]$_ })
    $f = @($o | Where-Object { $_ -like 'FAIL*' }); $sum = (@($o | Where-Object { $_ -like 'SELFTEST:*' }) -join '')
    if ($f.Count -or $sum -notlike '*, 0 failed') { throw ($sum + ' :: ' + ($f -join ' || ')) }
    return $sum
}
function Do-CheckIgnore { $ws = Need-Workspace; return (powershell -NoProfile -ExecutionPolicy Bypass -File "$RepoDir\tests\check-ignore.ps1" $ws 2>&1 | Select-Object -Last 1) }
function Do-Args {
    $ga = @(cmd /c "`"$RepoDir\tests\args.cmd`"" 2>&1 | ForEach-Object { [string]$_ })
    if ($ga.Count -ne 2 -or $ga[0] -cne 'ARGS 15 :: silo_work | Silo | pass | 2 | (Sam): | bzn | - | tower, | cornice; | (LiDAR | mirrors | LAS | Y). | Config: | on.' -or $ga[1] -cne 'ARGS 3 :: default | Silo pass 3 (Sam, photos): roof + lantern & dock, 50% off | -y') { throw ($ga -join ' || ') }
    return 'arguments as typed'
}
function Do-CheckDv { $ws = Need-Workspace; $l = [string](powershell -NoProfile -ExecutionPolicy Bypass -File "$RepoDir\tests\check-dv.ps1" $ws 2>&1 | Select-Object -Last 1); if ($l -notlike '*, 0 problem(s)') { throw $l }; return $l }
function Do-Selection {
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File "$RepoDir\tests\screenshot.ps1" | Out-Null
    $dm = @(Select-String -Path "$RepoDir\tests\gui-selfcheck-demo.txt" -Pattern 'tick boxes|click|select all|  clear|selection kept' | ForEach-Object { $_.Line })
    if ($dm.Count -lt 8 -or @($dm | Where-Object { $_ -notlike 'PASS*' }).Count) { throw ($dm -join ' || ') }
    return ([string]$dm.Count + ' selection checks')
}
function Do-RunAll {
    $ws = Need-Workspace
    cmd /c "`"$RepoDir\tests\run.cmd`" `"$ws`"" | Out-Null
    $f = @(Select-String -Path "$RepoDir\tests\last-run.txt" -Pattern 'FAIL  ' -SimpleMatch | ForEach-Object { $_.Line })
    $s = @(Select-String -Path "$RepoDir\tests\last-run.txt" -Pattern 'SELFTEST:|GUI SELFCHECK' | ForEach-Object { $_.Line })
    if ($f.Count) { throw (($s -join ' | ') + ' :: ' + ($f -join ' || ')) }
    return ($s -join ' | ')
}
function Stop-Window {
    $pat = '*dvcl-gui' + '.ps1*'
    $old = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like $pat -and $_.CommandLine -notlike '*SelfCheck*' })
    foreach ($p in $old) { Stop-Process -Id $p.ProcessId -Force }
    return $old.Count
}
function Do-Restart { $n = Stop-Window; Start-Sleep 1; Start-Process (Join-Path $RepoDir 'dvcl.exe'); return ('dvcl window restarted (' + $n + ' closed)') }

# ---- Unreal: closed only by asking the editor itself (Python remote execution through dvcl), never killed
function Ue-Core { . (Join-Path $RepoDir 'src\DvclCore.ps1'); Set-DvRoot (Find-DvRoot (Need-Workspace)) }
function Do-CloseUnreal {
    if (-not (Get-Process UnrealEditor -ErrorAction SilentlyContinue)) { return 'Unreal was not open' }
    . Ue-Core
    $py = "import unreal`nd = [p.get_name() for p in unreal.EditorLoadingAndSavingUtils.get_dirty_content_packages()] + [p.get_name() for p in unreal.EditorLoadingAndSavingUtils.get_dirty_map_packages()]`nif d:`n    print('UNSAVED ' + str(len(d)) + ': ' + ', '.join(d[:8]))`nelse:`n    print('QUITTING')`n    unreal.SystemLibrary.quit_editor()"
    $r = Invoke-Ue $py
    $uns = @($r.Lines | Where-Object { $_ -like 'UNSAVED*' })
    if ($uns.Count) { throw ('Unreal not closed, it has unsaved changes: ' + $uns[0] + ' - save in Unreal, then ask again') }
    if (-not (@($r.Lines) -contains 'QUITTING')) { throw ('Unreal did not answer (' + $r.State + '): close it yourself') }
    for ($i = 0; $i -lt 60; $i++) { if (-not (Get-Process UnrealEditor -ErrorAction SilentlyContinue)) { return 'Unreal closed' }; Start-Sleep 2 }
    throw 'Unreal still open after 2 min (a dialog may be waiting in it)'
}
function Do-OpenUnreal {
    $ws = Need-Workspace
    $up = @(Get-ChildItem -LiteralPath $ws -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter *.uproject -File -ErrorAction SilentlyContinue } | Select-Object -First 1)
    if (-not $up.Count) { throw 'no .uproject found in the workspace' }
    $eng = Local-Setting 'engine.txt'; if (-not $eng) { throw 'no engine: put its folder in _run\engine.txt' }
    $exe = Join-Path $eng 'Engine\Binaries\Win64\UnrealEditor.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw ('no editor at ' + $exe) }
    Start-Process -FilePath $exe -ArgumentList ('"' + $up[0].FullName + '"')
    return ('Unreal opening ' + $up[0].Name + ' (takes a few minutes)')
}
function Do-Link {
    if (Get-Process UnrealEditor -ErrorAction SilentlyContinue) { throw 'Unreal is open (close-unreal first)' }
    $eng = Local-Setting 'engine.txt'
    $o = @(cmd /c "`"$RepoDir\ue\install.cmd`" `"$eng`"" 2>&1 | ForEach-Object { [string]$_ })
    if (-not ($o -match '^OK installed')) { throw ((@(Select-String -Path "$RepoDir\ue\install.log" -Pattern ': error ' | Select-Object -First 12 | ForEach-Object { $_.Line }) + @($o | Select-Object -Last 3)) -join ' || ') }
    return ($o | Where-Object { $_ -match '^OK installed' } | Select-Object -First 1)
}
function Do-Probe {
    $ws = Need-Workspace
    $pl = New-Object System.Collections.Generic.List[string]
    Push-Location $ws
    try {
        $last = ''; foreach ($l in @(& dv log -n 1 2>&1)) { if ([string]$l -match '(dv\.commit\.\d+)') { $last = $Matches[1]; break } }
        foreach ($a in @(@('log', '--help'), @('log', '-n', '5'), @('branch'), @('merge', '-l'), @('show', $last), @('show', '--help'))) {
            $pl.Add('==== dv ' + ($a -join ' '))
            foreach ($l in @(& dv @a 2>&1 | ForEach-Object { [string]$_ } | Select-Object -First 60)) { $pl.Add($l) }
        }
    } finally { Pop-Location }
    [System.IO.File]::WriteAllLines((Join-Path $RepoDir 'tests\probe-dv.log'), [string[]]$pl)
    return ([string]$pl.Count + ' lines to tests\probe-dv.log')
}
# where the time goes: dvcl's own TIMING lines and the duration of each dv call, from the workspace's dvcl log
function Do-Timings {
    $ws = Need-Workspace; $f = Join-Path $ws '.dvcl\dvcl.log'
    if (-not (Test-Path -LiteralPath $f)) { throw 'no dvcl log in the workspace' }
    $lines = @(Get-Content -LiteralPath $f -Tail 6000 | Where-Object { $_ -match 'TIMING |  exit=\S+\s+\d+ms  dv |==== dvcl |RUN dv |online|offline' })
    [System.IO.File]::WriteAllLines((Join-Path $RepoDir 'tests\timings.log'), [string[]]$lines)
    # per dv command: count, median, max (ms)
    $by = @{}
    foreach ($l in $lines) { if ($l -match 'exit=\S+\s+(\d+)ms  dv (\S+)') { $k = $Matches[2]; if (-not $by.ContainsKey($k)) { $by[$k] = New-Object System.Collections.Generic.List[int] }; $by[$k].Add([int]$Matches[1]) } }
    $sum = foreach ($k in $by.Keys) { $v = @($by[$k] | Sort-Object); 'dv ' + $k + ' x' + $v.Count + ' median ' + $v[[int]($v.Count / 2)] + 'ms max ' + $v[-1] + 'ms' }
    return ((@($sum) | Sort-Object) -join ' ; ')
}
function Do-Publish {
    $words = Local-Setting 'private-words.txt'; if (-not $words) { throw 'no _run\private-words.txt: release refused' }
    $msg = Local-Setting 'release-message.txt'; if (-not $msg) { throw 'no _run\release-message.txt: release refused' }
    $ver = ([string](Get-Content -LiteralPath "$RepoDir\VERSION" -TotalCount 1)).Trim()
    Push-Location $RepoDir
    try {
        Remove-Item -LiteralPath VERSION.new, VERSION.tmp -Force -ErrorAction SilentlyContinue
        git add -A 2>&1 | Out-Null
        $h = @(git diff --cached -U0 | Select-String -Pattern ('^\+.*(' + $words + ')'))
        if ($h.Count) { git reset -q 2>&1 | Out-Null; throw ([string]$h.Count + ' staged line(s) hold a private word: not committed') }
        if (-not (git diff --cached --name-only)) { throw 'nothing to commit' }
        git commit -q -m $msg; if ($LASTEXITCODE) { throw 'commit failed' }
        git tag ('v' + $ver); git push origin main --tags 2>&1 | Out-Null
        if ($LASTEXITCODE) { git push origin main --tags 2>&1 | Out-Null; if ($LASTEXITCODE) { throw 'push failed' } }
        Remove-Item -LiteralPath (Join-Path $RunDir 'release-message.txt') -Force -ErrorAction SilentlyContinue
        return ('released v' + $ver + ' ' + (git rev-parse --short HEAD))
    } finally { Pop-Location }
}
function Run-Full {
    $ok = (Step 'selftest' { Do-Selftest }); if ($ok) { $ok = (Step 'args' { Do-Args }) }; if ($ok) { $ok = (Step 'check-dv' { Do-CheckDv }) }
    if ($ok) { [void](Step 'close-window' { Stop-Window }); $ok = (Step 'selection' { Do-Selection }) }; if ($ok) { $ok = (Step 'run-all' { Do-RunAll }) }
    return $ok
}

$actions = @{
    'test'         = { if ((Step 'selftest' { Do-Selftest }) -and (Step 'check-ignore' { Do-CheckIgnore })) { [void](Step 'restart' { Do-Restart }) } }
    'full'         = { [void](Run-Full); [void](Step 'restart' { Do-Restart }) }
    'close-unreal' = { [void](Step 'close-unreal' { Do-CloseUnreal }) }
    'open-unreal'  = { [void](Step 'open-unreal' { Do-OpenUnreal }) }
    'link'         = { $was = [bool](Get-Process UnrealEditor -ErrorAction SilentlyContinue)
                       if (Step 'close-unreal' { Do-CloseUnreal }) { [void](Step 'link' { Do-Link }); if ($was) { [void](Step 'open-unreal' { Do-OpenUnreal }) } } }
    'restart'      = { [void](Step 'restart' { Do-Restart }) }
    'probe'        = { [void](Step 'probe' { Do-Probe }) }
    'timings'      = { [void](Step 'timings' { Do-Timings }) }
    'bench'        = { [void](Step 'bench' { $ws = Need-Workspace; $o = Join-Path $RepoDir 'tests\bench.log'; & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoDir 'tools\bench.ps1') $ws $o 2>&1 | Out-Null; if (-not (Test-Path -LiteralPath $o)) { throw 'bench wrote nothing' }; (Get-Content -LiteralPath $o | Select-Object -First 3) -join ' ; ' }) }
    'release'      = { if (Run-Full) { [void](Step 'publish' { Do-Publish }) }; [void](Step 'restart' { Do-Restart }) }
}
