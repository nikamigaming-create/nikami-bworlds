[CmdletBinding()]
param(
    [string]$OpenMWExe = "local/openmw-pristine-mads-33568a/openmw.exe",
    [string]$ResourcesRoot = "local/openmw-pristine-mads-33568a/resources",
    [string]$ProfileDirectory = "profiles/fallout3",
    [string]$StartupScript = "config/starts/fo3-level-one-megaton.txt",
    [string]$PreDoorScript = "config/proofs/fo3-moriartys-front-door.txt",
    [string]$OutputRoot = "run/fo3-interaction-audit",
    [ValidateRange(30, 360)][int]$TimeoutSeconds = 180,
    [ValidateRange(60, 3600)][int]$SettleFrames = 240,
    [ValidateRange(0.0, 23.9999)][double]$StartHour = 12.0,
    [ValidateRange(-128.0, 128.0)][double]$EyeOffsetZ = -40.0,
    [switch]$ActorTelemetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) $Path))
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ProfileValue([string]$ConfigPath, [string]$Key) {
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -match ('^\s*' + [Regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) { return $Matches[1] }
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
$preDoor = Resolve-RepoPath $PreDoorScript
$outputBase = Resolve-RepoPath $OutputRoot
$baselineConfig = Resolve-RepoPath "config/playable-baseline"
$doorPreloadConfig = Resolve-RepoPath "config/door-preload"
$profileConfig = Join-Path $profile "openmw.cfg"
foreach ($requiredFile in @($exe, $profileConfig, $startup, $preDoor, (Join-Path $baselineConfig "settings.cfg"),
    (Join-Path $doorPreloadConfig "settings.cfg"))) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Missing FO3 audit file: $requiredFile" }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) { throw "Missing resources: $resources" }
if ([IO.Path]::GetFileName($exe) -ne "openmw.exe") { throw "FO3 audit requires flat openmw.exe." }
if (Get-Process -Name openmw,openmw_vr -ErrorAction SilentlyContinue) {
    throw "OpenMW is already running. The audit will not replace or interfere with it."
}

$morrowindConfig = Resolve-RepoPath "profiles/morrowind/openmw.cfg"
$morrowindData = Get-ProfileValue $morrowindConfig "data"
if ([string]::IsNullOrWhiteSpace($morrowindData)) { throw "Unable to resolve shared OpenMW UI assets." }
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
    foreach ($file in Get-ChildItem -LiteralPath $screenshotDirectory -File) { $beforeScreenshots[$file.FullName] = $true }
}

$arguments = @(
    "--replace", "config",
    "--config", $profile,
    "--config", $baselineConfig,
    "--config", $doorPreloadConfig,
    "--config", $sessionConfig,
    "--user-data", $sessionUserData,
    "--resources", $resources,
    "--data", $morrowindData,
    "--fallback-archive", "Morrowind.bsa",
    "--skip-menu",
    "--start", "MegatonEntrance",
    "--script-run", $startup
)
if ($arguments -contains "--no-sound") { throw "FO3 audit contract violation: sound must stay enabled." }
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "

$environmentPrefixes = @("OPENMW_WORLD_VIEWER_", "OPENMW_PROOF_", "OPENMW_FNV_", "OPENMW_ESM4_", "OPENMW_PLAYABLE_", "OPENMW_AUTHORED_")
$previousEnvironment = @{}
foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
    if ($environmentPrefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}

$environment = [ordered]@{
    OPENMW_AUTHORED_INTERACTION_AUDIT = "1"
    OPENMW_AUTHORED_INTERACTION_LABEL = "fallout3-megaton-moriartys"
    OPENMW_AUTHORED_INTERACTION_SETTLE_FRAMES = $SettleFrames.ToString([Globalization.CultureInfo]::InvariantCulture)
    OPENMW_AUTHORED_INTERACTION_PHASE_TIMEOUT_SECONDS = "45"
    OPENMW_AUTHORED_INTERACTION_ACTOR_REF = "FormId:0x1003b46"
    OPENMW_AUTHORED_INTERACTION_MAX_ACTOR_DISTANCE = "512"
    OPENMW_AUTHORED_INTERACTION_MAX_ACTOR_DRIFT = "512"
    OPENMW_AUTHORED_INTERACTION_REQUIRE_ACTOR_ON_RETURN = "1"
    OPENMW_AUTHORED_INTERACTION_DIALOGUE_TOPIC = "What can you tell me about Megaton?"
    OPENMW_AUTHORED_INTERACTION_PRE_DOOR_SCRIPT = $preDoor
    OPENMW_AUTHORED_INTERACTION_PRE_DOOR_SETTLE_FRAMES = "180"
    OPENMW_AUTHORED_INTERACTION_DOOR_IN_REF = "FormId:0x1003a23"
    OPENMW_AUTHORED_INTERACTION_INTERIOR_CELL = "FormId:0x1003a35"
    OPENMW_AUTHORED_INTERACTION_INTERIOR_ACTOR_REF = "FormId:0x1003b3d"
    OPENMW_AUTHORED_INTERACTION_RADIO_REF = "FormId:0x102056c"
    OPENMW_AUTHORED_INTERACTION_DOOR_OUT_REF = "FormId:0x1003a5f"
    OPENMW_ESM4_PLAYER_NPC = "Player"
    OPENMW_ESM4_PLAYER_OUTFIT = "VaultSuit101"
    OPENMW_ESM4_FIRST_PERSON_EYE_OFFSET_Z = $EyeOffsetZ.ToString([Globalization.CultureInfo]::InvariantCulture)
    OPENMW_PLAYABLE_SESSION_BACKGROUND = "1"
    OPENMW_PLAYABLE_START_HOUR = $StartHour.ToString([Globalization.CultureInfo]::InvariantCulture)
    OPENMW_PROOF_DELAY_STARTUP_SCRIPT = "1"
    OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI = "1"
    OPENMW_WORLD_VIEWER_TELEMETRY = "0"
    OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = if ($ActorTelemetry) { "1" } else { "0" }
    OPENMW_WORLD_VIEWER_DOOR_PRELOAD_TELEMETRY = "1"
    OPENMW_DEBUG_LEVEL = "INFO"
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
    foreach ($entry in $environment.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process") }
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
    if (-not $process.Start()) { throw "Failed to start hidden FO3 audit." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    } else { $process.WaitForExit() }
    $process.Refresh()
    if ($process.HasExited) { $exitCode = $process.ExitCode }
} finally {
    if ($null -ne $stdoutTask) { [IO.File]::WriteAllText($stdout, $stdoutTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false)) }
    if ($null -ne $stderrTask) { [IO.File]::WriteAllText($stderr, $stderrTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false)) }
    foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
        if ($environmentPrefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) { [Environment]::SetEnvironmentVariable($name, $null, "Process") }
    }
    foreach ($entry in $previousEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process") }
}

