# dvcl-cli.ps1 - command-line front end (run through dvcl.cmd). GUI: dvcl-gui.cmd
# Works on the Diversion workspace that contains the current directory.
# No param block on purpose: args like "-y" stay in $args.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DvclCore.ps1')

function Show-List($pending) {
    $set = Pending-Set $pending
    foreach ($name in (@('default') + @($script:CLs | ForEach-Object { $_.name }))) {
        $items = Get-CLItems $pending $name
        $d = ''; $stale = @()
        if ($name -ne 'default') { $c = Find-CL $name; if ($c.desc) { $d = '  "' + $c.desc + '"' }; $stale = Stale-Of $pending $c $set }
        $s = ''; if ($stale.Count -gt 0) { $s = '  +' + $stale.Count + ' not pending' }
        Say ("== " + $name + $d + "  (" + $items.Count + ")" + $s) 'Cyan'
        foreach ($p in $items) { Say ("   #{0,-4} {1}  {2}" -f $p.Index, (Kind-Letter $p.Kind), $p.Path) }
        foreach ($f in $stale) { Say ("   -     .  " + $f + "   (not pending)") 'DarkGray' }
    }
}

function Confirm-Or-Exit([string]$q, [bool]$yes) {
    if ($yes) { return }
    $a = Read-Host ($q + " [y/N]")
    if ($a -notmatch '^(y|yes|o|oui)$') { Say "Cancelled." 'Yellow'; exit 0 }
}

