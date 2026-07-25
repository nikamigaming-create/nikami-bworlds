param(
    [string]$ContractPath,
    [string]$ReportPath,
    [switch]$ContractOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ContractPath)) {
    $ContractPath = Join-Path $PSScriptRoot "..\catalog\fnv-jam-4.6-full-proof-contract.json"
}

$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
}

function Has-Field {
    param($Object, [string]$Name)
    if ($null -eq $Object) {
        return $false
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-Field {
    param($Object, [string]$Name)
    if (-not (Has-Field $Object $Name)) {
        return $null
    }
    return $Object.PSObject.Properties[$Name].Value
}

function Get-Strings {
    param($Value)
    return @($Value | ForEach-Object { [string]$_ })
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        Add-Failure "$Label expected '$Expected', got '$Actual'"
    }
}

function Assert-True {
    param($Actual, [string]$Label)
    if ($Actual -isnot [bool] -or $Actual -ne $true) {
        Add-Failure "$Label must be true"
    }
}

function Assert-Zero {
    param($Actual, [string]$Label)
    if ($null -eq $Actual -or [double]$Actual -ne 0) {
        Add-Failure "$Label must be zero, got '$Actual'"
    }
}

function Read-Number {
    param($Object, [string]$Name, [string]$Context)
    if (-not (Has-Field $Object $Name)) {
        Add-Failure "$Context missing measurement '$Name'"
        return $null
    }
    try {
        return [double](Get-Field $Object $Name)
    }
    catch {
        Add-Failure "$Context measurement '$Name' is not numeric"
        return $null
    }
}

function Test-RelativeParity {
    param(
        $Retail,
        $OpenMW,
        [double]$Tolerance,
        [string]$Label
    )
    if ($null -eq $Retail -or $null -eq $OpenMW) {
        return
    }
    $denominator = [Math]::Max([Math]::Abs([double]$Retail), 0.000001)
    $relativeError = [Math]::Abs([double]$OpenMW - [double]$Retail) / $denominator
    if ($relativeError -gt $Tolerance) {
        Add-Failure "$Label relative error $relativeError exceeds $Tolerance"
    }
}

function Resolve-EvidencePath {
    param([string]$Path, [string]$BaseDirectory)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Test-EvidenceFile {
    param(
        $Evidence,
        [string]$BaseDirectory,
        [string]$Context
    )
    $path = [string](Get-Field $Evidence "path")
    $sha256 = [string](Get-Field $Evidence "sha256")
    if ([string]::IsNullOrWhiteSpace($path)) {
        Add-Failure "$Context missing path"
        return $null
    }
    if ($sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        Add-Failure "$Context missing a valid SHA-256"
    }
    $resolved = Resolve-EvidencePath $path $BaseDirectory
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        Add-Failure "$Context file does not exist: $resolved"
        return $resolved
    }
    if ((Get-Item -LiteralPath $resolved).Length -le 0) {
        Add-Failure "$Context file is empty: $resolved"
    }
    if ($sha256 -match '^[0-9A-Fa-f]{64}$') {
        $actualHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
        if ($actualHash -ne $sha256.ToUpperInvariant()) {
            Add-Failure "$Context SHA-256 mismatch for $resolved"
        }
    }
    return $resolved
}

if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
    throw "Missing JAM proof contract: $ContractPath"
}

try {
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
}
catch {
    throw "Invalid JAM proof contract JSON at ${ContractPath}: $($_.Exception.Message)"
}
$resolvedContractPath = (Resolve-Path -LiteralPath $ContractPath).Path
$contractDirectory = Split-Path -Parent $resolvedContractPath

Assert-Equal (Get-Field $contract "schemaVersion") 1 "contract.schemaVersion"
Assert-Equal (Get-Field $contract "contractId") "fnv-jam-4.6-full-parity-v1" "contract.contractId"

