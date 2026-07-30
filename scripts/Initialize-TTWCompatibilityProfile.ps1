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

function Resolve-PreferredTtwRoot {
    param(
        [string]$ParameterValue,
        [Parameter(Mandatory=$true)][bool]$ExplicitRoot,
        [Parameter(Mandatory=$true)][string]$ProfilesRoot
    )

    $configuredRoot = Resolve-NikamiPath `
        -ParameterValue $ParameterValue `
        -EnvName "NIKAMI_TTW_ROOT" `
        -ConfigName "ttwRoot"

    if ($ExplicitRoot) {
        if ([string]::IsNullOrWhiteSpace($configuredRoot)) {
            throw "Missing TTW mod directory. Pass -TtwRoot with the complete official installer output."
        }
        return [pscustomobject]@{
            root = Resolve-ExistingDirectory -Path $configuredRoot -Description "TTW mod directory"
            source = "explicit"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($configuredRoot) -and
        (Test-Path -LiteralPath $configuredRoot -PathType Container)) {
        $configuredFull = Resolve-ExistingDirectory -Path $configuredRoot -Description "configured TTW mod directory"
        if ((Get-TtwInstallAssessment -Root $configuredFull).complete) {
            return [pscustomobject]@{ root = $configuredFull; source = "configured" }
        }
    }

    # A launcher must not regress from a previously verified full TTW install to
    # a smaller source archive just because an old local path remains configured.
    # The profile manifests are generated data, so this uses recorded installation
    # evidence rather than a machine-specific path or a content-specific override.
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($manifestPath in @(Get-ChildItem -LiteralPath $ProfilesRoot -Recurse -File -Filter "ttw-compatibility-profile.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath.FullName -Raw | ConvertFrom-Json
            $candidate = [string]$manifest.sources.ttwRoot
            if (-not [bool]$manifest.installAssessment.complete -or [string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }
            $candidate = [IO.Path]::GetFullPath($candidate)
            if (-not $seen.Add($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Container)) {
                continue
            }
            $candidate = Resolve-ExistingDirectory -Path $candidate -Description "verified TTW mod directory"
            if ((Get-TtwInstallAssessment -Root $candidate).complete) {
                Write-Warning "Configured TTW root is incomplete; using the verified full TTW install recorded in $($manifestPath.FullName): $candidate"
                return [pscustomobject]@{ root = $candidate; source = "verified-profile" }
            }
        }
        catch {
            Write-Warning "Ignoring unreadable TTW profile manifest $($manifestPath.FullName): $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($configuredRoot)) {
        return [pscustomobject]@{
            root = Resolve-ExistingDirectory -Path $configuredRoot -Description "TTW mod directory"
            source = "configured-partial"
        }
    }

    throw "Could not locate a TTW mod directory. Pass -TtwRoot with the complete official installer output."
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

function New-TtwDataLayer {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$Role,
        [Parameter(Mandatory=$true)][string]$Description,
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][int]$Priority
    )

    return [pscustomobject][ordered]@{
        id = $Id
        role = $Role
        description = $Description
        sourcePath = [IO.Path]::GetFullPath($SourcePath)
        priority = $Priority
    }
}

function Resolve-TtwLayeredFile {
    param(
        [Parameter(Mandatory=$true)][object[]]$Layers,
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [AllowEmptyString()][string]$RequiredLayerId = "",
        [AllowEmptyCollection()][object[]]$PlannedAliasRecords = @()
    )

    # OpenMW's VFS takes the last data= entry which contains a file.  Walk the
    # declared layers in the same order so the manifest records the actual
    # provider rather than merely assuming that the generated TTW directory
    # happens to be complete.
    $winner = $null
    foreach ($layer in $Layers) {
        $candidate = Join-Path ([string]$layer.sourcePath) $RelativePath
        $resolvedCandidate = $candidate
        $plannedAlias = @()
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -and
            [string]$layer.id -eq "fallout3-archive-aliases") {
            $plannedAlias = @($PlannedAliasRecords | Where-Object {
                [string]$_.aliasName -ieq $RelativePath
            } | Select-Object -First 1)
            if ($plannedAlias.Count -eq 1) {
                $resolvedCandidate = [string]$plannedAlias[0].sourcePath
            }
        }
        if (Test-Path -LiteralPath $resolvedCandidate -PathType Leaf) {
            $item = Get-Item -LiteralPath $resolvedCandidate
            $winner = [pscustomobject][ordered]@{
                id = $Id
                relativePath = $RelativePath
                expectedProviderLayerId = $RequiredLayerId
                providerLayerId = [string]$layer.id
                providerPath = $item.FullName
                plannedAlias = ($plannedAlias.Count -eq 1)
                bytes = [long]$item.Length
            }
        }
    }

    if ($null -eq $winner) {
        throw "The TTW data-layer union cannot resolve required asset '$RelativePath'."
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredLayerId) -and
        $winner.providerLayerId -ne $RequiredLayerId) {
        throw "The TTW data-layer union resolved '$RelativePath' from '$($winner.providerLayerId)', expected '$RequiredLayerId'."
    }
    return $winner
}

function New-ProfileTextFile {
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
        -Generator "Initialize-TTWCompatibilityProfile.ps1" `
        -AllowReplace:$AllowReplace `
        -AllowGeneratedUpgrade:$AllowGeneratedUpgrade `
        -PreviewOnly:$PreviewOnly
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
    [IO.File]::WriteAllText($Path, (($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
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

$ttwRootExplicit = $PSBoundParameters.ContainsKey("TtwRoot") -or
    -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("NIKAMI_TTW_ROOT", "Process"))
$ttwRootResolution = Resolve-PreferredTtwRoot `
    -ParameterValue $TtwRoot `
    -ExplicitRoot $ttwRootExplicit `
    -ProfilesRoot (Join-Path $repoRoot "profiles")
$TtwRoot = [string]$ttwRootResolution.root

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
    $BinaryRoot = Resolve-NikamiOpenMWRuntimeRoot
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

# The exact same union model used by the retail TTW shadow is declared here as
# OpenMW data= layers. The order is low-to-high precedence: generated TTW is
# last, so it owns converted masters, meshes, textures, Bink video, and its
# own archives while the licensed base games still supply anything TTW does not
# ship (for example Fallout - Voices1.bsa).
$dataLayers = [Collections.Generic.List[object]]::new()
$dataLayers.Add((New-TtwDataLayer `
    -Id "fallout3-base" `
    -Role "licensed-base" `
    -Description "Licensed Fallout 3 base Data" `
    -SourcePath $Fallout3Data `
    -Priority 100))
$dataLayers.Add((New-TtwDataLayer `
    -Id "fallout-new-vegas-base" `
    -Role "licensed-base" `
    -Description "Licensed Fallout: New Vegas base Data" `
    -SourcePath $FalloutNewVegasData `
    -Priority 200))
if ($aliasRecords.Count -gt 0) {
    $dataLayers.Add((New-TtwDataLayer `
        -Id "fallout3-archive-aliases" `
        -Role "profile-owned-aliases" `
        -Description "Profile-local Fallout 3 archive-name compatibility links" `
        -SourcePath $aliasDirectory `
        -Priority 300))
}
$dataLayers.Add((New-TtwDataLayer `
    -Id "ttw-generated-overlay" `
    -Role "generated-conversion-overlay" `
    -Description "Official TTW generated output; overrides matching base assets" `
    -SourcePath $TtwRoot `
    -Priority 400))
if ($IncludeJam) {
    $dataLayers.Add((New-TtwDataLayer `
        -Id "jam-optional-overlay" `
        -Role "optional-mod-overlay" `
        -Description "Optional JAM layer; it may be added to the shared TTW campaign" `
        -SourcePath $JamRoot `
        -Priority 500))
}

