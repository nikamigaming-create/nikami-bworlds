[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EvidenceRoot,
    [string]$ReportPath = '',
    [switch]$CaptureCleanExit,
    [string]$WrapperFailure = '',
    [string]$VisualInspectionNote = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$evidenceRootPath = [IO.Path]::GetFullPath($EvidenceRoot)
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $evidenceRootPath 'retail-doc-container-report.json'
}
$reportPathValue = [IO.Path]::GetFullPath($ReportPath)
$telemetryPath = Join-Path $evidenceRootPath 'retail-doc-container.jsonl'
$modulePath = Join-Path $evidenceRootPath 'retail-doc-container-loaded-modules.json'
$nativeFrameRoot = Join-Path $evidenceRootPath 'native-frames'
foreach ($path in @($telemetryPath, $modulePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Retail container evidence is missing: $path"
    }
}
if (Test-Path -LiteralPath $reportPathValue) {
    throw "Refusing to overwrite retail container evidence report: $reportPathValue"
}

$targetReference = [uint32]0x00103E37
$targetBase = [uint32]0x0002FCC3
$targetCell = [uint32]0x00103DF9
$events = @(Get-Content -LiteralPath $telemetryPath | ForEach-Object { $_ | ConvertFrom-Json })
$commands = @($events | Where-Object event -eq 'scheduled-console-command')
$snapshots = @($events | Where-Object event -eq 'retail-container-store-snapshot')
$activations = @($events | Where-Object event -eq 'retail-container-native-activation')
$transfers = @($events | Where-Object event -eq 'retail-container-native-transfer')
$loadResults = @($events | Where-Object event -eq 'load-result')
$captureCompletions = @($events | Where-Object event -eq 'capture-complete')
$moduleReport = Get-Content -Raw -LiteralPath $modulePath | ConvertFrom-Json
$nativeFrames = @(Get-ChildItem -LiteralPath $nativeFrameRoot -Filter 'frame-*.bmp' -File -ErrorAction Stop)

function Get-OnlySnapshot([string]$Label) {
    $matches = @($snapshots | Where-Object label -eq $Label)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one retail container snapshot '$Label'; found $($matches.Count)."
    }
    $matches[0]
}

function Get-StoreCount($Snapshot, [uint32]$Form) {
    $matches = @($Snapshot.store.items | Where-Object { [uint32]$_.form -eq $Form })
    if ($matches.Count -gt 1) {
        throw "Container store contains duplicate form $Form."
    }
    if ($matches.Count -eq 0) { return [int64]0 }
    [int64]$matches[0].count
}

$resolvedBefore = Get-OnlySnapshot 'resolved-before-activate'
$activeBefore = Get-OnlySnapshot 'active-before-take'
$activeAfter = Get-OnlySnapshot 'active-after-take'
$afterReload = Get-OnlySnapshot 'after-reload'
$transfer = if ($transfers.Count -eq 1) { $transfers[0] } else { $null }
$selectedForm = if ($null -ne $transfer) { [uint32]$transfer.selectedForm } else { [uint32]0 }
$containerBefore = Get-StoreCount $activeBefore $selectedForm
$containerAfter = Get-StoreCount $activeAfter $selectedForm
$containerReloaded = Get-StoreCount $afterReload $selectedForm
$resolvedLeveledItems = @($activeBefore.store.items | Where-Object {
    [bool]$_.resolvedFromLeveledList -and [int64]$_.count -gt 0
})

$targetContractPass = @(@($resolvedBefore, $activeBefore, $activeAfter, $afterReload) | Where-Object {
    [uint32]$_.targetReference -eq $targetReference -and
    [uint32]$_.store.baseForm -eq $targetBase -and
    [uint32]$_.store.parentCell -eq $targetCell -and
    [bool]$_.store.available
}).Count -eq 4
$activeStorePass = [bool]$activeBefore.interface.containerMenuReadable -and
    [bool]$activeBefore.interface.containerMenuVisible -and
    [bool]$activeBefore.store.runtimeChangesAvailable -and
    [int]$activeBefore.store.authoredLeveledListRows -eq 3 -and
    $resolvedLeveledItems.Count -gt 0
