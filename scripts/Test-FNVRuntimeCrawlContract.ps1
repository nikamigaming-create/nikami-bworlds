[CmdletBinding()]
param(
    [string]$ContractPath = "catalog/fnv-full-runtime-crawl-contract.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$contractFile = if ([IO.Path]::IsPathRooted($ContractPath)) {
    [IO.Path]::GetFullPath($ContractPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $ContractPath))
}
if (-not (Test-Path -LiteralPath $contractFile -PathType Leaf)) {
    throw "Missing FNV runtime crawl contract: $contractFile"
}

$contract = Get-Content -LiteralPath $contractFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$contract.schema -ne "nikami-fnv-full-runtime-crawl-contract/v1") {
    throw "Unexpected FNV runtime crawl contract schema: $($contract.schema)"
}

$failures = [Collections.Generic.List[string]]::new()
function Add-Failure([string]$Message) { $script:failures.Add($Message) | Out-Null }

$requiredDenominators = [ordered]@{
    winningLiveRecords = 628395
    cells = 44517
    cellsWithActorOrInteractable = 2516
    npcs = 3942
    creatures = 3739
    directedDoorTeleports = 1378
    containers = 10778
    terminals = 357
    craftingStationsCandidate = 304
    craftingStationCandidateBases = 12
    recipes = 291
    radios = 425
    dialogueInfos = 28896
    dialogueResponses = 37403
    quests = 640
    aiPackages = 4885
    weatherRecords = 98
}
foreach ($entry in $requiredDenominators.GetEnumerator()) {
    $property = $contract.denominators.PSObject.Properties[$entry.Key]
    if ($null -eq $property) {
        Add-Failure "Missing denominator '$($entry.Key)'."
        continue
    }
    if ([int]$property.Value -ne [int]$entry.Value) {
        Add-Failure "Denominator '$($entry.Key)' expected $($entry.Value), found $($property.Value)."
    }
}

$gates = @($contract.crawlGates)
foreach ($gateId in @(
    "cell-streaming",
    "actor-runtime",
    "dialogue-barter",
    "inventory-containers",
    "weapons-mods-ammo-repair",
    "crafting-workbench-reloading-campfire",
    "doors-world-state",
    "quests-scripts",
    "world-lighting-shaders-sound"
)) {
    if (-not @($gates | Where-Object { [string]$_.id -eq $gateId })) {
        Add-Failure "Missing crawl gate '$gateId'."
    }
}

$weaponGate = @($gates | Where-Object { [string]$_.id -eq "weapons-mods-ammo-repair" } | Select-Object -First 1)
if ($null -eq $weaponGate) {
    Add-Failure "Missing weapons/mods/ammo/repair gate."
} else {
    $weaponEvidence = (@($weaponGate.requiredEvidence) -join "`n").ToLowerInvariant()
    foreach ($needle in @("weapon mod", "ammo type switching", "condition loss", "repair", "vendor service", "normal in-game combat")) {
        if (-not $weaponEvidence.Contains($needle)) {
            Add-Failure "Weapon gate does not explicitly require '$needle'."
        }
    }
    if ([int]$weaponGate.currentStatus.acceptedParityCredit -ne 0) {
        Add-Failure "Weapon gate must not claim accepted parity before exhaustive proof."
    }
}

$craftingGate = @($gates | Where-Object { [string]$_.id -eq "crafting-workbench-reloading-campfire" } | Select-Object -First 1)
if ($null -eq $craftingGate) {
    Add-Failure "Missing crafting gate."
} else {
    $craftingEvidence = (@($craftingGate.requiredEvidence) -join "`n").ToLowerInvariant()
    foreach ($needle in @("workbench", "reloading bench", "campfire", "291 recipes", "ammo breakdown", "save/load")) {
        if (-not $craftingEvidence.Contains($needle)) {
            Add-Failure "Crafting gate does not explicitly require '$needle'."
        }
    }
    if ([int]$craftingGate.currentStatus.acceptedParityCredit -ne 0) {
        Add-Failure "Crafting gate must not claim accepted parity before exhaustive proof."
    }
}

$nextSlices = (@($contract.nextSlicesInOrder) -join "`n").ToLowerInvariant()
foreach ($needle in @("switches ammo", "weapon mod", "repair/condition", "workbench", "reloading bench", "campfire", "291 recipes")) {
    if (-not $nextSlices.Contains($needle)) {
        Add-Failure "Next-slice plan does not include '$needle'."
    }
}

if ($failures.Count -gt 0) {
    Write-Host "FNV runtime crawl contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "FNV runtime crawl contract passed: full-game crawl includes explicit weapons, mods, ammo, repair, and crafting gates."
