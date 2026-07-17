[CmdletBinding()]
param(
    [string]$OpenMWExe = "local/openmw-fo4guard/openmw.exe",
    [string]$ResourcesRoot = "local/openmw-fo4guard/resources",
    [string]$ProfileDirectory = "profiles/fallout_new_vegas",
    [string]$StartupScript = "config/starts/fnv-level-one-goodsprings.txt",
    [string]$OutputRoot = "run/fnv-interaction-audit",
    [ValidateRange(1, 360)]
    [int]$TimeoutSeconds = 180,
    [ValidateRange(60, 3600)]
    [int]$SettleFrames = 900,
    [ValidateRange(0.0, 23.9999)]
    [double]$StartHour = 14.45,
    [ValidateRange(-128.0, 128.0)]
    [double]$EyeOffsetZ = -40.0,
    [switch]$DoorOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) $Path))
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ProfileValue([string]$ConfigPath, [string]$Key) {
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -match ('^\s*' + [Regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) {
            return $Matches[1]
        }
    }
    return $null
}

function Measure-NativeScreenshotScene([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new($Path)
    try {
        $sceneHeight = [Math]::Max(1, [int][Math]::Floor($bitmap.Height * 0.80))
        $step = [Math]::Max(1, [int][Math]::Floor([Math]::Min($bitmap.Width, $sceneHeight) / 96.0))
        [long]$samples = 0
        [long]$nonBlack = 0
        [double]$sum = 0
        [double]$squared = 0
        for ($y = 0; $y -lt $sceneHeight; $y += $step) {
            for ($x = 0; $x -lt $bitmap.Width; $x += $step) {
                $pixel = $bitmap.GetPixel($x, $y)
                $luma = (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
                ++$samples
                if ($luma -gt 12) { ++$nonBlack }
                $sum += $luma
                $squared += $luma * $luma
            }
        }
        $mean = if ($samples -gt 0) { $sum / $samples } else { 0.0 }
        $variance = if ($samples -gt 0) { [Math]::Max(0.0, ($squared / $samples) - ($mean * $mean)) } else { 0.0 }
        $fraction = if ($samples -gt 0) { $nonBlack / [double]$samples } else { 0.0 }
        $deviation = [Math]::Sqrt($variance)
        [pscustomobject][ordered]@{
            path = $Path -replace "\\", "/"
            sceneNonBlackFraction = $fraction
            sceneMeanLuma = $mean
            sceneLumaStandardDeviation = $deviation
            pass = $fraction -ge 0.03 -and $deviation -ge 3.0
        }
    } finally {
        $bitmap.Dispose()
    }
}

$exe = Resolve-RepoPath $OpenMWExe
$resources = Resolve-RepoPath $ResourcesRoot
$profile = Resolve-RepoPath $ProfileDirectory
$startup = Resolve-RepoPath $StartupScript
$outputBase = Resolve-RepoPath $OutputRoot
$baselineConfig = Resolve-RepoPath "config/playable-baseline"
$doorPreloadConfig = Resolve-RepoPath "config/door-preload"
$fnvPlayableGraphicsConfig = Resolve-RepoPath "config/fnv-playable-graphics"
$profileConfig = Join-Path $profile "openmw.cfg"

foreach ($requiredFile in @($exe, $profileConfig, $startup, (Join-Path $baselineConfig "settings.cfg"),
    (Join-Path $doorPreloadConfig "settings.cfg"), (Join-Path $fnvPlayableGraphicsConfig "settings.cfg"))) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Missing required interaction-audit file: $requiredFile"
    }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "Missing OpenMW resources root: $resources"
}
if ([IO.Path]::GetFileName($exe) -ne "openmw.exe") {
    throw "The interaction audit is flat/background-only and requires openmw.exe: $exe"
}
if (Get-Process -Name openmw,openmw_vr -ErrorAction SilentlyContinue) {
    throw "OpenMW is already running. The audit will not replace or interfere with an existing session."
}

