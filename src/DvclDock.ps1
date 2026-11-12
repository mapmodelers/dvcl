# DvclDock.ps1 - movable panels for the dvcl window (dot-sourced by dvcl-gui.ps1).
# A panel ("pad": Local, Depot, Changelists, Submitted, History, Log) is a tab in a zone.
# Zones: left / center / right / bottom of the main window, plus one per floating window.
# Drag a tab: onto a zone = joins its tabs; to a window edge = that side; outside the window =
# its own window. Right-click a tab: Move to / New window / Reset layout. Empty zones fold away.
# The layout (zones, tabs, floating windows, splitter positions) is saved in settings.json.

$script:Pads = [ordered]@{}
$script:Zones = [ordered]@{}
$script:FloatN = 0
$script:DockDrag = $null
$script:LayoutReady = $false
$script:DefaultLayout = [ordered]@{ left = @('local'); center = @('depot'); right = @('pending', 'submitted'); bottom = @('log', 'history') }
$script:DefaultRatios = @{ split = 0.74; main = 0.56; trees = 0.5 }

function New-Zone([string]$name) {
    $root = New-Object System.Windows.Forms.Panel; $root.Dock = 'Fill'
    $strip = New-Object System.Windows.Forms.FlowLayoutPanel
    $strip.Dock = 'Top'; $strip.Height = 24; $strip.WrapContents = $false; $strip.Padding = New-Object System.Windows.Forms.Padding(0)
    $strip.Margin = New-Object System.Windows.Forms.Padding(0)
    $body = New-Object System.Windows.Forms.Panel; $body.Dock = 'Fill'
    $root.Controls.Add($body); $root.Controls.Add($strip)
    $z = [pscustomobject]@{ Name = $name; Root = $root; Strip = $strip; Body = $body; Pads = (New-Object System.Collections.ArrayList); Active = ''; Form = $null; Closing = $false; Bounds = $null }
    $script:Zones[$name] = $z
    return $z
}

# $panel: the pad's content (a Panel filled by the window code). $home: zone it returns to.
function Register-Pad([string]$id, [string]$title, $panel, [string]$homeZone) {
    $panel.Dock = 'Fill'
    $script:Pads[$id] = [pscustomobject]@{ Id = $id; Title = $title; Panel = $panel; Zone = ''; Home = $homeZone }
}

function Zone-Of([string]$padId) { $p = $script:Pads[$padId]; if ($p -and $p.Zone) { return $script:Zones[$p.Zone] }; return $null }

function Undock-Pad([string]$id) {
    $p = $script:Pads[$id]; if (-not $p -or -not $p.Zone) { return }
    $z = $script:Zones[$p.Zone]; $p.Zone = ''
    if (-not $z) { return }
    $z.Pads.Remove($id)
    if ($z.Body.Controls.Contains($p.Panel)) { $z.Body.Controls.Remove($p.Panel) }
    if ($z.Active -eq $id) { $z.Active = $(if ($z.Pads.Count) { [string]$z.Pads[0] } else { '' }) }
    Render-Zone $z
    if ($z.Form -and $z.Pads.Count -eq 0 -and -not $z.Closing) { $z.Closing = $true; $z.Form.Close() }
}

function Dock-Pad([string]$id, [string]$zoneName, [int]$index = -1, [bool]$activate = $true) {
    $p = $script:Pads[$id]; $z = $script:Zones[$zoneName]
    if (-not $p -or -not $z) { return }
    if ($p.Zone -eq $zoneName) { if ($activate) { Activate-Pad $id }; return }
    Undock-Pad $id
    if ($index -lt 0 -or $index -gt $z.Pads.Count) { $index = $z.Pads.Count }
    $z.Pads.Insert($index, $id)
    $p.Zone = $zoneName
    $z.Body.Controls.Add($p.Panel)
    if ($activate -or -not $z.Active) { $z.Active = $id }
    Render-Zone $z
    Update-Collapse
}

# Bring a pad to front (restyles the tabs only: the clicked label must stay alive for a drag)
function Activate-Pad([string]$id) {
    $z = Zone-Of $id; if (-not $z) { return }
    if ($z.Active -ne $id) { $z.Active = $id; Show-Active $z; $script:LayoutDirty = $true }
    if ($z.Form -and -not $z.Form.Visible) { $z.Form.Show() }
}
function Show-Active($z) {
    foreach ($pid2 in $z.Pads) { $script:Pads[$pid2].Panel.Visible = ($pid2 -eq $z.Active) }
    Style-Zone $z
    if ($z.Form -and $z.Active) { $z.Form.Text = $script:Pads[$z.Active].Title }
    if ($z.Active -and $script:OnPadShown) { & $script:OnPadShown $z.Active }
}

