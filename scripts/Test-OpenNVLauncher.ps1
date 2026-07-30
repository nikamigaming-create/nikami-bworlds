[CmdletBinding()]
param(
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateScript = Join-Path $PSScriptRoot "Get-OpenNVLauncherState.ps1"
$depotTestScript = Join-Path $PSScriptRoot "Test-OpenNVModDepot.ps1"
. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
$stableRuntime = (Resolve-NikamiOpenMWRuntimeRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$failures = [Collections.Generic.List[string]]::new()
$rows = [Collections.Generic.List[object]]::new()

if (-not (Test-Path -LiteralPath $stateScript -PathType Leaf)) {
    throw "Missing launcher state script: $stateScript"
}
if (-not (Test-Path -LiteralPath $depotTestScript -PathType Leaf)) {
    throw "Missing mod-depot validation script: $depotTestScript"
}

$state = (& $stateScript -AsJson | ConvertFrom-Json)
foreach ($campaign in @($state.campaigns)) {
    foreach ($variantProperty in @($campaign.variants.PSObject.Properties)) {
        $variantName = [string]$variantProperty.Name
        $variant = $variantProperty.Value
        $label = "$($campaign.id)/$variantName"
        if (-not [bool]$variant.ready) {
            $failures.Add("$label is not ready: $($variant.message)")
            continue
        }
        if ([string]$variant.profileConfigState -cne "current") {
            $failures.Add("$label profile configuration is not current: $($variant.profileConfigState)")
        }
        $runtimeRoot = [IO.Path]::GetFullPath([string]$variant.runtimeRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (-not $runtimeRoot.Equals($stableRuntime, [StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add("$label runtime is not the pinned player runtime: $runtimeRoot")
        }
        $configPath = Join-Path ([string]$variant.profileDirectory) "openmw.cfg"
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            $failures.Add("$label is missing generated config: $configPath")
            continue
        }
        $configLines = @(Get-Content -LiteralPath $configPath)
        $dataLines = @($configLines | Where-Object { $_ -match '^(data|data-local)=' })
        $fallbackLines = @($dataLines | Where-Object { $_ -match '(?i)opennv-ui-fallback' })
        if ($fallbackLines.Count -ne 0) {
            $failures.Add("$label must not mount generated placeholder UI textures")
        }
        $forbiddenLines = @($dataLines | Where-Object { $_ -match '(?i)(^|[\\/])downloads([\\/]|$)|(?i)(^|[\\/])local[\\/]labs([\\/]|$)' })
        if ($forbiddenLines.Count -gt 0) {
            $failures.Add("$label contains forbidden player data layer(s): $($forbiddenLines -join '; ')")
        }
        $rows.Add([pscustomobject]@{
            campaign = [string]$campaign.id
            variant = $variantName
            profile = [string]$variant.profileDirectory
            config = [string]$variant.profileConfigState
            placeholderUiLayers = $fallbackLines.Count
            runtime = $runtimeRoot
        })
    }
}

$depot = (& $depotTestScript -AsJson | ConvertFrom-Json)
if (-not [bool]$depot.ready) {
    $failedModules = @($depot.modules | Where-Object { -not $_.ready } | ForEach-Object { "$($_.id):$($_.status)" }) -join "; "
    $failures.Add("Hash-locked mod depot is not ready: $failedModules")
}

$result = [pscustomobject]@{
    schema = "nikami-open-nv-launcher-check/v1"
    ready = ($failures.Count -eq 0)
    profiles = @($rows.ToArray())
    depot = $depot
    failures = @($failures.ToArray())
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 12
}
else {
    $rows | Format-Table -AutoSize
    if ($failures.Count -eq 0) {
        Write-Host "OpenNV launcher validation passed."
    }
    else {
        foreach ($failure in $failures) {
            Write-Host "Launcher validation failure: $failure" -ForegroundColor Red
        }
    }
}

if ($failures.Count -gt 0) {
    exit 1
}
