# DvclCore.ps1 - shared engine for dvcl (CLI) and dvcl-gui (window).
# Named changelists on top of the Diversion CLI (dv v1.6+).
# Per-repo data (local, never versioned): <repo>\.dvcl\changelists.json  - log: <repo>\.dvcl\dvcl.log
# Windows PowerShell 5.1 compatible. Errors are thrown (callers decide how to show them).

$script:Root = $null
$script:Db   = $null
$script:Log  = $null
$script:CLs  = New-Object System.Collections.ArrayList
$script:OnSay = $null    # optional scriptblock { param($text, $color) } (GUI log panel)
$script:OnDv  = $null    # optional scriptblock { param($line) } (GUI: live dv output)

# dv prints progress lines while it waits for sync: kept out of logs and UI
# lines that mean "your files are still going up" (Wait-Upload)
$script:DvUpload = '^\s*Compressing |^Uploading |^Outbound changes|active blob transfers|^Sync in progress|^Currently syncing|^Queued filesystem events'
$script:DvNoise = '\{\{spinner\}\}|^\s*Compressing |^Sync in progress|^Queued filesystem events|^Inbound changes|^Outbound changes|^Currently syncing|active blob transfers|^Downloading |^Uploading |^Recently synced'

# ---------------------------------------------------------------- repo / logging
function Find-DvRoot([string]$start) {
    if (-not $start -or -not (Test-Path -LiteralPath $start)) { return $null }
    # GetFullPath normalizes 'D:\repo.' (trailing dot from dvcl-gui.cmd) and relative paths
    $d = [System.IO.Path]::GetFullPath($start).TrimEnd('\')
    if ($d -match '^[A-Za-z]:$') { $d += '\' }
    # the user folder's .diversion is Diversion's own settings, not a workspace
    $prof = ([string]$env:USERPROFILE).TrimEnd('\')
    while ($d) {
        if ($d.TrimEnd('\') -ine $prof -and (Test-Path -LiteralPath (Join-Path $d '.diversion') -PathType Container)) { return $d }
        $p = Split-Path -Parent $d
        if (-not $p -or $p -eq $d) { break }
        $d = $p
    }
    return $null
}

function Set-DvRoot([string]$root) {
    $script:Root = $root.TrimEnd('\')
    $dir = Join-Path $script:Root '.dvcl'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $script:Db  = Join-Path $dir 'changelists.json'
    $script:Log = Join-Path $dir 'dvcl.log'
    # where dvcl is installed, for the Unreal revision control "dvcl" (it runs dvcl's command line)
    try { $tf = Join-Path $dir 'tool.txt'; $tool = Split-Path -Parent $PSScriptRoot; if (-not (Test-Path -LiteralPath $tf) -or ([System.IO.File]::ReadAllText($tf)).Trim() -ne $tool) { [System.IO.File]::WriteAllText($tf, $tool, (New-Object System.Text.UTF8Encoding($false))) } } catch {}
    # keep the log small: above 2 MB it becomes dvcl.old.log (previous one replaced)
    try { if ((Test-Path -LiteralPath $script:Log) -and (Get-Item -LiteralPath $script:Log).Length -gt 2MB) { Move-Item -LiteralPath $script:Log -Destination (Join-Path $dir 'dvcl.old.log') -Force } } catch {}
    Load-Db
}

function Write-Log([string]$t) {
    if (-not $script:Log) { return }
    try { Add-Content -LiteralPath $script:Log -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t) -Encoding UTF8 } catch {}
}

# Several lines in one write (dv output: one file open instead of one per line)
function Write-LogLines([string[]]$lines) {
    if (-not $script:Log -or -not $lines -or $lines.Count -eq 0) { return }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content -LiteralPath $script:Log -Value @($lines | ForEach-Object { '[' + $ts + '] ' + $_ }) -Encoding UTF8 } catch {}
}

# Telemetry for diagnosis: "TIMING <what> <ms>" lines in the log
function Write-Timing([string]$what, [double]$ms) { Write-Log ("TIMING " + $what + " " + [int]$ms + "ms") }

function Say([string]$t, [string]$c = 'Gray') {
    Write-Log ("> " + $t)
    if ($script:OnSay) { & $script:OnSay $t $c } else { Write-Host $t -ForegroundColor $c }
}

function Fail([string]$t) { Write-Log ("ERROR: " + $t); throw $t }

function Norm([string]$p) {
    $p = ($p -replace '\\', '/').Trim().Trim('"')
    if ($script:Root) {
        $rootFwd = ($script:Root -replace '\\', '/').TrimEnd('/') + '/'
        if ($p.StartsWith($rootFwd, [StringComparison]::OrdinalIgnoreCase)) { $p = $p.Substring($rootFwd.Length) }
    }
    $p = $p -replace '^\./', ''
    return $p.TrimEnd('/')
}

# Runs dv in the repo. $quiet: output goes to the log file only, not to the window.
# One argument quoted for a Windows command line (the rules programs use to split it back)
function Quote-Arg([string]$a) {
    if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
    $bs = [char]92; $sb = New-Object System.Text.StringBuilder; [void]$sb.Append('"'); $k = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq $bs) { $k++; continue }
        if ($ch -eq [char]34) { [void]$sb.Append($bs, 2 * $k + 1); [void]$sb.Append([char]34); $k = 0; continue }
        if ($k) { [void]$sb.Append($bs, $k); $k = 0 }
        [void]$sb.Append($ch)
    }
    [void]$sb.Append($bs, 2 * $k); [void]$sb.Append('"')
    return $sb.ToString()
}
# Runs a program while the window keeps working ($script:PumpUi: repaint, scroll, browse) instead of
# freezing until it ends. Output: stdout then stderr lines. Returns @{ Lines; Code }.
function Invoke-Pumped([string]$exe, [string[]]$a, [string]$cwd) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = (@($a | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
    $psi.WorkingDirectory = $cwd; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    try { $psi.StandardOutputEncoding = [Console]::OutputEncoding; $psi.StandardErrorEncoding = [Console]::OutputEncoding } catch {}
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $beat = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.WaitForExit(25)) {
        if ($script:PumpUi) { & $script:PumpUi }
        # a long online action keeps its online mark fresh: other dvcl do not pause sync under it
        if ($beat.ElapsedMilliseconds -gt 60000) { $beat.Restart(); Touch-OnlineMark }
    }
    $p.WaitForExit()
    $lines = New-Object System.Collections.ArrayList
    foreach ($t in @($o.Result, $e.Result)) {
        if (-not $t) { continue }
        $ls = $t -split "`r?`n"; if ($ls.Count -and $ls[-1] -eq '') { $ls = @($ls | Select-Object -SkipLast 1) }
        foreach ($l in $ls) { [void]$lines.Add([string]$l) }
    }
    $code = $p.ExitCode; $p.Dispose()
    return [pscustomobject]@{ Lines = @($lines); Code = $code }
}
# dv's own .exe (pumped runs need it; a dv.cmd / script falls back to the normal call)
function Dv-Exe {
    if ($null -eq $script:DvExe) {
        $script:DvExe = ''
        $g = @(Get-Command dv -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -like '*.exe' }) | Select-Object -First 1
        if ($g) { $script:DvExe = $g.Source }
    }
    return $script:DvExe
}

function Invoke-Dv([string[]]$a, [bool]$quiet = $false, [bool]$brief = $false) {
    if (-not $script:Root) { Fail "no Diversion repo selected" }
    Write-Log ("RUN dv " + ($a -join ' '))
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $script:Root
    try {
        if ($script:PumpUi -and (Dv-Exe)) { $pr = Invoke-Pumped (Dv-Exe) $a $script:Root; $out = @($pr.Lines); $code = $pr.Code }
        else {
            $out  = @(& dv @a 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
        }
    } catch {
        $out = @("dv could not be started: " + $_.Exception.Message + " (is Diversion installed and dv in PATH?)"); $code = 9009
    } finally {
        Pop-Location
        $ErrorActionPreference = $prev
    }
    return (Finish-Dv $a $out $code $quiet (-not $brief) $t0.Elapsed.TotalMilliseconds)
}

# Shared by Invoke-Dv and the window's background runner: filters progress noise, logs, reports.
# SyncBusy = dv printed sync-progress lines (Diversion still uploading / downloading).
function Finish-Dv([string[]]$a, [string[]]$out, [int]$code, [bool]$quiet, [bool]$logLines, [double]$ms) {
    $out = @($out | Where-Object { $null -ne $_ })
    $busy = (@($out | Where-Object { $_ -match $script:DvNoise })).Count -gt 0
    $upl = @($out | Where-Object { $_ -match $script:DvUpload } | Select-Object -First 1)
    $clean = @($out | Where-Object { $_ -notmatch $script:DvNoise })
    if ($logLines) { Write-LogLines @($clean | ForEach-Object { '  | ' + $_ }) }
    else { Write-LogLines @(@('  (' + $clean.Count + ' lines, first 5:)') + @($clean | Select-Object -First 5 | ForEach-Object { '  sample | ' + $_ })) }
    if (-not $quiet -and $script:OnDv) { foreach ($l in $clean) { if ($l.Trim()) { & $script:OnDv $l } } }
    Write-Log ("  exit=" + $code + "  " + [int]$ms + "ms  dv " + ($a -join ' '))
    return [pscustomobject]@{ Code = $code; Lines = $clean; SyncBusy = $busy; Upload = $(if ($upl.Count) { [string]$upl[0] } else { '' }) }
}

# ---------------------------------------------------------------- depot listing (dv ls)
# All paths of the workspace revision, sorted (ordinal) for prefix lookups.
# Quiet on purpose: thousands of lines go neither to the log nor to the UI.
function Get-DepotPaths {
    if (-not $script:Root) { Fail "no Diversion repo selected" }
    Write-Log "RUN dv ls"
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $script:Root
    try { $out = @(& dv ls 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    catch { $out = @("dv could not be started: " + $_.Exception.Message); $code = 9009 }
    finally { Pop-Location; $ErrorActionPreference = $prev }
    return (Read-DepotResult (Finish-Dv @('ls') $out $code $true $false $t0.Elapsed.TotalMilliseconds))
}

function Read-DepotResult($r) {
    if ($r.Code -ne 0) { Fail ("dv ls failed: " + (($r.Lines | Select-Object -Last 3) -join ' | ')) }
    return ,(Parse-DepotLines $r.Lines)
}

# dv ls lines: "(F) <path> <size> <mode>" and "(D) <path> <mode>"; other lines are ignored.
# Folders get a trailing '/'. Returns the paths sorted (ordinal).
function Parse-DepotLines([string[]]$lines) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -match '^\(F\)\s+(.+?)\s+\d[\d.,]*\s*[KkMGT]?i?B\s+\S+$') { $list.Add(($Matches[1] -replace '\\', '/')) }
        elseif ($t -match '^\(D\)\s+(.+?)\s+[-dlrwxsStT]{10}$') { $list.Add((($Matches[1] -replace '\\', '/').TrimEnd('/') + '/')) }
    }
    $arr = $list.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return ,$arr
}

# Immediate children of a folder ('' = root) in a sorted path list: @{ Dirs; Files }
function Get-DepotChildren([string[]]$paths, [string]$dir) {
    $prefix = ''
    if ($dir) { $prefix = $dir.TrimEnd('/') + '/' }
    $dirs  = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $files = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $i = 0
    if ($prefix) { $i = [Array]::BinarySearch($paths, $prefix, [StringComparer]::Ordinal); if ($i -lt 0) { $i = -bnot $i } }
    for (; $i -lt $paths.Length; $i++) {
        $p = $paths[$i]
        if (-not $p.StartsWith($prefix, [StringComparison]::Ordinal)) { break }
        $rest = $p.Substring($prefix.Length)
        if (-not $rest) { continue }
        $k = $rest.IndexOf('/')
        if ($k -ge 0) { [void]$dirs.Add($rest.Substring(0, $k)) } else { [void]$files.Add($rest) }
    }
    foreach ($d in $dirs) { [void]$files.Remove($d) }
    return [pscustomobject]@{ Dirs = @($dirs); Files = @($files) }
}

# ---------------------------------------------------------------- dv status
# Section headers look like "New:" / "Modified:"; entries are indented lines below them.
# "old -> new" (renames) keeps both paths.
function Parse-Status([string[]]$lines) {
    $res  = New-Object System.Collections.ArrayList
    $kind = $null
    foreach ($raw in $lines) {
        if ($null -eq $raw) { continue }
        $l = $raw.TrimEnd()
        if ($l -match '^([A-Za-z][A-Za-z ]*):\s*$') { $kind = $Matches[1]; continue }
        if ($kind -and $raw -match '^\s+(\S.*)$') {
            $entry = $Matches[1].Trim()
            $old = $null; $path = $entry
            if ($entry -match '^(.+?)\s+->\s+(.+)$') { $old = Norm $Matches[1]; $path = $Matches[2] }
            [void]$res.Add([pscustomobject]@{ Index = $res.Count + 1; Kind = $kind; Path = (Norm $path); Old = $old })
            continue
        }
        if ($l -ne '' -and $raw -notmatch '^\s') { $kind = $null }
    }
    return ,$res.ToArray()
}

# $wait: let dv wait until Diversion has synced everything (needed before submit / revert / shelve;
# can take a minute). Without it dv answers at once with what the agent knows so far.
function Status-Args([bool]$wait) { if ($wait) { return @('status', '--no-limit') } else { return @('status', '--no-limit', '--nowait') } }

function Get-Pending([bool]$wait = $true) {
    if ($wait -and $script:OnSay) { Say "Waiting for Diversion to finish syncing..." 'Gray' }
    return (Read-Status (Invoke-Dv (Status-Args $wait) $true))
}

function Read-Status($r) {
    if ($r.Code -ne 0) { Fail ("dv status failed (exit " + $r.Code + "). Is Diversion Desktop running? " + ($r.Lines -join ' ')) }
    $branch = ''; $commit = ''; $paused = $false
    foreach ($l in $r.Lines) {
        if ($l -match '^On branch (\S+)') { $branch = $Matches[1] }
        if ($l -match 'over commit (\S+)') { $commit = $Matches[1] }
        # header lines only (file entries are indented): "... paused ..." = sync off
        if ($l -notmatch '^\s' -and $l -match 'paus') { $paused = $true }
    }
    return [pscustomobject]@{ Files = (Parse-Status $r.Lines); Branch = $branch; Commit = $commit; Paused = $paused; Syncing = [bool]$r.SyncBusy }
}

# First commit id in `dv show <branch>` output = the branch head ('' if not found)
function Read-HeadCommit([string[]]$lines) {
    foreach ($l in $lines) { if ($l -match '(dv\.commit\.\d+)') { return $Matches[1] } }
    return ''
}

# ---------------------------------------------------------------- locks / folder sync
function Lock-Paths([string[]]$paths, [bool]$on) {
    $bad = 0
    foreach ($p in $paths) {
        if ($on) { $r = Invoke-Dv @('lock', $p) } else { $r = Invoke-Dv @('lock', '-d', $p) }
        if ($r.Code -ne 0) { $bad++; Say ("   FAILED: " + $p + "  -> " + ($r.Lines -join ' ')) 'Red' }
    }
    $verb = 'Unlocked'; if ($on) { $verb = 'Locked' }
    if ($bad -gt 0) { Fail ($bad.ToString() + " of " + @($paths).Count + " path(s) failed") }
    Say ($verb + " " + @($paths).Count + " path(s).") 'Green'
}

function Get-Locks {
    $r = Invoke-Dv @('lock') $true
    if ($r.Code -ne 0) { Fail ("dv lock failed: " + ($r.Lines -join ' ')) }
    return ,@($r.Lines | Where-Object { $_.Trim() })
}

# Selective sync: whether this PC downloads a folder (Diversion refuses while files are pending)
function Set-FolderSync([string]$folder, [bool]$on) {
    $f = Norm $folder
    $op = '-remove'; if ($on) { $op = '-add' }
    $r = Invoke-Dv @('preferences', $op, $f)
    if ($r.Code -ne 0) { Fail ("dv preferences " + $op + " failed: " + ($r.Lines -join ' ')) }
    if ($on) { Say ("This PC now downloads " + $f) 'Green' } else { Say ("This PC stopped downloading " + $f + " (it stays in Diversion)") 'Green' }
}

# ---------------------------------------------------------------- sync / get latest
# Going offline = pause sync. Before pausing, dvcl records a baseline of the folder (sizes + dates)
# and the current pending list, so it can find offline edits by itself (dv reports nothing while paused).
function Set-Sync([bool]$on) {
    # another dvcl (window or command) is online for its own action: its sync is left as it is,
    # that dvcl pauses it when done (else its upload would be cut)
    $other = Get-OtherOnline
    if ($other) {
        Write-Log ('sync ' + $(if ($on) { 'on' } else { 'off' }) + ': left to dvcl pid ' + $other.pid + ' (' + $other.what + '), online for its own action')
        if ($on) { Set-OfflineFlag $false; Say ("Online: another dvcl is online (" + $other.what + "), sync is already on.") 'Green' }
        else { Say ("Sync left on: another dvcl is online (" + $other.what + ") and pauses it when its action ends.") 'Yellow' }
        return
    }
    if (-not $on) {
        # Diversion's list from a sync wait seconds ago (after unshelve; nothing written since): reused
        if ($script:SyncedSt -and $script:SyncedAt -and ((Get-Date) - $script:SyncedAt).TotalSeconds -lt 15) { $st = $script:SyncedSt; Write-Log 'sync wait reused (just synced)' }
        else { $st = Get-Pending $true }
        $script:SyncedSt = $null
        if ($st.Paused) {
            # already paused (Diversion app): keep an existing baseline, else start one from the last online list
            if (-not (Test-Path -LiteralPath (Dvcl-File 'baseline.tsv'))) { Write-Baseline (Read-LastStatus) $st.Commit }
            Set-OfflineFlag $true; Clear-OnlineMark
            Say "Sync was already paused: dvcl is in offline mode." 'Yellow'
            return
        }
        Write-Baseline $st.Files $st.Commit
        Save-LastHead $st.Branch $st.Commit
    }
    $sub = 'pause'; if ($on) { $sub = 'resume' }
    $r = Invoke-Dv @('workspace', $sub)
    if ($r.Code -ne 0) {
        # already in that state (e.g. toggled in the Diversion app): fine
        if (($r.Lines -join ' ') -match 'already') { Say ("(Diversion: " + ($r.Lines -join ' ') + ")") 'Gray' }
        else { Fail ("dv workspace " + $sub + " failed: " + ($r.Lines -join ' ')) }
    }
    Set-OfflineFlag (-not $on)
    # who has sync on: a dvcl that dies before pausing again is found and undone (Safety-Check)
    if ($on) { Write-OnlineMark } else { Clear-OnlineMark }
    if ($on) { Say "Online: sync resumed. Diversion now uploads your offline changes to your private workspace (nothing is submitted)." 'Green' }
    else { Say "Offline: sync paused. dvcl tracks your changes by scanning the folder. Changelists and local shelves keep working." 'Yellow' }
}

function Get-Latest {
    $r = Invoke-Dv @('update')
    if ($r.Code -ne 0) { Fail ("dv update failed: " + ($r.Lines -join ' ')) }
    Say "Got latest from the branch." 'Green'
}

# dv log for one path: plain lines for display
function Get-History([string]$path) {
    $r = Invoke-Dv @('log', $path, '-n', '50')
    if ($r.Code -ne 0) { Fail ("dv log failed: " + ($r.Lines -join ' ')) }
    return ,@($r.Lines)
}

# ---------------------------------------------------------------- submitted commits (dv log / dv show)
# dv log: one block per commit, starting with the line holding its id (dv.commit.N);
# "Author:" / "Date:" lines, the rest is the description. --oneline: id + description on one line.
function Commit-Num([string]$id) { if ($id -match '(\d+)\s*$') { return [int]$Matches[1] }; return 0 }
function Parse-Log([string[]]$lines) {
    $list = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($raw in @($lines)) {
        $l = [string]$raw
        if ($l -match '^\s*(?:commit\s*:?\s+)?(dv\.commit\.\d+)\b(.*)$') {
            $rest = $Matches[2] -replace '^\s*\([^)]*\)', '' -replace '^\s*[-:|]\s*', ''
            $cur = [pscustomobject]@{ Id = $Matches[1]; Num = (Commit-Num $Matches[1]); Author = ''; Date = ''; Desc = $rest.Trim() }
            [void]$list.Add($cur); continue
        }
        if (-not $cur) { continue }
        if ($l -match '^\s*(?:Author|By|Committer|User)\s*:\s*(.+)$') { $cur.Author = ($Matches[1] -replace '\s*<[^>]*>', '').Trim(); continue }
        if ($l -match '^\s*(?:Date|Time|Created)\s*:\s*(.+)$') { $cur.Date = $Matches[1].Trim(); continue }
        if ($l -match '^\s*(?:Branch|Merge|Parents?|Ref)\s*:') { continue }
        if ($l.Trim()) { $cur.Desc = ($(if ($cur.Desc) { $cur.Desc + "`n" } else { '' }) + $l.Trim()) }
    }
    return $list   # streamed: callers wrap in @()
}
# dv show --name-status: "M<tab>path", "R<tab>old<tab>new" (or "old -> new"), or "Modified: path"
# Commit date for display, local time: "2026-11-12 09:35". dv gives ISO UTC with --date iso,
# else "MM-DD-YYYY HH:MM:SS".
function Format-CommitDate([string]$d) {
    $t = ([string]$d).Trim()
    if ($t -match '^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d)?Z$') {
        try { return ([datetime]::Parse($t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch {}
    }
    if ($t -match '^(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d)') { return ($Matches[1] + ' ' + $Matches[2]) }
    if ($t -match '^(\d\d)-(\d\d)-(\d{4})\s+(\d\d:\d\d)') { return ($Matches[3] + '-' + $Matches[1] + '-' + $Matches[2] + ' ' + $Matches[4]) }
    return $t
}
function Parse-ShowFiles([string[]]$lines) {
    $list = New-Object System.Collections.ArrayList
    foreach ($raw in @($lines)) {
        $l = [string]$raw; $k = $null; $path = $null
        # at column 0 only: the commit description is indented and may start with "A new..."
        if ($l -match '^([AMDRC])\d*(?:\t|\s+)(\S.*)$') { $k = $Matches[1]; $path = $Matches[2] }
        elseif ($l -match '^(Added|Modified|Deleted|Renamed|Moved|New|Removed|Changed)\s*:?\s+(\S.*)$') { $k = Kind-Letter $Matches[1]; $path = $Matches[2] }
        if (-not $k) { continue }
        if ($k -eq 'C') { $k = 'A' }
        $path = $path.Trim()
        if ($path -match '\t') { $path = ($path -split '\t')[-1] } elseif ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        $path = ($path.Trim().Trim('"') -replace '\\', '/').TrimStart('/')
        if ($path) { [void]$list.Add([pscustomobject]@{ Kind = $k; Path = $path }) }
    }
    return $list   # streamed: callers wrap in @()
}

# Unreal one-file-per-actor (OFPA): ".../__ExternalActors__/<level path>/<hashed folders>/<file>".
# Returns the level's folder and name ($null for any other file), so a level's thousands of actor
# files can show as one line.
function Ofpa-Group([string]$path) {
    $m = [regex]::Match($path, '^(.*?/__External(Actors|Objects)__/)(.+)$', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $segs = @($m.Groups[3].Value.Split('/'))
    $keep = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $segs.Count - 1; $i++) { [void]$keep.Add($segs[$i]) }
    # the hashed folders under the level (Unreal: two, of one and two characters)
    $cut = 0
    while ($cut -lt 2 -and $keep.Count -gt 1 -and ([string]$keep[$keep.Count - 1]) -match '^[0-9A-Za-z]{1,2}$') { $keep.RemoveAt($keep.Count - 1); $cut++ }
    if ($keep.Count -eq 0) { return $null }
    $lvl = ($keep -join '/')
    return [pscustomobject]@{ Folder = ($m.Groups[1].Value + $lvl); Name = [string]$keep[$keep.Count - 1]; What = $(if ($m.Groups[2].Value -ieq 'Actors') { 'actors' } else { 'objects' }) }
}
# Pending / shelved items split into plain ones and OFPA groups (one per level folder), order kept
function Split-Ofpa($items, [string]$pathProp = 'Path') {
    $plain = New-Object System.Collections.ArrayList
    $groups = [ordered]@{}
    foreach ($it in @($items)) {
        $g = Ofpa-Group ([string]$it.$pathProp)
        if (-not $g) { [void]$plain.Add($it); continue }
        if (-not $groups.Contains($g.Folder)) { $groups[$g.Folder] = [pscustomobject]@{ Folder = $g.Folder; Name = $g.Name; What = $g.What; Items = (New-Object System.Collections.ArrayList) } }
        [void]$groups[$g.Folder].Items.Add($it)
    }
    return [pscustomobject]@{ Plain = $plain; Groups = @($groups.Values) }
}
# "123 files: 120 M, 2 A, 1 D"
function Kinds-Text($items) {
    $n = [ordered]@{}
    foreach ($it in @($items)) { $k = Kind-Letter $it.Kind; if (-not $n.Contains($k)) { $n[$k] = 0 }; $n[$k]++ }
    return ([string]@($items).Count + ' files: ' + (@($n.Keys | ForEach-Object { [string]$n[$_] + ' ' + $_ }) -join ', '))
}

function Kind-Letter([string]$k) {
    switch -regex ($k) { '^[AMDR!]$' { $k.ToUpperInvariant() } '^New|^Add' { 'A' } '^Mod|^Chang' { 'M' } '^Del|^Rem' { 'D' } '^Ren|^Mov' { 'R' } '^Conf' { '!' } default { '?' } }
}

# ---------------------------------------------------------------- changelist store
# Changelists have numbers: #1, #2... never reused ("next" is kept in the file).
$script:NextId = 1
function Load-Db {
    $script:CLs = New-Object System.Collections.ArrayList
    $script:NextId = 1
    $missing = $false
    if ($script:Db -and (Test-Path -LiteralPath $script:Db)) {
        $txt = Get-Content -LiteralPath $script:Db -Raw -Encoding UTF8
        if ($txt -and $txt.Trim()) {
            $j = $txt | ConvertFrom-Json
            if ($j.next) { $script:NextId = [int]$j.next }
            foreach ($c in @($j.changelists)) {
                if ($null -eq $c) { continue }
                $files = New-Object System.Collections.ArrayList
                foreach ($f in @($c.files)) { if ($f) { [void]$files.Add([string]$f) } }
                $id = 0; if ($c.id) { $id = [int]$c.id }
                if ($id -le 0) { $missing = $true } elseif ($id -ge $script:NextId) { $script:NextId = $id + 1 }
                [void]$script:CLs.Add([pscustomobject]@{ id = $id; name = [string]$c.name; desc = [string]$c.desc; branch = [string]$c.branch; files = $files })
            }
        }
    }
    # changelists from older versions get their numbers once
    if ($missing) { foreach ($c in $script:CLs) { if ($c.id -le 0) { $c.id = $script:NextId; $script:NextId++ } }; Save-Db }
}

function New-ClObject([string]$name, [string]$desc) {
    $c = [pscustomobject]@{ id = $script:NextId; name = $name; desc = ([string]$desc).Trim(); branch = (Current-Branch); files = (New-Object System.Collections.ArrayList) }
    $script:NextId++
    return $c
}

# ---- branches: each changelist remembers the branch it was made on (job branches, merged later)
# The branch the workspace is on: last read from Diversion (window / command), else the one saved at the last pause
function Current-Branch {
    if ($script:Branch) { return [string]$script:Branch }
    try { return [string](Read-LastHead).Branch } catch { return '' }
}
# '' = fine; else why this changelist must not be submitted from the current branch
function ClBranch-Problem($c, [string]$current) {
    if ($c -and $c.branch -and $current -and ([string]$c.branch) -ine $current) {
        return ("changelist '" + $c.name + "' was made on branch '" + $c.branch + "', the workspace is on '" + $current + "'. Switch back (dvcl branch switch " + $c.branch + ") or move its files to a changelist of this branch.")
    }
    return ''
}
# Before a branch switch (checked offline, before going online). Pending work is never mixed in silently:
# with pending files it refuses, unless $take (Diversion takes them along). Unreal must be closed.
function Assert-CanSwitch([string]$name, [bool]$take) {
    if (-not $name) { Fail "usage: dvcl branch switch <branch> [--take]" }
    if ((Current-Branch) -ieq $name) { Fail ("already on branch '" + $name + "'") }
    if (Find-UeEngine) { Fail "Unreal is open: close it first (switching branch rewrites the files it has loaded)" }
    $files = @(Get-OfflinePendingOrOnline)
    if ($files.Count -gt 0 -and -not $take) {
        $by = @{}
        foreach ($p in $files) { $o = Owner-Of $p.Path; $k = $(if ($o) { '#' + $o.id + ' ' + $o.name } else { 'default' }); if (-not $by.ContainsKey($k)) { $by[$k] = 0 }; $by[$k]++ }
        Fail ([string]$files.Count + " pending file(s) (" + ((@($by.Keys | Sort-Object | ForEach-Object { $_ + ': ' + $by[$_] })) -join ', ') + "): switching would carry them into '" + $name + "'. Submit or shelve them first (dvcl shelve <cl>), or take them along on purpose: dvcl branch switch " + $name + " --take")
    }
}
# The switch itself (sync on). With $take, Diversion first gets the offline changes, then carries them over.
function Switch-Branch([string]$name, [bool]$take) {
    if ($take) { [void](Wait-Upload) }
    $a = @('checkout', $name, '--ignore-shelf'); if ($take) { $a += '--take-changes' }
    $r = Invoke-Dv $a
    if ($r.Code -ne 0) { Fail ("dv checkout failed: " + ($r.Lines -join ' ')) }
    $script:Branch = $name
    Say ("Workspace now on branch '" + $name + "'.") 'Green'
}
# Branch names of the repository (dv branch lists them), current one marked by Diversion
function Get-Branches { return (Parse-Branches (Invoke-Dv @('branch') $true).Lines) }
function Parse-Branches([string[]]$lines) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($lines)) { if ([string]$l -match '^\W*branch\s+(\S+)') { if (-not $names.Contains($Matches[1])) { $names.Add($Matches[1]) } } }
    return ,$names.ToArray()
}
function Get-OfflinePendingOrOnline {
    if (Test-OfflineFlag) { return (Get-OfflinePending) }
    $st = Get-Pending $false
    if ($st.Paused) { return (Get-OfflinePending) }
    return $st.Files
}

# "#12 description" (or name) for display
function CL-Label($c) { if (-not $c) { return 'default' }; $d = ($c.desc -replace '\s+', ' ').Trim(); if (-not $d) { $d = $c.name }; return ('#' + $c.id + '  ' + $d) }

function Save-Db {
    $out = @()
    foreach ($c in $script:CLs) { $out += [pscustomobject]@{ id = $c.id; name = $c.name; desc = $c.desc; branch = [string]$c.branch; files = @($c.files) } }
    $json = [pscustomobject]@{ next = $script:NextId; changelists = $out } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $script:Db -Value $json -Encoding UTF8
}

# By name, else by number ("12", "#12" or "CL12")
function Find-CL([string]$name) {
    foreach ($c in $script:CLs) { if ($c.name -ieq $name) { return $c } }
    if ($name -match '^(?:#|cl ?)?(\d+)$') { $n = [int]$Matches[1]; foreach ($c in $script:CLs) { if ($c.id -eq $n) { return $c } } }
    return $null
}

function Check-Name([string]$name) {
    if (-not $name) { Fail "missing changelist name" }
    if ($name -notmatch '^[A-Za-z0-9_\-]{1,40}$') { Fail "name '$name': use letters, digits, _ or - (max 40)" }
    if ($name -ieq 'default') { Fail "'default' is reserved (it holds unassigned files)" }
}

# 'ply file' -> 'ply_file' (allowed chars, max 40). Base form, no uniqueness check.
function Slug-Base([string]$s) {
    $n = (([string]$s) -replace '[^A-Za-z0-9_\-]+', '_').Trim('_')
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40).TrimEnd('_') }
    if (-not $n -or $n -ieq 'default') { $n = 'cl' }
    return $n
}

