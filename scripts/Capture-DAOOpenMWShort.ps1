[CmdletBinding()]
param(
    [ValidateSet("outside-walk", "people", "native-people", "outside-look", "waterfront", "town-match", "town-survey", "cluster-match", "tavern")]
    [string]$Shot = "outside-walk",
    [string]$OutputRoot,
    [string]$Binary = "D:\code\nikami-worlds\local\labs\openmw-051-threeway-candidate-r30\openmw.exe",
    [ValidateRange(2, 5)]
    [int]$Seconds = 3
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$binaryRoot = Split-Path $Binary -Parent
$resources = Join-Path $binaryRoot "resources"
$baseConfig = Join-Path $repoRoot "local\dao-openmw-poc\openmw-dao-walkaround-20260802-182825\config"
$exterior = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-20260802-10b\lak100d\redcliffe-approved-cluster.obj"
$exteriorPlayable = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-20260802-10b\lak100d\lak100d-openmw-playable2.obj"
$exteriorBaked = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-baked-20260803\lak100d\redcliffe-openmw-baked.obj"
$exteriorFullBaked = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-full-baked-20260803-v2\lak100d\redcliffe-openmw-full-baked.obj"
$exteriorFullBakedNoSky = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-full-baked-20260803-v2\lak100d\redcliffe-openmw-full-baked-nosky.obj"
$exteriorFullClean = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-full-baked-20260803-v2\lak100d\redcliffe-openmw-full-baked-clean.obj"
$exteriorFullOcean2 = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-full-baked-20260803-v2\lak100d\redcliffe-openmw-full-baked-ocean2.obj"
$exteriorFullOceanRaised = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-full-baked-20260803-v2\lak100d\redcliffe-openmw-full-baked-ocean-raised.obj"
$exteriorFullOceanDiagnostic = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-full-baked-20260803-v2\lak100d\redcliffe-openmw-full-baked-ocean-diagnostic.obj"
$exteriorSkyOnly = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-full-baked-20260803-v2\lak100d\redcliffe-openmw-sky-only.obj"
$exteriorFullAlpha = Join-Path $repoRoot "local\dao-openmw-poc\haven-export-full-baked-20260803-v2\lak100d\redcliffe-openmw-full-baked-alpha.obj"
$godotExactEnvironment = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-environment-v2.obj"
$godotNativeEnvironment = "D:\code\opendao-poc\godot\assets\generated\redcliffe-environment-v2.glb"
$godotExactConnectedEnvironment = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-environment-connected.obj"
$godotExactActors = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-actors-direct.obj"
$godotNativeActors = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-actors-direct.glb"
$godotExactSky = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-sky-dome.obj"
$godotExactVegetation = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-vegetation.obj"
$godotExactSetpieces = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-setpieces.obj"
$godotExactTerrainRing = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-terrain-ring.obj"
$godotNativeTerrainRing = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-terrain-ring-dao-shader.glb"
$godotTerrainAssets = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\terrain-palettes"
$tavern = Join-Path $repoRoot "local\dao-openmw-poc\godot-transfer-v1\redcliffe-tavern-openmw.obj"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot ("local\dao-openmw-poc\mobile-shorts\{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $Shot)
}
foreach ($required in @($Binary, $resources, $baseConfig, $exterior, $exteriorPlayable, $exteriorBaked, $exteriorFullBaked, $exteriorFullBakedNoSky, $exteriorFullClean, $exteriorFullOcean2, $exteriorFullOceanRaised, $exteriorFullOceanDiagnostic, $exteriorSkyOnly, $exteriorFullAlpha, $godotExactEnvironment, $godotNativeEnvironment, $godotExactConnectedEnvironment, $godotExactActors, $godotNativeActors, $godotExactSky, $godotExactVegetation, $godotExactSetpieces, $godotExactTerrainRing, $godotNativeTerrainRing, $godotTerrainAssets, $tavern)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required OpenMW short dependency is missing: $required" }
}
if (Test-Path -LiteralPath $OutputRoot) { throw "Refusing to overwrite existing short directory: $OutputRoot" }
if (Get-Process -Name openmw -ErrorAction SilentlyContinue) { throw "OpenMW is already running." }

$shotTable = @{
    "outside-walk" = @{
        scene=$exterior; scale="64"; x="-16640"; y="-19264"; z="0"
        frames="0,80,160,240"; ex="-720,-610,-500,-390"; ey="500,430,360,290"; ez="370,360,350,340"
        tx="0,0,0,0"; ty="-64,-64,-64,-64"; tz="155,155,155,155"
    }
    "people" = @{
        scene=$exteriorBaked; scale="1"; x="0"; y="0"; z="0"
        # Native scene coordinates match the Godot square shot 1:1.
        frames="0,80,160,240"; ex="282,280,278,276"; ey="289,290,291,292"; ez="5.0,5.0,5.0,5.0"
        # The current OpenMW survey hook consumes a reversed look vector.
        tx="294,290,286,282"; ty="278,280,282,284"; tz="6.4,6.4,6.4,6.4"
    }
    "native-people" = @{
        # The exact camera-match gate uses the composed Godot GLB. The legacy
        # OBJ terrain ring is intentionally excluded here: it has independent
        # transform/material conversion and must pass its own native-glTF gate
        # before it can extend the shot.
        background=$godotExactSky; scene=([string]$godotNativeTerrainRing + ';' + [string]$godotNativeEnvironment + ';' + [string]$godotExactSetpieces + ';' + [string]$godotExactVegetation); foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"
        # Close validation on the authored militia pair at (255.74,300.74)
        # and (257.49,302.25); retain the same approach side as the oracle.
        frames="0,80,160,240"; ex="252.8,252.8,252.8,252.8"; ey="305.4,305.4,305.4,305.4"; ez="3.25,3.25,3.25,3.25"
        tx="256.6,256.6,256.6,256.6"; ty="301.6,301.6,301.6,301.6"; tz="2.55,2.55,2.55,2.55"
    }
    "outside-look" = @{
        scene=$exterior; scale="64"; x="-16640"; y="-19264"; z="0"
        # Elevated architectural shot: keep the fire/terrain shell below frame.
        frames="0,80,160,240"; ex="-540,-520,-500,-480"; ey="330,320,310,300"; ez="520,518,516,514"
        tx="0,10,20,30"; ty="-64,-64,-64,-64"; tz="455,455,455,455"
    }
    "waterfront" = @{
        scene=$exteriorFullOceanRaised; background=$exteriorSkyOnly; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"
        # Seaward establishing shot: remain inside the authored water footprint
        # and look back toward Redcliffe so ocean, shoreline, and skyline coexist.
        frames="0,80,160,240"; ex="248,252,256,260"; ey="55,59,63,67"; ez="2.4,2.4,2.4,2.4"
        tx="260,260,260,260"; ty="295,298,301,304"; tz="5.2,5.2,5.2,5.2"
    }
    "town-match" = @{
        # Native glTF for both the 14 connected tiles and composed town; this
        # keeps every terrain transform in the same coordinate pipeline.
        background=$godotExactSky; scene=([string]$godotNativeTerrainRing + ';' + [string]$godotNativeEnvironment + ';' + [string]$godotExactSetpieces + ';' + [string]$godotExactVegetation); foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"
        # Exact Godot desktop default after its terrain ray cast: terrain Y
        # 2.18328 + 1.60 m eye height, mapped to OpenMW Z-up coordinates.
        frames="0,80,160,240"; ex="250,250,250,250"; ey="307,307,307,307"; ez="3.78328,3.78328,3.78328,3.78328"
        # Godot/OBJ (x, y, z) maps through OSG OBJ loading as (x, -z, y).
        # Keep the authored target direction; reversing it points the camera
        # away from the square and exposes the underside of the terrain shell.
        # The retained Godot reference applies a right-third composition yaw;
        # place the bonfire/actor group accordingly, then animate this baseline.
        tx="256,256,256,256"; ty="300.5,300.5,300.5,300.5"; tz="2.5,2.5,2.5,2.5"
    }
    "town-survey" = @{
        scene=$exteriorFullOceanRaised; background=$exteriorSkyOnly; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"
        # Four cardinal headings from the known square eye point, one per second.
        frames="0,60,120,180"; ex="250,250,250,250"; ey="307,307,307,307"; ez="4.0,4.0,4.0,4.0"
        tx="250,250,270,230"; ty="327,287,307,307"; tz="4.0,4.0,4.0,4.0"
    }
    "cluster-match" = @{
        scene=$exteriorBaked; background=$exteriorSkyOnly; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"
        frames="0,80,160,240"; ex="250,250,250,250"; ey="307,307,307,307"; ez="4.0,4.0,4.0,4.0"
        tx="260,260,260,260"; ty="300,300,300,300"; tz="2.5,2.5,2.5,2.5"
    }
    "tavern" = @{
        scene=$tavern; scale="64"; x="0"; y="0"; z="0"
        frames="0,80,160,240"; ex="430,500,570,640"; ey="-120,-115,-110,-105"; ez="92,94,96,98"
        tx="1080,1080,1080,1080"; ty="-88,-88,-88,-88"; tz="102,102,102,102"
    }
}
$shotConfig = $shotTable[$Shot]
$config = Join-Path $OutputRoot "config"
$userData = Join-Path $OutputRoot "userdata"
New-Item -ItemType Directory -Path $config,$userData,(Join-Path $userData "data") -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $baseConfig "openmw.cfg"),(Join-Path $baseConfig "settings.cfg") -Destination $config

