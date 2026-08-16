[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SimulatorDataDirectory,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,
    [ValidateSet("left", "right", "both")]
    [string]$Eye = "left",
    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd(
    [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$SimulatorDataDirectory = [IO.Path]::GetFullPath($SimulatorDataDirectory)
$DestinationPath = [IO.Path]::GetFullPath($DestinationPath)
if (-not $SimulatorDataDirectory.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not $DestinationPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Simulator data and evidence output must stay inside this repository."
}
if (-not (Test-Path -LiteralPath $SimulatorDataDirectory -PathType Container)) {
    throw "Simulator data directory does not exist: $SimulatorDataDirectory"
}
if (Test-Path -LiteralPath $DestinationPath) {
    throw "Refusing to overwrite an existing evidence frame: $DestinationPath"
}

$statusPath = Join-Path $SimulatorDataDirectory "screenshot_status.json"
$sourcePath = Join-Path $SimulatorDataDirectory "screenshot.bmp"
$started = [DateTime]::UtcNow
$requestPath = Join-Path $SimulatorDataDirectory "screenshot_request.json"
$temporaryPath = "$requestPath.tmp"
[IO.File]::WriteAllText($temporaryPath, (@{ eye = $Eye; layer = "projection" } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporaryPath -Destination $requestPath -Force

$deadline = $started.AddSeconds($TimeoutSeconds)
do {
    if ((Test-Path -LiteralPath $statusPath -PathType Leaf) -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        $statusItem = Get-Item -LiteralPath $statusPath
        if ($statusItem.LastWriteTimeUtc -ge $started) {
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            if ($status.layer -eq "projection-eye-source" -and $status.eye -eq $Eye) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null
                Copy-Item -LiteralPath $sourcePath -Destination $DestinationPath -ErrorAction Stop
                [pscustomobject]@{ status = "pass"; source = "projection-eye-source"; frame = $status.capturedFrame; path = $DestinationPath }
                exit 0
            }
        }
    }
    Start-Sleep -Milliseconds 50
} while ([DateTime]::UtcNow -lt $deadline)

throw "Simulator did not return a native $Eye eye frame within $TimeoutSeconds seconds."
