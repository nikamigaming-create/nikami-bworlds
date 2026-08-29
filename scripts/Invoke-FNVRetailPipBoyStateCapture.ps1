[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$GameRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas",
    [string]$SavePath =
        "D:\code\nikami-worlds\local\retail-pipboy-fixtures\NikamiCleanPipBoyOracle-20260802.fos",
    # Capture a real retail first-person weapon pose before the ordinary
    # native Pip-Boy lifecycle. WeaponForm is the retail runtime FormID (the
    # Save330 normalized 0x0100434F 10mm pistol is retail 0x0000434F). The
    # isolated save copy is the source of the item; this only asks retail to
    # equip and draw it so xNVSE/D3D can constrain OpenMW's binding.
    [switch]$WeaponAudit,
    [ValidatePattern('^[0-9a-fA-F]{1,8}$')]
    [string]$WeaponForm = '0000434F',
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

$weaponFormValue = [Convert]::ToUInt32($WeaponForm, 16)
$weaponFormHex = ('{0:X8}' -f $weaponFormValue)

# Drive InterfaceManager::OpenPipboy/ClosePipboy, the native retail entrypoints
# used by JohnnyGuitar NVSE's TogglePipBoy command. Retail therefore owns the
# weapon holster/restore, both-arm animation, rendered menus, and lifecycle.
# No menu visibility, Pip-Boy mode, or animation state is written by the oracle.
$scheduledList = [Collections.Generic.List[string]]::new()
$scheduledList.Add('640:EnableBackgroundInputPolling')
$scheduledList.Add($(if ($WeaponAudit) { '650@0x14:FirstPerson' } else { '650:player.FirstPerson' }))
if ($WeaponAudit) {
    $scheduledList.Add("660@0x14:EquipExact $weaponFormHex")
    $scheduledList.Add('820:PipBoySnapshot weapon-drawn')
    $scheduledList.Add('822:PipBoyTreeSnapshot weapon-drawn')
}
$scheduledList.Add($(if ($WeaponAudit) { '680@0x14:SetWeaponOut 1' } else { '680:player.SetWeaponOut 1' }))
$scheduledList.AddRange([string[]]@(
    # The immutable fixture opens with the official Gun Runners' Arsenal
    # MessageMenu. Retail rejects Pip-Boy open while that modal owns the UI.
    # Dismiss it once, only when MessageMenu 1001 is visibly present, then
    # prove the neutral HUD-only state before measuring the native lifecycle.
    '800:DismissBlockingMessageMenuOnce'
    '850:PipBoySnapshot before-raise'
    '860:PipBoyTreeSnapshot before-raise'
    '900:OpenPipBoyRetail'
    '920:PipBoySnapshot raising'
    # OpenPipBoyRetail arms the rendered-menu callback. The oracle dispatches
    # it exactly once only after retail reaches held mode and owns a ready,
    # active Pip-Boy manager; no input or menu visibility state is synthesized.
    '960:PipBoySnapshot naturally-held'
    '962:PipBoyTreeSnapshot naturally-held'
    '1040:PipBoySnapshot held'
    '1042:PipBoyTreeSnapshot held'
    # Native InterfaceManager::ClosePipboy owns modes 4 -> 5 -> 0.
    '1050:ClosePipBoyRetail'
    '1060:PipBoySnapshot lower-requested'
    '1070:PipBoySnapshot lowering-terminal'
))
$scheduledList.AddRange([string[]]@(
    '1080:PipBoySnapshot lowering'
    '1140:PipBoySnapshot after-lower'
    '1142:PipBoyTreeSnapshot after-lower'
))
$scheduled = $scheduledList.ToArray()
$screenshotFrames = @(
    if ($WeaponAudit) { 820 }
    850, 920, 960, 1040, 1060, 1070, 1080, 1140
)

& $oracle `
    -GameRoot $GameRoot `
    -OutputPath $telemetry `
    -SaveFixture $SavePath `
    -ScheduledCommand $scheduled `
    -PipBoyProbe `
    -VisibleGame `
    -IsolateFromFNVXR `
    -SampleEvery 2 `
    -BeforeFrame 830 `
    -CommandFrame 900 `
    -AfterFrame 1160 `
    -ScreenshotFrame $screenshotFrames `
    -ScreenshotDirectory $frames `
    -MaxFrames 1170 `
    -TimeoutSeconds $TimeoutSeconds

$events = @(Get-Content -LiteralPath $telemetry | ForEach-Object { $_ | ConvertFrom-Json })
$snapshots = @($events | Where-Object event -eq 'retail-pipboy-snapshot')
$commands = @($events | Where-Object event -eq 'scheduled-console-command')
$renderedOpenDispatches = @($events | Where-Object event -eq 'retail-pipboy-rendered-open-dispatched')
$backgroundModeEvents = @($events | Where-Object event -eq 'background-game-mode')
$rejected = @($commands | Where-Object { -not [bool]$_.accepted })
$nativeFrames = @(Get-ChildItem -LiteralPath $frames -Filter '*.bmp' -File | Sort-Object Name)

function Measure-PipBoyHeldFrame([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new($Path)
    try {
        # A retail held Pip-Boy fills the middle of the native backbuffer with
        # its opaque CRT and bezel. Sample a resolution-relative region so the
        # validator checks the rendered result instead of trusting menu state.
        $dark = 0
        $samples = 0
        $step = [Math]::Max(2, [int]($bitmap.Width / 220))
        for ($y = [int]($bitmap.Height * 0.12); $y -lt [int]($bitmap.Height * 0.72); $y += $step) {
            for ($x = [int]($bitmap.Width * 0.30); $x -lt [int]($bitmap.Width * 0.70); $x += $step) {
                $pixel = $bitmap.GetPixel($x, $y)
                $samples++
                if ($pixel.R -lt 75 -and $pixel.G -lt 75 -and $pixel.B -lt 75) {
                    $dark++
                }
            }
        }
        [pscustomobject][ordered]@{
            path = $Path
            samples = $samples
            darkFraction = if ($samples -gt 0) { $dark / $samples } else { 0.0 }
            screenDominant = $samples -gt 0 -and ($dark / $samples) -ge 0.75
        }
    }
    finally {
        $bitmap.Dispose()
    }
}
$firstPersonSnapshots = @($snapshots | Where-Object {
    $null -ne $_.player.firstPerson -and
    [bool]$_.player.firstPerson.available -and
    @($_.player.firstPerson.nodes).Count -gt 0
})
$messageDismissCommands = @($commands | Where-Object {
    $_.command -eq 'DismissBlockingMessageMenuOnce' -and [bool]$_.accepted
})
$beforeRaiseSnapshots = @($snapshots | Where-Object { $_.label -eq 'before-raise' })
$beforeRaiseHudOnly = $beforeRaiseSnapshots.Count -eq 1 -and
    [int]$beforeRaiseSnapshots[0].interface.pipBoyMode -eq 0 -and
    @($beforeRaiseSnapshots[0].interface.menuStack).Count -eq 0 -and
    @($beforeRaiseSnapshots[0].interface.visibleMenus).Count -eq 1 -and
    [int]$beforeRaiseSnapshots[0].interface.visibleMenus[0].type -eq 1004
$messageNeutralizationPass = $messageDismissCommands.Count -eq 1 -and
    [int]$messageDismissCommands[0].frame -lt 900 -and
    $backgroundModeEvents.Count -eq 0 -and $beforeRaiseHudOnly
$openSnapshots = @($snapshots | Where-Object {
    [int]$_.interface.pipBoyMode -eq 3 -and
    @($_.interface.visibleMenus | Where-Object { $_.type -eq 1003 }).Count -gt 0
})
$heldPipBoySnapshots = @($openSnapshots | Where-Object {
    [bool]$_.interface.physical.renderedOpen -and
    @($_.player.firstPerson.animDataSequences | Where-Object {
        $null -ne $_ -and [string]$_.file -match '(?i)pipboy.*\.kf$'
    }).Count -gt 0
})
$heldFrameEvidence = @($heldPipBoySnapshots | Where-Object { $_.label -eq 'held' } | ForEach-Object {
    $heldFramePath = Join-Path $frames ('frame-{0:D6}.bmp' -f [int]$_.frame)
    if (Test-Path -LiteralPath $heldFramePath -PathType Leaf) {
        Measure-PipBoyHeldFrame $heldFramePath
    }
})
$heldVisualPass = $heldFrameEvidence.Count -gt 0 -and
    @($heldFrameEvidence | Where-Object { -not $_.screenDominant }).Count -eq 0
$closedSnapshots = @($snapshots | Where-Object {
    [int]$_.frame -ge 1050 -and [int]$_.interface.pipBoyMode -eq 0
})
$afterLowerSnapshots = @($snapshots | Where-Object {
    $_.label -eq 'after-lower' -and
    [int]$_.interface.pipBoyMode -eq 0 -and
    @($_.interface.visibleMenus | Where-Object { $_.type -eq 1003 }).Count -eq 0 -and
    @($_.player.firstPerson.animDataSequences | Where-Object {
        $null -ne $_ -and [string]$_.file -match '(?i)pipboy.*\.kf$'
    }).Count -eq 0
})
$afterLowerFrameEvidence = @($afterLowerSnapshots | ForEach-Object {
    $afterLowerFramePath = Join-Path $frames ('frame-{0:D6}.bmp' -f [int]$_.frame)
    if (Test-Path -LiteralPath $afterLowerFramePath -PathType Leaf) {
        Measure-PipBoyHeldFrame $afterLowerFramePath
    }
})
$afterLowerVisualPass = $afterLowerFrameEvidence.Count -gt 0 -and
    @($afterLowerFrameEvidence | Where-Object { $_.screenDominant }).Count -eq 0
$heldStateSnapshots = @($snapshots | Where-Object {
    $_.label -in @('naturally-held', 'held')
})
$lowerMode4Snapshots = @($snapshots | Where-Object {
    [int]$_.frame -ge 1050 -and [int]$_.interface.pipBoyMode -eq 4
} | Sort-Object frame)
$lowerMode5Snapshots = @(if ($lowerMode4Snapshots.Count -gt 0) {
    $snapshots | Where-Object {
        [int]$_.frame -gt [int]$lowerMode4Snapshots[0].frame -and
        [int]$_.interface.pipBoyMode -eq 5
    } | Sort-Object frame
})
$lowerMode0Snapshots = @(if ($lowerMode5Snapshots.Count -gt 0) {
    $snapshots | Where-Object {
        [int]$_.frame -gt [int]$lowerMode5Snapshots[0].frame -and
        [int]$_.interface.pipBoyMode -eq 0
    } | Sort-Object frame
})
$nativeLowerLifecyclePass = $lowerMode4Snapshots.Count -gt 0 -and
    $lowerMode5Snapshots.Count -gt 0 -and $lowerMode0Snapshots.Count -gt 0
$weaponSnapshots = @($snapshots | Where-Object { $_.label -eq 'weapon-drawn' })
$weaponEquipCommands = @($commands | Where-Object {
    $_.targetForm -eq 0x14 -and $_.command -eq "EquipExact $weaponFormHex" -and [bool]$_.accepted
})
$weaponOutCommands = @($commands | Where-Object {
    $_.targetForm -eq 0x14 -and $_.command -eq 'SetWeaponOut 1' -and [bool]$_.accepted
})
$weaponSnapshotEquipped = if ($weaponSnapshots.Count -eq 1) { [uint32]$weaponSnapshots[0].player.equippedWeapon } else { 0 }
$weaponSnapshotFirstPerson = $weaponSnapshots.Count -eq 1 -and
    $null -ne $weaponSnapshots[0].player.firstPerson -and
    [bool]$weaponSnapshots[0].player.firstPerson.available -and
    @($weaponSnapshots[0].player.firstPerson.nodes).Count -gt 0
$weaponAuditPass = -not $WeaponAudit -or
    ($weaponSnapshots.Count -eq 1 -and $weaponEquipCommands.Count -eq 1 -and
        $weaponOutCommands.Count -ge 1 -and $weaponSnapshotEquipped -eq $weaponFormValue -and
        $weaponSnapshotFirstPerson)
$afterLowerPass = $afterLowerSnapshots.Count -gt 0 -and $afterLowerVisualPass

$passed = $rejected.Count -eq 0 -and
    $nativeFrames.Count -eq $screenshotFrames.Count -and
    $messageNeutralizationPass -and
    $renderedOpenDispatches.Count -eq 1 -and
    $firstPersonSnapshots.Count -gt 0 -and
    $openSnapshots.Count -gt 0 -and
    $heldPipBoySnapshots.Count -gt 0 -and
    $heldVisualPass -and
    $closedSnapshots.Count -gt 0 -and
    $afterLowerPass -and
    $nativeLowerLifecyclePass -and
    $heldStateSnapshots.Count -eq 2 -and
    $weaponAuditPass

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
        method = 'xNVSE-scheduled native lifecycle calls plus Direct3D 9 backbuffer and per-frame first-person scene graph'
        driver = 'in-process xNVSE call to native InterfaceManager OpenPipboy/ClosePipboy; retail-owned lifecycle'
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        sourceFramesRetained = $true
        telemetryRetained = $true
        weaponAudit = [bool]$WeaponAudit
    }
    assertions = [pscustomobject][ordered]@{
        scheduledCommands = $commands.Count
        rejectedCommands = $rejected.Count
        requestedNativeFrames = $screenshotFrames.Count
        retainedNativeFrames = $nativeFrames.Count
        messageMenuNeutralization = [ordered]@{
            acceptedCommands = $messageDismissCommands.Count
            frame = if ($messageDismissCommands.Count -eq 1) { [int]$messageDismissCommands[0].frame } else { $null }
            backgroundCloseEvents = $backgroundModeEvents.Count
            beforeRaiseHudOnly = [bool]$beforeRaiseHudOnly
            passed = [bool]$messageNeutralizationPass
        }
        renderedOpenCallbackDispatches = $renderedOpenDispatches.Count
        firstPersonSnapshots = $firstPersonSnapshots.Count
        renderedStatsOpenSnapshots = $openSnapshots.Count
        nativeRenderedPipBoySnapshots = $heldPipBoySnapshots.Count
        heldVisualEvidence = @($heldFrameEvidence)
        heldVisualPass = [bool]$heldVisualPass
        closedSnapshots = $closedSnapshots.Count
        verifiedAfterLowerSnapshots = $afterLowerSnapshots.Count
        afterLowerVisualEvidence = @($afterLowerFrameEvidence)
        afterLowerVisualPass = [bool]$afterLowerVisualPass
        afterLowerRequired = $true
        completePipBoyLowerVerified = [bool]$afterLowerPass
        nativeLowerLifecycle = [ordered]@{
            mode4Frame = if ($lowerMode4Snapshots.Count -gt 0) { [int]$lowerMode4Snapshots[0].frame } else { $null }
            mode5Frame = if ($lowerMode5Snapshots.Count -gt 0) { [int]$lowerMode5Snapshots[0].frame } else { $null }
            mode0Frame = if ($lowerMode0Snapshots.Count -gt 0) { [int]$lowerMode0Snapshots[0].frame } else { $null }
            passed = [bool]$nativeLowerLifecyclePass
        }
        namedHeldStateSnapshots = $heldStateSnapshots.Count
        weaponAudit = [ordered]@{
            requested = [bool]$WeaponAudit
            form = ('0x{0:X8}' -f $weaponFormValue)
            snapshots = $weaponSnapshots.Count
            acceptedEquipCommands = $weaponEquipCommands.Count
            acceptedWeaponOutCommands = $weaponOutCommands.Count
            equippedForm = ('0x{0:X8}' -f $weaponSnapshotEquipped)
            firstPersonSceneGraph = [bool]$weaponSnapshotFirstPerson
            passed = [bool]$weaponAuditPass
        }
    }
    artifacts = @($artifacts)
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
if (-not $passed) {
    throw "Retail Pip-Boy state capture failed validation. See $reportPath"
}
$report
