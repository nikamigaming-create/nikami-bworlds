[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$BinaryRoot = "D:\code\nikami-worlds\local\openmw-player-recovery-authored-opening",
    [string]$FalloutNewVegasData = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data",
    [string]$OutputRoot = "",
    [ValidateRange(6, 60)]
    [int]$CaptureSeconds = 16,
    [ValidateRange(60, 3600)]
    [int]$NativeScreenshotFrame = 480,
    # TestMap01 is the worldspace editor ID, not an interior CELL editor ID.
    # Use its installed FalloutNV.esm form ID with the engine's generic
    # exterior-start boundary rather than pretending it is a named cell.
    # FalloutNV.esm occupies load index 01 in this OpenMW profile, so retain
    # that resolved form ID rather than the raw on-disk local form ID.
    [string]$TestMapWorldspace = "FormId:0x010d703c",
    [int]$TestMapGridX = 0,
    [int]$TestMapGridY = 0,
    # The canonical outer capture entry point defaults to 240 seconds. Keep
    # this diagnostic compatible with that declared default while retaining a
    # bounded wait for a stalled launch.
    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 90,
    # Opt-in native-driver telemetry for renderer investigation. The normal
    # TestMap proof path remains unchanged and does not enable a debug GL
    # context.
    [switch]$OpenGlDebug
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Quote-OpenNVArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + ($Argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-Artifact {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $file.FullName
        bytes = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Set-CaptureProfileSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $lines = [Collections.Generic.List[string]]::new([string[]](Get-Content -LiteralPath $Path))
    $sectionHeader = "[$Section]"
    $sectionStart = -1
    $sectionEnd = $lines.Count
    for ($index = 0; $index -lt $lines.Count; ++$index) {
        if ($lines[$index].Trim().Equals($sectionHeader, [StringComparison]::OrdinalIgnoreCase)) {
            $sectionStart = $index
            for ($next = $index + 1; $next -lt $lines.Count; ++$next) {
                if ($lines[$next] -match '^\s*\[.+\]\s*$') {
                    $sectionEnd = $next
                    break
                }
            }
            break
        }
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    if ($sectionStart -lt 0) {
        if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
            $lines.Add("")
        }
        $lines.Add($sectionHeader)
        $lines.Add("$Key = $Value")
    }
    else {
        $written = $false
        for ($index = $sectionStart + 1; $index -lt $sectionEnd; ++$index) {
            if ($lines[$index] -match $keyPattern) {
                $lines[$index] = "$Key = $Value"
                $written = $true
                break
            }
        }
        if (-not $written) {
            $lines.Insert($sectionEnd, "$Key = $Value")
        }
    }

    [IO.File]::WriteAllText(
        $Path,
        (($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
}

function Save-And-ClearOpenMwEnvironment {
    $previous = @{}
    foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
        if ($name.StartsWith("OPENMW_", [StringComparison]::OrdinalIgnoreCase)) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    return $previous
}

function Restore-Environment {
    param([Parameter(Mandatory = $true)][hashtable]$Values)

    foreach ($entry in $Values.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

function Save-AsyncProcessStreams {
    param(
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task[string]]$StandardOutputTask,
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task[string]]$StandardErrorTask,
        [Parameter(Mandatory = $true)][string]$StandardOutputPath,
        [Parameter(Mandatory = $true)][string]$StandardErrorPath
    )

    [IO.File]::WriteAllText(
        $StandardOutputPath,
        $StandardOutputTask.GetAwaiter().GetResult(),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        $StandardErrorPath,
        $StandardErrorTask.GetAwaiter().GetResult(),
        [Text.UTF8Encoding]::new($false))
}

function Get-NativeFrameHealth {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bitmap = [System.Drawing.Bitmap]::new($Path)
        try {
            $sampleWidth = 64
            $sampleHeight = 36
            $sampleCount = $sampleWidth * $sampleHeight
            $magenta = 0
            $black = 0
            $brown = 0
            $lumaSum = 0.0
            $lumaSquareSum = 0.0
            for ($sampleY = 0; $sampleY -lt $sampleHeight; ++$sampleY) {
                $pixelY = [Math]::Min($bitmap.Height - 1, [int](($sampleY + 0.5) * $bitmap.Height / $sampleHeight))
                for ($sampleX = 0; $sampleX -lt $sampleWidth; ++$sampleX) {
                    $pixelX = [Math]::Min($bitmap.Width - 1, [int](($sampleX + 0.5) * $bitmap.Width / $sampleWidth))
                    $pixel = $bitmap.GetPixel($pixelX, $pixelY)
                    $red = [double]$pixel.R
                    $green = [double]$pixel.G
                    $blue = [double]$pixel.B
                    $luma = (0.2126 * $red) + (0.7152 * $green) + (0.0722 * $blue)
                    $lumaSum += $luma
                    $lumaSquareSum += $luma * $luma
                    if ([Math]::Max($red, [Math]::Max($green, $blue)) -lt 12) { ++$black }
                    if ($red -gt 180 -and $blue -gt 120 -and $green -lt 140) { ++$magenta }
                    if ($red -ge 30 -and $red -le 140 -and $green -ge 20 -and $green -le 110 -and
                        $blue -le 80 -and ($red - $green) -ge 5 -and ($green - $blue) -ge 5) { ++$brown }
                }
            }
            $meanLuma = $lumaSum / $sampleCount
            $lumaDeviation = [Math]::Sqrt([Math]::Max(0.0, ($lumaSquareSum / $sampleCount) - ($meanLuma * $meanLuma)))
            $magentaRatio = $magenta / $sampleCount
            $blackRatio = $black / $sampleCount
            $brownRatio = $brown / $sampleCount
            $faults = [Collections.Generic.List[string]]::new()
            if ($magentaRatio -ge 0.10) { $faults.Add("pervasive-magenta") }
            if ($blackRatio -ge 0.98 -and $meanLuma -lt 12) { $faults.Add("black") }
            if ($brownRatio -ge 0.95 -and $lumaDeviation -le 15.0) { $faults.Add("brown-void") }
            if ($lumaDeviation -le 1.0) { $faults.Add("flat-color") }
            return [ordered]@{
                sampleMethod = "64x36 RGB grid over OpenMW ScreenCaptureHandler PNG"
                width = $bitmap.Width
                height = $bitmap.Height
                meanLuma = [Math]::Round($meanLuma, 2)
                lumaStandardDeviation = [Math]::Round($lumaDeviation, 2)
                magentaRatio = [Math]::Round($magentaRatio, 4)
                blackRatio = [Math]::Round($blackRatio, 4)
                brownRatio = [Math]::Round($brownRatio, 4)
                faults = @($faults.ToArray())
                passed = $faults.Count -eq 0
            }
        }
        finally {
            $bitmap.Dispose()
        }
    }
    catch {
        return [ordered]@{
            sampleMethod = "64x36 RGB grid over OpenMW ScreenCaptureHandler PNG"
            passed = $false
            faults = @("native-frame-decode-failed")
            error = $_.Exception.Message
        }
    }
}

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$FalloutNewVegasData = [IO.Path]::GetFullPath($FalloutNewVegasData)
$binary = Join-Path $BinaryRoot "openmw.exe"
$resources = Join-Path $BinaryRoot "resources"
$initializer = Join-Path $WorldsRoot "scripts\Initialize-OpenNVBaseProfile.ps1"
foreach ($path in @($binary, $initializer, (Join-Path $FalloutNewVegasData "FalloutNV.esm"))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing TestMap diagnostic requirement: $path"
    }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "Missing TestMap diagnostic runtime resources: $resources"
}
if (@(Get-Process -Name "openmw" -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "Refusing to overlap the TestMap diagnostic with an existing OpenMW process."
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $WorldsRoot ("run\opennv-testmap-diagnostic-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing TestMap diagnostic: $OutputRoot"
}

$stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$profileDirectory = Join-Path $WorldsRoot "profiles\_verification\newvegas-testmap-diagnostic-$stamp"
$campaignUserdata = Join-Path $WorldsRoot "profiles\_verification\_campaigns\newvegas-testmap-diagnostic-$stamp\userdata"
$stdoutPath = Join-Path $OutputRoot "openmw.stdout.log"
$stderrPath = Join-Path $OutputRoot "openmw.stderr.log"
$captureStdoutPath = Join-Path $OutputRoot "ffmpeg.stdout.log"
$captureStderrPath = Join-Path $OutputRoot "ffmpeg.stderr.log"
$rawVideoPath = Join-Path $OutputRoot "OpenMW-TestMap01-exact-title-raw.mp4"
$mobileVideoPath = Join-Path $OutputRoot "OpenMW-TestMap01-native-frame-mobile.mp4"
$nativeFramePath = Join-Path $OutputRoot "TestMap01-native.png"
$reportPath = Join-Path $OutputRoot "testmap-diagnostic-report.json"

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$profile = & $initializer `
    -FalloutNewVegasData $FalloutNewVegasData `
    -ProfileDirectory $profileDirectory `
    -CampaignUserdataDirectory $campaignUserdata `
    -BinaryRoot $BinaryRoot `
    -Force
if (-not [bool]$profile.launchable) {
    throw "The isolated New Vegas TestMap profile is not launchable: $($profile.installReasons -join '; ')"
}
$settingsPath = Join-Path ([string]$profile.profileDirectory) "settings.cfg"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "screenshot format" -Value "png"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "notify on saved screenshot" -Value "false"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "minimize on focus loss" -Value "false"
# This build's Bullet library is deliberately single-threaded. Requesting no
# asynchronous physics workers avoids a capability warning without changing
# the TestMap simulation path.
Set-CaptureProfileSetting -Path $settingsPath -Section "Physics" -Key "async num threads" -Value "0"

$previousEnvironment = Save-And-ClearOpenMwEnvironment
$previousTextureStorage = [Environment]::GetEnvironmentVariable("OSG_GL_TEXTURE_STORAGE", "Process")
$game = $null
$gameStdoutTask = $null
$gameStderrTask = $null
$gameStreamsSaved = $false
$recorder = $null
$recorderStdoutTask = $null
$recorderStderrTask = $null
$recorderExitCode = $null
$recorderStreamsSaved = $false
$captureError = $null
$gameTermination = "not-started"
$nativeSourceFrame = $null
$startedAt = [DateTime]::UtcNow
try {
    # TestMap's native Fallout map and UI textures receive later image updates.
    # OSG's immutable-storage path rejects those updates on the NVIDIA driver;
    # use OSG's supported mutable-storage mode for this isolated Fallout run.
    [Environment]::SetEnvironmentVariable("OSG_GL_TEXTURE_STORAGE", "OFF", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "INFO", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_START_WORLDSPACE", $TestMapWorldspace, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_START_GRID_X", [string]$TestMapGridX, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_START_GRID_Y", [string]$TestMapGridY, "Process")
    if ($OpenGlDebug) {
        [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_OPENGL", "1", "Process")
    }
    # This is deliberately the existing engine-native screenshot hook. No
    # keyboard binding, console command, desktop click, or window focus call
    # reaches the game; the explicit --start bypasses authored New Game logic
    # so the diagnostic remains in TestMap01.
    [Environment]::SetEnvironmentVariable("OPENMW_PROOF_SCREENSHOT_FRAME", [string]$NativeScreenshotFrame, "Process")

    $arguments = @(
        "--replace", "config",
        "--config", [string]$profile.profileDirectory,
        "--resources", [string]$profile.resourcesRoot,
        "--skip-menu", "--start", "TestMap01"
    )
    $argumentLine = ($arguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "
    # Keep the engine streams owned by this process object and write them only
    # after OpenMW has exited. Start-Process keeps the redirected file handles
    # open long enough to race report hashing on Windows.
    $gameStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $gameStartInfo.FileName = $binary
    $gameStartInfo.Arguments = $argumentLine
    $gameStartInfo.WorkingDirectory = Split-Path -Parent $binary
    $gameStartInfo.UseShellExecute = $false
    $gameStartInfo.CreateNoWindow = $false
    $gameStartInfo.RedirectStandardOutput = $true
    $gameStartInfo.RedirectStandardError = $true
    $game = [Diagnostics.Process]::new()
    $game.StartInfo = $gameStartInfo
    if (-not $game.Start()) {
        throw "Unable to start OpenMW for the TestMap diagnostic."
    }
    $gameStdoutTask = $game.StandardOutput.ReadToEndAsync()
    $gameStderrTask = $game.StandardError.ReadToEndAsync()

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($game.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $game.Refresh()
        if ($game.HasExited) {
            throw "OpenMW exited before the TestMap diagnostic window appeared."
        }
    }
    if ($game.MainWindowHandle -eq 0) {
        throw "OpenMW did not expose an exact-title capture window for the TestMap diagnostic."
    }

    $ffmpegArguments = @(
        "-hide_banner", "-loglevel", "warning", "-y",
        "-f", "gdigrab", "-framerate", "60", "-draw_mouse", "0", "-i", "title=OpenMW",
        "-t", ([string]$CaptureSeconds),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", $rawVideoPath
    )
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
    if (-not $recorder.Start()) {
        throw "Unable to start the exact-title TestMap recorder."
    }
    $recorderStdoutTask = $recorder.StandardOutput.ReadToEndAsync()
    $recorderStderrTask = $recorder.StandardError.ReadToEndAsync()

    $screenshotDirectory = Join-Path $campaignUserdata "screenshots"
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $screenshotDirectory -PathType Container) {
            $candidate = Get-ChildItem -LiteralPath $screenshotDirectory -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension.ToLowerInvariant() -in @(".png", ".jpg", ".jpeg") } |
                Sort-Object LastWriteTimeUtc, Name | Select-Object -Last 1
            if ($null -ne $candidate -and $candidate.Length -gt 0) {
                $nativeSourceFrame = $candidate
                break
            }
        }
        $game.Refresh()
        if ($game.HasExited) {
            throw "OpenMW exited before its native TestMap screenshot was written."
        }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $nativeSourceFrame) {
        throw "Timed out waiting for the native OpenMW TestMap screenshot."
    }
    Copy-Item -LiteralPath $nativeSourceFrame.FullName -Destination $nativeFramePath -ErrorAction Stop

    $recorder.WaitForExit()
    $recorder.Refresh()
    $recorderExitCode = $recorder.ExitCode
    Save-AsyncProcessStreams `
        -StandardOutputTask $recorderStdoutTask `
        -StandardErrorTask $recorderStderrTask `
        -StandardOutputPath $captureStdoutPath `
        -StandardErrorPath $captureStderrPath
    $recorderStreamsSaved = $true
    if ($recorderExitCode -ne 0 -or -not (Test-Path -LiteralPath $rawVideoPath -PathType Leaf)) {
        throw "The exact-title TestMap recorder did not produce a valid raw MP4."
    }
}
catch {
    $captureError = $_.Exception.Message
}
finally {
    if ($null -ne $recorder) {
        $recorder.Refresh()
        if (-not $recorder.HasExited) {
            $recorder.Kill()
            $recorder.WaitForExit()
        }
        if ($null -eq $recorderExitCode -and $recorder.HasExited) {
            $recorderExitCode = $recorder.ExitCode
        }
        if (-not $recorderStreamsSaved -and $null -ne $recorderStdoutTask -and $null -ne $recorderStderrTask) {
            Save-AsyncProcessStreams `
                -StandardOutputTask $recorderStdoutTask `
                -StandardErrorTask $recorderStderrTask `
                -StandardOutputPath $captureStdoutPath `
                -StandardErrorPath $captureStderrPath
        }
    }
    if ($null -ne $game) {
        $game.Refresh()
        if (-not $game.HasExited) {
            Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue
            [void]$game.WaitForExit(15000)
            $game.Refresh()
            if ($game.HasExited) {
                $gameTermination = "owned-process-terminated-after-capture"
            }
            else {
                $gameTermination = "owned-process-exit-timeout"
                if ([string]::IsNullOrWhiteSpace($captureError)) {
                    $captureError = "Timed out waiting for the owned OpenMW process to release its capture streams."
                }
            }
        }
        else {
            $gameTermination = "engine-exited"
        }
        if ($game.HasExited -and -not $gameStreamsSaved -and $null -ne $gameStdoutTask -and $null -ne $gameStderrTask) {
            Save-AsyncProcessStreams `
                -StandardOutputTask $gameStdoutTask `
                -StandardErrorTask $gameStderrTask `
                -StandardOutputPath $stdoutPath `
                -StandardErrorPath $stderrPath
            $gameStreamsSaved = $true
        }
        $game.Dispose()
        $game = $null
    }
    Restore-Environment -Values $previousEnvironment
    [Environment]::SetEnvironmentVariable("OSG_GL_TEXTURE_STORAGE", $previousTextureStorage, "Process")
}

$nativeFrameHealth = if (Test-Path -LiteralPath $nativeFramePath -PathType Leaf) {
    Get-NativeFrameHealth -Path $nativeFramePath
} else {
    [ordered]@{ passed = $false; faults = @("native-frame-missing") }
}

if (Test-Path -LiteralPath $nativeFramePath -PathType Leaf) {
    $mobileArguments = @(
        "-hide_banner", "-loglevel", "warning", "-y",
        "-loop", "1", "-framerate", "30", "-i", $nativeFramePath,
        "-t", "5", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", $mobileVideoPath
    )
    $mobile = Start-Process -FilePath (Get-Command ffmpeg -ErrorAction Stop).Source `
        -ArgumentList (($mobileArguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " ") `
        -WindowStyle Hidden -Wait -PassThru
    if ($mobile.ExitCode -ne 0) {
        $captureError = if ($null -eq $captureError) {
            "Unable to encode the native TestMap frame for mobile playback."
        } else {
            "$captureError; unable to encode the native TestMap frame for mobile playback."
        }
    }
}

$logText = @(
    $(if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -Raw -LiteralPath $stdoutPath }),
    $(if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -Raw -LiteralPath $stderrPath }),
    $(if (Test-Path -LiteralPath (Join-Path $profile.profileDirectory "openmw.log") -PathType Leaf) {
        Get-Content -Raw -LiteralPath (Join-Path $profile.profileDirectory "openmw.log")
    })
) -join [Environment]::NewLine
$logLines = @($logText -split "[\r\n]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
# The renderer reports resource paths as `Resource 'textures/...' not found`,
# rather than directly after `Failed to open image:`. Keep the full matching
# log lines so a failed diagnostic names the actual missing assets.
$missingTextureFailures = @($logLines | Where-Object {
    $_ -match "Failed to open image:"
})
$missingModelFailures = @($logLines | Where-Object {
    $_ -match "(?:Failed to load|failed to insert).+Resource 'meshes/.+' not found"
})
$missingGlobalScriptFailures = @($logLines | Where-Object {
    $_ -match 'Failed to add global script'
})
$unsupportedObScriptFailures = @($logLines | Where-Object {
    $_ -match 'FNV/ESM4 ObScript unsupported command:'
})
$unhandledControllerDiagnostics = @($logLines | Where-Object {
    $_ -match 'Unhandled controller '
})
$runtimeErrorDiagnostics = @($logLines | Where-Object {
    $_ -match '\sE\]'
})
$runtimeWarningDiagnostics = @($logLines | Where-Object {
    $_ -match '\[[^\]]*\sW\]'
})
$runtimeCleanlinessFailures = @(
    $missingTextureFailures
    $missingModelFailures
    $missingGlobalScriptFailures
    $unsupportedObScriptFailures
    $unhandledControllerDiagnostics
    $runtimeErrorDiagnostics
    $runtimeWarningDiagnostics
)
$testMapRequested = $logText -match [regex]::Escape("TestMap01")
$testMapExteriorPlacementObserved = $logText -match [regex]::Escape("World viewer: explicit exterior start location=")
$testMapStartFailureObserved = $logText -match [regex]::Escape("Failed to start new game:")
$rawVideoArtifact = Get-Artifact $rawVideoPath
$nativeFrameArtifact = Get-Artifact $nativeFramePath
$mobileVideoArtifact = Get-Artifact $mobileVideoPath
$passed = [string]::IsNullOrWhiteSpace($captureError) -and $testMapRequested -and
    $testMapExteriorPlacementObserved -and -not $testMapStartFailureObserved -and
    $null -ne $rawVideoArtifact -and $null -ne $nativeFrameArtifact -and $null -ne $mobileVideoArtifact -and
    [bool]$nativeFrameHealth.passed -and $runtimeCleanlinessFailures.Count -eq 0

$report = [ordered]@{
    schema = "opennv-testmap01-clean-diagnostic/v1"
    status = if ($passed) { "pass" } else { "fail" }
    diagnosticOnly = $true
    purpose = "Visual asset and renderer diagnostic. TestMap01 is not an authored New Vegas start and is never gameplay-opening proof."
    startedAtUtc = $startedAt.ToString("o")
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    launch = [ordered]@{
        skipMenu = $true
        newGame = $false
        newGameMechanicsBypassed = $true
        explicitStartCell = "TestMap01"
        explicitExteriorWorldspace = $TestMapWorldspace
        explicitExteriorGrid = @($TestMapGridX, $TestMapGridY)
        explicitStartCellIsNotGameplayProof = $true
    }
    capture = [ordered]@{
        method = "OpenMW ScreenCaptureHandler native framebuffer screenshot plus exact-title ffmpeg transport capture"
        driver = "explicit --start TestMap01 diagnostic; no game input is sent"
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        windowTitle = "OpenMW"
        nativeScreenshotFrame = $NativeScreenshotFrame
        gameTermination = $gameTermination
        recorderExitCode = $recorderExitCode
    }
    source = [ordered]@{
        binary = $binary
        resources = $resources
        falloutNewVegasData = $FalloutNewVegasData
        profileDirectory = $profile.profileDirectory
        profileManifest = $profile.manifestPath
        content = @($profile.content)
    }
    assertions = [ordered]@{
        explicitTestMapRequestObserved = $testMapRequested
        explicitTestMapExteriorPlacementObserved = $testMapExteriorPlacementObserved
        explicitTestMapStartFailureAbsent = -not $testMapStartFailureObserved
        nativeFrameHealth = $nativeFrameHealth
        missingLegacyTextureFailures = @($missingTextureFailures)
        missingLegacyTextureFailuresAbsent = $missingTextureFailures.Count -eq 0
        runtimeCleanliness = [ordered]@{
            passed = $runtimeCleanlinessFailures.Count -eq 0
            missingTextureFailures = @($missingTextureFailures)
            missingModelFailures = @($missingModelFailures)
            missingGlobalScriptFailures = @($missingGlobalScriptFailures)
            unsupportedObScriptFailures = @($unsupportedObScriptFailures)
            unhandledControllerDiagnostics = @($unhandledControllerDiagnostics)
            errorDiagnostics = @($runtimeErrorDiagnostics)
            warningDiagnostics = @($runtimeWarningDiagnostics)
        }
    }
    artifacts = @(
        (Get-Artifact $stdoutPath),
        (Get-Artifact $stderrPath),
        (Get-Artifact (Join-Path $profile.profileDirectory "openmw.log")),
        (Get-Artifact $captureStdoutPath),
        (Get-Artifact $captureStderrPath),
        $rawVideoArtifact,
        $nativeFrameArtifact,
        $mobileVideoArtifact
    ) | Where-Object { $null -ne $_ }
    error = $captureError
}
[IO.File]::WriteAllText(
    $reportPath,
    (($report | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))

$report | ConvertTo-Json -Depth 10
if (-not $passed) {
    throw "OpenNV TestMap01 renderer diagnostic failed. See $reportPath"
}
