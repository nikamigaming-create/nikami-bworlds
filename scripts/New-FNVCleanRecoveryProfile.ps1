[CmdletBinding()]
param(
    [string]$SourceProfileDirectory = "D:/code/nikami-worlds/profiles/fallout_new_vegas",
    [string]$BinaryRoot = "local/openmw-pristine-mads-33568a",
    [string]$EngineCommit = "33568aec1d425d511f7a0b0eb743b3246da681ba",
    [string]$OfficialDataRoot = "D:/SteamLibrary/steamapps/common/Fallout New Vegas/Data",
    [string]$UiBridgeRoot = "D:/Modlists/fnv/openmw-config/data",
    [string]$OutputRoot = "run/fnv-pristine-mads-profile/33568a",
    [string]$TargetSettingsSchemaPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-CanonicalTreeHash([string]$Root) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $rows = foreach ($file in Get-ChildItem -LiteralPath $rootPath -Recurse -File | Sort-Object FullName) {
        if (-not $file.FullName.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Tree-hash file escaped its root: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relative`t$($file.Length)`t$hash"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($rows -join "`n") + "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function New-IniSettingsDocument {
    param(
        [string[]]$LayerPaths,
        [string[]]$SourceModelLines,
        [string[]]$SourceVrLines,
        [Collections.Generic.HashSet[string]]$AllowedSettingPairs,
        [Collections.Generic.List[string]]$SkippedSettingPairs
    )

    $sectionOrder = New-Object Collections.Generic.List[string]
    $sectionNames = @{}
    $values = @{}

    function Set-IniValue([string]$Section, [string]$Key, [string]$Value) {
        $pair = "$Section`n$Key"
        if ($null -ne $AllowedSettingPairs -and -not $AllowedSettingPairs.Contains($pair)) {
            if ($null -ne $SkippedSettingPairs -and -not $SkippedSettingPairs.Contains("[$Section] $Key")) {
                $SkippedSettingPairs.Add("[$Section] $Key") | Out-Null
            }
            return
        }
        $sectionId = $Section.ToLowerInvariant()
        if (-not $sectionNames.ContainsKey($sectionId)) {
            $sectionNames[$sectionId] = $Section
            $sectionOrder.Add($sectionId) | Out-Null
        }
        if (-not $values.ContainsKey($sectionId)) {
            $values[$sectionId] = [ordered]@{}
        }
        $values[$sectionId][$Key] = $Value
    }

    foreach ($path in $LayerPaths) {
        $section = ""
        foreach ($line in Get-Content -LiteralPath $path) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\[(.+)\]$') {
                $section = $matches[1]
                continue
            }
            if ([string]::IsNullOrWhiteSpace($section) -or [string]::IsNullOrWhiteSpace($trimmed) -or
                $trimmed.StartsWith('#') -or -not $trimmed.Contains('=')) {
                continue
            }
            $separator = $trimmed.IndexOf('=')
            Set-IniValue $section $trimmed.Substring(0, $separator).Trim() $trimmed.Substring($separator + 1).Trim()
        }
    }

    # Bethesda's 20.2.0.7 meshes are an explicit compatibility requirement,
    # not a graphics mod or a renderer override.
    Set-IniValue "Models" "load unsupported nif files" "true"
    Set-IniValue "Video" "resolution x" "1600"
    Set-IniValue "Video" "resolution y" "900"

    foreach ($sourceSectionLines in @($SourceModelLines, $SourceVrLines)) {
        $sourceSection = ""
        foreach ($line in $sourceSectionLines) {
            $trimmed = $line.Trim()
            if ($trimmed -match '^\[(.+)\]$') {
                $sourceSection = $matches[1]
                continue
            }
            if ([string]::IsNullOrWhiteSpace($sourceSection) -or [string]::IsNullOrWhiteSpace($trimmed) -or
                $trimmed.StartsWith('#') -or -not $trimmed.Contains('=')) {
                continue
            }
            $separator = $trimmed.IndexOf('=')
            $key = $trimmed.Substring(0, $separator).Trim()
            if ($sourceSection -ieq "Models" -and @(
                    "skyatmosphere",
                    "skyclouds",
                    "skynight01",
                    "skynight02"
                ) -icontains $key) {
                # These source-profile overrides force Morrowind-style sky
                # models through an FNV renderer path whose SkyShaderProperty
                # support is not complete. Keep them quarantined until that
                # renderer slice has paired visual evidence.
                continue
            }
            Set-IniValue $sourceSection $key $trimmed.Substring($separator + 1).Trim()
        }
    }

    $result = New-Object Collections.Generic.List[string]
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sectionId in $sectionOrder) {
        $sectionName = [string]$sectionNames[$sectionId]
        $result.Add("[$sectionName]") | Out-Null
        foreach ($entry in $values[$sectionId].GetEnumerator()) {
            $pair = "$sectionName`n$($entry.Key)"
            if (-not $seen.Add($pair)) {
                throw "Duplicate generated setting: [$sectionName] $($entry.Key)"
            }
            $result.Add("$($entry.Key) = $($entry.Value)") | Out-Null
        }
        $result.Add("") | Out-Null
    }
    return ,$result.ToArray()
}

