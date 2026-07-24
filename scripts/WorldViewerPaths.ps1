Set-StrictMode -Version Latest

$script:NikamiRepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$script:NikamiCurrentOpenMWRuntimeDirectory = "openmw-pristine-mads-33568a"
$script:NikamiRejectedOpenMWRuntimeDirectories = @(
    "openmw-fo4guard",
    "openmw-clean-recovery-6a5576"
)

function Assert-NikamiOpenMWRuntimeIsNotRejected {
    param(
        [Parameter(Mandatory=$true)]
        [string]$RuntimeRoot
    )

    $normalized = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $directory = Split-Path -Leaf $normalized
    if ($script:NikamiRejectedOpenMWRuntimeDirectories -icontains $directory) {
        throw "Rejected obsolete OpenMW runtime '$directory'. Ordinary FNV launches are locked to local/$($script:NikamiCurrentOpenMWRuntimeDirectory)."
    }
}

function Get-NikamiLocalConfig {
    param(
        [string]$ConfigPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $script:NikamiRepoRoot "local/paths.json"
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $null
    }

    return Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

function Get-NikamiConfigValue {
    param(
        [object]$Config,
        [string]$Name
    )

    if ($null -eq $Config -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-NikamiPath {
    param(
        [string]$ParameterValue = "",
        [string]$EnvName = "",
        [string]$ConfigName = "",
        [string]$Fallback = "",
        [switch]$Required,
        [string]$Description = "path"
    )

    if (-not [string]::IsNullOrWhiteSpace($ParameterValue)) {
        return $ParameterValue
    }

    if (-not [string]::IsNullOrWhiteSpace($EnvName)) {
        $envValue = [Environment]::GetEnvironmentVariable($EnvName, "Process")
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            return $envValue
        }
    }

    $config = Get-NikamiLocalConfig
    $configValue = Get-NikamiConfigValue -Config $config -Name $ConfigName
    if ($null -ne $configValue -and -not [string]::IsNullOrWhiteSpace([string]$configValue)) {
        return [string]$configValue
    }

    if (-not [string]::IsNullOrWhiteSpace($Fallback)) {
        return $Fallback
    }

    if ($Required) {
        $sources = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($EnvName)) {
            $sources.Add("env:$EnvName")
        }
        if (-not [string]::IsNullOrWhiteSpace($ConfigName)) {
            $sources.Add("local/paths.json:$ConfigName")
        }
        $sourceText = if ($sources.Count -gt 0) { $sources -join " or " } else { "a script parameter" }
        throw "Missing $Description. Set it with a parameter, $sourceText."
    }

    return ""
}

function Resolve-NikamiPathList {
    param(
        [string[]]$ParameterValue = @(),
        [string]$EnvName = "",
        [string]$ConfigName = ""
    )

    $values = New-Object System.Collections.Generic.List[string]

    foreach ($value in $ParameterValue) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values.Add($value)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EnvName)) {
        $envValue = [Environment]::GetEnvironmentVariable($EnvName, "Process")
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            foreach ($part in ($envValue -split ';')) {
                if (-not [string]::IsNullOrWhiteSpace($part)) {
                    $values.Add($part)
                }
            }
        }
    }

    $config = Get-NikamiLocalConfig
    $configValue = Get-NikamiConfigValue -Config $config -Name $ConfigName
    if ($null -ne $configValue) {
        foreach ($part in @($configValue)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$part)) {
                $values.Add([string]$part)
            }
        }
    }

    return @($values.ToArray() | Select-Object -Unique)
}

function Resolve-NikamiRepoRelativePath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $script:NikamiRepoRoot $Path))
}

function Get-NikamiOpenMWRuntimeRoot {
    return (Join-Path $script:NikamiRepoRoot "local\$($script:NikamiCurrentOpenMWRuntimeDirectory)")
}

function Get-NikamiOpenMWResourcesRoot {
    return (Join-Path (Get-NikamiOpenMWRuntimeRoot) "resources")
}