$staticFootprintSpec = Get-Field $contract "staticFootprint"
$staticFootprintPath = Resolve-EvidencePath `
    ([string](Get-Field $staticFootprintSpec "path")) $contractDirectory
$staticFootprint = $null
if ($null -eq $staticFootprintPath -or
    -not (Test-Path -LiteralPath $staticFootprintPath -PathType Leaf)) {
    Add-Failure "Missing generated static footprint: $staticFootprintPath"
}
else {
    try {
        $staticFootprint = Get-Content -LiteralPath $staticFootprintPath -Raw | ConvertFrom-Json
    }
    catch {
        Add-Failure "Invalid static footprint JSON at ${staticFootprintPath}: $($_.Exception.Message)"
    }
}

if ($null -ne $staticFootprint) {
    Assert-Equal (Get-Field $staticFootprint "schemaVersion") `
        (Get-Field $staticFootprintSpec "schemaVersion") "staticFootprint.schemaVersion"
    Assert-Equal (Get-Field $staticFootprint "contractId") `
        (Get-Field $contract "contractId") "staticFootprint.contractId"
    $footprintProvenance = Get-Field $staticFootprint "provenance"
    $contractFixture = Get-Field $contract "fixture"
    Assert-Equal ([string](Get-Field $footprintProvenance "archiveSha256")).ToUpperInvariant() `
        ([string](Get-Field $contractFixture "archiveSha256")).ToUpperInvariant() `
        "staticFootprint.provenance.archiveSha256"
    Assert-Equal ([string](Get-Field $footprintProvenance "pluginSha256")).ToUpperInvariant() `
        ([string](Get-Field $contractFixture "pluginSha256")).ToUpperInvariant() `
        "staticFootprint.provenance.pluginSha256"
    Assert-Equal (Get-Field (Get-Field $staticFootprint "sctx") "count") `
        (Get-Field $contractFixture "expectedSctxCount") "staticFootprint.sctx.count"

    $footprintProviders = @{}
    foreach ($provider in @((Get-Field $staticFootprint "providers"))) {
        $providerId = [string](Get-Field $provider "id")
        if (-not [string]::IsNullOrWhiteSpace($providerId)) {
            $footprintProviders[$providerId] = $provider
        }
    }
    $expectedProviderCounts = Get-Field $staticFootprintSpec "providerCounts"
    foreach ($providerProperty in $expectedProviderCounts.PSObject.Properties) {
        $providerId = $providerProperty.Name
        if (-not $footprintProviders.ContainsKey($providerId)) {
            Add-Failure "staticFootprint.providers missing '$providerId'"
            continue
        }
        $provider = $footprintProviders[$providerId]
        Assert-Equal (Get-Field $provider "activeUniqueSymbols") `
            (Get-Field $providerProperty.Value "activeUniqueSymbols") `
            "staticFootprint.providers[$providerId].activeUniqueSymbols"
        Assert-Equal (Get-Field $provider "activeOccurrences") `
            (Get-Field $providerProperty.Value "activeOccurrences") `
            "staticFootprint.providers[$providerId].activeOccurrences"
    }

    $expectedSemantics = Get-Field $staticFootprintSpec "languageSemantics"
    $actualSemantics = Get-Field $staticFootprint "languageSemantics"
    foreach ($property in $expectedSemantics.PSObject.Properties) {
        Assert-Equal (Get-Field $actualSemantics $property.Name) $property.Value `
            "staticFootprint.languageSemantics.$($property.Name)"
    }

    $expectedAssets = Get-Field $staticFootprintSpec "assets"
    $actualAssets = Get-Field $staticFootprint "assets"
    foreach ($property in $expectedAssets.PSObject.Properties) {
        Assert-Equal (Get-Field $actualAssets $property.Name) $property.Value `
            "staticFootprint.assets.$($property.Name)"
    }
    if (@((Get-Field $staticFootprint "providerOwnershipAmbiguities")).Count -ne 0) {
        Add-Failure "staticFootprint has ambiguous provider ownership"
    }
}

$requiredLayerIds = @("xnvse-core", "jip-ln", "johnnyguitar", "knvse")
$contractLayers = @((Get-Field $contract "layers"))
$contractLayerIds = Get-Strings @($contractLayers | ForEach-Object { Get-Field $_ "id" })
foreach ($layerId in $requiredLayerIds) {
    if ($contractLayerIds -notcontains $layerId) {
        Add-Failure "Contract missing required layer '$layerId'"
    }
}
if (@($contractLayerIds | Select-Object -Unique).Count -ne $contractLayerIds.Count) {
    Add-Failure "Contract layer IDs must be unique"
}

$requiredScenarioIds = @(
    "JDC.dynamic-crosshair",
    "JHM.hit-marker",
    "JHI.hit-indicator",
    "JLM.loot-menu",
    "JVO.visual-objectives",
    "JWH.weapon-wheel",
    "JBT.bullet-time",
    "JHB.hold-breath",
    "JVS.sprint",
    "JAM.configuration-persistence",
    "PROVIDER.knvse-animation"
)
$contractScenarios = @((Get-Field $contract "scenarios"))
$contractScenarioIds = Get-Strings @($contractScenarios | ForEach-Object { Get-Field $_ "id" })
foreach ($scenarioId in $requiredScenarioIds) {
    if ($contractScenarioIds -notcontains $scenarioId) {
        Add-Failure "Contract missing required scenario '$scenarioId'"
    }
}
if (@($contractScenarioIds | Select-Object -Unique).Count -ne $contractScenarioIds.Count) {
    Add-Failure "Contract scenario IDs must be unique"
}

