# tests/probe-ue.ps1 <workspace> [<file> ...] - what a dvcl Unreal link can use (read-only):
# open editor + engine folder, Python, remote execution reachable, Python API present, which of
# <file>s are loaded / unsaved in Unreal, C++ build tools, engine plugin folder writable.
# Report: tests\probe-ue.log (stays on this PC). Changes nothing (a temp file is created and removed).
param([string]$Workspace, [string[]]$Files = @())
$ErrorActionPreference = 'Continue'
$logf = Join-Path $PSScriptRoot 'probe-ue.log'
Set-Content -LiteralPath $logf -Value ('probe-ue ' + (Get-Date -Format s)) -Encoding UTF8
function Note([string]$t) { Add-Content -LiteralPath $logf -Value $t -Encoding UTF8 }

$ed = @(Get-Process UnrealEditor -ErrorAction SilentlyContinue | Where-Object { $_.Path })
Note ('editors running: ' + $ed.Count + ' ' + (($ed | ForEach-Object { $_.Path }) -join ' ; '))
$engine = ''
if ($ed.Count) { $engine = Split-Path (Split-Path (Split-Path (Split-Path $ed[0].Path))) }
Note ('engine dir: ' + $engine)

$py = $null
foreach ($c in @(@('py', '-3'), @('python'))) {
    try { $v = & $c[0] @($c | Select-Object -Skip 1) --version 2>&1; if ($LASTEXITCODE -eq 0) { $py = $c; Note ('python: ' + ($c -join ' ') + ' -> ' + $v); break } } catch {}
}
if (-not $py) { Note 'python: NOT FOUND' }

# inside Unreal: API present, loaded / unsaved state of the files
$rels = @($Files | ForEach-Object { ($_ -replace '\\', '/') })
$code = @"
import unreal
print('engine ' + unreal.SystemLibrary.get_engine_version())
print('project ' + unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_dir()))
for n in ['EditorLoadingAndSavingUtils', 'SourceControlHelpers', 'PackageTools', 'EditorAssetLibrary', 'DvclLinkLibrary']:
    print('api %s %s' % (n, hasattr(unreal, n)))
print('api find_package %s' % hasattr(unreal, 'find_package'))
try:
    w = unreal.get_editor_subsystem(unreal.UnrealEditorSubsystem).get_editor_world()
    print('world ' + w.get_path_name())
except Exception as e:
    print('world ? %s' % e)
for rel in $(ConvertTo-Json -Compress -InputObject ([string[]]$rels)):
    full = r'''$($Workspace -replace "'", "")'''.replace('\\', '/').rstrip('/') + '/' + rel
    pkg = None
    if '/Content/' in full:
        pkg = '/Game/' + full.split('/Content/', 1)[1].rsplit('.', 1)[0]
    p = unreal.find_package(pkg) if (pkg and hasattr(unreal, 'find_package')) else None
    print('file %s | package %s | loaded %s | unsaved %s' % (rel, pkg, p is not None, (p.is_dirty() if p else '-')))
"@
$tmp = Join-Path $env:TEMP ('dvcl-probe-ue-' + [guid]::NewGuid().ToString('N') + '.py')
Set-Content -LiteralPath $tmp -Value $code -Encoding UTF8
if ($py -and $engine) {
    $out = & $py[0] @($py | Select-Object -Skip 1) (Join-Path (Split-Path $PSScriptRoot) 'src\dvcl_ue.py') $engine $Workspace $tmp 10 2>&1
    foreach ($l in $out) { Note ('ue | ' + $l) }
}
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

# C++ build tools (to build a small editor plugin) and engine plugin folder
$vsw = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vsw) { Note ('visual studio: ' + ((& $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) -join ' ')) } else { Note 'visual studio: vswhere not found' }
if ($engine) {
    Note ('RunUAT: ' + (Test-Path (Join-Path $engine 'Engine\Build\BatchFiles\RunUAT.bat')))
    $mp = Join-Path $engine 'Engine\Plugins\Marketplace'
    Note ('engine Marketplace plugins: ' + ((Get-ChildItem -LiteralPath $mp -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '))
    $t = Join-Path $mp ('dvcl-write-test-' + [guid]::NewGuid().ToString('N'))
    try { [void](New-Item -ItemType File -Path $t -ErrorAction Stop); Remove-Item -LiteralPath $t -Force; Note 'engine plugin folder writable: True' } catch { Note ('engine plugin folder writable: False (' + $_.Exception.Message + ')') }
}
(Get-Content -LiteralPath $logf | Where-Object { $_ -match '^(editors|engine dir|python|visual|RunUAT|engine plugin|ue \| (RESULT|api|engine|file))' }) -join ' || '
