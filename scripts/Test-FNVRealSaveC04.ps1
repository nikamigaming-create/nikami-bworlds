[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\\code\\nikami-worlds",
    [string]$CaptureRoot = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c04-openmw-20260802-171700",
    [string]$RuntimeRoot = "D:\\code\\nikami-worlds\\local\\openmw-real-save330-c04-icons-20260802-171500",
    [string]$FixturePath = "D:\\code\\nikami-worlds\\local\\retail-real-save-fixtures\\NikamiRealWorldSave330-20260802.fos",
    [string]$DenominatorPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-map-marker-denominator.json",
    [string]$ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c04-map-selection-validation.json",
    [string]$EngineSourceRoot = "D:\\code\\nikami-openmw-save330-integrated"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$CaptureRoot = [IO.Path]::GetFullPath($CaptureRoot)
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$FixturePath = [IO.Path]::GetFullPath($FixturePath)
$DenominatorPath = [IO.Path]::GetFullPath($DenominatorPath)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)
$EngineSourceRoot = [IO.Path]::GetFullPath($EngineSourceRoot)

if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing C04 validation artifact: $ValidationPath"
}

$OpenMwRoot = Join-Path $CaptureRoot "openmw"
$SummaryPath = Join-Path $CaptureRoot "background-capture-summary.json"
$ReportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$StdoutPath = Join-Path $OpenMwRoot "openmw.stdout.log"
$StderrPath = Join-Path $OpenMwRoot "openmw.stderr.log"
$VideoPath = Join-Path $OpenMwRoot "OpenMW-Save330-C04-map-selection-exact-title-raw.mp4"
$NativeSourceRoot = Join-Path $OpenMwRoot "native-source-frames"
$PipBoyAnimationSourcePath = Join-Path $EngineSourceRoot "apps\\openmw\\mwrender\\esm4npcanimation.cpp"
$PipBoyAnimationLoaderSourcePath = Join-Path $EngineSourceRoot "apps\\openmw\\mwrender\\animation.cpp"
$PipBoyTextKeyIsolationSourcePath = Join-Path $EngineSourceRoot "components\\nifosg\\falloutkf.hpp"
$PipBoyTextKeyIsolationTestPath = Join-Path $EngineSourceRoot "apps\\components_tests\\nifosg\\testnifloader.cpp"
$PipBoyRenderingSourcePath = Join-Path $EngineSourceRoot "apps\\openmw\\mwrender\\renderingmanager.cpp"

$checks = [Collections.Generic.List[object]]::new()
$script:c04AllPass = $true

function Add-C04Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:c04AllPass = $false }
}

function Get-C04Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Read-C04Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { return $null }
}

function Test-C04Pattern {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    return $Text -match $Pattern
}

$summary = Read-C04Json $SummaryPath
$report = Read-C04Json $ReportPath
$stdout = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) { Get-Content -Raw -LiteralPath $StdoutPath } else { '' }
$stderr = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { Get-Content -Raw -LiteralPath $StderrPath } else { '' }
$denominator = Read-C04Json $DenominatorPath