# A pad is "showing" when it is the active tab of a zone that is on screen
function Pad-Showing([string]$id) {
    $z = Zone-Of $id; if (-not $z -or $z.Active -ne $id) { return $false }
    $f = $z.Root.FindForm(); if (-not $f) { return $false }
    return ($z.Root.Visible -and $z.Root.Width -gt 0 -and $z.Root.Height -gt 0 -and $f.Visible)
}

# Tabs of a zone (rebuilt on each change: a handful of labels)
function Render-Zone($z) {
    $z.Strip.SuspendLayout()
    foreach ($c in @($z.Strip.Controls)) { $c.Dispose() }
    $z.Strip.Controls.Clear()
    foreach ($id in $z.Pads) {
        $p = $script:Pads[$id]
        $l = New-Object System.Windows.Forms.Label
        $l.AutoSize = $true; $l.Text = $p.Title; $l.Tag = $id; $l.Cursor = [System.Windows.Forms.Cursors]::Hand
        $l.Padding = New-Object System.Windows.Forms.Padding(9, 4, 9, 4); $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 1, 0)
        $l.Add_MouseDown($script:TabDown); $l.Add_MouseMove($script:TabMove); $l.Add_MouseUp($script:TabUp)
        [void]$z.Strip.Controls.Add($l)
    }
    $z.Strip.ResumeLayout()
    Show-Active $z
    $script:LayoutDirty = $true
}

function Style-Zone($z) {
    $P = $script:Pal
    $z.Strip.BackColor = $P.Back
    foreach ($l in $z.Strip.Controls) {
        $on = ($l.Tag -eq $z.Active)
        $l.Font = $(if ($on) { $fontBold } else { $fontUi })
        $l.BackColor = $(if ($on) { $P.Input } else { $P.Back })
        $l.ForeColor = $(if ($on) { $P.Fore } else { $P.Muted })
    }
}
function Style-Zones { foreach ($z in @($script:Zones.Values)) { Style-Zone $z } }

# Empty zones of the main window fold away (SplitContainer cannot fold both sides)
function Set-Fold($sc, [bool]$c1, [bool]$c2) {
    if ($c1 -and $c2) { $c2 = $false }
    if ($sc.Panel1Collapsed -ne $c1 -or $sc.Panel2Collapsed -ne $c2) {
        $sc.Panel1Collapsed = $false; $sc.Panel2Collapsed = $false
        if ($c1) { $sc.Panel1Collapsed = $true }
        if ($c2) { $sc.Panel2Collapsed = $true }
    }
}
function Update-Collapse {
    $n = @{}; foreach ($k in 'left', 'center', 'right', 'bottom') { $n[$k] = $script:Zones[$k].Pads.Count }
    Set-Fold $trees ($n.left -eq 0) ($n.center -eq 0)
    Set-Fold $main (($n.left + $n.center) -eq 0) ($n.right -eq 0)
    Set-Fold $split (($n.left + $n.center + $n.right) -eq 0) ($n.bottom -eq 0)
}

# ---- floating windows
function Float-Pad([string]$id, $rect) {
    $p = $script:Pads[$id]; if (-not $p) { return }
    $script:FloatN++
    $z = New-Zone ('float' + $script:FloatN)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $p.Title; $f.Font = $fontUi; $f.FormBorderStyle = 'SizableToolWindow'; $f.ShowInTaskbar = $false
    $f.StartPosition = 'Manual'; $f.Bounds = $rect; $f.Owner = $form; $f.MinimumSize = New-Object System.Drawing.Size(220, 140); $f.Tag = $z.Name
    $f.Controls.Add($z.Root)
    $z.Form = $f; $z.Bounds = $rect
    $f.Add_LocationChanged({ param($s, $e) $zz = $script:Zones[$s.Tag]; if ($zz -and $s.WindowState -eq 'Normal') { $zz.Bounds = $s.Bounds } })
    $f.Add_SizeChanged({ param($s, $e) $zz = $script:Zones[$s.Tag]; if ($zz -and $s.WindowState -eq 'Normal') { $zz.Bounds = $s.Bounds } })
    $f.Add_FormClosing({
        param($s, $e)
        $zz = $script:Zones[$s.Tag]; if (-not $zz) { return }
        # closing with the main window (or app exit; may still be cancelled by the tray): kept in the layout
        if ($e.CloseReason -ne [System.Windows.Forms.CloseReason]::UserClosing -and $e.CloseReason -ne [System.Windows.Forms.CloseReason]::None) { return }
        # closed by the user: its panels go back to their places in the main window
        $zz.Closing = $true
        foreach ($pid2 in @($zz.Pads)) { Dock-Pad $pid2 $script:Pads[$pid2].Home -1 $true }
        $script:Zones.Remove($s.Tag)
    })
    Dock-Pad $id $z.Name
    Theme-Docked $f
    $f.Show()
    $script:LayoutDirty = $true
    return $z
}
function Float-Forms { return @($script:Zones.Values | Where-Object { $_.Form -and -not $_.Form.IsDisposed } | ForEach-Object { $_.Form }) }
function Theme-Docked($f) { Theme-Walk $f; Set-TitleDark $f $script:Dark; foreach ($z in @($script:Zones.Values)) { if ($z.Form -eq $f) { Style-Zone $z } } }