# Slug not used by an existing changelist (adds _2, _3...)
function Unique-Name([string]$s) {
    $base = Slug-Base $s; $n = $base; $i = 2
    while (Find-CL $n) { $suf = '_' + $i; $n = $base.Substring(0, [Math]::Min($base.Length, 40 - $suf.Length)) + $suf; $i++ }
    return $n
}

function Owner-Of([string]$path) { foreach ($c in $script:CLs) { foreach ($f in $c.files) { if ($f -ieq $path) { return $c } } }; return $null }

function Detach([string]$path) {
    foreach ($c in $script:CLs) {
        for ($i = $c.files.Count - 1; $i -ge 0; $i--) { if ($c.files[$i] -ieq $path) { $c.files.RemoveAt($i) } }
    }
}

# Changelist entries are never dropped automatically: dv status can be empty or partial
# (sync paused, agent busy). Entries that are not pending are shown as "not pending";
# Clean-Stale removes them on request. Submit / revert detach their own files.
function Pending-Set($pending) {
    $set = @{}; foreach ($p in $pending) { $set[$p.Path.ToLowerInvariant()] = 1 }
    return $set
}

# Entries of changelist $c that are not in the pending list
function Stale-Of($pending, $c, $set = $null) {
    if ($null -eq $set) { $set = Pending-Set $pending }
    return ,@($c.files | Where-Object { -not $set.ContainsKey(([string]$_).ToLowerInvariant()) })
}

