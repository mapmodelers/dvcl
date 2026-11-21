# tools\watch.ps1 - dvcl dev watcher. Start it once (dev-watch.cmd) and leave the window open.
# It runs ONLY the actions below, when _run\request.txt appears (first line = action word).
# Results: _run\done.txt (action, result, time), _run\digest.txt (one line per step with DURATION_S),
# _run\watch.log (full output of the last action). Heartbeat every 10 s: _run\alive.txt.
# Local settings (in _run, never committed): workspace.txt (Diversion workspace to test against),
# engine.txt (Unreal engine folder, for 'link'), private-words.txt (regex the release refuses to publish),
# release-message.txt (commit message for 'release').
#   test     selftest + offline-scan check; restarts the dvcl window if all pass
#   full     every check the release runs (selftest, arguments, Diversion data, selection, window self-check)
#   link     build + install the Unreal link (refused while Unreal is open; never closes it)
#   restart  restart the dvcl window
#   release  'full', then commit + tag (VERSION) + push, only if all pass and no private word is staged
$root = Split-Path -Parent $PSScriptRoot
$run = Join-Path $root '_run'
New-Item -ItemType Directory -Force $run | Out-Null
$req = Join-Path $run 'request.txt'
function Local-Setting([string]$name) { $f = Join-Path $run $name; if (Test-Path -LiteralPath $f) { return ([string](Get-Content -LiteralPath $f -TotalCount 1)).Trim() }; return '' }

$script:Digest = New-Object System.Collections.Generic.List[string]
function Step([string]$name, [scriptblock]$sb) {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $res = 'OK'; $info = ''
    try { $info = (@(& $sb) | ForEach-Object { [string]$_ }) -join ' | ' } catch { $res = 'FAIL'; $info = $_.Exception.Message }
    $line = 'STEP {0} {1} DURATION_S {2} :: {3}' -f $name, $res, [int]$sw.Elapsed.TotalSeconds, (($info -replace "`r?`n", ' | ') -replace '\s+', ' ')
    $script:Digest.Add($line); Write-Host $line
    return ($res -eq 'OK')
}
function Need-Workspace { $ws = Local-Setting 'workspace.txt'; if (-not $ws -or -not (Test-Path -LiteralPath $ws)) { throw 'no workspace: put its folder in _run\workspace.txt' }; return $ws }