$fixtureArtifact = Get-C04Artifact $FixturePath
$denominatorArtifact = Get-C04Artifact $DenominatorPath
$runtimeArtifact = Get-C04Artifact (Join-Path $RuntimeRoot "openmw.exe")
$summaryArtifact = Get-C04Artifact $SummaryPath
$reportArtifact = Get-C04Artifact $ReportPath
$stdoutArtifact = Get-C04Artifact $StdoutPath
$stderrArtifact = Get-C04Artifact $StderrPath
$videoArtifact = Get-C04Artifact $VideoPath
$pipBoyAnimationSourceArtifact = Get-C04Artifact $PipBoyAnimationSourcePath
$pipBoyAnimationLoaderSourceArtifact = Get-C04Artifact $PipBoyAnimationLoaderSourcePath
$pipBoyTextKeyIsolationSourceArtifact = Get-C04Artifact $PipBoyTextKeyIsolationSourcePath
$pipBoyTextKeyIsolationTestArtifact = Get-C04Artifact $PipBoyTextKeyIsolationTestPath
$pipBoyRenderingSourceArtifact = Get-C04Artifact $PipBoyRenderingSourcePath
$pipBoyAnimationSource = if ($null -ne $pipBoyAnimationSourceArtifact) {
    Get-Content -LiteralPath $PipBoyAnimationSourcePath -Raw -Encoding UTF8
} else {
    ''
}
$pipBoyRenderingSource = if ($null -ne $pipBoyRenderingSourceArtifact) {
    Get-Content -LiteralPath $PipBoyRenderingSourcePath -Raw -Encoding UTF8
} else {
    ''
}
$pipBoyAnimationLoaderSource = if ($null -ne $pipBoyAnimationLoaderSourceArtifact) {
    Get-Content -LiteralPath $PipBoyAnimationLoaderSourcePath -Raw -Encoding UTF8
} else {
    ''
}
$pipBoyTextKeyIsolationSource = if ($null -ne $pipBoyTextKeyIsolationSourceArtifact) {
    Get-Content -LiteralPath $PipBoyTextKeyIsolationSourcePath -Raw -Encoding UTF8
} else {
    ''
}
$pipBoyTextKeyIsolationTest = if ($null -ne $pipBoyTextKeyIsolationTestArtifact) {
    Get-Content -LiteralPath $PipBoyTextKeyIsolationTestPath -Raw -Encoding UTF8
} else {
    ''
}
$pipBoyPresentationMatch = [regex]::Match(
    $pipBoyAnimationSource,
    'void ESM4NpcAnimation::setPipBoyPresentationProgress\(.*?(?=\r?\n\s*void ESM4NpcAnimation::setPipBoyInteractionProgress)',
    [System.Text.RegularExpressions.RegexOptions]::Singleline)
$pipBoyPresentationSource = $pipBoyPresentationMatch.Value
$pipBoyRendererMatch = [regex]::Match(
    $pipBoyRenderingSource,
    'void RenderingManager::updateFalloutPipBoyPresentation\(.*?(?=\r?\n\s*void RenderingManager::updatePlayerPtr)',
    [System.Text.RegularExpressions.RegexOptions]::Singleline)
$pipBoyRendererSource = $pipBoyRendererMatch.Value

Add-C04Check "Public background-capture summary is retained" ($null -ne $summaryArtifact) $summaryArtifact
Add-C04Check "OpenMW real-save report is retained" ($null -ne $reportArtifact) $reportArtifact
Add-C04Check "Canonical Save330 fixture is retained" ($null -ne $fixtureArtifact) $fixtureArtifact
Add-C04Check "C01 marker denominator is retained" ($null -ne $denominatorArtifact) $denominatorArtifact
Add-C04Check "Retail Pip-Boy animation source is retained" ($null -ne $pipBoyAnimationSourceArtifact) $pipBoyAnimationSourceArtifact
Add-C04Check "Retail Pip-Boy animation loader source is retained" ($null -ne $pipBoyAnimationLoaderSourceArtifact) $pipBoyAnimationLoaderSourceArtifact
Add-C04Check "Retail Pip-Boy text-key isolation source is retained" ($null -ne $pipBoyTextKeyIsolationSourceArtifact) $pipBoyTextKeyIsolationSourceArtifact
Add-C04Check "Retail Pip-Boy text-key isolation test source is retained" ($null -ne $pipBoyTextKeyIsolationTestArtifact) $pipBoyTextKeyIsolationTestArtifact
Add-C04Check "Pip-Boy presentation renderer source is retained" ($null -ne $pipBoyRenderingSourceArtifact) $pipBoyRenderingSourceArtifact

$requiredRetailAnimationNeedles = @(
    'requireAsset("pipboy-arm"',
    'mPipBoyArmPart = attach("pipboy-arm", pipBoy, true, false, "Bip01 L ForeTwist");',
    'mPipBoyArmPart->setNodeMask(0);',
    'topology=direct-authored-nif',
    'meshes/characters/_1stperson/h2hidle.kf',
    'meshes/characters/_1stperson/h2haim.kf',
    'FNV Pip-Boy retail base layers:',
    'meshes/characters/_1stperson/locomotion/male/pipboy.kf',
    'meshes/characters/_male/idleanims/1stppipboywaver.kf',
    'static_cast<void>(progress);',
    'sequence=authored-loop',
    'sequence=retail-waver-resting-right-hand',
    'manipulateObservedRetail=0',
    'retailDataOnly=1',
    'static_cast<void>(interactionPulse);'
)
$missingRetailAnimationNeedles = @($requiredRetailAnimationNeedles | Where-Object {
        -not $pipBoyAnimationSource.Contains($_)
    })
