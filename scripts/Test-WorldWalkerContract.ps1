param(
    [string]$ContractPath = "catalog/world-walker-ui-contract.json",
    [string]$CellSchemaPath = "catalog/cell-catalog.schema.json",
    [string]$SeedPath = "catalog/world-walker.seed.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$failures = New-Object System.Collections.Generic.List[string]

foreach ($path in @($ContractPath, $CellSchemaPath, $SeedPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        $failures.Add("Missing required file: $path")
    }
}

if ($failures.Count -eq 0) {
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
    $cellSchema = Get-Content -LiteralPath $CellSchemaPath -Raw | ConvertFrom-Json
    $seed = Get-Content -LiteralPath $SeedPath -Raw | ConvertFrom-Json

    if ($contract.schemaVersion -ne 1) {
        $failures.Add("Unexpected contract schema version: $($contract.schemaVersion)")
    }
    if ($cellSchema.schemaVersion -ne 1) {
        $failures.Add("Unexpected cell schema version: $($cellSchema.schemaVersion)")
    }
    if ($seed.schemaVersion -ne 1) {
        $failures.Add("Unexpected seed schema version: $($seed.schemaVersion)")
    }

    $requiredActions = @(
        "viewer.launchWorld",
        "viewer.listCells",
        "viewer.jumpToCell",
        "viewer.jumpToMapPoint",
        "viewer.jumpToCoordinates"
    )
    $actionIds = @($contract.actions | ForEach-Object { $_.id })
    foreach ($action in $requiredActions) {
        if ($actionIds -notcontains $action) {
            $failures.Add("Contract missing action: $action")
        }
    }

    $requiredSchemaKeys = @("worldspaces", "cells")
    foreach ($key in $requiredSchemaKeys) {
        if ($cellSchema.requiredTopLevelKeys -notcontains $key) {
            $failures.Add("Cell schema missing required top-level key marker: $key")
        }
    }

    $readyWorlds = @($seed.worlds | Where-Object { $_.readyForWorldWalker -eq $true })
    if ($readyWorlds.Count -eq 0) {
        $failures.Add("Seed has no ready world-walker profiles")
    }

    $excludedWorldIds = @()
    if ($null -ne $contract.PSObject.Properties["excludedWorldIds"]) {
        $excludedWorldIds = @($contract.excludedWorldIds | ForEach-Object { [string]$_ })
    }
    foreach ($worldId in $excludedWorldIds) {
        $excludedRows = @($seed.worlds | Where-Object { [string]$_.id -eq $worldId })
        foreach ($world in $excludedRows) {
            if ($world.readyForWorldWalker -eq $true) {
                $failures.Add("$worldId is excluded by contract but readyForWorldWalker is true")
            }
        }
    }

    foreach ($world in $readyWorlds) {
        $args = @($world.launchArgs)
        foreach ($requiredArg in @("--replace", "config", "--config")) {
            if ($args -notcontains $requiredArg) {
                $failures.Add("$($world.id): launchArgs missing $requiredArg")
            }
        }
        if (-not $world.profileDirectory) {
            $failures.Add("$($world.id): ready world missing profileDirectory")
        }
        if ($world.cellCatalogStatus -ne "present" -and $world.cellCatalogStatus -ne "needed") {
            $failures.Add("$($world.id): invalid cellCatalogStatus $($world.cellCatalogStatus)")
        }
    }

    $readyWorlds | Format-Table -AutoSize id, supportTier, profileDirectory, cellCatalogStatus
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "World walker contract validation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "World walker contract validation passed."
