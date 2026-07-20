param(
    [string]$GameRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas",
    [string]$RuntimeRoot = "local\xnvse-retail-oracle",
    [string]$PluginDll = "local\xnvse-retail-oracle\plugins\nvse_retail_oracle.dll",
    [string]$OutputPath = "run\retail-oracle\fnv-goodsprings-behavior.jsonl",
    [string]$SaveName = "Save 222     Goodsprings  00 01 36",
    [string]$SaveFixture = "",
    [string[]]$QuestForm = @("0x00102037", "0x00104C1C", "0x0010A214", "0x0015D912"),
    [string[]]$GlobalForm = @("0x35", "0x36", "0x37", "0x38", "0x39", "0x3A"),
    [Alias('GMST')]
    [string[]]$GameSetting = @(),
    [string[]]$Command = @(),
    [string[]]$ScheduledCommand = @(),
    [string[]]$ActorCommand = @(),
    [string]$SetStageQuestForm = "0",
    [int]$SetStageIndex = 65535,
    [int]$BeforeFrame = 10,
    [int]$CommandFrame = 20,
    [int]$AfterFrame = 30,
    [int]$MaxFrames = 40,
    [int]$TimeoutSeconds = 55,
    [string]$PlanPath = "",
    [string]$SharedMemoryName = "",
    [ValidateRange(1000, 300000)]
    [int]$BarrierTimeoutMilliseconds = 30000,
    [int]$SampleEvery = 1,
    [string]$TargetForm = "0",
    [string]$ExpectedTargetBaseForm = "0",
    [string]$ObserverApproachForm = "0",
    [float]$ObserverApproachStopDistance = 1400,
    [float]$ObserverApproachStepDistance = 64,
    [string[]]$ObserverWaypoint = @(),
    [string]$EquipForm = "0",
    [string]$PlayGroup = "",
    [string]$DriveCommand = "",
    [int]$PrepareActorFrame = 60,
    [int]$EquipActorFrame = 60,
    [int]$DriveActorFrame = 180,
    [int]$FootIkToggleFrame = 0,
    [ValidateSet(-1, 0, 1)]
    [int]$FootIkToggleEnabled = -1,
    [switch]$FurnitureOnly,
    [string[]]$FurnitureSettledCommand = @(),
    [switch]$ExitAfterFurnitureRelease,
    [int]$ExitAfterFurnitureSettledSamples = 0,
    [int]$FurnitureReleaseSamples = 3,
    [switch]$BackgroundDataMode,
    [switch]$VisibleGame,
    [switch]$IsolateFromFNVXR,
    [switch]$AllowRootHookDlls,
    [Alias("ValidateOnly", "NoLaunch")]
    [switch]$DryRun,
    [switch]$CaptureSession,
    [string]$SessionTargetForm = "0",
    [switch]$CaptureAnimation,
    [int[]]$ScreenshotFrame = @(),
    [string]$ScreenshotDirectory = "",
    [switch]$MaterialShaderCapture,
    [ValidateRange(1, 1000000)]
    [int]$MaterialShaderFrame = 30,
    [switch]$PortraitCamera,
    [ValidateRange(32, 1000)]
    [float]$PortraitDistance = 110,
    [ValidateSet('front-portrait', 'front-full-body')]
    [string]$CameraShotKind = 'front-portrait',
    [ValidateRange(1.25, 10)]
    [float]$FullBodyDistanceScale = 1.6,
    [switch]$RequireAppearanceTelemetry,
    [string[]]$BatchTargetForm = @(),
    [string[]]$BatchExpectedBaseForm = @(),
    [ValidateRange(1, 600)]
    [int]$BatchSettleFrames = 20,
    [ValidateRange(1, 60)]
    [int]$BatchAdvanceFrames = 3,
    [switch]$BatchMoveToTargets,
    [switch]$BatchEnableTargets,
    [switch]$BatchProofStaging,
    [string]$BatchProofAnchorForm = '0',
    [float]$BatchProofTargetX = 0,
    [float]$BatchProofTargetY = 0,
    [float]$BatchProofTargetZ = 0,
    [float]$BatchProofTargetYaw = 0,
    [float]$BatchProofPlayerX = 0,
    [float]$BatchProofPlayerY = 0,
    [float]$BatchProofPlayerZ = 0,
    [ValidateRange(0, 512)]
    [float]$BatchProofMinimumCameraHeight = 48,
    [ValidateRange(0, 512)]
    [float]$BatchProofMinimumAimHeight = 16,
    [ValidateRange(1, 1200)]
    [int]$BatchProofInitializationFrames = 30,
    [ValidateRange(1, 600)]
    [int]$BatchProofTargetSettleFrames = 15,
    [switch]$BatchForceWeaponOut,
    [ValidateRange(1, 600)]
    [int]$BatchWeaponProbeFrames = 12,
    [string[]]$BatchEnableParentForm = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$evidenceHelperPath = Join-Path $PSScriptRoot 'FNVRetailOracleEvidence.ps1'
if (-not (Test-Path -LiteralPath $evidenceHelperPath -PathType Leaf)) {
    throw "Missing retail-oracle evidence helper: $evidenceHelperPath"
}
. $evidenceHelperPath

function Resolve-AbsolutePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function ConvertFrom-SidecarPlanUInt([string]$Text, [string]$Context) {
    if ($Text -notmatch '^(?:0[xX][0-9a-fA-F]{1,8}|[0-9]{1,10})$') {
        throw "$Context is not a canonical unsigned 32-bit integer."
    }
    try {
        $value = if ($Text -match '^0[xX]') {
            [Convert]::ToUInt32($Text.Substring(2), 16)
        } else {
            [uint32]::Parse($Text, [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture)
        }
    }
    catch { throw "$Context exceeds the unsigned 32-bit range." }
    return [uint32]$value
}

function ConvertFrom-SidecarPlanFloat([string]$Text, [string]$Context) {
    $value = 0.0
    if (-not [double]::TryParse($Text, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or
        [double]::IsNaN($value) -or [double]::IsInfinity($value)) {
        throw "$Context is not a finite invariant floating-point value."
    }
    return [double]$value
}

function Test-PathWithinRoot([string]$Path, [string]$Root, [switch]$AllowRoot) {
    $absolutePath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $absoluteRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($absolutePath.Equals($absoluteRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [bool]$AllowRoot
    }
    $rootPrefix = $absoluteRoot + [System.IO.Path]::DirectorySeparatorChar
    return $absolutePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-FileWithRetry([string]$Path, [int]$TimeoutMilliseconds = 5000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $Path)) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out removing file: $Path"
}

function Remove-DirectoryWithRetry([string]$Path, [int]$TimeoutMilliseconds = 15000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 150
        }
        if (-not (Test-Path -LiteralPath $Path)) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out removing directory: $Path"
}

function Complete-FNVProcessHandle(
    [System.Diagnostics.Process]$Process,
    [string]$Label,
    [int]$GraceMilliseconds = 5000
) {
    if ($null -eq $Process) { return }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            if (-not $Process.WaitForExit($GraceMilliseconds)) {
                $Process.Kill()
                if (-not $Process.WaitForExit($GraceMilliseconds)) {
                    throw "$Label did not exit within $GraceMilliseconds ms after Kill()."
                }
            }
        }
        # The parameterless overload completes native process-handle cleanup
        # after the process has signaled, including the fast launcher process.
        $Process.WaitForExit()
    }
    finally {
        $Process.Dispose()
    }
}

