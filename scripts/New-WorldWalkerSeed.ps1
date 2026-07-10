param(
    [string]$WorldCatalogPath = "catalog/worlds.local.json",
    [string]$ContractPath = "catalog/world-walker-ui-contract.json",
    [string]$OutputPath = "catalog/world-walker.seed.json",
    [string]$CellsRoot = "catalog/cells"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToForwardSlash([string]$Path) {
    return ($Path -replace "\\", "/")
}

foreach ($path in @($WorldCatalogPath, $ContractPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required input: $path"
    }
}

$worldCatalog = Get-Content -LiteralPath $WorldCatalogPath -Raw | ConvertFrom-Json
$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
$excludedWorldIds = @()
if ($null -ne $contract.PSObject.Properties["excludedWorldIds"]) {
    $excludedWorldIds = @($contract.excludedWorldIds | ForEach-Object { [string]$_ })
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
New-Item -ItemType Directory -Force -Path $CellsRoot | Out-Null

$worldRows = @()
foreach ($world in $worldCatalog.worlds) {
    $worldId = [string]$world.id
    $excludedByContract = $excludedWorldIds -contains $worldId
    $profileReady = -not $excludedByContract -and $world.openmwTarget -eq $true -and $world.installStatus -eq "ready" -and $world.profileStatus -eq "generated"
    $cellCatalogPath = Join-Path $CellsRoot "$($world.id).cells.json"

    $worldRows += [pscustomobject][ordered]@{
        id = $worldId
        displayName = $world.displayName
        supportTier = $world.supportTier
        installStatus = $world.installStatus
        profileStatus = $world.profileStatus
        excludedByContract = $excludedByContract
        readyForWorldWalker = $profileReady
        profileDirectory = $world.profileDirectory
        profileConfig = $world.generatedProfileConfig
        settingsConfig = $world.generatedSettingsConfig
        userDataDirectory = $world.userDataDirectory
        expectedCellCatalog = Convert-ToForwardSlash $cellCatalogPath
        cellCatalogStatus = if (Test-Path -LiteralPath $cellCatalogPath) { "present" } else { "needed" }
        launchArgs = if ($profileReady) { @("--replace", "config", "--config", $world.profileDirectory) } else { @() }
        firstCutModes = if ($profileReady) { @("cell-search", "coordinate-jump", "map-click-exterior") } else { @() }
    }
}

$readyWorlds = @($worldRows | Where-Object { $_.readyForWorldWalker })
$missingCatalogs = @($readyWorlds | Where-Object { $_.cellCatalogStatus -ne "present" } | ForEach-Object { $_.id })

$seed = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    contractPath = Convert-ToForwardSlash $ContractPath
    cellSchemaPath = "catalog/cell-catalog.schema.json"
    worldCatalogPath = Convert-ToForwardSlash $WorldCatalogPath
    contractActions = @($contract.actions | ForEach-Object { $_.id })
    excludedWorldIds = @($excludedWorldIds)
    summary = [pscustomobject][ordered]@{
        worlds = @($worldRows).Count
        readyWorlds = @($readyWorlds).Count
        missingCellCatalogs = @($missingCatalogs).Count
    }
    worlds = $worldRows
    nextNeeded = @(
        "Export per-world cell catalogs under catalog/cells.",
        "Add native ViewerTravel bridge for explicit worldspace coordinate jumps.",
        "Add MyGUI WorldWalkerWindow and VR pointer smoke test."
    )
}

$seed | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding ASCII

$worldRows | Format-Table -AutoSize id, supportTier, installStatus, readyForWorldWalker, cellCatalogStatus
Write-Host "Wrote world walker seed: $OutputPath"
if ($missingCatalogs.Count -gt 0) {
    Write-Host "Cell catalogs still needed for: $($missingCatalogs -join ', ')"
}
