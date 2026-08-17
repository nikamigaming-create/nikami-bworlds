[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SimulatorDataDirectory,
    [float]$PosX = 0.0,
    [float]$PosY = 1.7,
    [float]$PosZ = 0.0,
    [float]$Yaw = 0.0,
    [float]$Pitch = 0.0,
    [float]$Roll = 0.0,
    [switch]$SetRoll,
    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd(
    [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$SimulatorDataDirectory = [IO.Path]::GetFullPath($SimulatorDataDirectory)
if (-not $SimulatorDataDirectory.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "SimulatorDataDirectory must be inside this repository."
}
if (-not (Test-Path -LiteralPath $SimulatorDataDirectory -PathType Container)) {
    throw "Simulator data directory does not exist: $SimulatorDataDirectory"
}

$ackPath = Join-Path $SimulatorDataDirectory "command_ack.json"
$command = [ordered]@{ x = $PosX; y = $PosY; z = $PosZ; yaw = $Yaw; pitch = $Pitch }
if ($SetRoll) { $command.roll = $Roll }
$commandPath = Join-Path $SimulatorDataDirectory "head_pose_command.json"
$temporaryPath = "$commandPath.tmp"

# The simulator uses one one-shot acknowledgement file for all commands. Clear
# the previous acknowledgement before publishing this command so a newly
# created matching file is authoritative. Filesystem timestamp precision is
# not reliable enough to order this IPC handshake against DateTime.UtcNow.
if (Test-Path -LiteralPath $ackPath -PathType Leaf) {
    Remove-Item -LiteralPath $ackPath -Force
}

$started = [DateTime]::UtcNow
[IO.File]::WriteAllText($temporaryPath, ($command | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporaryPath -Destination $commandPath -Force

$deadline = $started.AddSeconds($TimeoutSeconds)
do {
    if (Test-Path -LiteralPath $ackPath -PathType Leaf) {
        $ackItem = Get-Item -LiteralPath $ackPath
        $ack = Get-Content -LiteralPath $ackPath -Raw | ConvertFrom-Json
        if ($ack.command -eq "head_pose" -and [bool]$ack.success) {
            [pscustomobject]@{ status = "pass"; command = $command; acknowledgedUtc = $ackItem.LastWriteTimeUtc.ToString("o") }
            exit 0
        }
    }
    Start-Sleep -Milliseconds 50
} while ([DateTime]::UtcNow -lt $deadline)

throw "Simulator did not acknowledge the head pose within $TimeoutSeconds seconds."
