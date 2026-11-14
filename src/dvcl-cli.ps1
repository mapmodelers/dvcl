# dvcl-cli.ps1 - command-line front end (run through dvcl.cmd). GUI: dvcl-gui.cmd
# Works on the Diversion workspace that contains the current directory.
# No param block on purpose: args like "-y" stay in $args.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DvclCore.ps1')

function Show-List($pending) {
    $set = Pending-Set $pending
    $shmap = Map-Shelves @(@(Get-LocalShelves) + @(Read-DvShelfCache))
    foreach ($name in (@('default') + @($script:CLs | ForEach-Object { $_.name }))) {
        $items = Get-CLItems $pending $name
        $d = ''; $stale = @(); $num = ''
        if ($name -ne 'default') { $c = Find-CL $name; $num = 'CL' + $c.id + ' '; if ($c.desc) { $d = '  "' + $c.desc + '"' }; $stale = Stale-Of $pending $c $set }
        $s = ''; if ($stale.Count -gt 0) { $s = '  +' + $stale.Count + ' not pending' }
        Say ("== " + $num + $name + $d + "  (" + $items.Count + ")" + $s) 'Cyan'
        foreach ($p in $items) { Say ("   #{0,-4} {1}  {2}" -f $p.Index, (Kind-Letter $p.Kind), $p.Path) }
        foreach ($f in $stale) { Say ("   -     .  " + $f + "   (not pending)") 'DarkGray' }
        if ($shmap.ContainsKey($name.ToLowerInvariant())) { foreach ($sh in $shmap[$name.ToLowerInvariant()]) { Say ("   shelved " + $(if ($sh.Local) { $sh.Id + '  (local, ' + $sh.Count + ' files)' } else { $sh.Name + '  (Diversion)' })) 'DarkYellow' } }
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
  <cl> = changelist name or number (dvcl submit 12)
  dvcl new <cl> [description]   create a changelist
  dvcl desc <cl> <description>  set / change its description
  dvcl add <cl> <spec...>       move files into <cl> (creates <cl> if missing)
  dvcl remove <spec...>         move files back to default
  dvcl delete <cl>              delete <cl> (its files go back to default)
  dvcl submit <cl> [-y]         commit ONLY <cl>'s files with its description, then close it
  dvcl submit default "msg"     commit the unassigned files
  dvcl revert <cl> [-y]         discard <cl>'s local changes (your versions copied to .dvcl\revert-backup)
  dvcl shelve <cl>              Diversion shelf of <cl>'s files, workspace untouched
  dvcl shelves                  list shelves and their files
  dvcl unshelve <shelf> [<cl>]  apply one (kept) into <cl> (default: the shelf's changelist)
  (revert / shelve / unshelve need Diversion sync: on for that command only, then off again)
  dvcl get                      get latest: pull the branch's new commits into the workspace
  dvcl sync on|off              go online (resume sync) / offline (pause sync). Offline, dvcl finds
                                your changes by scanning the folder; shelve makes a local copy
  dvcl clean [cl]               remove entries that are no longer pending (all changelists or one)
  dvcl recover                  restore changelist entries dropped by dvcl 0.2.x (from the log)
  dvcl history <file>           last 50 commits touching <file>
  dvcl lock <file...>           lock files (others cannot submit them)   dvcl unlock <file...>
  dvcl locks                    list locks
  dvcl folder on|off <folder>   download / stop downloading a folder on this PC (no pending files allowed)
  dvcl report                   copy the last 200 log lines to the clipboard
  dvcl selftest                 offline test of parser / matcher / store (no dv calls)
  dvcl args <anything>          show the arguments as dvcl receives them (script / shell quoting check)

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
        $big = @(1..900 | ForEach-Object { [pscustomobject]@{ Path = ('Game/Content/Very/Long/Folder/Name/For/Testing/Asset_' + $_ + '.uasset'); Kind = 'M'; Old = $null } })
        $big += [pscustomobject]@{ Path = 'Game/new.txt'; Kind = 'R'; Old = 'Game/old.txt' }
        $pl = Commit-Plan $big $null
        $flat = @($pl.Batches | ForEach-Object { $_.Files }); $lens = @($pl.Batches | ForEach-Object { ($_.Files | ForEach-Object { $_.Length + 3 } | Measure-Object -Sum).Sum })
        T "big submit: split under the command-line limit, nothing lost, rename kept whole" (-not $pl.All -and @($pl.Batches).Count -ge 3 -and $flat.Count -eq 902 -and @($lens | Where-Object { $_ -gt 24000 }).Count -eq 0 -and @($pl.Batches | Where-Object { $_.Files -contains 'Game/old.txt' -and $_.Files -contains 'Game/new.txt' }).Count -eq 1)
        T "big submit: all pending files = one dv commit -a" ((Commit-Plan $big $big).All -and -not (Commit-Plan @($big | Select-Object -First 5) $big).All)
        $cl = @(Split-CmdLine 'desc silo_work Silo pass 2 (Sam): scan - tower, cornice; (LiDAR mirrors LAS Y). Config: on')
        T "args: unquoted text with ( ) : ; , - kept" ($cl.Count -eq 16 -and $cl[0] -eq 'desc' -and (($cl | Select-Object -Skip 2) -join ' ') -eq 'Silo pass 2 (Sam): scan - tower, cornice; (LiDAR mirrors LAS Y). Config: on')
        $cq = @(Split-CmdLine 'submit default "Silo pass 3 (Sam, photos): roof + lantern & dock, ""quoted""" -y')
        T "args: quoted text with & , quotes; -y separate" ($cq.Count -eq 4 -and $cq[2] -eq 'Silo pass 3 (Sam, photos): roof + lantern & dock, "quoted"' -and $cq[3] -eq '-y')
        $cb = @(Split-CmdLine 'a "D:\x y\\" b\"c')
        T "args: Windows backslash rules" ($cb[1] -eq 'D:\x y\' -and $cb[2] -eq 'b"c')
        $fr = Finish-Dv @('status') (@('Sync in progress {{spinner}}') + $sample) 0 $true $false 5
        T "dv output: sync progress detected and filtered" ($fr.SyncBusy -and $fr.Lines.Count -eq $sample.Count)
        $st = Read-Status $fr
        T "status: branch, commit, 8 files, not paused" ($st.Branch -eq 'main' -and $st.Commit -eq 'dv.commit.43' -and $st.Files.Count -eq 8 -and -not $st.Paused -and $st.Syncing)
        T "status: 'paused' header detected" ((Read-Status (Finish-Dv @('status') @('Workspace sync is paused') 0 $true $false 1)).Paused)
        T "status: no wait = --nowait" (((Status-Args $false) -join ' ') -eq 'status --no-limit --nowait' -and ((Status-Args $true) -join ' ') -eq 'status --no-limit')
        T "branch head from dv show" ((Read-HeadCommit @('Branch main dv.branch.1', 'commit dv.commit.57', 'Author: x', 'parent dv.commit.56')) -eq 'dv.commit.57')
        Load-Db
        [void](New-CL 'one' 'single file')
        Move-ToCL 'one' @($p[7])
        [void](New-CL 'empty' '')
        Load-Db
        T "store: 2 changelists reloaded" ($script:CLs.Count -eq 2)
        T "store: single-file list stays a list" ((Find-CL 'one').files.Count -eq 1)
        T "store: empty list reloads empty" ((Find-CL 'empty').files.Count -eq 0)
        T "numbers: #1, #2 kept on reload, found by number" ((Find-CL 'one').id -eq 1 -and (Find-CL 'empty').id -eq 2 -and (Find-CL '#2').name -eq 'empty' -and (Find-CL '1').name -eq 'one' -and (Find-CL 'CL2').name -eq 'empty')
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
        $lg = @(Parse-Log @('commit dv.commit.52 (HEAD -> main)', 'Author: Sam <s@x.y>', 'Date:   2026-11-10T10:00:00Z', '', '    station roof', '    second line', 'commit dv.commit.51', 'Author: Al', 'Date: 2026-11-09', '', '    fence'))
        T "log: blocks parsed (id, number, author, date, description)" ($lg.Count -eq 2 -and $lg[0].Num -eq 52 -and $lg[0].Author -eq 'Sam' -and $lg[0].Date -like '2026-11-10*' -and $lg[0].Desc -eq "station roof`nsecond line" -and $lg[1].Desc -eq 'fence')
        $lo = @(Parse-Log @('dv.commit.9 fix lights', 'dv.commit.8 - first'))
        T "log: one line per commit" ($lo.Count -eq 2 -and $lo[0].Desc -eq 'fix lights' -and $lo[1].Desc -eq 'first' -and $lo[1].Num -eq 8)
        $sf = @(Parse-ShowFiles @('commit dv.commit.52', "`tA new bench", '    M lamp fix', "M`tGame/Content/A.uasset", "A`tGame/B.umap", "R`tGame/old.txt`tGame/new.txt", 'D  Game/C.ini', 'Modified: Game/D.ini'))
        T "show: changed files parsed" ($sf.Count -eq 5 -and $sf[0].Kind -eq 'M' -and $sf[2].Path -eq 'Game/new.txt' -and $sf[3].Kind -eq 'D' -and $sf[4].Path -eq 'Game/D.ini')
        $loc = ([datetime]::new(2026, 11, 12, 8, 35, 0, [DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        T "dates: ISO UTC to local, US order to ISO" ((Format-CommitDate '2026-11-12T08:35:02Z') -eq $loc -and (Format-CommitDate '11-12-2026 09:35:02') -eq '2026-11-12 09:35')
        T "numbers never reused" ((New-CL 'again' '').id -gt 2); Remove-CL 'again'
        $threw = $false; try { Check-Name 'default' } catch { $threw = $true }
        T "name 'default' refused" $threw
        T "slug: 'ply file' -> ply_file" ((Slug-Base 'ply file') -eq 'ply_file')
        T "new: spaces become a slug" ((New-CL 'ply file' 'Ply import').name -eq 'ply_file')
        T "new: duplicate slug gets _2" ((New-CL 'ply file' '').name -eq 'ply_file_2')
        # ---- offline mode (real temp folder)
        $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'dvcl_off_' + [guid]::NewGuid().ToString('N'))
        $saveRoot = $script:Root
        try {
            $script:Root = $tmp
            function MkF([string]$rel, [string]$txt) { $f = Full-Path $rel; [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($f)); [System.IO.File]::WriteAllText($f, $txt) }
            [void][System.IO.Directory]::CreateDirectory((Full-Path '.dvcl'))
            [void][System.IO.Directory]::CreateDirectory((Full-Path '.diversion'))
            MkF '.dvignore' "# ue`nSaved/*`nIntermediate/*`n*.tmp`n/artsource`n"
            MkF 'Game/.gitignore' "Cache/`n"; MkF 'Game/Cache/c.bin' 'x'; MkF 'Game/Sub/artsource/keep.txt' 'x'
            MkF 'Game/Content/A.uasset' 'a1'; MkF 'Game/Content/B.uasset' 'b1'; MkF 'Game/Content/C.uasset' 'c1'
            MkF 'Game/Saved/log.txt' 'x'; MkF 'Game/Intermediate/x.obj' 'x'; MkF 'Game/Content/t.tmp' 'x'; MkF 'artsource/big.blend' 'x'
            $sc = Scan-Workspace
            $ps = Scan-WorkspacePs
            $same = ($sc.Count -eq $ps.Count) -and (@($ps.Keys | Where-Object { -not $sc.ContainsKey($_) -or $sc[$_] -ne $ps[$_] }).Count -eq 0)
            T "scan: compiled scanner = PowerShell scan (same entries)" ((Ensure-Scanner) -and $same) ("native " + $sc.Count + " / ps " + $ps.Count)
            T "scan: Saved/* and Intermediate/* hidden at any depth" (-not $sc.ContainsKey('Game/Saved/log.txt') -and -not $sc.ContainsKey('Game/Intermediate/x.obj'))
            T "scan: wildcard, /anchored, nested .gitignore, .diversion" (-not $sc.ContainsKey('Game/Content/t.tmp') -and -not $sc.ContainsKey('artsource') -and $sc.ContainsKey('Game/Sub/artsource/keep.txt') -and -not $sc.ContainsKey('Game/Cache') -and -not $sc.ContainsKey('.diversion'))
            T "scan: normal files and folders kept" ($sc.ContainsKey('Game/Content/A.uasset') -and $sc['Game/Content'] -eq 'D')
            $known = @([pscustomobject]@{ Index = 1; Kind = 'Modified'; Path = 'Game/Content/C.uasset'; Old = $null })
            Write-Baseline $known 'dv.commit.1'
            T "offline: no change = only the known pending file" ((@(Get-OfflinePending)).Count -eq 1)
            Start-Sleep -Milliseconds 50
            MkF 'Game/Content/A.uasset' 'a2-longer'; Remove-Item -LiteralPath (Full-Path 'Game/Content/B.uasset'); MkF 'Game/Content/New/D.uasset' 'd'
            MkF 'Game/Saved/other.txt' 'ignored'
            $off = Get-OfflinePending
            $k = @{}; foreach ($x in $off) { $k[$x.Path] = $x.Kind }
            T "offline: modified, deleted, new file + new folder, known pending kept" ($k['Game/Content/A.uasset'] -eq 'Modified' -and $k['Game/Content/B.uasset'] -eq 'Deleted' -and $k['Game/Content/New/D.uasset'] -eq 'New' -and $k['Game/Content/New'] -eq 'New' -and $k['Game/Content/C.uasset'] -eq 'Modified' -and $off.Count -eq 5)
            T "offline: ignored files never pending" (-not $k.ContainsKey('Game/Saved/other.txt'))
            T "offline: indexes 1..n" ($off[0].Index -eq 1 -and $off[$off.Count - 1].Index -eq $off.Count)
            Remove-Item -LiteralPath (Dvcl-File 'baseline.tsv')
            [void](Get-OfflinePending)
            # a baseline listing many paths the scan no longer sees (ignore rules changed) is retaken, not 1000s of deletes
            $bl = Dvcl-File 'baseline.tsv'; $extra = @(); for ($q = 0; $q -lt 1500; $q++) { $extra += ('Game/Saved/old' + $q + "`t1|1") }
            [System.IO.File]::AppendAllLines($bl, [string[]]$extra)
            $off2 = Get-OfflinePending
            T "offline: mismatched baseline retaken, no mass false deletions" ($script:BaselineFresh -and @($off2 | Where-Object { $_.Kind -eq 'Deleted' }).Count -le 1)
            T "offline: no baseline -> one is taken, flagged as fresh" ($script:BaselineFresh -and (Test-Path -LiteralPath (Dvcl-File 'baseline.tsv')))
            Set-OfflineFlag $true; $f1 = Test-OfflineFlag; Set-OfflineFlag $false
            T "offline flag set / cleared" ($f1 -and -not (Test-OfflineFlag))
            Set-OfflineFlag $true; $cp = Current-Pending; $wild = Select-Pending $cp.Files @('Content/*.uasset'); Set-OfflineFlag $false
            T "offline: add with a wildcard matches from the folder scan" ($cp.Paused -and @($wild).Count -ge 1 -and @($wild).Count -eq @($cp.Files | Where-Object { $_.Path -like '*.uasset' }).Count -and @($wild | Where-Object { $_.Path -notlike 'Game/Content/*.uasset' }).Count -eq 0) ("" + @($wild).Count + " of " + @($cp.Files).Count + " | " + (@($cp.Files | % { $_.Path }) -join ","))
            $id = Shelve-Local 'my work' @($off | Where-Object { $_.Path -like '*.uasset' })
            MkF 'Game/Content/A.uasset' 'changed-after-shelve'
            $ls = @(Get-LocalShelves)
            T "local shelf listed with its copied files" ($ls.Count -eq 1 -and $ls[0].Id -eq $id -and $ls[0].Count -eq 3)
            $id2 = Shelve-Local 'other work' @($off | Where-Object { $_.Path -like '*New/D.uasset' })
            $rows = @(Get-LocalShelves)
            T "two local shelves = two rows (not one row holding both)" ($rows.Count -eq 2 -and $rows[0] -isnot [array] -and $rows[0].Id -and $rows[1].Id)
            $m = Map-Shelves $rows
            T "shelves map to changelists (recorded, by name, created when missing)" ($m.ContainsKey('my_work') -and $m.ContainsKey('other_work') -and (Find-CL 'other_work'))
            T "shelf name without dvcl stamp -> changelist" ((Shelf-ClName ([pscustomobject]@{ Name = 'town_blockout_20261111-0645'; Cl = '' })) -eq 'town_blockout' -and (Shelf-ClName ([pscustomobject]@{ Name = 'x'; Cl = 'mine' })) -eq 'mine')
            T "Diversion shelf list parsed one row per shelf" (@(Read-Shelves @('shelf a_20261111-0101 (dv.shelf.1)', '  Created: today', 'shelf b (dv.shelf.2)')).Count -eq 2)
            Remove-CL 'other_work'; Remove-CL 'my_work'
            Delete-LocalShelf $id2
            $other = @($ls[0].Files | Where-Object { $_.Path -ne 'Game/Content/A.uasset' } | Select-Object -First 1)[0].Path
            MkF $other 'changed-other'
            Apply-LocalShelf $id @('Game/Content/A.uasset')
            T "local unshelve of selected files only" ([System.IO.File]::ReadAllText((Full-Path 'Game/Content/A.uasset')) -eq 'a2-longer' -and [System.IO.File]::ReadAllText((Full-Path $other)) -eq 'changed-other')
            Apply-LocalShelf $id
            T "local unshelve restores the shelved content" ([System.IO.File]::ReadAllText((Full-Path 'Game/Content/A.uasset')) -eq 'a2-longer' -and [System.IO.File]::ReadAllText((Full-Path $other)) -ne 'changed-other')
            Delete-LocalShelf $id
            T "local shelf deleted" (@(Get-LocalShelves).Count -eq 0)
            # ---- Unreal link: the Python sent to the editor, the files Get latest will write
            $uc = Ue-Code 'release_files' @('Game/Content/A b.uasset', "Game/Content/q'x.umap")
            T "unreal link: Python call with full paths (/, quotes safe)" ($uc -like "*unreal.DvclLinkLibrary.release_files(*" -and $uc -like ('*' + ((Full-Path 'Game/Content/A b.uasset') -replace '\\', '/') + '*') -and ($uc -like "*q'x.umap*" -or $uc -like '*q\u0027x.umap*'))
            $origDv = ${function:Invoke-Dv}
            Set-Item function:script:Invoke-Dv { param([string[]]$a, [bool]$q)
                if ($a[0] -eq 'log') { return [pscustomobject]@{ Code = 0; Lines = @('commit dv.commit.9', 'Author: s', 'Date: 2026-11-12T08:00:00Z', '', "`tnine", 'commit dv.commit.8', 'Author: s', '', "`teight", 'commit dv.commit.7', 'Author: s', '', "`tseven") } }
                if ($a[1] -eq 'dv.commit.9') { return [pscustomobject]@{ Code = 0; Lines = @('commit dv.commit.9', "M`tGame/X.uasset", "A`tGame/Y.umap") } }
                if ($a[1] -eq 'dv.commit.8') { return [pscustomobject]@{ Code = 0; Lines = @('commit dv.commit.8', "M`tGame/x.uasset", "D`tGame/Z.uasset") } }
                return [pscustomobject]@{ Code = 0; Lines = @("M`tGame/OLD.uasset") } }
            try { $inc = @(Incoming-Files 'dv.commit.7') } finally { Set-Item function:script:Invoke-Dv $origDv }
            T "get latest: files of the newer commits only, once each" ($inc.Count -eq 3 -and @($inc | Where-Object { $_ -ieq 'Game/OLD.uasset' }).Count -eq 0 -and @($inc | Where-Object { $_ -ieq 'Game/X.uasset' }).Count -eq 1)
            # ---- Diversion shelves, revert (dv simulated)
            T "kinds: letters kept" ((Kind-Letter 'M') -eq 'M' -and (Kind-Letter 'a') -eq 'A' -and (Kind-Letter 'Modified') -eq 'M' -and (Kind-Letter 'New') -eq 'A')
            $sfl = Parse-Status @('Shelf mansion_20261108-0755 contains 3 change(s):', '', 'Modified:', "`t Game/S/a.uasset", "`t Game/S/b.uasset", 'New:', "`t Game/S/n.uasset")
            Save-ShelfFiles 'dv.shelf.t1' $sfl; $rb = Read-ShelfFiles 'dv.shelf.t1'
            T "shelf files: dv shelf show parsed and kept" ($rb.Count -eq 3 -and $rb[0].Kind -eq 'M' -and $rb[2].Kind -eq 'A' -and $rb[2].Path -eq 'Game/S/n.uasset' -and $null -eq (Read-ShelfFiles 'dv.shelf.none'))
            T "dv errors: unwritten files found" (((@(Unwritten @('Restored x', 'Last error: Cannot write to Game/S/a.uasset - file is locked by Unreal', 'Last error: Cannot write to .diversion/u/P/.dv.tmp.X - file is open'))) -join ',') -eq 'Game/S/a.uasset')
            MkF 'Game/S/a.uasset' 'mine-a'; MkF 'Game/S/b.uasset' 'mine-b'
            $lk = [System.IO.File]::Open((Full-Path 'Game/S/b.uasset'), 'Open', 'ReadWrite', 'None')
            $l1 = Test-Locked 'Game/S/b.uasset'; $lk.Close()
            T "open file seen as locked, closed one not" ($l1 -and -not (Test-Locked 'Game/S/b.uasset') -and -not (Test-Locked 'Game/S/none.uasset'))
            # unshelve a Diversion shelf partly: dv applies all three, dvcl puts the other two back
            $origApply = ${function:Apply-Shelf}
            Set-Item function:script:Apply-Shelf { param($x) MkF 'Game/S/a.uasset' 'shelf-a'; MkF 'Game/S/b.uasset' 'shelf-b'; MkF 'Game/S/n.uasset' 'shelf-n' }
            try { $done = Apply-DvShelf ([pscustomobject]@{ Id = 'dv.shelf.t1' }) @('Game/S/a.uasset') } finally { Set-Item function:script:Apply-Shelf $origApply }
            T "Diversion shelf: selected files only, the others left as they were" (@($done).Count -eq 1 -and [System.IO.File]::ReadAllText((Full-Path 'Game/S/a.uasset')) -eq 'shelf-a' -and [System.IO.File]::ReadAllText((Full-Path 'Game/S/b.uasset')) -eq 'mine-b' -and -not (Test-Path -LiteralPath (Full-Path 'Game/S/n.uasset')))
            # revert: dv restore simulated; one file held open -> not touched, reported, stays pending
            MkF 'Game/S/a.uasset' 'mine-a2'
            $origDv = ${function:Invoke-Dv}
            Set-Item function:script:Invoke-Dv { param([string[]]$a, [bool]$q) if ($a[0] -eq 'restore') { MkF $a[1] ('base-' + $a[1]) }; return [pscustomobject]@{ Code = 0; Lines = @('Restored') } }
            $lk = [System.IO.File]::Open((Full-Path 'Game/S/b.uasset'), 'Open', 'ReadWrite', 'None')
            $msg = ''
            try { [void](Revert-Items 'x' @([pscustomobject]@{ Kind = 'Modified'; Path = 'Game/S/a.uasset' }, [pscustomobject]@{ Kind = 'Modified'; Path = 'Game/S/b.uasset' })) } catch { $msg = [string]$_ } finally { $lk.Close(); Set-Item function:script:Invoke-Dv $origDv }
            $bk = @(Get-ChildItem -LiteralPath (Full-Path '.dvcl/revert-backup') -Directory)
            T "revert: done where possible, open file reported (not touched), your version copied" ([System.IO.File]::ReadAllText((Full-Path 'Game/S/a.uasset')) -eq 'base-Game/S/a.uasset' -and [System.IO.File]::ReadAllText((Full-Path 'Game/S/b.uasset')) -eq 'mine-b' -and $msg -like '*not reverted*' -and $bk.Count -eq 1 -and [System.IO.File]::ReadAllText((Join-Path $bk[0].FullName 'Game/S/a.uasset')) -eq 'mine-a2')
            Save-LastHead 'main' 'dv.commit.7'; $h = Read-LastHead
            T "launch cache: branch + commit" ($h.Branch -eq 'main' -and $h.Commit -eq 'dv.commit.7')
            Save-DepotCache 'dv.commit.7' ([string[]]@('A/', 'A/b.uasset'))
            $dc = Read-DepotCache 'dv.commit.7'
            T "launch cache: depot list for the same commit only" ($dc.Length -eq 2 -and $dc[1] -eq 'A/b.uasset' -and $null -eq (Read-DepotCache 'dv.commit.8'))
        } finally {
            $script:Root = $saveRoot
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        }
    } finally {
        if (Test-Path $script:Db) { Remove-Item $script:Db -Force }
    }
    Write-Host ""
    $msg = "SELFTEST: " + $script:ok + " passed, " + $script:ko + " failed"
    if ($script:ko -eq 0) { Write-Host $msg -ForegroundColor Green } else { Write-Host $msg -ForegroundColor Red; exit 1 }
}

# Pending files now: offline (sync paused or offline flag) = dvcl's folder scan, as in the window
function Current-Pending {
    if (Test-OfflineFlag) { return [pscustomobject]@{ Files = (Get-OfflinePending); Branch = ''; Commit = ''; Paused = $true; Syncing = $false } }
    $st = Get-Pending
    if ($st.Paused) { $st.Files = Get-OfflinePending }
    return $st
}

# Diversion exchanges files only with sync on: on for this command only, then back off
function With-Sync([scriptblock]$sb) {
    $was = (Test-OfflineFlag) -or (Get-Pending $false).Paused
    if ($was) { Set-Sync $true }
    try { & $sb } finally { if ($was) { Set-Sync $false } }
}

# ---------------------------------------------------------------- main
# dvcl.cmd passes its whole command line in DVCL_LINE (any characters survive); direct runs use $args
$argv = @($args)
$rawLine = $env:DVCL_LINE
if ($null -ne $rawLine) { Remove-Item env:DVCL_LINE; $argv = @(Split-CmdLine $rawLine) }
$cmd = 'status'
if ($argv.Count -gt 0) { $cmd = $argv[0].ToLowerInvariant(); $argv = @($argv | Select-Object -Skip 1) }
# dvcl args ... : prints the arguments as dvcl received them (checks what a script or shell passes)
if ($cmd -eq 'args') { Write-Output ('ARGS ' + $argv.Count + ' :: ' + ($argv -join ' | ')); exit 0 }
$yes = $false
if ($argv -contains '-y') { $yes = $true; $argv = @($argv | Where-Object { $_ -ne '-y' }) }

if ($cmd -in 'help', '-h', '--help', '/?') { Show-Help; exit 0 }
if ($cmd -eq 'selftest') { Run-SelfTest; exit 0 }

$root = Find-DvRoot (Get-Location).Path
if (-not $root) { Write-Host "Not inside a Diversion workspace (no .diversion folder above $((Get-Location).Path)). cd into your repo first." -ForegroundColor Red; exit 1 }
Set-DvRoot $root
# a changelist can be given by its number: dvcl submit 12 (or CL12, #12)
if ($cmd -in 'desc', 'add', 'move', 'mv', 'delete', 'submit', 'revert', 'shelve' -and $argv.Count -gt 0 -and $argv[0] -match '^(#|cl ?)?\d+$') {
    Load-Db; $c = Find-CL $argv[0]; if ($c) { $argv[0] = $c.name }
}
Write-Log ("==== dvcl " + $cmd + " " + ($argv -join ' '))

try {
    switch ($cmd) {
        'report' {
            $lines = @(Get-Content -LiteralPath $script:Log -Tail 200 -Encoding UTF8)
            ($lines -join "`r`n") | Set-Clipboard
            Write-Host ("Copied the last " + $lines.Count + " log lines to the clipboard.") -ForegroundColor Green
        }

        { $_ -in 'status', 'st', 'list', 'ls' } {
            $st = Get-Pending $false
            $sync = 'sync on'
            if ($st.Syncing) { $sync = 'sync on, still syncing (list may be incomplete)' }
            if ($st.Paused -or (Test-OfflineFlag)) {
                $st.Files = Get-OfflinePending
                $sync = 'OFFLINE: pending files from dvcl''s folder scan (dvcl sync on = go online)'
                if ($script:BaselineFresh) { $sync += '; tracking started now, earlier offline edits may be missing' }
            } elseif (-not $st.Syncing) { Save-LastStatus $st.Files }
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
            $st = Current-Pending
            $sel = Select-Pending $st.Files $specs
            foreach ($p in $sel) { Say ("   -> " + $name + " : " + $p.Path) }
            Move-ToCL $name $sel
        }

        { $_ -in 'remove', 'rm' } {
            if ($argv.Count -eq 0) { Fail "nothing to remove" }
            $st = Current-Pending
            $sel = Select-Pending $st.Files $argv
            Move-ToCL 'default' $sel
        }

        'delete' { Remove-CL $argv[0] }

        'submit' {
            $name = $argv[0]; if (-not $name) { Fail "usage: dvcl submit <cl>  |  dvcl submit default ""message""" }
            $st = Get-Pending
            if ($st.Paused -or (Test-OfflineFlag)) { Fail "offline: submit needs Diversion online. Run: dvcl sync on" }
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
            $pre = Get-CLItems (Current-Pending).Files $name
            if ($pre.Count -eq 0) { Fail "no pending files in this changelist" }
            Say ("Revert '" + $name + "' : local changes will be DISCARDED (your versions copied to .dvcl\revert-backup)") 'Cyan'
            foreach ($p in $pre) { Say ("   {0}  {1}" -f (Kind-Letter $p.Kind), $p.Path) }
            Confirm-Or-Exit ("Revert these " + $pre.Count + " path(s)?") $yes
            With-Sync { $items = Get-CLItems (Get-Pending).Files $name; [void](Revert-Items $name $items) }
        }

        'shelve' {
            $name = $argv[0]; if (-not $name) { Fail "usage: dvcl shelve <cl>" }
            if ((Get-CLItems (Current-Pending).Files $name).Count -eq 0) { Fail "no pending files in this changelist" }
            With-Sync { [void](Shelve-Items ($name + "_" + (Get-Date -Format 'yyyyMMdd-HHmm')) (Get-CLItems (Get-Pending).Files $name)) }
        }

        'shelves' {
            # dv shelf / dv shelf show work with sync paused
            $sh = @(Get-LocalShelves) + @(Get-Shelves)
            if ($sh.Count -eq 0) { Say "No shelves." }
            foreach ($s in $sh) {
                if ($s.Local) { Say ("  local      " + $s.Id + "   (" + $s.Created + ")  -> " + (Shelf-ClName $s)) 'Cyan' }
                else {
                    $fl = Read-ShelfFiles $s.Id; if ($null -eq $fl) { $fl = Fetch-ShelfFiles $s.Id }
                    $s.Files = @($fl)
                    Say ("  diversion  " + $s.Name + "   (" + $s.Created + ")  -> " + (Shelf-ClName $s)) 'Cyan'
                }
                foreach ($f in @($s.Files)) { Say ("      {0}  {1}" -f (Kind-Letter $f.Kind), $f.Path) }
            }
        }

        'get' { Get-Latest }

        'sync' {
            $a = ([string]$argv[0]).ToLowerInvariant()
            if ($a -in 'on', 'resume') { Set-Sync $true } elseif ($a -in 'off', 'pause') { Set-Sync $false } else { Fail "usage: dvcl sync on|off" }
        }

        'clean' {
            $st = Get-Pending $false
            if ($st.Paused -or (Test-OfflineFlag)) { [void](Clean-Stale (Get-OfflinePending) ([string]$argv[0]) $false) }
            else { [void](Clean-Stale (Get-Pending $true).Files ([string]$argv[0]) $false) }
        }

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

        { $_ -in 'lock', 'unlock' } {
            if ($argv.Count -eq 0) { Fail ("usage: dvcl " + $cmd + " <file...>") }
            Lock-Paths @($argv | ForEach-Object { Norm $_ }) ($cmd -eq 'lock')
        }

        'locks' { $l = Get-Locks; if ($l.Count -eq 0) { Say "No locks." } else { foreach ($x in $l) { Say $x } } }

        'folder' {
            $a = ([string]$argv[0]).ToLowerInvariant()
            if (-not $argv[1] -or $a -notin 'on', 'off') { Fail "usage: dvcl folder on|off <folder>" }
            Set-FolderSync $argv[1] ($a -eq 'on')
        }

        'unshelve' {
            if (-not $argv[0]) { Fail "usage: dvcl unshelve <shelf name or id> [<cl>]" }
            $loc = @(Get-LocalShelves | Where-Object { $_.Id -ieq $argv[0] })
            if ($loc.Count) { $sh = $loc[0]; Apply-LocalShelf $sh.Id; $done = @($sh.Files) }
            else {
                $sh = @(Get-Shelves | Where-Object { $_.Id -ieq $argv[0] -or $_.Name -ieq $argv[0] })
                if ($sh.Count -eq 0) { Fail ("no shelf '" + $argv[0] + "' (dvcl shelves)") }
                $sh = $sh[0]; $script:UnDone = $null
                With-Sync { $script:UnDone = Apply-DvShelf $sh $null }
                $done = @($script:UnDone)
            }
            $to = $(if ($argv[1]) { [string]$argv[1] } else { Shelf-ClName $sh }); $tc = Find-CL $to; if ($tc) { $to = $tc.name }
            if ($to -ine 'default' -and $done.Count) { Move-ToCL $to $done }
        }

        default { Write-Host ("Unknown command '" + $cmd + "'.") -ForegroundColor Red; Show-Help; exit 1 }
    }
} catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
