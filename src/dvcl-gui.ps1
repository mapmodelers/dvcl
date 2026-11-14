# dvcl-gui.ps1 - changelist window for Diversion: Local / Depot trees and pending changelists side by side.
# Launch with dvcl-gui.cmd (needs -STA). Optional arg: a folder inside a Diversion workspace.

param([string]$StartDir = '', [switch]$SelfCheck, [string]$Shot = '')   # -Shot <png>: README screenshot (tests\screenshot.ps1)

# Startup telemetry (TIMING lines in <repo>\.dvcl\dvcl.log)
$script:ScriptStart = Get-Date
$script:Clock = [Diagnostics.Stopwatch]::StartNew()
$script:FirstShown = $false
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Window is launched without a console: show fatal errors in a message box
trap { [void][System.Windows.Forms.MessageBox]::Show(($_.Exception.Message + "`r`n`r`n" + $_.InvocationInfo.PositionMessage), 'dvcl - fatal error', 'OK', 'Error'); break }
. (Join-Path $PSScriptRoot 'DvclCore.ps1')
. (Join-Path $PSScriptRoot 'DvclDock.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- settings (last repo, window size)
$script:SettingsFile = Join-Path $env:APPDATA 'dvcl\settings.json'
function Load-Settings {
    try { if (Test-Path -LiteralPath $script:SettingsFile) { return (Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json) } } catch {}
    return [pscustomobject]@{ lastRepo = ''; w = 980; h = 640; ui = 'dark' }
}
function Save-Settings {
    if ($Shot) { return }   # screenshot runs never touch the user's settings
    try {
        $dir = Split-Path -Parent $script:SettingsFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        # self-check runs keep the user's layout
        $lay = $settings.layout; if (-not $SelfCheck -and $script:LayoutReady) { $lay = Get-Layout }
        $last = [string]$script:Root; if ($SelfCheck -and $settings.lastRepo) { $last = [string]$settings.lastRepo }
        [pscustomobject]@{ lastRepo = $last; w = $form.Width; h = $form.Height; ui = $(if ($script:Dark) { 'dark' } else { 'light' }); layout = $lay } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch {}
}
$settings = Load-Settings

# ---------------------------------------------------------------- tool info (update, bug report)
$script:ToolDir = Split-Path -Parent $PSScriptRoot
$script:GhRepo  = 'mapmodelers/dvcl'
function Get-LocalVersion {
    try { return (Get-Content -LiteralPath (Join-Path $script:ToolDir 'VERSION') -Raw).Trim() } catch { return '0.0.0' }
}
$script:RunVersion = Get-LocalVersion   # a newer version on disk restarts the window when it is opened again

# ---------------------------------------------------------------- look
$fontUi   = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontMono = New-Object System.Drawing.Font('Consolas', 9)
# ---- theme: palette read by everything that colors (light = Windows defaults, dark = VS-like)
$script:Dark = $false
$script:PalLight = @{
    Back = [System.Drawing.SystemColors]::Control; Fore = [System.Drawing.SystemColors]::ControlText; Input = [System.Drawing.SystemColors]::Window
    Muted = [System.Drawing.Color]::FromArgb(110, 110, 110); Stale = [System.Drawing.Color]::DarkGray; Shelf = [System.Drawing.Color]::FromArgb(120, 80, 30)
    Log = [System.Drawing.Color]::FromArgb(250, 250, 250); Link = [System.Drawing.Color]::FromArgb(0, 90, 190)
    Border = [System.Drawing.SystemColors]::ControlDark; Hi = [System.Drawing.SystemColors]::Highlight; Sel = [System.Drawing.SystemColors]::Highlight
    offline = [System.Drawing.Color]::FromArgb(255, 236, 160); online = [System.Drawing.Color]::FromArgb(214, 240, 214)
    busy = [System.Drawing.Color]::FromArgb(210, 228, 250); down = [System.Drawing.Color]::FromArgb(250, 215, 215); loading = [System.Drawing.SystemColors]::Control
    A = [System.Drawing.Color]::FromArgb(0, 140, 60); M = [System.Drawing.Color]::FromArgb(30, 30, 30); D = [System.Drawing.Color]::FromArgb(200, 40, 40)
    R = [System.Drawing.Color]::FromArgb(140, 80, 0); X = [System.Drawing.Color]::FromArgb(200, 0, 160); Q = [System.Drawing.Color]::Gray
}
$script:PalDark = @{
    Back = [System.Drawing.Color]::FromArgb(45, 45, 48); Fore = [System.Drawing.Color]::FromArgb(225, 225, 225); Input = [System.Drawing.Color]::FromArgb(30, 30, 30)
    Muted = [System.Drawing.Color]::FromArgb(150, 150, 150); Stale = [System.Drawing.Color]::FromArgb(115, 115, 115); Shelf = [System.Drawing.Color]::FromArgb(205, 165, 110)
    Log = [System.Drawing.Color]::FromArgb(24, 24, 24); Link = [System.Drawing.Color]::FromArgb(110, 175, 255)
    Border = [System.Drawing.Color]::FromArgb(63, 63, 70); Hi = [System.Drawing.Color]::FromArgb(62, 62, 66); Sel = [System.Drawing.Color]::FromArgb(0, 120, 215)
    offline = [System.Drawing.Color]::FromArgb(92, 74, 20); online = [System.Drawing.Color]::FromArgb(35, 80, 45)
    busy = [System.Drawing.Color]::FromArgb(35, 60, 100); down = [System.Drawing.Color]::FromArgb(110, 40, 40); loading = [System.Drawing.Color]::FromArgb(45, 45, 48)
    A = [System.Drawing.Color]::FromArgb(110, 205, 120); M = [System.Drawing.Color]::FromArgb(235, 235, 235); D = [System.Drawing.Color]::FromArgb(240, 105, 105)
    R = [System.Drawing.Color]::FromArgb(230, 160, 70); X = [System.Drawing.Color]::FromArgb(240, 110, 220); Q = [System.Drawing.Color]::FromArgb(160, 160, 160)
}
$script:Pal = $script:PalLight
$colKind = @{
    'A' = [System.Drawing.Color]::FromArgb(0, 140, 60)
    'M' = [System.Drawing.Color]::FromArgb(30, 30, 30)
    'D' = [System.Drawing.Color]::FromArgb(200, 40, 40)
    'R' = [System.Drawing.Color]::FromArgb(140, 80, 0)
    '!' = [System.Drawing.Color]::FromArgb(200, 0, 160)
    '?' = [System.Drawing.Color]::Gray
}

# ---------------------------------------------------------------- main window
# Layout: toolbar / state bar / zones [left | center | right] over [bottom] / status bar.
# Panels (Local, Depot, Changelists, Submitted, History, Log) are tabs in those zones (DvclDock.ps1).
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

# State bar: where dvcl stands with Diversion (OFFLINE / ONLINE / busy / not answering), one button
# to switch, and the branch state. Colors: amber offline, green online, blue busy, red not answering.
$modeBar = New-Object System.Windows.Forms.Panel
$modeBar.Dock = 'Top'; $modeBar.Height = 34
$modeFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$modeFlow.Dock = 'Fill'; $modeFlow.WrapContents = $false; $modeFlow.BackColor = [System.Drawing.Color]::Transparent
$modeLbl = New-Object System.Windows.Forms.Label
$modeLbl.AutoSize = $true; $modeLbl.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$modeLbl.Margin = New-Object System.Windows.Forms.Padding(10, 7, 6, 0)
$btnMode = New-Object System.Windows.Forms.Button
$btnMode.AutoSize = $true; $btnMode.Height = 26; $btnMode.FlatStyle = 'System'; $btnMode.Margin = New-Object System.Windows.Forms.Padding(4, 4, 8, 0)
$modeDesc = New-Object System.Windows.Forms.Label
$modeDesc.AutoSize = $true; $modeDesc.Margin = New-Object System.Windows.Forms.Padding(4, 9, 4, 0)
$branchLbl = New-Object System.Windows.Forms.Label
$branchLbl.AutoSize = $true; $branchLbl.Margin = New-Object System.Windows.Forms.Padding(18, 9, 4, 0); $branchLbl.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
# Shown while dvcl works (loading, scanning, going online...): the rest of the window is greyed out
$busyBar = New-Object System.Windows.Forms.ProgressBar
$busyBar.Style = 'Marquee'; $busyBar.MarqueeAnimationSpeed = 30; $busyBar.Width = 140; $busyBar.Height = 16
$busyBar.Margin = New-Object System.Windows.Forms.Padding(18, 9, 4, 0); $busyBar.Visible = $false
$busyLbl = New-Object System.Windows.Forms.Label
$busyLbl.AutoSize = $true; $busyLbl.Margin = New-Object System.Windows.Forms.Padding(4, 9, 4, 0); $busyLbl.Visible = $false
$busyLbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$modeFlow.Controls.AddRange(@($modeLbl, $btnMode, $modeDesc, $branchLbl, $busyBar, $busyLbl))
$modeBar.Controls.Add($modeFlow)
$modeTip = New-Object System.Windows.Forms.ToolTip
$modeTip.SetToolTip($branchLbl, "Auto-update (others' commits arriving by themselves) is a setting in the Diversion app: keep it off. Get latest pulls them when you choose.")

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Horizontal'

$main = New-Object System.Windows.Forms.SplitContainer
$main.Dock = 'Fill'; $main.Orientation = 'Vertical'
$split.Panel1.Controls.Add($main)

# Left: Local (this PC) | Depot (Diversion, at your workspace commit), side by side, each with a path bar
$trees = New-Object System.Windows.Forms.SplitContainer
$trees.Dock = 'Fill'; $trees.Orientation = 'Vertical'
$tabLocal = New-Object System.Windows.Forms.Panel; $tabLocal.Dock = 'Fill'
$tabDepot = New-Object System.Windows.Forms.Panel; $tabDepot.Dock = 'Fill'
function New-Head([string]$text, [string]$tip) {
    $l = New-Object System.Windows.Forms.Label
    $l.Dock = 'Top'; $l.Height = 22; $l.TextAlign = 'MiddleLeft'; $l.Font = $fontBold; $l.Text = $text
    $l.Padding = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
    return $l
}
function New-BrowseTree {
    $t = New-Object System.Windows.Forms.TreeView
    $t.Dock = 'Fill'; $t.HideSelection = $false; $t.FullRowSelect = $true; $t.ItemHeight = 20; $t.Font = $fontUi; $t.ShowNodeToolTips = $true
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
$main.Panel1.Controls.Add($trees)

# ---- state icons (drawn here, no image files): file / folder + a colored badge per state
#   + added (green)   dot modified (white)   x deleted (red)   > renamed (orange)   ! conflict (magenta)
$icons = New-Object System.Windows.Forms.ImageList
$icons.ImageSize = New-Object System.Drawing.Size(16, 16); $icons.ColorDepth = 'Depth32Bit'
$script:BadgeColor = @{
    'A' = [System.Drawing.Color]::FromArgb(40, 160, 60); 'M' = [System.Drawing.Color]::FromArgb(245, 245, 245)
    'D' = [System.Drawing.Color]::FromArgb(210, 40, 40); 'R' = [System.Drawing.Color]::FromArgb(220, 130, 0)
    '!' = [System.Drawing.Color]::FromArgb(200, 0, 160); '?' = [System.Drawing.Color]::Gray
}
function New-Icon([string]$base, [string]$badge) {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $grey = [System.Drawing.Color]::FromArgb(120, 120, 120)
    switch ($base) {
        'file'   { $g.FillRectangle([System.Drawing.Brushes]::White, 3, 1, 9, 13); $g.DrawRectangle((New-Object System.Drawing.Pen($grey)), 3, 1, 9, 13) }
        'faded'  { $g.DrawRectangle((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(190, 190, 190))), 3, 1, 9, 13) }
        'folder' { $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 190, 70)); $g.FillRectangle($b, 1, 3, 6, 3); $g.FillRectangle($b, 1, 5, 14, 9) }
        'folderoff' { $pn = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(170, 170, 170)); $g.DrawRectangle($pn, 1, 3, 5, 2); $g.DrawRectangle($pn, 1, 5, 13, 8) }
        'cl'     { $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 60, 60))), 2, 2, 12, 12); foreach ($y in 5, 8, 11) { $g.DrawLine([System.Drawing.Pens]::White, 4, $y, 11, $y) } }
        'shelf'  {
            # zipped folder
            $g.SmoothingMode = 'None'
            $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 190, 70)); $g.FillRectangle($b, 1, 3, 6, 3); $g.FillRectangle($b, 1, 5, 14, 9)
            $z = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(70, 70, 70))
            foreach ($y in 5, 7, 9) { $g.FillRectangle($z, 6, $y, 2, 1); $g.FillRectangle($z, 8, ($y + 1), 2, 1) }
            $g.FillRectangle($z, 6, 11, 4, 3)
        }
        'cldef'  { $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 150, 150))), 2, 2, 12, 12); foreach ($y in 5, 8, 11) { $g.DrawLine([System.Drawing.Pens]::White, 4, $y, 11, $y) } }
    }
    if ($badge) {
        $c = $script:BadgeColor[$badge]
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($c)), 7, 7, 9, 9)
        $w = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.6)
        switch ($badge) {
            'A' { $g.DrawLine($w, 11.5, 9, 11.5, 14); $g.DrawLine($w, 9, 11.5, 14, 11.5) }
            'M' { $g.DrawEllipse((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 90, 90))), 7, 7, 8.6, 8.6); $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 60, 60))), 10, 10, 3, 3) }
            'D' { $g.DrawLine($w, 9.5, 9.5, 13.5, 13.5); $g.DrawLine($w, 13.5, 9.5, 9.5, 13.5) }
            'R' { $g.DrawLine($w, 9, 11.5, 14, 11.5); $g.DrawLine($w, 12, 9.5, 14, 11.5); $g.DrawLine($w, 12, 13.5, 14, 11.5) }
            '!' { $g.DrawLine($w, 11.5, 8.5, 11.5, 12); $g.FillRectangle([System.Drawing.Brushes]::White, 11, 13, 1.6, 1.6) }
        }
    }
    $g.Dispose()
    return $bmp
}
$icons.Images.Add('none', (New-Object System.Drawing.Bitmap(16, 16)))
foreach ($b in 'file', 'folder', 'folderoff', 'cl', 'cldef', 'shelf') { $icons.Images.Add($b, (New-Icon $b '')) }
$icons.Images.Add('stale', (New-Icon 'faded' ''))
foreach ($k in 'A', 'M', 'D', 'R', '!', '?') { $icons.Images.Add(('file-' + $k), (New-Icon 'file' $k)); $icons.Images.Add(('folder-' + $k), (New-Icon 'folder' $k)) }
# Local / Depot trees exist before the icons: attach the list here
$tvLocal.ImageList = $icons; $tvDepot.ImageList = $icons
function Set-Icon($node, [string]$key) { $node.ImageKey = $key; $node.SelectedImageKey = $key }
# Icon of a pending item: folder or file + its state
function Pending-IconKey($p) {
    $base = 'file'; if ([System.IO.Directory]::Exists((Full-Path $p.Path))) { $base = 'folder' }
    return ($base + '-' + (Kind-Letter $p.Kind))
}

# Right: pending changelists
$tv = New-Object System.Windows.Forms.TreeView
$tv.Dock = 'Fill'; $tv.CheckBoxes = $false; $tv.HideSelection = $false; $tv.FullRowSelect = $false; $tv.DrawMode = 'OwnerDrawText'
# Multi-selection like Explorer (click, Ctrl+click, Shift+click, Ctrl+A): selected file paths
$script:Sel = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$tv.ShowLines = $true; $tv.AllowDrop = $true; $tv.ItemHeight = 20; $tv.ImageList = $icons; $tv.ShowNodeToolTips = $true
$tv.Font = $fontBold   # changelist rows bold; file rows set back to regular (avoids clipped bold text)
# Header with the icon legend
$pendHead = New-Object System.Windows.Forms.FlowLayoutPanel
$pendHead.Dock = 'Top'; $pendHead.Height = 24; $pendHead.WrapContents = $false
foreach ($lg in @(@('file-A', 'added'), @('file-M', 'modified'), @('file-D', 'deleted'), @('file-R', 'renamed'), @('file-!', 'conflict'), @('stale', 'stale'), @('shelf', 'shelved'))) {
    $pb = New-Object System.Windows.Forms.PictureBox; $pb.Size = New-Object System.Drawing.Size(16, 16); $pb.Image = $icons.Images[$lg[0]]
    $pb.Margin = New-Object System.Windows.Forms.Padding(6, 4, 2, 0)
    $lt = New-Object System.Windows.Forms.Label; $lt.AutoSize = $true; $lt.Text = $lg[1]; $lt.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $lt.Margin = New-Object System.Windows.Forms.Padding(0, 5, 4, 0)
    [void]$pendHead.Controls.Add($pb); [void]$pendHead.Controls.Add($lt)
}
$padPending = New-Object System.Windows.Forms.Panel
$padPending.Controls.Add($tv); $padPending.Controls.Add($pendHead)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Dock = 'Fill'; $logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.Font = $fontMono; $logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250); $logBox.WordWrap = $false
$padLog = New-Object System.Windows.Forms.Panel
$padLog.Controls.Add($logBox)

