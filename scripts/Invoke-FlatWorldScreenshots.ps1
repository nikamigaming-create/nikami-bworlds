param(
    [string[]]$WorldId = @(),
    [string]$SeedPath = "catalog/world-walker.seed.json",
    [string]$StartsPath = "catalog/flat-world-proof-starts.json",
    [string]$BinaryRoot = "",
    [string]$ProofRoot = "proof/flat-world-screenshots",
    [int]$RunSeconds = 0,
    [string]$ScreenshotFrames = "",
    [string]$StartCellOverride = "",
    [int]$WindowCaptureSeconds = 0,
    [int]$TelemetryInterval = 30,
    [int]$RefTelemetryLimit = 2000,
    [int]$ScreenshotReadyFrames = -1,
    [int]$Esm4GridRadius = -1,
    [switch]$NoTelemetry,
    [switch]$PreserveNativeMaterials,
    [switch]$FullbrightNativeMaterials,
    [switch]$FullbrightActorMaterialsOnly,
    [switch]$DisableActors,
    [switch]$RenderDisabledActors,
    [string]$FocusActor = "",
    [switch]$DisableSky,
    [switch]$AllowOsgUpdateTraversal,
    [switch]$StripOsgUpdateCallbacks,
    [switch]$StripOsgNodeUpdateCallbacks,
    [switch]$StripOsgStateSetUpdateCallbacks,
    [string[]]$StripOsgUpdateCallbackClass = @(),
    [string[]]$KeepOsgUpdateCallbackPath = @(),
    [int]$OsgUpdateCallbackAuditLimit = 120,
    [double]$StartPosX = [double]::NaN,
    [double]$StartPosY = [double]::NaN,
    [double]$StartPosZ = [double]::NaN,
    [double]$StartRotX = [double]::NaN,
    [double]$StartRotY = [double]::NaN,
    [double]$StartRotZ = [double]::NaN,
    [int]$StartGridX = [int]::MinValue,
    [int]$StartGridY = [int]::MinValue,
    [double]$CameraPosX = [double]::NaN,
    [double]$CameraPosY = [double]::NaN,
    [double]$CameraPosZ = [double]::NaN,
    [double]$CameraTargetX = [double]::NaN,
    [double]$CameraTargetY = [double]::NaN,
    [double]$CameraTargetZ = [double]::NaN,
    [switch]$AllowBadScreenshots,
    [switch]$AllowLegacySyntheticProof,
    [switch]$ShowGui,
    [switch]$DryRun,
    [string[]]$SetEnv = @(),
    [switch]$KeepRunning,
    [string]$RunLedgerPath = "proof/world-viewer-run-ledger.jsonl"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

if (-not $AllowLegacySyntheticProof) {
    throw "Invoke-FlatWorldScreenshots.ps1 is a legacy synthetic screenshot harness. Use scripts/Start-WorldProfileExisting.ps1 for real OpenMW profile launches, or pass -AllowLegacySyntheticProof only for isolated diagnostics."
}

function Convert-ToForwardSlash([string]$Path) {
    return ($Path -replace "\\", "/")
}

function Quote-CommandArg([string]$Arg) {
    if ($Arg -match '[\s"]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-ProcessEnvValue([string]$Name, $Value) {
    if ($null -eq $Value) {
        [Environment]::SetEnvironmentVariable($Name, $null, "Process")
        return
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        [Environment]::SetEnvironmentVariable($Name, $null, "Process")
        return
    }

    [Environment]::SetEnvironmentVariable($Name, $text, "Process")
}

function Set-ProcessEnvFloatOverride([string]$Name, [double]$Value) {
    if ([double]::IsNaN($Value)) {
        return $false
    }
    [Environment]::SetEnvironmentVariable(
        $Name,
        $Value.ToString("R", [System.Globalization.CultureInfo]::InvariantCulture),
        "Process")
    return $true
}

function Set-ProcessEnvIntOverride([string]$Name, [int]$Value) {
    if ($Value -eq [int]::MinValue) {
        return $false
    }
    [Environment]::SetEnvironmentVariable(
        $Name,
        $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "Process")
    return $true
}

function ConvertTo-ProcessEnvOverrides([string[]]$Assignments) {
    $overrides = New-Object System.Collections.Generic.List[object]
    foreach ($assignment in @($Assignments)) {
        if ([string]::IsNullOrWhiteSpace($assignment)) {
            continue
        }

        $separator = $assignment.IndexOf("=")
        if ($separator -lt 1) {
            throw "-SetEnv expects NAME=VALUE, got: $assignment"
        }

        $name = $assignment.Substring(0, $separator).Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "-SetEnv has an invalid environment variable name: $name"
        }

        $overrides.Add([pscustomobject][ordered]@{
            name = $name
            value = $assignment.Substring($separator + 1)
        }) | Out-Null
    }

    return @($overrides.ToArray())
}

function Set-ProcessEnvOverrides($Overrides) {
    foreach ($override in @($Overrides)) {
        Set-ProcessEnvValue ([string]$override.name) $override.value
    }
}

function New-ProofRunConfig($World, [string]$WorldRunDir, [string]$UserDataDir) {
    $sourceConfigDir = [string]$World.profileDirectory
    if ([string]::IsNullOrWhiteSpace($sourceConfigDir) -or -not (Test-Path -LiteralPath $sourceConfigDir)) {
        throw "$($World.id): missing generated profile directory $sourceConfigDir"
    }

    $runConfigDir = Join-Path $WorldRunDir "config"
    $dataLocalDir = Join-Path $UserDataDir "data"
    if ([string]$World.id -eq "starfield" -and $dataLocalDir.Length -gt 80) {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
        $dataLocalDir = Join-Path (Join-Path $repoRoot "local\proof-data") ("starfield-{0}" -f ([System.Guid]::NewGuid().ToString("N").Substring(0, 12)))
    }
    New-Item -ItemType Directory -Force -Path $runConfigDir, $UserDataDir, $dataLocalDir | Out-Null

    foreach ($name in @("openmw.cfg", "settings.cfg", "shaders.yaml")) {
        $source = Join-Path $sourceConfigDir $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $runConfigDir $name) -Force
        }
    }

    $cfgPath = Join-Path $runConfigDir "openmw.cfg"
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        throw "$($World.id): copied proof config is missing openmw.cfg"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $hasReplaceDataLocal = $false
    foreach ($line in Get-Content -LiteralPath $cfgPath) {
        if ($line -match '^\s*replace\s*=\s*data-local\s*$') {
            $hasReplaceDataLocal = $true
        }
        if ($line -match '^\s*(user-data|data-local)\s*=') {
            continue
        }
        $lines.Add($line)
    }
    if (-not $hasReplaceDataLocal) {
        $insertAt = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*replace\s*=') {
                $insertAt = $i + 1
            }
        }
        $lines.Insert($insertAt, "replace=data-local")
    }
    $lines.Add("")
    $lines.Add("user-data=$(Convert-ToForwardSlash $UserDataDir)")
    $lines.Add("data-local=$(Convert-ToForwardSlash $dataLocalDir)")
    Set-Content -LiteralPath $cfgPath -Value $lines -Encoding ASCII

    [pscustomobject][ordered]@{
        configDirectory = (Resolve-Path -LiteralPath $runConfigDir).Path
        dataLocalDirectory = (Resolve-Path -LiteralPath $dataLocalDir).Path
        openmwCfg = (Resolve-Path -LiteralPath $cfgPath).Path
    }
}

function Get-OpenMwConfigDataDirectories([string]$OpenMwCfg) {
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $OpenMwCfg) {
        $match = [regex]::Match($line, '^\s*data\s*=\s*(?<path>.+?)\s*$')
        if (-not $match.Success) {
            continue
        }
        $path = ($match.Groups["path"].Value -replace '/', '\').Trim()
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            $dirs.Add((Resolve-Path -LiteralPath $path).Path)
        }
    }
    return @($dirs.ToArray() | Select-Object -Unique)
}

function Find-StarfieldTextureArchive([string[]]$DataDirectories, [string]$RelativeTexturePath, [string]$BsaTool) {
    foreach ($dataDir in $DataDirectories) {
        $archives = Get-ChildItem -LiteralPath $dataDir -File -Filter "Starfield - Textures*.ba2" -ErrorAction SilentlyContinue |
            Sort-Object Name
        foreach ($archive in $archives) {
            $match = & $BsaTool list $archive.FullName 2>$null |
                Select-String -SimpleMatch $RelativeTexturePath |
                Select-Object -First 1
            if ($null -ne $match) {
                return $archive.FullName
            }
        }
    }
    return ""
}

function Get-StarfieldOpacityTexturePath([string]$Texture) {
    $normalized = $Texture -replace '\\', '/'
    $lower = $normalized.ToLowerInvariant()
    if ($lower -notmatch '^textures/actors/human/faces/(hair|beards|eyebrows)/') {
        return ""
    }
    if ($lower -notmatch '_color\.dds$') {
        return ""
    }

    $directory = [System.IO.Path]::GetDirectoryName($normalized).Replace('\', '/')
    $filename = [System.IO.Path]::GetFileName($normalized)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($filename)

    if ($stem -match '^(?<base>.+_shared)_[^_]+_color$') {
        return "$directory/$($Matches.base)_opacity.dds"
    }
    if ($stem -match '^(?<base>eyebrows_[^_]+)_[^_]+_color$') {
        return "$directory/$($Matches.base)_opacity.dds"
    }
    if ($stem -match '^(?<base>child_eyebrows_[^_]+)_[^_]+_color$') {
        return "$directory/$($Matches.base)_opacity.dds"
    }

    return ($normalized -replace '_color\.dds$', '_opacity.dds')
}

function Convert-StarfieldActorProofTextures([string]$OpenMwCfg, [string]$DataLocalDirectory, [string]$BinaryRoot) {
    $bsaTool = Join-Path $BinaryRoot "bsatool.exe"
    if (-not (Test-Path -LiteralPath $bsaTool)) {
        Write-Warning "Starfield actor texture cache skipped: missing bsatool.exe at $bsaTool"
        return [pscustomobject][ordered]@{
            count = 0
            alphaMerged = 0
            alphaNonOpaquePixels = 0
            ledgerPath = $null
        }
    }

    $dataDirs = @(Get-OpenMwConfigDataDirectories -OpenMwCfg $OpenMwCfg)
    if ($dataDirs.Count -eq 0) {
        Write-Warning "Starfield actor texture cache skipped: no data= directories in $OpenMwCfg"
        return [pscustomobject][ordered]@{
            count = 0
            alphaMerged = 0
            alphaNonOpaquePixels = 0
            ledgerPath = $null
        }
    }

    $textures = @(
        "textures/actors/human/faces/chargen/male_default_sk3_color.dds",
        "textures/actors/human/faces/chargen/female_default_sk3_color.dds",
        "textures/actors/human/faces/beards/beard_shared_brown_color.dds",
        "textures/actors/human/faces/hair/afro_hair_shared_brown_color.dds",
        "textures/actors/human/faces/hair/short_hair_shared_brown_color.dds",
        "textures/actors/human/faces/eyebrows/eyebrows_fluffy_brown_color.dds",
        "textures/actors/human/faces/eyebrows/femaleeyebrows01_color.dds",
        "textures/actors/human/faces/eyelashes/malelashes01_color.dds",
        "textures/actors/human/faces/eyelashes/femalelashes01_color.dds",
        "textures/actors/human/faces/eyes/eye_tear_color.dds",
        "textures/actors/human/faces/teeth/nnteeth_color.dds",
        "textures/actors/human/naked_body/nakedbodym_sk3_color.dds",
        "textures/actors/human/naked_body/nakedbodyf_sk3_color.dds",
        "textures/actors/human/hands/defaulthandsm_sk3_color.dds",
        "textures/actors/human/hands/defaulthandsf_sk3_color.dds",
        "textures/clothes/outfit_service_uniform_01/outfit_service_uniform_lowerbody_01_color.dds",
        "textures/clothes/outfit_service_uniform_01/outfit_service_uniform_sleeves_01_color.dds",
        "textures/clothes/outfit_service_uniform_01/outfit_service_uniform_upperbody_01_color.dds",
        "textures/clothes/outfit_employee_uniform_formal_01/outfit_employee_uniform_formal_lowerbody_01_color.dds",
        "textures/clothes/outfit_employee_uniform_formal_01/outfit_employee_uniform_formal_sleeves_01_color.dds",
        "textures/clothes/outfit_employee_uniform_formal_01/outfit_employee_uniform_formal_upperbody_01_color.dds",
        "textures/clothes/outfit_ucpolice/outfit_ucsecurity_arms_mat_color.dds",
        "textures/clothes/outfit_ucpolice/outfit_ucsecurity_helmet_mat_color.dds",
        "textures/clothes/outfit_ucpolice/outfit_ucsecurity_legsandacc_mat_color.dds",
        "textures/clothes/outfit_ucpolice/outfit_ucsecurity_torso_mat_color.dds",
        "textures/clothes/outfit_ucpolice/outfit_ucsecurity_visor_mat_color.dds",
        "textures/clothes/spacesuit_ecliptic/spacesuit_ecliptic_flightcap_color.dds",
        "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_hat_color.dds",
        "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_sleeves_color.dds",
        "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_upperbody_color.dds",
        "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_f/outfit_colonist_quarterpaddedvest_01_lowerbody_f_color.dds",
        "textures/clothes/outfit_colonist_quarterpaddedvest_01/outfit_colonist_quarterpaddedvest_01_m/outfit_colonist_quarterpaddedvest_01_lowerbody_m_color.dds",
        "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_mechanic_lowerbody_01_color.dds",
        "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_mechanic_sleeves_01_color.dds",
        "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_mechanic_upperbody_01_color.dds",
        "textures/clothes/outfit_utilityoveralls_01/headwear_ssohat_01_color.dds",
        "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_sso_jacket_sleeves_01_color.dds",
        "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_sso_jacket_upperbody_01_color.dds",
        "textures/clothes/outfit_utilityoveralls_01/outfit_utilityoveralls_sso_jacket_cooling_upperbody_01_color.dds",
        "textures/architecture/city/newatlantis/naglasspattern02_color.dds",
        "textures/architecture/city/newatlantis/nagrassastroturf01_color.dds",
        "textures/architecture/city/newatlantis/nacarpet01b_color.dds",
        "textures/architecture/city/newatlantis/naterminalsignage01_color.dds",
        "textures/architecture/city/newatlantis/nametalbrasspattern01_color.dds",
        "textures/architecture/city/newatlantis/nastone01mossy01_color.dds",
        "textures/architecture/city/newatlantis/nascreenpattern01_color.dds",
        "textures/architecture/city/newatlantis/naplasticcirclepattern01_color.dds",
        "textures/architecture/city/newatlantis/natilefloor01_color.dds",
        "textures/architecture/city/newatlantis/naconcretemossy01_color.dds",
        "textures/architecture/city/newatlantis/naconcreteprinted02_color.dds"
    )
    $extractRoot = Join-Path $DataLocalDirectory "__starfield_texture_extract"
    $converted = 0
    $alphaMerged = 0
    $alphaNonOpaquePixels = 0
    $cacheLedger = New-Object System.Collections.Generic.List[object]
    $converter = @'
import sys
import json
from pathlib import Path
from PIL import Image

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
opacity = Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None
dst.parent.mkdir(parents=True, exist_ok=True)
image = Image.open(src)
image.load()
if image.mode != "RGBA":
    image = image.convert("RGBA")
alpha_source = "color-alpha" if image.getextrema()[3] != (255, 255) else "opaque"
if opacity and opacity.exists():
    mask = Image.open(opacity)
    mask.load()
    if mask.mode != "L":
        mask = mask.convert("L")
    if mask.size != image.size:
        mask = mask.resize(image.size, Image.Resampling.LANCZOS)
    image.putalpha(mask)
    alpha_source = "opacity-map"
image.save(dst)
a = image.getchannel("A")
hist = a.histogram()
print(json.dumps({
    "source": str(src),
    "destination": str(dst),
    "opacity": str(opacity) if opacity else "",
    "alphaSource": alpha_source,
    "width": image.size[0],
    "height": image.size[1],
    "alphaMin": a.getextrema()[0],
    "alphaMax": a.getextrema()[1],
    "alphaNonOpaquePixels": sum(hist[:255]),
    "alphaTransparentPixels": hist[0]
}))
'@

    foreach ($texture in $textures) {
        $pngRelative = $texture -replace '\.dds$', '.png'
        $pngDestination = Join-Path $DataLocalDirectory ($pngRelative -replace '/', '\')
        if (Test-Path -LiteralPath $pngDestination) {
            $converted++
            $cacheLedger.Add([pscustomobject][ordered]@{
                texture = $texture
                png = (Convert-ToForwardSlash $pngDestination)
                status = "already-cached"
            }) | Out-Null
            continue
        }

        $archive = Find-StarfieldTextureArchive -DataDirectories $dataDirs -RelativeTexturePath $texture -BsaTool $bsaTool
        if ([string]::IsNullOrWhiteSpace($archive)) {
            Write-Warning "Starfield actor texture cache: not found in Starfield texture BA2s: $texture"
            $cacheLedger.Add([pscustomobject][ordered]@{
                texture = $texture
                status = "missing-source"
            }) | Out-Null
            continue
        }

        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        & $bsaTool extract -f $archive $texture $extractRoot | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Starfield actor texture cache: extraction failed for $texture from $archive"
            continue
        }

        $extracted = Join-Path $extractRoot ($texture -replace '/', '\')
        if (-not (Test-Path -LiteralPath $extracted)) {
            Write-Warning "Starfield actor texture cache: extracted texture missing: $extracted"
            $cacheLedger.Add([pscustomobject][ordered]@{
                texture = $texture
                archive = (Convert-ToForwardSlash $archive)
                status = "missing-extracted-source"
            }) | Out-Null
            continue
        }

        $opacityTexture = Get-StarfieldOpacityTexturePath -Texture $texture
        $opacityArchive = ""
        $opacityExtracted = ""
        if (-not [string]::IsNullOrWhiteSpace($opacityTexture)) {
            $opacityArchive = Find-StarfieldTextureArchive -DataDirectories $dataDirs -RelativeTexturePath $opacityTexture -BsaTool $bsaTool
            if (-not [string]::IsNullOrWhiteSpace($opacityArchive)) {
                & $bsaTool extract -f $opacityArchive $opacityTexture $extractRoot | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $candidateOpacity = Join-Path $extractRoot ($opacityTexture -replace '/', '\')
                    if (Test-Path -LiteralPath $candidateOpacity) {
                        $opacityExtracted = $candidateOpacity
                    }
                }
            }
        }

        $decodeOk = $false
        $stats = $null
        $ledgerRecorded = $false
        $pythonError = Join-Path $extractRoot "python-dds-decode.err"
        $nativeErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $decodeOutput = @($converter | python - $extracted $pngDestination $opacityExtracted 2>$pythonError)
            $pythonExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $nativeErrorActionPreference
        }
        if ($pythonExitCode -eq 0 -and (Test-Path -LiteralPath $pngDestination)) {
            $decodeOk = $true
            if ($decodeOutput.Count -gt 0) {
                try {
                    $stats = $decodeOutput[-1] | ConvertFrom-Json
                }
                catch {
                    $stats = $null
                }
            }
            if ($null -ne $stats) {
                if ([string](Get-PropertyValue $stats "alphaSource") -eq "opacity-map") {
                    $alphaMerged++
                }
                $nonOpaque = [int64](Get-PropertyValue $stats "alphaNonOpaquePixels")
                $alphaNonOpaquePixels += $nonOpaque
                $cacheLedger.Add([pscustomobject][ordered]@{
                    texture = $texture
                    opacityTexture = $opacityTexture
                    archive = (Convert-ToForwardSlash $archive)
                    opacityArchive = if ([string]::IsNullOrWhiteSpace($opacityArchive)) { "" } else { (Convert-ToForwardSlash $opacityArchive) }
                    png = (Convert-ToForwardSlash $pngDestination)
                    status = "converted"
                    alphaSource = [string](Get-PropertyValue $stats "alphaSource")
                    alphaMin = [int](Get-PropertyValue $stats "alphaMin")
                    alphaMax = [int](Get-PropertyValue $stats "alphaMax")
                    alphaNonOpaquePixels = $nonOpaque
                    alphaTransparentPixels = [int64](Get-PropertyValue $stats "alphaTransparentPixels")
                }) | Out-Null
                $ledgerRecorded = $true
            }
        }
        else {
            Remove-Item -LiteralPath $pngDestination -Force -ErrorAction SilentlyContinue
            $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $ffmpeg) {
                $ffmpegError = Join-Path $extractRoot "ffmpeg-dds-decode.err"
                $nativeErrorActionPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    & $ffmpeg.Source -hide_banner -loglevel error -y -i $extracted -frames:v 1 -update 1 $pngDestination 2>$ffmpegError | Out-Null
                    $ffmpegExitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $nativeErrorActionPreference
                }
                if ($ffmpegExitCode -eq 0 -and (Test-Path -LiteralPath $pngDestination)) {
                    $decodeOk = $true
                    $ffmpegMergeError = Join-Path $extractRoot "ffmpeg-alpha-merge.err"
                    $nativeErrorActionPreference = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"
                    try {
                        $decodeOutput = @($converter | python - $pngDestination $pngDestination $opacityExtracted 2>$ffmpegMergeError)
                        $mergeExitCode = $LASTEXITCODE
                    }
                    finally {
                        $ErrorActionPreference = $nativeErrorActionPreference
                    }
                    if ($mergeExitCode -eq 0 -and $decodeOutput.Count -gt 0) {
                        try {
                            $stats = $decodeOutput[-1] | ConvertFrom-Json
                        }
                        catch {
                            $stats = $null
                        }
                    }
                }
            }
        }

        if ($decodeOk -and -not $ledgerRecorded) {
            if ($null -ne $stats) {
                if ([string](Get-PropertyValue $stats "alphaSource") -eq "opacity-map") {
                    $alphaMerged++
                }
                $nonOpaque = [int64](Get-PropertyValue $stats "alphaNonOpaquePixels")
                $alphaNonOpaquePixels += $nonOpaque
                $cacheLedger.Add([pscustomobject][ordered]@{
                    texture = $texture
                    opacityTexture = $opacityTexture
                    archive = (Convert-ToForwardSlash $archive)
                    opacityArchive = if ([string]::IsNullOrWhiteSpace($opacityArchive)) { "" } else { (Convert-ToForwardSlash $opacityArchive) }
                    png = (Convert-ToForwardSlash $pngDestination)
                    status = "converted"
                    alphaSource = [string](Get-PropertyValue $stats "alphaSource")
                    alphaMin = [int](Get-PropertyValue $stats "alphaMin")
                    alphaMax = [int](Get-PropertyValue $stats "alphaMax")
                    alphaNonOpaquePixels = $nonOpaque
                    alphaTransparentPixels = [int64](Get-PropertyValue $stats "alphaTransparentPixels")
                }) | Out-Null
            }
            else {
                $cacheLedger.Add([pscustomobject][ordered]@{
                    texture = $texture
                    opacityTexture = $opacityTexture
                    archive = (Convert-ToForwardSlash $archive)
                    opacityArchive = if ([string]::IsNullOrWhiteSpace($opacityArchive)) { "" } else { (Convert-ToForwardSlash $opacityArchive) }
                    png = (Convert-ToForwardSlash $pngDestination)
                    status = "converted-no-alpha-stats"
                }) | Out-Null
            }
        }

        if (-not $decodeOk) {
            Write-Warning "Starfield actor texture cache: decode failed for $texture"
            Remove-Item -LiteralPath $pngDestination -Force -ErrorAction SilentlyContinue
            $cacheLedger.Add([pscustomobject][ordered]@{
                texture = $texture
                opacityTexture = $opacityTexture
                archive = (Convert-ToForwardSlash $archive)
                status = "decode-failed"
            }) | Out-Null
            continue
        }
        $converted++
    }

    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    $ledgerPath = Join-Path $DataLocalDirectory "starfield-texture-cache-ledger.json"
    @($cacheLedger.ToArray()) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ledgerPath -Encoding ASCII
    return [pscustomobject][ordered]@{
        count = $converted
        alphaMerged = $alphaMerged
        alphaNonOpaquePixels = $alphaNonOpaquePixels
        ledgerPath = (Resolve-Path -LiteralPath $ledgerPath).Path
    }
}