$extraScenePaths = if ($shotConfig.background) { ([string]$shotConfig.background) + ';' + ([string]$shotConfig.scene) } else { [string]$shotConfig.scene }
$environment = [ordered]@{
    OSG_NOTIFY_LEVEL = "DEBUG"
    OPENMW_WORLD_VIEWER_START_POS_X = "-320"
    OPENMW_WORLD_VIEWER_START_POS_Y = "960"
    OPENMW_WORLD_VIEWER_START_POS_Z = "160"
    OPENMW_WORLD_VIEWER_START_ROT_X = "0"
    OPENMW_WORLD_VIEWER_START_ROT_Y = "0"
    OPENMW_WORLD_VIEWER_START_ROT_Z = "3.14159265"
    OPENMW_WORLD_VIEWER_START_DRY = "1"
    OPENMW_WORLD_VIEWER_START_CAMERA_MODE = "static"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE = $extraScenePaths
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_SCALE = [string]$shotConfig.scale
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_X = [string]$shotConfig.x
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_Y = [string]$shotConfig.y
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_Z = [string]$shotConfig.z
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_PROOF_LIGHT = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_DAO_ATMOSPHERE = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_DAO_PBR = "1"
    OPENMW_GLTF_DAO_PBR = "1"
    OPENMW_GLTF_DAO_TERRAIN_ASSET_DIR = $godotTerrainAssets
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_DAO_ALPHA_CUTOUT = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_PRESERVE_MATERIALS = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_ISOLATE = "1"
    OPENMW_WORLD_VIEWER_DAO_TELEMETRY_PATH = (Join-Path $OutputRoot "openmw-runtime-state.json")
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_FRAMES = [string]$shotConfig.frames
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_X = [string]$shotConfig.ex
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_Y = [string]$shotConfig.ey
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_EYE_Z = [string]$shotConfig.ez
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_X = [string]$shotConfig.tx
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_Y = [string]$shotConfig.ty
    OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_TARGET_Z = [string]$shotConfig.tz
    OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI = "1"
    OPENMW_PROOF_HIDE_GUI = "1"
    OPENMW_PROOF_HIDE_PLAYER_VISUAL = "1"
    OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS = "1"
    OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = "1"
    # Always retain one renderer-native frame. Desktop/window capture can be
    # black when another application occludes OpenMW even though the renderer
    # and scene telemetry are healthy.
    # The untouched Godot GLB carries all normal palettes and can spend over
    # ten seconds decoding embedded images. Capture after that renderer work,
    # never from the loading/clear frames.
    OPENMW_PROOF_SCREENSHOT_READY_FRAMES = "60"
}
if ($shotConfig.background) {
    $environment.OPENMW_WORLD_VIEWER_EXTRA_SCENE_BACKGROUND_FIRST = "1"
}
if ($shotConfig.outdoorClear) {
    $environment.OPENMW_WORLD_VIEWER_PROOF_OUTDOOR_CLEAR = [string]$shotConfig.outdoorClear
}
if ($shotConfig.foreground) {
    $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_SCENE = [string]$shotConfig.foreground
    $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_PROOF_LIGHT = "1"
    $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_PRESERVE_MATERIALS = "1"
}
if ($shotConfig.gridX) {
    $environment.OPENMW_WORLD_VIEWER_START_WORLDSPACE = [string]$shotConfig.worldspace
    $environment.OPENMW_WORLD_VIEWER_START_GRID_X = [string]$shotConfig.gridX
    $environment.OPENMW_WORLD_VIEWER_START_GRID_Y = [string]$shotConfig.gridY
}
$previous = @{}
foreach ($name in @([Environment]::GetEnvironmentVariables("Process").Keys | ForEach-Object {[string]$_})) {
    if ($name.StartsWith("OPENMW_WORLD_VIEWER_") -or $name.StartsWith("OPENMW_PROOF_")) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}