# Zones and panels (submitted / history: DvclViews.ps1)
. (Join-Path $PSScriptRoot 'DvclViews.ps1')
foreach ($k in 'left', 'center', 'right', 'bottom') { [void](New-Zone $k) }
$trees.Panel1.Controls.Add($script:Zones.left.Root); $trees.Panel2.Controls.Add($script:Zones.center.Root)
$main.Panel2.Controls.Add($script:Zones.right.Root); $split.Panel2.Controls.Add($script:Zones.bottom.Root)
$vSub = New-CommitView 'submitted'; $vHist = New-CommitView 'history'
Register-Pad 'local' 'Local' $tabLocal 'left'
Register-Pad 'depot' 'Depot' $tabDepot 'center'
Register-Pad 'pending' 'Changelists' $padPending 'right'
Register-Pad 'submitted' 'Submitted' $vSub.Root 'right'
Register-Pad 'log' 'Log' $padLog 'bottom'
Register-Pad 'history' 'History' $vHist.Root 'bottom'
foreach ($id in @($script:Pads.Keys)) { Dock-Pad $id $script:Pads[$id].Home -1 $false }

$status = New-Object System.Windows.Forms.StatusStrip
$statusLbl = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLbl.Spring = $true; $statusLbl.TextAlign = 'MiddleLeft'
[void]$status.Items.Add($statusLbl)

# Docking order: last added docks first (toolbar on top, state bar under it, status bottom, split fills)
$form.Controls.Add($split)
$form.Controls.Add($modeBar)
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

# UI lock: while dvcl works (sync call or background job) the toolbar, trees and state-bar button
# are disabled (greyed) and the state bar shows a moving bar + what is running. Nested: counted.
$script:BusyDepth = 0
function Begin-Busy([string]$what) {
    $script:BusyDepth++
    if (-not $what) { $what = 'Working...' }
    $busyLbl.Text = $what; $busyBar.Visible = $true; $busyLbl.Visible = $true
    if ($script:OpDepth -gt 0) { Op-Step $what }
    $tool.Enabled = $false; $split.Enabled = $false; $btnMode.Enabled = $false; Set-FloatsEnabled $false
    $form.UseWaitCursor = $true
    [System.Windows.Forms.Application]::DoEvents()
}
function End-Busy {
    if ($script:BusyDepth -gt 0) { $script:BusyDepth-- }
    if ($script:BusyDepth -gt 0) { return }
    $busyBar.Visible = $false; $busyLbl.Visible = $false
    $tool.Enabled = $true; $split.Enabled = $true; $btnMode.Enabled = $true; Set-FloatsEnabled $true
    $form.UseWaitCursor = $false
}

function Run-Busy([scriptblock]$sb, [string]$what = 'Working...') {
    if ($script:Busy) { return }
    $script:Busy = $true
    Begin-Busy $what
    try { & $sb }
    catch {
        $m = $_.Exception.Message
        & $script:OnSay ("ERROR: " + $m) 'Red'
        [void][System.Windows.Forms.MessageBox]::Show($form, $m, 'dvcl', 'OK', 'Error')
    }
    finally { End-Busy; $script:Busy = $false }
}

# ---------------------------------------------------------------- action card
# One action (unshelve, revert, shelve, submit, get latest, online / offline) = one card over the
# window: everything behind it is locked (no misclick, no second action) and is not redrawn until the
# action is done, then drawn once. The card lists the steps as they run.
$script:OpDepth = 0; $script:TreeDirty = $false; $script:BuildCount = 0
$script:OpSteps = New-Object System.Collections.ArrayList; $script:OpCurrent = ''; $script:OpLater = @{}
$opPanel = New-Object System.Windows.Forms.Panel; $opPanel.Visible = $false
$opCard = New-Object System.Windows.Forms.Panel; $opCard.Width = 460; $opCard.Height = 236; $opCard.BorderStyle = 'FixedSingle'
$opTitle = New-Object System.Windows.Forms.Label; $opTitle.Left = 20; $opTitle.Top = 16; $opTitle.Width = 420; $opTitle.Height = 26; $opTitle.AutoEllipsis = $true
$opTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$opBar = New-Object System.Windows.Forms.ProgressBar; $opBar.Style = 'Marquee'; $opBar.MarqueeAnimationSpeed = 30; $opBar.Left = 20; $opBar.Top = 50; $opBar.Width = 420; $opBar.Height = 10
$opNow = New-Object System.Windows.Forms.Label; $opNow.Left = 20; $opNow.Top = 70; $opNow.Width = 420; $opNow.Height = 20; $opNow.AutoEllipsis = $true
$opNow.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$opDone = New-Object System.Windows.Forms.Label; $opDone.Left = 20; $opDone.Top = 94; $opDone.Width = 420; $opDone.Height = 110
$opHint = New-Object System.Windows.Forms.Label; $opHint.Left = 20; $opHint.Top = 208; $opHint.Width = 420; $opHint.Height = 18
$opHint.Text = 'dvcl is locked until this is done.'
$opCard.Controls.AddRange(@($opTitle, $opBar, $opNow, $opDone, $opHint))
$opPanel.Controls.Add($opCard)
$form.Controls.Add($opPanel)
function Place-Op {
    $opPanel.Bounds = $form.ClientRectangle
    $opCard.Left = [Math]::Max(0, [int](($opPanel.Width - $opCard.Width) / 2)); $opCard.Top = [Math]::Max(0, [int](($opPanel.Height - $opCard.Height) / 2.6))
}
$form.Add_Resize({ if ($opPanel.Visible) { Place-Op } })
function Show-OpSteps {
    $ok = [string][char]0x2713
    $d = @($script:OpSteps | Select-Object -Last 6 | ForEach-Object { $ok + '  ' + $_ })
    $opDone.Text = $d -join "`r`n"
}
function Begin-Op([string]$title) {
    $script:OpDepth++
    if ($script:OpDepth -gt 1) { return }
    $script:OpSteps.Clear(); $script:OpCurrent = ''; $script:TreeDirty = $false
    $opTitle.Text = $title; $opNow.Text = 'Starting'; $opDone.Text = ''
    $opPanel.BackColor = $form.BackColor; $opCard.BackColor = $tv.BackColor
    foreach ($c in @($opTitle, $opNow)) { $c.ForeColor = $tv.ForeColor }
    foreach ($c in @($opDone, $opHint)) { $c.ForeColor = $script:Pal.Muted }
    Place-Op; $opPanel.Visible = $true; $opPanel.BringToFront()
    Set-FloatsEnabled $false
    $form.UseWaitCursor = $true
    [System.Windows.Forms.Application]::DoEvents()
}
# a step of the action (each busy text): the previous one is ticked
function Op-Step([string]$what) {
    if ($script:OpDepth -eq 0 -or -not $what -or $what -eq $script:OpCurrent) { return }
    if ($script:OpCurrent -and -not $script:OpSteps.Contains($script:OpCurrent)) { [void]$script:OpSteps.Add($script:OpCurrent) }
    $script:OpCurrent = $what; $opNow.Text = $what + '...'
    Show-OpSteps
    [System.Windows.Forms.Application]::DoEvents()
}
function End-Op {
    if ($script:OpDepth -gt 1) { $script:OpDepth--; return }
    if ($script:OpDepth -eq 0) { return }
    # the refresh that ends the action (status / folder scan) finishes behind the card
    Op-Step 'Updating the view'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (($script:StatusRunning -or @($script:Jobs | Where-Object { $_.Busy }).Count) -and $sw.ElapsedMilliseconds -lt 20000) {
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40
    }
    $script:OpDepth = 0
    if ($script:TreeDirty) { $script:TreeDirty = $false; Build-Tree }
    $opPanel.Visible = $false
    Set-FloatsEnabled $true
    $form.UseWaitCursor = $false
    # shelf list / branch head skipped during the action: read once now, in the background
    if ($script:OpLater['shelf']) { Start-DvAsync @('shelf') 'Apply-DvShelves' $true $true '' }
    if ($script:OpLater['head']) { Start-DvAsync @('show', [string]$script:OpLater['head']) 'Apply-Head' $true $true }
    $script:OpLater = @{}
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
    Theme-Walk $d
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
    Theme-Walk $d
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
    Theme-Walk $d
    [void]$d.ShowDialog($form)
}

# ---------------------------------------------------------------- pending changelists tree
$script:Paused = $false
$script:Offline = $false
$script:BaselineFresh = $false

$script:MaxRows = 1500
function Build-Tree {
    if ($script:OpDepth -gt 0) { $script:TreeDirty = $true; return }
    $script:BuildCount++
    # keep what the user selected across rebuilds (refresh, theme, outside changes)
    $keepSel = $null; if ($tv.SelectedNode -and $tv.SelectedNode.Tag) { $t = $tv.SelectedNode.Tag; $keepSel = [string]$t.Type + '|' + $(if ($t.Type -eq 'file') { $t.Item.Path } elseif ($t.Type -eq 'cl') { $t.Name } else { [string]$t.Path + [string]$t.Cl }) }
    $script:InBuild = $true; $tv.BeginUpdate()
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
            $label = '#' + $c.id + '  ' + $label
        }
        $shs = @(); if ($script:ShelfMap -and $script:ShelfMap.ContainsKey($name.ToLowerInvariant())) { $shs = @($script:ShelfMap[$name.ToLowerInvariant()]) }
        $count = '   (' + $items.Count
        if ($stale.Count -gt 0) { $count += ' +' + $stale.Count + ' stale' }
        if ($shs.Count -gt 0) { $count += ', ' + $shs.Count + ' shelved' }
        $count += ')'
        $n = New-Object System.Windows.Forms.TreeNode(($label + $count))
        $n.Tag = [pscustomobject]@{ Type = 'cl'; Name = $name; Stale = $stale.Count }
        Set-Icon $n $(if ($name -eq 'default') { 'cldef' } else { 'cl' })
        # a huge list freezes the TreeView (48k rows = 80 s): show the first ones, the rest stay in the changelist
        $shown = 0
        foreach ($p in $items) {
            if ($shown -ge $script:MaxRows) {
                $more = New-Object System.Windows.Forms.TreeNode(('+' + ($items.Count - $shown) + ' more'))
                $more.Tag = [pscustomobject]@{ Type = 'more'; Cl = $name }; $more.ForeColor = $script:Pal.Stale; $more.NodeFont = $fontUi; Set-Icon $more 'none'
                [void]$n.Nodes.Add($more); break
            }
            $shown++
            $k = Kind-Letter $p.Kind
            $f = New-Object System.Windows.Forms.TreeNode($p.Path)
            $f.Tag = [pscustomobject]@{ Type = 'file'; Item = $p; Cl = $name }
            $f.ForeColor = $colKind[$k]
            Set-Icon $f (Pending-IconKey $p)
            $f.NodeFont = $fontUi
            [void]$n.Nodes.Add($f)
        }
        # Entries kept although dv does not report them (committed elsewhere, or sync paused)
        foreach ($sp in $stale) {
            $f = New-Object System.Windows.Forms.TreeNode($sp)
            $f.Tag = [pscustomobject]@{ Type = 'stale'; Path = $sp; Cl = $name }
            Set-Icon $f 'stale'
            $f.ForeColor = $script:Pal.Stale
            $f.NodeFont = $fontUi
            [void]$n.Nodes.Add($f)
        }
        # Shelves of this changelist (collapsed): local ones list their files
        foreach ($sh in $shs) {
            # "Shelved files (n)" under the changelist; shelf name in the tooltip
            $label = 'Shelved files' + $(if ($sh.Count -ge 0) { ' (' + $sh.Count + ')' } else { '' }) + '   ' + $(if ($sh.Local) { 'local' } else { 'Diversion' }) + $(if ($sh.Created) { ', ' + $sh.Created } else { '' })
            $sn = New-Object System.Windows.Forms.TreeNode($label)
            $sn.ToolTipText = 'shelf ' + $(if ($sh.Local) { $sh.Id } else { $sh.Name + ' (' + $sh.Id + ')' })
            $sn.Tag = [pscustomobject]@{ Type = 'shelf'; Shelf = $sh; Cl = $name }; $sn.NodeFont = $fontUi
            $sn.ForeColor = $script:Pal.Shelf; Set-Icon $sn 'shelf'
            foreach ($sf in @($sh.Files)) {
                $k = Kind-Letter $sf.Kind
                $fn = New-Object System.Windows.Forms.TreeNode($sf.Path)
                $fn.Tag = [pscustomobject]@{ Type = 'shelffile'; Path = $sf.Path; Cl = $name; ShelfId = [string]$sh.Id }; $fn.NodeFont = $fontUi
                $fn.ForeColor = $script:Pal.Muted; Set-Icon $fn ('file-' + $k)
                [void]$sn.Nodes.Add($fn)
            }
            [void]$n.Nodes.Add($sn)
        }
        [void]$tv.Nodes.Add($n)
    }
    $tv.ExpandAll()
    foreach ($cn in $tv.Nodes) {
        if ($keepSel -eq ('cl|' + $cn.Tag.Name)) { $tv.SelectedNode = $cn }
        foreach ($x in $cn.Nodes) {
            if ($x.Tag.Type -eq 'shelf') { if ($script:OpenShelves.Contains([string]$x.Tag.Shelf.Id)) { $x.Expand() } else { $x.Collapse() } }
            if ($x.Tag.Type -eq 'file') {
                if ($keepSel -eq ('file|' + $x.Tag.Item.Path)) { $tv.SelectedNode = $x }
            }
        }
    }
    if ($tv.Nodes.Count -gt 0) { $tv.Nodes[0].EnsureVisible() }
    $tv.EndUpdate(); $script:InBuild = $false
}

$script:Shelves = @(); $script:ShelfMap = @{}
$script:OpenShelves = New-Object 'System.Collections.Generic.HashSet[string]' 
# Local shelves + last known Diversion shelves, grouped by changelist (creates missing changelists)
function Load-Shelves {
    $script:Shelves = @(@(Get-LocalShelves) + @(Read-DvShelfCache))
    $script:ShelfMap = Map-Shelves $script:Shelves
    Queue-ShelfFiles
}
function Apply-DvShelves($r) {
    if ($r.Code -ne 0) { return }
    $list = @(Read-Shelves $r.Lines)
    Save-DvShelfCache $list
    # redrawn only when the list changed
    $before = (@($script:Shelves | ForEach-Object { [string]$_.Id + '=' + [string]$_.Count }) -join '|')
    Load-Shelves
    if ((@($script:Shelves | ForEach-Object { [string]$_.Id + '=' + [string]$_.Count }) -join '|') -ne $before) { Build-Tree }
}
# Diversion shelves whose file list is not known yet: `dv shelf show` in the background, one shelf
# at a time (read-only, works offline); each shelf tried once per session
$script:ShelfQueue = New-Object System.Collections.Queue; $script:ShelfFetching = ''
$script:ShelfTried = New-Object 'System.Collections.Generic.HashSet[string]'
function Queue-ShelfFiles {
    if (-not $script:Root) { return }
    foreach ($sh in @($script:Shelves)) {
        if ($sh.Local -or $sh.Count -ge 0 -or -not $script:ShelfTried.Add([string]$sh.Id)) { continue }
        $script:ShelfQueue.Enqueue([string]$sh.Id)
    }
    Next-ShelfFiles
}
function Next-ShelfFiles {
    if ($script:ShelfFetching -or $script:ShelfQueue.Count -eq 0) { return }
    $script:ShelfFetching = [string]$script:ShelfQueue.Dequeue()
    Start-DvAsync @('shelf', 'show', $script:ShelfFetching) 'Apply-ShelfFiles' $true $true
}
function Apply-ShelfFiles($r) {
    $id = $script:ShelfFetching; $script:ShelfFetching = ''
    if ($r.Code -eq 0 -and $id) { Save-ShelfFiles $id (Parse-Status $r.Lines) }
    if ($script:ShelfQueue.Count -eq 0) { Load-Shelves; Build-Tree } else { Next-ShelfFiles }
}
# Unshelve into a changelist ($cl: the shelf's own, or any other). $only: some of its files.
# Diversion shelves go online for this only, then back offline. Asks only when it would overwrite
# files you have changed.
# Files Unreal (or another program) holds open cannot be written: say so before anything happens
# (no going online for nothing). $true = stopped.
function Stop-IfLocked([string[]]$paths, [string]$what) {
    $l = @($paths | Where-Object { $_ -and (Test-Locked $_) })
    if ($l.Count -eq 0) { return $false }
    $list = ($l | Select-Object -First 12) -join "`r`n"; if ($l.Count -gt 12) { $list += "`r`n... and " + ($l.Count - 12) + " more" }
    & $script:OnSay ($what + ' not done: ' + $l.Count + ' file(s) open in Unreal or another program') 'Red'
    [void][System.Windows.Forms.MessageBox]::Show($form, ($what + " not done, nothing was changed.`r`n`r`nThese " + $l.Count + " file(s) are open in Unreal (or another program), so they cannot be written now:`r`n`r`n" + $list), $what, 'OK', 'Warning')
    return $true
}