function Get-IniSectionLines([string[]]$Lines, [string]$SectionName) {
    $inside = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            if ($inside) {
                break
            }
            $inside = $matches[1] -ieq $SectionName
            if ($inside) {
                $line
            }
            continue
        }
        if ($inside) {
            $line
        }
    }
}

$sourceProfile = [IO.Path]::GetFullPath($SourceProfileDirectory)
$binary = Resolve-RepoPath $BinaryRoot
$officialData = [IO.Path]::GetFullPath($OfficialDataRoot)
$uiBridge = [IO.Path]::GetFullPath($UiBridgeRoot)
$output = Resolve-RepoPath $OutputRoot
$sourceOpenmw = Join-Path $sourceProfile "openmw.cfg"
$sourceSettings = Join-Path $sourceProfile "settings.cfg"
$targetSettingsSchema = if ([string]::IsNullOrWhiteSpace($TargetSettingsSchemaPath)) {
    $null
} else {
    [IO.Path]::GetFullPath($TargetSettingsSchemaPath)
}
if ($EngineCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "EngineCommit must be a full 40-character Git object ID."
}
$denominatorPath = Join-Path $repoRoot "catalog/fnv-parity-denominators.json"
$boundedSettingsPath = Join-Path $repoRoot "config/playable-baseline/settings.cfg"
$fnvSettingsPath = Join-Path $repoRoot "config/fnv-playable-graphics/settings.cfg"

foreach ($required in @(
        $sourceOpenmw,
        $sourceSettings,
        $denominatorPath,
        $boundedSettingsPath,
        $fnvSettingsPath,
        (Join-Path $binary "openmw.exe"),
        (Join-Path $binary "openmw_vr.exe"),
        (Join-Path $binary "resources"),
        $officialData,
        $uiBridge
    )) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing clean-recovery profile input: $required"
    }
}
if ($null -ne $targetSettingsSchema -and -not (Test-Path -LiteralPath $targetSettingsSchema -PathType Leaf)) {
    throw "Missing target settings schema: $targetSettingsSchema"
}

$denominators = Get-Content -LiteralPath $denominatorPath -Raw -Encoding UTF8 | ConvertFrom-Json
$masters = @($denominators.officialMasters)
$archives = @($denominators.officialArchives | Sort-Object { [int]$_.order })
if ($masters.Count -ne 10 -or $archives.Count -ne 21) {
    throw "Frozen FNV scope must contain exactly 10 masters and 21 archives."
}
foreach ($entry in @($masters) + @($archives)) {
    $path = Join-Path $officialData ([string]$entry.name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Frozen official FNV input is missing: $path"
    }
    if ((Get-Item -LiteralPath $path).Length -ne [long]$entry.bytes) {
        throw "Frozen official FNV input size differs: $path"
    }
}

if (Test-Path -LiteralPath $output) {
    throw "Refusing to overwrite clean-recovery profile output: $output"
}
$userData = Join-Path $output "userdata"
$dataLocal = Join-Path $userData "data"
[IO.Directory]::CreateDirectory($dataLocal) | Out-Null

