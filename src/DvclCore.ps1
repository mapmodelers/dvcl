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
$script:DvNoise = '\{\{spinner\}\}|^Sync in progress|^Queued filesystem events|^Inbound changes|^Outbound changes|^Currently syncing|active blob transfers|^Downloading |^Uploading |^Recently synced'

# ---------------------------------------------------------------- repo / logging
function Find-DvRoot([string]$start) {
    if (-not $start -or -not (Test-Path -LiteralPath $start)) { return $null }
    # GetFullPath normalizes 'D:\repo.' (trailing dot from dvcl-gui.cmd) and relative paths
    $d = [System.IO.Path]::GetFullPath($start).TrimEnd('\')
    if ($d -match '^[A-Za-z]:$') { $d += '\' }
    while ($d) {
        if (Test-Path -LiteralPath (Join-Path $d '.diversion') -PathType Container) { return $d }
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
    Load-Db
}

function Write-Log([string]$t) {
    if (-not $script:Log) { return }
    Add-Content -LiteralPath $script:Log -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t) -Encoding UTF8
}

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

function Invoke-Dv([string[]]$a) {
    if (-not $script:Root) { Fail "no Diversion repo selected" }
    Write-Log ("RUN dv " + ($a -join ' '))
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $script:Root
    try {
        $out  = @(& dv @a 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $out = @("dv could not be started: " + $_.Exception.Message + " (is Diversion installed and dv in PATH?)"); $code = 9009
    } finally {
        Pop-Location
        $ErrorActionPreference = $prev
    }
    $clean = @($out | Where-Object { $_ -notmatch $script:DvNoise })
    foreach ($l in $clean) {
        Write-Log ("  | " + $l)
        if ($script:OnDv -and $l.Trim()) { & $script:OnDv $l }
    }
    Write-Log ("  exit=" + $code)
    return [pscustomobject]@{ Code = $code; Lines = $clean }
}

# ---------------------------------------------------------------- depot listing (dv ls)
# All paths of the workspace revision, sorted (ordinal) for prefix lookups.
# Quiet on purpose: thousands of lines go neither to the log nor to the UI.
function Get-DepotPaths {
    if (-not $script:Root) { Fail "no Diversion repo selected" }
    Write-Log "RUN dv ls"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $script:Root
    try { $out = @(& dv ls 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    catch { $out = @("dv could not be started: " + $_.Exception.Message); $code = 9009 }
    finally { Pop-Location; $ErrorActionPreference = $prev }
    Write-Log ("  exit=" + $code + "  lines=" + $out.Count)
    foreach ($l in ($out | Select-Object -First 5)) { Write-Log ("  sample | " + $l) }
    if ($code -ne 0) { Fail ("dv ls failed: " + (($out | Select-Object -Last 3) -join ' | ')) }
    return ,(Parse-DepotLines $out)
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

function Get-Pending {
    $r = Invoke-Dv @('status', '--no-limit')
    if ($r.Code -ne 0) { Fail ("dv status failed (exit " + $r.Code + "). Is Diversion Desktop running? " + ($r.Lines -join ' ')) }
    $branch = ''; $commit = ''
    foreach ($l in $r.Lines) {
        if ($l -match '^On branch (\S+)') { $branch = $Matches[1] }
        if ($l -match 'over commit (\S+)') { $commit = $Matches[1] }
    }
    return [pscustomobject]@{ Files = (Parse-Status $r.Lines); Branch = $branch; Commit = $commit }
}

function Kind-Letter([string]$k) {
    switch -regex ($k) { '^New|^Add' { 'A' } '^Mod|^Chang' { 'M' } '^Del|^Rem' { 'D' } '^Ren|^Mov' { 'R' } '^Conf' { '!' } default { '?' } }
}

# ---------------------------------------------------------------- changelist store
function Load-Db {
    $script:CLs = New-Object System.Collections.ArrayList
    if ($script:Db -and (Test-Path -LiteralPath $script:Db)) {
        $txt = Get-Content -LiteralPath $script:Db -Raw -Encoding UTF8
        if ($txt -and $txt.Trim()) {
            $j = $txt | ConvertFrom-Json
            foreach ($c in @($j.changelists)) {
                if ($null -eq $c) { continue }
                $files = New-Object System.Collections.ArrayList
                foreach ($f in @($c.files)) { if ($f) { [void]$files.Add([string]$f) } }
                [void]$script:CLs.Add([pscustomobject]@{ name = [string]$c.name; desc = [string]$c.desc; files = $files })
            }
        }
    }
}

function Save-Db {
    $out = @()
    foreach ($c in $script:CLs) { $out += [pscustomobject]@{ name = $c.name; desc = $c.desc; files = @($c.files) } }
    $json = [pscustomobject]@{ changelists = $out } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $script:Db -Value $json -Encoding UTF8
}

function Find-CL([string]$name) { foreach ($c in $script:CLs) { if ($c.name -ieq $name) { return $c } }; return $null }

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

# Drops entries that are no longer pending (committed / reverted elsewhere). Returns how many.
function Prune($pending) {
    $set = @{}; foreach ($p in $pending) { $set[$p.Path.ToLowerInvariant()] = 1 }
    $n = 0
    foreach ($c in $script:CLs) {
        for ($i = $c.files.Count - 1; $i -ge 0; $i--) {
            if (-not $set.ContainsKey($c.files[$i].ToLowerInvariant())) { Write-Log ("prune " + $c.name + " : " + $c.files[$i]); $c.files.RemoveAt($i); $n++ }
        }
    }
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
    if ($len -gt 28000) { Fail ("command line too long (" + $len + " chars, " + $list.Count + " paths). Split this changelist in two.") }
    return ,$list.ToArray()
}

# ---------------------------------------------------------------- operations (shared by CLI and GUI)
function New-CL([string]$name, [string]$desc) {
    if (-not $name) { $name = $desc }
    if ($name -notmatch '^[A-Za-z0-9_\-]{1,40}$' -or $name -ieq 'default') {
        $new = Unique-Name $name
        Say ("Name '" + $name + "' -> '" + $new + "'") 'Yellow'
        $name = $new
    }
    if (Find-CL $name) { Fail "changelist '$name' already exists" }
    $c = [pscustomobject]@{ name = $name; desc = ([string]$desc).Trim(); files = (New-Object System.Collections.ArrayList) }
    [void]$script:CLs.Add($c); Save-Db
    Say ("Created changelist '" + $name + "'") 'Green'
    return $c
}

function Set-CLDesc([string]$name, [string]$desc) {
    $c = Find-CL $name; if (-not $c) { Fail ("no changelist '" + $name + "'") }
    $c.desc = ([string]$desc).Trim(); Save-Db
}

function Remove-CL([string]$name) {
    $c = Find-CL $name; if (-not $c) { Fail ("no changelist '" + $name + "'") }
    [void]$script:CLs.Remove($c); Save-Db
    Say ("Deleted changelist '" + $c.name + "' (" + $c.files.Count + " file(s) back to default). Nothing was reverted.") 'Green'
}

# Moves pending items to a changelist ('default' = unassign). Creates the changelist if missing.
function Move-ToCL([string]$name, $items) {
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
function Submit-Items([string]$clName, $items, [string]$desc) {
    $desc = ([string]$desc).Trim()
    if (-not $desc) { Fail "a description is required to submit" }
    if (@($items).Count -eq 0) { Fail "nothing to submit" }
    $files = Files-For-Commit $items
    $r = Invoke-Dv (@('commit') + $files + @('-m', $desc))
    if ($r.Code -ne 0) { Fail ("dv commit failed (exit " + $r.Code + "): " + ($r.Lines -join ' ')) }
    foreach ($p in $items) { Detach $p.Path }
    $c = Find-CL $clName
    if ($c -and $c.files.Count -eq 0) { [void]$script:CLs.Remove($c) }
    Save-Db
    Say ("Submitted " + @($items).Count + " path(s) from '" + $clName + "': " + $desc) 'Green'
}

function Shelve-Items([string]$shelf, $items) {
    if (@($items).Count -eq 0) { Fail "nothing to shelve" }
    if ($shelf.Length -gt 60) { $shelf = $shelf.Substring(0, 60) }
    $r = Invoke-Dv (@('shelf', 'create', $shelf) + (Files-For-Commit $items) + @('--no-reset'))
    if ($r.Code -ne 0) { Fail ("dv shelf create failed (exit " + $r.Code + "): " + ($r.Lines -join ' ')) }
    Say ("Shelved " + @($items).Count + " path(s) as '" + $shelf + "'. Workspace unchanged.") 'Green'
    return $shelf
}

# Discards local changes (dv restore from the workspace base commit) after a backup shelf.
# New files are skipped (nothing to restore). Returns the backup shelf name.
function Revert-Items([string]$prefix, $items) {
    $toRestore = @($items | Where-Object { (Kind-Letter $_.Kind) -ne 'A' })
    foreach ($p in @($items | Where-Object { (Kind-Letter $_.Kind) -eq 'A' })) { Say ("   skip (new file, nothing to revert): " + $p.Path) 'Yellow' }
    if ($toRestore.Count -eq 0) { Fail "nothing revertable (only new files)" }
    $shelf = Shelve-Items ($prefix + "_backup_" + (Get-Date -Format 'yyyyMMdd-HHmmss')) $toRestore
    $bad = 0
    foreach ($p in $toRestore) {
        $r = Invoke-Dv @('restore', $p.Path)
        if ($r.Code -ne 0) { $bad++; Say ("   FAILED: " + $p.Path + "  -> " + ($r.Lines -join ' ')) 'Red' }
        else { Detach $p.Path; Say ("   reverted: " + $p.Path) }
    }
    foreach ($c in @($script:CLs)) { if ($c.files.Count -eq 0 -and $c.name -ieq $prefix) { [void]$script:CLs.Remove($c) } }
    Save-Db
    if ($bad -gt 0) { Fail ($bad.ToString() + " path(s) failed to revert. Backup shelf: " + $shelf) }
    Say ("Reverted " + $toRestore.Count + " path(s). Undo: unshelve " + $shelf) 'Green'
    return $shelf
}

# Parses `dv shelf` output into objects { Name; Id; Created }
function Get-Shelves {
    $r = Invoke-Dv @('shelf')
    if ($r.Code -ne 0) { Fail ("dv shelf failed: " + ($r.Lines -join ' ')) }
    $res = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($l in $r.Lines) {
        if ($l -match '^\s*shelf\s+(.+?)\s+\((dv\.shelf\.[^)]+)\)') {
            $cur = [pscustomobject]@{ Name = $Matches[1]; Id = $Matches[2]; Created = '' }
            [void]$res.Add($cur)
        } elseif ($cur -and $l -match '^\s*Created:\s*(.+)$') { $cur.Created = $Matches[1].Trim() }
    }
    return ,$res.ToArray()
}

function Apply-Shelf([string]$shelf) {
    $r = Invoke-Dv @('shelf', 'apply', $shelf, '--keep', '-f')
    if ($r.Code -ne 0) { Fail ("dv shelf apply failed: " + ($r.Lines -join ' ')) }
    # dv returns before the agent has rewritten the files: give it a moment so a refresh shows them
    Start-Sleep -Seconds 3
    Say ("Applied shelf '" + $shelf + "' (shelf kept).") 'Green'
}

function Delete-Shelf([string]$shelf) {
    $r = Invoke-Dv @('shelf', 'delete', $shelf, '-f')
    if ($r.Code -ne 0) { Fail ("dv shelf delete failed: " + ($r.Lines -join ' ')) }
    Say ("Deleted shelf '" + $shelf + "'.") 'Green'
}