# Before writing $paths: files Unreal holds are released through the dvcl link (no restart), unless
# one has unsaved changes in Unreal (then nothing happens). $true = go on. $script:UeUsed = reload after.
$script:UeUsed = $false
# size + time of each file before the write: after it, Unreal reloads only the files that changed
function File-Stamp([string]$rel) {
    $f = Full-Path $rel
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return 'none' }
    $i = Get-Item -LiteralPath $f; return ([string]$i.Length + ':' + $i.LastWriteTimeUtc.Ticks)
}
function Ue-StampNow([string]$rel) { $s = File-Stamp $rel; if ($script:UeStamp[$rel] -and ([string]$script:UeStamp[$rel]).Split(':').Count -gt 2) { $s += ':' + (File-Hash $rel) }; return $s }
function Ue-Prepare([string[]]$paths, [string]$what) {
    $script:UeUsed = $false
    $paths = @($paths | Where-Object { $_ })
    $script:UeStamp = @{}; foreach ($p in $paths) { $script:UeStamp[$p] = File-Stamp $p }
    $script:UeEditor = [bool](Find-UeEngine)
    $locked = @($paths | Where-Object { Test-Locked $_ })
    # files Unreal has loaded: content hash too, so a rewrite with the same size and time still counts
    foreach ($p in $locked) { $script:UeStamp[$p] = (File-Stamp $p) + ':' + (File-Hash $p) }
    if ($locked.Count -eq 0) { $script:UeUsed = $script:UeEditor; return $true }
    if (-not $script:UeEditor) { return (-not (Stop-IfLocked $locked $what)) }
    $script:UeRel = $null
    Run-Busy { $script:UeRel = Ue-Release $locked } 'Asking Unreal to release the files'
    $r = $script:UeRel
    if (-not $r) { return $false }
    if ($r.Unsaved.Count) {
        $list = ($r.Unsaved | Select-Object -First 12) -join "`r`n"
        [void][System.Windows.Forms.MessageBox]::Show($form, ($what + " not done, nothing was changed.`r`n`r`nThese assets have unsaved changes in Unreal. Save them (or revert them there), then try again:`r`n`r`n" + $list), $what, 'OK', 'Warning')
        return $false
    }
    if ($r.State -eq 'nolink') { & $script:OnSay 'Unreal holds these files and the dvcl link is not installed (ue\install.cmd, then restart Unreal once).' 'Yellow' }
    elseif ($r.State -ne 'ok') { & $script:OnSay ('Unreal link: ' + $r.State + ' (see dvcl.log)') 'Yellow' }
    $script:UeUsed = ($r.State -eq 'ok')
    # whatever is still held (no link, another program): stop here, Unreal takes back what it let go
    if (Stop-IfLocked $locked $what) {
        if ($r.Released.Count) { $script:UeRel2 = $r.Released; Run-Busy { Ue-Reload $script:UeRel2 } 'Unreal reloading the assets' }
        $script:UeUsed = $false; return $false
    }
    return $true
}
# After writing: the editor reloads what it had loaded and rescans the files
function Ue-Finish([string[]]$paths) {
    if (-not $script:UeUsed) { return }
    $script:UeUsed = $false
    $script:UePaths = @(@($paths) | Where-Object { $_ -and (-not $script:UeStamp -or -not $script:UeStamp.ContainsKey($_) -or (Ue-StampNow $_) -ne $script:UeStamp[$_]) })
    Write-Log ('unreal: ' + $script:UePaths.Count + ' of ' + @($paths).Count + ' file(s) changed, reloaded')
    if ($script:UePaths.Count -eq 0) { return }
    Run-Busy { Ue-Reload $script:UePaths } 'Unreal reloading the changed assets'
}

function Do-Unshelve($sh, [string]$cl, [string[]]$only) {
    if (-not $cl) { $cl = 'default' }
    # a Diversion shelf is applied whole (the others are put back after): all its files get written
    $writes = @(@($sh.Files) | ForEach-Object { $_.Path } | Where-Object { $sh.Local -eq $false -or -not $only -or $only -icontains $_ })
    $files = @($sh.Files); if ($only) { $files = @($files | Where-Object { $only -icontains $_.Path }) }
    $mine = @($files | Where-Object { $script:PendingByPath.ContainsKey($_.Path) } | ForEach-Object { $_.Path })
    if ($mine.Count) {
        $list = ($mine | Select-Object -First 12) -join "`r`n"; if ($mine.Count -gt 12) { $list += "`r`n... and " + ($mine.Count - 12) + " more" }
        if (-not (Ask-YesNo ("These " + $mine.Count + " file(s) have your own changes; unshelving overwrites them:`r`n`r`n" + $list) 'Unshelve')) { return }
    }
    Begin-Op ('Unshelving ' + $(if ($sh.Local) { $sh.Id } else { $sh.Name }) + ' into ' + $(if ($cl -ieq 'default') { 'default' } else { (CL-Label (Find-CL $cl)) }))
    try {
    # asked first: Unreal only lets go of the files once the answer is yes
    if (-not (Ue-Prepare $writes 'Unshelve')) { return }
    $script:UnSh = $sh; $script:UnOnly = $only; $script:UnCl = $cl; $script:UnDone = $null
    try {
        if ($sh.Local) {
            Run-Busy { Apply-LocalShelf $script:UnSh.Id $script:UnOnly; $script:UnDone = $files } 'Unshelving'
        } else {
            if (-not (Ensure-Online 'Unshelve')) { Back-Offline; return }
            # Unreal takes the files back right after the write, before sync is paused again
            try { Run-Busy { $script:UnDone = Apply-DvShelf $script:UnSh $script:UnOnly } 'Unshelving' }
            finally { try { Ue-Finish $writes } finally { Back-Offline } }
        }
    } finally { Ue-Finish $writes }
    if ($script:UnDone -and $cl -ine 'default') { Run-Busy { Move-ToCL $script:UnCl @($script:UnDone) } 'Moving the files to the changelist' }
    Refresh-All
    } finally { End-Op }
}
function Do-DeleteShelf($sh) {
    $label = $(if ($sh.Local) { $sh.Id } else { $sh.Name })
    if (-not (Ask-YesNo ("Delete shelf '" + $label + "'? Cannot be undone.") 'Delete shelf')) { return }
    Begin-Op ('Deleting shelf ' + $label)
    try {
    if ($sh.Local) { Run-Busy { Delete-LocalShelf $sh.Id } }
    else {
        if (-not (Ensure-Online 'Delete shelf')) { Back-Offline; return }
        try { Run-Busy { Delete-Shelf $sh.Id } 'Deleting the shelf' } finally { Back-Offline }
    }
    Refresh-All
    } finally { End-Op }
}

function Total-Entries { $t = 0; foreach ($c in $script:CLs) { $t += $c.files.Count }; return $t }

# ---------------------------------------------------------------- background dv runs
# dv status can wait a minute for Diversion to finish syncing; dv ls takes seconds. These run in a
# background runspace so the window stays usable; a timer hands the result to a function by name.
# Self-check runs them inline ($script:SyncMode) so its checks see the results.
$script:Jobs = New-Object System.Collections.ArrayList
$script:SyncMode = $false
$script:DvJobScript = {
    param($root, [string[]]$a)
    $ErrorActionPreference = 'Continue'
    Set-Location -LiteralPath $root
    try { $o = @(& dv @a 2>&1 | ForEach-Object { "$_" }); $c = $LASTEXITCODE }
    catch { $o = @('dv could not be started: ' + $_.Exception.Message + ' (is Diversion installed and dv in PATH?)'); $c = 9009 }
    [pscustomobject]@{ Out = $o; Code = $c }
}.ToString()

# $busy: text shown while it runs, with the window locked ('' = quiet check, window stays usable)
function Start-DvAsync([string[]]$a, [string]$onDone, [bool]$quiet, [bool]$logLines, [string]$busy = '') {
    Write-Log ("RUN dv " + ($a -join ' ') + "   (background)")
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($busy) { Begin-Busy $busy }
    if ($script:SyncMode) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        Push-Location -LiteralPath $script:Root
        try { $out = @(& dv @a 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
        catch { $out = @('dv could not be started: ' + $_.Exception.Message); $code = 9009 }
        finally { Pop-Location; $ErrorActionPreference = $prev }
        try { & $onDone (Finish-Dv $a $out ([int]$code) $quiet $logLines $sw.Elapsed.TotalMilliseconds) }
        finally { if ($busy) { End-Busy } }
        return
    }
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript($script:DvJobScript).AddArgument($script:Root).AddArgument([string[]]$a)
        $job = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Args = $a; Done = $onDone; Raw = $false; Quiet = $quiet; LogLines = $logLines; Sw = $sw; Busy = [bool]$busy }
    } catch { if ($busy) { End-Busy }; throw }
    [void]$script:Jobs.Add($job)
    $jobTimer.Start()
}

# Offline folder scan in a background runspace: runs src\dvcl-scan.ps1 (same engine)
# Pending list right after dvcl paused sync: Diversion's last list as offline scan would give it
function Pending-FromLast($known) {
    $res = New-Object System.Collections.ArrayList
    foreach ($p in @($known)) {
        $k = Kind-Letter $p.Kind; $ex = Test-Path -LiteralPath (Full-Path $p.Path)
        if ($k -eq 'D') { if (-not $ex) { [void]$res.Add([pscustomobject]@{ Index = $res.Count + 1; Kind = 'Deleted'; Path = $p.Path; Old = $null }) } }
        elseif ($ex) { [void]$res.Add([pscustomobject]@{ Index = $res.Count + 1; Kind = $(if ($k -eq 'A') { 'New' } else { 'Modified' }); Path = $p.Path; Old = $null }) }
    }
    return $res
}
$script:PausedAt = $null
function Start-ScanAsync {
    if ($script:PausedAt -and ((Get-Date) - $script:PausedAt).TotalSeconds -lt 60 -and (Test-OfflineFlag)) {
        $script:PausedAt = $null
        $f = Pending-FromLast (Read-LastStatus)
        Write-Log ('offline scan skipped: sync paused just now, ' + $f.Count + ' pending from Diversion')
        Apply-Scan ([pscustomobject]@{ Files = $f; Fresh = $false; Error = $null })
        return
    }
    $script:PausedAt = $null
    if ($script:SyncMode) {
        Begin-Busy 'Scanning folder'
        try { $f = Get-OfflinePending; Apply-Scan ([pscustomobject]@{ Files = $f; Fresh = [bool]$script:BaselineFresh; Error = $null }) }
        catch { Apply-Scan ([pscustomobject]@{ Files = @(); Fresh = $false; Error = $_.Exception.Message }) }
        finally { End-Busy }
        return
    }
    $ps = [powershell]::Create()
    [void]$ps.AddCommand((Join-Path $PSScriptRoot 'dvcl-scan.ps1')).AddParameter('Workspace', $script:Root)
    Begin-Busy 'Scanning folder'
    $job = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Args = @('(folder scan)'); Done = 'Apply-Scan'; Raw = $true; Quiet = $true; LogLines = $false; Sw = [Diagnostics.Stopwatch]::StartNew(); Busy = $true }
    [void]$script:Jobs.Add($job)
    $jobTimer.Start()
}

$jobTimer = New-Object System.Windows.Forms.Timer
$jobTimer.Interval = 150
$jobTimer.Add_Tick({
    foreach ($j in @($script:Jobs)) {
        if (-not $j.Handle.IsCompleted) { continue }
        [void]$script:Jobs.Remove($j)
        $res = $null
        try { $o = $j.PS.EndInvoke($j.Handle); if ($o.Count -gt 0) { $res = $o[0] } }
        catch { if ($j.Raw) { $res = [pscustomobject]@{ Files = @(); Fresh = $false; Error = $_.Exception.Message } } else { $res = [pscustomobject]@{ Out = @('background dv failed: ' + $_.Exception.Message); Code = 9009 } } }
        finally { $j.PS.Dispose() }
        if ($j.Raw) {
            if ($null -eq $res -or $null -eq $res.PSObject.Properties['Files']) { $res = [pscustomobject]@{ Files = @(); Fresh = $false; Error = 'background scan returned nothing' } }
            try { & $j.Done $res } catch { & $script:OnSay ('ERROR: ' + $_.Exception.Message) 'Red' }
            finally { if ($j.Busy) { End-Busy } }
            continue
        }
        if ($null -eq $res) { $res = [pscustomobject]@{ Out = @('dv returned nothing'); Code = 9009 } }
        try { & $j.Done (Finish-Dv $j.Args @($res.Out) ([int]$res.Code) $j.Quiet $j.LogLines $j.Sw.Elapsed.TotalMilliseconds) }
        catch { & $script:OnSay ('ERROR: ' + $_.Exception.Message) 'Red' }
        finally { if ($j.Busy) { End-Busy } }
    }
    if ($script:Jobs.Count -eq 0) { $jobTimer.Stop() }
})

# While Diversion is still syncing, re-read the status every 4 s until it is done
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 4000
$pollTimer.Add_Tick({ $pollTimer.Stop(); Refresh-All })

# ---------------------------------------------------------------- state bar
$script:Mode = ''
$script:Head = ''
$script:ModeText = @{
    'offline' = 'Nothing syncs. Submit and Get latest go online, then back.'
    'online'  = 'Syncing to your private workspace.'
    'down'    = 'Diversion app closed or no network.'
    'busy'    = ''
    'loading' = ''
}
function Set-Mode([string]$state, [string]$desc) {
    $script:Mode = $state
    switch ($state) {
        'offline' { $modeBar.BackColor = $script:Pal.offline; $modeLbl.Text = 'OFFLINE'; $btnMode.Text = 'Go online'; $btnMode.Tag = 'on'; $btnMode.Visible = $true }
        'online'  { $modeBar.BackColor = $script:Pal.online; $modeLbl.Text = 'ONLINE'; $btnMode.Text = 'Go offline'; $btnMode.Tag = 'off'; $btnMode.Visible = $true }
        'busy'    { $modeBar.BackColor = $script:Pal.busy; $modeLbl.Text = 'BUSY'; $btnMode.Visible = $false }
        'down'    { $modeBar.BackColor = $script:Pal.down; $modeLbl.Text = 'NO DIVERSION'; $btnMode.Text = 'Retry'; $btnMode.Tag = 'retry'; $btnMode.Visible = $true }
        default   { $modeBar.BackColor = $script:Pal.loading; $modeLbl.Text = '...'; $btnMode.Visible = $false }
    }
    if (-not $desc) { $desc = $script:ModeText[$state] }
    $modeDesc.Text = $desc
    [System.Windows.Forms.Application]::DoEvents()
}
$btnMode.Add_Click({
    switch ([string]$btnMode.Tag) { 'on' { Do-Sync $true } 'off' { Do-Sync $false } default { Refresh-All } }
})

# "main @ dv.commit.52 - branch: up to date / NEW COMMITS / checked when online"
function Set-BranchInfo {
    if (-not $script:Branch) { $branchLbl.Text = ''; return }
    $h = ''
    if ($script:Offline) { $h = '' }
    elseif ($script:Head -and $script:WsCommit) { if ($script:Head -eq $script:WsCommit) { $h = 'up to date' } else { $h = 'NEW COMMITS' } }
    $branchLbl.Text = $script:Branch + ' @ ' + $script:WsCommit + $(if ($h) { '  -  ' + $h } else { '' })
    $branchLbl.ForeColor = $(if ($h -like '*NEW COMMITS*') { $script:Pal.Link } else { $script:Pal.Muted })
}

# ---------------------------------------------------------------- refresh
$script:StatusRunning = $false
$script:RefreshAgain = $false
$script:WsCommit = ''

# Reads the status in the background (dv status --nowait: answers at once, no wait for sync)
function Refresh-All {
    if (-not $script:Root) { $statusLbl.Text = 'No Diversion repo selected (Repo...)'; $tv.Nodes.Clear(); return }
    if ($script:StatusRunning) { $script:RefreshAgain = $true; return }
    Load-Db
    $script:StatusRunning = $true
    $statusLbl.Text = 'Reading status'
    if (-not $script:Mode) { Set-Mode 'loading' '' }
    # Offline (dvcl paused sync): Diversion is not asked at all (its first answer takes ~20 s);
    # branch/commit come from the last online read, files from the folder scan.
    if (Test-OfflineFlag) {
        $h = Read-LastHead
        Write-Log 'offline: dv status skipped'
        $script:LastStatusArgs = @('(offline, not asked)')
        Apply-Status ([pscustomobject]@{ Code = 0; SyncBusy = $false; Lines = @(('On branch ' + $h.Branch), ('Cloud workspace is over commit ' + $h.Commit), 'Workspace sync is paused.') })
        return
    }
    $script:LastStatusArgs = Status-Args $false
    Start-DvAsync $script:LastStatusArgs 'Apply-Status' $true $true 'Reading status'
}

# Reads the status now and waits until Diversion has synced everything (before submit / shelve / revert)
function Refresh-Now {
    $script:okNow = $false
    Run-Busy { Load-Db; Apply-Status (Invoke-Dv (Status-Args $true) $true); $script:okNow = $true } 'Uploading'
    return $script:okNow
}

function Apply-Status($r) {
    $script:StatusRunning = $false
    $unreachable = $false
    try { $st = Read-Status $r }
    catch {
        # Diversion not answering (app closed, no network): work offline from the folder scan
        & $script:OnSay ('ERROR: ' + $_.Exception.Message) 'Red'
        $unreachable = $true
        $st = [pscustomobject]@{ Files = @(); Branch = ''; Commit = ''; Paused = $true; Syncing = $false }
    }
    $script:Offline = [bool]$st.Paused -or (Test-OfflineFlag)
    if ($script:Offline) {
        # folder scan in the background (seconds on big projects), then the same display path
        $script:StatusRunning = $true
        $script:ScanSt = $st; $script:ScanUnreachable = $unreachable
        $statusLbl.Text = 'Offline: scanning your folder for changes...'
        Start-ScanAsync
        return
    } elseif (-not $st.Syncing) {
        Save-LastStatus $st.Files
        Save-LastHead $st.Branch $st.Commit
        # online without dvcl's offline flag: a leftover baseline is stale
        $bl = Dvcl-File 'baseline.tsv'; if (Test-Path -LiteralPath $bl) { Remove-Item -LiteralPath $bl -Force }
    }
    Show-Pending $st $unreachable
}

function Apply-Scan($res) {
    $script:StatusRunning = $false
    $st = $script:ScanSt
    if ($res.Error) { & $script:OnSay ('ERROR: folder scan failed: ' + $res.Error) 'Red' }
    $st.Files = @($res.Files)
    $script:BaselineFresh = [bool]$res.Fresh
    Show-Pending $st $script:ScanUnreachable
}

