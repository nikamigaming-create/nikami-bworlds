param(
    [string]$Fallout3Data = "",
    [string]$ProfileDirectory = "",
    [string]$CampaignUserdataDirectory = "",
    [string]$BinaryRoot = "",
    [ValidateSet("Auto", "RequireAll")]
    [string]$DlcPolicy = "Auto",
    [switch]$DryRun,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

$repoRoot = Split-Path -Parent $PSScriptRoot
$baseContent = @("Fallout3.esm")
$baseArchives = @(
    "Fallout - Meshes.bsa", "Fallout - Misc.bsa", "Fallout - Sound.bsa",
    "Fallout - Textures.bsa", "Fallout - Voices.bsa", "Fallout - MenuVoices.bsa"
)
$optionalDlc = @(
    [pscustomobject]@{ Name = "Operation: Anchorage"; Master = "Anchorage.esm"; Archives = @("Anchorage - Main.bsa", "Anchorage - Sounds.bsa") },
    [pscustomobject]@{ Name = "The Pitt"; Master = "ThePitt.esm"; Archives = @("ThePitt - Main.bsa", "ThePitt - Sounds.bsa") },
    [pscustomobject]@{ Name = "Broken Steel"; Master = "BrokenSteel.esm"; Archives = @("BrokenSteel - Main.bsa", "BrokenSteel - Sounds.bsa") },
    [pscustomobject]@{ Name = "Point Lookout"; Master = "PointLookout.esm"; Archives = @("PointLookout - Main.bsa", "PointLookout - Sounds.bsa") },
    [pscustomobject]@{ Name = "Mothership Zeta"; Master = "Zeta.esm"; Archives = @("Zeta - Main.bsa", "Zeta - Sounds.bsa") }
)

function Resolve-ExistingDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Missing ${Description}: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Parent
    )

    $pathFull = [IO.Path]::GetFullPath($Path)
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return $pathFull.StartsWith($parentFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-OpenMWPath {
    param([Parameter(Mandatory=$true)][string]$Path)

    return ([IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

function Assert-File {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing ${Description}: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Write-ProfileTextFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Description,
        [switch]$AllowReplace,
        [switch]$PreviewOnly
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $current = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
        $expected = $Text -replace "`r`n", "`n"
        if ($current -ceq $expected) {
            return "unchanged"
        }
        if (-not $AllowReplace) {
            throw "Existing $Description differs from the generated OpenNV profile. Refusing to overwrite $Path; pass -Force only if this profile is disposable."
        }
    }

    if ($PreviewOnly) {
        Write-Host "Would write ${Description}: $Path"
        return "preview"
    }

    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
    return "written"
}

function Ensure-ProfileTemplateFile {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [switch]$PreviewOnly
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        return
    }
    if ($PreviewOnly) {
        Write-Host "Would create profile template: $Destination"
        return
    }
    [IO.File]::WriteAllText($Destination, [IO.File]::ReadAllText($Source), [Text.UTF8Encoding]::new($false))
}

$Fallout3Data = Resolve-NikamiPath `
    -ParameterValue $Fallout3Data `
    -EnvName "NIKAMI_FALLOUT3_DATA" `
    -ConfigName "fallout3Data" `
    -Fallback "D:/SteamLibrary/steamapps/common/Fallout 3 goty/Data" `
    -Required `
    -Description "Fallout 3 Data directory"
$Fallout3Data = Resolve-ExistingDirectory -Path (Resolve-NikamiRepoRelativePath -Path $Fallout3Data) -Description "Fallout 3 Data directory"
Assert-File -Path (Join-Path $Fallout3Data "Fallout3.esm") -Description "Fallout 3 master" | Out-Null
foreach ($archive in $baseArchives) {
    Assert-File -Path (Join-Path $Fallout3Data $archive) -Description "Fallout 3 base archive" | Out-Null
}

$availableDlc = [Collections.Generic.List[object]]::new()
$missingDlc = [Collections.Generic.List[object]]::new()
foreach ($dlc in $optionalDlc) {
    $expectedFiles = @($dlc.Master) + @($dlc.Archives)
    $presentFiles = @($expectedFiles | Where-Object {
        Test-Path -LiteralPath (Join-Path $Fallout3Data $_) -PathType Leaf
    })
    if ($presentFiles.Count -eq $expectedFiles.Count) {
        $availableDlc.Add($dlc)
    }
    elseif ($presentFiles.Count -eq 0) {
        $missingDlc.Add($dlc)
    }
    else {
        $missingFiles = @($expectedFiles | Where-Object { $_ -notin $presentFiles })
        throw "Fallout 3 add-on '$($dlc.Name)' is only partly installed. Missing: $($missingFiles -join ', '). Verify or reinstall that add-on before launching it."
    }
}
if ($DlcPolicy -eq "RequireAll" -and $missingDlc.Count -gt 0) {
    throw "This profile was asked to require all Fallout 3 DLC, but these are unavailable: $($missingDlc.Name -join ', '). Use -DlcPolicy Auto for an ownership-aware standalone profile."
}

$activeContent = [Collections.Generic.List[string]]::new()
$activeArchives = [Collections.Generic.List[string]]::new()
foreach ($entry in $baseContent) { $activeContent.Add($entry) }
foreach ($archive in $baseArchives) { $activeArchives.Add($archive) }
foreach ($dlc in $availableDlc) {
    $activeContent.Add($dlc.Master)
    foreach ($archive in $dlc.Archives) { $activeArchives.Add($archive) }
}

if ([string]::IsNullOrWhiteSpace($ProfileDirectory)) {
    $ProfileDirectory = Join-Path $repoRoot "profiles/open_fo3_vanilla"
}
$ProfileDirectory = Resolve-NikamiRepoRelativePath -Path $ProfileDirectory
$profilesRoot = Join-Path $repoRoot "profiles"
if (-not (Test-PathWithin -Path $ProfileDirectory -Parent $profilesRoot)) {
    throw "OpenFO3 profile must remain under $profilesRoot. Requested: $ProfileDirectory"
}
if ([string]::IsNullOrWhiteSpace($CampaignUserdataDirectory)) {
    $CampaignUserdataDirectory = Join-Path $profilesRoot "_campaigns/fallout3/userdata"
}
$CampaignUserdataDirectory = Resolve-NikamiRepoRelativePath -Path $CampaignUserdataDirectory
if (-not (Test-PathWithin -Path $CampaignUserdataDirectory -Parent $profilesRoot)) {
    throw "OpenFO3 campaign userdata must remain under $profilesRoot. Requested: $CampaignUserdataDirectory"
}

if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    $BinaryRoot = Join-Path $repoRoot "local/openmw-ttw-compat"
}
$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$ResourcesRoot = Resolve-NikamiOpenMWResourcesRoot -ParameterValue (Join-Path $BinaryRoot "resources")

$userdataDirectory = $CampaignUserdataDirectory
$userdataDataDirectory = Join-Path $ProfileDirectory "userdata/data"
$openmwConfigPath = Join-Path $ProfileDirectory "openmw.cfg"
$manifestPath = Join-Path $ProfileDirectory "open-fo3-profile.json"
$settingsPath = Join-Path $ProfileDirectory "settings.cfg"
$inputPath = Join-Path $ProfileDirectory "input_v3.xml"

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("# Generated by Initialize-OpenFO3BaseProfile.ps1.")
$lines.Add("# Fallout 3 source contents and directory entries remain untouched.")
$lines.Add("replace=data")
$lines.Add("replace=data-local")
$lines.Add("replace=fallback-archive")
$lines.Add("replace=content")
$lines.Add("")
$lines.Add("user-data=$(ConvertTo-OpenMWPath $userdataDirectory)")
$lines.Add("data-local=$(ConvertTo-OpenMWPath $userdataDataDirectory)")
$lines.Add("resources=$(ConvertTo-OpenMWPath $ResourcesRoot)")
$lines.Add("data=$(ConvertTo-OpenMWPath $Fallout3Data)")
$lines.Add("")
foreach ($archive in $activeArchives) {
    $lines.Add("fallback-archive=$archive")
}
$lines.Add("")
foreach ($entry in $activeContent) {
    $lines.Add("content=$entry")
}
$lines.Add("")
$lines.Add("encoding=win1252")
$openmwConfigText = ($lines -join [Environment]::NewLine) + [Environment]::NewLine

$manifest = [ordered]@{
    schema = "nikami-open-fo3-profile/v1"
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    style = "fallout3-vanilla"
    dlc = [ordered]@{
        policy = $DlcPolicy
        available = @($availableDlc | ForEach-Object { $_.Name })
        unavailable = @($missingDlc | ForEach-Object { $_.Name })
    }
    sources = [ordered]@{
        fallout3Data = ConvertTo-OpenMWPath $Fallout3Data
        openmwRuntime = ConvertTo-OpenMWPath $BinaryRoot
    }
    persistence = [ordered]@{
        campaign = "fallout3"
        sharedUserdata = ConvertTo-OpenMWPath $userdataDirectory
        profileDataLocal = ConvertTo-OpenMWPath $userdataDataDirectory
    }
    content = @($activeContent.ToArray())
    archives = @($activeArchives.ToArray())
    safety = @(
        "No Fallout 3 source file contents or directory entries are modified.",
        "Only complete DLC sets present in the licensed game directory are mounted.",
        "Saves stay inside the Fallout 3 campaign store and generated local data stays in this profile."
    )
}
$manifestText = ($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine

if ($DryRun) {
    Write-Host "OpenFO3 base profile preflight passed."
    Write-Host "Profile: $ProfileDirectory"
    Write-Host "Runtime: $BinaryRoot"
    Write-Host "DLC:     $(if ($missingDlc.Count -eq 0) { 'all detected' } else { "ownership-aware; unavailable: $($missingDlc.Name -join ', ')" })"
    Write-Host "Content: $($activeContent.ToArray() -join ' -> ')"
}
else {
    New-Item -ItemType Directory -Path $ProfileDirectory, $userdataDirectory, $userdataDataDirectory -Force | Out-Null
    Write-ProfileTextFile -Path $openmwConfigPath -Text $openmwConfigText -Description "OpenFO3 OpenMW configuration" -AllowReplace:$Force | Out-Null
    Ensure-ProfileTemplateFile -Source (Join-Path $repoRoot "templates/open-nv/settings.cfg") -Destination $settingsPath
    # Let OpenMW create its default controls when the release ships no custom
    # input map, rather than requiring a generated developer profile.
    $inputTemplate = Join-Path $repoRoot "templates/open-nv/input_v3.xml"
    if (Test-Path -LiteralPath $inputTemplate -PathType Leaf) {
        Ensure-ProfileTemplateFile -Source $inputTemplate -Destination $inputPath
    }
    [IO.File]::WriteAllText($manifestPath, $manifestText, [Text.UTF8Encoding]::new($false))
    Write-Host "Prepared isolated OpenFO3 vanilla profile: $ProfileDirectory"
}

return [pscustomobject]@{
    profileDirectory = $ProfileDirectory
    openmwConfigPath = $openmwConfigPath
    manifestPath = $manifestPath
    content = @($activeContent.ToArray())
    jamEnabled = $false
    dlcPolicy = $DlcPolicy
    availableDlc = @($availableDlc | ForEach-Object { $_.Name })
    unavailableDlc = @($missingDlc | ForEach-Object { $_.Name })
    launchable = $true
    launchMode = "fallout3-vanilla"
    runtimeRoot = $BinaryRoot
    resourcesRoot = $ResourcesRoot
}
