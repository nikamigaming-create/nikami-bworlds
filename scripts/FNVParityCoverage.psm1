Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FNVParityPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Test-FNVReleaseArtifactReference {
    param(
        [AllowNull()]
        [object]$Reference,
        [Parameter(Mandatory)]
        [ValidateSet("scope-freeze", "release")]
        [string]$Kind,
        [Parameter(Mandatory)]
        [object]$Control,
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [string]$RequiredScopeManifestSha256 = ""
    )

    if ($null -eq $Reference) {
        return $false
    }
    try {
        $path = [string]$Reference.path
        $expectedSha = [string]$Reference.sha256
        if ([IO.Path]::IsPathRooted($path) -or
            -not $path.Replace("\", "/").StartsWith("catalog/fnv-evidence-manifests/") -or
            $expectedSha -notmatch "^[0-9a-fA-F]{64}$") {
            return $false
        }
        $resolved = Resolve-FNVParityPath -Path $path -RepoRoot $RepoRoot
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            return $false
        }
        if ((Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash -ne $expectedSha) {
            return $false
        }
        $manifest = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$manifest.scopeId -ne [string]$Control.scopeId -or [string]$manifest.status -ne "pass") {
            return $false
        }
        if ($Kind -eq "scope-freeze") {
            return [string]$manifest.schema -eq "nikami-fnv-parity-scope-freeze/v1" -and
                [bool]$manifest.capabilityInventoryComplete -and
                [bool]$manifest.contentDenominatorsFrozen -and
                [string]$manifest.capabilityCaseSetSha256 -eq [string]$Control.scorePolicy.capabilityCaseSetSha256 -and
                [string]$manifest.contentCounterSetSha256 -eq [string]$Control.scorePolicy.contentCounterSetSha256 -and
                [string]$manifest.corpusSha256 -match "^[0-9a-fA-F]{64}$" -and
                [string]$manifest.profileSha256 -match "^[0-9a-fA-F]{64}$" -and
                [string]$manifest.oracleSha256 -match "^[0-9a-fA-F]{64}$" -and
                -not [string]::IsNullOrWhiteSpace([string]$manifest.userApproval)
        }
        return [string]$manifest.schema -eq "nikami-fnv-parity-release/v1" -and
            [double]$manifest.certifiedParityPct -eq 100.0 -and
            [bool]$manifest.releaseReady -and [bool]$manifest.promoted -and [bool]$manifest.normalExit -and
            [string]$manifest.scopeManifestSha256 -eq $RequiredScopeManifestSha256 -and
            [string]$manifest.binarySha256 -match "^[0-9a-fA-F]{64}$" -and
            [string]$manifest.engineCommit -match "^[0-9a-fA-F]{40}$" -and
            [string]$manifest.engineTree -match "^[0-9a-fA-F]{40}$" -and
            [string]$manifest.corpusSha256 -match "^[0-9a-fA-F]{64}$" -and
            [string]$manifest.profileSha256 -match "^[0-9a-fA-F]{64}$" -and
            [string]$manifest.fullResultsSha256 -match "^[0-9a-fA-F]{64}$" -and
            [string]$manifest.naturalJourneySha256 -match "^[0-9a-fA-F]{64}$" -and
            [string]$manifest.cleanInstallSha256 -match "^[0-9a-fA-F]{64}$" -and
            [string]$manifest.regressionsSha256 -match "^[0-9a-fA-F]{64}$" -and
            -not [string]::IsNullOrWhiteSpace([string]$manifest.userApproval)
    } catch {
        return $false
    }
}

