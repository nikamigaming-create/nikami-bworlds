param(
    [Parameter(Mandatory = $true)]
    [string]$OpenMWExe,
    [Parameter(Mandatory = $true)]
    [string]$ResourcesRoot,
    [string]$ProfileDirectory = "profiles/fallout_new_vegas",
    [string]$ScriptPath = "config/proofs/fnv-behavior-vcg02.txt",
    [string]$LoadSaveGame = "",
    [string]$StartCell = "Goodsprings",
    [string]$OutputRoot = "run/openmw-behavior-proofs",
    [int]$TimeoutSeconds = 90,
    [int]$PostGateSeconds = 0,
    [int]$QuickSaveFrame = -1,
    [string]$QuickSaveName = "FNV Quest Runtime Roundtrip",
    [switch]$ShowWindow,
    [switch]$ExpectLoadedState,
    [switch]$Wait
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

$exe = Resolve-RepoPath $OpenMWExe
$resources = Resolve-RepoPath $ResourcesRoot
$profile = Resolve-RepoPath $ProfileDirectory
$script = Resolve-RepoPath $ScriptPath
$saveGame = if ([string]::IsNullOrWhiteSpace($LoadSaveGame)) { "" } else { Resolve-RepoPath $LoadSaveGame }
$outputBase = Resolve-RepoPath $OutputRoot

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing OpenMW executable: $exe" }
if ([System.IO.Path]::GetFileName($exe) -ne "openmw.exe") { throw "Flat proof requires openmw.exe, got: $exe" }
if (-not (Test-Path -LiteralPath $resources -PathType Container)) { throw "Missing resources root: $resources" }
if (-not (Test-Path -LiteralPath (Join-Path $profile "openmw.cfg") -PathType Leaf)) {
    throw "Missing profile openmw.cfg: $profile"
}
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Missing behavior script: $script" }
if (-not [string]::IsNullOrWhiteSpace($saveGame) -and -not (Test-Path -LiteralPath $saveGame -PathType Leaf)) {
    throw "Missing save game: $saveGame"
}
if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be positive" }
if ($PostGateSeconds -lt 0 -or $PostGateSeconds -gt 60) { throw "PostGateSeconds must be between 0 and 60" }
if ($QuickSaveFrame -lt -1) { throw "QuickSaveFrame must be -1 or greater" }
if (Get-Process -Name openmw -ErrorAction SilentlyContinue) { throw "openmw.exe is already running" }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outputDirectory = Join-Path $outputBase "fnv-vcg02-$stamp"
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$profileLog = Join-Path $profile "openmw.log"
$startedAt = Get-Date
$proofEnvironment = @{}
foreach ($key in @([Environment]::GetEnvironmentVariables("Process").Keys)) {
    $name = [string]$key
    if ($name.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase) -or
        $name.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase)) {
        $proofEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}
