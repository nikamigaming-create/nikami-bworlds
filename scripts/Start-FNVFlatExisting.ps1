param(
    [switch]$DryRun,
    [switch]$Wait,
    [switch]$AllowDuplicate,
    [switch]$Menu,
    [string]$LoadSavegame = "",
    [string]$SaveDirectory = "",
    [string]$BinaryRoot = "",
    [ValidateRange(0.1, 10.0)]
    [double]$PlayerSpeedMultiplier = 1.0,
    [switch]$PreferUsable10mm,
    [switch]$UnlockAllMapMarkers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

$repoRoot = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $PSScriptRoot "Start-WorldProfileExisting.ps1"
$seedPath = Join-Path $repoRoot "catalog\world-walker.seed.json"

if ($Menu -and -not [string]::IsNullOrWhiteSpace($LoadSavegame)) {
    throw "-Menu and -LoadSavegame are mutually exclusive."
}

if (-not $Menu -and [string]::IsNullOrWhiteSpace($LoadSavegame)) {
    if ([string]::IsNullOrWhiteSpace($SaveDirectory)) {
        $SaveDirectory = Resolve-NikamiPath `
            -EnvName "NIKAMI_FNV_SAVE_DIRECTORY" `
            -ConfigName "fnvSaveDirectory"
    }
    if ([string]::IsNullOrWhiteSpace($SaveDirectory)) {
        $documentRoots = @(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments),
            $(if ([string]::IsNullOrWhiteSpace($env:OneDrive)) { $null } else { Join-Path $env:OneDrive "Documents" })
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $detectedSaveDirectory = $documentRoots | ForEach-Object { Join-Path $_ "My Games\FalloutNV\Saves" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
            Select-Object -First 1
        if ($null -ne $detectedSaveDirectory) {
            $SaveDirectory = [string]$detectedSaveDirectory
        }
    }
    if (-not (Test-Path -LiteralPath $SaveDirectory -PathType Container)) {
        throw "FNV save directory does not exist: $SaveDirectory. Pass -LoadSavegame or -Menu."
    }

    $latest = Get-ChildItem -LiteralPath $SaveDirectory -Filter "*.fos" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        throw "No native FNV .fos saves were found in $SaveDirectory. Pass -Menu to start without a save."
    }
    $LoadSavegame = $latest.FullName
}

$parameters = @{
    WorldId = "fallout_new_vegas"
    Mode = "flat"
    SeedPath = $seedPath
    FnvPlayerSpeedMultiplier = $PlayerSpeedMultiplier
}
if ($DryRun) { $parameters.DryRun = $true }
if ($Wait) { $parameters.Wait = $true }
if ($AllowDuplicate) { $parameters.AllowDuplicate = $true }
if ($PreferUsable10mm) { $parameters.FnvPreferUsable10mm = $true }
if ($UnlockAllMapMarkers) { $parameters.FnvUnlockAllMapMarkers = $true }
if (-not [string]::IsNullOrWhiteSpace($BinaryRoot)) { $parameters.BinaryRoot = $BinaryRoot }
if (-not [string]::IsNullOrWhiteSpace($LoadSavegame)) {
    $parameters.SkipMenu = $true
    $parameters.LoadSavegame = $LoadSavegame
}

Write-Host "FNV Flat launch: normal runtime, no proof injection and no rebuild."
if ($Menu) {
    Write-Host "Start: native menu"
}
else {
    Write-Host "Start: $([IO.Path]::GetFullPath($LoadSavegame))"
}

& $launcher @parameters
$launchSucceeded = $?
$nativeExitCode = Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
if ($null -ne $nativeExitCode) {
    exit [int]$nativeExitCode
}
exit $(if ($launchSucceeded) { 0 } else { 1 })