function Get-FNVParityCoverage {
    [CmdletBinding()]
    param(
        [string]$ControlPlanePath = "catalog/fnv-parity-control-plane.json",
        [string]$RepoRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..")))
    )

    $controlPath = Resolve-FNVParityPath -Path $ControlPlanePath -RepoRoot $RepoRoot
    $control = Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $axisRows = New-Object System.Collections.Generic.List[object]
    $axisScoresRaw = New-Object System.Collections.Generic.List[double]
    $openCaseRows = New-Object System.Collections.Generic.List[object]
    $maturityCounts = @{}
    [int]$allCases = 0
    [int]$completeCases = 0

    foreach ($axis in @($control.axes)) {
        $cases = @($axis.cases)
        $instances = @($axis.instances)
        if ($cases.Count -eq 0) {
            throw "Parity axis '$($axis.id)' has no capability cases."
        }
        if ($instances.Count -eq 0) {
            throw "Parity axis '$($axis.id)' has no content-instance denominator."
        }

        $axisCompleteCases = @($cases | Where-Object { [string]$_.state -eq "complete" }).Count
        $axisCasePct = 100.0 * $axisCompleteCases / $cases.Count
        $allCases += $cases.Count
        $completeCases += $axisCompleteCases

        foreach ($case in $cases) {
            $state = [string]$case.state
            if (-not $maturityCounts.ContainsKey($state)) {
                $maturityCounts[$state] = 0
            }
            $maturityCounts[$state] = [int]$maturityCounts[$state] + 1
            if ($state -ne "complete") {
                $openCaseRows.Add([pscustomobject][ordered]@{
                    axisId = [string]$axis.id
                    caseId = [string]$case.id
                    state = $state
                    exit = [string]$case.exit
                }) | Out-Null
            }
        }

        [long]$acceptedInstances = 0
        [long]$observedInstances = 0
        [long]$totalInstances = 0
        [double]$minimumAcceptedFamilyPct = 100.0
        $instanceRows = New-Object System.Collections.Generic.List[object]
        foreach ($counter in $instances) {
            [long]$accepted = [long]$counter.accepted
            [long]$observed = [long]$counter.observed
            [long]$total = [long]$counter.total
            if ($total -le 0) {
                throw "Parity counter '$($axis.id)/$($counter.id)' has a non-positive denominator."
            }
            if ($accepted -lt 0 -or $accepted -gt $observed -or $observed -gt $total) {
                throw "Parity counter '$($axis.id)/$($counter.id)' violates 0 <= accepted <= observed <= total."
            }
            $acceptedInstances += $accepted
            $observedInstances += $observed
            $totalInstances += $total
            $familyAcceptedPct = 100.0 * $accepted / $total
            $familyObservedPct = 100.0 * $observed / $total
            $minimumAcceptedFamilyPct = [Math]::Min($minimumAcceptedFamilyPct, $familyAcceptedPct)
            $instanceRows.Add([pscustomobject][ordered]@{
                id = [string]$counter.id
                observed = $observed
                accepted = $accepted
                total = $total
                observedPct = [Math]::Round($familyObservedPct, 6)
                acceptedPct = [Math]::Round($familyAcceptedPct, 6)
            }) | Out-Null
        }
        if ($totalInstances -le 0) {
            throw "Parity axis '$($axis.id)' has a non-positive content denominator."
        }

        $axisAcceptedPct = 100.0 * $acceptedInstances / $totalInstances
        $axisObservedPct = 100.0 * $observedInstances / $totalInstances
        $axisScore = [Math]::Min($axisCasePct, $minimumAcceptedFamilyPct)
        $axisScoresRaw.Add($axisScore) | Out-Null
        $axisRows.Add([pscustomobject][ordered]@{
            id = [string]$axis.id
            name = [string]$axis.name
            completeCapabilityCases = $axisCompleteCases
            totalCapabilityCases = $cases.Count
            capabilityCompletionPct = [Math]::Round($axisCasePct, 4)
            observedContentInstances = $observedInstances
            acceptedContentInstances = $acceptedInstances
            totalContentInstances = $totalInstances
            observedContentPct = [Math]::Round($axisObservedPct, 6)
            acceptedContentPct = [Math]::Round($axisAcceptedPct, 6)
            minimumAcceptedContentFamilyPct = [Math]::Round($minimumAcceptedFamilyPct, 6)
            certifiedAxisPct = [Math]::Round($axisScore, 6)
            contentFamilies = @($instanceRows | ForEach-Object { $_ })
        }) | Out-Null
    }

    if ($axisRows.Count -eq 0) {
        throw "Parity control plane has no axes."
    }

    $axisPercentages = @($axisScoresRaw | ForEach-Object { [double]$_ })
    $overall = ($axisPercentages | Measure-Object -Minimum).Minimum
    $balancedAxisProgress = ($axisPercentages | Measure-Object -Average).Average
    $capabilityPct = if ($allCases -gt 0) { 100.0 * $completeCases / $allCases } else { 0.0 }

    $maturityRows = @($control.scorePolicy.maturityStates | ForEach-Object {
        [pscustomobject][ordered]@{
            state = [string]$_
            count = if ($maturityCounts.ContainsKey([string]$_)) { [int]$maturityCounts[[string]$_] } else { 0 }
        }
    })
    $axisArray = @($axisRows | ForEach-Object { $_ })
    $notGreenAxisCount = @($axisArray | Where-Object { $_.certifiedAxisPct -ne 100.0 }).Count
    $scopeFreezeGreen = Test-FNVReleaseArtifactReference -Reference $control.releaseArtifacts.scopeFreezeManifest `
        -Kind "scope-freeze" -Control $control -RepoRoot $RepoRoot
    $scopeManifestSha = if ($scopeFreezeGreen) { [string]$control.releaseArtifacts.scopeFreezeManifest.sha256 } else { "" }
    $releaseManifestGreen = $scopeFreezeGreen -and
        (Test-FNVReleaseArtifactReference -Reference $control.releaseArtifacts.releaseManifest -Kind "release" `
            -Control $control -RepoRoot $RepoRoot -RequiredScopeManifestSha256 $scopeManifestSha)
    $allCountersAccepted = @($axisArray | ForEach-Object { $_.contentFamilies } |
        Where-Object { [long]$_.accepted -ne [long]$_.total }).Count -eq 0
    $releasePrerequisites = @(
        [pscustomobject][ordered]@{ id = "all-certified-axes"; complete = ($notGreenAxisCount -eq 0) }
        [pscustomobject][ordered]@{ id = "all-capability-cases"; complete = ($completeCases -eq $allCases) }
        [pscustomobject][ordered]@{ id = "all-content-counters"; complete = $allCountersAccepted }
        [pscustomobject][ordered]@{ id = "scope-freeze-manifest"; complete = $scopeFreezeGreen }
        [pscustomobject][ordered]@{ id = "release-manifest"; complete = $releaseManifestGreen }
    )
    $openReleasePrerequisiteCount = @($releasePrerequisites | Where-Object { -not $_.complete }).Count

    return [pscustomobject][ordered]@{
        schema = "nikami-fnv-parity-coverage/v1"
        asOf = [string]$control.asOf
        scopeId = [string]$control.scopeId
        certifiedParityPct = [Math]::Round([double]$overall, 6)
        balancedAxisProgressPct = [Math]::Round([double]$balancedAxisProgress, 6)
        releaseReady = [bool]($overall -eq 100.0 -and $notGreenAxisCount -eq 0 -and
            $openReleasePrerequisiteCount -eq 0)
        capabilityInventoryComplete = [bool]$scopeFreezeGreen
        capabilityCases = [pscustomobject][ordered]@{
            complete = $completeCases
            total = $allCases
            open = $allCases - $completeCases
            pct = [Math]::Round($capabilityPct, 4)
        }
        formalFNVProductSubsystems = $control.currentTruth.formalFNVProductSubsystems
        formalAllLedgerRowsIncludingControls = $control.currentTruth.formalAllLedgerRowsIncludingControls
        maturity = $maturityRows
        openCapabilityCases = @($openCaseRows | ForEach-Object { $_ })
        releasePrerequisites = $releasePrerequisites
        axes = $axisArray
    }
}

Export-ModuleMember -Function Get-FNVParityCoverage