Start-Sleep -Milliseconds 500
$copiedScreenshots = @()
if (Test-Path -LiteralPath $screenshotDirectory) {
    $index = 0
    foreach ($file in Get-ChildItem -LiteralPath $screenshotDirectory -File |
        Where-Object { -not $beforeScreenshots.ContainsKey($_.FullName) -and $_.LastWriteTimeUtc -ge $startedAt.AddSeconds(-2) } |
        Sort-Object LastWriteTimeUtc, Name) {
        ++$index
        $destination = Join-Path $output ("fo3-interaction-{0:d2}{1}" -f $index, $file.Extension.ToLowerInvariant())
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $copiedScreenshots += $destination
    }
}
if (Test-Path -LiteralPath $profileLog) { Copy-Item -LiteralPath $profileLog -Destination (Join-Path $output "openmw.log") -Force }

$logText = ""
foreach ($path in @($stdout, $stderr, (Join-Path $output "openmw.log"))) {
    if (Test-Path -LiteralPath $path) { $logText += "`n" + (Get-Content -LiteralPath $path -Raw) }
}
$resultMatch = [Regex]::Matches($logText, 'Authored interaction audit: label=fallout3-megaton-moriartys result=(?<result>pass|fail) reason="(?<reason>[^"]*)" (?<gates>[^\r\n]+)') | Select-Object -Last 1
$gates = [ordered]@{}
if ($null -ne $resultMatch) {
    foreach ($gateMatch in [Regex]::Matches($resultMatch.Groups["gates"].Value, '(?<name>actor|dialogue|doorIn|interiorActors|radio|doorOut)=(?<value>[01])')) {
        $gates[$gateMatch.Groups["name"].Value] = $gateMatch.Groups["value"].Value -eq "1"
    }
}
$pixelMeasurements = @($copiedScreenshots | ForEach-Object { Measure-NativeScreenshotScene $_ })
$pixelPass = $copiedScreenshots.Count -eq 5 -and @($pixelMeasurements | Where-Object { -not $_.pass }).Count -eq 0
$doorPreloadRequested = [Regex]::Match($logText,
    'Teleport door preload telemetry: phase=requested format=esm4 door=FormId:0x1003a23 destCell=FormId:0x1003a35')
