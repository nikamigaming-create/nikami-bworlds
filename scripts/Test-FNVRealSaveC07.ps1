[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\\code\\nikami-worlds",
    [string]$CaptureRoot = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c07-openmw-20260802-185000",
    [string]$RuntimeRoot = "D:\\code\\nikami-worlds\\local\\openmw-real-save330-c07-travel-persistence-20260802-183000",
    [string]$FixturePath = "D:\\code\\nikami-worlds\\local\\retail-real-save-fixtures\\NikamiRealWorldSave330-20260802.fos",
    [string]$DenominatorPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-player-denominator.json",
    [string]$MarkerDenominatorPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-map-marker-denominator.json",
    [string]$A03ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-a03-validation.json",
    [string]$ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c07-travel-persistence-validation.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$CaptureRoot = [IO.Path]::GetFullPath($CaptureRoot)
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$FixturePath = [IO.Path]::GetFullPath($FixturePath)
$DenominatorPath = [IO.Path]::GetFullPath($DenominatorPath)
$MarkerDenominatorPath = [IO.Path]::GetFullPath($MarkerDenominatorPath)
$A03ValidationPath = [IO.Path]::GetFullPath($A03ValidationPath)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)

if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing C07 validation artifact: $ValidationPath"
}

$OpenMwRoot = Join-Path $CaptureRoot "openmw"
$FirstRoot = Join-Path $OpenMwRoot "first-travel"
$ReloadRoot = Join-Path $OpenMwRoot "after-cold-reload"
$SummaryPath = Join-Path $CaptureRoot "background-capture-summary.json"
$ReportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$FirstReportPath = Join-Path $FirstRoot "real-save-capture-report.json"
$ReloadReportPath = Join-Path $ReloadRoot "real-save-capture-report.json"
$FirstStdoutPath = Join-Path $FirstRoot "openmw.stdout.log"
$FirstStderrPath = Join-Path $FirstRoot "openmw.stderr.log"
$ReloadStdoutPath = Join-Path $ReloadRoot "openmw.stdout.log"
$ReloadStderrPath = Join-Path $ReloadRoot "openmw.stderr.log"
$FirstVideoPath = Join-Path $FirstRoot "OpenMW-Save330-C07-travel-persistence-first-exact-title-raw.mp4"
$ReloadVideoPath = Join-Path $ReloadRoot "OpenMW-Save330-C07-travel-persistence-reload-exact-title-raw.mp4"
$FirstStatePath = Join-Path $FirstRoot "real-save-state.json"
$ReloadStatePath = Join-Path $ReloadRoot "real-save-state.json"
$GeneratedSavePath = Join-Path $OpenMwRoot "Save330-C07-travel-persistence.omwsave"
$SaveManifestPath = Join-Path $OpenMwRoot "save330-c07-production-save-manifest.json"
$FirstNativeSourceRoot = Join-Path $FirstRoot "native-source-frames"
$ReloadNativeSourceRoot = Join-Path $ReloadRoot "native-source-frames"

$checks = [Collections.Generic.List[object]]::new()
$script:c07AllPass = $true

function Add-C07Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:c07AllPass = $false }
}

function Get-C07Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Read-C07Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { return $null }
}

function Test-C07Pattern {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    return $Text -match $Pattern
}

function Get-C07B04Data {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $inventoryRows = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, 'FNV B04 persistence inventory item: form=FormId:([0-9a-fx]+) count=([0-9]+) visible=([01]) equipped=([01])')) {
        $null = $inventoryRows.Add([ordered]@{
                form = $match.Groups[1].Value.ToLowerInvariant()
                count = [int]$match.Groups[2].Value
                visible = [int]$match.Groups[3].Value
                equipped = [int]$match.Groups[4].Value
            })
    }

    $equippedRows = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, 'FNV B04 persistence equipped: slot=([0-9]+) form=FormId:([0-9a-fx]+)')) {
        $null = $equippedRows.Add([ordered]@{
                slot = [int]$match.Groups[1].Value
                form = $match.Groups[2].Value.ToLowerInvariant()
            })
    }

    $modifierRows = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, 'FNV B04 persistence actor-value modifier: actorValue=([0-9]+) permanent=([-0-9.]+) damage=([-0-9.]+) temporary=([-0-9.]+)')) {
        $null = $modifierRows.Add([ordered]@{
                actorValue = [int]$match.Groups[1].Value
                permanent = [double]$match.Groups[2].Value
                damage = [double]$match.Groups[3].Value
                temporary = [double]$match.Groups[4].Value
            })
    }

    $markerRows = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, 'FNV B04 persistence map marker: id=FormId:([0-9a-fx]+) name="(.*?)" state=([0-9]+) override=([0-9]+) authoredVisible=([01]) authoredCanTravel=([01])')) {
        $null = $markerRows.Add([ordered]@{
                id = $match.Groups[1].Value.ToLowerInvariant()
                name = $match.Groups[2].Value
                state = [int]$match.Groups[3].Value
                override = [uint32]$match.Groups[4].Value
                authoredVisible = [int]$match.Groups[5].Value
                authoredCanTravel = [int]$match.Groups[6].Value
            })
    }

    $inventorySummary = $null
    $inventoryMatch = [regex]::Match($Text, 'FNV B04 persistence: OpenMW save player inventory stacks=([0-9]+) visible=([0-9]+) worn=([0-9]+) totalItems=([0-9]+) health=([-0-9.]+) actionPoints=([-0-9.]+) actionPointsMax=([-0-9.]+)')
    if ($inventoryMatch.Success) {
        $inventorySummary = [ordered]@{
            stacks = [int]$inventoryMatch.Groups[1].Value
            visible = [int]$inventoryMatch.Groups[2].Value
            worn = [int]$inventoryMatch.Groups[3].Value
            totalItems = [int]$inventoryMatch.Groups[4].Value
            health = [double]$inventoryMatch.Groups[5].Value
            actionPoints = [double]$inventoryMatch.Groups[6].Value
            actionPointsMax = [double]$inventoryMatch.Groups[7].Value
        }
    }

    $identity = $null
    $identityMatch = [regex]::Match($Text, 'FNV B04 persistence: OpenMW save player identity initialized=([01]) base=FormId:([0-9a-fx]+) reference=FormId:([0-9a-fx]+)')
    if ($identityMatch.Success) {
        $identity = [ordered]@{
            initialized = [int]$identityMatch.Groups[1].Value
            base = $identityMatch.Groups[2].Value.ToLowerInvariant()
            reference = $identityMatch.Groups[3].Value.ToLowerInvariant()
        }
    }

    $quest = $null
    $questMatch = [regex]::Match($Text, 'FNV B04 persistence: OpenMW save quest state states=([0-9]+) stages=([0-9]+) objectives=([0-9]+) variables=([0-9]+) active=FormId:([0-9a-fx]+)')
    if ($questMatch.Success) {
        $quest = [ordered]@{
            states = [int]$questMatch.Groups[1].Value
            stages = [int]$questMatch.Groups[2].Value
            objectives = [int]$questMatch.Groups[3].Value
            variables = [int]$questMatch.Groups[4].Value
            active = $questMatch.Groups[5].Value.ToLowerInvariant()
        }
    }

    $globals = $null
    $globalsMatch = [regex]::Match($Text, 'FNV B04 persistence: OpenMW save globals count=([0-9]+)')
    if ($globalsMatch.Success) { $globals = [int]$globalsMatch.Groups[1].Value }

    $markerSummary = $null
    $markerSummaryMatch = [regex]::Match($Text, 'FNV B04 persistence: OpenMW save map markers authored=([0-9]+) visible=([0-9]+) travel=([0-9]+) overrides=([0-9]+)')
    if ($markerSummaryMatch.Success) {
        $markerSummary = [ordered]@{
            authored = [int]$markerSummaryMatch.Groups[1].Value
            visible = [int]$markerSummaryMatch.Groups[2].Value
            travel = [int]$markerSummaryMatch.Groups[3].Value
            overrides = [int]$markerSummaryMatch.Groups[4].Value
        }
    }

    $inventorySignature = @($inventoryRows | ForEach-Object { '{0}:{1}:{2}:{3}' -f $_.form, $_.count, $_.visible, $_.equipped } | Sort-Object) -join '|'
    $equippedSignature = @($equippedRows | ForEach-Object { '{0}:{1}' -f $_.slot, $_.form } | Sort-Object) -join '|'
    $modifierSignature = @($modifierRows | ForEach-Object { '{0}:{1}:{2}:{3}' -f $_.actorValue, $_.permanent, $_.damage, $_.temporary } | Sort-Object) -join '|'
    $markerSignature = @($markerRows | ForEach-Object { '{0}:{1}:{2}:{3}:{4}:{5}' -f $_.id, $_.name, $_.state, $_.override, $_.authoredVisible, $_.authoredCanTravel } | Sort-Object) -join '|'

    return [ordered]@{
        inventoryRows = @($inventoryRows)
        equippedRows = @($equippedRows)
        modifierRows = @($modifierRows)
        markerRows = @($markerRows)
        inventorySummary = $inventorySummary
        identity = $identity
        quest = $quest
        globals = $globals
        markerSummary = $markerSummary
        inventorySignature = $inventorySignature
        equippedSignature = $equippedSignature
        modifierSignature = $modifierSignature
        markerSignature = $markerSignature
    }
}

