[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$RunRoot = "D:\code\nikami-worlds\run\fnv-real-save-campaign\b03-openmw-20260802-220100"
)

$ErrorActionPreference = "Stop"
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$OpenMwRoot = Join-Path $RunRoot "openmw"
$summaryPath = Join-Path $RunRoot "background-capture-summary.json"
$reportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$statePath = Join-Path $OpenMwRoot "real-save-state.json"
$logPath = Join-Path $OpenMwRoot "openmw.stdout.log"
$framePath = Join-Path $OpenMwRoot "Save330-native-world.png"
$videoPath = Join-Path $OpenMwRoot "OpenMW-Save330-exact-title-raw.mp4"
$validationPath = Join-Path $WorldsRoot "run\fnv-real-save-campaign\b03-settle-validation.json"
$savePath = Join-Path $WorldsRoot "local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos"

if (Test-Path -LiteralPath $validationPath) {
    throw "Refusing to overwrite an existing B03 validation artifact: $validationPath"
}

$checks = [Collections.Generic.List[object]]::new()
$script:b03AllPass = $true

function Add-B03Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][object]$Detail
    )
    $checks.Add([ordered]@{
            name = $Name
            passed = $Passed
            detail = $Detail
        })
    if (-not $Passed) {
        $script:b03AllPass = $false
    }
}

function Read-B03Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-B03Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path
    [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Test-B03Finite {
    param([Parameter(Mandatory = $true)][double]$Value)
    return (-not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value))
}

$summary = Read-B03Json -Path $summaryPath
$captureReport = Read-B03Json -Path $reportPath
$state = Read-B03Json -Path $statePath
$log = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $logPath
}
else {
    ""
}

foreach ($path in @($summaryPath, $reportPath, $statePath, $logPath, $framePath, $videoPath)) {
    Add-B03Check -Name "artifact exists: $([IO.Path]::GetFileName($path))" `
        -Passed (Test-Path -LiteralPath $path -PathType Leaf) `
        -Detail $path
}

Add-B03Check -Name "public summary is a passing RealSave run" `
    -Passed ($null -ne $summary -and
        $summary.schema -eq "nikami-fnv-jam-background-capture-run/v1" -and
        $summary.status -eq "pass" -and
        $summary.scenario -eq "RealSave" -and
        $summary.target -eq "OpenMW" -and
        $null -ne $summary.realSave -and
        $summary.realSave.status -eq "pass") `
    -Detail ([ordered]@{
            schema = if ($null -ne $summary) { $summary.schema } else { $null }
            status = if ($null -ne $summary) { $summary.status } else { $null }
            realSaveStatus = if ($null -ne $summary -and $null -ne $summary.realSave) { $summary.realSave.status } else { $null }
        })

$summaryPolicyDetail = if ($null -ne $summary) { $summary.policy } else { $null }
Add-B03Check -Name "capture has no host control and did not overwrite output" `
    -Passed ($null -ne $summary -and
        $summary.policy.windowsAppControlUsed -eq $false -and
        $summary.policy.foregroundActivationUsed -eq $false -and
        $summary.policy.foregroundInputInjected -eq $false -and
        $summary.policy.capturesRanSequentially -eq $true -and
        $summary.policy.outputOverwritten -eq $false) `
    -Detail $summaryPolicyDetail

$captureAssertions = if ($null -ne $captureReport) { $captureReport.assertions } else { $null }
Add-B03Check -Name "B02 normal-load assertions remain passing" `
    -Passed ($null -ne $captureReport -and
        $captureReport.status -eq "pass" -and
        $captureReport.routeId -eq "save330-cold-load-settle-v1" -and
        $captureReport.capture.recorderExitCode -eq 0 -and
        $captureReport.capture.userConfigurationRestored -eq $true -and
        $captureAssertions.stateManifestPass -eq $true -and
        $captureAssertions.ordinaryLoadPathObserved -eq $true -and
        $captureAssertions.nativeSaveLoadComplete -eq $true -and
        $captureAssertions.playerIdentityRestored -eq $true -and
        $captureAssertions.savedTransformApplied -eq $true -and
        $captureAssertions.fallbackInventoryAbsent -eq $true -and
        $captureAssertions.syntheticPlacementAbsent -eq $true -and
        $captureAssertions.nativeWorldFrameRetained -eq $true -and
        $captureAssertions.exactTitleVideoRetained -eq $true) `
    -Detail $captureAssertions