function Copy-LatestScreenshot([string]$ScreenshotDir, [string]$DestinationDir, [string]$WorldId) {
    if (-not (Test-Path -LiteralPath $ScreenshotDir)) {
        return $null
    }
    $shot = Get-ChildItem -LiteralPath $ScreenshotDir -File -Filter "screenshot*.png" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $shot) {
        return $null
    }
    $destination = Join-Path $DestinationDir "$WorldId.png"
    Copy-Item -LiteralPath $shot.FullName -Destination $destination -Force
    return (Resolve-Path -LiteralPath $destination).Path
}

function Ensure-DrawingAssembly {
    Add-Type -AssemblyName System.Drawing
}

function Get-ScreenshotQuality([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    Ensure-DrawingAssembly
    $bitmap = New-Object System.Drawing.Bitmap($Path)
    try {
        $width = $bitmap.Width
        $height = $bitmap.Height
        if ($width -le 0 -or $height -le 0) {
            return [pscustomobject][ordered]@{
                width = $width
                height = $height
                sampledPixels = 0
                acceptable = $false
                reasons = @("empty image")
            }
        }

        $targetSamples = 30000.0
        $step = [Math]::Max(1, [int][Math]::Floor([Math]::Sqrt(($width * $height) / $targetSamples)))
        $sampled = 0
        $brightnessSum = 0.0
        $brightnessSquaredSum = 0.0
        $dark = 0
        $magenta = 0
        $purple = 0
        $brightLowSaturation = 0
        $blueSkyLike = 0
        $nearWhite = 0
        $skyOrVoid = 0
        $worldSignal = 0
        $lowSaturationMid = 0
        $colorSignal = 0

        for ($y = 0; $y -lt $height; $y += $step) {
            for ($x = 0; $x -lt $width; $x += $step) {
                $pixel = $bitmap.GetPixel($x, $y)
                $brightness = (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
                $maxChannel = [Math]::Max($pixel.R, [Math]::Max($pixel.G, $pixel.B))
                $minChannel = [Math]::Min($pixel.R, [Math]::Min($pixel.G, $pixel.B))
                $channelSpread = $maxChannel - $minChannel
                $brightnessSum += $brightness
                $brightnessSquaredSum += ($brightness * $brightness)
                $sampled++

                if ($brightness -lt 20) {
                    $dark++
                }
                $isMagenta = ($pixel.R -gt 180 -and $pixel.B -gt 180 -and $pixel.G -lt 110 -and ($pixel.R - $pixel.G) -gt 70 -and ($pixel.B - $pixel.G) -gt 70)
                $isPurple = ($pixel.R -gt 110 -and $pixel.B -gt 130 -and $pixel.G -lt 105 -and ($pixel.B - $pixel.G) -gt 45)
                $isBrightLowSaturation = ($brightness -gt 145 -and $channelSpread -lt 45)
                $isBlueSkyLike = ($brightness -gt 80 -and $pixel.B -gt ($pixel.R + 20) -and $pixel.B -gt ($pixel.G + 15))
                $isNearWhite = ($brightness -gt 220 -and $channelSpread -lt 38)
                $isSkyOrVoid = ($isNearWhite -or ($isBlueSkyLike -and $brightness -gt 150))
                $isLowSaturationMid = ($brightness -gt 45 -and $brightness -lt 220 -and $channelSpread -lt 35)
                $isColorSignal = ($brightness -gt 35 -and $channelSpread -gt 55)

                if ($isMagenta) {
                    $magenta++
                }
                if ($isPurple) {
                    $purple++
                }
                if ($isBrightLowSaturation) {
                    $brightLowSaturation++
                }
                if ($isBlueSkyLike) {
                    $blueSkyLike++
                }
                if ($isNearWhite) {
                    $nearWhite++
                }
                if ($isSkyOrVoid) {
                    $skyOrVoid++
                }
                if ($isLowSaturationMid) {
                    $lowSaturationMid++
                }
                if ($isColorSignal) {
                    $colorSignal++
                }
                if (-not $isSkyOrVoid -and $brightness -gt 25 -and -not $isMagenta -and -not $isPurple) {
                    $worldSignal++
                }
            }
        }

        if ($sampled -le 0) {
            return [pscustomobject][ordered]@{
                width = $width
                height = $height
                sampledPixels = 0
                acceptable = $false
                reasons = @("no sampled pixels")
            }
        }

        $mean = $brightnessSum / $sampled
        $variance = [Math]::Max(0.0, ($brightnessSquaredSum / $sampled) - ($mean * $mean))
        $stddev = [Math]::Sqrt($variance)
        $darkRatio = $dark / $sampled
        $magentaRatio = $magenta / $sampled
        $purpleRatio = $purple / $sampled
        $brightLowSaturationRatio = $brightLowSaturation / $sampled
        $blueSkyLikeRatio = $blueSkyLike / $sampled
        $nearWhiteRatio = $nearWhite / $sampled
        $skyOrVoidRatio = $skyOrVoid / $sampled
        $worldSignalRatio = $worldSignal / $sampled
        $lowSaturationMidRatio = $lowSaturationMid / $sampled
        $colorSignalRatio = $colorSignal / $sampled
        $reasons = New-Object System.Collections.Generic.List[string]

        if ($mean -lt 18 -or $darkRatio -gt 0.92) {
            $reasons.Add("too dark or blank")
        }
        if ($stddev -lt 4 -and $mean -lt 35) {
            $reasons.Add("low-variance loading/blank frame")
        }
        if ($magentaRatio -gt 0.005 -or $purpleRatio -gt 0.04) {
            $reasons.Add("purple/magenta fallback pixels detected")
        }
        if ($brightLowSaturationRatio -gt 0.68 -and $stddev -lt 55) {
            $reasons.Add("large bright low-saturation fallback/void surface")
        }
        if ($brightLowSaturationRatio -gt 0.24 -and $stddev -gt 42 -and $colorSignalRatio -lt 0.025) {
            $reasons.Add("large high-contrast low-color fallback texture")
        }
        if ($blueSkyLikeRatio -gt 0.8) {
            $reasons.Add("mostly sky/blue void")
        }
        if ($nearWhiteRatio -gt 0.65) {
            $reasons.Add("mostly near-white frame")
        }
        if ($skyOrVoidRatio -gt 0.72) {
            $reasons.Add("sky/void dominates frame")
        }
        if ($worldSignalRatio -lt 0.18) {
            $reasons.Add("too little non-void world signal")
        }
        if ($mean -gt 210 -and $stddev -lt 25 -and $skyOrVoidRatio -gt 0.55) {
            $reasons.Add("washed-out low-detail frame")
        }

        [pscustomobject][ordered]@{
            width = $width
            height = $height
            sampledPixels = $sampled
            meanBrightness = [Math]::Round($mean, 2)
            brightnessStdDev = [Math]::Round($stddev, 2)
            darkRatio = [Math]::Round($darkRatio, 4)
            magentaRatio = [Math]::Round($magentaRatio, 4)
            purpleRatio = [Math]::Round($purpleRatio, 4)
            brightLowSaturationRatio = [Math]::Round($brightLowSaturationRatio, 4)
            blueSkyLikeRatio = [Math]::Round($blueSkyLikeRatio, 4)
            nearWhiteRatio = [Math]::Round($nearWhiteRatio, 4)
            skyOrVoidRatio = [Math]::Round($skyOrVoidRatio, 4)
            worldSignalRatio = [Math]::Round($worldSignalRatio, 4)
            lowSaturationMidRatio = [Math]::Round($lowSaturationMidRatio, 4)
            colorSignalRatio = [Math]::Round($colorSignalRatio, 4)
            acceptable = ($reasons.Count -eq 0)
            reasons = @($reasons)
        }
    }
    finally {
        $bitmap.Dispose()
    }
}

function Get-ProofLogSummary([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $specs = @(
        [pscustomobject]@{ Name = "renderFailures"; Pattern = "failed to render|failed to load|Error loading|cannot load" },
        [pscustomobject]@{ Name = "missingAssets"; Pattern = "not found|missing|does not exist|cannot find|could not find" },
        [pscustomobject]@{ Name = "unsupportedAssets"; Pattern = "unsupported|not supported|unhandled" },
        [pscustomobject]@{ Name = "shaderIssues"; Pattern = "shader|purple|magenta|fallback" },
        [pscustomobject]@{ Name = "actorIssues"; Pattern = "actor|npc|creature|skeleton|bone|animation|rig" },
        [pscustomobject]@{ Name = "terrainIssues"; Pattern = "World viewer terrain:|LandTexture not found|missing ESM4 LTEX|missing ESM4 LTEX diffuse" },
        [pscustomobject]@{ Name = "viewerTelemetry"; Pattern = "World viewer telemetry:|World viewer ref:|World viewer cell:|World viewer ray:|World viewer actor ledger:|World viewer mesh ledger:|World viewer texture ledger:|World viewer material ledger:|World viewer nif geometry ledger:|World viewer bs geometry|World viewer osg-update-callback|FNV/ESM4 proof:" }
    )

    $categories = [ordered]@{}
    foreach ($spec in $specs) {
        $categories[$spec.Name] = [ordered]@{
            count = 0
            examples = New-Object System.Collections.Generic.List[string]
        }
    }

    $lineCount = 0
    $warningCount = 0
    $errorCount = 0
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        $lineCount++
        if ($line -match "\bWarning\b|WARN|warning:") {
            $warningCount++
        }
        if ($line -match "\bError\b|ERROR|error:|failed") {
            $errorCount++
        }

        foreach ($spec in $specs) {
            if ($line -match $spec.Pattern) {
                $entry = $categories[$spec.Name]
                $entry.count++
                if ($entry.examples.Count -lt 20) {
                    $entry.examples.Add($line)
                }
            }
        }
    }

    $normalized = [ordered]@{}
    foreach ($spec in $specs) {
        $entry = $categories[$spec.Name]
        $normalized[$spec.Name] = [pscustomobject][ordered]@{
            count = $entry.count
            examples = @($entry.examples)
        }
    }

    [pscustomobject][ordered]@{
        totalLines = $lineCount
        warnings = $warningCount
        errors = $errorCount
        categories = $normalized
    }
}

function Convert-WorldViewerTelemetryValue([string]$Value) {
    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.Trim()
    if ($text.Length -ge 2 -and $text.StartsWith('"') -and $text.EndsWith('"')) {
        return $text.Substring(1, $text.Length - 2)
    }
    if ($text.Length -ge 2 -and $text.StartsWith('(') -and $text.EndsWith(')')) {
        return $text
    }
    if ($text -eq '<none>') {
        return $text
    }
    if ($text -match '^0x[0-9a-fA-F]+$') {
        return $text
    }

    $intValue = 0
    if ([int]::TryParse($text, [ref]$intValue)) {
        return $intValue
    }

    $doubleValue = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue)) {
        return $doubleValue
    }

    return $text
}

