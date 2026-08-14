[CmdletBinding()]
param(
    [ValidateSet("FirstSmoke", "ChetObservation", "ChetPersistent", "ChetTransaction", "ChetPersistenceSave", "ChetPersistenceReload")]
    [string]$Route = "FirstSmoke",
    [string]$WorldsRoot = "",
    [string]$BinaryRoot = "",
    [string]$SavePath = "",
    [string]$OutputRoot = "",
    [ValidateRange(10, 120)]
    [int]$CaptureSeconds = 45,
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 120,
    [string]$ReloadTransferItem = "",
    [int]$ReloadTransferPlayerCount = -1,
    [int]$ReloadTransferContainerCount = -1,
    [string]$ReloadPurchaseItem = "",
    [int]$ReloadPurchasePlayerCount = -1,
    [int]$ReloadPurchaseMerchantCount = -1,
    [int]$ReloadPlayerCaps = -1,
    [int]$ReloadMerchantCaps = -1
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($WorldsRoot)) {
    $WorldsRoot = Split-Path -Parent $PSScriptRoot
}
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ProfileValue([string]$ConfigPath, [string]$Key) {
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -match ('^\s*' + [Regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) {
            return $Matches[1].Trim('"')
        }
    }
    return $null
}

if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    throw "FirstSmoke requires an explicit minimally manifested OpenMW runtime root."
}
if ([string]::IsNullOrWhiteSpace($SavePath)) {
    throw "FirstSmoke requires an explicit existing OpenMW-native Goodsprings save."
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    throw "FirstSmoke requires a unique output root."
}

$BinaryRoot = [IO.Path]::GetFullPath($BinaryRoot)
$SavePath = [IO.Path]::GetFullPath($SavePath)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing FirstSmoke output root: $OutputRoot"
}

$exe = Join-Path $BinaryRoot "openmw.exe"
$resources = Join-Path $BinaryRoot "resources"
$runtimeManifest = Join-Path $BinaryRoot "runtime-manifest.json"
if (-not (Test-Path -LiteralPath $runtimeManifest -PathType Leaf)) {
    $runtimeManifest = Join-Path $BinaryRoot "candidate-runtime-manifest.json"
}
$profile = Join-Path $WorldsRoot "profiles\fallout_new_vegas"
$profileConfig = Join-Path $profile "openmw.cfg"
$morrowindConfig = Join-Path $WorldsRoot "profiles\morrowind\openmw.cfg"
$baselineConfig = Join-Path $WorldsRoot "config\playable-baseline"
$graphicsConfig = Join-Path $WorldsRoot "config\fnv-playable-graphics"
$doorConfig = Join-Path $WorldsRoot "config\door-preload"
foreach ($file in @($exe, $runtimeManifest, $SavePath, $profileConfig, $morrowindConfig,
        (Join-Path $baselineConfig "settings.cfg"), (Join-Path $graphicsConfig "settings.cfg"),
        (Join-Path $doorConfig "settings.cfg"))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing FirstSmoke input: $file"
    }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "Missing FirstSmoke resources: $resources"
}
if (Get-Process -Name openmw,openmw_vr,FalloutNV -ErrorAction SilentlyContinue) {
    throw "A capture engine is already running. FirstSmoke will not interfere with it."
}

$morrowindData = Get-ProfileValue $morrowindConfig "data"
if ([string]::IsNullOrWhiteSpace($morrowindData)) {
    throw "Unable to resolve the shared OpenMW UI data directory from $morrowindConfig"
}
$morrowindData = [IO.Path]::GetFullPath($morrowindData)

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$sessionConfig = Join-Path $OutputRoot "session-config"
$userData = Join-Path $OutputRoot "user-data"
New-Item -ItemType Directory -Path $sessionConfig,$userData | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $sessionConfig "openmw.cfg"),
    ('user-data="{0}"' -f ($userData -replace '\\', '/')),
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText(
    (Join-Path $sessionConfig "settings.cfg"),
    "[Lua]`r`nlua num threads = 0`r`n",
    [Text.UTF8Encoding]::new($false))