$expectedSaveHash = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
$observedSaveHash = if ($null -ne $captureReport -and $null -ne $captureReport.sourceSave) {
    [string]$captureReport.sourceSave.sha256
}
else {
    ""
}
Add-B03Check -Name "B03 source remains the immutable Save330 fixture" `
    -Passed ((Test-Path -LiteralPath $savePath -PathType Leaf) -and
        $observedSaveHash.ToLowerInvariant() -eq $expectedSaveHash -and
        (Get-FileHash -LiteralPath $savePath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedSaveHash) `
    -Detail ([ordered]@{ path = $savePath; expectedSha256 = $expectedSaveHash; observedSha256 = $observedSaveHash })

$telemetryPattern = 'World viewer telemetry: frame=(?<frame>\d+) state=(?<state>-?\d+) loadingGui=(?<loadingGui>[01]) worldReady=(?<worldReady>[01]) readyFrames=(?<readyFrames>\d+) activeCells=(?<activeCells>\d+) hour=(?<hour>[-+0-9.eE]+) weatherId=(?<weatherId>-?\d+) weatherTransition=(?<weatherTransition>[-+0-9.eE]+) playerCell="(?<cell>[^"]+)" exterior=(?<exterior>[01]) grid=\((?<gridX>-?\d+),(?<gridY>-?\d+)\) worldspace=(?<worldspace>[^ ]+) playerPos=\((?<px>[-+0-9.eE]+),(?<py>[-+0-9.eE]+),(?<pz>[-+0-9.eE]+)\) playerRot=\((?<rx>[-+0-9.eE]+),(?<ry>[-+0-9.eE]+),(?<rz>[-+0-9.eE]+)\) cameraMode=(?<cameraMode>-?\d+) cameraPos=\((?<cx>[-+0-9.eE]+),(?<cy>[-+0-9.eE]+),(?<cz>[-+0-9.eE]+)\) cameraPitch=(?<pitch>[-+0-9.eE]+) cameraYaw=(?<yaw>[-+0-9.eE]+) playerHealth=(?<health>[-+0-9.eE]+) playerActionPoints=(?<ap>[-+0-9.eE]+) playerActionPointsMax=(?<apMax>[-+0-9.eE]+)'
$telemetryMatches = [regex]::Matches($log, $telemetryPattern)
$telemetry = @($telemetryMatches | ForEach-Object {
        $match = $_
        [ordered]@{
            frame = [int]$match.Groups["frame"].Value
            state = [int]$match.Groups["state"].Value
            loadingGui = $match.Groups["loadingGui"].Value -eq "1"
            worldReady = $match.Groups["worldReady"].Value -eq "1"
            readyFrames = [int]$match.Groups["readyFrames"].Value
            activeCells = [int]$match.Groups["activeCells"].Value
            hour = [double]$match.Groups["hour"].Value
            weatherId = [int]$match.Groups["weatherId"].Value
            weatherTransition = [double]$match.Groups["weatherTransition"].Value
            cell = $match.Groups["cell"].Value
            exterior = $match.Groups["exterior"].Value -eq "1"
            grid = @([int]$match.Groups["gridX"].Value, [int]$match.Groups["gridY"].Value)
            worldspace = $match.Groups["worldspace"].Value
            position = @([double]$match.Groups["px"].Value, [double]$match.Groups["py"].Value, [double]$match.Groups["pz"].Value)
            rotation = @([double]$match.Groups["rx"].Value, [double]$match.Groups["ry"].Value, [double]$match.Groups["rz"].Value)
            cameraMode = [int]$match.Groups["cameraMode"].Value
            cameraPosition = @([double]$match.Groups["cx"].Value, [double]$match.Groups["cy"].Value, [double]$match.Groups["cz"].Value)
            cameraPitch = [double]$match.Groups["pitch"].Value
            cameraYaw = [double]$match.Groups["yaw"].Value
            health = [double]$match.Groups["health"].Value
            actionPoints = [double]$match.Groups["ap"].Value
            actionPointsMax = [double]$match.Groups["apMax"].Value
        }
    })
