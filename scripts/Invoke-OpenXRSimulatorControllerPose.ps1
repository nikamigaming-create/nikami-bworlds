[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SimulatorDataDirectory,
    [ValidateSet("left", "right")]
    [string]$Hand = "right",
    [float]$PosX = 0.2,
    [float]$PosY = -0.3,
    [float]$PosZ = -0.4,
    [float]$Yaw = 0.0,
    [float]$Pitch = -0.3,
    [float]$Roll = 0.0,
    [ValidateRange(0.0, 1.0)]
    [float]$Trigger = 0.0,
    [ValidateRange(0.0, 1.0)]
    [float]$Grip = 0.0,
    [ValidateRange(0, 1)]
    [int]$ButtonA = 0,
    [ValidateRange(0, 1)]
    [int]$ButtonB = 0,
    [ValidateRange(0, 1)]
    [int]$Menu = 0,
    [ValidateRange(0, 1)]
    [int]$ThumbstickClick = 0,
    [ValidateRange(-1.0, 1.0)]
    [float]$ThumbstickX = 0.0,
    [ValidateRange(-1.0, 1.0)]
    [float]$ThumbstickY = 0.0,
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
$command = [ordered]@{
    hand = if ($Hand -eq "left") { 0 } else { 1 }
    posX = $PosX; posY = $PosY; posZ = $PosZ
    yaw = $Yaw; pitch = $Pitch; roll = $Roll
    trigger = $Trigger; grip = $Grip
    buttonA = $ButtonA; buttonB = $ButtonB; menu = $Menu; thumbstickClick = $ThumbstickClick
    thumbstickX = $ThumbstickX; thumbstickY = $ThumbstickY
}
$commandPath = Join-Path $SimulatorDataDirectory "controller_pose_command.json"
$temporaryPath = "$commandPath.tmp"

# The simulator uses one one-shot acknowledgement file for all commands. Clear
# the previous acknowledgement before publishing this command so a newly
# created matching file is authoritative. Do not compare filesystem timestamps
# with DateTime.UtcNow here: NTFS/file-cache timestamp precision can make a
# successfully rewritten acknowledgement appear a few ticks older than the
# command start time.
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
        if ($ack.command -eq "controller_pose" -and [bool]$ack.success) {
            [pscustomobject]@{ status = "pass"; command = $command; acknowledgedUtc = $ackItem.LastWriteTimeUtc.ToString("o") }
            exit 0
        }
    }
    Start-Sleep -Milliseconds 50
} while ([DateTime]::UtcNow -lt $deadline)

throw "Simulator did not acknowledge the controller pose within $TimeoutSeconds seconds."
