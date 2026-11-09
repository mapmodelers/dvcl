# dvcl-gui.ps1 - "Pending changelists" window for Diversion.
# Launch with dvcl-gui.cmd (needs -STA). Optional arg: a folder inside a Diversion workspace.

param([string]$StartDir = '', [switch]$SelfCheck)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Window is launched without a console: show fatal errors in a message box
trap { [void][System.Windows.Forms.MessageBox]::Show(($_.Exception.Message + "`r`n`r`n" + $_.InvocationInfo.PositionMessage), 'dvcl - fatal error', 'OK', 'Error'); break }
. (Join-Path $PSScriptRoot 'DvclCore.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- settings (last repo, window size)
$script:SettingsFile = Join-Path $env:APPDATA 'dvcl\settings.json'
function Load-Settings {
    try { if (Test-Path -LiteralPath $script:SettingsFile) { return (Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json) } } catch {}
    return [pscustomobject]@{ lastRepo = ''; w = 980; h = 640 }
}
function Save-Settings {
    try {
        $dir = Split-Path -Parent $script:SettingsFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        [pscustomobject]@{ lastRepo = [string]$script:Root; w = $form.Width; h = $form.Height } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch {}
}
$settings = Load-Settings

# ---------------------------------------------------------------- tool info (update, bug report)
$script:ToolDir = Split-Path -Parent $PSScriptRoot
$script:GhRepo  = 'mapmodelers/dvcl'
function Get-LocalVersion {
    try { return (Get-Content -LiteralPath (Join-Path $script:ToolDir 'VERSION') -Raw).Trim() } catch { return '0.0.0' }
}

# ---------------------------------------------------------------- look
$fontUi   = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)
$colKind = @{
    'A' = [System.Drawing.Color]::FromArgb(0, 120, 215)
    'M' = [System.Drawing.Color]::FromArgb(30, 30, 30)
    'D' = [System.Drawing.Color]::FromArgb(200, 40, 40)
    'R' = [System.Drawing.Color]::FromArgb(140, 80, 0)
    '!' = [System.Drawing.Color]::FromArgb(200, 0, 160)
    '?' = [System.Drawing.Color]::Gray
}

# ---------------------------------------------------------------- main window
$form = New-Object System.Windows.Forms.Form
$form.Text = 'dvcl - Pending changelists'
$form.Font = $fontUi
$form.StartPosition = 'CenterScreen'
$form.Width = [int]$settings.w; $form.Height = [int]$settings.h
$form.MinimumSize = New-Object System.Drawing.Size(640, 400)
$form.KeyPreview = $true
$ico = Join-Path $script:ToolDir 'dvcl.ico'
if (Test-Path -LiteralPath $ico) { $form.Icon = New-Object System.Drawing.Icon($ico) }

$tool = New-Object System.Windows.Forms.ToolStrip
$tool.GripStyle = 'Hidden'
function Add-Btn([string]$text, [string]$tip, [scriptblock]$onClick) {
    $b = New-Object System.Windows.Forms.ToolStripButton
    $b.Text = $text; $b.ToolTipText = $tip; $b.DisplayStyle = 'Text'
    $b.Add_Click($onClick)
    [void]$tool.Items.Add($b)
    return $b
}

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

$tv = New-Object System.Windows.Forms.TreeView
$tv.Dock = 'Fill'; $tv.CheckBoxes = $true; $tv.HideSelection = $false; $tv.FullRowSelect = $true
$tv.ShowLines = $true; $tv.AllowDrop = $true; $tv.ItemHeight = 20
$tv.Font = $fontBold   # changelist rows bold; file rows set back to regular (avoids clipped bold text)
# Tabs: Pending (changelists) / Local (workspace folder) / Depot (repository at the workspace revision)
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabPending = New-Object System.Windows.Forms.TabPage('Pending')
$tabLocal   = New-Object System.Windows.Forms.TabPage('Local')
$tabDepot   = New-Object System.Windows.Forms.TabPage('Depot')
$tabs.TabPages.AddRange(@($tabPending, $tabLocal, $tabDepot))
$tabPending.Controls.Add($tv)
function New-BrowseTree {
    $t = New-Object System.Windows.Forms.TreeView
    $t.Dock = 'Fill'; $t.HideSelection = $false; $t.FullRowSelect = $true; $t.ItemHeight = 20; $t.Font = $fontUi
    return $t
}
$tvLocal = New-BrowseTree; $tabLocal.Controls.Add($tvLocal)
$tvDepot = New-BrowseTree; $tabDepot.Controls.Add($tvDepot)
$split.Panel1.Controls.Add($tabs)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Dock = 'Fill'; $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.Font = $fontMono; $logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250); $logBox.WordWrap = $false
$split.Panel2.Controls.Add($logBox)

$status = New-Object System.Windows.Forms.StatusStrip
$statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLbl.Spring = $true; $statusLbl.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusLbl)

$form.Controls.Add($split)
$form.Controls.Add($tool)
$form.Controls.Add($status)