$readyTelemetry = @($telemetry | Where-Object { $_.worldReady })
$initial = if ($readyTelemetry.Count -gt 0) { $readyTelemetry[0] } else { $null }
$latest = if ($readyTelemetry.Count -gt 0) { $readyTelemetry[-1] } else { $null }

Add-B03Check -Name "bounded settle produced repeated world-ready telemetry" `
    -Passed ($telemetry.Count -ge 20 -and $readyTelemetry.Count -ge 20 -and $null -ne $initial -and $null -ne $latest -and
        ($latest.frame - $initial.frame) -ge 300 -and $latest.readyFrames -ge 300) `
    -Detail ([ordered]@{ samples = $telemetry.Count; readySamples = $readyTelemetry.Count; initialFrame = if ($null -ne $initial) { $initial.frame } else { $null }; latestFrame = if ($null -ne $latest) { $latest.frame } else { $null }; latestReadyFrames = if ($null -ne $latest) { $latest.readyFrames } else { $null } })

$finiteLatest = $false
if ($null -ne $latest) {
    $finiteValues = @($latest.position + $latest.rotation + $latest.cameraPosition + @($latest.cameraPitch, $latest.cameraYaw, $latest.hour, $latest.weatherTransition, $latest.health, $latest.actionPoints, $latest.actionPointsMax))
    $finiteLatest = @($finiteValues | Where-Object { Test-B03Finite -Value ([double]$_) }).Count -eq $finiteValues.Count
}
Add-B03Check -Name "settled player and camera values are finite" -Passed $finiteLatest -Detail $latest

$worldspacePass = $false
if ($null -ne $latest) {
    $worldspaceMatch = [regex]::Match([string]$latest.worldspace, '0x(?<form>[0-9a-fA-F]{1,8})')
    if ($worldspaceMatch.Success) {
        $worldspacePass = (([Convert]::ToUInt32($worldspaceMatch.Groups["form"].Value, 16) -band 0x00ffffff) -eq 0x000da726)
    }
}
$locationPass = $null -ne $latest -and $latest.state -eq 2 -and -not $latest.loadingGui -and $latest.worldReady -and
    $latest.activeCells -gt 0 -and $latest.cell -eq "Mojave Wasteland" -and $latest.exterior -and
    $latest.grid[0] -eq -18 -and $latest.grid[1] -eq -1 -and $worldspacePass
Add-B03Check -Name "settled location is the authored Goodsprings exterior" -Passed $locationPass `
    -Detail ([ordered]@{ cell = if ($null -ne $latest) { $latest.cell } else { $null }; exterior = if ($null -ne $latest) { $latest.exterior } else { $null }; grid = if ($null -ne $latest) { $latest.grid } else { $null }; worldspace = if ($null -ne $latest) { $latest.worldspace } else { $null }; worldspaceMatches = $worldspacePass })

$tail = if ($telemetry.Count -ge 10) { @($telemetry | Select-Object -Last 10) } else { @($telemetry) }
$stable = $tail.Count -ge 5 -and $null -ne $latest
if ($stable) {
    foreach ($sample in $tail) {
        if ($sample.cell -ne $latest.cell -or $sample.grid[0] -ne $latest.grid[0] -or $sample.grid[1] -ne $latest.grid[1] -or
            $sample.worldspace -ne $latest.worldspace -or $sample.cameraMode -ne $latest.cameraMode -or
            [Math]::Abs($sample.position[0] - $latest.position[0]) -gt 0.05 -or
            [Math]::Abs($sample.position[1] - $latest.position[1]) -gt 0.05 -or
            [Math]::Abs($sample.position[2] - $latest.position[2]) -gt 0.05 -or
            [Math]::Abs($sample.rotation[0] - $latest.rotation[0]) -gt 0.01 -or
            [Math]::Abs($sample.rotation[1] - $latest.rotation[1]) -gt 0.01 -or
            [Math]::Abs($sample.rotation[2] - $latest.rotation[2]) -gt 0.01 -or
            [Math]::Abs($sample.cameraPosition[0] - $latest.cameraPosition[0]) -gt 0.05 -or
            [Math]::Abs($sample.cameraPosition[1] - $latest.cameraPosition[1]) -gt 0.05 -or
            [Math]::Abs($sample.cameraPosition[2] - $latest.cameraPosition[2]) -gt 0.05) {
            $stable = $false
            break
        }
    }
}
Add-B03Check -Name "last bounded telemetry window is stationary" -Passed $stable `
    -Detail ([ordered]@{ tailSamples = $tail.Count; latestPosition = if ($null -ne $latest) { $latest.position } else { $null }; latestCamera = if ($null -ne $latest) { $latest.cameraPosition } else { $null } })

