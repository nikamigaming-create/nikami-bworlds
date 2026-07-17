param(
    [Parameter(Mandatory)]
    [string]$RunDirectory,
    [string]$RosterPath = 'catalog/fnv-goodsprings-actor-roster.json',
    [int]$SampleEvery = 30,
    [int]$BatchSettleFrames = 90,
    [int]$BatchAdvanceFrames = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Convert-FormId([string]$Form) {
    if ($Form -match '^0[xX]([0-9a-fA-F]+)$') {
        return [Convert]::ToUInt32($Matches[1], 16)
    }
    return [Convert]::ToUInt32($Form, 10)
}

function Write-OrValidateDeterministicJson([string]$Path, [object]$Document) {
    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    $json = ($Document | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($absolutePath)
        if ($existing -cne $json) {
            throw "Existing deterministic manifest does not match validated evidence: $absolutePath"
        }
        return $absolutePath
    }
    $parent = Split-Path -Parent $absolutePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Manifest parent directory does not exist: $parent"
    }
    $temporary = Join-Path $parent (
        '.{0}.{1}.{2}.tmp' -f [System.IO.Path]::GetFileName($absolutePath), $PID,
        [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporary, $absolutePath)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $absolutePath
}

if ($SampleEvery -lt 1 -or $BatchSettleFrames -lt 1 -or $BatchAdvanceFrames -lt 1) {
    throw 'SampleEvery, BatchSettleFrames, and BatchAdvanceFrames must be positive.'
}

$runDirectoryAbs = Resolve-RepoPath $RunDirectory
$rosterFile = Resolve-RepoPath $RosterPath
$rosterImporter = Join-Path $PSScriptRoot 'Import-FNVGoodspringsActorRoster.ps1'
$evidenceHelper = Join-Path $PSScriptRoot 'FNVRetailOracleEvidence.ps1'
$contactSheetScript = Join-Path $PSScriptRoot 'New-ScreenshotContactSheet.ps1'
foreach ($required in @($runDirectoryAbs, $rosterFile, $rosterImporter, $evidenceHelper, $contactSheetScript)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing finalization dependency: $required" }
}
if (-not (Test-Path -LiteralPath $runDirectoryAbs -PathType Container)) {
    throw "RunDirectory is not a directory: $runDirectoryAbs"
}

. $rosterImporter
. $evidenceHelper
$targets = @(Import-FNVGoodspringsActorRoster -Path $rosterFile)
$targetForms = @($targets | ForEach-Object { [string]$_.authoredRef })
$baseForms = @($targets | ForEach-Object { [string]$_.base })
$enableParents = @(
    @($targets | ForEach-Object { [string]$_.enableParent } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    '0x105d4c'
    '0x11d9a5'
) | Select-Object -Unique
$maxFrames = [Math]::Max(600, $targets.Count * ($BatchSettleFrames + 60))
$rosterEvidence = Get-FNVFileEvidence $rosterFile 'canonical-goodsprings-roster'

$jsonl = Join-Path $runDirectoryAbs 'retail-all-actors.jsonl'
$screenshotDirectory = Join-Path $runDirectoryAbs 'screenshots'
if (-not (Test-Path -LiteralPath $jsonl -PathType Leaf)) { throw "Missing retail JSONL: $jsonl" }
if (-not (Test-Path -LiteralPath $screenshotDirectory -PathType Container)) {
    throw "Missing retail screenshot directory: $screenshotDirectory"
}
$captureEvidence = Get-FNVFileEvidence $jsonl 'oracle-jsonl'

$expectedScreenshotNames = @(Get-FNVExpectedScreenshotNames -BatchTargetForm $targetForms)
$capturedScreenshots = @($expectedScreenshotNames | ForEach-Object {
    Join-Path $screenshotDirectory $_
})
$actualScreenshotNames = @(Get-ChildItem -LiteralPath $screenshotDirectory -Filter 'frame-target-*.bmp' -File |
    ForEach-Object Name)
if ($actualScreenshotNames.Count -ne $expectedScreenshotNames.Count -or
    @($actualScreenshotNames | Where-Object { $_ -notin $expectedScreenshotNames }).Count -ne 0) {
    throw "Retail screenshot set is not the exact canonical 37-target set in $screenshotDirectory"
}
$screenshotEvidence = @(Assert-FNVRetailScreenshotFiles `
    -Path $capturedScreenshots -ExpectedName $expectedScreenshotNames)

$validationEvents = New-Object System.Collections.Generic.List[object]
$streamEventCounts = @{}
$targetStats = @{}
foreach ($target in $targets) {
    $reference = Convert-FormId ([string]$target.authoredRef)
    $targetStats[$reference] = [ordered]@{
        appearanceEvents = 0
        portraitEvents = 0
        actorFrames = 0
        geometryShapes = 0
        incompleteGeometryShapes = 0
        geometrySummaryEvents = 0
        geometryStatusEvents = 0
        geometrySummaryEmittedShapes = 0
        geometryPointerReadFailures = 0
        geometryDataReadFailures = 0
        geometryInvalidDataLayouts = 0
        geometryVertexReadFailures = 0
        geometryTraversalFaults = 0
        captureFaults = 0
        cameraFocusKind = $null
        cameraShotKind = $null
        cameraBoundValid = $false
        cameraBoundRadius = 0.0
        weaponStateEvents = 0
        weaponStateStatus = $null
        weaponRequired = $false
        weaponForm = 0
        weaponOut = $false
    }
}

foreach ($eventLine in [System.IO.File]::ReadLines($jsonl)) {
    if ($eventLine -notmatch '"event":"(?<eventName>[^"]+)"') {
        throw 'Retail JSONL contains a line without a top-level event name.'
    }
    $eventName = [string]$Matches.eventName
    if (-not $streamEventCounts.ContainsKey($eventName)) { $streamEventCounts[$eventName] = 0 }
    ++$streamEventCounts[$eventName]

    $reference = $null
    if ($eventLine -match '"refForm":(?<refForm>[0-9]+)') {
        $reference = [uint32]$Matches.refForm
    }
    if ($null -ne $reference -and $targetStats.ContainsKey($reference)) {
        $stats = $targetStats[$reference]
        switch ($eventName) {
            { $_ -in @('npc-appearance', 'target-appearance') } { ++$stats.appearanceEvents; break }
            'portrait-camera-set' {
                ++$stats.portraitEvents
                if ($eventLine -match '"focusKind":"(?<focusKind>[^"]+)"') {
                    $stats.cameraFocusKind = [string]$Matches.focusKind
                }
                if ($eventLine -match '"shotKind":"(?<shotKind>[^"]+)"') {
                    $stats.cameraShotKind = [string]$Matches.shotKind
                }
                if ($eventLine -match '"worldBound":\{"valid":(?<valid>true|false),"center":\[[^\]]+\],"radius":(?<radius>[-+0-9.eE]+)') {
                    $stats.cameraBoundValid = [string]$Matches.valid -eq 'true'
                    $stats.cameraBoundRadius = [double]::Parse(
                        [string]$Matches.radius, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                break
            }
            'batch-weapon-state' {
                ++$stats.weaponStateEvents
                if ($eventLine -match '"status":"(?<status>[^"]+)"') {
                    $stats.weaponStateStatus = [string]$Matches.status
                }
                if ($eventLine -match '"weaponRequired":(?<required>true|false)') {
                    $stats.weaponRequired = [string]$Matches.required -eq 'true'
                }
                if ($eventLine -match '"weaponForm":(?<form>[0-9]+)') {
                    $stats.weaponForm = [uint32]$Matches.form
                }
                if ($eventLine -match '"weaponOut":(?<out>true|false)') {
                    $stats.weaponOut = [string]$Matches.out -eq 'true'
                }
                break
            }
            'actor-frame' { ++$stats.actorFrames; break }
            'actor-geometry' {
                ++$stats.geometryShapes
                if ($eventLine -notmatch '"complete":true') { ++$stats.incompleteGeometryShapes }
                if (-not $eventLine.TrimEnd().EndsWith(']}', [System.StringComparison]::Ordinal)) {
                    throw ("Actor geometry line for 0x{0:x8} is truncated." -f $reference)
                }
                break
            }
            'actor-geometry-status' {
                ++$stats.geometrySummaryEvents
                ++$stats.geometryStatusEvents
                foreach ($counter in @(
                    @{ Json = 'emittedShapes'; Stat = 'geometrySummaryEmittedShapes' }
                    @{ Json = 'pointerReadFailures'; Stat = 'geometryPointerReadFailures' }
                    @{ Json = 'dataReadFailures'; Stat = 'geometryDataReadFailures' }
                    @{ Json = 'invalidDataLayouts'; Stat = 'geometryInvalidDataLayouts' }
                    @{ Json = 'vertexReadFailures'; Stat = 'geometryVertexReadFailures' }
                )) {
                    if ($eventLine -match ('"' + $counter.Json + '":(?<count>[0-9]+)')) {
                        $stats[$counter.Stat] += [int]$Matches.count
                    }
                }
                if ($eventLine -match '"traversalFault":true') { ++$stats.geometryTraversalFaults }
                break
            }
            { $_ -in @('actor-geometry-node-status', 'actor-geometry-fault') } {
                ++$stats.geometryStatusEvents
                if ($eventName -eq 'actor-geometry-fault') { ++$stats.geometryTraversalFaults }
                break
            }
            'capture-fault' { ++$stats.captureFaults; break }
        }
    }

    # Preserve the complete geometry payload in JSONL without expanding its
    # vertex array into PowerShell memory. Every other event is fully parsed and
    # subsequently checked by the shared retail evidence validator.
    if ($eventName -ne 'actor-geometry') {
        $validationEvents.Add(($eventLine | ConvertFrom-Json)) | Out-Null
    }
}
$events = @($validationEvents.ToArray())
$cameraEvents = @($events | Where-Object { $_.event -eq 'portrait-camera-set' })
$weaponEvents = @($events | Where-Object { $_.event -eq 'batch-weapon-state' })
if ($cameraEvents.Count -ne $targets.Count -or $weaponEvents.Count -ne $targets.Count) {
    throw "Canonical full-body finalization requires exactly $($targets.Count) camera and weapon-state events."
}
for ($targetIndex = 0; $targetIndex -lt $targets.Count; ++$targetIndex) {
    $expectedReference = Convert-FormId ([string]$targets[$targetIndex].authoredRef)
    $cameraMatch = @($cameraEvents | Where-Object { $_.refForm -eq $expectedReference })
    $weaponMatch = @($weaponEvents | Where-Object {
        $_.targetIndex -eq $targetIndex -and $_.refForm -eq $expectedReference
    })
    if ($cameraMatch.Count -ne 1 -or [string]$cameraMatch[0].shotKind -ne 'front-full-body' -or
        -not [bool]$cameraMatch[0].worldBound.valid -or $weaponMatch.Count -ne 1) {
        throw ("Canonical camera/weapon identity gate failed at target {0} ({1:x8})." -f
            $targetIndex, $expectedReference)
    }
    if ([string]$weaponMatch[0].status -notin @('passed', 'not-applicable') -or
        ([bool]$weaponMatch[0].weaponRequired -and (-not [bool]$weaponMatch[0].weaponOut -or
            [uint32]$weaponMatch[0].weaponForm -eq 0))) {
        throw "Canonical weapon-drawn gate failed at target index $targetIndex."
    }
}
$loadRequests = @($events | Where-Object { $_.event -eq 'load-request' })
if ($loadRequests.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$loadRequests[0].save)) {
    throw 'Existing retail evidence must contain exactly one named load-request.'
}
$saveName = [string]$loadRequests[0].save
$validation = Assert-FNVRetailOracleEvidence `
    -Events $events `
    -SaveName $saveName `
    -BatchTargetForm $targetForms `
    -BatchExpectedBaseForm $baseForms `
    -BeforeFrame 5 `
    -CommandFrame 10 `
    -AfterFrame 15 `
    -MaxFrames $maxFrames `
    -BatchSettleFrames $BatchSettleFrames `
    -BatchAdvanceFrames $BatchAdvanceFrames `
    -BatchMoveToTargets $true `
    -BatchEnableTargets $true `
    -BatchEnableParentForm $enableParents `
    -BackgroundDataMode $true
$validationEventCount = [int]$validation.eventCount
$totalEventCount = [int](($streamEventCounts.Values | Measure-Object -Sum).Sum)
$validation.eventCount = $totalEventCount
$validation | Add-Member -NotePropertyName validationEventCount -NotePropertyValue $validationEventCount
$validation | Add-Member -NotePropertyName validationPayloadOmissions -NotePropertyValue @('actor-geometry')

$screenshotByReference = @{}
for ($index = 0; $index -lt $targets.Count; ++$index) {
    $reference = Convert-FormId ([string]$targets[$index].authoredRef)
    $screenshotByReference[$reference] = $capturedScreenshots[$index]
}
$screenshotEventByReference = @{}
foreach ($screenshotEvent in @($validation.screenshots)) {
    $key = Convert-FormId ([string]$screenshotEvent.targetForm)
    if ($screenshotEventByReference.ContainsKey($key)) {
        throw ("Duplicate screenshot telemetry for 0x{0:x8}." -f $key)
    }
    $screenshotEventByReference[$key] = $screenshotEvent
}

$rows = foreach ($target in $targets) {
    $reference = Convert-FormId ([string]$target.authoredRef)
    $base = Convert-FormId ([string]$target.base)
    if (-not $screenshotEventByReference.ContainsKey($reference)) {
        throw ("Missing screenshot telemetry for 0x{0:x8}." -f $reference)
    }
    $stats = $targetStats[$reference]
    $shotEvent = $screenshotEventByReference[$reference]
    $authoredRef = ('0x{0:x8}' -f $reference)
    $baseForm = ('0x{0:x8}' -f $base)
    $passed = $stats.appearanceEvents -eq 1 -and $stats.portraitEvents -eq 1 -and
        $stats.cameraShotKind -eq 'front-full-body' -and $stats.cameraBoundValid -and
        $stats.cameraBoundRadius -gt 0 -and $stats.weaponStateEvents -eq 1 -and
        $stats.weaponStateStatus -in @('passed', 'not-applicable') -and
        (-not $stats.weaponRequired -or ($stats.weaponOut -and $stats.weaponForm -ne 0)) -and
        $stats.actorFrames -ge 2 -and $stats.geometryShapes -ge 1 -and
        $stats.incompleteGeometryShapes -eq 0 -and $stats.geometrySummaryEvents -eq 1 -and
        $stats.geometrySummaryEmittedShapes -eq $stats.geometryShapes -and
        $stats.geometryPointerReadFailures -eq 0 -and $stats.geometryDataReadFailures -eq 0 -and
        $stats.geometryInvalidDataLayouts -eq 0 -and $stats.geometryVertexReadFailures -eq 0 -and
        $stats.geometryTraversalFaults -eq 0 -and $stats.captureFaults -eq 0
    [pscustomobject][ordered]@{
        captureId = ('{0}::front-full-body' -f [string]$target.id)
        targetId = [string]$target.id
        id = [string]$target.id
        category = [string]$target.category
        authoredRef = $authoredRef
        actualRuntimeRef = $authoredRef
        reference = $authoredRef
        base = $baseForm
        expectedBase = $baseForm
        identityMode = 'authored-reference'
        shotKind = 'front-full-body'
        requestedFrame = [int]$shotEvent.frame
        actualFrame = [int]$shotEvent.frame
        screenshot = [string]$screenshotByReference[$reference]
        appearanceEvents = [int]$stats.appearanceEvents
        portraitEvents = [int]$stats.portraitEvents
        actorFrames = [int]$stats.actorFrames
        geometryShapes = [int]$stats.geometryShapes
        incompleteGeometryShapes = [int]$stats.incompleteGeometryShapes
        geometrySummaryEvents = [int]$stats.geometrySummaryEvents
        geometryStatusEvents = [int]$stats.geometryStatusEvents
        geometrySummaryEmittedShapes = [int]$stats.geometrySummaryEmittedShapes
        geometryPointerReadFailures = [int]$stats.geometryPointerReadFailures
        geometryDataReadFailures = [int]$stats.geometryDataReadFailures
        geometryInvalidDataLayouts = [int]$stats.geometryInvalidDataLayouts
        geometryVertexReadFailures = [int]$stats.geometryVertexReadFailures
        geometryTraversalFaults = [int]$stats.geometryTraversalFaults
        captureFaults = [int]$stats.captureFaults
        cameraFocusKind = $stats.cameraFocusKind
        cameraShotKind = $stats.cameraShotKind
        cameraBoundValid = [bool]$stats.cameraBoundValid
        cameraBoundRadius = [double]$stats.cameraBoundRadius
        weaponStateEvents = [int]$stats.weaponStateEvents
        weaponStateStatus = $stats.weaponStateStatus
        weaponRequired = [bool]$stats.weaponRequired
        weaponForm = ('0x{0:x8}' -f [uint32]$stats.weaponForm)
        weaponOut = [bool]$stats.weaponOut
        passed = [bool]$passed
    }
}
$failed = @($rows | Where-Object { -not $_.passed })
if ($failed.Count -gt 0) {
    throw "Existing retail telemetry failed the canonical contract for: $($failed.id -join ', ')"
}

$eventCounts = @($streamEventCounts.GetEnumerator() | Sort-Object Key | ForEach-Object {
    [pscustomobject][ordered]@{ event = [string]$_.Key; count = [int]$_.Value }
})
$resumedOracleManifestPath = $jsonl + '.manifest.json'
$resumedOracleManifest = [pscustomobject][ordered]@{
    schema = 'nikami-fnv-retail-oracle-resumed-run-manifest/v1'
    status = 'passed'
    finalizationMode = 'existing-evidence-no-launch'
    processCount = 1
    expectedIdentity = [pscustomobject][ordered]@{
        eventSchema = 'nikami-retail-oracle/v4'
        runtime = 'FalloutNV-1.4.0.525'
        batchTargetForms = @($targetForms | ForEach-Object { Format-FNVFormId $_ })
        batchBaseForms = @($baseForms | ForEach-Object { Format-FNVFormId $_ })
        batchEnableParentForms = @($enableParents | ForEach-Object { Format-FNVFormId $_ })
        batchSettleFrames = $BatchSettleFrames
        batchAdvanceFrames = $BatchAdvanceFrames
        maxFrames = $maxFrames
        cameraShotKind = 'front-full-body'
        batchForceWeaponOut = $true
    }
    evidence = [pscustomobject][ordered]@{
        capture = $captureEvidence
        canonicalRoster = $rosterEvidence
        screenshots = @($screenshotEvidence)
        validationPayloadOmissions = @('actor-geometry')
        eventCounts = @($eventCounts)
    }
    validation = $validation
}
$resumedOracleManifestPath = Write-OrValidateDeterministicJson `
    -Path $resumedOracleManifestPath -Document $resumedOracleManifest

$contactSheet = Join-Path $runDirectoryAbs 'retail-contact-sheet.png'
if (-not (Test-Path -LiteralPath $contactSheet -PathType Leaf)) {
    & $contactSheetScript -ManifestPath $resumedOracleManifestPath `
        -OutputPath $contactSheet -Columns 5 | Out-Null
}
$contactSheetEvidence = Get-FNVFileEvidence $contactSheet 'retail-contact-sheet'

# Refuse to finalize across a concurrently changed capture.
$captureEvidenceAfter = Get-FNVFileEvidence $jsonl 'oracle-jsonl'
if ($captureEvidenceAfter.sha256 -cne $captureEvidence.sha256 -or
    $captureEvidenceAfter.bytes -ne $captureEvidence.bytes) {
    throw 'Retail JSONL changed during no-launch finalization.'
}
for ($index = 0; $index -lt $screenshotEvidence.Count; ++$index) {
    $after = Get-FNVFileEvidence $capturedScreenshots[$index] 'retail-screenshot'
    if ($after.sha256 -cne $screenshotEvidence[$index].sha256 -or
        $after.bytes -ne $screenshotEvidence[$index].bytes) {
        throw "Retail screenshot changed during no-launch finalization: $($capturedScreenshots[$index])"
    }
}

$fullManifestPath = Join-Path $runDirectoryAbs 'full-telemetry-manifest.json'
$fullManifest = [pscustomobject][ordered]@{
    schema = 'nikami-fnv-goodsprings-full-telemetry/v2'
    runId = [System.IO.Path]::GetFileName($runDirectoryAbs.TrimEnd('\', '/'))
    processCount = 1
    passiveCapture = $false
    captureStaging = 'draw-already-equipped-weapons'
    canonicalShotKind = 'front-full-body'
    finalizationMode = 'existing-evidence-no-launch'
    canonicalRoster = $rosterFile
    canonicalRosterSha256 = $rosterEvidence.sha256
    targetCount = $targets.Count
    sampleEvery = $SampleEvery
    batchSettleFrames = $BatchSettleFrames
    batchAdvanceFrames = $BatchAdvanceFrames
    maxFrames = $maxFrames
    jsonl = $jsonl
    oracleManifest = $resumedOracleManifestPath
    contactSheet = $contactSheet
    contactSheetEvidence = $contactSheetEvidence
    screenshots = @($rows | ForEach-Object {
        [pscustomobject][ordered]@{
            captureId = $_.captureId
            targetId = $_.targetId
            authoredRef = $_.authoredRef
            actualRuntimeRef = $_.actualRuntimeRef
            base = $_.base
            identityMode = $_.identityMode
            shotKind = $_.shotKind
            requestedFrame = $_.requestedFrame
            actualFrame = $_.actualFrame
            path = $_.screenshot
        }
    })
    rows = @($rows)
    failed = @()
    evidence = [pscustomobject][ordered]@{
        capture = $captureEvidence
        canonicalRoster = $rosterEvidence
        screenshots = @($screenshotEvidence)
        eventCounts = @($eventCounts)
    }
}
$fullManifestPath = Write-OrValidateDeterministicJson `
    -Path $fullManifestPath -Document $fullManifest

[pscustomobject][ordered]@{
    schema = 'nikami-fnv-goodsprings-full-telemetry-finalization/v1'
    status = 'validated-existing-evidence-no-launch'
    runDirectory = $runDirectoryAbs
    targetCount = $targets.Count
    processCount = 1
    jsonl = $jsonl
    oracleManifest = $resumedOracleManifestPath
    manifest = $fullManifestPath
    contactSheet = $contactSheet
    captureSha256 = $captureEvidence.sha256
}