function Show-Pending($st, [bool]$unreachable) {
    Load-Shelves
    $script:Pending = $st.Files
    $script:Paused = $script:Offline
    $script:WsCommit = $st.Commit
    $script:PendingByPath = @{}
    foreach ($p in $st.Files) { $script:PendingByPath[$p.Path] = $p }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Build-Tree
    Write-Timing ('build-pending-tree (' + $st.Files.Count + ' files)') $sw.Elapsed.TotalMilliseconds
    # Diversion shelves: listed online in the background (no lock), cached for offline
    if (-not $script:Offline -and -not $unreachable) { if ($script:OpDepth -gt 0) { $script:OpLater['shelf'] = $true } else { Start-DvAsync @('shelf') 'Apply-DvShelves' $true $true '' } }
    $script:Branch = $st.Branch
    $note = ''; if ($script:BaselineFresh) { $note = '  (tracking from now)' }
    if ($unreachable) { Set-Mode 'down' '' }
    elseif ($script:Offline) { Set-Mode 'offline' ($script:ModeText['offline'] + $note) }
    elseif ($st.Syncing) { Set-Mode 'online' 'Syncing...' }
    else { Set-Mode 'online' '' }
    Set-BranchInfo
    $script:LocalBuilt = $false; $script:DepotBuilt = $false
    Show-Tab
    $sync = 'sync on'
    if ($st.Syncing) { $sync = 'sync on - Diversion still syncing, list updates by itself' }
    if ($script:Offline) { $sync = 'OFFLINE' }
    $statusLbl.Text = $script:Root + '    ' + $st.Files.Count + ' pending    dvcl ' + (Get-LocalVersion)
    $form.Text = 'dvcl - ' + (Split-Path -Leaf $script:Root)
    if (-not $script:FirstShown) { $script:FirstShown = $true; Write-Timing 'script-start-to-pending-list' $script:Clock.Elapsed.TotalMilliseconds }
    if ($st.Syncing -and -not $script:Paused -and -not $script:SyncMode -and $script:OpDepth -eq 0) { $pollTimer.Start() }
    if ($st.Branch -and -not $script:Offline) { if ($script:OpDepth -gt 0) { $script:OpLater['head'] = $st.Branch } else { Start-DvAsync @('show', $st.Branch) 'Apply-Head' $true $true } }
    Views-Refresh
    if ($script:RefreshAgain) { $script:RefreshAgain = $false; Refresh-All }
}

# Branch head vs workspace commit: "Get latest" says when the branch has new commits
function Apply-Head($r) {
    $script:Head = ''
    if ($r.Code -eq 0) { $script:Head = Read-HeadCommit $r.Lines }
    if ($script:Head -and $script:WsCommit -and $script:Head -ne $script:WsCommit) {
        $btnGet.Text = 'Get latest (new commits)'; $btnGet.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 200)
        $btnGet.ToolTipText = 'The branch is at ' + $script:Head + ', your workspace at ' + $script:WsCommit + '. Click to pull (dv update).'
    } else {
        $btnGet.Text = 'Get latest'; $btnGet.ForeColor = [System.Drawing.SystemColors]::ControlText
        $btnGet.ToolTipText = "Pull the branch's new commits into your workspace (dv update)"
    }
    Set-BranchInfo
}

# Changelist of the selected node ('default' if nothing selected)
function Selected-CL {
    $n = $tv.SelectedNode
    if (-not $n) { return 'default' }
    if ($n.Tag.Type -eq 'cl') { return $n.Tag.Name }
    return $n.Tag.Cl
}

# Target files: selected files, else the selected changelist's files
# Selectable rows: pending files and shelved files (key "shelf|<id>|<path>": a file can be both)
function Node-Key($n) {
    if (-not $n -or -not $n.Tag) { return $null }
    if ($n.Tag.Type -eq 'file') { return $n.Tag.Item.Path }
    if ($n.Tag.Type -eq 'shelffile') { return ('shelf|' + $n.Tag.ShelfId + '|' + $n.Tag.Path) }
    return $null
}
function Is-Sel($n) { $k = Node-Key $n; return ($k -and $script:Sel.Contains($k)) }
# Rows a Shift+click range runs over, top to bottom (shelved files only when their shelf is open)
function Sel-Nodes {
    $l = New-Object System.Collections.ArrayList
    foreach ($cn in $tv.Nodes) { foreach ($fn in $cn.Nodes) {
            if ($fn.Tag.Type -eq 'file') { [void]$l.Add($fn) }
            elseif ($fn.Tag.Type -eq 'shelf' -and $fn.IsExpanded) { foreach ($sf in $fn.Nodes) { [void]$l.Add($sf) } }
        } }
    return ,$l
}
# Selected shelved files of one shelf
function Sel-ShelfPaths([string]$shelfId) { return @($script:Sel | Where-Object { $_ -like ('shelf|' + $shelfId + '|*') } | ForEach-Object { $_.Substring(('shelf|' + $shelfId + '|').Length) }) }
function Target-Items {
    $sel = New-Object System.Collections.ArrayList
    foreach ($fn in (File-Nodes)) { if (Is-Sel $fn) { [void]$sel.Add($fn.Tag.Item) } }
    if ($sel.Count -gt 0) { return ,$sel.ToArray() }
    $n = $tv.SelectedNode
    if (-not $n) { return ,@() }
    if ($n.Tag.Type -eq 'file') { return ,@($n.Tag.Item) }
    if ($n.Tag.Type -in 'stale', 'shelf', 'shelffile') { return ,@() }
    if ($n.Tag.Type -eq 'more') { return ,@(Get-CLItems $script:Pending $n.Tag.Cl) }
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
    Begin-Op ('Submitting ' + $name)
    try {
    if ($script:Offline) { if (-not (Ensure-Online 'Submit')) { Back-Offline; return } }
    elseif (-not (Refresh-Now)) { return }
    try {
        $items = Get-CLItems $script:Pending $name
        if ($items.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($form, "Changelist '" + $name + "' has no pending file.", 'Submit'); return }
        $desc = ''; if ($name -ne 'default') { $desc = (Find-CL $name).desc }
        $r = Show-SubmitDialog $name $desc $items
        if (-not $r) { return }
        Run-Busy {
            if ($name -ne 'default' -and $r.Desc -ne $desc) { Set-CLDesc $name $r.Desc }
            Submit-Items $name $r.Items $r.Desc $script:Pending
        }
    } finally { Back-Offline }
    Refresh-All
    } finally { End-Op }
}

# Shelve = a Diversion shelf (team-visible) attached to the changelist: the selected files, else the
# changelist's files. Goes online for this only, then back offline.
function Do-Shelve {
    $name = Selected-CL
    $paths = @(Target-Items | ForEach-Object { $_.Path })
    if ($paths.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($form, "Changelist '" + $name + "' has no pending file.", 'Shelve'); return }
    Begin-Op ('Shelving ' + $paths.Count + ' file(s) of ' + $name)
    try {
    if (-not (Ensure-Online 'Shelve')) { Back-Offline; return }
    try {
        # Diversion's own list once synced (same paths)
        $items = @($script:Pending | Where-Object { $paths -icontains $_.Path })
        if ($items.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show($form, 'Diversion lists none of these files as changed.', 'Shelve'); return }
        $script:ShName = $name + '_' + (Get-Date -Format 'yyyyMMdd-HHmm'); $script:ShItems = $items
        Run-Busy { [void](Shelve-Items $script:ShName $script:ShItems) } 'Shelving'
    } finally { Back-Offline }
    Refresh-All
    } finally { End-Op }
}

function Do-Revert {
    $items = Target-Items
    if ($items.Count -eq 0) { return }
    $list = (@($items | Select-Object -First 15 | ForEach-Object { (Kind-Letter $_.Kind) + '  ' + $_.Path }) -join "`r`n")
    if ($items.Count -gt 15) { $list += "`r`n... and " + ($items.Count - 15) + " more" }
    $q = "Discard local changes of " + $items.Count + " path(s)?`r`n(Your versions are copied to .dvcl\revert-backup on this PC; new files are skipped.)`r`n`r`n" + $list
    if (-not (Ask-YesNo $q 'Revert')) { return }
    Begin-Op ('Reverting ' + $items.Count + ' file(s)')
    try {
    $writes = @($items | Where-Object { (Kind-Letter $_.Kind) -ne 'A' } | ForEach-Object { $_.Path })
    if (-not (Ue-Prepare $writes 'Revert')) { return }
    $prefix = Selected-CL
    if (-not (Ensure-Online 'Revert')) { Back-Offline; return }
    try {
        Run-Busy {
            # only what is still pending once Diversion has synced
            $now = Pending-Set (Get-Pending $true).Files
            $still = @($items | Where-Object { $now.ContainsKey($_.Path.ToLowerInvariant()) })
            [void](Revert-Items $prefix $still)
        } 'Reverting'
    } finally { try { Ue-Finish $writes } finally { Back-Offline } }
    Refresh-All
    } finally { End-Op }
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
    if ($script:ShelfMap.ContainsKey($name.ToLowerInvariant())) { [void][System.Windows.Forms.MessageBox]::Show($form, "'" + $name + "' has shelves. Delete them first.", 'Delete changelist', 'OK', 'Information'); return }
    if (-not (Ask-YesNo ("Delete changelist '" + $name + "'?`r`nIts files go back to default. Nothing is reverted.") 'Delete changelist')) { return }
    Run-Busy { Remove-CL $name; Build-Tree }
}

function Do-Shelves {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Shelves'; $d.Font = $fontUi; $d.StartPosition = 'CenterParent'; $d.Width = 560; $d.Height = 380; $d.ShowInTaskbar = $false
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'; $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false
    [void]$lv.Columns.Add('Shelf', 300); [void]$lv.Columns.Add('Where', 80); [void]$lv.Columns.Add('Created', 140)
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel; $bar.Dock = 'Bottom'; $bar.Height = 38; $bar.FlowDirection = 'RightToLeft'; $bar.Padding = New-Object System.Windows.Forms.Padding(6)
    $bClose = New-Object System.Windows.Forms.Button; $bClose.Text = 'Close'; $bClose.DialogResult = 'Cancel'
    $bDel   = New-Object System.Windows.Forms.Button; $bDel.Text = 'Delete...'
    $bApply = New-Object System.Windows.Forms.Button; $bApply.Text = 'Unshelve'
    $bar.Controls.AddRange(@($bClose, $bDel, $bApply))
    $d.Controls.Add($lv); $d.Controls.Add($bar); $d.CancelButton = $bClose
    $fill = {
        $lv.Items.Clear()
        $all = @(Get-LocalShelves)
        if (-not $script:Offline) { $all += @(Get-Shelves) }
        foreach ($s in $all) {
            $label = $s.Name; $where = 'Diversion'
            if ($s.Local) { $label = $s.Id; $where = 'local' }
            $it = New-Object System.Windows.Forms.ListViewItem($label)
            [void]$it.SubItems.Add($where); [void]$it.SubItems.Add($s.Created); $it.Tag = $s
            [void]$lv.Items.Add($it)
        }
    }
    $bApply.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $s = $lv.SelectedItems[0].Tag
        if ($s.Local) {
            $d.Close(); Do-Unshelve $s (Shelf-ClName $s); return
        } else {
            if (-not (Ensure-Online 'Unshelving from Diversion')) { return }
            if (-not (Ask-YesNo ("Apply shelf '" + $s.Name + "' to your workspace? (the shelf is kept)") 'Unshelve')) { return }
            Run-Busy { Apply-Shelf $s.Id }
        }
        $d.Close()
    })
    $bDel.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $s = $lv.SelectedItems[0].Tag
        if (-not (Ask-YesNo ("Permanently delete shelf '" + $s.Name + "'? This cannot be undone.") 'Delete shelf')) { return }
        Run-Busy { if ($s.Local) { Delete-LocalShelf $s.Id } else { Delete-Shelf $s.Id }; & $fill }
    })
    $d.Add_Shown({ Run-Busy { & $fill } })
    Theme-Walk $d
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

# State bar button. Going offline waits until Diversion has synced, then records the folder.
function Do-Sync([bool]$on) {
    Begin-Op $(if ($on) { 'Going online' } else { 'Going offline' })
    try {
        Set-Mode 'busy' ''
        Run-Busy { Set-Sync $on } $(if ($on) { 'Resuming sync' } else { 'Pausing sync' })
        Refresh-All
    } finally { End-Op }
}

# After an action that went online only for itself: pause sync again (new baseline taken)
$script:WentOnline = $false
function Back-Offline {
    $script:WasBack = $false
    if (-not $script:WentOnline) { return }
    $script:WentOnline = $false
    Set-Mode 'busy' ''
    Run-Busy { Set-Sync $false } 'Going offline'
    if (Test-OfflineFlag) { $script:PausedAt = Get-Date }
    $script:WasBack = $true
}

# Actions that need the server go online by themselves (no question): resume sync, wait until
# Diversion has uploaded the pending changes to your private workspace, then the caller continues
# and Back-Offline pauses sync again. The state bar shows each step.
function Ensure-Online([string]$what) {
    if (-not $script:Offline) { return $true }
    Set-Mode 'busy' $what
    $script:okOn = $false
    Run-Busy { Set-Sync $true; $script:okOn = $true } 'Going online'
    if (-not $script:okOn) { return $false }
    $script:WentOnline = $true
    Set-Mode 'busy' $what
    if (-not (Refresh-Now)) { return $false }
    if ($script:Offline) { [void][System.Windows.Forms.MessageBox]::Show($form, 'Diversion still reports sync as paused. Try again in a moment.', $what, 'OK', 'Warning'); return $false }
    Set-Mode 'busy' $what
    return $true
}

# Get latest: the files of the newer commits are released in Unreal first and reloaded after
function Do-GetLatest {
    Begin-Op 'Getting latest'
    try {
    if (-not (Ensure-Online 'Get latest')) { Back-Offline; return }
    $script:Incoming = @()
    try {
        Run-Busy { $script:Incoming = @(Incoming-Files $script:WsCommit) } 'Listing the incoming files'
        if (-not (Ue-Prepare $script:Incoming 'Get latest')) { return }
        try {
            Run-Busy { Get-Latest; Say ("Got " + $script:Incoming.Count + " changed file(s). Your pending changes were kept.") 'Gray' } 'Getting latest'
        } finally { Ue-Finish $script:Incoming }
    } finally { Back-Offline }
    Refresh-All
    } finally { End-Op }
}

function Do-History([string]$rel) { Show-History $rel }

# Not-pending entries: one changelist ($name) or all ('')
function Do-CleanStale([string]$name) {
    $n = 0; foreach ($c in $script:CLs) { if (-not $name -or $c.name -ieq $name) { $n += (Stale-Of $script:Pending $c).Count } }
    if ($n -eq 0) { return }
    if (-not (Ask-YesNo ("Remove " + $n + " entr" + $(if ($n -eq 1) { 'y' } else { 'ies' }) + " that are no longer pending (already submitted or reverted)?`r`nFiles are not touched.") 'Remove not-pending entries')) { return }
    Run-Busy { [void](Clean-Stale $script:Pending $name $false); Build-Tree }
}

function Do-RemoveEntry([string]$rel) {
    if (-not $rel) { return }
    Run-Busy { Detach $rel; Save-Db; Say ("Removed from its changelist: " + $rel) 'Green'; Build-Tree }
}

function Do-Lock([string[]]$paths, [bool]$on) {
    $paths = @($paths | Where-Object { $_ })
    if ($paths.Count -eq 0) { return }
    if (-not (Ensure-Online 'Locking')) { Back-Offline; return }
    try { Run-Busy { Lock-Paths $paths $on } } finally { Back-Offline; if ($script:WasBack) { Refresh-All } }
}

function Do-ShowLocks {
    $script:locks = $null
    Run-Busy { $script:locks = Get-Locks }
    if ($null -ne $script:locks) {
        $l = @($script:locks); if ($l.Count -eq 0) { $l = @('(no locks)') }
        Show-TextDialog 'Locks' $l
    }
}