$morrowindConfig = Resolve-RepoPath "profiles/morrowind/openmw.cfg"
$morrowindData = Get-ProfileValue $morrowindConfig "data"
if ([string]::IsNullOrWhiteSpace($morrowindData)) {
    throw "Unable to resolve the shared OpenMW UI data directory from $morrowindConfig"
}
$morrowindData = [IO.Path]::GetFullPath($morrowindData)

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$output = Join-Path $outputBase $stamp
New-Item -ItemType Directory -Path $output -Force | Out-Null
$sessionConfig = Join-Path $output "session-config"
$sessionUserData = Join-Path $output "user-data"
New-Item -ItemType Directory -Path $sessionConfig,$sessionUserData -Force | Out-Null
Set-Content -LiteralPath (Join-Path $sessionConfig "openmw.cfg") `
    -Value ('user-data="{0}"' -f ($sessionUserData -replace '\\', '/')) -Encoding utf8

$screenshotDirectory = Join-Path $sessionUserData "screenshots"
$profileLog = Join-Path $sessionConfig "openmw.log"
$beforeScreenshots = @{}
if (Test-Path -LiteralPath $screenshotDirectory) {
    foreach ($file in Get-ChildItem -LiteralPath $screenshotDirectory -File) {
        $beforeScreenshots[$file.FullName] = $true
    }
}

$arguments = @(
    "--replace", "config",
    "--config", $profile,
    "--config", $baselineConfig,
    "--config", $fnvPlayableGraphicsConfig,
    "--config", $doorPreloadConfig,
    "--config", $sessionConfig,
    "--user-data", $sessionUserData,
    "--resources", $resources,
    "--data", $morrowindData,
    "--fallback-archive", "Morrowind.bsa",
    "--skip-menu",
    "--start", "Goodsprings",
    "--script-run", $startup
)
if ($arguments -contains "--no-sound") {
    throw "Interaction-audit contract violation: sound must stay enabled."
}
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "

$environmentPrefixes = @(
    "OPENMW_WORLD_VIEWER_",
    "OPENMW_PROOF_",
    "OPENMW_FNV_",
    "OPENMW_ESM4_",
    "OPENMW_PLAYABLE_"
)
$previousEnvironment = @{}
foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
    if ($environmentPrefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}

$environment = [ordered]@{
    OPENMW_FNV_INTERACTION_AUDIT = "1"
    OPENMW_FNV_INTERACTION_SETTLE_FRAMES = $SettleFrames.ToString([Globalization.CultureInfo]::InvariantCulture)
    OPENMW_FNV_INTERACTION_PHASE_TIMEOUT_SECONDS = "45"
    OPENMW_ESM4_FIRST_PERSON_EYE_OFFSET_Z = $EyeOffsetZ.ToString([Globalization.CultureInfo]::InvariantCulture)
    OPENMW_PLAYABLE_SESSION_BACKGROUND = "1"
    OPENMW_PLAYABLE_START_HOUR = $StartHour.ToString([Globalization.CultureInfo]::InvariantCulture)
    OPENMW_PROOF_DELAY_STARTUP_SCRIPT = "1"
    OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI = "1"
    OPENMW_WORLD_VIEWER_TELEMETRY = "0"
    OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "0"
    OPENMW_WORLD_VIEWER_DOOR_PRELOAD_TELEMETRY = "1"
    OPENMW_DEBUG_LEVEL = "INFO"
}
if ($DoorOnly) {
    $environment.OPENMW_FNV_INTERACTION_DOOR_ONLY = "1"
}

$stdout = Join-Path $output "stdout.log"
$stderr = Join-Path $output "stderr.log"
$startedAt = [DateTime]::UtcNow
$process = $null
$timedOut = $false
$exitCode = $null
$stdoutTask = $null
$stderrTask = $null
try {
    foreach ($entry in $environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $exe
    $startInfo.Arguments = $argumentLine
    $startInfo.WorkingDirectory = Split-Path -Parent $exe
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start hidden OpenMW interaction audit."
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
    else {
        # Complete asynchronous redirected-stream draining before querying ExitCode.
        $process.WaitForExit()
    }
    $process.Refresh()
    if ($process.HasExited) {
        $exitCode = $process.ExitCode
    }
} finally {
    if ($null -ne $stdoutTask) {
        [IO.File]::WriteAllText($stdout, $stdoutTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    }
    if ($null -ne $stderrTask) {
        [IO.File]::WriteAllText($stderr, $stderrTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    }
    foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
        if ($environmentPrefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
    }
}

Start-Sleep -Milliseconds 500
$copiedScreenshots = @()
if (Test-Path -LiteralPath $screenshotDirectory) {
    $index = 0
    foreach ($file in Get-ChildItem -LiteralPath $screenshotDirectory -File |
        Where-Object { -not $beforeScreenshots.ContainsKey($_.FullName) -and $_.LastWriteTimeUtc -ge $startedAt.AddSeconds(-2) } |
        Sort-Object LastWriteTimeUtc, Name) {
        ++$index
        $destination = Join-Path $output ("fnv-interaction-{0:d2}{1}" -f $index, $file.Extension.ToLowerInvariant())
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $copiedScreenshots += $destination
    }
}
if (Test-Path -LiteralPath $profileLog) {
    Copy-Item -LiteralPath $profileLog -Destination (Join-Path $output "openmw.log") -Force
}

$logText = ""
foreach ($path in @($stdout, $stderr, (Join-Path $output "openmw.log"))) {
    if (Test-Path -LiteralPath $path) {
        $logText += "`n" + (Get-Content -LiteralPath $path -Raw)
    }
}
$resultMatch = [Regex]::Matches($logText, 'FNV interaction audit: result=(?<result>pass|fail) reason="(?<reason>[^"]*)" (?<gates>[^\r\n]+)') |
    Select-Object -Last 1
