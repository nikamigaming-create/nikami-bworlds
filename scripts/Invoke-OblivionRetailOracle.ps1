[CmdletBinding()]
param(
    [string]$GameRoot = "D:\SteamLibrary\steamapps\common\Oblivion",
    [string]$PluginDll = "external\xobse\nikami_oblivion_oracle\build\nikami_oblivion_oracle.dll",
    [string]$BackgroundGuardDll = "external\xobse\nikami_oblivion_hidden\build\nikami_oblivion_hidden.dll",
    [string]$HiddenLoader = "external\xobse\obse\loader\Release\loader.exe",
    [string]$OutputPath = "run\retail-oracle\oblivion-palace-animation-v1.jsonl",
    [string]$SaveName = "",
    [string]$StartCell = "ICPalace03",
    [string]$TargetForm = "0x00132A9B",
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 90,
    [ValidateRange(30, 600)]
    [int]$SettleFrames = 90,
    [ValidateRange(30, 900)]
    [int]$MaxFrames = 150,
    [ValidateRange(1, 120)]
    [int]$SampleEvery = 5,
    [switch]$KeepInstalledPlugins
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Assert-ChildPath([string]$Parent, [string]$Child) {
    $resolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $resolvedChild = [System.IO.Path]::GetFullPath($Child)
    if (-not $resolvedChild.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing filesystem operation outside $resolvedParent`: $resolvedChild"
    }
}

function Remove-OracleFileWithRetry([string]$Path, [int]$Attempts = 24) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq $Attempts) {
                throw
            }
            Start-Sleep -Milliseconds 250
        }
    }
}

if ($TargetForm -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$') {
    throw "TargetForm must be decimal or 0x-prefixed hexadecimal: $TargetForm"
}
if ($MaxFrames -lt $SettleFrames) {
    throw "MaxFrames must be greater than or equal to SettleFrames."
}

$gameRootPath = Resolve-AbsolutePath $GameRoot
$sourcePlugin = Resolve-AbsolutePath $PluginDll
$sourceBackgroundGuard = Resolve-AbsolutePath $BackgroundGuardDll
$sourceLoader = Resolve-AbsolutePath $HiddenLoader
$output = Resolve-AbsolutePath $OutputPath
$gameExe = Join-Path $gameRootPath "Oblivion.exe"
$runtimeDll = Join-Path $gameRootPath "obse_1_2_416.dll"
$pluginDirectory = Join-Path $gameRootPath "Data\OBSE\Plugins"
$pluginBackupDirectory = Join-Path $gameRootPath ".nikami-obse-plugins-backup-$PID"
$installedPlugin = Join-Path $pluginDirectory "nikami_oblivion_oracle.dll"
$installedLoader = Join-Path $gameRootPath "obse_loader_nikami_oracle.exe"
$installedBackgroundGuard = Join-Path $gameRootPath "nikami_oblivion_hidden.dll"
$documentsRoot = [Environment]::GetFolderPath("MyDocuments")
$oblivionIni = Join-Path $documentsRoot "My Games\Oblivion\Oblivion.ini"
$iniBackup = "$oblivionIni.nikami-backup-$PID"
$saveDirectory = Join-Path $documentsRoot "My Games\Oblivion\Saves"
$saveFile = if ([string]::IsNullOrWhiteSpace($SaveName)) { $null } else { Join-Path $saveDirectory ("{0}.ess" -f $SaveName) }
$fixtureSaveName = "NikamiOblivionOracle$PID"
$fixtureSave = Join-Path $saveDirectory "$fixtureSaveName.ess"
$sourceCosave = if ($null -eq $saveFile) { $null } else { [System.IO.Path]::ChangeExtension($saveFile, ".obse") }
$fixtureCosave = Join-Path $saveDirectory "$fixtureSaveName.obse"

foreach ($required in @($gameExe, $runtimeDll, $sourcePlugin, $sourceBackgroundGuard, $sourceLoader, $oblivionIni)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing required Oblivion oracle file: $required"
    }
}
if ($null -ne $saveFile -and -not (Test-Path -LiteralPath $saveFile -PathType Leaf)) {
    throw "Missing requested Oblivion save: $saveFile"
}
if ($null -eq $saveFile -and [string]::IsNullOrWhiteSpace($StartCell)) {
    throw "Specify either SaveName or StartCell."
}
if (Get-Process -Name "Oblivion" -ErrorAction SilentlyContinue) {
    throw "Oblivion is already running; refusing to touch a user-owned process."
}
foreach ($temporary in @($pluginBackupDirectory, $installedLoader, $installedBackgroundGuard, $iniBackup)) {
    if (Test-Path -LiteralPath $temporary) {
        throw "Refusing to overwrite stale Oblivion oracle state: $temporary"
    }
}
foreach ($fixture in @($fixtureSave, $fixtureCosave)) {
    if (Test-Path -LiteralPath $fixture) {
        throw "Refusing to overwrite stale Oblivion oracle save fixture: $fixture"
    }
}

Assert-ChildPath $gameRootPath $pluginDirectory
Assert-ChildPath $gameRootPath $pluginBackupDirectory
Assert-ChildPath $gameRootPath $installedLoader
Assert-ChildPath $gameRootPath $installedBackgroundGuard
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Force
}

if (-not ('Nikami.OracleWindowAudit' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Nikami {
    public static class OracleWindowAudit {
        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
    }
}
'@
}

$environment = [ordered]@{
    NIKAMI_OBLIVION_ORACLE_HIDDEN = "1"
    NIKAMI_OBLIVION_ORACLE_GUARD_DLL = $installedBackgroundGuard
    NIKAMI_OBLIVION_ORACLE_OUTPUT = $output
    NIKAMI_OBLIVION_ORACLE_SAVE = if ($null -ne $saveFile) { $fixtureSaveName } else { "" }
    NIKAMI_OBLIVION_ORACLE_START_CELL = $StartCell
    NIKAMI_OBLIVION_ORACLE_TARGET_FORM = $TargetForm
    NIKAMI_OBLIVION_ORACLE_SAMPLE_EVERY = [string]$SampleEvery
    NIKAMI_OBLIVION_ORACLE_SETTLE_FRAMES = [string]$SettleFrames
    NIKAMI_OBLIVION_ORACLE_MAX_FRAMES = [string]$MaxFrames
}
$previousEnvironment = @{}
$hadPluginDirectory = Test-Path -LiteralPath $pluginDirectory -PathType Container
$isolatedPlugins = -not $KeepInstalledPlugins
$gameProcess = $null
$loaderProcess = $null
$visibleViolation = $false
$foregroundViolation = $false
$timedOut = $false
$exitCode = $null

try {
    if ($isolatedPlugins -and $hadPluginDirectory) {
        Move-Item -LiteralPath $pluginDirectory -Destination $pluginBackupDirectory
    }
    New-Item -ItemType Directory -Force -Path $pluginDirectory | Out-Null
    if (Test-Path -LiteralPath $installedPlugin) {
        throw "Oracle plugin name already exists after isolation: $installedPlugin"
    }
    Copy-Item -LiteralPath $sourcePlugin -Destination $installedPlugin
    Copy-Item -LiteralPath $sourceBackgroundGuard -Destination $installedBackgroundGuard
    Copy-Item -LiteralPath $sourceLoader -Destination $installedLoader
    if ($null -ne $saveFile) {
        Copy-Item -LiteralPath $saveFile -Destination $fixtureSave
    }
    if ($null -ne $sourceCosave -and (Test-Path -LiteralPath $sourceCosave -PathType Leaf)) {
        Copy-Item -LiteralPath $sourceCosave -Destination $fixtureCosave
    }

    Copy-Item -LiteralPath $oblivionIni -Destination $iniBackup
    $iniText = Get-Content -LiteralPath $oblivionIni -Raw
    $iniText = [Regex]::Replace($iniText, '(?im)^bFull Screen\s*=.*$', 'bFull Screen=0')
    $iniText = [Regex]::Replace($iniText, '(?im)^iSize W\s*=.*$', 'iSize W=800')
    $iniText = [Regex]::Replace($iniText, '(?im)^iSize H\s*=.*$', 'iSize H=600')
    Set-Content -LiteralPath $oblivionIni -Value $iniText -Encoding Default -NoNewline

    foreach ($entry in $environment.GetEnumerator()) {
        $previousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, "Process")
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }

    $startedAt = Get-Date
    $loaderProcess = Start-Process -FilePath $installedLoader -WorkingDirectory $gameRootPath `
        -WindowStyle Hidden -PassThru
    $launchDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $launchDeadline -and $null -eq $gameProcess) {
        $gameProcess = Get-Process -Name "Oblivion" -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
            Select-Object -First 1
        if ($null -eq $gameProcess) {
            Start-Sleep -Milliseconds 50
        }
    }
    if ($null -eq $gameProcess) {
        throw "Hidden OBSE loader did not create Oblivion within 20 seconds (loader PID $($loaderProcess.Id))."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $gameProcess.Refresh()
        if ($gameProcess.HasExited) { break }
        $window = $gameProcess.MainWindowHandle
        if ($window -ne [IntPtr]::Zero) {
            if ([Nikami.OracleWindowAudit]::IsWindowVisible($window)) {
                $visibleViolation = $true
                Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
                throw "Background-safety violation: the oracle window became visible. The launched PID was terminated."
            }
            if ([Nikami.OracleWindowAudit]::GetForegroundWindow() -eq $window) {
                $foregroundViolation = $true
                Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
                throw "Background-safety violation: the oracle window became foreground. The launched PID was terminated."
            }
        }
        $gameProcess.WaitForExit(100) | Out-Null
    }
    $gameProcess.Refresh()
    if (-not $gameProcess.HasExited) {
        $timedOut = $true
        Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
        $gameProcess.WaitForExit(5000) | Out-Null
        throw "Oblivion retail oracle timed out after $TimeoutSeconds seconds."
    }
    try { $exitCode = $gameProcess.ExitCode } catch { $exitCode = $null }
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "Oblivion retail oracle exited with code $exitCode."
    }
}
finally {
    if ($null -ne $gameProcess) {
        try {
            $gameProcess.Refresh()
            if (-not $gameProcess.HasExited) {
                Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    foreach ($entry in $environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $previousEnvironment[$entry.Key], "Process")
    }
    if (Test-Path -LiteralPath $iniBackup -PathType Leaf) {
        Copy-Item -LiteralPath $iniBackup -Destination $oblivionIni -Force
        Remove-OracleFileWithRetry $iniBackup
    }
    if (Test-Path -LiteralPath $installedLoader -PathType Leaf) {
        Remove-OracleFileWithRetry $installedLoader
    }
    if (Test-Path -LiteralPath $installedBackgroundGuard -PathType Leaf) {
        Remove-OracleFileWithRetry $installedBackgroundGuard
    }
    foreach ($fixture in @($fixtureSave, $fixtureCosave)) {
        if (Test-Path -LiteralPath $fixture -PathType Leaf) {
            Remove-OracleFileWithRetry $fixture
        }
    }
    if ($isolatedPlugins) {
        if (Test-Path -LiteralPath $pluginDirectory -PathType Container) {
            Assert-ChildPath $gameRootPath $pluginDirectory
            if (Test-Path -LiteralPath $installedPlugin -PathType Leaf) {
                Remove-OracleFileWithRetry $installedPlugin
            }
            Remove-Item -LiteralPath $pluginDirectory -Recurse -Force
        }
        if ($hadPluginDirectory -and (Test-Path -LiteralPath $pluginBackupDirectory -PathType Container)) {
            Move-Item -LiteralPath $pluginBackupDirectory -Destination $pluginDirectory
        }
    } elseif (Test-Path -LiteralPath $installedPlugin -PathType Leaf) {
        Remove-OracleFileWithRetry $installedPlugin
    }
}

if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Oblivion retail oracle produced no output: $output"
}
$events = @(Get-Content -LiteralPath $output | ForEach-Object { $_ | ConvertFrom-Json })
$snapshots = @($events | Where-Object { $_.event -eq "snapshot" })
$complete = @($events | Where-Object { $_.event -eq "capture-complete" })
if ($snapshots.Count -eq 0 -or $complete.Count -ne 1) {
    throw "Incomplete Oblivion retail oracle output: snapshots=$($snapshots.Count), completion=$($complete.Count)."
}
$targetSnapshots = @($snapshots | Where-Object { $null -ne $_.target })
if ($targetSnapshots.Count -eq 0) {
    throw "The authored Palace Guard never resolved in retail telemetry."
}
$result = [pscustomobject][ordered]@{
    schema = "nikami-oblivion-retail-oracle-run/v1"
    status = "captured"
    output = $output
    save = if ($null -ne $saveFile) { $SaveName } else { $null }
    startCell = $StartCell
    targetForm = $TargetForm
    processId = $gameProcess.Id
    exitCode = $exitCode
    timedOut = $timedOut
    foregroundInputUsed = $false
    visibleWindowObserved = $visibleViolation
    foregroundWindowObserved = $foregroundViolation
    installedPluginsIsolated = $isolatedPlugins
    screenshotsCaptured = 0
    snapshotCount = $snapshots.Count
    playerLevel = $snapshots[-1].player.level
    targetDistance = $snapshots[-1].distance
    targetInCombat = $snapshots[-1].target.inCombat
    targetPackage = $snapshots[-1].target.package
    targetProcedure = $snapshots[-1].target.procedure
    playerAnimation = $snapshots[-1].player.thirdPersonAnimation
    targetAnimation = $snapshots[-1].target.thirdPersonAnimation
}
$resultPath = [System.IO.Path]::ChangeExtension($output, ".result.json")
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
$result
