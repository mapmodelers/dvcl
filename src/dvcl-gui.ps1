# dvcl-gui.ps1 - changelist window for Diversion: Local / Depot trees and pending changelists side by side.
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
# Layout: toolbar / sync banner / [Local|Depot trees  |  Pending changelists] / log / status bar
$form = New-Object System.Windows.Forms.Form
$form.Text = 'dvcl'
$form.Font = $fontUi
$form.StartPosition = 'CenterScreen'
$form.Width = [int]$settings.w; $form.Height = [int]$settings.h
$form.MinimumSize = New-Object System.Drawing.Size(760, 440)
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
function Add-DropBtn([string]$text, [string]$tip) {
    $b = New-Object System.Windows.Forms.ToolStripDropDownButton
    $b.Text = $text; $b.ToolTipText = $tip; $b.DisplayStyle = 'Text'
    [void]$tool.Items.Add($b)
    return $b
}
function Add-DropItem($drop, [string]$text, [string]$tip, [scriptblock]$onClick) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    $mi.ToolTipText = $tip; $mi.Add_Click($onClick)
    [void]$drop.DropDownItems.Add($mi)
    return $mi
}

# Yellow bar shown while Diversion sync is paused (click = resume)
$banner = New-Object System.Windows.Forms.Label
$banner.Dock = 'Top'; $banner.Height = 26; $banner.Visible = $false; $banner.TextAlign = 'MiddleLeft'
$banner.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$banner.BackColor = [System.Drawing.Color]::FromArgb(255, 236, 160); $banner.Cursor = [System.Windows.Forms.Cursors]::Hand
$banner.Text = 'Sync is paused: Diversion reports no changes, so changelist entries show as not pending (nothing is lost). Click here to resume sync.'

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

$main = New-Object System.Windows.Forms.SplitContainer
$main.Dock = 'Fill'; $main.Orientation = 'Vertical'
$split.Panel1.Controls.Add($main)

# Left: Local (workspace folder) / Depot (repository at the workspace revision), each with a path bar
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabLocal = New-Object System.Windows.Forms.TabPage('Local')
$tabDepot = New-Object System.Windows.Forms.TabPage('Depot')
$tabs.TabPages.AddRange(@($tabLocal, $tabDepot))
function New-BrowseTree {
    $t = New-Object System.Windows.Forms.TreeView
    $t.Dock = 'Fill'; $t.HideSelection = $false; $t.FullRowSelect = $true; $t.ItemHeight = 20; $t.Font = $fontUi
    return $t
}
# Path bar: editable path (Enter = go to it) + Copy + Explorer. Controls carry their tree kind in Tag.
function New-PathBar([string]$kind) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Top'; $p.Height = 28; $p.Padding = New-Object System.Windows.Forms.Padding(2, 3, 2, 2)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Dock = 'Fill'; $tb.Font = $fontMono; $tb.Tag = $kind
    $bExp = New-Object System.Windows.Forms.Button
    $bExp.Text = 'Explorer'; $bExp.Dock = 'Right'; $bExp.Width = 66; $bExp.FlatStyle = 'System'; $bExp.Tag = $kind
    $bCopy = New-Object System.Windows.Forms.Button
    $bCopy.Text = 'Copy'; $bCopy.Dock = 'Right'; $bCopy.Width = 52; $bCopy.FlatStyle = 'System'; $bCopy.Tag = $kind
    $p.Controls.Add($tb); $p.Controls.Add($bCopy); $p.Controls.Add($bExp)
    return [pscustomobject]@{ Panel = $p; Box = $tb; Copy = $bCopy; Explorer = $bExp }
}
$tvLocal = New-BrowseTree; $tvLocal.Tag = 'local'; $tvLocal.AllowDrop = $false
$tvDepot = New-BrowseTree; $tvDepot.Tag = 'depot'; $tvDepot.AllowDrop = $false
$barLocal = New-PathBar 'local'
$barDepot = New-PathBar 'depot'
$tabLocal.Controls.Add($tvLocal); $tabLocal.Controls.Add($barLocal.Panel)
$tabDepot.Controls.Add($tvDepot); $tabDepot.Controls.Add($barDepot.Panel)
$main.Panel1.Controls.Add($tabs)

