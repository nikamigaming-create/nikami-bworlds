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
        'viewing distance = 32768',
        'reverse z = false',
        'preload enabled = false',
        'preload exterior grid = false',
        'preload doors = true',
        'preload distance = 8192',
        'preload instances = false',
        'preload cell cache min = 8',
        'preload cell cache max = 24',
        'distant terrain = true',
        'lod factor = 1.0',
        'composite map resolution = 512',
        'object paging = true',
        'object paging active grid = false',
        'object paging min size = 0.01',
        'anisotropy = 8',
        'texture mipmap = linear',
        'antialiasing = 2',
        'vsync mode = 1',
        'framerate limit = 60',
        'force shaders = true',
        'apply lighting to environment maps = true',
        'adjust coverage for alpha test = false',
        'soft particles = false',
        'enable shadows = true',
        'number of shadow maps = 2',
        'shadow map resolution = 1024',
        'terrain shadows = false',
        'object shadows = true',
        'shader = true',
        'rtt size = 1024',
        'refraction = false',
        'reflection detail = 2',
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
Assert-Contract ([string]$fnvWorld.preset -eq 'fnv_balanced') `
    "Generated FNV profile does not select the balanced preset."
$fnv = $catalog.presets.$($fnvWorld.preset)
Assert-Contract ([int]$fnv.Camera.'viewing distance' -eq 32768) `
    "Generated FNV profile does not use the bounded view distance."
Assert-Contract (-not [bool]$fnv.Camera.'reverse z') `
    "Generated FNV profile unnecessarily enables reverse-Z."
Assert-Contract (-not [bool]$fnv.Cells.'preload enabled') `
    "Generated FNV profile enables expensive cell preloading."
Assert-Contract ([bool]$fnv.Terrain.'distant terrain') `
    "Generated FNV profile does not enable distant terrain."
Assert-Contract ([bool]$fnv.Terrain.'object paging') `
    "Generated FNV profile does not retain distant object scenery."
Assert-Contract (-not [bool]$fnv.Terrain.'object paging active grid') `
    "Generated FNV profile enables unsafe active-grid paging."
Assert-Contract ([double]$fnv.Terrain.'object paging min size' -eq 0.01) `
    "Generated FNV profile does not retain the bounded paging threshold."
Assert-Contract ([int]$fnv.General.anisotropy -eq 8) `
    "Generated FNV profile does not use balanced 8x anisotropy."
Assert-Contract ([int]$fnv.Video.antialiasing -eq 2) `
    "Generated FNV profile does not use balanced 2x antialiasing."
Assert-Contract ([int]$fnv.Video.'vsync mode' -eq 1 -and [int]$fnv.Video.'framerate limit' -eq 60) `
    "Generated FNV profile does not cap presentation at 60 FPS."
Assert-Contract ([bool]$fnv.Shadows.'enable shadows') `
    "Generated FNV profile does not enable shadows."
Assert-Contract ([bool]$fnv.Water.shader -and -not [bool]$fnv.Water.refraction) `
    "Generated FNV profile does not use balanced shader water without refraction."

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
