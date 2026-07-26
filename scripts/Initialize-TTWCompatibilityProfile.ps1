param(
    [string]$TtwRoot = "",
    [string]$Fallout3Data = "",
    [string]$FalloutNewVegasData = "",
    [string]$JamRoot = "",
    [Alias("WithJam")]
    [switch]$IncludeJam,
    [string]$ProfileDirectory = "",
    [string]$CampaignUserdataDirectory = "",
    [string]$BinaryRoot = "",
    [switch]$DryRun,
    [switch]$AllowPartialInstall,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

$repoRoot = Split-Path -Parent $PSScriptRoot
$ttwContent = @(
    "FalloutNV.esm",
    "DeadMoney.esm",
    "HonestHearts.esm",
    "OldWorldBlues.esm",
    "LonesomeRoad.esm",
    "GunRunnersArsenal.esm",
    "Fallout3.esm",
    "Anchorage.esm",
    "ThePitt.esm",
    "BrokenSteel.esm",
    "PointLookout.esm",
    "Zeta.esm",
    "CaravanPack.esm",
    "ClassicPack.esm",
    "MercenaryPack.esm",
    "TribalPack.esm",
    "TaleOfTwoWastelands.esm",
    "YUPTTW.esm"
)

# A source-archive profile does not contain the full official installer output,
# but it can safely mount the licensed Fallout 3/New Vegas archives together
# with TTW's rules and the YUPTTW overlay. Keep this deliberately small and
# explicit: a tree that only happens to contain the masters is not launchable.
$sourceArchiveRequiredFiles = @(
    "TaleOfTwoWastelands.esm",
    "YUPTTW.esm",
    "YUPTTW - Main.bsa",
    "YUPTTW - Sounds.bsa"
)

$jamPlugin = "JustAssortedMods.esp"

$fo3ArchiveAliases = [ordered]@{
    "Fallout3 - Meshes.bsa" = "Fallout - Meshes.bsa"
    "Fallout3 - Misc.bsa" = "Fallout - Misc.bsa"
    "Fallout3 - Sound.bsa" = "Fallout - Sound.bsa"
    "Fallout3 - Textures.bsa" = "Fallout - Textures.bsa"
    "Fallout3 - Voices.bsa" = "Fallout - Voices.bsa"
    "Fallout3 - MenuVoices.bsa" = "Fallout - MenuVoices.bsa"
}

$fo3DlcArchives = @(
    "Anchorage - Main.bsa", "Anchorage - Sounds.bsa",
    "BrokenSteel - Main.bsa", "BrokenSteel - Sounds.bsa",
    "PointLookout - Main.bsa", "PointLookout - Sounds.bsa",
    "ThePitt - Main.bsa", "ThePitt - Sounds.bsa",
    "Zeta - Main.bsa", "Zeta - Sounds.bsa"
)

$fnvArchives = @(
    "Fallout - Meshes.bsa", "Fallout - Misc.bsa", "Fallout - Sound.bsa",
    "Fallout - Textures.bsa", "Fallout - Textures2.bsa", "Fallout - Voices1.bsa",
    "DeadMoney - Main.bsa", "DeadMoney - Sounds.bsa",
    "HonestHearts - Main.bsa", "HonestHearts - Sounds.bsa",
    "OldWorldBlues - Main.bsa", "OldWorldBlues - Sounds.bsa",
    "LonesomeRoad - Main.bsa", "LonesomeRoad - Sounds.bsa",
    "GunRunnersArsenal - Main.bsa", "GunRunnersArsenal - Sounds.bsa",
    "CaravanPack - Main.bsa", "ClassicPack - Main.bsa",
    "MercenaryPack - Main.bsa", "TribalPack - Main.bsa", "Update.bsa"
)

function ConvertTo-OpenMWPath {
    param([Parameter(Mandatory=$true)][string]$Path)

    return ([IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

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
    $prefix = $parentFull + [IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DataRootsFromProfile {
    param([Parameter(Mandatory=$true)][string]$ProfileConfig)

    if (-not (Test-Path -LiteralPath $ProfileConfig -PathType Leaf)) {
        return @()
    }

    $configDirectory = Split-Path -Parent $ProfileConfig
    $values = @(Get-NikamiOpenMWConfigValues -ConfigPath $ProfileConfig -Key "data")
    $roots = [Collections.Generic.List[string]]::new()
    for ($index = $values.Count - 1; $index -ge 0; --$index) {
        $value = [string]$values[$index]
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        if (-not [IO.Path]::IsPathRooted($value)) {
            $value = Join-Path $configDirectory $value
        }
        $roots.Add($value)
    }
    return @($roots.ToArray())
}

function Resolve-TtwGameData {
    param(
        [string]$ParameterValue,
        [Parameter(Mandatory=$true)][string]$EnvironmentName,
        [Parameter(Mandatory=$true)][string]$ConfigName,
        [Parameter(Mandatory=$true)][string]$ExpectedMaster,
        [Parameter(Mandatory=$true)][string[]]$ExistingProfileConfig,
        [Parameter(Mandatory=$true)][string[]]$SteamCommonNames,
        [Parameter(Mandatory=$true)][string]$Description
    )

    $candidates = [Collections.Generic.List[string]]::new()
    $configured = Resolve-NikamiPath -ParameterValue $ParameterValue -EnvName $EnvironmentName -ConfigName $ConfigName
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $candidates.Add($configured)
    }

    foreach ($profileConfig in $ExistingProfileConfig) {
        foreach ($root in @(Get-DataRootsFromProfile -ProfileConfig $profileConfig)) {
            $candidates.Add($root)
        }
    }

    $localConfig = Get-NikamiLocalConfig
    foreach ($steamAppsRoot in @(Get-NikamiConfigValue -Config $localConfig -Name "steamAppsRoots")) {
        if ([string]::IsNullOrWhiteSpace([string]$steamAppsRoot)) {
            continue
        }
        foreach ($commonName in $SteamCommonNames) {
            $candidates.Add((Join-Path ([string]$steamAppsRoot) (Join-Path "common" (Join-Path $commonName "Data"))))
        }
    }

    foreach ($steamAppsRoot in @(
        "D:/SteamLibrary/steamapps",
        "C:/Program Files (x86)/Steam/steamapps",
        "C:/Program Files/Steam/steamapps"
    )) {
        foreach ($commonName in $SteamCommonNames) {
            $candidates.Add((Join-Path $steamAppsRoot (Join-Path "common" (Join-Path $commonName "Data"))))
        }
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $candidateFull = [IO.Path]::GetFullPath($candidate)
        if (-not $seen.Add($candidateFull)) {
            continue
        }
        $master = Join-Path $candidateFull $ExpectedMaster
        if (Test-Path -LiteralPath $master -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidateFull).Path
        }
    }

    throw "Could not locate $Description. Pass -$ConfigName with the Data directory containing $ExpectedMaster."
}

function Get-DirectoryFootprint {
    param([Parameter(Mandatory=$true)][string]$Path)

    [long]$bytes = 0
    [long]$files = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File)) {
        $bytes += [long]$file.Length
        ++$files
    }

    return [pscustomobject]@{
        bytes = $bytes
        files = $files
    }
}

function Get-TtwInstallAssessment {
    param([Parameter(Mandatory=$true)][string]$Root)

    $missingContent = @($ttwContent | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)
    })
    $missingSourceArchiveFiles = @($sourceArchiveRequiredFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)
    })
    $footprint = Get-DirectoryFootprint -Path $Root
    $hasLooseAssetLayer = (Test-Path -LiteralPath (Join-Path $Root "meshes") -PathType Container) -or
        (Test-Path -LiteralPath (Join-Path $Root "textures") -PathType Container)
    $hasTtwArchiveLayer = @(
        Get-ChildItem -LiteralPath $Root -File -Filter "TaleOfTwoWastelands*.bsa" -ErrorAction SilentlyContinue
    ).Count -gt 0
    # The current official setup guide expects roughly 17 GB.  This lower bound
    # deliberately leaves room for filesystem reporting differences while still
    # detecting an output that only contains masters and the small YUP overlay.
    [long]$minimumBytes = 12GB
    $reasons = [Collections.Generic.List[string]]::new()
    if ($missingContent.Count -gt 0) {
        $reasons.Add("missing content files: $($missingContent -join ', ')")
    }
    if ($footprint.bytes -lt $minimumBytes) {
        $reasons.Add(("installed TTW tree is {0:N2} GiB; the current setup guide expects about 17 GB" -f ($footprint.bytes / 1GB)))
    }
    if (-not ($hasLooseAssetLayer -or $hasTtwArchiveLayer)) {
        $reasons.Add("no TTW mesh/texture asset layer was found (only .override markers do not provide assets to OpenMW)")
    }

    return [pscustomobject]@{
        complete = ($reasons.Count -eq 0)
        reasons = @($reasons.ToArray())
        sourceArchiveCompatible = ($missingContent.Count -eq 0 -and $missingSourceArchiveFiles.Count -eq 0)
        missingSourceArchiveFiles = $missingSourceArchiveFiles
        bytes = $footprint.bytes
        files = $footprint.files
        missingContent = $missingContent
        hasLooseAssetLayer = $hasLooseAssetLayer
        hasTtwArchiveLayer = $hasTtwArchiveLayer
        expectedInstalledSize = "about 17 GB"
    }
}

