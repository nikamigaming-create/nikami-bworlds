[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$SavePath =
        "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Save 331     Goodsprings  00 17 36.fos",
    [ValidateRange(60, 300)]
    [int]$TimeoutSeconds = 150
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    throw 'OutputRoot is required.'
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite retail Pip-Boy capture: $OutputRoot"
}
if (-not (Test-Path -LiteralPath $SavePath -PathType Leaf)) {
    throw "Retail Pip-Boy save fixture is missing: $SavePath"
}

$oracle = Join-Path $WorldsRoot 'scripts\Invoke-FNVRetailOracle.ps1'
$telemetry = Join-Path $OutputRoot 'retail-pipboy-state.jsonl'
$frames = Join-Path $OutputRoot 'native-d3d9-frames'
$reportPath = Join-Path $OutputRoot 'retail-pipboy-state-report.json'
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

# Retail's Menu Mode action is control 14. Drive that control and let retail's
# own PlayerCharacter/Pip-Boy lifecycle holster the weapon, raise both arms,
# open the rendered manager, close it, lower the arm, and restore the weapon.
# Calling Open/ClosePipBoyRenderedManager directly opens UI state without the
# physical first-person transition and produced a false-positive proof with the
# rifle still rendered through a low Pip-Boy.
$scheduled = @(
    '640:EnableBackgroundInputPolling',
    '650:player.FirstPerson',
    '680:player.SetWeaponOut 1',
    '850:PipBoySnapshot before-raise',
    '860:PipBoyTreeSnapshot before-raise',
    '900:HoldKey 15',
    '904:ReleaseKey 15',
    '920:PipBoySnapshot raising',
    # The measured native gate reaches Pip-Boy mode 3/rendered-open around
    # frame 938. Create the menu renderer only after that physical gate; doing
    # this before the gate interrupts the authored arm sequence.
    '950:OpenPipBoyRenderedManager',
    '1000:PipBoySnapshot held',
    '1010:PipBoyTreeSnapshot held',
    '1050:HoldKey 15',
    '1054:ReleaseKey 15',
    '1070:PipBoySnapshot lowering',
    '1120:PipBoySnapshot after-lower',
    '1130:PipBoyTreeSnapshot after-lower'
)
$screenshotFrames = @(840..1130 | Where-Object { ($_ % 2) -eq 0 })

& $oracle `
    -OutputPath $telemetry `
    -SaveFixture $SavePath `
    -ScheduledCommand $scheduled `
    -PipBoyProbe `
    -BackgroundDataMode `
    -VisibleGame `
    -IsolateFromFNVXR `
    -SampleEvery 2 `
    -BeforeFrame 830 `
    -CommandFrame 900 `
    -AfterFrame 1140 `
    -ScreenshotFrame $screenshotFrames `
    -ScreenshotDirectory $frames `
    -MaxFrames 1150 `
    -TimeoutSeconds $TimeoutSeconds

$events = @(Get-Content -LiteralPath $telemetry | ForEach-Object { $_ | ConvertFrom-Json })
$snapshots = @($events | Where-Object event -eq 'retail-pipboy-snapshot')
$commands = @($events | Where-Object event -eq 'scheduled-console-command')
$rejected = @($commands | Where-Object { -not [bool]$_.accepted })
$nativeFrames = @(Get-ChildItem -LiteralPath $frames -Filter '*.bmp' -File | Sort-Object Name)
$firstPersonSnapshots = @($snapshots | Where-Object {
    $null -ne $_.player.firstPerson -and
    [bool]$_.player.firstPerson.available -and
    @($_.player.firstPerson.nodes).Count -gt 0
})
$openSnapshots = @($snapshots | Where-Object {
    [int]$_.interface.pipBoyMode -eq 3 -and
    [int]$_.interface.renderedMenuOrPipboyManager -eq 1 -and
    @($_.interface.visibleMenus | Where-Object { $_.type -eq 1003 }).Count -gt 0
})
$heldPipBoySnapshots = @($openSnapshots | Where-Object {
    [bool]$_.interface.physical.renderedOpen -and
    @($_.player.firstPerson.animDataSequences | Where-Object {
        $null -ne $_ -and [string]$_.file -match '(?i)pipboy.*\.kf$'
    }).Count -gt 0
})
$closedSnapshots = @($snapshots | Where-Object {
    [int]$_.interface.pipBoyMode -ne 3
})

$passed = $rejected.Count -eq 0 -and
    $nativeFrames.Count -eq $screenshotFrames.Count -and
    $firstPersonSnapshots.Count -gt 0 -and
    $openSnapshots.Count -gt 0 -and
    $heldPipBoySnapshots.Count -gt 0 -and
    $closedSnapshots.Count -gt 0

$artifacts = [Collections.Generic.List[object]]::new()
foreach ($path in @($telemetry, "$telemetry.manifest.json")) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $file = Get-Item -LiteralPath $path
        $artifacts.Add([pscustomobject][ordered]@{
            path = $file.FullName
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        })
    }
}
foreach ($file in $nativeFrames) {
    $artifacts.Add([pscustomobject][ordered]@{
        path = $file.FullName
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    })
}

$report = [pscustomobject][ordered]@{
    schema = 'nikami-retail-pipboy-state-capture/v1'
    status = if ($passed) { 'pass' } else { 'fail' }
    capture = [pscustomobject][ordered]@{
        method = 'xNVSE-scheduled retail input plus native Direct3D 9 backbuffer and per-frame first-person scene graph'
        driver = 'in-process xNVSE HoldKey/ReleaseKey live Tab binding; native retail Pip-Boy lifecycle'
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        sourceFramesRetained = $true
        telemetryRetained = $true
    }
    assertions = [pscustomobject][ordered]@{
        scheduledCommands = $commands.Count
        rejectedCommands = $rejected.Count
        requestedNativeFrames = $screenshotFrames.Count
        retainedNativeFrames = $nativeFrames.Count
        firstPersonSnapshots = $firstPersonSnapshots.Count
        renderedStatsOpenSnapshots = $openSnapshots.Count
        nativeRenderedPipBoySnapshots = $heldPipBoySnapshots.Count
        closedSnapshots = $closedSnapshots.Count
    }
    artifacts = @($artifacts)
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
if (-not $passed) {
    throw "Retail Pip-Boy state capture failed validation. See $reportPath"
}
$report
