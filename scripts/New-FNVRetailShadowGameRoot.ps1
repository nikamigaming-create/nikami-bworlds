[CmdletBinding()]
param(
    [ValidateSet('Build', 'VerifyProcess')]
    [string]$Mode = 'Build',
    [string]$SourceGameRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas',
    [Parameter(Mandatory = $true)]
    [string]$ShadowRoot,
    [string]$ExternalRuntimeRoot = '',
    [int]$TargetProcessId = 0,
    [string]$ManifestPath = '',
    [string]$VerificationPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Artifact([string]$Kind, [string]$SourcePath, [string]$ShadowPath) {
    $source = Get-Item -LiteralPath $SourcePath
    $shadow = Get-Item -LiteralPath $ShadowPath
    [pscustomobject][ordered]@{
        kind = $Kind
        sourcePath = $source.FullName
        sourceBytes = $source.Length
        sourceSha256 = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash
        shadowPath = $shadow.FullName
        shadowBytes = $shadow.Length
        shadowSha256 = (Get-FileHash -LiteralPath $shadow.FullName -Algorithm SHA256).Hash
    }
}

function Test-ProhibitedName([string]$Name) {
    $leaf = [IO.Path]::GetFileName($Name)
    $leaf -match '(?i)fnvxr|openxr|openvr|reshade' -or
        $leaf -match '(?i)^xinput.*\.dll$' -or
        $leaf -match '(?i)^(d3d9|dinput8|dxgi)\.dll$'
}

$sourceRoot = [IO.Path]::GetFullPath($SourceGameRoot)
$shadowRootPath = [IO.Path]::GetFullPath($ShadowRoot)
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = "$shadowRootPath.shadow-manifest.json"
}
$manifestPathValue = [IO.Path]::GetFullPath($ManifestPath)

$requiredRootFiles = @(
    'FalloutNV.exe',
    'atimgpud.dll',
    'binkw32.dll',
    'Fallout_default.ini',
    'GDFFalloutNV.dll',
    'libvorbis.dll',
    'libvorbisfile.dll',
    'steam_api.dll'
)
$requiredDataFiles = @(
    'CaravanPack - Main.bsa', 'CaravanPack.esm', 'CaravanPack.nam',
    'ClassicPack - Main.bsa', 'ClassicPack.esm', 'ClassicPack.nam',
    'DeadMoney - Main.bsa', 'DeadMoney - Sounds.bsa', 'DeadMoney.esm', 'DEADMONEY.NAM',
    'Fallout - Meshes.bsa', 'Fallout - Misc.bsa', 'Fallout - Sound.bsa',
    'Fallout - Textures.bsa', 'Fallout - Textures2.bsa', 'Fallout - Voices1.bsa',
    'FalloutNV.esm',
    'GunRunnersArsenal - Main.bsa', 'GunRunnersArsenal - Sounds.bsa',
    'GunRunnersArsenal.esm', 'GUNRUNNERSARSENAL.NAM',
    'HonestHearts - Main.bsa', 'HonestHearts - Sounds.bsa', 'HonestHearts.esm', 'HONESTHEARTS.NAM',
    'LonesomeRoad - Main.bsa', 'LonesomeRoad - Sounds.bsa', 'LonesomeRoad.esm', 'LONESOMEROAD.NAM',
    'MercenaryPack - Main.bsa', 'MercenaryPack.esm', 'MercenaryPack.nam',
    'OldWorldBlues - Main.bsa', 'OldWorldBlues - Sounds.bsa', 'OldWorldBlues.esm', 'OLDWORLDBLUES.NAM',
    'TribalPack - Main.bsa', 'TribalPack.esm', 'TribalPack.nam',
    'Update.bsa'
)
$requiredDataDirectories = @('Shaders', 'Video')