$arguments = @(
    "--replace", "config",
    "--config", $profile,
    "--config", $baselineConfig,
    "--config", $graphicsConfig,
    "--config", $doorConfig,
    "--config", $sessionConfig,
    "--user-data", $userData,
    "--resources", $resources,
    "--data", $morrowindData,
    "--fallback-archive", "Morrowind.bsa",
    "--load-savegame", $SavePath
)
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "
$stdout = Join-Path $OutputRoot "stdout.log"
$stderr = Join-Path $OutputRoot "stderr.log"
$openmwLog = Join-Path $sessionConfig "openmw.log"
$routeSlug = switch ($Route) {
    "ChetObservation" { "r2-chet-observation" }
    "ChetPersistent" { "r2-goodsprings-persistent" }
    "ChetTransaction" { "r2-goodsprings-transaction" }
    "ChetPersistenceSave" { "r2-goodsprings-persistence-save" }
    "ChetPersistenceReload" { "r2-goodsprings-persistence-reload" }
    default { "first-smoke" }
}
$resultReportName = switch ($Route) {
    "ChetObservation" { "r2-chet-observation-report.json" }
    "ChetPersistent" { "r2-goodsprings-persistent-report.json" }
    "ChetTransaction" { "r2-goodsprings-transaction-report.json" }
    "ChetPersistenceSave" { "r2-goodsprings-persistence-save-report.json" }
    "ChetPersistenceReload" { "r2-goodsprings-persistence-reload-report.json" }
    default { "first-smoke-report.json" }
}
$video = Join-Path $OutputRoot ("OpenMW-FNV-{0}-exact-title.mp4" -f $routeSlug)
$ffmpegLog = Join-Path $OutputRoot "ffmpeg.log"
$startedAt = [DateTime]::UtcNow
$game = $null
$gameExitCode = $null
$ffmpeg = $null
$timedOut = $false
$titleObserved = $false
$driverEnvironmentName = switch ($Route) {
    "ChetObservation" { "OPENMW_FNV_R2_CHET_OBSERVATION" }
    "ChetPersistent" { "OPENMW_FNV_R2_GOODSPRINGS_PERSISTENT" }
    "ChetTransaction" { "OPENMW_FNV_R2_GOODSPRINGS_TRANSACTION" }
    "ChetPersistenceSave" { "OPENMW_FNV_R2_GOODSPRINGS_PERSISTENCE_SAVE" }
    "ChetPersistenceReload" { "OPENMW_FNV_R2_GOODSPRINGS_PERSISTENCE_RELOAD" }
    default { "OPENMW_FNV_FIRST_SMOKE" }
}
$previousDriver = [Environment]::GetEnvironmentVariable($driverEnvironmentName, "Process")
$previousDebug = $env:OPENMW_DEBUG_LEVEL
$previousCrashCatcher = $env:OPENMW_DISABLE_CRASH_CATCHER
$previousFatalDialog = $env:OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG
$reloadEnvironment = [ordered]@{
    OPENMW_FNV_R2_RELOAD_TRANSFER_ITEM = $ReloadTransferItem
    OPENMW_FNV_R2_RELOAD_TRANSFER_PLAYER_COUNT = [string]$ReloadTransferPlayerCount
    OPENMW_FNV_R2_RELOAD_TRANSFER_CONTAINER_COUNT = [string]$ReloadTransferContainerCount
    OPENMW_FNV_R2_RELOAD_PURCHASE_ITEM = $ReloadPurchaseItem
    OPENMW_FNV_R2_RELOAD_PURCHASE_PLAYER_COUNT = [string]$ReloadPurchasePlayerCount
    OPENMW_FNV_R2_RELOAD_PURCHASE_MERCHANT_COUNT = [string]$ReloadPurchaseMerchantCount
    OPENMW_FNV_R2_RELOAD_PLAYER_CAPS = [string]$ReloadPlayerCaps
    OPENMW_FNV_R2_RELOAD_MERCHANT_CAPS = [string]$ReloadMerchantCaps
}
$previousReloadEnvironment = @{}
try {
    [Environment]::SetEnvironmentVariable($driverEnvironmentName, "1", "Process")
    if ($Route -eq "ChetPersistenceReload") {
        foreach ($name in $reloadEnvironment.Keys) {
            $previousReloadEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, $reloadEnvironment[$name], "Process")
        }
    }
    $env:OPENMW_DEBUG_LEVEL = "INFO"
    $env:OPENMW_DISABLE_CRASH_CATCHER = "1"
    $env:OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = "1"
    $game = Start-Process -FilePath $exe -ArgumentList $argumentLine -WorkingDirectory $BinaryRoot `
        -WindowStyle Normal -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $titleDeadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $titleDeadline -and -not $game.HasExited) {
        $game.Refresh()
        if ($game.MainWindowTitle -eq "OpenMW") {
            $titleObserved = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if ($titleObserved) {
        $ffmpegInfo = [Diagnostics.ProcessStartInfo]::new()
        $ffmpegInfo.FileName = "ffmpeg"
        $ffmpegInfo.UseShellExecute = $false
        $ffmpegInfo.CreateNoWindow = $true
        $ffmpegInfo.RedirectStandardInput = $true
        $ffmpegInfo.RedirectStandardOutput = $true
        $ffmpegInfo.RedirectStandardError = $true
        $ffmpegInfo.Arguments = (@("-y", "-hide_banner", "-loglevel", "error",
                "-f", "gdigrab", "-framerate", "30", "-i", "title=OpenMW",
                "-t", [string]$CaptureSeconds, "-c:v", "libx264", "-preset", "veryfast",
                "-pix_fmt", "yuv420p", $video) |
            ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join " "
        $ffmpeg = [Diagnostics.Process]::new()
        $ffmpeg.StartInfo = $ffmpegInfo
        [void]$ffmpeg.Start()
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $game.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $game.Refresh()
    }
    if (-not $game.HasExited) {
        $timedOut = $true
        $game.Kill()
        $game.WaitForExit()
    }
    else {
        $game.WaitForExit()
    }
    $game.Refresh()
    $gameExitCode = $game.ExitCode
}
finally {
    [Environment]::SetEnvironmentVariable($driverEnvironmentName, $previousDriver, "Process")
    foreach ($name in $previousReloadEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousReloadEnvironment[$name], "Process")
    }
    $env:OPENMW_DEBUG_LEVEL = $previousDebug
    $env:OPENMW_DISABLE_CRASH_CATCHER = $previousCrashCatcher
    $env:OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = $previousFatalDialog
    if ($null -ne $ffmpeg -and -not $ffmpeg.HasExited) {
        try { $ffmpeg.StandardInput.WriteLine("q") } catch {}
        if (-not $ffmpeg.WaitForExit(15000)) { $ffmpeg.Kill(); $ffmpeg.WaitForExit() }
    }
    if ($null -ne $ffmpeg) {
        $ffmpegText = $ffmpeg.StandardOutput.ReadToEnd() + $ffmpeg.StandardError.ReadToEnd()
        [IO.File]::WriteAllText($ffmpegLog, $ffmpegText, [Text.UTF8Encoding]::new($false))
        $ffmpeg.Dispose()
    }
}

$logText = if (Test-Path -LiteralPath $openmwLog) { Get-Content -Raw -LiteralPath $openmwLog } else { "" }
$resultPattern = if ($Route -eq "ChetPersistenceReload") {
    'FNV R2 persistence reload: result=(?<result>pass|fail) state=(?<state>[01]) interaction=(?<interaction>[01])'
}
elseif ($Route -eq "ChetPersistenceSave") {
    'FNV R2 Chet: result=(?<result>pass|fail) reason="(?<reason>[^"]*)" door=(?<door>[01]) dialogue=(?<dialogue>[01]) barter=(?<barter>[01]) containerTransfer=(?<containerTransfer>[01]) barterCancel=(?<barterCancel>[01]) transaction=(?<transaction>[01]) nativeSave=(?<nativeSave>[01]) reload=(?<reload>[01])'
}
elseif ($Route -in @("ChetPersistent", "ChetTransaction")) {
    'FNV R2 Chet: result=(?<result>pass|fail) reason="(?<reason>[^"]*)" door=(?<door>[01]) dialogue=(?<dialogue>[01]) barter=(?<barter>[01]) containerTransfer=(?<containerTransfer>[01]) barterCancel=(?<barterCancel>[01]) transaction=(?<transaction>[01])'
}
elseif ($Route -eq "ChetObservation") {
    'FNV R2 Chet: result=(?<result>pass|fail) reason="(?<reason>[^"]*)" door=(?<door>[01]) dialogue=(?<dialogue>[01]) barter=(?<barter>[01])'
}
else {
    'FNV first smoke: result=(?<result>pass|fail) reason="(?<reason>[^"]*)" movement=(?<movement>[01]) door=(?<door>[01]) container=(?<container>[01])'
}
$resultMatch = [regex]::Matches($logText, $resultPattern) | Select-Object -Last 1
$nativeFrames = @(Get-ChildItem -LiteralPath (Join-Path $userData "screenshots") -Filter '*.png' -File -ErrorAction SilentlyContinue | Sort-Object Name)
$generatedSavePath = $null
if ($Route -eq "ChetPersistenceSave") {
    $saveCandidates = @(Get-ChildItem -LiteralPath $userData -Recurse -File -Filter '*.omwsave' -ErrorAction SilentlyContinue)
    if ($saveCandidates.Count -eq 1) {
        $generatedSavePath = Join-Path $OutputRoot 'R2-Goodsprings-Persistence.omwsave'
        Copy-Item -LiteralPath $saveCandidates[0].FullName -Destination $generatedSavePath -ErrorAction Stop
    }
}
$artifacts = [Collections.Generic.List[object]]::new()
$nativeFramePaths = @($nativeFrames | ForEach-Object { $_.FullName })
foreach ($path in @($video, $stdout, $stderr, $openmwLog, $ffmpegLog, $runtimeManifest, $SavePath, $generatedSavePath) + $nativeFramePaths) {
    if (-not [string]::IsNullOrWhiteSpace([string]$path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        $file = Get-Item -LiteralPath $path
        $artifacts.Add([pscustomobject][ordered]@{
            path = $file.FullName
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }
}
$movement = $Route -eq "FirstSmoke" -and $null -ne $resultMatch -and $resultMatch.Groups['movement'].Value -eq '1'
$door = $null -ne $resultMatch -and $resultMatch.Groups['door'].Value -eq '1'
$container = $Route -eq "FirstSmoke" -and $null -ne $resultMatch -and $resultMatch.Groups['container'].Value -eq '1'
$chetRoute = $Route -in @("ChetObservation", "ChetPersistent", "ChetTransaction", "ChetPersistenceSave")
$dialogue = $chetRoute -and $null -ne $resultMatch -and $resultMatch.Groups['dialogue'].Value -eq '1'
$barter = $chetRoute -and $null -ne $resultMatch -and $resultMatch.Groups['barter'].Value -eq '1'
$containerTransfer = $Route -in @("ChetPersistent", "ChetTransaction", "ChetPersistenceSave") -and $null -ne $resultMatch -and $resultMatch.Groups['containerTransfer'].Value -eq '1'
$barterCancel = $Route -eq "ChetPersistent" -and $null -ne $resultMatch -and $resultMatch.Groups['barterCancel'].Value -eq '1'
$transaction = $Route -in @("ChetTransaction", "ChetPersistenceSave") -and $null -ne $resultMatch -and $resultMatch.Groups['transaction'].Value -eq '1'
$nativeSave = $Route -eq "ChetPersistenceSave" -and $null -ne $resultMatch -and $resultMatch.Groups['nativeSave'].Value -eq '1'
$reloadState = $Route -eq "ChetPersistenceReload" -and $null -ne $resultMatch -and $resultMatch.Groups['state'].Value -eq '1'
$reloadInteraction = $Route -eq "ChetPersistenceReload" -and $null -ne $resultMatch -and $resultMatch.Groups['interaction'].Value -eq '1'
$peacefulExitLogged = $logText -match '(?m)^\[[^\]]+\] Quitting peacefully\.\s*$'
$videoRetained = (Test-Path -LiteralPath $video -PathType Leaf) -and (Get-Item -LiteralPath $video).Length -gt 0
$minimumNativeFrames = if ($Route -eq "ChetPersistenceSave") { 7 } elseif ($Route -eq "ChetPersistenceReload") { 2 } elseif ($Route -in @("ChetPersistent", "ChetTransaction")) { 6 } elseif ($Route -eq "ChetObservation") { 3 } else { 4 }
$routeAssertionsPassed = if ($Route -eq "ChetPersistent") { $door -and $dialogue -and $barter -and $containerTransfer -and $barterCancel } elseif ($Route -eq "ChetTransaction") { $door -and $dialogue -and $barter -and $containerTransfer -and $transaction } elseif ($Route -eq "ChetPersistenceSave") { $door -and $dialogue -and $barter -and $containerTransfer -and $transaction -and $nativeSave -and $null -ne $generatedSavePath } elseif ($Route -eq "ChetPersistenceReload") { $reloadState -and $reloadInteraction } elseif ($Route -eq "ChetObservation") { $door -and $dialogue -and $barter } else { $movement -and $door -and $container }
$passed = $null -ne $resultMatch -and $resultMatch.Groups['result'].Value -eq 'pass' -and
    $routeAssertionsPassed -and $nativeFrames.Count -ge $minimumNativeFrames -and $videoRetained -and
    $titleObserved -and -not $timedOut -and ($gameExitCode -eq 0 -or $peacefulExitLogged)
$reason = if ($null -ne $resultMatch) { $resultMatch.Groups['reason'].Value }
    elseif ($timedOut) { "OpenMW timed out before a $Route result" }
    elseif (-not $titleObserved) { "exact OpenMW window title was not observed" }
    else { "OpenMW exited without $Route result telemetry" }

$report = [ordered]@{
    schema = "nikami-openmw-fnv-$routeSlug/v1"
    status = if ($passed) { "pass" } else { "fail" }
    startedAt = $startedAt.ToString("o")
    completedAt = [DateTime]::UtcNow.ToString("o")
    firstObservedBlocker = if ($passed) { $null } else { $reason }
    source = [ordered]@{
        runtimeRoot = $BinaryRoot
        runtimeManifest = $runtimeManifest
        savePath = $SavePath
        saveSha256 = (Get-FileHash -LiteralPath $SavePath -Algorithm SHA256).Hash.ToLowerInvariant()
        generatedSavePath = $generatedSavePath
    }
    launch = [ordered]@{
        executable = $exe
        arguments = $arguments
        exitCode = $gameExitCode
        peacefulExitLogged = $peacefulExitLogged
        timedOut = $timedOut
        retailEngineLaunched = $false
        openmwVrLaunched = $false
    }
    capture = [ordered]@{
        method = "OpenMW native ScreenCaptureHandler frames plus ffmpeg gdigrab exact-title transport"
        selfDriven = $true
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        proofStateMutationUsed = $false
        cameraDrivingUsed = $false
        exactTitleObserved = $titleObserved
        nativeFrameCount = $nativeFrames.Count
    }
    assertions = [ordered]@{
        ordinaryExteriorGameplay = if ($Route -eq "FirstSmoke") { $logText -match 'FNV first smoke: exterior-ready cell=' } else { $true }
        exteriorMovement = $movement
        authoredDoorTransition = $door
        unlockedContainerOpened = $container
        chetDialogueOpened = $dialogue
        authoredBarterOpened = $barter
        ordinaryContainerTransfer = $containerTransfer
        authoredBarterCancellationNoDelta = $barterCancel
        authoredMerchantTransaction = $transaction
        nativeProductionSave = $nativeSave -and $null -ne $generatedSavePath
        coldReloadStateRetained = $reloadState
        ordinaryReloadContainerOpened = $reloadInteraction
        nativeFramesRetained = $nativeFrames.Count -ge $minimumNativeFrames
        exactTitleVideoRetained = $videoRetained
    }
    telemetry = [ordered]@{
        resultReason = $reason
        log = $openmwLog
    }
    artifacts = @($artifacts)
}
$reportPath = Join-Path $OutputRoot $resultReportName
[IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 10
if (-not $passed) { throw "OpenMW $Route failed: $reason. See $reportPath" }