# ---- drag a tab
# Hint: a translucent rectangle where the tab would go (shown without taking the focus)
$script:Hint = $null
function Show-Hint($rect) {
    if (-not (Ensure-Ui)) { return }
    if (-not $script:Hint) {
        $h = New-Object System.Windows.Forms.Form
        $h.FormBorderStyle = 'None'; $h.ShowInTaskbar = $false; $h.TopMost = $true; $h.StartPosition = 'Manual'; $h.Opacity = 0.35
        $script:Hint = $h
    }
    $script:Hint.BackColor = $script:Pal.Link
    $script:Hint.Bounds = $rect
    [void][DvclNative.Win]::ShowWindow($script:Hint.Handle, 4)   # SW_SHOWNOACTIVATE
    [void][DvclNative.Win]::SetWindowPos($script:Hint.Handle, [IntPtr]::new(-1), $rect.X, $rect.Y, $rect.Width, $rect.Height, 0x10)
}
function Hide-Hint { if ($script:Hint -and (Ensure-Ui)) { [void][DvclNative.Win]::ShowWindow($script:Hint.Handle, 0) } }

function Screen-Rect($c) { return $c.RectangleToScreen($c.ClientRectangle) }

# Where a tab dropped at screen point $pt goes: @{ Zone; Rect } or @{ New; Rect } or $null (no change)
function Find-DropTarget($pt) {
    foreach ($f in (Float-Forms)) { if ($f.Visible -and $f.Bounds.Contains($pt)) { return @{ Zone = $f.Tag; Rect = $f.Bounds } } }
    if ($form.Bounds.Contains($pt)) {
        $a = Screen-Rect $split
        if (-not $a.Contains($pt)) { return $null }
        $e = 40
        if ($script:Zones.left.Pads.Count -eq 0 -and $pt.X -lt $a.Left + $e) { return @{ Zone = 'left'; Rect = (New-Object System.Drawing.Rectangle($a.Left, $a.Top, [int]($a.Width * 0.25), $a.Height)) } }
        if ($script:Zones.right.Pads.Count -eq 0 -and $pt.X -gt $a.Right - $e) { return @{ Zone = 'right'; Rect = (New-Object System.Drawing.Rectangle(($a.Right - [int]($a.Width * 0.3)), $a.Top, [int]($a.Width * 0.3), $a.Height)) } }
        if ($script:Zones.bottom.Pads.Count -eq 0 -and $pt.Y -gt $a.Bottom - $e) { return @{ Zone = 'bottom'; Rect = (New-Object System.Drawing.Rectangle($a.Left, ($a.Bottom - [int]($a.Height * 0.3)), $a.Width, [int]($a.Height * 0.3))) } }
        foreach ($k in 'left', 'center', 'right', 'bottom') {
            $z = $script:Zones[$k]
            if ($z.Pads.Count -eq 0) { continue }
            $r = Screen-Rect $z.Root
            if ($r.Width -gt 0 -and $r.Contains($pt)) { return @{ Zone = $k; Rect = $r } }
        }
        return $null
    }
    return @{ New = $true; Rect = (New-Object System.Drawing.Rectangle(($pt.X - 60), ($pt.Y - 12), 460, 380)) }
}