# Selective sync of one folder on this PC
function Do-FolderSync([string]$rel, [bool]$on) {
    if (-not $rel) { return }
    if (-not $on -and -not (Ask-YesNo ("Stop downloading '" + $rel + "' on this PC?`r`nDiversion stops syncing it here; its local files may be removed from this PC. It stays in Diversion, and you can download it again from the Depot tree.`r`nDiversion refuses this while you have pending files.") 'Stop downloading folder')) { return }
    Run-Busy { Set-FolderSync $rel $on }
    Refresh-All
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
function Add-Placeholder($node) { $ph = $node.Nodes.Add('...'); $ph.ImageKey = 'none'; $ph.SelectedImageKey = 'none' }
function Is-Unloaded($node) { return ($node.Nodes.Count -eq 1 -and $null -eq $node.Nodes[0].Tag) }

# Icon + color by state; folders also get the badge when they are pending themselves (new folder)
function Mark-Pending($node, [string]$rel) {
    $isDir = $node.Tag.Type -in 'dir', 'ddir'
    $p = $script:PendingByPath[$rel]
    if ($p) { $k = Kind-Letter $p.Kind; $node.ForeColor = $colKind[$k]; Set-Icon $node ($(if ($isDir) { 'folder-' } else { 'file-' }) + $k) }
    else { Set-Icon $node $(if ($isDir) { 'folder' } else { 'file' }) }
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
        Mark-Pending $n (Norm $d)
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
        Mark-Pending $n $rel
        # not downloaded on this PC (selective sync): grey
        if (-not [System.IO.Directory]::Exists((Join-Path $script:Root ($rel -replace '/', '\')))) { $n.ForeColor = $script:Pal.Stale; Set-Icon $n 'folderoff'; $n.ToolTipText = 'not on this PC' }
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

# Fill both trees after a refresh, then go back to the paths shown in their path bars.
# The depot list (dv ls, can take seconds) is kept per workspace commit: reloaded only when it changes.
$script:DepotBuilt = $false; $script:DepotLoading = $false; $script:DepotCommit = $null
function Show-Tab {
    if (-not $script:Root) { return }
    if (-not $script:LocalBuilt) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $tvLocal.BeginUpdate(); $tvLocal.Nodes.Clear()
        Add-LocalChildren $tvLocal.Nodes $script:Root
        $tvLocal.EndUpdate(); $script:LocalBuilt = $true
        if ($barLocal.Box.Text) { Navigate-Tree 'local' $barLocal.Box.Text $true }
        Write-Timing 'build-local-tree' $sw.Elapsed.TotalMilliseconds
    }
    if (-not $script:DepotBuilt) {
        if ($null -ne $script:DepotPaths -and $script:DepotPaths.Length -gt 0 -and $script:DepotCommit -eq $script:WsCommit) { Build-DepotTree }
        elseif ($null -ne ($cached = Read-DepotCache $script:WsCommit)) {
            # same commit as last time: the saved list is exact, no dv ls (15-40 s)
            $script:DepotPaths = $cached; $script:DepotCommit = $script:WsCommit
            Write-Log ('depot: cache for ' + $script:WsCommit + ' (' + $cached.Length + ' paths)')
            Build-DepotTree
        }
        elseif (-not $script:DepotLoading) {
            # new commit: dv ls in the background WITHOUT locking the window (only the Depot tree waits)
            $script:DepotLoading = $true
            $tvDepot.Nodes.Clear(); $ph = $tvDepot.Nodes.Add('Loading depot...'); $ph.ImageKey = 'none'; $ph.SelectedImageKey = 'none'
            Start-DvAsync @('ls') 'Apply-Depot' $true $false ''
        }
    }
}

function Build-DepotTree {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $tvDepot.BeginUpdate(); $tvDepot.Nodes.Clear()
    Add-DepotChildren $tvDepot.Nodes ''
    $tvDepot.EndUpdate(); $script:DepotBuilt = $true
    if ($barDepot.Box.Text) { Navigate-Tree 'depot' $barDepot.Box.Text $true }
    Write-Timing ('build-depot-tree (' + $script:DepotPaths.Length + ' paths)') $sw.Elapsed.TotalMilliseconds
}

function Apply-Depot($r) {
    $script:DepotLoading = $false
    try { $paths = Read-DepotResult $r }
    catch {
        $tvDepot.Nodes.Clear(); $ph = $tvDepot.Nodes.Add('Depot unavailable. F5.'); $ph.ImageKey = 'none'; $ph.SelectedImageKey = 'none'
        & $script:OnSay ('ERROR: ' + $_.Exception.Message) 'Red'; $script:DepotPaths = $null; return
    }
    $script:DepotPaths = $paths; $script:DepotCommit = $script:WsCommit
    Save-DepotCache $script:WsCommit $paths
    Build-DepotTree
}

# Expands a tree down to a path and selects it. Accepts a full Windows path inside the workspace,
# a repo path (MyGame/Content/...) and either slash. $quiet: no log line when not found.
function Navigate-Tree([string]$kind, [string]$text, [bool]$quiet = $false) {
    $t = ([string]$text).Trim().Trim('"')
    if (-not $t -or -not $script:Root) { return }
    $tree = Tree-Of $kind
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
$script:DrawTreeNode = {
    param($s, $e)
    if (-not $script:Dark -or $s.Focused -or -not ($e.State -band [System.Windows.Forms.TreeNodeStates]::Selected) -or $e.Bounds.Width -le 0) { $e.DrawDefault = $true; return }
    $b = New-Object System.Drawing.SolidBrush($script:Pal.Hi)
    $e.Graphics.FillRectangle($b, $e.Bounds); $b.Dispose()
    $fnt = $e.Node.NodeFont; if (-not $fnt) { $fnt = $s.Font }
    $fc = $e.Node.ForeColor; if ($fc.IsEmpty) { $fc = $script:Pal.Fore }
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Node.Text, $fnt, $e.Bounds, $fc, [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, NoPrefix, SingleLine')
}
foreach ($t0 in @($tvLocal, $tvDepot)) { $t0.Add_DrawNode($script:DrawTreeNode) }
foreach ($t0 in @($tv, $tvLocal, $tvDepot)) { $t0.Add_LostFocus({ param($s, $e) $s.Invalidate() }); $t0.Add_GotFocus({ param($s, $e) $s.Invalidate() }) }
$tvLocal.Add_AfterSelect({ param($s, $e) $barLocal.Box.Text = Node-Display $e.Node; if ($e.Node.Tag) { History-Follow (Node-Rel $e.Node) } })
$tvDepot.Add_AfterSelect({ param($s, $e) $barDepot.Box.Text = Node-Display $e.Node; if ($e.Node.Tag) { History-Follow (Node-Rel $e.Node) } })
$tv.Add_AfterSelect({ param($s, $e) if ($e.Node.Tag -and $e.Node.Tag.Type -in 'file', 'stale', 'shelffile') { $r = Selected-Rel; if (-not $r -and $e.Node.Tag.Path) { $r = $e.Node.Tag.Path }; History-Follow $r } })

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
#   ...and onto the other tree: finds it there
$script:DragFind = $null
function Start-TreeDrag($src, [string]$rel, $items) {
    $script:DragFind = $rel
    $script:DragItems = $(if ($items -and @($items).Count -gt 0) { @($items) } else { $null })
    try { [void]$src.DoDragDrop('dvcl', [System.Windows.Forms.DragDropEffects]'Move, Link') }
    finally { $script:DragFind = $null; $script:DragItems = $null }
}
$dragFromTree = {
    param($s, $e)
    if (-not $e.Item.Tag) { return }
    $rel = Node-Rel $e.Item
    Start-TreeDrag $s $rel (Pending-Under $rel)
}
$tvLocal.Add_ItemDrag($dragFromTree)
$tvDepot.Add_ItemDrag($dragFromTree)

# Drop on Local / Depot (from a tree, a changelist or Windows Explorer): show it in that tree
function Drop-FindPath($data) {
    if ($data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $f = @($data.GetData([System.Windows.Forms.DataFormats]::FileDrop)); if ($f.Count) { return [string]$f[0] } }
    return $script:DragFind
}
$findDragOver = {
    param($s, $e)
    if (Drop-FindPath $e.Data) {
        if ($e.AllowedEffect -band [System.Windows.Forms.DragDropEffects]::Link) { $e.Effect = [System.Windows.Forms.DragDropEffects]::Link } else { $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy }
    } else { $e.Effect = [System.Windows.Forms.DragDropEffects]::None }
}
$findDrop = { param($s, $e) $p = Drop-FindPath $e.Data; if ($p) { $s.Focus(); Navigate-Tree $s.Tag $p } }
foreach ($t in @($tvLocal, $tvDepot)) { $t.AllowDrop = $true; $t.Add_DragEnter($findDragOver); $t.Add_DragOver($findDragOver); $t.Add_DragDrop($findDrop) }

# Right-click on Local / Depot
$menuL = New-Object System.Windows.Forms.ContextMenuStrip
function CL-MenuText([string]$nm) { if ($nm -eq 'default') { return 'default' }; $c = Find-CL $nm; if ($c) { return ('#' + $c.id + '  ' + $nm) }; return $nm }
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
        $mi = Add-MenuItem $mv (CL-MenuText $nm) $null $true
        $mi.Tag = $nm
        $mi.Add_Click({ param($src, $ev) Do-Move $src.Tag $script:MenuItems })
    }
    [void]$mv.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $mv 'New changelist...' { [void](Do-NewCL $script:MenuItems) })
    [void]$menuL.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $isFile = $e.Node.Tag.Type -in 'lfile', 'dfile'
    [void](Add-MenuItem $menuL 'History' { Do-History $script:MenuRel } $isFile)
    if ($isFile) {
        [void](Add-MenuItem $menuL 'Lock' { Do-Lock @($script:MenuRel) $true })
        [void](Add-MenuItem $menuL 'Unlock' { Do-Lock @($script:MenuRel) $false })
    } else {
        [void](Add-MenuItem $menuL 'Download this folder to this PC' { Do-FolderSync $script:MenuRel $true })
        [void](Add-MenuItem $menuL 'Stop downloading this folder...' { Do-FolderSync $script:MenuRel $false })
    }
    $script:MenuOther = $(if ($s.Tag -eq 'depot') { 'local' } else { 'depot' })
    [void](Add-MenuItem $menuL ('Show in ' + $(if ($script:MenuOther -eq 'depot') { 'Depot' } else { 'Local' }) + ' tree') { Navigate-Tree $script:MenuOther $script:MenuRel })
    $mx = Add-MenuItem $menuL 'Show in Explorer' { Open-PathInExplorer 'local' $script:MenuDisplay }; $mx.ShortcutKeyDisplayString = 'Ctrl+Shift+S'
    [void](Add-MenuItem $menuL 'Copy path' { [System.Windows.Forms.Clipboard]::SetText($script:MenuDisplay) })
    Theme-Strip $menuL
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

# ---------------------------------------------------------------- theme
# Dark toolbars / menus without white outlines, dark scrollbars, dark title bar (compiled once, cached)
$script:UiSource = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace DvclNative {
  public class DarkColors : ProfessionalColorTable {
    Color b, bd, hl;
    public DarkColors(Color back, Color border, Color high) { b = back; bd = border; hl = high; UseSystemColors = false; }
    public override Color ToolStripGradientBegin { get { return b; } }
    public override Color ToolStripGradientMiddle { get { return b; } }
    public override Color ToolStripGradientEnd { get { return b; } }
    public override Color ToolStripBorder { get { return b; } }
    public override Color ToolStripDropDownBackground { get { return b; } }
    public override Color ToolStripContentPanelGradientBegin { get { return b; } }
    public override Color ToolStripContentPanelGradientEnd { get { return b; } }
    public override Color StatusStripGradientBegin { get { return b; } }
    public override Color StatusStripGradientEnd { get { return b; } }
    public override Color MenuStripGradientBegin { get { return b; } }
    public override Color MenuStripGradientEnd { get { return b; } }
    public override Color MenuBorder { get { return bd; } }
    public override Color MenuItemBorder { get { return hl; } }
    public override Color MenuItemSelected { get { return hl; } }
    public override Color MenuItemSelectedGradientBegin { get { return hl; } }
    public override Color MenuItemSelectedGradientEnd { get { return hl; } }
    public override Color MenuItemPressedGradientBegin { get { return hl; } }
    public override Color MenuItemPressedGradientMiddle { get { return hl; } }
    public override Color MenuItemPressedGradientEnd { get { return hl; } }
    public override Color ImageMarginGradientBegin { get { return b; } }
    public override Color ImageMarginGradientMiddle { get { return b; } }
    public override Color ImageMarginGradientEnd { get { return b; } }
    public override Color ButtonSelectedHighlight { get { return hl; } }
    public override Color ButtonSelectedBorder { get { return hl; } }
    public override Color ButtonSelectedGradientBegin { get { return hl; } }
    public override Color ButtonSelectedGradientMiddle { get { return hl; } }
    public override Color ButtonSelectedGradientEnd { get { return hl; } }
    public override Color ButtonPressedGradientBegin { get { return hl; } }
    public override Color ButtonPressedGradientMiddle { get { return hl; } }
    public override Color ButtonPressedGradientEnd { get { return hl; } }
    public override Color ButtonCheckedGradientBegin { get { return hl; } }
    public override Color ButtonCheckedGradientMiddle { get { return hl; } }
    public override Color ButtonCheckedGradientEnd { get { return hl; } }
    public override Color SeparatorDark { get { return bd; } }
    public override Color SeparatorLight { get { return b; } }
    public override Color GripDark { get { return b; } }
    public override Color GripLight { get { return b; } }
    public override Color OverflowButtonGradientBegin { get { return b; } }
    public override Color OverflowButtonGradientMiddle { get { return b; } }
    public override Color OverflowButtonGradientEnd { get { return b; } }
  }
  public class DarkRenderer : ToolStripProfessionalRenderer {
    public DarkRenderer(ProfessionalColorTable t) : base(t) { RoundedEdges = false; }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { if (e.ToolStrip is ToolStripDropDown) base.OnRenderToolStripBorder(e); }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) { e.ArrowColor = e.Item.ForeColor; base.OnRenderArrow(e); }
  }
  public static class Win {
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string id);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  }
}
'@
$script:UiOk = $null
function Ensure-Ui {
    if ($null -eq $script:UiOk) { $script:UiOk = Ensure-Native 'DvclNative.DarkRenderer' 'dvclui' $script:UiSource @('System.Windows.Forms', 'System.Drawing') }
    return $script:UiOk
}

function Theme-Walk($root) {
    $P = $script:Pal; $d = $script:Dark; $ui = Ensure-Ui
    foreach ($c in @($root) + @(Get-Descendants $root)) {
        if ($c -eq $modeBar -or $c -eq $modeFlow -or $c -is [System.Windows.Forms.ProgressBar] -or $c -is [System.Windows.Forms.PictureBox]) { continue }
        if ($c -is [System.Windows.Forms.TreeView] -or $c -is [System.Windows.Forms.ListView] -or $c -is [System.Windows.Forms.CheckedListBox] -or ($c -is [System.Windows.Forms.TextBox])) {
            $c.BackColor = $(if ($c -eq $logBox) { $P.Log } else { $P.Input }); $c.ForeColor = $P.Fore
            if ($c -is [System.Windows.Forms.TreeView]) { $c.LineColor = $P.Muted }
            # no light 3D frames in dark; dark scrollbars / expanders (Windows 10+)
            if ($c -is [System.Windows.Forms.TreeView] -or $c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.ListView]) { $c.BorderStyle = $(if ($d) { 'FixedSingle' } else { 'Fixed3D' }) }
            if ($c -is [System.Windows.Forms.TextBox] -and -not $c.Multiline -and $d) { $c.BorderStyle = 'FixedSingle' }
            if ($ui) { try { [void][DvclNative.Win]::SetWindowTheme($c.Handle, $(if ($d) { 'DarkMode_Explorer' } else { 'Explorer' }), $null) } catch {} }
            if ($c -is [System.Windows.Forms.ListView] -and $ui) {
                # column header (LVM_GETHEADER)
                try { $hh = [DvclNative.Win]::SendMessage($c.Handle, 0x101F, [IntPtr]::Zero, [IntPtr]::Zero); if ($hh -ne [IntPtr]::Zero) { [void][DvclNative.Win]::SetWindowTheme($hh, $(if ($d) { 'DarkMode_ItemsView' } else { 'Explorer' }), $null) } } catch {}
            }
            if ($c -is [System.Windows.Forms.TreeView]) {
                # double-buffered (TVM_SETEXTENDEDSTYLE, TVS_EX_DOUBLEBUFFER): no flicker on selection repaint
                if ($ui) { try { [void][DvclNative.Win]::SendMessage($c.Handle, 0x112C, [IntPtr]4, [IntPtr]4) } catch {} }
                # dark: no tree lines = dark expand arrows instead of light +/- boxes; dark path tooltip (TVM_GETTOOLTIPS)
                if ($c -eq $tv) { $c.ShowLines = -not $d }
                # dark: the selection of an unfocused tree is drawn dark (Windows draws it light)
                $c.DrawMode = $(if ($d -or $c -eq $tv) { 'OwnerDrawText' } else { 'Normal' })
                if ($ui) { try { $tt = [DvclNative.Win]::SendMessage($c.Handle, 0x1119, [IntPtr]::Zero, [IntPtr]::Zero); if ($tt -ne [IntPtr]::Zero) { [void][DvclNative.Win]::SetWindowTheme($tt, $(if ($d) { 'DarkMode_Explorer' } else { 'Explorer' }), $null) } } catch {} }
            }
        }
        elseif ($c -is [System.Windows.Forms.Button]) {
            if ($d) { $c.FlatStyle = 'Flat'; $c.BackColor = $P.Back; $c.ForeColor = $P.Fore; $c.FlatAppearance.BorderColor = $P.Border; $c.FlatAppearance.MouseOverBackColor = $P.Hi }
            else { $c.FlatStyle = 'System'; $c.UseVisualStyleBackColor = $true; $c.ForeColor = $P.Fore }
        }
        elseif ($c -is [System.Windows.Forms.Label]) { if ($c -ne $branchLbl) { $c.ForeColor = $P.Fore } }
        elseif ($c -is [System.Windows.Forms.ToolStrip]) { Theme-Strip $c }
        elseif ($c -is [System.Windows.Forms.Form] -or $c -is [System.Windows.Forms.Panel] -or $c -is [System.Windows.Forms.SplitContainer] -or $c -is [System.Windows.Forms.FlowLayoutPanel]) { $c.BackColor = $P.Back; $c.ForeColor = $P.Fore }
        if ($c -is [System.Windows.Forms.Form]) { Set-TitleDark $c $d }
    }
}
# Toolbars, status bar and menus: dark renderer without outlines, or back to Windows look
function Theme-Strip($c) {
    $P = $script:Pal
    if ($script:Dark -and (Ensure-Ui)) { $c.Renderer = New-Object DvclNative.DarkRenderer (New-Object DvclNative.DarkColors $P.Back, $P.Border, $P.Hi) }
    else { $c.RenderMode = 'ManagerRenderMode' }
    $c.BackColor = $P.Back; $c.ForeColor = $P.Fore
    foreach ($it in $c.Items) {
        if ($it -ne $btnGet -or $btnGet.Text -eq 'Get latest') { $it.ForeColor = $P.Fore }
        if ($it -is [System.Windows.Forms.ToolStripDropDownItem]) { foreach ($sub in $it.DropDownItems) { $sub.ForeColor = $P.Fore }; Theme-Strip $it.DropDown }
    }
}
function Get-Descendants($c) { foreach ($x in $c.Controls) { $x; Get-Descendants $x } }

# Windows 10/11 dark title bar (best effort)
function Set-TitleDark($f, [bool]$on) {
    if (-not (Ensure-Ui)) { return }
    try { $v = [int]$on; [void][DvclNative.Win]::DwmSetWindowAttribute($f.Handle, 20, [ref]$v, 4) } catch {}
}

function Apply-Theme([bool]$dark, [bool]$rebuild = $true) {
    $script:Dark = $dark
    $script:Pal = $(if ($dark) { $script:PalDark } else { $script:PalLight })
    foreach ($k in 'A', 'M', 'D', 'R') { $colKind[$k] = $script:Pal[$k] }
    $colKind['!'] = $script:Pal.X; $colKind['?'] = $script:Pal.Q
    Theme-Walk $form
    foreach ($f in (Float-Forms)) { Theme-Docked $f }
    Style-Zones
    foreach ($v in @($script:Views.Values)) { $v.Info.LinkColor = $script:Pal.Link; $v.Info.ActiveLinkColor = $script:Pal.Link; if ($v.Commits.Count) { Fill-Commits $v } }
    foreach ($m in @($menu, $menuL, $trayMenu, $script:TabMenu, $script:ViewMenu)) { if ($m) { Theme-Strip $m } }
    $btnTheme.Text = $(if ($dark) { 'Light' } else { 'Dark' })
    if ($script:Mode) { Set-Mode $script:Mode $modeDesc.Text }
    Set-BranchInfo
    if ($rebuild -and $script:Root) { Build-Tree; $script:LocalBuilt = $false; $script:DepotBuilt = $false; Show-Tab }
    Save-Settings
}

# ---------------------------------------------------------------- outside changes
# Another dvcl window, the command line or an agent may change changelists / shelves meanwhile:
# every change re-reads the file first (core), and this timer shows outside changes within 2 s.
$script:DbStamp = 0; $script:ShelfStamp = 0
function Get-Stamps {
    $a = 0; $b = 0
    try { if ($script:Db -and (Test-Path -LiteralPath $script:Db)) { $a = (Get-Item -LiteralPath $script:Db).LastWriteTimeUtc.Ticks } } catch {}
    try { $sd = Dvcl-File 'shelves'; if (Test-Path -LiteralPath $sd) { $b = (Get-Item -LiteralPath $sd).LastWriteTimeUtc.Ticks } } catch {}
    return @($a, $b)
}
$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 2000
$watchTimer.Add_Tick({
    if (-not $script:Root -or $script:BusyDepth -gt 0 -or $script:StatusRunning) { return }
    $st = Get-Stamps
    if ($script:DbStamp -eq 0) { $script:DbStamp = $st[0]; $script:ShelfStamp = $st[1]; return }
    if ($st[0] -ne $script:DbStamp -or $st[1] -ne $script:ShelfStamp) {
        $script:DbStamp = $st[0]; $script:ShelfStamp = $st[1]
        Load-Db; Load-Shelves; Build-Tree
        Write-Log 'changelists / shelves changed: view updated'
    }
})

# ---------------------------------------------------------------- toolbar
[void](Add-Btn 'Refresh' 'Reload pending changes (F5)' { Refresh-All })
[void]$tool.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-Btn 'New' 'New changelist; selected files move into it (Ctrl+N)' { [void](Do-NewCL (Target-Items-IfChecked)) })
[void](Add-Btn 'Submit...' 'Submit the selected changelist (Ctrl+Enter)' { Do-Submit })
[void](Add-Btn 'Shelve' 'Shelve the selected files or changelist to Diversion (team-visible), workspace untouched' { Do-Shelve })
[void](Add-Btn 'Revert...' 'Discard local changes of the selected files (your versions copied to .dvcl\revert-backup)' { Do-Revert })
[void](Add-Btn 'Shelves' 'List, unshelve or delete shelves' { Do-Shelves })
[void](Add-Btn 'Locks' 'Files locked in this repository' { Do-ShowLocks })
[void]$tool.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$btnGet = Add-Btn 'Get latest' "Pull the branch's new commits into your workspace (dv update)" { Do-GetLatest }
$ddTools = Add-DropBtn 'Tools' 'Changelist maintenance'
[void](Add-DropItem $ddTools 'Remove all not-pending entries' 'Drop entries Diversion no longer reports (committed elsewhere)' { Do-CleanStale '' })
[void](Add-DropItem $ddTools 'Recover entries lost by dvcl 0.2' 'Put back files that dvcl 0.2 dropped from changelists while sync was paused' { Do-Recover })
[void]$tool.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$ddView = Add-DropBtn 'View' 'Panels: drag a tab to move it, out of the window for its own window; right-click a tab for more'
foreach ($pid0 in @($script:Pads.Keys)) {
    $mi = Add-DropItem $ddView ($script:Pads[$pid0].Title) ('Bring ' + $script:Pads[$pid0].Title + ' to front') { param($src, $ev) Activate-Pad $src.Tag; $z = Zone-Of $src.Tag; if ($z -and $z.Form) { $z.Form.Activate() } }
    $mi.Tag = $pid0
}
[void]$ddView.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-DropItem $ddView 'Reset layout' 'Panels back to their places' { Reset-Layout })
[void](Add-Btn 'Repo...' 'Pick another Diversion workspace' { Do-ChangeRepo })
$bBug = Add-Btn 'Report bug' 'Open a new issue on GitHub' { Do-ReportBug }; $bBug.Alignment = 'Right'
$bUpd = Add-Btn 'Update' 'Check GitHub for a new version and update' { Do-Update }; $bUpd.Alignment = 'Right'
$btnTheme = Add-Btn 'Dark' 'Dark / light theme' { Apply-Theme (-not $script:Dark) }; $btnTheme.Alignment = 'Right'

