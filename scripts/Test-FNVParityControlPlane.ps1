[CmdletBinding()]
param(
    [string]$ControlPlanePath = "catalog/fnv-parity-control-plane.json",
    [string]$DenominatorPath = "catalog/fnv-parity-denominators.json",
    [string]$FormalLedgerPath = "catalog/fnv-flat-acceptance-ledger.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

$controlPath = Resolve-RepoPath $ControlPlanePath
$denominatorFile = Resolve-RepoPath $DenominatorPath
$formalFile = Resolve-RepoPath $FormalLedgerPath
foreach ($required in @($controlPath, $denominatorFile, $formalFile)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing FNV parity control file: $required"
    }
}

$control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json
$denominators = Get-Content -LiteralPath $denominatorFile -Raw | ConvertFrom-Json
$formal = Get-Content -LiteralPath $formalFile -Raw | ConvertFrom-Json
$failures = New-Object System.Collections.Generic.List[string]
function Assert-Control([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}
function Test-Sha256([string]$Value) {
    return $Value -match "^[0-9a-fA-F]{64}$"
}

Assert-Control ([string]$control.schema -eq "nikami-fnv-parity-control-plane/v1") `
    "Unexpected control-plane schema."
Assert-Control ([string]$denominators.schema -eq "nikami-fnv-parity-denominators/v1") `
    "Unexpected denominator schema."
Assert-Control ([string]$control.scopeId -eq [string]$denominators.scopeId) `
    "Control plane and denominators use different scope IDs."
Assert-Control ([string]$control.denominators -eq "catalog/fnv-parity-denominators.json") `
    "Control plane does not point at the canonical denominator file."
Assert-Control ([string]$control.scorePolicy.certifiedParityFormula -eq "min(axisScore)") `
    "Certified parity must be the weakest-axis score."
Assert-Control ([int]$control.scorePolicy.capabilityInventoryFloor -ge 179) `
    "Capability inventory floor was reduced below the audited baseline."
Assert-Control (@($control.releasePrerequisites.PSObject.Properties).Count -gt 0) `
    "Release prerequisites are missing."

$expectedAxes = @(
    "provenance-build-replay",
    "content-census-parsing",
    "world-traversal-physics",
    "rendering-weather-materials",
    "player-ui-character-creation",
    "activation-locks-objects",
    "inventory-economy-crafting",
    "actor-appearance-animation",
    "ai-packages-furniture-followers",
    "combat-vats-damage",
    "dialogue-voice-lip",
    "quests-scripts-factions",
    "audio-music-radio-video",
    "persistence-map-fast-travel",
    "end-to-end-base-dlc-release"
)
$axisIds = @($control.axes | ForEach-Object { [string]$_.id })
Assert-Control ($axisIds.Count -eq 15) "Control plane must contain exactly 15 parity axes."
Assert-Control (@($axisIds | Select-Object -Unique).Count -eq $axisIds.Count) `
    "Control plane contains duplicate axis IDs."
foreach ($expected in $expectedAxes) {
    Assert-Control ($axisIds -contains $expected) "Control plane is missing axis '$expected'."
}

$validStates = @($control.scorePolicy.maturityStates | ForEach-Object { [string]$_ })
$allCaseIds = New-Object System.Collections.Generic.List[string]
foreach ($axis in @($control.axes)) {
    $caseIds = @($axis.cases | ForEach-Object { [string]$_.id })
    Assert-Control ($caseIds.Count -gt 0) "Axis '$($axis.id)' has no capability cases."
    Assert-Control (@($caseIds | Select-Object -Unique).Count -eq $caseIds.Count) `
        "Axis '$($axis.id)' contains duplicate case IDs."
    foreach ($case in @($axis.cases)) {
        $allCaseIds.Add("$($axis.id)/$($case.id)") | Out-Null
        $caseEvidence = @()
        if ($null -ne $case.PSObject.Properties["evidence"]) {
            $caseEvidence = @($case.evidence)
        }
        Assert-Control ($validStates -contains [string]$case.state) `
            "Case '$($axis.id)/$($case.id)' has invalid state '$($case.state)'."
        Assert-Control (-not [string]::IsNullOrWhiteSpace([string]$case.exit)) `
            "Case '$($axis.id)/$($case.id)' has no exit criterion."
        if ([string]$case.state -ne "uncovered") {
            Assert-Control ($caseEvidence.Count -gt 0) `
                "Non-uncovered case '$($axis.id)/$($case.id)' has no evidence reference."
        }
        if ([string]$case.state -eq "complete") {
            Assert-Control ($caseEvidence.Count -gt 0) `
                "Complete case '$($axis.id)/$($case.id)' has no evidence."
            $acceptance = if ($null -ne $case.PSObject.Properties["acceptance"]) {
                $case.acceptance
            } else {
                $null
            }
            Assert-Control ($null -ne $acceptance) `
                "Complete case '$($axis.id)/$($case.id)' has no immutable acceptance contract."
            if ($null -ne $acceptance) {
                Assert-Control ([string]$acceptance.kind -eq "immutable-result-manifest") `
                    "Complete case '$($axis.id)/$($case.id)' does not use an immutable result manifest."
                Assert-Control (Test-Sha256 ([string]$acceptance.manifestSha256)) `
                    "Complete case '$($axis.id)/$($case.id)' has no valid manifest SHA-256."
                Assert-Control (-not [string]::IsNullOrWhiteSpace([string]$acceptance.sourceEvidence)) `
                    "Complete case '$($axis.id)/$($case.id)' has no source evidence ID."
            }
        }
        foreach ($evidenceId in $caseEvidence) {
            Assert-Control ($null -ne $control.evidence.PSObject.Properties[[string]$evidenceId]) `
                "Case '$($axis.id)/$($case.id)' references unknown evidence '$evidenceId'."
        }
    }

    Assert-Control (@($axis.instances).Count -gt 0) "Axis '$($axis.id)' has no instance counters."
    foreach ($counter in @($axis.instances)) {
        [long]$observed = $counter.observed
        [long]$accepted = $counter.accepted
        [long]$total = $counter.total
        Assert-Control ($total -gt 0) "Counter '$($axis.id)/$($counter.id)' has a non-positive total."
        Assert-Control ($accepted -ge 0 -and $accepted -le $observed) `
            "Counter '$($axis.id)/$($counter.id)' has accepted outside 0..observed."
        Assert-Control ($observed -ge 0 -and $observed -le $total) `
            "Counter '$($axis.id)/$($counter.id)' has observed outside 0..total."
        if ($accepted -gt 0) {
            $acceptance = if ($null -ne $counter.PSObject.Properties["acceptance"]) {
                $counter.acceptance
            } else {
                $null
            }
            Assert-Control ($null -ne $acceptance) `
                "Counter '$($axis.id)/$($counter.id)' has hand-edited accepted rows without a result ledger."
            if ($null -ne $acceptance) {
                Assert-Control ([string]$acceptance.kind -eq "generated-result-ledger") `
                    "Counter '$($axis.id)/$($counter.id)' does not derive acceptance from a generated result ledger."
                Assert-Control (Test-Sha256 ([string]$acceptance.ledgerSha256)) `
                    "Counter '$($axis.id)/$($counter.id)' has no valid result-ledger SHA-256."
            }
        }
    }
}
Assert-Control ($allCaseIds.Count -ge [int]$control.scorePolicy.capabilityInventoryFloor) `
    "Capability case count fell below the audited inventory floor."
Assert-Control (@($allCaseIds | Select-Object -Unique).Count -eq $allCaseIds.Count) `
    "Control plane contains duplicate fully qualified capability-case IDs."

foreach ($property in $control.evidence.PSObject.Properties) {
    $entry = $property.Value
    if ([string]$entry.kind -ne "path") {
        continue
    }
    $resolved = Resolve-RepoPath ([string]$entry.path)
    Assert-Control (Test-Path -LiteralPath $resolved -PathType Leaf) `
        "Evidence '$($property.Name)' does not exist: $resolved"
}

$layers = @($control.onionLayers)
Assert-Control ($layers.Count -eq 8) "Control plane must contain onion layers 0 through 7."
for ($index = 0; $index -lt $layers.Count; ++$index) {
    Assert-Control ([int]$layers[$index].id -eq $index) "Onion layers are not ordered 0 through 7."
    Assert-Control (-not [string]::IsNullOrWhiteSpace([string]$layers[$index].exit)) `
        "Onion layer $index has no exit criterion."
    Assert-Control (-not [string]::IsNullOrWhiteSpace([string]$layers[$index].hardStop)) `
        "Onion layer $index has no hard stop."
}

$nextSlices = @($control.nextSlices)
Assert-Control ($nextSlices.Count -eq 8) "Control plane must contain eight ordered execution slices."
for ($index = 0; $index -lt $nextSlices.Count; ++$index) {
    Assert-Control ([int]$nextSlices[$index].order -eq ($index + 1)) "Next slices are not ordered 1 through 8."
}

Assert-Control ([int64]$denominators.recordCorpus.winningLiveRecords -eq 628395) `
    "Official winning-live-record denominator changed."
Assert-Control ([int64]$denominators.recordCorpus.winningLivePlacedReferences -eq 427319) `
    "Winning-live-placement denominator changed."
Assert-Control ([int]$denominators.questsAndScripts.officialQuests -eq 640) `
    "Official quest denominator changed."
Assert-Control ([int]$denominators.questsAndScripts.officialStandaloneScripts -eq 3707) `
    "Official standalone-script denominator changed."
Assert-Control ([int]$denominators.dialogue.infos -eq 28896) `
    "Dialogue INFO denominator changed."
Assert-Control (@($denominators.scorePolicy.retailExcluded) -contains "FNVR.esp") `
    "FNVR.esp is not explicitly excluded from retail scoring."

$fNVRows = @($formal.subsystems | Where-Object {
    [string]$_.id -notin @("fallout3-control", "morrowind-regression", "openmw-queue-replay")
})
$fNVPass = @($fNVRows | Where-Object { [string]$_.status -eq "pass" }).Count
Assert-Control ($fNVRows.Count -eq [int]$control.currentTruth.formalFNVProductSubsystems.total) `
    "Formal FNV subsystem denominator differs from the control-plane snapshot."
Assert-Control ($fNVPass -eq [int]$control.currentTruth.formalFNVProductSubsystems.complete) `
    "Formal FNV subsystem numerator differs from the control-plane snapshot."

Import-Module (Join-Path $PSScriptRoot "FNVParityCoverage.psm1") -Force
$coverage = Get-FNVParityCoverage -ControlPlanePath $controlPath -RepoRoot $repoRoot
Assert-Control ([double]$coverage.certifiedParityPct -eq [double]$control.currentTruth.certifiedParityPct) `
    "Computed certified parity differs from currentTruth."
Assert-Control ([double]$coverage.balancedAxisProgressPct -eq [double]$control.currentTruth.balancedAxisProgressPct) `
    "Computed balanced axis progress differs from currentTruth."
Assert-Control ([bool]$coverage.releaseReady -eq [bool]$control.currentTruth.releaseReady) `
    "Computed release readiness differs from currentTruth."
Assert-Control ([int]$coverage.capabilityCases.complete -eq [int]$control.currentTruth.completeCapabilityCases) `
    "Computed complete capability-case count differs from currentTruth."
Assert-Control ([int]$coverage.capabilityCases.open -eq [int]$control.currentTruth.openCapabilityCases) `
    "Computed open capability-case count differs from currentTruth."

if ($failures.Count -gt 0) {
    Write-Host "FNV parity control-plane failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host ("FNV parity control plane passed: certified={0:N2}%, cases={1}/{2}, formal={3}/{4}." -f `
    $coverage.certifiedParityPct, $coverage.capabilityCases.complete, $coverage.capabilityCases.total, `
    $coverage.formalFNVProductSubsystems.complete, $coverage.formalFNVProductSubsystems.total)