$measurementRequirements = Get-Field $contract "measurementRequirements"
foreach ($scenario in $contractScenarios) {
    $scenarioId = [string](Get-Field $scenario "id")
    $states = Get-Strings (Get-Field $scenario "visibleStates")
    $assertions = Get-Strings (Get-Field $scenario "assertions")
    $layers = Get-Strings (Get-Field $scenario "requiredLayers")
    if ($states.Count -eq 0) {
        Add-Failure "Contract scenario '$scenarioId' has no visible states"
    }
    if ($assertions.Count -eq 0) {
        Add-Failure "Contract scenario '$scenarioId' has no assertions"
    }
    foreach ($layer in $layers) {
        if ($contractLayerIds -notcontains $layer) {
            Add-Failure "Contract scenario '$scenarioId' references unknown layer '$layer'"
        }
    }
    if (-not (Has-Field $measurementRequirements $scenarioId)) {
        Add-Failure "Contract scenario '$scenarioId' has no measurement requirements"
    }
}

$crosshairContract = $contractScenarios | Where-Object { (Get-Field $_ "id") -eq "JDC.dynamic-crosshair" } | Select-Object -First 1
$crosshairMustShow = @(
    "weapon-ready-idle",
    "walking-spread-expanded",
    "running-or-firing-spread-expanded",
    "stopped-spread-recovered",
    "aim-down-sights-mode",
    "interactable-prompt-coexistence",
    "hostile-system-color"
)
$crosshairStates = Get-Strings (Get-Field $crosshairContract "visibleStates")
foreach ($state in $crosshairMustShow) {
    if ($crosshairStates -notcontains $state) {
        Add-Failure "Crosshair contract missing visible state '$state'"
    }
}

$capturePolicy = Get-Field $contract "capturePolicy"
Assert-True (Get-Field $capturePolicy "continuousRawCaptureRequired") "capturePolicy.continuousRawCaptureRequired"
Assert-Zero (Get-Field $capturePolicy "syntheticGameplayFramesAllowed") "capturePolicy.syntheticGameplayFramesAllowed"
Assert-Zero (Get-Field $capturePolicy "unlabelledSplicesAllowed") "capturePolicy.unlabelledSplicesAllowed"

