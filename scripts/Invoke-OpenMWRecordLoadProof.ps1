param(
    [Parameter(Mandatory = $true)]
    [string]$OpenMWExe,
    [Parameter(Mandatory = $true)]
    [string]$ResourcesRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet("fallout3", "fallout_new_vegas")]
    [string]$WorldId,
    [string]$ProfileDirectory = "",
    [string]$StartCell = "",
    [string]$OutputRoot = "run/openmw-record-load-proofs",
    [int]$TimeoutSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$worlds = @{
    fallout3 = [ordered]@{
        profile = "profiles/fallout3"
        start = "MegatonEntrance"
        counts = [ordered]@{
            worlds = 32; cells = 42410; refs = 568107; actors = 2154; creatures = 3349
            npcBases = 1647; creatureBases = 533; leveledNpcBases = 89; leveledCreatureBases = 60
            quests = 192; dialogueTopics = 6381; dialogueInfos = 22327; scripts = 1257
            globals = 155; formLists = 243; statics = 5803; textureSets = 244
        }
    }
    fallout_new_vegas = [ordered]@{
        profile = "profiles/fallout_new_vegas"
        start = "Goodsprings"
        counts = [ordered]@{
            worlds = 33; cells = 44517; refs = 419409; actors = 3942; creatures = 3739
            npcBases = 4220; creatureBases = 2235; leveledNpcBases = 397; leveledCreatureBases = 437
            quests = 642; dialogueTopics = 21298; dialogueInfos = 28896; scripts = 3709
            globals = 255; formLists = 608; statics = 9667; textureSets = 619
        }
    }
}

$world = $worlds[$WorldId]
if ([string]::IsNullOrWhiteSpace($ProfileDirectory)) { $ProfileDirectory = $world.profile }
if ([string]::IsNullOrWhiteSpace($StartCell)) { $StartCell = $world.start }

$exe = Resolve-RepoPath $OpenMWExe
$resources = Resolve-RepoPath $ResourcesRoot
$profile = Resolve-RepoPath $ProfileDirectory
$outputBase = Resolve-RepoPath $OutputRoot
$profileLog = Join-Path $profile "openmw.log"

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing OpenMW executable: $exe" }
if ([System.IO.Path]::GetFileName($exe) -ne "openmw.exe") { throw "Flat proof requires openmw.exe, got: $exe" }
if (-not (Test-Path -LiteralPath $resources -PathType Container)) { throw "Missing resources root: $resources" }
if (-not (Test-Path -LiteralPath (Join-Path $profile "openmw.cfg") -PathType Leaf)) {
    throw "Missing profile openmw.cfg: $profile"
}
if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 300) { throw "TimeoutSeconds must be between 1 and 300" }
if (Get-Process -Name openmw -ErrorAction SilentlyContinue) { throw "openmw.exe is already running" }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputDirectory = Join-Path $outputBase "$WorldId-$stamp"
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$startedAt = Get-Date

$previousEnvironment = @{}
foreach ($key in @([Environment]::GetEnvironmentVariables("Process").Keys)) {
    $name = [string]$key
    if ($name.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase) -or
        $name.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase)) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}

$arguments = @(
    "--replace", "config",
    "--config", $profile,
    "--resources", $resources,
    "--skip-menu",
    "--start", $StartCell
)
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
$process = $null
try {
    $process = Start-Process -FilePath $exe -ArgumentList $argumentLine `
        -WorkingDirectory (Split-Path -Parent $exe) -PassThru
}
finally {
    foreach ($key in @([Environment]::GetEnvironmentVariables("Process").Keys)) {
        $name = [string]$key
        if ($name.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase)) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
    }
}

$fields = @(
    "worlds", "cells", "refs", "actors", "creatures", "npcBases", "creatureBases",
    "leveledNpcBases", "leveledCreatureBases", "quests", "dialogueTopics", "dialogueInfos",
    "scripts", "globals", "formLists", "statics", "textureSets"
)
$fieldPattern = ($fields | ForEach-Object { "$_=(?<$($_)>\d+)" }) -join " "
$countPattern = "World viewer: ESM4 load counts offset=(?<loaded>\d+)/(?<total>\d+) $fieldPattern"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$match = $null
$logText = ""
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $profileLog -PathType Leaf) {
        $logFile = Get-Item -LiteralPath $profileLog
        if ($logFile.LastWriteTime -ge $startedAt.AddSeconds(-1)) {
            $logText = Get-Content -LiteralPath $profileLog -Raw
            $matches = [regex]::Matches($logText, $countPattern)
            if ($matches.Count -gt 0) {
                $match = $matches[$matches.Count - 1]
                $expectedReached = ([int64]$match.Groups["loaded"].Value -eq [int64]$match.Groups["total"].Value)
                foreach ($field in $fields) {
                    if ([int]$match.Groups[$field].Value -ne [int]$world.counts[$field]) {
                        $expectedReached = $false
                        break
                    }
                }
                if ($expectedReached -or $logText -match 'FNV/ESM4 proof: prepareEngine complete') {
                    break
                }
            }
        }
    }
    if ($process.HasExited) { break }
    Start-Sleep -Milliseconds 250
    $process.Refresh()
}

if ($null -ne $match -and -not $process.HasExited) {
    Start-Sleep -Seconds 2
    $null = $process.CloseMainWindow()
}
if (-not $process.HasExited -and -not $process.WaitForExit(30000)) {
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
}

if (Test-Path -LiteralPath $profileLog -PathType Leaf) {
    $logText = Get-Content -LiteralPath $profileLog -Raw
    Set-Content -LiteralPath (Join-Path $outputDirectory "openmw.log") -Value $logText -Encoding UTF8
}

$actual = [ordered]@{}
$mismatches = @()
if ($null -ne $match) {
    $loaded = [int64]$match.Groups["loaded"].Value
    $total = [int64]$match.Groups["total"].Value
    if ($loaded -ne $total) { $mismatches += "offset=$loaded/$total" }
    foreach ($field in $fields) {
        $value = [int]$match.Groups[$field].Value
        $actual[$field] = $value
        if ($value -ne [int]$world.counts[$field]) {
            $mismatches += "$field=$value expected=$($world.counts[$field])"
        }
    }
}
else {
    $mismatches += "load-count marker not observed"
}
if ($process.ExitCode -ne 0) { $mismatches += "exitCode=$($process.ExitCode)" }

$manifest = [ordered]@{
    schema = "nikami-openmw-record-load-proof/v1"
    status = if ($mismatches.Count -eq 0) { "pass" } else { "fail" }
    worldId = $WorldId
    executable = $exe -replace "\\", "/"
    executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    resources = $resources -replace "\\", "/"
    profile = $profile -replace "\\", "/"
    startCell = $StartCell
    arguments = $arguments
    startedAt = $startedAt.ToUniversalTime().ToString("o")
    endedAt = (Get-Date).ToUniversalTime().ToString("o")
    exitCode = $process.ExitCode
    expected = $world.counts
    actual = $actual
    mismatches = $mismatches
    outputDirectory = $outputDirectory -replace "\\", "/"
}
$manifestPath = Join-Path $outputDirectory "manifest.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$manifest | ConvertTo-Json -Depth 8

if ($mismatches.Count -gt 0) {
    throw "OpenMW $WorldId record-load proof failed: $($mismatches -join '; '). See $manifestPath"
}