Add-C04Check "Canonical Pip-Boy playback declares the direct retail arm NIF/KFs and data-only MAP/WORLD path" `
    ($missingRetailAnimationNeedles.Count -eq 0) `
    ([ordered]@{ required = $requiredRetailAnimationNeedles; missing = $missingRetailAnimationNeedles })

$requiredBaseIdleIsolationNeedles = @(
    'std::string(pipBoyBaseIdleKf), std::string(skeleton), false, {}, "pipboybaseidle", true);'
)
$requiredBaseIdleIsolationLoaderNeedles = @(
    'falloutIsolateExistingGroups',
    'NifOsg::isolateFalloutSelectedSourceTextKeys',
    '{ "idle" }',
    'isolated selected Fallout source'
)
$requiredBaseIdleIsolationHelperNeedles = @(
    'inline bool isolateFalloutSelectedSourceTextKeys',
    'std::initializer_list<std::string_view> conflictingGroups',
    'conflictingGroup != semanticGroup',
    'textKeys.eraseGroup(conflictingGroup)'
)
$missingBaseIdleIsolationNeedles = @($requiredBaseIdleIsolationNeedles | Where-Object {
        -not $pipBoyAnimationSource.Contains($_)
    })
$missingBaseIdleIsolationLoaderNeedles = @($requiredBaseIdleIsolationLoaderNeedles | Where-Object {
        -not $pipBoyAnimationLoaderSource.Contains($_)
    })
$missingBaseIdleIsolationHelperNeedles = @($requiredBaseIdleIsolationHelperNeedles | Where-Object {
        -not $pipBoyTextKeyIsolationSource.Contains($_)
    })
$baseIdleIsolationCallPresent = $pipBoyAnimationSource.Contains($requiredBaseIdleIsolationNeedles[0])
$baseIdleIsolationLoaderPresent = $missingBaseIdleIsolationLoaderNeedles.Count -eq 0
$baseIdleIsolationHelperPresent = $missingBaseIdleIsolationHelperNeedles.Count -eq 0
$baseIdleIsolationTestPresent = $pipBoyTextKeyIsolationTest.Contains('shouldKeepSelectedPipBoyH2HIdleFromStealingProductionIdle')
Add-C04Check "Retail h2hidle alias is isolated from the production idle source stack" `
    ($baseIdleIsolationCallPresent -and $baseIdleIsolationLoaderPresent -and $baseIdleIsolationHelperPresent -and
     $baseIdleIsolationTestPresent -and $missingBaseIdleIsolationNeedles.Count -eq 0) `
    ([ordered]@{
        callPresent = $baseIdleIsolationCallPresent
        loaderPresent = $baseIdleIsolationLoaderPresent
        helperPresent = $baseIdleIsolationHelperPresent
        testPresent = $baseIdleIsolationTestPresent
        required = $requiredBaseIdleIsolationNeedles
        missing = $missingBaseIdleIsolationNeedles
        loaderMissing = $missingBaseIdleIsolationLoaderNeedles
        helperMissing = $missingBaseIdleIsolationHelperNeedles
    })

$forbiddenGeneratedAnimationNeedles = @(
    'applyPipBoyContactIk',
    'mPipBoyInteractionHandRoot',
    'handContactTargets',
    'physical-control contact IK: source=player-skeleton-extension',
    'FNV Pip-Boy physical right-arm IK'
)
$presentGeneratedAnimationNeedles = @($forbiddenGeneratedAnimationNeedles | Where-Object {
        $pipBoyAnimationSource.Contains($_)
    })
Add-C04Check "Canonical Pip-Boy source contains no generated hand/control animation" `
    ($presentGeneratedAnimationNeedles.Count -eq 0) `
    ([ordered]@{ forbidden = $forbiddenGeneratedAnimationNeedles; present = $presentGeneratedAnimationNeedles })

$forbiddenPresentationNeedles = @(
    'mPipBoyPresentationRoot',
    'retailHeldPipBoySample',
    'raiseState->second.mSpeedMult = 0.f',
    'raiseState->second.setTime(',
    'waverState->second.mSpeedMult = 0.f',
    'waverState->second.setTime(',
    'std::clamp(progress',
    'mPipBoyPresentationProgress *'
)
$presentPresentationNeedles = @($forbiddenPresentationNeedles | Where-Object {
        $pipBoyPresentationSource.Contains($_)
    })