$doorPreloadComplete = [Regex]::Match($logText,
    'Teleport door preload telemetry: phase=complete format=esm4 door=FormId:0x1003a23 destCell=FormId:0x1003a35')
$doorActivation = [Regex]::Match($logText,
    'Authored interaction audit: label=fallout3-megaton-moriartys activate=exterior-door')
$doorPreloadPass = $doorPreloadRequested.Success -and $doorPreloadComplete.Success -and
    $doorActivation.Success -and $doorPreloadRequested.Index -lt $doorPreloadComplete.Index -and
    $doorPreloadComplete.Index -lt $doorActivation.Index
$passed = -not $timedOut -and $exitCode -eq 0 -and $null -ne $resultMatch -and
    $resultMatch.Groups["result"].Value -eq "pass" -and $pixelPass -and $doorPreloadPass
$manifest = [ordered]@{
    schema = "nikami-fo3-interaction-audit/v1"
    status = if ($passed) { "pass" } else { "fail" }
    backgroundOnly = $true
    foregroundInputUsed = $false
    soundEnabled = $true
    executable = $exe -replace "\\", "/"
    executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    startedAt = $startedAt.ToString("o")
    endedAt = [DateTime]::UtcNow.ToString("o")
    timedOut = $timedOut
    exitCode = $exitCode
    startCell = "MegatonEntrance"
    startHour = $StartHour
    level = 1
    sourceRefs = [ordered]@{
        lucasSimms = "FormId:0x1003b46"
        exteriorDoor = "FormId:0x1003a23"
        interiorCell = "FormId:0x1003a35"
        gob = "FormId:0x1003b3d"
        radio = "FormId:0x102056c"
        interiorDoor = "FormId:0x1003a5f"
    }
    resultReason = if ($null -ne $resultMatch) { $resultMatch.Groups["reason"].Value } else { "result gate absent" }
    gates = $gates
    authoredDialogueText = $logText -match 'Authored interaction audit: dialogueResponse title="What can you tell me about Megaton\?" text=".+'
    authoredVoiceResolved = $logText -match 'dialogue: resolved authored voice'
    radioToggleObserved = $logText -match 'radio: toggled .*isPlaying=1'
    expectedScreenshotCount = 5
    screenshotCount = $copiedScreenshots.Count
    nativePixelStatus = if ($pixelPass) { "pass" } else { "fail" }
    doorPreload = [ordered]@{
        status = if ($doorPreloadPass) { "pass" } else { "fail" }
        sourceFormat = "esm4"
        sourceDoor = "FormId:0x1003a23"
        destinationCell = "FormId:0x1003a35"
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
if (-not $passed) { throw "FO3 interaction audit failed. See $manifestPath" }
