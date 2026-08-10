[CmdletBinding()]
param(
    [ValidateSet("outside-walk", "people", "native-people", "actor-closeup", "leliana", "leliana-tavern", "morrigan-hut", "leliana-face", "leliana-forest", "character-forest", "marethari", "marethari-set", "marethari-terrain", "forest-survey", "outside-look", "waterfront", "native-water", "water-dock", "water-scout", "runtime-town", "runtime-water", "redcliffe-world", "town-core", "town-post", "town-people-front", "town-match", "town-survey", "cluster-match", "tavern")]
    [string]$Shot = "outside-walk",
    [string]$OutputRoot,
    [string]$Binary = "D:\code\nikami-worlds\local\labs\openmw-051-threeway-candidate-r30\openmw.exe",
    [string]$ResourcesRoot,
    [string]$ActorAsset,
    [ValidateSet("0", "1")]
    [string]$DaoFaceShader = "1",
    [ValidateRange(2, 5)]
    [int]$Seconds = 3,
    [switch]$Interactive
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$binaryRoot = Split-Path $Binary -Parent
$resources = if ([string]::IsNullOrWhiteSpace($ResourcesRoot)) {
    Join-Path $binaryRoot "resources"
} else {
    (Resolve-Path -LiteralPath $ResourcesRoot).Path
}
$baseConfig = Join-Path $repoRoot "local\dao-openmw-poc\openmw-dao-walkaround-20260802-182825\config"
if (-not (Test-Path -LiteralPath $baseConfig)) {
    $baseConfig = "D:\code\opendao-poc\cache\openmw-shared\base-config"
}
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
$daoForestClearing = Join-Path $repoRoot "local\dao-openmw-poc\brc100d-clearing-20260806\brc100d-clearing-portrait.obj"
$daoMarethariActor = "D:\code\opendao-poc\cache\openmw-shared\marethari-actor-glb5\keeper-marethari.glb"
$daoMarethariTerrain59 = "D:\code\opendao-poc\cache\openmw-shared\marethari-terrain-direct-cells\brc997d_59_0.glb"
$daoMarethariTerrain31 = "D:\code\opendao-poc\cache\openmw-shared\marethari-terrain-direct-cells\brc997d_31_0.glb"
$daoMarethariTerrain31Local = "D:\code\opendao-poc\cache\dalish-origin-brc997d\brc997d\models\brc997d_31_0.glb"
$daoMarethariTerrainAssets = "D:\code\opendao-poc\cache\dalish-origin-brc997d\terrain-materials"
$daoMarethariGroundCell = "D:\code\opendao-poc\cache\openmw-shared\marethari-terrain-surface\brc997d_31_0.glb"
$daoMarethariWestGroundCell = "D:\code\opendao-poc\cache\openmw-shared\marethari-terrain-surface\brc997d_59_0.glb"
$daoMarethariAravel01A = "D:\code\opendao-poc\cache\dalish-origin-brc997d\brc997d\models\prp_aravel01_0.glb|255.924805,277.873627,2.305931,0.019157,-0.003702,0.793110,0.608766,1"
$daoMarethariAravel01B = "D:\code\opendao-poc\cache\openmw-shared\marethari-set-baked\aravel01_242_277.glb"
$daoMarethariAravel01C = "D:\code\opendao-poc\cache\openmw-shared\marethari-set-baked\aravel01_263_254.glb"
$daoMarethariAravel01D = "D:\code\opendao-poc\cache\openmw-shared\marethari-set-baked\aravel01_281_260.glb"
$daoMarethariAravel02 = "D:\code\opendao-poc\cache\dalish-origin-brc997d\brc997d\models\prp_aravel02.glb|245.110092,293.638214,2.391861,0.018455,-0.028633,0.992040,0.121232,1"
$daoMarethariEnvironment = ([string]$daoMarethariWestGroundCell + '|0,0,0;' +
    [string]$daoMarethariGroundCell + '|0,0,0;' +
    [string]$daoMarethariAravel01A + ';' +
    [string]$daoMarethariAravel02)
$godotExactConnectedEnvironment = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-environment-connected.obj"
$godotExactActors = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-actors-direct.obj"
$godotNativeActors = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-actors-direct.glb"
if (-not [string]::IsNullOrWhiteSpace($ActorAsset)) {
    $godotNativeActors = (Resolve-Path -LiteralPath $ActorAsset).Path
    $daoMarethariActor = $godotNativeActors
}
$godotExactSky = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-sky-dome.obj"
$godotExactVegetation = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-vegetation.obj"
$godotExactSetpieces = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-setpieces.obj"
$godotNativeVegetation = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-vegetation-native-alpha.glb"
$godotNativeSetpieces = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-setpieces-native.glb"
$godotExactTerrainRing = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-terrain-ring.obj"
$godotNativeTerrainRing = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-terrain-ring-dao-shader.glb"
$godotOpenMWTerrainRing = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-terrain-ring-local-zup.glb"
$godotAreaRoot = "D:\code\opendao-poc\cache\haven-actors-hair-v9\lak100d"
$godotAreaFile = Join-Path $godotAreaRoot "lak100d.havenarea"
$godotConnectedTerrainPaths = @()
if (Test-Path -LiteralPath $godotAreaFile) {
    $areaDefinition = Get-Content -LiteralPath $godotAreaFile -Raw | ConvertFrom-Json
    foreach ($entry in $areaDefinition.terrain.patches.psobject.Properties) {
        $definition = $entry.Value
        foreach ($instance in $definition.instances) {
            $dx = [double]$instance.position[0] - 260.0
            $dy = [double]$instance.position[1] - 301.0
            if ([Math]::Sqrt($dx * $dx + $dy * $dy) -le 85.0) { continue }
            $asset = Join-Path $godotAreaRoot ([string]$definition.file)
            if (-not (Test-Path -LiteralPath $asset)) { throw "Missing connected terrain asset: $asset" }
            $godotConnectedTerrainPaths += ("{0}|{1},{2},{3}" -f $asset, $instance.position[0], $instance.position[1], $instance.position[2])
        }
    }
}
$godotConnectedTerrain = $godotConnectedTerrainPaths -join ';'
$godotNativeWater = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-authored-water.glb"
$godotRuntimeOpenMW = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\redcliffe-runtime-openmw.glb"
$godotTerrainAssets = Join-Path $repoRoot "local\dao-openmw-poc\godot-exact-obj-v1\terrain-palettes"
$tavern = Join-Path $repoRoot "local\dao-openmw-poc\godot-transfer-v1\redcliffe-tavern-openmw.obj"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot ("local\dao-openmw-poc\mobile-shorts\{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $Shot)
}
foreach ($required in @($Binary, $resources, $baseConfig)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required OpenMW short dependency is missing: $required" }
}
if (Test-Path -LiteralPath $OutputRoot) { throw "Refusing to overwrite existing short directory: $OutputRoot" }
$resolvedBinary = (Resolve-Path -LiteralPath $Binary).Path
$sameBinaryProcess = Get-CimInstance Win32_Process -Filter "Name='openmw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $resolvedBinary } |
    Select-Object -First 1
if ($sameBinaryProcess) { throw "The requested OpenMW binary is already running (PID $($sameBinaryProcess.ProcessId))." }

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
        background=$godotExactSky; scene=$godotNativeEnvironment; foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="52"
        # Close validation on the authored militia pair at (255.74,300.74)
        # and (257.49,302.25); retain the same approach side as the oracle.
        frames="0,80,160,240"; ex="252.8,252.8,252.8,252.8"; ey="305.4,305.4,305.4,305.4"; ez="3.25,3.25,3.25,3.25"
        tx="256.6,256.6,256.6,256.6"; ty="301.6,301.6,301.6,301.6"; tz="2.55,2.55,2.55,2.55"
    }
    "actor-closeup" = @{
        # Measured camera on militia_3's positive face-normal side. This avoids
        # the prior line-of-sight overlap with militia_4 and is the actor
        # hierarchy/material portfolio gate.
        background=$godotExactSky; scene=$godotNativeEnvironment; foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="72"
        frames="0,80,160,240"; ex="255.8,255.8,255.8,255.8"; ey="303.32,303.32,303.32,303.32"; ez="3.4,3.4,3.4,3.4"
        tx="257.486,257.486,257.486,257.486"; ty="302.249,302.249,302.249,302.249"; tz="3.3,3.3,3.3,3.3"
    }
    "leliana" = @{
        # Exact high-poly Leliana portrait exported with Origins complexion,
        # authored auburn hair, younger facial normal, and glTF PBR materials.
        # Load Leliana as primary DAO scene content. The diagnostic foreground
        # branch is intentionally hidden by this capture profile.
        background=([string]$godotExactSky + ';' + [string]$godotExactEnvironment); scene=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="30"
        # Preserve the accepted Godot view ray at the export's Bethesda-unit
        # presentation scale, safely beyond OpenMW's near clip.
        frames="0,80,160,240"; proofFrames="160"; ex="255.9997,255.9997,255.9997,255.9997"; ey="272.5001,272.5001,272.5001,272.5001"; ez="96.6309,96.6309,96.6309,96.6309"
        tx="255.9997,255.9997,255.9997,255.9997"; ty="300.5001,300.5001,300.5001,300.5001"; tz="95.8599,95.8599,95.8599,95.8599"
    }
    "leliana-tavern" = @{
        # Exact lot120st_commander `leliana` placement and cam_leliana_cu,
        # sharing the hrt002d tavern export with the Godot portrait capture.
        scene=([string]$godotNativeActors + '|20.997124,17.492834,0.025964,0,0,-0.971343,0.237686,1'); scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="23"; daoCharacter="leliana"; faceTangents="0"; nativeOnly="1"; crop16x9="1"; captureWidth="1920"; captureHeight="1080"; clearR="0.12"; clearG="0.10"; clearB="0.08"; authoredLotheringManifest="1"; sharedMainCamera="1"
        frames="0,80,160,240"; proofFrames="160"; ex="21.243518,21.243518,21.243518,21.243518"; ey="16.050750,16.050750,16.050750,16.050750"; ez="1.729767,1.729767,1.729767,1.729767"
        tx="20.986500,20.986500,20.986500,20.986500"; ty="17.513240,17.513240,17.513240,17.513240"; tz="1.584723,1.584723,1.584723,1.584723"
    }
    "morrigan-hut" = @{
        # pre200st_flemeth_hut_int actor2 and cam2_1_2, composed with the
        # pre211ar_flemeths_hut_int stage transform. The room manifest is the
        # same ost102d export consumed by Godot.
        scene=([string]$godotNativeActors + '|-56.525110,-14.261370,0.054783,0,0,0.659346,0.751840,1'); scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="30"; daoCharacter="morrigan"; faceTangents="0"; nativeOnly="1"; crop16x9="1"; captureWidth="1920"; captureHeight="1080"; clearR="0.07"; clearG="0.045"; clearB="0.03"; authoredAreaManifest="D:\code\opendao-poc\cache\morrigan-hut-layout-export\ost102d\ost102d.havenarea"; sharedMainCamera="1"
        frames="0,80,160,240"; proofFrames="160"; ex="-59.325572,-59.325572,-59.325572,-59.325572"; ey="-14.901152,-14.901152,-14.901152,-14.901152"; ez="0.955667,0.955667,0.955667,0.955667"
        tx="-56.525110,-56.525110,-56.525110,-56.525110"; ty="-14.261370,-14.261370,-14.261370,-14.261370"; tz="1.500000,1.500000,1.500000,1.500000"
    }
    "leliana-face" = @{
        # Isolated native face-shader gate. Keep the exact authored portrait
        # but remove environment geometry and frame tightly enough to inspect
        # complexion, facial normals, roughness and forward scattering.
        scene=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="25"
        frames="0,80,160,240"; proofFrames="160"; ex="255.9997,255.9997,255.9997,255.9997"; ey="287.5001,287.5001,287.5001,287.5001"; ez="96.1000,96.1000,96.1000,96.1000"
        tx="255.9997,255.9997,255.9997,255.9997"; ty="300.5001,300.5001,300.5001,300.5001"; tz="96.1000,96.1000,96.1000,96.1000"
    }
    "leliana-forest" = @{
        # DAO Brecilian/Dalish clearing composed directly from brc100d.rim.
        # Leliana is translated into the clearing; no Morrowind cell geometry
        # or Redcliffe substitute participates in this portrait gate.
        scene=$daoForestClearing; foreground=$godotNativeActors; foregroundPreserve="0"; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="35"
        frames="0,80,160,240"; proofFrames="160"; ex="123,123,123,123"; ey="78.05,78.05,78.05,78.05"; ez="3.45,3.45,3.45,3.45"
        tx="123,123,123,123"; ty="78.5,78.5,78.5,78.5"; tz="3.45,3.45,3.45,3.45"
    }
    "character-forest" = @{
        # Canonical UTC actor GLBs are meter-scale, Z-up and face +Y. Rotate
        # them toward a camera on the clearing's south side and keep the actor
        # in the post-render foreground pass so forest depth cannot erase it.
        scene=$daoForestClearing; foreground=$godotNativeActors; foregroundPreserve="1"; foregroundScale="1"; foregroundX="123"; foregroundY="78.5"; foregroundZ="0"; foregroundRotZ="0"; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="35"
        frames="0,80,160,240"; proofFrames="160"; ex="123,123,123,123"; ey="77.85,77.85,77.85,77.85"; ez="1.62,1.62,1.62,1.62"
        tx="123,123,123,123"; ty="78.5,78.5,78.5,78.5"; tz="1.62,1.62,1.62,1.62"
    }
    "marethari" = @{
        # Exact bed200st_keeper stage shot. Coordinates come from the authored
        # DAO stage and are shared with the Godot portrait reconstruction.
        # The staged actor is part of the same canonical scene export. A
        # separate post-render foreground camera caused transform and clipping
        # divergence, so it is intentionally absent from this parity shot.
        # Environment and actor share the normal depth/material pass. Marking
        # the camp as a generic `background` invokes the sky-only override and
        # turns every authored material into flat grey.
        scene=$daoMarethariActor; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="10.550000"; daoCharacter="keeper_marethari"; nativeOnly="1"; crop16x9="1"; captureWidth="1920"; captureHeight="1080"; clearR="0.260"; clearG="0.300"; clearB="0.320"; authoredDalishManifest="1"; sharedMainCamera="1"
        # Exact global camera produced by Godot's stage_transform * cam2_1_1.
        frames="0,80,160,240"; proofFrames="160"; ex="257.673578,257.673578,257.673578,257.673578"; ey="270.063270,270.063270,270.063270,270.063270"; ez="4.351884,4.351884,4.351884,4.351884"
        tx="256.7754,256.7754,256.7754,256.7754"; ty="271.8335,271.8335,271.8335,271.8335"; tz="4.2205,4.2205,4.2205,4.2205"
    }
    "marethari-terrain" = @{
        # Minimal parity gate: the single authored ground cell beneath the
        # stage and Marethari share the exact portrait camera and depth pass.
        scene=([string]$daoMarethariTerrain31Local + '|287.387512,287.940125,0,0,0,0,1,1'); scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="10.550000"; daoCharacter="keeper_marethari"; nativeOnly="1"; crop16x9="1"; clearR="0.260"; clearG="0.300"; clearB="0.320"; terrainAssets=$daoMarethariTerrainAssets
        frames="0,80,160,240"; proofFrames="160"; ex="257.673578,257.673578,257.673578,257.673578"; ey="270.063270,270.063270,270.063270,270.063270"; ez="4.351884,4.351884,4.351884,4.351884"
        tx="256.7664,256.7664,256.7664,256.7664"; ty="271.8289,271.8289,271.8289,271.8289"; tz="4.2205,4.2205,4.2205,4.2205"
    }
    "marethari-set" = @{
        # Set-transform QA: exact portrait camera with the two original Haven
        # aravel instances, excluding terrain so depth/placement can be judged.
        scene=([string]$daoMarethariAravel01A + ';' + [string]$daoMarethariAravel02 + ';' + [string]$daoMarethariActor); scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="10.550000"; daoCharacter="keeper_marethari"; nativeOnly="1"; offsetAsOuter="1"; crop16x9="1"; clearR="0.260"; clearG="0.300"; clearB="0.320"; terrainAssets=$daoMarethariTerrainAssets
        frames="0,80,160,240"; proofFrames="160"; ex="257.673578,257.673578,257.673578,257.673578"; ey="270.063270,270.063270,270.063270,270.063270"; ez="4.351884,4.351884,4.351884,4.351884"
        tx="256.7664,256.7664,256.7664,256.7664"; ty="271.8289,271.8289,271.8289,271.8289"; tz="4.2205,4.2205,4.2205,4.2205"
    }
    "forest-survey" = @{
        scene=$daoForestClearing; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="70"
        frames="0,80,160,240"; proofFrames="160"; ex="123,123,123,123"; ey="30,30,30,30"; ez="30,30,30,30"
        tx="123,123,123,123"; ty="90,90,90,90"; tz="24,24,24,24"
    }
    "outside-look" = @{
        scene=$exterior; scale="64"; x="-16640"; y="-19264"; z="0"
        # Elevated architectural shot: keep the fire/terrain shell below frame.
        frames="0,80,160,240"; ex="-540,-520,-500,-480"; ey="330,320,310,300"; ez="520,518,516,514"
        tx="0,10,20,30"; ty="-64,-64,-64,-64"; tz="455,455,455,455"
    }
    "waterfront" = @{
        background=$godotExactSky; scene=([string]$godotNativeEnvironment + ';' + [string]$godotNativeWater); foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="72"
        # Exact Godot water tour. Player=(260,.18001,-150), desktop head
        # height=.65, target=(260,4,-300), mapped to OpenMW's Z-up axes.
        frames="0,80,160,240"; ex="260,260,260,260"; ey="250,250,250,250"; ez="2.2,2.2,2.2,2.2"
        tx="260,260,260,260"; ty="301,301,301,301"; tz="2.8,2.8,2.8,2.8"
    }
    "native-water" = @{
        # Water parity pass: authored shoreline with OpenMW's own animated
        # water. Vegetation remains excluded until its root-to-terrain gate
        # passes; floating props must never contaminate a water validation.
        background=$godotExactSky; scene=$godotNativeEnvironment; foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="60"; nativeWater="1"; waterHeight="0.02"
        # Harbor-facing shot from the verified town eye. Looking outward keeps
        # the authored quay and buildings in front of the native water and
        # avoids exposing the finite export boundary from offshore.
        frames="0,80,160,240"; ex="250,250,250,250"; ey="307,307,307,307"; ez="3.782912,3.782912,3.782912,3.782912"
        tx="250,250,250,250"; ty="150,150,150,150"; tz="2.0,2.0,2.0,2.0"
    }
    "water-dock" = @{
        # Low harbor approach using OpenMW's native animated water, with the
        # same authored town, setpieces, vegetation, actors, and sky as the
        # land portfolio shot.
        background=$godotExactSky; scene=([string]$godotNativeTerrainRing + ';' + [string]$godotNativeEnvironment + ';' + [string]$godotNativeSetpieces + ';' + [string]$godotNativeVegetation); foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="72"; nativeWater="1"; waterHeight="40.941948"
        # Godot's approved water proof uses this authored open-water approach.
        # Opaque DAO shell back faces are culled in the compatibility reader.
        frames="0,80,160,240"; ex="260,260,260,260"; ey="150,150,150,150"; ez="41.771958,41.771958,41.771958,41.771958"
        tx="260,260,260,260"; ty="301,301,301,301"; tz="4.0,4.0,4.0,4.0"
    }
    "water-scout" = @{
        background=$godotExactSky; scene=([string]$godotNativeEnvironment + ';' + [string]$godotNativeWater + ';' + [string]$godotExactVegetation); foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="66"
        # Four headings from the verified clear town camera. Native renderer
        # screenshots are taken at every keyframe, avoiding unsafe shoreline
        # guesses that can land beneath DAO's terrain shell.
        frames="30,90,150,210"; proofFrames="30,90,150,210"; ex="250,250,250,250"; ey="307,307,307,307"; ez="4.65,4.65,4.65,4.65"
        tx="260,350,250,150"; ty="300,307,407,307"; tz="2.5,1.0,1.0,1.0"
    }
    "runtime-town" = @{
        background=$godotExactSky; scene=$godotRuntimeOpenMW; foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="72"; notify="NOTICE"; screenshotTimeout="180"
        frames="0,80,160,240"; ex="250,250,250,250"; ey="307,307,307,307"; ez="3.782912,3.782912,3.782912,3.782912"
        # Exact rendered Camera3D basis from Godot telemetry, transformed from
        # Godot Y-up to OpenMW Z-up.  The scripted look-at request is not the
        # final camera forward vector because Player applies body yaw/pitch.
        tx="256.712575,256.712575,256.712575,256.712575"; ty="299.728043,299.728043,299.728043,299.728043"; tz="2.347652,2.347652,2.347652,2.347652"
    }
    "runtime-water" = @{
        background=$godotExactSky; scene=$godotRuntimeOpenMW; foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="72"; notify="NOTICE"; screenshotTimeout="180"
        frames="0,80,160,240"; ex="260,260,260,260"; ey="150,150,150,150"; ez="0.83001,0.83001,0.83001,0.83001"
        tx="260,260,260,260"; ty="301,301,301,301"; tz="4,4,4,4"
    }
    "redcliffe-world" = @{
        # Interactive full-world entry point. This uses the validated Godot-
        # composed Redcliffe GLB directly and never includes a Morrowind sky,
        # actor, terrain, or host-cell render layer.
        scene=$godotNativeEnvironment; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; hideWorld="1"; fov="72"; nativeOnly="1"; screenshotTimeout="180"
        frames="0,80,160,240"; ex="250,250,250,250"; ey="307,307,307,307"; ez="4.65,4.65,4.65,4.65"
        tx="260,260,260,260"; ty="300,300,300,300"; tz="2.5,2.5,2.5,2.5"
    }
    "town-match" = @{
        # The generated environment contains the two inner terrain cells; the
        # ring supplies the remaining authored Redcliffe landscape cells.
        background=$godotExactSky; scene=([string]$godotConnectedTerrain + ';' + [string]$godotNativeEnvironment + ';' + [string]$godotNativeSetpieces + ';' + [string]$godotNativeVegetation); foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="72"
        # Identical measured camera to the retained Godot town-core reference.
        # The previous lower eye/different target/default FOV made correctly
        # placed 132 m terrain tiles appear falsely foregrounded.
        frames="0,80,160,240"; ex="250,250,250,250"; ey="307,307,307,307"; ez="4.65,4.65,4.65,4.65"
        tx="260,260,260,260"; ty="300,300,300,300"; tz="2.5,2.5,2.5,2.5"
    }
    "town-core" = @{
        # Exact Godot-composed neighborhood only. The connected terrain ring
        # has a separate placement-parity gate and must not occlude this shot.
        background=$godotExactSky; scene=$godotNativeEnvironment; foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="72"; nativeWater="1"; waterHeight="0.02"
        # Exact Godot town tour: player origin at Y=4 plus the .65 m head.
        frames="0,80,160,240"; ex="250,250,250,250"; ey="307,307,307,307"; ez="4.65,4.65,4.65,4.65"
        tx="260,260,260,260"; ty="300,300,300,300"; tz="2.5,2.5,2.5,2.5"
    }
    "town-post" = @{
        # Postable square composition: exact native town plus the authored
        # vegetation pass. The independently baked terrain-ring artifact is
        # excluded until its placement parity gate passes.
        background=$godotExactSky; scene=([string]$godotNativeEnvironment + ';' + [string]$godotNativeSetpieces + ';' + [string]$godotNativeVegetation); foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="72"
        frames="0,80,160,240"; ex="250,250,250,250"; ey="307,307,307,307"; ez="4.65,4.65,4.65,4.65"
        tx="260,260,260,260"; ty="300,300,300,300"; tz="2.5,2.5,2.5,2.5"
    }
    "town-people-front" = @{
        # Same exact authored scene and actor state as town-core. The camera
        # lies on the positive transformed face-normal side of militia 2/3/4
        # (approximately +X,+Y in OpenMW space), measured from the glTF nodes.
        background=$godotExactSky; scene=$godotNativeEnvironment; foreground=$godotNativeActors; scale="1"; x="0"; y="0"; z="0"; outdoorClear="1"; fov="52"
        frames="0,80,160,240"; ex="260.5,260.5,260.5,260.5"; ey="305.0,305.0,305.0,305.0"; ez="3.4,3.4,3.4,3.4"
        tx="256.5,256.5,256.5,256.5"; ty="301.0,301.0,301.0,301.0"; tz="3.25,3.25,3.25,3.25"
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
$captureOpenMwCfg = Join-Path $config "openmw.cfg"
# The proof config names Morrowind.esm but the original seed omitted its BSA
# registrations. Native OpenMW water reads its animation/material textures
# through the VFS, so make the installed archives explicit for every isolated
# capture instead of falling back to the magenta missing-texture marker.
[System.IO.File]::AppendAllText($captureOpenMwCfg,
    "`r`nfallback-archive=Morrowind.bsa`r`n" +
    "fallback-archive=Tribunal.bsa`r`n" +
    "fallback-archive=Bloodmoon.bsa`r`n")
$captureSettingsCfg = Join-Path $config "settings.cfg"
$captureSettings = [System.IO.File]::ReadAllText($captureSettingsCfg)
$captureWidth = if ($shotConfig.captureWidth) { [int]$shotConfig.captureWidth } else { 800 }
$captureSettings = [regex]::Replace($captureSettings,
    '(?m)^resolution x\s*=.*$', "resolution x = $captureWidth")
$captureHeight = if ($shotConfig.captureHeight) { [int]$shotConfig.captureHeight } elseif ($shotConfig.crop16x9) { 450 } else { 600 }
$captureSettings = [regex]::Replace($captureSettings,
    '(?m)^resolution y\s*=.*$', "resolution y = $captureHeight")
$captureSettings = [regex]::Replace($captureSettings,
    '(?ms)(\[Water\].*?^shader\s*=\s*)false', '${1}true')
$captureSettings = [regex]::Replace($captureSettings,
    '(?ms)(\[Water\].*?^rtt size\s*=\s*)512', '${1}1024')
$captureSettings = [regex]::Replace($captureSettings,
    '(?ms)(\[Water\].*?^refraction\s*=\s*)false', '${1}true')
if ($Shot -eq "marethari") {
    # Match the accepted Godot portrait's CameraAttributesPractical focus
    # band using OpenMW's own depth-aware postprocessor.
    $captureSettings = [regex]::Replace($captureSettings,
        '(?ms)(\[Post Processing\].*?^enabled\s*=\s*)false', '${1}true')
    $captureSettings = [regex]::Replace($captureSettings,
        '(?ms)(\[Post Processing\].*?^chain\s*=).*$','$1 opendao_portrait_dof')
}
[System.IO.File]::WriteAllText($captureSettingsCfg, $captureSettings)

$extraScenePaths = if ($shotConfig.background) { ([string]$shotConfig.background) + ';' + ([string]$shotConfig.scene) } else { [string]$shotConfig.scene }
$extraSceneManifestPath = ""
if ($shotConfig.authoredDalishManifest) {
    $areaPath = "D:\code\opendao-poc\cache\dalish-origin-brc997d\brc997d\brc997d.havenarea"
    $areaRoot = Split-Path $areaPath -Parent
    $area = Get-Content -LiteralPath $areaPath -Raw | ConvertFrom-Json
    $manifestLines = [System.Collections.Generic.List[string]]::new()
    $tables = @(
        @{ data=$area.terrain.patches; radius=85.0 },
        @{ data=$area.props; radius=105.0 },
        @{ data=$area.trees; radius=105.0 }
    )
    foreach ($table in $tables) {
        if ([string]$shotConfig.authoredDalishManifest -eq 'propsOnly' -and $table.data -eq $area.terrain.patches) { continue }
        foreach ($definitionProperty in $table.data.PSObject.Properties) {
            $definition = $definitionProperty.Value
            if ([string]$shotConfig.authoredDalishManifest -eq 'stageCore' -and
                $table.data -eq $area.terrain.patches -and
                [string]$definition.file -notmatch '(?i)brc997d_(31|59)_0\.glb$') { continue }
            if ([string]$shotConfig.authoredDalishManifest -eq 'stageCore' -and
                $table.data -ne $area.terrain.patches -and
                [string]$definition.file -notmatch '(?i)prp_aravel02(?:_0)?\.glb$') { continue }
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($instance in $definition.instances) {
                $px = [double]$instance.position[0]
                $py = [double]$instance.position[1]
                $distance = [math]::Sqrt(($px - 260.0) * ($px - 260.0) + ($py - 301.0) * ($py - 301.0))
                if ($distance -gt [double]$table.radius) { continue }
                $rotation = $instance.rotation
                $key = ([string]::Join(',', @($instance.position + $rotation)))
                if (-not $seen.Add($key)) { continue }
                $assetPath = Join-Path $areaRoot ([string]$definition.file)
                # Godot-normalized carriage GLBs preserve the exact DAO mesh,
                # textures, and instance transform while serializing the
                # topology/tangents/material layout that both renderers can
                # consume identically.
                if ([string]$definition.file -match '(?i)prp_aravel01_0\.glb$') {
                    $assetPath = 'D:\code\opendao-poc\cache\openmw-shared\godot-canonical-set\prp_aravel01_0.glb'
                } elseif ([string]$definition.file -match '(?i)prp_aravel02(?:_0)?\.glb$') {
                    $assetPath = 'D:\code\opendao-poc\cache\openmw-shared\godot-canonical-set\prp_aravel02.glb'
                }
                if (-not (Test-Path -LiteralPath $assetPath)) { continue }
                $scaleValue = if ($null -ne $instance.scale) { [double]$instance.scale } else { 1.0 }
                $placement = @(
                    [double]$instance.position[0], [double]$instance.position[1], [double]$instance.position[2],
                    [double]$rotation[0], [double]$rotation[1], [double]$rotation[2], [double]$rotation[3], $scaleValue
                ) | ForEach-Object { $_.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
                $manifestLines.Add($assetPath + '|' + ([string]::Join(',', $placement)))
            }
        }
    }
    $extraSceneManifestPath = Join-Path $OutputRoot 'dalish-authored-scene.manifest'
    [IO.File]::WriteAllLines($extraSceneManifestPath, $manifestLines)
}
if ($shotConfig.authoredLotheringManifest) {
    $areaPath = "D:\code\opendao-poc\cache\lot120-tavern-export\hrt002d\hrt002d.havenarea"
    $areaRoot = Split-Path $areaPath -Parent
    $area = Get-Content -LiteralPath $areaPath -Raw | ConvertFrom-Json
    $manifestLines = [System.Collections.Generic.List[string]]::new()
    foreach ($definitionProperty in $area.props.PSObject.Properties) {
        $definition = $definitionProperty.Value
        foreach ($instance in $definition.instances) {
            $px = [double]$instance.position[0]
            $py = [double]$instance.position[1]
            $distance = [math]::Sqrt(($px - 21.0) * ($px - 21.0) + ($py - 17.5) * ($py - 17.5))
            if ($distance -gt 18.0) { continue }
            $assetPath = Join-Path $areaRoot ([string]$definition.file)
            if (-not (Test-Path -LiteralPath $assetPath)) { continue }
            $rotation = $instance.rotation
            $scaleValue = if ($null -ne $instance.scale) { [double]$instance.scale } else { 1.0 }
            $placement = @(
                [double]$instance.position[0], [double]$instance.position[1], [double]$instance.position[2],
                [double]$rotation[0], [double]$rotation[1], [double]$rotation[2], [double]$rotation[3], $scaleValue
            ) | ForEach-Object { $_.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
            $manifestLines.Add($assetPath + '|' + ([string]::Join(',', $placement)))
        }
    }
    $extraSceneManifestPath = Join-Path $OutputRoot 'lothering-authored-scene.manifest'
    [IO.File]::WriteAllLines($extraSceneManifestPath, $manifestLines)
}
if ($shotConfig.authoredAreaManifest) {
    $areaPath = [string]$shotConfig.authoredAreaManifest
    $areaRoot = Split-Path $areaPath -Parent
    $area = Get-Content -LiteralPath $areaPath -Raw | ConvertFrom-Json
    $manifestLines = [System.Collections.Generic.List[string]]::new()
    foreach ($definitionProperty in $area.props.PSObject.Properties) {
        $definition = $definitionProperty.Value
        foreach ($instance in $definition.instances) {
            $assetPath = Join-Path $areaRoot ([string]$definition.file)
            if (-not (Test-Path -LiteralPath $assetPath)) { continue }
            $rotation = $instance.rotation
            $scaleValue = if ($null -ne $instance.scale) { [double]$instance.scale } else { 1.0 }
            $placement = @(
                [double]$instance.position[0], [double]$instance.position[1], [double]$instance.position[2],
                [double]$rotation[0], [double]$rotation[1], [double]$rotation[2], [double]$rotation[3], $scaleValue
            ) | ForEach-Object { $_.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
            $manifestLines.Add($assetPath + '|' + ([string]::Join(',', $placement)))
        }
    }
    $extraSceneManifestPath = Join-Path $OutputRoot 'authored-area-scene.manifest'
    [IO.File]::WriteAllLines($extraSceneManifestPath, $manifestLines)
}
$environment = [ordered]@{
    OSG_NOTIFY_LEVEL = $(if ($shotConfig.notify) { [string]$shotConfig.notify } else { "DEBUG" })
    OPENMW_WORLD_VIEWER_START_POS_X = "-320"
    OPENMW_WORLD_VIEWER_START_POS_Y = "960"
    OPENMW_WORLD_VIEWER_START_POS_Z = "160"
    OPENMW_WORLD_VIEWER_START_ROT_X = "0"
    OPENMW_WORLD_VIEWER_START_ROT_Y = "0"
    OPENMW_WORLD_VIEWER_START_ROT_Z = "3.14159265"
    OPENMW_WORLD_VIEWER_START_DRY = "1"
    OPENMW_WORLD_VIEWER_START_CAMERA_MODE = "static"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE = $extraScenePaths
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_MANIFEST = $extraSceneManifestPath
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_SCALE = [string]$shotConfig.scale
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_X = [string]$shotConfig.x
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_Y = [string]$shotConfig.y
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_Z = [string]$shotConfig.z
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_PROOF_LIGHT = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_DAO_ATMOSPHERE = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_DAO_PBR = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_SHARED_MAIN_CAMERA = $(if ($shotConfig.sharedMainCamera) { "1" } else { "0" })
    OPENMW_WORLD_VIEWER_PROOF_CLEAR_R = $(if ($shotConfig.clearR) { [string]$shotConfig.clearR } else { "0.16" })
    OPENMW_WORLD_VIEWER_PROOF_CLEAR_G = $(if ($shotConfig.clearG) { [string]$shotConfig.clearG } else { "0.19" })
    OPENMW_WORLD_VIEWER_PROOF_CLEAR_B = $(if ($shotConfig.clearB) { [string]$shotConfig.clearB } else { "0.20" })
    OPENMW_GLTF_DAO_PBR = "1"
    OPENMW_DAO_FACE_SHADER = $DaoFaceShader
    OPENMW_DAO_FACE_ONLY = "1"
    OPENMW_DAO_FACE_MATERIAL_DIR = "D:\code\opendao-poc\cache\dao-face-material-contract\textures"
    OPENMW_DAO_ROBE_TINT_MASK = "D:\code\opendao-poc\godot\assets\generated\keeper_robe_tint_mask_b.png"
    OPENMW_DAO_FACE_GODOT_MATERIAL_DIR = "D:\code\opendao-poc\godot\assets\generated"
    OPENMW_DAO_FACE_CHARACTER = $(if ($shotConfig.daoCharacter) { [string]$shotConfig.daoCharacter } else { "" })
    OPENMW_DAO_FACE_TANGENTS = $(if ($null -ne $shotConfig.faceTangents) { [string]$shotConfig.faceTangents } else { "1" })
    OPENMW_GLTF_DAO_TERRAIN_ASSET_DIR = $(if ($shotConfig.terrainAssets) { [string]$shotConfig.terrainAssets } else { $godotTerrainAssets })
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_DAO_ALPHA_CUTOUT = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_PRESERVE_MATERIALS = "1"
    OPENMW_WORLD_VIEWER_EXTRA_SCENE_DIRECT_CAMERA = "1"
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
    OPENMW_PROOF_CAPTURE_POSTPROCESS = $(if ($shotConfig.sharedMainCamera) { "1" } else { "0" })
    OPENMW_PROOF_POSTPROCESS_SCREENSHOT_PATH = $(if ($shotConfig.sharedMainCamera) { Join-Path $userData "screenshots\screenshot000.png" } else { "" })
    OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS = "1"
    OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = "1"
    # Always retain one renderer-native frame. Desktop/window capture can be
    # black when another application occludes OpenMW even though the renderer
    # and scene telemetry are healthy.
    # The untouched Godot GLB carries all normal palettes and can spend over
    # ten seconds decoding embedded images. Capture after that renderer work,
    # never from the loading/clear frames.
}
if ($shotConfig.nativeWater) {
    # The dry-start guard is evaluated every frame. Leaving it enabled resets
    # the native lake to -200000 immediately after the one-time water setup.
    $environment.OPENMW_WORLD_VIEWER_START_DRY = "0"
    $environment.OPENMW_WORLD_VIEWER_DAO_NATIVE_WATER_HEIGHT = [string]$shotConfig.waterHeight
    $environment.OPENMW_PROOF_HIDE_WORLD_OCCLUDERS = "1"
} else {
    if (-not $shotConfig.sharedMainCamera) {
        $environment.OPENMW_WORLD_VIEWER_EXTRA_SCENE_ISOLATE = "1"
    }
}
if ($shotConfig.raycastCamera) {
    $environment.OPENMW_WORLD_VIEWER_DAO_RAYCAST_CAMERA = "1"
}
if ($shotConfig.proofFrames) {
    $environment.OPENMW_PROOF_SCREENSHOT_FRAME = [string]$shotConfig.proofFrames
} else {
    $environment.OPENMW_PROOF_SCREENSHOT_READY_FRAMES = "1"
}
if ($shotConfig.fov) {
    $environment.OPENMW_WORLD_VIEWER_EXTRA_SCENE_DIRECT_CAMERA_FOV_Y = [string]$shotConfig.fov
}
if ($shotConfig.background) {
    $environment.OPENMW_WORLD_VIEWER_EXTRA_SCENE_BACKGROUND_FIRST = "1"
}
if ($shotConfig.offsetAsOuter) {
    $environment.OPENMW_WORLD_VIEWER_EXTRA_SCENE_OFFSET_AS_OUTER = [string]$shotConfig.offsetAsOuter
}
if ($shotConfig.outdoorClear) {
    $environment.OPENMW_WORLD_VIEWER_PROOF_OUTDOOR_CLEAR = [string]$shotConfig.outdoorClear
}
if ($shotConfig.hideWorld) {
    $environment.OPENMW_PROOF_HIDE_WORLD_OCCLUDERS = [string]$shotConfig.hideWorld
}
if ($shotConfig.foreground) {
    $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_SCENE = [string]$shotConfig.foreground
    $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_PROOF_LIGHT = "1"
    if (-not $shotConfig.ContainsKey("foregroundPreserve") -or [string]$shotConfig.foregroundPreserve -ne "0") {
        $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_PRESERVE_MATERIALS = "1"
    }
    if ($shotConfig.foregroundScale) { $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_SCALE = [string]$shotConfig.foregroundScale }
    if ($shotConfig.foregroundX) { $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_X = [string]$shotConfig.foregroundX }
    if ($shotConfig.foregroundY) { $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_Y = [string]$shotConfig.foregroundY }
    if ($shotConfig.foregroundZ) { $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_Z = [string]$shotConfig.foregroundZ }
    if ($shotConfig.foregroundRotZ) { $environment.OPENMW_WORLD_VIEWER_EXTRA_FOREGROUND_ROT_Z = [string]$shotConfig.foregroundRotZ }
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
    $startParameters = @{
        FilePath = $Binary
        ArgumentList = $argumentLine
        WorkingDirectory = $binaryRoot
        RedirectStandardOutput = $stdout
        RedirectStandardError = $stderr
        PassThru = $true
    }
    if ($shotConfig.nativeOnly -and -not $Interactive) { $startParameters.WindowStyle = "Hidden" }
    $process = Start-Process @startParameters
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
    if ($Interactive) {
        [ordered]@{shot=$Shot; pid=$process.Id; interactive=$true; scene=[string]$shotConfig.scene; sceneLoaded=$true} | ConvertTo-Json
        return
    }
    # The untouched Godot GLB uploads more than 500 embedded textures on its
    # first render traversal. Wait for the renderer-native artifact instead of
    # racing that upload with a fixed sleep.
    $screenshotDirectory = Join-Path $userData "screenshots"
    $screenshotDeadline = (Get-Date).AddSeconds($(if ($shotConfig.screenshotTimeout) { [int]$shotConfig.screenshotTimeout } else { 45 }))
    while ((Get-Date) -lt $screenshotDeadline) {
        $readyScreenshot = Get-ChildItem -LiteralPath $screenshotDirectory -Filter "screenshot*.png" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -Last 1
        if ($readyScreenshot) { break }
        if ($process.HasExited) { throw "OpenMW exited while waiting for the native DAO frame (exit $($process.ExitCode))." }
        Start-Sleep -Milliseconds 100
    }
    if (-not $readyScreenshot) { throw "Timed out waiting for the renderer-native DAO frame." }
    # OSG creates the destination before its PNG writer has emitted the final
    # chunks. Do not terminate a native-only proof while that file is growing.
    $stableSamples = 0
    $previousLength = -1L
    $writeDeadline = (Get-Date).AddSeconds(10)
    while ($stableSamples -lt 5 -and (Get-Date) -lt $writeDeadline) {
        $currentLength = (Get-Item -LiteralPath $readyScreenshot.FullName).Length
        if ($currentLength -gt 0 -and $currentLength -eq $previousLength) {
            ++$stableSamples
        } else {
            $stableSamples = 0
            $previousLength = $currentLength
        }
        Start-Sleep -Milliseconds 100
    }
    if ($stableSamples -lt 5) { throw "Native DAO frame did not finish writing." }
    if (-not $shotConfig.nativeOnly) {
        & ffmpeg -hide_banner -loglevel warning -y -f gdigrab -framerate 60 -draw_mouse 0 -i "title=OpenMW" -t $Seconds `
            -vf "scale=1280:720:flags=lanczos" -c:v libx264 -preset fast -crf 19 -pix_fmt yuv420p -an -movflags +faststart $mp4
        if ($LASTEXITCODE -ne 0) { throw "OpenMW exact-title recording failed with exit code $LASTEXITCODE." }
    }
} finally {
    if (-not $Interactive -and $null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
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
# crop16x9 shots render at their requested 16:9 resolution natively. Cropping a 4:3 projection after
# capture changes the effective vertical FOV and invalidates camera parity.
if ($shotConfig.nativeOnly) {
    Copy-Item -LiteralPath $preview -Destination $contactSheet
} else {
    & ffmpeg -hide_banner -loglevel error -y -i $mp4 -vf "fps=1,scale=426:240:flags=lanczos,tile=3x1" -frames:v 1 -update 1 $contactSheet
    if ($LASTEXITCODE -ne 0) { throw "Contact-sheet extraction failed." }
    & ffmpeg -v error -i $mp4 -f null -
    if ($LASTEXITCODE -ne 0) { throw "Full MP4 decode validation failed." }
}
[ordered]@{shot=$Shot; video=$mp4; preview=$preview; contactSheet=$contactSheet; scene=[string]$shotConfig.scene; seconds=$Seconds} | ConvertTo-Json
