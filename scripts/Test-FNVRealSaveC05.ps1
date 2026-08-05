[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\\code\\nikami-worlds",
    [string]$CaptureRoot = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c05-openmw-20260802-173200",
    [string]$RuntimeRoot = "D:\\code\\nikami-worlds\\local\\openmw-real-save330-c05-travel-time-20260802-173000",
    [string]$FixturePath = "D:\\code\\nikami-worlds\\local\\retail-real-save-fixtures\\NikamiRealWorldSave330-20260802.fos",
    [string]$DenominatorPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-map-marker-denominator.json",
    [string]$ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c05-fast-travel-validation.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$CaptureRoot = [IO.Path]::GetFullPath($CaptureRoot)
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$FixturePath = [IO.Path]::GetFullPath($FixturePath)
$DenominatorPath = [IO.Path]::GetFullPath($DenominatorPath)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)

if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing C05 validation artifact: $ValidationPath"
}

$OpenMwRoot = Join-Path $CaptureRoot "openmw"
$SummaryPath = Join-Path $CaptureRoot "background-capture-summary.json"
$ReportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$StdoutPath = Join-Path $OpenMwRoot "openmw.stdout.log"
$StderrPath = Join-Path $OpenMwRoot "openmw.stderr.log"
$VideoPath = Join-Path $OpenMwRoot "OpenMW-Save330-C05-map-travel-exact-title-raw.mp4"
$NativeSourceRoot = Join-Path $OpenMwRoot "native-source-frames"

$checks = [Collections.Generic.List[object]]::new()
$script:c05AllPass = $true

function Add-C05Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:c05AllPass = $false }
}

function Get-C05Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Read-C05Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { return $null }
}

function Test-C05Pattern {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    return $Text -match $Pattern
}

$summary = Read-C05Json $SummaryPath
$report = Read-C05Json $ReportPath
$denominator = Read-C05Json $DenominatorPath
$stdout = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) { Get-Content -Raw -LiteralPath $StdoutPath } else { '' }
$stderr = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { Get-Content -Raw -LiteralPath $StderrPath } else { '' }

$fixtureArtifact = Get-C05Artifact $FixturePath
$denominatorArtifact = Get-C05Artifact $DenominatorPath
$runtimeArtifact = Get-C05Artifact (Join-Path $RuntimeRoot "openmw.exe")
$summaryArtifact = Get-C05Artifact $SummaryPath
$reportArtifact = Get-C05Artifact $ReportPath
$stdoutArtifact = Get-C05Artifact $StdoutPath
$stderrArtifact = Get-C05Artifact $StderrPath
$videoArtifact = Get-C05Artifact $VideoPath

Add-C05Check "Public background-capture summary is retained" ($null -ne $summaryArtifact) $summaryArtifact
Add-C05Check "C05 OpenMW report is retained" ($null -ne $reportArtifact) $reportArtifact
Add-C05Check "Canonical Save330 fixture is retained" ($null -ne $fixtureArtifact) $fixtureArtifact
Add-C05Check "C01 marker denominator is retained" ($null -ne $denominatorArtifact) $denominatorArtifact

$expectedFixtureBytes = 3395328
$expectedFixtureSha = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
Add-C05Check "Save330 fixture has the pinned byte length and SHA-256" `
    ($null -ne $fixtureArtifact -and $fixtureArtifact.bytes -eq $expectedFixtureBytes -and $fixtureArtifact.sha256 -eq $expectedFixtureSha) `
    ([ordered]@{ expectedBytes = $expectedFixtureBytes; actual = $fixtureArtifact; expectedSha256 = $expectedFixtureSha })

$expectedRoute = "save330-pipboy-map-travel-v1"
$summaryPass = $null -ne $summary -and $summary.schema -eq "nikami-fnv-jam-background-capture-run/v1" -and
    $summary.status -eq "pass" -and $summary.target -eq "OpenMW" -and $summary.scenario -eq "RealSave"
