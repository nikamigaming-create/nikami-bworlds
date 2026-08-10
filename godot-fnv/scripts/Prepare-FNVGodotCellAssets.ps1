[CmdletBinding()]
param(
    [string]$DataRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data',
    [string]$BsaTool = 'D:\code\nikami-worlds\local\build\openmw-051-full-port-noqt\RelWithDebInfo\bsatool.exe',
    [string]$NifTest = 'D:\code\nikami-worlds\local\build\openmw-051-full-port-noqt\RelWithDebInfo\niftest.exe',
    [int]$Radius = 2,
    [int]$Limit = 0,
    [string]$Godot = 'D:\code\gd\Godot_v4.6.3-stable_win64_console.exe',
    [string]$RingPath = '',
    [string]$AssetInventoryPath = '',
    [switch]$AllModels,
    [switch]$SkipGodotImport,
    [switch]$SkipTerrainBake,
    [switch]$Refresh,
    [int]$ShardCount = 1,
    [int]$ShardIndex = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ringPath = if ([string]::IsNullOrWhiteSpace($RingPath)) {
    Join-Path $projectRoot 'generated\world\cell-ring.json'
} elseif ([IO.Path]::IsPathRooted($RingPath)) {
    [IO.Path]::GetFullPath($RingPath)
} else {
    [IO.Path]::GetFullPath((Join-Path $projectRoot $RingPath))
}
$nativeRoot = Join-Path $projectRoot 'generated\assets\native'
$convertedRoot = Join-Path $projectRoot 'generated\assets\converted'
$meshesBsa = Join-Path $DataRoot 'Fallout - Meshes.bsa'
$soundBsa = Join-Path $DataRoot 'Fallout - Sound.bsa'
$mainArchives = @(
    'GunRunnersArsenal - Main.bsa',
    'CaravanPack - Main.bsa',
    'ClassicPack - Main.bsa',
    'MercenaryPack - Main.bsa',
    'TribalPack - Main.bsa',
    'LonesomeRoad - Main.bsa',
    'OldWorldBlues - Main.bsa',
    'HonestHearts - Main.bsa',
    'DeadMoney - Main.bsa',
    'Update.bsa'
) | ForEach-Object { Join-Path $DataRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
$meshArchives = @($mainArchives) + @($meshesBsa)
$textureArchives = @(
    $mainArchives
    (Join-Path $DataRoot 'Fallout - Textures.bsa'),
    (Join-Path $DataRoot 'Fallout - Textures2.bsa')
)
$textureAliases = @{
    'textures\nvdlc01\effects\fwspark.dds' = 'textures\nvdlc01\effects\fireworks\nvdlc01fwspark.dds'
}
if ($ShardCount -lt 1 -or $ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount) {
    throw "Invalid model shard $ShardIndex/$ShardCount"
}

function Invoke-LockedTextureExtract([string]$RelativePath, [string]$TargetPath) {
    $mutex = [Threading.Mutex]::new($false, 'Global\OpenNVGodotTextureExtract')
    try {
        $null = $mutex.WaitOne()
        if (Test-Path -LiteralPath $TargetPath) { return }
        foreach ($archive in $textureArchives) {
            & $BsaTool extract -f $archive $RelativePath $convertedRoot | Out-Null
            if (Test-Path -LiteralPath $TargetPath) { break }
        }
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Repair-MissingMaterialTextures([string]$MaterialPath) {
    if (-not (Test-Path -LiteralPath $MaterialPath -PathType Leaf)) { return }
    $materialDirectory = Split-Path -Parent $MaterialPath
    $rewritten = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $MaterialPath) {
        if ($line -match '^map_Kd\s+(.+)$') {
            $candidate = [IO.Path]::GetFullPath((Join-Path $materialDirectory $Matches[1]))
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                Write-Warning "Omitting unresolved texture map from $MaterialPath`: $($Matches[1])"
                continue
            }
        }
        $rewritten.Add($line)
    }
    Set-Content -LiteralPath $MaterialPath -Value $rewritten -Encoding utf8
}

foreach ($terrainTexture in @(
    'textures\landscape\dirtwasteland01.dds',
    'textures\landscape\dirtwasteland01_n.dds'
)) {
    $terrainTarget = Join-Path $convertedRoot $terrainTexture
    if (-not (Test-Path -LiteralPath $terrainTarget)) {
        foreach ($archive in $textureArchives) {
            & $BsaTool extract -f $archive $terrainTexture $convertedRoot | Out-Null
            if (Test-Path -LiteralPath $terrainTarget) { break }
        }
    }
}

foreach ($sound in @(
    'sound\fx\amb\amb_desertdefault\beds\amb_desertdaybed_lp.ogg',
    'sound\fx\amb\amb_desertdefault\wind\mellow\amb_windgust_mellow_01.ogg',
    'sound\fx\amb\amb_desertdefault\birds\a\sfx_desert_bird-a_os_01.ogg',
    'sound\fx\obj\vegasdoor\sfx_vegasdoor_open.wav'
)) {
    $soundTarget = Join-Path $convertedRoot $sound
    if (-not (Test-Path -LiteralPath $soundTarget)) {
        & $BsaTool extract -f $soundBsa $sound $convertedRoot | Out-Null
    }
}

foreach ($required in @($ringPath, $BsaTool) + $meshArchives) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required authored-cell input missing: $required" }
}

$inventoryPath = if (-not [string]::IsNullOrWhiteSpace($AssetInventoryPath)) {
    if ([IO.Path]::IsPathRooted($AssetInventoryPath)) { [IO.Path]::GetFullPath($AssetInventoryPath) }
    else { [IO.Path]::GetFullPath((Join-Path $projectRoot $AssetInventoryPath)) }
} else {
    Join-Path $projectRoot ("generated\assets\cell-asset-inventory-{0:d2}-of-{1:d2}.json" -f $ShardIndex, $ShardCount)
}
if ([string]::IsNullOrWhiteSpace($AssetInventoryPath)) {
    $inventoryArgs = @(
        (Join-Path $projectRoot 'tools\collect_fnv_cell_assets.py'),
        '--ring', $ringPath, '--output', $inventoryPath, '--radius', $Radius
    )
    if ($AllModels) { $inventoryArgs += '--all-models' }
    & python @inventoryArgs
    if ($LASTEXITCODE -ne 0) { throw 'Authored cell asset inventory compilation failed' }
}
if (-not (Test-Path -LiteralPath $inventoryPath)) { throw "Authored cell asset inventory missing: $inventoryPath" }
$assetInventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
$landTextures = @($assetInventory.landTextures)
foreach ($terrainTexture in $landTextures) {
    $terrainTarget = Join-Path $convertedRoot $terrainTexture
    if (Test-Path -LiteralPath $terrainTarget) { continue }
    Invoke-LockedTextureExtract $terrainTexture $terrainTarget
}
if ($ShardIndex -eq 0 -and -not $SkipTerrainBake) {
    python (Join-Path $projectRoot 'tools\bake_fnv_land_albedo.py') `
        --ring $ringPath --texture-root $convertedRoot `
        --output (Join-Path $convertedRoot 'terrain-albedo') --radius $Radius --route-detail
    if ($LASTEXITCODE -ne 0) { throw 'Authored LAND albedo baking failed' }
}
$models = @($assetInventory.models)
$models = @(for ($modelIndex = 0; $modelIndex -lt $models.Count; ++$modelIndex) {
    if (($modelIndex % $ShardCount) -eq $ShardIndex) { $models[$modelIndex] }
})
if ($Limit -gt 0) { $models = @($models | Select-Object -First $Limit) }

$converted = 0
$skipped = 0
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($model in $models) {
    $sourceRelative = 'meshes\' + ([string]$model).Replace('/', '\').TrimStart('\')
    $nativePath = Join-Path $nativeRoot $sourceRelative
    $objRelative = [IO.Path]::ChangeExtension(([string]$model).Replace('\', '/'), '.obj')
    $objPath = Join-Path $convertedRoot $objRelative
    $dependenciesPath = $objPath + '.textures.json'
    $metadataCurrent = $false
    if (Test-Path -LiteralPath $dependenciesPath -PathType Leaf) {
        $existingDependencies = Get-Content -Raw -LiteralPath $dependenciesPath | ConvertFrom-Json
        $metadataCurrent = $null -ne $existingDependencies.PSObject.Properties['render_surfaces'] -and
            $null -ne $existingDependencies.PSObject.Properties['collision_surfaces'] -and
            $null -ne $existingDependencies.PSObject.Properties['two_sided_surfaces'] -and
            $null -ne $existingDependencies.PSObject.Properties['collision_mode'] -and
            [string]$existingDependencies.collision_mode -eq 'openmw-bsx-render-geometry-v1'
    }
    if ((Test-Path -LiteralPath $objPath) -and $metadataCurrent -and -not $Refresh) { $skipped++; continue }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nativePath) | Out-Null
    foreach ($archive in $meshArchives) {
        & $BsaTool extract -f $archive $sourceRelative $nativeRoot | Out-Null
        if (Test-Path -LiteralPath $nativePath) { break }
    }
    if (-not (Test-Path -LiteralPath $nativePath)) {
        $failed.Add($sourceRelative); continue
    }
    $priorErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $conversionOutput = & python (Join-Path $projectRoot 'tools\convert_fnv_nif_to_obj.py') --input $nativePath --output $objPath `
        --texture-root $convertedRoot --dependencies-output $dependenciesPath 2>&1
    $conversionExitCode = $LASTEXITCODE
    $ErrorActionPreference = $priorErrorActionPreference
    $conversionOutput | ForEach-Object { Write-Host $_ }
    $conversionText = $conversionOutput | Out-String
    if ($conversionExitCode -ne 0 -and (Test-Path -LiteralPath $NifTest) -and
        $conversionText -match 'unpack requires|Reading <struct|failed to read|unsupported') {
        $ErrorActionPreference = 'Continue'
        $fallbackOutput = & python (Join-Path $projectRoot 'tools\convert_openmw_geometry_dump_to_obj.py') `
            --niftest $NifTest --input $nativePath --output $objPath `
            --texture-root $convertedRoot --dependencies-output $dependenciesPath 2>&1
        $conversionExitCode = $LASTEXITCODE
        $ErrorActionPreference = $priorErrorActionPreference
        $fallbackOutput | ForEach-Object { Write-Host $_ }
    }
    if ($conversionExitCode -eq 0 -and (Test-Path -LiteralPath $objPath)) {
        $converted++
        $dependencies = Get-Content -Raw -LiteralPath $dependenciesPath | ConvertFrom-Json
        foreach ($texture in @($dependencies.textures)) {
            $texturePath = Join-Path $convertedRoot ([string]$texture)
            if (Test-Path -LiteralPath $texturePath) { continue }
            Invoke-LockedTextureExtract ([string]$texture) $texturePath
            $canonicalTexture = ([string]$texture).Replace('/', '\').ToLowerInvariant()
            if (-not (Test-Path -LiteralPath $texturePath) -and $textureAliases.ContainsKey($canonicalTexture)) {
                $aliasRelative = [string]$textureAliases[$canonicalTexture]
                $aliasPath = Join-Path $convertedRoot $aliasRelative
                Invoke-LockedTextureExtract $aliasRelative $aliasPath
                if (Test-Path -LiteralPath $aliasPath) {
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $texturePath) | Out-Null
                    Copy-Item -LiteralPath $aliasPath -Destination $texturePath
                }
            }
        }
        Repair-MissingMaterialTextures ([IO.Path]::ChangeExtension($objPath, '.mtl'))
    } else { $failed.Add($sourceRelative) }
}

if (-not $SkipGodotImport) {
    & $Godot --headless --path $projectRoot --editor --quit --log-file (Join-Path $projectRoot 'generated\godot-cell-import.log')
    if ($LASTEXITCODE -ne 0) { throw "Godot authored-cell import failed with exit code $LASTEXITCODE" }
}

[pscustomobject]@{
    schema = 'nikami-open-nv-godot-cell-assets/v1'
    radius = $Radius
    shardCount = $ShardCount
    shardIndex = $ShardIndex
    requested = $models.Count
    converted = $converted
    cached = $skipped
    failed = @($failed)
} | ConvertTo-Json -Depth 4