# Removes not-pending entries ($name = one changelist, '' = all). Returns how many.
function Clean-Stale($pending, [string]$name, [bool]$paused) {
    Load-Db   # re-read: another window, the command line or an agent may have changed it
    if ($paused) { Fail "sync is paused: every entry looks not pending. Resume sync first." }
    $set = Pending-Set $pending
    $n = 0
    foreach ($c in $script:CLs) {
        if ($name -and $c.name -ine $name) { continue }
        for ($i = $c.files.Count - 1; $i -ge 0; $i--) {
            if (-not $set.ContainsKey($c.files[$i].ToLowerInvariant())) { Write-Log ("clean " + $c.name + " : " + $c.files[$i]); $c.files.RemoveAt($i); $n++ }
        }
    }
    Save-Db
    Say ("Removed " + $n + " not-pending entr" + $(if ($n -eq 1) { 'y' } else { 'ies' }) + ".") 'Green'
    return $n
}

# Restores entries dropped by the old automatic prune (dvcl 0.2.x logged "prune <cl> : <path>").
# Only paths that are pending now and in no changelist; the latest prune of a path wins.
# $lines: log lines (default: this repo's log). Returns how many entries were restored.
function Recover-Pruned($pending, [string[]]$lines = $null) {
    Load-Db
    if ($null -eq $lines) {
        if (-not $script:Log -or -not (Test-Path -LiteralPath $script:Log)) { Say "No log: nothing to recover." 'Yellow'; return 0 }
        $lines = @(Get-Content -LiteralPath $script:Log -Encoding UTF8)
    }
    $last = [ordered]@{}
    foreach ($l in $lines) {
        if ($l -match '^\[[^\]]+\] prune (\S+) : (.+)$') { $last[$Matches[2].Trim().ToLowerInvariant()] = @($Matches[1], $Matches[2].Trim()) }
    }
    $byPath = @{}; foreach ($p in $pending) { $byPath[$p.Path.ToLowerInvariant()] = $p }
    $n = 0
    foreach ($k in $last.Keys) {
        $p = $byPath[$k]
        if (-not $p -or (Owner-Of $p.Path)) { continue }
        $clName = $last[$k][0]
        if ($clName -notmatch '^[A-Za-z0-9_\-]{1,40}$' -or $clName -ieq 'default') { continue }
        $c = Find-CL $clName
        if (-not $c) { Save-Db; [void](New-CL $clName ''); $c = Find-CL $clName }   # New-CL re-reads the file: save first
        [void]$c.files.Add($p.Path); $n++
        Write-Log ("recover " + $c.name + " : " + $p.Path)
    }
    Save-Db
    Say ("Recovered " + $n + " changelist entr" + $(if ($n -eq 1) { 'y' } else { 'ies' }) + ".") 'Green'
    return $n
}

# Items of one changelist ('default' = unassigned files)
function Get-CLItems($pending, [string]$name) {
    if ($name -ieq 'default') { return ,@($pending | Where-Object { -not (Owner-Of $_.Path) }) }
    return ,@($pending | Where-Object { $o = Owner-Of $_.Path; $o -and $o.name -ieq $name })
}

# Specs: indexes ("3", "5-8"), wildcards (Content/Maps/*), files or folders.
# A spec is also tried under each top-level folder of the pending files,
# so Content/Maps/* matches MyGame/Content/Maps/*.
function Select-Pending($pending, [string[]]$specs) {
    $sel = [ordered]@{}
    foreach ($s in $specs) {
        if (-not $s) { continue }
        $hit = 0
        if ($s -match '^#?(\d+)(?:-(\d+))?$') {
            $a = [int]$Matches[1]; $b = $a; if ($Matches[2]) { $b = [int]$Matches[2] }
            foreach ($p in $pending) { if ($p.Index -ge $a -and $p.Index -le $b) { $sel[$p.Path] = $p; $hit++ } }
        } else {
            $n = Norm $s
            $cands = @($n)
            $first = ($n -split '/')[0]
            $tops = @($pending | ForEach-Object { ($_.Path -split '/')[0] } | Sort-Object -Unique)
            if ($tops -notcontains $first) { foreach ($t in $tops) { $cands += ($t + '/' + $n) } }
            foreach ($p in $pending) {
                foreach ($c in $cands) {
                    $isWild = $c -match '[\*\?]'
                    if (($isWild -and $p.Path -like $c) -or ($p.Path -ieq $c) -or ($p.Path.StartsWith($c + '/', [StringComparison]::OrdinalIgnoreCase))) {
                        $sel[$p.Path] = $p; $hit++; break
                    }
                }
            }
        }
        if ($hit -eq 0) { Say ("  (no pending file matches '" + $s + "')") 'Yellow' }
    }
    return ,@($sel.Values)
}

function Files-For-Commit($items) {
    $list = New-Object System.Collections.ArrayList
    foreach ($p in $items) {
        if ($p.Old) { [void]$list.Add($p.Old) }
        [void]$list.Add($p.Path)
    }
    $len = 0; foreach ($f in $list) { $len += $f.Length + 3 }
    if ($len -gt 28000) { Fail ("command line too long (" + $len + " chars, " + $list.Count + " paths): shelve fewer files at once.") }
    return ,$list.ToArray()
}

