[CmdletBinding()]
param(
    [string]$EngineRoot = "D:/code/nikami-openmw-pristine-mads",
    [string]$BaselineCommit = "2ed153af06",
    [string]$RuntimeRoot = "local/openmw-pristine-mads-33568a",
    [string]$KnownWorkingSettings = "D:/Modlists/fnv/openmw-config/flat-ui-proof/20260611_232015/settings.cfg",
    [string]$OutputPath = "catalog/fnv-renderer-boundary-manifest.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-PathFromRepo([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-TextSha256([string[]]$Rows) {
    $text = ($Rows -join "`n") + "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("X2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-Git([string[]]$Arguments) {
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & git -C $script:engine @Arguments 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Get-TreeEntries([string]$Root) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return @(Get-ChildItem -LiteralPath $rootPath -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
        [ordered]@{
            path = $relative
            bytes = $_.Length
            sha256 = Get-Sha256 $_.FullName
        }
    })
}

function Get-EntryDigest([object[]]$Entries) {
    return Get-TextSha256 @($Entries | ForEach-Object { "$($_.path)`t$($_.bytes)`t$($_.sha256)" })
}

$engine = [IO.Path]::GetFullPath($EngineRoot)
$runtime = Resolve-PathFromRepo $RuntimeRoot
$knownSettings = [IO.Path]::GetFullPath($KnownWorkingSettings)
$output = Resolve-PathFromRepo $OutputPath
$sourceSettings = Join-Path $repoRoot "config/fnv-playable-graphics/settings.cfg"
$sourcePreset = Join-Path $repoRoot "catalog/world-settings-presets.json"
$generatedSettings = Join-Path $repoRoot "run/fnv-pristine-mads-profile/33568a/settings.cfg"
$generatedManifest = Join-Path $repoRoot "run/fnv-pristine-mads-profile/33568a/manifest.json"

foreach ($required in @(
        (Join-Path $engine ".git"),
        (Join-Path $engine "files/shaders"),
        (Join-Path $runtime "resources/shaders"),
        (Join-Path $runtime "openmw.exe"),
        (Join-Path $runtime "openmw_vr.exe"),
        $knownSettings,
        $sourceSettings,
        $sourcePreset
    )) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing renderer-boundary input: $required"
    }
}

