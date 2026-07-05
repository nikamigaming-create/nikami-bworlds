param(
    [string[]]$WorldId = @(),
    [string]$SeedPath = "catalog/world-walker.seed.json",
    [string]$StartsPath = "catalog/flat-world-proof-starts.json",
    [string]$BinaryRoot = "",
    [string]$ProofRoot = "proof/flat-world-screenshots",
    [int]$RunSeconds = 0,
    [string]$ScreenshotFrames = "",
    [string]$StartCellOverride = "",
    [int]$WindowCaptureSeconds = 0,
    [switch]$DryRun,
    [switch]$KeepRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Convert-ToForwardSlash([string]$Path) {
    return ($Path -replace "\\", "/")
}

function Quote-CommandArg([string]$Arg) {
    if ($Arg -match '[\s"]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Copy-LatestScreenshot([string]$ScreenshotDir, [string]$DestinationDir, [string]$WorldId) {
    if (-not (Test-Path -LiteralPath $ScreenshotDir)) {
        return $null
    }
    $shot = Get-ChildItem -LiteralPath $ScreenshotDir -File -Filter "screenshot*.png" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $shot) {
        return $null
    }
    $destination = Join-Path $DestinationDir "$WorldId.png"
    Copy-Item -LiteralPath $shot.FullName -Destination $destination -Force
    return (Resolve-Path -LiteralPath $destination).Path
}

function Ensure-WindowCaptureTypes {
    if ("Win32OpenMWCapture" -as [type]) {
        return
    }

    Add-Type -AssemblyName System.Drawing
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32OpenMWCapture
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
}

function Wait-ProcessMainWindow($Process, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $Process.MainWindowHandle
        }
        Start-Sleep -Milliseconds 250
    }
    return [IntPtr]::Zero
}

function Save-ProcessWindowScreenshot($Process, [string]$DestinationPath) {
    Ensure-WindowCaptureTypes

    $handle = Wait-ProcessMainWindow -Process $Process -TimeoutSeconds 8
    if ($handle -eq [IntPtr]::Zero) {
        return $false
    }

    [void][Win32OpenMWCapture]::ShowWindow($handle, 9)
    [void][Win32OpenMWCapture]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 750

    $rect = New-Object Win32OpenMWCapture+RECT
    if (-not [Win32OpenMWCapture]::GetClientRect($handle, [ref]$rect)) {
        return $false
    }

    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) {
        return $false
    }

    $point = New-Object Win32OpenMWCapture+POINT
    $point.X = 0
    $point.Y = 0
    if (-not [Win32OpenMWCapture]::ClientToScreen($handle, [ref]$point)) {
        return $false
    }

    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($point.X, $point.Y, 0, 0, (New-Object System.Drawing.Size($width, $height)))
        $bitmap.Save($DestinationPath, [System.Drawing.Imaging.ImageFormat]::Png)
        return $true
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

foreach ($path in @($SeedPath, $StartsPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required input: $path"
    }
}

