[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DataRoot,
    [string]$BinaryRoot = "local/openmw-fo4guard",
    [string]$OutputPath = "run/fnv-parity-profile/openmw.cfg",
    [string]$DenominatorPath = "catalog/fnv-parity-denominators.json",
    [switch]$SkipFileValidation
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

$data = [IO.Path]::GetFullPath($DataRoot)
$binary = Resolve-RepoPath $BinaryRoot
$output = Resolve-RepoPath $OutputPath
$denominatorFile = Resolve-RepoPath $DenominatorPath
if (-not (Test-Path -LiteralPath $denominatorFile -PathType Leaf)) {
    throw "FNV denominator file does not exist: $denominatorFile"
}
$denominators = Get-Content -LiteralPath $denominatorFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$denominators.schema -ne "nikami-fnv-parity-denominators/v1") {
    throw "Unexpected FNV denominator schema."
}

$masters = @($denominators.officialMasters)
$archives = @($denominators.officialArchives | Sort-Object { [int]$_.order })
if ($masters.Count -ne 10 -or $archives.Count -ne 21) {
    throw "Frozen FNV parity scope must contain 10 masters and 21 archives."
}
if (-not $SkipFileValidation) {
    if (-not (Test-Path -LiteralPath $data -PathType Container)) {
        throw "FNV Data directory does not exist: $data"
    }
    foreach ($entry in @($masters) + @($archives)) {
        $path = Join-Path $data ([string]$entry.name)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Frozen FNV input is missing: $path"
        }
        if ((Get-Item -LiteralPath $path).Length -ne [long]$entry.bytes) {
            throw "Frozen FNV input size differs: $path"
        }
    }
}

$profileRoot = Split-Path -Parent $output
$userData = Join-Path $profileRoot "userdata"
$dataLocal = Join-Path $userData "data"
$resources = Join-Path $binary "resources"
foreach ($directory in @($profileRoot, $userData, $dataLocal)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

$lines = New-Object System.Collections.Generic.List[string]
foreach ($replace in @("data", "data-local", "fallback-archive", "content")) {
    $lines.Add("replace=$replace") | Out-Null
}
$lines.Add("") | Out-Null
$lines.Add("user-data=$($userData.Replace('\', '/'))") | Out-Null
$lines.Add("data-local=$($dataLocal.Replace('\', '/'))") | Out-Null
$lines.Add("resources=$($resources.Replace('\', '/'))") | Out-Null
$lines.Add("data=$($data.Replace('\', '/'))") | Out-Null
$lines.Add("") | Out-Null
foreach ($archive in $archives) {
    $lines.Add("fallback-archive=$($archive.name)") | Out-Null
}
$lines.Add("") | Out-Null
foreach ($master in $masters) {
    $lines.Add("content=$($master.name)") | Out-Null
}

[IO.File]::WriteAllLines($output, $lines, (New-Object Text.UTF8Encoding($false)))
Write-Output $output
