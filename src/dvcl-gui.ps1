# dvcl-gui.ps1 - "Pending changelists" window for Diversion.
# Launch with dvcl-gui.cmd (needs -STA). Optional arg: a folder inside a Diversion workspace.

param([string]$StartDir = '')

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
$split.Panel1.Controls.Add($tv)

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
        if ((Prune $st.Files) -gt 0) { Save-Db }
        Build-Tree
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
})
$form.Add_FormClosing({ Save-Settings })

[void]$form.ShowDialog()