function Get-C07TravelRow {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][ValidateSet('first-arrival', 'reload-before-map', 'reload-map-reopened', 'second-arrival')][string]$Kind
    )

    if ($Kind -eq 'first-arrival' -or $Kind -eq 'second-arrival') {
        $phaseName = if ($Kind -eq 'first-arrival') { 'first-travel-arrived' } else { 'second-travel-arrived' }
        $pattern = 'FNV C07 persistence: phase=' + $phaseName + ' marker=0x([0-9a-f]+) cell=FormId:0x([0-9a-f]+) worldspace=FormId:0x([0-9a-f]+) pos=\(([-0-9.]+),([-0-9.]+),([-0-9.]+)\) beforeHour=([-0-9.]+) afterHour=([-0-9.]+) timeAdvanced=([01]) sameDestinationCell=([01]) menuClosed=([01]) controlsEnabled=([01]) travelCleared=([01]) cameraMode=([01])'
        $match = [regex]::Match($Text, $pattern)
        if (-not $match.Success) { return $null }
        return [ordered]@{
            kind = $Kind
            marker = $match.Groups[1].Value.ToLowerInvariant()
            cell = $match.Groups[2].Value.ToLowerInvariant()
            worldspace = $match.Groups[3].Value.ToLowerInvariant()
            position = @([double]$match.Groups[4].Value, [double]$match.Groups[5].Value, [double]$match.Groups[6].Value)
            beforeHour = [double]$match.Groups[7].Value
            afterHour = [double]$match.Groups[8].Value
            timeAdvanced = [int]$match.Groups[9].Value
            sameDestinationCell = [int]$match.Groups[10].Value
            menuClosed = [int]$match.Groups[11].Value
            controlsEnabled = [int]$match.Groups[12].Value
            travelCleared = [int]$match.Groups[13].Value
            cameraMode = [int]$match.Groups[14].Value
        }
    }

    if ($Kind -eq 'reload-before-map') {
        $pattern = 'FNV C07 persistence: phase=reload-before-map marker=0x([0-9a-f]+) markerState=([0-9]+) mapOpen=([01]) cell="FormId:0x([0-9a-f]+)" worldspace="FormId:0x([0-9a-f]+)" pos=\(([-0-9.]+),([-0-9.]+),([-0-9.]+)\) hour=([-0-9.]+) cameraMode=([01])'
    } else {
        $pattern = 'FNV C07 persistence: phase=reload-map-reopened marker=0x([0-9a-f]+) name="Southern Passage" markerState=([0-9]+) mapOpen=([01]) worldMap=([01]) selected=([01]) cell="FormId:0x([0-9a-f]+)" worldspace="FormId:0x([0-9a-f]+)" pos=\(([-0-9.]+),([-0-9.]+),([-0-9.]+)\) hour=([-0-9.]+) cameraMode=([01])'
    }
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    if ($Kind -eq 'reload-before-map') {
        return [ordered]@{
            kind = $Kind
            marker = $match.Groups[1].Value.ToLowerInvariant()
            markerState = [int]$match.Groups[2].Value
            mapOpen = [int]$match.Groups[3].Value
            cell = $match.Groups[4].Value.ToLowerInvariant()
            worldspace = $match.Groups[5].Value.ToLowerInvariant()
            position = @([double]$match.Groups[6].Value, [double]$match.Groups[7].Value, [double]$match.Groups[8].Value)
            hour = [double]$match.Groups[9].Value
            cameraMode = [int]$match.Groups[10].Value
        }
    }
    return [ordered]@{
        kind = $Kind
        marker = $match.Groups[1].Value.ToLowerInvariant()
        markerState = [int]$match.Groups[2].Value
        mapOpen = [int]$match.Groups[3].Value
        worldMap = [int]$match.Groups[4].Value
        selected = [int]$match.Groups[5].Value
        cell = $match.Groups[6].Value.ToLowerInvariant()
        worldspace = $match.Groups[7].Value.ToLowerInvariant()
        position = @([double]$match.Groups[8].Value, [double]$match.Groups[9].Value, [double]$match.Groups[10].Value)
        hour = [double]$match.Groups[11].Value
        cameraMode = [int]$match.Groups[12].Value
    }
}

