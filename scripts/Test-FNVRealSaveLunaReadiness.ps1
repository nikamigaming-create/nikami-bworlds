[CmdletBinding()]
param(
    [string]$WorldsRoot,
    [string]$EngineRoot = 'D:/code/nikami-openmw-save330-integrated',
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($WorldsRoot)) {
    $WorldsRoot = Split-Path -Parent $PSScriptRoot
}

function Resolve-RequiredPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Luna readiness failed: missing $Label at $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-RelativeCheck {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $absolute = Join-Path $Root $Path
    [ordered]@{
        path = $absolute.Replace('\\', '/')
        present = Test-Path -LiteralPath $absolute
    }
}

$worlds = Resolve-RequiredPath -Path $WorldsRoot -Label 'worlds repository'
$engine = Resolve-RequiredPath -Path $EngineRoot -Label 'engine repository'
$fixture = Resolve-RequiredPath -Path (Join-Path $worlds 'local/retail-real-save-fixtures/NikamiRealWorldSave330-20260802.fos') -Label 'immutable Save330 fixture'
$fixtureManifest = Resolve-RequiredPath -Path (Join-Path $worlds 'run/fnv-real-save-campaign/save330-fixture-manifest.json') -Label 'Save330 fixture manifest'
$profile = Resolve-RequiredPath -Path (Join-Path $worlds 'run/fnv-real-save-campaign/save330-official-profile-20260802') -Label 'official Save330 profile'
$runtime = Resolve-RequiredPath -Path (Join-Path $worlds 'local/openmw-real-save330-d01-inventory-20260802-191500/openmw.exe') -Label 'last passing OpenMW runtime'
$priorProof = Resolve-RequiredPath -Path (Join-Path $worlds 'run/opennv-pipboy-item-use-reload-gate-20260802-111500/openmw') -Label 'last passing Pip-Boy item proof'

$expectedSaveHash = '07DBDD2D7C4ABE3160628E5463A9603A40F4271042C1DA1B89F1C4A4F7DBD81F'
$expectedRuntimeHash = '840D4EC916FCDE22C9FDC7EEE33223EB300B0F9324F252634B6B476C6080A292'
$fixtureHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
$runtimeHash = (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash
if ($fixtureHash -ne $expectedSaveHash) {
    throw "Luna readiness failed: Save330 hash $fixtureHash does not match $expectedSaveHash"
}
if ($runtimeHash -ne $expectedRuntimeHash) {
    throw "Luna readiness failed: runtime hash $runtimeHash does not match $expectedRuntimeHash"
}

$worldFiles = @(
    'docs/fnv-real-save-pipboy-fast-travel-luna-max-plan.md',
    'docs/fnv-real-save-pipboy-fast-travel-progress.md',
    'docs/fnv-jam-background-capture.md',
    'catalog/fnv-jam-background-capture-recipes.json',
    'scripts/FNVSaveProfile.ps1',
    'scripts/Test-FNVSaveProfile.ps1',
    'scripts/Test-FNVJamBackgroundCapture.ps1',
    'scripts/Invoke-FNVJamBackgroundCapture.ps1',
    'scripts/Invoke-OpenNVPipBoyShowcaseCapture.ps1',
    'scripts/compare_fnv_paired_proofs.py',
    'scripts/render_fnv_retail_openmw_pair.py',
    'scripts/export_fnv_parity_corpus.py',
    'oracles/fnv_save330_visual/save330-player-payload-ledger.json'
)
$engineFiles = @(
    'components/esm4/fonvsavegame.cpp',
    'components/esm4/fonvsavegame.hpp',
    'apps/openmw/mwworld/fnvsavepreflight.cpp',
    'apps/openmw/mwworld/fnvplayerstate.cpp',
    'apps/openmw/mwworld/fnvplayerruntimestate.cpp',
    'apps/openmw/mwworld/fnvfasttravel.cpp',
    'apps/openmw/mwgui/mapwindow.cpp',
    'apps/openmw/mwgui/windowmanagerimp.cpp',
    'apps/openmw/mwmechanics/character.cpp',
    'apps/openmw/mwrender/renderingmanager.cpp',
    'apps/components_tests/esm4/fonvsavegame.cpp',
    'apps/openmw_tests/mwworld/testfnvsavepreflight.cpp',
    'apps/openmw_tests/mwworld/testfnvplayerstate.cpp',
    'apps/openmw_tests/mwworld/testfnvplayerruntimestate.cpp',
    'apps/openmw_tests/mwworld/testfnvfasttravel.cpp',
    'apps/openmw_tests/mwmechanics/testfalloutcombat.cpp'
)

$checks = @(
    $worldFiles | ForEach-Object { Get-RelativeCheck -Root $worlds -Path $_ }
    $engineFiles | ForEach-Object { Get-RelativeCheck -Root $engine -Path $_ }
)
$missing = @($checks | Where-Object { -not $_.present })
if ($missing.Count -ne 0) {
    throw "Luna readiness failed: $($missing.Count) required tool/source paths are missing"
}

& (Join-Path $worlds 'scripts/Test-FNVSaveProfile.ps1') | Out-Host
. (Join-Path $worlds 'scripts/FNVSaveProfile.ps1')
$saveMasters = @(Get-FNVSaveMasterNames -SavePath $fixture)
$profileContent = @(
    Get-Content -LiteralPath (Join-Path $profile 'openmw.cfg') -Encoding utf8 |
        Where-Object { $_ -match '^content=' } |
        ForEach-Object { $_.Substring('content='.Length) }
)
if ($saveMasters.Count -ne 10 -or $profileContent.Count -ne 10) {
    throw "Luna readiness failed: expected 10 Save330/profile masters, found $($saveMasters.Count)/$($profileContent.Count)"
}
for ($index = 0; $index -lt $saveMasters.Count; ++$index) {
    if ($saveMasters[$index] -cne $profileContent[$index]) {
        throw "Luna readiness failed: master order mismatch at $index ($($saveMasters[$index]) != $($profileContent[$index]))"
    }
}

$report = [ordered]@{
    schema = 'nikami-fnv-luna-readiness/v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    status = 'pass'
    currentBite = 'D02'
    worldsRoot = $worlds.Replace('\\', '/')
    engineRoot = $engine.Replace('\\', '/')
    immutableSave = [ordered]@{
        path = $fixture.Replace('\\', '/')
        bytes = (Get-Item -LiteralPath $fixture).Length
        sha256 = $fixtureHash
        manifest = $fixtureManifest.Replace('\\', '/')
    }
    officialProfile = $profile.Replace('\\', '/')
    officialMasterOrder = $saveMasters
    promotedDiagnosticRuntime = [ordered]@{
        path = $runtime.Replace('\\', '/')
        sha256 = $runtimeHash
        scope = 'Retained passing Save330 D01 inventory runtime; this readiness check does not promote it as the current visual/animation acceptance runtime.'
    }
    priorPassingProof = $priorProof.Replace('\\', '/')
    requiredPathChecks = $checks
    nextAction = 'D02 remains in progress: correct the production first-person Pip-Boy hand bind, placement, and contact animation before returning to the full Save330 weapon-selection matrix.'
    captureAuthority = 'scripts/Invoke-FNVJamBackgroundCapture.ps1 only, after mandatory preflight; no foreground input or concurrent engines'
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $worlds 'run/fnv-real-save-campaign/luna-readiness.json'
}
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$report | ConvertTo-Json -Depth 8