# Selected files only (used by "New changelist": nothing selected = empty changelist)
function Target-Items-IfChecked {
    $sel = New-Object System.Collections.ArrayList
    foreach ($fn in (File-Nodes)) { if (Is-Sel $fn) { [void]$sel.Add($fn.Tag.Item) } }
    return ,$sel.ToArray()
}

# ---------------------------------------------------------------- tree events

$tv.Add_NodeMouseDoubleClick({ param($s, $e) if ($e.Node.Tag.Type -eq 'file') { $tv.SelectedNode = $e.Node; Do-ShowInExplorer } elseif ($e.Node.Tag.Type -eq 'cl') { $tv.SelectedNode = $e.Node; Do-EditDesc } })

# Drag files onto a changelist (or onto a file of it)
$tv.Add_AfterExpand({ param($s, $e) if (-not $script:InBuild -and $e.Node.Tag.Type -eq 'shelf') { [void]$script:OpenShelves.Add([string]$e.Node.Tag.Shelf.Id) } })
$tv.Add_AfterCollapse({ param($s, $e) if (-not $script:InBuild -and $e.Node.Tag.Type -eq 'shelf') { [void]$script:OpenShelves.Remove([string]$e.Node.Tag.Shelf.Id) } })
$script:DragShelf = $null
$tv.Add_ItemDrag({
    param($s, $e)
    if ($e.Item.Tag.Type -in 'shelf', 'shelffile') {
        # a shelf, or shelved files (the selected ones if this one is selected), onto a changelist = unshelve there
        $shn = $(if ($e.Item.Tag.Type -eq 'shelf') { $e.Item } else { $e.Item.Parent })
        $only = $null
        if ($e.Item.Tag.Type -eq 'shelffile') {
            if (Is-Sel $e.Item) { $only = @(Sel-ShelfPaths ([string]$shn.Tag.Shelf.Id)) } else { $only = @($e.Item.Tag.Path) }
            if ($only.Count -ge @($shn.Tag.Shelf.Files).Count) { $only = $null }
        }
        $script:DragShelf = @{ Shelf = $shn.Tag.Shelf; Only = $only }
        try { [void]$tv.DoDragDrop('dvcl', [System.Windows.Forms.DragDropEffects]'Move, Link') } finally { $script:DragShelf = $null }
        return
    }
    if ($e.Item.Tag.Type -ne 'file') { return }
    # dragging a file outside the selection drags it alone (and selects it), like Explorer
    if (-not (Is-Sel $e.Item)) { Select-Click $e.Item ([System.Windows.Forms.Keys]::None) }
    $items = Target-Items-IfChecked
    Start-TreeDrag $tv $e.Item.Tag.Item.Path $items
})
$tv.Add_DragOver({
    param($s, $e)
    $pt = $tv.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    $n = $tv.GetNodeAt($pt)
    if ($n -and ($script:DragItems -or ($script:DragShelf -and $n.Tag.Type -eq 'cl'))) { $tv.SelectedNode = $n; $e.Effect = [System.Windows.Forms.DragDropEffects]::Move } else { $e.Effect = [System.Windows.Forms.DragDropEffects]::None }
})
$tv.Add_DragDrop({
    param($s, $e)
    $pt = $tv.PointToClient((New-Object System.Drawing.Point($e.X, $e.Y)))
    $n = $tv.GetNodeAt($pt)
    if ($n -and $script:DragShelf -and $n.Tag.Type -eq 'cl') { $d = $script:DragShelf; Do-Unshelve $d.Shelf ([string]$n.Tag.Name) $d.Only; return }
    if (-not $n -or -not $script:DragItems) { return }
    $to = $n.Tag.Name; if ($n.Tag.Type -ne 'cl') { $to = $n.Tag.Cl }
    Do-Move $to $script:DragItems
})

