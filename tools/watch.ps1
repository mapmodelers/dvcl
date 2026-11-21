# tools\watch.ps1 - dvcl dev watcher. Start it once (dev-watch.cmd) and leave the window open.
# It runs ONLY the actions of tools\watch-actions.ps1 (read again at every request), when _run\request.txt
# appears (first line = action word). Results: _run\done.txt (action, result, time), _run\digest.txt (one line
# per step with DURATION_S), _run\watch.log (full output of the last action). Heartbeat every 10 s: _run\alive.txt.
# Local settings (in _run, never committed): workspace.txt (Diversion workspace to test against), engine.txt
# (Unreal engine folder), private-words.txt (regex the release refuses to publish), release-message.txt.
$RepoDir = Split-Path -Parent $PSScriptRoot
$RunDir = Join-Path $RepoDir '_run'
New-Item -ItemType Directory -Force $RunDir | Out-Null
$req = Join-Path $RunDir 'request.txt'
$script:Digest = New-Object System.Collections.Generic.List[string]

$host.UI.RawUI.WindowTitle = 'dvcl dev watcher'
Write-Host 'dvcl dev watcher - leave this window open, close it to stop.'
$beat = 0
while ($true) {
    if (Test-Path -LiteralPath $req) {
        Start-Sleep -Milliseconds 300
        $a = ''
        try { $a = ([string](Get-Content -LiteralPath $req -TotalCount 1)).Trim().ToLower() } catch {}
        Remove-Item -LiteralPath $req -Force -ErrorAction SilentlyContinue
        $t0 = Get-Date
        Set-Content -LiteralPath (Join-Path $RunDir 'done.txt') -Value ("$a running " + (Get-Date -Format s))
        $script:Digest.Clear()
        $actions = @{}
        try { . (Join-Path $PSScriptRoot 'watch-actions.ps1') } catch { $script:Digest.Add('STEP load FAIL DURATION_S 0 :: ' + $_.Exception.Message) }
        if ($actions.ContainsKey($a)) {
            Write-Host "[$(Get-Date -Format s)] running: $a"
            & $actions[$a] *>&1 | Tee-Object -FilePath (Join-Path $RunDir 'watch.log')
            $res = $(if (@($script:Digest | Where-Object { $_ -match '^STEP \S+ FAIL ' }).Count) { 'FAIL' } else { 'OK' })
        } else {
            Write-Host "[$(Get-Date -Format s)] refused unknown action: $a"
            $res = 'refused'
        }
        $script:Digest.Insert(0, ('ACTION {0} {1} DURATION_S {2} {3}' -f $a, $res, [int]((Get-Date) - $t0).TotalSeconds, (Get-Date -Format s)))
        [System.IO.File]::WriteAllLines((Join-Path $RunDir 'digest.txt'), [string[]]$script:Digest)
        Set-Content -LiteralPath (Join-Path $RunDir 'done.txt') -Value ("$a $res " + (Get-Date -Format s))
        Write-Host "[$(Get-Date -Format s)] finished: $a ($res)"
    }
    if ($beat % 5 -eq 0) { Set-Content -LiteralPath (Join-Path $RunDir 'alive.txt') -Value (Get-Date -Format s) }
    $beat++
    Start-Sleep -Seconds 2
}