$script:OnSay = {
    param($t, $c)
    $logBox.AppendText((Get-Date -Format 'HH:mm:ss') + '  ' + $t + "`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}
$script:OnDv = {
    param($l)
    $logBox.AppendText('          dv | ' + $l + "`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------------------------------------------------------------- helpers
$script:Pending = @()
$script:Busy = $false

function Run-Busy([scriptblock]$sb) {
    if ($script:Busy) { return }
    $script:Busy = $true
    $form.UseWaitCursor = $true; $tool.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    try { & $sb }
    catch {
        $m = $_.Exception.Message
        & $script:OnSay ("ERROR: " + $m) 'Red'
        [void][System.Windows.Forms.MessageBox]::Show($form, $m, 'dvcl', 'OK', 'Error')
    }
    finally { $form.UseWaitCursor = $false; $tool.Enabled = $true; $script:Busy = $false }
}

function Ask-YesNo([string]$text, [string]$title = 'dvcl') {
    return ([System.Windows.Forms.MessageBox]::Show($form, $text, $title, 'YesNo', 'Warning') -eq 'Yes')
}

# Small modal dialog: optional single-line name + optional multi-line text. Returns $null on cancel.
function Show-Dialog([string]$title, [string]$nameLabel, [string]$nameValue, [string]$textLabel, [string]$textValue) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title; $d.Font = $fontUi; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'; $d.Width = 460; $d.ShowInTaskbar = $false
    $y = 12; $nameTb = $null; $textTb = $null
    if ($nameLabel) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $nameLabel; $l.Left = 12; $l.Top = $y; $l.AutoSize = $true; $d.Controls.Add($l); $y += 20
        $nameTb = New-Object System.Windows.Forms.TextBox; $nameTb.Left = 12; $nameTb.Top = $y; $nameTb.Width = 420; $nameTb.Text = $nameValue; $d.Controls.Add($nameTb); $y += 34
    }
    if ($textLabel) {
        $l2 = New-Object System.Windows.Forms.Label; $l2.Text = $textLabel; $l2.Left = 12; $l2.Top = $y; $l2.AutoSize = $true; $d.Controls.Add($l2); $y += 20
        $textTb = New-Object System.Windows.Forms.TextBox; $textTb.Left = 12; $textTb.Top = $y; $textTb.Width = 420; $textTb.Height = 90
        $textTb.Multiline = $true; $textTb.ScrollBars = 'Vertical'; $textTb.AcceptsReturn = $true; $textTb.Text = $textValue; $d.Controls.Add($textTb); $y += 100
    }
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.Left = 276; $ok.Top = $y; $ok.Width = 75; $ok.DialogResult = 'OK'
    $ca = New-Object System.Windows.Forms.Button; $ca.Text = 'Cancel'; $ca.Left = 357; $ca.Top = $y; $ca.Width = 75; $ca.DialogResult = 'Cancel'
    $d.Controls.Add($ok); $d.Controls.Add($ca); $d.AcceptButton = $ok; $d.CancelButton = $ca
    $d.ClientSize = New-Object System.Drawing.Size(446, ($y + 36))
    $res = $d.ShowDialog($form)
    if ($res -ne 'OK') { return $null }
    $n = ''; $t = ''
    if ($nameTb) { $n = $nameTb.Text.Trim() }
    if ($textTb) { $t = $textTb.Text.Trim() }
    return [pscustomobject]@{ Name = $n; Text = $t }
}

# Submit dialog: description + checked file list. Returns $null or { Desc; Items }
function Show-SubmitDialog([string]$clName, [string]$desc, $items) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = "Submit changelist '" + $clName + "'"; $d.Font = $fontUi; $d.StartPosition = 'CenterParent'
    $d.Width = 760; $d.Height = 520; $d.MinimumSize = New-Object System.Drawing.Size(500, 360); $d.ShowInTaskbar = $false
    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Description:'; $l.Dock = 'Top'; $l.Height = 20
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.Dock = 'Top'; $tb.Height = 90; $tb.ScrollBars = 'Vertical'; $tb.AcceptsReturn = $true; $tb.Text = $desc
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'Files (uncheck to leave them pending):'; $l2.Dock = 'Top'; $l2.Height = 24; $l2.TextAlign = 'BottomLeft'
    $cl = New-Object System.Windows.Forms.CheckedListBox; $cl.Dock = 'Fill'; $cl.CheckOnClick = $true; $cl.Font = $fontMono; $cl.HorizontalScrollbar = $true
    foreach ($p in $items) { [void]$cl.Items.Add(((Kind-Letter $p.Kind) + '  ' + $p.Path), $true) }
    $bar = New-Object System.Windows.Forms.Panel; $bar.Dock = 'Bottom'; $bar.Height = 40
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Submit'; $ok.Width = 90; $ok.Anchor = 'Top,Right'; $ok.Top = 8; $ok.Left = $bar.Width - 200
    $ca = New-Object System.Windows.Forms.Button; $ca.Text = 'Cancel'; $ca.Width = 90; $ca.Anchor = 'Top,Right'; $ca.Top = 8; $ca.Left = $bar.Width - 100; $ca.DialogResult = 'Cancel'
    $bar.Controls.Add($ok); $bar.Controls.Add($ca)
    $ok.Add_Click({
        if (-not $tb.Text.Trim()) { [void][System.Windows.Forms.MessageBox]::Show($d, 'A description is required.', 'Submit', 'OK', 'Warning'); return }
        if ($cl.CheckedIndices.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($d, 'No file checked.', 'Submit', 'OK', 'Warning'); return }
        $d.DialogResult = 'OK'; $d.Close()
    })
    $d.Controls.Add($cl); $d.Controls.Add($l2); $d.Controls.Add($tb); $d.Controls.Add($l); $d.Controls.Add($bar)
    $d.CancelButton = $ca
    $d.Add_Shown({ $ok.Left = $bar.ClientSize.Width - 200; $ca.Left = $bar.ClientSize.Width - 100; $tb.Focus() })
    if ($d.ShowDialog($form) -ne 'OK') { return $null }
    $sel = @(); foreach ($i in $cl.CheckedIndices) { $sel += $items[$i] }
    return [pscustomobject]@{ Desc = $tb.Text.Trim(); Items = $sel }
}

# ---------------------------------------------------------------- tree
function Build-Tree {
    $tv.BeginUpdate()
    $tv.Nodes.Clear()
    $names = @('default') + @($script:CLs | ForEach-Object { $_.name })
    foreach ($name in $names) {
        $items = Get-CLItems $script:Pending $name
        $label = $name
        if ($name -ne 'default') {
            $c = Find-CL $name
            if ($c.desc) {
                $d = ($c.desc -replace '\s+', ' ').Trim()
                # name derived from the description: show the description only
                if ($name.StartsWith((Slug-Base (($c.desc -split "`n")[0])), [StringComparison]::OrdinalIgnoreCase)) { $label = $d } else { $label = $name + '   ' + $d }
            }
        }
        $n = New-Object System.Windows.Forms.TreeNode(($label + '   (' + $items.Count + ')'))
        $n.Tag = [pscustomobject]@{ Type = 'cl'; Name = $name }
        foreach ($p in $items) {
            $k = Kind-Letter $p.Kind
            $f = New-Object System.Windows.Forms.TreeNode(($k + '   ' + $p.Path))
            $f.Tag = [pscustomobject]@{ Type = 'file'; Item = $p; Cl = $name }
            $f.ForeColor = $colKind[$k]
            $f.NodeFont = $fontUi
            [void]$n.Nodes.Add($f)
        }
        [void]$tv.Nodes.Add($n)
    }
    $tv.ExpandAll()
    if ($tv.Nodes.Count -gt 0) { $tv.Nodes[0].EnsureVisible() }
    $tv.EndUpdate()
}

function Refresh-All {
    Run-Busy {
        if (-not $script:Root) { $statusLbl.Text = 'No Diversion repo selected (Repo...)'; $tv.Nodes.Clear(); return }
        Load-Db
        $st = Get-Pending
        $script:Pending = $st.Files
        $script:PendingByPath = @{}
        foreach ($p in $st.Files) { $script:PendingByPath[$p.Path] = $p }
        if ((Prune $st.Files) -gt 0) { Save-Db }
        Build-Tree
        $script:LocalBuilt = $false; $script:DepotPaths = $null
        Show-Tab
        $statusLbl.Text = $script:Root + '    branch ' + $st.Branch + '    ' + $st.Commit + '    ' + $st.Files.Count + ' pending path(s)'
        $form.Text = 'dvcl - ' + (Split-Path -Leaf $script:Root) + ' - Pending changelists'
    }
}

# Changelist of the selected node ('default' if nothing selected)
function Selected-CL {
    $n = $tv.SelectedNode
    if (-not $n) { return 'default' }
    if ($n.Tag.Type -eq 'cl') { return $n.Tag.Name }
    return $n.Tag.Cl
}

# Target files: checked files, else the selected file, else all files of the selected changelist
function Target-Items {
    $sel = New-Object System.Collections.ArrayList
    foreach ($cn in $tv.Nodes) { foreach ($fn in $cn.Nodes) { if ($fn.Checked) { [void]$sel.Add($fn.Tag.Item) } } }
    if ($sel.Count -gt 0) { return ,$sel.ToArray() }
    $n = $tv.SelectedNode
    if (-not $n) { return ,@() }
    if ($n.Tag.Type -eq 'file') { return ,@($n.Tag.Item) }
    return ,@(Get-CLItems $script:Pending $n.Tag.Name)
}

# ---------------------------------------------------------------- actions
function Do-NewCL([object[]]$moveItems) {
    # Only a description. The internal name is derived from it (ply file -> ply_file).
    $r = Show-Dialog 'New changelist' $null $null 'Description:' ''
    if (-not $r -or -not $r.Text) { return $null }
    $script:made = $null
    Run-Busy {
        $c = New-CL (Unique-Name (($r.Text -split "`n")[0])) $r.Text
        if ($moveItems -and $moveItems.Count -gt 0) { Move-ToCL $c.name $moveItems }
        $script:made = $c.name
        Build-Tree
    }
    return $script:made
}

function Do-Move([string]$to, $items) {
    if (-not $items -or $items.Count -eq 0) { return }
    Run-Busy { Move-ToCL $to $items; Build-Tree }
}

function Do-Submit {
    $name = Selected-CL
    $items = Get-CLItems $script:Pending $name
    if ($items.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($form, "Changelist '" + $name + "' has no pending file.", 'Submit'); return }
    $desc = ''; if ($name -ne 'default') { $desc = (Find-CL $name).desc }
    $r = Show-SubmitDialog $name $desc $items
    if (-not $r) { return }
    Run-Busy {
        if ($name -ne 'default' -and $r.Desc -ne $desc) { Set-CLDesc $name $r.Desc }
        Submit-Items $name $r.Items $r.Desc
    }
    Refresh-All
}

function Do-Shelve {
    $name = Selected-CL
    $items = Get-CLItems $script:Pending $name
    if ($items.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($form, "Changelist '" + $name + "' has no pending file.", 'Shelve'); return }
    $r = Show-Dialog ("Shelve '" + $name + "'") 'Shelf name:' ($name + '_' + (Get-Date -Format 'yyyyMMdd-HHmm')) $null $null
    if (-not $r -or -not $r.Name) { return }
    Run-Busy { [void](Shelve-Items $r.Name $items) }
}

function Do-Revert {
    $items = Target-Items
    if ($items.Count -eq 0) { return }
    $list = (@($items | Select-Object -First 15 | ForEach-Object { (Kind-Letter $_.Kind) + '  ' + $_.Path }) -join "`r`n")
    if ($items.Count -gt 15) { $list += "`r`n... and " + ($items.Count - 15) + " more" }
    $q = "Discard local changes of " + $items.Count + " path(s)?`r`n(A backup shelf is created first; new files are skipped.)`r`nClose Unreal before reverting.`r`n`r`n" + $list
    if (-not (Ask-YesNo $q 'Revert')) { return }
    $prefix = Selected-CL
    Run-Busy { [void](Revert-Items $prefix $items) }
    Refresh-All
}

function Do-EditDesc {
    $name = Selected-CL
    if ($name -eq 'default') { return }
    $c = Find-CL $name
    $r = Show-Dialog ("Changelist '" + $name + "'") $null $null 'Description:' $c.desc
    if (-not $r) { return }
    Run-Busy { Set-CLDesc $name $r.Text; Build-Tree }
}

function Do-DeleteCL {
    $name = Selected-CL
    if ($name -eq 'default') { return }
    if (-not (Ask-YesNo ("Delete changelist '" + $name + "'?`r`nIts files go back to default. Nothing is reverted.") 'Delete changelist')) { return }
    Run-Busy { Remove-CL $name; Build-Tree }
}

function Do-Shelves {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Shelves'; $d.Font = $fontUi; $d.StartPosition = 'CenterParent'; $d.Width = 560; $d.Height = 380; $d.ShowInTaskbar = $false
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
    [void]$lv.Columns.Add('Shelf', 330); [void]$lv.Columns.Add('Created', 180)
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Bottom'; $bar.Height = 38; $bar.FlowDirection = 'RightToLeft'; $bar.Padding = New-Object System.Windows.Forms.Padding(6)
    $bClose = New-Object System.Windows.Forms.Button; $bClose.Text = 'Close'; $bClose.DialogResult = 'Cancel'
    $bDel   = New-Object System.Windows.Forms.Button; $bDel.Text = 'Delete...'
    $bApply = New-Object System.Windows.Forms.Button; $bApply.Text = 'Unshelve'
    $bar.Controls.AddRange(@($bClose, $bDel, $bApply))
    $d.Controls.Add($lv); $d.Controls.Add($bar); $d.CancelButton = $bClose
    $fill = {
        $lv.Items.Clear()
        foreach ($s in (Get-Shelves)) {
            $it = New-Object System.Windows.Forms.ListViewItem($s.Name)
            [void]$it.SubItems.Add($s.Created); $it.Tag = $s
            [void]$lv.Items.Add($it)
        }
    }
    $bApply.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $s = $lv.SelectedItems[0].Tag
        if (-not (Ask-YesNo ("Apply shelf '" + $s.Name + "' to your workspace? (the shelf is kept)") 'Unshelve')) { return }
        Run-Busy { Apply-Shelf $s.Id }
        $d.Close()
    })
    $bDel.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $s = $lv.SelectedItems[0].Tag
        if (-not (Ask-YesNo ("Permanently delete shelf '" + $s.Name + "'? This cannot be undone.") 'Delete shelf')) { return }
        Run-Busy { Delete-Shelf $s.Id; & $fill }
    })
    $d.Add_Shown({ Run-Busy { & $fill } })
    [void]$d.ShowDialog($form)
    Refresh-All
}

