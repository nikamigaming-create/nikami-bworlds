param(
    [string]$BaseManifestPath = "run/actor-math-matrix/fnv-root-frame-20260708-0624/baseline/fallout_new_vegas-20260708-062334/manifest.json",
    [string]$OutputRoot = "run/actor-math-direct",
    [string]$RunId = "",
    [string]$CaseId = "baseline",
    [int]$RunSeconds = 12,
    [string[]]$SetEnv = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Convert-ToForwardSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    return ([System.IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-EnvironmentAssignment([string]$Assignment) {
    $separator = $Assignment.IndexOf("=")
    if ($separator -lt 1) {
        throw "Expected NAME=VALUE environment assignment, got '$Assignment'."
    }
    [pscustomobject][ordered]@{
        name = $Assignment.Substring(0, $separator)
        value = $Assignment.Substring($separator + 1)
    }
}

function Set-ScopedEnvironment([hashtable]$PreviousEnvironment, [System.Collections.Generic.List[string]]$Applied, [string]$Name, [string]$Value) {
    if (-not $PreviousEnvironment.ContainsKey($Name)) {
        $PreviousEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, "Process")
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        [Environment]::SetEnvironmentVariable($Name, $null, "Process")
        $Applied.Add("$Name=") | Out-Null
        return
    }

    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    $Applied.Add("$Name=$Value") | Out-Null
}

function Restore-ScopedEnvironment([hashtable]$PreviousEnvironment) {
    foreach ($entry in $PreviousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

$resolvedBaseManifest = Resolve-RepoRelativePath $BaseManifestPath
if (-not (Test-Path -LiteralPath $resolvedBaseManifest -PathType Leaf)) {
    throw "Base manifest not found: $BaseManifestPath"
}

$base = Get-Content -LiteralPath $resolvedBaseManifest -Raw | ConvertFrom-Json
$binary = [string](Get-PropertyValue $base "binary")
$commandLine = [string](Get-PropertyValue $base "commandLine")
$profileDirectory = [string](Get-PropertyValue $base "profileDirectory")
if ([string]::IsNullOrWhiteSpace($binary) -or -not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "Base manifest binary is missing or invalid: $binary"
}
if ([string]::IsNullOrWhiteSpace($commandLine) -or -not $commandLine.StartsWith($binary, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Base manifest commandLine does not start with binary path."
}
if ([string]::IsNullOrWhiteSpace($profileDirectory)) {
    throw "Base manifest has no profileDirectory."
}

$runStamp = if ([string]::IsNullOrWhiteSpace($RunId)) { (Get-Date).ToString("yyyyMMdd-HHmmss") } else { $RunId }
$caseRoot = Resolve-RepoRelativePath (Join-Path (Join-Path $OutputRoot $runStamp) $CaseId)
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

$previousEnvironment = @{}
$appliedEnvironment = New-Object System.Collections.Generic.List[string]
$assignments = New-Object System.Collections.Generic.List[object]
foreach ($entry in @((Get-PropertyValue $base "processEnvironment"))) {
    if ([string]::IsNullOrWhiteSpace([string]$entry)) {
        continue
    }
    $assignments.Add((ConvertTo-EnvironmentAssignment ([string]$entry))) | Out-Null
}
foreach ($entry in @($SetEnv)) {
    if ([string]::IsNullOrWhiteSpace($entry)) {
        continue
    }
    $assignments.Add((ConvertTo-EnvironmentAssignment $entry)) | Out-Null
}

$profileLogPath = Join-Path $profileDirectory "openmw.log"
$runLogPath = Join-Path $caseRoot "openmw.log"
$manifestPath = Join-Path $caseRoot "manifest.json"

$process = $null
$startedAt = Get-Date
try {
    foreach ($assignment in @($assignments.ToArray())) {
        Set-ScopedEnvironment -PreviousEnvironment $previousEnvironment -Applied $appliedEnvironment -Name $assignment.name -Value $assignment.value
    }

    if (Test-Path -LiteralPath $profileLogPath -PathType Leaf) {
        Remove-Item -LiteralPath $profileLogPath -Force
    }

    $argumentLine = $commandLine.Substring($binary.Length).Trim()
    Write-Host "Direct actor math run '$CaseId': $binary $argumentLine"
    $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $binary) -WindowStyle Hidden -PassThru
    $exited = $process.WaitForExit([Math]::Max(1, $RunSeconds) * 1000)
    if (-not $exited) {
        $process.Refresh()
        if (-not $process.HasExited) {
            [void]$process.CloseMainWindow()
            $exited = $process.WaitForExit(2000)
        }
    }
    if (-not $exited) {
        $process.Refresh()
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
    }
}
finally {
    if (Test-Path -LiteralPath $profileLogPath -PathType Leaf) {
        Copy-Item -LiteralPath $profileLogPath -Destination $runLogPath -Force
    }

    $exitCode = $null
    $hasExited = $false
    if ($null -ne $process) {
        $process.Refresh()
        $hasExited = [bool]$process.HasExited
        if ($hasExited) {
            $exitCode = $process.ExitCode
        }
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        worldId = [string](Get-PropertyValue $base "worldId")
        mode = [string](Get-PropertyValue $base "mode")
        createdAt = $startedAt.ToString("o")
        completedAt = (Get-Date).ToString("o")
        caseId = $CaseId
        outputDirectory = $caseRoot
        binary = $binary
        resources = [string](Get-PropertyValue $base "resources")
        profileDirectory = $profileDirectory
        commandLine = $commandLine
        startCell = [string](Get-PropertyValue $base "startCell")
        startSlice = [string](Get-PropertyValue $base "startSlice")
        runSeconds = $RunSeconds
        environmentOverrides = @($SetEnv)
        processEnvironment = @($appliedEnvironment.ToArray())
        logPath = if (Test-Path -LiteralPath $runLogPath -PathType Leaf) { $runLogPath } else { $null }
        status = if (Test-Path -LiteralPath $runLogPath -PathType Leaf) { "log-captured" } else { "missing-log" }
        pid = if ($null -ne $process) { $process.Id } else { $null }
        exited = $hasExited
        exitCode = $exitCode
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding ASCII
    Restore-ScopedEnvironment -PreviousEnvironment $previousEnvironment
}

Write-Host "Manifest: $manifestPath"
Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
