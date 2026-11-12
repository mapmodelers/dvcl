# DvclViews.ps1 - Submitted and History panels (dot-sourced by dvcl-gui.ps1).
# Submitted: the branch's commits (dv log), newest first; commits not in your workspace yet are
#   highlighted (Get latest). Optional path = only commits touching it.
# History: the same list for one file or folder; follows the selection (trees, changelists,
#   submitted files) while it is on screen.
# Pick a commit: its files below (dv show --name-status). Both read Diversion in the background.

$script:Views = @{}
$script:CommitFiles = @{}   # commit id -> files (commits never change)

function New-CommitView([string]$key) {
    $root = New-Object System.Windows.Forms.Panel
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Top'; $bar.Height = 28; $bar.Padding = New-Object System.Windows.Forms.Padding(2, 3, 2, 2)
    $path = New-Object System.Windows.Forms.TextBox; $path.Dock = 'Fill'; $path.Font = $fontMono; $path.Tag = $key
    $tip = New-Object System.Windows.Forms.ToolTip
    $bRef = New-Object System.Windows.Forms.Button; $bRef.Text = 'Refresh'; $bRef.Dock = 'Right'; $bRef.Width = 64; $bRef.FlatStyle = 'System'; $bRef.Tag = $key
    $bMore = New-Object System.Windows.Forms.Button; $bMore.Text = 'More'; $bMore.Dock = 'Right'; $bMore.Width = 52; $bMore.FlatStyle = 'System'; $bMore.Tag = $key
    $filter = New-Object System.Windows.Forms.TextBox; $filter.Dock = 'Right'; $filter.Width = 150; $filter.Tag = $key
    $tip.SetToolTip($filter, 'Filter: text, author or commit number')
    $tip.SetToolTip($bMore, 'Load 100 more commits')
    $follow = $null
    if ($key -eq 'history') {
        $follow = New-Object System.Windows.Forms.CheckBox; $follow.Text = 'Follow'; $follow.Dock = 'Right'; $follow.Width = 64; $follow.Checked = $true; $follow.Tag = $key
        $follow.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
        $tip.SetToolTip($follow, 'Show the history of whatever file or folder you select')
        $tip.SetToolTip($path, 'File or folder (Enter = show its history)')
    } else { $tip.SetToolTip($path, 'Only commits touching this file or folder (empty = all; Enter = apply)') }
    $bar.Controls.Add($path); $bar.Controls.Add($filter); if ($follow) { $bar.Controls.Add($follow) }; $bar.Controls.Add($bMore); $bar.Controls.Add($bRef)
    $info = New-Object System.Windows.Forms.LinkLabel
    $info.Dock = 'Top'; $info.Height = 20; $info.TextAlign = 'MiddleLeft'; $info.Padding = New-Object System.Windows.Forms.Padding(4, 0, 0, 0); $info.Tag = $key
    $info.LinkBehavior = 'HoverUnderline'
    $sc = New-Object System.Windows.Forms.SplitContainer; $sc.Dock = 'Fill'; $sc.Orientation = 'Horizontal'
    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.HideSelection = $false; $list.ShowItemToolTips = $true; $list.Tag = $key
    foreach ($c in @(@('Commit', 70), @('Date', 120), @('Author', 120), @('Description', 520))) { [void]$list.Columns.Add($c[0], $c[1]) }
    $files = New-Object System.Windows.Forms.ListView
    $files.Dock = 'Fill'; $files.View = 'Details'; $files.FullRowSelect = $true; $files.MultiSelect = $false; $files.HideSelection = $false; $files.SmallImageList = $icons; $files.Tag = $key
    [void]$files.Columns.Add('Files of the selected commit', 900)
    $sc.Panel1.Controls.Add($list); $sc.Panel2.Controls.Add($files)
    $root.Controls.Add($sc); $root.Controls.Add($info); $root.Controls.Add($bar)
    $v = [pscustomobject]@{ Key = $key; Root = $root; Path = $path; Filter = $filter; Follow = $follow; Info = $info; Split = $sc; List = $list; Files = $files
        Limit = 100; Commits = @(); Raw = @(); Loading = $false; Again = $false; Want = ''; Loaded = ''; FilesLoading = ''; FilesNext = ''; Newer = 0
    }
    $script:Views[$key] = $v

    $path.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Return') { $e.Handled = $true; $e.SuppressKeyPress = $true; Load-Commits $s.Tag $true } })
    $bRef.Add_Click({ param($s, $e) Load-Commits $s.Tag $true })
    $bMore.Add_Click({ param($s, $e) $vv = $script:Views[$s.Tag]; $vv.Limit = [Math]::Min(1000, $vv.Limit + 100); Load-Commits $s.Tag $true })
    $filter.Add_TextChanged({ param($s, $e) Fill-Commits $script:Views[$s.Tag] })
    $info.Add_LinkClicked({ param($s, $e) Do-GetLatest })
    $list.Add_SelectedIndexChanged({ param($s, $e) if ($s.SelectedItems.Count -eq 1 -and $s.SelectedItems[0].Tag) { Load-Files $s.Tag $s.SelectedItems[0].Tag.Id } })
    $list.Add_MouseUp({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-CommitMenu $s $e.Location } })
    $files.Add_MouseUp({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-FileMenu $s $e.Location } })
    $files.Add_DoubleClick({ param($s, $e) $p = View-SelFile $s; if ($p) { Navigate-Tree 'depot' $p } })
    $files.Add_SelectedIndexChanged({ param($s, $e) if ($s.Tag -eq 'submitted') { $p = View-SelFile $s; if ($p) { History-Follow $p } } })
    return $v
}