function Do-ChangeRepo {
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Pick a folder inside a Diversion workspace'
    if ($script:Root) { $fb.SelectedPath = $script:Root }
    if ($fb.ShowDialog($form) -ne 'OK') { return }
    $root = Find-DvRoot $fb.SelectedPath
    if (-not $root) { [void][System.Windows.Forms.MessageBox]::Show($form, 'No Diversion workspace (.diversion folder) found at or above this folder.', 'dvcl', 'OK', 'Warning'); return }
    Set-DvRoot $root; Save-Settings
    Refresh-All
}

function Do-ShowInExplorer {
    $n = $tv.SelectedNode
    if (-not $n -or $n.Tag.Type -ne 'file') { return }
    $full = Join-Path $script:Root ($n.Tag.Item.Path -replace '/', '\')
    if (Test-Path -LiteralPath $full) { Start-Process explorer.exe ('/select,"' + $full + '"') }
    else { Start-Process explorer.exe ('"' + (Split-Path -Parent $full) + '"') }
}

# ---------------------------------------------------------------- Local / Depot trees
$script:PendingByPath = @{}
$script:LocalBuilt = $false
$script:DepotPaths = $null

# A node that still has to load its children carries one placeholder child with no Tag.
function Add-Placeholder($node) { [void]$node.Nodes.Add('...') }
function Is-Unloaded($node) { return ($node.Nodes.Count -eq 1 -and $null -eq $node.Nodes[0].Tag) }

function Mark-Pending($node, [string]$rel) {
    $p = $script:PendingByPath[$rel]
    if ($p) { $k = Kind-Letter $p.Kind; $node.Text = $k + '   ' + $node.Text; $node.ForeColor = $colKind[$k] }
}

function Add-LocalChildren($nodes, [string]$dir) {
    try {
        $dirs  = @([System.IO.Directory]::GetDirectories($dir) | Sort-Object)
        $files = @([System.IO.Directory]::GetFiles($dir) | Sort-Object)
    } catch { return }
    foreach ($d in $dirs) {
        $name = [System.IO.Path]::GetFileName($d)
        if ($name -eq '.diversion' -or $name -eq '.dvcl') { continue }
        $n = New-Object System.Windows.Forms.TreeNode($name)
        $n.Tag = [pscustomobject]@{ Type = 'dir'; Path = $d }
        Add-Placeholder $n
        [void]$nodes.Add($n)
    }
    foreach ($f in $files) {
        $n = New-Object System.Windows.Forms.TreeNode([System.IO.Path]::GetFileName($f))
        $n.Tag = [pscustomobject]@{ Type = 'lfile'; Path = $f }
        Mark-Pending $n (Norm $f)
        [void]$nodes.Add($n)
    }
}

function Add-DepotChildren($nodes, [string]$dir) {
    $c = Get-DepotChildren $script:DepotPaths $dir
    foreach ($d in $c.Dirs) {
        $rel = $d; if ($dir) { $rel = $dir + '/' + $d }
        $n = New-Object System.Windows.Forms.TreeNode($d)
        $n.Tag = [pscustomobject]@{ Type = 'ddir'; Path = $rel }
        Add-Placeholder $n
        [void]$nodes.Add($n)
    }
    foreach ($f in $c.Files) {
        $rel = $f; if ($dir) { $rel = $dir + '/' + $f }
        $n = New-Object System.Windows.Forms.TreeNode($f)
        $n.Tag = [pscustomobject]@{ Type = 'dfile'; Path = $rel }
        Mark-Pending $n $rel
        [void]$nodes.Add($n)
    }
}

# Fill the visible tab once per refresh (Depot runs dv ls: only when that tab is opened)
function Show-Tab {
    if (-not $script:Root) { return }
    if ($tabs.SelectedTab -eq $tabLocal -and -not $script:LocalBuilt) {
        $tvLocal.BeginUpdate(); $tvLocal.Nodes.Clear()
        Add-LocalChildren $tvLocal.Nodes $script:Root
        $tvLocal.EndUpdate(); $script:LocalBuilt = $true
    }
    elseif ($tabs.SelectedTab -eq $tabDepot -and $null -eq $script:DepotPaths) {
        $script:DepotPaths = [string[]]@()
        $form.UseWaitCursor = $true; [System.Windows.Forms.Application]::DoEvents()
        try {
            $script:DepotPaths = Get-DepotPaths
            $tvDepot.BeginUpdate(); $tvDepot.Nodes.Clear()
            Add-DepotChildren $tvDepot.Nodes ''
            $tvDepot.EndUpdate()
            & $script:OnSay ('Depot: ' + $script:DepotPaths.Length + ' path(s)') 'Gray'
        } catch { & $script:OnSay ('ERROR: ' + $_.Exception.Message) 'Red' }
        finally { $form.UseWaitCursor = $false }
    }
}
$tabs.Add_SelectedIndexChanged({ Show-Tab })

$tvLocal.Add_BeforeExpand({ param($s, $e) if (Is-Unloaded $e.Node) { $e.Node.Nodes.Clear(); Add-LocalChildren $e.Node.Nodes $e.Node.Tag.Path } })
$tvDepot.Add_BeforeExpand({ param($s, $e) if (Is-Unloaded $e.Node) { $e.Node.Nodes.Clear(); Add-DepotChildren $e.Node.Nodes $e.Node.Tag.Path } })

function Open-InExplorer([string]$full) {
    if (Test-Path -LiteralPath $full -PathType Leaf) { Start-Process explorer.exe ('/select,"' + $full + '"') }
    elseif (Test-Path -LiteralPath $full) { Start-Process explorer.exe ('"' + $full + '"') }
}
$tvLocal.Add_NodeMouseDoubleClick({ param($s, $e) if ($e.Node.Tag -and $e.Node.Tag.Type -eq 'lfile') { Open-InExplorer $e.Node.Tag.Path } })
$tvDepot.Add_NodeMouseDoubleClick({ param($s, $e) if ($e.Node.Tag -and $e.Node.Tag.Type -eq 'dfile') { Open-InExplorer (Join-Path $script:Root ($e.Node.Tag.Path -replace '/', '\')) } })

# ---------------------------------------------------------------- update / bug report (GitHub)
function Do-Update {
    $script:Restart = $false
    Run-Busy {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'dvcl'
        $remote = $wc.DownloadString('https://raw.githubusercontent.com/' + $script:GhRepo + '/main/VERSION').Trim()
        $local = Get-LocalVersion
        if ([version]$remote -le [version]$local) { [void][System.Windows.Forms.MessageBox]::Show($form, ('dvcl ' + $local + ' is up to date.'), 'Update'); return }
        if (-not (Ask-YesNo ('Update dvcl ' + $local + ' to ' + $remote + '?') 'Update')) { return }
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git -and (Test-Path -LiteralPath (Join-Path $script:ToolDir '.git'))) {
            $o = @(& git -C $script:ToolDir pull --ff-only 2>&1 | ForEach-Object { "$_" })
            if ($LASTEXITCODE -ne 0) { Fail ('git pull failed: ' + ($o -join ' ')) }
        } else {
            $zip = Join-Path $env:TEMP 'dvcl-update.zip'
            $x = Join-Path $env:TEMP ('dvcl-update-' + [guid]::NewGuid().ToString('N'))
            $wc.DownloadFile('https://github.com/' + $script:GhRepo + '/archive/refs/heads/main.zip', $zip)
            Expand-Archive -LiteralPath $zip -DestinationPath $x -Force
            $top = Get-ChildItem -LiteralPath $x -Directory | Select-Object -First 1
            Copy-Item -Path (Join-Path $top.FullName '*') -Destination $script:ToolDir -Recurse -Force
            Remove-Item -LiteralPath $zip, $x -Recurse -Force -ErrorAction SilentlyContinue
        }
        & $script:OnSay ('Updated to ' + $remote) 'Green'
        $script:Restart = Ask-YesNo ('dvcl updated to ' + $remote + '. Restart now?') 'Update'
    }
    if ($script:Restart) {
        Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $script:ToolDir 'src\dvcl-gui.ps1') + '"'), ('"' + $script:Root + '"'))
        $form.Close()
    }
}

# Opens a new GitHub issue with versions only (no paths, no log: add what you want to share)
function Get-BugUrl {
    $body = "What happened:`n`n`nSteps to reproduce:`n1. `n`n---`ndvcl " + (Get-LocalVersion) + ' / Windows ' + [Environment]::OSVersion.Version + ' / PowerShell ' + $PSVersionTable.PSVersion
    return ('https://github.com/' + $script:GhRepo + '/issues/new?body=' + [Uri]::EscapeDataString($body))
}
function Do-ReportBug { Start-Process (Get-BugUrl) }

# ---------------------------------------------------------------- toolbar
[void](Add-Btn 'Refresh' 'Reload pending changes (F5)' { Refresh-All })
[void]$tool.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-Btn 'New changelist' 'Create a changelist; checked files move into it (Ctrl+N)' { [void](Do-NewCL (Target-Items-IfChecked)) })
[void](Add-Btn 'Submit...' 'Submit the selected changelist (Ctrl+Enter)' { Do-Submit })
[void](Add-Btn 'Shelve...' 'Shelve the selected changelist to the cloud, workspace untouched' { Do-Shelve })
[void](Add-Btn 'Revert...' 'Discard local changes of checked / selected files (backup shelf first)' { Do-Revert })
[void]$tool.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-Btn 'Shelves' 'List, unshelve or delete shelves' { Do-Shelves })
[void](Add-Btn 'Repo...' 'Pick another Diversion workspace' { Do-ChangeRepo })
$bBug = Add-Btn 'Report bug' 'Open a new issue on GitHub' { Do-ReportBug }; $bBug.Alignment = 'Right'
$bUpd = Add-Btn 'Update' 'Check GitHub for a new version and update' { Do-Update }; $bUpd.Alignment = 'Right'