function Assert-ArchiveFile {
    param(
        [Parameter(Mandatory=$true)][string]$Directory,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Description
    )

    $path = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing $Description archive: $path"
    }
    return (Resolve-Path -LiteralPath $path).Path
}

function Test-NameInList {
    param([string[]]$Names, [string]$Name)

    return @($Names | Where-Object { $_ -ieq $Name }).Count -gt 0
}

function New-ProfileTextFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Description,
        [switch]$AllowReplace,
        [switch]$PreviewOnly
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $current = [IO.File]::ReadAllText($Path)
        $normalCurrent = $current -replace "`r`n", "`n"
        $normalExpected = $Text -replace "`r`n", "`n"
        if ($normalCurrent -ceq $normalExpected) {
            return "unchanged"
        }
        if (-not $AllowReplace) {
            throw "Existing $Description differs from the generated compatibility profile. Refusing to overwrite $Path; pass -Force only if this profile is disposable."
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
        [Parameter(Mandatory=$true)][string]$Description,
        [switch]$PreviewOnly
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        return "unchanged"
    }
    if ($PreviewOnly) {
        Write-Host "Would create $Description from $Source"
        return "preview"
    }
    [IO.File]::WriteAllText($Destination, [IO.File]::ReadAllText($Source), [Text.UTF8Encoding]::new($false))
    return "written"
}

