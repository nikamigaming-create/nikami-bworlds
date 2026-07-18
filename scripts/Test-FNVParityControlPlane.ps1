[CmdletBinding()]
param(
    [string]$ControlPlanePath = "catalog/fnv-parity-control-plane.json",
    [string]$DenominatorPath = "catalog/fnv-parity-denominators.json",
    [string]$ExclusionPath = "catalog/fnv-parity-exclusions.json",
    [string]$BiteLedgerSchemaPath = "catalog/fnv-bite-ledger.schema.json",
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
$exclusionFile = Resolve-RepoPath $ExclusionPath
$biteLedgerSchemaFile = Resolve-RepoPath $BiteLedgerSchemaPath
$formalFile = Resolve-RepoPath $FormalLedgerPath
foreach ($required in @($controlPath, $denominatorFile, $exclusionFile, $biteLedgerSchemaFile, $formalFile)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing FNV parity control file: $required"
    }
}

$control = Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8 | ConvertFrom-Json
$denominators = Get-Content -LiteralPath $denominatorFile -Raw -Encoding UTF8 | ConvertFrom-Json
$exclusions = Get-Content -LiteralPath $exclusionFile -Raw -Encoding UTF8 | ConvertFrom-Json
$biteLedgerSchema = Get-Content -LiteralPath $biteLedgerSchemaFile -Raw -Encoding UTF8 | ConvertFrom-Json
$formal = Get-Content -LiteralPath $formalFile -Raw -Encoding UTF8 | ConvertFrom-Json
$failures = New-Object System.Collections.Generic.List[string]
function Assert-Control([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}
function Test-Sha256([string]$Value) {
    return $Value -match "^[0-9a-fA-F]{64}$"
}
function Get-TextSha256([string]$Value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "")
    } finally {
        $algorithm.Dispose()
    }
}

Assert-Control ([string]$control.schema -eq "nikami-fnv-parity-control-plane/v1") `
    "Unexpected control-plane schema."
Assert-Control ([string]$denominators.schema -eq "nikami-fnv-parity-denominators/v1") `
    "Unexpected denominator schema."
Assert-Control ([string]$exclusions.schema -eq "nikami-fnv-parity-exclusions/v1") `
    "Unexpected exclusion-ledger schema."
Assert-Control ([string]$control.scopeId -eq [string]$denominators.scopeId) `
    "Control plane and denominators use different scope IDs."
Assert-Control ([string]$control.scopeId -eq [string]$exclusions.scopeId) `
    "Control plane and exclusions use different scope IDs."
Assert-Control ([string]$control.denominators -eq "catalog/fnv-parity-denominators.json") `
    "Control plane does not point at the canonical denominator file."
Assert-Control ([string]$control.exclusions -eq "catalog/fnv-parity-exclusions.json") `
    "Control plane does not point at the canonical exclusion ledger."
Assert-Control ([string]$control.biteLedgerSchema -eq "catalog/fnv-bite-ledger.schema.json" -and
    [string]$biteLedgerSchema.'$id' -eq "nikami-fnv-bite-ledger-row/v1") `
    "Control plane does not point at the canonical bite-ledger schema."