# Checked files only (used by "New changelist": nothing checked = empty changelist)
function Target-Items-IfChecked {
    $sel = New-Object System.Collections.ArrayList
    foreach ($cn in $tv.Nodes) { foreach ($fn in $cn.Nodes) { if ($fn.Checked) { [void]$sel.Add($fn.Tag.Item) } } }
    return ,$sel.ToArray()
}

# ---------------------------------------------------------------- tree events
# Checking a changelist checks its files
$tv.Add_AfterCheck({
    param($s, $e)
    if ($e.Action -eq [System.Windows.Forms.TreeViewAction]::Unknown) { return }
    if ($e.Node.Tag.Type -eq 'cl') { foreach ($c in $e.Node.Nodes) { $c.Checked = $e.Node.Checked } }
})

$tv.Add_NodeMouseDoubleClick({ param($s, $e) if ($e.Node.Tag.Type -eq 'file') { $tv.SelectedNode = $e.Node; Do-ShowInExplorer } elseif ($e.Node.Tag.Type -eq 'cl') { $tv.SelectedNode = $e.Node; Do-EditDesc } })

# Drag files onto a changelist (or onto a file of it)
$tv.Add_ItemDrag({
    param($s, $e)
    if ($e.Item.Tag.Type -ne 'file') { return }
    $items = Target-Items-IfChecked
    if ($items.Count -eq 0 -or -not $e.Item.Checked) { $items = @($e.Item.Tag.Item) }
    $script:DragItems = $items
    [void]$tv.DoDragDrop('dvcl', [System.Windows.Forms.DragDropEffects]::Move)
})
$tv.Add_DragOver({
    param($s, $e)
    $pt = $tv.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    $n = $tv.GetNodeAt($pt)
    if ($n) { $tv.SelectedNode = $n; $e.Effect = [System.Windows.Forms.DragDropEffects]::Move } else { $e.Effect = [System.Windows.Forms.DragDropEffects]::None }
})
$tv.Add_DragDrop({
    param($s, $e)
    $pt = $tv.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    $n = $tv.GetNodeAt($pt)
    if (-not $n -or -not $script:DragItems) { return }
    $to = $n.Tag.Name; if ($n.Tag.Type -eq 'file') { $to = $n.Tag.Cl }
    Do-Move $to $script:DragItems
    $script:DragItems = $null
})

