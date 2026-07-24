[CmdletBinding()]
param(
    [string]$OpenMWExe = "../nikami-openmw-save330-integrated/MSVC2022_64/RelWithDebInfo/openmw.exe",
    [string]$ResourcesRoot = "../nikami-openmw-save330-integrated/MSVC2022_64/RelWithDebInfo/resources",
    [string]$ProfileDirectory = "run/fnv-save330-integrated-capture-02/config",
    [string]$MorrowindProfileDirectory = "../nikami-worlds/profiles/morrowind",
    [string]$SavePath = "",
    [string]$OutputRoot = "run/fnv-goodsprings-actor-audit",
    [ValidateRange(60, 600)]
    [int]$TimeoutSeconds = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ConfigValue([string]$ConfigPath, [string]$Key) {
    foreach ($line in Get-Content -LiteralPath $ConfigPath) {
        if ($line -match ('^\s*' + [Regex]::Escape($Key) + '\s*=\s*(.+?)\s*$')) {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

if ([string]::IsNullOrWhiteSpace($SavePath)) {
    $saveDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games/FalloutNV/Saves'
    $save = Get-ChildItem -LiteralPath $saveDirectory -Filter '*.fos' -File -ErrorAction Stop |
        Where-Object { $_.Name -match '^Save 330\b' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -eq $save) { throw "No Save 330 Fallout: New Vegas save was found in $saveDirectory" }
    $SavePath = $save.FullName
}

$exe = Resolve-RepoPath $OpenMWExe
$resources = Resolve-RepoPath $ResourcesRoot
$profile = Resolve-RepoPath $ProfileDirectory
$morrowindProfile = Resolve-RepoPath $MorrowindProfileDirectory
$saveFile = Resolve-RepoPath $SavePath
$outputBase = Resolve-RepoPath $OutputRoot
$baselineConfig = Resolve-RepoPath 'config/playable-baseline'
$graphicsConfig = Resolve-RepoPath 'config/fnv-playable-graphics'
$doorConfig = Resolve-RepoPath 'config/door-preload'

foreach ($path in @($exe, $saveFile, (Join-Path $profile 'openmw.cfg'),
        (Join-Path $morrowindProfile 'openmw.cfg'), (Join-Path $baselineConfig 'settings.cfg'),
        (Join-Path $graphicsConfig 'settings.cfg'), (Join-Path $doorConfig 'settings.cfg'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing Goodsprings actor-audit input: $path"
    }
}
if (-not (Test-Path -LiteralPath $resources -PathType Container)) {
    throw "Missing OpenMW resources directory: $resources"
}
if (Get-Process -Name openmw,openmw_vr -ErrorAction SilentlyContinue) {
    throw 'OpenMW is already running; the hidden audit will not interfere with an existing session.'
}

$morrowindData = Get-ConfigValue (Join-Path $morrowindProfile 'openmw.cfg') 'data'
if ([string]::IsNullOrWhiteSpace($morrowindData)) {
    throw 'The shared Morrowind UI data path is absent from its profile.'
}
$morrowindData = [IO.Path]::GetFullPath($morrowindData)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$output = Join-Path $outputBase $stamp
$sessionConfig = Join-Path $output 'session-config'
$sessionUserData = Join-Path $output 'user-data'
New-Item -ItemType Directory -Path $sessionConfig,$sessionUserData -Force | Out-Null
Set-Content -LiteralPath (Join-Path $sessionConfig 'openmw.cfg') -Encoding utf8 `
    -Value ('user-data="{0}"' -f ($sessionUserData -replace '\\', '/'))
Set-Content -LiteralPath (Join-Path $sessionConfig 'settings.cfg') -Encoding ascii -Value @(
    '[Video]'
    'resolution x = 1920'
    'resolution y = 1080'
    'fullscreen = false'
    'window border = false'
)

$arguments = @(
    '--replace', 'config', '--config', $profile, '--config', $baselineConfig,
    '--config', $graphicsConfig, '--config', $doorConfig, '--config', $sessionConfig,
    '--user-data', $sessionUserData, '--resources', $resources, '--data', $morrowindData,
    '--fallback-archive', 'Morrowind.bsa', '--skip-menu', '--load-savegame', $saveFile
)
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' '

$environment = [ordered]@{
    OPENMW_FNV_GOODSPRINGS_ACTOR_AUDIT = '1'
    OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI = '1'
    OPENMW_WORLD_VIEWER_TELEMETRY = '0'
    OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY = '0'
    OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG = '1'
    OPENMW_DISABLE_CRASH_CATCHER = '1'
    OPENMW_DEBUG_LEVEL = 'VERBOSE'
}
$prefixes = @('OPENMW_WORLD_VIEWER_', 'OPENMW_PROOF_', 'OPENMW_FNV_', 'OPENMW_ESM4_', 'OPENMW_PLAYABLE_')
$previous = @{}
foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys | ForEach-Object { [string]$_ })) {
    if ($prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
}

$stdout = Join-Path $output 'stdout.log'
$stderr = Join-Path $output 'stderr.log'
$process = $null
$timedOut = $false
try {
    foreach ($entry in $environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $exe
    $startInfo.Arguments = $argumentLine
    $startInfo.WorkingDirectory = Split-Path -Parent $exe
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start hidden Goodsprings actor audit.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $process.WaitForExit(250) | Out-Null
    }
    if (-not $process.HasExited) {
        $timedOut = $true
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit(5000) | Out-Null
    }
    if ($process.HasExited) { $process.WaitForExit() }
    [IO.File]::WriteAllText($stdout, $stdoutTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderr, $stderrTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
}
finally {
    foreach ($name in @([Environment]::GetEnvironmentVariables('Process').Keys | ForEach-Object { [string]$_ })) {
        if ($prefixes | Where-Object { $name.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }
    foreach ($entry in $previous.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, 'Process')
    }
}

$profileLog = Join-Path $sessionConfig 'openmw.log'
if (Test-Path -LiteralPath $profileLog) {
    Copy-Item -LiteralPath $profileLog -Destination (Join-Path $output 'openmw.log') -Force
}
$logText = ''
foreach ($path in @($stdout, $stderr, (Join-Path $output 'openmw.log'))) {
    if (Test-Path -LiteralPath $path) { $logText += "`n" + (Get-Content -LiteralPath $path -Raw) }
}

$summary = [Regex]::Match($logText,
    'FNV Goodsprings actor audit: result=(?<result>pass|fail) passed=(?<passed>\d+) total=(?<total>\d+) failures="(?<failures>[^"]*)"')
$targetMatches = [Regex]::Matches($logText,
    'FNV Goodsprings actor audit: target=(?<target>[^ ]+) ref=(?<ref>FormId:0x[0-9a-f]+) result=(?<result>pass|fail) reason="(?<reason>[^"]*)"[^\r\n]*',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase)
$targetRows = @($targetMatches | ForEach-Object {
    [pscustomobject][ordered]@{
        target = $_.Groups['target'].Value
        reference = $_.Groups['ref'].Value
        result = $_.Groups['result'].Value.ToLowerInvariant()
        reason = $_.Groups['reason'].Value.Trim()
        telemetry = $_.Value
    }
})
$targetsByReference = [ordered]@{}
foreach ($target in $targetRows) {
    # OpenMW writes the same structured line to stdout and openmw.log. Keep the latest copy of each
    # authored reference so the gate counts actors, not logging sinks.
    $targetsByReference[[string]$target.reference] = $target
}
$targets = @($targetsByReference.Values)
$screenshot = Get-ChildItem -LiteralPath (Join-Path $sessionUserData 'screenshots') -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc,Name | Select-Object -First 1
$capture = $null
if ($null -ne $screenshot) {
    $capture = Join-Path $output ('victor-facing' + $screenshot.Extension.ToLowerInvariant())
    Copy-Item -LiteralPath $screenshot.FullName -Destination $capture -Force
}

$exitCode = if ($null -ne $process -and $process.HasExited) { $process.ExitCode } else { $null }
$pass = -not $timedOut -and $exitCode -eq 0 -and $summary.Success -and
    $summary.Groups['result'].Value -eq 'pass' -and $targets.Count -eq 11
$result = [pscustomobject][ordered]@{
    schema = 'nikami-fnv-goodsprings-actor-audit/v1'
    pass = $pass
    executable = $exe -replace '\\', '/'
    executableSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    save = $saveFile -replace '\\', '/'
    saveSha256 = (Get-FileHash -LiteralPath $saveFile -Algorithm SHA256).Hash.ToLowerInvariant()
    output = $output -replace '\\', '/'
    timedOut = $timedOut
    exitCode = $exitCode
    passedTargets = if ($summary.Success) { [int]$summary.Groups['passed'].Value } else { 0 }
    totalTargets = if ($summary.Success) { [int]$summary.Groups['total'].Value } else { 0 }
    failures = if ($summary.Success) { $summary.Groups['failures'].Value } else { 'summary-missing' }
    targets = $targets
    victorCapture = if ($null -ne $capture) { $capture -replace '\\', '/' } else { $null }
    foregroundInputUsed = $false
    actorsMovedOrEnabledByHarness = $false
}
$resultPath = Join-Path $output 'result.json'
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
$result | ConvertTo-Json -Depth 8
if (-not $pass) { throw "FNV Goodsprings actor audit failed; see $resultPath" }