function Convert-WorldViewerFlag($Value) {
    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return $Value
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return ([double]$Value) -ne 0.0
    }

    $text = ([string]$Value).Trim()
    return -not ([string]::IsNullOrWhiteSpace($text) -or $text -eq "0" -or $text -ieq "false" -or $text -ieq "no" -or $text -ieq "off")
}

function Convert-WorldViewerInt($Value) {
    if ($null -eq $Value) {
        return 0
    }
    $intValue = 0
    if ([int]::TryParse(([string]$Value), [ref]$intValue)) {
        return $intValue
    }
    return 0
}

function Convert-WorldViewerDouble($Value) {
    if ($null -eq $Value) {
        return 0.0
    }
    $doubleValue = 0.0
    if ([double]::TryParse(([string]$Value), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue)) {
        return $doubleValue
    }
    return 0.0
}

function Parse-WorldViewerKeyValues([string]$Text) {
    $values = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]$values
    }

    $matches = [regex]::Matches($Text, '([A-Za-z][A-Za-z0-9_]*)=("[^"]*"|\([^)]*\)|0x[0-9a-fA-F]+|[^\s]+)')
    foreach ($match in $matches) {
        $values[$match.Groups[1].Value] = Convert-WorldViewerTelemetryValue $match.Groups[2].Value
    }
    return [pscustomobject]$values
}

