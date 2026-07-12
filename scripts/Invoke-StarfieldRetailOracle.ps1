[CmdletBinding()]
param(
    [string]$GameRoot = "D:\SteamLibrary\steamapps\common\Starfield",
    [string]$SfseLoader = "external\sfse\build\sfse_loader\Release\sfse_loader.exe",
    [string]$SfseRuntime = "external\sfse\build\sfse\Release\sfse_1_16_244.dll",
    [string]$PluginDll = "external\sfse\nikami_starfield_oracle\build\Release\nikami_starfield_oracle.dll",
    [string]$OutputPath = "run\retail-oracle\starfield-new-atlantis-actor-composition-v1.jsonl",
    [string]$StartCommand = "coc NewAtlantisSpaceport",
    [string[]]$TargetForm = @("0x0123337C"),
    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 120,
    [ValidateRange(0, 600)]
    [int]$SettleFrames = 0,
    [ValidateRange(180, 3600)]
    [int]$MaxFrames = 1200,
    [hashtable]$EnvironmentOverride = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Assert-ChildPath([string]$Parent, [string]$Child) {
    $resolvedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $resolvedChild = [IO.Path]::GetFullPath($Child)
    if (-not $resolvedChild.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing filesystem operation outside $resolvedParent`: $resolvedChild"
    }
}

function Set-IniValue([string]$Text, [string]$Section, [string]$Key, [string]$Value) {
    $keyPattern = '(?im)^\s*' + [Regex]::Escape($Key) + '\s*=.*$'
    if ([Regex]::IsMatch($Text, $keyPattern)) {
        return [Regex]::Replace($Text, $keyPattern, "$Key=$Value", 1)
    }

    $sectionPattern = '(?im)^\s*\[' + [Regex]::Escape($Section) + '\]\s*$'
    $sectionMatch = [Regex]::Match($Text, $sectionPattern)
    if ($sectionMatch.Success) {
        return $Text.Insert($sectionMatch.Index + $sectionMatch.Length, "`r`n$Key=$Value")
    }
    return $Text.TrimEnd() + "`r`n`r`n[$Section]`r`n$Key=$Value`r`n"
}

function Remove-OracleFileWithRetry([string]$Path, [int]$Attempts = 30) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq $Attempts) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

foreach ($form in $TargetForm) {
    if ($form -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$' -or $form -match '^(0[xX]0+|0+)$') {
        throw "TargetForm must contain nonzero decimal or 0x-prefixed FormIDs: $form"
    }
}
if ([string]::IsNullOrWhiteSpace($StartCommand) -or $StartCommand -match '[\r\n]') {
    throw "StartCommand must be one nonempty console command."
}

$gameRootPath = Resolve-AbsolutePath $GameRoot
$sourceLoader = Resolve-AbsolutePath $SfseLoader
$sourceRuntime = Resolve-AbsolutePath $SfseRuntime
$sourcePlugin = Resolve-AbsolutePath $PluginDll
$output = Resolve-AbsolutePath $OutputPath
$gameExe = Join-Path $gameRootPath "Starfield.exe"
$installedLoader = Join-Path $gameRootPath "sfse_loader.exe"
$installedRuntime = Join-Path $gameRootPath "sfse_1_16_244.dll"
$pluginDirectory = Join-Path $gameRootPath "Data\SFSE\Plugins"
$installedPlugin = Join-Path $pluginDirectory "nikami_starfield_oracle.dll"
$pluginBackupDirectory = Join-Path $gameRootPath ".nikami-sfse-plugins-backup-$PID"
$loaderBackup = "$installedLoader.nikami-backup-$PID"
$runtimeBackup = "$installedRuntime.nikami-backup-$PID"
$startupBatch = Join-Path $gameRootPath "nikami_starfield_oracle.txt"
$startupBatchBackup = "$startupBatch.nikami-backup-$PID"
$documentsRoot = [Environment]::GetFolderPath("MyDocuments")
$starfieldDocuments = Join-Path $documentsRoot "My Games\Starfield"
if (-not (Test-Path -LiteralPath $starfieldDocuments -PathType Container)) {
    $oneDriveDocuments = Join-Path $env:USERPROFILE "OneDrive\Documents\My Games\Starfield"
    if (Test-Path -LiteralPath $oneDriveDocuments -PathType Container) {
        $starfieldDocuments = $oneDriveDocuments
    }
}
$customIni = Join-Path $starfieldDocuments "StarfieldCustom.ini"
$iniBackup = "$customIni.nikami-backup-$PID"

foreach ($required in @($gameExe, $sourceLoader, $sourceRuntime, $sourcePlugin, $customIni)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing required Starfield oracle file: $required"
    }
}
if ((Get-Item -LiteralPath $gameExe).VersionInfo.FileVersion -notlike '1.16.244*') {
    throw "The native oracle is pinned to Starfield 1.16.244.0."
}
if (Get-Process -Name "Starfield" -ErrorAction SilentlyContinue) {
    throw "Starfield is already running; refusing to touch a user-owned process."
}
foreach ($temporary in @($pluginBackupDirectory, $loaderBackup, $runtimeBackup, $startupBatchBackup, $iniBackup)) {
    if (Test-Path -LiteralPath $temporary) {
        throw "Refusing to overwrite stale Starfield oracle state: $temporary"
    }
}

Assert-ChildPath $gameRootPath $installedLoader
Assert-ChildPath $gameRootPath $installedRuntime
Assert-ChildPath $gameRootPath $pluginDirectory
Assert-ChildPath $gameRootPath $pluginBackupDirectory
Assert-ChildPath $gameRootPath $startupBatch
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
if (Test-Path -LiteralPath $output -PathType Leaf) {
    Remove-Item -LiteralPath $output -Force
}

if (-not ('Nikami.StarfieldOracleWindowAudit' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Nikami {
    public static class StarfieldOracleWindowAudit {
        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
    }
}
'@
}

if (-not ('Nikami.HiddenDesktopProcess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Nikami {
    public static class HiddenDesktopProcess {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO {
            public uint cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public ushort wShowWindow;
            public ushort cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateDesktopW(string name, IntPtr device, IntPtr devMode,
            uint flags, uint desiredAccess, IntPtr securityAttributes);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool CloseDesktop(IntPtr desktop);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(string applicationName, string commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags,
            IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private static IntPtr desktop = IntPtr.Zero;

        public static int Launch(string executable, string workingDirectory, string desktopName) {
            const uint GENERIC_ALL = 0x10000000;
            const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
            const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
            const uint STARTF_USESHOWWINDOW = 0x00000001;
            const ushort SW_HIDE = 0;

            desktop = CreateDesktopW(desktopName, IntPtr.Zero, IntPtr.Zero, 0, GENERIC_ALL, IntPtr.Zero);
            if (desktop == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateDesktopW failed");

            var startup = new STARTUPINFO {
                cb = (uint)Marshal.SizeOf<STARTUPINFO>(),
                lpDesktop = desktopName,
                dwFlags = STARTF_USESHOWWINDOW,
                wShowWindow = SW_HIDE
            };
            PROCESS_INFORMATION process;
            if (!CreateProcessW(executable, null, IntPtr.Zero, IntPtr.Zero, false,
                    CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero,
                    workingDirectory, ref startup, out process)) {
                int error = Marshal.GetLastWin32Error();
                CloseDesktop(desktop);
                desktop = IntPtr.Zero;
                throw new Win32Exception(error, "CreateProcessW failed");
            }
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            return checked((int)process.dwProcessId);
        }

        public static void Close() {
            if (desktop != IntPtr.Zero) {
                CloseDesktop(desktop);
                desktop = IntPtr.Zero;
            }
        }
    }
}
'@
}

$environment = [ordered]@{
    NIKAMI_STARFIELD_ORACLE_HIDDEN = "1"
    NIKAMI_STARFIELD_ORACLE_OUTPUT = $output
    NIKAMI_STARFIELD_ORACLE_TARGET_FORMS = ($TargetForm -join ',')
    NIKAMI_STARFIELD_ORACLE_SETTLE_FRAMES = [string]$SettleFrames
    NIKAMI_STARFIELD_ORACLE_MAX_FRAMES = [string]$MaxFrames
}
foreach ($entry in $EnvironmentOverride.GetEnumerator()) {
    if ($null -ne $entry.Value) {
        $environment[[string]$entry.Key] = [string]$entry.Value
    }
}
$previousEnvironment = @{}
$hadPluginDirectory = Test-Path -LiteralPath $pluginDirectory -PathType Container
$hadLoader = Test-Path -LiteralPath $installedLoader -PathType Leaf
$hadRuntime = Test-Path -LiteralPath $installedRuntime -PathType Leaf
$hadStartupBatch = Test-Path -LiteralPath $startupBatch -PathType Leaf
$gameProcess = $null
$loaderProcess = $null
$visibleViolation = $false
$foregroundViolation = $false
$timedOut = $false
$exitCode = $null

try {
    if ($hadPluginDirectory) {
        Move-Item -LiteralPath $pluginDirectory -Destination $pluginBackupDirectory
    }
    New-Item -ItemType Directory -Force -Path $pluginDirectory | Out-Null
    if ($hadLoader) { Move-Item -LiteralPath $installedLoader -Destination $loaderBackup }
    if ($hadRuntime) { Move-Item -LiteralPath $installedRuntime -Destination $runtimeBackup }
    if ($hadStartupBatch) { Move-Item -LiteralPath $startupBatch -Destination $startupBatchBackup }
    Copy-Item -LiteralPath $sourceLoader -Destination $installedLoader
    Copy-Item -LiteralPath $sourceRuntime -Destination $installedRuntime
    Copy-Item -LiteralPath $sourcePlugin -Destination $installedPlugin
    [IO.File]::WriteAllText($startupBatch, $StartCommand + "`r`n", [Text.ASCIIEncoding]::new())

    Copy-Item -LiteralPath $customIni -Destination $iniBackup
    $iniText = Get-Content -LiteralPath $customIni -Raw
    $iniText = Set-IniValue $iniText "General" "sStartingConsoleCommand" "bat nikami_starfield_oracle"
    $iniText = Set-IniValue $iniText "General" "SIntroSequence" "0"
    $iniText = Set-IniValue $iniText "General" "uMainMenuDelayBeforeAllowSkip" "0"
    [IO.File]::WriteAllText($customIni, $iniText, [Text.UTF8Encoding]::new($false))

    foreach ($entry in $environment.GetEnumerator()) {
        $previousEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, "Process")
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }

    $startedAt = Get-Date
    # Keep the loader and every child window on a dedicated desktop which is never switched into view. SFSE accepts
    # no Bethesda runtime switches here; passing one opens a modal "Couldn't read arguments" dialog.
    $desktopName = "NikamiStarfieldOracle-$PID"
    $loaderPid = [Nikami.HiddenDesktopProcess]::Launch($installedLoader, $gameRootPath, $desktopName)
    $loaderProcess = Get-Process -Id $loaderPid -ErrorAction Stop
    $launchDeadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $launchDeadline -and $null -eq $gameProcess) {
        $gameProcess = Get-Process -Name "Starfield" -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
            Select-Object -First 1
        if ($null -eq $gameProcess) { Start-Sleep -Milliseconds 50 }
    }
    if ($null -eq $gameProcess) {
        throw "Hidden SFSE loader did not create Starfield within 30 seconds (loader PID $($loaderProcess.Id))."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $gameProcess.Refresh()
        if ($gameProcess.HasExited) { break }
        $window = $gameProcess.MainWindowHandle
        if ($window -ne [IntPtr]::Zero) {
            if ([Nikami.StarfieldOracleWindowAudit]::IsWindowVisible($window)) {
                $visibleViolation = $true
                Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
                throw "Background-safety violation: the Starfield oracle window became visible."
            }
            if ([Nikami.StarfieldOracleWindowAudit]::GetForegroundWindow() -eq $window) {
                $foregroundViolation = $true
                Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
                throw "Background-safety violation: the Starfield oracle window became foreground."
            }
        }
        $gameProcess.WaitForExit(50) | Out-Null
    }
    $gameProcess.Refresh()
    if (-not $gameProcess.HasExited) {
        $timedOut = $true
        Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
        $gameProcess.WaitForExit(5000) | Out-Null
        throw "Starfield retail oracle timed out after $TimeoutSeconds seconds."
    }
    try { $exitCode = $gameProcess.ExitCode } catch { $exitCode = $null }
}
finally {
    if ($null -ne $gameProcess) {
        try {
            $gameProcess.Refresh()
            if (-not $gameProcess.HasExited) { Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
    if ($null -ne $loaderProcess) {
        try {
            $loaderProcess.Refresh()
            if (-not $loaderProcess.HasExited) { Stop-Process -Id $loaderProcess.Id -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
    if ('Nikami.HiddenDesktopProcess' -as [type]) {
        [Nikami.HiddenDesktopProcess]::Close()
    }
    foreach ($entry in $environment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $previousEnvironment[$entry.Key], "Process")
    }
    if (Test-Path -LiteralPath $iniBackup -PathType Leaf) {
        Copy-Item -LiteralPath $iniBackup -Destination $customIni -Force
        Remove-Item -LiteralPath $iniBackup -Force
    }
    foreach ($installed in @($installedPlugin, $installedLoader, $installedRuntime, $startupBatch)) {
        Remove-OracleFileWithRetry $installed
    }
    if (Test-Path -LiteralPath $pluginDirectory -PathType Container) {
        Remove-Item -LiteralPath $pluginDirectory -Recurse -Force
    }
    if ($hadPluginDirectory -and (Test-Path -LiteralPath $pluginBackupDirectory -PathType Container)) {
        Move-Item -LiteralPath $pluginBackupDirectory -Destination $pluginDirectory
    }
    if ($hadLoader -and (Test-Path -LiteralPath $loaderBackup -PathType Leaf)) {
        Move-Item -LiteralPath $loaderBackup -Destination $installedLoader
    }
    if ($hadRuntime -and (Test-Path -LiteralPath $runtimeBackup -PathType Leaf)) {
        Move-Item -LiteralPath $runtimeBackup -Destination $installedRuntime
    }
    if ($hadStartupBatch -and (Test-Path -LiteralPath $startupBatchBackup -PathType Leaf)) {
        Move-Item -LiteralPath $startupBatchBackup -Destination $startupBatch
    }
}

if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Starfield retail oracle produced no output: $output"
}
$events = @(Get-Content -LiteralPath $output | ForEach-Object { $_ | ConvertFrom-Json })
$complete = @($events | Where-Object event -eq "capture-complete")
$references = @($events | Where-Object event -eq "reference")
$treeSummaries = @($events | Where-Object event -eq "tree-summary")
if ($complete.Count -ne 1) {
    throw "Incomplete Starfield retail oracle output: completion events=$($complete.Count)."
}
$result = [pscustomobject][ordered]@{
    schema = "nikami-starfield-retail-oracle-run/v1"
    status = [string]$complete[0].result
    reason = [string]$complete[0].reason
    output = $output
    startCommand = $StartCommand
    targetForms = @($TargetForm)
    processId = $gameProcess.Id
    exitCode = $exitCode
    timedOut = $timedOut
    foregroundInputUsed = $false
    visibleWindowObserved = $visibleViolation
    foregroundWindowObserved = $foregroundViolation
    pluginIsolation = $true
    referenceCount = $references.Count
    treeCount = $treeSummaries.Count
    nodeCount = (@($treeSummaries | ForEach-Object { [int]$_.nodes }) | Measure-Object -Sum).Sum
    geometryCount = (@($treeSummaries | ForEach-Object { [int]$_.geometry }) | Measure-Object -Sum).Sum
    semanticNodeCount = (@($treeSummaries | ForEach-Object { [int]$_.semanticNodes }) | Measure-Object -Sum).Sum
}
$resultPath = [IO.Path]::ChangeExtension($output, ".result.json")
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultPath -Encoding utf8
$result