$activationPass = $activations.Count -eq 1 -and [bool]$activations[0].accepted -and
    [uint32]$activations[0].targetReference -eq $targetReference -and
    [uint32]$activations[0].entryPoint -eq [uint32]0x00573170
$transferPass = $null -ne $transfer -and [bool]$transfer.invoked -and
    [bool]$transfer.transferred -and $selectedForm -ne 0 -and
    [int64]$transfer.containerDelta -eq -1 -and [int64]$transfer.playerDelta -eq 1 -and
    $containerAfter -eq ($containerBefore - 1)
$reloadPass = $loadResults.Count -eq 2 -and
    @($loadResults | Where-Object { -not [bool]$_.succeeded }).Count -eq 0 -and
    $containerReloaded -eq $containerAfter
$captureCompletePass = $captureCompletions.Count -eq 1 -and
    [int]$captureCompletions[0].frames -ge 860
$moduleWhitelistPass = [string]$moduleReport.schema -eq 'nikami-fnv-retail-shadow-loaded-modules/v1' -and
    [string]$moduleReport.status -eq 'pass' -and
    [bool]$moduleReport.process.exactShadowExecutable -and
    @($moduleReport.assertions.prohibitedModules).Count -eq 0 -and
    @($moduleReport.assertions.unexpectedPlugins).Count -eq 0 -and
    @($moduleReport.assertions.shadowDataPluginFiles).Count -eq 0 -and
    [int]$moduleReport.assertions.isolatedOraclePluginCount -eq 1 -and
    [int]$moduleReport.assertions.loadedOracleModuleCount -eq 1 -and
    [bool]$moduleReport.assertions.oracleModuleMatchesIsolatedPlugin -and
    [bool]$moduleReport.assertions.nvseCoreInExternalRuntime -and
    @($moduleReport.assertions.retailDataPluginModules).Count -eq 0

$framePass = $false
$frameEvidence = $null
if ($nativeFrames.Count -eq 1) {
    $frameBytes = [IO.File]::ReadAllBytes($nativeFrames[0].FullName)
    $width = if ($frameBytes.Length -ge 30) { [BitConverter]::ToInt32($frameBytes, 18) } else { 0 }
    $height = if ($frameBytes.Length -ge 30) { [Math]::Abs([BitConverter]::ToInt32($frameBytes, 22)) } else { 0 }
    $bitsPerPixel = if ($frameBytes.Length -ge 30) { [BitConverter]::ToUInt16($frameBytes, 28) } else { 0 }
    $framePass = $frameBytes.Length -ge 54 -and $frameBytes[0] -eq 0x42 -and
        $frameBytes[1] -eq 0x4D -and $width -eq 1280 -and $height -eq 720 -and
        $bitsPerPixel -eq 32
    $frameEvidence = [pscustomobject][ordered]@{
        path = $nativeFrames[0].FullName
        bytes = $nativeFrames[0].Length
        sha256 = (Get-FileHash -LiteralPath $nativeFrames[0].FullName -Algorithm SHA256).Hash
        width = $width
        height = $height
        bitsPerPixel = $bitsPerPixel
    }
}