# Multi-select: Ctrl+click toggles a file, Shift+click checks a range, Ctrl+A checks all, Esc clears
function File-Nodes { $l = New-Object System.Collections.ArrayList; foreach ($cn in $tv.Nodes) { foreach ($fn in $cn.Nodes) { [void]$l.Add($fn) } }; return ,$l }
$script:Anchor = $null
$tv.Add_NodeMouseClick({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left -or $e.Node.Tag.Type -ne 'file') { return }
    if ($tv.HitTest($e.Location).Location -eq [System.Windows.Forms.TreeViewHitTestLocations]::StateImage) { $script:Anchor = $e.Node; return }
    Select-Click $e.Node ([System.Windows.Forms.Control]::ModifierKeys)
})
function Select-Click($node, $mods) {
    if (($mods -band [System.Windows.Forms.Keys]::Shift) -and $script:Anchor -and $script:Anchor.TreeView) {
        $all = File-Nodes; $a = $all.IndexOf($script:Anchor); $b = $all.IndexOf($node)
        if ($a -ge 0 -and $b -ge 0) { for ($i = [Math]::Min($a, $b); $i -le [Math]::Max($a, $b); $i++) { $all[$i].Checked = $true } }
    } elseif ($mods -band [System.Windows.Forms.Keys]::Control) {
        $node.Checked = -not $node.Checked; $script:Anchor = $node
    } else { $script:Anchor = $node }
}
function Check-AllFiles([bool]$on) { foreach ($n in (File-Nodes)) { $n.Checked = $on }; if (-not $on) { foreach ($cn in $tv.Nodes) { $cn.Checked = $false } } }
$tv.Add_KeyDown({
    param($s, $e)
    if ($e.Control -and $e.KeyCode -eq 'A') { Check-AllFiles $true; $e.Handled = $true; $e.SuppressKeyPress = $true }
    elseif ($e.KeyCode -eq 'Escape') { Check-AllFiles $false; $e.Handled = $true }
})

