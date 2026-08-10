[CmdletBinding()]
param(
    [string]$SavePath = 'D:\code\nikami-worlds\local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos',
    [string]$ContentProfile = 'D:\code\nikami-worlds\profiles\fallout_new_vegas\openmw.cfg',
    [string]$DataRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data',
    [string]$DenominatorExe = 'D:\code\nikami-worlds\local\build\fnv-playability-recovery-20260807\authored-ads-gui-direct-fbo-v1\RelWithDebInfo\fnv-save330-denominator.exe',
    [string]$BsaTool = 'D:\code\nikami-worlds\local\build\openmw-051-full-port-noqt\RelWithDebInfo\bsatool.exe',
    [string]$Godot = 'D:\code\gd\Godot_v4.6.3-stable_win64_console.exe',
    [switch]$SkipIntro,
    [switch]$SkipGodotImport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$generated = Join-Path $projectRoot 'generated'
New-Item -ItemType Directory -Force -Path $generated | Out-Null

foreach ($required in @($SavePath, $ContentProfile, $DataRoot, $DenominatorExe)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required FNV Godot input missing: $required" }
}

$normalized = Join-Path $generated 'normalized-save.json'
$manifest = Join-Path $generated 'bootstrap.json'
$saveOverlay = Join-Path $generated 'save330-overlay'
& $DenominatorExe --save $SavePath --content-profile $ContentProfile --output $normalized
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $normalized)) {
    throw "Native FOS normalization failed with exit code $LASTEXITCODE"
}

python (Join-Path $projectRoot 'tools\build_bootstrap_manifest.py') `
    --normalized-save $normalized --save $SavePath --data-root $DataRoot --output $manifest
if ($LASTEXITCODE -ne 0) { throw 'Godot bootstrap manifest generation failed' }

$semanticDirectory = Join-Path $generated 'semantic-db'
$overlayArguments = @(
    (Join-Path $projectRoot 'tools\decode_fnv_changeform_index.py'),
    '--save', $SavePath,
    '--output-dir', $saveOverlay
)
if (Test-Path -LiteralPath (Join-Path $semanticDirectory 'manifest.json') -PathType Leaf) {
    $overlayArguments += @('--semantic-db', $semanticDirectory)
}
& python @overlayArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $saveOverlay 'index.json'))) {
    throw 'FOS change-form index generation failed'
}

if (-not $SkipIntro) {
    $introSource = Join-Path $DataRoot 'Video\FNVIntro.bik'
    $introOutput = Join-Path $generated 'FNVIntro.ogv'
    $introStamp = Join-Path $generated 'FNVIntro.quality-v2.json'
    if (-not (Test-Path -LiteralPath $introSource)) { throw "Owned FNV intro is missing: $introSource" }
    $sourceHash = (Get-FileHash -LiteralPath $introSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $introReady = $false
    if ((Test-Path -LiteralPath $introOutput) -and (Test-Path -LiteralPath $introStamp)) {
        $stamp = Get-Content -Raw -LiteralPath $introStamp | ConvertFrom-Json
        $introReady = $stamp.sourceSha256 -eq $sourceHash -and $stamp.profile -eq 'theora-q10-vorbis-q8-v2'
    }
    if (-not $introReady) {
        $introTemporary = Join-Path $generated 'FNVIntro.tmp.ogv'
        & ffmpeg -y -hide_banner -loglevel error -i $introSource -map 0:v:0 -map 0:a:0 `
            -c:v libtheora -q:v 10 -pix_fmt yuv420p -c:a libvorbis -q:a 8 $introTemporary
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $introTemporary)) { throw 'FNV HQ intro conversion failed' }
        Move-Item -LiteralPath $introTemporary -Destination $introOutput -Force
        [pscustomobject]@{
            schema = 'nikami-open-nv-intro-cache/v2'
            sourceSha256 = $sourceHash
            profile = 'theora-q10-vorbis-q8-v2'
        } | ConvertTo-Json | Set-Content -LiteralPath $introStamp -Encoding utf8
    }
}

if (Test-Path -LiteralPath $BsaTool) {
    $uiRoot = Join-Path $generated 'authored-ui'
    New-Item -ItemType Directory -Force -Path $uiRoot | Out-Null
    $miscBsa = Join-Path $DataRoot 'Fallout - Misc.bsa'
    foreach ($menuFile in @(
        'menus\options\main_menu.xml',
        'menus\options\load_menu.xml',
        'menus\main\inventory_menu.xml',
        'menus\main\stats_menu.xml',
        'menus\main\map_menu.xml',
        'menus\container_menu.xml',
        'menus\recipe_menu.xml'
    )) {
        & $BsaTool extract -f $miscBsa $menuFile $uiRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not extract authored UI document $menuFile" }
    }
    $uiAssetRoot = Join-Path $generated 'authored-ui-assets'
    New-Item -ItemType Directory -Force -Path $uiAssetRoot | Out-Null
    & $BsaTool extract -f (Join-Path $DataRoot 'Fallout - Textures2.bsa') `
        'textures\interface\shared\title.dds' $uiAssetRoot | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $uiAssetRoot 'textures\interface\shared\title.dds'))) {
        throw 'Could not extract the authored Fallout: New Vegas title texture'
    }
}

if (-not $SkipGodotImport) {
    if (-not (Test-Path -LiteralPath $Godot)) { throw "Godot executable missing: $Godot" }
    & $Godot --headless --path $projectRoot --editor --quit --log-file (Join-Path $generated 'godot-import.log')
    if ($LASTEXITCODE -ne 0) { throw "Godot import failed with exit code $LASTEXITCODE" }
}

[pscustomobject]@{
    schema = 'nikami-open-nv-godot-build/v1'
    status = 'ready'
    project = $projectRoot
    save = (Resolve-Path $SavePath).Path
    manifest = $manifest
    saveOverlay = Join-Path $saveOverlay 'index.json'
    intro = if ($SkipIntro) { $null } else { Join-Path $generated 'FNVIntro.ogv' }
    authoredUi = Join-Path $generated 'authored-ui'
} | ConvertTo-Json -Depth 5