$saveCommands = @($commands | Where-Object { [string]$_.command -match '^Save (?<stem>NikamiDocContainer-[A-Za-z0-9-]+)$' })
$loadCommands = @($commands | Where-Object { [string]$_.command -match '^LoadGame "NikamiDocContainer-[A-Za-z0-9-]+"$' })
$generatedSaveStem = if ($saveCommands.Count -eq 1) {
    [regex]::Match([string]$saveCommands[0].command, '^Save (?<stem>.+)$').Groups['stem'].Value
} else { '' }
$saveDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FalloutNV\Saves'
$generatedSavePaths = if ([string]::IsNullOrWhiteSpace($generatedSaveStem)) { @() } else {
    @('.fos', '.nvse', '.bak', '.fos.bak') | ForEach-Object {
        Join-Path $saveDirectory ($generatedSaveStem + $_)
    }
}
$generatedSaveRemoved = $generatedSavePaths.Count -gt 0 -and
    @($generatedSavePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0
$saveReloadPass = $saveCommands.Count -eq 1 -and [bool]$saveCommands[0].accepted -and
    $loadCommands.Count -eq 1 -and [bool]$loadCommands[0].accepted -and $reloadPass

$scheduledCommandsPass = $commands.Count -eq 10 -and
    @($commands | Where-Object { -not [bool]$_.accepted }).Count -eq 0
$contractPass = $scheduledCommandsPass -and $targetContractPass -and $activeStorePass -and
    $activationPass -and $transferPass -and $saveReloadPass -and $captureCompletePass -and
    $moduleWhitelistPass -and $framePass -and $generatedSaveRemoved
$canonicalCapturePass = $contractPass -and [bool]$CaptureCleanExit

$artifacts = @($telemetryPath, $modulePath) + @($nativeFrames.FullName)
$report = [pscustomobject][ordered]@{
    schema = 'nikami-retail-doc-container-evidence/v1'
    status = if ($canonicalCapturePass) { 'pass' } elseif ($contractPass) {
        'contract-pass-capture-wrapper-failed'
    } else { 'fail' }
    contractStatus = if ($contractPass) { 'pass' } else { 'fail' }
    canonicalCaptureStatus = if ($canonicalCapturePass) { 'pass' } else { 'fail' }
    captureCleanExit = [bool]$CaptureCleanExit
    wrapperFailure = if ([string]::IsNullOrWhiteSpace($WrapperFailure)) { $null } else { $WrapperFailure }
    scope = [pscustomobject][ordered]@{
        targetReference = ('0x{0:X8}' -f $targetReference)
        targetBase = ('0x{0:X8}' -f $targetBase)
        targetCell = ('0x{0:X8}' -f $targetCell)
        proofStaging = 'COC GSDocMitchellHouse'
        naturalRouteClaimed = $false
        presentationParityClaimed = $false
        menuRowSelectionClaimed = $false
    }
    capture = [pscustomobject][ordered]@{
        method = 'in-process xNVSE native activation/transfer plus read-only retail store telemetry'
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        menuKeyInjectionUsed = $false
        bindingHoldInjectionUsed = $false
        nativeSourceFrameRetained = [bool]$framePass
        liveModuleWhitelistVerified = [bool]$moduleWhitelistPass
    }
    assertions = [pscustomobject][ordered]@{
        scheduledCommandsPass = [bool]$scheduledCommandsPass
        targetContractPass = [bool]$targetContractPass
        nativeActivationPass = [bool]$activationPass
        activeContainerStorePass = [bool]$activeStorePass
        resolvedLeveledItems = $resolvedLeveledItems.Count
        selectedForm = ('0x{0:X8}' -f $selectedForm)
        containerBefore = $containerBefore
        containerAfter = $containerAfter
        playerDelta = if ($null -ne $transfer) { [int64]$transfer.playerDelta } else { 0 }
        nativeTransferPass = [bool]$transferPass
        successfulLoadResults = @($loadResults | Where-Object succeeded).Count
        afterReloadCount = $containerReloaded
        persistencePass = [bool]$saveReloadPass
        captureCompletePass = [bool]$captureCompletePass
        liveModuleWhitelistPass = [bool]$moduleWhitelistPass
        nativeFramePass = [bool]$framePass
        generatedSaveStem = $generatedSaveStem
        generatedSaveRemoved = [bool]$generatedSaveRemoved
    }
    nativeFrame = $frameEvidence
    visualInspection = [pscustomobject][ordered]@{
        performed = -not [string]::IsNullOrWhiteSpace($VisualInspectionNote)
        note = if ([string]::IsNullOrWhiteSpace($VisualInspectionNote)) { $null } else { $VisualInspectionNote }
    }
    artifacts = @($artifacts | ForEach-Object {
        $file = Get-Item -LiteralPath $_
        [pscustomobject][ordered]@{
            path = $file.FullName
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    })
}
[IO.File]::WriteAllText(
    $reportPathValue,
    ($report | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))
$report