# Right: pending changelists
$tv = New-Object System.Windows.Forms.TreeView
$tv.Dock = 'Fill'; $tv.CheckBoxes = $true; $tv.HideSelection = $false; $tv.FullRowSelect = $true
$tv.ShowLines = $true; $tv.AllowDrop = $true; $tv.ItemHeight = 20
$tv.Font = $fontBold   # changelist rows bold; file rows set back to regular (avoids clipped bold text)
$pendHead = New-Object System.Windows.Forms.Label
$pendHead.Dock = 'Top'; $pendHead.Height = 26; $pendHead.TextAlign = 'MiddleLeft'; $pendHead.Font = $fontBold
$pendHead.Text = 'Pending changelists'; $pendHead.Padding = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
$main.Panel2.Controls.Add($tv); $main.Panel2.Controls.Add($pendHead)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Dock = 'Fill'; $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.Font = $fontMono; $logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250); $logBox.WordWrap = $false
$split.Panel2.Controls.Add($logBox)

$status = New-Object System.Windows.Forms.StatusStrip
$statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLbl.Spring = $true; $statusLbl.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusLbl)

# Docking order: last added docks first (toolbar on top, banner under it, status bottom, split fills)
$form.Controls.Add($split)
$form.Controls.Add($banner)
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

# Read-only text window (history)
function Show-TextDialog([string]$title, [string[]]$lines) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title; $d.Font = $fontUi; $d.StartPosition = 'CenterParent'; $d.Width = 820; $d.Height = 480; $d.ShowInTaskbar = $false
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Dock = 'Fill'; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Both'; $tb.WordWrap = $false; $tb.Font = $fontMono
    $tb.Text = ($lines -join "`r`n")
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Bottom'; $bar.Height = 38; $bar.FlowDirection = 'RightToLeft'; $bar.Padding = New-Object System.Windows.Forms.Padding(6)
    $bClose = New-Object System.Windows.Forms.Button; $bClose.Text = 'Close'; $bClose.DialogResult = 'Cancel'
    $bar.Controls.Add($bClose)
    $d.Controls.Add($tb); $d.Controls.Add($bar); $d.CancelButton = $bClose
    $d.Add_Shown({ $tb.SelectionLength = 0 })
    [void]$d.ShowDialog($form)
}

# ---------------------------------------------------------------- pending changelists tree
$script:Paused = $false

function Build-Tree {
    $tv.BeginUpdate()
    $tv.Nodes.Clear()
    $set = Pending-Set $script:Pending
    $names = @('default') + @($script:CLs | ForEach-Object { $_.name })
    foreach ($name in $names) {
        $items = Get-CLItems $script:Pending $name
        $label = $name; $stale = @()
        if ($name -ne 'default') {
            $c = Find-CL $name
            $stale = Stale-Of $script:Pending $c $set
            if ($c.desc) {
                $d = ($c.desc -replace '\s+', ' ').Trim()
                # name derived from the description: show the description only
                if ($name.StartsWith((Slug-Base (($c.desc -split "`n")[0])), [StringComparison]::OrdinalIgnoreCase)) { $label = $d } else { $label = $name + '   ' + $d }
            }
        }
        $count = '   (' + $items.Count + ')'
        if ($stale.Count -gt 0) { $count = '   (' + $items.Count + ' + ' + $stale.Count + ' not pending)' }
        $n = New-Object System.Windows.Forms.TreeNode(($label + $count))
        $n.Tag = [pscustomobject]@{ Type = 'cl'; Name = $name; Stale = $stale.Count }
        foreach ($p in $items) {
            $k = Kind-Letter $p.Kind
            $f = New-Object System.Windows.Forms.TreeNode(($k + '   ' + $p.Path))
            $f.Tag = [pscustomobject]@{ Type = 'file'; Item = $p; Cl = $name }
            $f.ForeColor = $colKind[$k]
            $f.NodeFont = $fontUi
            [void]$n.Nodes.Add($f)
        }
        # Entries kept although dv does not report them (committed elsewhere, or sync paused)
        foreach ($sp in $stale) {
            $f = New-Object System.Windows.Forms.TreeNode(('.   ' + $sp + '   (not pending)'))
            $f.Tag = [pscustomobject]@{ Type = 'stale'; Path = $sp; Cl = $name }
            $f.ForeColor = [System.Drawing.Color]::DarkGray
            $f.NodeFont = $fontUi
            [void]$n.Nodes.Add($f)
        }
        [void]$tv.Nodes.Add($n)
    }
    $tv.ExpandAll()
    if ($tv.Nodes.Count -gt 0) { $tv.Nodes[0].EnsureVisible() }
    $tv.EndUpdate()
}

