param(
    [string]$OutputRoot = "run/fnv-natural-sky-proof",
    [string]$BinaryRoot = "local/openmw-fo4guard",
    [int]$RunSeconds = 26,
    [int]$CaptureSecond = 13,
    [int]$NativeScreenshotWaitSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Four upward cardinal views exercise the same natural Goodsprings WTHR without
# requiring every direction to contain visible cloud texels. NVCloudlight has
# authored clear areas and the cloud dome fades to the horizon.
$angleFrames = @(150, 270, 390, 510)
$captureFrames = @(210, 330, 450, 570)
$pitches = @(0.82, 0.82, 0.82, 0.82)
$yaws = @(-3.14159265, -1.57079633, 0, 1.57079633)

$environment = @(
    "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=",
    "OPENMW_FNV_PROOF_WEATHER_ID=",
    "OPENMW_FNV_PROOF_IMAGE_SPACE_ID=",
    "OPENMW_FNV_BOOTSTRAP_HOUR=12",
    "OPENMW_FNV_PROOF_FREEZE_TIME=1",
    "OPENMW_WORLD_VIEWER_CAMERA_ANGLE_SEQUENCE_FRAMES=$($angleFrames -join ',')",
    "OPENMW_WORLD_VIEWER_CAMERA_ANGLE_SEQUENCE_PITCHES=$($pitches -join ',')",
    "OPENMW_WORLD_VIEWER_CAMERA_ANGLE_SEQUENCE_YAWS=$($yaws -join ',')"
)

$result = @(& (Join-Path $PSScriptRoot "Invoke-RealWorldScreenshots.ps1") `
    -WorldId fallout_new_vegas `
    -Mode flat `
    -OutputRoot $OutputRoot `
    -BinaryRoot $BinaryRoot `
    -RunSeconds $RunSeconds `
    -CaptureSeconds $CaptureSecond `
    -EngineScreenshotFrames ($captureFrames -join ",") `
    -ExpectedScreenshotCount $captureFrames.Count `
    -NativeScreenshotWaitSeconds $NativeScreenshotWaitSeconds `
    -SetEnv $environment `
    -BackgroundWindow)

if ($result.Count -ne 1) {
    throw "Natural-sky proof expected one FNV result, got $($result.Count)."
}

$manifest = $result[0]
$logText = if (-not [string]::IsNullOrWhiteSpace([string]$manifest.logPath) -and
    (Test-Path -LiteralPath $manifest.logPath)) {
    Get-Content -LiteralPath $manifest.logPath -Raw
} else {
    ""
}

$checks = [ordered]@{
    nativeCardinalCaptures = @($manifest.screenshots | Where-Object {
        $_.source -eq "openmw-native-screenshot"
    }).Count -eq $captureFrames.Count
    naturalWeatherSelected = $logText -match
        'selected authored weather source=region .*editorId=GSWeatherRegion .*weather=FormId:0x11237d7 .*runtimeSlot=33 selected=1'
    noWeatherForce = $logText -notmatch 'force-weather'
    fourCloudLayersMapped = $logText -match 'mapped Fallout cloud geometry layers=4'
    authoredCloudTextureActive = $logText -match
        'active cloud sampler contract image=textures/sky/nvcloudlight\.dds'
    atmosphereActive = $logText -match 'atmosphere vertical colors runtime-supported'
}
$failures = @($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value } |
    ForEach-Object { [string]$_.Key })
$gate = [pscustomobject][ordered]@{
    schema = "nikami-fnv-natural-sky-gate/v1"
    status = if ($failures.Count -eq 0) { "pass" } else { "fail" }
    weather = "FormId:0x11237d7"
    runtimeSlot = 33
    forcedWeather = $false
    cardinalViewCount = $captureFrames.Count
    checks = [pscustomobject]$checks
    failures = $failures
}
$manifest | Add-Member -NotePropertyName naturalSkyGate -NotePropertyValue $gate -Force
$manifestPath = Join-Path ([string]$manifest.outputDirectory) "manifest.json"
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding ASCII
$manifest

if ($failures.Count -ne 0) {
    throw "FNV natural-sky proof failed: $($failures -join ', '). See $manifestPath"
}