function Get-ExistingAliasRecords {
    param([string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return @()
    }
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        return @($manifest.archiveAliases)
    }
    catch {
        throw "Cannot validate existing TTW archive aliases because the generated manifest is unreadable: $ManifestPath"
    }
}

function Ensure-ArchiveAlias {
    param(
        [Parameter(Mandatory=$true)][string]$AliasPath,
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [AllowEmptyCollection()][object[]]$ExistingAliasRecords = @(),
        [switch]$PreviewOnly
    )

    $source = Get-Item -LiteralPath $SourcePath
    $aliasName = Split-Path -Leaf $AliasPath
    $sourceFull = [IO.Path]::GetFullPath($SourcePath)
    if (Test-Path -LiteralPath $AliasPath -PathType Leaf) {
        $existing = Get-Item -LiteralPath $AliasPath
        $record = @($ExistingAliasRecords | Where-Object {
            [string]$_.aliasName -ieq $aliasName -and
            [string]$_.sourcePath -ieq (ConvertTo-OpenMWPath $sourceFull) -and
            [long]$_.sourceBytes -eq [long]$source.Length
        })
        if ($record.Count -ne 1 -or [long]$existing.Length -ne [long]$source.Length) {
            throw "Archive alias already exists but is not the profile-managed link to ${sourceFull}: $AliasPath"
        }
        return [pscustomobject]@{
            aliasName = $aliasName
            aliasPath = ConvertTo-OpenMWPath $AliasPath
            sourcePath = ConvertTo-OpenMWPath $sourceFull
            sourceBytes = [long]$source.Length
            linkType = [string]$record[0].linkType
            state = "unchanged"
        }
    }

    $sameVolume = [IO.Path]::GetPathRoot($AliasPath).Equals(
        [IO.Path]::GetPathRoot($SourcePath), [StringComparison]::OrdinalIgnoreCase)
    $linkType = if ($sameVolume) { "HardLink" } else { "SymbolicLink" }
    if ($PreviewOnly) {
        Write-Host "Would create $linkType archive alias: $AliasPath -> $SourcePath"
        return [pscustomobject]@{
            aliasName = $aliasName
            aliasPath = ConvertTo-OpenMWPath $AliasPath
            sourcePath = ConvertTo-OpenMWPath $sourceFull
            sourceBytes = [long]$source.Length
            linkType = $linkType
            state = "preview"
        }
    }

    New-Item -ItemType $linkType -Path $AliasPath -Target $SourcePath | Out-Null
    return [pscustomobject]@{
        aliasName = $aliasName
        aliasPath = ConvertTo-OpenMWPath $AliasPath
        sourcePath = ConvertTo-OpenMWPath $sourceFull
        sourceBytes = [long]$source.Length
        linkType = $linkType
        state = "created"
    }
}