# Right-click menus
$menu = New-Object System.Windows.Forms.ContextMenuStrip
function Add-MenuItem($parent, [string]$text, [scriptblock]$onClick, [bool]$enabled = $true) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $mi.Enabled = $enabled
    if ($onClick) { $mi.Add_Click($onClick) }
    if ($parent -is [System.Windows.Forms.ContextMenuStrip]) { [void]$parent.Items.Add($mi) } else { [void]$parent.DropDownItems.Add($mi) }
    return $mi
}
$tv.Add_NodeMouseClick({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    $tv.SelectedNode = $e.Node
    $menu.Items.Clear()
    $isCl = $e.Node.Tag.Type -eq 'cl'
    $clName = Selected-CL
    $items = Target-Items
    $mv = Add-MenuItem $menu ("Move " + $items.Count + " file(s) to") $null ($items.Count -gt 0)
    foreach ($nm in (@('default') + @($script:CLs | ForEach-Object { $_.name }))) {
        $target = $nm
        $mi = Add-MenuItem $mv $nm $null ($nm -ne $clName -or (Target-Items-IfChecked).Count -gt 0)
        $mi.Tag = $target
        $mi.Add_Click({ param($src, $ev) Do-Move $src.Tag (Target-Items) })
    }
    [void]$mv.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $mv 'New changelist...' { [void](Do-NewCL (Target-Items)) })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $menu ("Submit '" + $clName + "'...") { Do-Submit })
    [void](Add-MenuItem $menu ("Shelve '" + $clName + "'...") { Do-Shelve })
    [void](Add-MenuItem $menu ("Revert " + $items.Count + " file(s)...") { Do-Revert } ($items.Count -gt 0))
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    if ($isCl) {
        [void](Add-MenuItem $menu 'Edit description...' { Do-EditDesc } ($clName -ne 'default'))
        [void](Add-MenuItem $menu 'Delete changelist' { Do-DeleteCL } ($clName -ne 'default'))
        [void](Add-MenuItem $menu 'New changelist...' { [void](Do-NewCL (Target-Items-IfChecked)) })
    } else {
        [void](Add-MenuItem $menu 'Show in Explorer' { Do-ShowInExplorer })
        [void](Add-MenuItem $menu 'Copy path' { [System.Windows.Forms.Clipboard]::SetText(($script:Root + '\' + ($tv.SelectedNode.Tag.Item.Path -replace '/', '\'))) })
    }
    $menu.Show($tv, $e.Location)
})

# Keyboard
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'F5') { Refresh-All; $e.Handled = $true }
    elseif ($e.Control -and $e.KeyCode -eq 'N') { [void](Do-NewCL (Target-Items-IfChecked)); $e.Handled = $true }
    elseif ($e.Control -and $e.KeyCode -eq 'Return') { Do-Submit; $e.Handled = $true }
})

