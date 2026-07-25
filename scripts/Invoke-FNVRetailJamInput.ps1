[CmdletBinding()]
param(
    [string]$TelemetryPath,
    [int]$BaselineStartFrame = 880,
    [int]$BaselineEndFrame = 1020,
    [int]$SprintStartFrame = 1120,
    [int]$SprintEndFrame = 1450,
    [int]$TimeoutSeconds = 90,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class FnvJamRetailInput
{
    private const uint InputKeyboard = 1;
    private const uint KeyEventKeyUp = 0x0002;
    private const uint KeyEventScanCode = 0x0008;

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct Input
    {
        [FieldOffset(0)]
        public uint Type;
        [FieldOffset(8)]
        public KeyboardInput Keyboard;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int inputSize);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);

    [DllImport("user32.dll")]
    private static extern IntPtr SetActiveWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    private static void SendScanCode(ushort scanCode, bool keyUp)
    {
        Input input = new Input();
        input.Type = InputKeyboard;
        input.Keyboard.VirtualKey = 0;
        input.Keyboard.ScanCode = scanCode;
        input.Keyboard.Flags = KeyEventScanCode | (keyUp ? KeyEventKeyUp : 0);
        input.Keyboard.Time = 0;
        input.Keyboard.ExtraInfo = UIntPtr.Zero;
        Input[] inputs = new Input[] { input };
        if (SendInput(1, inputs, Marshal.SizeOf(typeof(Input))) != 1)
            throw new InvalidOperationException(
                "SendInput failed with Win32 error " + Marshal.GetLastWin32Error());
    }

    public static void Down(ushort scanCode) { SendScanCode(scanCode, false); }
    public static void Up(ushort scanCode) { SendScanCode(scanCode, true); }
    public static int InputSize() { return Marshal.SizeOf(typeof(Input)); }

    public static bool ForceForegroundWindow(IntPtr hWnd)
    {
        uint ignoredProcessId;
        uint currentThread = GetCurrentThreadId();
        uint targetThread = GetWindowThreadProcessId(hWnd, out ignoredProcessId);
        IntPtr previousForeground = GetForegroundWindow();
        uint foregroundThread = GetWindowThreadProcessId(previousForeground, out ignoredProcessId);
        bool attachedForeground = foregroundThread != 0 && foregroundThread != currentThread
            && AttachThreadInput(currentThread, foregroundThread, true);
        bool attachedTarget = targetThread != 0 && targetThread != currentThread
            && targetThread != foregroundThread && AttachThreadInput(currentThread, targetThread, true);
        try
        {
            ShowWindow(hWnd, 9);
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
            SetActiveWindow(hWnd);
            SetFocus(hWnd);
            return GetForegroundWindow() == hWnd;
        }
        finally
        {
            if (attachedTarget)
                AttachThreadInput(currentThread, targetThread, false);
            if (attachedForeground)
                AttachThreadInput(currentThread, foregroundThread, false);
        }
    }
}
"@

if ($SelfTest) {
    [FnvJamRetailInput]::Up([UInt16]0x2A)
    [FnvJamRetailInput]::Up([UInt16]0x11)
    [ordered]@{
        schema = "nikami-fnv-retail-jam-input-self-test/v1"
        status = "passed"
        marshalledInputBytes = [FnvJamRetailInput]::InputSize()
        shiftReleaseAccepted = $true
        forwardReleaseAccepted = $true
    } | ConvertTo-Json -Depth 3
    exit 0
}

if ([string]::IsNullOrWhiteSpace($TelemetryPath)) {
    throw "TelemetryPath is required unless SelfTest is selected."
}

function Get-LatestFrame([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return -1
    }
    foreach ($line in @(Get-Content -LiteralPath $Path -Tail 20 -ErrorAction SilentlyContinue |
            Select-Object -Last 20)) {
        if ($line -match '"frame":(\d+)') {
            $script:latestFrame = [int]$Matches[1]
        }
    }
    return $script:latestFrame
}

$script:latestFrame = -1
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$game = $null
while ([DateTime]::UtcNow -lt $deadline) {
    $game = Get-Process FalloutNV -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1
    if ($null -ne $game -and (Get-LatestFrame $TelemetryPath) -ge $BaselineStartFrame) {
        break
    }
    Start-Sleep -Milliseconds 50
}
if ($null -eq $game) {
    throw "FalloutNV did not expose a window before the input deadline."
}
if ($script:latestFrame -lt $BaselineStartFrame) {
    throw "Retail telemetry did not reach frame $BaselineStartFrame before the input deadline."
}

$shell = New-Object -ComObject WScript.Shell
$focused = $false
for ($attempt = 0; $attempt -lt 10 -and -not $focused; $attempt++) {
    [void]$shell.AppActivate($game.Id)
    [void][FnvJamRetailInput]::ForceForegroundWindow($game.MainWindowHandle)
    Start-Sleep -Milliseconds 75
    $focused = [FnvJamRetailInput]::GetForegroundWindow() -eq $game.MainWindowHandle
}
if (-not $focused) {
    throw "Windows refused to focus the retail FalloutNV proof window."
}

$scanW = [UInt16]0x11
$scanLeftShift = [UInt16]0x2A
$baselinePressedAtFrame = Get-LatestFrame $TelemetryPath
try {
    [FnvJamRetailInput]::Down($scanW)
    while (-not $game.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $frame = Get-LatestFrame $TelemetryPath
        if ($frame -ge $BaselineEndFrame) {
            break
        }
        Start-Sleep -Milliseconds 50
        $game.Refresh()
    }
    [FnvJamRetailInput]::Up($scanW)

    while (-not $game.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $frame = Get-LatestFrame $TelemetryPath
        if ($frame -ge $SprintStartFrame) {
            break
        }
        Start-Sleep -Milliseconds 50
        $game.Refresh()
    }
    $sprintPressedAtFrame = Get-LatestFrame $TelemetryPath
    [FnvJamRetailInput]::Down($scanW)
    Start-Sleep -Milliseconds 100
    [FnvJamRetailInput]::Down($scanLeftShift)
    while (-not $game.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $frame = Get-LatestFrame $TelemetryPath
        if ($frame -ge $SprintEndFrame) {
            break
        }
        Start-Sleep -Milliseconds 50
        $game.Refresh()
    }
}
finally {
    [FnvJamRetailInput]::Up($scanLeftShift)
    [FnvJamRetailInput]::Up($scanW)
}

[ordered]@{
    schema = "nikami-fnv-retail-jam-input/v1"
    status = "completed"
    processId = $game.Id
    focused = $focused
    baselineStartFrame = $baselinePressedAtFrame
    sprintStartFrame = $sprintPressedAtFrame
    endFrame = Get-LatestFrame $TelemetryPath
    scanCodes = [ordered]@{
        forwardW = 17
        sprintLeftShift = 42
    }
} | ConvertTo-Json -Depth 4