$TtwRoot = Resolve-NikamiPath -ParameterValue $TtwRoot -EnvName "NIKAMI_TTW_ROOT" -ConfigName "ttwRoot" -Required -Description "TTW mod directory"
$TtwRoot = Resolve-ExistingDirectory -Path $TtwRoot -Description "TTW mod directory"

$Fallout3Data = Resolve-TtwGameData `
    -ParameterValue $Fallout3Data `
    -EnvironmentName "NIKAMI_FALLOUT3_DATA" `
    -ConfigName "fallout3Data" `
    -ExpectedMaster "Fallout3.esm" `
    -ExistingProfileConfig @((Join-Path $repoRoot "profiles/fallout3/openmw.cfg")) `
    -SteamCommonNames @("Fallout 3 goty", "Fallout 3") `
    -Description "Fallout 3 Data directory"
$FalloutNewVegasData = Resolve-TtwGameData `
    -ParameterValue $FalloutNewVegasData `
    -EnvironmentName "NIKAMI_FALLOUT_NEW_VEGAS_DATA" `
    -ConfigName "falloutNewVegasData" `
    -ExpectedMaster "FalloutNV.esm" `
    -ExistingProfileConfig @((Join-Path $repoRoot "profiles/fallout_new_vegas/openmw.cfg")) `
    -SteamCommonNames @("Fallout New Vegas") `
    -Description "Fallout: New Vegas Data directory"

$activeContent = @($ttwContent)
if ($IncludeJam) {
    $JamRoot = Resolve-NikamiPath `
        -ParameterValue $JamRoot `
        -EnvName "NIKAMI_JAM_ROOT" `
        -ConfigName "jamRoot" `
        -Fallback (Join-Path $repoRoot "local/mods/jam-4.6-original") `
        -Required `
        -Description "JAM 4.6 mod directory"
    $JamRoot = Resolve-ExistingDirectory -Path (Resolve-NikamiRepoRelativePath -Path $JamRoot) -Description "JAM 4.6 mod directory"
    $jamPluginPath = Join-Path $JamRoot $jamPlugin
    if (-not (Test-Path -LiteralPath $jamPluginPath -PathType Leaf)) {
        throw "Missing JAM plugin: $jamPluginPath"
    }
    $activeContent = @($ttwContent + $jamPlugin)
}
else {
    $JamRoot = ""
}