function Get-WorldViewerTelemetrySummary([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $cells = New-Object System.Collections.Generic.List[object]
    $rays = New-Object System.Collections.Generic.List[object]
    $actorLedger = New-Object System.Collections.Generic.List[object]
    $meshLedger = New-Object System.Collections.Generic.List[object]
    $geometryLedger = New-Object System.Collections.Generic.List[object]
    $textureLedger = New-Object System.Collections.Generic.List[object]
    $materialLedger = New-Object System.Collections.Generic.List[object]
    $starfieldMeshLedger = New-Object System.Collections.Generic.List[object]
    $starfieldActorTextureLedger = New-Object System.Collections.Generic.List[object]
    $starfieldWorldTextureLedger = New-Object System.Collections.Generic.List[object]
    $starfieldWorldMaterialFallbackLedger = New-Object System.Collections.Generic.List[object]
    $starfieldWorldSkippedGeometryLedger = New-Object System.Collections.Generic.List[object]
    $meshLoadFailures = New-Object System.Collections.Generic.List[object]
    $staticSkeletonAttaches = New-Object System.Collections.Generic.List[object]
    $tes5FaceSurfaceFallbacks = New-Object System.Collections.Generic.List[object]
    $proofActorStages = New-Object System.Collections.Generic.List[object]
    $proofGroundSnaps = New-Object System.Collections.Generic.List[object]
    $proofActorBounds = New-Object System.Collections.Generic.List[object]
    $proofActorCameraRaycasts = New-Object System.Collections.Generic.List[object]
    $proofActorOrbitCandidates = New-Object System.Collections.Generic.List[object]
    $problemRefs = New-Object System.Collections.Generic.List[object]
    $refsByType = [ordered]@{}
    $rayKinds = [ordered]@{}
    $meshStages = [ordered]@{}
    $textureRoles = [ordered]@{}
    $materialShaderPrefixes = [ordered]@{}
    $materialBsLightingTypes = [ordered]@{}
    $latestTelemetry = $null
    $refDumpTruncated = $null

    $cellRefs = 0
    $cellEnabled = 0
    $cellRendered = 0
    $cellMissingRenderNode = 0
    $cellActors = 0
    $cellRenderedActors = 0
    $cellDoors = 0
    $cellDeleted = 0
    $loggedRefs = 0
    $loggedRenderedRefs = 0
    $loggedActorRefs = 0
    $loggedRenderedActorRefs = 0
    $proxyActorRefs = 0
    $proxyTposeRefs = 0
    $proxyAnimatedRefs = 0
    $nativeActorLedgerEvents = 0
    $nativeActorRenderBegins = 0
    $nativeActorRenderEnds = 0
    $nativeActorCustomData = 0
    $nativeActorRootBegins = 0
    $nativeActorRootEnds = 0
    $nativeActorRootExceptions = 0
    $nativeActorModelFallbacks = 0
    $nativeActorPartsRequested = 0
    $nativeActorPartsTemplated = 0
    $nativeActorPartsAttached = 0
    $nativeActorPartsMissing = 0
    $nativeActorPartsQuarantined = 0
    $nativeActorTemplateExceptions = 0
    $nativeActorAnimSources = 0
    $nativeActorAnimSourcesBound = 0
    $nativeActorControllerSources = 0
    $nativeActorControllersBound = 0
    $nativeActorControllersTotal = 0
    $nativeActorControllerZeroSources = 0
    $staticSkeletonAttachEvents = 0
    $tes5StaticFaceSurfaceFallbackEvents = 0
    $meshLedgerEvents = 0
    $meshLoadFailureEvents = 0
    $meshTemplateFinalEvents = 0
    $meshTemplateFinalWithGeometry = 0
    $meshTemplateFinalEmptyGeometry = 0
    $meshTemplateFinalInvalidBounds = 0
    $actorMeshTemplateEvents = 0
    $actorMeshTemplateWithGeometry = 0
    $actorMeshTemplateEmptyGeometry = 0
    $starfieldExternalMeshEvents = 0
    $starfieldExternalMeshVertices = 0
    $starfieldExternalMeshIndices = 0
    $starfieldExternalMeshWithUv = 0
    $starfieldExternalMeshWithNormals = 0
    $starfieldExternalMeshFailures = 0
    $starfieldActorProofTextureEvents = 0
    $starfieldActorProofTextureUnits = 0
    $starfieldWorldProofTextureEvents = 0
    $starfieldWorldProofTextureUnits = 0
    $starfieldWorldMaterialFallbackEvents = 0
    $starfieldWorldSkippedGeometryEvents = 0
    $starfieldBsGeometryProxyEvents = 0
    $textureLedgerEvents = 0
    $textureImagesResolved = 0
    $textureImagesMissing = 0
    $textureSkinAuxSkipped = 0
    $materialLedgerEvents = 0
    $materialWithTextureUnits = 0
    $materialWithoutTextureUnits = 0
    $materialShaderRequired = 0
    $materialWithVertexColors = 0
    $materialWithAlphaSort = 0
    $materialColorModeOff = 0
    $materialColorModeNonOff = 0
    $nifGeometryLedgerEvents = 0
    $nifGeometryWithVertices = 0
    $nifGeometryWithTriangles = 0
    $bsGeometryLedgerEvents = 0
    $bsGeometryWithInlineTriangles = 0
    $bsGeometryWithSkinPartitions = 0
    $bsGeometryWithPartitionTriangles = 0
    $bsPartitionFallbackEvents = 0
    $bsPartitionFallbackAttached = 0
    $bsPartitionFallbackEmptyVertices = 0
    $bsPartitionFallbackGeneratedNormals = 0
    $bsAttachedEvents = 0
    $bsGeometryQuarantineEvents = 0
    $osgUpdateCallbackEvents = 0
    $osgUpdateCallbackSummaries = 0
    $osgUpdateNodeCallbacks = 0
    $osgUpdateNodeOwnersStripped = 0
    $osgUpdateStateSetCallbacks = 0
    $osgUpdateStateSetOwnersStripped = 0
    $rayHits = 0
    $groundRayHits = 0
    $centerRenderHits = 0
    $actorRayHits = 0
    $actorRayActorHits = 0
    $proofActorStageEvents = 0
    $proofGroundSnapEvents = 0
    $proofGroundSnapHits = 0
    $proofGroundSnapMisses = 0
    $proofGroundSnapFailures = 0
    $proofActorBoundsEvents = 0
    $proofActorBoundsValid = 0
    $proofActorBoundsInvalid = 0
    $proofActorCameraRaycastEvents = 0
    $proofActorCameraRaycastAdjusted = 0
    $proofActorCameraRaycastClear = 0
    $proofActorCameraRaycastTooClose = 0
    $proofActorOrbitCandidateEvents = 0
    $proofActorOrbitCandidateClear = 0
    $proofActorOrbitSelectedEvents = 0
    $proofActorOrbitKeptEvents = 0
    $latestProofActorBounds = $null
    $latestProofGroundSnap = $null
    $latestProofActorStage = $null
    $latestProofActorCameraRaycast = $null
    $latestProofActorOrbitSelection = $null

    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        $telemetryIndex = $line.IndexOf("World viewer telemetry:")
        if ($telemetryIndex -ge 0) {
            $body = $line.Substring($telemetryIndex + "World viewer telemetry:".Length).Trim()
            if ($body -match '^ref dump truncated') {
                $refDumpTruncated = Parse-WorldViewerKeyValues $body
            }
            elseif ($body -match '\bframe=') {
                $latestTelemetry = Parse-WorldViewerKeyValues $body
            }
            continue
        }

        $cellIndex = $line.IndexOf("World viewer cell:")
        if ($cellIndex -ge 0) {
            $cell = Parse-WorldViewerKeyValues ($line.Substring($cellIndex + "World viewer cell:".Length).Trim())
            $cellRefs += Convert-WorldViewerInt (Get-PropertyValue $cell "refs")
            $cellEnabled += Convert-WorldViewerInt (Get-PropertyValue $cell "enabled")
            $cellRendered += Convert-WorldViewerInt (Get-PropertyValue $cell "rendered")
            $cellMissingRenderNode += Convert-WorldViewerInt (Get-PropertyValue $cell "missingRenderNode")
            $cellActors += Convert-WorldViewerInt (Get-PropertyValue $cell "actors")
            $cellRenderedActors += Convert-WorldViewerInt (Get-PropertyValue $cell "renderedActors")
            $cellDoors += Convert-WorldViewerInt (Get-PropertyValue $cell "doors")
            $cellDeleted += Convert-WorldViewerInt (Get-PropertyValue $cell "deleted")
            if ($cells.Count -lt 80) {
                $cells.Add($cell)
            }
            continue
        }

        $proxyIndex = $line.IndexOf("World viewer: inserted ESM4 actor proxy")
        if ($proxyIndex -ge 0) {
            $proxy = Parse-WorldViewerKeyValues ($line.Substring($proxyIndex + "World viewer: inserted ESM4 actor proxy".Length).Trim())
            $proxyActorRefs++
            if (([string](Get-PropertyValue $proxy "pose")) -eq "tpose") {
                $proxyTposeRefs++
            }
            if (Convert-WorldViewerFlag (Get-PropertyValue $proxy "animated")) {
                $proxyAnimatedRefs++
            }
            continue
        }

        $actorLedgerIndex = $line.IndexOf("World viewer actor ledger:")
        if ($actorLedgerIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($actorLedgerIndex + "World viewer actor ledger:".Length).Trim())
            $nativeActorLedgerEvents++
            $phaseValue = Get-PropertyValue $entry "phase"
            $phase = if ($null -ne $phaseValue) { [string]$phaseValue } else { "<unknown>" }
            switch ($phase) {
                "render-insert-begin" { $nativeActorRenderBegins++ }
                "render-insert-end" { $nativeActorRenderEnds++ }
                "npc-custom-data" { $nativeActorCustomData++ }
                "npc-root-begin" { $nativeActorRootBegins++ }
                "npc-root-end" { $nativeActorRootEnds++ }
                "npc-root-exception" { $nativeActorRootExceptions++ }
                "npc-model-fallback" { $nativeActorModelFallbacks++ }
                "part-request" { $nativeActorPartsRequested++ }
                "part-template" { $nativeActorPartsTemplated++ }
                "part-attached" { $nativeActorPartsAttached++ }
                "part-missing" { $nativeActorPartsMissing++ }
                "part-quarantine" { $nativeActorPartsQuarantined++ }
                "part-template-exception" { $nativeActorTemplateExceptions++ }
                "animation-source" {
                    $nativeActorAnimSources++
                    if (Convert-WorldViewerFlag (Get-PropertyValue $entry "bound")) {
                        $nativeActorAnimSourcesBound++
                    }
                }
            }
            if ($actorLedger.Count -lt 240) {
                $actorLedger.Add($entry)
            }
            continue
        }

        $meshLedgerIndex = $line.IndexOf("World viewer mesh ledger:")
        if ($meshLedgerIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($meshLedgerIndex + "World viewer mesh ledger:".Length).Trim())
            $meshLedgerEvents++
            $stageValue = Get-PropertyValue $entry "stage"
            $stage = if ($null -ne $stageValue) { [string]$stageValue } else { "<unknown>" }
            if (-not $meshStages.Contains($stage)) {
                $meshStages[$stage] = 0
            }
            $meshStages[$stage]++

            $geometryCount = Convert-WorldViewerInt (Get-PropertyValue $entry "geometry")
            $drawables = Convert-WorldViewerInt (Get-PropertyValue $entry "drawables")
            $rigRenderGeometry = Convert-WorldViewerInt (Get-PropertyValue $entry "rigRenderGeometry")
            $boundValid = Convert-WorldViewerFlag (Get-PropertyValue $entry "boundValid")
            $pathText = [string](Get-PropertyValue $entry "path")
            $looksLikeActorMesh = $pathText -match '(?i)(^|/)(actors|characters|creatures|meshes/actors|meshes/characters|meshes/creatures)(/|$)'

            if ($stage -eq "template-final") {
                $meshTemplateFinalEvents++
                if ($geometryCount -gt 0 -or $drawables -gt 0 -or $rigRenderGeometry -gt 0) {
                    $meshTemplateFinalWithGeometry++
                }
                else {
                    $meshTemplateFinalEmptyGeometry++
                }
                if (-not $boundValid) {
                    $meshTemplateFinalInvalidBounds++
                }
                if ($looksLikeActorMesh) {
                    $actorMeshTemplateEvents++
                    if ($geometryCount -gt 0 -or $drawables -gt 0 -or $rigRenderGeometry -gt 0) {
                        $actorMeshTemplateWithGeometry++
                    }
                    else {
                        $actorMeshTemplateEmptyGeometry++
                    }
                }
            }

            if ($meshLedger.Count -lt 240) {
                $meshLedger.Add($entry)
            }
            continue
        }

        $meshFailureMatch = [regex]::Match($line, "Failed to load '(?<path>[^']+)': (?<reason>.*?)(?:, using marker_error instead)?$")
        if ($meshFailureMatch.Success) {
            $meshLoadFailureEvents++
            if ($meshLoadFailures.Count -lt 120) {
                $meshLoadFailures.Add([pscustomobject][ordered]@{
                    path = $meshFailureMatch.Groups["path"].Value
                    reason = $meshFailureMatch.Groups["reason"].Value
                })
            }
            continue
        }

        $starfieldMeshLoadedIndex = $line.IndexOf("World viewer: Starfield mesh loaded")
        if ($starfieldMeshLoadedIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($starfieldMeshLoadedIndex + "World viewer: Starfield mesh loaded".Length).Trim())
            $starfieldExternalMeshEvents++
            $vertices = Convert-WorldViewerInt (Get-PropertyValue $entry "vertices")
            $indices = Convert-WorldViewerInt (Get-PropertyValue $entry "indices")
            $uv1 = Convert-WorldViewerInt (Get-PropertyValue $entry "uv1")
            $normals = Convert-WorldViewerInt (Get-PropertyValue $entry "normals")
            $starfieldExternalMeshVertices += $vertices
            $starfieldExternalMeshIndices += $indices
            if ($uv1 -gt 0) {
                $starfieldExternalMeshWithUv++
            }
            if ($normals -gt 0) {
                $starfieldExternalMeshWithNormals++
            }
            if ($starfieldMeshLedger.Count -lt 240) {
                $entry | Add-Member -NotePropertyName phase -NotePropertyValue "starfield-mesh-loaded" -Force
                $starfieldMeshLedger.Add($entry)
            }
            continue
        }

        $starfieldMeshFailureIndex = $line.IndexOf("World viewer: Starfield mesh load failed")
        if ($starfieldMeshFailureIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($starfieldMeshFailureIndex + "World viewer: Starfield mesh load failed".Length).Trim())
            $starfieldExternalMeshFailures++
            $meshLoadFailureEvents++
            if ($meshLoadFailures.Count -lt 120) {
                $meshLoadFailures.Add([pscustomobject][ordered]@{
                    path = [string](Get-PropertyValue $entry "path")
                    reason = [string](Get-PropertyValue $entry "reason")
                    source = "starfield-external-mesh"
                })
            }
            continue
        }

        $starfieldActorTextureIndex = $line.IndexOf("World viewer: Starfield actor proof texture")
        if ($starfieldActorTextureIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($starfieldActorTextureIndex + "World viewer: Starfield actor proof texture".Length).Trim())
            $starfieldActorProofTextureEvents++
            $starfieldActorProofTextureUnits += Convert-WorldViewerInt (Get-PropertyValue $entry "boundTextureUnits")
            if ($starfieldActorTextureLedger.Count -lt 240) {
                $entry | Add-Member -NotePropertyName phase -NotePropertyValue "starfield-actor-proof-texture" -Force
                $starfieldActorTextureLedger.Add($entry)
            }
            continue
        }

        $starfieldWorldTextureIndex = $line.IndexOf("World viewer: Starfield world proof texture")
        if ($starfieldWorldTextureIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($starfieldWorldTextureIndex + "World viewer: Starfield world proof texture".Length).Trim())
            $starfieldWorldProofTextureEvents++
            $starfieldWorldProofTextureUnits += Convert-WorldViewerInt (Get-PropertyValue $entry "boundTextureUnits")
            if ($starfieldWorldTextureLedger.Count -lt 240) {
                $entry | Add-Member -NotePropertyName phase -NotePropertyValue "starfield-world-proof-texture" -Force
                $starfieldWorldTextureLedger.Add($entry)
            }
            continue
        }

        $starfieldWorldMaterialFallbackIndex = $line.IndexOf("World viewer: Starfield world material fallback")
        if ($starfieldWorldMaterialFallbackIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($starfieldWorldMaterialFallbackIndex + "World viewer: Starfield world material fallback".Length).Trim())
            $starfieldWorldMaterialFallbackEvents++
            if ($starfieldWorldMaterialFallbackLedger.Count -lt 240) {
                $entry | Add-Member -NotePropertyName phase -NotePropertyValue "starfield-world-material-fallback" -Force
                $starfieldWorldMaterialFallbackLedger.Add($entry)
            }
            continue
        }

        $starfieldWorldSkippedGeometryIndex = $line.IndexOf("World viewer: Starfield world proof skipped geometry")
        if ($starfieldWorldSkippedGeometryIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($starfieldWorldSkippedGeometryIndex + "World viewer: Starfield world proof skipped geometry".Length).Trim())
            $starfieldWorldSkippedGeometryEvents++
            if ($starfieldWorldSkippedGeometryLedger.Count -lt 240) {
                $entry | Add-Member -NotePropertyName phase -NotePropertyValue "starfield-world-skipped-geometry" -Force
                $starfieldWorldSkippedGeometryLedger.Add($entry)
            }
            continue
        }

        $starfieldProxyIndex = $line.IndexOf("World viewer: Starfield BSGeometry proxy")
        if ($starfieldProxyIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($starfieldProxyIndex + "World viewer: Starfield BSGeometry proxy".Length).Trim())
            $starfieldBsGeometryProxyEvents++
            if ($geometryLedger.Count -lt 240) {
                $entry | Add-Member -NotePropertyName phase -NotePropertyValue "starfield-bs-proxy" -Force
                $geometryLedger.Add($entry)
            }
            continue
        }

        $textureLedgerIndex = $line.IndexOf("World viewer texture ledger:")
        if ($textureLedgerIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($textureLedgerIndex + "World viewer texture ledger:".Length).Trim())
            $textureLedgerEvents++
            $roleValue = Get-PropertyValue $entry "role"
            $role = if ($null -ne $roleValue) { [string]$roleValue } else { "<unknown>" }
            if (-not $textureRoles.Contains($role)) {
                $textureRoles[$role] = 0
            }
            $textureRoles[$role]++

            if (Convert-WorldViewerFlag (Get-PropertyValue $entry "skippedAsEmissive")) {
                $textureSkinAuxSkipped++
            }
            elseif ($null -ne (Get-PropertyValue $entry "image")) {
                $imageResolved = Convert-WorldViewerFlag (Get-PropertyValue $entry "image")
                $width = Convert-WorldViewerInt (Get-PropertyValue $entry "width")
                $height = Convert-WorldViewerInt (Get-PropertyValue $entry "height")
                if ($imageResolved -and $width -gt 0 -and $height -gt 0) {
                    $textureImagesResolved++
                }
                else {
                    $textureImagesMissing++
                }
            }

            if ($textureLedger.Count -lt 240) {
                $textureLedger.Add($entry)
            }
            continue
        }

        $materialLedgerIndex = $line.IndexOf("World viewer material ledger:")
        if ($materialLedgerIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($materialLedgerIndex + "World viewer material ledger:".Length).Trim())
            $materialLedgerEvents++

            $shaderPrefixValue = Get-PropertyValue $entry "shaderPrefix"
            $shaderPrefix = if ($null -ne $shaderPrefixValue -and -not [string]::IsNullOrWhiteSpace([string]$shaderPrefixValue)) { [string]$shaderPrefixValue } else { "<none>" }
            if (-not $materialShaderPrefixes.Contains($shaderPrefix)) {
                $materialShaderPrefixes[$shaderPrefix] = 0
            }
            $materialShaderPrefixes[$shaderPrefix]++

            $bsLightingTypeValue = Get-PropertyValue $entry "bsLightingType"
            $bsLightingType = if ($null -ne $bsLightingTypeValue) { [string]$bsLightingTypeValue } else { "<none>" }
            if (-not $materialBsLightingTypes.Contains($bsLightingType)) {
                $materialBsLightingTypes[$bsLightingType] = 0
            }
            $materialBsLightingTypes[$bsLightingType]++

            $stateTextureUnits = Convert-WorldViewerInt (Get-PropertyValue $entry "stateTextureUnits")
            $boundTextureSlots = Convert-WorldViewerInt (Get-PropertyValue $entry "boundTextureSlots")
            if ($stateTextureUnits -gt 0 -or $boundTextureSlots -gt 0) {
                $materialWithTextureUnits++
            }
            else {
                $materialWithoutTextureUnits++
            }
            if (Convert-WorldViewerFlag (Get-PropertyValue $entry "shaderRequired")) {
                $materialShaderRequired++
            }
            if (Convert-WorldViewerFlag (Get-PropertyValue $entry "hasVertexColors")) {
                $materialWithVertexColors++
            }
            if (Convert-WorldViewerFlag (Get-PropertyValue $entry "hasSortAlpha")) {
                $materialWithAlphaSort++
            }
            if ((Convert-WorldViewerInt (Get-PropertyValue $entry "colorMode")) -eq 0) {
                $materialColorModeOff++
            }
            else {
                $materialColorModeNonOff++
            }
            if ($materialLedger.Count -lt 240) {
                $materialLedger.Add($entry)
            }
            continue
        }

        $nifGeometryIndex = $line.IndexOf("World viewer nif geometry ledger:")
        if ($nifGeometryIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($nifGeometryIndex + "World viewer nif geometry ledger:".Length).Trim())
            $nifGeometryLedgerEvents++
            if (Convert-WorldViewerInt (Get-PropertyValue $entry "vertices") -gt 0) {
                $nifGeometryWithVertices++
            }
            if (Convert-WorldViewerInt (Get-PropertyValue $entry "triangles") -gt 0) {
                $nifGeometryWithTriangles++
            }
            if ($geometryLedger.Count -lt 240) {
                $geometryLedger.Add($entry)
            }
            continue
        }

        $bsPartitionFallbackIndex = $line.IndexOf("World viewer bs geometry partition-fallback:")
        if ($bsPartitionFallbackIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($bsPartitionFallbackIndex + "World viewer bs geometry partition-fallback:".Length).Trim())
            $bsPartitionFallbackEvents++
            if (Convert-WorldViewerFlag (Get-PropertyValue $entry "attached")) {
                $bsPartitionFallbackAttached++
            }
            if (Convert-WorldViewerInt (Get-PropertyValue $entry "vertices") -le 0) {
                $bsPartitionFallbackEmptyVertices++
            }
            if (Convert-WorldViewerFlag (Get-PropertyValue $entry "generatedNormals")) {
                $bsPartitionFallbackGeneratedNormals++
            }
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "bs-partition-fallback" -Force
            if ($geometryLedger.Count -lt 240) {
                $geometryLedger.Add($entry)
            }
            continue
        }

        $bsAttachedIndex = $line.IndexOf("World viewer bs geometry attached:")
        if ($bsAttachedIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($bsAttachedIndex + "World viewer bs geometry attached:".Length).Trim())
            $bsAttachedEvents++
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "bs-attached" -Force
            if ($geometryLedger.Count -lt 240) {
                $geometryLedger.Add($entry)
            }
            continue
        }

        $bsQuarantineIndex = $line.IndexOf("World viewer bs geometry quarantine:")
        if ($bsQuarantineIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($bsQuarantineIndex + "World viewer bs geometry quarantine:".Length).Trim())
            $bsGeometryQuarantineEvents++
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "bs-quarantine" -Force
            if ($geometryLedger.Count -lt 240) {
                $geometryLedger.Add($entry)
            }
            continue
        }

        $bsGeometryIndex = $line.IndexOf("World viewer bs geometry ledger:")
        if ($bsGeometryIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($bsGeometryIndex + "World viewer bs geometry ledger:".Length).Trim())
            $bsGeometryLedgerEvents++
            if (Convert-WorldViewerInt (Get-PropertyValue $entry "triangles") -gt 0) {
                $bsGeometryWithInlineTriangles++
            }
            if (Convert-WorldViewerFlag (Get-PropertyValue $entry "niSkinPartitions")) {
                $bsGeometryWithSkinPartitions++
            }
            if (Convert-WorldViewerInt (Get-PropertyValue $entry "partitionTriangles") -gt 0) {
                $bsGeometryWithPartitionTriangles++
            }
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "bs-ledger" -Force
            if ($geometryLedger.Count -lt 240) {
                $geometryLedger.Add($entry)
            }
            continue
        }

        $staticSkeletonMatch = [regex]::Match($line, "World viewer: static-skeleton attached NPC model part (?<model>.+?) to (?<ref>.+?) attachNode=(?<attachNode>.+?) staticGeometry=(?<staticGeometry>\d+) nodeMap=(?<nodeMap>\d+)")
        if ($staticSkeletonMatch.Success) {
            $staticSkeletonAttachEvents++
            if ($staticSkeletonAttaches.Count -lt 120) {
                $staticSkeletonAttaches.Add([pscustomobject][ordered]@{
                    model = $staticSkeletonMatch.Groups["model"].Value
                    ref = $staticSkeletonMatch.Groups["ref"].Value
                    attachNode = $staticSkeletonMatch.Groups["attachNode"].Value
                    staticGeometry = [int]$staticSkeletonMatch.Groups["staticGeometry"].Value
                    nodeMap = [int]$staticSkeletonMatch.Groups["nodeMap"].Value
                })
            }
            continue
        }

        $tes5FaceFallbackMatch = [regex]::Match($line, "World viewer: TES5 static face surface fallback model=(?<model>.+?) actor=(?<actor>.+?) attachNode=(?<attachNode>.+?) nodeMap=(?<nodeMap>\d+)")
        if ($tes5FaceFallbackMatch.Success) {
            $tes5StaticFaceSurfaceFallbackEvents++
            if ($tes5FaceSurfaceFallbacks.Count -lt 120) {
                $tes5FaceSurfaceFallbacks.Add([pscustomobject][ordered]@{
                    model = $tes5FaceFallbackMatch.Groups["model"].Value
                    actor = $tes5FaceFallbackMatch.Groups["actor"].Value
                    attachNode = $tes5FaceFallbackMatch.Groups["attachNode"].Value
                    nodeMap = [int]$tes5FaceFallbackMatch.Groups["nodeMap"].Value
                })
            }
            continue
        }

        $controllerMatch = [regex]::Match($line, 'FNV/ESM4 diag: animation source (?<source>.+?) bound (?<bound>\d+)/(?<total>\d+) controller\(s\) to (?<base>.+?), missing (?<missing>\d+)')
        if ($controllerMatch.Success) {
            $boundControllers = [int]$controllerMatch.Groups["bound"].Value
            $totalControllers = [int]$controllerMatch.Groups["total"].Value
            $nativeActorControllerSources++
            $nativeActorControllersBound += $boundControllers
            $nativeActorControllersTotal += $totalControllers
            if ($totalControllers -gt 0 -and $boundControllers -eq 0) {
                $nativeActorControllerZeroSources++
            }
            if ($actorLedger.Count -lt 240) {
                $actorLedger.Add([pscustomobject][ordered]@{
                    phase = "animation-controller-bind"
                    source = $controllerMatch.Groups["source"].Value
                    skeleton = $controllerMatch.Groups["base"].Value
                    bound = $boundControllers
                    total = $totalControllers
                    missing = [int]$controllerMatch.Groups["missing"].Value
                })
            }
            continue
        }

        $osgSummaryIndex = $line.IndexOf("World viewer osg-update-callback-summary:")
        if ($osgSummaryIndex -ge 0) {
            $summary = Parse-WorldViewerKeyValues ($line.Substring($osgSummaryIndex + "World viewer osg-update-callback-summary:".Length).Trim())
            $osgUpdateCallbackSummaries++
            $osgUpdateNodeCallbacks += Convert-WorldViewerInt (Get-PropertyValue $summary "nodeCallbacks")
            $osgUpdateNodeOwnersStripped += Convert-WorldViewerInt (Get-PropertyValue $summary "nodeOwnersStripped")
            $osgUpdateStateSetCallbacks += Convert-WorldViewerInt (Get-PropertyValue $summary "stateSetCallbacks")
            $osgUpdateStateSetOwnersStripped += Convert-WorldViewerInt (Get-PropertyValue $summary "stateSetOwnersStripped")
            continue
        }

        $osgCallbackIndex = $line.IndexOf("World viewer osg-update-callback:")
        if ($osgCallbackIndex -ge 0) {
            $osgUpdateCallbackEvents++
            continue
        }

        $proofStageIndex = $line.IndexOf("FNV/ESM4 proof: staged actor")
        if ($proofStageIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($proofStageIndex + "FNV/ESM4 proof: staged actor".Length).Trim())
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "stage" -Force
            $proofActorStageEvents++
            $latestProofActorStage = $entry
            if ($proofActorStages.Count -lt 80) {
                $proofActorStages.Add($entry)
            }
            continue
        }

        $proofGroundSnapIndex = $line.IndexOf("FNV/ESM4 proof: render-ground ")
        if ($proofGroundSnapIndex -ge 0) {
            $body = $line.Substring($proofGroundSnapIndex + "FNV/ESM4 proof: render-ground ".Length).Trim()
            $entry = Parse-WorldViewerKeyValues $body
            $status = "<unknown>"
            if ($body.StartsWith("snapped actor")) {
                $status = "snapped"
                $proofGroundSnapHits++
            }
            elseif ($body.StartsWith("snap already grounded")) {
                $status = "already-grounded"
                $proofGroundSnapHits++
            }
            elseif ($body.StartsWith("snap missed")) {
                $status = "missed"
                $proofGroundSnapMisses++
            }
            elseif ($body.StartsWith("snap failed")) {
                $status = "failed"
                $proofGroundSnapFailures++
            }
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "render-ground-snap" -Force
            $entry | Add-Member -NotePropertyName status -NotePropertyValue $status -Force
            $proofGroundSnapEvents++
            $latestProofGroundSnap = $entry
            if ($proofGroundSnaps.Count -lt 80) {
                $proofGroundSnaps.Add($entry)
            }
            continue
        }

        $proofActorBoundsIndex = $line.IndexOf("FNV/ESM4 proof: actor render bounds")
        if ($proofActorBoundsIndex -ge 0) {
            $body = $line.Substring($proofActorBoundsIndex + "FNV/ESM4 proof: actor render bounds".Length).Trim()
            $entry = Parse-WorldViewerKeyValues $body
            $valid = -not $body.StartsWith("invalid")
            $entry | Add-Member -NotePropertyName valid -NotePropertyValue $valid -Force
            $proofActorBoundsEvents++
            if ($valid) {
                $proofActorBoundsValid++
                $latestProofActorBounds = $entry
            }
            else {
                $proofActorBoundsInvalid++
            }
            if ($proofActorBounds.Count -lt 80) {
                $proofActorBounds.Add($entry)
            }
            continue
        }

        $proofActorCameraRaycastIndex = $line.IndexOf("FNV/ESM4 proof: actor orbit camera raycast ")
        if ($proofActorCameraRaycastIndex -ge 0) {
            $body = $line.Substring($proofActorCameraRaycastIndex + "FNV/ESM4 proof: actor orbit camera raycast ".Length).Trim()
            $entry = Parse-WorldViewerKeyValues $body
            $status = "<unknown>"
            if ($body.StartsWith("adjusted")) {
                $status = "adjusted"
                $proofActorCameraRaycastAdjusted++
            }
            elseif ($body.StartsWith("clear")) {
                $status = "clear"
                $proofActorCameraRaycastClear++
            }
            elseif ($body.StartsWith("hit too close")) {
                $status = "too-close"
                $proofActorCameraRaycastTooClose++
            }
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "actor-camera-raycast" -Force
            $entry | Add-Member -NotePropertyName status -NotePropertyValue $status -Force
            $proofActorCameraRaycastEvents++
            $latestProofActorCameraRaycast = $entry
            if ($proofActorCameraRaycasts.Count -lt 80) {
                $proofActorCameraRaycasts.Add($entry)
            }
            continue
        }

        $proofActorOrbitCandidateIndex = $line.IndexOf("FNV/ESM4 proof: actor orbit camera candidate ")
        if ($proofActorOrbitCandidateIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($proofActorOrbitCandidateIndex + "FNV/ESM4 proof: actor orbit camera candidate ".Length).Trim())
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "actor-camera-orbit-candidate" -Force
            $proofActorOrbitCandidateEvents++
            if ((Convert-WorldViewerInt (Get-PropertyValue $entry "blockers")) -eq 0) {
                $proofActorOrbitCandidateClear++
            }
            if ($proofActorOrbitCandidates.Count -lt 120) {
                $proofActorOrbitCandidates.Add($entry)
            }
            continue
        }

        $proofActorOrbitSelectedIndex = $line.IndexOf("FNV/ESM4 proof: actor orbit camera selected ")
        if ($proofActorOrbitSelectedIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($proofActorOrbitSelectedIndex + "FNV/ESM4 proof: actor orbit camera selected ".Length).Trim())
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "actor-camera-orbit-selected" -Force
            $proofActorOrbitSelectedEvents++
            $latestProofActorOrbitSelection = $entry
            if ($proofActorOrbitCandidates.Count -lt 120) {
                $proofActorOrbitCandidates.Add($entry)
            }
            continue
        }

        $proofActorOrbitKeptIndex = $line.IndexOf("FNV/ESM4 proof: actor orbit camera kept ")
        if ($proofActorOrbitKeptIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($proofActorOrbitKeptIndex + "FNV/ESM4 proof: actor orbit camera kept ".Length).Trim())
            $entry | Add-Member -NotePropertyName phase -NotePropertyValue "actor-camera-orbit-kept" -Force
            $proofActorOrbitKeptEvents++
            $latestProofActorOrbitSelection = $entry
            if ($proofActorOrbitCandidates.Count -lt 120) {
                $proofActorOrbitCandidates.Add($entry)
            }
            continue
        }

        $refIndex = $line.IndexOf("World viewer ref:")
        if ($refIndex -ge 0) {
            $ref = Parse-WorldViewerKeyValues ($line.Substring($refIndex + "World viewer ref:".Length).Trim())
            $loggedRefs++
            $typeValue = Get-PropertyValue $ref "type"
            $typeName = if ($null -ne $typeValue) { [string]$typeValue } else { "<unknown>" }
            if (-not $refsByType.Contains($typeName)) {
                $refsByType[$typeName] = 0
            }
            $refsByType[$typeName]++

            $rendered = Convert-WorldViewerFlag (Get-PropertyValue $ref "rendered")
            $actor = Convert-WorldViewerFlag (Get-PropertyValue $ref "actor")
            if ($rendered) {
                $loggedRenderedRefs++
            }
            if ($actor) {
                $loggedActorRefs++
                if ($rendered) {
                    $loggedRenderedActorRefs++
                }
            }
            if ((-not $rendered -or ($actor -and -not $rendered)) -and $problemRefs.Count -lt 40) {
                $problemRefs.Add($ref)
            }
            continue
        }

        $rayIndex = $line.IndexOf("World viewer ray:")
        if ($rayIndex -ge 0) {
            $ray = Parse-WorldViewerKeyValues ($line.Substring($rayIndex + "World viewer ray:".Length).Trim())
            $kindValue = Get-PropertyValue $ray "kind"
            $kind = if ($null -ne $kindValue) { [string]$kindValue } else { "<unknown>" }
            if (-not $rayKinds.Contains($kind)) {
                $rayKinds[$kind] = 0
            }
            $rayKinds[$kind]++

            $hit = Convert-WorldViewerFlag (Get-PropertyValue $ray "hit")
            $actorHit = Convert-WorldViewerFlag (Get-PropertyValue $ray "actorHit")
            if ($hit) {
                $rayHits++
            }
            if ($hit -and ($kind -eq "playerGround" -or $kind -eq "cameraGround")) {
                $groundRayHits++
            }
            if ($hit -and $kind -eq "cameraCenterRender") {
                $centerRenderHits++
            }
            if ($hit -and ($kind -eq "cameraActorRender" -or $kind -eq "actorCrossPhysics")) {
                $actorRayHits++
            }
            if ($actorHit -and ($kind -eq "cameraActorRender" -or $kind -eq "actorCrossPhysics")) {
                $actorRayActorHits++
            }
            if ($rays.Count -lt 120) {
                $rays.Add($ray)
            }
            continue
        }
    }

    [pscustomobject][ordered]@{
        latestTelemetry = $latestTelemetry
        cellCount = $cells.Count
        cellRefs = $cellRefs
        cellEnabled = $cellEnabled
        cellRendered = $cellRendered
        cellMissingRenderNode = $cellMissingRenderNode
        cellActors = $cellActors
        cellRenderedActors = $cellRenderedActors
        cellDoors = $cellDoors
        cellDeleted = $cellDeleted
        loggedRefs = $loggedRefs
        loggedRenderedRefs = $loggedRenderedRefs
        loggedActorRefs = $loggedActorRefs
        loggedRenderedActorRefs = $loggedRenderedActorRefs
        proxyActorRefs = $proxyActorRefs
        proxyTposeRefs = $proxyTposeRefs
        proxyAnimatedRefs = $proxyAnimatedRefs
        nativeActorLedgerEvents = $nativeActorLedgerEvents
        nativeActorRenderBegins = $nativeActorRenderBegins
        nativeActorRenderEnds = $nativeActorRenderEnds
        nativeActorCustomData = $nativeActorCustomData
        nativeActorRootBegins = $nativeActorRootBegins
        nativeActorRootEnds = $nativeActorRootEnds
        nativeActorRootExceptions = $nativeActorRootExceptions
        nativeActorModelFallbacks = $nativeActorModelFallbacks
        nativeActorPartsRequested = $nativeActorPartsRequested
        nativeActorPartsTemplated = $nativeActorPartsTemplated
        nativeActorPartsAttached = $nativeActorPartsAttached
        nativeActorPartsMissing = $nativeActorPartsMissing
        nativeActorPartsQuarantined = $nativeActorPartsQuarantined
        nativeActorTemplateExceptions = $nativeActorTemplateExceptions
        nativeActorAnimSources = $nativeActorAnimSources
        nativeActorAnimSourcesBound = $nativeActorAnimSourcesBound
        nativeActorControllerSources = $nativeActorControllerSources
        nativeActorControllersBound = $nativeActorControllersBound
        nativeActorControllersTotal = $nativeActorControllersTotal
        nativeActorControllerZeroSources = $nativeActorControllerZeroSources
        staticSkeletonAttachEvents = $staticSkeletonAttachEvents
        tes5StaticFaceSurfaceFallbackEvents = $tes5StaticFaceSurfaceFallbackEvents
        meshLedgerEvents = $meshLedgerEvents
        meshLoadFailureEvents = $meshLoadFailureEvents
        meshTemplateFinalEvents = $meshTemplateFinalEvents
        meshTemplateFinalWithGeometry = $meshTemplateFinalWithGeometry
        meshTemplateFinalEmptyGeometry = $meshTemplateFinalEmptyGeometry
        meshTemplateFinalInvalidBounds = $meshTemplateFinalInvalidBounds
        actorMeshTemplateEvents = $actorMeshTemplateEvents
        actorMeshTemplateWithGeometry = $actorMeshTemplateWithGeometry
        actorMeshTemplateEmptyGeometry = $actorMeshTemplateEmptyGeometry
        starfieldExternalMeshEvents = $starfieldExternalMeshEvents
        starfieldExternalMeshVertices = $starfieldExternalMeshVertices
        starfieldExternalMeshIndices = $starfieldExternalMeshIndices
        starfieldExternalMeshWithUv = $starfieldExternalMeshWithUv
        starfieldExternalMeshWithNormals = $starfieldExternalMeshWithNormals
        starfieldExternalMeshFailures = $starfieldExternalMeshFailures
        starfieldActorProofTextureEvents = $starfieldActorProofTextureEvents
        starfieldActorProofTextureUnits = $starfieldActorProofTextureUnits
        starfieldWorldProofTextureEvents = $starfieldWorldProofTextureEvents
        starfieldWorldProofTextureUnits = $starfieldWorldProofTextureUnits
        starfieldWorldMaterialFallbackEvents = $starfieldWorldMaterialFallbackEvents
        starfieldWorldSkippedGeometryEvents = $starfieldWorldSkippedGeometryEvents
        starfieldBsGeometryProxyEvents = $starfieldBsGeometryProxyEvents
        meshStages = [pscustomobject]$meshStages
        textureLedgerEvents = $textureLedgerEvents
        textureImagesResolved = $textureImagesResolved
        textureImagesMissing = $textureImagesMissing
        textureSkinAuxSkipped = $textureSkinAuxSkipped
        textureRoles = [pscustomobject]$textureRoles
        materialLedgerEvents = $materialLedgerEvents
        materialWithTextureUnits = $materialWithTextureUnits
        materialWithoutTextureUnits = $materialWithoutTextureUnits
        materialShaderRequired = $materialShaderRequired
        materialWithVertexColors = $materialWithVertexColors
        materialWithAlphaSort = $materialWithAlphaSort
        materialColorModeOff = $materialColorModeOff
        materialColorModeNonOff = $materialColorModeNonOff
        materialShaderPrefixes = [pscustomobject]$materialShaderPrefixes
        materialBsLightingTypes = [pscustomobject]$materialBsLightingTypes
        nifGeometryLedgerEvents = $nifGeometryLedgerEvents
        nifGeometryWithVertices = $nifGeometryWithVertices
        nifGeometryWithTriangles = $nifGeometryWithTriangles
        bsGeometryLedgerEvents = $bsGeometryLedgerEvents
        bsGeometryWithInlineTriangles = $bsGeometryWithInlineTriangles
        bsGeometryWithSkinPartitions = $bsGeometryWithSkinPartitions
        bsGeometryWithPartitionTriangles = $bsGeometryWithPartitionTriangles
        bsPartitionFallbackEvents = $bsPartitionFallbackEvents
        bsPartitionFallbackAttached = $bsPartitionFallbackAttached
        bsPartitionFallbackEmptyVertices = $bsPartitionFallbackEmptyVertices
        bsPartitionFallbackGeneratedNormals = $bsPartitionFallbackGeneratedNormals
        bsAttachedEvents = $bsAttachedEvents
        bsGeometryQuarantineEvents = $bsGeometryQuarantineEvents
        osgUpdateCallbackEvents = $osgUpdateCallbackEvents
        osgUpdateCallbackSummaries = $osgUpdateCallbackSummaries
        osgUpdateNodeCallbacks = $osgUpdateNodeCallbacks
        osgUpdateNodeOwnersStripped = $osgUpdateNodeOwnersStripped
        osgUpdateStateSetCallbacks = $osgUpdateStateSetCallbacks
        osgUpdateStateSetOwnersStripped = $osgUpdateStateSetOwnersStripped
        refsByType = [pscustomobject]$refsByType
        refDumpTruncated = $refDumpTruncated
        rayCount = $rays.Count
        rayHits = $rayHits
        groundRayHits = $groundRayHits
        centerRenderHits = $centerRenderHits
        actorRayHits = $actorRayHits
        actorRayActorHits = $actorRayActorHits
        proofActorStageEvents = $proofActorStageEvents
        proofGroundSnapEvents = $proofGroundSnapEvents
        proofGroundSnapHits = $proofGroundSnapHits
        proofGroundSnapMisses = $proofGroundSnapMisses
        proofGroundSnapFailures = $proofGroundSnapFailures
        proofActorBoundsEvents = $proofActorBoundsEvents
        proofActorBoundsValid = $proofActorBoundsValid
        proofActorBoundsInvalid = $proofActorBoundsInvalid
        proofActorCameraRaycastEvents = $proofActorCameraRaycastEvents
        proofActorCameraRaycastAdjusted = $proofActorCameraRaycastAdjusted
        proofActorCameraRaycastClear = $proofActorCameraRaycastClear
        proofActorCameraRaycastTooClose = $proofActorCameraRaycastTooClose
        proofActorOrbitCandidateEvents = $proofActorOrbitCandidateEvents
        proofActorOrbitCandidateClear = $proofActorOrbitCandidateClear
        proofActorOrbitSelectedEvents = $proofActorOrbitSelectedEvents
        proofActorOrbitKeptEvents = $proofActorOrbitKeptEvents
        latestProofActorStage = $latestProofActorStage
        latestProofGroundSnap = $latestProofGroundSnap
        latestProofActorBounds = $latestProofActorBounds
        latestProofActorCameraRaycast = $latestProofActorCameraRaycast
        latestProofActorOrbitSelection = $latestProofActorOrbitSelection
        rayKinds = [pscustomobject]$rayKinds
        cells = @($cells.ToArray())
        rays = @($rays.ToArray())
        actorLedger = @($actorLedger.ToArray())
        meshLedger = @($meshLedger.ToArray())
        starfieldMeshLedger = @($starfieldMeshLedger.ToArray())
        geometryLedger = @($geometryLedger.ToArray())
        textureLedger = @($textureLedger.ToArray())
        starfieldActorTextureLedger = @($starfieldActorTextureLedger.ToArray())
        starfieldWorldTextureLedger = @($starfieldWorldTextureLedger.ToArray())
        starfieldWorldMaterialFallbackLedger = @($starfieldWorldMaterialFallbackLedger.ToArray())
        starfieldWorldSkippedGeometryLedger = @($starfieldWorldSkippedGeometryLedger.ToArray())
        materialLedger = @($materialLedger.ToArray())
        meshLoadFailures = @($meshLoadFailures.ToArray())
        staticSkeletonAttaches = @($staticSkeletonAttaches.ToArray())
        tes5FaceSurfaceFallbacks = @($tes5FaceSurfaceFallbacks.ToArray())
        proofActorStages = @($proofActorStages.ToArray())
        proofGroundSnaps = @($proofGroundSnaps.ToArray())
        proofActorBounds = @($proofActorBounds.ToArray())
        proofActorCameraRaycasts = @($proofActorCameraRaycasts.ToArray())
        proofActorOrbitCandidates = @($proofActorOrbitCandidates.ToArray())
        problemRefs = @($problemRefs.ToArray())
    }
}