$generatedBiteLedgerFile = Resolve-RepoPath ([string]$control.biteLedger.path)
Assert-Control (Test-Path -LiteralPath $generatedBiteLedgerFile -PathType Leaf) `
    "Generated GECK bite ledger is missing."
if (Test-Path -LiteralPath $generatedBiteLedgerFile -PathType Leaf) {
    $generatedBiteLedger = Get-Content -LiteralPath $generatedBiteLedgerFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $generatedBiteLedgerFileSha = (Get-FileHash -LiteralPath $generatedBiteLedgerFile -Algorithm SHA256).Hash
    Assert-Control ([string]$generatedBiteLedger.schema -eq "nikami-fnv-bite-ledger/v1" -and
        [string]$generatedBiteLedger.scopeId -eq [string]$control.scopeId) `
        "Generated GECK bite ledger has the wrong schema or scope."
    Assert-Control ($generatedBiteLedgerFileSha -eq [string]$control.biteLedger.fileSha256) `
        "Generated GECK bite-ledger file hash differs from the control plane."
    Assert-Control ([string]$generatedBiteLedger.canonicalSha256 -eq [string]$control.biteLedger.canonicalSha256 -and
        [string]$generatedBiteLedger.sourceReport.canonicalSha256 -eq
        [string]$control.biteLedger.sourceReportCanonicalSha256) `
        "Generated GECK bite-ledger canonical/source hash differs from the control plane."
    Assert-Control (@($generatedBiteLedger.rows).Count -eq [int]$control.biteLedger.rows -and
        [int]$generatedBiteLedger.summary.inputRows -eq [int]$control.biteLedger.rows -and
        [int]$generatedBiteLedger.summary.outputRows -eq [int]$control.biteLedger.rows -and
        [int]$generatedBiteLedger.summary.droppedRows -eq 0 -and
        [int]$generatedBiteLedger.summary.duplicateInputIds -eq 0 -and
        [int]$generatedBiteLedger.summary.duplicateRowIds -eq 0) `
        "Generated GECK bite ledger dropped, duplicated, or miscounted workload rows."
    Assert-Control ([int]$generatedBiteLedger.summary.uncoveredRows -eq [int]$control.biteLedger.uncoveredRows -and
        [int]$generatedBiteLedger.summary.parityCreditRows -eq [int]$control.biteLedger.parityCreditRows -and
        @($generatedBiteLedger.rows | Where-Object { [string]$_.implementation.disposition -ne "uncovered" }).Count -eq 0) `
        "Generated GECK bite ledger awarded unreviewed implementation/parity credit."
}
Assert-Control (@($exclusions.exclusions).Count -eq 0) `
    "Current scope unexpectedly contains an approved exclusion."
Assert-Control ([string]$control.scorePolicy.certifiedParityFormula -eq "min(axisScore)") `
    "Certified parity must be the weakest-axis score."
