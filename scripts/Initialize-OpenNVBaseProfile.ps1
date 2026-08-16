param(
    [string]$FalloutNewVegasData = "",
    [string]$JamRoot = "",
    [Alias("WithJam")]
    [switch]$IncludeJam,
    [string]$ProfileDirectory = "",
    [string]$CampaignUserdataDirectory = "",
    [string]$BinaryRoot = "",
    [ValidateSet("Auto", "RequireAll")]
    [string]$DlcPolicy = "Auto",
    [switch]$DryRun,
    [switch]$Force,
    # Used only by Start-OpenNV.ps1 to migrate a launcher-owned generated
    # openmw.cfg after first preserving it under the profile.
    [switch]$UpgradeGeneratedProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
. (Join-Path $PSScriptRoot "OpenNVProfileConfig.ps1")

$repoRoot = Split-Path -Parent $PSScriptRoot
$baseContent = @("FalloutNV.esm")
$baseArchives = @(
    "Fallout - Meshes.bsa", "Fallout - Misc.bsa", "Fallout - Sound.bsa",
    "Fallout - Textures.bsa", "Fallout - Textures2.bsa", "Fallout - Voices1.bsa", "Update.bsa"
)
$optionalDlc = @(
    [pscustomobject]@{ Name = "Dead Money"; Master = "DeadMoney.esm"; Archives = @("DeadMoney - Main.bsa", "DeadMoney - Sounds.bsa") },
    [pscustomobject]@{ Name = "Honest Hearts"; Master = "HonestHearts.esm"; Archives = @("HonestHearts - Main.bsa", "HonestHearts - Sounds.bsa") },
    [pscustomobject]@{ Name = "Old World Blues"; Master = "OldWorldBlues.esm"; Archives = @("OldWorldBlues - Main.bsa", "OldWorldBlues - Sounds.bsa") },
    [pscustomobject]@{ Name = "Lonesome Road"; Master = "LonesomeRoad.esm"; Archives = @("LonesomeRoad - Main.bsa", "LonesomeRoad - Sounds.bsa") },
    [pscustomobject]@{ Name = "Tribal Pack"; Master = "TribalPack.esm"; Archives = @("TribalPack - Main.bsa") },
    [pscustomobject]@{ Name = "Mercenary Pack"; Master = "MercenaryPack.esm"; Archives = @("MercenaryPack - Main.bsa") },
    [pscustomobject]@{ Name = "Classic Pack"; Master = "ClassicPack.esm"; Archives = @("ClassicPack - Main.bsa") },
    [pscustomobject]@{ Name = "Caravan Pack"; Master = "CaravanPack.esm"; Archives = @("CaravanPack - Main.bsa") },
    [pscustomobject]@{ Name = "Gun Runners' Arsenal"; Master = "GunRunnersArsenal.esm"; Archives = @("GunRunnersArsenal - Main.bsa", "GunRunnersArsenal - Sounds.bsa") }
)
$jamPlugin = "JustAssortedMods.esp"
$jamRequiredMasters = @("FalloutNV.esm", "DeadMoney.esm", "HonestHearts.esm", "LonesomeRoad.esm")

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
        [switch]$AllowGeneratedUpgrade,
        [switch]$PreviewOnly
    )

    return Write-OpenNVLauncherConfig `
        -Path $Path `
        -Text $Text `
        -Description $Description `
        -Generator "Initialize-OpenNVBaseProfile.ps1" `
        -AllowReplace:$AllowReplace `
        -AllowGeneratedUpgrade:$AllowGeneratedUpgrade `
        -PreviewOnly:$PreviewOnly
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

function Ensure-ProfileCompatibilityCommandMapping {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$Capability,
        [switch]$PreviewOnly
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Cannot add a profile compatibility command mapping because settings.cfg is missing: $Path"
    }

    $text = [IO.File]::ReadAllText($Path)
    $lines = [Collections.Generic.List[string]]::new([string[]]($text -split "`r?`n"))
    $sectionStart = -1
    $sectionEnd = $lines.Count
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[OpenNV Compatibility\]\s*$') {
            $sectionStart = $index
            for ($next = $index + 1; $next -lt $lines.Count; $next++) {
                if ($lines[$next] -match '^\s*\[.+\]\s*$') {
                    $sectionEnd = $next
                    break
                }
            }
            break
        }
    }

    $mapping = "$Command`:$Capability"
    if ($sectionStart -lt 0) {
        $lines.Add("")
        $lines.Add("[OpenNV Compatibility]")
        $lines.Add("script command mappings = $mapping")
    }
    else {
        $mappingIndex = -1
        for ($index = $sectionStart + 1; $index -lt $sectionEnd; $index++) {
            if ($lines[$index] -match '^\s*script command mappings\s*=\s*(.*)$') {
                $mappingIndex = $index
                $existing = [string]$Matches[1]
                $entries = @($existing -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
                if ($entries -contains $mapping) {
                    return "unchanged"
                }
                $lines[$index] = "script command mappings = $(($entries + $mapping) -join ', ')"
                break
            }
        }
        if ($mappingIndex -lt 0) {
            $lines.Insert($sectionStart + 1, "script command mappings = $mapping")
        }
    }

    if ($PreviewOnly) {
        Write-Host "Would add OpenNV compatibility mapping $mapping to $Path"
        return "preview"
    }
    [IO.File]::WriteAllText(
        $Path,
        (($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
    return "written"
}

$FalloutNewVegasData = Resolve-NikamiPath `
    -ParameterValue $FalloutNewVegasData `
    -EnvName "NIKAMI_FALLOUT_NEW_VEGAS_DATA" `
    -ConfigName "falloutNewVegasData" `
    -Required `
    -Description "Fallout: New Vegas Data directory"
$FalloutNewVegasData = Resolve-ExistingDirectory -Path (Resolve-NikamiRepoRelativePath -Path $FalloutNewVegasData) -Description "Fallout: New Vegas Data directory"
Assert-File -Path (Join-Path $FalloutNewVegasData "FalloutNV.esm") -Description "Fallout: New Vegas master" | Out-Null
foreach ($archive in $baseArchives) {
    Assert-File -Path (Join-Path $FalloutNewVegasData $archive) -Description "Fallout: New Vegas base archive" | Out-Null
}

$availableDlc = [Collections.Generic.List[object]]::new()
$missingDlc = [Collections.Generic.List[object]]::new()
foreach ($dlc in $optionalDlc) {
    $expectedFiles = @($dlc.Master) + @($dlc.Archives)
    $presentFiles = @($expectedFiles | Where-Object {
        Test-Path -LiteralPath (Join-Path $FalloutNewVegasData $_) -PathType Leaf
    })
    if ($presentFiles.Count -eq $expectedFiles.Count) {
        $availableDlc.Add($dlc)
    }
    elseif ($presentFiles.Count -eq 0) {
        $missingDlc.Add($dlc)
    }
    else {
        $missingFiles = @($expectedFiles | Where-Object { $_ -notin $presentFiles })
        throw "Fallout: New Vegas add-on '$($dlc.Name)' is only partly installed. Missing: $($missingFiles -join ', '). Verify or reinstall that add-on before launching it."
    }
}
if ($DlcPolicy -eq "RequireAll" -and $missingDlc.Count -gt 0) {
    throw "This profile was asked to require all Fallout: New Vegas DLC/preorder packs, but these are unavailable: $($missingDlc.Name -join ', '). Use -DlcPolicy Auto for an ownership-aware standalone profile."
}

$activeArchives = [Collections.Generic.List[string]]::new()
foreach ($archive in $baseArchives) { $activeArchives.Add($archive) }
$activeContent = [Collections.Generic.List[string]]::new()
foreach ($entry in $baseContent) { $activeContent.Add($entry) }
foreach ($dlc in $availableDlc) {
    $activeContent.Add($dlc.Master)
    foreach ($archive in $dlc.Archives) { $activeArchives.Add($archive) }
}
if ($IncludeJam) {
    $JamRoot = Resolve-NikamiPath `
        -ParameterValue $JamRoot `
        -EnvName "NIKAMI_JAM_ROOT" `
        -ConfigName "jamRoot" `
        -Fallback (Join-Path $repoRoot "local/mods/jam-4.6-original") `
        -Required `
        -Description "JAM 4.6 mod directory"
    $JamRoot = Resolve-ExistingDirectory -Path (Resolve-NikamiRepoRelativePath -Path $JamRoot) -Description "JAM 4.6 mod directory"
    Assert-File -Path (Join-Path $JamRoot $jamPlugin) -Description "JAM plugin" | Out-Null
    $missingJamMasters = @($jamRequiredMasters | Where-Object { $_ -notin $activeContent })
    if ($missingJamMasters.Count -gt 0) {
        throw "JAM requires these Fallout: New Vegas masters, which are not available under the current DLC ownership set: $($missingJamMasters -join ', '). Launch vanilla or install the required DLC before enabling JAM."
    }
    $activeContent.Add($jamPlugin)
}
else {
    $JamRoot = ""
}

if ([string]::IsNullOrWhiteSpace($ProfileDirectory)) {
    $profileName = if ($IncludeJam) { "open_nv_jam" } else { "open_nv_vanilla" }
    $ProfileDirectory = Join-Path $repoRoot (Join-Path "profiles" $profileName)
}
$ProfileDirectory = Resolve-NikamiRepoRelativePath -Path $ProfileDirectory
$profilesRoot = Join-Path $repoRoot "profiles"
if (-not (Test-PathWithin -Path $ProfileDirectory -Parent $profilesRoot)) {
    throw "OpenNV profile must remain under $profilesRoot. Requested: $ProfileDirectory"
}
if ([string]::IsNullOrWhiteSpace($CampaignUserdataDirectory)) {
    $CampaignUserdataDirectory = Join-Path $profilesRoot "_campaigns/new_vegas/userdata"
}
$CampaignUserdataDirectory = Resolve-NikamiRepoRelativePath -Path $CampaignUserdataDirectory
if (-not (Test-PathWithin -Path $CampaignUserdataDirectory -Parent $profilesRoot)) {
    throw "OpenNV campaign userdata must remain under $profilesRoot. Requested: $CampaignUserdataDirectory"
}

if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    $BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot
}
$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$ResourcesRoot = Resolve-NikamiOpenMWResourcesRoot -ParameterValue (Join-Path $BinaryRoot "resources")

$userdataDirectory = $CampaignUserdataDirectory
$userdataDataDirectory = Join-Path $ProfileDirectory "userdata/data"
$openmwConfigPath = Join-Path $ProfileDirectory "openmw.cfg"
$manifestPath = Join-Path $ProfileDirectory "open-nv-profile.json"
$settingsPath = Join-Path $ProfileDirectory "settings.cfg"
$inputPath = Join-Path $ProfileDirectory "input_v3.xml"

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("# Generated by Initialize-OpenNVBaseProfile.ps1.")
$lines.Add("# Vanilla source contents and directory entries remain untouched.")
$lines.Add("replace=data")
$lines.Add("replace=data-local")
$lines.Add("replace=fallback-archive")
$lines.Add("replace=content")
$lines.Add("")
$lines.Add("user-data=$(ConvertTo-OpenMWPath $userdataDirectory)")
$lines.Add("data-local=$(ConvertTo-OpenMWPath $userdataDataDirectory)")
$lines.Add("resources=$(ConvertTo-OpenMWPath $ResourcesRoot)")
$lines.Add("data=$(ConvertTo-OpenMWPath $FalloutNewVegasData)")
if ($IncludeJam) {
    $lines.Add("data=$(ConvertTo-OpenMWPath $JamRoot)")
}
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
    schema = "nikami-open-nv-profile/v1"
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    style = if ($IncludeJam) { "jam" } else { "vanilla" }
    sources = [ordered]@{
        falloutNewVegasData = ConvertTo-OpenMWPath $FalloutNewVegasData
        jamRoot = if ($IncludeJam) { ConvertTo-OpenMWPath $JamRoot } else { $null }
        openmwRuntime = ConvertTo-OpenMWPath $BinaryRoot
    }
    persistence = [ordered]@{
        campaign = "new-vegas"
        sharedUserdata = ConvertTo-OpenMWPath $userdataDirectory
        profileDataLocal = ConvertTo-OpenMWPath $userdataDataDirectory
        rule = "Vanilla and JAM use the same New Vegas save set so JAM can be added later; once a save is made with JAM, continue it with JAM enabled."
    }
    dlc = [ordered]@{
        policy = $DlcPolicy
        available = @($availableDlc | ForEach-Object { $_.Name })
        unavailable = @($missingDlc | ForEach-Object { $_.Name })
    }
    content = @($activeContent.ToArray())
    archives = @($activeArchives.ToArray())
    safety = @(
        "No Fallout: New Vegas source file contents or directory entries are modified.",
        "JAM is mounted from its registered hash-locked depot tree only when selected.",
        "The profile mounts native Fallout presentation assets; it does not override them with generated placeholder UI textures.",
        "Vanilla and JAM profiles intentionally share this campaign's saves while their generated local data stays isolated."
    )
}
$manifestText = ($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine

if ($DryRun) {
    Write-Host "OpenNV base profile preflight passed."
    Write-Host "Style:   $(if ($IncludeJam) { 'JAM' } else { 'vanilla' })"
    Write-Host "Profile: $ProfileDirectory"
    Write-Host "Runtime: $BinaryRoot"
    Write-Host "DLC:     $(if ($missingDlc.Count -eq 0) { 'all detected' } else { "ownership-aware; unavailable: $($missingDlc.Name -join ', ')" })"
    Write-Host "Content: $($activeContent.ToArray() -join ' -> ')"
}
else {
    New-Item -ItemType Directory -Path $ProfileDirectory, $userdataDirectory, $userdataDataDirectory -Force | Out-Null
    Write-ProfileTextFile `
        -Path $openmwConfigPath `
        -Text $openmwConfigText `
        -Description "OpenNV OpenMW configuration" `
        -AllowReplace:$Force `
        -AllowGeneratedUpgrade:$UpgradeGeneratedProfile | Out-Null
    Ensure-ProfileTemplateFile -Source (Join-Path $repoRoot "templates/open-nv/settings.cfg") -Destination $settingsPath
    Ensure-ProfileCompatibilityCommandMapping `
        -Path $settingsPath `
        -Command "ShowLoveTesterMenuParams" `
        -Capability "character-special" | Out-Null
    # When no profile-local input map exists, OpenMW creates its own defaults.
    # That makes a packaged release usable without inheriting a developer's
    # generated controls file.
    $inputTemplate = Join-Path $repoRoot "templates/open-nv/input_v3.xml"
    if (Test-Path -LiteralPath $inputTemplate -PathType Leaf) {
        Ensure-ProfileTemplateFile -Source $inputTemplate -Destination $inputPath
    }
    [IO.File]::WriteAllText($manifestPath, $manifestText, [Text.UTF8Encoding]::new($false))
    Write-Host "Prepared isolated OpenNV $(if ($IncludeJam) { 'JAM' } else { 'vanilla' }) profile: $ProfileDirectory"
}

return [pscustomobject]@{
    profileDirectory = $ProfileDirectory
    openmwConfigPath = $openmwConfigPath
    manifestPath = $manifestPath
    content = @($activeContent.ToArray())
    jamEnabled = [bool]$IncludeJam
    dlcPolicy = $DlcPolicy
    availableDlc = @($availableDlc | ForEach-Object { $_.Name })
    unavailableDlc = @($missingDlc | ForEach-Object { $_.Name })
    launchable = $true
    launchMode = if ($IncludeJam) { "jam" } else { "vanilla" }
    runtimeRoot = $BinaryRoot
    resourcesRoot = $ResourcesRoot
    profileConfigState = Get-OpenNVLauncherConfigState `
        -Path $openmwConfigPath `
        -Text $openmwConfigText `
        -Generator "Initialize-OpenNVBaseProfile.ps1"
}
