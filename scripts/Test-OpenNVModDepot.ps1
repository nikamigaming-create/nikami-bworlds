[CmdletBinding()]
param(
    [string[]]$Module = @(),
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "OpenNVModDepot.ps1")

$repoRoot = Split-Path -Parent $PSScriptRoot
$lock = Get-OpenNVModDepotLock
$ids = if ($Module.Count -eq 0) { @($lock.modules | ForEach-Object { [string]$_.id }) } else { @($Module) }
$states = @($ids | ForEach-Object { Get-OpenNVModDepotState -Id $_ -RepoRoot $repoRoot })
$result = [pscustomobject]@{
    schema = "nikami-open-nv-mod-depot-check/v1"
    ready = @($states | Where-Object { -not $_.ready }).Count -eq 0
    modules = $states
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
}
else {
    $states | Select-Object id, status, archivePath, installPath | Format-Table -AutoSize
}

if (-not $result.ready) {
    $failed = @($states | Where-Object { -not $_.ready } | ForEach-Object { "$($_.id): $($_.status)" }) -join "; "
    throw "OpenNV mod-depot verification failed: $failed"
}