# Path box -> repo path ('' = whole repo)
function View-Path($v) {
    $t = ([string]$v.Path.Text).Trim().Trim('"')
    if (-not $t) { return '' }
    return (Norm $t)
}

function Load-Commits([string]$key, [bool]$force = $false) {
    $v = $script:Views[$key]; if (-not $v -or -not $script:Root) { return }
    $path = View-Path $v
    if ($key -eq 'history' -and -not $path) { $v.List.Items.Clear(); $v.Files.Items.Clear(); Set-ViewInfo $v 'Select a file or folder: its commits show here.' $false; return }
    if ($path -match '^[A-Za-z]:') { Set-ViewInfo $v ('Not inside this workspace: ' + $path) $false; return }
    $want = $script:Root + '|' + $path + '|' + $v.Limit
    if (-not $force -and $want -eq $v.Loaded) { return }
    if ($v.Loading) { $v.Again = $true; return }
    $v.Loading = $true; $v.Want = $want
    Set-ViewInfo $v ('Reading commits' + $(if ($path) { ' of ' + $path } else { '' }) + '...') $false
    $a = @('log'); if ($path) { $a += $path }; $a += @('-n', [string]$v.Limit, '--date', 'iso')
    Start-DvAsync $a ('Apply-Log' + $(if ($key -eq 'history') { 'History' } else { 'Submitted' })) $true $false ''
}
function Apply-LogSubmitted($r) { Apply-Log 'submitted' $r }
function Apply-LogHistory($r) { Apply-Log 'history' $r }
function Apply-Log([string]$key, $r) {
    $v = $script:Views[$key]
    $v.Loading = $false
    if ($v.Again) { $v.Again = $false; Load-Commits $key; return }
    $v.Raw = @($r.Lines)
    if ($r.Code -ne 0) {
        $v.Loaded = ''; $v.Commits = @(); $v.List.Items.Clear(); $v.Files.Items.Clear()
        Set-ViewInfo $v ('Diversion did not answer: ' + ((@($r.Lines) | Where-Object { $_.Trim() } | Select-Object -Last 1) -join '')) $false
        return
    }
    $v.Loaded = $v.Want
    $v.Commits = @(Parse-Log $r.Lines)
    Fill-Commits $v
}

function Set-ViewInfo($v, [string]$text, [bool]$getLink) {
    $v.Info.Text = $text
    $v.Info.Links.Clear()
    $i = $text.IndexOf('Get latest')
    if ($getLink -and $i -ge 0) { [void]$v.Info.Links.Add($i, 10) }
}

function Short-Date([string]$d) { return (Format-CommitDate $d) }