$healthPass = $null -ne $latest -and $latest.health -eq 100 -and ($telemetry | Where-Object { $_.health -ne 100 }).Count -eq 0
$apPass = $null -ne $latest -and $latest.actionPoints -gt 0 -and $latest.actionPointsMax -gt 0 -and
    $latest.actionPoints -le ($latest.actionPointsMax + 0.001) -and
    ($telemetry | Where-Object { $_.actionPoints -ne $latest.actionPoints -or $_.actionPointsMax -ne $latest.actionPointsMax }).Count -eq 0
Add-B03Check -Name "health and Action Points remain finite and unchanged" `
    -Passed ($healthPass -and $apPass -and $log -match 'Native FNV save Player restored actor values: modifiers=1 perks=0 health=100') `
    -Detail ([ordered]@{ health = if ($null -ne $latest) { $latest.health } else { $null }; actionPoints = if ($null -ne $latest) { $latest.actionPoints } else { $null }; actionPointsMax = if ($null -ne $latest) { $latest.actionPointsMax } else { $null }; healthLogObserved = $log -match 'Native FNV save Player restored actor values: modifiers=1 perks=0 health=100' })

$weatherTimePass = $null -ne $latest -and $latest.hour -ge 0 -and $latest.hour -lt 24 -and $latest.weatherId -ge 0 -and
    $latest.weatherTransition -ge 0 -and $latest.weatherTransition -le 1
Add-B03Check -Name "weather and game time are finite" -Passed $weatherTimePass `
    -Detail ([ordered]@{ hour = if ($null -ne $latest) { $latest.hour } else { $null }; weatherId = if ($null -ne $latest) { $latest.weatherId } else { $null }; weatherTransition = if ($null -ne $latest) { $latest.weatherTransition } else { $null } })

$actorMatches = [regex]::Matches($log, 'World viewer actor ledger: phase=actor-part-manifest ref=FormId:0x[0-9a-fA-F]+ .* game=FONV')
$actorNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($match in $actorMatches) {
    $nameMatch = [regex]::Match($match.Value, 'name="(?<name>[^"]+)"')
    if ($nameMatch.Success) { [void]$actorNames.Add($nameMatch.Groups["name"].Value) }
}
$authoredWorldPass = $actorMatches.Count -ge 10 -and $actorNames.Contains("Goodsprings Settler") -and $actorNames.Contains("Easy Pete")
Add-B03Check -Name "nearby authored Goodsprings references are visible" -Passed $authoredWorldPass `
    -Detail ([ordered]@{ actorPartLines = $actorMatches.Count; actorNames = @($actorNames | Sort-Object) })

$playerAssembly = [regex]::Match($log, 'World viewer actor ledger: phase=actor-assembly-gate ref=FormId:@0x0 base="Player".*status=passed')
$playerAssemblyPass = $playerAssembly.Success -and
    $playerAssembly.Value -match 'bodyComplete=1' -and
    $playerAssembly.Value -match 'raceFaceComplete=1' -and
    $playerAssembly.Value -match 'hairComplete=1' -and
    $playerAssembly.Value -match 'armorRequired=3 armorAttached=3' -and
    $playerAssembly.Value -match 'weaponHiddenByProof=0'
