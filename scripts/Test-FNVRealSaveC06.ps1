[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\\code\\nikami-worlds",
    [string]$CaptureRoot = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c06-openmw-20260802-180200",
    [string]$RuntimeRoot = "D:\\code\\nikami-worlds\\local\\openmw-real-save330-c06-rejection-matrix-20260802-180000",
    [string]$FixturePath = "D:\\code\\nikami-worlds\\local\\retail-real-save-fixtures\\NikamiRealWorldSave330-20260802.fos",
    [string]$DenominatorPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-map-marker-denominator.json",
    [string]$ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c06-rejection-matrix-validation.json"
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
    throw "Refusing to overwrite an existing C06 validation artifact: $ValidationPath"
}

$OpenMwRoot = Join-Path $CaptureRoot "openmw"
$SummaryPath = Join-Path $CaptureRoot "background-capture-summary.json"
$ReportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$StdoutPath = Join-Path $OpenMwRoot "openmw.stdout.log"
$StderrPath = Join-Path $OpenMwRoot "openmw.stderr.log"
$VideoPath = Join-Path $OpenMwRoot "OpenMW-Save330-C06-rejection-matrix-exact-title-raw.mp4"
$NativeSourceRoot = Join-Path $OpenMwRoot "native-source-frames"

$checks = [Collections.Generic.List[object]]::new()
$script:c06AllPass = $true

function Add-C06Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:c06AllPass = $false }
}

function Get-C06Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Read-C06Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { return $null }
}

function Test-C06Pattern {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    return $Text -match $Pattern
}

$summary = Read-C06Json $SummaryPath
$report = Read-C06Json $ReportPath
$denominator = Read-C06Json $DenominatorPath
$stdout = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) { Get-Content -Raw -LiteralPath $StdoutPath } else { '' }
$stderr = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { Get-Content -Raw -LiteralPath $StderrPath } else { '' }

$fixtureArtifact = Get-C06Artifact $FixturePath
$denominatorArtifact = Get-C06Artifact $DenominatorPath
$runtimeArtifact = Get-C06Artifact (Join-Path $RuntimeRoot "openmw.exe")
$summaryArtifact = Get-C06Artifact $SummaryPath
$reportArtifact = Get-C06Artifact $ReportPath
$stdoutArtifact = Get-C06Artifact $StdoutPath
$stderrArtifact = Get-C06Artifact $StderrPath
$videoArtifact = Get-C06Artifact $VideoPath

Add-C06Check "Public background-capture summary is retained" ($null -ne $summaryArtifact) $summaryArtifact
Add-C06Check "C06 OpenMW report is retained" ($null -ne $reportArtifact) $reportArtifact
Add-C06Check "Canonical Save330 fixture is retained" ($null -ne $fixtureArtifact) $fixtureArtifact
Add-C06Check "C01 marker denominator is retained" ($null -ne $denominatorArtifact) $denominatorArtifact

$expectedFixtureBytes = 3395328
$expectedFixtureSha = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
$fixturePass = $null -ne $fixtureArtifact -and $fixtureArtifact.bytes -eq $expectedFixtureBytes -and $fixtureArtifact.sha256 -eq $expectedFixtureSha
Add-C06Check "Save330 fixture has the pinned byte length and SHA-256" $fixturePass ([ordered]@{ expectedBytes = $expectedFixtureBytes; actual = $fixtureArtifact; expectedSha256 = $expectedFixtureSha })

$expectedRoute = "save330-pipboy-rejection-matrix-v1"
$summaryPass = $null -ne $summary -and $summary.schema -eq "nikami-fnv-jam-background-capture-run/v1" -and $summary.status -eq "pass" -and $summary.target -eq "OpenMW" -and $summary.scenario -eq "RealSave"
Add-C06Check "Public sequential capture summary passes" $summaryPass ([ordered]@{ schema = if ($null -ne $summary) { $summary.schema } else { $null }; status = if ($null -ne $summary) { $summary.status } else { $null } })

