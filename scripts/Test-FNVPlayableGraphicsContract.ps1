param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$settingsPath = Join-Path $repoRoot "config\fnv-playable-graphics\settings.cfg"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}

Assert-Contract (Test-Path -LiteralPath $settingsPath -PathType Leaf) `
    "FNV playable graphics settings are missing."
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw
    foreach ($required in @(
        'viewing distance = 196608',
        'reverse z = true',
        'preload enabled = true',
        'preload exterior grid = true',
        'preload doors = true',
        'preload distance = 32768',
        'preload instances = true',
        'preload cell cache min = 24',
        'preload cell cache max = 64',
        'distant terrain = true',
        'lod factor = 1.0',
        'composite map resolution = 1024',
        'object paging = true',
        'object paging active grid = false',
        'object paging min size = 0.005',
        'anisotropy = 16',
        'texture mipmap = linear',
        'antialiasing = 4',
        'force shaders = true',
        'apply lighting to environment maps = true',
        'soft particles = true',
        'enable shadows = true',
        'number of shadow maps = 4',
        'shadow map resolution = 2048',
        'terrain shadows = true',
        'object shadows = true',
        'shader = true',
        'rtt size = 2048',
        'refraction = true',
        'reflection detail = 4',
        'sunlight scattering = true'
    )) {
        Assert-Contract ($settings.Contains($required)) "FNV playable graphics setting is missing: $required"
    }
    Assert-Contract (-not $settings.Contains('[Fog]')) `
        "FNV playable graphics layer must not opt into Morrowind-derived distant fog."
}

$catalog = Get-Content -LiteralPath (Join-Path $repoRoot "catalog\world-settings-presets.json") -Raw |
    ConvertFrom-Json
$fnvWorld = $catalog.worlds.fallout_new_vegas
Assert-Contract ([string]$fnvWorld.preset -eq 'fnv_max_quality') `
    "Generated FNV profile does not select the maximum-quality preset."
$fnv = $catalog.presets.$($fnvWorld.preset)
Assert-Contract ([int]$fnv.Camera.'viewing distance' -eq 196608) `
    "Generated FNV profile does not use the maximum view distance."
Assert-Contract ([bool]$fnv.Camera.'reverse z') `
    "Generated FNV profile does not enable reverse-Z for its long view distance."
Assert-Contract ([bool]$fnv.Cells.'preload enabled') `
    "Generated FNV profile does not enable cell preloading."
Assert-Contract ([bool]$fnv.Terrain.'distant terrain') `
    "Generated FNV profile does not enable distant terrain."
Assert-Contract ([bool]$fnv.Terrain.'object paging') `
    "Generated FNV profile does not enable object paging."
Assert-Contract (-not [bool]$fnv.Terrain.'object paging active grid') `
    "Generated FNV profile enables unsafe active-grid paging."
Assert-Contract ([double]$fnv.Terrain.'object paging min size' -eq 0.005) `
    "Generated FNV profile does not use the safe object paging minimum size."
Assert-Contract ([int]$fnv.General.anisotropy -eq 16) `
    "Generated FNV profile does not use 16x anisotropy."
Assert-Contract ([int]$fnv.Video.antialiasing -eq 4) `
    "Generated FNV profile does not use 4x antialiasing."
Assert-Contract ([bool]$fnv.Shadows.'enable shadows') `
    "Generated FNV profile does not enable shadows."
Assert-Contract ([bool]$fnv.Water.shader -and [bool]$fnv.Water.refraction) `
    "Generated FNV profile does not enable shader water and refraction."

$baseline = Get-Content -LiteralPath (Join-Path $repoRoot "config\playable-baseline\settings.cfg") -Raw
foreach ($bounded in @(
    'viewing distance = 16384',
    'distant terrain = false',
    'object paging = false',
    'object paging active grid = false',
    'object paging min size = 0.1'
)) {
    Assert-Contract ($baseline.Contains($bounded)) "Shared bounded baseline changed unexpectedly: $bounded"
}

$launchers = @(
    "Invoke-PlayableSessionBaseline.ps1",
    "Invoke-FNVInteractionAudit.ps1",
    "Start-FalloutVRWalkaround.ps1"
)
foreach ($launcher in $launchers) {
    $path = Join-Path $PSScriptRoot $launcher
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Contract ($parseErrors.Count -eq 0) "$launcher does not parse."
    $source = Get-Content -LiteralPath $path -Raw
    Assert-Contract ($source.Contains('config/fnv-playable-graphics')) `
        "$launcher does not reference the FNV playable graphics layer."
}

if ($failures.Count -gt 0) {
    Write-Host "FNV playable graphics contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host "FNV playable graphics contract passed."