# Multi-select like Explorer: click = this file, Ctrl+click = add/remove, Shift+click = range
# (Ctrl+Shift = add range), arrows move it, Ctrl+A = all files, Esc = none.
# Clicking a changelist selects the changelist (= all its files for the commands).
$script:Anchor = $null
$tv.Add_NodeMouseClick({
    param($s, $e)
    $mods = [System.Windows.Forms.Control]::ModifierKeys
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        # right-click outside the selection: that item alone
        if (-not (Is-Sel $e.Node)) { $tv.SelectedNode = $e.Node; Select-Click $e.Node ([System.Windows.Forms.Keys]::None) }
        return
    }
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($tv.HitTest($e.Location).Location -eq [System.Windows.Forms.TreeViewHitTestLocations]::PlusMinus) { return }
    Select-Click $e.Node $mods
})
$tv.Add_AfterSelect({
    param($s, $e)
    if ($e.Action -ne [System.Windows.Forms.TreeViewAction]::ByKeyboard) { return }
    $mods = [System.Windows.Forms.Control]::ModifierKeys
    if ($mods -band [System.Windows.Forms.Keys]::Control) { $tv.Invalidate(); return }   # Ctrl+arrows: move without selecting
    Select-Click $e.Node ($mods -band [System.Windows.Forms.Keys]::Shift)
})
function Select-Click($node, $mods) {
    $shift = ($mods -band [System.Windows.Forms.Keys]::Shift); $ctrl = ($mods -band [System.Windows.Forms.Keys]::Control)
    $p = Node-Key $node
    if (-not $p) {
        if (-not $ctrl) { $script:Sel.Clear() }; $script:Anchor = $null; $tv.Invalidate(); return
    }
    if ($shift -and $script:Anchor -and $script:Anchor.TreeView) {
        $all = Sel-Nodes; $a = $all.IndexOf($script:Anchor); $b = $all.IndexOf($node)
        if (-not $ctrl) { $script:Sel.Clear() }
        if ($a -ge 0 -and $b -ge 0) { for ($i = [Math]::Min($a, $b); $i -le [Math]::Max($a, $b); $i++) { [void]$script:Sel.Add((Node-Key $all[$i])) } }
    } elseif ($ctrl) {
        if (-not $script:Sel.Remove($p)) { [void]$script:Sel.Add($p) }; $script:Anchor = $node
    } else { $script:Sel.Clear(); [void]$script:Sel.Add($p); $script:Anchor = $node }
    $tv.Invalidate()
}
# Click below the last row: nothing selected, like Explorer
function Tree-EmptyClick($pt) { if (-not $tv.GetNodeAt($pt)) { $script:Sel.Clear(); $script:Anchor = $null; $tv.SelectedNode = $null; $tv.Invalidate() } }
$tv.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Tree-EmptyClick $e.Location } })
function Check-AllFiles([bool]$on) { $script:Sel.Clear(); if ($on) { foreach ($n in (File-Nodes)) { [void]$script:Sel.Add($n.Tag.Item.Path) } }; $tv.Invalidate() }
# Draws the selection (selected files; a selected changelist or other row)
$tv.Add_DrawNode({
    param($s, $e)
    $n = $e.Node
    $on = (Is-Sel $n) -or ($n -eq $s.SelectedNode -and $n.Tag -and -not (Node-Key $n))
    $cur = ($n -eq $s.SelectedNode)
    if (-not $on -and -not $cur) { $e.DrawDefault = $true; return }
    if ($e.Bounds.Width -le 0) { return }
    $bg = $s.BackColor
    if ($on) { $bg = $(if ($s.Focused) { $script:Pal.Sel } elseif ($script:Dark) { $script:Pal.Hi } else { [System.Drawing.Color]::FromArgb(217, 217, 217) }) }
    $b = New-Object System.Drawing.SolidBrush($bg); $e.Graphics.FillRectangle($b, $e.Bounds); $b.Dispose()
    $fnt = $n.NodeFont; if (-not $fnt) { $fnt = $s.Font }
    $fc = $n.ForeColor; if ($fc.IsEmpty) { $fc = $s.ForeColor }
    if ($on -and $s.Focused) { $fc = [System.Drawing.Color]::White }
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $n.Text, $fnt, $e.Bounds, $fc, [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, NoPrefix, SingleLine')
    if ($cur -and $s.Focused -and -not $on) { [System.Windows.Forms.ControlPaint]::DrawFocusRectangle($e.Graphics, $e.Bounds) }
})
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
    if ($e.Node.Tag.Type -in 'shelf', 'shelffile') {
        $script:MenuShelf = $e.Node.Tag; if ($e.Node.Tag.Type -eq 'shelffile') { $script:MenuShelf = $e.Node.Parent.Tag }
        $script:MenuShelfPath = $(if ($e.Node.Tag.Type -eq 'shelffile') { $e.Node.Tag.Path } else { '' })
        $script:MenuShelfSel = @(Sel-ShelfPaths ([string]$script:MenuShelf.Shelf.Id))
        $nf = @($script:MenuShelf.Shelf.Files).Count
        $part = ($script:MenuShelfSel.Count -gt 0 -and $script:MenuShelfSel.Count -lt $nf)
        $script:MenuUnOnly = $(if ($part) { $script:MenuShelfSel } else { $null })
        $un = Add-MenuItem $menu ($(if ($part) { 'Unshelve ' + $script:MenuShelfSel.Count + ' selected file(s) into' } else { 'Unshelve' + $(if ($nf) { ' ' + $nf + ' file(s)' } else { '' }) + ' into' })) $null
        # the shelf's own changelist first, then default, then the others
        $targets = @($script:MenuShelf.Cl) + @('default') + @($script:CLs | ForEach-Object { $_.name })
        $seen = @{}
        foreach ($t in $targets) {
            if (-not $t -or $seen.ContainsKey($t.ToLowerInvariant())) { continue }; $seen[$t.ToLowerInvariant()] = 1
            $mi = Add-MenuItem $un (CL-MenuText $t) $null; $mi.Tag = $t
            $mi.Add_Click({ param($src, $ev) Do-Unshelve $script:MenuShelf.Shelf ([string]$src.Tag) $script:MenuUnOnly })
        }
        # these shelved files are also checked out in another changelist: move them to this shelf's one
        # (no file is touched). One item per changelist they are in. Scope: the selected / clicked
        # shelved files, else the whole shelf.
        $scope = @($script:MenuShelf.Shelf.Files | ForEach-Object { $_.Path })
        if ($script:MenuShelfSel.Count) { $scope = @($script:MenuShelfSel) } elseif ($script:MenuShelfPath) { $scope = @($script:MenuShelfPath) }
        $groups = [ordered]@{}
        foreach ($sp in $scope) {
            $pi = $script:PendingByPath[$sp]; if (-not $pi) { continue }
            $o = Owner-Of $sp; $on = $(if ($o) { $o.name } else { 'default' })
            if ($on -ieq $script:MenuShelf.Cl) { continue }
            if (-not $groups.Contains($on)) { $groups[$on] = New-Object System.Collections.ArrayList }
            [void]$groups[$on].Add($pi)
        }
        foreach ($gk in @($groups.Keys)) {
            $mi = Add-MenuItem $menu ("Move " + $groups[$gk].Count + " checked-out file(s) from " + (CL-MenuText $gk) + " to " + (CL-MenuText $script:MenuShelf.Cl)) $null
            $mi.Tag = @($groups[$gk].ToArray())
            $mi.Add_Click({ param($src, $ev) Do-Move $script:MenuShelf.Cl @($src.Tag) })
        }
        [void](Add-MenuItem $menu 'Delete shelf...' { Do-DeleteShelf $script:MenuShelf.Shelf })
        if ($script:MenuShelf.Shelf.Local) { [void](Add-MenuItem $menu 'Open shelf folder' { Open-InExplorer ([System.IO.Path]::Combine((Dvcl-File 'shelves'), $script:MenuShelf.Shelf.Id)) }) }
        if ($script:MenuShelfPath) {
            [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            [void](Add-MenuItem $menu 'Show in Local tree' { Navigate-Tree 'local' $script:MenuShelfPath })
            [void](Add-MenuItem $menu 'Show in Depot tree' { Navigate-Tree 'depot' $script:MenuShelfPath })
        }
        Theme-Strip $menu; $menu.Show($tv, $e.Location); return
    }
    $isCl = $e.Node.Tag.Type -eq 'cl'
    $clName = Selected-CL
    $items = Target-Items
    $mv = Add-MenuItem $menu ("Move " + $items.Count + " file(s) to") $null ($items.Count -gt 0)
    foreach ($nm in (@('default') + @($script:CLs | ForEach-Object { $_.name }))) {
        $target = $nm
        $mi = Add-MenuItem $mv (CL-MenuText $nm) $null ($nm -ne $clName -or (Target-Items-IfChecked).Count -gt 0)
        $mi.Tag = $target
        $mi.Add_Click({ param($src, $ev) Do-Move $src.Tag (Target-Items) })
    }
    [void]$mv.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $mv 'New changelist...' { [void](Do-NewCL (Target-Items)) })
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $menu ("Submit '" + $clName + "'...") { Do-Submit })
    [void](Add-MenuItem $menu ("Shelve '" + $clName + "'...") { Do-Shelve })
    [void](Add-MenuItem $menu ("Revert " + $items.Count + " file(s)...") { Do-Revert } ($items.Count -gt 0))
    [void](Add-MenuItem $menu ("Lock " + $items.Count + " file(s)") { Do-Lock @(Target-Items | ForEach-Object { $_.Path }) $true } ($items.Count -gt 0))
    [void](Add-MenuItem $menu ("Unlock " + $items.Count + " file(s)") { Do-Lock @(Target-Items | ForEach-Object { $_.Path }) $false } ($items.Count -gt 0))
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
        [void](Add-MenuItem $menu 'Show in Depot tree' { Navigate-Tree 'depot' (Selected-Rel) })
        [void](Add-MenuItem $menu 'History' { Do-History (Selected-Rel) })
        $mx = Add-MenuItem $menu 'Show in Explorer' { Do-ShowInExplorer }; $mx.ShortcutKeyDisplayString = 'Ctrl+Shift+S'
        [void](Add-MenuItem $menu 'Copy path' { [System.Windows.Forms.Clipboard]::SetText(($script:Root + '\' + ((Selected-Rel) -replace '/', '\'))) })
    }
    Theme-Strip $menu
    $menu.Show($tv, $e.Location)
})

# Keyboard
# Ctrl+Shift+S: show the selected item in Explorer, in the tree used last (Local, Depot or changelists)
$script:LastTree = $tv
foreach ($t in @($tv, $tvLocal, $tvDepot)) { $t.Add_Enter({ param($s, $e) $script:LastTree = $s }) }
function Do-OpenSelected {
    $t = $script:LastTree
    if ($t -eq $tv) { Do-ShowInExplorer; return }
    $n = $t.SelectedNode
    if (-not $n -or -not $n.Tag) { return }
    if ($t -eq $tvLocal) { Open-InExplorer $n.Tag.Path } else { Open-PathInExplorer 'depot' $n.Tag.Path }
}

$form.Add_KeyDown({
    param($s, $e)
    if ($script:BusyDepth -gt 0 -or $script:OpDepth -gt 0) { $e.Handled = $true; $e.SuppressKeyPress = $true; return }
    if ($e.Control -and $e.Shift -and $e.KeyCode -eq 'S') { Do-OpenSelected; $e.Handled = $true; $e.SuppressKeyPress = $true; return }
    if ($e.KeyCode -eq 'F5') { Refresh-All; $e.Handled = $true }
    elseif ($e.Control -and $e.KeyCode -eq 'N') { [void](Do-NewCL (Target-Items-IfChecked)); $e.Handled = $true }
    elseif ($e.Control -and $e.KeyCode -eq 'Return') { Do-Submit; $e.Handled = $true }
})

$form.Add_Shown({
    # saved panel layout (self-check and screenshot: default)
    $lay = $null; if (-not $SelfCheck -and -not $Shot) { $lay = $settings.layout }
    try { Apply-Layout $lay } catch { Write-Log ('layout: ' + $_.Exception.Message); Apply-Layout $null }
    # Repo: argument / current folder, else last used, else ask
    $root = $null
    if ($StartDir) { $root = Find-DvRoot $StartDir }
    if (-not $root -and $settings.lastRepo) { $root = Find-DvRoot $settings.lastRepo }
    $script:SyncMode = [bool]$SelfCheck -or [bool]$Shot
    if ($Shot -or $settings.ui -ne 'light') { Apply-Theme $true $false }   # dark unless chosen light (screenshot: dark)
    if (-not $SelfCheck -and -not $Shot) { $watchTimer.Start() }
    if ($root) {
        Set-DvRoot $root; Save-Settings
        Write-Log ("==== dvcl window " + (Get-LocalVersion))
        try { Write-Timing 'powershell-start-to-script' ($script:ScriptStart - (Get-Process -Id $PID).StartTime).TotalMilliseconds } catch {}
        Write-Timing 'script-start-to-window' $script:Clock.Elapsed.TotalMilliseconds
        Refresh-All
    } else { Do-ChangeRepo }
    if ($SelfCheck) { Run-GuiSelfCheck; $form.Close() }
    if ($Shot) { Take-Shot $Shot; $form.Close() }
})

# README screenshot of the window as it is (demo workspace from tests\screenshot.ps1)
function Take-Shot([string]$png) {
    $form.WindowState = 'Normal'; $form.Width = 1280; $form.Height = 700
    [System.Windows.Forms.Application]::DoEvents()
    $split.SplitterDistance = [int]($split.Height * 0.6)
    $main.SplitterDistance = [int]($main.Width * 0.5)
    $trees.SplitterDistance = [int]($trees.Width * 0.5)
    # History panel with demo commits (the demo workspace has no Diversion): two not got yet
    $hp = 'MyGame/Content/Maps/Town/Town.umap'
    $mk = { param($n, $a, $d, $t) [pscustomobject]@{ Id = ('dv.commit.' + $n); Num = $n; Author = $a; Date = $d; Desc = $t } }
    $vHist.Commits = @((& $mk 14 'sam' '2026-11-12T09:10:00Z' 'Town: market square props'), (& $mk 13 'mapmodelers' '2026-11-11T17:42:00Z' 'Town: road decals and curbs'),
        (& $mk 12 'mapmodelers' '2026-11-10T16:20:00Z' 'Town blockout: roads and plots'), (& $mk 9 'sam' '2026-11-07T11:05:00Z' 'Town map, first pass'))
    $script:CommitFiles['dv.commit.13'] = [pscustomobject]@{ Ok = $true; Raw = @(); Files = @(
            [pscustomobject]@{ Kind = 'M'; Path = $hp }, [pscustomobject]@{ Kind = 'A'; Path = 'MyGame/Content/Maps/Town/Decals/DI_Curb_01.uasset' },
            [pscustomobject]@{ Kind = 'A'; Path = 'MyGame/Content/Maps/Town/Decals/DI_Road_Crack_02.uasset' }, [pscustomobject]@{ Kind = 'D'; Path = 'MyGame/Content/Maps/Town/Decals/DI_Old_Paint.uasset' }) }
    $vHist.Follow.Checked = $false; $vHist.Path.Text = $hp; $vHist.Loaded = $script:Root + '|' + $hp + '|' + $vHist.Limit
    Activate-Pad 'history'; Fill-Commits $vHist
    $vHist.List.Items[1].Selected = $true
    # shallowest modified file: shown without scrolling the trees sideways
    $first = @($script:Pending | Where-Object { (Kind-Letter $_.Kind) -eq 'M' } | Sort-Object { ($_.Path -split '/').Count }, { $_.Path.Length }) | Select-Object -First 1
    if ($first) { Navigate-Tree 'local' $first.Path $true; Navigate-Tree 'depot' $first.Path $true }
    $tv.Focus(); if ($first) { foreach ($cn in $tv.Nodes) { foreach ($fn in $cn.Nodes) { if ($fn.Tag.Type -eq 'file' -and $fn.Tag.Item.Path -eq $first.Path) { $tv.SelectedNode = $fn } } } }
    $logBox.Clear()
    for ($i = 0; $i -lt 5; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

# ---------------------------------------------------------------- self-check (dvcl-gui -SelfCheck): drives the real window, writes a report, closes.
# Report: <tool>\tests\gui-selfcheck.txt (gitignored). Changes nothing: no submit, shelve, revert, sync, update or browser.
function Selfcheck-AsyncDone($res) { $script:scAsync = $res }

function Run-GuiSelfCheck {
    $r = New-Object System.Collections.ArrayList
    function C([string]$n, [bool]$c, [string]$d = '') { if ($c) { $script:scOk++ ; [void]$r.Add('PASS  ' + $n) } else { $script:scKo++; [void]$r.Add('FAIL  ' + $n + '   ' + $d) } }
    $script:scOk = 0; $script:scKo = 0
    try {
        C 'repo opened' ([bool]$script:Root)
        C 'icon loaded' ($null -ne $form.Icon)
        C 'version file' ((Get-LocalVersion) -ne '0.0.0') (Get-LocalVersion)
        C 'layout: default zones: Local | Depot | Changelists, Log below' ($trees.Panel1.Contains($tvLocal) -and $trees.Panel2.Contains($tvDepot) -and $main.Panel2.Contains($tv) -and $split.Panel2.Contains($logBox) -and $trees.Panel1.Width -gt 80 -and $trees.Panel2.Width -gt 80 -and $main.Panel2.Width -gt 100) ("" + $trees.Panel1.Width + ' / ' + $trees.Panel2.Width + ' / ' + $main.Panel2.Width)
        $n = 0; foreach ($z in @($script:Zones.Values)) { $n += $z.Pads.Count }
        C 'dock: 6 panels, each in exactly one zone' ($script:Pads.Count -eq 6 -and $n -eq 6 -and @($script:Pads.Values | Where-Object { -not $_.Zone }).Count -eq 0) ([string]$n)
        Dock-Pad 'pending' 'bottom'; Dock-Pad 'submitted' 'bottom'; [System.Windows.Forms.Application]::DoEvents()
        $f1 = $split.Panel2.Contains($tv) -and $main.Panel2Collapsed
        Apply-Layout $null
        C 'dock: moved panels fold their empty zone; reset puts them back' ($f1 -and $main.Panel2.Contains($tv) -and -not $main.Panel2Collapsed -and (Zone-Of 'submitted').Name -eq 'right')
        $zf = Float-Pad 'history' (New-Object System.Drawing.Rectangle(($form.Left + 40), ($form.Top + 40), 400, 300)); [System.Windows.Forms.Application]::DoEvents()
        $f2 = ($zf.Form.Visible -and $vHist.Root.FindForm() -eq $zf.Form -and $zf.Form.Owner -eq $form)
        $zf.Form.Close(); [System.Windows.Forms.Application]::DoEvents()
        C 'dock: own window; closing it puts the panel back' ($f2 -and (Zone-Of 'history').Name -eq 'bottom' -and $script:Zones.Count -eq 4) ([string]$script:Zones.Count)
        Dock-Pad 'log' 'left'; $zf = Float-Pad 'depot' (New-Object System.Drawing.Rectangle(($form.Left + 60), ($form.Top + 60), 400, 300)); Dock-Pad 'history' $zf.Name
        $saved = (Get-Layout) | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        Apply-Layout $null; Apply-Layout $saved; [System.Windows.Forms.Application]::DoEvents()
        $zd = Zone-Of 'depot'
        C 'dock: layout saved and restored (zones, own window with 2 tabs)' ((Zone-Of 'log').Name -eq 'left' -and $zd.Form -and $zd.Pads.Count -eq 2 -and (Zone-Of 'history') -eq $zd) ("" + (Zone-Of 'log').Name + ' / ' + $zd.Name)
        Apply-Layout $null
        C 'dock: tabs styled, menus ready' ($script:Zones.right.Strip.Controls.Count -eq 2 -and $script:TabMenu -and $script:ViewMenu)
        # Submitted / History: real dv answers (INFO only: depends on Diversion being reachable)
        Load-Commits 'submitted' $true
        [void]$r.Add('INFO  submitted: ' + $vSub.Info.Text)
        [void]$r.Add('INFO  submitted: ' + $vSub.Commits.Count + ' parsed; first: ' + (@($vSub.Commits | Select-Object -First 1 | ForEach-Object { $_.Id + ' | ' + $_.Author + ' | ' + $_.Date + ' | ' + ($_.Desc -replace "`n", ' / ') }) -join ''))
        foreach ($l in @($vSub.Raw | Select-Object -First 12)) { [void]$r.Add('INFO  dv log | ' + $l) }
        if ($vSub.Commits.Count) {
            $cid = $vSub.Commits[0].Id; Load-Files 'submitted' $cid; $cf = $script:CommitFiles[$cid]
            if ($cf) { [void]$r.Add('INFO  commit files: ' + @($cf.Files).Count + ' parsed; first: ' + (@($cf.Files | Select-Object -First 2 | ForEach-Object { $_.Kind + ' ' + $_.Path }) -join ' ; ')); foreach ($l in @($cf.Raw | Select-Object -First 10)) { [void]$r.Add('INFO  dv show | ' + $l) } }
            else { [void]$r.Add('INFO  commit files: dv show failed') }
            C 'submitted: commits listed with numbers' ($vSub.List.Items.Count -gt 0 -and $vSub.List.Items[0].Text -match '^\d+$') $vSub.List.Items[0].Text
            C 'submitted: dates as yyyy-MM-dd HH:mm (local)' ($vSub.List.Items[0].SubItems[1].Text -match '^\d{4}-\d\d-\d\d \d\d:\d\d$') $vSub.List.Items[0].SubItems[1].Text
            C 'submitted: commit files parsed' ($cf -and @($cf.Files).Count -gt 0)
        }
        $vHist.Path.Text = ''; Load-Commits 'history' $true
        C 'history: asks for a path when none' ($vHist.Info.Text -like 'Select a file*') $vHist.Info.Text
        C 'icons: image list set on the three trees' ((@($tv, $tvLocal, $tvDepot) | Where-Object { $_.ImageList -and $_.ImageList.Images.ContainsKey('file-A') }).Count -eq 3 -and $icons.Images.Count -ge 18) ([string]$icons.Images.Count)
        C 'numbers: changelist rows start with #id' (@($tv.Nodes | Where-Object { $_.Tag.Name -ne 'default' -and $_.Text -notmatch '^#\d+  ' }).Count -eq 0)
        C 'find: Local and Depot accept drops' ($tvLocal.AllowDrop -and $tvDepot.AllowDrop)
        if (Find-UeEngine) { $uv = Invoke-Ue "import unreal`nprint(unreal.DvclLinkLibrary.version() if hasattr(unreal, 'DvclLinkLibrary') else 'DVCL nolink')"; [void]$r.Add('INFO  unreal link: ' + $uv.State + ' ' + (($uv.Lines | Select-Object -First 3) -join ' / ')) } else { [void]$r.Add('INFO  unreal link: no editor running') }
        C 'restart: running version matches disk, restart path known' ($script:RunVersion -eq (Get-LocalVersion) -and $script:SelfPath -and (Test-Path -LiteralPath $script:SelfPath))
        C 'theme: changelist tree lines follow theme (none in dark)' ($tv.ShowLines -eq (-not $script:Dark))
        C 'theme: unfocused selections drawn dark (trees, commit lists)' (($tvLocal.DrawMode -eq 'OwnerDrawText') -eq $script:Dark -and $tv.DrawMode -eq 'OwnerDrawText' -and $vSub.List.OwnerDraw -and $vHist.Files.OwnerDraw)
        C 'icons: changelist rows have the changelist icon' (@($tv.Nodes | Where-Object { $_.ImageKey -notin 'cl', 'cldef' }).Count -eq 0)
        C 'layout: path bars present' ($tabLocal.Contains($barLocal.Box) -and $tabDepot.Contains($barDepot.Box))
        C 'toolbar: Get latest + Tools + Locks' ((@($tool.Items | Where-Object { $_.Text -like 'Get latest*' -or $_.Text -in 'Tools', 'Locks' })).Count -eq 3)
        C 'state bar: label and button match the state' ((($script:Offline -and $modeLbl.Text -eq 'OFFLINE' -and $btnMode.Text -eq 'Go online') -or (-not $script:Offline -and $modeLbl.Text -eq 'ONLINE' -and $btnMode.Text -eq 'Go offline')) -or $script:Mode -eq 'down') ($modeLbl.Text + ' / ' + $btnMode.Text)
        [void]$r.Add('INFO  state bar: ' + $modeLbl.Text + ' | ' + $modeDesc.Text + ' | ' + $branchLbl.Text)
        if (Test-OfflineFlag) { C 'offline launch: Diversion not asked' (@($script:LastStatusArgs) -join ' ' -like '*offline*') (@($script:LastStatusArgs) -join ' ') }
        else { C 'status read without waiting for sync (--nowait)' (@($script:LastStatusArgs) -contains '--nowait') (@($script:LastStatusArgs) -join ' ') }
        C 'log panel: no dv status dump' (-not $logBox.Text.Contains('dv | In repo'))
        [void]$r.Add('INFO  workspace ' + $script:WsCommit + '   branch head ' + $script:Head + '   button: ' + $btnGet.Text)
        if ($script:Offline) { [void]$r.Add('SKIP  branch head (offline)') } else { C 'branch head read from dv show' ([bool]$script:Head) 'see RUN dv show in dvcl.log' }
        try { $lk = Get-Locks; C 'locks list readable' $true; [void]$r.Add('INFO  locks: ' + @($lk).Count) } catch { C 'locks list readable' $false $_.Exception.Message }
        # background runner (normal launches): window keeps pumping messages while dv runs
        $wasDark = $script:Dark
        Apply-Theme (-not $wasDark); $c1 = $tvLocal.BackColor; $m1 = $colKind['M']
        Apply-Theme $wasDark; $c2 = $tvLocal.BackColor
        C 'theme: toggle recolors trees and file states, then restores' ($c1 -ne $c2 -and $m1 -ne $colKind['M'] -and $btnTheme.Text -eq $(if ($wasDark) { 'Light' } else { 'Dark' })) ("" + $c1 + ' / ' + $c2)
        C 'tray: icon + Open / Exit menu ready (off in self-check)' ($notify.Icon -and $trayMenu.Items.Count -eq 3 -and -not $script:TrayOn)
        C 'window unlocked when idle' ($script:BusyDepth -eq 0 -and $tool.Enabled -and $split.Enabled -and -not $busyBar.Visible) ("depth " + $script:BusyDepth)
        $script:SyncMode = $false; $script:scAsync = $null; $ticks = 0
        $swA = [Diagnostics.Stopwatch]::StartNew()
        Start-DvAsync (Status-Args $false) 'Selfcheck-AsyncDone' $true $true 'Selfcheck: reading status...'
        C 'window locked while loading (greyed, progress shown)' (-not $tool.Enabled -and -not $split.Enabled -and $busyBar.Visible -and $busyLbl.Text -like 'Selfcheck*')
        while ($null -eq $script:scAsync -and $swA.Elapsed.TotalSeconds -lt 90) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30; $ticks++ }
        $script:SyncMode = $true
        C 'window unlocked again after loading' ($script:BusyDepth -eq 0 -and $tool.Enabled -and $split.Enabled)
        C 'background dv status (window keeps repainting meanwhile)' ($null -ne $script:scAsync -and $script:scAsync.Code -eq 0 -and $ticks -gt 2) ("ticks " + $ticks)
        [void]$r.Add('INFO  background dv status: ' + [int]$swA.Elapsed.TotalMilliseconds + 'ms, ' + $ticks + ' UI pumps meanwhile')
        [void]$r.Add('INFO  sync paused: ' + $script:Paused + '   pending: ' + $script:Pending.Count + '   changelists: ' + $script:CLs.Count + '   entries: ' + (Total-Entries))
        C 'state bar shows OFFLINE only when offline' (($modeLbl.Text -eq 'OFFLINE') -eq [bool]$script:Offline -or $script:Mode -eq 'down')
        [void]$r.Add('INFO  offline: ' + [bool]$script:Offline + '   offline flag: ' + (Test-OfflineFlag) + '   baseline fresh: ' + [bool]$script:BaselineFresh)
        $clNodes = @($tv.Nodes | Where-Object { $_.Tag.Type -eq 'cl' })
        C 'pending tree: default + changelists' ($clNodes.Count -eq (1 + $script:CLs.Count)) ([string]$clNodes.Count)
        $shNodes = 0; foreach ($cn in $tv.Nodes) { foreach ($x in $cn.Nodes) { if ($x.Tag.Type -eq 'shelf') { $shNodes++ } } }
        C 'shelves shown under their changelists' ($shNodes -eq @($script:Shelves).Count) ("" + $shNodes + ' / ' + @($script:Shelves).Count)
        $dvs = @($script:Shelves | Where-Object { -not $_.Local })
        if ($dvs.Count) {
            C 'shelves: Diversion shelves list their files (read offline, kept)' (@($dvs | Where-Object { $_.Count -lt 1 }).Count -eq 0) ((@($dvs | ForEach-Object { $_.Name + ':' + $_.Count }) -join ', '))
            $shFileNodes = 0; foreach ($cn in $tv.Nodes) { foreach ($x in $cn.Nodes) { if ($x.Tag.Type -eq 'shelf' -and -not $x.Tag.Shelf.Local) { $shFileNodes += $x.Nodes.Count } } }
            C 'shelves: their files are in the tree' ($shFileNodes -eq (($dvs | Measure-Object -Property Count -Sum).Sum)) ([string]$shFileNodes)
        } else { [void]$r.Add('SKIP  Diversion shelf files (no Diversion shelf)') }
        [void]$r.Add('INFO  shelves: ' + (@($script:Shelves | ForEach-Object { $(if ($_.Local) { $_.Id } else { $_.Name }) + ' -> ' + (Shelf-ClName $_) }) -join ', '))
        $files = File-Nodes
        C 'pending tree: all pending files shown' ($files.Count -eq $script:Pending.Count) ("" + $files.Count + ' / ' + $script:Pending.Count)
        $staleShown = 0; foreach ($cn in $tv.Nodes) { foreach ($fn in $cn.Nodes) { if ($fn.Tag.Type -eq 'stale') { $staleShown++ } } }
        $staleReal = 0; foreach ($c in $script:CLs) { $staleReal += (Stale-Of $script:Pending $c).Count }
        C 'not-pending entries shown, not dropped' ($staleShown -eq $staleReal) ("" + $staleShown + ' / ' + $staleReal)
        foreach ($c in $script:CLs) { [void]$r.Add('INFO  changelist ' + $c.name + ': ' + (Get-CLItems $script:Pending $c.name).Count + ' pending, ' + (Stale-Of $script:Pending $c).Count + ' not pending') }
        # offline view without touching Diversion: dvcl's offline flag only, then back
        if (-not $script:Offline) {
            $onl = @($script:Pending | ForEach-Object { $_.Path.ToLowerInvariant() } | Sort-Object)
            $te = Total-Entries
            Set-OfflineFlag $true
            try {
                Refresh-All
                C 'offline view: state bar OFFLINE, folder scanned' ($modeLbl.Text -eq 'OFFLINE' -and $script:Offline)
                $offl = @($script:Pending | ForEach-Object { $_.Path.ToLowerInvariant() } | Sort-Object)
                $extra = @($offl | Where-Object { $onl -notcontains $_ }); $miss = @($onl | Where-Object { $offl -notcontains $_ })
                C 'offline view: same pending files as Diversion' ($extra.Count -eq 0 -and $miss.Count -eq 0) ("extra " + $extra.Count + ", missing " + $miss.Count)
                foreach ($x in ($extra | Select-Object -First 5)) { [void]$r.Add('INFO  offline extra: ' + $x) }
                foreach ($x in ($miss | Select-Object -First 5)) { [void]$r.Add('INFO  offline missing: ' + $x) }
                C 'offline view: changelists unchanged' ((Total-Entries) -eq $te)
            } finally { Set-OfflineFlag $false }
            Refresh-All
            C 'back online: state bar ONLINE, test baseline removed' ($modeLbl.Text -eq 'ONLINE' -and -not (Test-Path -LiteralPath (Dvcl-File 'baseline.tsv')))
        } else { [void]$r.Add('SKIP  offline view test (already offline)') }
        $before = Total-Entries
        Refresh-All
        C 'refresh drops no changelist entry' ((Total-Entries) -eq $before) ("" + $before + ' -> ' + (Total-Entries))
        $files = File-Nodes
        if ($files.Count -ge 3) {
            Check-AllFiles $false
            C 'no tick boxes: Explorer-style selection' (-not $tv.CheckBoxes)
            Select-Click $files[0] ([System.Windows.Forms.Keys]::None)
            Select-Click $files[2] ([System.Windows.Forms.Keys]::Shift)
            C 'shift-click selects a range of 3 files' ((@($files | Where-Object { Is-Sel $_ })).Count -eq 3)
            Select-Click $files[1] ([System.Windows.Forms.Keys]::Control)
            C 'ctrl-click removes one' ((@($files | Where-Object { Is-Sel $_ })).Count -eq 2)
            C 'targets = selected files' ((Target-Items).Count -eq 2)
            Select-Click $files[1] ([System.Windows.Forms.Keys]::None)
            C 'plain click = that file alone' ((@($files | Where-Object { Is-Sel $_ })).Count -eq 1 -and (Is-Sel $files[1]))
            Build-Tree; $fl = File-Nodes; C 'selection kept across a rebuild' ((@($fl | Where-Object { Is-Sel $_ })).Count -eq 1)
            $tv.Focus(); $pt = New-Object System.Drawing.Point(5, ($tv.ClientSize.Height - 3))
            if (-not $tv.GetNodeAt($pt)) { Tree-EmptyClick $pt; C 'click on empty space clears the selection' ($script:Sel.Count -eq 0 -and -not $tv.SelectedNode) } else { [void]$r.Add('SKIP  empty-space test (tree full)') }
            Select-Click $tv.Nodes[0] ([System.Windows.Forms.Keys]::None); C 'clicking a changelist clears file selection' ($script:Sel.Count -eq 0)
            $shn = @($tv.Nodes | ForEach-Object { $_.Nodes } | Where-Object { $_.Tag.Type -eq 'shelf' -and $_.Nodes.Count -ge 2 } | Select-Object -First 1)
            if ($shn.Count) {
                $shn[0].Expand(); Select-Click $shn[0].Nodes[0] ([System.Windows.Forms.Keys]::None); Select-Click $shn[0].Nodes[1] ([System.Windows.Forms.Keys]::Control)
                C 'shelved files: multi-select (ctrl-click 2)' ((Is-Sel $shn[0].Nodes[0]) -and (Is-Sel $shn[0].Nodes[1]) -and @(Sel-ShelfPaths ([string]$shn[0].Tag.Shelf.Id)).Count -eq 2)
            } else { [void]$r.Add('SKIP  shelved-file test (no shelf with 2+ files)') }
            Check-AllFiles $true; C 'select all' ((@($files | Where-Object { Is-Sel $_ })).Count -eq $files.Count)
            Check-AllFiles $false; C 'clear' ($script:Sel.Count -eq 0)
        } else { [void]$r.Add('SKIP  multi-select (needs 3+ pending files)') }

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
            C 'local tree: pending file has its state icon' ($tvLocal.SelectedNode -and $tvLocal.SelectedNode.ImageKey -like 'file-*') ([string]$tvLocal.SelectedNode.ImageKey)
            $script:LocalBuilt = $false; Show-Tab
            C 'local tree keeps its path after rebuild' ($tvLocal.SelectedNode -and $tvLocal.SelectedNode.Tag.Path -ieq $full)
        } else { [void]$r.Add('SKIP  path bar navigation (no pending file)') }

        C 'depot: dv ls parsed' ($script:DepotPaths.Length -gt 0) ([string]$script:DepotPaths.Length)
        C 'depot tree filled' ($tvDepot.Nodes.Count -gt 0)
        C 'depot: no raw dv lines' (-not (@($tvDepot.Nodes | Where-Object { $_.Text -match '^\((F|D)\)' })).Count)
        [void]$r.Add('INFO  depot top folders not on this PC: ' + (@($tvDepot.Nodes | Where-Object { $_.ImageKey -eq 'folderoff' })).Count)
        $dd = @($tvDepot.Nodes | Where-Object { $_.Tag.Type -eq 'ddir' }) | Select-Object -First 1
        if ($dd) { $dd.Expand(); C 'depot: folder expands' (-not (Is-Unloaded $dd) -and $dd.Nodes.Count -gt 0) }
        if ($pf -and (Kind-Letter $pf.Kind) -eq 'M') {
            Navigate-Tree 'depot' $pf.Path $true
            C 'path bar: go to a pending file (depot)' ($tvDepot.SelectedNode -and $tvDepot.SelectedNode.Tag.Path -ieq $pf.Path) ([string]$barDepot.Box.Text)
            C 'depot path bar shows the repo path' ($barDepot.Box.Text -ieq $pf.Path) $barDepot.Box.Text
        }
        C 'depot list kept for the same commit (no reload on refresh)' ($script:DepotCommit -eq $script:WsCommit)
        C 'Ctrl+Shift+S target follows the last tree used' ($null -ne $script:LastTree)

        # action card: covers and locks the window, lists the steps, tree drawn once at the end
        $bt0 = $script:BuildCount
        Begin-Op 'Test action'
        Begin-Busy 'Step one'; End-Busy; Begin-Busy 'Step two'; End-Busy
        Build-Tree; Build-Tree
        $cov = $opPanel.Visible -and $opPanel.Bounds.Contains($tool.Bounds) -and $opPanel.Bounds.Contains($split.Bounds) -and $script:BuildCount -eq $bt0
        $stp = $opDone.Text
        Begin-Op 'nested'; End-Op; $still = $opPanel.Visible -and $script:OpDepth -eq 1
        End-Op
        C 'action card: window covered and locked, steps listed, nothing redrawn during the action' ($cov -and $stp -like '*Step one*' -and $still) ($stp)
        C 'action card: gone after, tree drawn once' (-not $opPanel.Visible -and $script:OpDepth -eq 0 -and $script:BuildCount -eq ($bt0 + 1)) ([string]($script:BuildCount - $bt0))

        $pl = @(Pending-FromLast @([pscustomobject]@{ Kind = 'A'; Path = 'dvcl-no-such/x.uasset' }, [pscustomobject]@{ Kind = 'D'; Path = 'dvcl-no-such/y.uasset' }))
        C 'after pause: pending taken from Diversion list (new gone = dropped, deleted kept)' ($pl.Count -eq 1 -and $pl[0].Kind -eq 'Deleted' -and $pl[0].Path -eq 'dvcl-no-such/y.uasset') ([string]$pl.Count)
        C 'unreal: file stamp of a missing file' ((File-Stamp 'dvcl-no-such/z.uasset') -eq 'none')

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
# ---------------------------------------------------------------- tray + single window
# Closing the window (X) hides it to the notification area; tray icon: click = open, right-click > Exit.
# One window per workspace: launching dvcl again brings the running one back.
$script:TrayOn = $false; $script:ReallyExit = $false; $script:TrayTipShown = $false
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $(if ($form.Icon) { $form.Icon } else { [System.Drawing.SystemIcons]::Application })
$notify.Text = 'dvcl'
$notify.ContextMenuStrip = $trayMenu
function Show-FromTray {
    # dvcl was updated while this window was running: restart on the new version
    if ($script:TrayOn -and (Get-LocalVersion) -ne $script:RunVersion) { Restart-Dvcl; return }
    $form.Show(); Show-Floats
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
    $form.Activate(); $form.BringToFront()
}
function Exit-Dvcl { $script:ReallyExit = $true; $form.Close() }
$script:SelfPath = $PSCommandPath
function Restart-Dvcl { Say ('dvcl ' + (Get-LocalVersion) + ' on disk: restarting') 'Gray'; $script:Restart = $true; Exit-Dvcl }
[void](Add-MenuItem $trayMenu 'Open dvcl' { Show-FromTray })
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void](Add-MenuItem $trayMenu 'Exit' { Exit-Dvcl })
$trayMenu.Add_Opening({ Theme-Strip $trayMenu })
$notify.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-FromTray } })