function Test-C07Position {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Left,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Right,
        [double]$Tolerance = 0.5
    )
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if (@($Left).Count -ne 3 -or @($Right).Count -ne 3) { return $false }
    for ($index = 0; $index -lt 3; $index++) {
        if ([math]::Abs(([double]$Left[$index]) - ([double]$Right[$index])) -gt $Tolerance) { return $false }
    }
    return $true
}

$summary = Read-C07Json $SummaryPath
$report = Read-C07Json $ReportPath
$firstReport = Read-C07Json $FirstReportPath
$reloadReport = Read-C07Json $ReloadReportPath
$denominator = Read-C07Json $DenominatorPath
$markerDenominator = Read-C07Json $MarkerDenominatorPath
$a03 = Read-C07Json $A03ValidationPath
$saveManifest = Read-C07Json $SaveManifestPath
$firstState = Read-C07Json $FirstStatePath
$reloadState = Read-C07Json $ReloadStatePath
$firstStdout = if (Test-Path -LiteralPath $FirstStdoutPath -PathType Leaf) { Get-Content -Raw -LiteralPath $FirstStdoutPath } else { '' }
$firstStderr = if (Test-Path -LiteralPath $FirstStderrPath -PathType Leaf) { Get-Content -Raw -LiteralPath $FirstStderrPath } else { '' }
$reloadStdout = if (Test-Path -LiteralPath $ReloadStdoutPath -PathType Leaf) { Get-Content -Raw -LiteralPath $ReloadStdoutPath } else { '' }
$reloadStderr = if (Test-Path -LiteralPath $ReloadStderrPath -PathType Leaf) { Get-Content -Raw -LiteralPath $ReloadStderrPath } else { '' }

$fixtureArtifact = Get-C07Artifact $FixturePath
$denominatorArtifact = Get-C07Artifact $DenominatorPath
$markerDenominatorArtifact = Get-C07Artifact $MarkerDenominatorPath
$a03Artifact = Get-C07Artifact $A03ValidationPath
$runtimeArtifact = Get-C07Artifact (Join-Path $RuntimeRoot "openmw.exe")
$summaryArtifact = Get-C07Artifact $SummaryPath
$reportArtifact = Get-C07Artifact $ReportPath
$firstReportArtifact = Get-C07Artifact $FirstReportPath
$reloadReportArtifact = Get-C07Artifact $ReloadReportPath
$firstStdoutArtifact = Get-C07Artifact $FirstStdoutPath
$firstStderrArtifact = Get-C07Artifact $FirstStderrPath
$reloadStdoutArtifact = Get-C07Artifact $ReloadStdoutPath
$reloadStderrArtifact = Get-C07Artifact $ReloadStderrPath
$firstVideoArtifact = Get-C07Artifact $FirstVideoPath
$reloadVideoArtifact = Get-C07Artifact $ReloadVideoPath
$generatedSaveArtifact = Get-C07Artifact $GeneratedSavePath
$saveManifestArtifact = Get-C07Artifact $SaveManifestPath

Add-C07Check "Public background-capture summary is retained" ($null -ne $summaryArtifact) $summaryArtifact
Add-C07Check "Combined C07 real-save report is retained" ($null -ne $reportArtifact) $reportArtifact
Add-C07Check "Both C07 phase reports are retained" ($null -ne $firstReportArtifact -and $null -ne $reloadReportArtifact) ([ordered]@{ first = $firstReportArtifact; reload = $reloadReportArtifact })
Add-C07Check "Canonical Save330 fixture is retained" ($null -ne $fixtureArtifact) $fixtureArtifact
Add-C07Check "Both normalized and map-marker denominators are retained" ($null -ne $denominatorArtifact -and $null -ne $markerDenominatorArtifact) ([ordered]@{ player = $denominatorArtifact; markers = $markerDenominatorArtifact })
Add-C07Check "A03 normalized-plan validation is retained and passes" ($null -ne $a03 -and $a03.schema -eq "nikami-fnv-real-save-a03-validation/v1" -and $a03.status -eq "pass" -and $null -ne $a03Artifact) $(if ($null -ne $a03) { $a03 } else { $null })

$expectedFixtureBytes = 3395328
$expectedFixtureSha = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
Add-C07Check "Save330 fixture has the pinned byte length and SHA-256" ($null -ne $fixtureArtifact -and $fixtureArtifact.bytes -eq $expectedFixtureBytes -and $fixtureArtifact.sha256 -eq $expectedFixtureSha) ([ordered]@{ expectedBytes = $expectedFixtureBytes; actual = $fixtureArtifact; expectedSha256 = $expectedFixtureSha })

$expectedRoute = "save330-travel-persistence-v1"
$summaryPass = $null -ne $summary -and $summary.schema -eq "nikami-fnv-jam-background-capture-run/v1" -and $summary.status -eq "pass" -and $summary.target -eq "OpenMW" -and $summary.scenario -eq "RealSave" -and $null -ne $summary.realSave -and $summary.realSave.status -eq "pass" -and $summary.realSave.routeId -eq $expectedRoute
Add-C07Check "Public sequential capture summary passes the C07 route" $summaryPass ([ordered]@{ schema = if ($null -ne $summary) { $summary.schema } else { $null }; status = if ($null -ne $summary) { $summary.status } else { $null }; routeId = if ($null -ne $summary -and $null -ne $summary.realSave) { $summary.realSave.routeId } else { $null } })

$policyPass = $null -ne $summary -and $summary.policy.windowsAppControlUsed -eq $false -and $summary.policy.foregroundActivationUsed -eq $false -and $summary.policy.foregroundInputInjected -eq $false -and $summary.policy.capturesRanSequentially -eq $true -and $summary.policy.outputOverwritten -eq $false
Add-C07Check "Capture policy has no host control, concurrency, or overwrite" $policyPass $(if ($null -ne $summary) { $summary.policy } else { $null })

