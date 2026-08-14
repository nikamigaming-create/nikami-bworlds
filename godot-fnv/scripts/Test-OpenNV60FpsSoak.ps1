param(
    [string]$Godot = 'D:\code\gd\Godot_v4.6.3-stable_win64_console.exe',
    [ValidateRange(5, 1800)][int]$DurationSeconds = 30,
    [ValidateRange(7, 250)][int]$SpeedMetersPerSecond = 100,
    [ValidateRange(1, 500)][int]$MinimumCrossings = 8,
    [switch]$Headless
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $projectRoot 'local\performance'
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $outputRoot "opennv-60fps-soak-$stamp.json"
if (Test-Path -LiteralPath $reportPath) { throw "Refusing to overwrite $reportPath" }

$beforeIds = @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue | ForEach-Object Id)
$start = Get-Date
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$launchGodot = $Godot -replace '_console\.exe$', '.exe'
if (-not (Test-Path -LiteralPath $launchGodot -PathType Leaf)) { $launchGodot = $Godot }
$startInfo.FileName = $launchGodot
$startInfo.WorkingDirectory = Split-Path -Parent $projectRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$quotedProjectRoot = '"' + $projectRoot.Replace('"', '\"') + '"'
$startInfo.Arguments = if ($Headless) { "--headless --path $quotedProjectRoot" } else { "--path $quotedProjectRoot" }
$startInfo.Environment['FNV_GODOT_PERF_SOAK'] = '1'
$startInfo.Environment['FNV_GODOT_PERF_SECONDS'] = [string]$DurationSeconds
$startInfo.Environment['FNV_GODOT_PERF_SPEED'] = [string]$SpeedMetersPerSecond
$startInfo.Environment['FNV_GODOT_PERF_MIN_CROSSINGS'] = [string]$MinimumCrossings
$startInfo.Environment['FNV_GODOT_PERF_REPORT'] = $reportPath.Replace('\', '/')
$startInfo.Environment['FNV_GODOT_DISABLE_AUDIO'] = '1'
if ($Headless) {
    $startInfo.Environment['FNV_GODOT_PERF_HEADLESS'] = '1'
    $startInfo.Environment['FNV_GODOT_FORCE_SYNC_LOAD'] = '1'
}

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
[void]$process.Start()
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$timeoutMilliseconds = ($DurationSeconds + 180) * 1000
if (-not $process.WaitForExit($timeoutMilliseconds)) {
    $process.Kill()
    $process.WaitForExit()
    $newProcesses = @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -notin $beforeIds -and $_.StartTime -ge $start
    })
    $newProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
    $timeoutOutput = ($stdoutTask.Result + [Environment]::NewLine + $stderrTask.Result)
    throw "OpenNV performance soak timed out after $($DurationSeconds + 180) seconds.`n$($timeoutOutput.Substring([Math]::Max(0, $timeoutOutput.Length - 12000)))"
}
$process.WaitForExit()
$processOutput = $stdoutTask.Result + [Environment]::NewLine + $stderrTask.Result

# Godot's Windows console shim and render child can outlive the primary process
# briefly while RenderingServer tears down. Give orderly shutdown a bounded
# grace period before classifying a real leak.
$shutdownDeadline = (Get-Date).AddSeconds(30)
do {
    $newProcesses = @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue | Where-Object {
        $_.Id -notin $beforeIds -and $_.StartTime -ge $start
    })
    if ($newProcesses.Count -eq 0) { break }
    Start-Sleep -Milliseconds 100
} while ((Get-Date) -lt $shutdownDeadline)

$newProcesses = @(Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue | Where-Object {
    $_.Id -notin $beforeIds -and $_.StartTime -ge $start
})
if ($newProcesses.Count -gt 0) {
    $newProcesses | Stop-Process
    throw "Godot leaked $($newProcesses.Count) process(es) after the performance run."
}
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
    throw "OpenNV performance soak failed with exit $($process.ExitCode).`n$($processOutput.Substring([Math]::Max(0, $processOutput.Length - 12000)))"
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if ($report.schema -ne 'opennv-godot-streaming-soak/v2') {
    throw "Unexpected OpenNV performance schema: $($report.schema)"
}
$expectedStatus = if ($Headless) { 'diagnostic-pass' } else { 'pass' }
if ($report.status -ne $expectedStatus) {
    throw "OpenNV 60 FPS acceptance failed: $reportPath"
}
if ([bool]$report.headless -ne [bool]$Headless) {
    throw 'Performance report execution mode does not match the requested mode.'
}
if ([math]::Abs([double]$report.configuredDurationSeconds - $DurationSeconds) -gt 0.01 -or
    [math]::Abs([double]$report.speedMetersPerSecond - $SpeedMetersPerSecond) -gt 0.01 -or
    [int]$report.thresholds.minimumCrossings -ne $MinimumCrossings) {
    throw 'Performance report arguments do not match the requested run.'
}
if (-not [bool]$report.workloadValid -or [int]$report.crossings -lt $MinimumCrossings -or
    [double]$report.frameMsec.p99 -gt 16.7 -or [double]$report.crossingFrameMsec.max -gt 33.3 -or
    [int]$report.frameMsec.over50 -ne 0 -or [int]$report.streaming.max_stream_commit_usec -gt 2000 -or
    [int]$report.streaming.max_focus_update_usec -gt 2000 -or
    [double]$report.memoryDriftPercent -gt 10.0 -or [int]$report.maxMissingActors -ne 0 -or
    [int]$report.streaming.actor_lifecycle_invariant_violations -ne 0 -or
    [int]$report.streaming.actor_load_quarantined -ne 0 -or
	[int]$report.streaming.unsupported_model_instances -ne 0 -or
	[int]$report.streaming.mesh_load_failures -ne 0 -or [int]$report.streaming.skeletal_cache_failures -ne 0 -or
	-not [bool]$report.streaming.world_mesh_cache_contract_valid -or
	[int]$report.streaming.world_mesh_cache_fallback_paths -ne 0 -or
	-not [bool]$report.streaming.terrain_mesh_cache_contract_valid -or
	[int]$report.streaming.terrain_mesh_cache_fallback_paths -ne 0 -or
	[int]$report.streaming.pending_meshes -ne 0 -or
    [int]$report.streaming.waiting_mesh_paths -ne 0 -or [int]$report.streaming.ready_mesh_paths -ne 0 -or
	[int]$report.streaming.pending_skeletal_actors -ne 0 -or
	[int]$report.streaming.pending_exterior_cell_jobs -ne 0 -or [int]$report.streaming.pending_focus_scan -ne 0 -or
	[int]$report.streaming.pending_interior_stage_jobs -ne 0 -or
	[int]$report.streaming.pending_exterior_retire_jobs -ne 0 -or
	[int]$report.streaming.pending_navmesh_cell_jobs -ne 0 -or
    [double]$report.frameMsec.max -gt 33.3) {
    throw 'Independent 60 FPS threshold validation failed.'
}
if (-not $Headless -and $report.displayServer -eq 'headless') {
    throw 'A headless run cannot promote desktop rendering performance.'
}
if (-not $Headless -and (-not [bool]$report.expectedRenderer -or $report.renderingMethod -ne 'mobile' -or
    $report.renderingDriver -ne 'vulkan')) {
    throw 'Only the Vulkan mobile renderer can promote OpenNV desktop/VR performance.'
}
$report | ConvertTo-Json -Depth 12
Write-Host "OPENNV_60FPS_SOAK_$($expectedStatus.ToUpperInvariant().Replace('-', '_')) report=$reportPath"