# How a submit goes to Diversion. All pending files at once: one "dv commit -a".
# Otherwise batches of paths under the Windows command-line limit (a rename's two paths stay
# together); more than one batch = more than one Diversion commit ("part i/n").
$script:CommitChars = 24000
function Commit-Plan($items, $pending) {
    $items = @($items)
    if ($null -ne $pending) {
        $pp = @($pending | ForEach-Object { $_.Path })
        $ip = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $items) { [void]$ip.Add($p.Path) }
        $allIn = ($pp.Count -gt 0 -and $pp.Count -eq $ip.Count)
        if ($allIn) { foreach ($x in $pp) { if (-not $ip.Contains($x)) { $allIn = $false; break } } }
        if ($allIn) { return [pscustomobject]@{ All = $true; Batches = @([pscustomobject]@{ Items = $items; Files = @() }) } }
    }
    $batches = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList; $curF = New-Object System.Collections.ArrayList; $len = 0
    foreach ($p in $items) {
        $f = @(); if ($p.Old) { $f += $p.Old }; $f += $p.Path
        $add = 0; foreach ($x in $f) { $add += $x.Length + 3 }
        if ($cur.Count -gt 0 -and $len + $add -gt $script:CommitChars) {
            [void]$batches.Add([pscustomobject]@{ Items = $cur.ToArray(); Files = [string[]]$curF.ToArray() })
            $cur = New-Object System.Collections.ArrayList; $curF = New-Object System.Collections.ArrayList; $len = 0
        }
        [void]$cur.Add($p); foreach ($x in $f) { [void]$curF.Add($x) }; $len += $add
    }
    if ($cur.Count -gt 0) { [void]$batches.Add([pscustomobject]@{ Items = $cur.ToArray(); Files = [string[]]$curF.ToArray() }) }
    return [pscustomobject]@{ All = $false; Batches = $batches.ToArray() }
}

# One command line -> arguments, Windows rules: spaces split, "..." groups (quotes removed),
# \" = a quote, "" inside quotes = a quote. dvcl.cmd hands its arguments over this way so that
# any text (parentheses, & ; , : - quotes) reaches dvcl unchanged.
function Split-CmdLine([string]$line) {
    $out = New-Object System.Collections.ArrayList
    $sb = New-Object System.Text.StringBuilder
    $inq = $false; $has = $false; $i = 0; $n = $line.Length
    $bs = [char]92; $dq = [char]34
    while ($i -lt $n) {
        $ch = $line[$i]
        if ($ch -eq $bs) {
            $k = 0; while ($i -lt $n -and $line[$i] -eq $bs) { $k++; $i++ }
            if ($i -lt $n -and $line[$i] -eq $dq) {
                [void]$sb.Append([string]::new($bs, [int][Math]::Floor($k / 2)))
                if ($k % 2 -eq 1) { [void]$sb.Append($dq); $i++ }
            } else { [void]$sb.Append([string]::new($bs, $k)) }
            $has = $true; continue
        }
        if ($ch -eq $dq) {
            if ($inq -and $i + 1 -lt $n -and $line[$i + 1] -eq $dq) { [void]$sb.Append($dq); $i += 2; continue }
            $inq = -not $inq; $has = $true; $i++; continue
        }
        if (-not $inq -and ($ch -eq [char]' ' -or $ch -eq [char]9)) {
            if ($has) { [void]$out.Add($sb.ToString()); [void]$sb.Clear(); $has = $false }
            $i++; continue
        }
        [void]$sb.Append($ch); $has = $true; $i++
    }
    if ($has) { [void]$out.Add($sb.ToString()) }
    return [string[]]$out.ToArray()   # streamed: callers wrap in @()
}

# ---------------------------------------------------------------- operations (shared by CLI and GUI)
function New-CL([string]$name, [string]$desc) {
    Load-Db   # re-read: another window, the command line or an agent may have changed it
    if (-not $name) { $name = $desc }
    if ($name -notmatch '^[A-Za-z0-9_\-]{1,40}$' -or $name -ieq 'default') {
        $new = Unique-Name $name
        Say ("Name '" + $name + "' -> '" + $new + "'") 'Yellow'
        $name = $new
    }
    if (Find-CL $name) { Fail "changelist '$name' already exists" }
    $c = New-ClObject $name $desc
    [void]$script:CLs.Add($c); Save-Db
    Say ("Created changelist #" + $c.id + " '" + $name + "'") 'Green'
    return $c
}

function Set-CLDesc([string]$name, [string]$desc) {
    Load-Db   # re-read: another window, the command line or an agent may have changed it
    $c = Find-CL $name; if (-not $c) { Fail ("no changelist '" + $name + "'") }
    $c.desc = ([string]$desc).Trim(); Save-Db
}

function Remove-CL([string]$name) {
    Load-Db   # re-read: another window, the command line or an agent may have changed it
    $c = Find-CL $name; if (-not $c) { Fail ("no changelist '" + $name + "'") }
    [void]$script:CLs.Remove($c); Save-Db
    Say ("Deleted changelist '" + $c.name + "' (" + $c.files.Count + " file(s) back to default). Nothing was reverted.") 'Green'
}

# Moves pending items to a changelist ('default' = unassign). Creates the changelist if missing.
function Move-ToCL([string]$name, $items) {
    Load-Db   # re-read: another window, the command line or an agent may have changed it
    if ($name -ieq 'default') {
        foreach ($p in $items) { Detach $p.Path }
    } else {
        $c = Find-CL $name
        if (-not $c) { $c = New-CL $name '' }
        foreach ($p in $items) { Detach $p.Path; [void]$c.files.Add($p.Path) }
    }
    Save-Db
    Say ("Moved " + @($items).Count + " file(s) to '" + $name + "'") 'Green'
}

# Commits exactly these items. $clName: the changelist they came from ('default' or a name).
# $pending (optional): the pending list used to pick the items; the changelist is closed
# when none of its remaining entries is pending (its not-pending entries go with it).
function Submit-Items([string]$clName, $items, [string]$desc, $pending = $null) {
    $desc = ([string]$desc).Trim()
    if (-not $desc) { Fail "a description is required to submit" }
    if (@($items).Count -eq 0) { Fail "nothing to submit" }
    $plan = Commit-Plan $items $pending
    $nb = @($plan.Batches).Count
    if ($nb -gt 1) { Say ([string]@($items).Count + ' paths: too many for one command line, submitted as ' + $nb + ' Diversion commits (part i/' + $nb + ').') 'Yellow' }
    $i = 0
    foreach ($b in @($plan.Batches)) {
        $i++
        $m = $desc; if ($nb -gt 1) { $m = $desc + ' (part ' + $i + '/' + $nb + ')' }
        if ($plan.All) { $r = Invoke-Dv @('commit', '-a', '-m', $m) } else { $r = Invoke-Dv (@('commit') + $b.Files + @('-m', $m)) }
        if ($r.Code -ne 0) {
            $done = $(if ($i -gt 1) { ' Parts 1-' + ($i - 1) + ' were submitted; the rest stays in the changelist.' } else { '' })
            Fail ("dv commit failed (exit " + $r.Code + "): " + ($r.Lines -join ' ') + $done)
        }
        # each part leaves the changelist once committed (a later failure keeps only the rest)
        Load-Db
        foreach ($p in @($b.Items)) { Detach $p.Path }
        Save-Db
    }
    Load-Db
    $c = Find-CL $clName
    if ($c) {
        $left = $c.files.Count
        if ($null -ne $pending) { $left = $c.files.Count - (Stale-Of $pending $c).Count }
        if ($left -eq 0) { [void]$script:CLs.Remove($c) }
    }
    Save-Db
    Say ("Submitted " + @($items).Count + " path(s) from '" + $clName + "': " + $desc) 'Green'
}

# Creates a Diversion shelf (sync must be on). Its file list is kept at once (.dvcl\dv-shelf-files).
function Shelve-Items([string]$shelf, $items) {
    if (@($items).Count -eq 0) { Fail "nothing to shelve" }
    if ($shelf.Length -gt 60) { $shelf = $shelf.Substring(0, 60) }
    $r = Invoke-Dv (@('shelf', 'create', $shelf) + (Files-For-Commit $items) + @('--no-reset'))
    if ($r.Code -ne 0) { Fail ("dv shelf create failed (exit " + $r.Code + "): " + ($r.Lines -join ' ')) }
    $id = ''; foreach ($l in $r.Lines) { if ($l -match '(dv\.shelf\.[0-9A-Za-z-]+)') { $id = $Matches[1] } }
    if ($id) { Save-ShelfFiles $id $items }
    Say ("Shelved " + @($items).Count + " path(s) as '" + $shelf + "'. Workspace unchanged.") 'Green'
    return $shelf
}

# A file another program holds open (Unreal keeps loaded assets open): cannot be overwritten now
function Test-Locked([string]$rel) {
    $f = Full-Path $rel
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $false }
    try { $st = [System.IO.File]::Open($f, 'Open', 'ReadWrite', 'None'); $st.Close(); return $false } catch { return $true }
}
# Paths dv reported it could not write ("Cannot write to <path> - file is locked ...")
function Unwritten($lines) {
    $h = @{}
    foreach ($l in @($lines)) { if ([string]$l -match 'Cannot write to (.+?) - ') { $p = Norm $Matches[1]; if ($p -notlike '.diversion*') { $h[$p.ToLowerInvariant()] = $p } } }
    return @($h.Values)
}
function File-Hash([string]$rel) { $f = Full-Path $rel; if (Test-Path -LiteralPath $f -PathType Leaf) { return (Get-FileHash -LiteralPath $f -Algorithm MD5).Hash }; return '' }