if ($Mode -eq 'Build') {
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Retail source GameRoot is missing: $sourceRoot"
    }
    if (Test-Path -LiteralPath $shadowRootPath) {
        throw "Refusing to overwrite retail shadow GameRoot: $shadowRootPath"
    }
    if (Test-Path -LiteralPath $manifestPathValue) {
        throw "Refusing to overwrite retail shadow manifest: $manifestPathValue"
    }

    foreach ($relativePath in $requiredRootFiles) {
        $sourcePath = Join-Path $sourceRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required retail root file is missing: $sourcePath"
        }
    }
    foreach ($relativePath in $requiredDataFiles) {
        $sourcePath = Join-Path (Join-Path $sourceRoot 'Data') $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Required retail Data file is missing: $sourcePath"
        }
    }
    foreach ($relativePath in $requiredDataDirectories) {
        $sourcePath = Join-Path (Join-Path $sourceRoot 'Data') $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
            throw "Required retail Data directory is missing: $sourcePath"
        }
    }

    $sourceHooks = @(Get-ChildItem -LiteralPath $sourceRoot -File | Where-Object { Test-ProhibitedName $_.Name })
    $sourceVrPlugins = @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'Data') -Recurse -File |
        Where-Object { Test-ProhibitedName $_.Name })

    New-Item -ItemType Directory -Path $shadowRootPath | Out-Null
    $shadowData = New-Item -ItemType Directory -Path (Join-Path $shadowRootPath 'Data')
    New-Item -ItemType Directory -Path (Join-Path $shadowData.FullName 'NVSE\Plugins') | Out-Null

    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($relativePath in $requiredRootFiles) {
        $sourcePath = Join-Path $sourceRoot $relativePath
        $shadowPath = Join-Path $shadowRootPath $relativePath
        Copy-Item -LiteralPath $sourcePath -Destination $shadowPath
        $artifacts.Add((Get-Artifact -Kind 'copied-retail-root' -SourcePath $sourcePath -ShadowPath $shadowPath))
    }
    foreach ($relativePath in $requiredDataFiles) {
        $sourcePath = Join-Path (Join-Path $sourceRoot 'Data') $relativePath
        $shadowPath = Join-Path $shadowData.FullName $relativePath
        New-Item -ItemType HardLink -Path $shadowPath -Target $sourcePath | Out-Null
        $artifacts.Add((Get-Artifact -Kind 'hardlinked-retail-data' -SourcePath $sourcePath -ShadowPath $shadowPath))
    }
    $directoryLinks = [Collections.Generic.List[object]]::new()
    foreach ($relativePath in $requiredDataDirectories) {
        $sourcePath = Join-Path (Join-Path $sourceRoot 'Data') $relativePath
        $shadowPath = Join-Path $shadowData.FullName $relativePath
        $link = New-Item -ItemType Junction -Path $shadowPath -Target $sourcePath
        $directoryLinks.Add([pscustomobject][ordered]@{
            kind = 'junction-retail-data'
            sourcePath = [IO.Path]::GetFullPath($sourcePath)
            shadowPath = $link.FullName
        })
    }

    $allowedRootSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $requiredRootFiles) { [void]$allowedRootSet.Add($name) }
    $unexpectedRootFiles = @(Get-ChildItem -LiteralPath $shadowRootPath -File |
        Where-Object { -not $allowedRootSet.Contains($_.Name) })
    $shadowPlugins = @(Get-ChildItem -LiteralPath (Join-Path $shadowData.FullName 'NVSE\Plugins') -File)
    $shadowProhibited = @(
        Get-ChildItem -LiteralPath $shadowRootPath -File | Where-Object { Test-ProhibitedName $_.Name }
        Get-ChildItem -LiteralPath $shadowData.FullName -File | Where-Object {
            Test-ProhibitedName $_.Name -or $_.Extension -ieq '.esp'
        }
        $shadowPlugins | Where-Object { $_.Extension -ieq '.dll' }
    )
    $exeArtifact = @($artifacts | Where-Object { [IO.Path]::GetFileName($_.shadowPath) -ieq 'FalloutNV.exe' })[0]
    $passed = $unexpectedRootFiles.Count -eq 0 -and $shadowPlugins.Count -eq 0 -and
        $shadowProhibited.Count -eq 0 -and
        $exeArtifact.sourceSha256 -eq $exeArtifact.shadowSha256

    $manifest = [pscustomobject][ordered]@{
        schema = 'nikami-fnv-retail-shadow/v1'
        status = if ($passed) { 'pass' } else { 'fail' }
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        sourceGameRoot = $sourceRoot
        shadowGameRoot = $shadowRootPath
        policy = [pscustomobject][ordered]@{
            sourceInstallationModified = $false
            wholeDataDirectoryLinked = $false
            copiedRootAllowlist = $requiredRootFiles
            hardlinkedDataAllowlist = $requiredDataFiles
            junctionDataAllowlist = $requiredDataDirectories
            emptyShadowNvsePluginDirectory = (Join-Path $shadowData.FullName 'NVSE\Plugins')
            excludedPatterns = @('fnvxr', 'openxr', 'openvr', 'reshade', 'xinput*.dll', 'd3d9.dll', 'dinput8.dll', 'dxgi.dll', '*.esp', 'Data\NVSE from source')
        }
        assertions = [pscustomobject][ordered]@{
            exactRetailExeMatch = [bool]($exeArtifact.sourceSha256 -eq $exeArtifact.shadowSha256)
            unexpectedRootFiles = @($unexpectedRootFiles | ForEach-Object FullName)
            shadowPluginFiles = @($shadowPlugins | ForEach-Object FullName)
            prohibitedShadowFiles = @($shadowProhibited | ForEach-Object FullName)
        }
        excludedSourceCandidates = @(
            @($sourceHooks) + @($sourceVrPlugins) | ForEach-Object {
                [pscustomobject][ordered]@{
                    path = $_.FullName
                    bytes = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                }
            }
        )
        artifacts = @($artifacts)
        directoryLinks = @($directoryLinks)
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPathValue -Encoding utf8
    if (-not $passed) {
        throw "Retail shadow failed its prelaunch whitelist. See $manifestPathValue"
    }
    $manifest
    exit 0
}