if ($failures.Count -gt 0) {
    Write-Host "JAM proof contract validation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

if ($ContractOnly) {
    $contractScenarios |
        Select-Object @{Name = "Scenario"; Expression = { Get-Field $_ "id" } },
            @{Name = "VisibleStates"; Expression = { @(Get-Field $_ "visibleStates").Count } },
            @{Name = "Layers"; Expression = { (Get-Strings (Get-Field $_ "requiredLayers")) -join ", " } } |
        Format-Table -AutoSize
    Write-Host "JAM 4.6 full-proof contract validation passed."
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    Add-Failure "ReportPath is required unless -ContractOnly is used"
}
elseif (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    Add-Failure "Proof report does not exist: $ReportPath"
}

if ($failures.Count -gt 0) {
    Write-Host "JAM full-proof validation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

$resolvedReportPath = (Resolve-Path -LiteralPath $ReportPath).Path
$reportDirectory = Split-Path -Parent $resolvedReportPath
try {
    $report = Get-Content -LiteralPath $resolvedReportPath -Raw | ConvertFrom-Json
}
catch {
    throw "Invalid proof report JSON at ${resolvedReportPath}: $($_.Exception.Message)"
}

Assert-Equal (Get-Field $report "schemaVersion") 1 "report.schemaVersion"
Assert-Equal (Get-Field $report "contractId") (Get-Field $contract "contractId") "report.contractId"
Assert-True (Get-Field $report "passed") "report.passed"

$fixture = Get-Field $contract "fixture"
$provenance = Get-Field $report "provenance"
Assert-Equal ([string](Get-Field $provenance "archiveSha256")).ToUpperInvariant() `
    ([string](Get-Field $fixture "archiveSha256")).ToUpperInvariant() "provenance.archiveSha256"
Assert-Equal ([string](Get-Field $provenance "pluginSha256")).ToUpperInvariant() `
    ([string](Get-Field $fixture "pluginSha256")).ToUpperInvariant() "provenance.pluginSha256"
Assert-Equal (Get-Field $provenance "dllCount") (Get-Field $fixture "allowedNativeDllCount") "provenance.dllCount"
if ((Get-Field $provenance "pluginModified") -isnot [bool] -or (Get-Field $provenance "pluginModified")) {
    Add-Failure "provenance.pluginModified must be false"
}

$runtime = Get-Field $report "runtime"
$sctx = Get-Field $runtime "sctx"
Assert-Equal (Get-Field $sctx "discovered") (Get-Field $fixture "expectedSctxCount") "runtime.sctx.discovered"
Assert-Equal (Get-Field $sctx "parsed") (Get-Field $fixture "expectedSctxCount") "runtime.sctx.parsed"
Assert-Equal (Get-Field $sctx "compileErrors") 0 "runtime.sctx.compileErrors"
Assert-Zero (Get-Field $runtime "unknownCommandCount") "runtime.unknownCommandCount"
Assert-Zero (Get-Field $runtime "fallbackStubDispatchCount") "runtime.fallbackStubDispatchCount"
Assert-Zero (Get-Field $runtime "failedEventRegistrationCount") "runtime.failedEventRegistrationCount"
Assert-Zero (Get-Field $runtime "failedSerializationRoundTripCount") "runtime.failedSerializationRoundTripCount"

$coverageRows = @((Get-Field $runtime "commandCoverage"))
$coverageByProvider = @{}
foreach ($row in $coverageRows) {
    $provider = [string](Get-Field $row "provider")
    if ([string]::IsNullOrWhiteSpace($provider)) {
        Add-Failure "runtime.commandCoverage has a row without provider"
        continue
    }
    if ($coverageByProvider.ContainsKey($provider)) {
        Add-Failure "runtime.commandCoverage duplicates provider '$provider'"
        continue
    }
    $coverageByProvider[$provider] = $row
}

$referenceAudit = Get-Field (Get-Field $contract "runtimeGates") "activeUniqueSymbolAudit"
foreach ($providerProperty in $referenceAudit.PSObject.Properties) {
    $provider = $providerProperty.Name
    if (-not $coverageByProvider.ContainsKey($provider)) {
        Add-Failure "runtime.commandCoverage missing provider '$provider'"
        continue
    }
    $row = $coverageByProvider[$provider]
    Assert-Equal (Get-Field $row "staticUniqueSymbols") $providerProperty.Value `
        "runtime.commandCoverage[$provider].staticUniqueSymbols"
    $unsupported = Get-Strings (Get-Field $row "unsupportedCommandIds")
    if ($unsupported.Count -gt 0) {
        Add-Failure "runtime.commandCoverage[$provider] has unsupported commands: $($unsupported -join ', ')"
    }
    $requiredCommands = Get-Strings (Get-Field $row "requiredCommandIds")
    $executedCommands = Get-Strings (Get-Field $row "executedCommandIds")
    $unreachableRows = @((Get-Field $row "unreachableCommands"))
    $unreachableIds = Get-Strings @($unreachableRows | ForEach-Object { Get-Field $_ "id" })
    foreach ($commandId in $requiredCommands) {
        if ($executedCommands -notcontains $commandId -and $unreachableIds -notcontains $commandId) {
            Add-Failure "runtime.commandCoverage[$provider] did not execute or justify '$commandId'"
        }
    }
    foreach ($unreachable in $unreachableRows) {
        foreach ($field in @("id", "reason", "configurationEvidenceEventId")) {
            if ([string]::IsNullOrWhiteSpace([string](Get-Field $unreachable $field))) {
                Add-Failure "runtime.commandCoverage[$provider] unreachable command missing '$field'"
            }
        }
    }
}

if ($coverageByProvider.ContainsKey("knvse")) {
    $knvseProbeCommands = Get-Strings (Get-Field $coverageByProvider["knvse"] "probeCommandIds")
    if ($knvseProbeCommands.Count -eq 0) {
        Add-Failure "runtime.commandCoverage[knvse] must list the separately labelled probe commands"
    }
}

$capture = Get-Field $report "capture"
Assert-True (Get-Field $capture "continuousRawCapture") "capture.continuousRawCapture"
Assert-True (Get-Field $capture "overlayTelemetryBacked") "capture.overlayTelemetryBacked"
Assert-Zero (Get-Field $capture "syntheticGameplayFrames") "capture.syntheticGameplayFrames"
Assert-Zero (Get-Field $capture "unlabelledSplices") "capture.unlabelledSplices"
$overlayFields = Get-Strings (Get-Field $capture "overlayFields")
foreach ($field in (Get-Strings (Get-Field $capturePolicy "requiredOverlayFields"))) {
    if ($overlayFields -notcontains $field) {
        Add-Failure "capture.overlayFields missing '$field'"
    }
}

$artifacts = @((Get-Field $report "artifacts"))
$artifactByKind = @{}
$resolvedArtifactPaths = @{}
foreach ($artifact in $artifacts) {
    $kind = [string](Get-Field $artifact "kind")
    if ([string]::IsNullOrWhiteSpace($kind)) {
        Add-Failure "Artifact has no kind"
        continue
    }
    if ($artifactByKind.ContainsKey($kind)) {
        Add-Failure "Duplicate artifact kind '$kind'"
        continue
    }
    $artifactByKind[$kind] = $artifact
    $resolvedArtifactPaths[$kind] = Test-EvidenceFile $artifact $reportDirectory "artifact[$kind]"
}
foreach ($kind in (Get-Strings (Get-Field $contract "requiredArtifacts"))) {
    if (-not $artifactByKind.ContainsKey($kind)) {
        Add-Failure "Missing required artifact '$kind'"
    }
}

$telemetryById = @{}
if ($resolvedArtifactPaths.ContainsKey("telemetry-jsonl")) {
    $telemetryPath = $resolvedArtifactPaths["telemetry-jsonl"]
    if ($null -ne $telemetryPath -and (Test-Path -LiteralPath $telemetryPath -PathType Leaf)) {
        $lineNumber = 0
        foreach ($line in (Get-Content -LiteralPath $telemetryPath)) {
            $lineNumber += 1
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $event = $line | ConvertFrom-Json
            }
            catch {
                Add-Failure "telemetry-jsonl line $lineNumber is invalid JSON"
                continue
            }
            foreach ($field in @(
                "id", "timestamp", "scenarioId", "side", "sourceScript",
                "provider", "commandOrEvent", "enginePath", "state"
            )) {
                if (-not (Has-Field $event $field)) {
                    Add-Failure "telemetry-jsonl line $lineNumber missing '$field'"
                }
            }
            $eventId = [string](Get-Field $event "id")
            if ([string]::IsNullOrWhiteSpace($eventId)) {
                continue
            }
            if ($telemetryById.ContainsKey($eventId)) {
                Add-Failure "telemetry-jsonl duplicates event id '$eventId'"
            }
            else {
                $telemetryById[$eventId] = $event
            }
        }
    }
}
if ($telemetryById.Count -eq 0) {
    Add-Failure "No valid telemetry events were loaded"
}

$attestations = @((Get-Field $report "layerAttestations"))
$attestationById = @{}
foreach ($attestation in $attestations) {
    $id = [string](Get-Field $attestation "id")
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        $attestationById[$id] = $attestation
    }
}
foreach ($layerId in $requiredLayerIds) {
    if (-not $attestationById.ContainsKey($layerId)) {
        Add-Failure "Missing layer attestation '$layerId'"
        continue
    }
    $attestation = $attestationById[$layerId]
    Assert-True (Get-Field $attestation "passed") "layerAttestations[$layerId].passed"
    Assert-True (Get-Field $attestation "visibleInVideo") "layerAttestations[$layerId].visibleInVideo"
    $eventIds = Get-Strings (Get-Field $attestation "telemetryEventIds")
    $nativePaths = Get-Strings (Get-Field $attestation "nativeEnginePaths")
    if ($eventIds.Count -eq 0) {
        Add-Failure "layerAttestations[$layerId] has no telemetryEventIds"
    }
    if ($nativePaths.Count -eq 0) {
        Add-Failure "layerAttestations[$layerId] has no nativeEnginePaths"
    }
    foreach ($eventId in $eventIds) {
        if (-not $telemetryById.ContainsKey($eventId)) {
            Add-Failure "layerAttestations[$layerId] references missing telemetry event '$eventId'"
        }
    }
}

$reportScenarios = @((Get-Field $report "scenarios"))
$reportScenarioById = @{}
foreach ($scenario in $reportScenarios) {
    $id = [string](Get-Field $scenario "id")
    if ([string]::IsNullOrWhiteSpace($id)) {
        Add-Failure "Report scenario has no id"
        continue
    }
    if ($reportScenarioById.ContainsKey($id)) {
        Add-Failure "Report duplicates scenario '$id'"
        continue
    }
    $reportScenarioById[$id] = $scenario
}

$minimumScenarioSeconds = [double](Get-Field $capturePolicy "minimumScenarioSeconds")
$requiredStillPhases = Get-Strings (Get-Field $capturePolicy "requiredStillPhases")
$requiredStillSide = [string](Get-Field $capturePolicy "requiredStillSide")

foreach ($contractScenario in $contractScenarios) {
    $scenarioId = [string](Get-Field $contractScenario "id")
    if (-not $reportScenarioById.ContainsKey($scenarioId)) {
        Add-Failure "Report missing scenario '$scenarioId'"
        continue
    }
    $scenario = $reportScenarioById[$scenarioId]
    Assert-True (Get-Field $scenario "passed") "scenarios[$scenarioId].passed"

    $executedLayers = Get-Strings (Get-Field $scenario "executedLayers")
    foreach ($layer in (Get-Strings (Get-Field $contractScenario "requiredLayers"))) {
        if ($executedLayers -notcontains $layer) {
            Add-Failure "scenarios[$scenarioId].executedLayers missing '$layer'"
        }
    }

    $video = Get-Field $scenario "video"
    foreach ($videoSide in @("retail", "openmw", "sideBySide")) {
        $interval = Get-Field $video $videoSide
        $start = Read-Number $interval "startSeconds" "scenarios[$scenarioId].video.$videoSide"
        $end = Read-Number $interval "endSeconds" "scenarios[$scenarioId].video.$videoSide"
        if ($null -ne $start -and $null -ne $end) {
            if (($end - $start) -lt $minimumScenarioSeconds) {
                Add-Failure "scenarios[$scenarioId].video.$videoSide is shorter than $minimumScenarioSeconds seconds"
            }
        }
    }

    $scenarioEventIds = Get-Strings (Get-Field $scenario "telemetryEventIds")
    if ($scenarioEventIds.Count -eq 0) {
        Add-Failure "scenarios[$scenarioId] has no telemetryEventIds"
    }
    $scenarioEvents = @()
    foreach ($eventId in $scenarioEventIds) {
        if (-not $telemetryById.ContainsKey($eventId)) {
            Add-Failure "scenarios[$scenarioId] references missing telemetry event '$eventId'"
            continue
        }
        $event = $telemetryById[$eventId]
        $scenarioEvents += $event
        if ((Get-Field $event "scenarioId") -ne $scenarioId) {
            Add-Failure "Telemetry event '$eventId' belongs to '$((Get-Field $event 'scenarioId'))', not '$scenarioId'"
        }
    }
    foreach ($sideName in @("retail", "openmw")) {
        if (@($scenarioEvents | Where-Object { (Get-Field $_ "side") -eq $sideName }).Count -eq 0) {
            Add-Failure "scenarios[$scenarioId] has no '$sideName' telemetry event"
        }
    }
    foreach ($layer in (Get-Strings (Get-Field $contractScenario "requiredLayers"))) {
        $layerEvents = @($scenarioEvents | Where-Object {
            (Get-Field $_ "provider") -eq $layer -or
                (Get-Strings (Get-Field $_ "layers")) -contains $layer
        })
        if ($layerEvents.Count -eq 0) {
            Add-Failure "scenarios[$scenarioId] has no telemetry event proving layer '$layer'"
        }
    }

    $stills = @((Get-Field $scenario "stills"))
    foreach ($phase in $requiredStillPhases) {
        $still = $stills | Where-Object {
            (Get-Field $_ "phase") -eq $phase -and (Get-Field $_ "side") -eq $requiredStillSide
        } | Select-Object -First 1
        if ($null -eq $still) {
            Add-Failure "scenarios[$scenarioId] missing $requiredStillSide '$phase' still"
        }
        else {
            [void](Test-EvidenceFile $still $reportDirectory "scenarios[$scenarioId].stills[$phase]")
        }
    }

    $expectedAssertions = Get-Strings (Get-Field $contractScenario "assertions")
    $assertionResults = @((Get-Field $scenario "assertionResults"))
    foreach ($expectedAssertion in $expectedAssertions) {
        $result = $assertionResults | Where-Object {
            (Get-Field $_ "assertion") -eq $expectedAssertion
        } | Select-Object -First 1
        if ($null -eq $result) {
            Add-Failure "scenarios[$scenarioId] missing assertion result: $expectedAssertion"
            continue
        }
        Assert-True (Get-Field $result "passed") "scenarios[$scenarioId] assertion"
        $resultEventIds = Get-Strings (Get-Field $result "telemetryEventIds")
        if ($resultEventIds.Count -eq 0) {
            Add-Failure "scenarios[$scenarioId] assertion has no telemetryEventIds"
        }
        foreach ($eventId in $resultEventIds) {
            if (-not $telemetryById.ContainsKey($eventId)) {
                Add-Failure "scenarios[$scenarioId] assertion references missing telemetry event '$eventId'"
            }
        }
    }

    $requiredStates = Get-Strings (Get-Field $contractScenario "visibleStates")
    $requiredMeasurements = Get-Strings (Get-Field $measurementRequirements $scenarioId)
    foreach ($sideName in @("retail", "openmw")) {
        $side = Get-Field $scenario $sideName
        Assert-True (Get-Field $side "passed") "scenarios[$scenarioId].$sideName.passed"
        $visibleStates = Get-Strings (Get-Field $side "visibleStates")
        foreach ($state in $requiredStates) {
            if ($visibleStates -notcontains $state) {
                Add-Failure "scenarios[$scenarioId].$sideName.visibleStates missing '$state'"
            }
        }
        $measurements = Get-Field $side "measurements"
        foreach ($measurement in $requiredMeasurements) {
            if (-not (Has-Field $measurements $measurement)) {
                Add-Failure "scenarios[$scenarioId].$sideName.measurements missing '$measurement'"
            }
        }
    }
}

function Get-ScenarioMeasurements {
    param([string]$ScenarioId, [string]$Side)
    if (-not $reportScenarioById.ContainsKey($ScenarioId)) {
        return $null
    }
    return Get-Field (Get-Field $reportScenarioById[$ScenarioId] $Side) "measurements"
}

foreach ($sideName in @("retail", "openmw")) {
    $m = Get-ScenarioMeasurements "JDC.dynamic-crosshair" $sideName
    if ($null -ne $m) {
        $idle = Read-Number $m "idleReticleExtentPixels" "JDC.$sideName"
        $walking = Read-Number $m "walkingReticleExtentPixels" "JDC.$sideName"
        $active = Read-Number $m "activeReticleExtentPixels" "JDC.$sideName"
        $recovered = Read-Number $m "recoveredReticleExtentPixels" "JDC.$sideName"
        if ($null -ne $idle -and $null -ne $walking -and $walking -le ($idle * 1.05)) {
            Add-Failure "JDC.$sideName walking reticle did not expand by at least five percent"
        }
        if ($null -ne $idle -and $null -ne $active -and $active -le ($idle * 1.05)) {
            Add-Failure "JDC.$sideName active reticle did not expand by at least five percent"
        }
        if ($null -ne $idle -and $null -ne $recovered) {
            $recoveryTolerance = [Math]::Max($idle * 0.10, 1.0)
            if ([Math]::Abs($recovered - $idle) -gt $recoveryTolerance) {
                Add-Failure "JDC.$sideName reticle did not recover to idle extent"
            }
        }
        foreach ($flag in @("interactablePromptVisible", "hostileSystemColor")) {
            Assert-True (Get-Field $m $flag) "JDC.$sideName.$flag"
        }
    }

    $m = Get-ScenarioMeasurements "JHM.hit-marker" $sideName
    if ($null -ne $m) {
        foreach ($field in @("normalHitHealthDelta", "headshotOrCriticalHealthDelta", "killHealthDelta", "markerDisplaySeconds")) {
            $value = Read-Number $m $field "JHM.$sideName"
            if ($null -ne $value -and $value -le 0) {
                Add-Failure "JHM.$sideName.$field must be greater than zero"
            }
        }
    }

    $m = Get-ScenarioMeasurements "JHI.hit-indicator" $sideName
    if ($null -ne $m) {
        foreach ($field in @("frontAngularErrorDegrees", "rightAngularErrorDegrees", "rearAngularErrorDegrees", "leftAngularErrorDegrees")) {
            $value = Read-Number $m $field "JHI.$sideName"
            if ($null -ne $value -and [Math]::Abs($value) -gt 15) {
                Add-Failure "JHI.$sideName.$field exceeds 15 degrees"
            }
        }
        $healthDelta = Read-Number $m "totalPlayerHealthDelta" "JHI.$sideName"
        if ($null -ne $healthDelta -and $healthDelta -le 0) {
            Add-Failure "JHI.$sideName must record real player health loss"
        }
    }

    $m = Get-ScenarioMeasurements "JLM.loot-menu" $sideName
    if ($null -ne $m) {
        Assert-Zero (Get-Field $m "duplicateTransferCount") "JLM.$sideName.duplicateTransferCount"
        $containerBefore = Read-Number $m "containerItemCountBefore" "JLM.$sideName"
        $containerAfter = Read-Number $m "containerItemCountAfter" "JLM.$sideName"
        $playerBefore = Read-Number $m "playerItemCountBefore" "JLM.$sideName"
        $playerAfter = Read-Number $m "playerItemCountAfter" "JLM.$sideName"
        if ($null -ne $containerBefore -and $null -ne $containerAfter -and $containerAfter -ge $containerBefore) {
            Add-Failure "JLM.$sideName container count did not decrease"
        }
        if ($null -ne $playerBefore -and $null -ne $playerAfter -and $playerAfter -le $playerBefore) {
            Add-Failure "JLM.$sideName player count did not increase"
        }
    }

    $m = Get-ScenarioMeasurements "JVO.visual-objectives" $sideName
    if ($null -ne $m) {
        $x0 = Read-Number $m "initialScreenX" "JVO.$sideName"
        $y0 = Read-Number $m "initialScreenY" "JVO.$sideName"
        $x1 = Read-Number $m "movedScreenX" "JVO.$sideName"
        $y1 = Read-Number $m "movedScreenY" "JVO.$sideName"
        if ($null -ne $x0 -and $null -ne $y0 -and $null -ne $x1 -and $null -ne $y1 -and
            [Math]::Abs($x1 - $x0) + [Math]::Abs($y1 - $y0) -lt 2) {
            Add-Failure "JVO.$sideName objective marker did not move on screen"
        }
    }

    $m = Get-ScenarioMeasurements "JWH.weapon-wheel" $sideName
    if ($null -ne $m) {
        Assert-Equal (Get-Field $m "equippedWeaponFormId") (Get-Field $m "selectedWeaponFormId") `
            "JWH.$sideName selected/equipped weapon"
        Assert-Equal (Get-Field $m "cancelledWeaponFormId") (Get-Field $m "selectedWeaponFormId") `
            "JWH.$sideName cancelled selection"
    }

    $m = Get-ScenarioMeasurements "JBT.bullet-time" $sideName
    if ($null -ne $m) {
        $normal = Read-Number $m "normalTimeScale" "JBT.$sideName"
        $active = Read-Number $m "activeTimeScale" "JBT.$sideName"
        $restored = Read-Number $m "restoredTimeScale" "JBT.$sideName"
        $resourceBefore = Read-Number $m "resourceBefore" "JBT.$sideName"
        $resourceAfter = Read-Number $m "resourceAfter" "JBT.$sideName"
        if ($null -ne $normal -and $null -ne $active -and $active -ge $normal) {
            Add-Failure "JBT.$sideName active time scale was not reduced"
        }
        if ($null -ne $normal -and $null -ne $restored -and [Math]::Abs($restored - $normal) -gt 0.001) {
            Add-Failure "JBT.$sideName normal time scale was not restored"
        }
        if ($null -ne $resourceBefore -and $null -ne $resourceAfter -and $resourceAfter -ge $resourceBefore) {
            Add-Failure "JBT.$sideName resource did not drain"
        }
    }

    $m = Get-ScenarioMeasurements "JHB.hold-breath" $sideName
    if ($null -ne $m) {
        $baseline = Read-Number $m "baselineSwayRms" "JHB.$sideName"
        $active = Read-Number $m "activeSwayRms" "JHB.$sideName"
        $restored = Read-Number $m "restoredSwayRms" "JHB.$sideName"
        $resourceBefore = Read-Number $m "resourceBefore" "JHB.$sideName"
        $resourceAfter = Read-Number $m "resourceAfter" "JHB.$sideName"
        if ($null -ne $baseline -and $null -ne $active -and $active -ge $baseline) {
            Add-Failure "JHB.$sideName sway was not reduced"
        }
        if ($null -ne $baseline -and $null -ne $restored -and
            [Math]::Abs($restored - $baseline) -gt [Math]::Max($baseline * 0.10, 0.001)) {
            Add-Failure "JHB.$sideName baseline sway was not restored"
        }
        if ($null -ne $resourceBefore -and $null -ne $resourceAfter -and $resourceAfter -ge $resourceBefore) {
            Add-Failure "JHB.$sideName resource did not drain"
        }
    }

    $m = Get-ScenarioMeasurements "JVS.sprint" $sideName
    if ($null -ne $m) {
        $baseline = Read-Number $m "baselineSpeed" "JVS.$sideName"
        $sprint = Read-Number $m "sprintSpeed" "JVS.$sideName"
        $ratio = Read-Number $m "speedRatio" "JVS.$sideName"
        $apBefore = Read-Number $m "actionPointsBefore" "JVS.$sideName"
        $apAfter = Read-Number $m "actionPointsAfter" "JVS.$sideName"
        if ($null -ne $baseline -and $baseline -le 0) {
            Add-Failure "JVS.$sideName baseline speed must be positive"
        }
        if ($null -ne $sprint -and $null -ne $baseline -and $sprint -le $baseline) {
            Add-Failure "JVS.$sideName sprint speed did not exceed baseline"
        }
        if ($null -ne $ratio -and ($ratio -lt 1.65 -or $ratio -gt 1.85)) {
            Add-Failure "JVS.$sideName speed ratio '$ratio' is outside 1.65..1.85"
        }
        if ($null -ne $apBefore -and $null -ne $apAfter -and $apAfter -ge $apBefore) {
            Add-Failure "JVS.$sideName Action Points did not drain"
        }
    }

    $m = Get-ScenarioMeasurements "JAM.configuration-persistence" $sideName
    if ($null -ne $m) {
        Assert-Equal (Get-Field $m "restoredSettingCount") (Get-Field $m "changedSettingCount") `
            "JAM.persistence.$sideName restored settings"
        Assert-Zero (Get-Field $m "duplicateEventCount") "JAM.persistence.$sideName.duplicateEventCount"
    }

    $m = Get-ScenarioMeasurements "PROVIDER.knvse-animation" $sideName
    if ($null -ne $m) {
        $overrideCount = Read-Number $m "overridePlayCount" "kNVSE.$sideName"
        $restoreCount = Read-Number $m "restorePlayCount" "kNVSE.$sideName"
        if ($null -ne $overrideCount -and $overrideCount -lt 1) {
            Add-Failure "kNVSE.$sideName override animation did not play"
        }
        if ($null -ne $restoreCount -and $restoreCount -lt 1) {
            Add-Failure "kNVSE.$sideName original animation was not restored"
        }
        Assert-Zero (Get-Field $m "leakedOverrideCount") "kNVSE.$sideName.leakedOverrideCount"
    }
}

$retailCrosshair = Get-ScenarioMeasurements "JDC.dynamic-crosshair" "retail"
$openmwCrosshair = Get-ScenarioMeasurements "JDC.dynamic-crosshair" "openmw"
foreach ($field in @(
    "idleReticleExtentPixels",
    "walkingReticleExtentPixels",
    "activeReticleExtentPixels",
    "recoveredReticleExtentPixels"
)) {
    Test-RelativeParity (Read-Number $retailCrosshair $field "JDC.retail") `
        (Read-Number $openmwCrosshair $field "JDC.openmw") 0.05 "JDC parity $field"
}

$retailSprint = Get-ScenarioMeasurements "JVS.sprint" "retail"
$openmwSprint = Get-ScenarioMeasurements "JVS.sprint" "openmw"
foreach ($field in @(
    "baselineSpeed",
    "sprintSpeed",
    "cloudDisplacementPerRealSecond",
    "cloudDisplacementPerSimulationSecond"
)) {
    Test-RelativeParity (Read-Number $retailSprint $field "JVS.retail") `
        (Read-Number $openmwSprint $field "JVS.openmw") 0.05 "JVS parity $field"
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "JAM 4.6 full-proof validation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "JAM 4.6 full compatibility proof passed." -ForegroundColor Green
Write-Host "Publishable claim: $((Get-Field $contract 'claimAllowedOnlyWhenPassed'))"
