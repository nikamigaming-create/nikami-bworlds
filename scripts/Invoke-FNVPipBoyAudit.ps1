[CmdletBinding()]
param(
    [string]$OpenMWExe = "local/openmw-fo4guard/openmw.exe",
    [string]$ResourcesRoot = "local/openmw-fo4guard/resources",
    [string]$ProfileDirectory = "",
    [string]$MorrowindProfileDirectory = "",
    [string]$StartupScript = "config/starts/fnv-level-one-goodsprings.txt",
    [string]$SavePath = "",
    [string]$OutputRoot = "run/fnv-pipboy-audit",
    [ValidateRange(640, 7680)]
    [int]$ResolutionX = 1920,
    [ValidateRange(480, 4320)]
    [int]$ResolutionY = 1080,
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ConfigValue([string]$ConfigPath, [string]$Key) {
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -match ('^\s*' + [Regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Resolve-SharedWorldRoot {
    $local = Get-Item -LiteralPath (Join-Path $repoRoot "local") -Force
    $target = @($local.Target | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) |
        Select-Object -First 1
    if ($null -ne $target) { return Split-Path -Parent ([IO.Path]::GetFullPath([string]$target)) }

    $sibling = Join-Path (Split-Path -Parent $repoRoot) "nikami-worlds"
    if (Test-Path -LiteralPath $sibling -PathType Container) { return [IO.Path]::GetFullPath($sibling) }
    throw "Unable to resolve the shared nikami-worlds root; pass -ProfileDirectory and -MorrowindProfileDirectory."
}

function Measure-Screenshot([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new($Path)
    try {
        $step = [Math]::Max(1, [int][Math]::Floor([Math]::Min($bitmap.Width, $bitmap.Height) / 120.0))
        [long]$samples = 0
        [long]$nonBlack = 0
        [long]$magenta = 0
        [double]$sum = 0
        [double]$squared = 0
        $colors = [Collections.Generic.HashSet[int]]::new()
        for ($y = 0; $y -lt $bitmap.Height; $y += $step) {
            for ($x = 0; $x -lt $bitmap.Width; $x += $step) {
                $pixel = $bitmap.GetPixel($x, $y)
                $luma = (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
                ++$samples
                if ($luma -gt 12) { ++$nonBlack }
                if ($pixel.R -gt 110 -and $pixel.B -gt 110 -and $pixel.G -lt ([Math]::Min($pixel.R, $pixel.B) * 0.55)) {
                    ++$magenta
                }
                $sum += $luma
                $squared += $luma * $luma
                $quantized = (($pixel.R -shr 4) -shl 8) -bor (($pixel.G -shr 4) -shl 4) -bor ($pixel.B -shr 4)
                $colors.Add($quantized) | Out-Null
            }
        }
        $mean = if ($samples) { $sum / $samples } else { 0.0 }
        $deviation = if ($samples) {
            [Math]::Sqrt([Math]::Max(0.0, ($squared / $samples) - ($mean * $mean)))
        } else { 0.0 }
        $nonBlackFraction = if ($samples) { $nonBlack / [double]$samples } else { 0.0 }
        $magentaFraction = if ($samples) { $magenta / [double]$samples } else { 0.0 }
        [pscustomobject][ordered]@{
            path = $Path -replace "\\", "/"
            width = $bitmap.Width
            height = $bitmap.Height
            sampleCount = $samples
            distinctQuantizedColors = $colors.Count
            nonBlackFraction = $nonBlackFraction
            meanLuma = $mean
            lumaStandardDeviation = $deviation
            magentaFraction = $magentaFraction
            pass = $nonBlackFraction -ge 0.05 -and $deviation -ge 4.0 -and
                $colors.Count -ge 32 -and $magentaFraction -lt 0.35
        }
    } finally {
        $bitmap.Dispose()
    }
}

function Measure-ScreenshotDifference([string]$LeftPath, [string]$RightPath) {
    Add-Type -AssemblyName System.Drawing
    $left = [Drawing.Bitmap]::new($LeftPath)
    $right = [Drawing.Bitmap]::new($RightPath)
    try {
        if ($left.Width -ne $right.Width -or $left.Height -ne $right.Height) { return 1.0 }
        $step = [Math]::Max(1, [int][Math]::Floor([Math]::Min($left.Width, $left.Height) / 120.0))
        [long]$samples = 0
        [long]$changed = 0
        for ($y = 0; $y -lt $left.Height; $y += $step) {
            for ($x = 0; $x -lt $left.Width; $x += $step) {
                $a = $left.GetPixel($x, $y)
                $b = $right.GetPixel($x, $y)
                ++$samples
                if ([Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B) -ge 36) {
                    ++$changed
                }
            }
        }
        return $(if ($samples) { $changed / [double]$samples } else { 0.0 })
    } finally {
        $left.Dispose()
        $right.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($ProfileDirectory) -or
    [string]::IsNullOrWhiteSpace($MorrowindProfileDirectory)) {
    $sharedRoot = Resolve-SharedWorldRoot
    if ([string]::IsNullOrWhiteSpace($ProfileDirectory)) {
        $ProfileDirectory = Join-Path $sharedRoot "profiles/fallout_new_vegas"
    }
    if ([string]::IsNullOrWhiteSpace($MorrowindProfileDirectory)) {
        $MorrowindProfileDirectory = Join-Path $sharedRoot "profiles/morrowind"
    }
}

$exe = Resolve-RepoPath $OpenMWExe
$resources = Resolve-RepoPath $ResourcesRoot
$profile = [IO.Path]::GetFullPath($ProfileDirectory)
$morrowindProfile = [IO.Path]::GetFullPath($MorrowindProfileDirectory)
$startup = Resolve-RepoPath $StartupScript
$save = if ([string]::IsNullOrWhiteSpace($SavePath)) { $null } else { Resolve-RepoPath $SavePath }
$outputBase = Resolve-RepoPath $OutputRoot
$baselineConfig = Resolve-RepoPath "config/playable-baseline"
$graphicsConfig = Resolve-RepoPath "config/fnv-playable-graphics"
$doorConfig = Resolve-RepoPath "config/door-preload"

foreach ($path in @($exe, (Join-Path $profile "openmw.cfg"), (Join-Path $morrowindProfile "openmw.cfg"),
    $(if ($null -ne $save) { $save } else { $startup }), (Join-Path $baselineConfig "settings.cfg"), (Join-Path $graphicsConfig "settings.cfg"),
    (Join-Path $doorConfig "settings.cfg"))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Pip-Boy audit input: $path" }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) { throw "Missing resources root: $resources" }
if (Get-Process -Name openmw,openmw_vr -ErrorAction SilentlyContinue) {
    throw "OpenMW is already running; the audit will not replace an existing session."
}

$morrowindData = Get-ConfigValue (Join-Path $morrowindProfile "openmw.cfg") "data"
if ([string]::IsNullOrWhiteSpace($morrowindData)) { throw "Missing shared UI data path in Morrowind profile." }
$morrowindData = [IO.Path]::GetFullPath($morrowindData)

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$output = Join-Path $outputBase $stamp
$sessionConfig = Join-Path $output "session-config"
$sessionUserData = Join-Path $output "user-data"
New-Item -ItemType Directory -Path $sessionConfig,$sessionUserData -Force | Out-Null
Set-Content -LiteralPath (Join-Path $sessionConfig "openmw.cfg") -Encoding utf8 `
    -Value ('user-data="{0}"' -f ($sessionUserData -replace '\\', '/'))
Set-Content -LiteralPath (Join-Path $sessionConfig "settings.cfg") -Encoding ascii -Value @(
    "[Video]"
    "resolution x = $ResolutionX"
    "resolution y = $ResolutionY"
    "fullscreen = false"
    "window border = false"
)

$arguments = @(
    "--replace", "config", "--config", $profile, "--config", $baselineConfig,
    "--config", $graphicsConfig, "--config", $doorConfig, "--config", $sessionConfig,
    "--user-data", $sessionUserData, "--resources", $resources, "--data", $morrowindData,
    "--fallback-archive", "Morrowind.bsa", "--skip-menu"
)
if ($null -ne $save) {
    $arguments += @("--load-savegame", $save)
}
else {
    $arguments += @("--start", "Goodsprings", "--script-run", $startup)
}
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "

$environment = [ordered]@{
    OPENMW_PLAYABLE_SESSION = "1"
    OPENMW_PLAYABLE_SESSION_ID = "fnv-pipboy-audit"
    OPENMW_PLAYABLE_SESSION_BACKGROUND = "1"
    OPENMW_PLAYABLE_SESSION_EXIT_AFTER_COMPLETE = "1"
    OPENMW_PLAYABLE_SESSION_SETTLE_FRAMES = "240"
    OPENMW_PLAYABLE_SESSION_DURATION_SECONDS = "15"
    OPENMW_PLAYABLE_SESSION_FORWARD = "0"
    OPENMW_PLAYABLE_SESSION_STRAFE = "0"
    OPENMW_PLAYABLE_SESSION_RUN = "0"
    OPENMW_PLAYABLE_SESSION_VALIDATE_CAMERAS = "0"
    OPENMW_PLAYABLE_SESSION_REQUIRE_ACTOR = "0"
    OPENMW_PLAYABLE_SESSION_NEUTRALIZE_ACTOR = "0"
    OPENMW_PLAYABLE_SESSION_CAPTURE_SCREENSHOTS = "0"
    OPENMW_PLAYABLE_SESSION_MIN_DISTANCE = "0"
    OPENMW_PLAYABLE_SESSION_MIN_SPEED = "0"
    OPENMW_PROOF_DELAY_STARTUP_SCRIPT = "1"
    OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI = "1"
    OPENMW_PROOF_INVENTORY_FRAME = "450"
    OPENMW_PROOF_INVENTORY_PANE_FRAME = "480,600,720,840"
    OPENMW_PROOF_INVENTORY_PANE_INDEX = "0,1,2,3"
    OPENMW_PROOF_SCREENSHOT_FRAME = "540,660,780,900"
    OPENMW_WORLD_VIEWER_TELEMETRY = "0"
    OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "0"
    OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = "1"
    OPENMW_DISABLE_CRASH_CATCHER = "1"
    OPENMW_DEBUG_LEVEL = "VERBOSE"
}
$prefixes = @("OPENMW_WORLD_VIEWER_", "OPENMW_PROOF_", "OPENMW_FNV_", "OPENMW_ESM4_", "OPENMW_PLAYABLE_")
$previous = @{}
foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
    if ($prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}

$stdout = Join-Path $output "stdout.log"
$stderr = Join-Path $output "stderr.log"
$process = $null
$timedOut = $false
$stoppedAfterCapture = $false
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
    if (-not $process.Start()) { throw "Failed to start hidden Pip-Boy audit." }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $captureDirectory = Join-Path $sessionUserData "screenshots"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        if (@(Get-ChildItem -LiteralPath $captureDirectory -File -ErrorAction SilentlyContinue).Count -ge 4) {
            $stoppedAfterCapture = $true
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $process.WaitForExit(5000) | Out-Null
            break
        }
        $process.WaitForExit(250) | Out-Null
    }
    if (-not $process.HasExited) {
        $timedOut = $true
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
    if ($process.HasExited) { $process.WaitForExit() }
    [IO.File]::WriteAllText($stdout, $stdoutTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderr, $stderrTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
} finally {
    foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
        if ($prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    foreach ($entry in $previous.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

$profileLog = Join-Path $sessionConfig "openmw.log"
if (Test-Path -LiteralPath $profileLog) { Copy-Item $profileLog (Join-Path $output "openmw.log") -Force }
$screenshots = @(Get-ChildItem (Join-Path $sessionUserData "screenshots") -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc,Name)
$labels = @("map", "items", "data", "stats")
$captures = @()
for ($i = 0; $i -lt [Math]::Min($screenshots.Count, $labels.Count); ++$i) {
    $destination = Join-Path $output ("pipboy-{0}{1}" -f $labels[$i], $screenshots[$i].Extension.ToLowerInvariant())
    Copy-Item -LiteralPath $screenshots[$i].FullName -Destination $destination -Force
    $captures += $destination
}

$logText = ""
foreach ($path in @($stdout, $stderr, (Join-Path $output "openmw.log"))) {
    if (Test-Path -LiteralPath $path) { $logText += "`n" + (Get-Content -LiteralPath $path -Raw) }
}
$paneLogChecks = [ordered]@{}
for ($i = 0; $i -lt 4; ++$i) {
    $paneLogChecks[$labels[$i]] = $logText -match ("raising native inventory pane index={0}" -f $i) -and
        $logText -match ("Pip-Boy active pane index={0}" -f $i)
}
$measurements = @($captures | ForEach-Object { Measure-Screenshot $_ })
$differences = @()
for ($i = 1; $i -lt $captures.Count; ++$i) {
    $differences += [pscustomobject][ordered]@{
        left = $labels[$i - 1]
        right = $labels[$i]
        changedFraction = Measure-ScreenshotDifference $captures[$i - 1] $captures[$i]
    }
}
$exitCode = if ($null -ne $process -and $process.HasExited) { $process.ExitCode } else { $null }
$pass = -not $timedOut -and ($exitCode -eq 0 -or $stoppedAfterCapture) -and $captures.Count -eq 4 -and
    @($measurements | Where-Object { -not $_.pass }).Count -eq 0 -and
    @($differences | Where-Object { $_.changedFraction -lt 0.005 }).Count -eq 0 -and
    @($paneLogChecks.GetEnumerator() | Where-Object { -not $_.Value }).Count -eq 0
$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    pass = $pass
    executable = $exe -replace "\\", "/"
    executableSha256 = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    output = $output -replace "\\", "/"
    timedOut = $timedOut
    stoppedAfterCapture = $stoppedAfterCapture
    exitCode = $exitCode
    paneLogChecks = $paneLogChecks
    captures = @($captures | ForEach-Object { $_ -replace "\\", "/" })
    measurements = $measurements
    differences = $differences
}
$resultPath = Join-Path $output "result.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
$result | ConvertTo-Json -Depth 8
if (-not $pass) { throw "FNV Pip-Boy audit failed; see $resultPath" }
