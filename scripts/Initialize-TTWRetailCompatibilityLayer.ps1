[CmdletBinding()]
param(
    [string]$LayerRoot = 'D:\code\nikami-worlds\local\ttw-retail-compat',
    [string]$TtwNvseArchive = 'D:\code\nikami-worlds\local\ttw-retail-compat\source\ROOGNVSE-77415-3-3-3b-1736213734.7z',
    [string]$JipPlugin = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\NVSE\Plugins\jip_nvse.dll',
    [string]$SevenZip = 'C:\Program Files\7-Zip\7z.exe',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing compatibility-layer input: $Path"
    }
    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $file.FullName
        bytes = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Install-LayerFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$AllowReplace
    )

    $sourceArtifact = Get-Artifact $Source
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $destinationArtifact = Get-Artifact $Destination
        if ($destinationArtifact.sha256 -eq $sourceArtifact.sha256) {
            return $destinationArtifact
        }
        if (-not $AllowReplace) {
            throw "Compatibility-layer destination already exists with different contents: $Destination"
        }
    }
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force:$AllowReplace
    return Get-Artifact $Destination
}

$LayerRoot = [IO.Path]::GetFullPath($LayerRoot)
$TtwNvseArchive = [IO.Path]::GetFullPath($TtwNvseArchive)
$JipPlugin = [IO.Path]::GetFullPath($JipPlugin)
$SevenZip = [IO.Path]::GetFullPath($SevenZip)
foreach ($required in @($TtwNvseArchive, $JipPlugin, $SevenZip)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing compatibility-layer input: $required"
    }
}

$pluginsRoot = Join-Path $LayerRoot 'plugins'
$extractRoot = Join-Path $LayerRoot ('extract-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $LayerRoot, $extractRoot -Force | Out-Null

& $SevenZip x $TtwNvseArchive '-y' ("-o$extractRoot") 'nvse\plugins\ttw_nvse.dll' 'nvse\plugins\TTW.ini' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "7-Zip could not extract TTW NVSE from $TtwNvseArchive"
}

$ttwDllSource = Join-Path $extractRoot 'nvse\plugins\ttw_nvse.dll'
$ttwIniSource = Join-Path $extractRoot 'nvse\plugins\TTW.ini'
foreach ($required in @($ttwDllSource, $ttwIniSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "The TTW NVSE archive did not contain its expected file: $required"
    }
}

$jipArtifact = Install-LayerFile -Source $JipPlugin -Destination (Join-Path $pluginsRoot 'jip_nvse.dll') -AllowReplace:$Force
$ttwArtifact = Install-LayerFile -Source $ttwDllSource -Destination (Join-Path $pluginsRoot 'ttw_nvse.dll') -AllowReplace:$Force
$ttwIniArtifact = Install-LayerFile -Source $ttwIniSource -Destination (Join-Path $pluginsRoot 'TTW.ini') -AllowReplace:$Force

$manifestPath = Join-Path $LayerRoot 'compatibility-layer.json'
$manifest = [ordered]@{
    schema = 'opennv-ttw-retail-compat-layer/v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    sourceAssetsUnmodified = $true
    capabilities = @('ttw-fresh-opening', 'retail-nvse-isolated')
    inputs = [ordered]@{
        ttwNvseArchive = Get-Artifact $TtwNvseArchive
        jipPlugin = Get-Artifact $JipPlugin
    }
    plugins = @(
        [ordered]@{
            id = 'jip-ln-nvse'
            loadOrder = 10
            path = 'plugins/jip_nvse.dll'
            sha256 = $jipArtifact.sha256
            source = $JipPlugin
        },
        [ordered]@{
            id = 'ttw-nvse'
            loadOrder = 20
            path = 'plugins/ttw_nvse.dll'
            sha256 = $ttwArtifact.sha256
            source = $TtwNvseArchive
        }
    )
    supportFiles = @(
        [ordered]@{
            path = 'plugins/TTW.ini'
            sha256 = $ttwIniArtifact.sha256
            source = $TtwNvseArchive
        }
    )
}
[IO.File]::WriteAllText(
    $manifestPath,
    (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))

[ordered]@{
    status = 'pass'
    layerRoot = $LayerRoot
    manifest = Get-Artifact $manifestPath
    plugins = @($jipArtifact, $ttwArtifact)
    supportFiles = @($ttwIniArtifact)
    transientExtraction = $extractRoot
}