$reportPass = $null -ne $report -and $report.schema -eq "nikami-fnv-real-save-capture/v1" -and $report.status -eq "pass" -and $report.target -eq "OpenMW" -and $report.routeId -eq $expectedRoute
Add-C07Check "Combined report passes the exact C07 route" $reportPass ([ordered]@{ schema = if ($null -ne $report) { $report.schema } else { $null }; status = if ($null -ne $report) { $report.status } else { $null }; routeId = if ($null -ne $report) { $report.routeId } else { $null } })

$requiredCombinedAssertions = @("productionSaveCreated", "firstTravelSavePhasePass", "cleanQuitAfterSave", "coldReloadPhasePass", "mapReopenedAfterColdReload", "secondTravelPass")
$missingCombinedAssertions = @($requiredCombinedAssertions | Where-Object { $null -eq $report -or $null -eq $report.assertions.PSObject.Properties[$_] -or [bool]$report.assertions.$_ -ne $true })
Add-C07Check "All combined C07 assertions pass" ($missingCombinedAssertions.Count -eq 0) ([ordered]@{ required = $requiredCombinedAssertions; missing = $missingCombinedAssertions })

$phaseReportData = @(
    [ordered]@{ name = "first"; report = $firstReport; phase = "first"; root = $FirstRoot; stdout = $firstStdout; stderr = $firstStderr; video = $firstVideoArtifact; reportArtifact = $firstReportArtifact; state = $firstState },
    [ordered]@{ name = "reload"; report = $reloadReport; phase = "reload"; root = $ReloadRoot; stdout = $reloadStdout; stderr = $reloadStderr; video = $reloadVideoArtifact; reportArtifact = $reloadReportArtifact; state = $reloadState }
)
foreach ($phaseData in $phaseReportData) {
    $phaseReportPass = $null -ne $phaseData.report -and $phaseData.report.schema -eq "nikami-fnv-real-save-capture/v1" -and $phaseData.report.status -eq "pass" -and $phaseData.report.target -eq "OpenMW" -and $phaseData.report.routeId -eq $expectedRoute
    Add-C07Check ("$($phaseData.name) phase report passes") $phaseReportPass ([ordered]@{ name = $phaseData.name; status = if ($null -ne $phaseData.report) { $phaseData.report.status } else { $null }; routeId = if ($null -ne $phaseData.report) { $phaseData.report.routeId } else { $null } })
    $phaseCapture = if ($null -ne $phaseData.report) { $phaseData.report.capture } else { $null }
    $phaseCapturePass = $null -ne $phaseCapture -and $phaseCapture.windowsAppControlUsed -eq $false -and $phaseCapture.foregroundActivationUsed -eq $false -and $phaseCapture.foregroundInputInjected -eq $false -and $phaseCapture.sourceFrameRetained -eq $true -and $phaseCapture.nativeFrameCount -eq 3 -and @($phaseCapture.nativeFramePaths).Count -eq 3 -and $phaseCapture.telemetryRetained -eq $true -and $phaseCapture.exactTitleVideoRetained -eq $true -and $phaseCapture.recorderExitCode -eq 0 -and $phaseCapture.gameTermination -eq "engine-exited" -and $phaseCapture.userConfigurationRestored -eq $true
    Add-C07Check ("$($phaseData.name) phase retained three native frames, telemetry, exact-title video, and clean termination") $phaseCapturePass $phaseCapture
    $phaseAssertions = @("stateManifestPass", "ordinaryLoadPathObserved", "nativeSaveLoadComplete", "playerIdentityRestored", "savedTransformApplied", "fallbackInventoryAbsent", "syntheticPlacementAbsent", "nativeWorldFrameRetained", "c07TravelPersistenceFramesRetained", "exactTitleVideoRetained")
    $missingPhaseAssertions = @($phaseAssertions | Where-Object { $null -eq $phaseData.report -or $null -eq $phaseData.report.assertions.PSObject.Properties[$_] -or [bool]$phaseData.report.assertions.$_ -ne $true })
    Add-C07Check ("$($phaseData.name) phase ordinary-load and C07 assertions pass") ($missingPhaseAssertions.Count -eq 0) ([ordered]@{ required = $phaseAssertions; missing = $missingPhaseAssertions })
    Add-C07Check ("$($phaseData.name) phase stdout and stderr artifacts are retained") ($null -ne (Get-C07Artifact (Join-Path $phaseData.root "openmw.stdout.log")) -and $null -ne (Get-C07Artifact (Join-Path $phaseData.root "openmw.stderr.log"))) ([ordered]@{ stdout = Get-C07Artifact (Join-Path $phaseData.root "openmw.stdout.log"); stderr = Get-C07Artifact (Join-Path $phaseData.root "openmw.stderr.log") })
}

$expectedRuntimePath = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot "openmw.exe"))
$reportedRuntimePath = if ($null -ne $report) { [IO.Path]::GetFullPath([string]$report.source.binary.path) } else { '' }
$reportedRuntimeSha = if ($null -ne $report) { ([string]$report.source.binary.sha256).ToLowerInvariant() } else { '' }
$pdbCount = @((Get-ChildItem -LiteralPath $RuntimeRoot -Filter "*.pdb" -File -Recurse -ErrorAction SilentlyContinue)).Count
$runtimePass = $null -ne $runtimeArtifact -and $runtimeArtifact.bytes -gt 0 -and $reportedRuntimePath -eq $expectedRuntimePath -and $reportedRuntimeSha -eq $runtimeArtifact.sha256 -and (Test-Path -LiteralPath (Join-Path $RuntimeRoot "resources") -PathType Container) -and (Test-Path -LiteralPath (Join-Path $RuntimeRoot "osgPlugins-3.6.5") -PathType Container) -and $pdbCount -eq 0
Add-C07Check "Report matches the supplied staged no-PDB runtime" $runtimePass ([ordered]@{ expectedPath = $expectedRuntimePath; reportedPath = $reportedRuntimePath; runtime = $runtimeArtifact; reportedSha256 = $reportedRuntimeSha; pdbCount = $pdbCount })