$profileLines = New-Object Collections.Generic.List[string]
$dataInserted = $false
foreach ($line in Get-Content -LiteralPath $sourceOpenmw) {
    if ($line -match '^\s*user-data\s*=') {
        $profileLines.Add("user-data=$($userData.Replace('\', '/'))") | Out-Null
        continue
    }
    if ($line -match '^\s*data-local\s*=') {
        $profileLines.Add("data-local=$($dataLocal.Replace('\', '/'))") | Out-Null
        continue
    }
    if ($line -match '^\s*resources\s*=') {
        $resources = (Join-Path $binary "resources").Replace('\', '/')
        $profileLines.Add("resources=$resources") | Out-Null
        continue
    }
    if ($line -match '^\s*data\s*=') {
        if (-not $dataInserted) {
            $profileLines.Add("data=$($uiBridge.Replace('\', '/'))") | Out-Null
            $profileLines.Add("data=$($officialData.Replace('\', '/'))") | Out-Null
            $dataInserted = $true
        }
        continue
    }
    if ($line -match '^\s*content\s*=\s*FNVR\.esp\s*$') {
        continue
    }
    $profileLines.Add($line) | Out-Null
}
if (-not $dataInserted) {
    throw "Source profile did not contain a data declaration."
}

$content = @($profileLines | Where-Object { $_ -match '^\s*content\s*=' } | ForEach-Object {
    ($_ -split '=', 2)[1].Trim()
})
$expectedContent = @($masters | ForEach-Object { [string]$_.name })
if (($content -join "`n") -ne ($expectedContent -join "`n")) {
    throw "Sanitized profile content order differs from the frozen official master order."
}
$profileText = ($profileLines -join "`n") + "`n"
if ($profileText -match '(?im)^\s*(?:data|fallback-archive)\s*=.*morrowind' -or
    $profileText -match '(?im)^\s*content\s*=.*(?:FNVR|\.esp)') {
    throw "Sanitized recovery profile contains a non-official plugin or Morrowind data/archive."
}
[IO.File]::WriteAllText((Join-Path $output "openmw.cfg"), $profileText, (New-Object Text.UTF8Encoding($false)))

$sourceSettingsLines = @(Get-Content -LiteralPath $sourceSettings)
$sourceModelLines = @(Get-IniSectionLines $sourceSettingsLines "Models")
$sourceVrLines = @(Get-IniSectionLines $sourceSettingsLines "VR")
if ($sourceModelLines.Count -eq 0) {
    throw "Source profile has no Fallout model compatibility section."
}
if ($sourceVrLines.Count -eq 0) {
    throw "Source profile has no calibrated Mads VR settings section."
}

$allowedSettingPairs = $null
if ($null -ne $targetSettingsSchema) {
    $allowedSettingPairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $schemaSection = ""
    foreach ($line in Get-Content -LiteralPath $targetSettingsSchema) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[(.+)\]$') {
            $schemaSection = $matches[1]
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($schemaSection) -and -not [string]::IsNullOrWhiteSpace($trimmed) -and
            -not $trimmed.StartsWith('#') -and $trimmed.Contains('=')) {
            $key = $trimmed.Substring(0, $trimmed.IndexOf('=')).Trim()
            $allowedSettingPairs.Add("$schemaSection`n$key") | Out-Null
        }
    }
}
$skippedSettingPairs = New-Object Collections.Generic.List[string]
$settings = New-IniSettingsDocument -LayerPaths @($boundedSettingsPath, $fnvSettingsPath) `
    -SourceModelLines $sourceModelLines -SourceVrLines $sourceVrLines `
    -AllowedSettingPairs $allowedSettingPairs -SkippedSettingPairs $skippedSettingPairs
[IO.File]::WriteAllLines((Join-Path $output "settings.cfg"), $settings, (New-Object Text.UTF8Encoding($false)))

$seed = [ordered]@{
    schemaVersion = 1
    worlds = @([ordered]@{
        id = "fallout_new_vegas"
        displayName = "Fallout: New Vegas clean recovery"
        readyForWorldWalker = $true
        installStatus = "ready"
        profileStatus = "generated"
        profileDirectory = $output.Replace('\', '/')
    })
}
$seed | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output "seed.json") -Encoding utf8

$profileHash = Get-CanonicalTreeHash $output
$manifest = [ordered]@{
    schema = "nikami-fnv-clean-recovery-profile/v1"
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    engineCommit = $EngineCommit.ToLowerInvariant()
    binaryRoot = $binary.Replace('\', '/')
    flatBinarySha256 = (Get-FileHash -LiteralPath (Join-Path $binary "openmw.exe") -Algorithm SHA256).Hash.ToLowerInvariant()
    vrBinarySha256 = (Get-FileHash -LiteralPath (Join-Path $binary "openmw_vr.exe") -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceOpenmwCfgSha256 = (Get-FileHash -LiteralPath $sourceOpenmw -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceSettingsCfgSha256 = (Get-FileHash -LiteralPath $sourceSettings -Algorithm SHA256).Hash.ToLowerInvariant()
    uiBridgeRoot = $uiBridge.Replace('\', '/')
    uiBridgeTreeSha256 = Get-CanonicalTreeHash $uiBridge
    officialDataRoot = $officialData.Replace('\', '/')
    officialMasterCount = $masters.Count
    officialArchiveCount = $archives.Count
    content = $content
    morrowindDataOrArchive = $false
    graphicsMods = @()
    dynamicShaderStateCopied = $false
    unsupportedNifFiles = $true
    quarantinedSkyModelOverrides = @(
        "skyatmosphere",
        "skyclouds",
        "skynight01",
        "skynight02"
    )
    duplicateSettingPairs = 0
    targetSettingsSchemaSha256 = if ($null -eq $targetSettingsSchema) { $null } else {
        (Get-FileHash -LiteralPath $targetSettingsSchema -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    skippedUnsupportedSettings = @($skippedSettingPairs.ToArray())
    profileTreeSha256BeforeManifest = $profileHash
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output "manifest.json") -Encoding utf8

Write-Output (Join-Path $output "manifest.json")