$gates = [ordered]@{}
if ($null -ne $resultMatch) {
    foreach ($gateMatch in [Regex]::Matches($resultMatch.Groups["gates"].Value, '(?<name>actor|dialogue|quest|doorIn|interiorActors|radio|doorOut)=(?<value>[01])')) {
        $gates[$gateMatch.Groups["name"].Value] = $gateMatch.Groups["value"].Value -eq "1"
    }
}

$expectedScreenshotCount = if ($DoorOnly) { 4 } else { 6 }
$pixelMeasurements = @($copiedScreenshots | ForEach-Object { Measure-NativeScreenshotScene $_ })
$pixelPass = $copiedScreenshots.Count -eq $expectedScreenshotCount `
    -and @($pixelMeasurements | Where-Object { -not $_.pass }).Count -eq 0
$doorPreloadRequested = [Regex]::Match($logText,
    'Teleport door preload telemetry: phase=requested format=esm4 door=FormId:0x110636f destCell=FormId:0x1106185')
$doorPreloadComplete = [Regex]::Match($logText,
    'Teleport door preload telemetry: phase=complete format=esm4 door=FormId:0x110636f destCell=FormId:0x1106185')
$doorActivation = [Regex]::Match($logText,
    'FNV interaction audit: activate label=prospector-saloon-front-door')
$doorPreloadPass = $doorPreloadRequested.Success -and $doorPreloadComplete.Success -and
    $doorActivation.Success -and $doorPreloadRequested.Index -lt $doorPreloadComplete.Index -and
    $doorPreloadComplete.Index -lt $doorActivation.Index
$passed = -not $timedOut -and $exitCode -eq 0 -and $null -ne $resultMatch `
    -and $resultMatch.Groups["result"].Value -eq "pass" -and $pixelPass -and $doorPreloadPass
$manifest = [ordered]@{
    schema = "nikami-fnv-interaction-audit/v1"
    status = if ($passed) { "pass" } else { "fail" }
    backgroundOnly = $true
    foregroundInputUsed = $false
    evidenceClass = "driven-subsystem-harness"
    soundEnabled = $true
    executable = $exe -replace "\\", "/"
    executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    startedAt = $startedAt.ToString("o")
    endedAt = [DateTime]::UtcNow.ToString("o")
    timeoutSeconds = $TimeoutSeconds
    timedOut = $timedOut
    exitCode = $exitCode
    startCell = "Goodsprings"
    startHour = $StartHour
    firstPersonEyeOffsetZ = $EyeOffsetZ
    level = 1
    sourceRefs = [ordered]@{
        easyPete = "FormId:0x1104c80"
        exteriorDoor = "FormId:0x110636f"
        interiorCell = "FormId:0x1106185"
        interiorDoor = "FormId:0x110618e"
        sunny = "FormId:0x1104e85"
        trudy = "FormId:0x1104c6d"
        cheyenne = "FormId:0x110588e"
        radio = "FormId:0x1109087"
    }
    resultReason = if ($null -ne $resultMatch) { $resultMatch.Groups["reason"].Value } else { "result gate absent" }
    gates = $gates
    renderedQuestNotification = $logText -match 'FNV interaction audit: rendered notification text="Quest (Added|Updated):'
    authoredDialogueText = $logText -match 'FNV interaction audit: dialogue response title="Why are you called Easy Pete\?" text="Was a prospector'
    authoredVoiceResolved = $logText -match 'FNV/ESM4 dialogue: resolved authored voice info='
    radioToggleObserved = $logText -match 'FNV/ESM4 radio: toggled .*isPlaying=1'
    expectedScreenshotCount = $expectedScreenshotCount
    screenshotCount = $copiedScreenshots.Count
    nativePixelStatus = if ($pixelPass) { "pass" } else { "fail" }
    doorPreload = [ordered]@{
        status = if ($doorPreloadPass) { "pass" } else { "fail" }
        sourceFormat = "esm4"
        sourceDoor = "FormId:0x110636f"
        destinationCell = "FormId:0x1106185"
        requestedBeforeComplete = $doorPreloadRequested.Success -and $doorPreloadComplete.Success -and
            $doorPreloadRequested.Index -lt $doorPreloadComplete.Index
        completeBeforeActivation = $doorPreloadComplete.Success -and $doorActivation.Success -and
            $doorPreloadComplete.Index -lt $doorActivation.Index
    }
    screenshotSceneMeasurements = $pixelMeasurements
    screenshots = @($copiedScreenshots | ForEach-Object { $_ -replace "\\", "/" })
    outputDirectory = $output -replace "\\", "/"
    command = @($exe) + $arguments
}
$manifestPath = Join-Path $output "manifest.json"
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$manifest | ConvertTo-Json -Depth 12

if (-not $passed) {
    throw "FNV interaction audit failed. See $manifestPath"
}