$resolvedLayeredAssets = [Collections.Generic.List[object]]::new()
$requiredLayeredAssets = @(
    [pscustomobject]@{ id = "falloutnv-master"; relativePath = "FalloutNV.esm"; requiredLayerId = "ttw-generated-overlay" },
    [pscustomobject]@{ id = "fallout3-master"; relativePath = "Fallout3.esm"; requiredLayerId = "ttw-generated-overlay" },
    [pscustomobject]@{ id = "ttw-master"; relativePath = "TaleOfTwoWastelands.esm"; requiredLayerId = "ttw-generated-overlay" },
    [pscustomobject]@{ id = "yupttw-master"; relativePath = "YUPTTW.esm"; requiredLayerId = "ttw-generated-overlay" },
    [pscustomobject]@{ id = "authored-opening-bink"; relativePath = "Video\Fallout INTRO Vsk.bik"; requiredLayerId = "ttw-generated-overlay" },
    [pscustomobject]@{ id = "ttw-main-archive"; relativePath = "TaleOfTwoWastelands - Main.bsa"; requiredLayerId = "ttw-generated-overlay" },
    [pscustomobject]@{ id = "ttw-textures-archive"; relativePath = "TaleOfTwoWastelands - Textures.bsa"; requiredLayerId = "ttw-generated-overlay" },
    [pscustomobject]@{ id = "fallout-new-vegas-voices"; relativePath = "Fallout - Voices1.bsa"; requiredLayerId = "" },
    [pscustomobject]@{ id = "fallout3-misc"; relativePath = "Fallout3 - Misc.bsa"; requiredLayerId = "" }
)
foreach ($asset in $requiredLayeredAssets) {
    $resolvedLayeredAssets.Add((Resolve-TtwLayeredFile `
        -Layers $dataLayers.ToArray() `
        -Id ([string]$asset.id) `
        -RelativePath ([string]$asset.relativePath) `
        -RequiredLayerId ([string]$asset.requiredLayerId) `
        -PlannedAliasRecords $aliasRecords.ToArray()))
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
foreach ($dataLayer in $dataLayers) {
    $lines.Add("data=$(ConvertTo-OpenMWPath ([string]$dataLayer.sourcePath))")
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
    dataLayerPolicy = [ordered]@{
        order = "low-to-high precedence"
        resolver = "OpenMW VFS uses the last data= entry containing a file"
        sourceTreesModified = $false
    }
    dataLayers = @(
        foreach ($dataLayer in $dataLayers) {
            [ordered]@{
                id = [string]$dataLayer.id
                role = [string]$dataLayer.role
                description = [string]$dataLayer.description
                path = ConvertTo-OpenMWPath ([string]$dataLayer.sourcePath)
                priority = [int]$dataLayer.priority
            }
        }
    )
    resolvedLayeredAssets = @(
        foreach ($asset in $resolvedLayeredAssets) {
            [ordered]@{
                id = [string]$asset.id
                relativePath = [string]$asset.relativePath
                expectedProviderLayerId = [string]$asset.expectedProviderLayerId
                providerLayerId = [string]$asset.providerLayerId
                providerPath = ConvertTo-OpenMWPath ([string]$asset.providerPath)
                plannedAlias = [bool]$asset.plannedAlias
                bytes = [long]$asset.bytes
            }
        }
    )
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
    compatibility = [ordered]@{
        scriptCommandMappings = @(
            [ordered]@{
                command = "TTW_ShowGeneProjector"
                capability = "character-appearance"
                declaration = "profile-local OpenNV Compatibility settings"
                source = "TaleOfTwoWastelands.esm authored CG00 stage source"
            }
        )
    }
    safety = @(
        "No source game or TTW file contents or directory entries are modified.",
        "The profile mounts native Fallout and TTW presentation assets; it does not override them with generated placeholder UI textures.",
        "FO3 base-archive collisions are resolved with profile-local links only.",
        "The generated TTW output is mounted as the highest-priority compatibility layer; base-only assets remain available beneath it.",
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
    New-ProfileTextFile `
        -Path $openmwConfigPath `
        -Text $openmwConfigText `
        -Description "TTW OpenMW configuration" `
        -AllowReplace:$Force `
        -AllowGeneratedUpgrade:$UpgradeGeneratedProfile | Out-Null
    $settingsTemplate = Join-Path $repoRoot "templates/open-nv/settings.cfg"
    if (-not (Test-Path -LiteralPath $settingsTemplate -PathType Leaf)) {
        throw "Missing FNV settings template: $settingsTemplate"
    }
    Ensure-ProfileTemplateFile -Source $settingsTemplate -Destination $settingsPath -Description "TTW settings.cfg" | Out-Null
    Ensure-ProfileCompatibilityCommandMapping -Path $settingsPath -Command "TTW_ShowGeneProjector" -Capability "character-appearance" | Out-Null
    $inputTemplate = Join-Path $repoRoot "templates/open-nv/input_v3.xml"
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
    dataLayers = @($dataLayers.ToArray())
    resolvedLayeredAssets = @($resolvedLayeredAssets.ToArray())
    runtimeRoot = $BinaryRoot
    resourcesRoot = $ResourcesRoot
    profileConfigState = Get-OpenNVLauncherConfigState `
        -Path $openmwConfigPath `
        -Text $openmwConfigText `
        -Generator "Initialize-TTWCompatibilityProfile.ps1"
}