function Resolve-NikamiOpenMWRuntimeRoot {
    param(
        [string]$ParameterValue = "",
        [switch]$RequireCurrent
    )

    $defaultRoot = Resolve-NikamiRepoRelativePath -Path (Get-NikamiOpenMWRuntimeRoot)
    $configuredRoot = Resolve-NikamiPath `
        -ParameterValue $ParameterValue `
        -EnvName "NIKAMI_OPENMW_BINARY_ROOT" `
        -ConfigName "openmwBinaryRoot" `
        -Fallback (Get-NikamiOpenMWRuntimeRoot)
    $candidateRoot = Resolve-NikamiRepoRelativePath -Path $configuredRoot

    $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $script:NikamiRepoRoot "local"))
    $allowedPrefix = $allowedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidateRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "External OpenMW runtime roots are not allowed. Runtime must be under $allowedRoot. Requested: $candidateRoot."
    }
    Assert-NikamiOpenMWRuntimeIsNotRejected -RuntimeRoot $candidateRoot
    if ($RequireCurrent -and $candidateRoot -ine $defaultRoot) {
        throw "Ordinary OpenMW launches are locked to $defaultRoot. Requested: $candidateRoot."
    }

    if (-not (Test-Path -LiteralPath $candidateRoot)) {
        throw "Missing repo-local OpenMW runtime root: $candidateRoot"
    }

    $candidateRoot = (Resolve-Path -LiteralPath $candidateRoot).Path
    $binary = Join-Path $candidateRoot "openmw.exe"
    if (-not (Test-Path -LiteralPath $binary)) {
        throw "Missing repo-local OpenMW binary: $binary"
    }

    # A build-tree openmw.exe is not a runnable Windows deployment by itself.
    # Reject incomplete runtime directories before Windows displays a loader
    # dialog (which is both opaque to the harness and easy to mistake for an
    # engine crash).
    $requiredRuntimeFiles = @(
        "MyGUIEngine.dll"
    )
    foreach ($requiredRuntimeFile in $requiredRuntimeFiles) {
        $requiredRuntimePath = Join-Path $candidateRoot $requiredRuntimeFile
        if (-not (Test-Path -LiteralPath $requiredRuntimePath -PathType Leaf)) {
            throw "Incomplete repo-local OpenMW runtime: missing $requiredRuntimeFile beside $binary. Launch the packaged runtime under local, not a build-tree openmw.exe."
        }
    }

    return $candidateRoot
}

function Resolve-NikamiOpenMWResourcesRoot {
    param(
        [string]$ParameterValue = "",
        [switch]$RequireCurrent
    )

    $defaultRoot = Resolve-NikamiRepoRelativePath -Path (Get-NikamiOpenMWResourcesRoot)
    $configuredRoot = Resolve-NikamiPath `
        -ParameterValue $ParameterValue `
        -EnvName "NIKAMI_OPENMW_RESOURCES" `
        -ConfigName "openmwResources" `
        -Fallback (Get-NikamiOpenMWResourcesRoot)
    $candidateRoot = Resolve-NikamiRepoRelativePath -Path $configuredRoot

    $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $script:NikamiRepoRoot "local"))
    $allowedPrefix = $allowedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidateRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "External OpenMW resources roots are not allowed. Resources must be under $allowedRoot. Requested: $candidateRoot."
    }
    $runtimeRoot = Split-Path -Parent $candidateRoot
    Assert-NikamiOpenMWRuntimeIsNotRejected -RuntimeRoot $runtimeRoot
    if ($RequireCurrent -and $candidateRoot -ine $defaultRoot) {
        throw "Ordinary OpenMW launches are locked to $defaultRoot. Requested: $candidateRoot."
    }

    if (-not (Test-Path -LiteralPath $candidateRoot)) {
        throw "Missing repo-local OpenMW resources root: $candidateRoot"
    }

    return (Resolve-Path -LiteralPath $candidateRoot).Path
}

function Get-NikamiProofBinaryRoot {
    return Get-NikamiOpenMWRuntimeRoot
}

