[CmdletBinding()]
param(
    [string]$PolicyPath = "catalog/fnv-seamless-exterior-policy.json",
    [string]$SchemaPath = "catalog/fnv-seamless-exterior-policy.schema.json",
    [string]$GraphPath = "",
    [switch]$RequireReviewed,
    [string]$ReportPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Resolve-RepoInputPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
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

function Add-Failure([string]$Message) {
    $failures.Add($Message)
}

function Add-Warning([string]$Message) {
    $warnings.Add($Message)
}

function Test-ExactBoolean($Value, [bool]$Expected) {
    return $Value -is [bool] -and [bool]$Value -eq $Expected
}

function Read-JsonDocument([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure "Missing ${Label}: $Path"
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-Failure "Invalid JSON in $Label '$Path': $($_.Exception.Message)"
        return $null
    }
}

function Test-FormId([string]$Value) {
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^0x[0-9a-f]{8}$'
}

$policyFullPath = Resolve-RepoInputPath $PolicyPath
$schemaFullPath = Resolve-RepoInputPath $SchemaPath
$graphFullPath = Resolve-RepoInputPath $GraphPath

$schema = Read-JsonDocument -Path $schemaFullPath -Label "seamless exterior policy schema"
$policy = Read-JsonDocument -Path $policyFullPath -Label "seamless exterior policy"

if ($null -ne $schema) {
    if ([string](Get-PropertyValue $schema '$schema') -ne 'https://json-schema.org/draft/2020-12/schema') {
        Add-Failure "Policy schema must declare JSON Schema draft 2020-12"
    }
    if ([string](Get-PropertyValue (Get-PropertyValue (Get-PropertyValue $schema 'properties') 'schema') 'const') -ne 'nikami-fnv-seamless-exterior-policy/v1') {
        Add-Failure "Policy schema must lock the policy schema identity"
    }
    $edgeDefinitions = Get-PropertyValue (Get-PropertyValue $schema '$defs') 'edgePolicy'
    $classification = Get-PropertyValue (Get-PropertyValue $edgeDefinitions 'properties') 'classification'
    $allowedFromSchema = @((Get-PropertyValue $classification 'enum') | ForEach-Object { [string]$_ })
    $expectedClassifications = @(
        'same-worldspace-boundary',
        'outdoor-portal',
        'real-interior-door',
        'scripted-or-unsafe',
        'unreviewed'
    )
    $sortedSchemaClassifications = @($allowedFromSchema | Sort-Object)
    $sortedExpectedClassifications = @($expectedClassifications | Sort-Object)
    if (($sortedSchemaClassifications -join '|') -ne ($sortedExpectedClassifications -join '|')) {
        Add-Failure "Policy schema must expose exactly the five reviewed transition classifications"
    }
}

$edgePolicyById = @{}
$graphDefaultByHash = @{}
$unreviewedPolicyCount = 0
$approvedPolicyCount = 0
$graphDefaultAppliedEdgeCount = 0
$graphUnreviewedPolicyCount = 0
$graphApprovedPolicyCount = 0
if ($null -ne $policy) {
    if ([string](Get-PropertyValue $policy 'schema') -ne 'nikami-fnv-seamless-exterior-policy/v1') {
        Add-Failure "Policy has unexpected schema '$([string](Get-PropertyValue $policy 'schema'))'"
    }

    $scope = Get-PropertyValue $policy 'scope'
    if ([string](Get-PropertyValue $scope 'edition') -ne 'Fallout: New Vegas Ultimate Edition') {
        Add-Failure "Policy scope must be Fallout: New Vegas Ultimate Edition"
    }
    if ([string](Get-PropertyValue $scope 'language') -ne 'English') {
        Add-Failure "Policy scope must be English"
    }
    if ([string](Get-PropertyValue $scope 'edgeIdentity') -ne 'xtel:<source-reference-load-order-form-id>') {
        Add-Failure "Policy edge identity must be based on the source XTEL reference FormID"
    }
    $loadOrder = @((Get-PropertyValue $scope 'frozenLoadOrder') | ForEach-Object { [string]$_ })
    if ($loadOrder.Count -eq 0) {
        Add-Failure "Policy scope has no frozen load order"
    }
    elseif (@($loadOrder | Select-Object -Unique).Count -ne $loadOrder.Count) {
        Add-Failure "Policy frozen load order contains duplicate plugin names"
    }

    $defaults = Get-PropertyValue $policy 'defaults'
    if ([string](Get-PropertyValue $defaults 'classification') -ne 'unreviewed') {
        Add-Failure "Policy default classification must stay unreviewed"
    }
    if ([string](Get-PropertyValue $defaults 'activation') -ne 'retain-authored-transition') {
        Add-Failure "Policy default activation must retain the authored transition"
    }
    if (-not (Test-ExactBoolean (Get-PropertyValue $defaults 'walkThrough') $false)) {
        Add-Failure "Policy default walkThrough must be false"
    }
    if (-not (Test-ExactBoolean (Get-PropertyValue $defaults 'shippingEligible') $false)) {
        Add-Failure "Policy default shippingEligible must be false"
    }

    foreach ($graphDefault in @((Get-PropertyValue $policy 'graphDefaults'))) {
        $graphSchemaValue = [string](Get-PropertyValue $graphDefault 'graphSchema')
        $graphSha = [string](Get-PropertyValue $graphDefault 'graphSha256')
        $classification = [string](Get-PropertyValue $graphDefault 'classification')
        $reviewState = [string](Get-PropertyValue $graphDefault 'reviewState')
        $walkThroughValue = Get-PropertyValue $graphDefault 'walkThrough'
        $notes = [string](Get-PropertyValue $graphDefault 'notes')
        if ($graphSchemaValue -ne 'nikami-fnv-exterior-transition-graph/v1') {
            Add-Failure "Policy graph default has unexpected graphSchema '$graphSchemaValue'"
        }
        if ($graphSha -notmatch '^[0-9a-f]{64}$') {
            Add-Failure "Policy graph default has invalid graphSha256 '$graphSha'"
            continue
        }
        if ($graphDefaultByHash.ContainsKey($graphSha)) {
            Add-Failure "Policy contains duplicate graph default for SHA '$graphSha'"
        }
        else {
            $graphDefaultByHash[$graphSha] = $graphDefault
        }
        if ($classification -ne 'unreviewed' -or $reviewState -ne 'unreviewed') {
            Add-Failure "Policy graph default '$graphSha' must remain unreviewed"
        }
        if (-not (Test-ExactBoolean $walkThroughValue $false)) {
            Add-Failure "Policy graph default '$graphSha' may not enable walkThrough"
        }
        if ([string]::IsNullOrWhiteSpace($notes)) {
            Add-Failure "Policy graph default '$graphSha' has no review notes"
        }
    }

    $allowedClassifications = @(
        'same-worldspace-boundary',
        'outdoor-portal',
        'real-interior-door',
        'scripted-or-unsafe',
        'unreviewed'
    )
    foreach ($edgePolicy in @((Get-PropertyValue $policy 'edges'))) {
        $edgeId = [string](Get-PropertyValue $edgePolicy 'edgeId')
        $sourceRef = [string](Get-PropertyValue $edgePolicy 'sourceRef')
        $classification = [string](Get-PropertyValue $edgePolicy 'classification')
        $reviewState = [string](Get-PropertyValue $edgePolicy 'reviewState')
        $walkThroughValue = Get-PropertyValue $edgePolicy 'walkThrough'
        $notes = [string](Get-PropertyValue $edgePolicy 'notes')

        if ($edgeId -notmatch '^xtel:0x[0-9a-f]{8}$') {
            Add-Failure "Policy edge has invalid edgeId '$edgeId'"
            continue
        }
        if (-not (Test-FormId $sourceRef)) {
            Add-Failure "Policy edge '$edgeId' has invalid sourceRef '$sourceRef'"
        }
        elseif ($edgeId -ne "xtel:$sourceRef") {
            Add-Failure "Policy edge '$edgeId' must use its sourceRef as the edge identity"
        }
        if ($edgePolicyById.ContainsKey($edgeId)) {
            Add-Failure "Policy contains duplicate edgeId '$edgeId'"
        }
        else {
            $edgePolicyById[$edgeId] = $edgePolicy
        }
        if ($allowedClassifications -notcontains $classification) {
            Add-Failure "Policy edge '$edgeId' has unsupported classification '$classification'"
        }
        if (@('unreviewed', 'reviewed', 'approved') -notcontains $reviewState) {
            Add-Failure "Policy edge '$edgeId' has unsupported reviewState '$reviewState'"
        }
        if ($walkThroughValue -isnot [bool]) {
            Add-Failure "Policy edge '$edgeId' walkThrough must be boolean"
        }
        if ([string]::IsNullOrWhiteSpace($notes)) {
            Add-Failure "Policy edge '$edgeId' has no review notes"
        }
        if ($classification -eq 'unreviewed') {
            ++$unreviewedPolicyCount
            if ($reviewState -ne 'unreviewed') {
                Add-Failure "Unreviewed policy edge '$edgeId' must use reviewState unreviewed"
            }
            if ($walkThroughValue -is [bool] -and [bool]$walkThroughValue) {
                Add-Failure "Unreviewed policy edge '$edgeId' may not enable walkThrough"
            }
        }
        if ($reviewState -eq 'approved') {
            ++$approvedPolicyCount
        }
        if ($walkThroughValue -is [bool] -and [bool]$walkThroughValue -and
            ($classification -ne 'outdoor-portal' -or $reviewState -ne 'approved')) {
            Add-Failure "walkThrough policy edge '$edgeId' must be an approved outdoor portal"
        }
    }
}

$graphEdgeCount = 0
$graphUnresolvedCount = 0
if (-not [string]::IsNullOrWhiteSpace($graphFullPath)) {
    $graph = Read-JsonDocument -Path $graphFullPath -Label "exterior transition graph"
    if ($null -ne $graph) {
        if ([string](Get-PropertyValue $graph 'schema') -ne 'nikami-fnv-exterior-transition-graph/v1') {
            Add-Failure "Transition graph has unexpected schema '$([string](Get-PropertyValue $graph 'schema'))'"
        }
        $graphSource = Get-PropertyValue $graph 'source'
        if (-not [bool](Get-PropertyValue $graphSource 'completeOfficialSet')) {
            Add-Failure "Transition graph was not exported from the complete frozen official load order"
        }
        $configuredOrderMatchesFrozen = Get-PropertyValue $graphSource 'configuredContentOrderMatchesFrozen'
        if ($configuredOrderMatchesFrozen -is [bool] -and -not [bool]$configuredOrderMatchesFrozen) {
            Add-Warning "Graph selected the canonical official order from profile data roots, but the source profile itself has a different content order. It is not runtime proof until that profile is normalized."
        }

        $graphEdges = @((Get-PropertyValue $graph 'edges'))
        $graphEdgeCount = $graphEdges.Count
        $graphSha = [string](Get-PropertyValue $graph 'canonicalGraphSha256')
        if ($graphSha -notmatch '^[0-9a-f]{64}$') {
            Add-Failure "Transition graph has invalid canonicalGraphSha256 '$graphSha'"
        }
        $graphDefault = if ($graphDefaultByHash.ContainsKey($graphSha)) { $graphDefaultByHash[$graphSha] } else { $null }
        $generatedFrom = Get-PropertyValue $policy 'generatedFrom'
        if ($null -ne $generatedFrom -and [string](Get-PropertyValue $generatedFrom 'graphSha256') -ne $graphSha) {
            Add-Failure "Policy generatedFrom graph SHA does not match the supplied transition graph"
        }
        $seenGraphIds = @{}
        $unresolvedById = @{}
        foreach ($unresolved in @((Get-PropertyValue $graph 'unresolvedEdges'))) {
            $unresolvedId = [string](Get-PropertyValue $unresolved 'edgeId')
            if (-not [string]::IsNullOrWhiteSpace($unresolvedId)) {
                $unresolvedById[$unresolvedId] = $true
            }
        }
        $graphUnresolvedCount = $unresolvedById.Count

        foreach ($graphEdge in $graphEdges) {
            $edgeId = [string](Get-PropertyValue $graphEdge 'edgeId')
            $source = Get-PropertyValue $graphEdge 'source'
            $sourceRef = [string](Get-PropertyValue $source 'formId')
            if ($edgeId -notmatch '^xtel:0x[0-9a-f]{8}$') {
                Add-Failure "Transition graph edge has invalid edgeId '$edgeId'"
                continue
            }
            if ($seenGraphIds.ContainsKey($edgeId)) {
                Add-Failure "Transition graph contains duplicate edgeId '$edgeId'"
                continue
            }
            $seenGraphIds[$edgeId] = $true

            $isExplicitPolicy = $edgePolicyById.ContainsKey($edgeId)
            if ($isExplicitPolicy) {
                $edgePolicy = $edgePolicyById[$edgeId]
                if ([string](Get-PropertyValue $edgePolicy 'sourceRef') -ne $sourceRef) {
                    Add-Failure "Policy edge '$edgeId' sourceRef does not match the graph"
                }
            }
            elseif ($null -ne $graphDefault) {
                $edgePolicy = $graphDefault
                ++$graphDefaultAppliedEdgeCount
            }
            else {
                Add-Failure "Transition graph edge '$edgeId' has no explicit policy entry or matching fail-closed graph default"
                continue
            }

            $classification = [string](Get-PropertyValue $edgePolicy 'classification')
            $reviewState = [string](Get-PropertyValue $edgePolicy 'reviewState')
            if ($classification -eq 'unreviewed') {
                ++$graphUnreviewedPolicyCount
            }
            if ($reviewState -eq 'approved') {
                ++$graphApprovedPolicyCount
            }
            $hints = Get-PropertyValue $graphEdge 'classificationHints'
            $sourceExterior = [bool](Get-PropertyValue $hints 'sourceExterior')
            $destinationExterior = [bool](Get-PropertyValue $hints 'destinationExterior')
            $sameWorldspace = [bool](Get-PropertyValue $hints 'sameWorldspace')
            if ($classification -eq 'same-worldspace-boundary' -and
                (-not $sourceExterior -or -not $destinationExterior -or -not $sameWorldspace)) {
                Add-Failure "Policy edge '$edgeId' is not an exterior transition within one worldspace"
            }
            if ($classification -eq 'outdoor-portal' -and
                (-not $sourceExterior -or -not $destinationExterior)) {
                Add-Failure "Policy edge '$edgeId' is not an exterior-to-exterior portal"
            }
            if ($unresolvedById.ContainsKey($edgeId) -and
                $classification -notin @('unreviewed', 'scripted-or-unsafe')) {
                Add-Failure "Unresolved graph edge '$edgeId' may only remain unreviewed or scripted-or-unsafe"
            }
            if ($RequireReviewed -and ($classification -eq 'unreviewed' -or $reviewState -ne 'approved')) {
                Add-Failure "Release review requires approved policy for graph edge '$edgeId'"
            }
        }

        foreach ($policyEdgeId in $edgePolicyById.Keys) {
            if (-not $seenGraphIds.ContainsKey($policyEdgeId)) {
                Add-Failure "Policy edge '$policyEdgeId' is absent from the generated graph"
            }
        }
        if ($graphUnresolvedCount -gt 0) {
            Add-Warning "Graph retains $graphUnresolvedCount unresolved edge(s); they remain fail-closed until reviewed."
        }
    }
}
elseif ($RequireReviewed) {
    Add-Failure "-RequireReviewed requires -GraphPath so every exported edge is checked"
}

$report = [ordered]@{
    schema = 'nikami-fnv-seamless-exterior-contract-report/v1'
    status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
    policyPath = $policyFullPath
    schemaPath = $schemaFullPath
    graphPath = if ([string]::IsNullOrWhiteSpace($graphFullPath)) { $null } else { $graphFullPath }
    requireReviewed = [bool]$RequireReviewed
    counts = [ordered]@{
        explicitPolicyEdges = $edgePolicyById.Count
        graphDefaults = $graphDefaultByHash.Count
        inheritedGraphDefaultEdges = $graphDefaultAppliedEdgeCount
        unreviewedPolicyEdges = if ($graphEdgeCount -gt 0) { $graphUnreviewedPolicyCount } else { $unreviewedPolicyCount }
        approvedPolicyEdges = if ($graphEdgeCount -gt 0) { $graphApprovedPolicyCount } else { $approvedPolicyCount }
        graphEdges = $graphEdgeCount
        graphUnresolvedEdges = $graphUnresolvedCount
    }
    warnings = @($warnings)
    failures = @($failures)
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $reportFullPath = Resolve-RepoInputPath $ReportPath
    $reportDirectory = Split-Path -Parent $reportFullPath
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
        New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportFullPath -Encoding utf8
}

$report
if ($failures.Count -gt 0) {
    exit 1
}