function Total-Entries { $t = 0; foreach ($c in $script:CLs) { $t += $c.files.Count }; return $t }

function Refresh-All {
    Run-Busy {
        if (-not $script:Root) { $statusLbl.Text = 'No Diversion repo selected (Repo...)'; $tv.Nodes.Clear(); return }
        Load-Db
        $st = Get-Pending
        $script:Pending = $st.Files
        $script:Paused = [bool]$st.Paused
        $script:PendingByPath = @{}
        foreach ($p in $st.Files) { $script:PendingByPath[$p.Path] = $p }
        Build-Tree
        $banner.Visible = $script:Paused
        $script:LocalBuilt = $false; $script:DepotPaths = $null
        Show-Tab
        $sync = 'sync on'; if ($script:Paused) { $sync = 'SYNC PAUSED' }
        $statusLbl.Text = $script:Root + '    branch ' + $st.Branch + '    ' + $st.Commit + '    ' + $st.Files.Count + ' pending path(s)    ' + $sync + '    dvcl ' + (Get-LocalVersion)
        $form.Text = 'dvcl - ' + (Split-Path -Leaf $script:Root)
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
    foreach ($fn in (File-Nodes)) { if ($fn.Checked) { [void]$sel.Add($fn.Tag.Item) } }
    if ($sel.Count -gt 0) { return ,$sel.ToArray() }
    $n = $tv.SelectedNode
    if (-not $n) { return ,@() }
    if ($n.Tag.Type -eq 'file') { return ,@($n.Tag.Item) }
    if ($n.Tag.Type -eq 'stale') { return ,@() }
    return ,@(Get-CLItems $script:Pending $n.Tag.Name)
}

# Pending file nodes only (not changelist rows, not "not pending" entries)
function File-Nodes { $l = New-Object System.Collections.ArrayList; foreach ($cn in $tv.Nodes) { foreach ($fn in $cn.Nodes) { if ($fn.Tag.Type -eq 'file') { [void]$l.Add($fn) } } }; return ,$l }

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
        Submit-Items $name $r.Items $r.Desc $script:Pending
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
    $rel = Selected-Rel
    if (-not $rel) { return }
    $full = Join-Path $script:Root ($rel -replace '/', '\')
    if (Test-Path -LiteralPath $full) { Start-Process explorer.exe ('/select,"' + $full + '"') }
    else { Start-Process explorer.exe ('"' + (Split-Path -Parent $full) + '"') }
}

# Repo-relative path of the selected pending / not-pending file ('' if none)
function Selected-Rel {
    $n = $tv.SelectedNode
    if (-not $n) { return '' }
    if ($n.Tag.Type -eq 'file') { return $n.Tag.Item.Path }
    if ($n.Tag.Type -eq 'stale') { return $n.Tag.Path }
    return ''
}

function Do-Sync([bool]$on) {
    if (-not $on -and -not (Ask-YesNo "Pause Diversion sync?`r`nWhile paused, Diversion reports no changes: changelist entries show as not pending (they are kept) and you cannot submit.`r`nAuto-update (new commits from others) is a separate setting in the Diversion app." 'Pause sync')) { return }
    Run-Busy { Set-Sync $on }
    Refresh-All
}

function Do-GetLatest {
    if (-not (Ask-YesNo "Get latest: pull the branch's new commits into your workspace (dv update)?`r`nYour pending changes are kept. Unreal may need to reload changed assets." 'Get latest')) { return }
    Run-Busy { Get-Latest }
    Refresh-All
}

function Do-History([string]$rel) {
    if (-not $rel) { return }
    $script:hist = $null
    Run-Busy { $script:hist = Get-History $rel }
    if ($null -ne $script:hist) {
        $lines = @($script:hist); if ($lines.Count -eq 0) { $lines = @('(no commit touches this path)') }
        Show-TextDialog ('History - ' + $rel) $lines
    }
}

# Not-pending entries: one changelist ($name) or all ('')
function Do-CleanStale([string]$name) {
    Run-Busy { [void](Clean-Stale $script:Pending $name $script:Paused); Build-Tree }
}

function Do-RemoveEntry([string]$rel) {
    if (-not $rel) { return }
    Run-Busy { Detach $rel; Save-Db; Say ("Removed from its changelist: " + $rel) 'Green'; Build-Tree }
}

function Do-Recover {
    Run-Busy {
        if ($script:Paused) { Fail "Sync is paused: resume sync first, then recover." }
        [void](Recover-Pruned $script:Pending); Build-Tree
    }
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

# Tags: Local { Type dir|lfile; Path = full Windows path; Name }  Depot { Type ddir|dfile; Path = repo path; Name }
function Add-LocalChildren($nodes, [string]$dir) {
    try {
        $dirs  = @([System.IO.Directory]::GetDirectories($dir) | Sort-Object)
        $files = @([System.IO.Directory]::GetFiles($dir) | Sort-Object)
    } catch { return }
    foreach ($d in $dirs) {
        $name = [System.IO.Path]::GetFileName($d)
        if ($name -eq '.diversion' -or $name -eq '.dvcl') { continue }
        $n = New-Object System.Windows.Forms.TreeNode($name)
        $n.Tag = [pscustomobject]@{ Type = 'dir'; Path = $d; Name = $name }
        Add-Placeholder $n
        [void]$nodes.Add($n)
    }
    foreach ($f in $files) {
        $name = [System.IO.Path]::GetFileName($f)
        $n = New-Object System.Windows.Forms.TreeNode($name)
        $n.Tag = [pscustomobject]@{ Type = 'lfile'; Path = $f; Name = $name }
        Mark-Pending $n (Norm $f)
        [void]$nodes.Add($n)
    }
}

function Add-DepotChildren($nodes, [string]$dir) {
    $c = Get-DepotChildren $script:DepotPaths $dir
    foreach ($d in $c.Dirs) {
        $rel = $d; if ($dir) { $rel = $dir + '/' + $d }
        $n = New-Object System.Windows.Forms.TreeNode($d)
        $n.Tag = [pscustomobject]@{ Type = 'ddir'; Path = $rel; Name = $d }
        Add-Placeholder $n
        [void]$nodes.Add($n)
    }
    foreach ($f in $c.Files) {
        $rel = $f; if ($dir) { $rel = $dir + '/' + $f }
        $n = New-Object System.Windows.Forms.TreeNode($f)
        $n.Tag = [pscustomobject]@{ Type = 'dfile'; Path = $rel; Name = $f }
        Mark-Pending $n $rel
        [void]$nodes.Add($n)
    }
}

function Load-Children($node) {
    if (-not (Is-Unloaded $node)) { return }
    $node.Nodes.Clear()
    if ($node.Tag.Type -eq 'dir') { Add-LocalChildren $node.Nodes $node.Tag.Path }
    elseif ($node.Tag.Type -eq 'ddir') { Add-DepotChildren $node.Nodes $node.Tag.Path }
}

function Tree-Of([string]$kind) { if ($kind -eq 'depot') { return $tvDepot } else { return $tvLocal } }
function Bar-Of([string]$kind) { if ($kind -eq 'depot') { return $barDepot } else { return $barLocal } }

# Path shown in the path bar: Local = full Windows path, Depot = repo path
function Node-Display($node) { if (-not $node -or -not $node.Tag) { return '' }; return [string]$node.Tag.Path }
# Repo-relative path of a Local / Depot node
function Node-Rel($node) {
    if (-not $node -or -not $node.Tag) { return '' }
    if ($node.Tag.Type -in 'dir', 'lfile') { return (Norm $node.Tag.Path) }
    return [string]$node.Tag.Path
}

# Fill the visible tab once per refresh (Depot runs dv ls: only when that tab is opened), then
# go back to the path shown in its path bar.
function Show-Tab {
    if (-not $script:Root) { return }
    if ($tabs.SelectedTab -eq $tabLocal -and -not $script:LocalBuilt) {
        $tvLocal.BeginUpdate(); $tvLocal.Nodes.Clear()
        Add-LocalChildren $tvLocal.Nodes $script:Root
        $tvLocal.EndUpdate(); $script:LocalBuilt = $true
        if ($barLocal.Box.Text) { Navigate-Tree 'local' $barLocal.Box.Text $true }
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
            if ($barDepot.Box.Text) { Navigate-Tree 'depot' $barDepot.Box.Text $true }
        } catch { & $script:OnSay ('ERROR: ' + $_.Exception.Message) 'Red' }
        finally { $form.UseWaitCursor = $false }
    }
}
$tabs.Add_SelectedIndexChanged({ Show-Tab })

# Expands a tree down to a path and selects it. Accepts a full Windows path inside the workspace,
# a repo path (MyGame/Content/...) and either slash. $quiet: no log line when not found.
function Navigate-Tree([string]$kind, [string]$text, [bool]$quiet = $false) {
    $t = ([string]$text).Trim().Trim('"')
    if (-not $t -or -not $script:Root) { return }
    $tree = Tree-Of $kind
    $wantTab = $tabLocal; if ($kind -eq 'depot') { $wantTab = $tabDepot }
    if ($tabs.SelectedTab -ne $wantTab) { $tabs.SelectedTab = $wantTab; [System.Windows.Forms.Application]::DoEvents() }
    $rootFwd = ($script:Root -replace '\\', '/').TrimEnd('/')
    if (($t -replace '\\', '/').TrimEnd('/') -ieq $rootFwd) { $tree.SelectedNode = $null; return }
    $rel = Norm $t
    if ($rel -match '^[A-Za-z]:') { if (-not $quiet) { Say ("Not inside this workspace: " + $t) 'Yellow' }; return }
    $nodes = $tree.Nodes; $found = $null
    foreach ($seg in ($rel -split '/')) {
        if (-not $seg) { continue }
        $hit = $null
        foreach ($n in $nodes) { if ($n.Tag -and $n.Tag.Name -ieq $seg) { $hit = $n; break } }
        if (-not $hit) { if (-not $quiet) { Say ("Not found in the " + $kind + " tree: " + $rel) 'Yellow' }; break }
        $found = $hit
        Load-Children $hit
        if ($hit.Nodes.Count -gt 0) { $hit.Expand() }
        $nodes = $hit.Nodes
    }
    if ($found) { $tree.SelectedNode = $found; $found.EnsureVisible() }
}

$tvLocal.Add_BeforeExpand({ param($s, $e) Load-Children $e.Node })
$tvDepot.Add_BeforeExpand({ param($s, $e) Load-Children $e.Node })
$tvLocal.Add_AfterSelect({ param($s, $e) $barLocal.Box.Text = Node-Display $e.Node })
$tvDepot.Add_AfterSelect({ param($s, $e) $barDepot.Box.Text = Node-Display $e.Node })

foreach ($b in @($barLocal, $barDepot)) {
    $b.Box.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Return') { Navigate-Tree $s.Tag $s.Text; $e.Handled = $true; $e.SuppressKeyPress = $true } })
    $b.Copy.Add_Click({ param($s, $e) $t = (Bar-Of $s.Tag).Box.Text; if ($t) { [System.Windows.Forms.Clipboard]::SetText($t) } })
    $b.Explorer.Add_Click({ param($s, $e) Open-PathInExplorer $s.Tag (Bar-Of $s.Tag).Box.Text })
}

function Open-InExplorer([string]$full) {
    if (Test-Path -LiteralPath $full -PathType Leaf) { Start-Process explorer.exe ('/select,"' + $full + '"') }
    elseif (Test-Path -LiteralPath $full) { Start-Process explorer.exe ('"' + $full + '"') }
    else { Say ("Not on disk: " + $full) 'Yellow' }
}
# Path bar text -> Explorer. Depot paths are repo paths: mapped to the workspace folder.
function Open-PathInExplorer([string]$kind, [string]$text) {
    $t = ([string]$text).Trim().Trim('"')
    if (-not $t) { if ($script:Root) { Open-InExplorer $script:Root }; return }
    if ($t -notmatch '^[A-Za-z]:') { $t = Join-Path $script:Root ($t -replace '/', '\') }
    Open-InExplorer $t
}
$tvLocal.Add_NodeMouseDoubleClick({ param($s, $e) if ($e.Node.Tag -and $e.Node.Tag.Type -eq 'lfile') { Open-InExplorer $e.Node.Tag.Path } })
$tvDepot.Add_NodeMouseDoubleClick({ param($s, $e) if ($e.Node.Tag -and $e.Node.Tag.Type -eq 'dfile') { Open-InExplorer (Join-Path $script:Root ($e.Node.Tag.Path -replace '/', '\')) } })

# Pending items at or under a repo path ('' = everything)
function Pending-Under([string]$rel) {
    if (-not $rel) { return ,@($script:Pending) }
    return ,@($script:Pending | Where-Object { $_.Path -ieq $rel -or $_.Path.StartsWith($rel + '/', [StringComparison]::OrdinalIgnoreCase) })
}

# Drag a file or folder from Local / Depot onto a changelist: moves its pending files there
$dragFromTree = {
    param($s, $e)
    if (-not $e.Item.Tag) { return }
    $rel = Node-Rel $e.Item
    $items = Pending-Under $rel
    if ($items.Count -eq 0) { & $script:OnSay ('Nothing pending under ' + $rel) 'Gray'; return }
    $script:DragItems = $items
    [void]$s.DoDragDrop('dvcl', [System.Windows.Forms.DragDropEffects]::Move)
}
$tvLocal.Add_ItemDrag($dragFromTree)
$tvDepot.Add_ItemDrag($dragFromTree)

# Right-click on Local / Depot
$menuL = New-Object System.Windows.Forms.ContextMenuStrip
$treeMenu = {
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right -or -not $e.Node.Tag) { return }
    $s.SelectedNode = $e.Node
    $rel = Node-Rel $e.Node
    $script:MenuItems = Pending-Under $rel
    $script:MenuRel = $rel
    $script:MenuDisplay = Node-Display $e.Node
    $menuL.Items.Clear()
    $n = $script:MenuItems.Count
    $mv = Add-MenuItem $menuL ("Move " + $n + " pending file(s) to") $null ($n -gt 0)
    foreach ($nm in (@('default') + @($script:CLs | ForEach-Object { $_.name }))) {
        $mi = Add-MenuItem $mv $nm $null $true
        $mi.Tag = $nm
        $mi.Add_Click({ param($src, $ev) Do-Move $src.Tag $script:MenuItems })
    }
    [void]$mv.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $mv 'New changelist...' { [void](Do-NewCL $script:MenuItems) })
    [void]$menuL.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $isFile = $e.Node.Tag.Type -in 'lfile', 'dfile'
    [void](Add-MenuItem $menuL 'History...' { Do-History $script:MenuRel } $isFile)
    [void](Add-MenuItem $menuL 'Show in Explorer' { Open-PathInExplorer 'local' $script:MenuDisplay })
    [void](Add-MenuItem $menuL 'Copy path' { [System.Windows.Forms.Clipboard]::SetText($script:MenuDisplay) })
    $menuL.Show($s, $e.Location)
}
$tvLocal.Add_NodeMouseClick($treeMenu)
$tvDepot.Add_NodeMouseClick($treeMenu)

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
[void](Add-Btn 'Shelves' 'List, unshelve or delete shelves' { Do-Shelves })
[void]$tool.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-Btn 'Get latest' "Pull the branch's new commits into your workspace (dv update)" { Do-GetLatest })
$ddSync = Add-DropBtn 'Sync' 'Diversion sync of this workspace with the cloud'
[void](Add-DropItem $ddSync 'Resume sync' 'Needed to see and submit changes' { Do-Sync $true })
[void](Add-DropItem $ddSync 'Pause sync...' 'Stop uploading / downloading; changelists are kept' { Do-Sync $false })
$ddTools = Add-DropBtn 'Tools' 'Changelist maintenance'
[void](Add-DropItem $ddTools 'Remove all not-pending entries' 'Drop entries Diversion no longer reports (committed elsewhere)' { Do-CleanStale '' })
[void](Add-DropItem $ddTools 'Recover entries lost by dvcl 0.2' 'Put back files that dvcl 0.2 dropped from changelists while sync was paused' { Do-Recover })
[void]$tool.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-Btn 'Repo...' 'Pick another Diversion workspace' { Do-ChangeRepo })
$bBug = Add-Btn 'Report bug' 'Open a new issue on GitHub' { Do-ReportBug }; $bBug.Alignment = 'Right'
$bUpd = Add-Btn 'Update' 'Check GitHub for a new version and update' { Do-Update }; $bUpd.Alignment = 'Right'
$banner.Add_Click({ Do-Sync $true })

# Checked files only (used by "New changelist": nothing checked = empty changelist)
function Target-Items-IfChecked {
    $sel = New-Object System.Collections.ArrayList
    foreach ($fn in (File-Nodes)) { if ($fn.Checked) { [void]$sel.Add($fn.Tag.Item) } }
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
    $to = $n.Tag.Name; if ($n.Tag.Type -ne 'cl') { $to = $n.Tag.Cl }
    Do-Move $to $script:DragItems
    $script:DragItems = $null
})

# Multi-select: Ctrl+click toggles a file, Shift+click checks a range, Ctrl+A checks all, Esc clears
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
        $ns = [int]$e.Node.Tag.Stale
        [void](Add-MenuItem $menu ('Remove ' + $ns + ' not-pending entr' + $(if ($ns -eq 1) { 'y' } else { 'ies' })) { Do-CleanStale (Selected-CL) } ($ns -gt 0))
    } else {
        $isStale = $e.Node.Tag.Type -eq 'stale'
        if ($isStale) { [void](Add-MenuItem $menu 'Remove from changelist' { Do-RemoveEntry (Selected-Rel) }) }
        [void](Add-MenuItem $menu 'Show in Local tree' { Navigate-Tree 'local' (Selected-Rel) })
        [void](Add-MenuItem $menu 'History...' { Do-History (Selected-Rel) })
        [void](Add-MenuItem $menu 'Show in Explorer' { Do-ShowInExplorer })
        [void](Add-MenuItem $menu 'Copy path' { [System.Windows.Forms.Clipboard]::SetText(($script:Root + '\' + ((Selected-Rel) -replace '/', '\'))) })
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
    $split.SplitterDistance = [int]($split.Height * 0.76)
    $main.SplitterDistance = [int]($main.Width * 0.42)
    # Repo: argument / current folder, else last used, else ask
    $root = $null
    if ($StartDir) { $root = Find-DvRoot $StartDir }
    if (-not $root -and $settings.lastRepo) { $root = Find-DvRoot $settings.lastRepo }
    if ($root) { Set-DvRoot $root; Save-Settings; Refresh-All } else { Do-ChangeRepo }
    if ($SelfCheck) { Run-GuiSelfCheck; $form.Close() }
})

# ---------------------------------------------------------------- self-check (dvcl-gui -SelfCheck): drives the real window, writes a report, closes.
# Report: <tool>\tests\gui-selfcheck.txt (gitignored). Changes nothing: no submit, shelve, revert, sync, update or browser.
function Run-GuiSelfCheck {
    $r = New-Object System.Collections.ArrayList
    function C([string]$n, [bool]$c, [string]$d = '') { if ($c) { $script:scOk++ ; [void]$r.Add('PASS  ' + $n) } else { $script:scKo++; [void]$r.Add('FAIL  ' + $n + '   ' + $d) } }
    $script:scOk = 0; $script:scKo = 0
    try {
        C 'repo opened' ([bool]$script:Root)
        C 'icon loaded' ($null -ne $form.Icon)
        C 'version file' ((Get-LocalVersion) -ne '0.0.0') (Get-LocalVersion)
        C 'layout: trees left, changelists right' ($main.Panel1.Contains($tabs) -and $main.Panel2.Contains($tv) -and $main.Panel1.Width -gt 100 -and $main.Panel2.Width -gt 100) ("" + $main.Panel1.Width + ' / ' + $main.Panel2.Width)
        C 'layout: path bars present' ($tabLocal.Contains($barLocal.Box) -and $tabDepot.Contains($barDepot.Box))
        C 'toolbar: Get latest + Sync + Tools' ((@($tool.Items | Where-Object { $_.Text -in 'Get latest', 'Sync', 'Tools' })).Count -eq 3)
        [void]$r.Add('INFO  sync paused: ' + $script:Paused + '   pending: ' + $script:Pending.Count + '   changelists: ' + $script:CLs.Count + '   entries: ' + (Total-Entries))
        C 'banner shown only when sync is paused' ($banner.Visible -eq $script:Paused)
        $clNodes = @($tv.Nodes | Where-Object { $_.Tag.Type -eq 'cl' })
        C 'pending tree: default + changelists' ($clNodes.Count -eq (1 + $script:CLs.Count)) ([string]$clNodes.Count)
        $files = File-Nodes
        C 'pending tree: all pending files shown' ($files.Count -eq $script:Pending.Count) ("" + $files.Count + ' / ' + $script:Pending.Count)
        $staleShown = 0; foreach ($cn in $tv.Nodes) { foreach ($fn in $cn.Nodes) { if ($fn.Tag.Type -eq 'stale') { $staleShown++ } } }
        $staleReal = 0; foreach ($c in $script:CLs) { $staleReal += (Stale-Of $script:Pending $c).Count }
        C 'not-pending entries shown, not dropped' ($staleShown -eq $staleReal) ("" + $staleShown + ' / ' + $staleReal)
        foreach ($c in $script:CLs) { [void]$r.Add('INFO  changelist ' + $c.name + ': ' + (Get-CLItems $script:Pending $c.name).Count + ' pending, ' + (Stale-Of $script:Pending $c).Count + ' not pending') }
        $before = Total-Entries
        Refresh-All
        C 'refresh drops no changelist entry' ((Total-Entries) -eq $before) ("" + $before + ' -> ' + (Total-Entries))
        $files = File-Nodes
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
        if ($ld) {
            $ld.Expand(); C 'local: folder expands' (-not (Is-Unloaded $ld))
            $tvLocal.SelectedNode = $ld; [System.Windows.Forms.Application]::DoEvents()
            C 'local path bar follows selection' ($barLocal.Box.Text -eq $ld.Tag.Path) $barLocal.Box.Text
            $top = Node-Rel $ld
            $under = (Pending-Under $top).Count
            $expect = (@($script:Pending | Where-Object { $_.Path.StartsWith($top + '/', [StringComparison]::OrdinalIgnoreCase) -or $_.Path -ieq $top })).Count
            C 'drag source: folder gives its pending files' ($under -eq $expect) ("" + $under + ' / ' + $expect)
        }
        $pf = @($script:Pending | Where-Object { (Kind-Letter $_.Kind) -eq 'M' }) | Select-Object -First 1
        if (-not $pf) { $pf = @($script:Pending | Where-Object { $_.Path -match '\.[A-Za-z0-9]+$' }) | Select-Object -First 1 }
        if ($pf) {
            $full = Join-Path $script:Root ($pf.Path -replace '/', '\')
            $barLocal.Box.Text = ''
            Navigate-Tree 'local' $full $true
            C 'path bar: go to a pending file (local)' ($tvLocal.SelectedNode -and $tvLocal.SelectedNode.Tag.Path -ieq $full) ([string]$barLocal.Box.Text)
            C 'local tree marks pending file' ($tvLocal.SelectedNode -and $tvLocal.SelectedNode.Text -match '^[AMDR!]   ')
            $script:LocalBuilt = $false; Show-Tab
            C 'local tree keeps its path after rebuild' ($tvLocal.SelectedNode -and $tvLocal.SelectedNode.Tag.Path -ieq $full)
        } else { [void]$r.Add('SKIP  path bar navigation (no pending file)') }

        $tabs.SelectedTab = $tabDepot; [System.Windows.Forms.Application]::DoEvents()
        C 'depot: dv ls parsed' ($script:DepotPaths.Length -gt 0) ([string]$script:DepotPaths.Length)
        C 'depot tree filled' ($tvDepot.Nodes.Count -gt 0)
        C 'depot: no raw dv lines' (-not (@($tvDepot.Nodes | Where-Object { $_.Text -match '^\((F|D)\)' })).Count)
        $dd = @($tvDepot.Nodes | Where-Object { $_.Tag.Type -eq 'ddir' }) | Select-Object -First 1
        if ($dd) { $dd.Expand(); C 'depot: folder expands' (-not (Is-Unloaded $dd) -and $dd.Nodes.Count -gt 0) }
        if ($pf -and (Kind-Letter $pf.Kind) -eq 'M') {
            Navigate-Tree 'depot' $pf.Path $true
            C 'path bar: go to a pending file (depot)' ($tvDepot.SelectedNode -and $tvDepot.SelectedNode.Tag.Path -ieq $pf.Path) ([string]$barDepot.Box.Text)
            C 'depot path bar shows the repo path' ($barDepot.Box.Text -ieq $pf.Path) $barDepot.Box.Text
        }
        $tabs.SelectedTab = $tabLocal

        $u = Get-BugUrl
        C 'bug report: GitHub issue URL' ($u.StartsWith('https://github.com/' + $script:GhRepo + '/issues/new'))
        C 'bug report: no local path in it' (-not ([Uri]::UnescapeDataString($u)).ToLower().Contains(([string]$script:Root).ToLower()))
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient; $wc.Headers['User-Agent'] = 'dvcl'
            $remote = $wc.DownloadString('https://raw.githubusercontent.com/' + $script:GhRepo + '/main/VERSION').Trim()
            [void]$r.Add('INFO  update: GitHub has ' + $remote + ', local ' + (Get-LocalVersion))
        } catch { [void]$r.Add('INFO  update: GitHub VERSION not reachable (' + $_.Exception.Message + ')') }
    } catch { $script:scKo++; [void]$r.Add('FAIL  exception: ' + $_.Exception.Message + ' @ line ' + $_.InvocationInfo.ScriptLineNumber) }
    [void]$r.Insert(0, ('GUI SELFCHECK ' + (Get-Date -Format s) + ': ' + $script:scOk + ' passed, ' + $script:scKo + ' failed'))
    $out = Join-Path $script:ToolDir 'tests\gui-selfcheck.txt'
    Set-Content -LiteralPath $out -Value $r -Encoding UTF8
}
$form.Add_FormClosing({ Save-Settings })

[void]$form.ShowDialog()