if ([string]::IsNullOrWhiteSpace($ProfileDirectory)) {
    $profileName = if ($IncludeJam) { "tale_of_two_wastelands_jam" } else { "tale_of_two_wastelands" }
    $ProfileDirectory = Join-Path $repoRoot (Join-Path "profiles" $profileName)
}
$ProfileDirectory = Resolve-NikamiRepoRelativePath -Path $ProfileDirectory
$profileRoot = Join-Path $repoRoot "profiles"
if (-not (Test-PathWithin -Path $ProfileDirectory -Parent $profileRoot)) {
    throw "TTW compatibility profile must remain under $profileRoot. Requested: $ProfileDirectory"
}
if ([string]::IsNullOrWhiteSpace($CampaignUserdataDirectory)) {
    $CampaignUserdataDirectory = Join-Path $profileRoot "_campaigns/tale_of_two_wastelands/userdata"
}
$CampaignUserdataDirectory = Resolve-NikamiRepoRelativePath -Path $CampaignUserdataDirectory
if (-not (Test-PathWithin -Path $CampaignUserdataDirectory -Parent $profileRoot)) {
    throw "TTW campaign userdata must remain under $profileRoot. Requested: $CampaignUserdataDirectory"
}

$assessment = Get-TtwInstallAssessment -Root $TtwRoot
if (-not $assessment.complete -and -not $assessment.sourceArchiveCompatible -and -not $AllowPartialInstall) {
    $detail = $assessment.reasons -join "; "
    throw "TTW source preflight failed: $detail. Re-run the official installer into a new empty MO2 mod directory; this script will not alter the current TTW, Fallout 3, or New Vegas trees."
}
if (-not $assessment.complete -and -not $assessment.sourceArchiveCompatible) {
    Write-Warning "TTW source preflight is partial: $($assessment.reasons -join '; '). This profile is diagnostic only and the normal launcher will refuse to start it."
}
elseif (-not $assessment.complete) {
    Write-Warning "TTW source uses the tested source-archive compatibility mode: $($assessment.reasons -join '; '). It remains isolated and does not claim to be a full official installer output."
}

if ([string]::IsNullOrWhiteSpace($BinaryRoot)) {
    # TTW needs the parser compatibility build. Keep the global runtime default
    # unchanged for other worlds.
    $BinaryRoot = Join-Path $repoRoot "local/openmw-ttw-compat"
}
$BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$ResourcesRoot = Resolve-NikamiOpenMWResourcesRoot -ParameterValue (Join-Path $BinaryRoot "resources")

$aliasDirectory = Join-Path $ProfileDirectory "archive-aliases"
$userdataDirectory = $CampaignUserdataDirectory
$userdataDataDirectory = Join-Path $ProfileDirectory "userdata/data"
$openmwConfigPath = Join-Path $ProfileDirectory "openmw.cfg"
$manifestPath = Join-Path $ProfileDirectory "ttw-compatibility-profile.json"
$settingsPath = Join-Path $ProfileDirectory "settings.cfg"
$inputPath = Join-Path $ProfileDirectory "input_v3.xml"

$fo3SourceArchives = [ordered]@{}
foreach ($entry in $fo3ArchiveAliases.GetEnumerator()) {
    $fo3SourceArchives[$entry.Key] = Assert-ArchiveFile -Directory $Fallout3Data -Name $entry.Value -Description "Fallout 3 base"
}
foreach ($archive in $fo3DlcArchives) {
    Assert-ArchiveFile -Directory $Fallout3Data -Name $archive -Description "Fallout 3 DLC" | Out-Null
}
foreach ($archive in $fnvArchives) {
    Assert-ArchiveFile -Directory $FalloutNewVegasData -Name $archive -Description "Fallout: New Vegas" | Out-Null
}

if (-not $DryRun) {
    # Create only profile-owned directories after every source preflight has
    # succeeded.  No directory below a source game or TTW installation is made.
    New-Item -ItemType Directory -Path $ProfileDirectory, $aliasDirectory, $userdataDirectory, $userdataDataDirectory -Force | Out-Null
}

