# dvcl-scan.ps1 - offline folder scan, run by the window in a background runspace.
# Output: { Files; Fresh; Error }. Same engine as the window (DvclCore.ps1).
param([string]$Workspace)   # not $Root: DvclCore.ps1 resets $script:Root when loaded
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'DvclCore.ps1')
    $script:Root = $Workspace
    $script:Log = [System.IO.Path]::Combine($Workspace, '.dvcl', 'dvcl.log')
    $f = Get-OfflinePending
    [pscustomobject]@{ Files = $f; Fresh = [bool]$script:BaselineFresh; Error = $null }
} catch { [pscustomobject]@{ Files = @(); Fresh = $false; Error = ($_.Exception.Message + ' @ line ' + $_.InvocationInfo.ScriptLineNumber) } }
