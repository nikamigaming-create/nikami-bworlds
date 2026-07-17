[CmdletBinding()]
param(
    [ValidateSet("all", "morrowind", "fallout3", "fallout_new_vegas", "oblivion", "starfield", "skyrim", "fallout4")]
    [string[]]$WorldId = @("all"),
    [string]$OutputRoot = "",
    [string]$BinaryRoot = "",
    [hashtable]$EnvironmentOverride = @{},
    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 150,
    [switch]$NoScreenshots,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Get-OptionalProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Fallback = $null
    )

    if ($null -eq $Object) {
        return $Fallback
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Fallback
    }
    return $property.Value
}

function ConvertTo-InvariantString([object]$Value) {
    if ($Value -is [IFormattable]) {
        return $Value.ToString($null, [Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

function Quote-CommandArg([string]$Value) {
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Stop-LaunchedProcessTree {
    param([Parameter(Mandatory=$true)][int]$RootProcessId)

    # The crash monitor is a child openmw.exe. Capture only descendants of the PID
    # started by this runner so a failed hidden proof cannot leave audio behind.
    $processes = @(Get-CimInstance Win32_Process)
    $pending = @($RootProcessId)
    $tree = New-Object System.Collections.Generic.List[int]
    while ($pending.Count -gt 0) {
        $current = [int]$pending[0]
        $pending = @($pending | Select-Object -Skip 1)
        $tree.Add($current) | Out-Null
        $pending += @($processes | Where-Object { $_.ParentProcessId -eq $current } |
            ForEach-Object { [int]$_.ProcessId })
    }

    $ids = @($tree.ToArray())
    [array]::Reverse($ids)
    foreach ($id in $ids) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
}

function Add-EnvironmentValue {
    param(
        [System.Collections.IDictionary]$Environment,
        [string]$Name,
        [object]$Value
    )

    if ($null -eq $Value) {
        return
    }
    $text = ConvertTo-InvariantString $Value
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        $Environment[$Name] = $text
    }
}

function Add-StartEnvironment {
    param(
        [System.Collections.IDictionary]$Environment,
        [object]$StartSpec
    )

    $anchor = Get-OptionalProperty $StartSpec "anchor"
    if ($null -eq $anchor) {
        return
    }

    $position = Get-OptionalProperty $anchor "position"
    if ($null -ne $position) {
        Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_POS_X" (Get-OptionalProperty $position "x")
        Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_POS_Y" (Get-OptionalProperty $position "y")
        Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_POS_Z" (Get-OptionalProperty $position "z")
    }

    $rotation = Get-OptionalProperty $anchor "rotation"
    if ($null -ne $rotation) {
        Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_ROT_X" (Get-OptionalProperty $rotation "x")
        Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_ROT_Y" (Get-OptionalProperty $rotation "y")
        Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_ROT_Z" (Get-OptionalProperty $rotation "z")
    }

    $exterior = Get-OptionalProperty $anchor "exteriorLocation"
    if ($null -ne $exterior) {
        Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_WORLDSPACE" (Get-OptionalProperty $exterior "worldspace")
        $grid = Get-OptionalProperty $exterior "grid"
        if ($null -ne $grid) {
            Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_GRID_X" (Get-OptionalProperty $grid "x")
            Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_START_GRID_Y" (Get-OptionalProperty $grid "y")
        }
    }

    if ([bool](Get-OptionalProperty $anchor "dry" $false)) {
        $Environment["OPENMW_WORLD_VIEWER_START_DRY"] = "1"
    }

    Add-EnvironmentValue $Environment "OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS" (Get-OptionalProperty $StartSpec "esm4GridRadius")
}

function Get-ProfileUserDataPath {
    param(
        [string]$ProfileDirectory
    )

    $configPath = Join-Path $ProfileDirectory "openmw.cfg"
    foreach ($line in Get-Content -LiteralPath $configPath) {
        if ($line -match '^\s*user-data\s*=\s*(.+?)\s*$') {
            return [System.IO.Path]::GetFullPath($Matches[1])
        }
    }
    return Join-Path $ProfileDirectory "userdata"
}

function Get-TelemetryNumber {
    param(
        [string]$Line,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    $escapedName = [Regex]::Escape($Name)
    if ($Line -match "(?:^|\s)$escapedName=([-+0-9.eE]+|nan|inf|-inf)(?:\s|$)") {
        $value = 0.0
        if ([double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            return $value
        }
    }
    return $null
}

function Save-Json {
    param(
        [object]$Value,
        [string]$Path
    )

    $Value | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Measure-NativeScreenshotScene {
    param([Parameter(Mandatory=$true)][string]$Path)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new($Path)
    try {
        # Ignore the bottom HUD band. A crosshair or map widget must never be
        # enough to promote a black world render to a visual pass.
        $sceneHeight = [Math]::Max(1, [int][Math]::Floor($bitmap.Height * 0.80))
        $step = [Math]::Max(1, [int][Math]::Floor([Math]::Min($bitmap.Width, $sceneHeight) / 96.0))
        [long]$sampleCount = 0
        [long]$nonBlackCount = 0
        [double]$lumaSum = 0
        [double]$lumaSquaredSum = 0
        for ($y = 0; $y -lt $sceneHeight; $y += $step) {
            for ($x = 0; $x -lt $bitmap.Width; $x += $step) {
                $pixel = $bitmap.GetPixel($x, $y)
                $luma = (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
                ++$sampleCount
                if ($luma -gt 12) { ++$nonBlackCount }
                $lumaSum += $luma
                $lumaSquaredSum += $luma * $luma
            }
        }
        $mean = if ($sampleCount -gt 0) { $lumaSum / $sampleCount } else { 0.0 }
        $variance = if ($sampleCount -gt 0) {
            [Math]::Max(0.0, ($lumaSquaredSum / $sampleCount) - ($mean * $mean))
        } else { 0.0 }
        $nonBlackFraction = if ($sampleCount -gt 0) { $nonBlackCount / [double]$sampleCount } else { 0.0 }
        $standardDeviation = [Math]::Sqrt($variance)
        [pscustomobject][ordered]@{
            path = $Path
            width = $bitmap.Width
            height = $bitmap.Height
            sampleCount = $sampleCount
            sceneNonBlackFraction = $nonBlackFraction
            sceneMeanLuma = $mean
            sceneLumaStandardDeviation = $standardDeviation
            pass = $nonBlackFraction -ge 0.03 -and $standardDeviation -ge 3.0
        }
    } finally {
        $bitmap.Dispose()
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$contractPath = Join-Path $repoRoot "catalog/playable-session-baselines.json"
$startsPath = Join-Path $repoRoot "catalog/flat-world-proof-starts.json"
$playableConfigTemplate = Join-Path $repoRoot "config/playable-baseline"
$doorPreloadConfig = Join-Path $repoRoot "config/door-preload"
$fnvPlayableGraphicsConfig = Join-Path $repoRoot "config/fnv-playable-graphics"
$starfieldMaterialMap = Join-Path $repoRoot "config/proofs/starfield-new-atlantis-material-map.tsv"
$starfieldTextureCacheScript = Join-Path $repoRoot "scripts/initialize_starfield_texture_cache.py"
if (-not (Test-Path -LiteralPath $contractPath)) {
    throw "Missing playable-session contract: $contractPath"
}
if (-not (Test-Path -LiteralPath $startsPath)) {
    throw "Missing world start catalog: $startsPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $playableConfigTemplate "settings.cfg"))) {
    throw "Missing bounded playable-session settings: $playableConfigTemplate"
}
if (-not (Test-Path -LiteralPath (Join-Path $doorPreloadConfig "settings.cfg"))) {
    throw "Missing authored door-preload settings: $doorPreloadConfig"
}
if (-not (Test-Path -LiteralPath (Join-Path $fnvPlayableGraphicsConfig "settings.cfg"))) {
    throw "Missing FNV normal-play graphics settings: $fnvPlayableGraphicsConfig"
}

$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
$starts = Get-Content -LiteralPath $startsPath -Raw | ConvertFrom-Json
$runtimeRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$resourcesRoot = Resolve-NikamiOpenMWResourcesRoot
$binary = Join-Path $runtimeRoot "openmw.exe"
$morrowindProfileConfig = Join-Path $repoRoot "profiles/morrowind/openmw.cfg"
$morrowindUiDataPath = $null
foreach ($line in Get-Content -LiteralPath $morrowindProfileConfig) {
    if ($line -match '^\s*data\s*=\s*(.+?)\s*$') {
        $morrowindUiDataPath = [System.IO.Path]::GetFullPath($Matches[1])
        break
    }
}
if ([string]::IsNullOrWhiteSpace($morrowindUiDataPath)) {
    throw "Unable to resolve the Morrowind data path used by the shared OpenMW UI fallback."
}

$requested = @($WorldId)
if ($requested -contains "all") {
    $requested = @($contract.order)
}
$requested = @($contract.order | Where-Object { $requested -contains $_ })
if ($requested.Count -eq 0) {
    throw "No worlds selected."
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputRoot = Join-Path $repoRoot "run/playable-session-baseline/$stamp"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot $OutputRoot
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)

$existingProcess = Get-CimInstance Win32_Process -Filter "Name = 'openmw.exe'" | Select-Object -First 1
if ($null -ne $existingProcess -and -not $DryRun) {
    throw "OpenMW is already running as PID $($existingProcess.ProcessId). The baseline runner will not touch or replace it."
}

Write-Host "Flat playable-session baseline"
Write-Host "Runtime: $binary"
Write-Host "Worlds:  $($requested -join ', ')"
Write-Host "Output:  $OutputRoot"
Write-Host "Desktop: background/hidden only; no foreground activation or OS input"

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$results = New-Object System.Collections.Generic.List[object]
$environmentPrefixes = @(
    "OPENMW_WORLD_VIEWER_",
    "OPENMW_PROOF_",
    "OPENMW_FNV_",
    "OPENMW_ESM4_",
    "OPENMW_PLAYABLE_"
)

foreach ($id in $requested) {
    $world = Get-OptionalProperty $contract.worlds $id
    if ($null -eq $world) {
        throw "Missing contract entry for '$id'."
    }
    $profileId = [string](Get-OptionalProperty $world "profileId")
    $startSourceId = [string](Get-OptionalProperty $world "startSourceId")
    $normalSession = [bool](Get-OptionalProperty $world "normalSession" $false)
    $startSpec = Get-OptionalProperty $starts.worlds $startSourceId
    if ($null -eq $startSpec) {
        throw "Missing start catalog entry '$startSourceId' for '$id'."
    }

    $profileDirectory = Join-Path $repoRoot "profiles/$profileId"
    $profileConfig = Join-Path $profileDirectory "openmw.cfg"
    if (-not (Test-Path -LiteralPath $profileConfig)) {
        throw "Missing profile config for '$id': $profileConfig"
    }
    $startCell = [string](Get-OptionalProperty $startSpec "startCell")
    if ([string]::IsNullOrWhiteSpace($startCell)) {
        throw "Missing startCell for '$id'."
    }

    $defaults = $contract.defaults
    $environment = [ordered]@{
        OPENMW_PLAYABLE_SESSION = "1"
        OPENMW_PLAYABLE_SESSION_ID = $id
        OPENMW_PLAYABLE_SESSION_BACKGROUND = "1"
        OPENMW_PLAYABLE_SESSION_EXIT_AFTER_COMPLETE = "1"
        OPENMW_PLAYABLE_SESSION_FORWARD = "1"
        OPENMW_PLAYABLE_SESSION_STRAFE = "0"
        OPENMW_PLAYABLE_SESSION_RUN = "0"
        OPENMW_PLAYABLE_SESSION_FORCE_LEVEL_ONE = if ([bool](Get-OptionalProperty $defaults "forceLevelOne" $true)) { "1" } else { "0" }
        OPENMW_PLAYABLE_SESSION_VALIDATE_CAMERAS = if ([bool](Get-OptionalProperty $defaults "validateCameras" $true)) { "1" } else { "0" }
        OPENMW_PLAYABLE_SESSION_REQUIRE_ACTOR = if ([bool](Get-OptionalProperty $defaults "requireActor" $true)) { "1" } else { "0" }
        OPENMW_PLAYABLE_SESSION_NEUTRALIZE_ACTOR = if ([bool](Get-OptionalProperty $world "neutralizeActor" (Get-OptionalProperty $defaults "neutralizeActor" $true))) { "1" } else { "0" }
        OPENMW_PLAYABLE_SESSION_CAPTURE_SCREENSHOTS = if (-not $NoScreenshots -and [bool](Get-OptionalProperty $defaults "captureScreenshots" $true)) { "1" } else { "0" }
        OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI = "1"
        # Keep normal sessions quiet. Explicit EnvironmentOverride values are
        # applied later and may opt a diagnostic run back into these streams.
        OPENMW_WORLD_VIEWER_TELEMETRY = "0"
        OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = "0"
    }

    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_DURATION_SECONDS" (Get-OptionalProperty $world "durationSeconds" (Get-OptionalProperty $defaults "durationSeconds" 4))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_SETTLE_FRAMES" (Get-OptionalProperty $world "settleFrames" (Get-OptionalProperty $defaults "settleFrames" 240))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_CAMERA_DISTANCE" (Get-OptionalProperty $world "cameraDistance" (Get-OptionalProperty $defaults "cameraDistance" 192))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_MIN_DISTANCE" (Get-OptionalProperty $world "minimumDistance" (Get-OptionalProperty $defaults "minimumDistance" 64))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_MIN_CAMERA_SEGMENT_DISTANCE" (Get-OptionalProperty $world "minimumCameraSegmentDistance" (Get-OptionalProperty $defaults "minimumCameraSegmentDistance" 24))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_MIN_SPEED" (Get-OptionalProperty $world "minimumSpeed" (Get-OptionalProperty $defaults "minimumSpeed" 20))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_MAX_SPEED" (Get-OptionalProperty $world "maximumSpeed" (Get-OptionalProperty $defaults "maximumSpeed" 600))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_MAX_VERTICAL_DRIFT" (Get-OptionalProperty $world "maximumVerticalDrift" (Get-OptionalProperty $defaults "maximumVerticalDrift" 512))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_MAX_FIRST_PERSON_CAMERA_DISTANCE" (Get-OptionalProperty $world "maximumFirstPersonCameraDistance" (Get-OptionalProperty $defaults "maximumFirstPersonCameraDistance" 512))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_MAX_ACTOR_DRIFT" (Get-OptionalProperty $world "maximumActorDrift" (Get-OptionalProperty $defaults "maximumActorDrift" 256))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_MAX_ACTOR_DISTANCE" (Get-OptionalProperty $world "maximumActorDistance" (Get-OptionalProperty $defaults "maximumActorDistance" 3072))
    Add-EnvironmentValue $environment "OPENMW_PLAYABLE_SESSION_ACTOR" (Get-OptionalProperty $world "actor")

    $startEnvironment = Get-OptionalProperty $startSpec "environment"
    if ($null -ne $startEnvironment) {
        foreach ($property in $startEnvironment.PSObject.Properties) {
            Add-EnvironmentValue $environment ([string]$property.Name) $property.Value
        }
    }
    Add-StartEnvironment $environment $startSpec
    Add-StartEnvironment $environment $world

    $worldEnvironment = Get-OptionalProperty $world "environment"
    if ($null -ne $worldEnvironment) {
        foreach ($property in $worldEnvironment.PSObject.Properties) {
            Add-EnvironmentValue $environment ([string]$property.Name) $property.Value
        }
    }
    if ($normalSession) {
        # The normal-session contract may use an explicit authored-world start
        # anchor for repeatability, but it must not alter actors, player
        # identity/outfit, water, weather, image space, or loading presentation.
        foreach ($name in @(
            "OPENMW_ESM4_PLAYER_NPC",
            "OPENMW_FNV_PLAYER_NPC",
            "OPENMW_ESM4_PLAYER_OUTFIT",
            "OPENMW_FNV_PLAYER_OUTFIT",
            "OPENMW_ESM4_PLAYER_HEADGEAR",
            "OPENMW_FNV_PLAYER_HEADGEAR",
            "OPENMW_FNV_PROOF_WEATHER_ID",
            "OPENMW_FNV_PROOF_IMAGE_SPACE_ID",
            "OPENMW_FNV_PROCEDURE_HOUR",
            "OPENMW_FNV_BOOTSTRAP_HOUR",
            "OPENMW_FNV_BOOTSTRAP_LEVEL1_COURIER",
            "OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI"
        )) {
            $environment.Remove($name)
        }
        $environment["OPENMW_WORLD_VIEWER_START_DRY"] = "0"
        $environment["OPENMW_WORLD_VIEWER_TELEMETRY"] = "0"
        $environment["OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY"] = "0"
        $environment["OPENMW_PLAYABLE_SESSION_NEUTRALIZE_ACTOR"] = "0"
    }
    if ($id -eq "starfield") {
        if (-not (Test-Path -LiteralPath $starfieldMaterialMap)) {
            throw "Missing Starfield authored material bridge: $starfieldMaterialMap"
        }
        if (-not (Test-Path -LiteralPath $starfieldTextureCacheScript)) {
            throw "Missing Starfield texture-cache initializer: $starfieldTextureCacheScript"
        }
        Add-EnvironmentValue $environment "OPENMW_WORLD_VIEWER_STARFIELD_MATERIAL_MAP" `
            ([System.IO.Path]::GetFullPath($starfieldMaterialMap))
    }
    # Explicit command-line overrides are the final authority, including for
    # world-specific values installed immediately above.
    foreach ($entry in $EnvironmentOverride.GetEnumerator()) {
        Add-EnvironmentValue $environment ([string]$entry.Key) $entry.Value
    }
    if ($normalSession) {
        $forbiddenNormalSessionNames = @(
            "OPENMW_ESM4_PLAYER_NPC",
            "OPENMW_FNV_PLAYER_NPC",
            "OPENMW_ESM4_PLAYER_OUTFIT",
            "OPENMW_FNV_PLAYER_OUTFIT",
            "OPENMW_ESM4_PLAYER_HEADGEAR",
            "OPENMW_FNV_PLAYER_HEADGEAR",
            "OPENMW_FNV_PROOF_WEATHER_ID",
            "OPENMW_FNV_PROOF_IMAGE_SPACE_ID",
            "OPENMW_FNV_PROCEDURE_HOUR",
            "OPENMW_FNV_BOOTSTRAP_HOUR",
            "OPENMW_FNV_BOOTSTRAP_LEVEL1_COURIER",
            "OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI"
        )
        $forbiddenNormalSessionValues = @($forbiddenNormalSessionNames | Where-Object {
            $environment.Contains($_)
        })
        if ($forbiddenNormalSessionValues.Count -gt 0) {
            throw "Normal session '$id' contains forbidden proof/player override(s): $($forbiddenNormalSessionValues -join ', ')"
        }
        if ([string]$environment["OPENMW_WORLD_VIEWER_START_DRY"] -ne "0" -or
            [string]$environment["OPENMW_PLAYABLE_SESSION_NEUTRALIZE_ACTOR"] -ne "0") {
            throw "Normal session '$id' must use normal water and unmodified actor behavior."
        }
    }
    $effectiveStarfieldMaterialMap = $starfieldMaterialMap
    if ($id -eq "starfield") {
        $effectiveStarfieldMaterialMap = [string]$environment["OPENMW_WORLD_VIEWER_STARFIELD_MATERIAL_MAP"]
        if (-not (Test-Path -LiteralPath $effectiveStarfieldMaterialMap)) {
            throw "Missing effective Starfield authored material bridge: $effectiveStarfieldMaterialMap"
        }
    }

    $worldOutput = Join-Path $OutputRoot $id
    $sessionConfigDirectory = Join-Path $worldOutput "session-config"
    $sessionUserData = Join-Path $worldOutput "user-data"
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $worldOutput -Force | Out-Null
        New-Item -ItemType Directory -Path $sessionConfigDirectory,$sessionUserData -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sessionConfigDirectory "openmw.cfg") `
            -Value ('user-data="{0}"' -f ($sessionUserData -replace '\\', '/')) -Encoding utf8
    }

    $argsList = @(
        "--replace", "config",
        "--config", $profileDirectory,
        "--config", $playableConfigTemplate
    )
    if ($id -eq "fallout_new_vegas") {
        $argsList += @("--config", $fnvPlayableGraphicsConfig)
    }
    if ($normalSession) {
        $argsList += @("--config", $doorPreloadConfig)
    }
    $argsList += @("--config", $sessionConfigDirectory)
    $argsList += @("--user-data", $sessionUserData)
    $argsList += @(
        "--resources", $resourcesRoot,
        "--skip-menu",
        "--start", $startCell
    )
    if ($id -ne "morrowind") {
        $argsList += @(
            "--data", $morrowindUiDataPath,
            "--fallback-archive", "Morrowind.bsa"
        )
    }
    $argumentLine = ($argsList | ForEach-Object { Quote-CommandArg ([string]$_) }) -join " "

    Write-Host ""
    Write-Host "[$id] $([string](Get-OptionalProperty $world 'label'))"
    Write-Host "  data:  $([string](Get-OptionalProperty $world 'dataSource'))"
    Write-Host "  start: $startCell"
    Write-Host "  actor: $([string](Get-OptionalProperty $world 'actorLabel' 'nearest loaded actor'))"
    if ($DryRun) {
        Write-Host "  command: $(Quote-CommandArg $binary) $argumentLine"
        Write-Host "  window: hidden, no activation or input"
        continue
    }

    if ($id -eq "starfield") {
        $python = Get-Command python -ErrorAction Stop | Select-Object -First 1
        $cacheLedger = Join-Path $worldOutput "starfield-texture-cache-ledger.json"
        Write-Host "  cache: authored Starfield material/actor PNG bridge (local BA2s only)"
        & $python.Source $starfieldTextureCacheScript `
            --openmw-cfg $profileConfig `
            --material-map $effectiveStarfieldMaterialMap `
            --data-local (Join-Path $profileDirectory "userdata/data") `
            --binary-root $runtimeRoot `
            --ledger $cacheLedger
        if ($LASTEXITCODE -ne 0) {
            throw "Starfield texture-cache initialization failed with exit code $LASTEXITCODE; see $cacheLedger"
        }
    }

    $stdoutPath = Join-Path $worldOutput "stdout.log"
    $stderrPath = Join-Path $worldOutput "stderr.log"
    $screenshotDirectory = Join-Path $sessionUserData "screenshots"
    $beforeScreenshots = @{}
    if (Test-Path -LiteralPath $screenshotDirectory) {
        foreach ($file in Get-ChildItem -LiteralPath $screenshotDirectory -File) {
            $beforeScreenshots[$file.FullName] = $true
        }
    }

    $previousEnvironment = @{}
    $existingEnvironmentNames = @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })
    foreach ($name in $existingEnvironmentNames) {
        $matchesPrefix = $false
        foreach ($prefix in $environmentPrefixes) {
            if ($name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $matchesPrefix = $true
                break
            }
        }
        if ($matchesPrefix) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }

    $timedOut = $false
    $fatalDetectedDuringRun = $false
    $exitCode = $null
    $startUtc = [DateTime]::UtcNow
    try {
        foreach ($entry in $environment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
        }

        $process = Start-Process -FilePath $binary -ArgumentList $argumentLine `
            -WorkingDirectory $runtimeRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        Write-Host "  pid:   $($process.Id) (background/hidden)"
        $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $lastObservedLogWriteUtc = [DateTime]::MinValue
        while (-not $process.WaitForExit(500)) {
            if (Test-Path -LiteralPath $stdoutPath) {
                $logWriteUtc = (Get-Item -LiteralPath $stdoutPath).LastWriteTimeUtc
                if ($logWriteUtc -gt $lastObservedLogWriteUtc) {
                    $lastObservedLogWriteUtc = $logWriteUtc
                    $fatalTail = @(Get-Content -LiteralPath $stdoutPath -Tail 80 | Where-Object {
                        $_ -match '(?:prepareEngine failed:|Failed to start new game:|Fatal error:|Unhandled exception:)'
                    } | Select-Object -Last 1)
                    if ($fatalTail.Count -gt 0) {
                        $fatalDetectedDuringRun = $true
                        Stop-LaunchedProcessTree -RootProcessId $process.Id
                        $process.WaitForExit(5000) | Out-Null
                        break
                    }
                }
            }
            if ([DateTime]::UtcNow -ge $deadlineUtc) {
                $timedOut = $true
                Stop-LaunchedProcessTree -RootProcessId $process.Id
                $process.WaitForExit(5000) | Out-Null
                break
            }
        }
        if ($process.HasExited) {
            $exitCode = $process.ExitCode
        }
    } finally {
        foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object { [string]$_ })) {
            foreach ($prefix in $environmentPrefixes) {
                if ($name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    [Environment]::SetEnvironmentVariable($name, $null, "Process")
                    break
                }
            }
        }
        foreach ($entry in $previousEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
        }
    }

    Start-Sleep -Milliseconds 500
    $newScreenshots = @()
    if (Test-Path -LiteralPath $screenshotDirectory) {
        $newScreenshots = @(Get-ChildItem -LiteralPath $screenshotDirectory -File |
            Where-Object { -not $beforeScreenshots.ContainsKey($_.FullName) -and $_.LastWriteTimeUtc -ge $startUtc.AddSeconds(-2) } |
            Sort-Object LastWriteTimeUtc, Name)
    }
    $copiedScreenshots = New-Object System.Collections.Generic.List[string]
    $screenshotIndex = 0
    foreach ($file in $newScreenshots) {
        ++$screenshotIndex
        $extension = $file.Extension.ToLowerInvariant()
        $destination = Join-Path $worldOutput ("{0}-{1:d2}{2}" -f $id, $screenshotIndex, $extension)
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $copiedScreenshots.Add($destination) | Out-Null
    }

    $logLines = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $path) {
            foreach ($line in Get-Content -LiteralPath $path) {
                $logLines.Add([string]$line) | Out-Null
            }
        }
    }
    $escapedId = [Regex]::Escape($id)
    $startTelemetryPattern = 'Playable session telemetry: phase=start id="{0}"' -f $escapedId
    $endTelemetryPattern = 'Playable session telemetry: phase=end id="{0}"' -f $escapedId
    $startTelemetry = @($logLines | Where-Object { $_ -match $startTelemetryPattern } | Select-Object -Last 1)
    $cameraTelemetry = @($logLines | Where-Object { $_ -match "Playable session telemetry: phase=camera-switch" } | Select-Object -Last 1)
    $endTelemetry = @($logLines | Where-Object { $_ -match $endTelemetryPattern } | Select-Object -Last 1)
    $endTelemetryText = if ($endTelemetry.Count -gt 0) { [string]$endTelemetry[0] } else { "" }
    $fatalLog = @($logLines | Where-Object { $_ -match '(?:prepareEngine failed:|Failed to start new game:|Fatal error:|Unhandled exception:)' } | Select-Object -Last 1)
    $fatalLogText = if ($fatalLog.Count -gt 0) { [string]$fatalLog[0] } else { $null }
    $engineResult = if ($endTelemetryText -match '(?:^|\s)result=(pass|fail)(?:\s|$)') { $Matches[1] } else { "missing" }
    $expectedScreenshotCount = if ($NoScreenshots) { 0 } else { [int](Get-OptionalProperty $world "expectedScreenshotCount" (Get-OptionalProperty $defaults "expectedScreenshotCount" 3)) }
    $capturePass = $NoScreenshots -or $copiedScreenshots.Count -ge $expectedScreenshotCount
    $screenshotSceneMeasurements = @()
    if (-not $NoScreenshots) {
        $screenshotSceneMeasurements = @($copiedScreenshots | ForEach-Object {
            Measure-NativeScreenshotScene -Path $_
        })
    }
    $pixelProofPass = $NoScreenshots -or (
        $capturePass -and @($screenshotSceneMeasurements | Where-Object { -not $_.pass }).Count -eq 0
    )

    # A resolved/stationary actor is not proof that its render parts are assembled. Make the native actor and
    # locomotion diagnostics part of the contract so detached heads or an idle-sliding player cannot pass.
    # Every imported Bethesda world must prove its player proxy, even when the engine
    # auto-selects the world's native Player record instead of an explicit override.
    # Fallout 4 previously bypassed this gate and promoted a visible bind pose.
    $requiresPlayerVisual = $id -ne "morrowind"
    $locomotionSelected = @($logLines | Where-Object {
        $_ -match 'ESM4 player visual locomotion: phase=selected.*selected="(?:walkforward|walkback|walkleft|walkright)".*available=1'
    } | Select-Object -Last 1)
    $locomotionAdvanced = @($logLines | Where-Object {
        $_ -match 'ESM4 player visual locomotion: phase=advanced.*selected="(?:walkforward|walkback|walkleft|walkright)"'
    } | Select-Object -Last 1)
    $locomotionAnimationTime = if ($locomotionAdvanced.Count -gt 0) {
        Get-TelemetryNumber ([string]$locomotionAdvanced[0]) "animationTime"
    } else { $null }
    $locomotionPass = -not $requiresPlayerVisual -or (
        $locomotionSelected.Count -gt 0 -and $locomotionAdvanced.Count -gt 0 -and
        $null -ne $locomotionAnimationTime -and $locomotionAnimationTime -gt 0.05
    )
    $badPoseLines = @($logLines | Where-Object {
        $_ -match "RigGeometry .* pose sanity .* verdict=BAD"
    })
    $nativePlayerRecordLines = @($logLines | Where-Object {
        $_ -match 'using native player visual proxy Player \(FormId:'
    } | Select-Object -Last 1)
    $playerOverrideLines = @($logLines | Where-Object {
        $_ -match 'using native player visual proxy (?!Player \()[^ ]+' -or
        $_ -match 'player proxy (?:outfit|headgear)' -or
        $_ -match 'inventory proxy (?:outfit|headgear)' -or
        $_ -match 'level-1 Courier visual outfit'
    })
    $actorNeutralizationLines = @($logLines | Where-Object {
        $_ -match 'Playable session: (?:enabled safe-start hostility guard|suppressed false safe-start combat package)'
    })
    $normalWaterLines = @($logLines | Where-Object {
        $_ -match 'World viewer: pinned explicit start anchor .* dry=0(?:\s|$)'
    } | Select-Object -Last 1)
    $normalSessionRuntimePass = -not $normalSession -or (
        $nativePlayerRecordLines.Count -gt 0 -and
        $playerOverrideLines.Count -eq 0 -and
        $actorNeutralizationLines.Count -eq 0 -and
        $normalWaterLines.Count -gt 0
    )
    $playerHeadLines = @($logLines | Where-Object {
        $_ -match 'attachment bounds .*headhuman\.nif for "Player"'
    })
    $playerHeadOffset = if ($playerHeadLines.Count -gt 0) {
        Get-TelemetryNumber ([string]$playerHeadLines[-1]) "headPlanarDelta"
    } else { $null }
    $fo4FaceCompositionLines = @($logLines | Where-Object {
        $_ -match 'FO4 face composition telemetry: actor="Player".*face=1.*eyes=1.*mouthTeeth=1.*result=pass'
    } | Select-Object -Last 1)
    $fo4FaceCompositionPass = $id -ne "fallout4" -or $fo4FaceCompositionLines.Count -gt 0
    $skyrimFaceCompositionLines = @($logLines | Where-Object {
        $_ -match 'Skyrim face composition telemetry: actor="Player".*face=1.*eyes=1.*mouth=1.*hair=1.*result=pass'
    } | Select-Object -Last 1)
    $skyrimFaceCompositionPass = $id -ne "skyrim" -or $skyrimFaceCompositionLines.Count -gt 0
    $starfieldGeneratedPlayerFace = @($logLines | Where-Object {
        $_ -match 'Starfield generated face composition: actor="Player".*attached=1'
    }).Count -gt 0
    $starfieldGeneratedPlayerHead = @($logLines | Where-Object {
        $_ -match 'Starfield actor proof texture .*facegeom/starfield\.esm/.+\.nif.*shape="Human_(?:Male|Female)_Head"'
    }).Count -gt 0
    $starfieldGeneratedPlayerLeftEye = @($logLines | Where-Object {
        $_ -match 'Starfield mesh loaded .*facegeom/starfield\.esm/.+\.nif.*shape="Human_(?:Male|Female)_LeftEye"'
    }).Count -gt 0
    $starfieldGeneratedPlayerRightEye = @($logLines | Where-Object {
        $_ -match 'Starfield mesh loaded .*facegeom/starfield\.esm/.+\.nif.*shape="Human_(?:Male|Female)_RightEye"'
    }).Count -gt 0
    $starfieldGeneratedPlayerTeeth = @($logLines | Where-Object {
        $_ -match 'Starfield actor proof texture .*facegeom/starfield\.esm/.+\.nif.*shape="Human_(?:Male|Female)_Teeth"'
    }).Count -gt 0
    $starfieldGeneratedPlayerTongue = @($logLines | Where-Object {
        $_ -match 'Starfield mesh loaded .*facegeom/starfield\.esm/.+\.nif.*shape="Human_(?:Male|Female)_Tongue"'
    }).Count -gt 0
    $starfieldGeneratedPlayerHair = @($logLines | Where-Object {
        $_ -match 'Starfield actor proof texture .*facegeom/starfield\.esm/.+\.nif.*shape="Human_(?:Male|Female)_Hair_'
    }).Count -gt 0
    $starfieldPlayerHead = $starfieldGeneratedPlayerFace -and $starfieldGeneratedPlayerHead -or @($logLines | Where-Object {
        $_ -match 'attachment bounds .*characterassets/(?:male/malehead|female/femalehead)\.nif for "Player"'
    }).Count -gt 0
    $starfieldPlayerLeftEye = $starfieldGeneratedPlayerLeftEye -or @($logLines | Where-Object {
        $_ -match 'attachment bounds .*characterassets/(?:male|female)/lefteye\.nif for "Player"'
    }).Count -gt 0
    $starfieldPlayerRightEye = $starfieldGeneratedPlayerRightEye -or @($logLines | Where-Object {
        $_ -match 'attachment bounds .*characterassets/(?:male|female)/righteye\.nif for "Player"'
    }).Count -gt 0
    $starfieldPlayerMouth = ($starfieldGeneratedPlayerTeeth -and $starfieldGeneratedPlayerTongue) -or (@($logLines | Where-Object {
        $_ -match 'attachment bounds .*characterassets/(?:male|female)/teeth\.nif for "Player"'
    }).Count -gt 0 -and @($logLines | Where-Object {
        $_ -match 'attachment bounds .*characterassets/(?:male|female)/tongue\.nif for "Player"'
    }).Count -gt 0)
    $starfieldPlayerHair = $starfieldGeneratedPlayerHair -or @($logLines | Where-Object {
        $_ -match 'attachment bounds .*actors/human/mesh/hairs/.+\.nif for "Player"'
    }).Count -gt 0
    $starfieldPlayerHands = @($logLines | Where-Object {
        $_ -match 'attachment bounds .*actors/human/mesh/nakedhands/hands_3rd_.+\.nif for "Player"'
    }).Count -gt 0
    $starfieldPlayerBody = @($logLines | Where-Object {
        $_ -match 'attachment bounds .*outfit_miner_utilitysuit.*(?:shirt|upperbody).+\.nif for "Player"'
    }).Count -gt 0 -and @($logLines | Where-Object {
        $_ -match 'attachment bounds .*outfit_miner_utilitysuit.*(?:pants|lowerbody).+\.nif for "Player"'
    }).Count -gt 0
    $starfieldActorVisualBase = [string](Get-OptionalProperty $world "actorVisualBase" "")
    $starfieldActorHands = if ([string]::IsNullOrWhiteSpace($starfieldActorVisualBase)) {
        $false
    } else {
        $actorVisualBasePattern = [regex]::Escape($starfieldActorVisualBase)
        @($logLines | Where-Object {
            $_ -match 'attachment bounds .*actors/human/mesh/nakedhands/hands_3rd_.+\.nif' -and
            $_ -match "for $actorVisualBasePattern"
        }).Count -gt 0
    }
    $starfieldMissingCoreBones = @($logLines | Where-Object {
        $_ -match 'RigGeometry did not find bone (?:faceBone_|[CLR]_)'
    })
    $starfieldCompositionPass = $id -ne "starfield" -or (
        $starfieldPlayerHead -and $starfieldPlayerLeftEye -and $starfieldPlayerRightEye -and
        $starfieldPlayerMouth -and $starfieldPlayerHair -and $starfieldPlayerHands -and
        $starfieldPlayerBody -and $starfieldActorHands -and $starfieldMissingCoreBones.Count -eq 0
    )
    $playerHeadPass = if ($id -eq "fallout4") {
        $fo4FaceCompositionPass
    } elseif ($id -eq "skyrim") {
        $skyrimFaceCompositionPass
    } elseif ($id -eq "starfield") {
        $starfieldCompositionPass
    } else {
        -not $requiresPlayerVisual -or (
            $playerHeadLines.Count -gt 0 -and $null -ne $playerHeadOffset -and $playerHeadOffset -le 42
        )
    }
    $visualTelemetryPass = $locomotionPass -and $playerHeadPass -and $badPoseLines.Count -eq 0 -and
        $normalSessionRuntimePass
    $visualTelemetryStatus = if ($visualTelemetryPass) { "pass" } else { "fail" }

    $status = "pass"
    $reason = "engine telemetry passed and native proof captures were written"
    $visualPromotionReady = [bool](Get-OptionalProperty $world "visualPromotionReady" $true)
    if ($null -ne $fatalLogText) {
        $status = "fail"
        $reason = "OpenMW reported a fatal startup error: $fatalLogText"
    } elseif ($timedOut) {
        $status = "fail"
        $reason = "background process timed out before a complete session"
    } elseif ($null -ne $exitCode -and $exitCode -ne 0) {
        $status = "fail"
        $reason = "OpenMW exited with code $exitCode"
    } elseif ($engineResult -eq "missing") {
        $status = "fail"
        $reason = "no end-of-session telemetry was emitted"
    } elseif ($engineResult -ne "pass") {
        $status = "fail"
        $reason = "one or more level, movement, camera, or actor-stability checks failed"
    } elseif (-not $visualTelemetryPass) {
        $status = "fail"
        $reason = "actor/session telemetry failed (locomotion=$locomotionPass head=$playerHeadPass badPoses=$($badPoseLines.Count) normalSession=$normalSessionRuntimePass)"
    } elseif (-not $capturePass) {
        $status = "fail"
        $reason = "telemetry passed but only $($copiedScreenshots.Count) of $expectedScreenshotCount native captures were written"
    } elseif (-not $pixelProofPass) {
        $status = "fail"
        $failedPixels = @($screenshotSceneMeasurements | Where-Object { -not $_.pass }).Count
        $reason = "telemetry passed but $failedPixels native captures contain no credible rendered world pixels"
    } elseif (-not $visualPromotionReady) {
        $status = "fail"
        $reason = "automated gates passed, but the world-specific visual promotion gate remains open pending clean native review captures"
    }

    $result = [pscustomobject][ordered]@{
        worldId = $id
        label = [string](Get-OptionalProperty $world "label")
        runtimeMode = "flat"
        profileId = $profileId
        dataSource = [string](Get-OptionalProperty $world "dataSource")
        uiFallback = if ($id -eq "morrowind") { "native Morrowind assets" } else { "Morrowind.bsa OpenMW UI assets" }
        startCell = $startCell
        normalSession = $normalSession
        nativePlayerRecord = if ($normalSession) { "Player" } else { $null }
        actorLabel = [string](Get-OptionalProperty $world "actorLabel" "nearest loaded actor")
        actorTarget = Get-OptionalProperty $world "actor"
        actorNeutralized = [string]$environment["OPENMW_PLAYABLE_SESSION_NEUTRALIZE_ACTOR"] -ne "0"
        dryStart = $environment.Contains("OPENMW_WORLD_VIEWER_START_DRY") -and
            [string]$environment["OPENMW_WORLD_VIEWER_START_DRY"] -ne "0"
        status = $status
        reason = $reason
        telemetryStatus = $engineResult
        visualTelemetryStatus = $visualTelemetryStatus
        nativePixelStatus = if ($pixelProofPass) { "pass" } else { "fail" }
        visualPromotionReady = $visualPromotionReady
        knownAcceptanceBlockers = @(Get-OptionalProperty $world "knownAcceptanceBlockers" @())
        normalSessionRuntimePass = $normalSessionRuntimePass
        normalSessionRuntimeEvidence = [pscustomobject][ordered]@{
            nativePlayerRecordLines = $nativePlayerRecordLines.Count
            playerOverrideLines = $playerOverrideLines.Count
            actorNeutralizationLines = $actorNeutralizationLines.Count
            normalWaterLines = $normalWaterLines.Count
        }
        effectiveEnvironment = [pscustomobject]$environment
        fatalError = $fatalLogText
        timedOut = $timedOut
        fatalDetectedDuringRun = $fatalDetectedDuringRun
        exitCode = $exitCode
        expectedScreenshotCount = $expectedScreenshotCount
        screenshotCount = $copiedScreenshots.Count
        screenshots = @($copiedScreenshots.ToArray())
        screenshotSceneMeasurements = @($screenshotSceneMeasurements)
        metrics = [pscustomobject][ordered]@{
            distance = Get-TelemetryNumber $endTelemetryText "distance"
            averageSpeed = Get-TelemetryNumber $endTelemetryText "averageSpeed"
            verticalDrift = Get-TelemetryNumber $endTelemetryText "verticalDrift"
            thirdPersonDistance = Get-TelemetryNumber $endTelemetryText "thirdPersonDistance"
            firstPersonDistance = Get-TelemetryNumber $endTelemetryText "firstPersonDistance"
            firstPersonCameraDistance = Get-TelemetryNumber $endTelemetryText "firstPersonCameraDistance"
            actorStartDistance = Get-TelemetryNumber $endTelemetryText "actorStartDistance"
            actorEndDistance = Get-TelemetryNumber $endTelemetryText "actorEndDistance"
            actorDrift = Get-TelemetryNumber $endTelemetryText "actorDrift"
            actorCombatSuppressions = Get-TelemetryNumber $endTelemetryText "actorCombatSuppressions"
            playerHeadPlanarOffset = $playerHeadOffset
            fo4FaceCompositionPass = $fo4FaceCompositionPass
            skyrimFaceCompositionPass = $skyrimFaceCompositionPass
            starfieldCompositionPass = $starfieldCompositionPass
            starfieldPlayerHead = $starfieldPlayerHead
            starfieldPlayerEyes = $starfieldPlayerLeftEye -and $starfieldPlayerRightEye
            starfieldPlayerMouth = $starfieldPlayerMouth
            starfieldPlayerHair = $starfieldPlayerHair
            starfieldPlayerHands = $starfieldPlayerHands
            starfieldPlayerBody = $starfieldPlayerBody
            starfieldActorHands = $starfieldActorHands
            starfieldMissingCoreBones = $starfieldMissingCoreBones.Count
            locomotionAnimationTime = $locomotionAnimationTime
        }
        telemetry = [pscustomobject][ordered]@{
            start = if ($startTelemetry.Count -gt 0) { [string]$startTelemetry[0] } else { $null }
            cameraSwitch = if ($cameraTelemetry.Count -gt 0) { [string]$cameraTelemetry[0] } else { $null }
            end = if ($endTelemetry.Count -gt 0) { [string]$endTelemetry[0] } else { $null }
        }
        artifacts = [pscustomobject][ordered]@{
            directory = $worldOutput
            stdout = $stdoutPath
            stderr = $stderrPath
        }
        notes = [string](Get-OptionalProperty $world "notes")
    }
    Save-Json $result (Join-Path $worldOutput "result.json")
    $results.Add($result) | Out-Null
    Write-Host "  result: $status - $reason"
    if (-not [string]::IsNullOrWhiteSpace($endTelemetryText)) {
        Write-Host "  telemetry: $endTelemetryText"
    }
    Write-Host "  captures: $($copiedScreenshots.Count)/$expectedScreenshotCount"
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run complete. No process was launched and no artifacts were written."
    exit 0
}

$overallStatus = if (@($results | Where-Object { $_.status -ne "pass" }).Count -eq 0) { "pass" } else { "fail" }
$ledger = [pscustomobject][ordered]@{
    schemaVersion = 2
    generatedAt = (Get-Date).ToString("o")
    runtimeMode = "flat"
    foregroundInputUsed = $false
    controlWorld = [string]$contract.controlWorld
    overallStatus = $overallStatus
    binary = $binary
    binarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    results = @($results.ToArray())
}
Save-Json $ledger (Join-Path $OutputRoot "ledger.json")

$markdown = New-Object System.Collections.Generic.List[string]
$markdown.Add("# Flat playable-session baseline") | Out-Null
$markdown.Add("") | Out-Null
$markdown.Add("Generated: $($ledger.generatedAt)") | Out-Null
$markdown.Add("") | Out-Null
$markdown.Add("Runtime: flat OpenMW only. No retail game, VR runtime, foreground activation, mouse, or keyboard automation was used.") | Out-Null
$markdown.Add("") | Out-Null
$markdown.Add("| World | Data source | Telemetry | Captures | Overall | Reason |") | Out-Null
$markdown.Add("|---|---|---:|---:|---:|---|") | Out-Null
foreach ($result in $results) {
    $dataSource = $result.dataSource -replace '\|', '\|'
    $reason = $result.reason -replace '\|', '\|'
    $markdown.Add("| $($result.label) | $dataSource | $($result.telemetryStatus) | $($result.screenshotCount)/$($result.expectedScreenshotCount) | $($result.status) | $reason |") | Out-Null
}
$markdown.Add("") | Out-Null
$markdown.Add('Machine-readable metrics, raw telemetry, logs, and capture paths are in `ledger.json` and each world''s `result.json`.') | Out-Null
$markdown | Set-Content -LiteralPath (Join-Path $OutputRoot "ledger.md") -Encoding utf8

Write-Host ""
Write-Host "Ledger:  $(Join-Path $OutputRoot 'ledger.md')"
Write-Host "Overall: $overallStatus"
if ($overallStatus -ne "pass") {
    exit 1
}