$existingAliasRecords = @(Get-ExistingAliasRecords -ManifestPath $manifestPath)
$aliasRecords = [Collections.Generic.List[object]]::new()
foreach ($entry in $fo3SourceArchives.GetEnumerator()) {
    # A complete official TTW installation may already provide this historical
    # renamed archive.  Otherwise the profile has a hard link to the licensed
    # Fallout 3 archive, not a copied or modified archive.
    if (Test-Path -LiteralPath (Join-Path $TtwRoot $entry.Key) -PathType Leaf) {
        continue
    }
    $aliasRecords.Add((Ensure-ArchiveAlias `
        -AliasPath (Join-Path $aliasDirectory $entry.Key) `
        -SourcePath $entry.Value `
        -ExistingAliasRecords $existingAliasRecords `
        -PreviewOnly:$DryRun))
}

$archiveNames = [Collections.Generic.List[string]]::new()
foreach ($archive in @($fo3ArchiveAliases.Keys) + $fo3DlcArchives + $fnvArchives) {
    if (-not (Test-NameInList -Names $archiveNames.ToArray() -Name $archive)) {
        $archiveNames.Add($archive)
    }
}
$ttwExtraArchives = @(
    Get-ChildItem -LiteralPath $TtwRoot -File -Filter "*.bsa" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name } |
        Where-Object { -not (Test-NameInList -Names $archiveNames.ToArray() -Name $_) }
)
foreach ($archive in @($ttwExtraArchives | Where-Object { $_ -notmatch '^YUPTTW\s*-\s*' } | Sort-Object) +
        @($ttwExtraArchives | Where-Object { $_ -match '^YUPTTW\s*-\s*' } | Sort-Object)) {
    if (-not (Test-NameInList -Names $archiveNames.ToArray() -Name $archive)) {
        $archiveNames.Add($archive)
    }
}

$lines = [Collections.Generic.List[string]]::new()
$lines.Add("# Generated by Initialize-TTWCompatibilityProfile.ps1.")
$lines.Add("# Source file contents and source directory entries remain untouched.")
$lines.Add("replace=data")
$lines.Add("replace=data-local")
$lines.Add("replace=fallback-archive")
$lines.Add("replace=content")
$lines.Add("")
$lines.Add("user-data=$(ConvertTo-OpenMWPath $userdataDirectory)")
$lines.Add("data-local=$(ConvertTo-OpenMWPath $userdataDataDirectory)")
$lines.Add("resources=$(ConvertTo-OpenMWPath $ResourcesRoot)")
$lines.Add("data=$(ConvertTo-OpenMWPath $Fallout3Data)")
$lines.Add("data=$(ConvertTo-OpenMWPath $FalloutNewVegasData)")
if ($aliasRecords.Count -gt 0) {
    $lines.Add("data=$(ConvertTo-OpenMWPath $aliasDirectory)")
}
$lines.Add("data=$(ConvertTo-OpenMWPath $TtwRoot)")
if ($IncludeJam) {
    $lines.Add("data=$(ConvertTo-OpenMWPath $JamRoot)")
}
$lines.Add("")
foreach ($archive in $archiveNames) {
    $lines.Add("fallback-archive=$archive")
}
$lines.Add("")
foreach ($content in $activeContent) {
    $lines.Add("content=$content")
}
$lines.Add("")
$lines.Add("encoding=win1252")
$openmwConfigText = ($lines -join [Environment]::NewLine) + [Environment]::NewLine