$form.Add_Shown({
    $split.SplitterDistance = [int]($split.Height * 0.72)
    # Repo: argument / current folder, else last used, else ask
    $root = $null
    if ($StartDir) { $root = Find-DvRoot $StartDir }
    if (-not $root -and $settings.lastRepo) { $root = Find-DvRoot $settings.lastRepo }
    if ($root) { Set-DvRoot $root; Save-Settings; Refresh-All } else { Do-ChangeRepo }
    if ($SelfCheck) { Run-GuiSelfCheck; $form.Close() }
})

# ---------------------------------------------------------------- self-check (dvcl-gui -SelfCheck): drives the real window, writes a report, closes.
# Report: <tool>\tests\gui-selfcheck.txt (gitignored). Changes nothing: no submit, shelve, revert, update or browser.
function Run-GuiSelfCheck {
    $r = New-Object System.Collections.ArrayList; $ok = 0; $ko = 0
    function C([string]$n, [bool]$c, [string]$d = '') { if ($c) { $script:scOk++ ; [void]$r.Add('PASS  ' + $n) } else { $script:scKo++; [void]$r.Add('FAIL  ' + $n + '   ' + $d) } }
    $script:scOk = 0; $script:scKo = 0
    try {
        C 'repo opened' ([bool]$script:Root)
        C 'icon loaded' ($null -ne $form.Icon)
        C 'version file' ((Get-LocalVersion) -ne '0.0.0') (Get-LocalVersion)
        C 'pending tree: default + changelists' ($tv.Nodes.Count -eq (1 + $script:CLs.Count)) ([string]$tv.Nodes.Count)
        $files = File-Nodes
        C 'pending tree: all pending files shown' ($files.Count -eq $script:Pending.Count) ("" + $files.Count + ' / ' + $script:Pending.Count)
        if ($files.Count -ge 3) {
            Check-AllFiles $false
            Select-Click $files[0] ([System.Windows.Forms.Keys]::None)
            Select-Click $files[2] ([System.Windows.Forms.Keys]::Shift)
            C 'shift-click range checks 3 files' ((@($files | Where-Object { $_.Checked })).Count -eq 3)
            Select-Click $files[1] ([System.Windows.Forms.Keys]::Control)
            C 'ctrl-click toggles one off' ((@($files | Where-Object { $_.Checked })).Count -eq 2)
            C 'targets = checked files' ((Target-Items).Count -eq 2)
            Check-AllFiles $true; C 'select all' ((@($files | Where-Object { $_.Checked })).Count -eq $files.Count)
            Check-AllFiles $false; C 'clear' ((@($files | Where-Object { $_.Checked })).Count -eq 0)
        } else { [void]$r.Add('SKIP  multi-select (needs 3+ pending files)') }
        $tabs.SelectedTab = $tabLocal; [System.Windows.Forms.Application]::DoEvents()
        C 'local tree filled' ($tvLocal.Nodes.Count -gt 0) ([string]$tvLocal.Nodes.Count)
        C 'local: .diversion hidden' (-not (@($tvLocal.Nodes | Where-Object { $_.Text -eq '.diversion' })).Count)
        $ld = @($tvLocal.Nodes | Where-Object { $_.Tag.Type -eq 'dir' }) | Select-Object -First 1
        if ($ld) { $ld.Expand(); C 'local: folder expands' (-not (Is-Unloaded $ld)) }
        $tabs.SelectedTab = $tabDepot; [System.Windows.Forms.Application]::DoEvents()
        C 'depot: dv ls parsed' ($script:DepotPaths.Length -gt 0) ([string]$script:DepotPaths.Length)
        C 'depot tree filled' ($tvDepot.Nodes.Count -gt 0)
        C 'depot: no raw dv lines' (-not (@($tvDepot.Nodes | Where-Object { $_.Text -match '^\((F|D)\)' })).Count)
        $dd = @($tvDepot.Nodes | Where-Object { $_.Tag.Type -eq 'ddir' }) | Select-Object -First 1
        if ($dd) { $dd.Expand(); C 'depot: folder expands' (-not (Is-Unloaded $dd) -and $dd.Nodes.Count -gt 0) }
        $marked = 0
        foreach ($p in $script:Pending) { if (@($script:DepotPaths | Where-Object { $_ -eq $p.Path }).Count) { $marked++ } }
        [void]$r.Add('INFO  pending files found in depot: ' + $marked + ' / ' + $script:Pending.Count + ' (new files are not in the depot)')
        $tabs.SelectedTab = $tabPending
        $u = Get-BugUrl
        C 'bug report: GitHub issue URL' ($u.StartsWith('https://github.com/' + $script:GhRepo + '/issues/new'))
        C 'bug report: no local path in it' (-not ([Uri]::UnescapeDataString($u)).ToLower().Contains(([string]$script:Root).ToLower()))
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = 'dvcl'
            $remote = $wc.DownloadString('https://raw.githubusercontent.com/' + $script:GhRepo + '/main/VERSION').Trim()
            [void]$r.Add('INFO  update: GitHub has ' + $remote + ', local ' + (Get-LocalVersion))
        } catch { [void]$r.Add('INFO  update: GitHub VERSION not reachable yet (' + $_.Exception.Message + ')') }
    } catch { $script:scKo++; [void]$r.Add('FAIL  exception: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber) }
    [void]$r.Insert(0, ('GUI SELFCHECK ' + (Get-Date -Format s) + ': ' + $script:scOk + ' passed, ' + $script:scKo + ' failed'))
    $out = Join-Path $script:ToolDir 'tests\gui-selfcheck.txt'
    Set-Content -LiteralPath $out -Value $r -Encoding UTF8
}
$form.Add_FormClosing({ Save-Settings })

[void]$form.ShowDialog()