$policyPass = $null -ne $summary -and $summary.policy.windowsAppControlUsed -eq $false -and $summary.policy.foregroundActivationUsed -eq $false -and $summary.policy.foregroundInputInjected -eq $false -and $summary.policy.capturesRanSequentially -eq $true -and $summary.policy.outputOverwritten -eq $false
Add-C06Check "Capture policy has no host control, concurrency, or overwrite" $policyPass $(if ($null -ne $summary) { $summary.policy } else { $null })

$reportPass = $null -ne $report -and $report.schema -eq "nikami-fnv-real-save-capture/v1" -and $report.status -eq "pass" -and $report.target -eq "OpenMW" -and $report.routeId -eq $expectedRoute
Add-C06Check "Real-save report passes the exact C06 route" $reportPass ([ordered]@{ schema = if ($null -ne $report) { $report.schema } else { $null }; status = if ($null -ne $report) { $report.status } else { $null }; routeId = if ($null -ne $report) { $report.routeId } else { $null } })

$capturePass = $null -ne $report -and $report.capture.windowsAppControlUsed -eq $false -and $report.capture.foregroundActivationUsed -eq $false -and $report.capture.foregroundInputInjected -eq $false -and $report.capture.sourceFrameRetained -eq $true -and $report.capture.nativeFrameCount -eq 5 -and $report.capture.telemetryRetained -eq $true -and $report.capture.exactTitleVideoRetained -eq $true -and $report.capture.recorderExitCode -eq 0 -and $report.capture.gameTermination -eq "engine-exited" -and $report.capture.userConfigurationRestored -eq $true
Add-C06Check "C06 capture retained five native frames, telemetry, and exact-title video" $capturePass $(if ($null -ne $report) { $report.capture } else { $null })

$requiredAssertions = @("stateManifestPass", "ordinaryLoadPathObserved", "nativeSaveLoadComplete", "playerIdentityRestored", "savedTransformApplied", "fallbackInventoryAbsent", "syntheticPlacementAbsent", "nativeWorldFrameRetained", "c06RejectionMatrixFramesRetained", "exactTitleVideoRetained")
$missingAssertions = @($requiredAssertions | Where-Object { $null -eq $report -or $null -eq $report.assertions.PSObject.Properties[$_] -or [bool]$report.assertions.$_ -ne $true })
Add-C06Check "All ordinary-load and C06 report assertions pass" ($missingAssertions.Count -eq 0) ([ordered]@{ required = $requiredAssertions; missing = $missingAssertions })

$expectedRuntimePath = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot "openmw.exe"))
$reportedRuntimePath = if ($null -ne $report) { [IO.Path]::GetFullPath([string]$report.source.binary.path) } else { '' }
$runtimeSha = if ($null -ne $runtimeArtifact) { $runtimeArtifact.sha256 } else { '' }
$reportedRuntimeSha = if ($null -ne $report) { ([string]$report.source.binary.sha256).ToLowerInvariant() } else { '' }
$pdbCount = @((Get-ChildItem -LiteralPath $RuntimeRoot -Filter "*.pdb" -File -Recurse -ErrorAction SilentlyContinue)).Count
Add-C06Check "Report binary path and SHA match the staged no-PDB runtime" ($null -ne $runtimeArtifact -and $reportedRuntimePath -eq $expectedRuntimePath -and $reportedRuntimeSha -eq $runtimeSha -and (Test-Path -LiteralPath (Join-Path $RuntimeRoot "resources") -PathType Container) -and (Test-Path -LiteralPath (Join-Path $RuntimeRoot "osgPlugins-3.6.5") -PathType Container) -and $pdbCount -eq 0) ([ordered]@{ expectedPath = $expectedRuntimePath; reportedPath = $reportedRuntimePath; runtime = $runtimeArtifact; reportedSha256 = $reportedRuntimeSha; pdbCount = $pdbCount })

Add-C06Check "Report is hash-locked to the immutable Save330 source" ($null -ne $report -and [IO.Path]::GetFullPath([string]$report.source.saveFixture.path) -eq [IO.Path]::GetFullPath($FixturePath) -and [int64]$report.source.saveFixture.bytes -eq $expectedFixtureBytes -and ([string]$report.source.saveFixture.sha256).ToLowerInvariant() -eq $expectedFixtureSha) $(if ($null -ne $report) { $report.source.saveFixture } else { $null })