$equipmentPass = $log -match 'Native FNV save Player inventory: stacks=50 worn=3' -and
    ([regex]::Matches($log, 'Native FNV save Player equipped ExtraWorn:')).Count -eq 3 -and
    $log -match 'FNV first-person saveWorn: total=3 armor=3 weapon=0 source=native-save' -and
    $playerAssemblyPass
Add-B03Check -Name "Player equipment and actor assembly are native-save complete" -Passed $equipmentPass `
    -Detail ([ordered]@{ playerAssembly = $playerAssembly.Value; extraWornCount = ([regex]::Matches($log, 'Native FNV save Player equipped ExtraWorn:')).Count })

$noTposePass = $log -match 'World viewer actor ledger: phase=parts-end ref=FormId:@0x0 base="Player".*visualRigGeometry=10.*visualBoundValid=1' -and
    $log -match 'World viewer actor ledger: phase=actor-assembly-gate ref=FormId:@0x0 base="Player".*status=passed' -and
    $log -match 'ESM4 player visual locomotion: phase=advanced selected="idle".*available=1'
$noDetachedWeaponPass = $log -notmatch 'World viewer actor ledger: phase=equipment-part .*npc="Player".*kind=weapon.*attached=0' -and
    $log -match 'FNV/ESM4 authored weapon target: actor=Player target=Weapon present=1 synthetic=0' -and
    $log -match 'World viewer actor weapon mesh ledger: .*valid=1.*gate=actor-weapon-mesh-telemetry'
Add-B03Check -Name "no T-pose or detached weapon is reported" -Passed ($noTposePass -and $noDetachedWeaponPass) `
    -Detail ([ordered]@{ noTpose = $noTposePass; noDetachedWeapon = $noDetachedWeaponPass })

$fatalPatterns = @(
    '(?i)unhandled exception',
    '(?i)access violation',
    '(?i)openmw exited unexpectedly',
    '(?i)fatal.*(missing|failed|asset|resource)',
    '(?i)missing required (world )?(asset|resource)',
    '(?i)failed to load required'
)
$fatalHits = [Collections.Generic.List[string]]::new()
foreach ($pattern in $fatalPatterns) {
    foreach ($match in [regex]::Matches($log, $pattern)) { $fatalHits.Add($match.Value) }
}
$noFatalPass = $fatalHits.Count -eq 0 -and $captureReport.capture.gameTermination -eq "owned-process-terminated-after-capture" -and
    $captureReport.capture.recorderExitCode -eq 0
$nonFatalMissingImageWarnings = ([regex]::Matches($log, 'Failed to open image:')).Count
Add-B03Check -Name "no crash or fatal required-asset failure" -Passed $noFatalPass `
    -Detail ([ordered]@{ fatalHits = @($fatalHits); knownNonFatalMissingImageWarnings = $nonFatalMissingImageWarnings; gameTermination = $captureReport.capture.gameTermination })

$validation = [ordered]@{
    schema = "nikami-fnv-real-save-b03-validation/v1"
    status = if ($script:b03AllPass) { "pass" } else { "fail" }
    bite = "B03"
    runRoot = $RunRoot
    source = [ordered]@{
        save = Get-B03Artifact -Path $savePath
        captureReport = Get-B03Artifact -Path $reportPath
        stateManifest = Get-B03Artifact -Path $statePath
        stdout = Get-B03Artifact -Path $logPath
        nativeWorldFrame = Get-B03Artifact -Path $framePath
        exactTitleVideo = Get-B03Artifact -Path $videoPath
    }
    observations = [ordered]@{
        telemetrySamples = $telemetry.Count
        worldReadySamples = $readyTelemetry.Count
        initial = $initial
        latest = $latest
        authoredActorNames = @($actorNames | Sort-Object)
        knownNonFatalMissingImageWarnings = $nonFatalMissingImageWarnings
    }
    checks = @($checks)
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    failedChecks = @($checks | Where-Object { -not $_.passed }).Count
}
[IO.File]::WriteAllText($validationPath, ($validation | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$validation | ConvertTo-Json -Depth 6
if (-not $script:b03AllPass) {
    exit 1
}