[Environment]::SetEnvironmentVariable("OPENMW_PROOF_DELAY_STARTUP_SCRIPT", "1", "Process")
if ($QuickSaveFrame -ge 0) {
    [Environment]::SetEnvironmentVariable("OPENMW_PROOF_QUICKSAVE_FRAME", [string]$QuickSaveFrame, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_PROOF_QUICKSAVE_NAME", $QuickSaveName, "Process")
}

$arguments = @(
    "--replace", "config",
    "--config", $profile,
    "--resources", $resources,
    "--skip-menu",
    "--start", $StartCell,
    "--script-run", $script
)
if (-not [string]::IsNullOrWhiteSpace($saveGame)) {
    $arguments += @("--load-savegame", $saveGame)
}
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join " "

try {
    $startParameters = @{
        FilePath = $exe
        ArgumentList = $argumentLine
        WorkingDirectory = (Split-Path -Parent $exe)
        PassThru = $true
    }
    if (-not $ShowWindow) {
        $startParameters.WindowStyle = "Hidden"
    }
    $process = Start-Process @startParameters
}
finally {
    foreach ($key in @([Environment]::GetEnvironmentVariables("Process").Keys)) {
        $name = [string]$key
        if ($name.StartsWith("OPENMW_PROOF_", [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith("OPENMW_WORLD_VIEWER_", [StringComparison]::OrdinalIgnoreCase)) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    foreach ($entry in $proofEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
    }
}

$launch = [ordered]@{
    schema = "nikami-openmw-behavior-proof/v1"
    status = if ($Wait) { "running" } else { "launched" }
    pid = $process.Id
    startedAt = $startedAt.ToUniversalTime().ToString("o")
    executable = $exe -replace "\\", "/"
    executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    resources = $resources -replace "\\", "/"
    profile = $profile -replace "\\", "/"
    script = $script -replace "\\", "/"
    loadSaveGame = if ([string]::IsNullOrWhiteSpace($saveGame)) { $null } else { $saveGame -replace "\\", "/" }
    startCell = $StartCell
    quickSaveFrame = $QuickSaveFrame
    quickSaveName = if ($QuickSaveFrame -ge 0) { $QuickSaveName } else { $null }
    arguments = $arguments
    expected = [ordered]@{
        quest = "VCG02"
        form = "FormId:0x10a214"
        stage = 5
        flags = 33
        stageDone = 1
        entryExecuted = 1
    }
    outputDirectory = $outputDirectory -replace "\\", "/"
}

if (-not $Wait) {
    $launch | ConvertTo-Json -Depth 8
    exit 0
}

$gatePattern = if ($ExpectLoadedState) {
    'FNV/ESM4 behavior: LoadedQuestState quest=VCG02 form=FormId:0x(?<form>[0-9a-fA-F]+) stage=5 flags=33 active=1 doneStages=1 objectives=1'
} else {
    'FNV/ESM4 behavior: SetStage quest=VCG02 form=FormId:0x(?<form>[0-9a-fA-F]+) stage=5 flags=33 done=1 entryExecuted=1'
}
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$matched = $false
$matchedInternalForm = $null
$logText = ""
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $profileLog -PathType Leaf) {
        $logFile = Get-Item -LiteralPath $profileLog
        if ($logFile.LastWriteTime -ge $startedAt.AddSeconds(-1)) {
            $logText = Get-Content -LiteralPath $profileLog -Raw
            foreach ($candidate in [regex]::Matches($logText, $gatePattern)) {
                $internalForm = [Convert]::ToUInt32($candidate.Groups["form"].Value, 16)
                if (($internalForm -band 0x00ffffff) -eq 0x0010a214) {
                    $matched = $true
                    $matchedInternalForm = "FormId:0x$($candidate.Groups['form'].Value)"
                    break
                }
            }
            if ($matched) { break }
        }
    }
    if ($process.HasExited) { break }
    Start-Sleep -Milliseconds 250
    $process.Refresh()
}

if ($matched -and $PostGateSeconds -gt 0 -and -not $process.HasExited) {
    Start-Sleep -Seconds $PostGateSeconds
    $process.Refresh()
}

if (-not $process.HasExited) {
    $null = $process.CloseMainWindow()
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}

if (Test-Path -LiteralPath $profileLog -PathType Leaf) {
    $logText = Get-Content -LiteralPath $profileLog -Raw
    Set-Content -LiteralPath (Join-Path $outputDirectory "openmw.log") -Value $logText -Encoding UTF8
}

$launch.status = if ($matched -and $process.ExitCode -eq 0) { "pass" } elseif ($matched) { "matched-nonzero-exit" } else { "fail" }
$launch.endedAt = (Get-Date).ToUniversalTime().ToString("o")
$launch.exitCode = $process.ExitCode
$launch.gateMatched = $matched
$launch.actualInternalForm = $matchedInternalForm
$manifestPath = Join-Path $outputDirectory "manifest.json"
$launch | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
$launch | ConvertTo-Json -Depth 8

if (-not $matched) { throw "OpenMW behavior gate was not observed before exit/timeout. See $manifestPath" }
if ($process.ExitCode -ne 0) { throw "OpenMW exited with code $($process.ExitCode). See $manifestPath" }