Add-C04Check "Pip-Boy lifecycle is direct authored playback with no wrapper, seek, freeze, or eased presentation sample" `
    ($pipBoyPresentationMatch.Success -and $presentPresentationNeedles.Count -eq 0) `
    ([ordered]@{ functionFound = $pipBoyPresentationMatch.Success; forbidden = $forbiddenPresentationNeedles; present = $presentPresentationNeedles })

$requiredPresentationNeedles = @(
    'play("pipboy",',
    'play("pipboybaseidle",',
    'play("pipboybaseaim",',
    '!isPlaying("pipboy")',
    'disable("pipboybaseidle");',
    'play("pipboywaver",',
    'std::numeric_limits<std::uint32_t>::max()',
    'mPipBoyArmPart->setNodeMask(~osg::Node::NodeMask(0));'
)
$missingPresentationNeedles = @($requiredPresentationNeedles | Where-Object {
        -not $pipBoyPresentationSource.Contains($_)
    })
Add-C04Check "Pip-Boy raise and held clips are selected only through their authored lifecycle" `
    ($pipBoyPresentationMatch.Success -and $missingPresentationNeedles.Count -eq 0) `
    ([ordered]@{ functionFound = $pipBoyPresentationMatch.Success; required = $requiredPresentationNeedles; missing = $missingPresentationNeedles })

$forbiddenRendererTimelineNeedles = @(
    'const float rate = physical ? 4.5f : 5.5f;',
    'mFalloutPipBoyPresentationProgress = std::clamp',
    'mFalloutPipBoyPresentationProgress + (target - mFalloutPipBoyPresentationProgress)'
)
$presentRendererTimelineNeedles = @($forbiddenRendererTimelineNeedles | Where-Object {
        $pipBoyRendererSource.Contains($_)
    })
Add-C04Check "Renderer supplies only physical visibility state, never a C++ Pip-Boy timeline" `
    ($pipBoyRendererMatch.Success -and $presentRendererTimelineNeedles.Count -eq 0 -and
     $pipBoyRendererSource.Contains('mFalloutPipBoyPresentationProgress = physical ? 1.f : 0.f;')) `
    ([ordered]@{ functionFound = $pipBoyRendererMatch.Success; forbidden = $forbiddenRendererTimelineNeedles; present = $presentRendererTimelineNeedles })

$requiredPausedPlaybackNeedles = @(
    'if (paused && mFalloutPipBoyPresentationProgress > 0.001f && mFalloutPlayerFirstPersonAnimation)',
    'mFalloutPlayerFirstPersonAnimation->runAnimation(dt);'
)
$missingPausedPlaybackNeedles = @($requiredPausedPlaybackNeedles | Where-Object {
        -not $pipBoyRenderingSource.Contains($_)
    })
Add-C04Check "Paused physical Pip-Boy advances only the existing authored first-person animation on renderer delta" `
    ($missingPausedPlaybackNeedles.Count -eq 0) `
    ([ordered]@{ required = $requiredPausedPlaybackNeedles; missing = $missingPausedPlaybackNeedles })

$presentationCallIndex = $pipBoyRenderingSource.IndexOf('updateFalloutPipBoyPresentation(dt);')
$pausedPlaybackIndex = $pipBoyRenderingSource.IndexOf($requiredPausedPlaybackNeedles[0])
$cameraAlignmentIndex = $pipBoyRenderingSource.IndexOf('if (mFalloutPlayerFirstPersonAnimation && mFalloutPlayerFirstPersonBasis')
$pausedPlaybackOrderPass = $presentationCallIndex -ge 0 -and $pausedPlaybackIndex -ge 0 -and
    $cameraAlignmentIndex -ge 0 -and $presentationCallIndex -lt $pausedPlaybackIndex -and
    $pausedPlaybackIndex -lt $cameraAlignmentIndex
