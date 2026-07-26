param(
    [string]$Fallout3Data = "",
    [string]$FalloutNewVegasData = "",
    [string]$TtwRoot = "",
    [string]$JamRoot = "",
    [string]$OutputPath = "",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$localRoot = Join-Path $repoRoot "local"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $localRoot "paths.json"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$expectedPrefix = [IO.Path]::GetFullPath($localRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
if (-not $OutputPath.StartsWith($expectedPrefix + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OpenNV configuration must remain under $localRoot. Requested: $OutputPath"
}

$provided = [ordered]@{
    fallout3Data = $Fallout3Data
    falloutNewVegasData = $FalloutNewVegasData
    ttwRoot = $TtwRoot
    jamRoot = $JamRoot
}
foreach ($key in @($provided.Keys)) {
    $value = [string]$provided[$key]
    if ([string]::IsNullOrWhiteSpace($value)) {
        continue
    }
    $resolved = [IO.Path]::GetFullPath($value)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Configured $key directory does not exist: $resolved"
    }
    $provided[$key] = $resolved -replace "\\", "/"
}

$existing = [ordered]@{}
if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
    try {
        $current = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Existing OpenNV configuration is not valid JSON: $OutputPath"
    }
    foreach ($property in $current.PSObject.Properties) {
        $existing[$property.Name] = $property.Value
    }
}

$hasInput = $false
foreach ($key in @($provided.Keys)) {
    $value = [string]$provided[$key]
    if ([string]::IsNullOrWhiteSpace($value)) {
        continue
    }
    $hasInput = $true
    $previousValue = if ($existing.Contains($key)) { [string]$existing[$key] } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($previousValue) -and $previousValue -cne $value -and -not $Force) {
        throw "local/paths.json already has a different $key. Re-run with -Force to change only that registered path."
    }
    $existing[$key] = $value
}
if (-not $hasInput -and $existing.Count -eq 0) {
    throw "Provide at least one path, for example -FalloutNewVegasData 'D:\\SteamLibrary\\steamapps\\common\\Fallout New Vegas\\Data'."
}

New-Item -ItemType Directory -Path $localRoot -Force | Out-Null
[IO.File]::WriteAllText($OutputPath, (($existing | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Host "OpenNV paths registered in $OutputPath"
foreach ($key in @($provided.Keys)) {
    $value = [string]$provided[$key]
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        Write-Host "  ${key}: $value"
    }
}