function Get-OpenMwCrashDumpInfo([string[]]$Roots, [datetime]$Since) {
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -File -Filter "openmw-crash*.dmp" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Since } |
            ForEach-Object { $candidates.Add($_) }
    }

    $dump = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $dump) {
        return $null
    }

    [pscustomobject][ordered]@{
        path = Convert-ToForwardSlash -Path $dump.FullName
        length = $dump.Length
        lastWriteTime = $dump.LastWriteTime.ToString("o")
    }
}

foreach ($path in @($SeedPath, $StartsPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required input: $path"
    }
}

$BinaryRoot = Resolve-NikamiProofBinaryRoot -ParameterValue $BinaryRoot

$binary = Join-Path $BinaryRoot "openmw.exe"

$seed = Get-Content -LiteralPath $SeedPath -Raw | ConvertFrom-Json
$starts = Get-Content -LiteralPath $StartsPath -Raw | ConvertFrom-Json

$selected = @($seed.worlds | Where-Object { $_.readyForWorldWalker -eq $true })
if ($WorldId.Count -gt 0) {
    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $WorldId) {
        [void]$wanted.Add($id)
    }
    $selected = @($selected | Where-Object { $wanted.Contains($_.id) })
}
if ($selected.Count -eq 0) {
    throw "No ready worlds selected."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$proofDir = Join-Path $ProofRoot $stamp
$cwdPath = (Get-Location).Path
$absProofDir = Join-Path $cwdPath $proofDir
$screensDir = Join-Path $absProofDir "screenshots"
$logsDir = Join-Path $absProofDir "logs"
New-Item -ItemType Directory -Force -Path $screensDir, $logsDir | Out-Null

$defaultRunSeconds = [int]$starts.defaults.runSeconds
if ($RunSeconds -le 0) {
    $RunSeconds = $defaultRunSeconds
}
if ([string]::IsNullOrWhiteSpace($ScreenshotFrames)) {
    $ScreenshotFrames = [string]$starts.defaults.screenshotFrames
}
$defaultExtraArgs = @($starts.defaults.extraArgs)

$viewerStartEnvNames = @(
    "OPENMW_WORLD_VIEWER_START_POS_X",
    "OPENMW_WORLD_VIEWER_START_POS_Y",
    "OPENMW_WORLD_VIEWER_START_POS_Z",
    "OPENMW_WORLD_VIEWER_START_ROT_X",
    "OPENMW_WORLD_VIEWER_START_ROT_Y",
    "OPENMW_WORLD_VIEWER_START_ROT_Z",
    "OPENMW_WORLD_VIEWER_START_WORLDSPACE",
    "OPENMW_WORLD_VIEWER_START_GRID_X",
    "OPENMW_WORLD_VIEWER_START_GRID_Y",
    "OPENMW_WORLD_VIEWER_START_DRY",
    "OPENMW_WORLD_VIEWER_START_CAMERA_MODE",
    "OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE",
    "OPENMW_WORLD_VIEWER_START_CAMERA_PITCH",
    "OPENMW_WORLD_VIEWER_START_CAMERA_YAW",
    "OPENMW_WORLD_VIEWER_START_CAMERA_POS_X",
    "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Y",
    "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Z",
    "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_X",
    "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Y",
    "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Z",
    "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_RAYCAST",
    "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_SAMPLES",
    "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_RADIUS",
    "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_HEIGHT",
    "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_CLEARANCE",
    "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_MIN_HIT_DISTANCE",
    "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_MIN_GROUND_HEIGHT",
    "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_GROUND_RAY_DISTANCE"
)

$viewerProofEnvNames = @(
    "OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG",
    "OPENMW_WORLD_VIEWER_TELEMETRY",
    "OPENMW_WORLD_VIEWER_TRACE",
    "OPENMW_WORLD_VIEWER_TELEMETRY_INTERVAL",
    "OPENMW_WORLD_VIEWER_REF_TELEMETRY",
    "OPENMW_WORLD_VIEWER_REF_TELEMETRY_LIMIT",
    "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY",
    "OPENMW_WORLD_VIEWER_MESH_LOAD_TELEMETRY",
    "OPENMW_WORLD_VIEWER_MATERIAL_TELEMETRY",
    "OPENMW_WORLD_VIEWER_ALLOW_MISSING_SKIN_BONES",
    "OPENMW_WORLD_VIEWER_ENABLE_SKIN_PARTITION_FALLBACK",
    "OPENMW_WORLD_VIEWER_GENERATE_MISSING_BS_NORMALS",
    "OPENMW_WORLD_VIEWER_QUARANTINE_FO4_ACTOR_BSSUBINDEXTRISHAPE",
    "OPENMW_WORLD_VIEWER_ATTACH_STATIC_SKELETON_PARTS",
    "OPENMW_WORLD_VIEWER_IGNORE_BS_PARTITION_VERTEX_COLORS",
    "OPENMW_WORLD_VIEWER_FORCE_FLAT_ACTOR_MATERIALS",
    "OPENMW_WORLD_VIEWER_FORCE_FLAT_NIF_MATERIALS",
    "OPENMW_WORLD_VIEWER_FORCE_FLAT_WORLD_MATERIALS",
    "OPENMW_WORLD_VIEWER_FULLBRIGHT_ACTOR_MATERIALS",
    "OPENMW_WORLD_VIEWER_FULLBRIGHT_NIF_MATERIALS",
    "OPENMW_WORLD_VIEWER_FULLBRIGHT_WORLD_MATERIALS",
    "OPENMW_WORLD_VIEWER_STARFIELD_ACTOR_PNG_TEXTURES",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_PARTS",
    "OPENMW_WORLD_VIEWER_POSITION_SCALE_STATIC_ACTOR_PARTS",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HEAD_PARTS",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HAIR_PARTS",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_FACE_HAIR_PARTS",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_BROW_PARTS",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_EYE_PARTS",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_MOUTH_PARTS",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HAND_PARTS",
    "OPENMW_WORLD_VIEWER_FORCE_ACTOR_PART_MASK",
    "OPENMW_WORLD_VIEWER_ROTATE_TES5_HAIR_PART_AXES",
    "OPENMW_WORLD_VIEWER_TES5_HAIR_PART_ROTATION_Z",
    "OPENMW_WORLD_VIEWER_ROTATE_TES5_FACE_PART_AXES",
    "OPENMW_WORLD_VIEWER_TES5_FACE_PART_ROTATION_Z",
    "OPENMW_WORLD_VIEWER_INSERT_ALL_ESM4_ARMOR_ADDONS",
    "OPENMW_WORLD_VIEWER_SKIP_ESM4_SKIN_WHEN_CLOTHED",
    "OPENMW_WORLD_VIEWER_DISABLE_TES5_STATIC_FACE_SURFACE_ANCHOR",
    "OPENMW_WORLD_VIEWER_SKIP_MISSING_ACTOR_PARTS",
    "OPENMW_WORLD_VIEWER_SKIP_UNMAPPED_RIGGED_ACTOR_PARTS",
    "OPENMW_WORLD_VIEWER_FREEZE_ESM4_ACTOR_MECHANICS",
    "OPENMW_WORLD_VIEWER_SKIP_OSG_UPDATE_TRAVERSAL",
    "OPENMW_WORLD_VIEWER_AUDIT_OSG_UPDATE_CALLBACKS",
    "OPENMW_WORLD_VIEWER_AUDIT_OSG_UPDATE_CALLBACKS_EVERY_FRAME",
    "OPENMW_WORLD_VIEWER_OSG_UPDATE_CALLBACK_AUDIT_LIMIT",
    "OPENMW_WORLD_VIEWER_STRIP_OSG_UPDATE_CALLBACKS",
    "OPENMW_WORLD_VIEWER_STRIP_OSG_NODE_UPDATE_CALLBACKS",
    "OPENMW_WORLD_VIEWER_STRIP_OSG_STATESET_UPDATE_CALLBACKS",
    "OPENMW_WORLD_VIEWER_STRIP_OSG_UPDATE_CALLBACK_CLASS_FILTER",
    "OPENMW_WORLD_VIEWER_KEEP_OSG_UPDATE_CALLBACK_PATH_FILTER",
    "OPENMW_WORLD_VIEWER_RAY_TELEMETRY",
    "OPENMW_WORLD_VIEWER_RAY_DISTANCE",
    "OPENMW_WORLD_VIEWER_ACTOR_RAY_LIMIT",
    "OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS",
    "OPENMW_WORLD_VIEWER_NEUTRAL_MISSING_TEXTURES",
    "OPENMW_WORLD_VIEWER_RENDER_DISABLED_ACTORS",
    "OPENMW_WORLD_VIEWER_DISABLE_ESM4_ACTORS",
    "OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXIES",
    "OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXY_ANIMATE",
    "OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS",
    "OPENMW_WORLD_VIEWER_REQUIRE_CAMERA_SETTLED",
    "OPENMW_PROOF_DISABLE_SKY",
    "OPENMW_PROOF_HIDE_FIRST_PERSON",
    "OPENMW_PROOF_HIDE_PLAYER_VISUAL",
    "OPENMW_PROOF_HIDE_WORLD_VISUAL"
)

$previousEnv = @{}
$processEnvOverrides = @(ConvertTo-ProcessEnvOverrides -Assignments $SetEnv)
$envNamesToPreserve = @("OPENMW_PROOF_SCREENSHOT_FRAME", "OPENMW_PROOF_SCREENSHOT_READY_FRAMES", "OPENMW_FNV_BOOTSTRAP_HOUR", "OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI", "OPENMW_PROOF_HIDE_GUI") + $viewerStartEnvNames + $viewerProofEnvNames + @($processEnvOverrides | ForEach-Object { $_.name })
foreach ($name in @($envNamesToPreserve | Sort-Object -Unique)) {
    $previousEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$results = New-Object System.Collections.Generic.List[object]

try {
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_PROOF_SCREENSHOT_FRAME", $ScreenshotFrames, "Process")
    if ($ScreenshotReadyFrames -ge 0) {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_SCREENSHOT_READY_FRAMES", [string]$ScreenshotReadyFrames, "Process")
    }
    elseif ([string]::IsNullOrWhiteSpace($ScreenshotFrames)) {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_SCREENSHOT_READY_FRAMES", "90", "Process")
    }
    else {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_SCREENSHOT_READY_FRAMES", "120", "Process")
    }
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_BOOTSTRAP_HOUR", "12", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI", "1", "Process")
    if ($ShowGui) {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_HIDE_GUI", $null, "Process")
    }
    else {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_HIDE_GUI", "1", "Process")
    }
    if (-not $NoTelemetry) {
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_TRACE", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_TELEMETRY_INTERVAL", [string]$TelemetryInterval, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_REF_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_REF_TELEMETRY_LIMIT", [string]$RefTelemetryLimit, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_MESH_LOAD_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_MATERIAL_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ALLOW_MISSING_SKIN_BONES", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ENABLE_SKIN_PARTITION_FALLBACK", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_GENERATE_MISSING_BS_NORMALS", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ATTACH_STATIC_SKELETON_PARTS", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_IGNORE_BS_PARTITION_VERTEX_COLORS", $null, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FORCE_FLAT_ACTOR_MATERIALS", $null, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FORCE_FLAT_NIF_MATERIALS", $null, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FORCE_FLAT_WORLD_MATERIALS", $null, "Process")
        if ($FullbrightNativeMaterials -or $FullbrightActorMaterialsOnly) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FULLBRIGHT_ACTOR_MATERIALS", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FULLBRIGHT_ACTOR_MATERIALS", $null, "Process")
        }
        if ($FullbrightNativeMaterials) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FULLBRIGHT_NIF_MATERIALS", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FULLBRIGHT_WORLD_MATERIALS", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FULLBRIGHT_NIF_MATERIALS", $null, "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FULLBRIGHT_WORLD_MATERIALS", $null, "Process")
        }
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SKIP_MISSING_ACTOR_PARTS", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SKIP_UNMAPPED_RIGGED_ACTOR_PARTS", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FREEZE_ESM4_ACTOR_MECHANICS", "1", "Process")
        if ($AllowOsgUpdateTraversal) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SKIP_OSG_UPDATE_TRAVERSAL", $null, "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_AUDIT_OSG_UPDATE_CALLBACKS", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_OSG_UPDATE_CALLBACK_AUDIT_LIMIT", [string]$OsgUpdateCallbackAuditLimit, "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SKIP_OSG_UPDATE_TRAVERSAL", "1", "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_AUDIT_OSG_UPDATE_CALLBACKS", $null, "Process")
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_OSG_UPDATE_CALLBACK_AUDIT_LIMIT", $null, "Process")
        }
        if ($StripOsgUpdateCallbacks) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STRIP_OSG_UPDATE_CALLBACKS", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STRIP_OSG_UPDATE_CALLBACKS", $null, "Process")
        }
        if ($StripOsgNodeUpdateCallbacks) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STRIP_OSG_NODE_UPDATE_CALLBACKS", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STRIP_OSG_NODE_UPDATE_CALLBACKS", $null, "Process")
        }
        if ($StripOsgStateSetUpdateCallbacks) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STRIP_OSG_STATESET_UPDATE_CALLBACKS", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STRIP_OSG_STATESET_UPDATE_CALLBACKS", $null, "Process")
        }
        if ($StripOsgUpdateCallbackClass.Count -gt 0) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STRIP_OSG_UPDATE_CALLBACK_CLASS_FILTER", ($StripOsgUpdateCallbackClass -join ";"), "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STRIP_OSG_UPDATE_CALLBACK_CLASS_FILTER", $null, "Process")
        }
        if ($KeepOsgUpdateCallbackPath.Count -gt 0) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_KEEP_OSG_UPDATE_CALLBACK_PATH_FILTER", ($KeepOsgUpdateCallbackPath -join ";"), "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_KEEP_OSG_UPDATE_CALLBACK_PATH_FILTER", $null, "Process")
        }
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_RAY_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_RAY_DISTANCE", "200000", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ACTOR_RAY_LIMIT", "8", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_NEUTRAL_MISSING_TEXTURES", $null, "Process")
        if ($RenderDisabledActors) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_RENDER_DISABLED_ACTORS", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_RENDER_DISABLED_ACTORS", $null, "Process")
        }
    }
    else {
        foreach ($name in @("OPENMW_WORLD_VIEWER_TELEMETRY", "OPENMW_WORLD_VIEWER_TRACE", "OPENMW_WORLD_VIEWER_REF_TELEMETRY", "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY", "OPENMW_WORLD_VIEWER_MESH_LOAD_TELEMETRY", "OPENMW_WORLD_VIEWER_MATERIAL_TELEMETRY", "OPENMW_WORLD_VIEWER_ALLOW_MISSING_SKIN_BONES", "OPENMW_WORLD_VIEWER_ENABLE_SKIN_PARTITION_FALLBACK", "OPENMW_WORLD_VIEWER_GENERATE_MISSING_BS_NORMALS", "OPENMW_WORLD_VIEWER_ATTACH_STATIC_SKELETON_PARTS", "OPENMW_WORLD_VIEWER_IGNORE_BS_PARTITION_VERTEX_COLORS", "OPENMW_WORLD_VIEWER_FORCE_FLAT_ACTOR_MATERIALS", "OPENMW_WORLD_VIEWER_FORCE_FLAT_NIF_MATERIALS", "OPENMW_WORLD_VIEWER_FORCE_FLAT_WORLD_MATERIALS", "OPENMW_WORLD_VIEWER_FULLBRIGHT_ACTOR_MATERIALS", "OPENMW_WORLD_VIEWER_FULLBRIGHT_NIF_MATERIALS", "OPENMW_WORLD_VIEWER_FULLBRIGHT_WORLD_MATERIALS", "OPENMW_WORLD_VIEWER_STARFIELD_ACTOR_PNG_TEXTURES", "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HEAD_PARTS", "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HAIR_PARTS", "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_FACE_HAIR_PARTS", "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_BROW_PARTS", "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_EYE_PARTS", "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_MOUTH_PARTS", "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HAND_PARTS", "OPENMW_WORLD_VIEWER_FORCE_ACTOR_PART_MASK", "OPENMW_WORLD_VIEWER_ROTATE_TES5_HAIR_PART_AXES", "OPENMW_WORLD_VIEWER_TES5_HAIR_PART_ROTATION_Z", "OPENMW_WORLD_VIEWER_ROTATE_TES5_FACE_PART_AXES", "OPENMW_WORLD_VIEWER_TES5_FACE_PART_ROTATION_Z", "OPENMW_WORLD_VIEWER_INSERT_ALL_ESM4_ARMOR_ADDONS", "OPENMW_WORLD_VIEWER_SKIP_ESM4_SKIN_WHEN_CLOTHED", "OPENMW_WORLD_VIEWER_SKIP_MISSING_ACTOR_PARTS", "OPENMW_WORLD_VIEWER_SKIP_UNMAPPED_RIGGED_ACTOR_PARTS", "OPENMW_WORLD_VIEWER_FREEZE_ESM4_ACTOR_MECHANICS", "OPENMW_WORLD_VIEWER_SKIP_OSG_UPDATE_TRAVERSAL", "OPENMW_WORLD_VIEWER_AUDIT_OSG_UPDATE_CALLBACKS", "OPENMW_WORLD_VIEWER_AUDIT_OSG_UPDATE_CALLBACKS_EVERY_FRAME", "OPENMW_WORLD_VIEWER_OSG_UPDATE_CALLBACK_AUDIT_LIMIT", "OPENMW_WORLD_VIEWER_STRIP_OSG_UPDATE_CALLBACKS", "OPENMW_WORLD_VIEWER_STRIP_OSG_NODE_UPDATE_CALLBACKS", "OPENMW_WORLD_VIEWER_STRIP_OSG_STATESET_UPDATE_CALLBACKS", "OPENMW_WORLD_VIEWER_STRIP_OSG_UPDATE_CALLBACK_CLASS_FILTER", "OPENMW_WORLD_VIEWER_KEEP_OSG_UPDATE_CALLBACK_PATH_FILTER", "OPENMW_WORLD_VIEWER_RAY_TELEMETRY", "OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS", "OPENMW_WORLD_VIEWER_NEUTRAL_MISSING_TEXTURES", "OPENMW_WORLD_VIEWER_RENDER_DISABLED_ACTORS", "OPENMW_WORLD_VIEWER_FOCUS_ACTOR", "OPENMW_PROOF_HIDE_FIRST_PERSON", "OPENMW_PROOF_HIDE_PLAYER_VISUAL", "OPENMW_PROOF_HIDE_WORLD_VISUAL")) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    if ([string]::IsNullOrWhiteSpace($FocusActor)) {
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FOCUS_ACTOR", $null, "Process")
    }
    else {
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_FOCUS_ACTOR", $FocusActor, "Process")
    }
    $starfieldOnlyProof = $selected.Count -eq 1 -and $selected[0].id -eq "starfield"
    if ($starfieldOnlyProof) {
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_REQUIRE_CAMERA_SETTLED", $null, "Process")
    }
    else {
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_REQUIRE_CAMERA_SETTLED", "1", "Process")
    }
    if ($DisableSky) {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_DISABLE_SKY", "1", "Process")
    }
    else {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_DISABLE_SKY", $null, "Process")
    }

    foreach ($world in $selected) {
        foreach ($name in $viewerStartEnvNames) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }

        $start = Get-PropertyValue $starts.worlds $world.id
        $startCell = if ($null -ne $start) { [string]$start.startCell } else { "" }
        $label = if ($null -ne $start) { [string]$start.label } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($StartCellOverride)) {
            if ($selected.Count -ne 1) {
                throw "-StartCellOverride can only be used when exactly one -WorldId is selected."
            }
            $startCell = $StartCellOverride
            $label = "manual probe"
        }

        $worldGridRadius = $Esm4GridRadius
        if ($worldGridRadius -lt 0) {
            $startGridRadius = Get-PropertyValue $start "esm4GridRadius"
            $defaultGridRadius = Get-PropertyValue $starts.defaults "esm4GridRadius"
            if ($null -ne $startGridRadius) {
                $worldGridRadius = [int]$startGridRadius
            }
            elseif ($null -ne $defaultGridRadius) {
                $worldGridRadius = [int]$defaultGridRadius
            }
        }
        if ($worldGridRadius -ge 0) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS", [string]$worldGridRadius, "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS", $null, "Process")
        }
        $disableEsm4Actors = $DisableActors -or ((Get-PropertyValue $start "disableEsm4Actors") -eq $true)
        if ($disableEsm4Actors) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_DISABLE_ESM4_ACTORS", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_DISABLE_ESM4_ACTORS", $null, "Process")
        }
        if ($world.id -eq "fallout4" -or $world.id -eq "fallout4_vr") {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_QUARANTINE_FO4_ACTOR_BSSUBINDEXTRISHAPE", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_QUARANTINE_FO4_ACTOR_BSSUBINDEXTRISHAPE", $null, "Process")
        }
        $esm4ActorProxies = ((Get-PropertyValue $start "esm4ActorProxies") -eq $true)
        if ($esm4ActorProxies) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXIES", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXIES", $null, "Process")
        }
        $esm4ActorProxyAnimate = ((Get-PropertyValue $start "esm4ActorProxyAnimate") -eq $true)
        if ($esm4ActorProxies -and $esm4ActorProxyAnimate) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXY_ANIMATE", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXY_ANIMATE", $null, "Process")
        }

        $worldRunDir = Join-Path $absProofDir $world.id
        $userDataDir = Join-Path $worldRunDir "userdata"
        $stdoutLog = Join-Path $logsDir "$($world.id).stdout.log"
        $stderrLog = Join-Path $logsDir "$($world.id).stderr.log"
        $windowCapture = Join-Path $screensDir "$($world.id).window.png"
        New-Item -ItemType Directory -Force -Path $worldRunDir | Out-Null
        $runConfig = New-ProofRunConfig -World $world -WorldRunDir $worldRunDir -UserDataDir $userDataDir
        $starfieldTextureCache = $null
        if ($world.id -eq "starfield") {
            $starfieldTextureCache = Convert-StarfieldActorProofTextures `
                -OpenMwCfg $runConfig.openmwCfg `
                -DataLocalDirectory $runConfig.dataLocalDirectory `
                -BinaryRoot $BinaryRoot
            if ($starfieldTextureCache.count -gt 0) {
                [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STARFIELD_ACTOR_PNG_TEXTURES", "1", "Process")
                Write-Host "Starfield actor texture cache: $($starfieldTextureCache.count) PNGs, $($starfieldTextureCache.alphaMerged) opacity masks merged"
            }
            else {
                [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STARFIELD_ACTOR_PNG_TEXTURES", $null, "Process")
            }
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_STARFIELD_ACTOR_PNG_TEXTURES", $null, "Process")
        }
        $resourcesDir = Join-Path $BinaryRoot "resources"

        $argsList = New-Object System.Collections.Generic.List[string]
        $argsList.Add("--replace")
        $argsList.Add("config")
        $argsList.Add("--config")
        $argsList.Add($runConfig.configDirectory)
        $argsList.Add("--user-data")
        $argsList.Add($userDataDir)
        $argsList.Add("--data-local")
        $argsList.Add($runConfig.dataLocalDirectory)
        if (Test-Path -LiteralPath $resourcesDir) {
            $argsList.Add("--resources")
            $argsList.Add($resourcesDir)
        }
        $argsList.Add("--skip-menu")
        if (-not [string]::IsNullOrWhiteSpace($startCell)) {
            $argsList.Add("--start")
            $argsList.Add($startCell)
        }
        foreach ($arg in $defaultExtraArgs) {
            if (-not [string]::IsNullOrWhiteSpace([string]$arg)) {
                $argsList.Add([string]$arg)
            }
        }

        $argumentLine = ($argsList.ToArray() | ForEach-Object { Quote-CommandArg $_ }) -join " "
        $commandLine = "$(Quote-CommandArg $binary) $argumentLine"
        Write-Host ""
        Write-Host "[$($world.id)] $($world.displayName)"
        Write-Host "Start: $startCell"
        Write-Host "Command: $commandLine"

        $status = "not-run"
        $exitCode = $null
        $screenshot = $null
        $windowScreenshot = $null
        $candidateScreenshots = New-Object System.Collections.Generic.List[object]
        $seenNativeScreenshots = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $nativeScreenshotDir = Join-Path $userDataDir "screenshots"
        $profileLog = Join-Path $runConfig.configDirectory "openmw.log"
        $userDataLog = Join-Path $userDataDir "openmw.log"
        $copiedOpenMwLog = Join-Path $logsDir "$($world.id).openmw.log"
        $notes = New-Object System.Collections.Generic.List[string]
        $screenshotQuality = $null
        $logSummary = $null
        $worldViewerTelemetry = $null
        $crashDump = $null

        $anchor = Get-PropertyValue $start "anchor"
        if ($null -ne $anchor) {
            $position = Get-PropertyValue $anchor "position"
            $rotation = Get-PropertyValue $anchor "rotation"
            $camera = Get-PropertyValue $anchor "camera"

            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_POS_X" (Get-PropertyValue $position "x")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_POS_Y" (Get-PropertyValue $position "y")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_POS_Z" (Get-PropertyValue $position "z")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_ROT_X" (Get-PropertyValue $rotation "x")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_ROT_Y" (Get-PropertyValue $rotation "y")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_ROT_Z" (Get-PropertyValue $rotation "z")
            $exteriorLocation = Get-PropertyValue $anchor "exteriorLocation"
            if ($null -ne $exteriorLocation) {
                $grid = Get-PropertyValue $exteriorLocation "grid"
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_WORLDSPACE" (Get-PropertyValue $exteriorLocation "worldspace")
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_GRID_X" (Get-PropertyValue $grid "x")
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_GRID_Y" (Get-PropertyValue $grid "y")
            }
            if ((Get-PropertyValue $anchor "dry") -ne $false) {
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_DRY" "1"
            }
            $usedStartOverride = $false
            $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_POS_X" $StartPosX) -or $usedStartOverride
            $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_POS_Y" $StartPosY) -or $usedStartOverride
            $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_POS_Z" $StartPosZ) -or $usedStartOverride
            $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_ROT_X" $StartRotX) -or $usedStartOverride
            $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_ROT_Y" $StartRotY) -or $usedStartOverride
            $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_ROT_Z" $StartRotZ) -or $usedStartOverride
            $usedStartOverride = (Set-ProcessEnvIntOverride "OPENMW_WORLD_VIEWER_START_GRID_X" $StartGridX) -or $usedStartOverride
            $usedStartOverride = (Set-ProcessEnvIntOverride "OPENMW_WORLD_VIEWER_START_GRID_Y" $StartGridY) -or $usedStartOverride
            if ($usedStartOverride) {
                $notes.Add("used command-line start override")
            }
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_MODE" (Get-PropertyValue $camera "mode")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE" (Get-PropertyValue $camera "distance")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_PITCH" (Get-PropertyValue $camera "pitch")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_YAW" (Get-PropertyValue $camera "yaw")
            $cameraPosition = Get-PropertyValue $camera "position"
            $cameraTarget = Get-PropertyValue $camera "target"
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_POS_X" (Get-PropertyValue $cameraPosition "x")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Y" (Get-PropertyValue $cameraPosition "y")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Z" (Get-PropertyValue $cameraPosition "z")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_X" (Get-PropertyValue $cameraTarget "x")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Y" (Get-PropertyValue $cameraTarget "y")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Z" (Get-PropertyValue $cameraTarget "z")
            $usedCameraOverride = $false
            $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_POS_X" $CameraPosX) -or $usedCameraOverride
            $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Y" $CameraPosY) -or $usedCameraOverride
            $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Z" $CameraPosZ) -or $usedCameraOverride
            $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_X" $CameraTargetX) -or $usedCameraOverride
            $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Y" $CameraTargetY) -or $usedCameraOverride
            $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Z" $CameraTargetZ) -or $usedCameraOverride
            if ($usedCameraOverride) {
                $notes.Add("used command-line camera override")
            }
            if ((Get-PropertyValue $camera "orbitRaycast") -eq $true) {
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_RAYCAST" "1"
            }
            else {
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_RAYCAST" $null
            }
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_SAMPLES" (Get-PropertyValue $camera "orbitSamples")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_RADIUS" (Get-PropertyValue $camera "orbitRadius")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_HEIGHT" (Get-PropertyValue $camera "orbitHeight")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_CLEARANCE" (Get-PropertyValue $camera "orbitClearance")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_MIN_HIT_DISTANCE" (Get-PropertyValue $camera "orbitMinHitDistance")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_MIN_GROUND_HEIGHT" (Get-PropertyValue $camera "orbitMinGroundHeight")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_ORBIT_GROUND_RAY_DISTANCE" (Get-PropertyValue $camera "orbitGroundRayDistance")
            $notes.Add("used explicit local start anchor")
        }

        $usedStartOverride = $false
        $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_POS_X" $StartPosX) -or $usedStartOverride
        $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_POS_Y" $StartPosY) -or $usedStartOverride
        $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_POS_Z" $StartPosZ) -or $usedStartOverride
        $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_ROT_X" $StartRotX) -or $usedStartOverride
        $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_ROT_Y" $StartRotY) -or $usedStartOverride
        $usedStartOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_ROT_Z" $StartRotZ) -or $usedStartOverride
        $usedStartOverride = (Set-ProcessEnvIntOverride "OPENMW_WORLD_VIEWER_START_GRID_X" $StartGridX) -or $usedStartOverride
        $usedStartOverride = (Set-ProcessEnvIntOverride "OPENMW_WORLD_VIEWER_START_GRID_Y" $StartGridY) -or $usedStartOverride
        if ($usedStartOverride) {
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_DRY" "1"
            $notes.Add("used command-line start override")
        }
        $usedCameraOverride = $false
        $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_POS_X" $CameraPosX) -or $usedCameraOverride
        $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Y" $CameraPosY) -or $usedCameraOverride
        $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Z" $CameraPosZ) -or $usedCameraOverride
        $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_X" $CameraTargetX) -or $usedCameraOverride
        $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Y" $CameraTargetY) -or $usedCameraOverride
        $usedCameraOverride = (Set-ProcessEnvFloatOverride "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Z" $CameraTargetZ) -or $usedCameraOverride
        if ($usedCameraOverride) {
            $notes.Add("used command-line camera override")
        }

        if ($processEnvOverrides.Count -gt 0) {
            Set-ProcessEnvOverrides -Overrides $processEnvOverrides
            $notes.Add("applied $($processEnvOverrides.Count) command-line environment override(s)")
        }

        if ($DryRun) {
            $status = "dry-run"
        }
        else {
            $worldStartedAt = Get-Date
            $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $binary) -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
            if (-not $KeepRunning) {
                $captureDelay = 0
                if ($WindowCaptureSeconds -gt 0) {
                    $notes.Add("window capture disabled; native OpenMW screenshot required")
                }

                $deadline = (Get-Date).AddSeconds([Math]::Max(1, $RunSeconds - $captureDelay))
                $sawNativeScreenshot = $false
                $acceptedNativeScreenshot = $false
                while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
                    if (Test-Path -LiteralPath $nativeScreenshotDir) {
                        $shots = @(Get-ChildItem -LiteralPath $nativeScreenshotDir -File -Filter "screenshot*.png" -ErrorAction SilentlyContinue |
                            Where-Object { $_.LastWriteTime -ge $worldStartedAt.AddSeconds(-2) } |
                            Sort-Object LastWriteTime)
                        foreach ($shot in $shots) {
                            if (-not $seenNativeScreenshots.Add($shot.FullName)) {
                                continue
                            }
                            $sawNativeScreenshot = $true
                            Start-Sleep -Milliseconds 750
                            $candidateIndex = $candidateScreenshots.Count + 1
                            $candidatePath = Join-Path $screensDir ("{0}.candidate-{1:000}.png" -f $world.id, $candidateIndex)
                            Copy-Item -LiteralPath $shot.FullName -Destination $candidatePath -Force
                            $candidateQuality = Get-ScreenshotQuality -Path $candidatePath
                            $candidateAccepted = ($null -ne $candidateQuality -and $candidateQuality.acceptable)
                            $candidateScreenshots.Add([pscustomobject][ordered]@{
                                path = (Convert-ToForwardSlash -Path $candidatePath)
                                capturedAt = $shot.LastWriteTime.ToString("o")
                                secondsAfterStart = [Math]::Round(($shot.LastWriteTime - $worldStartedAt).TotalSeconds, 1)
                                quality = $candidateQuality
                                accepted = [bool]$candidateAccepted
                            })
                            if ($candidateAccepted) {
                                $acceptedNativeScreenshot = $true
                                $screenshot = $candidatePath
                                $screenshotQuality = $candidateQuality
                                $notes.Add("accepted native screenshot candidate $candidateIndex after $([Math]::Round(((Get-Date) - $worldStartedAt).TotalSeconds, 1)) seconds")
                                break
                            }
                            elseif ($null -ne $candidateQuality) {
                                $notes.Add("rejected native screenshot candidate ${candidateIndex}: $($candidateQuality.reasons -join '; ')")
                            }
                        }
                        if ($acceptedNativeScreenshot) {
                            break
                        }
                    }
                    Start-Sleep -Milliseconds 500
                    $process.Refresh()
                }

                $process.Refresh()
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force
                    if ($acceptedNativeScreenshot) {
                        $notes.Add("stopped after accepted native screenshot")
                    }
                    elseif ($sawNativeScreenshot) {
                        $notes.Add("stopped after $RunSeconds seconds with only rejected native screenshots")
                    }
                    else {
                        $notes.Add("stopped after $RunSeconds seconds")
                    }
                }
                $process.Refresh()
                $exitCode = $process.ExitCode
            }
            else {
                $notes.Add("left running pid $($process.Id)")
            }

            Start-Sleep -Milliseconds 750
            if (-not $screenshot -and $candidateScreenshots.Count -gt 0) {
                $lastCandidate = $candidateScreenshots[$candidateScreenshots.Count - 1]
                $screenshot = $lastCandidate.path
                $screenshotQuality = $lastCandidate.quality
            }
            if (-not $screenshot) {
                $screenshot = Copy-LatestScreenshot -ScreenshotDir $nativeScreenshotDir -DestinationDir $screensDir -WorldId $world.id
            }
            if ($screenshot) {
                $status = "screenshot"
            }
            elseif ($windowScreenshot) {
                $destination = Join-Path $screensDir "$($world.id).png"
                Copy-Item -LiteralPath $windowScreenshot -Destination $destination -Force
                $screenshot = (Resolve-Path -LiteralPath $destination).Path
                $status = "window-screenshot"
            }
            else {
                $status = "no-screenshot"
                $notes.Add("no screenshot*.png found")
            }

            if (Test-Path -LiteralPath $profileLog) {
                Copy-Item -LiteralPath $profileLog -Destination $copiedOpenMwLog -Force
            }
            elseif (Test-Path -LiteralPath $userDataLog) {
                Copy-Item -LiteralPath $userDataLog -Destination $copiedOpenMwLog -Force
            }
            else {
                $notes.Add("no openmw.log found")
            }

            if ($screenshot -and $null -eq $screenshotQuality) {
                $screenshotQuality = Get-ScreenshotQuality -Path $screenshot
            }
            if ($screenshot) {
                if ($null -ne $screenshotQuality -and -not $screenshotQuality.acceptable -and -not $AllowBadScreenshots) {
                    $status = if ($status -eq "window-screenshot") { "rejected-window-screenshot" } else { "rejected-screenshot" }
                    $notes.Add("rejected screenshot quality: $($screenshotQuality.reasons -join '; ')")
                }
                elseif ($null -ne $screenshotQuality -and -not $screenshotQuality.acceptable -and $AllowBadScreenshots) {
                    $status = if ($status -eq "window-screenshot") { "rejected-window-screenshot" } else { "rejected-screenshot" }
                    $notes.Add("kept rejected screenshot evidence because AllowBadScreenshots was set: $($screenshotQuality.reasons -join '; ')")
                }
            }

            $logSummary = Get-ProofLogSummary -Path $copiedOpenMwLog
            $worldViewerTelemetry = Get-WorldViewerTelemetrySummary -Path $copiedOpenMwLog
            if ($null -ne $logSummary -and $null -ne $logSummary.categories.terrainIssues -and $logSummary.categories.terrainIssues.count -gt 0) {
                $notes.Add("Terrain issues: $($logSummary.categories.terrainIssues.count) logged fallback/lookup events")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.proxyActorRefs -gt 0) {
                $notes.Add("ESM4 actor proxy proof: $($worldViewerTelemetry.proxyActorRefs) proxy refs, $($worldViewerTelemetry.proxyTposeRefs) t-pose, $($worldViewerTelemetry.proxyAnimatedRefs) animated")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.nativeActorLedgerEvents -gt 0) {
                $notes.Add("Native actor ledger: roots $($worldViewerTelemetry.nativeActorRootEnds)/$($worldViewerTelemetry.nativeActorRootBegins), parts $($worldViewerTelemetry.nativeActorPartsAttached)/$($worldViewerTelemetry.nativeActorPartsRequested), missing $($worldViewerTelemetry.nativeActorPartsMissing), quarantined $($worldViewerTelemetry.nativeActorPartsQuarantined), templateErrors $($worldViewerTelemetry.nativeActorTemplateExceptions), animSources $($worldViewerTelemetry.nativeActorAnimSourcesBound)/$($worldViewerTelemetry.nativeActorAnimSources)")
                if ($worldViewerTelemetry.nativeActorModelFallbacks -gt 0) {
                    $notes.Add("Native actor model fallbacks: $($worldViewerTelemetry.nativeActorModelFallbacks)")
                }
                if ($worldViewerTelemetry.nativeActorControllerSources -gt 0) {
                    $notes.Add("Native actor controllers: $($worldViewerTelemetry.nativeActorControllersBound)/$($worldViewerTelemetry.nativeActorControllersTotal) bound across $($worldViewerTelemetry.nativeActorControllerSources) sources, zeroBoundSources $($worldViewerTelemetry.nativeActorControllerZeroSources)")
                }
                if ($worldViewerTelemetry.nativeActorRootExceptions -gt 0) {
                    $notes.Add("Native actor root exceptions: $($worldViewerTelemetry.nativeActorRootExceptions)")
                }
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.meshLedgerEvents -gt 0) {
                $notes.Add("Mesh ledger: template finals $($worldViewerTelemetry.meshTemplateFinalWithGeometry)/$($worldViewerTelemetry.meshTemplateFinalEvents) with geometry, actor templates $($worldViewerTelemetry.actorMeshTemplateWithGeometry)/$($worldViewerTelemetry.actorMeshTemplateEvents), loadFailures $($worldViewerTelemetry.meshLoadFailureEvents)")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.starfieldExternalMeshEvents -gt 0) {
                $notes.Add("Starfield external mesh ledger: loaded $($worldViewerTelemetry.starfieldExternalMeshEvents), uv $($worldViewerTelemetry.starfieldExternalMeshWithUv), normals $($worldViewerTelemetry.starfieldExternalMeshWithNormals), vertices $($worldViewerTelemetry.starfieldExternalMeshVertices), indices $($worldViewerTelemetry.starfieldExternalMeshIndices), failures $($worldViewerTelemetry.starfieldExternalMeshFailures), actorTextureUnits $($worldViewerTelemetry.starfieldActorProofTextureUnits), worldTextureUnits $($worldViewerTelemetry.starfieldWorldProofTextureUnits), worldFallbacks $($worldViewerTelemetry.starfieldWorldMaterialFallbackEvents), worldSkippedGeometry $($worldViewerTelemetry.starfieldWorldSkippedGeometryEvents)")
            }
            if ($null -ne $starfieldTextureCache -and $starfieldTextureCache.count -gt 0) {
                $notes.Add("Starfield texture cache: $($starfieldTextureCache.count) PNGs, opacity masks merged $($starfieldTextureCache.alphaMerged), nonOpaqueAlphaPixels $($starfieldTextureCache.alphaNonOpaquePixels)")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.tes5StaticFaceSurfaceFallbackEvents -gt 0) {
                $notes.Add("TES5 static face surface fallbacks: $($worldViewerTelemetry.tes5StaticFaceSurfaceFallbackEvents)")
            }
            if ($null -ne $worldViewerTelemetry -and ($worldViewerTelemetry.bsGeometryLedgerEvents -gt 0 -or $worldViewerTelemetry.nifGeometryLedgerEvents -gt 0)) {
                $notes.Add("Geometry ledger: NIF vertices $($worldViewerTelemetry.nifGeometryWithVertices)/$($worldViewerTelemetry.nifGeometryLedgerEvents), BS skin partitions $($worldViewerTelemetry.bsGeometryWithPartitionTriangles)/$($worldViewerTelemetry.bsGeometryLedgerEvents), partition fallback attached $($worldViewerTelemetry.bsPartitionFallbackAttached)/$($worldViewerTelemetry.bsPartitionFallbackEvents), BS quarantined $($worldViewerTelemetry.bsGeometryQuarantineEvents), generatedNormals $($worldViewerTelemetry.bsPartitionFallbackGeneratedNormals)")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.textureLedgerEvents -gt 0) {
                $notes.Add("Texture ledger: resolved $($worldViewerTelemetry.textureImagesResolved), missing $($worldViewerTelemetry.textureImagesMissing), skinAuxSkipped $($worldViewerTelemetry.textureSkinAuxSkipped)")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.materialLedgerEvents -gt 0) {
                $notes.Add("Material ledger: textureUnits $($worldViewerTelemetry.materialWithTextureUnits)/$($worldViewerTelemetry.materialLedgerEvents), shaderRequired $($worldViewerTelemetry.materialShaderRequired), colorModeOff $($worldViewerTelemetry.materialColorModeOff), alphaSort $($worldViewerTelemetry.materialWithAlphaSort)")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.proofActorBoundsValid -gt 0 -and $null -ne $worldViewerTelemetry.latestProofActorBounds) {
                $bounds = $worldViewerTelemetry.latestProofActorBounds
                $centerText = if ($null -ne (Get-PropertyValue $bounds "center")) { [string](Get-PropertyValue $bounds "center") } elseif ($null -ne (Get-PropertyValue $bounds "focus")) { "focus $([string](Get-PropertyValue $bounds "focus"))" } else { "<unknown>" }
                $bottomText = if ($null -ne (Get-PropertyValue $bounds "bottomDelta")) { ", bottomDelta $([string](Get-PropertyValue $bounds "bottomDelta"))" } else { "" }
                $notes.Add("Proof actor bounds: size $($bounds.size), center $centerText$bottomText")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.proofGroundSnapEvents -gt 0) {
                $notes.Add("Proof render-ground snap: hits $($worldViewerTelemetry.proofGroundSnapHits), misses $($worldViewerTelemetry.proofGroundSnapMisses), failures $($worldViewerTelemetry.proofGroundSnapFailures)")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.proofActorCameraRaycastEvents -gt 0) {
                $notes.Add("Proof actor camera raycast: adjusted $($worldViewerTelemetry.proofActorCameraRaycastAdjusted), clear $($worldViewerTelemetry.proofActorCameraRaycastClear), tooClose $($worldViewerTelemetry.proofActorCameraRaycastTooClose)")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.proofActorOrbitCandidateEvents -gt 0) {
                $selectedText = ""
                if ($null -ne $worldViewerTelemetry.latestProofActorOrbitSelection) {
                    $selection = $worldViewerTelemetry.latestProofActorOrbitSelection
                    $selectionPhase = Get-PropertyValue $selection "phase"
                    $selectionAngle = Get-PropertyValue $selection "angle"
                    $selectionBlockers = Get-PropertyValue $selection "blockers"
                    $angleText = if ($null -ne $selectionAngle) { " angle $selectionAngle" } else { "" }
                    $blockerText = if ($null -ne $selectionBlockers) { " blockers $selectionBlockers" } else { "" }
                    $selectedText = ", latest $selectionPhase$angleText$blockerText"
                }
                $notes.Add("Proof actor orbit raycast: candidates $($worldViewerTelemetry.proofActorOrbitCandidateEvents), clear $($worldViewerTelemetry.proofActorOrbitCandidateClear), selected $($worldViewerTelemetry.proofActorOrbitSelectedEvents), kept $($worldViewerTelemetry.proofActorOrbitKeptEvents)$selectedText")
            }
            $crashDump = Get-OpenMwCrashDumpInfo -Roots @($runConfig.configDirectory, $userDataDir) -Since $worldStartedAt.AddSeconds(-2)
            if ($null -ne $crashDump) {
                $notes.Add("crash dump detected: $($crashDump.path)")
                if ($status -eq "no-screenshot") {
                    $status = "crash-dump-no-screenshot"
                }
            }

            if ($screenshot -and -not $NoTelemetry -and -not $AllowBadScreenshots -and ($status -eq "screenshot" -or $status -eq "window-screenshot")) {
                $telemetryRejectReasons = New-Object System.Collections.Generic.List[string]
                if ($null -eq $worldViewerTelemetry -or $null -eq $worldViewerTelemetry.latestTelemetry) {
                    $telemetryRejectReasons.Add("missing world viewer frame telemetry")
                }
                else {
                    if ($worldViewerTelemetry.cellRendered -le 0 -and $worldViewerTelemetry.loggedRenderedRefs -le 0) {
                        $telemetryRejectReasons.Add("telemetry found no rendered refs")
                    }
                    if ($worldViewerTelemetry.groundRayHits -le 0 -and $worldViewerTelemetry.proofGroundSnapHits -le 0) {
                        $telemetryRejectReasons.Add("ground ray did not hit world/heightmap/water and proof render-ground snap did not hit")
                    }
                    if ($worldViewerTelemetry.centerRenderHits -le 0) {
                        $telemetryRejectReasons.Add("center render ray hit nothing")
                    }
                    if ($worldViewerTelemetry.cellActors -gt 0 -and $worldViewerTelemetry.cellRenderedActors -le 0 -and -not $disableEsm4Actors) {
                        $telemetryRejectReasons.Add("actor-populated cell rendered zero actor nodes")
                    }
                    elseif ($worldViewerTelemetry.cellActors -gt 0 -and $worldViewerTelemetry.cellRenderedActors -le 0 -and $disableEsm4Actors) {
                        $notes.Add("ESM4 actor render probes skipped by world config quarantine")
                    }
                    if ($worldViewerTelemetry.cellRenderedActors -gt 0 -and $worldViewerTelemetry.actorRayActorHits -le 0 -and ($esm4ActorProxies -or $worldViewerTelemetry.nativeActorPartsAttached -gt 0)) {
                        $notes.Add("Actor render nodes exist; actor physics ray probes are diagnostic until actor collision is stabilized")
                    }
                    elseif ($worldViewerTelemetry.cellRenderedActors -gt 0 -and $worldViewerTelemetry.actorRayActorHits -le 0) {
                        $telemetryRejectReasons.Add("rendered actor nodes present but actor ray probes hit no actors")
                    }
                    if ($worldViewerTelemetry.nativeActorPartsAttached -gt 0 -and $worldViewerTelemetry.bsPartitionFallbackEvents -gt 0 -and $worldViewerTelemetry.bsPartitionFallbackAttached -le 0) {
                        $telemetryRejectReasons.Add("actor BS skin partitions were found but none attached geometry")
                    }
                    if ($worldViewerTelemetry.actorMeshTemplateEvents -gt 0 -and $worldViewerTelemetry.actorMeshTemplateWithGeometry -le 0) {
                        $telemetryRejectReasons.Add("actor mesh templates loaded with zero geometry")
                    }
                    if ($worldViewerTelemetry.materialLedgerEvents -gt 0 -and $worldViewerTelemetry.materialWithTextureUnits -le 0) {
                        $telemetryRejectReasons.Add("actor material ledger found zero bound texture units")
                    }
                }

                if ($telemetryRejectReasons.Count -gt 0) {
                    $status = "rejected-telemetry-screenshot"
                    $notes.Add("rejected screenshot telemetry: $($telemetryRejectReasons -join '; ')")
                }
            }
        }

        $results.Add([pscustomobject][ordered]@{
            worldId = $world.id
            displayName = $world.displayName
            supportTier = $world.supportTier
            startCell = $startCell
            label = $label
            status = $status
            exitCode = $exitCode
            screenshot = if ($screenshot) { (Convert-ToForwardSlash -Path $screenshot) } else { $null }
            screenshotQuality = $screenshotQuality
            candidateScreenshots = @($candidateScreenshots.ToArray())
            windowScreenshot = if ($windowScreenshot) { (Convert-ToForwardSlash -Path $windowScreenshot) } else { $null }
            runDirectory = (Convert-ToForwardSlash -Path $worldRunDir)
            configDirectory = (Convert-ToForwardSlash -Path $runConfig.configDirectory)
            dataLocalDirectory = (Convert-ToForwardSlash -Path $runConfig.dataLocalDirectory)
            openmwLog = (Convert-ToForwardSlash -Path $copiedOpenMwLog)
            openmwLogSummary = $logSummary
            worldViewerTelemetry = $worldViewerTelemetry
            starfieldTextureCache = $starfieldTextureCache
            crashDump = $crashDump
            esm4GridRadius = $worldGridRadius
            processLog = (Convert-ToForwardSlash -Path $stdoutLog)
            processErrorLog = (Convert-ToForwardSlash -Path $stderrLog)
            command = $commandLine
            notes = @($notes)
        })
    }
}
finally {
    foreach ($entry in $previousEnv.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}

$manifest = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    binary = (Convert-ToForwardSlash -Path $binary)
    runSeconds = $RunSeconds
    screenshotFrames = $ScreenshotFrames
    windowCaptureSeconds = $WindowCaptureSeconds
    telemetry = (-not $NoTelemetry)
    telemetryInterval = $TelemetryInterval
    esm4GridRadius = $Esm4GridRadius
    focusActor = $FocusActor
    setEnv = @($processEnvOverrides | ForEach-Object { "{0}={1}" -f $_.name, $_.value })
    allowBadScreenshots = [bool]$AllowBadScreenshots
    showGui = [bool]$ShowGui
    proofDirectory = (Convert-ToForwardSlash -Path $absProofDir)
    results = @($results.ToArray())
}

$manifestPath = Join-Path $absProofDir "manifest.json"
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding ASCII

if (-not [string]::IsNullOrWhiteSpace($RunLedgerPath)) {
    $ledgerPath = $RunLedgerPath
    if (-not [System.IO.Path]::IsPathRooted($ledgerPath)) {
        $ledgerPath = Join-Path (Get-Location) $ledgerPath
    }
    $ledgerPath = [System.IO.Path]::GetFullPath($ledgerPath)
    $ledgerDir = Split-Path -Parent $ledgerPath
    if (-not [string]::IsNullOrWhiteSpace($ledgerDir)) {
        New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null
    }

    $ledgerResults = @($results.ToArray() | ForEach-Object {
        $quality = Get-PropertyValue $_ "screenshotQuality"
        $telemetrySummary = Get-PropertyValue $_ "worldViewerTelemetry"
        $textureCache = Get-PropertyValue $_ "starfieldTextureCache"
        [ordered]@{
            worldId = $_.worldId
            status = $_.status
            startCell = $_.startCell
            focusActor = $FocusActor
            screenshot = $_.screenshot
            acceptable = if ($null -ne $quality) { [bool]$quality.acceptable } else { $null }
            quality = if ($null -ne $quality) {
                [ordered]@{
                    meanBrightness = $quality.meanBrightness
                    brightnessStdDev = $quality.brightnessStdDev
                    worldSignalRatio = $quality.worldSignalRatio
                    brightLowSaturationRatio = $quality.brightLowSaturationRatio
                    skyOrVoidRatio = $quality.skyOrVoidRatio
                    lowSaturationMidRatio = $quality.lowSaturationMidRatio
                    colorSignalRatio = $quality.colorSignalRatio
                    magentaRatio = $quality.magentaRatio
                    purpleRatio = $quality.purpleRatio
                    reasons = @($quality.reasons)
                }
            } else { $null }
            candidateCount = @($_.candidateScreenshots).Count
            telemetry = if ($null -ne $telemetrySummary) {
                [ordered]@{
                    textureImagesResolved = $telemetrySummary.textureImagesResolved
                    textureImagesMissing = $telemetrySummary.textureImagesMissing
                    materialWithTextureUnits = $telemetrySummary.materialWithTextureUnits
                    materialLedgerEvents = $telemetrySummary.materialLedgerEvents
                    nativeActorPartsAttached = $telemetrySummary.nativeActorPartsAttached
                    nativeActorPartsRequested = $telemetrySummary.nativeActorPartsRequested
                    starfieldActorProofTextureUnits = $telemetrySummary.starfieldActorProofTextureUnits
                    starfieldWorldProofTextureUnits = $telemetrySummary.starfieldWorldProofTextureUnits
                    starfieldWorldMaterialFallbackEvents = $telemetrySummary.starfieldWorldMaterialFallbackEvents
                    starfieldWorldSkippedGeometryEvents = $telemetrySummary.starfieldWorldSkippedGeometryEvents
                    latestProofActorBounds = $telemetrySummary.latestProofActorBounds
                    latestProofActorOrbitSelection = $telemetrySummary.latestProofActorOrbitSelection
                }
            } else { $null }
            starfieldTextureCache = if ($null -ne $textureCache) {
                [ordered]@{
                    count = $textureCache.count
                    alphaMerged = $textureCache.alphaMerged
                    alphaNonOpaquePixels = $textureCache.alphaNonOpaquePixels
                }
            } else { $null }
            notes = @($_.notes)
        }
    })

    $ledgerEntry = [ordered]@{
        schemaVersion = 1
        generatedAt = $manifest.generatedAt
        manifest = (Convert-ToForwardSlash -Path $manifestPath)
        binary = $manifest.binary
        runSeconds = $RunSeconds
        screenshotFrames = $ScreenshotFrames
        telemetryInterval = $TelemetryInterval
        esm4GridRadius = $Esm4GridRadius
        setEnv = $manifest.setEnv
        flags = [ordered]@{
            preserveNativeMaterials = (-not $FullbrightNativeMaterials -and -not $FullbrightActorMaterialsOnly)
            legacyPreserveNativeMaterialsFlag = [bool]$PreserveNativeMaterials
            fullbrightNativeMaterials = [bool]$FullbrightNativeMaterials
            fullbrightActorMaterialsOnly = [bool]$FullbrightActorMaterialsOnly
            allowBadScreenshots = [bool]$AllowBadScreenshots
            showGui = [bool]$ShowGui
            keepRunning = [bool]$KeepRunning
        }
        results = $ledgerResults
    }
    ($ledgerEntry | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $ledgerPath -Encoding ASCII
}

Write-Host ""
$results | Format-Table -AutoSize worldId, status, startCell, screenshot
Write-Host "Manifest: $manifestPath"