$denominatorPass = $null -ne $denominator -and $denominator.schema -eq "nikami-fnv-save330-map-marker-denominator/v1" -and [int]$denominator.counts.authored -eq 320 -and [int]$denominator.counts.visible -eq 1 -and [int]$denominator.counts.travelEnabled -eq 1 -and (@($denominator.markers | Where-Object { $_.formId -eq "0x03008885" -and $_.name -eq "Southern Passage" -and $_.savedRuntimeState -eq 2 })).Count -eq 1 -and (@($denominator.markers | Where-Object { $_.savedRuntimeState -eq 0 })).Count -gt 0
Add-C06Check "C06 uses the restored discovered marker plus a hidden denominator marker" $denominatorPass $(if ($null -ne $denominator) { $denominator.counts } else { $null })

$namedFrameNames = @("Save330-C06-rejection-cancelled.png", "Save330-C06-rejection-disabled-travel.png", "Save330-C06-rejection-enemies-nearby.png", "Save330-C06-rejection-undiscovered.png", "Save330-C06-rejection-invalid-destination.png")
$namedFrames = @($namedFrameNames | ForEach-Object { Get-C06Artifact (Join-Path $OpenMwRoot $_) })
Add-C06Check "All five named C06 native frames are present and non-empty" ($namedFrames.Count -eq 5 -and @($namedFrames | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0) $namedFrames

$sourceFrames = if (Test-Path -LiteralPath $NativeSourceRoot -PathType Container) { @(Get-ChildItem -LiteralPath $NativeSourceRoot -Filter "screenshot*.png" -File | Sort-Object Name) } else { @() }
$sourceFrameArtifacts = @($sourceFrames | ForEach-Object { Get-C06Artifact $_.FullName })
$sourceFrameHashes = @($sourceFrameArtifacts | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
Add-C06Check "Five distinct native source frame hashes are retained" ($sourceFrameArtifacts.Count -eq 5 -and @($sourceFrameArtifacts | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0 -and $sourceFrameHashes.Count -eq 5) $sourceFrameArtifacts
Add-C06Check "Exact-title raw video is present and non-empty" ($null -ne $videoArtifact -and $videoArtifact.bytes -gt 0) $videoArtifact
Add-C06Check "Capture stdout/stderr artifacts are retained" ($null -ne $stdoutArtifact -and $null -ne $stderrArtifact) ([ordered]@{ stdout = $stdoutArtifact; stderr = $stderrArtifact })

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
    "rejection-only harness" = "FNV C06 rejection matrix: marker=0x[0-9a-f]+ hiddenMarker=0x[0-9a-f]+ source=restored-save330-state harness=production-rejection-only"
    "map pane" = "FNV C06 rejection matrix: phase=map-pane-selected pane=0 physical=1 path=physical-pipboy-production status=pass"
    "map ready" = 'FNV C06 rejection matrix: phase=map-ready marker=0x3008885 name="Southern Passage" hiddenMarker=0x[0-9a-f]+ state=2 worldMap=1 selected=1 path=production-map-focus status=pass'
}
foreach ($entry in $nativePatterns.GetEnumerator()) { Add-C06Check ("C06 log contains " + $entry.Key) (Test-C06Pattern $stdout $entry.Value) $entry.Value }

$casePatterns = [ordered]@{
    "cancelled" = 'FNV C06 rejection: case=cancelled expectedReason="cancelled" requestOpened=1 confirmationAttempted=0 cancelled=1 positionUnchanged=1 timeUnchanged=1 menuOpen=1 uiUsable=1 .* path=production-map-rejection status=pass'
    "disabled travel" = 'FNV C06 rejection: case=disabled-travel expectedReason="Fast travel is currently unavailable from this location\." requestOpened=1 confirmationAttempted=1 cancelled=0 positionUnchanged=1 timeUnchanged=1 menuOpen=1 uiUsable=1 .* path=production-map-rejection status=pass'
    "enemies nearby" = 'FNV C06 rejection: case=enemies-nearby expectedReason="You cannot fast travel when enemies are nearby\." requestOpened=1 confirmationAttempted=1 cancelled=0 positionUnchanged=1 timeUnchanged=1 menuOpen=1 uiUsable=1 .* path=production-map-rejection status=pass'
    "undiscovered" = 'FNV C06 rejection: case=undiscovered expectedReason="You have not discovered that location\." requestOpened=0 confirmationAttempted=0 cancelled=0 positionUnchanged=1 timeUnchanged=1 menuOpen=1 uiUsable=1 .* path=production-map-rejection status=pass'
    "invalid destination" = 'FNV C06 rejection: case=invalid-destination expectedReason="The map marker has no authored exterior destination\." requestOpened=1 confirmationAttempted=1 cancelled=0 positionUnchanged=1 timeUnchanged=1 menuOpen=1 uiUsable=1 .* path=production-map-rejection status=pass'
}
foreach ($entry in $casePatterns.GetEnumerator()) { Add-C06Check ("C06 case passes: " + $entry.Key) (Test-C06Pattern $stdout $entry.Value) $entry.Value }

$framePatterns = @(
    "FNV C06 native frame: state=rejection-cancelled scheduled=1 captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-disabled-travel scheduled=1 captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-enemies-nearby scheduled=1 captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-undiscovered scheduled=1 captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-invalid-destination scheduled=1 captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-cancelled index=0 source=ScreenCaptureHandler captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-disabled-travel index=1 source=ScreenCaptureHandler captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-enemies-nearby index=2 source=ScreenCaptureHandler captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-undiscovered index=3 source=ScreenCaptureHandler captureAfterUiSettle=1",
    "FNV C06 native frame: state=rejection-invalid-destination index=4 source=ScreenCaptureHandler captureAfterUiSettle=1",
    "FNV C06 rejection matrix: phase=complete captured=5 allCasesPositionTimeUnchanged=1 uiUsable=1 status=pass"
)
foreach ($pattern in $framePatterns) { Add-C06Check ("C06 log contains frame/completion evidence: " + $pattern) (Test-C06Pattern $stdout $pattern) $pattern }

Add-C06Check "C06 has no successful travel completion" (-not (Test-C06Pattern $stdout "FNV/ESM4 map: fast travel complete")) "FNV/ESM4 map: fast travel complete"
$forbiddenTerms = @("AppActivate", "SetForegroundWindow", "SendInput", "Computer Use", "showFalloutMapMarker", "unlock-all", "unlock all", "teleport shortcut", "TestMap")
$forbiddenFound = @($forbiddenTerms | Where-Object { $stdout -match [regex]::Escape($_) -or $stderr -match [regex]::Escape($_) })
Add-C06Check "C06 logs contain no host-control, unlock, teleport, or TestMap shortcut" ($forbiddenFound.Count -eq 0) $forbiddenFound

$validation = [ordered]@{
    schema = "nikami-fnv-real-save-c06-validation/v1"
    status = if ($script:c06AllPass) { "pass" } else { "fail" }
    objective = "Validate production Pip-Boy fast-travel rejection and cancellation behavior with unchanged Save330 position/time and usable map UI."
    captureRoot = $CaptureRoot
    routeId = $expectedRoute
    cases = @(
        [ordered]@{ name = "cancelled"; expectedReason = "cancelled" },
        [ordered]@{ name = "disabled-travel"; expectedReason = "Fast travel is currently unavailable from this location." },
        [ordered]@{ name = "enemies-nearby"; expectedReason = "You cannot fast travel when enemies are nearby." },
        [ordered]@{ name = "undiscovered"; expectedReason = "You have not discovered that location." },
        [ordered]@{ name = "invalid-destination"; expectedReason = "The map marker has no authored exterior destination." }
    )
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

if (-not $script:c06AllPass) { throw "C06 validation failed. See $ValidationPath" }

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $checks.Count
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-C06Artifact $ValidationPath
    captureRoot = $CaptureRoot
}
