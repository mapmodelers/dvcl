# dvcl-branches.ps1 - Branches panel data, run by the window in a background runspace.
# Output: { Rows; Graph; Error } (Files = @() so the window's job runner takes it as a raw result)
param([string]$Workspace, [string]$Branch)   # not $Root: DvclCore.ps1 resets $script:Root when loaded
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'DvclCore.ps1')
    $script:Root = $Workspace
    $script:Db = [System.IO.Path]::Combine($Workspace, '.dvcl', 'changelists.json')
    $script:Log = [System.IO.Path]::Combine($Workspace, '.dvcl', 'dvcl.log')
    Load-Db
    $rows = @(Branch-Rows)
    $ids = Parse-BranchIds (Invoke-Dv @('branch') $true).Lines
    $g = Graph-Data (Invoke-Dv @('log', '-n', '80', '--date', 'iso') $true).Lines $ids $Branch
    [pscustomobject]@{ Files = @(); Rows = $rows; Graph = $g; Error = $null }
} catch { [pscustomobject]@{ Files = @(); Rows = @(); Graph = $null; Error = ($_.Exception.Message + ' @ line ' + $_.InvocationInfo.ScriptLineNumber) } }