# Your version of each file, copied before a revert: .dvcl\revert-backup\<time>\<path> (last 10 kept)
function Backup-Local($items) {
    $base = [System.IO.Path]::Combine($script:Root, '.dvcl', 'revert-backup')
    $dir = Join-Path $base (Get-Date -Format 'yyyyMMdd-HHmmss')
    foreach ($p in @($items)) {
        $src = Full-Path $p.Path
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = [System.IO.Path]::Combine([string[]](@($dir) + ($p.Path -split '/')))
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    $old = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 10)
    foreach ($o in $old) { Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    return $dir
}

# Discards local changes (dv restore from the workspace base commit). Sync must be on. Nothing else
# goes to Diversion: your versions are copied to .dvcl\revert-backup first (this PC only).
# New files are skipped (nothing to restore). Files another program holds open are not touched and
# are reported; any file dv could not write stays pending. Returns the backup folder.
function Revert-Items([string]$prefix, $items) {
    $toRestore = @($items | Where-Object { (Kind-Letter $_.Kind) -ne 'A' })
    foreach ($p in @($items | Where-Object { (Kind-Letter $_.Kind) -eq 'A' })) { Say ("   skip (new file, nothing to revert): " + $p.Path) 'Yellow' }
    $locked = @($toRestore | Where-Object { Test-Locked $_.Path })
    foreach ($p in $locked) { Say ("   NOT reverted (open in Unreal or another program): " + $p.Path) 'Red' }
    $toRestore = @($toRestore | Where-Object { $locked -notcontains $_ })
    if ($toRestore.Count -eq 0) { Fail $(if ($locked.Count) { "nothing reverted: close those files (in Unreal: unload or close the level/asset), then revert again" } else { "nothing revertable (only new files)" }) }
    $dir = Backup-Local $toRestore
    $ok = 0; $bad = New-Object System.Collections.ArrayList
    foreach ($p in $toRestore) {
        $before = File-Hash $p.Path
        $r = Invoke-Dv @('restore', $p.Path)
        $un = Unwritten $r.Lines
        if ($r.Code -ne 0 -or $un.Count -gt 0 -or ((File-Hash $p.Path) -eq $before -and (Kind-Letter $p.Kind) -ne 'D')) {
            [void]$bad.Add($p.Path); Say ("   NOT reverted: " + $p.Path + $(if ($un.Count) { '  (file in use)' } elseif ($r.Code -ne 0) { '  -> ' + ($r.Lines -join ' ') } else { '  (file unchanged)' })) 'Red'
        } else { Detach $p.Path; $ok++; Say ("   reverted: " + $p.Path) }
    }
    Save-Db
    Say ("Reverted " + $ok + " path(s). Your versions were copied to " + $dir) $(if ($bad.Count + $locked.Count) { 'Yellow' } else { 'Green' })
    if ($bad.Count + $locked.Count) { Fail ([string]($bad.Count + $locked.Count) + " path(s) not reverted (listed above); they stay pending.") }
    return $dir
}

# ---- Unreal link: the open editor of this workspace releases the files dvcl is about to write and
# reloads them after (the dvcl link plugin, ue\install.cmd; reached by Python remote execution).
function Find-UeEngine {
    $p = @(Get-Process UnrealEditor -ErrorAction SilentlyContinue | Where-Object { $_.Path })
    if ($p.Count -eq 0) { return $null }
    return (Split-Path (Split-Path (Split-Path (Split-Path $p[0].Path))))
}
$script:PyCmd = $null
function Find-Python {
    if ($script:PyCmd) { return $script:PyCmd }
    foreach ($c in @(@('py', '-3'), @('python'))) {
        try { $null = & $c[0] @($c | Select-Object -Skip 1) --version 2>&1; if ($LASTEXITCODE -eq 0) { $script:PyCmd = $c; return $c } } catch {}
    }
    return $null
}
# Runs Python in the editor. State: ok, noeditor, nopython, nolink (plugin missing), fail
function Invoke-Ue([string]$code) {
    $eng = Find-UeEngine
    if (-not $eng) { return [pscustomobject]@{ Ok = $false; State = 'noeditor'; Lines = @() } }
    $py = Find-Python
    if (-not $py) { return [pscustomobject]@{ Ok = $false; State = 'nopython'; Lines = @() } }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dvcl-ue-' + [guid]::NewGuid().ToString('N') + '.py')
    [System.IO.File]::WriteAllText($tmp, $code, $script:Utf8)
    $pyArgs = @(@($py | Select-Object -Skip 1) + @((Join-Path $PSScriptRoot 'dvcl_ue.py'), $eng, $script:Root, $tmp, '6'))
    $pyExe = $(if ($script:PumpUi) { @(Get-Command $py[0] -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -like '*.exe' } | Select-Object -First 1) } else { @() })
    try {
        if ($pyExe.Count) { $pr = Invoke-Pumped $pyExe[0].Source $pyArgs $script:Root; $o = @($pr.Lines | Where-Object { $_ -ne '' }); $code2 = $pr.Code }
        else { $o = @(& $py[0] @pyArgs 2>&1 | ForEach-Object { [string]$_ }); $code2 = $LASTEXITCODE }
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    foreach ($l in $o) { Write-Log ('  ue | ' + $l) }
    $st = $(if ($code2 -eq 0) { 'ok' } elseif ($code2 -eq 2) { 'noeditor' } else { 'fail' })
    if ($o -contains 'DVCL nolink') { $st = 'nolink' }
    return [pscustomobject]@{ Ok = ($st -eq 'ok'); State = $st; Lines = $o }
}
# Python for one dvcl link call on these workspace files (full paths, JSON = valid Python literals)
function Ue-Code([string]$fn, [string[]]$rels) {
    $abs = @($rels | ForEach-Object { (Full-Path $_) -replace '\\', '/' })
    $list = ConvertTo-Json -Compress -InputObject ([string[]]$abs)
    return ("import unreal`nif not hasattr(unreal, 'DvclLinkLibrary'):`n    print('DVCL nolink')`nelse:`n    print(unreal.DvclLinkLibrary." + $fn + "(" + $list + "))")
}
# Before writing files: the editor lets go of them. Unsaved = assets with unsaved changes in Unreal
# (then nothing was released). Released = files it let go of.
function Ue-Release([string[]]$rels) {
    $r = Invoke-Ue (Ue-Code 'release_files' $rels)
    $uns = @(); $rel = @()
    foreach ($l in $r.Lines) {
        if ($l -match '^unsaved (.+)$') { $uns += (Norm $Matches[1]) }
        elseif ($l -match '^released (.+)$') { $rel += (Norm $Matches[1]) }
    }
    return [pscustomobject]@{ State = $r.State; Unsaved = $uns; Released = $rel }
}
function Ue-Reload([string[]]$rels) { if (@($rels).Count) { [void](Invoke-Ue (Ue-Code 'reload_files' $rels)) } }

# Files changed in the commits newer than the workspace's (what Get latest will write)
function Incoming-Files([string]$wsCommit) {
    $ws = Commit-Num $wsCommit
    if ($ws -le 0) { return @() }
    $r = Invoke-Dv @('log', '-n', '200', '--date', 'iso') $true
    $h = @{}
    foreach ($c in @(Parse-Log $r.Lines | Where-Object { $_.Num -gt $ws })) {
        $s = Invoke-Dv @('show', $c.Id, '--name-status', '--color', 'never') $true
        foreach ($f in @(Parse-ShowFiles $s.Lines)) { $h[$f.Path.ToLowerInvariant()] = $f.Path }
    }
    return @($h.Values)
}

# ---- Diversion shelf contents: `dv shelf show` (works with sync paused), kept per shelf in
# .dvcl\dv-shelf-files\<id>.tsv (a shelf never changes)
function Shelf-FilesFile([string]$id) { return [System.IO.Path]::Combine($script:Root, '.dvcl', 'dv-shelf-files', (($id -replace '[^\w.-]', '_') + '.tsv')) }
function Save-ShelfFiles([string]$id, $items) {
    $f = Shelf-FilesFile $id
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($f))
    $lines = @(@($items) | ForEach-Object { (Kind-Letter $_.Kind) + "`t" + $_.Path + "`t" + [string]$_.Old })
    [System.IO.File]::WriteAllLines($f, [string[]]$lines, $script:Utf8)
}
function Read-ShelfFiles([string]$id) {
    $f = Shelf-FilesFile $id
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $res = New-Object System.Collections.ArrayList
    foreach ($l in [System.IO.File]::ReadAllLines($f)) { $x = $l.Split("`t"); if ($x.Count -ge 2 -and $x[1]) { [void]$res.Add([pscustomobject]@{ Kind = $x[0]; Path = $x[1]; Old = $(if ($x.Count -gt 2 -and $x[2]) { $x[2] } else { $null }) }) } }
    return ,$res.ToArray()
}
# From dv (and kept); $null when dv did not answer
function Fetch-ShelfFiles([string]$id) {
    $r = Invoke-Dv @('shelf', 'show', $id) $true
    if ($r.Code -ne 0) { return $null }
    $items = Parse-Status $r.Lines
    Save-ShelfFiles $id $items
    return ,$items
}

# Unshelves a Diversion shelf (sync must be on). $only: just these paths, the shelf's other files are
# put back as they were (dv applies a whole shelf). Refuses if a file it would write is open in
# another program. Returns the unshelved items.
function Apply-DvShelf($sh, [string[]]$only) {
    $files = Read-ShelfFiles $sh.Id; if ($null -eq $files) { $files = Fetch-ShelfFiles $sh.Id }
    if ($null -eq $files) { Fail "could not read the shelf's files (dv shelf show)" }
    $want = @($files); if ($only) { $want = @($files | Where-Object { $only -icontains $_.Path }) }
    $locked = @($files | Where-Object { Test-Locked $_.Path } | ForEach-Object { $_.Path })
    if ($locked.Count) { Fail ("open in Unreal or another program, close them first (nothing unshelved): " + ($locked -join ', ')) }
    # the shelf's other files: keep their current state
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dvcl-unshelve-' + [guid]::NewGuid().ToString('N'))
    $keep = @($files | Where-Object { $want -notcontains $_ })
    $absent = @{}
    foreach ($k in $keep) {
        $src = Full-Path $k.Path
        if (Test-Path -LiteralPath $src -PathType Leaf) { $dst = [System.IO.Path]::Combine([string[]](@($tmp) + ($k.Path -split '/'))); [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst)); Copy-Item -LiteralPath $src -Destination $dst -Force }
        else { $absent[$k.Path] = 1 }
    }
    try {
        Apply-Shelf $sh.Id
        foreach ($k in $keep) {
            $f = Full-Path $k.Path
            if ($absent.ContainsKey($k.Path)) { if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force } }
            else { Copy-Item -LiteralPath ([System.IO.Path]::Combine([string[]](@($tmp) + ($k.Path -split '/')))) -Destination $f -Force }
        }
        # the shelf's other files were put back: Diversion's list from before that is out of date
        if ($keep.Count) { $script:SyncedSt = $null }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
    if ($only) { Say ("Unshelved " + $want.Count + " of " + @($files).Count + " file(s); the others were left as they were.") 'Green' }
    return ,$want
}

# Parses `dv shelf` output into objects { Name; Id; Created }
function Get-Shelves {
    $r = Invoke-Dv @('shelf')
    if ($r.Code -ne 0) { Fail ("dv shelf failed: " + ($r.Lines -join ' ')) }
    return (Read-Shelves $r.Lines)
}

# `dv shelf` lines -> { Name; Id; Created; Local = $false; Count = -1 (unknown) }
function Read-Shelves([string[]]$lines) {
    $res = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($l in $lines) {
        if ($l -match '^\s*shelf\s+(.+?)\s+\((dv\.shelf\.[^)]+)\)') {
            $cur = [pscustomobject]@{ Name = $Matches[1]; Id = $Matches[2]; Created = ''; Local = $false; Count = -1; Cl = ''; Files = @() }
            [void]$res.Add($cur)
        } elseif ($cur -and $l -match '^\s*Created:\s*(.+)$') { $cur.Created = $Matches[1].Trim() }
    }
    $res.ToArray()   # streamed: @(Read-Shelves ...) = one row per shelf
}

function Apply-Shelf([string]$shelf) {
    $r = Invoke-Dv @('shelf', 'apply', $shelf, '--keep', '-f')
    if ($r.Code -ne 0) { Fail ("dv shelf apply failed: " + ($r.Lines -join ' ')) }
    $un = Unwritten $r.Lines
    if ($un.Count) { Fail ("dv could not write (file in use): " + ($un -join ', ')) }
    # dv returns before the agent has rewritten the files: wait until Diversion reports its sync done
    # (the files are then on disk), instead of a fixed pause
    $script:SyncedSt = Get-Pending $true; $script:SyncedAt = Get-Date
    Say ("Applied shelf '" + $shelf + "' (shelf kept).") 'Green'
}

function Delete-Shelf([string]$shelf) {
    $r = Invoke-Dv @('shelf', 'delete', $shelf, '-f')
    if ($r.Code -ne 0) { Fail ("dv shelf delete failed: " + ($r.Lines -join ' ')) }
    Say ("Deleted shelf '" + $shelf + "'.") 'Green'
}

# ---------------------------------------------------------------- offline mode
# Files in <repo>\.dvcl:  offline.flag (set by dvcl when it pauses sync), baseline.tsv (folder snapshot
# taken when going offline), last-status.tsv (last pending list read online), shelves\ (local shelves).
function Dvcl-File([string]$name) { return [System.IO.Path]::Combine($script:Root, '.dvcl', $name) }
function Full-Path([string]$rel) { if (-not $rel) { return $script:Root }; return [System.IO.Path]::Combine([string[]](@($script:Root) + @($rel.Split('/')))) }
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