foreach ($entry in $environment.GetEnumerator()) {
    if (-not $previous.ContainsKey($entry.Key)) { $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, "Process") }
    [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, "Process")
}

$stdout = Join-Path $OutputRoot "openmw.stdout.log"
$stderr = Join-Path $OutputRoot "openmw.stderr.log"
$mp4 = Join-Path $OutputRoot ("opendao-openmw-{0}-{1}s-720p.mp4" -f $Shot, $Seconds)
$preview = Join-Path $OutputRoot ("opendao-openmw-{0}-preview.png" -f $Shot)
$contactSheet = Join-Path $OutputRoot ("opendao-openmw-{0}-contact-sheet.png" -f $Shot)
$process = $null
try {
    $startCell = if ($shotConfig.start) { [string]$shotConfig.start } else { "ToddTest" }
    $arguments = @("--replace","config","--config",$config,"--user-data",$userData,"--resources",$resources,"--skip-menu","--start",$startCell,"--no-sound")
    # Start-Process flattens string arrays and otherwise splits cell names at spaces.
    $argumentLine = ($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + ($value -replace '"', '\"') + '"' } else { $value }
    }) -join ' '
    $process = Start-Process -FilePath $Binary -ArgumentList $argumentLine -WorkingDirectory $binaryRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "OpenMW exited before the DAO scene loaded (exit $($process.ExitCode))." }
        if (Test-Path -LiteralPath $stdout) {
            $text = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
            $sceneLoaded = $text -match "World viewer extra scene: loaded"
            $foregroundLoaded = -not $shotConfig.foreground -or
                $text -match "World viewer extra foreground scene: loaded"
            if ($sceneLoaded -and $foregroundLoaded) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    if ((Get-Date) -ge $deadline) { throw "Timed out waiting for the DAO scene load gate." }
    # The loader gate fires before the splash swap has reached the D3D window.
    # Native GLB decoding finishes on the update traversal that emits the load
    # gate. Give the subsequent render traversals enough time to retire the
    # loading wallpaper and upload embedded textures before recording evidence.
    Start-Sleep -Milliseconds 5000
    & ffmpeg -hide_banner -loglevel warning -y -f gdigrab -framerate 60 -draw_mouse 0 -i "title=OpenMW" -t $Seconds `
        -vf "scale=1280:720:flags=lanczos" -c:v libx264 -preset fast -crf 19 -pix_fmt yuv420p -an -movflags +faststart $mp4
    if ($LASTEXITCODE -ne 0) { throw "OpenMW exact-title recording failed with exit code $LASTEXITCODE." }
} finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    foreach ($entry in $previous.GetEnumerator()) { [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process") }
}
$nativeScreenshot = Get-ChildItem -LiteralPath (Join-Path $userData "screenshots") -Filter "screenshot*.png" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
if ($nativeScreenshot) {
    Copy-Item -LiteralPath $nativeScreenshot.FullName -Destination $preview
} else {
    & ffmpeg -hide_banner -loglevel error -y -ss ([math]::Max(1, $Seconds / 2)) -i $mp4 -frames:v 1 -update 1 $preview
    if ($LASTEXITCODE -ne 0) { throw "Preview extraction failed." }
}
& ffmpeg -hide_banner -loglevel error -y -i $mp4 -vf "fps=1,scale=426:240:flags=lanczos,tile=3x1" -frames:v 1 -update 1 $contactSheet
if ($LASTEXITCODE -ne 0) { throw "Contact-sheet extraction failed." }
& ffmpeg -v error -i $mp4 -f null -
if ($LASTEXITCODE -ne 0) { throw "Full MP4 decode validation failed." }
[ordered]@{shot=$Shot; video=$mp4; preview=$preview; contactSheet=$contactSheet; scene=[string]$shotConfig.scene; seconds=$Seconds} | ConvertTo-Json
