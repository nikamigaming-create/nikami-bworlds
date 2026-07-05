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