Add-C04Check "Paused authored Pip-Boy update precedes Camera1st alignment" $pausedPlaybackOrderPass `
    ([ordered]@{ presentationCallIndex = $presentationCallIndex; pausedPlaybackIndex = $pausedPlaybackIndex; cameraAlignmentIndex = $cameraAlignmentIndex })

$unobservedManipulatePath = 'meshes/characters/_male/idleanims/pipboymanipulate.kf'
Add-C04Check "Ordinary MAP/WORLD navigation does not inject the separate unrecorded manipulate sequence" `
    (-not $pipBoyAnimationSource.Contains($unobservedManipulatePath)) `
    ([ordered]@{ forbiddenUntilRetailTrace = $unobservedManipulatePath; present = $pipBoyAnimationSource.Contains($unobservedManipulatePath) })

$expectedFixtureBytes = 3395328
$expectedFixtureSha = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
Add-C04Check "Save330 fixture has the pinned byte length and SHA-256" `
    ($null -ne $fixtureArtifact -and $fixtureArtifact.bytes -eq $expectedFixtureBytes -and
     $fixtureArtifact.sha256 -eq $expectedFixtureSha) `
    ([ordered]@{ expectedBytes = $expectedFixtureBytes; actual = $fixtureArtifact; expectedSha256 = $expectedFixtureSha })

$expectedRoute = "save330-pipboy-map-selection-v1"
$summaryPass = $null -ne $summary -and $summary.schema -eq "nikami-fnv-jam-background-capture-run/v1" -and
    $summary.status -eq "pass" -and $summary.target -eq "OpenMW" -and $summary.scenario -eq "RealSave"
Add-C04Check "Public sequential capture summary passes" $summaryPass `
    ([ordered]@{ schema = if ($null -ne $summary) { $summary.schema } else { $null }; status = if ($null -ne $summary) { $summary.status } else { $null } })

$policyPass = $null -ne $summary -and $summary.policy.windowsAppControlUsed -eq $false -and
    $summary.policy.foregroundActivationUsed -eq $false -and $summary.policy.foregroundInputInjected -eq $false -and
    $summary.policy.capturesRanSequentially -eq $true -and $summary.policy.outputOverwritten -eq $false
Add-C04Check "Capture policy has no host control, concurrency, or overwrite" $policyPass `
    $(if ($null -ne $summary) { $summary.policy } else { $null })

$reportPass = $null -ne $report -and $report.schema -eq "nikami-fnv-real-save-capture/v1" -and
    $report.status -eq "pass" -and $report.target -eq "OpenMW" -and $report.routeId -eq $expectedRoute
Add-C04Check "Real-save report passes the exact C04 route" $reportPass `
    ([ordered]@{ schema = if ($null -ne $report) { $report.schema } else { $null }; status = if ($null -ne $report) { $report.status } else { $null }; routeId = if ($null -ne $report) { $report.routeId } else { $null } })

$reportCapturePass = $null -ne $report -and $report.capture.windowsAppControlUsed -eq $false -and
    $report.capture.foregroundActivationUsed -eq $false -and $report.capture.foregroundInputInjected -eq $false -and
    $report.capture.sourceFrameRetained -eq $true -and $report.capture.nativeFrameCount -eq 4 -and
    $report.capture.telemetryRetained -eq $true -and $report.capture.exactTitleVideoRetained -eq $true -and
    $report.capture.recorderExitCode -eq 0 -and $report.capture.gameTermination -eq "engine-exited" -and
    $report.capture.userConfigurationRestored -eq $true
Add-C04Check "C04 capture retained four native MAP/WORLD transition frames, telemetry, and exact-title video" $reportCapturePass `
    $(if ($null -ne $report) { $report.capture } else { $null })

$requiredAssertions = @(
    "stateManifestPass",
    "ordinaryLoadPathObserved",
    "nativeSaveLoadComplete",
    "playerIdentityRestored",
    "savedTransformApplied",
    "fallbackInventoryAbsent",
    "syntheticPlacementAbsent",
    "nativeWorldFrameRetained",
    "c04MapSelectionFramesRetained",
    "exactTitleVideoRetained"
)
$missingAssertions = @($requiredAssertions | Where-Object {
        $null -eq $report -or $null -eq $report.assertions.PSObject.Properties[$_] -or
        [bool]$report.assertions.$_ -ne $true
    })
Add-C04Check "All ordinary-load and C04 report assertions pass" ($missingAssertions.Count -eq 0) `
    ([ordered]@{ required = $requiredAssertions; missing = $missingAssertions })