$baselineResult = @(Invoke-Git @("rev-parse", "$BaselineCommit^{commit}"))
$headResult = @(Invoke-Git @("rev-parse", "HEAD^{commit}"))
$baseline = $baselineResult[0].Trim()
$head = $headResult[0].Trim()
$boundaryRoots = @(
    "apps/openmw/mwrender",
    "apps/openmw/mwvr",
    "components/myguiplatform",
    "components/nif",
    "components/nifosg",
    "components/resource",
    "components/sceneutil",
    "components/shader",
    "components/stereo",
    "components/vr",
    "files/shaders"
)
$changedBoundaryPaths = @(Invoke-Git (@("diff", "--name-only", $baseline, "--") + $boundaryRoots) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Replace('\', '/') } |
    Sort-Object -Unique)
$expectedBoundaryPaths = @("components/myguiplatform/myguirendermanager.cpp")

$baselineEntries = @(Invoke-Git (@("ls-tree", "-r", "--full-tree", $baseline, "--") + $boundaryRoots) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object)
$currentFiles = @(Invoke-Git (@("ls-files", "--") + $boundaryRoots) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique)
$currentEntries = foreach ($file in $currentFiles) {
    $blobResult = @(Invoke-Git @("hash-object", "--", $file))
    $blob = $blobResult[0].Trim()
    "100644 blob $blob`t$($file.Replace('\', '/'))"
}

$guiPath = Join-Path $engine "components/myguiplatform/myguirendermanager.cpp"
$guiSource = Get-Content -LiteralPath $guiPath -Raw
$guiCorrectionPass = $guiSource.Contains('"gui.vert"') -and $guiSource.Contains('"gui.frag"') -and
    -not $guiSource.Contains('"gui_vertex.glsl"') -and -not $guiSource.Contains('"gui_fragment.glsl"')

$sourceShaderRoot = Join-Path $engine "files/shaders"
$deployedShaderRoot = Join-Path $runtime "resources/shaders"
$sourceShaders = @(Get-TreeEntries $sourceShaderRoot | Where-Object { $_.path -ne "CMakeLists.txt" })
$deployedShaders = @(Get-TreeEntries $deployedShaderRoot)
$sourceByPath = @{}
foreach ($entry in $sourceShaders) { $sourceByPath[[string]$entry.path] = $entry }
$deployedByPath = @{}
foreach ($entry in $deployedShaders) { $deployedByPath[[string]$entry.path] = $entry }
$shaderPaths = @($sourceByPath.Keys + $deployedByPath.Keys | Sort-Object -Unique)
$shaderMismatches = @($shaderPaths | ForEach-Object {
    $path = [string]$_
    if (-not $sourceByPath.ContainsKey($path)) {
        [ordered]@{ path = $path; reason = "deployed-only" }
    }
    elseif (-not $deployedByPath.ContainsKey($path)) {
        [ordered]@{ path = $path; reason = "source-only" }
    }
    elseif ([string]$sourceByPath[$path].sha256 -cne [string]$deployedByPath[$path].sha256) {
        [ordered]@{
            path = $path
            reason = "hash-mismatch"
            sourceSha256 = $sourceByPath[$path].sha256
            deployedSha256 = $deployedByPath[$path].sha256
        }
    }
})

$settingsText = Get-Content -LiteralPath $sourceSettings -Raw
$safeSettings = [ordered]@{
    viewingDistance10000 = $settingsText -match '(?m)^viewing distance = 10000$'
    unsupportedNifFiles = $settingsText -match '(?m)^load unsupported nif files = true$'
    distantTerrainDisabled = $settingsText -match '(?m)^distant terrain = false$'
    objectPagingDisabled = $settingsText -match '(?m)^object paging = false$'
    activeGridPagingDisabled = $settingsText -match '(?m)^object paging active grid = false$'
    forcedShadersDisabled = $settingsText -match '(?m)^force shaders = false$'
    environmentMapLightingDisabled = $settingsText -match '(?m)^apply lighting to environment maps = false$'
    shadowsDisabled = $settingsText -match '(?m)^enable shadows = false$'
    skyModelOverridesAbsent = -not ($settingsText -match '(?im)^(skyatmosphere|skyclouds|skynight01|skynight02)\s*=')
}
$safeSettingsPass = @($safeSettings.Values | Where-Object { -not $_ }).Count -eq 0

$knownSettingsHash = Get-Sha256 $knownSettings
$knownSettingsPass = (Get-Item -LiteralPath $knownSettings).Length -eq 174 -and
    $knownSettingsHash -ceq "670F5DC9FDF3EDC199EF4BCD6190BBE5D3DE1090F2C5CE466590E2582F8C582A"
$boundaryDeltaPass = ($changedBoundaryPaths -join "`n") -ceq ($expectedBoundaryPaths -join "`n")
$shaderPass = $sourceShaders.Count -eq 62 -and $deployedShaders.Count -eq 62 -and $shaderMismatches.Count -eq 0

$generatedProfile = [ordered]@{
    settingsPath = $generatedSettings.Replace('\', '/')
    settingsPresent = Test-Path -LiteralPath $generatedSettings -PathType Leaf
    settingsSha256 = if (Test-Path -LiteralPath $generatedSettings -PathType Leaf) { Get-Sha256 $generatedSettings } else { $null }
    existingManifestPath = $generatedManifest.Replace('\', '/')
    manifestPresent = Test-Path -LiteralPath $generatedManifest -PathType Leaf
    manifestFresh = $false
    acceptanceEligible = $false
    reason = "The ignored profile settings were safety-patched after its existing manifest was written; regenerate a new profile after a committed engine build."
}

$pass = $boundaryDeltaPass -and $guiCorrectionPass -and $shaderPass -and $safeSettingsPass -and $knownSettingsPass
$guiCurrentBlobResult = @(Invoke-Git @("hash-object", "--", "components/myguiplatform/myguirendermanager.cpp"))
$guiBaselineBlobResult = @(Invoke-Git @("rev-parse", "$baseline`:components/myguiplatform/myguirendermanager.cpp"))

$manifest = [ordered]@{
    schema = "nikami-fnv-renderer-boundary-manifest/v1"
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    pass = $pass
    acceptanceEligible = $false
    acceptanceNote = "Offline byte accounting only. Visual acceptance requires an explicitly authorized normal Save330 run."
    engine = [ordered]@{
        root = $engine.Replace('\', '/')
        baselineCommit = $baseline
        headCommit = $head
        boundaryRoots = $boundaryRoots
        changedBoundaryPaths = $changedBoundaryPaths
        expectedBoundaryPaths = $expectedBoundaryPaths
        boundaryDeltaPass = $boundaryDeltaPass
        baselineEntryCount = $baselineEntries.Count
        baselineEntriesSha256 = Get-TextSha256 $baselineEntries
        currentEntryCount = $currentEntries.Count
        currentEntriesSha256 = Get-TextSha256 $currentEntries
        guiFilenameCorrectionPass = $guiCorrectionPass
        guiCurrentBlob = $guiCurrentBlobResult[0].Trim()
        guiBaselineBlob = $guiBaselineBlobResult[0].Trim()
    }
    deployedRuntime = [ordered]@{
        root = $runtime.Replace('\', '/')
        flatBinarySha256 = Get-Sha256 (Join-Path $runtime "openmw.exe")
        vrBinarySha256 = Get-Sha256 (Join-Path $runtime "openmw_vr.exe")
        sourceProvenanceComplete = $false
        acceptanceEligible = $false
    }
    shaders = [ordered]@{
        pass = $shaderPass
        sourceRoot = $sourceShaderRoot.Replace('\', '/')
        deployedRoot = $deployedShaderRoot.Replace('\', '/')
        sourceCount = $sourceShaders.Count
        deployedCount = $deployedShaders.Count
        sourceTreeSha256 = Get-EntryDigest $sourceShaders
        deployedTreeSha256 = Get-EntryDigest $deployedShaders
        mismatches = $shaderMismatches
    }
    settings = [ordered]@{
        pass = $safeSettingsPass
        sourcePath = $sourceSettings.Replace('\', '/')
        sourceSha256 = Get-Sha256 $sourceSettings
        presetPath = $sourcePreset.Replace('\', '/')
        presetSha256 = Get-Sha256 $sourcePreset
        invariants = $safeSettings
        knownWorkingReference = [ordered]@{
            path = $knownSettings.Replace('\', '/')
            bytes = (Get-Item -LiteralPath $knownSettings).Length
            sha256 = $knownSettingsHash
            expectedSha256 = "670F5DC9FDF3EDC199EF4BCD6190BBE5D3DE1090F2C5CE466590E2582F8C582A"
            pass = $knownSettingsPass
        }
        generatedProfile = $generatedProfile
    }
}

$parent = Split-Path -Parent $output
if (-not (Test-Path -LiteralPath $parent)) {
    [IO.Directory]::CreateDirectory($parent) | Out-Null
}
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $output -Encoding utf8
Write-Output $output
if (-not $pass) {
    exit 1
}
