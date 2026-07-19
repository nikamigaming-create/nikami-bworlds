param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$settingsPath = Join-Path $repoRoot "config\fnv-playable-graphics\settings.cfg"
$failures = New-Object System.Collections.Generic.List[string]

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

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
        'viewing distance = 10000',
        'reverse z = false',
        'preload enabled = false',
        'preload num threads = 2',
        'preload exterior grid = false',
        'preload fast travel = false',
        'preload doors = true',
        'preload distance = 8192',
        'preload instances = false',
        'preload cell cache min = 8',
        'preload cell cache max = 24',
        'preload cell expiry delay = 10',
        'prediction time = 1',
        'cache expiry delay = 30',
        'target framerate = 60',
        'pointers cache size = 100',
        'distant terrain = false',
        'lod factor = 1.0',
        'composite map resolution = 512',
        'object paging = false',
        'object paging active grid = false',
        'object paging min size = 0.01',
        'load unsupported nif files = true',
        'anisotropy = 8',
        'texture mipmap = linear',
        'antialiasing = 2',
        'vsync mode = 1',
        'framerate limit = 60',
        'force shaders = false',
        'apply lighting to environment maps = false',
        'adjust coverage for alpha test = false',
        'soft particles = false',
        'enable shadows = false',
        'number of shadow maps = 2',
        'shadow map resolution = 1024',
        'terrain shadows = false',
        'object shadows = false',
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
    foreach ($quarantinedSkyModel in @('skyatmosphere', 'skyclouds', 'skynight01', 'skynight02')) {
        Assert-Contract (-not $settings.Contains($quarantinedSkyModel)) `
            "FNV renderer boundary contains quarantined sky-model override: $quarantinedSkyModel"
    }
}

$catalog = Get-Content -LiteralPath (Join-Path $repoRoot "catalog\world-settings-presets.json") -Raw |
    ConvertFrom-Json
$fnvWorld = $catalog.worlds.fallout_new_vegas
Assert-Contract ([string]$fnvWorld.preset -eq 'fnv_balanced') `
    "Generated FNV profile does not select the balanced preset."
$fnv = $catalog.presets.$($fnvWorld.preset)
Assert-Contract ([int]$fnv.Camera.'viewing distance' -eq 10000) `
    "Generated FNV profile does not use the last-known-working view distance."
Assert-Contract (-not [bool]$fnv.Camera.'reverse z') `
    "Generated FNV profile unnecessarily enables reverse-Z."
Assert-Contract (-not [bool]$fnv.Cells.'preload enabled') `
    "Generated FNV profile enables expensive cell preloading."
Assert-Contract ([int]$fnv.Cells.'preload num threads' -eq 2 -and
    -not [bool]$fnv.Cells.'preload exterior grid' -and
    [bool]$fnv.Cells.'preload doors' -and
    -not [bool]$fnv.Cells.'preload instances' -and
    [int]$fnv.Cells.'preload distance' -eq 8192) `
    "Generated FNV profile changed the independent cell-preload boundary."
Assert-Contract (-not [bool]$fnv.Terrain.'distant terrain') `
    "Generated FNV profile enables quarantined distant terrain."
Assert-Contract (-not [bool]$fnv.Terrain.'object paging') `
    "Generated FNV profile enables quarantined object paging."
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
Assert-Contract (-not [bool]$fnv.Shaders.'force shaders') `
    "Generated FNV profile enables quarantined forced shaders."
Assert-Contract (-not [bool]$fnv.Shaders.'apply lighting to environment maps') `
    "Generated FNV profile enables quarantined environment-map lighting."
Assert-Contract (-not [bool]$fnv.Shadows.'enable shadows') `
    "Generated FNV profile enables quarantined shadows."
Assert-Contract ([bool]$fnv.Models.'load unsupported nif files') `
    "Generated FNV profile disables required Bethesda NIF compatibility."
foreach ($quarantinedSkyModel in @('skyatmosphere', 'skyclouds', 'skynight01', 'skynight02')) {
    Assert-Contract (-not ($fnv.Models.PSObject.Properties.Name -contains $quarantinedSkyModel)) `
        "Generated FNV profile contains quarantined sky-model override: $quarantinedSkyModel"
}
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

$expectedRuntime = [IO.Path]::GetFullPath((Join-Path $repoRoot "local\openmw-pristine-mads-33568a"))
Assert-Contract (([IO.Path]::GetFullPath((Get-NikamiOpenMWRuntimeRoot))) -ieq $expectedRuntime) `
    "Default runtime is not locked to the pristine Mads package."
Assert-Contract (([IO.Path]::GetFullPath((Get-NikamiOpenMWResourcesRoot))) -ieq (Join-Path $expectedRuntime "resources")) `
    "Default resources are not locked to the pristine Mads package."
$resolvedCurrentRuntime = $null
$resolvedCurrentResources = $null
try {
    $resolvedCurrentRuntime = Resolve-NikamiOpenMWRuntimeRoot -RequireCurrent
    $resolvedCurrentResources = Resolve-NikamiOpenMWResourcesRoot -RequireCurrent
}
catch {
    Assert-Contract $false "Locked current runtime is not a complete package: $($_.Exception.Message)"
}
Assert-Contract ($null -ne $resolvedCurrentRuntime -and
    ([IO.Path]::GetFullPath($resolvedCurrentRuntime)) -ieq $expectedRuntime) `
    "Current-runtime resolver did not return the locked pristine Mads package."
Assert-Contract ($null -ne $resolvedCurrentResources -and
    ([IO.Path]::GetFullPath($resolvedCurrentResources)) -ieq (Join-Path $expectedRuntime "resources")) `
    "Current-resources resolver did not return the locked pristine Mads package."

foreach ($obsolete in @("openmw-fo4guard", "openmw-clean-recovery-6a5576")) {
    $rejected = $false
    try {
        Resolve-NikamiOpenMWRuntimeRoot -ParameterValue "local/$obsolete" | Out-Null
    }
    catch {
        $rejected = $_.Exception.Message -like "Rejected obsolete OpenMW runtime*"
    }
    Assert-Contract $rejected "Obsolete runtime is not rejected: $obsolete"
}

foreach ($ordinaryLauncher in @(
        "Start-FalloutWalkaround.ps1",
        "Start-WorldProfileExisting.ps1",
        "Start-FalloutVRWalkaround.ps1",
        "Start-FNVParityVRExisting.ps1"
    )) {
    $launcherSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot $ordinaryLauncher) -Raw
    Assert-Contract ($launcherSource.Contains("-RequireCurrent")) `
        "$ordinaryLauncher does not require the locked current runtime."
}

$parityProfileSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "New-FNVParityProfile.ps1") -Raw
Assert-Contract ($parityProfileSource.Contains('[string]$BinaryRoot = "local/openmw-pristine-mads-33568a"')) `
    "FNV parity profile generator still defaults to an obsolete runtime."

$recoveryGeneratorPath = Join-Path $PSScriptRoot "New-FNVCleanRecoveryProfile.ps1"
if (Test-Path -LiteralPath $recoveryGeneratorPath -PathType Leaf) {
    $recoveryGeneratorSource = Get-Content -LiteralPath $recoveryGeneratorPath -Raw
    Assert-Contract ($recoveryGeneratorSource.Contains('[string]$BinaryRoot = "local/openmw-pristine-mads-33568a"')) `
        "Recovery profile generator still defaults to an obsolete runtime."
    Assert-Contract ($recoveryGeneratorSource.Contains(') -icontains $key')) `
        "Recovery profile generator does not quarantine source sky-model overrides."
    Assert-Contract ($recoveryGeneratorSource.Contains('quarantinedSkyModelOverrides')) `
        "Recovery profile manifest does not account for quarantined sky-model overrides."
    foreach ($quarantinedSkyModel in @('skyatmosphere', 'skyclouds', 'skynight01', 'skynight02')) {
        Assert-Contract ($recoveryGeneratorSource.Contains('"' + $quarantinedSkyModel + '"')) `
            "Recovery profile generator does not name quarantined sky-model override: $quarantinedSkyModel"
    }
}

if ($failures.Count -gt 0) {
    Write-Host "FNV playable graphics contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host "FNV playable graphics contract passed."
