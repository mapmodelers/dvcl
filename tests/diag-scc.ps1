# tests\diag-scc.ps1 <workspace> - read-only: what Unreal's "dvcl" revision control sees.
# Writes tests\diag-scc.log (gitignored, stays on this PC) and prints a one-line summary. Changes nothing.
param([string]$Workspace)
$tool = Split-Path -Parent $PSScriptRoot
. (Join-Path $tool 'src\DvclCore.ps1')
Set-DvRoot (Find-DvRoot $Workspace)
$out = New-Object System.Collections.Generic.List[string]
function Add([string]$t) { $out.Add($t) }

# 1. dvcl windows running, and whether they started before the code they run changed
$gui = Get-Item -LiteralPath (Join-Path $tool 'src\dvcl-gui.ps1')
$core = Get-Item -LiteralPath (Join-Path $tool 'src\DvclCore.ps1')
Add ('code: gui ' + $gui.LastWriteTime.ToString('s') + ' core ' + $core.LastWriteTime.ToString('s'))
$pat = '*dvcl-gui' + '.ps1*'
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like $pat })
foreach ($p in $procs) {
    $st = $p.CreationDate
    $old = ($st -lt $gui.LastWriteTime) -or ($st -lt $core.LastWriteTime)
    Add ('dvcl window pid ' + $p.ProcessId + ' started ' + $st.ToString('s') + $(if ($old) { ' OLD CODE' } else { '' }))
}
if (-not $procs.Count) { Add 'dvcl window: none running' }

# 2. the list dvcl writes for Unreal
$pf = Dvcl-File 'pending.tsv'
if (Test-Path -LiteralPath $pf) {
    $lines = @(Get-Content -LiteralPath $pf -Encoding UTF8)
    Add ('pending.tsv: ' + ($lines.Count - 1) + ' file(s), written ' + (Get-Item -LiteralPath $pf).LastWriteTime.ToString('s'))
    $lines | Select-Object -First 6 | ForEach-Object { Add ('  ' + $_) }
} else { Add 'pending.tsv: MISSING' }

# 3. Unreal: provider, and the state it gives for the first pending files
$pick = @()
if (Test-Path -LiteralPath $pf) { $pick = @(Get-Content -LiteralPath $pf -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 3 | ForEach-Object { ($_ -split "`t")[1] }) }
$files = @($pick | ForEach-Object { (Full-Path $_).Replace('\', '/') })
$py = "import unreal`n" +
      "sc = unreal.SourceControl`n" +
      "try:`n    print('provider ' + str(sc.current_provider()) + ' enabled ' + str(sc.is_enabled()) + ' available ' + str(sc.is_available()))`nexcept Exception as e:`n    print('provider error ' + str(e))`n" +
      "for f in [" + (($files | ForEach-Object { "r'" + $_ + "'" }) -join ',') + "]:`n" +
      "    try:`n        s = sc.query_file_state(f, True)`n        print('state ' + f[-60:] + ' valid=' + str(s.is_valid) + ' controlled=' + str(s.is_source_controlled) + ' checkedout=' + str(s.is_checked_out) + ' added=' + str(s.is_added) + ' modified=' + str(s.is_modified))`n" +
      "    except Exception as e:`n        print('state error ' + str(e))`n"
$r = Invoke-Ue $py
Add ('unreal: ' + $r.State)
$r.Lines | Where-Object { $_ -notlike 'RESULT*' } | Select-Object -First 20 | ForEach-Object { Add ('  ' + $_) }

# 4. Unreal's log: revision control lines
$proj = Get-ChildItem -LiteralPath $script:Root -Directory | Where-Object { Get-ChildItem -LiteralPath $_.FullName -Filter *.uproject -File -ErrorAction SilentlyContinue } | Select-Object -First 1
if ($proj) {
    $ulog = Get-ChildItem -LiteralPath (Join-Path $proj.FullName 'Saved\Logs') -Filter *.log -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*backup*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($ulog) {
        Add ('unreal log: ' + $ulog.Name + ' ' + $ulog.LastWriteTime.ToString('s'))
        $hit = @(Get-Content -LiteralPath $ulog.FullName -ErrorAction SilentlyContinue | Where-Object { $_ -match 'SourceControl|RevisionControl|dvcl|DvclLink' })
        $hit | Select-Object -Last 40 | ForEach-Object { Add ('  ' + $_) }
    }
    $ini = Join-Path $proj.FullName 'Saved\Config\WindowsEditor\SourceControlSettings.ini'
    if (Test-Path -LiteralPath $ini) { Add 'SourceControlSettings.ini:'; Get-Content -LiteralPath $ini | ForEach-Object { Add ('  ' + $_) } }
}

# 5. dvcl log: the last submit (from its start to 60 lines after)
if (Test-Path -LiteralPath $script:Log) {
    $all = @(Get-Content -LiteralPath $script:Log -Encoding UTF8)
    $start = -1; for ($k = $all.Count - 1; $k -ge 0; $k--) { if ($all[$k] -match 'Submitting') { $start = $k; break } }
    if ($start -lt 0) { $start = [Math]::Max(0, $all.Count - 150) } else { $start = [Math]::Max(0, $start - 60) }
    Add ('dvcl log from line ' + $start + ' of ' + $all.Count + ':')
    $all[$start..([Math]::Min($all.Count - 1, $start + 260))] | ForEach-Object { Add ('  ' + $_) }
}

$log = Join-Path $PSScriptRoot 'diag-scc.log'
[System.IO.File]::WriteAllLines($log, $out.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
(@($out | Where-Object { $_ -like 'dvcl window*' -or $_ -like 'pending.tsv*' -or $_ -like 'unreal:*' -or $_ -like '  provider*' }) -join ' | ')