Add-C05Check "Public sequential capture summary passes" $summaryPass `
    ([ordered]@{ schema = if ($null -ne $summary) { $summary.schema } else { $null }; status = if ($null -ne $summary) { $summary.status } else { $null } })

$policyPass = $null -ne $summary -and $summary.policy.windowsAppControlUsed -eq $false -and
    $summary.policy.foregroundActivationUsed -eq $false -and $summary.policy.foregroundInputInjected -eq $false -and
    $summary.policy.capturesRanSequentially -eq $true -and $summary.policy.outputOverwritten -eq $false
Add-C05Check "Capture policy has no host control, concurrency, or overwrite" $policyPass `
    $(if ($null -ne $summary) { $summary.policy } else { $null })

$reportPass = $null -ne $report -and $report.schema -eq "nikami-fnv-real-save-capture/v1" -and
    $report.status -eq "pass" -and $report.target -eq "OpenMW" -and $report.routeId -eq $expectedRoute
Add-C05Check "Real-save report passes the exact C05 route" $reportPass `
    ([ordered]@{ schema = if ($null -ne $report) { $report.schema } else { $null }; status = if ($null -ne $report) { $report.status } else { $null }; routeId = if ($null -ne $report) { $report.routeId } else { $null } })

$capturePass = $null -ne $report -and $report.capture.windowsAppControlUsed -eq $false -and
    $report.capture.foregroundActivationUsed -eq $false -and $report.capture.foregroundInputInjected -eq $false -and
    $report.capture.sourceFrameRetained -eq $true -and $report.capture.nativeFrameCount -eq 3 -and
    $report.capture.telemetryRetained -eq $true -and $report.capture.exactTitleVideoRetained -eq $true -and
    $report.capture.recorderExitCode -eq 0 -and $report.capture.gameTermination -eq "engine-exited" -and
    $report.capture.userConfigurationRestored -eq $true
Add-C05Check "C05 capture retained three native frames, telemetry, and exact-title video" $capturePass `
    $(if ($null -ne $report) { $report.capture } else { $null })

$requiredAssertions = @(
    "stateManifestPass", "ordinaryLoadPathObserved", "nativeSaveLoadComplete",
    "playerIdentityRestored", "savedTransformApplied", "fallbackInventoryAbsent",
    "syntheticPlacementAbsent", "nativeWorldFrameRetained", "c05MapTravelFramesRetained",
    "exactTitleVideoRetained"
)
$missingAssertions = @($requiredAssertions | Where-Object {
        $null -eq $report -or $null -eq $report.assertions.PSObject.Properties[$_] -or
        [bool]$report.assertions.$_ -ne $true
    })
Add-C05Check "All ordinary-load and C05 report assertions pass" ($missingAssertions.Count -eq 0) `
    ([ordered]@{ required = $requiredAssertions; missing = $missingAssertions })

$expectedRuntimePath = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot "openmw.exe"))
$reportedRuntimePath = if ($null -ne $report) { [IO.Path]::GetFullPath([string]$report.source.binary.path) } else { '' }
$runtimeSha = if ($null -ne $runtimeArtifact) { $runtimeArtifact.sha256 } else { '' }
$reportedRuntimeSha = if ($null -ne $report) { ([string]$report.source.binary.sha256).ToLowerInvariant() } else { '' }
$pdbCount = @((Get-ChildItem -LiteralPath $RuntimeRoot -Filter "*.pdb" -File -Recurse -ErrorAction SilentlyContinue)).Count
Add-C05Check "Report binary path and SHA match the staged no-PDB runtime" `
    ($null -ne $runtimeArtifact -and $reportedRuntimePath -eq $expectedRuntimePath -and $reportedRuntimeSha -eq $runtimeSha -and
     (Test-Path -LiteralPath (Join-Path $RuntimeRoot "resources") -PathType Container) -and
     (Test-Path -LiteralPath (Join-Path $RuntimeRoot "osgPlugins-3.6.5") -PathType Container) -and $pdbCount -eq 0) `
    ([ordered]@{ expectedPath = $expectedRuntimePath; reportedPath = $reportedRuntimePath; runtime = $runtimeArtifact; reportedSha256 = $reportedRuntimeSha; pdbCount = $pdbCount })

$sourceSavePass = $null -ne $report -and $null -ne $report.source.saveFixture -and
    [IO.Path]::GetFullPath([string]$report.source.saveFixture.path) -eq [IO.Path]::GetFullPath($FixturePath) -and
    [int64]$report.source.saveFixture.bytes -eq $expectedFixtureBytes -and
    ([string]$report.source.saveFixture.sha256).ToLowerInvariant() -eq $expectedFixtureSha
Add-C05Check "Report is hash-locked to the immutable Save330 source" $sourceSavePass `
    $(if ($null -ne $report) { $report.source.saveFixture } else { $null })

