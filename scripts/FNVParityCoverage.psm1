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

function Get-FNVParityCoverage {
    [CmdletBinding()]
    param(
        [string]$ControlPlanePath = "catalog/fnv-parity-control-plane.json",
        [string]$RepoRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..")))
    )

    $controlPath = Resolve-FNVParityPath -Path $ControlPlanePath -RepoRoot $RepoRoot
    $control = Get-Content -LiteralPath $controlPath -Raw | ConvertFrom-Json

    $axisRows = New-Object System.Collections.Generic.List[object]
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

    $axisPercentages = @($axisRows | ForEach-Object { [double]$_.certifiedAxisPct })
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
    $releasePrerequisites = @($control.releasePrerequisites.PSObject.Properties | ForEach-Object {
        [pscustomobject][ordered]@{
            id = [string]$_.Name
            complete = [bool]$_.Value
        }
    })
    $openReleasePrerequisiteCount = @($releasePrerequisites | Where-Object { -not $_.complete }).Count

    return [pscustomobject][ordered]@{
        schema = "nikami-fnv-parity-coverage/v1"
        asOf = [string]$control.asOf
        scopeId = [string]$control.scopeId
        certifiedParityPct = [Math]::Round([double]$overall, 6)
        balancedAxisProgressPct = [Math]::Round([double]$balancedAxisProgress, 6)
        releaseReady = [bool]($overall -eq 100.0 -and $notGreenAxisCount -eq 0 -and
            $openReleasePrerequisiteCount -eq 0)
        capabilityInventoryComplete = [bool]$control.currentTruth.capabilityInventoryComplete
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