function Get-NikamiProofResourcesRoot {
    return Get-NikamiOpenMWResourcesRoot
}

function Resolve-NikamiProofBinaryRoot {
    param(
        [string]$ParameterValue = ""
    )

    return Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $ParameterValue
}

function Resolve-NikamiProofResourcesRoot {
    param(
        [string]$ParameterValue = ""
    )

    return Resolve-NikamiOpenMWResourcesRoot -ParameterValue $ParameterValue
}

function Test-NikamiFnvSkyRuntimeEnvironmentName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.StartsWith("OPENMW_FNV_PROOF_", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return @(
        "OPENMW_FNV_ENABLE_SKY_SHADER_PROPERTIES", "OPENMW_FNV_NATIVE_CLOUD_OPACITY",
        "OPENMW_FNV_SKY_MESH_SCALE", "OPENMW_FNV_SKY_MISSING_LOG", "OPENMW_FNV_SKY_TARGET_RADIUS"
    ) -contains $Name.ToUpperInvariant()
}

function Clear-NikamiFnvSkyRuntimeEnvironment([hashtable]$PreviousEnvironment) {
    foreach ($key in @([Environment]::GetEnvironmentVariables("Process").Keys)) {
        $name = [string]$key
        if (-not (Test-NikamiFnvSkyRuntimeEnvironmentName $name)) { continue }
        if ($null -ne $PreviousEnvironment -and -not $PreviousEnvironment.ContainsKey($name)) {
            $PreviousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}

function Restore-NikamiRuntimeEnvironment([hashtable]$PreviousEnvironment) {
    foreach ($entry in $PreviousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

function ConvertTo-NikamiManifestPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path) -replace "\\", "/"
}

function Get-NikamiSha256Text([string]$Text) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Get-NikamiObservedFileEvidence([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing bounded-evidence file: $Path" }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    return [pscustomobject][ordered]@{
        path = ConvertTo-NikamiManifestPath $resolved
        observedBytes = [long](Get-Item -LiteralPath $resolved).Length
        observedSha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
        hashVerification = "observed"
    }
}

function Get-NikamiOpenMWConfigValues([string]$ConfigPath, [string]$Key) {
    return @(Get-Content -LiteralPath $ConfigPath | ForEach-Object {
        if ($_ -match ('^\s*' + [Regex]::Escape($Key) + '\s*=\s*(.*?)\s*$')) {
            $Matches[1].Trim().Trim('"').Trim("'")
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-NikamiOpenMWDataRootsFromConfig([string]$ConfigPath) {
    $config = (Resolve-Path -LiteralPath $ConfigPath).Path
    $roots = @()
    foreach ($key in @("data", "data-local")) {
        foreach ($value in @(Get-NikamiOpenMWConfigValues $config $key)) {
            $candidate = if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path (Split-Path -Parent $config) $value }
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) { throw "OpenMW data root is missing: $candidate" }
            $roots += (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    if (-not $roots.Count) { throw "OpenMW configuration declares no data roots: $config" }
    return @($roots | Select-Object -Unique)
}

function Get-NikamiOpenMWConfigurationInputPaths([string[]]$ConfigDirectory, [string[]]$AdditionalFile = @()) {
    $paths = @()
    foreach ($directory in $ConfigDirectory) {
        foreach ($name in @("openmw.cfg", "settings.cfg", "input_v3.xml", "shaders.yaml")) {
            $candidate = Join-Path $directory $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $paths += (Resolve-Path -LiteralPath $candidate).Path }
        }
    }
    foreach ($file in $AdditionalFile) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing configuration input: $file" }
        $paths += (Resolve-Path -LiteralPath $file).Path
    }
    if (-not $paths.Count) { throw "Bounded launch evidence requires configuration inputs." }
    return @($paths | Select-Object -Unique)
}

function New-NikamiOpenMWBoundedInputEvidence {
    param(
        [string]$Executable, [string]$ResourcesRoot, [string[]]$ConfigurationPath,
        [string]$DataConfigPath, [string[]]$DataRoot,
        [string]$DenominatorPath = (Join-Path $script:NikamiRepoRoot "catalog/fnv-parity-denominators.json"),
        [switch]$AllowSyntheticDenominator
    )
    $executableEvidence = Get-NikamiObservedFileEvidence $Executable
    $resourceRootPath = (Resolve-Path -LiteralPath $ResourcesRoot).Path
    $resourceVersion = Get-NikamiObservedFileEvidence (Join-Path $resourceRootPath "version")
    $configuration = @($ConfigurationPath | ForEach-Object { Get-NikamiObservedFileEvidence $_ })
    $configurationContractSha = Get-NikamiSha256Text (($configuration | ForEach-Object {
        "$($_.path)`0$($_.observedBytes)`0$($_.observedSha256)`n"
    }) -join "")
    $denominatorEvidence = Get-NikamiObservedFileEvidence $DenominatorPath
    $denominator = Get-Content -LiteralPath $DenominatorPath -Raw | ConvertFrom-Json
    if ([string]$denominator.schema -cne "nikami-fnv-parity-denominators/v1") { throw "Unsupported FNV denominator schema." }
    if (-not $AllowSyntheticDenominator -and ([string]$denominator.scopeId -cne "fnv-ultimate-edition-en-official-v1" -or
        @($denominator.officialMasters).Count -ne 10 -or @($denominator.officialArchives).Count -ne 21)) {
        throw "FNV bounded evidence requires the frozen 10-master/21-archive denominator."
    }
    $roots = @($DataRoot | ForEach-Object {
        if (-not (Test-Path -LiteralPath $_ -PathType Container)) { throw "Missing data root: $_" }
        ConvertTo-NikamiManifestPath (Resolve-Path -LiteralPath $_).Path
    })
    $content = @(Get-NikamiOpenMWConfigValues $DataConfigPath "content")
    $archives = @(Get-NikamiOpenMWConfigValues $DataConfigPath "fallback-archive")
    $officialFiles = @()
    foreach ($expected in @($denominator.officialMasters) + @($denominator.officialArchives)) {
        if ([string]::IsNullOrWhiteSpace([string]$expected.name) -or [long]$expected.bytes -le 0 -or
            [string]$expected.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Malformed FNV denominator file evidence." }
        $kind = if ([IO.Path]::GetExtension([string]$expected.name) -ieq ".bsa") { "archive" } else { "master" }
        $path = $null
        for ($index = $roots.Count - 1; $index -ge 0 -and $null -eq $path; --$index) {
            $candidate = Join-Path $roots[$index] ([string]$expected.name)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $path = (Resolve-Path -LiteralPath $candidate).Path }
        }
        $observedBytes = if ($null -ne $path) { [long](Get-Item -LiteralPath $path).Length } else { -1L }
        $configured = if ($kind -eq "archive") { $archives -icontains [string]$expected.name } else { $content -icontains [string]$expected.name }
        if (-not $configured -or $observedBytes -ne [long]$expected.bytes) { throw "FNV frozen data contract mismatch: $($expected.name)" }
        $officialFiles += [pscustomobject][ordered]@{
            kind = $kind; name = [string]$expected.name; path = ConvertTo-NikamiManifestPath $path
            expectedBytes = [long]$expected.bytes; observedBytes = $observedBytes
            expectedSha256 = ([string]$expected.sha256).ToLowerInvariant()
            hashVerification = "not-observed"; expectedSha256Source = $denominatorEvidence.path
        }
    }
    $officialCorpusContractSha = Get-NikamiSha256Text ("manifest=$($denominatorEvidence.observedSha256)`nroots=$($roots -join '|')`n" +
        (($officialFiles | ForEach-Object {
            "$($_.kind)`0$($_.name)`0$($_.path)`0$($_.expectedBytes)`0$($_.observedBytes)`0$($_.expectedSha256)`0$($_.hashVerification)`n"
        }) -join ""))
    $resourceVersionContract = [pscustomobject][ordered]@{
        rootPath = ConvertTo-NikamiManifestPath $resourceRootPath
        version = $resourceVersion
        contractSha256 = Get-NikamiSha256Text "root=$(ConvertTo-NikamiManifestPath $resourceRootPath)`nversion=$($resourceVersion.observedSha256)`n"
        included = @("resources/version path, byte count, and live SHA-256")
        excluded = @("full resources tree is not hashed")
    }
    $officialCorpusContract = [pscustomobject][ordered]@{
        configPath = ConvertTo-NikamiManifestPath $DataConfigPath; configuredDataRoots = $roots
        denominator = $denominatorEvidence; scopeId = [string]$denominator.scopeId
        officialMasterCount = @($denominator.officialMasters).Count
        officialArchiveCount = @($denominator.officialArchives).Count
        officialFiles = $officialFiles
        verification = "filename and byte count observed; expected SHA-256 values not observed"
        contractSha256 = $officialCorpusContractSha
    }
    $configurationContract = [pscustomobject][ordered]@{
        files = $configuration; contractSha256 = $configurationContractSha
        included = @("declared OpenMW configuration files with live byte counts and SHA-256")
    }
    $aggregate = "exe=$($executableEvidence.observedSha256)`nresourceVersion=$($resourceVersionContract.contractSha256)`nconfiguration=$configurationContractSha`nofficialCorpus=$officialCorpusContractSha`n"
    return [pscustomobject][ordered]@{
        schema = "nikami-openmw-bounded-input-evidence/v1"; createdAtUtc = [DateTime]::UtcNow.ToString("o")
        executable = $executableEvidence; resourceVersionContract = $resourceVersionContract
        configurationContract = $configurationContract; officialCorpusContract = $officialCorpusContract
        coverage = [pscustomobject][ordered]@{
            claim = "bounded-input-evidence-not-full-effective-input-provenance"
            included = @("executable", "declared configuration files", "resources/version", "frozen official filename/byte contract")
            excluded = @("full resources tree is not hashed", "FNVR.esp is not hashed", "loose overlay files are not hashed", "shared UI data are not hashed")
        }
        boundedContractSha256 = Get-NikamiSha256Text $aggregate
    }
}

function Assert-NikamiOpenMWBoundedInputEvidence {
    param(
        $Evidence, [string]$Executable, [string]$ResourcesRoot, [string[]]$ConfigurationPath,
        [string]$DataConfigPath, [string[]]$DataRoot,
        [string]$DenominatorPath = (Join-Path $script:NikamiRepoRoot "catalog/fnv-parity-denominators.json"),
        [switch]$AllowSyntheticDenominator, [switch]$VerifyCurrent, [switch]$VerifyOfficialDataHashes
    )
    if ([string]$Evidence.schema -cne "nikami-openmw-bounded-input-evidence/v1" -or
        [string]$Evidence.coverage.claim -cne "bounded-input-evidence-not-full-effective-input-provenance") {
        throw "Bounded input evidence is missing or unsupported."
    }
    $configurationContractSha = Get-NikamiSha256Text ((@($Evidence.configurationContract.files) |
        ForEach-Object { "$($_.path)`0$($_.observedBytes)`0$($_.observedSha256)`n" }) -join "")
    $officialCorpusContractSha = Get-NikamiSha256Text ("manifest=$($Evidence.officialCorpusContract.denominator.observedSha256)`nroots=$(@($Evidence.officialCorpusContract.configuredDataRoots) -join '|')`n" +
        ((@($Evidence.officialCorpusContract.officialFiles) | ForEach-Object {
            "$($_.kind)`0$($_.name)`0$($_.path)`0$($_.expectedBytes)`0$($_.observedBytes)`0$($_.expectedSha256)`0$($_.hashVerification)`n"
        }) -join ""))
    $resourceVersionContractSha = Get-NikamiSha256Text "root=$($Evidence.resourceVersionContract.rootPath)`nversion=$($Evidence.resourceVersionContract.version.observedSha256)`n"
    if ([string]$Evidence.configurationContract.contractSha256 -cne $configurationContractSha -or
        [string]$Evidence.officialCorpusContract.contractSha256 -cne $officialCorpusContractSha -or
        [string]$Evidence.resourceVersionContract.contractSha256 -cne $resourceVersionContractSha) {
        throw "Bounded input evidence component mismatch."
    }
    $aggregate = Get-NikamiSha256Text "exe=$($Evidence.executable.observedSha256)`nresourceVersion=$resourceVersionContractSha`nconfiguration=$configurationContractSha`nofficialCorpus=$officialCorpusContractSha`n"
    if ([string]$Evidence.boundedContractSha256 -cne $aggregate) { throw "Bounded input evidence aggregate mismatch." }
    if ($VerifyCurrent) {
        $current = New-NikamiOpenMWBoundedInputEvidence -Executable $Executable -ResourcesRoot $ResourcesRoot `
            -ConfigurationPath $ConfigurationPath -DataConfigPath $DataConfigPath -DataRoot $DataRoot `
            -DenominatorPath $DenominatorPath -AllowSyntheticDenominator:$AllowSyntheticDenominator
        if ([string]$current.boundedContractSha256 -cne [string]$Evidence.boundedContractSha256) {
            throw "Bounded input evidence no longer matches current inputs."
        }
    }
    if ($VerifyOfficialDataHashes) {
        foreach ($file in @($Evidence.officialCorpusContract.officialFiles)) {
            if ((Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$file.expectedSha256) {
                throw "FNV official file SHA-256 mismatch: $($file.path)"
            }
        }
    }
    return $true
}

function Get-NikamiOpenMWBoundedInputEvidenceLogLines($Evidence) {
    return @(
        "OpenMW bounded input evidence: schema=$($Evidence.schema) contractSha256=$($Evidence.boundedContractSha256) claim=$($Evidence.coverage.claim)",
        "  executable path=$($Evidence.executable.path) observedSha256=$($Evidence.executable.observedSha256) observedBytes=$($Evidence.executable.observedBytes)",
        "  resourceVersion root=$($Evidence.resourceVersionContract.rootPath) versionPath=$($Evidence.resourceVersionContract.version.path) observedSha256=$($Evidence.resourceVersionContract.version.observedSha256) fullTreeHashed=false",
        "  configuration contractSha256=$($Evidence.configurationContract.contractSha256) paths=$(@($Evidence.configurationContract.files.path) -join '|')",
        "  officialCorpus contractSha256=$($Evidence.officialCorpusContract.contractSha256) roots=$(@($Evidence.officialCorpusContract.configuredDataRoots) -join '|') denominatorPath=$($Evidence.officialCorpusContract.denominator.path) denominatorObservedSha256=$($Evidence.officialCorpusContract.denominator.observedSha256) fileHashesObserved=false",
        "  excluded: $($Evidence.coverage.excluded -join '; ')"
    )
}

function Clear-NikamiWorldViewerRuntimeEnvironment {
    $keys = @([Environment]::GetEnvironmentVariables("Process").Keys)
    foreach ($key in $keys) {
        $name = [string]$key
        if ($name.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase) `
            -or $name.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase) `
            -or ($name.StartsWith("OPENMW_FNV_", [StringComparison]::OrdinalIgnoreCase) `
                -and $name.IndexOf("PROOF", [StringComparison]::OrdinalIgnoreCase) -ge 0) `
            -or $name.Equals("OPENMW_STARTUP_SCRIPT", [StringComparison]::OrdinalIgnoreCase) `
            -or $name.Equals("OPENMW_PLAYABLE_SESSION_BACKGROUND", [StringComparison]::OrdinalIgnoreCase) `
            -or $name.Equals("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", [StringComparison]::OrdinalIgnoreCase) `
            -or (Test-NikamiFnvSkyRuntimeEnvironmentName $name)) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
}