Assert-Control ([int]$control.scorePolicy.capabilityInventoryFloor -ge 187) `
    "Capability inventory floor was reduced below the audited baseline."
$releaseArtifactIds = @($control.releaseArtifacts.PSObject.Properties | ForEach-Object { [string]$_.Name })
Assert-Control ($releaseArtifactIds.Count -eq 2 -and
    $releaseArtifactIds -contains "scopeFreezeManifest" -and
    $releaseArtifactIds -contains "releaseManifest") `
    "Release artifact contract must contain scopeFreezeManifest and releaseManifest."

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
$allCounterRows = New-Object System.Collections.Generic.List[string]
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
                $sourceProperty = $control.evidence.PSObject.Properties[[string]$acceptance.sourceEvidence]
                Assert-Control ($null -ne $sourceProperty) `
                    "Complete case '$($axis.id)/$($case.id)' references an unknown acceptance manifest."
                if ($null -ne $sourceProperty) {
                    $sourceEntry = $sourceProperty.Value
                    $sourcePath = [string]$sourceEntry.path
                    Assert-Control ([string]$sourceEntry.kind -eq "repo-path") `
                        "Complete case '$($axis.id)/$($case.id)' acceptance manifest is not repository-backed."
                    Assert-Control (-not [IO.Path]::IsPathRooted($sourcePath) -and
                        $sourcePath.Replace("\", "/").StartsWith("catalog/fnv-evidence-manifests/")) `
                        "Complete case '$($axis.id)/$($case.id)' acceptance manifest is not a committed catalog artifact."
                    $resolvedSource = Resolve-RepoPath $sourcePath
                    Assert-Control (Test-Path -LiteralPath $resolvedSource -PathType Leaf) `
                        "Complete case '$($axis.id)/$($case.id)' acceptance manifest is missing."
                    if (Test-Path -LiteralPath $resolvedSource -PathType Leaf) {
                        $actualManifestSha = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash
                        Assert-Control ($actualManifestSha -eq [string]$acceptance.manifestSha256) `
                            "Complete case '$($axis.id)/$($case.id)' acceptance manifest hash differs."
                        $manifest = Get-Content -LiteralPath $resolvedSource -Raw -Encoding UTF8 | ConvertFrom-Json
                        $qualifiedCaseId = "$($axis.id)/$($case.id)"
                        Assert-Control ([string]$manifest.schema -eq "nikami-fnv-parity-result-manifest/v1") `
                            "Complete case '$qualifiedCaseId' acceptance manifest has the wrong schema."
                        Assert-Control ([string]$manifest.scopeId -eq [string]$control.scopeId) `
                            "Complete case '$qualifiedCaseId' acceptance manifest has the wrong scope."
                        Assert-Control ([string]$manifest.caseId -eq $qualifiedCaseId) `
                            "Complete case '$qualifiedCaseId' acceptance manifest names another case."
                        Assert-Control ([string]$manifest.status -eq "pass" -and [bool]$manifest.promoted -and
                            [bool]$manifest.normalExit -and -not [bool]$manifest.forceKilled) `
                            "Complete case '$qualifiedCaseId' manifest is not a promoted normal-exit pass."
                        foreach ($hashName in @("producerSha256", "corpusSha256", "profileSha256", "evidenceSha256")) {
                            Assert-Control (Test-Sha256 ([string]$manifest.$hashName)) `
                                "Complete case '$qualifiedCaseId' manifest lacks $hashName."
                        }
                        if ([bool]$manifest.runtimeRequired) {
                            foreach ($hashName in @("binarySha256", "saveSha256")) {
                                Assert-Control (Test-Sha256 ([string]$manifest.$hashName)) `
                                    "Runtime case '$qualifiedCaseId' manifest lacks $hashName."
                            }
                            Assert-Control ([string]$manifest.engineCommit -match "^[0-9a-fA-F]{40}$") `
                                "Runtime case '$qualifiedCaseId' manifest lacks a full engine commit."
                        }
                    }
                }
            }
        }
        foreach ($evidenceId in $caseEvidence) {
            Assert-Control ($null -ne $control.evidence.PSObject.Properties[[string]$evidenceId]) `
                "Case '$($axis.id)/$($case.id)' references unknown evidence '$evidenceId'."
        }
    }

    Assert-Control (@($axis.instances).Count -gt 0) "Axis '$($axis.id)' has no instance counters."
    $counterIds = @($axis.instances | ForEach-Object { [string]$_.id })
    Assert-Control (@($counterIds | Select-Object -Unique).Count -eq $counterIds.Count) `
        "Axis '$($axis.id)' contains duplicate content-counter IDs."
    foreach ($counter in @($axis.instances)) {
        [long]$observed = $counter.observed
        [long]$accepted = $counter.accepted
        [long]$total = $counter.total
        $allCounterRows.Add("$($axis.id)/$($counter.id)=$total") | Out-Null
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
                $sourceProperty = $control.evidence.PSObject.Properties[[string]$acceptance.sourceEvidence]
                Assert-Control ($null -ne $sourceProperty) `
                    "Counter '$($axis.id)/$($counter.id)' references an unknown result-ledger manifest."
                if ($null -ne $sourceProperty) {
                    $sourcePath = [string]$sourceProperty.Value.path
                    Assert-Control ([string]$sourceProperty.Value.kind -eq "repo-path") `
                        "Counter '$($axis.id)/$($counter.id)' result-ledger manifest is not repository-backed."
                    Assert-Control (-not [IO.Path]::IsPathRooted($sourcePath) -and
                        $sourcePath.Replace("\", "/").StartsWith("catalog/fnv-evidence-manifests/")) `
                        "Counter '$($axis.id)/$($counter.id)' result-ledger manifest is not a committed catalog artifact."
                    $resolvedSource = Resolve-RepoPath $sourcePath
                    Assert-Control (Test-Path -LiteralPath $resolvedSource -PathType Leaf) `
                        "Counter '$($axis.id)/$($counter.id)' result-ledger manifest is missing."
                    if (Test-Path -LiteralPath $resolvedSource -PathType Leaf) {
                        $actualLedgerSha = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash
                        Assert-Control ($actualLedgerSha -eq [string]$acceptance.ledgerSha256) `
                            "Counter '$($axis.id)/$($counter.id)' result-ledger manifest hash differs."
                        $ledger = Get-Content -LiteralPath $resolvedSource -Raw -Encoding UTF8 | ConvertFrom-Json
                        Assert-Control ([string]$ledger.schema -eq "nikami-fnv-parity-counter-manifest/v1" -and
                            [string]$ledger.scopeId -eq [string]$control.scopeId -and
                            [string]$ledger.axisId -eq [string]$axis.id -and
                            [string]$ledger.counterId -eq [string]$counter.id -and
                            [string]$ledger.status -eq "pass") `
                            "Counter '$($axis.id)/$($counter.id)' result-ledger identity/status is invalid."
                        Assert-Control ([long]$ledger.total -eq $total -and [long]$ledger.observed -eq $observed -and
                            [long]$ledger.accepted -eq $accepted) `
                            "Counter '$($axis.id)/$($counter.id)' values were not derived from its result ledger."
                        foreach ($hashName in @("rowsSha256", "producerSha256", "corpusSha256", "profileSha256")) {
                            Assert-Control (Test-Sha256 ([string]$ledger.$hashName)) `
                                "Counter '$($axis.id)/$($counter.id)' ledger lacks $hashName."
                        }
                    }
                }
            }
        }
    }
}
Assert-Control ($allCaseIds.Count -ge [int]$control.scorePolicy.capabilityInventoryFloor) `
    "Capability case count fell below the audited inventory floor."
Assert-Control (@($allCaseIds | Select-Object -Unique).Count -eq $allCaseIds.Count) `
    "Control plane contains duplicate fully qualified capability-case IDs."
$sortedCaseIds = [string[]]$allCaseIds.ToArray()
[Array]::Sort($sortedCaseIds, [StringComparer]::Ordinal)
$canonicalCaseSet = (($sortedCaseIds -join "`n") + "`n")
$caseSetSha256 = Get-TextSha256 $canonicalCaseSet
Assert-Control ($caseSetSha256 -eq "F1929B1C90DE3393EE91A47E28A532492035566128EC11823EFB4BA8A31D2D5F") `
    "Audited capability-case ID set changed; add discoveries deliberately or record a user-approved scope revision."
Assert-Control ($caseSetSha256 -eq [string]$control.scorePolicy.capabilityCaseSetSha256) `
    "Control-plane capability-case hash does not match its checked-in IDs."
$sortedCounterRows = [string[]]$allCounterRows.ToArray()
[Array]::Sort($sortedCounterRows, [StringComparer]::Ordinal)
$canonicalCounterSet = (($sortedCounterRows -join "`n") + "`n")
$counterSetSha256 = Get-TextSha256 $canonicalCounterSet
Assert-Control ($allCounterRows.Count -ge [int]$control.scorePolicy.contentCounterFloor) `
    "Content counter count fell below the audited inventory floor."
Assert-Control ($counterSetSha256 -eq "7DF528DCA347E63F0C5E786664234F134925DD9450DC869EC7EA356FF68AEC93") `
    "Audited content-counter ID/total set changed without a deliberate scope revision."
Assert-Control ($counterSetSha256 -eq [string]$control.scorePolicy.contentCounterSetSha256) `
    "Control-plane content-counter hash does not match its checked-in ID/total rows."

foreach ($property in $control.evidence.PSObject.Properties) {
    $entry = $property.Value
    switch ([string]$entry.kind) {
        "repo-path" {
            $resolved = Resolve-RepoPath ([string]$entry.path)
            Assert-Control (Test-Path -LiteralPath $resolved -PathType Leaf) `
                "Repository evidence '$($property.Name)' does not exist: $resolved"
        }
        "local-observation" {
            Assert-Control (-not [bool]$entry.certificationEligible) `
                "Local observation '$($property.Name)' must not be certification eligible."
        }
        "git-blob" {
            Assert-Control ([string]$entry.repository -match "^https://" -and
                [string]$entry.commit -match "^[0-9a-fA-F]{40}$" -and
                [string]$entry.blobSha1 -match "^[0-9a-fA-F]{40}$" -and
                -not [string]::IsNullOrWhiteSpace([string]$entry.path)) `
                "Git-blob evidence '$($property.Name)' lacks repository/commit/path/blob provenance."
        }
        default {
            Assert-Control $false "Evidence '$($property.Name)' has unsupported kind '$($entry.kind)'."
        }
    }
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
Assert-Control ($nextSlices.Count -eq 9) "Control plane must contain nine ordered execution slices."
for ($index = 0; $index -lt $nextSlices.Count; ++$index) {
    Assert-Control ([int]$nextSlices[$index].order -eq ($index + 1)) "Execution slices are not ordered 1 through 9."
    Assert-Control ([string]$nextSlices[$index].status -in @("pending", "in-progress", "complete")) `
        "Execution slice '$($nextSlices[$index].id)' has an invalid status."
    if ([string]$nextSlices[$index].status -eq "complete") {
        $engineCommit = if ($null -ne $nextSlices[$index].PSObject.Properties["engineCommit"]) {
            [string]$nextSlices[$index].engineCommit
        } else {
            ""
        }
        $worldsCommit = if ($null -ne $nextSlices[$index].PSObject.Properties["worldsCommit"]) {
            [string]$nextSlices[$index].worldsCommit
        } else {
            ""
        }
        Assert-Control (($engineCommit -match "^[0-9a-fA-F]{40}$") -or
            ($worldsCommit -match "^[0-9a-fA-F]{40}$")) `
            "Completed execution slice '$($nextSlices[$index].id)' lacks a full engine or worlds commit."
    }
}

Assert-Control ([int64]$denominators.recordCorpus.winningLiveRecords -eq 628395) `
    "Official winning-live-record denominator changed."
Assert-Control ([int64]$denominators.recordCorpus.winningLivePlacedReferences -eq 427319) `
    "Winning-live-placement denominator changed."
Assert-Control (@($denominators.officialMasters).Count -eq 10) `
    "Official master identity set changed."
Assert-Control (@($denominators.officialArchives).Count -eq 21) `
    "Official archive identity set changed."
$archiveOrders = @($denominators.officialArchives | ForEach-Object { [int]$_.order })
Assert-Control (($archiveOrders -join ",") -eq ((0..20) -join ",")) `
    "Official archive order is not the frozen 0..20 sequence."
Assert-Control ((@($denominators.officialArchives | Measure-Object authoredEntries -Sum).Sum) -eq 182177) `
    "Per-archive authored-entry counts do not reproduce the corpus total."
foreach ($entry in @($denominators.officialMasters) + @($denominators.officialArchives)) {
    Assert-Control ([long]$entry.bytes -gt 0 -and (Test-Sha256 ([string]$entry.sha256))) `
        "Frozen input '$($entry.name)' lacks size/SHA-256 provenance."
}
Assert-Control ([int]$denominators.questsAndScripts.officialQuests -eq 640) `
    "Official quest denominator changed."
Assert-Control ([int]$denominators.questsAndScripts.officialStandaloneScripts -eq 3707) `
    "Official standalone-script denominator changed."
Assert-Control ([int]$denominators.questsAndScripts.physicalRecordsWithScriptAttachments -eq 5151 -and
    [int]$denominators.questsAndScripts.winningLiveRecordsWithScriptAttachments -eq 5148) `
    "Physical/winning-live SCRI denominators changed."
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
Assert-Control ([int]$coverage.engineeringProgress.green -eq [int]$control.currentTruth.engineeringProgress.greenCapabilityCases -and
    [double]$coverage.engineeringProgress.greenPct -eq [double]$control.currentTruth.engineeringProgress.greenCapabilityPct) `
    "Computed green engineering progress differs from currentTruth."
Assert-Control ([int]$coverage.engineeringProgress.implementedOrBetter -eq
    [int]$control.currentTruth.engineeringProgress.implementedOrBetterCapabilityCases -and
    [double]$coverage.engineeringProgress.implementedOrBetterPct -eq
    [double]$control.currentTruth.engineeringProgress.implementedOrBetterCapabilityPct) `
    "Computed implemented-or-better engineering progress differs from currentTruth."
Assert-Control ([int]$coverage.engineeringProgress.liveEvidence -eq
    [int]$control.currentTruth.engineeringProgress.liveEvidenceCapabilityCases -and
    [double]$coverage.engineeringProgress.liveEvidencePct -eq
    [double]$control.currentTruth.engineeringProgress.liveEvidenceCapabilityPct) `
    "Computed live-evidence engineering progress differs from currentTruth."
Assert-Control ([int]$coverage.engineeringProgress.mapped -eq [int]$control.currentTruth.engineeringProgress.mappedCapabilityCases -and
    [double]$coverage.engineeringProgress.mappedPct -eq [double]$control.currentTruth.engineeringProgress.mappedCapabilityPct) `
    "Computed mapped engineering progress differs from currentTruth."

if ($failures.Count -gt 0) {
    Write-Host "FNV parity control-plane failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host ("FNV parity control plane passed: engineering={0:N2}% ({1}/{2}), certified={3:N2}% ({4}/{2}), formal={5}/{6}." -f `
    $coverage.engineeringProgress.greenPct, $coverage.engineeringProgress.green, $coverage.capabilityCases.total, `
    $coverage.certifiedParityPct, $coverage.capabilityCases.complete, `
    $coverage.formalFNVProductSubsystems.complete, $coverage.formalFNVProductSubsystems.total)