$script:TabDown = {
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:DockDrag = @{ Id = [string]$s.Tag; Start = [System.Windows.Forms.Cursor]::Position; On = $false }
        Activate-Pad ([string]$s.Tag)
    }
}
$script:TabMove = {
    param($s, $e)
    $d = $script:DockDrag; if (-not $d -or $e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $pt = [System.Windows.Forms.Cursor]::Position
    if (-not $d.On) {
        if ([Math]::Abs($pt.X - $d.Start.X) + [Math]::Abs($pt.Y - $d.Start.Y) -lt 8) { return }
        $d.On = $true; $s.Cursor = [System.Windows.Forms.Cursors]::SizeAll
    }
    $t = Find-DropTarget $pt
    if ($t) { Show-Hint $t.Rect } else { Hide-Hint }
}
$script:TabUp = {
    param($s, $e)
    $d = $script:DockDrag; $script:DockDrag = $null
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Show-TabMenu $s ([string]$s.Tag) $e.Location; return }
    if (-not $d -or -not $d.On) { return }
    if (-not $s.IsDisposed) { $s.Cursor = [System.Windows.Forms.Cursors]::Hand }
    Hide-Hint
    $t = Find-DropTarget ([System.Windows.Forms.Cursor]::Position)
    if (-not $t) { return }
    # applied just after this event: the dragged tab label is rebuilt (disposed) by the move
    $script:DropTodo = @{ Id = $d.Id; T = $t }
    $script:DropTimer.Start()
}
$script:DropTimer = New-Object System.Windows.Forms.Timer
$script:DropTimer.Interval = 15
$script:DropTimer.Add_Tick({
    $script:DropTimer.Stop()
    $x = $script:DropTodo; $script:DropTodo = $null; if (-not $x) { return }
    $t = $x.T; $cur = Zone-Of $x.Id
    if ($t.New) {
        # alone in its window already: just move that window
        if ($cur -and $cur.Form -and $cur.Pads.Count -eq 1) { $cur.Form.Location = $t.Rect.Location }
        else { [void](Float-Pad $x.Id $t.Rect) }
    }
    elseif (-not $cur -or $cur.Name -ne $t.Zone) { Dock-Pad $x.Id $t.Zone }
    Save-Layout
})

$script:TabMenu = New-Object System.Windows.Forms.ContextMenuStrip
function Show-TabMenu($label, [string]$id, $loc) {
    $m = $script:TabMenu; $m.Items.Clear(); $script:TabMenuId = $id
    $cur = Zone-Of $id
    $mv = Add-MenuItem $m 'Move to' $null
    foreach ($k in @(@('left', 'Left'), @('center', 'Center'), @('right', 'Right'), @('bottom', 'Bottom'))) {
        $mi = Add-MenuItem $mv $k[1] $null ($null -eq $cur -or $cur.Name -ne $k[0]); $mi.Tag = $k[0]
        $mi.Add_Click({ param($src, $ev) Dock-Pad $script:TabMenuId $src.Tag; Save-Layout })
    }
    [void](Add-MenuItem $m 'New window' {
            $pt = [System.Windows.Forms.Cursor]::Position
            [void](Float-Pad $script:TabMenuId (New-Object System.Drawing.Rectangle(($pt.X - 60), ($pt.Y - 12), 460, 380))); Save-Layout
        } (-not ($cur -and $cur.Form -and $cur.Pads.Count -eq 1)))
    [void]$m.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void](Add-MenuItem $m 'Reset layout' { Reset-Layout })
    Theme-Strip $m
    $m.Show($label, $loc)
}

# ---- save / restore
function Ratio($sc) {
    if ($sc.Panel1Collapsed -or $sc.Panel2Collapsed) { return $null }
    $size = $(if ($sc.Orientation -eq 'Vertical') { $sc.Width } else { $sc.Height })
    if ($size -le 0) { return $null }
    return [Math]::Round($sc.SplitterDistance / $size, 3)
}
function Get-Layout {
    $zones = [ordered]@{}; $active = [ordered]@{}
    foreach ($k in 'left', 'center', 'right', 'bottom') { $zones[$k] = @($script:Zones[$k].Pads); $active[$k] = $script:Zones[$k].Active }
    $floats = @()
    foreach ($z in @($script:Zones.Values)) {
        if (-not $z.Form -or $z.Pads.Count -eq 0 -or -not $z.Bounds) { continue }
        $b = $z.Bounds
        $floats += [pscustomobject]@{ pads = @($z.Pads); active = $z.Active; x = $b.X; y = $b.Y; w = $b.Width; h = $b.Height }
    }
    $r = [ordered]@{}
    foreach ($n in @(@('split', $split), @('main', $main), @('trees', $trees))) { $v = Ratio $n[1]; $r[$n[0]] = $(if ($null -ne $v) { $v } elseif ($script:Ratios -and $script:Ratios[$n[0]]) { $script:Ratios[$n[0]] } else { $script:DefaultRatios[$n[0]] }) }
    return [pscustomobject]@{ v = 1; zones = [pscustomobject]$zones; active = [pscustomobject]$active; floats = $floats; ratios = [pscustomobject]$r }
}
function Save-Layout { if ($script:LayoutReady) { $script:Layout = Get-Layout } }