function Convert-FNVRawFramebufferToBmp(
    [string]$Path,
    [string]$OutputPath,
    [int]$Width,
    [int]$Height,
    [string]$RowOrder,
    [string]$ChannelOrder
) {
    if ($Width -lt 1 -or $Height -lt 1 -or $ChannelOrder -ne 'BGRA8' -or
        $RowOrder -notin @('top-to-bottom', 'bottom-to-top')) {
        throw "Unsupported raw framebuffer layout: ${Width}x${Height} $RowOrder $ChannelOrder"
    }
    $pixels = [System.IO.File]::ReadAllBytes($Path)
    $rowBytes = [int64]$Width * 4
    $expectedBytes = $rowBytes * [int64]$Height
    if ($pixels.Length -ne $expectedBytes) {
        throw "Raw framebuffer byte count mismatch for $Path (expected $expectedBytes, got $($pixels.Length))."
    }
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap(
        $Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rectangle = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
    $data = $bitmap.LockBits(
        $rectangle,
        [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        for ($destinationRow = 0; $destinationRow -lt $Height; ++$destinationRow) {
            $sourceRow = if ($RowOrder -eq 'top-to-bottom') {
                $destinationRow
            } else {
                $Height - 1 - $destinationRow
            }
            $destinationOffset = if ($data.Stride -ge 0) {
                $destinationRow * $data.Stride
            } else {
                ($Height - 1 - $destinationRow) * (-$data.Stride)
            }
            $destination = [IntPtr]::Add($data.Scan0, $destinationOffset)
            [System.Runtime.InteropServices.Marshal]::Copy(
                $pixels, $sourceRow * $rowBytes, $destination, $rowBytes)
        }
    }
    finally {
        $bitmap.UnlockBits($data)
    }
    try {
        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Get-ManifestRuntimeFile(
    [object]$Manifest,
    [string]$Key,
    [string]$ExpectedRelativePath,
    [string]$RuntimeRootPath
) {
    if ($null -eq $Manifest.files -or
        -not ($Manifest.files.PSObject.Properties.Name -contains $Key)) {
        throw "Isolated xNVSE runtime manifest is missing files.$Key."
    }
    $entry = $Manifest.files.$Key
    if ($null -eq $entry -or
        -not ($entry.PSObject.Properties.Name -contains 'path') -or
        -not ($entry.PSObject.Properties.Name -contains 'sha256')) {
        throw "Isolated xNVSE runtime manifest files.$Key must declare path and sha256."
    }
    $declaredRelativePath = ([string]$entry.path).Replace('/', '\')
    if (-not $declaredRelativePath.Equals(
        $ExpectedRelativePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Isolated xNVSE runtime manifest files.$Key must use path '$ExpectedRelativePath'."
    }
    $absolutePath = [System.IO.Path]::GetFullPath((Join-Path $RuntimeRootPath $declaredRelativePath))
    if (-not (Test-PathWithinRoot -Path $absolutePath -Root $RuntimeRootPath)) {
        throw "Isolated xNVSE runtime file escapes RuntimeRoot: $absolutePath"
    }
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        throw "Missing isolated xNVSE runtime file: $absolutePath"
    }
    $declaredHash = ([string]$entry.sha256).ToLowerInvariant()
    if ($declaredHash -notmatch '^[0-9a-f]{64}$') {
        throw "Isolated xNVSE runtime manifest files.$Key has an invalid SHA-256."
    }
    $actualHash = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $declaredHash) {
        throw "Isolated xNVSE runtime hash mismatch for files.$Key ($absolutePath)."
    }
    return $absolutePath
}

if ($BeforeFrame -lt 1 -or $CommandFrame -le $BeforeFrame -or $AfterFrame -le $CommandFrame) {
    throw "Expected 0 < BeforeFrame < CommandFrame < AfterFrame."
}
if ($MaxFrames -lt $AfterFrame) {
    throw "MaxFrames must be greater than or equal to AfterFrame."
}
$planMode = -not [string]::IsNullOrWhiteSpace($PlanPath)
if ($planMode -ne (-not [string]::IsNullOrWhiteSpace($SharedMemoryName))) {
    throw "PlanPath and SharedMemoryName must be supplied together."
}
if ($TimeoutSeconds -lt 10 -or $TimeoutSeconds -gt 86400) {
    throw "TimeoutSeconds must be between 10 and 86400."
}
if ($SampleEvery -lt 1) {
    throw "SampleEvery must be positive."
}
if ($MaterialShaderCapture -and $MaterialShaderFrame -gt $MaxFrames) {
    throw "MaterialShaderFrame must be less than or equal to MaxFrames."
}
foreach ($form in @($TargetForm, $ExpectedTargetBaseForm, $ObserverApproachForm, $EquipForm, $SessionTargetForm)) {
    if ($form -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$') {
        throw "Expected a decimal or 0x-prefixed FormID, got: $form"
    }
    try { ConvertTo-FNVFormId $form | Out-Null }
    catch { throw "Expected a 32-bit decimal or 0x-prefixed FormID, got: $form" }
}
if ($ObserverApproachStopDistance -lt 64) {
    throw "ObserverApproachStopDistance must be at least 64 world units."
}
if ($ObserverApproachStepDistance -lt 1 -or $ObserverApproachStepDistance -gt 256) {
    throw "ObserverApproachStepDistance must be between 1 and 256 world units."
}
if ($PlayGroup -notmatch '^[A-Za-z0-9_]*$') {
    throw "PlayGroup may contain only ASCII letters, digits, and underscores."
}
if ($CaptureAnimation -and ($PrepareActorFrame -lt 1 -or $PrepareActorFrame -gt $MaxFrames)) {
    throw "PrepareActorFrame must be between 1 and MaxFrames for animation capture."
}
if ($CaptureAnimation -and
    (-not [string]::IsNullOrWhiteSpace($PlayGroup) -or -not [string]::IsNullOrWhiteSpace($DriveCommand)) -and
    ($EquipActorFrame -lt $PrepareActorFrame -or $DriveActorFrame -lt $EquipActorFrame -or
        $DriveActorFrame -gt $MaxFrames)) {
    throw "Expected PrepareActorFrame <= EquipActorFrame <= DriveActorFrame <= MaxFrames when PlayGroup is set."
}
if ($FootIkToggleFrame -lt 0 -or ($FootIkToggleFrame -gt 0 -and
    ($FootIkToggleFrame -lt $PrepareActorFrame -or $FootIkToggleFrame -gt $MaxFrames))) {
    throw "FootIkToggleFrame must be zero or between PrepareActorFrame and MaxFrames."
}
if (($FootIkToggleFrame -eq 0) -ne ($FootIkToggleEnabled -eq -1)) {
    throw "FootIkToggleFrame and FootIkToggleEnabled must be specified together."
}
if ($ExitAfterFurnitureRelease -and (-not $FurnitureOnly -or $TargetForm -match '^(0[xX]0+|0+)$')) {
    throw "ExitAfterFurnitureRelease requires FurnitureOnly and a nonzero TargetForm."
}
if ($FurnitureReleaseSamples -lt 1) {
    throw "FurnitureReleaseSamples must be positive."
}
if ($ExitAfterFurnitureSettledSamples -lt 0) {
    throw "ExitAfterFurnitureSettledSamples cannot be negative."
}
if ($ExitAfterFurnitureSettledSamples -gt 0 -and
    (-not $FurnitureOnly -or $TargetForm -match '^(0[xX]0+|0+)$')) {
    throw "ExitAfterFurnitureSettledSamples requires FurnitureOnly and a nonzero TargetForm."
}
if ($ExitAfterFurnitureRelease -and $ExitAfterFurnitureSettledSamples -gt 0) {
    throw "Choose one furniture completion condition: settled samples or release."
}
foreach ($entry in @($Command) + @($ActorCommand) + @($FurnitureSettledCommand)) {
    if ($entry -match '[|\r\n]') {
        throw "Retail oracle commands cannot contain pipe or newline characters: $entry"
    }
}
$GameSetting = @($GameSetting)
foreach ($editorId in $GameSetting) {
    if ($editorId -notmatch '^[A-Za-z][A-Za-z0-9_]{0,255}$') {
        throw "GameSetting must be a canonical GMST editor ID: $editorId"
    }
}
$canonicalGameSettings = @($GameSetting | ForEach-Object { $_.ToLowerInvariant() })
if (@($canonicalGameSettings | Select-Object -Unique).Count -ne $canonicalGameSettings.Count) {
    throw 'GameSetting contains duplicate editor IDs.'
}
foreach ($waypoint in @($ObserverWaypoint)) {
    if ($waypoint -notmatch '^-?[0-9]+(?:\.[0-9]+)?,-?[0-9]+(?:\.[0-9]+)?$') {
        throw "ObserverWaypoint must be an X,Y numeric pair: $waypoint"
    }
}
if ($DriveCommand -match '[|\r\n]') {
    throw "Retail oracle drive command cannot contain pipe or newline characters: $DriveCommand"
}
$requestedScreenshotFrames = @($ScreenshotFrame)
$ScreenshotFrame = @($ScreenshotFrame | Sort-Object -Unique)
if ($ScreenshotFrame.Count -ne $requestedScreenshotFrames.Count) {
    throw "ScreenshotFrame contains duplicate frame identities."
}
$BatchTargetForm = @($BatchTargetForm)
$BatchExpectedBaseForm = @($BatchExpectedBaseForm)
$BatchEnableParentForm = @($BatchEnableParentForm)
foreach ($frame in $ScreenshotFrame) {
    if ($frame -lt 1 -or $frame -gt $MaxFrames) {
        throw "ScreenshotFrame must be between 1 and MaxFrames: $frame"
    }
}
if ($PortraitCamera -and $TargetForm -match '^(0[xX]0+|0+)$') {
    throw "PortraitCamera requires a nonzero TargetForm."
}
if ($CameraShotKind -eq 'front-full-body' -and -not $PortraitCamera -and
    $BatchTargetForm.Count -eq 0 -and -not $planMode) {
    throw "CameraShotKind front-full-body requires PortraitCamera or BatchTargetForm."
}
if ($ExpectedTargetBaseForm -notmatch '^(0[xX]0+|0+)$' -and
    $TargetForm -match '^(0[xX]0+|0+)$') {
    throw "ExpectedTargetBaseForm requires a nonzero TargetForm."
}
foreach ($form in $BatchTargetForm) {
    if ($form -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$' -or $form -match '^(0[xX]0+|0+)$') {
        throw "BatchTargetForm requires nonzero decimal or 0x-prefixed FormIDs, got: $form"
    }
    try { ConvertTo-FNVFormId $form | Out-Null }
    catch { throw "BatchTargetForm requires 32-bit FormIDs, got: $form" }
}
$canonicalBatchTargets = @($BatchTargetForm | ForEach-Object { ConvertTo-FNVFormId $_ })
if (@($canonicalBatchTargets | Select-Object -Unique).Count -ne $canonicalBatchTargets.Count) {
    throw "BatchTargetForm contains duplicate target identities."
}
foreach ($form in $BatchExpectedBaseForm) {
    if ($form -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$') {
        throw "BatchExpectedBaseForm requires decimal or 0x-prefixed FormIDs, got: $form"
    }
    try { ConvertTo-FNVFormId $form | Out-Null }
    catch { throw "BatchExpectedBaseForm requires 32-bit FormIDs, got: $form" }
}
if ($BatchExpectedBaseForm.Count -ne 0 -and
    $BatchExpectedBaseForm.Count -ne $BatchTargetForm.Count) {
    throw "BatchExpectedBaseForm count must be zero or equal BatchTargetForm count."
}
foreach ($form in $BatchEnableParentForm) {
    if ($form -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$' -or $form -match '^(0[xX]0+|0+)$') {
        throw "BatchEnableParentForm requires nonzero decimal or 0x-prefixed FormIDs, got: $form"
    }
    try { ConvertTo-FNVFormId $form | Out-Null }
    catch { throw "BatchEnableParentForm requires 32-bit FormIDs, got: $form" }
}
$canonicalParentForms = @($BatchEnableParentForm | ForEach-Object { ConvertTo-FNVFormId $_ })
if (@($canonicalParentForms | Select-Object -Unique).Count -ne $canonicalParentForms.Count) {
    throw "BatchEnableParentForm contains duplicate parent identities."
}
if ($planMode -and ($BatchTargetForm.Count -gt 0 -or $ScreenshotFrame.Count -gt 0 -or
    $TargetForm -notmatch '^(0[xX]0+|0+)$' -or $ExpectedTargetBaseForm -notmatch '^(0[xX]0+|0+)$' -or
    $MaterialShaderCapture -or $FurnitureOnly)) {
    throw "PlanPath owns actor/action staging and screenshots; do not combine it with legacy target, batch, screenshot, material, or furniture modes."
}
if ($BatchTargetForm.Count -gt 0 -and $ScreenshotFrame.Count -gt 0) {
    throw "BatchTargetForm owns its screenshot schedule; do not also pass ScreenshotFrame."
}
if ($BatchTargetForm.Count -gt 0 -and
    ($TargetForm -notmatch '^(0[xX]0+|0+)$' -or $ExpectedTargetBaseForm -notmatch '^(0[xX]0+|0+)$')) {
    throw "BatchTargetForm cannot be combined with single TargetForm/base identities."
}
if ($BatchTargetForm.Count -eq 0 -and
    ($BatchMoveToTargets -or $BatchEnableTargets -or $BatchProofStaging -or $BatchForceWeaponOut -or
        $BatchEnableParentForm.Count -gt 0)) {
    throw "Batch movement, enablement, and parent identities require BatchTargetForm."
}
if ($BatchProofStaging) {
    if ($BatchProofAnchorForm -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$' -or
        $BatchProofAnchorForm -match '^(0[xX]0+|0+)$') {
        throw "BatchProofStaging requires a nonzero decimal or 0x-prefixed BatchProofAnchorForm."
    }
    try { $canonicalBatchProofAnchor = ConvertTo-FNVFormId $BatchProofAnchorForm }
    catch { throw "BatchProofAnchorForm requires a 32-bit FormID, got: $BatchProofAnchorForm" }
    if (-not $BatchEnableTargets) {
        throw "BatchProofStaging requires BatchEnableTargets so each authored reference is activated explicitly."
    }
    if ($CameraShotKind -ne 'front-full-body') {
        throw "BatchProofStaging requires CameraShotKind front-full-body."
    }
    foreach ($value in @($BatchProofTargetX, $BatchProofTargetY, $BatchProofTargetZ,
            $BatchProofTargetYaw, $BatchProofPlayerX, $BatchProofPlayerY, $BatchProofPlayerZ,
            $BatchProofMinimumCameraHeight, $BatchProofMinimumAimHeight)) {
        if ([float]::IsNaN([float]$value) -or [float]::IsInfinity([float]$value)) {
            throw "BatchProofStaging coordinates, yaw, and camera heights must all be finite."
        }
    }
    if ($BatchProofMinimumCameraHeight -lt $BatchProofMinimumAimHeight) {
        throw "BatchProofMinimumCameraHeight must be at least BatchProofMinimumAimHeight."
    }
}
else {
    $canonicalBatchProofAnchor = [uint32]0
}
if ($RequireAppearanceTelemetry -and $BatchTargetForm.Count -eq 0 -and
    $TargetForm -match '^(0[xX]0+|0+)$') {
    throw "RequireAppearanceTelemetry requires TargetForm or BatchTargetForm."
}
$sidecarPlanPath = $null
$sidecarPlanSequenceId = $null
$sidecarPlanActors = @()
$sidecarPlanActions = @()
$sidecarCaptureLabels = @()
if ($planMode) {
    if ($SharedMemoryName.Length -gt 180 -or $SharedMemoryName -notmatch '^(Local|Global)\\[A-Za-z0-9._-]+$') {
        throw "SharedMemoryName must be a Local\\ or Global\\ named-object identifier no longer than 180 characters."
    }
    $sidecarPlanPath = Resolve-AbsolutePath $PlanPath
    if (-not (Test-Path -LiteralPath $sidecarPlanPath -PathType Leaf)) {
        throw "Missing compiled retail sidecar plan: $sidecarPlanPath"
    }
    $sidecarPlanBytes = (Get-Item -LiteralPath $sidecarPlanPath).Length
    if ($sidecarPlanBytes -le 0 -or $sidecarPlanBytes -gt 16MB) {
        throw "Compiled retail sidecar plan must be between 1 byte and 16 MiB."
    }
    $sidecarLines = @([System.IO.File]::ReadAllLines($sidecarPlanPath))
    $sidecarRecordPhase = 'header'
    $sidecarEndRead = $false
    $sidecarScene = $null
    $sidecarActionIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $sidecarAuthoredRefs = [System.Collections.Generic.HashSet[uint32]]::new()
    for ($lineIndex = 0; $lineIndex -lt $sidecarLines.Count; $lineIndex++) {
        $lineNumber = $lineIndex + 1
        $line = [string]$sidecarLines[$lineIndex]
        if ($lineIndex -eq 0) { $line = $line.TrimStart([char]0xFEFF) }
        if ($line.Length -gt 4096 -or $line.Contains([char]0)) {
            throw "Compiled retail sidecar plan line $lineNumber exceeds 4096 characters or contains NUL."
        }
        if ($line.Length -eq 0) { continue }
        if ($sidecarEndRead) {
            throw "Compiled retail sidecar plan has a record after end at line $lineNumber."
        }
        if ($line[0] -eq '#') { continue }
        if ($sidecarRecordPhase -eq 'header') {
            if ($line -cne 'nikami-fnv-retail-plan-v1') {
                throw "Compiled retail sidecar plan has the wrong header at line $lineNumber."
            }
            $sidecarRecordPhase = 'sequence'
            continue
        }

        $fields = @($line -split "`t", -1)
        switch -CaseSensitive ($fields[0]) {
            'sequence' {
                if ($sidecarRecordPhase -ne 'sequence' -or $fields.Count -ne 2 -or
                    $null -ne $sidecarPlanSequenceId -or
                    $fields[1] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$') {
                    throw "Compiled retail sidecar plan has an invalid sequence record at line $lineNumber."
                }
                $sidecarPlanSequenceId = $fields[1]
                $sidecarRecordPhase = 'scene'
            }
            'scene' {
                if ($sidecarRecordPhase -ne 'scene' -or $fields.Count -ne 17) {
                    throw "Compiled retail sidecar plan has an invalid scene record at line $lineNumber."
                }
                $sceneUInt = @(
                    ConvertFrom-SidecarPlanUInt $fields[1] "scene.anchorForm"
                    ConvertFrom-SidecarPlanUInt $fields[2] "scene.weatherForm"
                    ConvertFrom-SidecarPlanUInt $fields[15] "scene.initializationFrames"
                    ConvertFrom-SidecarPlanUInt $fields[16] "scene.targetSettleFrames"
                )
                $sceneFloat = for ($fieldIndex = 3; $fieldIndex -le 14; $fieldIndex++) {
                    ConvertFrom-SidecarPlanFloat $fields[$fieldIndex] "scene field $fieldIndex"
                }
                if ($sceneUInt[0] -eq 0 -or $sceneUInt[1] -eq 0 -or
                    $sceneFloat[0] -lt 0 -or $sceneFloat[0] -ge 24 -or
                    $sceneFloat[1] -lt 0 -or $sceneFloat[1] -gt 10000 -or
                    $sceneFloat[9] -lt 1.25 -or $sceneFloat[9] -gt 10 -or
                    $sceneFloat[10] -lt $sceneFloat[11] -or $sceneFloat[11] -lt 0 -or
                    $sceneUInt[2] -lt 1 -or $sceneUInt[2] -gt 1200 -or
                    $sceneUInt[3] -lt 1 -or $sceneUInt[3] -gt 600) {
                    throw "Compiled retail sidecar scene constraints fail at line $lineNumber."
                }
                $sidecarScene = [pscustomobject]@{
                    anchorForm = $sceneUInt[0]
                    weatherForm = $sceneUInt[1]
                    gameHour = $sceneFloat[0]
                    timeScale = $sceneFloat[1]
                }
                $sidecarRecordPhase = 'actions'
            }
            'action' {
                if ($sidecarRecordPhase -ne 'actions' -or $fields.Count -ne 5 -or
                    $sidecarPlanActions.Count -ge 64) {
                    throw "Compiled retail sidecar plan has an out-of-order action at line $lineNumber."
                }
                $actionIndex = ConvertFrom-SidecarPlanUInt $fields[1] "action.index"
                $actionFrames = ConvertFrom-SidecarPlanUInt $fields[4] "action.frames"
                if ($actionIndex -ne $sidecarPlanActions.Count -or
                    $fields[2] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$' -or
                    $fields[3] -notmatch '^[A-Za-z0-9_]{1,63}$' -or
                    $actionFrames -lt 1 -or $actionFrames -gt 36000 -or
                    -not $sidecarActionIds.Add([string]$fields[2])) {
                    throw "Compiled retail sidecar plan has an invalid action at line $lineNumber."
                }
                $sidecarPlanActions += [pscustomobject]@{
                    index = [int]$actionIndex
                    id = [string]$fields[2]
                    playGroup = [string]$fields[3]
                    frames = [uint32]$actionFrames
                }
            }
            'actor' {
                if ($sidecarRecordPhase -notin @('actions', 'actors') -or
                    $sidecarPlanActions.Count -eq 0 -or $fields.Count -ne 6 -or
                    $sidecarPlanActors.Count -ge 8192) {
                    throw "Compiled retail sidecar plan has an out-of-order actor at line $lineNumber."
                }
                $actorIndex = ConvertFrom-SidecarPlanUInt $fields[1] "actor.index"
                $authoredRef = ConvertFrom-SidecarPlanUInt $fields[2] "actor.authoredRefForm"
                $baseForm = ConvertFrom-SidecarPlanUInt $fields[3] "actor.baseForm"
                $weaponForm = ConvertFrom-SidecarPlanUInt $fields[4] "actor.weaponForm"
                $enableParent = ConvertFrom-SidecarPlanUInt $fields[5] "actor.enableParentForm"
                if ($actorIndex -ne $sidecarPlanActors.Count -or $baseForm -eq 0 -or
                    ($authoredRef -ne 0 -and -not $sidecarAuthoredRefs.Add($authoredRef))) {
                    throw "Compiled retail sidecar plan has an invalid actor at line $lineNumber."
                }
                $sidecarPlanActors += [pscustomobject]@{
                    index = [int]$actorIndex
                    authoredRefForm = [uint32]$authoredRef
                    baseForm = [uint32]$baseForm
                    weaponForm = [uint32]$weaponForm
                    enableParentForm = [uint32]$enableParent
                }
                $sidecarRecordPhase = 'actors'
            }
            'end' {
                if ($sidecarRecordPhase -ne 'actors' -or $fields.Count -ne 1 -or
                    $sidecarPlanActors.Count -eq 0) {
                    throw "Compiled retail sidecar plan has an invalid end record at line $lineNumber."
                }
                $sidecarEndRead = $true
                $sidecarRecordPhase = 'end'
            }
            default {
                throw "Compiled retail sidecar plan has unknown record '$($fields[0])' at line $lineNumber."
            }
        }
    }
    if ($null -eq $sidecarPlanSequenceId -or $null -eq $sidecarScene -or
        $sidecarPlanActions.Count -eq 0 -or $sidecarPlanActors.Count -eq 0 -or
        -not $sidecarEndRead -or $sidecarRecordPhase -ne 'end') {
        throw "Compiled retail sidecar plan is incomplete or violates the bounded data-driven v1 contract."
    }
    foreach ($actor in $sidecarPlanActors) {
        foreach ($action in $sidecarPlanActions) {
            $sidecarCaptureLabels += ('actor-{0:D4}-action-{1:D2}-{2}' -f
                $actor.index, $action.index, $action.id)
        }
    }
}
$expectedScreenshotCount = if ($planMode) {
    $sidecarPlanActors.Count * $sidecarPlanActions.Count
} else {
    $ScreenshotFrame.Count + $BatchTargetForm.Count
}
if ($expectedScreenshotCount -gt 0 -and [string]::IsNullOrWhiteSpace($ScreenshotDirectory)) {
    $ScreenshotDirectory = "$OutputPath-screens"
}

$gameRootPath = Resolve-AbsolutePath $GameRoot
$runtimeRootPath = Resolve-AbsolutePath $RuntimeRoot
$output = Resolve-AbsolutePath $OutputPath
$runManifest = $output + '.manifest.json'
if (-not (Test-Path -LiteralPath $runtimeRootPath -PathType Container)) {
    throw "Missing repo-local isolated xNVSE RuntimeRoot: $runtimeRootPath"
}
if (-not (Test-PathWithinRoot -Path $runtimeRootPath -Root $repoRoot)) {
    throw "RuntimeRoot must be a directory inside the nikami-worlds repository: $runtimeRootPath"
}
if (Test-PathWithinRoot -Path $gameRootPath -Root 'D:\code\fnvvr' -AllowRoot) {
    throw "The flat retail oracle must not use the excluded fnvvr tree: $gameRootPath"
}
if ((Test-PathWithinRoot -Path $runtimeRootPath -Root $gameRootPath -AllowRoot) -or
    (Test-PathWithinRoot -Path $gameRootPath -Root $runtimeRootPath -AllowRoot)) {
    throw "RuntimeRoot and GameRoot must be disjoint."
}

$overlayLockPath = Join-Path $repoRoot 'catalog\oracle-overlay-lock.json'
if (-not (Test-Path -LiteralPath $overlayLockPath -PathType Leaf)) {
    throw "Missing oracle overlay lock: $overlayLockPath"
}
$overlayLock = Get-Content -LiteralPath $overlayLockPath -Raw | ConvertFrom-Json
if ($null -eq $overlayLock.overlays -or $null -eq $overlayLock.overlays.xnvse -or
    -not ($overlayLock.overlays.xnvse.PSObject.Properties.Name -contains 'replayedTree')) {
    throw "Oracle overlay lock does not declare overlays.xnvse.replayedTree."
}
$expectedReplayedTree = ([string]$overlayLock.overlays.xnvse.replayedTree).ToLowerInvariant()
if ($expectedReplayedTree -notmatch '^[0-9a-f]{40}$') {
    throw "Oracle overlay lock contains an invalid xNVSE replayedTree."
}

$runtimeManifestPath = Join-Path $runtimeRootPath 'oracle-runtime-manifest.json'
if (-not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
    throw "Missing isolated xNVSE runtime manifest: $runtimeManifestPath"
}
$runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json
if ([string]$runtimeManifest.schema -ne 'nikami-xnvse-isolated-runtime/v1') {
    throw "Unexpected isolated xNVSE runtime manifest schema: $($runtimeManifest.schema)"
}
if ($null -eq $runtimeManifest.overlay -or [string]$runtimeManifest.overlay.name -ne 'xnvse') {
    throw "Isolated xNVSE runtime manifest must declare overlay.name=xnvse."
}
$runtimeReplayedTree = ([string]$runtimeManifest.overlay.replayedTree).ToLowerInvariant()
if ($runtimeReplayedTree -ne $expectedReplayedTree) {
    throw "Isolated xNVSE runtime replayedTree '$runtimeReplayedTree' does not match catalog lock '$expectedReplayedTree'."
}

$loader = Get-ManifestRuntimeFile -Manifest $runtimeManifest -Key 'loader' `
    -ExpectedRelativePath 'nvse_loader.exe' -RuntimeRootPath $runtimeRootPath
$steamLoader = Get-ManifestRuntimeFile -Manifest $runtimeManifest -Key 'steamLoader' `
    -ExpectedRelativePath 'nvse_steam_loader.dll' -RuntimeRootPath $runtimeRootPath
$coreDll = Get-ManifestRuntimeFile -Manifest $runtimeManifest -Key 'core' `
    -ExpectedRelativePath 'nvse_1_4.dll' -RuntimeRootPath $runtimeRootPath
$manifestPlugin = Get-ManifestRuntimeFile -Manifest $runtimeManifest -Key 'plugin' `
    -ExpectedRelativePath 'plugins\nvse_retail_oracle.dll' -RuntimeRootPath $runtimeRootPath
$sourcePlugin = Resolve-AbsolutePath $PluginDll
if (-not $sourcePlugin.Equals($manifestPlugin, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "PluginDll must be the manifest-verified RuntimeRoot plugin: $manifestPlugin"
}

$gameExe = Join-Path $gameRootPath 'FalloutNV.exe'
$runToken = "$PID-$([Guid]::NewGuid().ToString('N'))"
$ephemeralRunRoot = Join-Path $runtimeRootPath ".runs\$runToken"
$isolatedPluginDirectory = Join-Path $ephemeralRunRoot 'plugins'
$installedPlugin = Join-Path $isolatedPluginDirectory 'nvse_retail_oracle.dll'
$rootHookBackupDirectory = Join-Path $ephemeralRunRoot 'root-hooks'
$screenshotBackupDirectory = Join-Path $gameRootPath ".nikami-screenshot-backup-$runToken"
$screenshotOutputDirectory = if ([string]::IsNullOrWhiteSpace($ScreenshotDirectory)) {
    $null
} else {
    Resolve-AbsolutePath $ScreenshotDirectory
}
$capturedScreenshots = @()
$framebufferDerivedScreenshots = @()
$portraitProofCrops = @()
$fixtureDestinations = @()
$rootHookBackups = @()
$resolvedSaveFixture = $null
$fixtureSaveName = $null
$legacyIsolationSpecified = $PSBoundParameters.ContainsKey('IsolateFromFNVXR')
if ($AllowRootHookDlls -and $legacyIsolationSpecified -and [bool]$IsolateFromFNVXR) {
    throw "AllowRootHookDlls conflicts with IsolateFromFNVXR."
}
$isolateRootHookDlls = if ($AllowRootHookDlls) {
    $false
} elseif ($legacyIsolationSpecified) {
    [bool]$IsolateFromFNVXR
} else {
    $true
}
$rootHookCandidates = @(
    (Join-Path $gameRootPath 'd3d9.dll'),
    (Join-Path $gameRootPath 'dinput8.dll')
)

if (-not [string]::IsNullOrWhiteSpace($SaveFixture)) {
    $resolvedSaveFixture = Resolve-AbsolutePath $SaveFixture
    if (-not (Test-Path -LiteralPath $resolvedSaveFixture -PathType Leaf) -or
        [System.IO.Path]::GetExtension($resolvedSaveFixture) -ine '.fos') {
        throw "SaveFixture must name an existing .fos file: $resolvedSaveFixture"
    }
    $saveDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FalloutNV\Saves'
    $fixtureSaveName = "NikamiOracleFixture-$PID"
    foreach ($extension in @('.fos', '.nvse')) {
        $source = [System.IO.Path]::ChangeExtension($resolvedSaveFixture, $extension)
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $destination = Join-Path $saveDirectory ($fixtureSaveName + $extension)
            if (Test-Path -LiteralPath $destination) {
                throw "Refusing to overwrite stale retail-oracle fixture: $destination"
            }
            $fixtureDestinations += [pscustomobject]@{ Source = $source; Destination = $destination }
        }
    }
    $SaveName = $fixtureSaveName
}

foreach ($required in @($gameExe, $sourcePlugin)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing required retail-oracle file: $required"
    }
}

$environment = [ordered]@{
    NIKAMI_NVSE_PLUGIN_DIR = $isolatedPluginDirectory
    NIKAMI_NVSE_STEAM_LOADER = $steamLoader
    NIKAMI_NVSE_CORE_DLL = $coreDll
    NIKAMI_ORACLE_OUTPUT = $output
    NIKAMI_ORACLE_PLAN_PATH = if ($planMode) { $sidecarPlanPath } else { "" }
    NIKAMI_ORACLE_SHARED_MEMORY_NAME = if ($planMode) { $SharedMemoryName } else { "" }
    NIKAMI_ORACLE_BARRIER_TIMEOUT_MS = [string]$BarrierTimeoutMilliseconds
    NIKAMI_ORACLE_SAMPLE_EVERY = [string]$SampleEvery
    NIKAMI_ORACLE_MAX_FRAMES = [string]$MaxFrames
    NIKAMI_ORACLE_TARGET_FORM = $TargetForm
    NIKAMI_ORACLE_OBSERVER_APPROACH_FORM = $ObserverApproachForm
    NIKAMI_ORACLE_OBSERVER_APPROACH_STOP_DISTANCE = [string]$ObserverApproachStopDistance
    NIKAMI_ORACLE_OBSERVER_APPROACH_STEP_DISTANCE = [string]$ObserverApproachStepDistance
    NIKAMI_ORACLE_OBSERVER_WAYPOINTS = (@($ObserverWaypoint) -join ";")
    NIKAMI_ORACLE_EQUIP_FORM = $EquipForm
    NIKAMI_ORACLE_ALL_HIGH_ACTORS = if ($CaptureAnimation) { "1" } else { "0" }
    NIKAMI_ORACLE_CAPTURE_ANIMATION = if ($CaptureAnimation) { "1" } else { "0" }
    NIKAMI_ORACLE_CAPTURE_SESSION = if ($CaptureSession) { "1" } else { "0" }
    NIKAMI_ORACLE_SESSION_TARGET_FORM = $SessionTargetForm
    NIKAMI_ORACLE_FURNITURE_ONLY = if ($FurnitureOnly) { "1" } else { "0" }
    NIKAMI_ORACLE_FURNITURE_SETTLED_COMMANDS = (@($FurnitureSettledCommand) -join "|")
    NIKAMI_ORACLE_EXIT_AFTER_FURNITURE_RELEASE = if ($ExitAfterFurnitureRelease) { "1" } else { "0" }
    NIKAMI_ORACLE_EXIT_AFTER_FURNITURE_SETTLED_SAMPLES = [string]$ExitAfterFurnitureSettledSamples
    NIKAMI_ORACLE_FURNITURE_RELEASE_SAMPLES = [string]$FurnitureReleaseSamples
    NIKAMI_ORACLE_CLOSE_MENUS = if ($BackgroundDataMode) { "1" } else { "0" }
    NIKAMI_ORACLE_SAVE = $SaveName
    NIKAMI_ORACLE_PLAY_GROUP = $PlayGroup
    NIKAMI_ORACLE_DRIVE_COMMAND = $DriveCommand
    NIKAMI_ORACLE_PREPARE_ACTOR_FRAME = [string]$PrepareActorFrame
    NIKAMI_ORACLE_EQUIP_ACTOR_FRAME = [string]$EquipActorFrame
    NIKAMI_ORACLE_DRIVE_ACTOR_FRAME = [string]$DriveActorFrame
    NIKAMI_ORACLE_FOOT_IK_TOGGLE_FRAME = [string]$FootIkToggleFrame
    NIKAMI_ORACLE_FOOT_IK_TOGGLE_ENABLED = if ($FootIkToggleEnabled -eq 1) { "1" } else { "0" }
    NIKAMI_ORACLE_QUEST_FORMS = (@($QuestForm) -join ",")
    NIKAMI_ORACLE_GLOBAL_FORMS = (@($GlobalForm) -join ",")
    NIKAMI_ORACLE_GAME_SETTINGS = (@($GameSetting) -join ",")
    NIKAMI_ORACLE_COMMANDS = (@($Command) -join "|")
    NIKAMI_ORACLE_SCHEDULED_COMMANDS = (@($ScheduledCommand) -join "|")
    NIKAMI_ORACLE_ACTOR_COMMANDS = (@($ActorCommand) -join "|")
    NIKAMI_ORACLE_BEFORE_FRAME = [string]$BeforeFrame
    NIKAMI_ORACLE_COMMAND_FRAME = [string]$CommandFrame
    NIKAMI_ORACLE_AFTER_FRAME = [string]$AfterFrame
    NIKAMI_ORACLE_SET_STAGE_QUEST = $SetStageQuestForm
    NIKAMI_ORACLE_SET_STAGE_INDEX = [string]$SetStageIndex
    NIKAMI_ORACLE_SCREENSHOT_FRAMES = (@($ScreenshotFrame) -join ",")
    NIKAMI_ORACLE_MATERIAL_SHADER_CAPTURE = if ($MaterialShaderCapture) { "1" } else { "0" }
    NIKAMI_ORACLE_MATERIAL_SHADER_FRAME = [string]$MaterialShaderFrame
    NIKAMI_ORACLE_BATCH_TARGET_FORMS = (@($BatchTargetForm) -join ",")
    NIKAMI_ORACLE_BATCH_SETTLE_FRAMES = [string]$BatchSettleFrames
    NIKAMI_ORACLE_BATCH_ADVANCE_FRAMES = [string]$BatchAdvanceFrames
    NIKAMI_ORACLE_BATCH_MOVE_TO_TARGETS = if ($BatchMoveToTargets) { "1" } else { "0" }
    NIKAMI_ORACLE_BATCH_ENABLE_TARGETS = if ($BatchEnableTargets) { "1" } else { "0" }
    NIKAMI_ORACLE_BATCH_ENABLE_PARENT_FORMS = (@($BatchEnableParentForm) -join ",")
    NIKAMI_ORACLE_BATCH_PROOF_STAGING = if ($BatchProofStaging) { "1" } else { "0" }
    NIKAMI_ORACLE_BATCH_PROOF_ANCHOR_FORM = $BatchProofAnchorForm
    NIKAMI_ORACLE_BATCH_PROOF_TARGET_X = [string]$BatchProofTargetX
    NIKAMI_ORACLE_BATCH_PROOF_TARGET_Y = [string]$BatchProofTargetY
    NIKAMI_ORACLE_BATCH_PROOF_TARGET_Z = [string]$BatchProofTargetZ
    NIKAMI_ORACLE_BATCH_PROOF_TARGET_YAW = [string]$BatchProofTargetYaw
    NIKAMI_ORACLE_BATCH_PROOF_PLAYER_X = [string]$BatchProofPlayerX
    NIKAMI_ORACLE_BATCH_PROOF_PLAYER_Y = [string]$BatchProofPlayerY
    NIKAMI_ORACLE_BATCH_PROOF_PLAYER_Z = [string]$BatchProofPlayerZ
    NIKAMI_ORACLE_BATCH_PROOF_MINIMUM_CAMERA_HEIGHT = [string]$BatchProofMinimumCameraHeight
    NIKAMI_ORACLE_BATCH_PROOF_MINIMUM_AIM_HEIGHT = [string]$BatchProofMinimumAimHeight
    NIKAMI_ORACLE_BATCH_PROOF_INITIALIZATION_FRAMES = [string]$BatchProofInitializationFrames
    NIKAMI_ORACLE_BATCH_PROOF_TARGET_SETTLE_FRAMES = [string]$BatchProofTargetSettleFrames
    NIKAMI_ORACLE_BATCH_FORCE_WEAPON_OUT = if ($BatchForceWeaponOut) { "1" } else { "0" }
    NIKAMI_ORACLE_BATCH_WEAPON_PROBE_FRAMES = [string]$BatchWeaponProbeFrames
    NIKAMI_ORACLE_PORTRAIT_CAMERA = if ($PortraitCamera) { "1" } else { "0" }
    NIKAMI_ORACLE_PORTRAIT_DISTANCE = [string]$PortraitDistance
    NIKAMI_ORACLE_CAMERA_SHOT_KIND = $CameraShotKind
    NIKAMI_ORACLE_FULL_BODY_DISTANCE_SCALE = [string]$FullBodyDistanceScale
    NIKAMI_ORACLE_EXIT_WHEN_DONE = "1"
}
$plannedRootHookMoves = @(if ($isolateRootHookDlls) {
    $rootHookCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
})
$loaderArgumentList = @('-altdll', $coreDll)
$cleanupWarnings = New-Object System.Collections.Generic.List[string]
if ($DryRun) {
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-retail-oracle-validation/v1'
        status = 'validated-no-launch'
        overlayLock = $overlayLockPath
        replayedTree = $expectedReplayedTree
        runtimeRoot = $runtimeRootPath
        runtimeManifest = $runtimeManifestPath
        loader = $loader
        steamLoader = $steamLoader
        coreDll = $coreDll
        pluginSource = $sourcePlugin
        ephemeralRunRoot = $ephemeralRunRoot
        isolatedPluginDirectory = $isolatedPluginDirectory
        retailPluginDirectoryUsed = $false
        ephemeralRunRootRetained = [bool](Test-Path -LiteralPath $ephemeralRunRoot)
        cleanupWarnings = @($cleanupWarnings)
        rootHookIsolation = $isolateRootHookDlls
        rootHookDlls = @($plannedRootHookMoves)
        launch = [pscustomobject][ordered]@{
            filePath = $loader
            workingDirectory = $gameRootPath
            argumentList = @($loaderArgumentList)
            hidden = -not [bool]$VisibleGame
        }
        isolationEnvironment = [pscustomobject][ordered]@{
            NIKAMI_NVSE_PLUGIN_DIR = $environment.NIKAMI_NVSE_PLUGIN_DIR
            NIKAMI_NVSE_STEAM_LOADER = $environment.NIKAMI_NVSE_STEAM_LOADER
            NIKAMI_NVSE_CORE_DLL = $environment.NIKAMI_NVSE_CORE_DLL
            NIKAMI_ORACLE_GAME_SETTINGS = $environment.NIKAMI_ORACLE_GAME_SETTINGS
        }
        output = $output
        runManifest = $runManifest
        sidecar = if ($planMode) { [pscustomobject][ordered]@{
            enabled = $true
            sequenceId = $sidecarPlanSequenceId
            planPath = $sidecarPlanPath
            sharedMemoryName = $SharedMemoryName
            barrierTimeoutMilliseconds = $BarrierTimeoutMilliseconds
            actors = $sidecarPlanActors.Count
            actionsPerActor = $sidecarPlanActions.Count
            expectedCaptures = $expectedScreenshotCount
        } } else { $null }
        wouldOverwrite = [pscustomobject][ordered]@{
            output = Test-Path -LiteralPath $output
            runManifest = Test-Path -LiteralPath $runManifest
        }
        expectedTargetBaseForm = $ExpectedTargetBaseForm
        batchExpectedBaseForms = @($BatchExpectedBaseForm)
        cameraShotKind = $CameraShotKind
        fullBodyDistanceScale = $FullBodyDistanceScale
        batchForceWeaponOut = [bool]$BatchForceWeaponOut
        batchWeaponProbeFrames = $BatchWeaponProbeFrames
        batchProofStaging = [bool]$BatchProofStaging
        batchProofAnchorForm = Format-FNVFormId $BatchProofAnchorForm
        batchProofTarget = @($BatchProofTargetX, $BatchProofTargetY, $BatchProofTargetZ, $BatchProofTargetYaw)
        batchProofPlayer = @($BatchProofPlayerX, $BatchProofPlayerY, $BatchProofPlayerZ)
        batchProofMinimumCameraHeight = $BatchProofMinimumCameraHeight
        batchProofMinimumAimHeight = $BatchProofMinimumAimHeight
        batchProofInitializationFrames = $BatchProofInitializationFrames
        batchProofTargetSettleFrames = $BatchProofTargetSettleFrames
        gameSettings = @($GameSetting)
    }
    return
}

if (Get-Process -Name 'FalloutNV' -ErrorAction SilentlyContinue) {
    throw 'FalloutNV is already running. Close it before starting an isolated oracle capture.'
}

if (Test-Path -LiteralPath $output) {
    throw "Refusing to overwrite existing retail-oracle output: $output"
}
if (Test-Path -LiteralPath $runManifest) {
    throw "Refusing to overwrite existing retail-oracle run manifest: $runManifest"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null

$runtimeEvidence = @(
    Get-FNVFileEvidence $overlayLockPath 'oracle-overlay-lock'
    Get-FNVFileEvidence $runtimeManifestPath 'isolated-runtime-manifest'
    Get-FNVFileEvidence $loader 'isolated-nvse-loader'
    Get-FNVFileEvidence $steamLoader 'isolated-nvse-steam-loader'
    Get-FNVFileEvidence $coreDll 'isolated-nvse-core'
    Get-FNVFileEvidence $sourcePlugin 'retail-oracle-plugin'
    Get-FNVFileEvidence $gameExe 'retail-game-executable'
    Get-FNVFileEvidence $PSCommandPath 'retail-oracle-runner'
    Get-FNVFileEvidence $evidenceHelperPath 'retail-oracle-evidence-helper'
)
$saveFixtureEvidence = @()
if ($null -ne $resolvedSaveFixture) {
    foreach ($extension in @('.fos', '.nvse')) {
        $fixtureSource = [System.IO.Path]::ChangeExtension($resolvedSaveFixture, $extension)
        if (Test-Path -LiteralPath $fixtureSource -PathType Leaf) {
            $saveFixtureEvidence += Get-FNVFileEvidence $fixtureSource "save-fixture$extension"
        }
    }
}
$rootHookEvidence = @(
    $rootHookCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object {
        $kind = if ($isolateRootHookDlls) { 'isolated-root-hook' } else { 'allowed-root-hook' }
        Get-FNVFileEvidence $_ $kind
    }
)

$previousEnvironment = @{}
$environmentNamesSet = New-Object System.Collections.Generic.List[string]
$cleanupFailures = New-Object System.Collections.Generic.List[string]
$cleanupWarnings = New-Object System.Collections.Generic.List[string]
$gameProcess = $null
$launcherProcess = $null
$runFailure = $null
$preserveEphemeralRunRoot = $false

try {
    if (Test-Path -LiteralPath $ephemeralRunRoot) {
        throw "Refusing to reuse an isolated xNVSE run directory: $ephemeralRunRoot"
    }
    New-Item -ItemType Directory -Path $isolatedPluginDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourcePlugin -Destination $installedPlugin
    $pluginEntries = @(Get-ChildItem -LiteralPath $isolatedPluginDirectory -Force)
    if ($pluginEntries.Count -ne 1 -or $pluginEntries[0].PSIsContainer -or
        -not $pluginEntries[0].FullName.Equals($installedPlugin, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Ephemeral xNVSE plugin directory must contain only nvse_retail_oracle.dll: $isolatedPluginDirectory"
    }

    if ($isolateRootHookDlls -and $plannedRootHookMoves.Count -gt 0) {
        New-Item -ItemType Directory -Path $rootHookBackupDirectory | Out-Null
        foreach ($candidate in $plannedRootHookMoves) {
            $backupPath = Join-Path $rootHookBackupDirectory ([System.IO.Path]::GetFileName($candidate))
            $entry = [pscustomobject]@{ Original = $candidate; Backup = $backupPath }
            $rootHookBackups += $entry
            Move-Item -LiteralPath $candidate -Destination $backupPath
        }
    }
    if ($expectedScreenshotCount -gt 0) {
        if (Test-Path -LiteralPath $screenshotBackupDirectory) {
            throw "Refusing to overwrite stale screenshot backup: $screenshotBackupDirectory"
        }
        New-Item -ItemType Directory -Path $screenshotBackupDirectory | Out-Null
        foreach ($existingScreenshot in @(Get-ChildItem -LiteralPath $gameRootPath -Filter 'ScreenShot*.bmp' -File)) {
            Move-Item -LiteralPath $existingScreenshot.FullName -Destination $screenshotBackupDirectory
        }
        New-Item -ItemType Directory -Force -Path $screenshotOutputDirectory | Out-Null
        if (@(Get-ChildItem -LiteralPath $screenshotOutputDirectory -Filter 'frame-*.bmp' -File).Count -gt 0) {
            throw "ScreenshotDirectory already contains frame-*.bmp files: $screenshotOutputDirectory"
        }
    }
    foreach ($fixture in $fixtureDestinations) {
        Copy-Item -LiteralPath $fixture.Source -Destination $fixture.Destination
    }

    foreach ($name in $environment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
        $environmentNamesSet.Add($name) | Out-Null
    }

    $startedAt = Get-Date
    $launchArguments = @{
        FilePath = $loader
        WorkingDirectory = $gameRootPath
        ArgumentList = @('-altdll', ('"{0}"' -f $coreDll))
        PassThru = $true
    }
    if (-not $VisibleGame) {
        $launchArguments.WindowStyle = 'Hidden'
    }
    $launcherProcess = Start-Process @launchArguments
    $launchDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $launchDeadline -and $null -eq $gameProcess) {
        $gameProcess = Get-Process -Name 'FalloutNV' -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
            Select-Object -First 1
        if ($null -eq $gameProcess) {
            Start-Sleep -Milliseconds 250
        }
    }
    if ($null -eq $gameProcess) {
        throw "Isolated nvse_loader did not start FalloutNV within 20 seconds (loader PID $($launcherProcess.Id))."
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $gameProcess.HasExited -and (Get-Date) -lt $deadline) {
        $gameProcess.WaitForExit(250) | Out-Null
        $gameProcess.Refresh()
    }
    if (-not $gameProcess.HasExited) {
        Stop-Process -Id $gameProcess.Id -Force
        $gameProcess.WaitForExit()
        throw "Retail oracle timed out after $TimeoutSeconds seconds."
    }
    $exitCode = $null
    try { $exitCode = $gameProcess.ExitCode } catch { $exitCode = $null }
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "FalloutNV oracle process exited with code $exitCode."
    }
}
catch {
    $runFailure = $_
}
finally {
    try {
        Complete-FNVProcessHandle -Process $gameProcess -Label 'FalloutNV'
    } catch { $cleanupFailures.Add("Failed to stop FalloutNV: $($_.Exception.Message)") | Out-Null }
    try {
        Complete-FNVProcessHandle -Process $launcherProcess -Label 'isolated nvse_loader'
    } catch { $cleanupFailures.Add("Failed to stop isolated nvse_loader: $($_.Exception.Message)") | Out-Null }

    foreach ($name in $environmentNamesSet) {
        try {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        } catch { $cleanupFailures.Add("Failed to restore process environment ${name}: $($_.Exception.Message)") | Out-Null }
    }

    foreach ($entry in $rootHookBackups) {
        if (-not (Test-Path -LiteralPath $entry.Backup -PathType Leaf)) { continue }
        if (Test-Path -LiteralPath $entry.Original) {
            $preserveEphemeralRunRoot = $true
            $cleanupFailures.Add("Refusing to overwrite root hook DLL while restoring $($entry.Original); backup retained at $($entry.Backup).") | Out-Null
            continue
        }
        try {
            Move-Item -LiteralPath $entry.Backup -Destination $entry.Original
        } catch {
            $preserveEphemeralRunRoot = $true
            $cleanupFailures.Add("Failed to restore root hook DLL $($entry.Original): $($_.Exception.Message)") | Out-Null
        }
    }

    foreach ($fixture in $fixtureDestinations) {
        if (-not (Test-Path -LiteralPath $fixture.Destination)) { continue }
        try { Remove-FileWithRetry -Path $fixture.Destination }
        catch { $cleanupFailures.Add("Failed to remove save fixture $($fixture.Destination): $($_.Exception.Message)") | Out-Null }
    }

    if ($expectedScreenshotCount -gt 0) {
        try {
            $newScreenshots = @(Get-ChildItem -LiteralPath $gameRootPath -Filter 'ScreenShot*.bmp' -File |
                Sort-Object @{
                    Expression = {
                        if ($_.BaseName -match '^ScreenShot([0-9]+)$') { [int64]$Matches[1] }
                        else { [int64]::MaxValue }
                    }
                }, Name)
            for ($index = 0; $index -lt $newScreenshots.Count; $index++) {
                $frameLabel = if ($planMode -and $index -lt $sidecarCaptureLabels.Count) {
                    $sidecarCaptureLabels[$index]
                } elseif ($index -lt $ScreenshotFrame.Count) {
                    '{0:D6}' -f $ScreenshotFrame[$index]
                } elseif (($index - $ScreenshotFrame.Count) -lt $BatchTargetForm.Count) {
                    'target-' + ((Format-FNVFormId $BatchTargetForm[$index - $ScreenshotFrame.Count]) `
                        -replace '^0[xX]', '').ToLowerInvariant()
                } else {
                    'extra-{0:D3}' -f ($index - $expectedScreenshotCount + 1)
                }
                $capturePath = Join-Path $screenshotOutputDirectory "frame-$frameLabel.bmp"
                Move-Item -LiteralPath $newScreenshots[$index].FullName -Destination $capturePath
                $capturedScreenshots += $capturePath
            }
        } catch { $cleanupFailures.Add("Failed to collect retail screenshots: $($_.Exception.Message)") | Out-Null }
        if (Test-Path -LiteralPath $screenshotBackupDirectory) {
            try {
                foreach ($originalScreenshot in @(Get-ChildItem -LiteralPath $screenshotBackupDirectory -File)) {
                    $restorePath = Join-Path $gameRootPath $originalScreenshot.Name
                    if (Test-Path -LiteralPath $restorePath) {
                        throw "Refusing to overwrite screenshot while restoring: $restorePath"
                    }
                    Move-Item -LiteralPath $originalScreenshot.FullName -Destination $restorePath
                }
                Remove-Item -LiteralPath $screenshotBackupDirectory -Force
            } catch { $cleanupFailures.Add("Failed to restore pre-existing screenshots: $($_.Exception.Message)") | Out-Null }
        }
    }

    if (-not $preserveEphemeralRunRoot -and (Test-Path -LiteralPath $ephemeralRunRoot)) {
        try {
            if (-not (Test-PathWithinRoot -Path $ephemeralRunRoot -Root $runtimeRootPath)) {
                throw "Ephemeral run directory escaped RuntimeRoot: $ephemeralRunRoot"
            }
            Remove-DirectoryWithRetry -Path $ephemeralRunRoot -TimeoutMilliseconds 60000
        } catch {
            # This directory contains only the isolated plugin copy after hooks
            # and fixtures have been restored. A delayed external file lock must
            # not discard otherwise valid immutable capture evidence.
            $preserveEphemeralRunRoot = $true
            $cleanupWarnings.Add("Retained ephemeral xNVSE run directory after cleanup timeout: $ephemeralRunRoot ($($_.Exception.Message))") | Out-Null
        }
    }
}

if ($cleanupFailures.Count -gt 0) {
    $failurePrefix = if ($null -ne $runFailure) { "$($runFailure.Exception.Message) " } else { '' }
    throw ($failurePrefix + 'Cleanup failure(s): ' + ($cleanupFailures -join ' | '))
}
if ($null -ne $runFailure) {
    throw $runFailure
}

if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Retail oracle produced no output: $output"
}

# Actor geometry records intentionally carry complete vertex arrays. Keep them
# in the immutable JSONL, but do not deserialize those arrays into PowerShell's
# object graph merely to validate unrelated run events. Event counts still come
# from the full stream below, and the Goodsprings contract audits geometry by
# top-level refForm/event keys without discarding the raw payload.
$validationEvents = New-Object System.Collections.Generic.List[object]
$streamEventCounts = @{}
foreach ($eventLine in [System.IO.File]::ReadLines($output)) {
    $eventName = $null
    if ($eventLine -match '"event":"(?<eventName>[^"]+)"') {
        $eventName = [string]$Matches.eventName
        if (-not $streamEventCounts.ContainsKey($eventName)) { $streamEventCounts[$eventName] = 0 }
        ++$streamEventCounts[$eventName]
    }
    if ($eventName -eq 'actor-geometry') { continue }
    $validationEvents.Add(($eventLine | ConvertFrom-Json)) | Out-Null
}
$events = @($validationEvents.ToArray())
$gameSettingEvents = @($events | Where-Object { $_.event -eq 'game-setting' })
if ($GameSetting.Count -gt 0) {
    $probeStarts = @($events | Where-Object { $_.event -eq 'game-setting-probe-start' })
    $probeCompletions = @($events | Where-Object { $_.event -eq 'game-setting-probe-complete' })
    if ($probeStarts.Count -ne 1 -or $probeCompletions.Count -ne 1) {
        throw "GameSetting probe requires one start and one completion event (starts=$($probeStarts.Count), completions=$($probeCompletions.Count))."
    }
    if (-not [bool]$probeStarts[0].singletonReadable -or
        -not [bool]$probeStarts[0].collectionResolved) {
        throw 'GameSetting probe could not resolve the retail GameSettingCollection singleton.'
    }
    if ($gameSettingEvents.Count -ne $GameSetting.Count) {
        throw "GameSetting probe emitted $($gameSettingEvents.Count) values, expected $($GameSetting.Count)."
    }
    foreach ($editorId in $GameSetting) {
        $matches = @($gameSettingEvents | Where-Object {
            [string]$_.requestedEditorId -ceq $editorId
        })
        if ($matches.Count -ne 1) {
            throw "GameSetting probe did not emit exactly one event for '$editorId'."
        }
        $setting = $matches[0]
        if ([bool]$setting.found -ne [bool]$setting.readable) {
            throw "GameSetting probe found '$editorId' but could not read its Setting payload."
        }
        if ([bool]$setting.found -and
            ([string]::IsNullOrWhiteSpace([string]$setting.editorId) -or
                [string]::IsNullOrWhiteSpace([string]$setting.type) -or
                $setting.PSObject.Properties.Name -notcontains 'typeCode' -or
                $setting.PSObject.Properties.Name -notcontains 'raw' -or
                $null -eq $setting.raw -or
                $setting.raw.PSObject.Properties.Name -notcontains 'hex' -or
                $setting.raw.PSObject.Properties.Name -notcontains 'bytesLittleEndian' -or
                @($setting.raw.bytesLittleEndian).Count -ne 4 -or
                $setting.PSObject.Properties.Name -notcontains 'value')) {
            throw "GameSetting probe returned an incomplete type/raw/value payload for '$editorId'."
        }
    }
    $foundGameSettingCount = @($gameSettingEvents | Where-Object { [bool]$_.found }).Count
    if ([int]$probeCompletions[0].requested -ne $GameSetting.Count -or
        [int]$probeCompletions[0].found -ne $foundGameSettingCount -or
        [int]$probeCompletions[0].missing -ne ($GameSetting.Count - $foundGameSettingCount)) {
        throw 'GameSetting probe completion totals do not match the requested editor IDs.'
    }
}
if ($MaterialShaderCapture -and $capturedScreenshots.Count -eq 0 -and
    $ScreenshotFrame.Count -eq 1 -and $ScreenshotFrame[0] -eq $MaterialShaderFrame) {
    $rawFrames = @($events | Where-Object {
        $_.event -eq 'final-framebuffer-raw' -and $_.frame -eq $MaterialShaderFrame -and $_.complete
    })
    if ($rawFrames.Count -eq 1 -and (Test-Path -LiteralPath ([string]$rawFrames[0].path) -PathType Leaf)) {
        $derivedPath = Join-Path $screenshotOutputDirectory ('frame-{0:D6}.bmp' -f $MaterialShaderFrame)
        Convert-FNVRawFramebufferToBmp `
            -Path ([string]$rawFrames[0].path) `
            -OutputPath $derivedPath `
            -Width ([int]$rawFrames[0].width) `
            -Height ([int]$rawFrames[0].height) `
            -RowOrder ([string]$rawFrames[0].rowOrder) `
            -ChannelOrder ([string]$rawFrames[0].channelOrder)
        $capturedScreenshots += $derivedPath
        $framebufferDerivedScreenshots += $derivedPath
    }
}
$materialCaptureEvidence = $null
if ($MaterialShaderCapture) {
    if ($ScreenshotFrame -notcontains $MaterialShaderFrame) {
        throw "MaterialShaderCapture requires ScreenshotFrame to contain MaterialShaderFrame ($MaterialShaderFrame)."
    }
    $actorFrames = @($events | Where-Object {
        $_.event -eq 'actor-frame' -and $_.frame -eq $MaterialShaderFrame -and
        ($TargetForm -eq '0' -or $_.refForm -eq (ConvertTo-FNVFormId $TargetForm) -or
            $_.baseForm -eq (ConvertTo-FNVFormId $TargetForm))
    })
    if (-not $CaptureAnimation -or $actorFrames.Count -ne 1) {
        throw "Unified material capture requires exactly one target actor-frame at frame $MaterialShaderFrame; found $($actorFrames.Count)."
    }
    $ledgers = @($events | Where-Object {
        $_.event -eq 'd3d9-ledger' -and $_.captureFrame -eq $MaterialShaderFrame -and $_.opened
    })
    if ($ledgers.Count -ne 1) {
        throw "Unified material capture requires exactly one open D3D9 ledger at frame $MaterialShaderFrame; found $($ledgers.Count)."
    }
    $framebuffers = @($events | Where-Object {
        $_.event -eq 'final-framebuffer-raw' -and $_.frame -eq $MaterialShaderFrame -and $_.complete
    })
    if ($framebuffers.Count -ne 1) {
        throw "Unified material capture requires exactly one complete final framebuffer at frame $MaterialShaderFrame; found $($framebuffers.Count)."
    }
    $ledgerPath = [string]$ledgers[0].path
    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
        throw "Unified material capture D3D9 ledger is missing: $ledgerPath"
    }
    $ledgerEvents = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json })
    $ledgerStarts = @($ledgerEvents | Where-Object {
        $_.event -eq 'start' -and $_.captureFrame -eq $MaterialShaderFrame
    })
    $ledgerFrames = @($ledgerEvents | Where-Object {
        $_.event -eq 'final-framebuffer' -and $_.frame -eq $MaterialShaderFrame -and $_.complete
    })
    $draws = @($ledgerEvents | Where-Object { $_.event -eq 'draw' -and $_.frame -eq $MaterialShaderFrame })
    if ($ledgerStarts.Count -ne 1 -or $ledgerFrames.Count -ne 1 -or $draws.Count -lt 1) {
        throw "D3D9 ledger failed coherence gate at frame $MaterialShaderFrame (starts=$($ledgerStarts.Count), framebuffers=$($ledgerFrames.Count), draws=$($draws.Count))."
    }
    $materialCaptureEvidence = [ordered]@{
        frame = $MaterialShaderFrame
        actorFrames = $actorFrames.Count
        ledger = Get-FNVFileEvidence $ledgerPath 'retail-d3d9-ledger'
        draws = $draws.Count
        finalFramebuffer = Get-FNVFileEvidence ([string]$framebuffers[0].path) 'retail-final-framebuffer'
    }
}
if ($planMode) {
    $sidecarErrors = @($events | Where-Object { $_.event -eq 'sidecar-error' })
    if ($sidecarErrors.Count -ne 0) {
        throw "Retail sidecar emitted $($sidecarErrors.Count) error event(s)."
    }
    $actionStarts = @($events | Where-Object { $_.event -eq 'sidecar-action-start' })
    $retailReady = @($events | Where-Object { $_.event -eq 'sidecar-retail-ready' })
    $screenshotReady = @($events | Where-Object { $_.event -eq 'sidecar-screenshot-ready' })
    $actorStages = @($events | Where-Object { $_.event -eq 'sidecar-actor-stage' })
    $sequenceComplete = @($events | Where-Object { $_.event -eq 'sidecar-sequence-complete' })
    foreach ($pair in @(
        [pscustomobject]@{ label = 'action-start'; actual = $actionStarts.Count; expected = $expectedScreenshotCount },
        [pscustomobject]@{ label = 'retail-ready'; actual = $retailReady.Count; expected = $expectedScreenshotCount },
        [pscustomobject]@{ label = 'screenshot-ready'; actual = $screenshotReady.Count; expected = $expectedScreenshotCount },
        [pscustomobject]@{ label = 'actor-stage'; actual = $actorStages.Count; expected = $sidecarPlanActors.Count },
        [pscustomobject]@{ label = 'sequence-complete'; actual = $sequenceComplete.Count; expected = 1 }
    )) {
        if ($pair.actual -ne $pair.expected) {
            throw "Retail sidecar $($pair.label) count is $($pair.actual), expected $($pair.expected)."
        }
    }
    $seenCaptureKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($capture in $screenshotReady) {
        if ([string]$capture.sequenceId -cne $sidecarPlanSequenceId -or
            [int]$capture.actorIndex -lt 0 -or [int]$capture.actorIndex -ge $sidecarPlanActors.Count -or
            [int]$capture.actionIndex -lt 0 -or [int]$capture.actionIndex -ge $sidecarPlanActions.Count) {
            throw "Retail sidecar screenshot-ready has an invalid sequence/actor/action identity."
        }
        $key = '{0}/{1}/{2}' -f $capture.sequenceId, $capture.actorIndex, $capture.actionIndex
        if (-not $seenCaptureKeys.Add($key)) {
            throw "Retail sidecar duplicated capture key '$key'."
        }
        if ($null -eq $capture.telemetry) {
            throw "Retail sidecar capture '$key' has no telemetry payload."
        }
        $plannedActor = $sidecarPlanActors[[int]$capture.actorIndex]
        $plannedAction = $sidecarPlanActions[[int]$capture.actionIndex]
        $observedSequences = @(
            @($capture.telemetry.animation.middleHighSequences) +
            @($capture.telemetry.animation.animDataSequences) |
                Where-Object { $null -ne $_ -and [bool]$_.readable }
        )
        $hourError = [Math]::Abs([double]$capture.telemetry.environment.gameHour -
            [double]$sidecarScene.gameHour)
        if ($hourError -gt 12) { $hourError = 24 - $hourError }
        $faceTelemetryValid = $null -ne $capture.telemetry.face
        if ($faceTelemetryValid -and [bool]$capture.telemetry.face.npc) {
            $faceChannels = @($capture.telemetry.face.faceGenChannels)
            $faceTelemetryValid = [bool]$capture.telemetry.face.appearanceReadable -and
                $faceChannels.Count -eq 3 -and
                @($faceChannels | Where-Object { -not [bool]$_.readable }).Count -eq 0 -and
                [bool]$capture.telemetry.animation.facialRuntime.animationDataAvailable
        }
        if (-not [bool]$capture.telemetry.capture.screenshotReady -or
            -not [bool]$capture.telemetry.weaponPolicy.exact -or
            [string]$capture.telemetry.key.sequenceId -cne $sidecarPlanSequenceId -or
            [int]$capture.telemetry.key.actorIndex -ne [int]$capture.actorIndex -or
            [int]$capture.telemetry.key.actionIndex -ne [int]$capture.actionIndex -or
            [uint32]$capture.telemetry.actor.baseForm -ne [uint32]$plannedActor.baseForm -or
            ([uint32]$plannedActor.authoredRefForm -ne 0 -and
                [uint32]$capture.telemetry.actor.refForm -ne [uint32]$plannedActor.authoredRefForm) -or
            [uint32]$capture.telemetry.weaponPolicy.requestedForm -ne [uint32]$plannedActor.weaponForm -or
            [string]$capture.telemetry.action.id -cne [string]$plannedAction.id -or
            -not [bool]$capture.telemetry.action.accepted -or
            -not [bool]$capture.telemetry.animation.processAvailable -or
            $observedSequences.Count -eq 0 -or -not $faceTelemetryValid -or
            $null -eq $capture.telemetry.equipment -or
            [uint32]$capture.telemetry.environment.currentWeatherForm -ne [uint32]$sidecarScene.weatherForm -or
            $hourError -gt 0.01 -or
            [uint64]$capture.telemetry.capture.size -lt 54 -or
            [uint32]$capture.telemetry.capture.width -lt 1 -or
            [uint32]$capture.telemetry.capture.height -lt 1 -or
            [uint32]$capture.telemetry.capture.bitsPerPixel -notin @(16, 24, 32) -or
            [uint32]$capture.telemetry.capture.stableFrames -lt 2 -or
            $null -eq $capture.telemetry.camera.viewMatrix -or
            $null -eq $capture.telemetry.camera.projectionMatrix) {
            throw "Retail sidecar capture '$key' lacks exact actor/action/weapon, evaluated animation/FaceGen/equipment, matched environment/camera, or stable screenshot telemetry."
        }
    }
    if ([string]$sequenceComplete[0].sequenceId -cne $sidecarPlanSequenceId -or
        [int]$sequenceComplete[0].actors -ne $sidecarPlanActors.Count -or
        [int]$sequenceComplete[0].actionsPerActor -ne $sidecarPlanActions.Count -or
        [int]$sequenceComplete[0].captures -ne $expectedScreenshotCount) {
        throw "Retail sidecar completion summary does not match the compiled plan."
    }
    $eventValidation = [pscustomobject][ordered]@{
        schema = 'nikami-fnv-retail-sidecar-validation/v1'
        status = 'passed'
        eventCount = $events.Count
        sequenceId = $sidecarPlanSequenceId
        actors = $sidecarPlanActors.Count
        actionsPerActor = $sidecarPlanActions.Count
        captures = $expectedScreenshotCount
        lockstepTransport = 'shared-memory+named-events'
    }
} else {
    $eventValidation = Assert-FNVRetailOracleEvidence `
        -Events $events `
        -SaveName $SaveName `
        -TargetForm $TargetForm `
        -ExpectedTargetBaseForm $ExpectedTargetBaseForm `
        -BatchTargetForm $BatchTargetForm `
        -BatchExpectedBaseForm $BatchExpectedBaseForm `
        -ScreenshotFrame $ScreenshotFrame `
        -BeforeFrame $BeforeFrame `
        -CommandFrame $CommandFrame `
        -AfterFrame $AfterFrame `
        -MaxFrames $MaxFrames `
        -BatchSettleFrames $BatchSettleFrames `
        -BatchAdvanceFrames $BatchAdvanceFrames `
        -BatchMoveToTargets ([bool]$BatchMoveToTargets) `
        -BatchEnableTargets ([bool]$BatchEnableTargets) `
        -BatchProofStaging ([bool]$BatchProofStaging) `
        -BatchProofInitializationFrames $BatchProofInitializationFrames `
        -BatchEnableParentForm $BatchEnableParentForm `
        -PortraitCamera ([bool]$PortraitCamera) `
        -RequireAppearanceTelemetry ([bool]$RequireAppearanceTelemetry) `
        -BackgroundDataMode ([bool]$BackgroundDataMode)
}
$validationEventCount = [int]$eventValidation.eventCount
$totalStreamEventCount = [int](($streamEventCounts.Values | Measure-Object -Sum).Sum)
$eventValidation.eventCount = $totalStreamEventCount
$eventValidation | Add-Member -NotePropertyName validationEventCount -NotePropertyValue $validationEventCount
$eventValidation | Add-Member -NotePropertyName validationPayloadOmissions -NotePropertyValue @('actor-geometry')

$snapshots = @($events | Where-Object { $_.event -eq "behavior-snapshot" })
$appearanceEvents = @($events | Where-Object { $_.event -in @("npc-appearance", "target-appearance") })
$expectedScreenshotNames = if ($planMode) {
    @($sidecarCaptureLabels | ForEach-Object { "frame-$_.bmp" })
} else {
    @(Get-FNVExpectedScreenshotNames -Frame $ScreenshotFrame -BatchTargetForm $BatchTargetForm)
}
$screenshotEvidence = @(Assert-FNVRetailScreenshotFiles `
    -Path $capturedScreenshots -ExpectedName $expectedScreenshotNames)
$expectedPortraitEvents = if ($planMode) { 0 } elseif ($BatchTargetForm.Count -gt 0) {
    $BatchTargetForm.Count
} elseif ($PortraitCamera) { 1 } else { 0 }
if ($expectedPortraitEvents -gt 0) {
    $portraitEvents = @($events | Where-Object { $_.event -eq "portrait-camera-set" })
    if ($portraitEvents.Count -ne $expectedPortraitEvents) {
        throw "Portrait camera resolved $($portraitEvents.Count) actor head(s), expected $expectedPortraitEvents."
    }
    foreach ($cameraEvent in $portraitEvents) {
        if ($cameraEvent.PSObject.Properties.Name -notcontains 'shotKind' -or
            [string]$cameraEvent.shotKind -ne $CameraShotKind) {
            throw "Camera shot-kind contract expected '$CameraShotKind' on every portrait-camera-set event."
        }
        if ($CameraShotKind -eq 'front-full-body') {
            if ($cameraEvent.PSObject.Properties.Name -notcontains 'worldBound' -or
                -not [bool]$cameraEvent.worldBound.valid -or [double]$cameraEvent.worldBound.radius -le 0) {
                throw "Full-body camera event lacks a valid assembled-actor world bound."
            }
        }
    }
    Add-Type -AssemblyName System.Drawing
    foreach ($screenshot in $capturedScreenshots) {
        $sourceImage = [System.Drawing.Bitmap]::FromFile($screenshot)
        try {
            if ($sourceImage.Width -lt 800 -or $sourceImage.Height -lt 600) {
                throw "Portrait screenshot is too small to validate: $screenshot"
            }
            # Preserve the raw retail frame.  The derived square only removes unused
            # peripheral scenery; the head-relative camera keeps the actor in this
            # lower-center safe region at every supported aspect ratio.
            $cropSize = [Math]::Min($sourceImage.Width, [Math]::Floor($sourceImage.Height * 0.875))
            $cropX = [Math]::Floor(($sourceImage.Width - $cropSize) / 2)
            $cropY = $sourceImage.Height - $cropSize
            $proofImage = New-Object System.Drawing.Bitmap(
                $cropSize, $cropSize, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($proofImage)
                try {
                    $sourceRectangle = New-Object System.Drawing.Rectangle($cropX, $cropY, $cropSize, $cropSize)
                    $targetRectangle = New-Object System.Drawing.Rectangle(0, 0, $cropSize, $cropSize)
                    $graphics.DrawImage(
                        $sourceImage, $targetRectangle, $sourceRectangle, [System.Drawing.GraphicsUnit]::Pixel)
                }
                finally {
                    $graphics.Dispose()
                }
                $proofPath = [System.IO.Path]::Combine(
                    [System.IO.Path]::GetDirectoryName($screenshot),
                    [System.IO.Path]::GetFileNameWithoutExtension($screenshot) + '-proof-crop.png')
                $proofImage.Save($proofPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $portraitProofCrops += $proofPath
            }
            finally {
                $proofImage.Dispose()
            }
        }
        finally {
            $sourceImage.Dispose()
        }
    }
}

if ($BatchForceWeaponOut) {
    $weaponEvents = @($events | Where-Object { $_.event -eq 'batch-weapon-state' })
    if ($weaponEvents.Count -ne $BatchTargetForm.Count) {
        throw "Batch weapon-state contract expected $($BatchTargetForm.Count) terminal events; found $($weaponEvents.Count)."
    }
    for ($targetIndex = 0; $targetIndex -lt $BatchTargetForm.Count; ++$targetIndex) {
        $expectedReference = ConvertTo-FNVFormId $BatchTargetForm[$targetIndex]
        $matches = @($weaponEvents | Where-Object {
            $_.targetIndex -eq $targetIndex -and $_.refForm -eq $expectedReference
        })
        if ($matches.Count -ne 1) {
            throw ("Batch weapon-state identity mismatch at index {0} ({1:x8})." -f
                $targetIndex, $expectedReference)
        }
        $weaponEvent = $matches[0]
        if ([string]$weaponEvent.status -notin @('passed', 'not-applicable')) {
            throw "Batch weapon-state terminal status is not valid at target index $targetIndex."
        }
        if ([bool]$weaponEvent.weaponRequired -and (-not [bool]$weaponEvent.weaponOut -or
            [uint32]$weaponEvent.weaponForm -eq 0)) {
            throw "Batch target index $targetIndex has an equipped weapon that was not proven drawn."
        }
    }
}

if ($BatchProofStaging) {
    $proofLoads = @($events | Where-Object { $_.event -eq 'batch-proof-volume-load-request' })
    $proofReady = @($events | Where-Object { $_.event -eq 'batch-proof-volume-ready' })
    $stageRequests = @($events | Where-Object { $_.event -eq 'batch-target-stage-request' })
    $censusGates = @($events | Where-Object { $_.event -eq 'batch-proof-volume-census' })
    $occlusionGates = @($events | Where-Object { $_.event -eq 'batch-camera-occlusion-gate' })
    $visualGates = @($events | Where-Object { $_.event -eq 'batch-visual-stage-gate' })
    $releaseEvents = @($events | Where-Object { $_.event -eq 'batch-target-release' })
    if ($proofLoads.Count -ne 1 -or -not [bool]$proofLoads[0].accepted -or
        [uint32]$proofLoads[0].anchorForm -ne [uint32]$canonicalBatchProofAnchor) {
        throw "Proof-volume load contract requires one accepted request for the configured authored anchor."
    }
    if ($proofReady.Count -ne 1 -or -not [bool]$proofReady[0].passed) {
        throw "Proof-volume initialization contract requires one passed readiness event."
    }
    foreach ($eventSet in @($stageRequests, $censusGates, $occlusionGates, $visualGates, $releaseEvents)) {
        if ($eventSet.Count -ne $BatchTargetForm.Count) {
            throw "Proof-staging contract expected $($BatchTargetForm.Count) per-target events; found $($eventSet.Count)."
        }
    }
    for ($targetIndex = 0; $targetIndex -lt $BatchTargetForm.Count; ++$targetIndex) {
        $expectedReference = ConvertTo-FNVFormId $BatchTargetForm[$targetIndex]
        $stage = @($stageRequests | Where-Object {
            [int]$_.targetIndex -eq $targetIndex -and [uint32]$_.targetForm -eq $expectedReference
        })
        $gate = @($visualGates | Where-Object {
            [int]$_.targetIndex -eq $targetIndex -and [uint32]$_.targetForm -eq $expectedReference
        })
        $census = @($censusGates | Where-Object {
            [int]$_.targetIndex -eq $targetIndex -and [uint32]$_.targetForm -eq $expectedReference
        })
        $occlusion = @($occlusionGates | Where-Object {
            [int]$_.targetIndex -eq $targetIndex -and [uint32]$_.targetForm -eq $expectedReference
        })
        $release = @($releaseEvents | Where-Object {
            [int]$_.targetIndex -eq $targetIndex -and [uint32]$_.targetForm -eq $expectedReference
        })
        if ($stage.Count -ne 1 -or -not [bool]$stage[0].accepted) {
            throw "Proof staging was not accepted for target index $targetIndex."
        }
        if ($gate.Count -ne 1 -or -not [bool]$gate[0].passed -or
            -not [bool]$gate[0].rootAvailable -or -not [bool]$gate[0].worldBoundValid -or
            -not [bool]$gate[0].proofVolumeExclusive -or -not [bool]$gate[0].occlusionGatePassed) {
            throw "Visual-stage gate did not pass for target index $targetIndex."
        }
        if (@($gate[0].camera).Count -ne 3 -or @($gate[0].aim).Count -ne 3 -or
            [float]$gate[0].camera[2] + 0.01 -lt
                ([float]$BatchProofTargetZ + [float]$BatchProofMinimumCameraHeight) -or
            [float]$gate[0].aim[2] + 0.01 -lt
                ([float]$BatchProofTargetZ + [float]$BatchProofMinimumAimHeight)) {
            throw "Proof camera ground-clearance contract failed for target index $targetIndex."
        }
        if ($census.Count -ne 1 -or -not [bool]$census[0].passed -or
            [int]$census[0].intruders -ne 0) {
            throw "Proof volume was not exclusive to target index $targetIndex."
        }
        if ($occlusion.Count -ne 1 -or -not [bool]$occlusion[0].passed -or
            -not [bool]$occlusion[0].invoked -or [bool]$occlusion[0].faulted -or
            -not [bool]$occlusion[0].fractionValid -or [bool]$occlusion[0].hit) {
            throw "Camera-to-target corridor is not proven clear for target index $targetIndex."
        }
        if ($release.Count -ne 1 -or -not [bool]$release[0].accepted) {
            throw "Proof target was not released before batch advance at target index $targetIndex."
        }
    }
    $eventValidation | Add-Member -NotePropertyName proofStaging -NotePropertyValue ([pscustomobject][ordered]@{
        anchorForm = Format-FNVFormId $BatchProofAnchorForm
        targetsStaged = $stageRequests.Count
        exclusiveVolumeGatesPassed = $censusGates.Count
        cameraCorridorsPassed = $occlusionGates.Count
        visualGatesPassed = $visualGates.Count
        targetsReleased = $releaseEvents.Count
    })
}

foreach ($preLaunchEvidence in @($runtimeEvidence) + @($saveFixtureEvidence) + @($rootHookEvidence)) {
    $currentEvidence = Get-FNVFileEvidence $preLaunchEvidence.path $preLaunchEvidence.kind
    if ($currentEvidence.bytes -ne $preLaunchEvidence.bytes -or
        $currentEvidence.sha256 -ne $preLaunchEvidence.sha256) {
        throw "Provenance artifact changed during retail capture: $($preLaunchEvidence.path)"
    }
}
$captureEvidence = Get-FNVFileEvidence $output 'oracle-jsonl'
$proofCropEvidence = @($portraitProofCrops | ForEach-Object {
    Get-FNVFileEvidence $_ 'portrait-proof-crop'
})
$eventCounts = @($streamEventCounts.GetEnumerator() | Sort-Object Key | ForEach-Object {
    [pscustomobject][ordered]@{ event = [string]$_.Key; count = [int]$_.Value }
})
$finishedAt = Get-Date
$manifestDocument = [ordered]@{
    schema = 'nikami-fnv-retail-oracle-run-manifest/v1'
    status = 'passed'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    run = [ordered]@{
        save = $SaveName
        saveFixture = $resolvedSaveFixture
        startedAtUtc = $startedAt.ToUniversalTime().ToString('o')
        finishedAtUtc = $finishedAt.ToUniversalTime().ToString('o')
        gameExitCode = $exitCode
        gameRoot = $gameRootPath
        loader = $loader
        loaderArguments = @($loaderArgumentList)
        workingDirectory = $gameRootPath
        hidden = -not [bool]$VisibleGame
    }
    isolation = [ordered]@{
        runtimeRoot = $runtimeRootPath
        ephemeralRunRoot = $ephemeralRunRoot
        isolatedPluginDirectory = $isolatedPluginDirectory
        retailPluginDirectoryUsed = $false
        rootHookIsolation = $isolateRootHookDlls
        rootHookDlls = @($rootHookEvidence)
        environment = [pscustomobject]$environment
    }
    expectedIdentity = [ordered]@{
        eventSchema = 'nikami-retail-oracle/v4'
        runtime = 'FalloutNV-1.4.0.525'
        sidecar = if ($planMode) { [ordered]@{
            schema = 'nikami-fnv-sidecar-retail/v1'
            sequenceId = $sidecarPlanSequenceId
            planPath = $sidecarPlanPath
            sharedMemoryName = $SharedMemoryName
            barrierTimeoutMilliseconds = $BarrierTimeoutMilliseconds
            actors = $sidecarPlanActors.Count
            actionsPerActor = $sidecarPlanActions.Count
            captures = $expectedScreenshotCount
        } } else { $null }
        targetForm = Format-FNVFormId $TargetForm
        targetBaseForm = Format-FNVFormId $ExpectedTargetBaseForm
        batchTargetForms = @($BatchTargetForm | ForEach-Object { Format-FNVFormId $_ })
        batchBaseForms = @($BatchExpectedBaseForm | ForEach-Object { Format-FNVFormId $_ })
        batchEnableParentForms = @($BatchEnableParentForm | ForEach-Object { Format-FNVFormId $_ })
        screenshotFiles = @($expectedScreenshotNames)
        beforeFrame = $BeforeFrame
        commandFrame = $CommandFrame
        afterFrame = $AfterFrame
        maxFrames = $MaxFrames
        materialShaderCapture = [bool]$MaterialShaderCapture
        materialShaderFrame = $MaterialShaderFrame
        batchSettleFrames = $BatchSettleFrames
        batchAdvanceFrames = $BatchAdvanceFrames
        cameraShotKind = $CameraShotKind
        fullBodyDistanceScale = $FullBodyDistanceScale
        batchForceWeaponOut = [bool]$BatchForceWeaponOut
        batchWeaponProbeFrames = $BatchWeaponProbeFrames
        batchProofStaging = [bool]$BatchProofStaging
        batchProofAnchorForm = Format-FNVFormId $BatchProofAnchorForm
        batchProofTarget = @($BatchProofTargetX, $BatchProofTargetY, $BatchProofTargetZ, $BatchProofTargetYaw)
        batchProofPlayer = @($BatchProofPlayerX, $BatchProofPlayerY, $BatchProofPlayerZ)
        batchProofMinimumCameraHeight = $BatchProofMinimumCameraHeight
        batchProofMinimumAimHeight = $BatchProofMinimumAimHeight
        batchProofInitializationFrames = $BatchProofInitializationFrames
        batchProofTargetSettleFrames = $BatchProofTargetSettleFrames
        gameSettings = @($GameSetting)
    }
    overlay = [ordered]@{
        upstream = [string]$overlayLock.overlays.xnvse.upstream
        baseCommit = [string]$overlayLock.overlays.xnvse.baseCommit
        series = [string]$overlayLock.overlays.xnvse.series
        patchCount = [int]$overlayLock.overlays.xnvse.patchCount
        replayedTree = $expectedReplayedTree
    }
    provenance = [ordered]@{
        runtime = @($runtimeEvidence)
        saveFixture = @($saveFixtureEvidence)
    }
    evidence = [ordered]@{
        capture = $captureEvidence
        screenshots = @($screenshotEvidence)
        portraitProofCrops = @($proofCropEvidence)
        framebufferDerivedScreenshots = @($framebufferDerivedScreenshots | ForEach-Object {
            Get-FNVFileEvidence $_ 'framebuffer-derived-retail-screenshot'
        })
        materialCapture = $materialCaptureEvidence
        validationPayloadOmissions = @('actor-geometry')
        eventCounts = @($eventCounts)
    }
    validation = $eventValidation
}
$writtenRunManifest = Write-FNVImmutableJsonManifest $runManifest $manifestDocument
$runManifestEvidence = Get-FNVFileEvidence $writtenRunManifest 'oracle-run-manifest'

[pscustomobject][ordered]@{
    schema = "nikami-fnv-retail-oracle-run/v2"
    sidecar = if ($planMode) { [pscustomobject][ordered]@{
        enabled = $true
        sequenceId = $sidecarPlanSequenceId
        planPath = $sidecarPlanPath
        sharedMemoryName = $SharedMemoryName
        barrierTimeoutMilliseconds = $BarrierTimeoutMilliseconds
        actors = $sidecarPlanActors.Count
        actionsPerActor = $sidecarPlanActions.Count
        expectedCaptures = $expectedScreenshotCount
        completionEvent = 'sidecar-sequence-complete'
    } } else { $null }
    output = $output
    bytes = (Get-Item -LiteralPath $output).Length
    runManifest = $writtenRunManifest
    runManifestSha256 = $runManifestEvidence.sha256
    validation = $eventValidation
    save = $SaveName
    saveFixture = $resolvedSaveFixture
    quests = @($QuestForm)
    globals = @($GlobalForm)
    gameSettings = @($GameSetting)
    gameSettingTelemetry = @($gameSettingEvents)
    commands = @($Command)
    actorCommands = @($ActorCommand)
    furnitureSettledCommands = @($FurnitureSettledCommand)
    exitAfterFurnitureRelease = [bool]$ExitAfterFurnitureRelease
    exitAfterFurnitureSettledSamples = $ExitAfterFurnitureSettledSamples
    furnitureReleaseSamples = $FurnitureReleaseSamples
    backgroundDataMode = [bool]$BackgroundDataMode
    visibleGame = [bool]$VisibleGame
    runtimeRoot = $runtimeRootPath
    runtimeManifest = $runtimeManifestPath
    replayedTree = $expectedReplayedTree
    isolatedPluginDirectory = $isolatedPluginDirectory
    ephemeralRunRootRetained = [bool](Test-Path -LiteralPath $ephemeralRunRoot)
    cleanupWarnings = @($cleanupWarnings)
    retailPluginDirectoryUsed = $false
    isolatedFromFNVXR = $isolateRootHookDlls
    allowedRootHookDlls = -not $isolateRootHookDlls
    screenshotFrames = @($ScreenshotFrame)
    batchTargetForms = @($BatchTargetForm)
    batchExpectedBaseForms = @($BatchExpectedBaseForm)
    batchSettleFrames = $BatchSettleFrames
    batchAdvanceFrames = $BatchAdvanceFrames
    batchMoveToTargets = [bool]$BatchMoveToTargets
    batchEnableTargets = [bool]$BatchEnableTargets
    batchEnableParentForms = @($BatchEnableParentForm)
    screenshots = @($capturedScreenshots)
    framebufferDerivedScreenshots = @($framebufferDerivedScreenshots)
    portraitProofCrops = @($portraitProofCrops)
    portraitCamera = [bool]$PortraitCamera
    portraitDistance = $PortraitDistance
    cameraShotKind = $CameraShotKind
    fullBodyDistanceScale = $FullBodyDistanceScale
    batchForceWeaponOut = [bool]$BatchForceWeaponOut
    batchWeaponProbeFrames = $BatchWeaponProbeFrames
    batchProofStaging = [bool]$BatchProofStaging
    batchProofAnchorForm = Format-FNVFormId $BatchProofAnchorForm
    batchProofTarget = @($BatchProofTargetX, $BatchProofTargetY, $BatchProofTargetZ, $BatchProofTargetYaw)
    batchProofPlayer = @($BatchProofPlayerX, $BatchProofPlayerY, $BatchProofPlayerZ)
    batchProofMinimumCameraHeight = $BatchProofMinimumCameraHeight
    batchProofMinimumAimHeight = $BatchProofMinimumAimHeight
    batchProofInitializationFrames = $BatchProofInitializationFrames
    batchProofTargetSettleFrames = $BatchProofTargetSettleFrames
    materialShaderCapture = [bool]$MaterialShaderCapture
    materialShaderFrame = $MaterialShaderFrame
    materialCaptureEvidence = $materialCaptureEvidence
    appearanceTelemetry = @($appearanceEvents)
    setStageQuestForm = $SetStageQuestForm
    setStageIndex = $SetStageIndex
    captureAnimation = [bool]$CaptureAnimation
    captureSession = [bool]$CaptureSession
    sessionTargetForm = $SessionTargetForm
    furnitureOnly = [bool]$FurnitureOnly
    sampleEvery = $SampleEvery
    targetForm = $TargetForm
    expectedTargetBaseForm = $ExpectedTargetBaseForm
    observerApproachForm = $ObserverApproachForm
    observerApproachStopDistance = $ObserverApproachStopDistance
    observerApproachStepDistance = $ObserverApproachStepDistance
    observerWaypoints = @($ObserverWaypoint)
    equipForm = $EquipForm
    playGroup = $PlayGroup
    driveCommand = $DriveCommand
    prepareActorFrame = $PrepareActorFrame
    equipActorFrame = $EquipActorFrame
    driveActorFrame = $DriveActorFrame
    footIkToggleFrame = $FootIkToggleFrame
    footIkToggleEnabled = $FootIkToggleEnabled
    before = @($snapshots | Where-Object { $_.label -eq "before" } | Select-Object -First 1)
    after = @($snapshots | Where-Object { $_.label -eq "after" } | Select-Object -First 1)
    status = "captured-validated"
}
