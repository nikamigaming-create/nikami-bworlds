param(
    [string]$OutputPath = "catalog/worlds.local.json",
    [switch]$GenerateProfiles,
    [string]$CapabilityPath = "catalog/bethesda-openmw-capabilities.json",
    [string]$SettingsPresetPath = "catalog/world-settings-presets.json",
    [string]$ProfilesRoot = "profiles",
    [string]$OpenMWResources = "",
    [string[]]$ExtraFalloutNewVegasInstallPaths = @(),
    [string[]]$ExtraSteamAppsRoots = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Convert-ToForwardSlash([string]$Path) {
    return ($Path -replace "\\", "/")
}

function Read-KeyValueFile([string]$Path) {
    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*"([^"]+)"\s+"([^"]*)"\s*$') {
            $result[$matches[1]] = $matches[2]
        }
    }
    return $result
}

function Get-SteamLibraryRoots {
    param([string[]]$ExtraRoots = @())

    $roots = New-Object System.Collections.Generic.List[string]
    $candidateSteamApps = @(
        "C:/Program Files (x86)/Steam/steamapps",
        "C:/Program Files/Steam/steamapps"
    )

    foreach ($candidate in $candidateSteamApps) {
        if (Test-Path -LiteralPath $candidate) {
            $roots.Add((Convert-ToForwardSlash (Resolve-Path -LiteralPath $candidate).Path))
        }
    }

    $libraryFiles = @(
        "C:/Program Files (x86)/Steam/steamapps/libraryfolders.vdf",
        "C:/Program Files/Steam/steamapps/libraryfolders.vdf"
    )

    foreach ($libraryFile in $libraryFiles) {
        if (-not (Test-Path -LiteralPath $libraryFile)) {
            continue
        }
        foreach ($line in Get-Content -LiteralPath $libraryFile) {
            if ($line -match '"path"\s+"([^"]+)"') {
                $steamApps = Join-Path ($matches[1] -replace "\\\\", "\") "steamapps"
                if (Test-Path -LiteralPath $steamApps) {
                    $roots.Add((Convert-ToForwardSlash (Resolve-Path -LiteralPath $steamApps).Path))
                }
            }
        }
    }

    foreach ($extraRoot in $ExtraRoots) {
        if (-not [string]::IsNullOrWhiteSpace($extraRoot) -and (Test-Path -LiteralPath $extraRoot)) {
            $roots.Add((Convert-ToForwardSlash (Resolve-Path -LiteralPath $extraRoot).Path))
        }
    }

    return $roots | Sort-Object -Unique
}

function Get-SteamApps {
    param([string[]]$SteamAppsRoots)

    $apps = @()
    foreach ($root in $SteamAppsRoots) {
        $manifestFiles = Get-ChildItem -LiteralPath $root -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue
        foreach ($manifest in $manifestFiles) {
            $values = Read-KeyValueFile $manifest.FullName
            if (-not $values.Contains("appid") -or -not $values.Contains("installdir")) {
                continue
            }
            $installPath = Join-Path (Join-Path $root "common") $values["installdir"]
            $apps += [ordered]@{
                appid = $values["appid"]
                name = if ($values.Contains("name")) { $values["name"] } else { "" }
                installdir = $values["installdir"]
                installPath = Convert-ToForwardSlash $installPath
                manifestPath = Convert-ToForwardSlash $manifest.FullName
            }
        }
    }
    return $apps
}

function Test-FilesPresent {
    param(
        [string]$BasePath,
        [string[]]$Files
    )

    $present = @()
    $missing = @()
    foreach ($file in $Files) {
        $path = Join-Path $BasePath $file
        if (Test-Path -LiteralPath $path) {
            $present += $file
        } else {
            $missing += $file
        }
    }

    return [ordered]@{
        present = $present
        missing = $missing
    }
}

function Get-FileNamesByExtension {
    param(
        [string]$BasePath,
        [string[]]$Extensions
    )

    if (-not (Test-Path -LiteralPath $BasePath)) {
        return @()
    }

    $escaped = $Extensions | ForEach-Object { [regex]::Escape($_) }
    $pattern = "\.($($escaped -join '|'))$"
    return Get-ChildItem -LiteralPath $BasePath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object Name |
        ForEach-Object { $_.Name }
}

function New-WorldDefinition {
    param(
        [string]$Id,
        [string]$DataSubpath,
        [string[]]$SteamAppIds,
        [string[]]$CommonInstallDirs,
        [string[]]$ExtraInstallPaths = @()
    )

    return [ordered]@{
        id = $Id
        dataSubpath = $DataSubpath
        steamAppIds = $SteamAppIds
        commonInstallDirs = $CommonInstallDirs
        extraInstallPaths = $ExtraInstallPaths
    }
}

function Get-InstallCandidates {
    param(
        [object]$Definition,
        [object[]]$SteamApps,
        [string[]]$SteamAppsRoots
    )

    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($app in $SteamApps) {
        if ($Definition.steamAppIds -contains $app.appid) {
            $paths.Add($app.installPath)
        }
    }

    foreach ($root in $SteamAppsRoots) {
        $commonRoot = Join-Path $root "common"
        foreach ($dir in $Definition.commonInstallDirs) {
            $candidate = Join-Path $commonRoot $dir
            if (Test-Path -LiteralPath $candidate) {
                $paths.Add((Convert-ToForwardSlash (Resolve-Path -LiteralPath $candidate).Path))
            }
        }
    }

    foreach ($extra in $Definition.extraInstallPaths) {
        if (Test-Path -LiteralPath $extra) {
            $paths.Add((Convert-ToForwardSlash (Resolve-Path -LiteralPath $extra).Path))
        }
    }

    return $paths | Sort-Object -Unique
}

function New-GeneratedProfile {
    param(
        [object]$World,
        [string]$ProfilePath,
        [string]$ResourcesPath,
        [string[]]$AdditionalConfigLines = @()
    )

    $profileDir = Split-Path -Parent $ProfilePath
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $profileDirFull = Convert-ToForwardSlash (Resolve-Path -LiteralPath $profileDir).Path
    $userDataDir = Join-Path $profileDir "userdata"
    New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null
    $userDataDirFull = Convert-ToForwardSlash (Resolve-Path -LiteralPath $userDataDir).Path
    $dataLocalDir = Join-Path $userDataDir "data"
    New-Item -ItemType Directory -Force -Path $dataLocalDir | Out-Null
    $dataLocalDirFull = Convert-ToForwardSlash (Resolve-Path -LiteralPath $dataLocalDir).Path

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("replace=data")
    $lines.Add("replace=data-local")
    $lines.Add("replace=fallback-archive")
    $lines.Add("replace=content")
    $lines.Add("")
    $lines.Add("user-data=$userDataDirFull")
    $lines.Add("data-local=$dataLocalDirFull")

    if ($ResourcesPath) {
        $lines.Add("resources=$(Convert-ToForwardSlash $ResourcesPath)")
    }

    foreach ($dataPath in $World.dataPaths) {
        $lines.Add("data=$dataPath")
    }
    $lines.Add("")

    foreach ($archive in $World.archiveStatus.present) {
        $lines.Add("fallback-archive=$archive")
    }
    $lines.Add("")

    foreach ($content in $World.contentStatus.present) {
        $lines.Add("content=$content")
    }
    $lines.Add("")
    $lines.Add("encoding=$($World.defaultEncoding)")
    if ($AdditionalConfigLines.Count -gt 0) {
        $lines.Add("")
        foreach ($line in ($AdditionalConfigLines | Select-Object -Unique)) {
            $lines.Add($line)
        }
    }

    Set-Content -LiteralPath $ProfilePath -Value $lines -Encoding ASCII

    return [ordered]@{
        profileDirectory = $profileDirFull
        userDataDirectory = $userDataDirFull
        dataLocalDirectory = $dataLocalDirFull
    }
}

function Merge-SettingsSections {
    param(
        [System.Collections.Specialized.OrderedDictionary]$Target,
        [object]$Source
    )

    if (-not $Source) {
        return
    }

    foreach ($section in $Source.PSObject.Properties) {
        if (-not $Target.Contains($section.Name)) {
            $Target[$section.Name] = [ordered]@{}
        }

        foreach ($setting in $section.Value.PSObject.Properties) {
            $Target[$section.Name][$setting.Name] = $setting.Value
        }
    }
}

function Convert-SettingValueToString {
    param([object]$Value)

    if ($Value -is [bool]) {
        if ($Value) { return "true" }
        return "false"
    }

    return [string]$Value
}

function New-GeneratedSettings {
    param(
        [string]$WorldId,
        [string]$ProfilePath,
        [object]$SettingsCatalog
    )

    if (-not $SettingsCatalog) {
        return $null
    }

    $worldSetting = $SettingsCatalog.worlds.PSObject.Properties[$WorldId]
    if (-not $worldSetting) {
        return $null
    }

    $presetName = $worldSetting.Value.preset
    $preset = $SettingsCatalog.presets.PSObject.Properties[$presetName]
    if (-not $preset) {
        throw "Settings preset '$presetName' for world '$WorldId' is missing from $SettingsPresetPath"
    }

    $settings = [ordered]@{}
    Merge-SettingsSections -Target $settings -Source $preset.Value
    Merge-SettingsSections -Target $settings -Source $worldSetting.Value.sections

    $settingsPath = Join-Path (Split-Path -Parent $ProfilePath) "settings.cfg"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Generated by Scan-BethesdaWorlds.ps1 for $WorldId.")
    $lines.Add("# Keep this file profile-local; do not rely on ambient user settings for viewer runs.")
    $lines.Add("")

    foreach ($sectionName in $settings.Keys) {
        $lines.Add("[$sectionName]")
        foreach ($settingName in $settings[$sectionName].Keys) {
            $lines.Add("$settingName = $(Convert-SettingValueToString $settings[$sectionName][$settingName])")
        }
        $lines.Add("")
    }

    Set-Content -LiteralPath $settingsPath -Value $lines -Encoding ASCII

    return [ordered]@{
        settingsPath = Convert-ToForwardSlash $settingsPath
        preset = $presetName
    }
}

$capabilities = Get-Content -LiteralPath $CapabilityPath -Raw | ConvertFrom-Json
$capabilityById = @{}
foreach ($game in $capabilities.games) {
    $capabilityById[$game.id] = $game
}

$settingsCatalog = $null
if (Test-Path -LiteralPath $SettingsPresetPath) {
    $settingsCatalog = Get-Content -LiteralPath $SettingsPresetPath -Raw | ConvertFrom-Json
}

$OpenMWResources = Resolve-NikamiPath `
    -ParameterValue $OpenMWResources `
    -EnvName "NIKAMI_OPENMW_RESOURCES" `
    -ConfigName "openmwResources" `
    -Description "OpenMW resources directory"

$configuredSteamRoots = @(Resolve-NikamiPathList `
    -ParameterValue $ExtraSteamAppsRoots `
    -EnvName "NIKAMI_STEAM_APPS_ROOTS" `
    -ConfigName "steamAppsRoots")

$configuredFnvRoots = @(Resolve-NikamiPathList `
    -ParameterValue $ExtraFalloutNewVegasInstallPaths `
    -EnvName "NIKAMI_FNV_ROOT" `
    -ConfigName "fnvRoot")

$definitions = @()
$definitions += (New-WorldDefinition -Id "morrowind" -DataSubpath "Data Files" -SteamAppIds @("22320") -CommonInstallDirs @("Morrowind"))
$definitions += (New-WorldDefinition -Id "oblivion" -DataSubpath "Data" -SteamAppIds @("22330") -CommonInstallDirs @("Oblivion"))
$definitions += (New-WorldDefinition -Id "fallout3" -DataSubpath "Data" -SteamAppIds @("22370", "22300") -CommonInstallDirs @("Fallout 3 goty", "Fallout 3"))
$definitions += (New-WorldDefinition -Id "fallout_new_vegas" -DataSubpath "Data" -SteamAppIds @("22380") -CommonInstallDirs @("Fallout New Vegas") -ExtraInstallPaths $configuredFnvRoots)
$definitions += (New-WorldDefinition -Id "skyrim_2011" -DataSubpath "Data" -SteamAppIds @("72850") -CommonInstallDirs @("Skyrim"))
$definitions += (New-WorldDefinition -Id "skyrim_vr" -DataSubpath "Data" -SteamAppIds @("611670") -CommonInstallDirs @("SkyrimVR"))
$definitions += (New-WorldDefinition -Id "fallout4" -DataSubpath "Data" -SteamAppIds @("377160") -CommonInstallDirs @("Fallout 4"))
$definitions += (New-WorldDefinition -Id "fallout4_vr" -DataSubpath "Data" -SteamAppIds @("611660") -CommonInstallDirs @("Fallout 4 VR"))
$definitions += (New-WorldDefinition -Id "fallout76" -DataSubpath "Data" -SteamAppIds @("1151340") -CommonInstallDirs @("Fallout76"))
$definitions += (New-WorldDefinition -Id "starfield" -DataSubpath "Data" -SteamAppIds @("1716740") -CommonInstallDirs @("Starfield"))

$steamRoots = @(Get-SteamLibraryRoots -ExtraRoots $configuredSteamRoots)
$steamApps = @(Get-SteamApps -SteamAppsRoots $steamRoots)

$worlds = @()
foreach ($definition in $definitions) {
    $cap = $capabilityById[$definition.id]
    $installCandidates = @(Get-InstallCandidates -Definition $definition -SteamApps $steamApps -SteamAppsRoots $steamRoots)
    $installPath = $null
    foreach ($candidate in $installCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate $definition.dataSubpath)) {
            $installPath = $candidate
            break
        }
    }
    if (-not $installPath -and $installCandidates.Count -gt 0) {
        $installPath = $installCandidates[0]
    }

    $dataPaths = @()
    $profileConfig = $null
    $additionalProfileConfigLines = @()
    $fnvRoot = if ($definition.id -eq "fallout_new_vegas" -and $configuredFnvRoots.Count -gt 0) { $configuredFnvRoots[0] } else { "" }
    $fnvProfileConfig = if ($fnvRoot) { Join-Path $fnvRoot "openmw-config/openmw.cfg" } else { "" }
    if ($definition.id -eq "fallout_new_vegas" -and $fnvProfileConfig -and (Test-Path -LiteralPath $fnvProfileConfig)) {
        $profileConfig = Convert-ToForwardSlash (Resolve-Path -LiteralPath $fnvProfileConfig).Path
        $additionalProfileConfigLines = @(Get-Content -LiteralPath $fnvProfileConfig | Where-Object { $_ -match '^\s*fallback\s*=' })
        $fnvOverlayData = Join-Path $fnvRoot "openmw-config/data"
        if (Test-Path -LiteralPath $fnvOverlayData) {
            $dataPaths += Convert-ToForwardSlash (Resolve-Path -LiteralPath $fnvOverlayData).Path
        }
        if ($installPath) {
            $fnvGameData = Join-Path $installPath $definition.dataSubpath
            if (Test-Path -LiteralPath $fnvGameData) {
                $dataPaths += Convert-ToForwardSlash (Resolve-Path -LiteralPath $fnvGameData).Path
            }
        }
    } elseif ($installPath) {
        $dataPath = Join-Path $installPath $definition.dataSubpath
        if (Test-Path -LiteralPath $dataPath) {
            $dataPaths += Convert-ToForwardSlash (Resolve-Path -LiteralPath $dataPath).Path
        }
    }

    $primaryDataPath = if ($dataPaths.Count -gt 0) { $dataPaths[-1] } else { $null }
    $contentFiles = if ($primaryDataPath) { @(Get-FileNamesByExtension -BasePath $primaryDataPath -Extensions @("esm", "esp", "esl")) } else { @() }
    $archiveFiles = if ($primaryDataPath) { @(Get-FileNamesByExtension -BasePath $primaryDataPath -Extensions @("bsa", "ba2")) } else { @() }

    $requiredContent = @($cap.content)
    $requiredArchives = @($cap.archives)
    $contentStatus = if ($primaryDataPath) { Test-FilesPresent -BasePath $primaryDataPath -Files $requiredContent } else { [ordered]@{ present = @(); missing = $requiredContent } }
    $archiveStatus = if ($primaryDataPath) { Test-FilesPresent -BasePath $primaryDataPath -Files $requiredArchives } else { [ordered]@{ present = @(); missing = $requiredArchives } }
    $viewerArchiveFiles = @()
    foreach ($archive in $requiredArchives) {
        if ($archiveStatus.present -contains $archive -and $viewerArchiveFiles -notcontains $archive) {
            $viewerArchiveFiles += $archive
        }
    }
    foreach ($archive in $archiveFiles) {
        if ($viewerArchiveFiles -notcontains $archive) {
            $viewerArchiveFiles += $archive
        }
    }

    $installStatus = "missing"
    if ($installPath -and -not $primaryDataPath) {
        $installStatus = "incomplete"
    } elseif ($primaryDataPath -and $requiredContent.Count -eq 0) {
        $installStatus = "discovered"
    } elseif ($primaryDataPath -and $contentStatus.missing.Count -eq 0) {
        $installStatus = "ready"
    } elseif ($primaryDataPath) {
        $installStatus = "incomplete"
    }

    if ($definition.id -eq "starfield" -and $primaryDataPath -and $contentStatus.missing -contains "Starfield.esm") {
        $installStatus = "incomplete-download"
    }

    $profileStatus = "not-generated"
    $generatedProfile = $null
    $generatedSettings = $null
    $settingsPreset = $null
    $profileDirectory = $null
    $userDataDirectory = $null
    $profileHashes = $null
    if ($GenerateProfiles -and $cap.openmwTarget -and $installStatus -eq "ready") {
        $generatedProfile = Convert-ToForwardSlash (Join-Path (Join-Path $ProfilesRoot $definition.id) "openmw.cfg")
        $profileInfo = New-GeneratedProfile -World ([pscustomobject]@{
            dataPaths = $dataPaths
            archiveStatus = [ordered]@{
                present = $viewerArchiveFiles
                missing = $archiveStatus.missing
            }
            contentStatus = $contentStatus
            defaultEncoding = $cap.defaultEncoding
        }) -ProfilePath $generatedProfile -ResourcesPath $OpenMWResources -AdditionalConfigLines $additionalProfileConfigLines
        $settingsInfo = New-GeneratedSettings -WorldId $definition.id -ProfilePath $generatedProfile -SettingsCatalog $settingsCatalog
        $profileDirectory = $profileInfo.profileDirectory
        $userDataDirectory = $profileInfo.userDataDirectory
        if ($settingsInfo) {
            $generatedSettings = $settingsInfo.settingsPath
            $settingsPreset = $settingsInfo.preset
        }
        $profileHashes = [ordered]@{
            openmwCfgSha256 = (Get-FileHash -LiteralPath $generatedProfile -Algorithm SHA256).Hash
            settingsCfgSha256 = if ($generatedSettings) { (Get-FileHash -LiteralPath $generatedSettings -Algorithm SHA256).Hash } else { $null }
        }
        $profileStatus = "generated"
    }

    $worlds += [ordered]@{
        id = $definition.id
        displayName = $cap.displayName
        supportTier = $cap.supportTier
        openmwTarget = [bool]$cap.openmwTarget
        installStatus = $installStatus
        installPath = $installPath
        dataPaths = $dataPaths
        existingProfileConfig = $profileConfig
        generatedProfileConfig = $generatedProfile
        generatedSettingsConfig = $generatedSettings
        settingsPreset = $settingsPreset
        profileDirectory = $profileDirectory
        userDataDirectory = $userDataDirectory
        profileHashes = $profileHashes
        profileStatus = $profileStatus
        defaultEncoding = $cap.defaultEncoding
        detectedContentFiles = $contentFiles
        detectedArchiveFiles = $archiveFiles
        contentStatus = $contentStatus
        archiveStatus = $archiveStatus
        viewerArchiveFiles = $viewerArchiveFiles
        isolationGuards = if ($generatedProfile) { @(
            "launch with --replace config --config $profileDirectory",
            "profile openmw.cfg replaces data, data-local, fallback-archive, and content",
            "profile user-data is $userDataDirectory",
            "profile data-local is profile-local to prevent global OpenMW loose-file bleed",
            "profile settings are $generatedSettings",
            $(if ($additionalProfileConfigLines.Count -gt 0) { "profile imports $($additionalProfileConfigLines.Count) fallback lines from existing local config" } else { "profile has no imported local fallback lines" })
        ) } else { @() }
        notes = $cap.notes
    }
}

$result = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    machine = $env:COMPUTERNAME
    steamAppsRoots = $steamRoots
    worlds = $worlds
}

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding ASCII
Write-Host "Wrote $OutputPath"
if ($GenerateProfiles) {
    Write-Host "Generated profiles under $ProfilesRoot"
}