# Does Diversion know this folder as a workspace? ok | nodv (dv not installed) | notrepo | error: <text>
function Test-DvWorkspace([string]$root) {
    if (-not (Get-Command dv -ErrorAction SilentlyContinue)) { return 'nodv' }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $root
    try { $out = @(& dv status --nowait 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    catch { return 'nodv' }
    finally { Pop-Location; $ErrorActionPreference = $prev }
    $t = ($out -join ' ')
    if ($t -match 'not a diversion repository') { return 'notrepo' }
    if ($code -ne 0) { return ('error: ' + (@($out | Where-Object { $_.Trim() }) | Select-Object -First 1)) }
    return 'ok'
}
# Diversion workspaces on this PC: folders with a .diversion folder, two levels under each fixed
# drive, the user folder and Documents (the user folder itself is Diversion's settings, skipped)
function Find-Workspaces {
    $res = New-Object System.Collections.ArrayList
    $prof = ([string]$env:USERPROFILE).TrimEnd('\')
    $skip = @('windows', 'program files', 'program files (x86)', 'programdata', '$recycle.bin', 'system volume information', 'appdata', 'recovery', 'perflogs', 'node_modules', '.git')
    $roots = @(); foreach ($dr in [System.IO.DriveInfo]::GetDrives()) { try { if ($dr.DriveType -eq 'Fixed' -and $dr.IsReady) { $roots += $dr.RootDirectory.FullName } } catch {} }
    $roots += @($prof, [Environment]::GetFolderPath('MyDocuments'))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($r in $roots) {
        $level = @($r)
        for ($depth = 0; $depth -lt 3 -and $sw.ElapsedMilliseconds -lt 4000; $depth++) {
            $next = @()
            foreach ($dir in $level) {
                if ($depth -gt 0 -and $dir.TrimEnd('\') -ine $prof -and (Test-Path -LiteralPath (Join-Path $dir '.diversion') -PathType Container)) {
                    if (-not ($res -icontains $dir)) { [void]$res.Add($dir) }; continue
                }
                if ($depth -lt 2) { try { foreach ($s in [System.IO.Directory]::GetDirectories($dir)) { if ($skip -notcontains ([System.IO.Path]::GetFileName($s)).ToLowerInvariant() -and -not ([System.IO.Path]::GetFileName($s)).StartsWith('.')) { $next += $s } } } catch {} }
            }
            $level = $next
        }
    }
    return ,$res
}

# Pending files for Unreal's "dvcl" revision control (dvcl link): .dvcl\pending.tsv, one line per file:
# <kind letter> TAB <path> TAB <changelist>. Rewritten only when it changes (Unreal re-reads it then).
function Write-PendingFile($pending) {
    if (-not $script:Root) { return }
    try {
        $own = @{}
        foreach ($c in $script:CLs) { foreach ($f in $c.files) { $own[[string]$f.ToLowerInvariant()] = '#' + $c.id + ' ' + $c.name } }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("#dvcl-pending1`n")
        foreach ($p in @($pending)) {
            $cl = $own[[string]$p.Path.ToLowerInvariant()]; if (-not $cl) { $cl = 'default' }
            [void]$sb.Append((Kind-Letter $p.Kind) + "`t" + $p.Path + "`t" + $cl + "`n")
        }
        $text = $sb.ToString()
        if ($text -eq $script:PendingFileText) { return }
        $f = Dvcl-File 'pending.tsv'; $tmp = $f + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $text, $script:Utf8)
        Move-Item -LiteralPath $tmp -Destination $f -Force
        $script:PendingFileText = $text
    } catch { Write-Log ('pending.tsv not written: ' + $_.Exception.Message) }
}

function Test-OfflineFlag { return (Test-Path -LiteralPath (Dvcl-File 'offline.flag')) }

# ---------------------------------------------------------------- stay offline (safety)
# On by default: sync is never left on. dvcl goes online only for an action (submit, shelve, revert,
# unshelve, get latest) and pauses again after it. .dvcl\online.json says which dvcl has sync on;
# if that process is gone (killed, crashed) or holds it too long, or sync was turned on elsewhere,
# the next dvcl (window every 15 s, any command at start) pauses it at once.
# Off: .dvcl\allow-online.flag (dvcl safety off).
function Safety-On { return -not (Test-Path -LiteralPath (Dvcl-File 'allow-online.flag')) }
function Set-Safety([bool]$on) {
    $f = Dvcl-File 'allow-online.flag'
    if ($on) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    else { [System.IO.File]::WriteAllText($f, (Get-Date -Format s), $script:Utf8) }
}
# .dvcl\online.json: which dvcl turned sync on (pid), for what, since when, last sign of life (at)
function Write-OnlineMark([string]$since = '') {
    if (-not $since) { $since = (Get-Date -Format s) }
    $what = $(if ($script:OnlineWhat) { $script:OnlineWhat } elseif ($script:OpTitle) { $script:OpTitle } else { 'dvcl' })
    try { [System.IO.File]::WriteAllText((Dvcl-File 'online.json'), ([pscustomobject]@{ pid = $PID; at = (Get-Date -Format s); since = $since; what = $what } | ConvertTo-Json -Compress), $script:Utf8) } catch {}
}
# another dvcl, still running, that has sync on for an action (mark fresh): $null if none
function Get-OtherOnline {
    $m = Read-OnlineMark
    if (-not $m) { return $null }
    $p = 0; try { $p = [int]$m.pid } catch {}
    if ($p -le 0 -or $p -eq $PID) { return $null }
    if (-not (Get-Process -Id $p -ErrorAction SilentlyContinue)) { return $null }
    $age = 999; try { $age = ((Get-Date) - [datetime]$m.at).TotalMinutes } catch {}
    if ($age -ge 90) { return $null }
    if (-not $m.what) { $m | Add-Member -NotePropertyName what -NotePropertyValue 'dvcl' -Force }
    return $m
}
# keeps our own mark fresh during a long online action (others pause sync only when it is old)
function Touch-OnlineMark {
    $m = Read-OnlineMark
    if ($m -and [int]$m.pid -eq $PID) { Write-OnlineMark ([string]$m.since) }
}
# Big uploads: polls "dv status --nowait" until Diversion shows no transfer lines, instead of one
# "dv status" that waits without a word and can be cut. Keeps the online mark fresh, so other dvcl
# windows / commands see the upload as alive and do not pause sync under it. Ends with the waited list.
function Wait-Upload([int]$maxMin = 300) {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = -1
    while ($true) {
        Touch-OnlineMark
        $r = Invoke-Dv (Status-Args $false) $true $true
        $st = Read-Status $r
        if ($st.Paused) { Write-Log 'upload wait: sync is paused'; return $st }
        if (-not $r.Upload) { break }
        $min = [int][Math]::Floor($sw.Elapsed.TotalMinutes)
        if ($min -ne $last) { $last = $min; Say ("Diversion is still uploading (" + $min + " min): " + $r.Upload.Trim()) 'Gray'; Write-Log ('upload wait: ' + $min + ' min: ' + $r.Upload.Trim()) }
        if ($sw.Elapsed.TotalMinutes -ge $maxMin) { Fail ("Diversion was still uploading after " + $maxMin + " min: nothing submitted. Run the submit again later (the upload goes on from where it is).") }
        Start-Sleep -Seconds 15
    }
    Write-Log ('upload wait: done after ' + [int]$sw.Elapsed.TotalSeconds + ' s')
    Touch-OnlineMark
    return (Get-Pending $true)
}
function Clear-OnlineMark { $f = Dvcl-File 'online.json'; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
function Read-OnlineMark {
    $f = Dvcl-File 'online.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) } catch { return [pscustomobject]@{ pid = 0; at = '' } }
}
# Pause now, without waiting for uploads to finish (the pending list is read as it is)
function Pause-Now([string]$why) {
    $r = Invoke-Dv @('workspace', 'pause')
    if ($r.Code -ne 0 -and ($r.Lines -join ' ') -notmatch 'already') { Fail ("dv workspace pause failed: " + ($r.Lines -join ' ')) }
    $st = Get-Pending $false
    Write-Baseline $st.Files $st.Commit $false
    if ($st.Branch) { Save-LastHead $st.Branch $st.Commit }
    Set-OfflineFlag $true; Clear-OnlineMark
    Say ("Stay offline: sync paused (" + $why + ").") 'Yellow'
}
# $busy: this process is in an action that went online itself. $deep: also ask Diversion when dvcl
# thinks it is online (start of the window / of a command). Returns what it did ('' = nothing).
function Safety-Check([bool]$busy, [bool]$deep, [int]$maxMinutes = 90) {
    if (-not (Safety-On)) { return '' }
    $m = Read-OnlineMark
    if ($m) {
        $p = [int]$m.pid
        $alive = ($p -gt 0) -and [bool](Get-Process -Id $p -ErrorAction SilentlyContinue)
        $age = 0; try { $age = ((Get-Date) - [datetime]$m.at).TotalMinutes } catch {}
        if ($p -eq $PID -and $busy) { return '' }
        if ($alive -and $p -ne $PID -and $age -lt $maxMinutes) { return '' }
        $why = $(if (-not $alive) { 'left on by a dvcl that stopped' } elseif ($p -eq $PID) { 'left on after an action' } else { 'on for more than ' + $maxMinutes + ' min' })
        Pause-Now $why; return $why
    }
    if ($deep -and -not (Test-OfflineFlag)) {
        $st = Get-Pending $false
        if (-not $st.Paused) { Pause-Now 'sync was on'; return 'sync was on' }
        Set-OfflineFlag $true
    }
    return ''
}
function Set-OfflineFlag([bool]$on) {
    $f = Dvcl-File 'offline.flag'
    if ($on) { [System.IO.File]::WriteAllText($f, (Get-Date -Format s), $script:Utf8) }
    elseif (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
}

# Ignore files, read like Diversion's default matcher: .dvignore and .gitignore in any folder,
# rules relative to that folder. "/x" = only at that folder; anything else matches at any depth
# below it (so "Saved/*" also hides MyGame/Saved/...). Trailing / = folders only.
# * and ? stay inside one folder name, ** crosses folders. A rule matching a folder hides what is in
# it; "!x" brings back what an earlier rule hid, even inside a hidden folder; the last rule that
# matches wins (as Diversion does online). Same rules in the compiled scanner (ScanSource): change both.
$script:IgnoreLogged = @{}
$script:IgnoreMatcher = 'm2'
function Ignore-Regex([string]$p, [bool]$anch) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $p.Length) {
        $c = $p[$i]
        if ($c -eq [char]'*') {
            if ($i + 1 -lt $p.Length -and $p[$i + 1] -eq [char]'*') {
                if ($i + 2 -lt $p.Length -and $p[$i + 2] -eq [char]'/') { [void]$sb.Append('(?:.*/)?'); $i += 3; continue }
                [void]$sb.Append('.*'); $i += 2; continue
            }
            [void]$sb.Append('[^/]*')
        }
        elseif ($c -eq [char]'?') { [void]$sb.Append('[^/]') }
        elseif ($c -eq [char]'[') {
            $j = $p.IndexOf(']', $i + 1)
            if ($j -gt $i + 1) {
                $cls = $p.Substring($i + 1, $j - $i - 1).Replace('\', '\\')
                if ($cls.StartsWith('!')) { $cls = '^' + $cls.Substring(1) }
                [void]$sb.Append('[' + $cls + ']'); $i = $j + 1; continue
            }
            [void]$sb.Append('\[')
        }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
        $i++
    }
    $pre = '^(?:.*/)?'; if ($anch) { $pre = '^' }
    return New-Object System.Text.RegularExpressions.Regex (($pre + $sb.ToString() + '$'), ([System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'))
}
function New-IgnoreRule([string]$p, [bool]$dirOnly, [bool]$anch, [bool]$neg, [string]$base) {
    $full = $p; if ($base) { $full = $base + '/' + $p }
    $w = $full.IndexOfAny([char[]]@('*', '?', '[')); $pre = $full; if ($w -ge 0) { $pre = $full.Substring(0, $w) }
    return [pscustomobject]@{ P = $p; DirOnly = $dirOnly; Anchored = $anch; Neg = $neg; Base = $base; R = (Ignore-Regex $p $anch); Prefix = $pre }
}
function Read-IgnoreFiles([string]$dirRel) {
    $rules = New-Object System.Collections.ArrayList
    foreach ($fn in @('.gitignore', '.dvignore')) {
        $f = Full-Path $(if ($dirRel) { $dirRel + '/' + $fn } else { $fn })
        if (-not [System.IO.File]::Exists($f)) { continue }
        foreach ($l in [System.IO.File]::ReadAllLines($f)) {
            $t = $l.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $neg = $t.StartsWith('!'); if ($neg) { $t = $t.Substring(1).Trim() }
            $dirOnly = $t.EndsWith('/')
            $t = ($t -replace '\\', '/').TrimEnd('/')
            $anch = $t.StartsWith('/')
            $t = $t.TrimStart('/')
            if ($t) { [void]$rules.Add((New-IgnoreRule $t $dirOnly $anch $neg $dirRel)) }
        }
        if (-not $script:IgnoreLogged.ContainsKey($f)) {
            $script:IgnoreLogged[$f] = 1
            Write-Log ("ignore file " + $(if ($dirRel) { $dirRel + '/' } else { '' }) + $fn + ": " + (@($rules | Where-Object { $_.Base -eq $dirRel } | ForEach-Object { $(if ($_.Neg) { '!' } else { '' }) + $(if ($_.Anchored) { '/' } else { '' }) + $_.P + $(if ($_.DirOnly) { '/' } else { '' }) }) -join '  '))
        }
    }
    return ,$rules.ToArray()
}

# Root rules + always-ignored dvcl / Diversion folders (kept for callers and tests)
function Read-Ignore {
    $fixed = @((New-IgnoreRule '.diversion' $false $true $false ''), (New-IgnoreRule '.dvcl' $false $true $false ''))
    $fromFiles = Read-IgnoreFiles ''
    return ,(@($fixed) + @($fromFiles))
}

# Diversion's matcher (same as the compiled scanner): a rule hides an entry when it matches the entry
# or one of its folders, the last matching rule wins, a "!" rule can bring back a file inside a hidden
# folder. $hit[i] = rule i matches the entry or a folder above it.
function Test-RuleHit($r, [string]$rel, [bool]$isDir) {
    if ($r.DirOnly -and -not $isDir) { return $false }
    $sub = $rel
    if ($r.Base) { if ($rel.Length -le $r.Base.Length) { return $false }; $sub = $rel.Substring($r.Base.Length + 1) }
    return $r.R.IsMatch($sub)
}
function Test-LastHit($rules, [bool[]]$hit) {
    for ($k = $rules.Count - 1; $k -ge 0; $k--) { if ($hit[$k]) { return (-not $rules[$k].Neg) } }
    return $false
}
function Test-CouldBringBack([string]$dir, $rules) {
    $d = $dir + '/'
    foreach ($r in $rules) {
        if (-not $r.Neg) { continue }
        if (-not $r.Anchored) { return $true }
        if ($r.Prefix.StartsWith($d, [StringComparison]::OrdinalIgnoreCase) -or $d.StartsWith($r.Prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
# One path checked on its own (its folders evaluated too): $true = hidden
function Test-Ignored([string]$rel, [string]$name, [bool]$isDir, $rules) {
    $parts = $rel.Split('/'); $hit = New-Object 'bool[]' $rules.Count; $cur = ''
    for ($n = 0; $n -lt $parts.Count; $n++) {
        if ($cur) { $cur += '/' + $parts[$n] } else { $cur = $parts[$n] }
        $d = $isDir -or $n -lt $parts.Count - 1
        for ($k = 0; $k -lt $rules.Count; $k++) { if (-not $hit[$k] -and (Test-RuleHit $rules[$k] $cur $d)) { $hit[$k] = $true } }
    }
    return (Test-LastHit $rules $hit)
}

# Snapshot of the workspace: rel path -> "size|ticks" for files, "D" for folders (ignored ones skipped).
# Compiled scanner (same rules as Scan-WorkspacePs, ~20x faster); falls back to PowerShell if it cannot load.
function Scan-Workspace {
    if (Ensure-Scanner) {
        $logs = $null
        $res = [DvclNative.Scanner]::Scan($script:Root, [ref]$logs)
        foreach ($l in $logs) { if (-not $script:IgnoreLogged.ContainsKey($l)) { $script:IgnoreLogged[$l] = 1; Write-Log $l } }
        return ,$res
    }
    return (Scan-WorkspacePs)
}

$script:ScanSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
namespace DvclNative {
  public static class Scanner {
    class Rule { public Regex R; public bool DirOnly; public bool Neg; public bool Anchored; public string Base; public string Prefix; }
    // same conversion as Ignore-Regex: * ? inside one name, ** across folders, [..] kept
    static Regex ToRegex(string p, bool anchored) {
      var sb = new StringBuilder();
      int i = 0;
      while (i < p.Length) {
        char c = p[i];
        if (c == '*') {
          if (i + 1 < p.Length && p[i + 1] == '*') {
            if (i + 2 < p.Length && p[i + 2] == '/') { sb.Append("(?:.*/)?"); i += 3; continue; }
            sb.Append(".*"); i += 2; continue;
          }
          sb.Append("[^/]*");
        }
        else if (c == '?') sb.Append("[^/]");
        else if (c == '[') {
          int j = p.IndexOf(']', i + 1);
          if (j > i + 1) {
            var cls = p.Substring(i + 1, j - i - 1).Replace("\\", "\\\\");
            if (cls.StartsWith("!")) cls = "^" + cls.Substring(1);
            sb.Append("[" + cls + "]"); i = j + 1; continue;
          }
          sb.Append("\\[");
        }
        else sb.Append(Regex.Escape(c.ToString()));
        i++;
      }
      return new Regex((anchored ? "^" : "^(?:.*/)?") + sb.ToString() + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }
    static Rule Make(string p, bool dirOnly, bool anchored, bool neg, string bas) {
      var full = bas.Length > 0 ? bas + "/" + p : p;
      int w = full.IndexOfAny(new[] { '*', '?', '[' });
      return new Rule { R = ToRegex(p, anchored), DirOnly = dirOnly, Neg = neg, Anchored = anchored, Base = bas, Prefix = w < 0 ? full : full.Substring(0, w) };
    }
    static string Full(string root, string rel) { return rel.Length == 0 ? root : Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar)); }
    // .gitignore + .dvignore of one folder, rules relative to it (same parsing as Read-IgnoreFiles)
    static List<Rule> ReadIgnore(string root, string rel, List<string> log) {
      var res = new List<Rule>();
      foreach (var fn in new[] { ".gitignore", ".dvignore" }) {
        var f = Path.Combine(Full(root, rel), fn);
        if (!File.Exists(f)) continue;
        var shown = new List<string>();
        foreach (var l0 in File.ReadAllLines(f)) {
          var t = l0.Trim();
          if (t.Length == 0 || t.StartsWith("#")) continue;
          bool neg = t.StartsWith("!"); if (neg) t = t.Substring(1).Trim();
          bool dirOnly = t.EndsWith("/");
          t = t.Replace('\\', '/').TrimEnd('/');
          bool anch = t.StartsWith("/");
          t = t.TrimStart('/');
          if (t.Length == 0) continue;
          res.Add(Make(t, dirOnly, anch, neg, rel));
          shown.Add((neg ? "!" : "") + (anch ? "/" : "") + t + (dirOnly ? "/" : ""));
        }
        log.Add("ignore file " + (rel.Length > 0 ? rel + "/" : "") + fn + ": " + string.Join("  ", shown));
      }
      return res;
    }
    // Diversion's matcher: a rule hides an entry when it matches the entry or one of its folders, the
    // last matching rule wins, and a "!" rule can bring back a file inside a hidden folder. So a hidden
    // folder is still entered when a "!" rule could match below it (else skipped: Saved, caches...).
    // Hit[i] = rule i matches this entry or a folder above it (inherited from the parent).
    static bool Matches(Rule r, string rel, bool isDir) {
      if (r.DirOnly && !isDir) return false;
      var sub = rel;
      if (r.Base.Length > 0) { if (rel.Length <= r.Base.Length) return false; sub = rel.Substring(r.Base.Length + 1); }
      return r.R.IsMatch(sub);
    }
    static bool Last(List<Rule> rules, bool[] hit) {
      for (int k = rules.Count - 1; k >= 0; k--) if (hit[k]) return !rules[k].Neg;
      return false;
    }
    static bool CouldBringBack(string dir, List<Rule> rules) {
      var d = dir + "/";
      foreach (var r in rules) {
        if (!r.Neg) continue;
        if (!r.Anchored) return true;
        if (r.Prefix.StartsWith(d, StringComparison.OrdinalIgnoreCase) || d.StartsWith(r.Prefix, StringComparison.OrdinalIgnoreCase)) return true;
      }
      return false;
    }
    class Frame { public string Rel; public List<Rule> Rules; public bool[] Hit; public bool Hidden; }
    public static Dictionary<string, string> Scan(string root, out string[] logOut) {
      var log = new List<string>();
      var res = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
      var rootRules = new List<Rule> { Make(".diversion", false, true, false, ""), Make(".dvcl", false, true, false, "") };
      rootRules.AddRange(ReadIgnore(root, "", log));
      var stack = new Stack<Frame>();
      stack.Push(new Frame { Rel = "", Rules = rootRules, Hit = new bool[rootRules.Count], Hidden = false });
      while (stack.Count > 0) {
        var top = stack.Pop(); var rel = top.Rel; var rules = top.Rules; var hit = top.Hit;
        if (rel.Length > 0 && !top.Hidden) {
          var more = ReadIgnore(root, rel, log);
          if (more.Count > 0) { rules = new List<Rule>(rules); rules.AddRange(more); var h2 = new bool[rules.Count]; Array.Copy(hit, h2, hit.Length); hit = h2; }
        }
        try {
          foreach (var i in new DirectoryInfo(Full(root, rel)).EnumerateFileSystemInfos()) {
            if ((i.Attributes & FileAttributes.ReparsePoint) != 0) continue;
            var r = rel.Length > 0 ? rel + "/" + i.Name : i.Name;
            bool isDir = (i.Attributes & FileAttributes.Directory) != 0;
            var h = new bool[rules.Count];
            for (int k = 0; k < rules.Count; k++) h[k] = hit[k] || Matches(rules[k], r, isDir);
            bool ignored = Last(rules, h);
            if (ignored) {
              if (isDir && CouldBringBack(r, rules)) stack.Push(new Frame { Rel = r, Rules = rules, Hit = h, Hidden = true });
              continue;
            }
            if (top.Hidden) {
              // brought back inside a hidden folder: list the folders above it too
              var up = rel;
              while (up.Length > 0 && !res.ContainsKey(up)) { res[up] = "D"; int s = up.LastIndexOf('/'); up = s < 0 ? "" : up.Substring(0, s); }
            }
            if (isDir) { res[r] = "D"; stack.Push(new Frame { Rel = r, Rules = rules, Hit = h, Hidden = false }); }
            else { var fi = (FileInfo)i; res[r] = fi.Length.ToString() + "|" + fi.LastWriteTimeUtc.Ticks.ToString(); }
          }
        } catch (Exception e) { log.Add("scan: cannot read " + rel + " (" + e.Message + ")"); }
      }
      logOut = log.ToArray();
      return res;
    }
  }
}
'@

# Compiled helpers (scanner, dark UI): built once per source version into %LOCALAPPDATA%\dvcl\<name>-<hash>.dll
function Ensure-Native([string]$typeName, [string]$name, [string]$source, [string[]]$refs = @()) {
    if ($typeName -as [type]) { return $true }
    if ($env:DVCL_NO_NATIVE) { return $false }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $sha = [System.Security.Cryptography.SHA1]::Create()
        $hash = (-join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($source + ($refs -join ',') + $PSVersionTable.PSVersion.ToString())) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }))
        $base = $env:LOCALAPPDATA; if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
        $dir = [System.IO.Path]::Combine($base, 'dvcl'); [void][System.IO.Directory]::CreateDirectory($dir)
        $dll = [System.IO.Path]::Combine($dir, $name + '-' + $hash + '.dll')
        if (-not (Test-Path -LiteralPath $dll)) {
            $tmp = $dll + '.' + [guid]::NewGuid().ToString('N') + '.tmp.dll'
            $r1 = @($refs); $r2 = @($refs) + @([psobject].Assembly.Location)
            try { if ($r1.Count) { Add-Type -TypeDefinition $source -OutputAssembly $tmp -OutputType Library -ReferencedAssemblies $r1 } else { Add-Type -TypeDefinition $source -OutputAssembly $tmp -OutputType Library } }
            catch { Add-Type -TypeDefinition $source -OutputAssembly $tmp -OutputType Library -ReferencedAssemblies $r2 }
            try { Move-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } catch { if (-not (Test-Path -LiteralPath $dll)) { $dll = $tmp } }
            Write-Timing ($name + ' compiled') $sw.Elapsed.TotalMilliseconds
        }
        Add-Type -Path $dll
        Write-Timing ($name + ' loaded') $sw.Elapsed.TotalMilliseconds
        return $true
    } catch { Write-Log ($name + ": native unavailable (" + $_.Exception.Message + ")"); return $false }
}

$script:ScannerOk = $null
function Ensure-Scanner {
    if ($null -eq $script:ScannerOk) {
        $script:ScannerOk = Ensure-Native 'DvclNative.Scanner' 'dvclscan' $script:ScanSource
        if (-not $script:ScannerOk) { Write-Log 'scanner: PowerShell scan used' }
    }
    return $script:ScannerOk
}

# PowerShell scan (reference implementation and fallback)
function Scan-WorkspacePs {
    $res = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $stack = New-Object System.Collections.Stack
    $r0 = Read-Ignore
    $stack.Push(@('', $r0, (New-Object 'bool[]' $r0.Count), $false))
    while ($stack.Count -gt 0) {
        $top = $stack.Pop(); $rel = $top[0]; $rules = $top[1]; $hit = $top[2]; $hidden = $top[3]
        if ($rel -and -not $hidden) {
            $more = Read-IgnoreFiles $rel
            if ($more.Count -gt 0) { $rules = @($rules) + @($more); $h2 = New-Object 'bool[]' $rules.Count; [Array]::Copy($hit, $h2, $hit.Length); $hit = $h2 }
        }
        try {
            foreach ($i in ([System.IO.DirectoryInfo](Full-Path $rel)).EnumerateFileSystemInfos()) {
                if ($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $r = $i.Name; if ($rel) { $r = $rel + '/' + $i.Name }
                $isDir = ($i.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0
                $h = New-Object 'bool[]' $rules.Count
                for ($k = 0; $k -lt $rules.Count; $k++) { $h[$k] = $hit[$k] -or (Test-RuleHit $rules[$k] $r $isDir) }
                if (Test-LastHit $rules $h) {
                    if ($isDir -and (Test-CouldBringBack $r $rules)) { $stack.Push(@($r, $rules, $h, $true)) }
                    continue
                }
                if ($hidden) {
                    $up = $rel
                    while ($up -and -not $res.ContainsKey($up)) { $res[$up] = 'D'; $s = $up.LastIndexOf('/'); if ($s -lt 0) { $up = '' } else { $up = $up.Substring(0, $s) } }
                }
                if ($isDir) { $res[$r] = 'D'; $stack.Push(@($r, $rules, $h, $false)) }
                else { $res[$r] = ([string]$i.Length + '|' + [string]$i.LastWriteTimeUtc.Ticks) }
            }
        } catch { Write-Log ("scan: cannot read " + $rel + " (" + $_.Exception.Message + ")") }
    }
    return ,$res
}

function Save-LastStatus($files) {
    $lines = @($files | ForEach-Object { $_.Kind + "`t" + $_.Path })
    [System.IO.File]::WriteAllLines((Dvcl-File 'last-status.tsv'), [string[]]$lines, $script:Utf8)
}

function Read-LastStatus {
    $f = Dvcl-File 'last-status.tsv'
    $res = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $f) {
        foreach ($l in [System.IO.File]::ReadAllLines($f)) {
            $x = $l.Split("`t")
            if ($x.Count -ge 2 -and $x[1]) { [void]$res.Add([pscustomobject]@{ Index = 0; Kind = $x[0]; Path = $x[1]; Old = $null }) }
        }
    }
    return ,$res.ToArray()
}

function Save-Baseline($scan, [string]$commit) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("#dvcl-baseline2`t" + $commit + "`t" + (Get-Date -Format s) + "`t" + $script:IgnoreMatcher)
    foreach ($k in $scan.Keys) { $lines.Add($k + "`t" + $scan[$k]) }
    [System.IO.File]::WriteAllLines((Dvcl-File 'baseline.tsv'), $lines, $script:Utf8)
}

# $trusted = $false: Diversion's list may be incomplete (read without waiting, or while an upload was
# cut by a pause): the files dvcl already knew as pending are kept, else the new snapshot would hide them.
function Write-Baseline($pendingFiles, [string]$commit, [bool]$trusted = $true) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $files = @($pendingFiles)
    if (-not $trusted -and (Test-Path -LiteralPath (Dvcl-File 'baseline.tsv'))) {
        try {
            $have = @{}; foreach ($p in $files) { $have[([string]$p.Path).ToLowerInvariant()] = 1 }
            $prev = Get-OfflinePending
            $add = @($prev | Where-Object { -not $have.ContainsKey(([string]$_.Path).ToLowerInvariant()) })
            if ($add.Count) { $files = @($files) + $add }
            Write-Log ('baseline: list read without waiting, ' + $add.Count + ' pending file(s) dvcl knew kept')
        } catch { Write-Log ('baseline: earlier pending files not read: ' + $_.Exception.Message) }
    }
    $scan = Scan-Workspace
    Save-Baseline $scan $commit
    Save-LastStatus $files
    Write-Timing ('baseline (' + $scan.Count + ' entries)') $sw.Elapsed.TotalMilliseconds
}

function Read-Baseline {
    $f = Dvcl-File 'baseline.tsv'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $res = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $all = [System.IO.File]::ReadAllLines($f)
    # older format (0.4.0 dev: ignore rules applied differently) -> not trusted, a new one is taken
    if ($all.Count -eq 0 -or -not $all[0].StartsWith("#dvcl-baseline2`t")) { Write-Log "baseline: old format, retaken"; return $null }
    $h = $all[0].Split("`t")
    $script:BaselineCommit = $(if ($h.Count -gt 1) { $h[1] } else { '' })
    $script:BaselineMatcher = $(if ($h.Count -gt 3) { $h[3] } else { '' })
    foreach ($l in $all) {
        if ($l.StartsWith('#')) { continue }
        $i = $l.LastIndexOf("`t"); if ($i -gt 0) { $res[$l.Substring(0, $i)] = $l.Substring($i + 1) }
    }
    return ,$res
}

function Test-OnDisk([string]$rel) { $f = Full-Path $rel; return ([System.IO.File]::Exists($f) -or [System.IO.Directory]::Exists($f)) }

# Pending files while offline: last pending list read online + what changed since the baseline.
# No baseline (sync paused outside dvcl): one is taken now; earlier offline edits are then unknown
# ($script:BaselineFresh = $true so the window can say so).
function Get-OfflinePending {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $script:BaselineFresh = $false
    $known = Read-LastStatus
    $base = Read-Baseline
    if ($null -eq $base) { Write-Baseline $known ''; $base = Read-Baseline; $script:BaselineFresh = $true }
    $now = Scan-Workspace
    # baseline taken with older ignore rules: what the rules now show was not in it. Those files are
    # taken as unchanged (Diversion's own pending list still marks the ones really changed); the
    # files already in it keep their snapshot, so offline edits made since are not lost.
    if ($script:BaselineMatcher -ne $script:IgnoreMatcher) {
        # committed in Diversion (dv ls, works offline) = unchanged; not committed = new, left out of the snapshot
        $dep = $null
        try { $dep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); foreach ($x in (Get-DepotPaths)) { [void]$dep.Add([string]$x) } }
        catch { $dep = $null; Write-Log ('baseline: dv ls not read (' + $_.Exception.Message + '): newly visible entries taken as unchanged') }
        $adopt = 0; $left = 0
        foreach ($k in @($now.Keys)) {
            if ($base.ContainsKey($k)) { continue }
            $isD = ($now[$k] -eq 'D')
            if ($null -eq $dep -or ($isD -and $dep.Contains($k + '/')) -or (-not $isD -and $dep.Contains($k))) { $base[$k] = $now[$k]; $adopt++ } else { $left++ }
        }
        Save-Baseline $base $script:BaselineCommit
        $script:BaselineMatcher = $script:IgnoreMatcher
        Write-Log ('baseline: ignore rules updated (' + $script:IgnoreMatcher + '), ' + $adopt + ' newly visible entries added as committed, ' + $left + ' left as new')
    }
    $out = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $known) {
        $exists = $now.ContainsKey($p.Path)
        if ((Kind-Letter $p.Kind) -eq 'D') { if (-not $exists -and -not (Test-OnDisk $p.Path)) { $out[$p.Path] = 'Deleted' } }
        elseif ($exists) { if ((Kind-Letter $p.Kind) -eq 'A') { $out[$p.Path] = 'New' } else { $out[$p.Path] = 'Modified' } }
    }
    foreach ($k in $now.Keys) {
        if ($out.ContainsKey($k)) { continue }
        if (-not $base.ContainsKey($k)) { $out[$k] = 'New' }
        elseif ($now[$k] -ne 'D' -and $now[$k] -ne $base[$k]) { $out[$k] = 'Modified' }
    }
    # gone from the scan but still on disk = hidden by the ignore rules now, not deleted
    $gone = @($base.Keys | Where-Object { -not $now.ContainsKey($_) -and -not $out.ContainsKey($_) -and -not (Test-OnDisk $_) })
    # more than half of the baseline "deleted" = the snapshot no longer matches the ignore rules,
    # not a real mass delete: take a new baseline instead of listing thousands of false deletions
    if ($gone.Count -gt 1000 -and $gone.Count -gt ($base.Count / 2)) {
        Write-Log ("baseline: " + $gone.Count + " of " + $base.Count + " entries missing, snapshot does not match the ignore rules: retaken")
        Write-Baseline $known ''; $script:BaselineFresh = $true; $gone = @()
    }
    foreach ($k in $gone) { $out[$k] = 'Deleted' }
    $res = New-Object System.Collections.ArrayList
    foreach ($kind in @('New', 'Modified', 'Deleted')) {
        foreach ($k in (@($out.Keys | Where-Object { $out[$_] -eq $kind }) | Sort-Object)) {
            [void]$res.Add([pscustomobject]@{ Index = $res.Count + 1; Kind = $kind; Path = $k; Old = $null })
        }
    }
    Write-Timing ('offline scan (' + $now.Count + ' entries, ' + $res.Count + ' pending)') $sw.Elapsed.TotalMilliseconds
    return ,$res.ToArray()
}

# ---------------------------------------------------------------- local shelves (offline)
# A copy of the files in <repo>\.dvcl\shelves\<id>\files + manifest.json. Nothing is uploaded.
function Shelve-Local([string]$name, $items, [string]$cl = '') {
    if (@($items).Count -eq 0) { Fail "nothing to shelve" }
    $id = (Slug-Base $name) + '_' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $dir = [System.IO.Path]::Combine((Dvcl-File 'shelves'), $id)
    $list = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($p in $items) {
        $src = Full-Path $p.Path
        $copied = $false
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $dst = [System.IO.Path]::Combine([string[]](@($dir, 'files') + @($p.Path.Split('/'))))
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
            [System.IO.File]::Copy($src, $dst, $true); $copied = $true; $n++
        }
        [void]$list.Add([pscustomobject]@{ path = $p.Path; kind = $p.Kind; copied = $copied })
    }
    [void][System.IO.Directory]::CreateDirectory($dir)
    $m = [pscustomobject]@{ name = $name; cl = $cl; created = (Get-Date -Format 'yyyy-MM-dd HH:mm'); items = $list.ToArray() }
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, 'manifest.json'), ($m | ConvertTo-Json -Depth 5), $script:Utf8)
    Write-Log ("local shelf " + $id + " : " + $n + " file(s)")
    Say ("Shelved " + $n + " file(s) locally as '" + $id + "' (copy in .dvcl\shelves, nothing uploaded).") 'Green'
    return $id
}