$reportedFixturePass = $null -ne $report -and $null -ne $report.source.saveFixture -and [IO.Path]::GetFullPath([string]$report.source.saveFixture.path) -eq [IO.Path]::GetFullPath($FixturePath) -and [int64]$report.source.saveFixture.bytes -eq $expectedFixtureBytes -and ([string]$report.source.saveFixture.sha256).ToLowerInvariant() -eq $expectedFixtureSha
$normalizedSourcePass = $null -ne $denominator -and $denominator.schema -eq "nikami-fnv-save-player-denominator/v2" -and $denominator.status -eq "normalized-save-denominator" -and [IO.Path]::GetFullPath(([string]$denominator.source.path).Replace('/', '\')) -eq [IO.Path]::GetFullPath($FixturePath) -and [int64]$denominator.source.bytes -eq $expectedFixtureBytes -and ([string]$denominator.source.sha256).ToLowerInvariant() -eq $expectedFixtureSha
Add-C07Check "Report and normalized plan are hash-locked to immutable Save330 provenance" ($reportedFixturePass -and $normalizedSourcePass) ([ordered]@{ reportSource = if ($null -ne $report) { $report.source.saveFixture } else { $null }; normalizedSource = if ($null -ne $denominator) { $denominator.source } else { $null } })

$normalizedPlanPass = $null -ne $denominator -and $denominator.normalizedLoadPlan.status -eq "resolved" -and @($denominator.masters).Count -eq 10 -and @($denominator.inventory.finalTotals).Count -eq 50 -and @($denominator.inventory.contributions).Count -eq 52 -and @($denominator.inventory.conditionedStacks).Count -eq 24 -and @($denominator.equippedRows.wornVisualItems).Count -eq 3 -and @($denominator.actorValues.modifiers).Count -eq 1 -and @($denominator.globals).Count -eq 200 -and @($denominator.questProgress.objectives).Count -eq 4 -and @($denominator.discoveredMarkerStates).Count -eq 1 -and $denominator.player.baseRecord.provenance.kind -eq "content-record" -and $denominator.player.baseRecord.provenance.contentFile -eq "FalloutNV.esm" -and $denominator.player.referenceRecord.provenance.kind -eq "content-record" -and $denominator.player.referenceRecord.provenance.contentFile -eq "FalloutNV.esm"
Add-C07Check "Normalized FalloutSaveLoadPlan retains final totals, worn rows, modifiers, and source provenance" $normalizedPlanPass $(if ($null -ne $denominator) { [ordered]@{ masters = @($denominator.masters).Count; finalTotals = @($denominator.inventory.finalTotals).Count; conditionedStacks = @($denominator.inventory.conditionedStacks).Count; wornVisualItems = @($denominator.equippedRows.wornVisualItems).Count; actorValueModifiers = @($denominator.actorValues.modifiers).Count; globals = @($denominator.globals).Count; objectives = @($denominator.questProgress.objectives).Count; normalizedLoadPlan = $denominator.normalizedLoadPlan; baseProvenance = $denominator.player.baseRecord.provenance; referenceProvenance = $denominator.player.referenceRecord.provenance } } else { $null })

$expectedMarkerPass = $null -ne $markerDenominator -and $markerDenominator.schema -eq "nikami-fnv-save330-map-marker-denominator/v1" -and [int]$markerDenominator.counts.authored -eq 320 -and [int]$markerDenominator.counts.visible -eq 1 -and [int]$markerDenominator.counts.travelEnabled -eq 1 -and [int]$markerDenominator.savedRuntimeState.values.discoveredTravel -eq 1 -and @($markerDenominator.markers | Where-Object { $_.formId -eq "0x03008885" -and $_.name -eq "Southern Passage" -and $_.iconType -eq 5 -and $_.worldspace -eq "0x0300683B" -and $_.cell -eq "0x0300688F" -and $_.savedRuntimeState -eq 2 -and $_.authoredVisible -eq $true -and $_.authoredCanTravel -eq $true }).Count -eq 1
Add-C07Check "Retail Save330 marker denominator has the canonical discovered travel icon" $expectedMarkerPass $(if ($null -ne $markerDenominator) { [ordered]@{ counts = $markerDenominator.counts; savedRuntimeState = $markerDenominator.savedRuntimeState; marker = @($markerDenominator.markers | Where-Object { $_.name -eq "Southern Passage" }) } } else { $null })

$manifestPass = $null -ne $saveManifest -and $saveManifest.schema -eq "nikami-fnv-real-save-c07-production-save/v1" -and $saveManifest.cleanQuitObserved -eq $true -and $null -ne $generatedSaveArtifact -and $generatedSaveArtifact.bytes -gt 0 -and [IO.Path]::GetFullPath([string]$saveManifest.generatedSave.path) -eq $generatedSaveArtifact.path -and [int64]$saveManifest.generatedSave.bytes -eq $generatedSaveArtifact.bytes -and ([string]$saveManifest.generatedSave.sha256).ToLowerInvariant() -eq $generatedSaveArtifact.sha256 -and [int64]$saveManifest.sourceFixture.bytes -eq $expectedFixtureBytes -and ([string]$saveManifest.sourceFixture.sha256).ToLowerInvariant() -eq $expectedFixtureSha
Add-C07Check "Production StateManager save and immutable save manifest are retained" ($manifestPass -and $null -ne $saveManifestArtifact) ([ordered]@{ manifest = $saveManifest; generatedSave = $generatedSaveArtifact; manifestArtifact = $saveManifestArtifact })

$firstNamedNames = @("Save330-C07-first-map-before-confirmation.png", "Save330-C07-first-map-confirmation.png", "Save330-C07-first-map-destination.png")
$reloadNamedNames = @("Save330-C07-reload-map-before-confirmation.png", "Save330-C07-reload-map-confirmation.png", "Save330-C07-reload-map-destination.png")
$firstNamedFrames = @($firstNamedNames | ForEach-Object { Get-C07Artifact (Join-Path $FirstRoot $_) })
$reloadNamedFrames = @($reloadNamedNames | ForEach-Object { Get-C07Artifact (Join-Path $ReloadRoot $_) })
Add-C07Check "First and reload named native frames are present and non-empty" (@($firstNamedFrames + $reloadNamedFrames).Count -eq 6 -and @($firstNamedFrames + $reloadNamedFrames | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0) ([ordered]@{ first = $firstNamedFrames; reload = $reloadNamedFrames })

$firstSourceFiles = if (Test-Path -LiteralPath $FirstNativeSourceRoot -PathType Container) { @(Get-ChildItem -LiteralPath $FirstNativeSourceRoot -Filter "screenshot*.png" -File | Sort-Object Name) } else { @() }
$reloadSourceFiles = if (Test-Path -LiteralPath $ReloadNativeSourceRoot -PathType Container) { @(Get-ChildItem -LiteralPath $ReloadNativeSourceRoot -Filter "screenshot*.png" -File | Sort-Object Name) } else { @() }
$firstSourceFrames = @($firstSourceFiles | ForEach-Object { Get-C07Artifact $_.FullName })
$reloadSourceFrames = @($reloadSourceFiles | ForEach-Object { Get-C07Artifact $_.FullName })
$firstSourceHashes = @($firstSourceFrames | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
$reloadSourceHashes = @($reloadSourceFrames | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
Add-C07Check "Each phase retains three distinct native ScreenCaptureHandler frame hashes" ($firstSourceFrames.Count -eq 3 -and $reloadSourceFrames.Count -eq 3 -and @($firstSourceFrames + $reloadSourceFrames | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0 -and $firstSourceHashes.Count -eq 3 -and $reloadSourceHashes.Count -eq 3) ([ordered]@{ first = $firstSourceFrames; reload = $reloadSourceFrames })
Add-C07Check "Both exact-title raw videos are present and non-empty" ($null -ne $firstVideoArtifact -and $firstVideoArtifact.bytes -gt 0 -and $null -ne $reloadVideoArtifact -and $reloadVideoArtifact.bytes -gt 0) ([ordered]@{ first = $firstVideoArtifact; reload = $reloadVideoArtifact })

$firstB04 = Get-C07B04Data $firstStdout
$reloadB04 = Get-C07B04Data $reloadStdout
$expectedInventorySummary = $null -ne $firstB04.inventorySummary -and $firstB04.inventorySummary.stacks -eq 55 -and $firstB04.inventorySummary.visible -eq 53 -and $firstB04.inventorySummary.worn -eq 3 -and $firstB04.inventorySummary.totalItems -eq 788 -and $firstB04.inventorySummary.health -eq 100 -and $firstB04.inventorySummary.actionPoints -eq 80 -and $firstB04.inventorySummary.actionPointsMax -eq 80 -and $null -ne $reloadB04.inventorySummary -and $reloadB04.inventorySummary.stacks -eq 55 -and $reloadB04.inventorySummary.visible -eq 53 -and $reloadB04.inventorySummary.worn -eq 3 -and $reloadB04.inventorySummary.totalItems -eq 788 -and $reloadB04.inventorySummary.health -eq 100 -and $reloadB04.inventorySummary.actionPoints -eq 80 -and $reloadB04.inventorySummary.actionPointsMax -eq 80
Add-C07Check "First and reload production inventories have the exact final totals" $expectedInventorySummary ([ordered]@{ first = $firstB04.inventorySummary; reload = $reloadB04.inventorySummary })

$expectedEquippedSignature = "1:0x1015038|11:0x100431e|5:0x1025b83"
$equippedParityPass = $firstB04.equippedRows.Count -eq 3 -and $reloadB04.equippedRows.Count -eq 3 -and $firstB04.equippedSignature -eq $expectedEquippedSignature -and $reloadB04.equippedSignature -eq $expectedEquippedSignature -and $firstB04.equippedSignature -eq $reloadB04.equippedSignature
Add-C07Check "Worn/equipped slot rows persist exactly across cold reload" $equippedParityPass ([ordered]@{ expected = $expectedEquippedSignature; first = $firstB04.equippedRows; reload = $reloadB04.equippedRows })

$inventoryRowsParityPass = $firstB04.inventoryRows.Count -eq 55 -and $reloadB04.inventoryRows.Count -eq 55 -and $firstB04.inventorySignature -eq $reloadB04.inventorySignature
Add-C07Check "All 55 production inventory rows persist with exact FormID/count/visibility/equipped parity" $inventoryRowsParityPass ([ordered]@{ firstCount = $firstB04.inventoryRows.Count; reloadCount = $reloadB04.inventoryRows.Count; signatureMatch = $firstB04.inventorySignature -eq $reloadB04.inventorySignature })

$expectedModifierSignature = "24:10:0:0"
$modifierParityPass = $firstB04.modifierRows.Count -eq 1 -and $reloadB04.modifierRows.Count -eq 1 -and $firstB04.modifierSignature -eq $expectedModifierSignature -and $reloadB04.modifierSignature -eq $expectedModifierSignature -and $firstB04.modifierSignature -eq $reloadB04.modifierSignature
Add-C07Check "Actor-value modifier rows persist exactly across cold reload" $modifierParityPass ([ordered]@{ expected = $expectedModifierSignature; first = $firstB04.modifierRows; reload = $reloadB04.modifierRows })

$identityParityPass = $null -ne $firstB04.identity -and $firstB04.identity.initialized -eq 1 -and $firstB04.identity.base -eq "0x1000007" -and $firstB04.identity.reference -eq "0x1000014" -and $null -ne $reloadB04.identity -and $reloadB04.identity.initialized -eq 1 -and $reloadB04.identity.base -eq $firstB04.identity.base -and $reloadB04.identity.reference -eq $firstB04.identity.reference
Add-C07Check "Player identity persists with exact base/reference FormIDs" $identityParityPass ([ordered]@{ first = $firstB04.identity; reload = $reloadB04.identity })

$questGlobalsPass = $null -ne $firstB04.quest -and $null -ne $reloadB04.quest -and $firstB04.quest.states -eq 640 -and $firstB04.quest.stages -eq 1405 -and $firstB04.quest.objectives -eq 1479 -and $firstB04.quest.variables -eq 4539 -and $firstB04.quest.active -eq "0x4002fca" -and ($firstB04.quest | ConvertTo-Json -Compress) -eq ($reloadB04.quest | ConvertTo-Json -Compress) -and $firstB04.globals -eq 268 -and $reloadB04.globals -eq 268
Add-C07Check "Quest and global state persists with exact production counts" $questGlobalsPass ([ordered]@{ firstQuest = $firstB04.quest; reloadQuest = $reloadB04.quest; firstGlobals = $firstB04.globals; reloadGlobals = $reloadB04.globals })

$markerRowsPass = $null -ne $firstB04.markerSummary -and $null -ne $reloadB04.markerSummary -and $firstB04.markerSummary.authored -eq 320 -and $firstB04.markerSummary.visible -eq 1 -and $firstB04.markerSummary.travel -eq 1 -and $firstB04.markerSummary.overrides -eq 0 -and ($firstB04.markerSummary | ConvertTo-Json -Compress) -eq ($reloadB04.markerSummary | ConvertTo-Json -Compress) -and $firstB04.markerRows.Count -eq 320 -and $reloadB04.markerRows.Count -eq 320 -and $firstB04.markerSignature -eq $reloadB04.markerSignature -and @($firstB04.markerRows | Where-Object { $_.id -eq "0x3008885" -and $_.name -eq "Southern Passage" -and $_.state -eq 2 -and $_.authoredVisible -eq 1 -and $_.authoredCanTravel -eq 1 }).Count -eq 1
Add-C07Check "All discovered marker rows and Southern Passage travel state persist exactly" $markerRowsPass ([ordered]@{ firstSummary = $firstB04.markerSummary; reloadSummary = $reloadB04.markerSummary; firstRows = $firstB04.markerRows.Count; reloadRows = $reloadB04.markerRows.Count; signatureMatch = $firstB04.markerSignature -eq $reloadB04.markerSignature; southernPassage = @($firstB04.markerRows | Where-Object { $_.name -eq "Southern Passage" }) })

$nativePatterns = [ordered]@{
    "ordinary Save330 load" = 'FNV/ESM4 proof: loading save from command line ".*NikamiRealWorldSave330-20260802\.fos"'
    "native structural parse" = 'Native FNV save structural parse complete: masters=10 .* inventoryEntries=50'
    "player identity" = 'Native FNV save Player identity restored: base=0x1000007 reference=0x1000014'
    "inventory denominator" = 'Native FNV save Player inventory: stacks=50 worn=3'
    "runtime inventory rebuild" = 'Native FNV save Player runtime inventory rebuilt: stacks=55 visible=53'
    "transform restoration" = 'Native FNV save restored local REFR/ACHR/ACRE transforms: applied=4 missing=0'
    "camera ownership" = 'Native FNV save owns camera mode=1 .* firstPersonModelFov='
    "first-person alignment" = 'FNV first-person camera alignment: .* exact=1'
    "production marker widget" = 'FNV/ESM4 map: rendered 1 exact world-map markers'
    "production marker icon" = 'FNV Pip-Boy MAP: overlay marker icons drawn=1 source=restored-production-marker-state'
    "settled OpenMW save telemetry" = 'FNV B04 persistence: OpenMW save player inventory stacks=55 visible=53 worn=3 totalItems=788'
    "quest telemetry" = 'FNV B04 persistence: OpenMW save quest state states=640 stages=1405 objectives=1479 variables=4539 active=FormId:0x4002fca'
    "global telemetry" = 'FNV B04 persistence: OpenMW save globals count=268'
    "marker telemetry" = 'FNV B04 persistence: OpenMW save map markers authored=320 visible=1 travel=1 overrides=0'
}
foreach ($entry in $nativePatterns.GetEnumerator()) {
    Add-C07Check ("First log contains " + $entry.Key) (Test-C07Pattern $firstStdout $entry.Value) $entry.Value
}

$reloadPatterns = [ordered]@{
    "cold OpenMW save load" = 'FNV/ESM4 proof: loading save from command line ".*Save330-C07-travel-persistence\.omwsave"'
    "OpenMW saved-game title" = "Loading saved game 'Save330 C07 Travel Persistence'"
    "reload inventory telemetry" = 'FNV B04 persistence: OpenMW save player inventory stacks=55 visible=53 worn=3 totalItems=788'
    "reload marker icon" = 'FNV Pip-Boy MAP: overlay marker icons drawn=1 source=restored-production-marker-state'
    "reload marker widget" = 'FNV/ESM4 map: rendered 1 exact world-map markers'
}
foreach ($entry in $reloadPatterns.GetEnumerator()) {
    Add-C07Check ("Reload log contains " + $entry.Key) (Test-C07Pattern $reloadStdout $entry.Value) $entry.Value
}

$firstTravelRow = Get-C07TravelRow $firstStdout 'first-arrival'
$reloadBeforeMapRow = Get-C07TravelRow $reloadStdout 'reload-before-map'
$reloadMapRow = Get-C07TravelRow $reloadStdout 'reload-map-reopened'
$secondTravelRow = Get-C07TravelRow $reloadStdout 'second-arrival'
$firstArrivalPass = $null -ne $firstTravelRow -and $firstTravelRow.marker -eq "3008885" -and $firstTravelRow.cell -eq "300688f" -and $firstTravelRow.worldspace -eq "300683b" -and $firstTravelRow.timeAdvanced -eq 1 -and $firstTravelRow.sameDestinationCell -eq 0 -and $firstTravelRow.menuClosed -eq 1 -and $firstTravelRow.controlsEnabled -eq 1 -and $firstTravelRow.travelCleared -eq 1 -and $firstTravelRow.cameraMode -eq 1
Add-C07Check "First production travel arrives at Southern Passage and advances four hours" $firstArrivalPass $firstTravelRow
$reloadPersistencePass = $null -ne $reloadBeforeMapRow -and $reloadBeforeMapRow.marker -eq "3008885" -and $reloadBeforeMapRow.markerState -eq 2 -and $reloadBeforeMapRow.mapOpen -eq 0 -and $reloadBeforeMapRow.cell -eq "300688f" -and $reloadBeforeMapRow.worldspace -eq "300683b" -and $reloadBeforeMapRow.cameraMode -eq 1 -and $null -ne $reloadMapRow -and $reloadMapRow.marker -eq "3008885" -and $reloadMapRow.markerState -eq 2 -and $reloadMapRow.mapOpen -eq 1 -and $reloadMapRow.worldMap -eq 1 -and $reloadMapRow.selected -eq 1 -and $reloadMapRow.cell -eq "300688f" -and $reloadMapRow.worldspace -eq "300683b" -and $reloadMapRow.cameraMode -eq 1
Add-C07Check "Cold reload restores marker state and reopens MAP with Southern Passage selected" $reloadPersistencePass ([ordered]@{ beforeMap = $reloadBeforeMapRow; mapReopened = $reloadMapRow })
$positionParityPass = $null -ne $firstTravelRow -and $null -ne $reloadBeforeMapRow -and $null -ne $reloadMapRow -and $null -ne $secondTravelRow -and $firstTravelRow.cell -eq $reloadBeforeMapRow.cell -and $firstTravelRow.cell -eq $reloadMapRow.cell -and $firstTravelRow.cell -eq $secondTravelRow.cell -and $firstTravelRow.worldspace -eq $reloadBeforeMapRow.worldspace -and $firstTravelRow.worldspace -eq $reloadMapRow.worldspace -and $firstTravelRow.worldspace -eq $secondTravelRow.worldspace -and (Test-C07Position $firstTravelRow.position $reloadBeforeMapRow.position) -and (Test-C07Position $firstTravelRow.position $reloadMapRow.position) -and (Test-C07Position $firstTravelRow.position $secondTravelRow.position)
Add-C07Check "Destination cell/worldspace/position persist across both travel phases" $positionParityPass ([ordered]@{ first = $firstTravelRow; reloadBeforeMap = $reloadBeforeMapRow; reloadMapReopened = $reloadMapRow; second = $secondTravelRow })
$timePersistencePass = $null -ne $firstTravelRow -and $null -ne $reloadBeforeMapRow -and [math]::Abs($firstTravelRow.afterHour - $reloadBeforeMapRow.hour) -le 0.1 -and $null -ne $firstState -and $null -ne $reloadState -and $firstState.observed.pass -eq $true -and $reloadState.observed.pass -eq $true -and $reloadState.observed.openMwSaveLoadObserved -eq $true
Add-C07Check "Travel time persists into the generated save and cold reload" $timePersistencePass ([ordered]@{ firstAfterHour = if ($null -ne $firstTravelRow) { $firstTravelRow.afterHour } else { $null }; reloadHour = if ($null -ne $reloadBeforeMapRow) { $reloadBeforeMapRow.hour } else { $null }; delta = if ($null -ne $firstTravelRow -and $null -ne $reloadBeforeMapRow) { [math]::Abs($firstTravelRow.afterHour - $reloadBeforeMapRow.hour) } else { $null } })
$secondTravelDeltaHours = $null
if ($null -ne $secondTravelRow) {
    $secondTravelDeltaHours = $secondTravelRow.afterHour - $secondTravelRow.beforeHour
    if ($secondTravelDeltaHours -lt 0) { $secondTravelDeltaHours += 24 }
}
# A same-cell request has no authored distance to convert into fast-travel
# hours. Normal unpaused simulation may still advance the game clock between
# the confirmation and arrival checks, so accept only that bounded drift rather
# than requiring an unstable exact zero.
$secondTravelPass = $null -ne $secondTravelRow -and $secondTravelDeltaHours -ge 0 -and $secondTravelDeltaHours -le 0.1 -and $secondTravelRow.sameDestinationCell -eq 1 -and $secondTravelRow.menuClosed -eq 1 -and $secondTravelRow.controlsEnabled -eq 1 -and $secondTravelRow.travelCleared -eq 1 -and $secondTravelRow.cameraMode -eq 1
Add-C07Check "Second same-cell production travel completes without an artificial long-distance time jump" $secondTravelPass ([ordered]@{ travel = $secondTravelRow; elapsedHours = $secondTravelDeltaHours; maximumNormalSimulationDriftHours = 0.1 })

$successCount = @([regex]::Matches(($firstStdout + "`n" + $reloadStdout), 'FNV/ESM4 map: fast travel complete')).Count
$firstC07Completion = Test-C07Pattern $firstStdout 'FNV C07 persistence: phase=first-travel-arrived .* path=production-persistence-travel status=pass'
$saveRequested = Test-C07Pattern $firstStdout 'FNV C07 persistence: phase=save-requested marker=0x3008885 .* arrivedBeforeSave=1 path=production-state-manager-quick-save status=pass'
$saveComplete = Test-C07Pattern $firstStdout 'FNV C07 persistence: phase=save-complete marker=0x3008885 .* cleanQuitRequested=1 path=production-state-manager-quick-save status=pass'
$reloadCompletion = Test-C07Pattern $reloadStdout 'FNV C07 persistence: phase=second-travel-complete marker=0x3008885 captured=3 confirmed=1 travelExecuted=1 path=production-confirmation-handler status=pass'
Add-C07Check "Exactly two successful production travel completions are retained" ($successCount -eq 2 -and $firstC07Completion -and $saveRequested -and $saveComplete -and $reloadCompletion) ([ordered]@{ successCount = $successCount; firstArrival = $firstC07Completion; saveRequested = $saveRequested; saveComplete = $saveComplete; secondComplete = $reloadCompletion })

$forbiddenTerms = @("AppActivate", "SetForegroundWindow", "SendInput", "Computer Use", "showFalloutMapMarker", "unlock-all", "unlock all", "teleport shortcut", "TestMap", "OPENMW_FNV_UNLOCK_ALL_MAP_MARKERS")
$forbiddenFound = @($forbiddenTerms | Where-Object { $firstStdout -match [regex]::Escape($_) -or $firstStderr -match [regex]::Escape($_) -or $reloadStdout -match [regex]::Escape($_) -or $reloadStderr -match [regex]::Escape($_) })
Add-C07Check "Canonical C07 logs contain no host-control, unlock, or shortcut evidence" ($forbiddenFound.Count -eq 0) $forbiddenFound

$validation = [ordered]@{
    schema = "nikami-fnv-real-save-c07-validation/v1"
    status = if ($script:c07AllPass) { "pass" } else { "fail" }
    objective = "Validate canonical Save330 travel, production save/reload persistence, marker icon selection, and exact player-state parity without a second binary save parser or host automation."
    captureRoot = $CaptureRoot
    routeId = $expectedRoute
    marker = [ordered]@{
        formId = "FormId:0x03008885"
        name = "Southern Passage"
        iconType = 5
        savedRuntimeState = 2
        destinationCell = "FormId:0x0300688F"
        destinationWorldspace = "FormId:0x0300683B"
        destinationPosition = @(-13248, -42631.2, 7719.86)
    }
    persistence = [ordered]@{
        generatedSave = $generatedSaveArtifact
        firstTravel = $firstTravelRow
        reloadBeforeMap = $reloadBeforeMapRow
        reloadMapReopened = $reloadMapRow
        secondTravel = $secondTravelRow
        firstB04 = $firstB04
        reloadB04 = $reloadB04
    }
    source = [ordered]@{
        fixture = $fixtureArtifact
        playerDenominator = $denominatorArtifact
        markerDenominator = $markerDenominatorArtifact
        a03Validation = $a03Artifact
        runtime = $runtimeArtifact
        publicSummary = $summaryArtifact
        captureReport = $reportArtifact
        firstReport = $firstReportArtifact
        reloadReport = $reloadReportArtifact
        firstStdout = $firstStdoutArtifact
        firstStderr = $firstStderrArtifact
        reloadStdout = $reloadStdoutArtifact
        reloadStderr = $reloadStderrArtifact
        firstVideo = $firstVideoArtifact
        reloadVideo = $reloadVideoArtifact
        saveManifest = $saveManifestArtifact
        namedNativeFrames = [ordered]@{ first = $firstNamedFrames; reload = $reloadNamedFrames }
        nativeSourceFrames = [ordered]@{ first = $firstSourceFrames; reload = $reloadSourceFrames }
    }
    checks = @($checks)
}
[IO.Directory]::CreateDirectory((Split-Path -Parent $ValidationPath)) | Out-Null
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 30) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

if (-not $script:c07AllPass) { throw "C07 validation failed. See $ValidationPath" }

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $checks.Count
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-C07Artifact $ValidationPath
    captureRoot = $CaptureRoot
}
