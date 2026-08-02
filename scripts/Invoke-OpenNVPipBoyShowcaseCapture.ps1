[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$BinaryRoot = "",
    [string]$FalloutNewVegasData = "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data",
    [string]$OutputRoot = "",
    [ValidateRange(60, 90)]
    [int]$CaptureSeconds = 80,
    [ValidateRange(45, 300)]
    [int]$TimeoutSeconds = 150,
    # One Pip-Boy action should finish its visible reach-and-return before the
    # next state changes.  This makes the retained native video useful for
    # reviewing the two-arm motion rather than a rapid panel slideshow.
    [ValidateRange(60, 300)]
    [int]$FramesPerPane = 150,
    [ValidateRange(1, 299)]
    [int]$CaptureDelayFrames = 135,
    # Final developer placement after the normal New Game path. This is not a
    # --start bypass and the report records the distinction.
    [string]$TestMapWorldspace = "FormId:0x010d703c",
    [int]$TestMapGridX = -3,
    [int]$TestMapGridY = 6
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($CaptureDelayFrames -ge $FramesPerPane) {
    throw "CaptureDelayFrames must be less than FramesPerPane for the Pip-Boy showcase."
}

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

function New-PipBoyPanelCollage {
    param(
        [Parameter(Mandatory = $true)][string[]]$FramePaths,
        [Parameter(Mandatory = $true)][string[]]$PanelNames,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $bitmaps = [Collections.Generic.List[System.Drawing.Bitmap]]::new()
    try {
        # Force each value through a scalar string before overload resolution.
        # PowerShell can otherwise pass a nested string array as the two-arg
        # Bitmap(filename, useIcm) overload on some hosts.
        foreach ($frame in @($FramePaths | ForEach-Object { [string]$_ })) {
            $bitmaps.Add([System.Drawing.Bitmap]::new([string]$frame))
        }
        # Measure-Object returns Double even for pixel dimensions.  Cast before
        # calling Bitmap(width, height), otherwise PowerShell can select the
        # filename/useIcm constructor instead of the pixel-dimension overload.
        $maxWidth = [int](($bitmaps | Measure-Object -Property Width -Maximum).Maximum)
        $maxHeight = [int](($bitmaps | Measure-Object -Property Height -Maximum).Maximum)
        # A full state sweep has more than the original four panels. Keep the
        # collage reviewable without allocating a multi-hundred-megabyte image.
        $thumbnailScale = [Math]::Min(1.0, [Math]::Min(640.0 / $maxWidth, 360.0 / $maxHeight))
        $tileWidth = [int][Math]::Round($maxWidth * $thumbnailScale)
        $tileHeight = [int][Math]::Round($maxHeight * $thumbnailScale)
        $padding = 28
        $captionHeight = 42
        $columnCount = 2
        $rowCount = [int][Math]::Ceiling($bitmaps.Count / [double]$columnCount)
        $canvasWidth = [int](($tileWidth * $columnCount) + ($padding * ($columnCount + 1)))
        $canvasHeight = [int]((($tileHeight + $captionHeight) * $rowCount) + ($padding * ($rowCount + 1)))
        $canvas = [System.Drawing.Bitmap]::new($canvasWidth, $canvasHeight)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($canvas)
            try {
                $graphics.Clear([System.Drawing.Color]::FromArgb(9, 18, 9))
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $font = [System.Drawing.Font]::new("Consolas", 20, [System.Drawing.FontStyle]::Bold)
                $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(120, 255, 135))
                try {
                    for ($index = 0; $index -lt $bitmaps.Count; ++$index) {
                        $column = $index % $columnCount
                        $row = [int]($index / $columnCount)
                        $left = $padding + ($column * ($tileWidth + $padding))
                        $top = $padding + ($row * ($tileHeight + $captionHeight + $padding))
                        $graphics.DrawImage($bitmaps[$index], $left, $top, $tileWidth, $tileHeight)
                        $graphics.DrawString("LIVE PIP-BOY - $($PanelNames[$index])", $font, $brush, $left, $top + $tileHeight + 7)
                    }
                }
                finally {
                    $font.Dispose()
                    $brush.Dispose()
                }
            }
            finally {
                $graphics.Dispose()
            }
            $canvas.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $canvas.Dispose()
        }
    }
    finally {
        foreach ($bitmap in $bitmaps) {
            $bitmap.Dispose()
        }
    }
}

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    $BinaryRoot = Join-Path $WorldsRoot "local\openmw-testmap-fnv-clean-20260801-080000"
}
$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$FalloutNewVegasData = [IO.Path]::GetFullPath($FalloutNewVegasData)
$binary = Join-Path $BinaryRoot "openmw.exe"
$resources = Join-Path $BinaryRoot "resources"
$initializer = Join-Path $WorldsRoot "scripts\Initialize-OpenNVBaseProfile.ps1"
foreach ($path in @($binary, $initializer, (Join-Path $FalloutNewVegasData "FalloutNV.esm"))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing live Pip-Boy showcase requirement: $path"
    }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "Missing live Pip-Boy showcase runtime resources: $resources"
}
if (@(Get-Process -Name "openmw" -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "Refusing to overlap the Pip-Boy showcase with an existing OpenMW process."
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $WorldsRoot ("run\opennv-pipboy-showcase-" + [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ"))
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing Pip-Boy showcase: $OutputRoot"
}

$stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$profileDirectory = Join-Path $WorldsRoot "profiles\_verification\newvegas-pipboy-showcase-$stamp"
$campaignUserdata = Join-Path $WorldsRoot "profiles\_verification\_campaigns\newvegas-pipboy-showcase-$stamp\userdata"
$stdoutPath = Join-Path $OutputRoot "openmw.stdout.log"
$stderrPath = Join-Path $OutputRoot "openmw.stderr.log"
$captureStdoutPath = Join-Path $OutputRoot "ffmpeg.stdout.log"
$captureStderrPath = Join-Path $OutputRoot "ffmpeg.stderr.log"
$rawVideoPath = Join-Path $OutputRoot "OpenMW-PipBoy-live-exact-title-raw.mp4"
$collagePath = Join-Path $OutputRoot "PipBoy-live-panel-collage.png"
$reportPath = Join-Path $OutputRoot "pipboy-showcase-report.json"
$panelNames = @(
    "STATS-CND", "STATS-RAD", "STATS-EFF", "STATS-SPECIAL", "STATS-SKILLS", "STATS-PERKS", "STATS-GENERAL",
    "ITEMS-WEAP-9MM", "ITEMS-WEAP-VARMINT", "ITEMS-APP-SUIT", "ITEMS-APP-HAT", "ITEMS-AID-STIMPAK",
    "ITEMS-MISC-CAPS", "ITEMS-AMMO-9MM", "ITEMS-AMMO-556", "DATA-QUESTS", "DATA-QUESTS-SCROLL", "DATA-NOTES",
    "DATA-RADIO", "MAP-WORLD", "MAP-WORLD-ZOOM-PAN", "MAP-LOCAL", "MAP-LOCAL-ZOOM-PAN", "WORLD-VARMINT-EQUIPPED"
)
$expectedNativeStateCount = $panelNames.Count
$nativeFramePaths = @($panelNames | ForEach-Object { Join-Path $OutputRoot ("PipBoy-$($_)-native.png") })

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$profile = & $initializer `
    -FalloutNewVegasData $FalloutNewVegasData `
    -ProfileDirectory $profileDirectory `
    -CampaignUserdataDirectory $campaignUserdata `
    -BinaryRoot $BinaryRoot `
    -Force
if (-not [bool]$profile.launchable) {
    throw "The isolated Pip-Boy showcase profile is not launchable: $($profile.installReasons -join '; ')"
}
$settingsPath = Join-Path ([string]$profile.profileDirectory) "settings.cfg"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "screenshot format" -Value "png"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "notify on saved screenshot" -Value "false"
Set-CaptureProfileSetting -Path $settingsPath -Section "General" -Key "minimize on focus loss" -Value "false"
Set-CaptureProfileSetting -Path $settingsPath -Section "OpenNV Compatibility" -Key "fallout controls" -Value "true"
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
$recorderStreamsSaved = $false
$recorderExitCode = $null
$gameTermination = "not-started"
$captureError = $null
$startedAt = [DateTime]::UtcNow
try {
    # The native FNV menu textures update after initial allocation. Use OSG's
    # supported mutable-storage mode for this isolated render-only pass.
    [Environment]::SetEnvironmentVariable("OSG_GL_TEXTURE_STORAGE", "OFF", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_DEBUG_LEVEL", "INFO", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_GAMEPLAY_START_WORLDSPACE", $TestMapWorldspace, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_GAMEPLAY_START_GRID_X", [string]$TestMapGridX, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_GAMEPLAY_START_GRID_Y", [string]$TestMapGridY, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_PIPBOY_SHOWCASE", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_PIPBOY_SHOWCASE_LOADOUT", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_PIPBOY_SHOWCASE_FIRST_READY_FRAME", "60", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_PIPBOY_SHOWCASE_FRAMES_PER_PANE", [string]$FramesPerPane, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_PIPBOY_SHOWCASE_CAPTURE_DELAY_FRAMES", [string]$CaptureDelayFrames, "Process")

    $arguments = @(
        "--replace", "config",
        "--config", [string]$profile.profileDirectory,
        "--resources", [string]$profile.resourcesRoot,
        "--skip-menu", "--new-game"
    )
    $gameStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $gameStartInfo.FileName = $binary
    $gameStartInfo.Arguments = ($arguments | ForEach-Object { Quote-OpenNVArgument $_ }) -join " "
    $gameStartInfo.WorkingDirectory = Split-Path -Parent $binary
    $gameStartInfo.UseShellExecute = $false
    $gameStartInfo.CreateNoWindow = $false
    $gameStartInfo.RedirectStandardOutput = $true
    $gameStartInfo.RedirectStandardError = $true
    # ProcessStartInfo can snapshot its environment before the caller's
    # environment changes on some .NET builds. Set the declared child values
    # explicitly as well, so the normal-New-Game placement and native panel
    # schedule are unambiguously owned by this isolated process.
    foreach ($entry in @{
        "OSG_GL_TEXTURE_STORAGE" = "OFF"
        "OPENMW_DEBUG_LEVEL" = "INFO"
        "OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG" = "1"
        "OPENMW_FNV_GAMEPLAY_START_WORLDSPACE" = $TestMapWorldspace
        "OPENMW_FNV_GAMEPLAY_START_GRID_X" = [string]$TestMapGridX
        "OPENMW_FNV_GAMEPLAY_START_GRID_Y" = [string]$TestMapGridY
        "OPENMW_FNV_PIPBOY_SHOWCASE" = "1"
        "OPENMW_FNV_PIPBOY_SHOWCASE_LOADOUT" = "1"
        "OPENMW_FNV_PIPBOY_SHOWCASE_FIRST_READY_FRAME" = "60"
        "OPENMW_FNV_PIPBOY_SHOWCASE_FRAMES_PER_PANE" = [string]$FramesPerPane
        "OPENMW_FNV_PIPBOY_SHOWCASE_CAPTURE_DELAY_FRAMES" = [string]$CaptureDelayFrames
    }.GetEnumerator()) {
        $gameStartInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
    }
    $game = [Diagnostics.Process]::new()
    $game.StartInfo = $gameStartInfo
    if (-not $game.Start()) {
        throw "Unable to start OpenMW for the live Pip-Boy showcase."
    }
    $gameStdoutTask = $game.StandardOutput.ReadToEndAsync()
    $gameStderrTask = $game.StandardError.ReadToEndAsync()

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($game.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $game.Refresh()
        if ($game.HasExited) {
            throw "OpenMW exited before the live Pip-Boy showcase window appeared."
        }
    }
    if ($game.MainWindowHandle -eq 0) {
        throw "OpenMW did not expose an exact-title capture window for the Pip-Boy showcase."
    }

    # Exact-title transport recording supplements the four native framebuffer
    # PNGs. It never activates, focuses, or injects input into the window.
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
        throw "Unable to start the exact-title Pip-Boy recorder."
    }
    $recorderStdoutTask = $recorder.StandardOutput.ReadToEndAsync()
    $recorderStderrTask = $recorder.StandardError.ReadToEndAsync()

    $screenshotDirectory = Join-Path $campaignUserdata "screenshots"
    $nativeSourceFrames = @()
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $screenshotDirectory -PathType Container) {
            $nativeSourceFrames = @(Get-ChildItem -LiteralPath $screenshotDirectory -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 0 -and $_.Extension.ToLowerInvariant() -in @(".png", ".jpg", ".jpeg") } |
                Sort-Object LastWriteTimeUtc, Name)
            if ($nativeSourceFrames.Count -ge $expectedNativeStateCount) {
                break
            }
        }
        $game.Refresh()
        if ($game.HasExited) {
            throw "OpenMW exited before all $expectedNativeStateCount native Pip-Boy states were written."
        }
        Start-Sleep -Milliseconds 100
    }
    if ($nativeSourceFrames.Count -lt $expectedNativeStateCount) {
        throw "Timed out waiting for $expectedNativeStateCount native Pip-Boy states; received $($nativeSourceFrames.Count)."
    }
    for ($index = 0; $index -lt $expectedNativeStateCount; ++$index) {
        Copy-Item -LiteralPath $nativeSourceFrames[$index].FullName -Destination $nativeFramePaths[$index] -ErrorAction Stop
    }

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
        throw "The exact-title Pip-Boy recorder did not produce a valid raw MP4."
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
            $gameTermination = if ($game.HasExited) {
                "owned-process-terminated-after-capture"
            } else {
                "owned-process-exit-timeout"
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
    }
    Restore-Environment -Values $previousEnvironment
    [Environment]::SetEnvironmentVariable("OSG_GL_TEXTURE_STORAGE", $previousTextureStorage, "Process")
}

if ([string]::IsNullOrWhiteSpace($captureError) -and @($nativeFramePaths | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
}).Count -eq $expectedNativeStateCount) {
    try {
        New-PipBoyPanelCollage -FramePaths $nativeFramePaths -PanelNames $panelNames -Destination $collagePath
    }
    catch {
        $captureError = "Unable to compose the native Pip-Boy panel collage: $($_.Exception.Message)"
    }
}

$profileLogPath = Join-Path $profile.profileDirectory "openmw.log"
# In the isolated launcher OpenMW mirrors its log to stdout and openmw.log.
# Retain a distinct profile log when it adds information, but do not count the
# same byte stream twice: each panel-open/capture event is one engine event.
$logTexts = [Collections.Generic.List[string]]::new()
$seenLogHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($logPath in @($stdoutPath, $stderrPath, $profileLogPath)) {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        continue
    }
    $logHash = (Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash
    if ($seenLogHashes.Add($logHash)) {
        $logTexts.Add((Get-Content -Raw -LiteralPath $logPath))
    }
}
$logText = $logTexts -join [Environment]::NewLine
$logLines = @($logText -split "[\r\n]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$normalNewGameObserved = $logText -match [regex]::Escape("World viewer: startNewGame complete bypass=0")
$testMapPlacementObserved = $logText -match [regex]::Escape("FNV gameplay start: applied final developer exterior placement=")
$authoredLoadoutObserved = $logText -match 'FNV Pip-Boy showcase: authored loadout source=FalloutNV\.esm fallbackItems=0.*status=pass'
$fallbackInventoryRecordsObserved = $logText -match 'inserted fallback inventory (weapon|potion|misc)'
$panelOpenEvents = @($logLines | Where-Object { $_ -match 'FNV Pip-Boy showcase: opened live state=' })
$panelCaptureEvents = @($logLines | Where-Object { $_ -match 'FNV Pip-Boy showcase: queuing GUI-inclusive native frame state=' })
$runtimeErrors = @($logLines | Where-Object { $_ -match '\sE\]' })
$runtimeWarnings = @($logLines | Where-Object { $_ -match '\[[^\]]*\sW\]' })
$nativeFrameArtifacts = @(
    @($nativeFramePaths | ForEach-Object { Get-Artifact $_ }) | Where-Object { $null -ne $_ }
)
$rawVideoArtifact = Get-Artifact $rawVideoPath
$collageArtifact = Get-Artifact $collagePath
$passed = [string]::IsNullOrWhiteSpace($captureError) -and $normalNewGameObserved -and $testMapPlacementObserved -and
    $authoredLoadoutObserved -and -not $fallbackInventoryRecordsObserved -and $panelOpenEvents.Count -eq $expectedNativeStateCount -and
    $panelCaptureEvents.Count -eq $expectedNativeStateCount -and $nativeFrameArtifacts.Count -eq $expectedNativeStateCount -and $null -ne $rawVideoArtifact -and
    $null -ne $collageArtifact

$report = [ordered]@{
    schema = "opennv-pipboy-live-panel-showcase/v2"
    status = if ($passed) { "pass" } else { "fail" }
    purpose = "Live Fallout Pip-Boy state sweep: every STATS, ITEMS, DATA, and MAP sub-screen, live item actions, and final equipped-weapon confirmation after normal New Game initialization and final TestMap01 placement."
    startedAtUtc = $startedAt.ToString("o")
    completedAtUtc = [DateTime]::UtcNow.ToString("o")
    launch = [ordered]@{
        skipMenu = $true
        newGame = $true
        newGameMechanicsBypassed = $false
        finalDeveloperExteriorWorldspace = $TestMapWorldspace
        finalDeveloperExteriorGrid = @($TestMapGridX, $TestMapGridY)
    }
    capture = [ordered]@{
        method = "OpenMW ScreenCaptureHandler retains every GUI-inclusive native Pip-Boy state PNG; ffmpeg retains an exact-title OpenMW transport MP4; the collage only arranges the retained native PNGs."
        driver = "Engine-owned dedicated Fallout Pip-Boy interaction schedule after normal New Game; no host keyboard or mouse input is sent."
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        windowTitle = "OpenMW"
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
        normalNewGameObserved = $normalNewGameObserved
        finalTestMapPlacementObserved = $testMapPlacementObserved
        authoredFalloutDataLoadoutObserved = $authoredLoadoutObserved
        fallbackInventoryRecordsAbsent = -not $fallbackInventoryRecordsObserved
        expectedNativeStateCount = $expectedNativeStateCount
        nativeStateNames = @($panelNames)
        panelOpenEvents = @($panelOpenEvents)
        panelCaptureEvents = @($panelCaptureEvents)
        nativePanelCount = $nativeFrameArtifacts.Count
        collageDerivedOnlyFromNativePanels = $null -ne $collageArtifact
    }
    runtimeDiagnostics = [ordered]@{
        errors = @($runtimeErrors)
        warnings = @($runtimeWarnings)
    }
    artifacts = @(
        (Get-Artifact $stdoutPath),
        (Get-Artifact $stderrPath),
        (Get-Artifact $profileLogPath),
        (Get-Artifact $captureStdoutPath),
        (Get-Artifact $captureStderrPath),
        $rawVideoArtifact
    ) + $nativeFrameArtifacts + @($collageArtifact) | Where-Object { $null -ne $_ }
    error = $captureError
}
[IO.File]::WriteAllText(
    $reportPath,
    (($report | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))

$report | ConvertTo-Json -Depth 10
if (-not $passed) {
    throw "OpenNV live Pip-Boy showcase failed. See $reportPath"
}