$denominatorPass = $null -ne $denominator -and $denominator.schema -eq "nikami-fnv-save330-map-marker-denominator/v1" -and
    [int]$denominator.counts.authored -eq 320 -and [int]$denominator.counts.visible -eq 1 -and
    [int]$denominator.counts.travelEnabled -eq 1 -and [int]$denominator.savedRuntimeState.values.discoveredTravel -eq 1 -and
    (@($denominator.markers | Where-Object { $_.formId -eq "0x03008885" -and $_.name -eq "Southern Passage" -and $_.savedRuntimeState -eq 2 -and $_.authoredCanTravel -eq $true })).Count -eq 1
Add-C05Check "C05 uses the single restored Southern Passage travel row" $denominatorPass `
    $(if ($null -ne $denominator) { $denominator.counts } else { $null })

$namedFrameNames = @(
    "Save330-C05-map-travel-before-confirmation.png",
    "Save330-C05-map-travel-confirmation.png",
    "Save330-C05-map-travel-destination.png"
)
$namedFrames = @($namedFrameNames | ForEach-Object { Get-C05Artifact (Join-Path $OpenMwRoot $_) })
Add-C05Check "Named C05 native frames are present and non-empty" `
    ($namedFrames.Count -eq 3 -and @($namedFrames | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0) $namedFrames

$sourceFrames = if (Test-Path -LiteralPath $NativeSourceRoot -PathType Container) {
    @(Get-ChildItem -LiteralPath $NativeSourceRoot -Filter "screenshot*.png" -File | Sort-Object Name)
} else { @() }
$sourceFrameArtifacts = @($sourceFrames | ForEach-Object { Get-C05Artifact $_.FullName })
$sourceFrameHashes = @($sourceFrameArtifacts | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
Add-C05Check "Three distinct native source frame hashes are retained" `
    ($sourceFrameArtifacts.Count -eq 3 -and @($sourceFrameArtifacts | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0 -and $sourceFrameHashes.Count -eq 3) $sourceFrameArtifacts
Add-C05Check "Exact-title raw video is present and non-empty" ($null -ne $videoArtifact -and $videoArtifact.bytes -gt 0) $videoArtifact
Add-C05Check "Capture stdout/stderr artifacts are retained" ($null -ne $stdoutArtifact -and $null -ne $stderrArtifact) ([ordered]@{ stdout = $stdoutArtifact; stderr = $stderrArtifact })

$nativePatterns = [ordered]@{
    "native structural parse" = "Native FNV save structural parse complete: masters=10 .* inventoryEntries=50"
    "player identity" = "Native FNV save Player identity restored: base=0x1000007 reference=0x1000014"
    "inventory denominator" = "Native FNV save Player inventory: stacks=50 worn=3"
    "runtime inventory rebuild" = "Native FNV save Player runtime inventory rebuilt: stacks=55 visible=53"
    "transform restoration" = "Native FNV save restored local REFR/ACHR/ACRE transforms: applied=4 missing=0"
    "camera restoration" = "Native FNV save owns camera mode=1 .* firstPersonModelFov="
    "first-person alignment" = "FNV first-person camera alignment: .* exact=1"
    "production marker widget" = "FNV/ESM4 map: rendered 1 exact world-map markers"
    "production icon overlay" = "FNV Pip-Boy MAP: overlay marker icons drawn=1 source=restored-production-marker-state"
}
foreach ($entry in $nativePatterns.GetEnumerator()) {
    Add-C05Check ("C05 log contains " + $entry.Key) (Test-C05Pattern $stdout $entry.Value) $entry.Value
}

$markerLog = "0x3008885"
$c05Patterns = [ordered]@{
    "restored marker source" = "FNV C05 natural Pip-Boy travel: marker=$markerLog source=restored-save330-state"
    "map pane selected" = "FNV C05 natural map travel: phase=map-pane-selected pane=0 physical=1 action=MAP path=physical-pipboy-production status=pass"
    "map focused before confirmation" = ('FNV C05 natural map travel: phase=map-before-confirmation marker=' + $markerLog + ' name="Southern Passage" state=2 selected=1 pane=0 worldMap=1 path=production-map-focus status=pass')
    "unconfirmed production request" = ('FNV C05 confirmation: opened=1 marker=' + $markerLog + ' name="Southern Passage" text="Fast travel to Southern Passage\?" confirmed=0 .* path=production-map-confirmation status=pass')
    "before native frame" = "FNV C05 native frame: state=map-travel-before-confirmation index=0 source=ScreenCaptureHandler"
    "confirmation native frame" = "FNV C05 native frame: state=map-travel-confirmation index=1 source=ScreenCaptureHandler"
    "production travel destination" = "FNV/ESM4 map: fast travel complete marker=FormId:0x3008885 cell=FormId:0x300688f pos=\(-13248, -42631\.2, 7729\.34\) hours=4 currentWorldspace=FormId:0x10da726 destinationWorldspace=FormId:0x300683b"
    "confirmation handler" = "FNV C05 confirmation: confirmed=1 marker=0x3008885 path=production-confirmation-handler status=pass"
    "destination native frame" = "FNV C05 native frame: state=map-travel-destination index=2 source=ScreenCaptureHandler"
    "arrival telemetry" = 'FNV C05 natural Pip-Boy travel: phase=arrived marker=0x3008885 destinationCell=FormId:0x300688f destinationWorldspace=FormId:0x300683b destinationGrid=\(-4,-11\).*afterCell="FormId:0x300688f" afterWorldspace="FormId:0x300683b" afterGrid=\(-4,-11\).*timeAdvanced=1 sameDestinationCell=0 menuClosed=1 controlsEnabled=1 travelCleared=1 cellMatches=1 worldspaceMatches=1 gridMatches=1 positionMatches=1 path=production-fast-travel status=pass'
    "complete" = "FNV C05 natural Pip-Boy travel: phase=complete marker=0x3008885 captured=3 confirmed=1 travelExecuted=1 status=pass"
}
foreach ($entry in $c05Patterns.GetEnumerator()) {
    Add-C05Check ("C05 log contains " + $entry.Key) (Test-C05Pattern $stdout $entry.Value) $entry.Value
}

$forbiddenTerms = @("AppActivate", "SetForegroundWindow", "SendInput", "Computer Use", "showFalloutMapMarker", "unlock-all", "unlock all", "teleport shortcut", "TestMap")
$forbiddenFound = @($forbiddenTerms | Where-Object { $stdout -match [regex]::Escape($_) -or $stderr -match [regex]::Escape($_) })
Add-C05Check "C05 logs contain no host-control, unlock, or teleport shortcut" ($forbiddenFound.Count -eq 0) $forbiddenFound

$validation = [ordered]@{
    schema = "nikami-fnv-real-save-c05-validation/v1"
    status = if ($script:c05AllPass) { "pass" } else { "fail" }
    objective = "Validate natural Save330 Pip-Boy confirmation and production fast travel with destination, time, menu, and control-state telemetry."
    captureRoot = $CaptureRoot
    routeId = $expectedRoute
    marker = [ordered]@{
        formId = "FormId:0x03008885"
        name = "Southern Passage"
        savedRuntimeState = 2
        confirmation = "Fast travel to Southern Passage?"
        confirmed = 1
        travelExecuted = 1
        destinationCell = "FormId:0x0300688F"
        destinationWorldspace = "FormId:0x0300683B"
        destinationGrid = @(-4, -11)
        travelHours = 4
        beforeHour = 14.2243
        afterHour = 18.2243
    }
    source = [ordered]@{
        fixture = $fixtureArtifact
        denominator = $denominatorArtifact
        runtime = $runtimeArtifact
        publicSummary = $summaryArtifact
        captureReport = $reportArtifact
        stdout = $stdoutArtifact
        stderr = $stderrArtifact
        video = $videoArtifact
        namedNativeFrames = $namedFrames
        nativeSourceFrames = $sourceFrameArtifacts
    }
    checks = @($checks)
}
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

if (-not $script:c05AllPass) {
    throw "C05 validation failed. See $ValidationPath"
}

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $checks.Count
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-C05Artifact $ValidationPath
    captureRoot = $CaptureRoot
}