function Do-Selftest {
    $o = @(cmd /c "`"$root\dvcl.cmd`" selftest" 2>&1 | ForEach-Object { [string]$_ })
    $f = @($o | Where-Object { $_ -like 'FAIL*' }); $sum = (@($o | Where-Object { $_ -like 'SELFTEST:*' }) -join '')
    if ($f.Count -or $sum -notlike '*, 0 failed') { throw ($sum + ' :: ' + ($f -join ' || ')) }
    return $sum
}
function Do-CheckIgnore { $ws = Need-Workspace; return (powershell -NoProfile -ExecutionPolicy Bypass -File "$root\tests\check-ignore.ps1" $ws 2>&1 | Select-Object -Last 1) }
function Do-Args {
    $ga = @(cmd /c "`"$root\tests\args.cmd`"" 2>&1 | ForEach-Object { [string]$_ })
    if ($ga.Count -ne 2 -or $ga[0] -cne 'ARGS 15 :: silo_work | Silo | pass | 2 | (Sam): | bzn | - | tower, | cornice; | (LiDAR | mirrors | LAS | Y). | Config: | on.' -or $ga[1] -cne 'ARGS 3 :: default | Silo pass 3 (Sam, photos): roof + lantern & dock, 50% off | -y') { throw ($ga -join ' || ') }
    return 'arguments as typed'
}
function Do-CheckDv { $ws = Need-Workspace; $l = [string](powershell -NoProfile -ExecutionPolicy Bypass -File "$root\tests\check-dv.ps1" $ws 2>&1 | Select-Object -Last 1); if ($l -notlike '*, 0 problem(s)') { throw $l }; return $l }
function Do-Selection {
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File "$root\tests\screenshot.ps1" | Out-Null
    $dm = @(Select-String -Path "$root\tests\gui-selfcheck-demo.txt" -Pattern 'tick boxes|click|select all|  clear|selection kept' | ForEach-Object { $_.Line })
    if ($dm.Count -lt 8 -or @($dm | Where-Object { $_ -notlike 'PASS*' }).Count) { throw ($dm -join ' || ') }
    return ([string]$dm.Count + ' selection checks')
}
function Do-RunAll {
    $ws = Need-Workspace
    cmd /c "`"$root\tests\run.cmd`" `"$ws`"" | Out-Null
    $f = @(Select-String -Path "$root\tests\last-run.txt" -Pattern 'FAIL  ' -SimpleMatch | ForEach-Object { $_.Line })
    $s = @(Select-String -Path "$root\tests\last-run.txt" -Pattern 'SELFTEST:|GUI SELFCHECK' | ForEach-Object { $_.Line })
    if ($f.Count) { throw (($s -join ' | ') + ' :: ' + ($f -join ' || ')) }
    return ($s -join ' | ')
}
function Stop-Window {
    $pat = '*dvcl-gui' + '.ps1*'
    $old = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like $pat -and $_.CommandLine -notlike '*SelfCheck*' })
    foreach ($p in $old) { Stop-Process -Id $p.ProcessId -Force }
    return $old.Count
}
function Do-Restart { $n = Stop-Window; Start-Sleep 1; Start-Process (Join-Path $root 'dvcl.exe'); return ('dvcl window restarted (' + $n + ' closed)') }
function Do-Link {
    if (Get-Process UnrealEditor -ErrorAction SilentlyContinue) { throw 'Unreal is open: close it, then ask again (the watcher never closes Unreal)' }
    $eng = Local-Setting 'engine.txt'
    $o = @(cmd /c "`"$root\ue\install.cmd`" `"$eng`"" 2>&1 | ForEach-Object { [string]$_ })
    if (-not ($o -match '^OK installed')) { throw ((@(Select-String -Path "$root\ue\install.log" -Pattern ': error ' | Select-Object -First 12 | ForEach-Object { $_.Line }) + @($o | Select-Object -Last 3)) -join ' || ') }
    return ($o | Where-Object { $_ -match '^OK installed' } | Select-Object -First 1)
}
function Do-Publish {
    $words = Local-Setting 'private-words.txt'; if (-not $words) { throw 'no _run\private-words.txt: release refused' }
    $msg = Local-Setting 'release-message.txt'; if (-not $msg) { throw 'no _run\release-message.txt: release refused' }
    $ver = ([string](Get-Content -LiteralPath "$root\VERSION" -TotalCount 1)).Trim()
    Push-Location $root
    try {
        Remove-Item -LiteralPath VERSION.new, VERSION.tmp -Force -ErrorAction SilentlyContinue
        git add -A 2>&1 | Out-Null
        $h = @(git diff --cached -U0 | Select-String -Pattern ('^\+.*(' + $words + ')'))
        if ($h.Count) { git reset -q 2>&1 | Out-Null; throw ([string]$h.Count + ' staged line(s) hold a private word: not committed') }
        if (-not (git diff --cached --name-only)) { throw 'nothing to commit' }
        git commit -q -m $msg; if ($LASTEXITCODE) { throw 'commit failed' }
        git tag ('v' + $ver); git push origin main --tags 2>&1 | Out-Null
        if ($LASTEXITCODE) { git push origin main --tags 2>&1 | Out-Null; if ($LASTEXITCODE) { throw 'push failed' } }
        Remove-Item -LiteralPath (Join-Path $run 'release-message.txt') -Force -ErrorAction SilentlyContinue
        return ('released v' + $ver + ' ' + (git rev-parse --short HEAD))
    } finally { Pop-Location }
}

$actions = @{
    'test'    = { if ((Step 'selftest' { Do-Selftest }) -and (Step 'check-ignore' { Do-CheckIgnore })) { [void](Step 'restart' { Do-Restart }) } }
    'full'    = { $ok = (Step 'selftest' { Do-Selftest }); if ($ok) { $ok = (Step 'args' { Do-Args }) }; if ($ok) { $ok = (Step 'check-dv' { Do-CheckDv }) }
                  if ($ok) { [void](Step 'close-window' { Stop-Window }); $ok = (Step 'selection' { Do-Selection }) }; if ($ok) { $ok = (Step 'run-all' { Do-RunAll }) }; [void](Step 'restart' { Do-Restart }) }
    'link'    = { [void](Step 'link' { Do-Link }) }
    'restart' = { [void](Step 'restart' { Do-Restart }) }
    'release' = { $ok = (Step 'selftest' { Do-Selftest }); if ($ok) { $ok = (Step 'args' { Do-Args }) }; if ($ok) { $ok = (Step 'check-dv' { Do-CheckDv }) }
                  if ($ok) { [void](Step 'close-window' { Stop-Window }); $ok = (Step 'selection' { Do-Selection }) }; if ($ok) { $ok = (Step 'run-all' { Do-RunAll }) }
                  if ($ok) { [void](Step 'publish' { Do-Publish }) }; [void](Step 'restart' { Do-Restart }) }
}

$host.UI.RawUI.WindowTitle = 'dvcl dev watcher'
Write-Host 'dvcl dev watcher - leave this window open, close it to stop.'
Write-Host ('Allowed actions: ' + (($actions.Keys | Sort-Object) -join ', '))
$beat = 0
while ($true) {
    if (Test-Path -LiteralPath $req) {
        Start-Sleep -Milliseconds 300
        $a = ''
        try { $a = ([string](Get-Content -LiteralPath $req -TotalCount 1)).Trim().ToLower() } catch {}
        Remove-Item -LiteralPath $req -Force -ErrorAction SilentlyContinue
        $t0 = Get-Date
        Set-Content -LiteralPath (Join-Path $run 'done.txt') -Value ("$a running " + (Get-Date -Format s))
        $script:Digest.Clear()
        if ($actions.ContainsKey($a)) {
            Write-Host "[$(Get-Date -Format s)] running: $a"
            & $actions[$a] *>&1 | Tee-Object -FilePath (Join-Path $run 'watch.log')
            $res = $(if (@($script:Digest | Where-Object { $_ -match '^STEP \S+ FAIL ' }).Count) { 'FAIL' } else { 'OK' })
        } else {
            Write-Host "[$(Get-Date -Format s)] refused unknown action: $a"
            $res = 'refused'
        }
        $script:Digest.Insert(0, ('ACTION {0} {1} DURATION_S {2} {3}' -f $a, $res, [int]((Get-Date) - $t0).TotalSeconds, (Get-Date -Format s)))
        [System.IO.File]::WriteAllLines((Join-Path $run 'digest.txt'), [string[]]$script:Digest)
        Set-Content -LiteralPath (Join-Path $run 'done.txt') -Value ("$a $res " + (Get-Date -Format s))
        Write-Host "[$(Get-Date -Format s)] finished: $a ($res)"
    }
    if ($beat % 5 -eq 0) { Set-Content -LiteralPath (Join-Path $run 'alive.txt') -Value (Get-Date -Format s) }
    $beat++
    Start-Sleep -Seconds 2
}
