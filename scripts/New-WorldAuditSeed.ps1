param(
    [string]$WorldCatalogPath = "catalog/worlds.local.json",
    [string]$ContractPath = "catalog/world-audit-contract.json",
    [string]$OutputPath = "catalog/world-audit.seed.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToForwardSlash([string]$Path) {
    return ($Path -replace "\\", "/")
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

foreach ($path in @($WorldCatalogPath, $ContractPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required input: $path"
    }
}

$catalog = Get-Content -LiteralPath $WorldCatalogPath -Raw | ConvertFrom-Json
$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json

$worldsById = @{}
foreach ($world in @($catalog.worlds)) {
    $worldsById[[string]$world.id] = $world
}

$passRows = @($contract.passes | Sort-Object order)
$auditWorlds = New-Object System.Collections.Generic.List[object]

foreach ($target in @($contract.targetWorlds | Sort-Object order)) {
    $id = [string]$target.id
    $world = if ($worldsById.ContainsKey($id)) { $worldsById[$id] } else { $null }
    $track = [string]$target.track
    $installStatus = if ($null -ne $world) { [string]$world.installStatus } else { "unknown" }
    $profileStatus = if ($null -ne $world) { [string]$world.profileStatus } else { "unknown" }
    $hasData = $false
    if ($null -ne $world) {
        $dataPaths = @(Get-PropertyValue $world "dataPaths")
        $hasData = $dataPaths.Count -gt 0
    }
    $hasProfile = $null -ne $world -and $installStatus -eq "ready" -and $profileStatus -eq "generated"

    $passes = New-Object System.Collections.Generic.List[object]
    foreach ($pass in $passRows) {
        $applies = @($pass.appliesToTracks)
        if ($applies -notcontains $track) {
            continue
        }

        $status = "blocked"
        $blocker = ""
        if ($track -eq "asset-research" -and $pass.id -match "cell|actor|zone|promotion") {
            $status = "not-applicable"
            $blocker = "asset-research track"
        }
        elseif ($pass.id -eq "profile-isolation" -or $pass.id -eq "cell-load-smoke" -or $pass.id -eq "cell-catalog" -or $pass.id -eq "actor-catalog" -or $pass.id -eq "actor-render-proof" -or $pass.id -eq "zone-traversal" -or $pass.id -eq "regression-promotion") {
            if ($hasProfile) {
                $status = "ready"
            }
            else {
                $blocker = "requires ready generated profile"
            }
        }
        else {
            if ($installStatus -eq "ready" -and $hasData) {
                $status = "ready"
            }
            elseif ($installStatus -eq "missing" -or $installStatus -eq "unknown") {
                $blocker = "world install not discovered"
            }
            else {
                $blocker = "requires discovered data path"
            }
        }

        $passes.Add([pscustomobject][ordered]@{
            id = [string]$pass.id
            order = [int]$pass.order
            status = $status
            blocker = $blocker
            evidence = @($pass.evidence)
            gate = [string]$pass.gate
        }) | Out-Null
    }

    $auditWorlds.Add([pscustomobject][ordered]@{
        id = $id
        displayName = if ($null -ne $world) { [string]$world.displayName } else { $id }
        order = [int]$target.order
        track = $track
        runtimePromotionAllowed = [bool]$target.runtimePromotionAllowed
        supportTier = if ($null -ne $world) { [string]$world.supportTier } else { "unknown" }
        installStatus = $installStatus
        profileStatus = $profileStatus
        profileDirectory = if ($null -ne $world) { Get-PropertyValue $world "profileDirectory" } else { $null }
        dataPaths = if ($null -ne $world) { @(Get-PropertyValue $world "dataPaths") } else { @() }
        passes = @($passes.ToArray())
    }) | Out-Null
}

$readyPasses = 0
$blockedPasses = 0
foreach ($world in @($auditWorlds.ToArray())) {
    foreach ($pass in @($world.passes)) {
        if ($pass.status -eq "ready") {
            $readyPasses++
        }
        elseif ($pass.status -eq "blocked") {
            $blockedPasses++
        }
    }
}

$seed = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    worldCatalogPath = Convert-ToForwardSlash $WorldCatalogPath
    contractPath = Convert-ToForwardSlash $ContractPath
    summary = [pscustomobject][ordered]@{
        worlds = @($auditWorlds.ToArray()).Count
        passes = @($passRows).Count
        readyPasses = $readyPasses
        blockedPasses = $blockedPasses
    }
    worlds = @($auditWorlds.ToArray())
    guardrails = @($contract.guardrails)
}

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$seed | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding ASCII

@($auditWorlds.ToArray()) |
    Select-Object id, track, installStatus, profileStatus, runtimePromotionAllowed |
    Format-Table -AutoSize

Write-Host "Wrote world audit seed: $OutputPath"
Write-Host "Ready passes: $readyPasses"
Write-Host "Blocked passes: $blockedPasses"