# Fills the commit list (filter applied here, no dv call)
function Fill-Commits($v) {
    $ws = Commit-Num $script:WsCommit
    $f = ([string]$v.Filter.Text).Trim()
    $selId = $null; if ($v.List.SelectedItems.Count -eq 1 -and $v.List.SelectedItems[0].Tag) { $selId = $v.List.SelectedItems[0].Tag.Id }
    $v.List.BeginUpdate(); $v.List.Items.Clear()
    $newer = 0; $shown = 0
    foreach ($c in @($v.Commits)) {
        if ($ws -gt 0 -and $c.Num -gt $ws) { $newer++ }
        if ($f -and -not (($c.Desc + ' ' + $c.Author + ' ' + $c.Num + ' ' + $c.Id) -like ('*' + $f + '*'))) { continue }
        $it = New-Object System.Windows.Forms.ListViewItem([string]$c.Num)
        [void]$it.SubItems.Add((Short-Date $c.Date)); [void]$it.SubItems.Add($c.Author); [void]$it.SubItems.Add((($c.Desc -split "`n") -join '  |  '))
        $it.Tag = $c
        $it.ToolTipText = $c.Id + '  ' + $c.Author + '  ' + $c.Date + "`n" + $c.Desc
        if ($ws -gt 0 -and $c.Num -gt $ws) { $it.ForeColor = $script:Pal.Link; $it.ToolTipText = "Not in your workspace yet (Get latest)`n" + $it.ToolTipText }
        elseif ($ws -gt 0 -and $c.Num -eq $ws) { $it.Font = $fontBold; $it.ToolTipText = "Your workspace is at this commit`n" + $it.ToolTipText }
        elseif ($ws -gt 0) { $it.ForeColor = $script:Pal.Fore }
        [void]$v.List.Items.Add($it); $shown++
        if ($selId -and $c.Id -eq $selId) { $it.Selected = $true }
    }
    # unknown output format: show dv's lines as they are (nothing lost)
    if ($v.Commits.Count -eq 0) {
        foreach ($l in @($v.Raw | Where-Object { $_.Trim() } | Select-Object -First 200)) {
            $it = New-Object System.Windows.Forms.ListViewItem(''); [void]$it.SubItems.Add(''); [void]$it.SubItems.Add(''); [void]$it.SubItems.Add($l); [void]$v.List.Items.Add($it)
        }
    }
    $v.List.EndUpdate()
    $v.Newer = $newer
    $p = View-Path $v
    $txt = [string]$v.Commits.Count + ' commit' + $(if ($v.Commits.Count -ne 1) { 's' } else { '' }) + $(if ($p) { ' touching ' + $p } else { ' on ' + $script:Branch })
    if ($f) { $txt += ', ' + $shown + ' match' }
    if ($v.Commits.Count -ge $v.Limit) { $txt += '  (More = older)' }
    if ($newer -gt 0) { $txt += '   -   ' + $newer + ' not in your workspace: Get latest' }
    Set-ViewInfo $v $txt ($newer -gt 0)
}

# Files of one commit (cached: a commit never changes)
function Load-Files([string]$key, [string]$id) {
    $v = $script:Views[$key]; if (-not $v -or -not $id) { return }
    if ($script:CommitFiles.ContainsKey($id)) { Fill-Files $v $script:CommitFiles[$id]; return }
    if ($v.FilesLoading) { $v.FilesNext = $id; return }
    $v.FilesLoading = $id
    $v.Files.Items.Clear(); [void]$v.Files.Items.Add('Reading files of ' + $id + '...')
    Start-DvAsync @('show', $id, '--name-status', '--color', 'never') ('Apply-Show' + $(if ($key -eq 'history') { 'History' } else { 'Submitted' })) $true $false ''
}
function Apply-ShowSubmitted($r) { Apply-Show 'submitted' $r }
function Apply-ShowHistory($r) { Apply-Show 'history' $r }
function Apply-Show([string]$key, $r) {
    $v = $script:Views[$key]
    $id = $v.FilesLoading; $v.FilesLoading = ''
    $res = [pscustomobject]@{ Files = @(Parse-ShowFiles $r.Lines); Raw = @($r.Lines); Ok = ($r.Code -eq 0) }
    if ($res.Ok) { $script:CommitFiles[$id] = $res }
    if ($v.FilesNext) { $n = $v.FilesNext; $v.FilesNext = ''; Load-Files $key $n; return }
    $sel = $null; if ($v.List.SelectedItems.Count -eq 1 -and $v.List.SelectedItems[0].Tag) { $sel = $v.List.SelectedItems[0].Tag.Id }
    if ($sel -eq $id) { Fill-Files $v $res }
}
function Fill-Files($v, $res) {
    $v.Files.BeginUpdate(); $v.Files.Items.Clear()
    $hp = $(if ($v.Key -eq 'history') { View-Path $v } else { '' })
    foreach ($fi in @($res.Files)) {
        $it = New-Object System.Windows.Forms.ListViewItem($fi.Path)
        $it.ImageKey = 'file-' + $fi.Kind; $it.ForeColor = $colKind[$fi.Kind]; $it.Tag = $fi.Path
        # history of one file: that file first, in bold
        if ($hp -and ($fi.Path -ieq $hp)) { $it.Font = $fontBold; [void]$v.Files.Items.Insert(0, $it) } else { [void]$v.Files.Items.Add($it) }
    }
    if (@($res.Files).Count -eq 0) { foreach ($l in @($res.Raw | Where-Object { $_.Trim() })) { [void]$v.Files.Items.Add($l) } }
    $v.Files.EndUpdate()
}