function Get-LocalShelves {
    $root = Dvcl-File 'shelves'
    $res = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $root) {
        foreach ($d in [System.IO.Directory]::GetDirectories($root)) {
            $mf = [System.IO.Path]::Combine($d, 'manifest.json')
            if (-not (Test-Path -LiteralPath $mf)) { continue }
            try { $m = [System.IO.File]::ReadAllText($mf).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { Write-Log ("shelf manifest unreadable: " + $mf); continue }
            $id = [System.IO.Path]::GetFileName($d)
            $files = @($m.items | Where-Object { $_.copied } | ForEach-Object { [pscustomobject]@{ Path = [string]$_.path; Kind = [string]$_.kind } })
            [void]$res.Add([pscustomobject]@{ Name = [string]$m.name; Id = $id; Created = [string]$m.created; Local = $true; Count = $files.Count; Cl = [string]$m.cl; Files = $files })
        }
    }
    # streamed (no comma-return): @(Get-LocalShelves) must give one row per shelf
    $res.ToArray() | Sort-Object Id -Descending
}

# Copies the shelved files back over the workspace (the shelf is kept)
# $only: restore just these paths (empty = the whole shelf)
function Apply-LocalShelf([string]$id, [string[]]$only) {
    $dir = [System.IO.Path]::Combine((Dvcl-File 'shelves'), $id)
    $mf = [System.IO.Path]::Combine($dir, 'manifest.json')
    if (-not (Test-Path -LiteralPath $mf)) { Fail ("no local shelf '" + $id + "'") }
    $m = [System.IO.File]::ReadAllText($mf) | ConvertFrom-Json
    $n = 0
    foreach ($it in @($m.items)) {
        if (-not $it.copied) { continue }
        if ($only -and -not ($only -icontains [string]$it.path)) { continue }
        $src = [System.IO.Path]::Combine([string[]](@($dir, 'files') + @(([string]$it.path).Split('/'))))
        $dst = Full-Path ([string]$it.path)
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dst))
        [System.IO.File]::Copy($src, $dst, $true); $n++
    }
    Say ("Restored " + $n + " file(s) from local shelf '" + $id + "' (shelf kept).") 'Green'
}