$expectedRuntimePath = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot "openmw.exe"))
$reportedRuntimePath = if ($null -ne $report) { [IO.Path]::GetFullPath([string]$report.source.binary.path) } else { '' }
$runtimeSha = if ($null -ne $runtimeArtifact) { $runtimeArtifact.sha256 } else { '' }
$reportedRuntimeSha = if ($null -ne $report) { ([string]$report.source.binary.sha256).ToLowerInvariant() } else { '' }
Add-C04Check "Report binary path and SHA match the staged no-PDB runtime" `
    ($null -ne $runtimeArtifact -and $reportedRuntimePath -eq $expectedRuntimePath -and $reportedRuntimeSha -eq $runtimeSha -and
     (Test-Path -LiteralPath (Join-Path $RuntimeRoot "resources") -PathType Container) -and
     (Test-Path -LiteralPath (Join-Path $RuntimeRoot "osgPlugins-3.6.5") -PathType Container) -and
     @((Get-ChildItem -LiteralPath $RuntimeRoot -Filter "*.pdb" -File -Recurse)).Count -eq 0) `
    ([ordered]@{ expectedPath = $expectedRuntimePath; reportedPath = $reportedRuntimePath; runtime = $runtimeArtifact; reportedSha256 = $reportedRuntimeSha; pdbCount = @((Get-ChildItem -LiteralPath $RuntimeRoot -Filter "*.pdb" -File -Recurse)).Count })

$sourceSavePass = $null -ne $report -and $null -ne $report.source.saveFixture -and
    [IO.Path]::GetFullPath([string]$report.source.saveFixture.path) -eq [IO.Path]::GetFullPath($FixturePath) -and
    [int64]$report.source.saveFixture.bytes -eq $expectedFixtureBytes -and
    ([string]$report.source.saveFixture.sha256).ToLowerInvariant() -eq $expectedFixtureSha
Add-C04Check "Report is hash-locked to the immutable Save330 source" $sourceSavePass `
    $(if ($null -ne $report) { $report.source.saveFixture } else { $null })

$denominatorPass = $null -ne $denominator -and $denominator.schema -eq "nikami-fnv-save330-map-marker-denominator/v1" -and
    [int]$denominator.counts.authored -eq 320 -and [int]$denominator.counts.visible -eq 1 -and
    [int]$denominator.counts.travelEnabled -eq 1 -and [int]$denominator.counts.explicitRuntimeOverrides -eq 0 -and
    [int]$denominator.savedRuntimeState.values.discoveredTravel -eq 1 -and
    (@($denominator.markers | Where-Object { $_.formId -eq "0x03008885" -and $_.name -eq "Southern Passage" -and $_.savedRuntimeState -eq 2 -and $_.authoredCanTravel -eq $true })).Count -eq 1
Add-C04Check "C04 target is the single discovered/travel-enabled Southern Passage denominator row" $denominatorPass `
    $(if ($null -ne $denominator) { $denominator.counts } else { $null })