function Apply-Ratios($r) {
    $script:Ratios = @{}
    foreach ($n in 'split', 'main', 'trees') { $v = $null; if ($r) { $v = $r.$n }; if (-not $v -or $v -le 0.05 -or $v -ge 0.95) { $v = $script:DefaultRatios[$n] }; $script:Ratios[$n] = [double]$v }
    foreach ($n in @(@('split', $split), @('main', $main), @('trees', $trees))) {
        $sc = $n[1]; $size = $(if ($sc.Orientation -eq 'Vertical') { $sc.Width } else { $sc.Height })
        try { if ($size -gt 0) { $sc.SplitterDistance = [int]($size * $script:Ratios[$n[0]]) } } catch {}
    }
}

# $lay: saved layout (or $null = default). Every pad ends up in exactly one zone.
function Apply-Layout($lay) {
    foreach ($z in @($script:Zones.Values)) { if ($z.Form) { $z.Closing = $true; foreach ($id in @($z.Pads)) { Undock-Pad $id }; if (-not $z.Form.IsDisposed) { $z.Form.Close() }; $script:Zones.Remove($z.Name) } }
    foreach ($id in @($script:Pads.Keys)) { Undock-Pad $id }
    $placed = @{}
    $src = $script:DefaultLayout
    $ok = $false
    if ($lay -and $lay.zones) {
        $src = [ordered]@{}; foreach ($k in 'left', 'center', 'right', 'bottom') { $src[$k] = @($lay.zones.$k) }
        $ok = $true
    }
    foreach ($k in 'left', 'center', 'right', 'bottom') {
        foreach ($id in @($src[$k])) { if ($id -and $script:Pads.Contains([string]$id) -and -not $placed[[string]$id]) { Dock-Pad ([string]$id) $k -1 $false; $placed[[string]$id] = $true } }
        $act = $null; if ($ok -and $lay.active) { $act = [string]$lay.active.$k }
        if ($act -and $script:Zones[$k].Pads.Contains($act)) { $script:Zones[$k].Active = $act; Render-Zone $script:Zones[$k] }
    }
    if ($ok) {
        foreach ($fl in @($lay.floats)) {
            if (-not $fl) { continue }
            $ids = @(@($fl.pads) | Where-Object { $_ -and $script:Pads.Contains([string]$_) -and -not $placed[[string]$_] })
            if ($ids.Count -eq 0) { continue }
            $rect = New-Object System.Drawing.Rectangle([int]$fl.x, [int]$fl.y, [Math]::Max(220, [int]$fl.w), [Math]::Max(140, [int]$fl.h))
            # off every screen (monitor removed): put it near the main window
            $vis = $false; foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) { if ($sc.WorkingArea.IntersectsWith($rect)) { $vis = $true } }
            if (-not $vis) { $rect.Location = New-Object System.Drawing.Point(($form.Left + 80), ($form.Top + 80)) }
            $z = Float-Pad ([string]$ids[0]) $rect; $placed[[string]$ids[0]] = $true
            foreach ($id in @($ids | Select-Object -Skip 1)) { Dock-Pad ([string]$id) $z.Name -1 $false; $placed[[string]$id] = $true }
            if ($fl.active -and $z.Pads.Contains([string]$fl.active)) { $z.Active = [string]$fl.active; Render-Zone $z }
        }
    }
    # anything left (new pads, bad file): its home zone
    foreach ($id in @($script:Pads.Keys)) { if (-not $placed[$id]) { Dock-Pad $id $script:Pads[$id].Home -1 $false } }
    foreach ($k in 'left', 'center', 'right', 'bottom') { $z = $script:Zones[$k]; if (-not $z.Active -and $z.Pads.Count) { $z.Active = [string]$z.Pads[0] }; Render-Zone $z }
    Update-Collapse
    [System.Windows.Forms.Application]::DoEvents()
    Apply-Ratios $(if ($ok) { $lay.ratios } else { $null })
    $script:LayoutReady = $true
    Save-Layout
}

function Reset-Layout { Apply-Layout $null; Theme-Walk $form; Style-Zones; Save-Settings }

# Tray: floating windows hide and come back with the main one
function Hide-Floats { foreach ($f in (Float-Forms)) { $f.Hide() } }
function Show-Floats { foreach ($f in (Float-Forms)) { $f.Show() } }
function Set-FloatsEnabled([bool]$on) { foreach ($f in (Float-Forms)) { foreach ($c in $f.Controls) { $c.Enabled = $on } } }