$manifest = [ordered]@{
    schema = "nikami-ttw-compatibility-profile/v1"
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    installAssessment = [ordered]@{
        complete = [bool]$assessment.complete
        reasons = @($assessment.reasons)
        sourceArchiveCompatible = [bool]$assessment.sourceArchiveCompatible
        missingSourceArchiveFiles = @($assessment.missingSourceArchiveFiles)
        bytes = [long]$assessment.bytes
        files = [long]$assessment.files
        expectedInstalledSize = $assessment.expectedInstalledSize
    }
    sources = [ordered]@{
        fallout3Data = ConvertTo-OpenMWPath $Fallout3Data
        falloutNewVegasData = ConvertTo-OpenMWPath $FalloutNewVegasData
        ttwRoot = ConvertTo-OpenMWPath $TtwRoot
        jamRoot = if ($IncludeJam) { ConvertTo-OpenMWPath $JamRoot } else { $null }
        openmwRuntime = ConvertTo-OpenMWPath $BinaryRoot
        resources = ConvertTo-OpenMWPath $ResourcesRoot
    }
    persistence = [ordered]@{
        campaign = "tale-of-two-wastelands"
        sharedUserdata = ConvertTo-OpenMWPath $userdataDirectory
        profileDataLocal = ConvertTo-OpenMWPath $userdataDataDirectory
        rule = "TTW and TTW+JAM use the same TTW save set so JAM can be added later; once a save is made with JAM, continue it with JAM enabled."
    }
    archiveAliases = @($aliasRecords.ToArray())
    archives = @($archiveNames.ToArray())
    content = @($activeContent)
    features = [ordered]@{
        jam = [bool]$IncludeJam
    }
    safety = @(
        "No source game or TTW file contents or directory entries are modified.",
        "FO3 base-archive collisions are resolved with profile-local links only.",
        "TTW and TTW+JAM intentionally share campaign saves while their generated local data stays isolated."
    )
}
$manifestText = ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine

if ($DryRun) {
    $mode = if ($assessment.complete) { "full-install" } elseif ($assessment.sourceArchiveCompatible) { "source-archive compatibility" } else { "diagnostic-partial" }
    Write-Host "TTW compatibility profile preflight passed in $mode mode."
    Write-Host "Profile: $ProfileDirectory"
    Write-Host "TTW:     $TtwRoot ($('{0:N2}' -f ($assessment.bytes / 1GB)) GiB, $($assessment.files) files)"
    Write-Host "Runtime: $BinaryRoot"
    Write-Host "JAM:     $(if ($IncludeJam) { 'enabled' } else { 'disabled' })"
    Write-Host "Content: $($activeContent -join ' -> ')"
    Write-Host "Archives: $($archiveNames -join ' -> ')"
}
else {
    New-ProfileTextFile -Path $openmwConfigPath -Text $openmwConfigText -Description "TTW OpenMW configuration" -AllowReplace:$Force | Out-Null
    $settingsTemplate = Join-Path $repoRoot "profiles/fallout_new_vegas/settings.cfg"
    if (-not (Test-Path -LiteralPath $settingsTemplate -PathType Leaf)) {
        throw "Missing FNV settings template: $settingsTemplate"
    }
    Ensure-ProfileTemplateFile -Source $settingsTemplate -Destination $settingsPath -Description "TTW settings.cfg" | Out-Null
    $inputTemplate = Join-Path $repoRoot "profiles/fallout_new_vegas/input_v3.xml"
    if (Test-Path -LiteralPath $inputTemplate -PathType Leaf) {
        Ensure-ProfileTemplateFile -Source $inputTemplate -Destination $inputPath -Description "TTW input_v3.xml" | Out-Null
    }
    [IO.File]::WriteAllText($manifestPath, $manifestText, [Text.UTF8Encoding]::new($false))
    Write-Host "Prepared isolated TTW compatibility profile: $ProfileDirectory"
    Write-Host "No Fallout 3, Fallout: New Vegas, or TTW source content or directory entry was changed."
}

return [pscustomobject]@{
    profileDirectory = $ProfileDirectory
    openmwConfigPath = $openmwConfigPath
    manifestPath = $manifestPath
    installComplete = [bool]$assessment.complete
    installReasons = @($assessment.reasons)
    sourceArchiveCompatible = [bool]$assessment.sourceArchiveCompatible
    missingSourceArchiveFiles = @($assessment.missingSourceArchiveFiles)
    launchable = [bool]($assessment.complete -or $assessment.sourceArchiveCompatible)
    launchMode = if ($assessment.complete) { "full-install" } elseif ($assessment.sourceArchiveCompatible) { "source-archive compatibility" } else { "diagnostic-partial" }
    content = @($activeContent)
    jamEnabled = [bool]$IncludeJam
    archives = @($archiveNames.ToArray())
    runtimeRoot = $BinaryRoot
    resourcesRoot = $ResourcesRoot
}