function View-SelFile($lv) { if ($lv.SelectedItems.Count -eq 1 -and $lv.SelectedItems[0].Tag) { return [string]$lv.SelectedItems[0].Tag }; return $null }

# ---- History: follow the selection while on screen (short delay: arrow keys stay fast)
$script:HistWant = ''
$histTimer = New-Object System.Windows.Forms.Timer
$histTimer.Interval = 350
$histTimer.Add_Tick({ $histTimer.Stop(); $v = $script:Views['history']; if ($v -and $script:HistWant) { $v.Path.Text = $script:HistWant; Load-Commits 'history' } })
function History-Follow([string]$rel) {
    $v = $script:Views['history']
    if (-not $v -or -not $rel -or -not $v.Follow.Checked -or -not (Pad-Showing 'history')) { return }
    $script:HistWant = $rel; $histTimer.Stop(); $histTimer.Start()
}
# "History..." in menus: show the panel on that path
function Show-History([string]$rel) {
    $v = $script:Views['history']; if (-not $v -or -not $rel) { return }
    $v.Path.Text = $rel
    Activate-Pad 'history'
    Load-Commits 'history'
}

# A panel came on screen: load it if needed
$script:OnPadShown = { param($id) if ($id -eq 'submitted' -or $id -eq 'history') { Load-Commits $id } }

# After each status read: a new workspace commit (get latest, submit) reloads the panels on
# screen (the others on their next showing); otherwise only first loads and recolor.
$script:ViewsWs = $null
function Views-Refresh {
    $chg = ($script:ViewsWs -ne $script:WsCommit); $script:ViewsWs = $script:WsCommit
    foreach ($k in @($script:Views.Keys)) {
        $v = $script:Views[$k]
        if (Pad-Showing $k) { Load-Commits $k $chg }
        else { if ($chg) { $v.Loaded = '' }; if ($v.Commits.Count) { Fill-Commits $v } }
    }
}

# ---- menus
$script:ViewMenu = New-Object System.Windows.Forms.ContextMenuStrip
function Show-CommitMenu($lv, $loc) {
    if ($lv.SelectedItems.Count -ne 1 -or -not $lv.SelectedItems[0].Tag) { return }
    $c = $lv.SelectedItems[0].Tag; $script:MenuCommit = $c
    $m = $script:ViewMenu; $m.Items.Clear()
    $ws = Commit-Num $script:WsCommit
    [void](Add-MenuItem $m 'Get latest' { Do-GetLatest } ($ws -gt 0 -and $c.Num -gt $ws))
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $m 'Copy commit id' { [System.Windows.Forms.Clipboard]::SetText($script:MenuCommit.Id) })
    [void](Add-MenuItem $m 'Copy description' { [System.Windows.Forms.Clipboard]::SetText($script:MenuCommit.Desc) } ([bool]$c.Desc))
    Theme-Strip $m; $m.Show($lv, $loc)
}
function Show-FileMenu($lv, $loc) {
    $p = View-SelFile $lv; if (-not $p) { return }
    $script:MenuFile = $p
    $c = $null; $lst = $script:Views[$lv.Tag].List; if ($lst.SelectedItems.Count -eq 1) { $c = $lst.SelectedItems[0].Tag }
    $script:MenuCommit = $c
    $m = $script:ViewMenu; $m.Items.Clear()
    [void](Add-MenuItem $m 'Show in Local tree' { Navigate-Tree 'local' $script:MenuFile })
    [void](Add-MenuItem $m 'Show in Depot tree' { Navigate-Tree 'depot' $script:MenuFile })
    [void](Add-MenuItem $m 'History' { Show-History $script:MenuFile })
    [void](Add-MenuItem $m 'Diff: this commit vs your workspace (text files)' { Do-DiffAt $script:MenuFile $script:MenuCommit.Id } ([bool]$c))
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $m 'Show in Explorer' { Open-InExplorer (Full-Path $script:MenuFile) })
    [void](Add-MenuItem $m 'Copy path' { [System.Windows.Forms.Clipboard]::SetText($script:MenuFile) })
    Theme-Strip $m; $m.Show($lv, $loc)
}
function Do-DiffAt([string]$rel, [string]$id) {
    if (-not $rel -or -not $id) { return }
    $script:diffOut = $null
    Run-Busy { $script:diffOut = Invoke-Dv @('diff', $rel, '--base', $id, '--color', 'never') $true } 'Comparing'
    if ($script:diffOut) {
        $l = @($script:diffOut.Lines); if ($l.Count -eq 0) { $l = @('(no difference)') }
        Show-TextDialog ('Diff ' + $rel + '  (' + $id + ' -> your workspace)') $l
    }
}
