[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [Parameter(Mandatory = $true)]
    [string]$BinaryRoot,
    [string]$FalloutNewVegasData = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data",
    [string]$OutputRoot = "",
    [ValidateRange(52, 90)]
    [int]$CaptureSeconds = 65,
    [ValidateRange(60, 240)]
    [int]$TimeoutSeconds = 120,
    [string]$StartCell = "SSHQ01",
    [string]$TerminalContentFile = "FalloutNV.esm",
    [ValidatePattern('^[0-9A-Fa-f]{8}$')]
    [string]$TerminalFormIndex = "00103B3C"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Quote-OpenNVArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)
    if ($Argument -notmatch '[\s"]') { return $Argument }
    return '"' + ($Argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Set-CaptureProfileSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $lines = [Collections.Generic.List[string]]::new([string[]](Get-Content -LiteralPath $Path))
    $header = "[$Section]"
    $start = -1
    $end = $lines.Count
    for ($i = 0; $i -lt $lines.Count; ++$i) {
        if ($lines[$i].Trim().Equals($header, [StringComparison]::OrdinalIgnoreCase)) {
            $start = $i
            for ($j = $i + 1; $j -lt $lines.Count; ++$j) {
                if ($lines[$j] -match '^\s*\[.+\]\s*$') { $end = $j; break }
            }
            break
        }
    }
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    if ($start -lt 0) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) { $lines.Add("") }
        $lines.Add($header)
        $lines.Add("$Key = $Value")
    }
    else {
        $written = $false
        for ($i = $start + 1; $i -lt $end; ++$i) {
            if ($lines[$i] -match $pattern) { $lines[$i] = "$Key = $Value"; $written = $true; break }
        }
        if (-not $written) { $lines.Insert($end, "$Key = $Value") }
    }
    [IO.File]::WriteAllText($Path, (($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
}

function Save-AsyncProcessStreams {
    param(
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task[string]]$StandardOutputTask,
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task[string]]$StandardErrorTask,
        [Parameter(Mandatory = $true)][string]$StandardOutputPath,
        [Parameter(Mandatory = $true)][string]$StandardErrorPath
    )
    [IO.File]::WriteAllText($StandardOutputPath, $StandardOutputTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($StandardErrorPath, $StandardErrorTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
}

function Get-Artifact {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $file.FullName
        bytes = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$FalloutNewVegasData = [IO.Path]::GetFullPath($FalloutNewVegasData)
$binary = Join-Path $BinaryRoot "openmw.exe"
$resources = Join-Path $BinaryRoot "resources"
$initializer = Join-Path $WorldsRoot "scripts\Initialize-OpenNVBaseProfile.ps1"
foreach ($path in @($binary, $initializer, (Join-Path $FalloutNewVegasData "FalloutNV.esm"))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Terminal capture requirement: $path" }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) { throw "Missing Terminal runtime resources: $resources" }
if (@(Get-Process -Name "openmw" -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "Refusing to overlap the Terminal capture with an existing OpenMW process."
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $WorldsRoot ("run\opennv-terminal-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "Refusing to overwrite an existing Terminal capture: $OutputRoot" }
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$profileDirectory = Join-Path $WorldsRoot "profiles\_verification\newvegas-terminal-$stamp"
$campaignUserdata = Join-Path $WorldsRoot "profiles\_verification\_campaigns\newvegas-terminal-$stamp\userdata"
$eventScriptPath = Join-Path $OutputRoot "terminal-self-drive.csv"
$stdoutPath = Join-Path $OutputRoot "openmw.stdout.log"
$stderrPath = Join-Path $OutputRoot "openmw.stderr.log"
$captureStdoutPath = Join-Path $OutputRoot "ffmpeg.stdout.log"
$captureStderrPath = Join-Path $OutputRoot "ffmpeg.stderr.log"
$videoPath = Join-Path $OutputRoot "OpenMW-Terminal-exact-title-raw.mp4"
$reportPath = Join-Path $OutputRoot "terminal-capture-report.json"
$eventLines = @(
    "# milliseconds, generic action, action arguments",
    "8000,stage-near-form,$TerminalContentFile,$TerminalFormIndex,80",
    "12000,screenshot",
    "16000,activate-faced-form,$TerminalContentFile,$TerminalFormIndex",
    "20000,screenshot",
    "24000,controller,DPadRight",
    "28000,screenshot",
    "32000,controller,DPadRight",
    "36000,screenshot",
    "40000,controller,B",
    "44000,screenshot",
    "48000,activate-faced-form,$TerminalContentFile,$TerminalFormIndex",
    "52000,screenshot",
    "56000,controller,B",
    "60000,screenshot"
)
[IO.File]::WriteAllText($eventScriptPath, (($eventLines -join [Environment]::NewLine) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))

$profile = & $initializer -FalloutNewVegasData $FalloutNewVegasData -ProfileDirectory $profileDirectory `
    -CampaignUserdataDirectory $campaignUserdata -BinaryRoot $BinaryRoot -Force
if (-not [bool]$profile.launchable) { throw "The isolated Terminal profile is not launchable: $($profile.installReasons -join '; ')" }
$settingsPath = Join-Path ([string]$profile.profileDirectory) "settings.cfg"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "screenshot format" -Value "png"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "notify on saved screenshot" -Value "false"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "minimize on focus loss" -Value "false"
Set-CaptureProfileSetting -Path $settingsPath -Section "Input" -Key "enable controller" -Value "true"
Set-CaptureProfileSetting -Path $settingsPath -Section "GUI" -Key "controller menus" -Value "true"
Set-CaptureProfileSetting -Path $settingsPath -Section "OpenNV Compatibility" -Key "fallout controls" -Value "true"
Set-CaptureProfileSetting -Path $settingsPath -Section "Physics" -Key "async num threads" -Value "0"

$game = $null
$recorder = $null
$gameStdoutTask = $null
$gameStderrTask = $null
$recorderStdoutTask = $null
$recorderStderrTask = $null
$gameStreamsSaved = $false
$recorderStreamsSaved = $false
$recorderExitCode = $null
$captureError = $null
$gameTermination = "not-started"
$startedAt = [DateTime]::UtcNow
try {
    $arguments = @("--replace", "config", "--config", [string]$profile.profileDirectory,
        "--resources", [string]$profile.resourcesRoot, "--skip-menu", "--start", $StartCell)
    $gameStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $gameStartInfo.FileName = $binary
    $gameStartInfo.Arguments = ($arguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "
    $gameStartInfo.WorkingDirectory = Split-Path -Parent $binary
    $gameStartInfo.UseShellExecute = $false
    $gameStartInfo.CreateNoWindow = $false
    $gameStartInfo.RedirectStandardOutput = $true
    $gameStartInfo.RedirectStandardError = $true
    foreach ($name in @($gameStartInfo.EnvironmentVariables.Keys | ForEach-Object { [string]$_ })) {
        if ($name.StartsWith("OPENMW_", [StringComparison]::OrdinalIgnoreCase)) { $gameStartInfo.EnvironmentVariables.Remove($name) }
    }
    $gameStartInfo.EnvironmentVariables["OPENMW_DEBUG_LEVEL"] = "INFO"
    $gameStartInfo.EnvironmentVariables["OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG"] = "1"
    $gameStartInfo.EnvironmentVariables["OPENMW_SELF_DRIVE_INPUT_SCRIPT"] = $eventScriptPath
    $game = [Diagnostics.Process]::new()
    $game.StartInfo = $gameStartInfo
    if (-not $game.Start()) { throw "Unable to start OpenMW for Terminal capture." }
    $gameStdoutTask = $game.StandardOutput.ReadToEndAsync()
    $gameStderrTask = $game.StandardError.ReadToEndAsync()

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($game.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $game.Refresh()
        if ($game.HasExited) { throw "OpenMW exited before its Terminal capture window appeared." }
    }
    if ($game.MainWindowHandle -eq 0) { throw "OpenMW did not expose an exact-title Terminal capture window." }

    $ffmpegArguments = @("-hide_banner", "-loglevel", "warning", "-y", "-f", "gdigrab", "-framerate", "60",
        "-draw_mouse", "0", "-i", "title=OpenMW", "-t", ([string]$CaptureSeconds), "-c:v", "libx264",
        "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", $videoPath)
    $recorderStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $recorderStartInfo.FileName = (Get-Command ffmpeg -ErrorAction Stop).Source
    $recorderStartInfo.Arguments = ($ffmpegArguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "
    $recorderStartInfo.WorkingDirectory = $WorldsRoot
    $recorderStartInfo.UseShellExecute = $false
    $recorderStartInfo.CreateNoWindow = $true
    $recorderStartInfo.RedirectStandardOutput = $true
    $recorderStartInfo.RedirectStandardError = $true
    $recorder = [Diagnostics.Process]::new()
    $recorder.StartInfo = $recorderStartInfo
    if (-not $recorder.Start()) { throw "Unable to start the exact-title Terminal recorder." }
    $recorderStdoutTask = $recorder.StandardOutput.ReadToEndAsync()
    $recorderStderrTask = $recorder.StandardError.ReadToEndAsync()
    if (-not $recorder.WaitForExit(($CaptureSeconds + 20) * 1000)) { throw "Timed out waiting for the Terminal recorder." }
    $recorder.Refresh()
    $recorderExitCode = $recorder.ExitCode
    Save-AsyncProcessStreams -StandardOutputTask $recorderStdoutTask -StandardErrorTask $recorderStderrTask `
        -StandardOutputPath $captureStdoutPath -StandardErrorPath $captureStderrPath
    $recorderStreamsSaved = $true
    if ($recorderExitCode -ne 0 -or -not (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
        throw "The exact-title Terminal recorder did not produce a valid MP4."
    }
}
catch { $captureError = $_.Exception.Message }
finally {
    if ($null -ne $recorder) {
        $recorder.Refresh()
        if (-not $recorder.HasExited) { $recorder.Kill(); $recorder.WaitForExit() }
        if ($null -eq $recorderExitCode -and $recorder.HasExited) { $recorderExitCode = $recorder.ExitCode }
        if (-not $recorderStreamsSaved -and $null -ne $recorderStdoutTask -and $null -ne $recorderStderrTask) {
            Save-AsyncProcessStreams -StandardOutputTask $recorderStdoutTask -StandardErrorTask $recorderStderrTask `
                -StandardOutputPath $captureStdoutPath -StandardErrorPath $captureStderrPath
        }
        $recorder.Dispose()
    }
    if ($null -ne $game) {
        $game.Refresh()
        if (-not $game.HasExited) {
            Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue
            [void]$game.WaitForExit(15000)
            $game.Refresh()
            $gameTermination = if ($game.HasExited) { "owned-process-terminated-after-capture" } else { "owned-process-exit-timeout" }
        }
        else { $gameTermination = "engine-exited" }
        if ($game.HasExited -and -not $gameStreamsSaved -and $null -ne $gameStdoutTask -and $null -ne $gameStderrTask) {
            Save-AsyncProcessStreams -StandardOutputTask $gameStdoutTask -StandardErrorTask $gameStderrTask `
                -StandardOutputPath $stdoutPath -StandardErrorPath $stderrPath
            $gameStreamsSaved = $true
        }
        $game.Dispose()
    }
}

$profileLogPath = Join-Path $profile.profileDirectory "openmw.log"
$logTexts = [Collections.Generic.List[string]]::new()
$seenLogHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($logPath in @($stdoutPath, $stderrPath, $profileLogPath)) {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { continue }
    $hash = (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash
    if ($seenLogHashes.Add($hash)) { $logTexts.Add((Get-Content -Raw -LiteralPath $logPath)) }
}
$logText = $logTexts -join [Environment]::NewLine
$logLines = @($logText -split "[\r\n]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$selfDriveLoaded = $logText -match 'Self-drive input: loaded .*events=14'
$eventExecutions = @($logLines | Where-Object { $_ -match 'Self-drive input: execute index=' })
$stagingObserved = @($logLines | Where-Object { $_ -match 'Self-drive input: staged near form without activation' }).Count -eq 1
$ordinaryActivations = @($logLines | Where-Object { $_ -match 'Self-drive input: dispatch ordinary action=Activate faced=0x' })
$ordinaryActivationObserved = $ordinaryActivations.Count -eq 2
$terminalIndexSuffix = $TerminalFormIndex.Substring(2)
$ordinaryActivationTargetObserved = $ordinaryActivationObserved -and
    @($ordinaryActivations | Where-Object { $_ -match [regex]::Escape($terminalIndexSuffix) }).Count -eq 2
$directActivationObserved = $logText -match 'Self-drive input: resolved activate-form'
$physicalCameraEntries = @($logLines | Where-Object { $_ -match 'FNV terminal camera: physical shell target=' })
$cameraRestorations = @($logLines | Where-Object { $_ -match 'FNV terminal camera: restored player view' })
$hackingOpened = $logText -match 'FNV/ESM4 terminal: hacking begin placement='
$hackingCompleted = $logText -match 'FNV/ESM4 terminal: hacking complete placement='
$controllerEvents = @($eventExecutions | Where-Object { $_ -match 'kind=0' })
$screenshotEvents = @($eventExecutions | Where-Object { $_ -match 'kind=1' })
$screenshotDirectory = Join-Path $campaignUserdata "screenshots"
$nativeFrames = @(if (Test-Path -LiteralPath $screenshotDirectory -PathType Container) {
    Get-ChildItem -LiteralPath $screenshotDirectory -File | Where-Object { $_.Length -gt 0 -and $_.Extension -eq '.png' } |
        Sort-Object LastWriteTimeUtc, Name
})
$copiedNativeFrames = [Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $nativeFrames.Count; ++$i) {
    $destination = Join-Path $OutputRoot ("Terminal-{0:D2}-native.png" -f ($i + 1))
    Copy-Item -LiteralPath $nativeFrames[$i].FullName -Destination $destination
    $copiedNativeFrames.Add($destination)
}
$runtimeErrors = @($logLines | Where-Object { $_ -match '\sE\]' })
$passed = [string]::IsNullOrWhiteSpace($captureError) -and $selfDriveLoaded -and $stagingObserved -and
    $ordinaryActivationTargetObserved -and -not $directActivationObserved -and $physicalCameraEntries.Count -eq 2 -and
    $cameraRestorations.Count -eq 2 -and $hackingOpened -and $hackingCompleted -and
    $controllerEvents.Count -eq 4 -and $screenshotEvents.Count -eq 7 -and $copiedNativeFrames.Count -eq 7 -and
    $null -ne (Get-Artifact $videoPath)
$report = [ordered]@{
    schema = "opennv-terminal-capture/v1"
    status = if ($passed) { "pass" } else { "fail" }
    purpose = "Paced interaction with an authored Fallout: New Vegas terminal and its native hacking UI."
    startedAtUtc = $startedAt.ToString("o")
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    launch = [ordered]@{ engine = "OpenMW"; retailEngineLaunched = $false; newGame = $false; diagnosticStart = $true; startCell = $StartCell }
    target = [ordered]@{ contentFile = $TerminalContentFile; localFormIndex = $TerminalFormIndex }
    pacingMilliseconds = @(8000, 12000, 16000, 20000, 24000, 28000, 32000, 36000, 40000, 44000, 48000, 52000, 56000, 60000)
    capture = [ordered]@{
        method = "OpenMW ScreenCaptureHandler native PNGs plus ffmpeg exact-title OpenMW transport MP4"
        driver = "Generic diagnostic start placement followed by ordinary faced-object Activate actions and paced controller menu input"
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        windowTitle = "OpenMW"
        gameTermination = $gameTermination
        recorderExitCode = $recorderExitCode
    }
    source = [ordered]@{
        binary = (Get-Artifact $binary)
        resources = $resources
        profileDirectory = $profile.profileDirectory
        profileManifest = $profile.manifestPath
        eventScript = (Get-Artifact $eventScriptPath)
        content = @($profile.content)
    }
    assertions = [ordered]@{
        selfDriveScriptLoaded = $selfDriveLoaded
        stagingObserved = $stagingObserved
        ordinaryActivationObserved = $ordinaryActivationObserved
        ordinaryActivationTargetObserved = $ordinaryActivationTargetObserved
        directActivationObserved = $directActivationObserved
        physicalCameraEntryCount = $physicalCameraEntries.Count
        cameraRestorationCount = $cameraRestorations.Count
        hackingOpened = $hackingOpened
        hackingCompleted = $hackingCompleted
        controllerEventCount = $controllerEvents.Count
        screenshotEventCount = $screenshotEvents.Count
        nativeFrameCount = $copiedNativeFrames.Count
        runtimeErrors = @($runtimeErrors)
    }
    artifacts = @((Get-Artifact $stdoutPath), (Get-Artifact $stderrPath), (Get-Artifact $profileLogPath),
        (Get-Artifact $captureStdoutPath), (Get-Artifact $captureStderrPath), (Get-Artifact $videoPath),
        (Get-Artifact $eventScriptPath)) + @($copiedNativeFrames | ForEach-Object { Get-Artifact $_ }) |
        Where-Object { $null -ne $_ }
    error = $captureError
}
[IO.File]::WriteAllText($reportPath, (($report | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 10
if (-not $passed) { throw "OpenNV Terminal capture failed. See $reportPath" }