function Show-Help {
@"
dvcl - changelists for Diversion  (window: dvcl-gui)
Run inside a Diversion workspace (any subfolder).

  dvcl                          list pending files grouped by changelist (#numbers used below)
  dvcl new <cl> [description]   create a changelist
  dvcl desc <cl> <description>  set / change its description
  dvcl add <cl> <spec...>       move files into <cl> (creates <cl> if missing)
  dvcl remove <spec...>         move files back to default
  dvcl delete <cl>              delete <cl> (its files go back to default)
  dvcl submit <cl> [-y]         commit ONLY <cl>'s files with its description, then close it
  dvcl submit default "msg"     commit the unassigned files
  dvcl revert <cl> [-y]         discard <cl>'s local changes (backup shelf made first)
  dvcl shelve <cl>              cloud shelf of <cl>'s files, workspace untouched (= p4 shelve)
  dvcl shelves                  list shelves          dvcl unshelve <shelf>   apply one (kept)
  dvcl get                      get latest: pull the branch's new commits into the workspace
  dvcl sync on|off              resume / pause Diversion sync (keep it on to see and submit changes)
  dvcl clean [cl]               remove entries that are no longer pending (all changelists or one)
  dvcl recover                  restore changelist entries dropped by dvcl 0.2.x (from the log)
  dvcl history <file>           last 50 commits touching <file>
  dvcl report                   copy the last 200 log lines to the clipboard
  dvcl selftest                 offline test of parser / matcher / store (no dv calls)

  spec = #number or range from the listing (4, 5-9), a file, a folder, or a wildcard
         (Content/Maps/*). Paths may omit the top folder (MyGame/).
"@ | Write-Host
}

# ---------------------------------------------------------------- selftest (offline)
function Run-SelfTest {
    $sample = @(
        'In repo MyGame dv.repo.x', 'On branch main dv.branch.1', 'Cloud workspace is over commit dv.commit.43',
        'Total modified paths: 14 (12 files)',
        'New:',
        "`t MyGame/Content/Props/crate",
        "`t MyGame/Content/Props/crate/SM_Crate.uasset",
        "`t MyGame/Content/__ExternalActors__/Maps/World/B/A3",
        'Modified:',
        "`t MyGame/Content/Maps/Town/Town_Pack.uasset",
        "`t MyGame/Content/Maps/Town/Town.umap",
        "`t MyGame/Content/__ExternalActors__/Maps/World/1/AR/HIK.uasset",
        'Deleted:',
        "`t MyGame/Content/Old/Gone.uasset",
        'Renamed:',
        "`t MyGame/Content/A.uasset -> MyGame/Content/B.uasset",
        ''
    )
    $script:ok = 0; $script:ko = 0
    function T([string]$name, [bool]$cond) {
        if ($cond) { Write-Host ("PASS  " + $name) -ForegroundColor Green; $script:ok++ } else { Write-Host ("FAIL  " + $name) -ForegroundColor Red; $script:ko++ }
    }
    $script:Root = 'C:\FakeRepo'
    $script:Log  = $null
    $script:Db   = Join-Path $env:TEMP ("dvcl_selftest_" + [guid]::NewGuid().ToString('N') + ".json")
    try {
        $p = Parse-Status $sample
        T "parse: 8 entries" ($p.Count -eq 8)
        T "parse: 3 New" (@($p | Where-Object { $_.Kind -eq 'New' }).Count -eq 3)
        T "parse: 3 Modified" (@($p | Where-Object { $_.Kind -eq 'Modified' }).Count -eq 3)
        T "parse: tab+space prefix stripped" ($p[0].Path -eq 'MyGame/Content/Props/crate')
        T "parse: rename keeps old + new" ($p[7].Old -eq 'MyGame/Content/A.uasset' -and $p[7].Path -eq 'MyGame/Content/B.uasset')
        T "parse: indexes 1..8" ($p[0].Index -eq 1 -and $p[7].Index -eq 8)
        T "match: folder without the top folder" ((Select-Pending $p @('Content/Props/crate')).Count -eq 2)
        T "match: wildcard" ((Select-Pending $p @('Content/__ExternalActors__/*')).Count -eq 2)
        T "match: range 4-6" ((Select-Pending $p @('4-6')).Count -eq 3)
        T "match: absolute Windows path" ((Select-Pending $p @('C:\FakeRepo\MyGame\Content\Old\Gone.uasset')).Count -eq 1)
        T "match: no partial-name folder match" ((Select-Pending $p @('Content/Props/cra')).Count -eq 0)
        $dp = [string[]]@('MyGame/Content/Maps/Town.umap', 'MyGame/Content/Props/', 'MyGame/Content/Props/Crate.uasset', 'MyGame/MyGame.uproject', 'README.md')
        [Array]::Sort($dp, [StringComparer]::Ordinal)
        $c0 = Get-DepotChildren $dp ''
        T "depot: root has 1 folder + 1 file" ($c0.Dirs.Count -eq 1 -and $c0.Files.Count -eq 1)
        $c1 = Get-DepotChildren $dp 'MyGame/Content'
        T "depot: Content has Maps + Props" ($c1.Dirs.Count -eq 2 -and $c1.Files.Count -eq 0)
        $c2 = Get-DepotChildren $dp 'MyGame/Content/Props'
        T "depot: Props has 1 file" ($c2.Files.Count -eq 1 -and $c2.Files[0] -eq 'Crate.uasset')
        $dl = Parse-DepotLines @('Will list contents for current workspace revision', '(F) .dvignore 867B -rw-r--r--', '(D) MyGame drwxrwxrwx', '(D) MyGame/My Maps drwxrwxrwx', '(F) MyGame/My Maps/Town 01.umap 2.0MB -rw-r--r--', '(F) MyGame/MyGame.uproject 1.1kB -rw-r--r--')
        T "dv ls: 5 entries, header skipped" ($dl.Count -eq 5)
        T "dv ls: path with spaces" ($dl -contains 'MyGame/My Maps/Town 01.umap')
        $c3 = Get-DepotChildren $dl 'MyGame'
        T "dv ls: MyGame = 1 folder + 1 file" ($c3.Dirs.Count -eq 1 -and $c3.Files.Count -eq 1 -and $c3.Dirs[0] -eq 'My Maps')
        T "commit list: rename gives 2 paths" ((Files-For-Commit @($p[7])).Count -eq 2)
        Load-Db
        [void](New-CL 'one' 'single file')
        Move-ToCL 'one' @($p[7])
        [void](New-CL 'empty' '')
        Load-Db
        T "store: 2 changelists reloaded" ($script:CLs.Count -eq 2)
        T "store: single-file list stays a list" ((Find-CL 'one').files.Count -eq 1)
        T "store: empty list reloads empty" ((Find-CL 'empty').files.Count -eq 0)
        T "owner lookup (case-insensitive)" ((Owner-Of 'MYGAME/content/b.uasset').name -eq 'one')
        T "items of 'one'" ((Get-CLItems $p 'one').Count -eq 1)
        T "items of default" ((Get-CLItems $p 'default').Count -eq 7)
        Move-ToCL 'default' @($p[7])
        T "move back to default" ((Find-CL 'one').files.Count -eq 0)
        Move-ToCL 'one' @($p[7])
        $notB = @($p | Where-Object { $_.Path -ne 'MyGame/Content/B.uasset' })
        T "stale: entry kept, listed as not pending" ((Find-CL 'one').files.Count -eq 1 -and (Stale-Of $notB (Find-CL 'one')).Count -eq 1)
        T "stale: empty pending list (sync paused) drops nothing" ((Stale-Of @() (Find-CL 'one')).Count -eq 1 -and (Find-CL 'one').files.Count -eq 1)
        $threw = $false; try { [void](Clean-Stale @() '' $true) } catch { $threw = $true }
        T "clean refused while sync paused" ($threw -and (Find-CL 'one').files.Count -eq 1)
        $n = Clean-Stale $notB 'one' $false
        T "clean drops not-pending entries" ($n -eq 1 -and (Find-CL 'one').files.Count -eq 0)
        $log = @('[2026-11-10 08:23:02] prune one : MyGame/Content/B.uasset', '[2026-11-10 08:23:02] prune gone : MyGame/Content/Never.uasset', '[2026-11-10 08:23:02] prune lost : MyGame/Content/Maps/Town/Town.umap', '[2026-11-10 08:23:03] > unrelated line')
        $n = Recover-Pruned $p $log
        T "recover: pending entries restored, missing skipped" ($n -eq 2 -and (Find-CL 'one').files.Count -eq 1 -and (Find-CL 'lost').files.Count -eq 1 -and $null -eq (Find-CL 'gone'))
        T "recover: owned paths not duplicated" ((Recover-Pruned $p $log) -eq 0)
        Remove-CL 'lost'
        Detach 'MyGame/Content/B.uasset'
        Remove-CL 'empty'
        T "delete changelist" ($null -eq (Find-CL 'empty'))
        $threw = $false; try { Check-Name 'default' } catch { $threw = $true }
        T "name 'default' refused" $threw
        T "slug: 'ply file' -> ply_file" ((Slug-Base 'ply file') -eq 'ply_file')
        T "new: spaces become a slug" ((New-CL 'ply file' 'Ply import').name -eq 'ply_file')
        T "new: duplicate slug gets _2" ((New-CL 'ply file' '').name -eq 'ply_file_2')
    } finally {
        if (Test-Path $script:Db) { Remove-Item $script:Db -Force }
    }
    Write-Host ""
    $msg = "SELFTEST: " + $script:ok + " passed, " + $script:ko + " failed"
    if ($script:ko -eq 0) { Write-Host $msg -ForegroundColor Green } else { Write-Host $msg -ForegroundColor Red; exit 1 }
}

# ---------------------------------------------------------------- main
$argv = @($args)
$cmd = 'status'
if ($argv.Count -gt 0) { $cmd = $argv[0].ToLowerInvariant(); $argv = @($argv | Select-Object -Skip 1) }
$yes = $false
if ($argv -contains '-y') { $yes = $true; $argv = @($argv | Where-Object { $_ -ne '-y' }) }

if ($cmd -in 'help', '-h', '--help', '/?') { Show-Help; exit 0 }
if ($cmd -eq 'selftest') { Run-SelfTest; exit 0 }

$root = Find-DvRoot (Get-Location).Path
if (-not $root) { Write-Host "Not inside a Diversion workspace (no .diversion folder above $((Get-Location).Path)). cd into your repo first." -ForegroundColor Red; exit 1 }
Set-DvRoot $root
Write-Log ("==== dvcl " + $cmd + " " + ($argv -join ' '))

try {
    switch ($cmd) {
        'report' {
            $lines = @(Get-Content -LiteralPath $script:Log -Tail 200 -Encoding UTF8)
            ($lines -join "`r`n") | Set-Clipboard
            Write-Host ("Copied the last " + $lines.Count + " log lines to the clipboard.") -ForegroundColor Green
        }

        { $_ -in 'status', 'st', 'list', 'ls' } {
            $st = Get-Pending
            $sync = 'sync on'; if ($st.Paused) { $sync = 'SYNC PAUSED (dvcl sync on)' }
            Say ("Repo " + $script:Root + "  |  branch " + $st.Branch + "  |  " + $st.Commit + "  |  " + $sync) 'DarkGray'
            Show-List $st.Files
        }

        'new'  { [void](New-CL $argv[0] ((@($argv | Select-Object -Skip 1)) -join ' ')) }

        'desc' {
            Set-CLDesc $argv[0] ((@($argv | Select-Object -Skip 1)) -join ' ')
            Say ("Description of '" + $argv[0] + "' updated.") 'Green'
        }

        { $_ -in 'add', 'move', 'mv' } {
            $name = $argv[0]; Check-Name $name
            $specs = @($argv | Select-Object -Skip 1); if ($specs.Count -eq 0) { Fail "nothing to add: give #numbers, files, folders or wildcards" }
            $st = Get-Pending
            $sel = Select-Pending $st.Files $specs
            foreach ($p in $sel) { Say ("   -> " + $name + " : " + $p.Path) }
            Move-ToCL $name $sel
        }

        { $_ -in 'remove', 'rm' } {
            if ($argv.Count -eq 0) { Fail "nothing to remove" }
            $st = Get-Pending
            $sel = Select-Pending $st.Files $argv
            Move-ToCL 'default' $sel
        }

        'delete' { Remove-CL $argv[0] }

        'submit' {
            $name = $argv[0]; if (-not $name) { Fail "usage: dvcl submit <cl>  |  dvcl submit default ""message""" }
            $st = Get-Pending
            if ($name -ieq 'default') {
                $desc = (@($argv | Select-Object -Skip 1) -join ' ').Trim()
                if (-not $desc) { Fail "default needs a message: dvcl submit default ""your message""" }
            } else {
                $c = Find-CL $name; if (-not $c) { Fail ("no changelist '" + $name + "'") }
                if (-not $c.desc) { Fail ("'" + $name + "' has no description: dvcl desc " + $name + " ""what you did""") }
                $desc = $c.desc
            }
            $items = Get-CLItems $st.Files $name
            if ($items.Count -eq 0) { Fail "no pending files in this changelist" }
            Say ("Submit '" + $name + "' : """ + $desc + """") 'Cyan'
            foreach ($p in $items) { Say ("   {0}  {1}" -f (Kind-Letter $p.Kind), $p.Path) }
            Confirm-Or-Exit ("Commit these " + $items.Count + " path(s)?") $yes
            Submit-Items $name $items $desc $st.Files
        }

        'revert' {
            $name = $argv[0]; if (-not $name) { Fail "usage: dvcl revert <cl>" }
            if ($name -ine 'default' -and -not (Find-CL $name)) { Fail ("no changelist '" + $name + "'") }
            $st = Get-Pending
            $items = Get-CLItems $st.Files $name
            if ($items.Count -eq 0) { Fail "no pending files in this changelist" }
            Say ("Revert '" + $name + "' : local changes will be DISCARDED (backup shelf first)") 'Cyan'
            foreach ($p in $items) { Say ("   {0}  {1}" -f (Kind-Letter $p.Kind), $p.Path) }
            Confirm-Or-Exit ("Revert these " + $items.Count + " path(s)? Close Unreal first.") $yes
            [void](Revert-Items $name $items)
        }

        'shelve' {
            $name = $argv[0]; if (-not $name) { Fail "usage: dvcl shelve <cl>" }
            $st = Get-Pending
            $items = Get-CLItems $st.Files $name
            [void](Shelve-Items ($name + "_" + (Get-Date -Format 'yyyyMMdd-HHmm')) $items)
        }

        'shelves' {
            $sh = Get-Shelves
            if ($sh.Count -eq 0) { Say "No shelves." }
            foreach ($s in $sh) { Say ("  " + $s.Name + "   (" + $s.Created + ")") }
        }

        'get' { Get-Latest }

        'sync' {
            $a = ([string]$argv[0]).ToLowerInvariant()
            if ($a -in 'on', 'resume') { Set-Sync $true } elseif ($a -in 'off', 'pause') { Set-Sync $false } else { Fail "usage: dvcl sync on|off" }
        }

        'clean' { $st = Get-Pending; [void](Clean-Stale $st.Files ([string]$argv[0]) $st.Paused) }

        'recover' {
            $st = Get-Pending
            if ($st.Paused) { Fail "sync is paused: resume it first (dvcl sync on), then run recover" }
            [void](Recover-Pruned $st.Files)
            Show-List $st.Files
        }

        'history' {
            if (-not $argv[0]) { Fail "usage: dvcl history <file>" }
            foreach ($l in (Get-History (Norm $argv[0]))) { Say $l }
        }

        'unshelve' { if (-not $argv[0]) { Fail "usage: dvcl unshelve <shelf name or id>" }; Apply-Shelf $argv[0] }

        default { Write-Host ("Unknown command '" + $cmd + "'.") -ForegroundColor Red; Show-Help; exit 1 }
    }
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