if ($TargetProcessId -le 0) {
    throw 'VerifyProcess requires -TargetProcessId.'
}
if ([string]::IsNullOrWhiteSpace($ExternalRuntimeRoot)) {
    throw 'VerifyProcess requires -ExternalRuntimeRoot.'
}
if ([string]::IsNullOrWhiteSpace($VerificationPath)) {
    $VerificationPath = "$shadowRootPath.loaded-modules.json"
}
$verificationPathValue = [IO.Path]::GetFullPath($VerificationPath)
if (Test-Path -LiteralPath $verificationPathValue) {
    throw "Refusing to overwrite loaded-module report: $verificationPathValue"
}
$process = Get-Process -Id $TargetProcessId -ErrorAction Stop
$processPath = $process.Path
$expectedProcessPath = Join-Path $shadowRootPath 'FalloutNV.exe'
$modules = @($process.Modules | ForEach-Object {
    $modulePath = $_.FileName
    [pscustomobject][ordered]@{
        name = $_.ModuleName
        path = $modulePath
        bytes = if (Test-Path -LiteralPath $modulePath -PathType Leaf) { (Get-Item -LiteralPath $modulePath).Length } else { 0 }
        sha256 = if (Test-Path -LiteralPath $modulePath -PathType Leaf) {
            (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
        } else { $null }
    }
})
$windowsRoot = [IO.Path]::GetFullPath($env:WINDIR)
$systemDirectories = @(
    [IO.Path]::GetFullPath((Join-Path $windowsRoot 'System32')),
    [IO.Path]::GetFullPath((Join-Path $windowsRoot 'SysWOW64'))
)
$allowedSystemHookModules = [Collections.Generic.List[object]]::new()
$prohibitedModules = [Collections.Generic.List[object]]::new()
foreach ($module in $modules) {
    if (-not (Test-ProhibitedName $module.name) -and -not (Test-ProhibitedName $module.path)) {
        continue
    }
    $alwaysProhibited = $module.name -match '(?i)fnvxr|openxr|openvr|reshade' -or
        $module.path -match '(?i)fnvxr|openxr|openvr|reshade'
    $systemPath = @($systemDirectories | Where-Object {
        $module.path.StartsWith($_ + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0
    $signature = if ($systemPath -and (Test-Path -LiteralPath $module.path -PathType Leaf)) {
        Get-AuthenticodeSignature -LiteralPath $module.path
    } else { $null }
    $validMicrosoftSystemModule = -not $alwaysProhibited -and $systemPath -and
        $null -ne $signature -and $signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
        $null -ne $signature.SignerCertificate -and
        $signature.SignerCertificate.Subject -match '(?i)(^|,\s*)O=Microsoft Corporation(,|$)'
    $evidence = [pscustomobject][ordered]@{
        name = $module.name
        path = $module.path
        bytes = $module.bytes
        sha256 = $module.sha256
        systemPath = [bool]$systemPath
        signatureStatus = if ($null -ne $signature) { [string]$signature.Status } else { $null }
        signerSubject = if ($null -ne $signature -and $null -ne $signature.SignerCertificate) {
            $signature.SignerCertificate.Subject
        } else { $null }
    }
    if ($validMicrosoftSystemModule) {
        $allowedSystemHookModules.Add($evidence)
    } else {
        $prohibitedModules.Add($evidence)
    }
}
$runtimeRootPath = [IO.Path]::GetFullPath($ExternalRuntimeRoot)
$candidatePluginDirectories = @(
    Get-ChildItem -LiteralPath (Join-Path $runtimeRootPath '.runs') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTimeUtc -ge $process.StartTime.ToUniversalTime().AddSeconds(-10) } |
        ForEach-Object { Join-Path $_.FullName 'plugins' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container }
)
$pluginFiles = @($candidatePluginDirectories | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -File | ForEach-Object {
        [pscustomobject][ordered]@{
            path = $_.FullName
            name = $_.Name
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
})
$unexpectedPlugins = @($pluginFiles | Where-Object { $_.name -ine 'nvse_retail_oracle.dll' })
$shadowPluginFiles = @(Get-ChildItem -LiteralPath (Join-Path $shadowRootPath 'Data\NVSE\Plugins') -File)
$oracleModules = @($modules | Where-Object { $_.name -ieq 'nvse_retail_oracle.dll' })
$nvseCoreModules = @($modules | Where-Object { $_.name -ieq 'nvse_1_4.dll' })
$retailDataPluginModules = @($modules | Where-Object { $_.path -match '(?i)\\Data\\nvse\\plugins\\' })
$oracleModuleMatchesPlugin = $oracleModules.Count -eq 1 -and $pluginFiles.Count -eq 1 -and
    $oracleModules[0].sha256 -eq $pluginFiles[0].sha256
$nvseCoreInExternalRuntime = $nvseCoreModules.Count -eq 1 -and
    $nvseCoreModules[0].path.StartsWith($runtimeRootPath + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)
$passed = $processPath.Equals($expectedProcessPath, [StringComparison]::OrdinalIgnoreCase) -and
    $prohibitedModules.Count -eq 0 -and $unexpectedPlugins.Count -eq 0 -and $shadowPluginFiles.Count -eq 0 -and
    $pluginFiles.Count -eq 1 -and $oracleModuleMatchesPlugin -and $nvseCoreInExternalRuntime -and
    $retailDataPluginModules.Count -eq 0
$report = [pscustomobject][ordered]@{
    schema = 'nikami-fnv-retail-shadow-loaded-modules/v1'
    status = if ($passed) { 'pass' } else { 'fail' }
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    process = [pscustomobject][ordered]@{
        id = $process.Id
        path = $processPath
        expectedPath = $expectedProcessPath
        exactShadowExecutable = $processPath.Equals($expectedProcessPath, [StringComparison]::OrdinalIgnoreCase)
        startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
    }
    assertions = [pscustomobject][ordered]@{
        prohibitedModules = @($prohibitedModules)
        allowedMicrosoftSystemInputAndGraphicsModules = @($allowedSystemHookModules)
        unexpectedPlugins = @($unexpectedPlugins)
        shadowDataPluginFiles = @($shadowPluginFiles | ForEach-Object FullName)
        isolatedOraclePluginCount = $pluginFiles.Count
        loadedOracleModuleCount = $oracleModules.Count
        oracleModuleMatchesIsolatedPlugin = [bool]$oracleModuleMatchesPlugin
        nvseCoreInExternalRuntime = [bool]$nvseCoreInExternalRuntime
        retailDataPluginModules = @($retailDataPluginModules)
    }
    isolatedPluginDirectories = $candidatePluginDirectories
    isolatedPluginFiles = $pluginFiles
    modules = $modules
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $verificationPathValue -Encoding utf8
if (-not $passed) {
    throw "Retail shadow loaded-module verification failed. See $verificationPathValue"
}
$report