$requiredNativeFiles = @(
    "Save330-C04-map-world-toggle-contact.png",
    "Save330-C04-map-world-overview.png",
    "Save330-C04-map-marker-focused.png",
    "Save330-C04-map-confirmation-open.png"
)
$nativeFileArtifacts = @($requiredNativeFiles | ForEach-Object { Get-C04Artifact (Join-Path $OpenMwRoot $_) })
$nativeFilesPass = $nativeFileArtifacts.Count -eq 4 -and @($nativeFileArtifacts | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0
Add-C04Check "Named native C04 frames are present and non-empty" $nativeFilesPass $nativeFileArtifacts

$sourceFrameFiles = if (Test-Path -LiteralPath $NativeSourceRoot -PathType Container) {
    @(Get-ChildItem -LiteralPath $NativeSourceRoot -Filter "screenshot*.png" -File | Sort-Object Name)
} else { @() }
$sourceFrameArtifacts = @($sourceFrameFiles | ForEach-Object { Get-C04Artifact $_.FullName })
$sourceFrameHashes = @($sourceFrameArtifacts | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
Add-C04Check "Four distinct native source frame files are retained" `
    ($sourceFrameArtifacts.Count -eq 4 -and @($sourceFrameArtifacts | Where-Object { $_.bytes -le 0 }).Count -eq 0 -and $sourceFrameHashes.Count -eq 4) `
    $sourceFrameArtifacts

Add-C04Check "Exact-title raw video is present and non-empty" `
    ($null -ne $videoArtifact -and $videoArtifact.bytes -gt 0) $videoArtifact
Add-C04Check "Capture stdout/stderr artifacts are retained" `
    ($null -ne $stdoutArtifact -and $null -ne $stderrArtifact) `
    ([ordered]@{ stdout = $stdoutArtifact; stderr = $stderrArtifact })

$nativeLoadPatterns = [ordered]@{
    "native structural parse" = "Native FNV save structural parse complete: masters=10 .* inventoryEntries=50"
    "player identity" = "Native FNV save Player identity restored: base=0x1000007 reference=0x1000014"
    "inventory denominator" = "Native FNV save Player inventory: stacks=50 worn=3"
    "runtime inventory rebuild" = "Native FNV save Player runtime inventory rebuilt: stacks=55 visible=53"
    "transform restoration" = "Native FNV save restored local REFR/ACHR/ACRE transforms: applied=4 missing=0"
    "camera restoration" = "Native FNV save owns camera mode=1 .* firstPersonModelFov="
    "first-person alignment" = "FNV first-person camera alignment: .* exact=1"
    "production map widget marker" = "FNV/ESM4 map: rendered 1 exact world-map markers"
}
foreach ($entry in $nativeLoadPatterns.GetEnumerator()) {
    Add-C04Check ("Native-load log contains " + $entry.Key) (Test-C04Pattern $stdout $entry.Value) $entry.Value
}

$markerLog = "0x3008885"
$c04Patterns = [ordered]@{
    "restored marker source" = "FNV C04 natural Pip-Boy path: marker=$markerLog source=restored-save330-state"
    "map pane selected" = "FNV C04 natural map selection: phase=map-pane-selected pane=0 physical=1 action=MAP path=physical-pipboy-production status=pass"
    "world map opened" = ('FNV C04 natural map selection: phase=world-map-opened marker=' + $markerLog + ' name="Southern Passage" state=2 pane=0 worldMap=1 rendered=1 path=physical-pipboy-production status=pass')
    "overview production map pan" = "FNV C04 natural map selection: phase=world-map-overview-pan pane=0 worldMap=1 action=MAP-PAN-RIGHT panBefore=[-+0-9.eE]+ panAfter=[-+0-9.eE]+ path=physical-pipboy-production status=pass"
    "retail held-arm timeline" = "FNV Pip-Boy retail held-arm: source=meshes/characters/_male/idleanims/1stppipboywaver.kf sequence=authored-loop connectedPose=1"
    "retail first-person FOV" = "FNV Pip-Boy first-person FOV: source=xNVSE-save330-retail observedFirstPerson=47(?:\.0+)? requestedVertical=47(?:\.0+)? baselineVertical=42\.653[0-9]* presentationActive=1 applied=1"
    "scroll-knob action" = "FNV C04 natural Pip-Boy interaction: phase=world-map-toggle-contact pulse=0\.(4[5-9][0-9]*|5[0-4][0-9]*) control=ScrollKnob (?:scheduled|dispatched)=1 captureAfterActionInput=1 source=production-map-action"
    "retail held scroll-knob input" = "FNV Pip-Boy retail held input: source=xNVSE-save330 sequence=retail-waver-resting-right-hand waverBound=1 waverRange=0-6 waverFrequency=1 variant=4 control=ScrollKnob manipulateObservedRetail=0 retailDataOnly=1"
    "production icon overlay" = "FNV Pip-Boy MAP: overlay marker icons drawn=1 source=restored-production-marker-state"
    "marker focused" = ('FNV C04 natural map selection: phase=marker-focused marker=' + $markerLog + ' name="Southern Passage" state=2 selected=1 tooltipNameMatchesFormId=1 pane=0 worldMap=1 path=production-map-focus status=pass')
    "exact confirmation" = ('FNV C04 confirmation: opened=1 marker=' + $markerLog + ' name="Southern Passage" text="Fast travel to Southern Passage\?" confirmed=0 path=production-map-confirmation status=pass')
    "contact native frame" = "FNV C04 native frame: state=map-world-toggle-contact index=0 captureAfterActionInput=[01] source=ScreenCaptureHandler"
    "overview native frame" = "FNV C04 native frame: state=map-world-overview index=1 captureAfterActionInput=[01] source=ScreenCaptureHandler"
    "focused native frame" = "FNV C04 native frame: state=map-marker-focused index=2 captureAfterActionInput=[01] source=ScreenCaptureHandler"
    "confirmation native frame" = "FNV C04 native frame: state=map-confirmation-open index=3 captureAfterActionInput=[01] source=ScreenCaptureHandler"
    "complete" = "FNV C04 natural Pip-Boy path: phase=complete marker=$markerLog captured=4 confirmed=0 travelExecuted=0 status=pass"
}
foreach ($entry in $c04Patterns.GetEnumerator()) {
    Add-C04Check ("C04 log contains " + $entry.Key) (Test-C04Pattern $stdout $entry.Value) $entry.Value
}

# The overview native frame must be a second real production MAP state, rather
# than a second write of the idle contact pixels.  Verify that the public
# ScrollKnob MAP-pan action actually advanced the terminal's X pan coordinate.
$overviewPanMatch = [regex]::Match($stdout,
    'FNV C04 natural map selection: phase=world-map-overview-pan pane=0 worldMap=1 action=MAP-PAN-RIGHT panBefore=(?<before>[-+0-9.eE]+) panAfter=(?<after>[-+0-9.eE]+) path=physical-pipboy-production status=pass')
$overviewPanPass = $overviewPanMatch.Success
if ($overviewPanPass) {
    $overviewPanBefore = [double]::Parse($overviewPanMatch.Groups['before'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $overviewPanAfter = [double]::Parse($overviewPanMatch.Groups['after'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $overviewPanPass = $overviewPanAfter -gt $overviewPanBefore
}
Add-C04Check "C04 overview is a distinct production MAP pan state" $overviewPanPass `
    $(if ($overviewPanMatch.Success) { [ordered]@{ before = $overviewPanMatch.Groups['before'].Value; after = $overviewPanMatch.Groups['after'].Value } } else { $null })

# The retained retail Save330 capture proves ordinary MAP/WORLD input has a
# held left-arm waver and a resting right hand. C04 must not insert a second
# input clip, generated reach, control motion, or a fabricated hand-at-knob
# screenshot.
$syntheticReachMatches = [regex]::Matches($stdout,
    'FNV Pip-Boy (physical-control contact IK|physical right-arm IK)|FNV Pip-Boy retail held input:.*physicalControl=1')
$syntheticReachPass = $syntheticReachMatches.Count -eq 0
Add-C04Check "Canonical MAP/WORLD input stays on the retail held waver without generated hand/control motion" $syntheticReachPass `
    ([ordered]@{ syntheticReachSamples = $syntheticReachMatches.Count })

$forbiddenCaptureTerms = @("AppActivate", "SetForegroundWindow", "SendInput", "Computer Use", "showFalloutMapMarker", "unlock-all", "unlock all")
$forbiddenTermsFound = @($forbiddenCaptureTerms | Where-Object { $stdout -match [regex]::Escape($_) -or $stderr -match [regex]::Escape($_) })
Add-C04Check "C04 runtime logs contain no host-control or unlock shortcut" ($forbiddenTermsFound.Count -eq 0) $forbiddenTermsFound

$validation = [ordered]@{
    schema = "nikami-fnv-real-save-c04-validation/v1"
    status = if ($script:c04AllPass) { "pass" } else { "fail" }
    objective = "Validate natural Save330 Pip-Boy MAP/WORLD selection, production marker icon rendering, focus, and unconfirmed fast-travel confirmation."
    captureRoot = $CaptureRoot
    routeId = $expectedRoute
    marker = [ordered]@{
        formId = "FormId:0x03008885"
        logFormId = $markerLog
        name = "Southern Passage"
        savedRuntimeState = 2
        iconType = "cave"
        confirmation = "Fast travel to Southern Passage?"
        confirmed = 0
        travelExecuted = 0
    }
    source = [ordered]@{
        fixture = $fixtureArtifact
        denominator = $denominatorArtifact
        runtime = $runtimeArtifact
        pipBoyAnimationSource = $pipBoyAnimationSourceArtifact
        pipBoyRenderingSource = $pipBoyRenderingSourceArtifact
        publicSummary = $summaryArtifact
        captureReport = $reportArtifact
        stdout = $stdoutArtifact
        stderr = $stderrArtifact
        video = $videoArtifact
        namedNativeFrames = $nativeFileArtifacts
        nativeSourceFrames = $sourceFrameArtifacts
    }
    checks = @($checks)
}
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

if (-not $script:c04AllPass) {
    throw "C04 validation failed. See $ValidationPath"
}

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $checks.Count
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-C04Artifact $ValidationPath
    captureRoot = $CaptureRoot
}