function Claim-Instance([string]$root) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $key = 'dvcl-' + (-join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant().TrimEnd('\'))) | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }))
    $created = $false
    $script:InstMutex = [System.Threading.Mutex]::new($true, ('Local\' + $key + '-m'), [ref]$created)
    if (-not $created) {
        try { $ev = [System.Threading.EventWaitHandle]::OpenExisting('Local\' + $key + '-e'); [void]$ev.Set() } catch {}
        return $false
    }
    $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, ('Local\' + $key + '-e'))
    return $true
}
$instTimer = New-Object System.Windows.Forms.Timer
$instTimer.Interval = 300
$instTimer.Add_Tick({ if ($script:ShowEvent -and $script:ShowEvent.WaitOne(0)) { Show-FromTray } })

$form.Add_FormClosing({
    param($s, $e)
    if ($script:TrayOn -and -not $script:ReallyExit -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Save-Layout; Hide-Floats
        $form.Hide()
        if (-not $script:TrayTipShown) { $script:TrayTipShown = $true; $notify.ShowBalloonTip(2500, 'dvcl', 'Still running here. Right-click > Exit to quit.', [System.Windows.Forms.ToolTipIcon]::Info) }
        return
    }
    Save-Settings
    $jobTimer.Stop(); $pollTimer.Stop(); $watchTimer.Stop(); $instTimer.Stop()
    foreach ($j in @($script:Jobs)) { try { $j.PS.Stop(); $j.PS.Dispose() } catch {} }
    $notify.Visible = $false; $notify.Dispose()
    if ($script:InstMutex) { try { $script:InstMutex.ReleaseMutex() } catch {}; $script:InstMutex.Dispose(); $script:InstMutex = $null }
    if ($script:Restart) {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + $script:SelfPath + '"'))
        if ($script:Root) { $a += ('"' + $script:Root.TrimEnd('\') + '"') }
        Start-Process powershell -ArgumentList $a -WindowStyle Hidden
    }
})

# Normal launch: one window per workspace, tray icon on
if (-not $SelfCheck -and -not $Shot) {
    $r0 = $null
    if ($StartDir) { $r0 = Find-DvRoot $StartDir }
    if (-not $r0 -and $settings.lastRepo) { $r0 = Find-DvRoot $settings.lastRepo }
    if ($r0 -and -not (Claim-Instance $r0)) { exit }
    $notify.Text = ('dvcl - ' + $(if ($r0) { Split-Path -Leaf $r0 } else { 'no repo' }))
    if ($notify.Text.Length -gt 63) { $notify.Text = $notify.Text.Substring(0, 63) }
    $notify.Visible = $true; $script:TrayOn = $true
    $instTimer.Start()
}
[System.Windows.Forms.Application]::Run($form)