function Delete-LocalShelf([string]$id) {
    $dir = [System.IO.Path]::Combine((Dvcl-File 'shelves'), $id)
    if (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($dir, 'manifest.json')))) { Fail ("no local shelf '" + $id + "'") }
    Remove-Item -LiteralPath $dir -Recurse -Force
    Say ("Deleted local shelf '" + $id + "'.") 'Green'
}

# ---------------------------------------------------------------- launch caches (fast start)
# last-head.txt: branch + commit read online (used offline, when dv is not asked)
# depot.tsv: dv ls result for one commit (dv ls takes 15-40 s; the list only changes with the commit)
function Save-LastHead([string]$branch, [string]$commit) {
    if (-not $branch -or -not $commit) { return }
    [System.IO.File]::WriteAllText((Dvcl-File 'last-head.txt'), ($branch + "`t" + $commit), $script:Utf8)
}
function Read-LastHead {
    $f = Dvcl-File 'last-head.txt'
    if (-not (Test-Path -LiteralPath $f)) { return [pscustomobject]@{ Branch = ''; Commit = '' } }
    $x = [System.IO.File]::ReadAllText($f).Trim().Split("`t")
    return [pscustomobject]@{ Branch = $x[0]; Commit = $(if ($x.Count -gt 1) { $x[1] } else { '' }) }
}
function Save-DepotCache([string]$commit, [string[]]$paths) {
    if (-not $commit) { return }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('#dvcl-depot' + "`t" + $commit)
    foreach ($p in $paths) { $lines.Add($p) }
    [System.IO.File]::WriteAllLines((Dvcl-File 'depot.tsv'), $lines, $script:Utf8)
}
function Read-DepotCache([string]$commit) {
    $f = Dvcl-File 'depot.tsv'
    if (-not $commit -or -not (Test-Path -LiteralPath $f)) { return $null }
    $all = [System.IO.File]::ReadAllLines($f)
    if ($all.Count -eq 0 -or $all[0] -ne ('#dvcl-depot' + "`t" + $commit)) { return $null }
    $arr = New-Object 'string[]' ($all.Count - 1)
    [Array]::Copy($all, 1, $arr, 0, $all.Count - 1)
    return ,$arr
}

# ---------------------------------------------------------------- shelves belong to changelists
# A shelf's changelist: the one recorded when it was made (local), else its name without the
# _yyyyMMdd-HHmm(ss) stamp dvcl adds, else its whole name. Missing changelists are created, so a
# changelist can hold only shelves (like a shelved changelist).
function Shelf-ClName($sh) {
    if ($sh.Cl) { return [string]$sh.Cl }
    $n = [string]$sh.Name
    if ($n -match '^(.+?)_\d{8}-\d{4,6}$') { $n = $Matches[1] }
    if ($n -ieq 'default') { return 'default' }
    return (Slug-Base $n)
}

# Shelves grouped by changelist name (lower-case keys); creates the missing changelists (one save)
function Map-Shelves($shelves) {
    $map = @{}
    $made = 0; $fresh = $false
    foreach ($sh in @($shelves)) {
        if ($null -eq $sh) { continue }
        $cl = Shelf-ClName $sh
        # before adding one, re-read: numbers must not clash with another window's
        if ($cl -ine 'default' -and -not (Find-CL $cl) -and -not $fresh) { Load-Db; $fresh = $true }
        if ($cl -ine 'default' -and -not (Find-CL $cl)) {
            [void]$script:CLs.Add((New-ClObject $cl ([string]$sh.Name -replace '_', ' ')))
            Write-Log ("changelist for shelf " + $sh.Id + " : " + $cl); $made++
        }
        $k = $cl.ToLowerInvariant()
        if (-not $map.ContainsKey($k)) { $map[$k] = New-Object System.Collections.ArrayList }
        [void]$map[$k].Add($sh)
    }
    if ($made -gt 0) { Save-Db }
    return $map
}

# Diversion shelves are listed online only: kept in .dvcl\dv-shelves.tsv for offline display
function Save-DvShelfCache($shelves) {
    $lines = @($shelves | ForEach-Object { $_.Name + "`t" + $_.Id + "`t" + $_.Created })
    [System.IO.File]::WriteAllLines((Dvcl-File 'dv-shelves.tsv'), [string[]]$lines, $script:Utf8)
}
function Read-DvShelfCache {
    $f = Dvcl-File 'dv-shelves.tsv'
    if (-not (Test-Path -LiteralPath $f)) { return }
    foreach ($l in [System.IO.File]::ReadAllLines($f)) {
        $x = $l.Split("`t"); if ($x.Count -lt 2) { continue }
        $fl = Read-ShelfFiles $x[1]
        [pscustomobject]@{ Name = $x[0]; Id = $x[1]; Created = $(if ($x.Count -gt 2) { $x[2] } else { '' }); Local = $false; Count = $(if ($null -ne $fl) { @($fl).Count } else { -1 }); Cl = ''; Files = $(if ($null -ne $fl) { @($fl) } else { @() }) }
    }
}