$BinaryRoot = Resolve-NikamiPath `
    -ParameterValue $BinaryRoot `
    -EnvName "NIKAMI_OPENMW_BINARY_ROOT" `
    -ConfigName "openmwBinaryRoot" `
    -Required `
    -Description "OpenMW binary root"

$binary = Join-Path $BinaryRoot "openmw.exe"
if (-not (Test-Path -LiteralPath $binary)) {
    throw "Missing existing flat OpenMW binary: $binary"
}

$seed = Get-Content -LiteralPath $SeedPath -Raw | ConvertFrom-Json
$starts = Get-Content -LiteralPath $StartsPath -Raw | ConvertFrom-Json

$selected = @($seed.worlds | Where-Object { $_.readyForWorldWalker -eq $true })
if ($WorldId.Count -gt 0) {
    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $WorldId) {
        [void]$wanted.Add($id)
    }
    $selected = @($selected | Where-Object { $wanted.Contains($_.id) })
}
if ($selected.Count -eq 0) {
    throw "No ready worlds selected."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$proofDir = Join-Path $ProofRoot $stamp
$cwdPath = (Get-Location).Path
$absProofDir = Join-Path $cwdPath $proofDir
$screensDir = Join-Path $absProofDir "screenshots"
$logsDir = Join-Path $absProofDir "logs"
New-Item -ItemType Directory -Force -Path $screensDir, $logsDir | Out-Null

$defaultRunSeconds = [int]$starts.defaults.runSeconds
if ($RunSeconds -le 0) {
    $RunSeconds = $defaultRunSeconds
}
if ([string]::IsNullOrWhiteSpace($ScreenshotFrames)) {
    $ScreenshotFrames = [string]$starts.defaults.screenshotFrames
}
$defaultExtraArgs = @($starts.defaults.extraArgs)

$previousEnv = @{}
foreach ($name in @("OPENMW_PROOF_SCREENSHOT_FRAME", "OPENMW_FNV_BOOTSTRAP_HOUR")) {
    $previousEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$results = New-Object System.Collections.Generic.List[object]

try {
    [Environment]::SetEnvironmentVariable("OPENMW_PROOF_SCREENSHOT_FRAME", $ScreenshotFrames, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_BOOTSTRAP_HOUR", "12", "Process")

    foreach ($world in $selected) {
        $start = Get-PropertyValue $starts.worlds $world.id
        $startCell = if ($null -ne $start) { [string]$start.startCell } else { "" }
        $label = if ($null -ne $start) { [string]$start.label } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($StartCellOverride)) {
            if ($selected.Count -ne 1) {
                throw "-StartCellOverride can only be used when exactly one -WorldId is selected."
            }
            $startCell = $StartCellOverride
            $label = "manual probe"
        }
        $worldRunDir = Join-Path $absProofDir $world.id
        $userDataDir = Join-Path $worldRunDir "userdata"
        $stdoutLog = Join-Path $logsDir "$($world.id).stdout.log"
        $stderrLog = Join-Path $logsDir "$($world.id).stderr.log"
        $windowCapture = Join-Path $screensDir "$($world.id).window.png"
        New-Item -ItemType Directory -Force -Path $userDataDir | Out-Null

        $argsList = New-Object System.Collections.Generic.List[string]
        $argsList.Add("--replace")
        $argsList.Add("config")
        $argsList.Add("--config")
        $argsList.Add($world.profileDirectory)
        $argsList.Add("--user-data")
        $argsList.Add($userDataDir)
        $argsList.Add("--skip-menu")
        if (-not [string]::IsNullOrWhiteSpace($startCell)) {
            $argsList.Add("--start")
            $argsList.Add($startCell)
        }
        foreach ($arg in $defaultExtraArgs) {
            if (-not [string]::IsNullOrWhiteSpace([string]$arg)) {
                $argsList.Add([string]$arg)
            }
        }

        $argumentLine = ($argsList.ToArray() | ForEach-Object { Quote-CommandArg $_ }) -join " "
        $commandLine = "$(Quote-CommandArg $binary) $argumentLine"
        Write-Host ""
        Write-Host "[$($world.id)] $($world.displayName)"
        Write-Host "Start: $startCell"
        Write-Host "Command: $commandLine"

        $status = "not-run"
        $exitCode = $null
        $screenshot = $null
        $windowScreenshot = $null
        $profileLog = Join-Path $world.profileDirectory "openmw.log"
        $userDataLog = Join-Path $userDataDir "openmw.log"
        $notes = New-Object System.Collections.Generic.List[string]

        if ($DryRun) {
            $status = "dry-run"
        }
        else {
            $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $binary) -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
            if (-not $KeepRunning) {
                $captureDelay = $WindowCaptureSeconds
                if ($captureDelay -gt 0) {
                    $captureDelay = [Math]::Min($captureDelay, $RunSeconds)
                    if (-not $process.WaitForExit($captureDelay * 1000)) {
                        if (Save-ProcessWindowScreenshot -Process $process -DestinationPath $windowCapture) {
                            $windowScreenshot = (Resolve-Path -LiteralPath $windowCapture).Path
                            $notes.Add("captured process window after $captureDelay seconds")
                        }
                        else {
                            $notes.Add("window capture failed after $captureDelay seconds")
                        }
                    }
                }

                $process.Refresh()
                if (-not $process.HasExited) {
                    $remainingMs = [Math]::Max(0, ($RunSeconds - $captureDelay) * 1000)
                    if (-not $process.WaitForExit($remainingMs)) {
                        Stop-Process -Id $process.Id -Force
                        $notes.Add("stopped after $RunSeconds seconds")
                    }
                }
                $process.Refresh()
                $exitCode = $process.ExitCode
            }
            else {
                $notes.Add("left running pid $($process.Id)")
            }

            Start-Sleep -Milliseconds 750
            $screenshot = Copy-LatestScreenshot -ScreenshotDir (Join-Path $userDataDir "screenshots") -DestinationDir $screensDir -WorldId $world.id
            if ($screenshot) {
                $status = "screenshot"
            }
            elseif ($windowScreenshot) {
                $destination = Join-Path $screensDir "$($world.id).png"
                Copy-Item -LiteralPath $windowScreenshot -Destination $destination -Force
                $screenshot = (Resolve-Path -LiteralPath $destination).Path
                $status = "window-screenshot"
            }
            else {
                $status = "no-screenshot"
                $notes.Add("no screenshot*.png found")
            }

            if (Test-Path -LiteralPath $profileLog) {
                Copy-Item -LiteralPath $profileLog -Destination (Join-Path $logsDir "$($world.id).openmw.log") -Force
            }
            elseif (Test-Path -LiteralPath $userDataLog) {
                Copy-Item -LiteralPath $userDataLog -Destination (Join-Path $logsDir "$($world.id).openmw.log") -Force
            }
            else {
                $notes.Add("no openmw.log found")
            }
        }

        $results.Add([pscustomobject][ordered]@{
            worldId = $world.id
            displayName = $world.displayName
            supportTier = $world.supportTier
            startCell = $startCell
            label = $label
            status = $status
            exitCode = $exitCode
            screenshot = if ($screenshot) { (Convert-ToForwardSlash -Path $screenshot) } else { $null }
            windowScreenshot = if ($windowScreenshot) { (Convert-ToForwardSlash -Path $windowScreenshot) } else { $null }
            runDirectory = (Convert-ToForwardSlash -Path $worldRunDir)
            openmwLog = (Convert-ToForwardSlash -Path (Join-Path $logsDir "$($world.id).openmw.log"))
            processLog = (Convert-ToForwardSlash -Path $stdoutLog)
            processErrorLog = (Convert-ToForwardSlash -Path $stderrLog)
            command = $commandLine
            notes = @($notes)
        })
    }
}
finally {
    foreach ($entry in $previousEnv.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}

$manifest = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    binary = (Convert-ToForwardSlash -Path $binary)
    runSeconds = $RunSeconds
    screenshotFrames = $ScreenshotFrames
    windowCaptureSeconds = $WindowCaptureSeconds
    proofDirectory = (Convert-ToForwardSlash -Path $absProofDir)
    results = @($results.ToArray())
}

$manifestPath = Join-Path $absProofDir "manifest.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding ASCII

Write-Host ""
$results | Format-Table -AutoSize worldId, status, startCell, screenshot
Write-Host "Manifest: $manifestPath"
