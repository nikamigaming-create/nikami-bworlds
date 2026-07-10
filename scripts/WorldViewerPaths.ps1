Set-StrictMode -Version Latest

$script:NikamiRepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path

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
    return (Join-Path $script:NikamiRepoRoot "local\openmw-fo4guard")
}

function Get-NikamiOpenMWResourcesRoot {
    return (Join-Path (Get-NikamiOpenMWRuntimeRoot) "resources")
}

function Resolve-NikamiOpenMWRuntimeRoot {
    param(
        [string]$ParameterValue = ""
    )

    $defaultRoot = Resolve-NikamiRepoRelativePath -Path (Get-NikamiOpenMWRuntimeRoot)
    $candidateRoot = $defaultRoot
    if (-not [string]::IsNullOrWhiteSpace($ParameterValue)) {
        $candidateRoot = Resolve-NikamiRepoRelativePath -Path $ParameterValue
    }

    $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $script:NikamiRepoRoot "local"))
    $allowedPrefix = $allowedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidateRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "External OpenMW runtime roots are not allowed. Runtime must be under $allowedRoot. Requested: $candidateRoot."
    }

    if (-not (Test-Path -LiteralPath $candidateRoot)) {
        throw "Missing repo-local OpenMW runtime root: $candidateRoot"
    }

    $candidateRoot = (Resolve-Path -LiteralPath $candidateRoot).Path
    $binary = Join-Path $candidateRoot "openmw.exe"
    if (-not (Test-Path -LiteralPath $binary)) {
        throw "Missing repo-local OpenMW binary: $binary"
    }

    return $candidateRoot
}

function Resolve-NikamiOpenMWResourcesRoot {
    param(
        [string]$ParameterValue = ""
    )

    $defaultRoot = Resolve-NikamiRepoRelativePath -Path (Get-NikamiOpenMWResourcesRoot)
    $candidateRoot = $defaultRoot
    if (-not [string]::IsNullOrWhiteSpace($ParameterValue)) {
        $candidateRoot = Resolve-NikamiRepoRelativePath -Path $ParameterValue
    }

    $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path $script:NikamiRepoRoot "local"))
    $allowedPrefix = $allowedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidateRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "External OpenMW resources roots are not allowed. Resources must be under $allowedRoot. Requested: $candidateRoot."
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

function Clear-NikamiWorldViewerRuntimeEnvironment {
    $keys = @([Environment]::GetEnvironmentVariables("Process").Keys)
    foreach ($key in $keys) {
        $name = [string]$key
        if ($name.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase) `
            -or $name.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase)) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
}
