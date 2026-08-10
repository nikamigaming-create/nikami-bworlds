[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$WorldsRoot = "D:\code\nikami-worlds",
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
    '850:PipBoySnapshot before-raise'
    '860:PipBoyTreeSnapshot before-raise'
    '900:OpenPipBoyRetail'
    '920:PipBoySnapshot raising'
    # In an unattended background session the animation reaches retail mode 3,
    # but its terminal animation event is not dispatched. Invoke only that
    # missed retail rendered-menu callback once; lifecycle state remains native.
    '944:OpenPipBoyRenderedManagerOnce'
    '946:PipBoySnapshot rendered-held'
    '950:PipBoySnapshot naturally-held'
    '970:MenuTapKey 60' # F2 / ITEMS through retail buffered menu input
    '980:PipBoySnapshot items'
    '982:PipBoyTreeSnapshot items'
    '990:MenuTapKey 208' # Down / list scroll
    '1000:PipBoySnapshot items-down'
    '1002:PipBoyTreeSnapshot items-down'
    '1010:MenuTapKey 61' # F3 / DATA
    '1020:PipBoySnapshot data'
    '1022:PipBoyTreeSnapshot data'
    '1030:MenuTapKey 59' # F1 / STATS
    '1040:PipBoySnapshot held'
    '1042:PipBoyTreeSnapshot held'
    # The audit route uses retail's native close entrypoint after the reference
    # frame. The normal Pip-Boy reference retains its native Tab-key lifecycle.
))
$scheduledList.Add($(if ($WeaponAudit) { '1050:ClosePipBoyRetail' } else { '1050:HoldKey 15' }))
if (-not $WeaponAudit) {
    $scheduledList.Add('1054:ReleaseKey 15')
}
if ($WeaponAudit) {
    $scheduledList.Add('1070:ClosePipBoyRenderedManagerOnce')
}
$scheduledList.AddRange([string[]]@(
    '1080:PipBoySnapshot lowering'
    '1140:PipBoySnapshot after-lower'
    '1142:PipBoyTreeSnapshot after-lower'
))
$scheduled = $scheduledList.ToArray()
$screenshotFrames = @(
    if ($WeaponAudit) { 820 }
    840..1150 | Where-Object { ($_ % 2) -eq 0 }
)

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
    -AfterFrame 1160 `
    -ScreenshotFrame $screenshotFrames `
    -ScreenshotDirectory $frames `
    -MaxFrames 1170 `
    -TimeoutSeconds $TimeoutSeconds

$events = @(Get-Content -LiteralPath $telemetry | ForEach-Object { $_ | ConvertFrom-Json })
$snapshots = @($events | Where-Object event -eq 'retail-pipboy-snapshot')
$commands = @($events | Where-Object event -eq 'scheduled-console-command')
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
    [int]$_.interface.pipBoyMode -ne 3
})
$afterLowerSnapshots = @($snapshots | Where-Object {
    $_.label -eq 'after-lower' -and
    [int]$_.interface.pipBoyMode -ne 3 -and
    -not [bool]$_.interface.physical.renderedOpen
})
$navigationSnapshots = @($snapshots | Where-Object {
    $_.label -in @('items', 'items-down', 'data', 'held')
})
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
$afterLowerPass = $afterLowerSnapshots.Count -gt 0

# A weapon-reference run proves the drawn retail pose plus the native opened
# Pip-Boy/navigation surface. It deliberately does not promote the lower
# callback as a complete lifecycle assertion; the ordinary no-WeaponAudit
# route remains the full raise/close reference.
$passed = $rejected.Count -eq 0 -and
    $nativeFrames.Count -eq $screenshotFrames.Count -and
    $firstPersonSnapshots.Count -gt 0 -and
    $openSnapshots.Count -gt 0 -and
    $heldPipBoySnapshots.Count -gt 0 -and
    $heldVisualPass -and
    $closedSnapshots.Count -gt 0 -and
    ($WeaponAudit -or $afterLowerPass) -and
    $navigationSnapshots.Count -eq 4 -and
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
        method = 'xNVSE-scheduled retail input plus native Direct3D 9 backbuffer and per-frame first-person scene graph'
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
        firstPersonSnapshots = $firstPersonSnapshots.Count
        renderedStatsOpenSnapshots = $openSnapshots.Count
        nativeRenderedPipBoySnapshots = $heldPipBoySnapshots.Count
        heldVisualEvidence = @($heldFrameEvidence)
        heldVisualPass = [bool]$heldVisualPass
        closedSnapshots = $closedSnapshots.Count
        verifiedAfterLowerSnapshots = $afterLowerSnapshots.Count
        afterLowerRequired = -not [bool]$WeaponAudit
        completePipBoyLowerVerified = [bool]$afterLowerPass
        namedNavigationSnapshots = $navigationSnapshots.Count
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
