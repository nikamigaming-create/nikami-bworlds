param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'FNVRetailOracleEvidence.ps1')

$failures = New-Object System.Collections.Generic.List[string]
$schema = 'nikami-retail-oracle/v4'
$startProperties = @{
    runtime = 'FalloutNV-1.4.0.525'
    boneLodWriterCallsHooked = $true
    highProcessBoneLodPathHooked = $true
    niAvObjectTransformLayout = 'local@0x34/world@0x68/NiTransform@0x34'
}

function New-OracleEvent([string]$Event, [hashtable]$Properties = @{}) {
    $row = [ordered]@{ schema = $script:schema; event = $Event }
    foreach ($key in $Properties.Keys) { $row[$key] = $Properties[$key] }
    return [pscustomobject]$row
}

function Copy-OracleEvents([object[]]$Events) {
    return @(($Events | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
}

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) | Out-Null }
}

function Assert-ThrowsLike([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notmatch $Pattern) {
        $detail = if ($null -eq $caught) { 'no exception' } else { $caught.Exception.Message }
        $script:failures.Add("$Message ($detail)") | Out-Null
    }
}

$singleEvents = @(
    (New-OracleEvent 'start' $startProperties),
    (New-OracleEvent 'load-result' @{ succeeded = $true }),
    (New-OracleEvent 'load-request' @{ save = 'FixtureSingle'; accepted = $true }),
    (New-OracleEvent 'background-game-mode' @{ frame = 0; closeAllMenusAccepted = $true }),
    (New-OracleEvent 'npc-appearance' @{ frame = 1; refForm = 0x00104C80; baseForm = 0x00104C7F }),
    (New-OracleEvent 'portrait-camera-set' @{ frame = 1; refForm = 0x00104C80 }),
    (New-OracleEvent 'behavior-snapshot' @{ frame = 10; label = 'before' }),
    (New-OracleEvent 'behavior-commands' @{ frame = 20 }),
    (New-OracleEvent 'screenshot-request' @{ frame = 30; requestedFrame = 30; accepted = $true }),
    (New-OracleEvent 'behavior-snapshot' @{ frame = 30; label = 'after' }),
    (New-OracleEvent 'capture-complete' @{ frames = 40 })
)
$singleArguments = @{
    SaveName = 'FixtureSingle'
    TargetForm = '0x00104C80'
    ExpectedTargetBaseForm = '0x00104C7F'
    ScreenshotFrame = @(30)
    BeforeFrame = 10
    CommandFrame = 20
    AfterFrame = 30
    MaxFrames = 40
    PortraitCamera = $true
    RequireAppearanceTelemetry = $true
    BackgroundDataMode = $true
}
$singleResult = Assert-FNVRetailOracleEvidence @singleArguments -Events $singleEvents
Assert-Contract ($singleResult.status -eq 'passed') 'Valid single-target evidence did not pass.'
Assert-Contract ($singleResult.targets.Count -eq 1) 'Single-target summary has the wrong target count.'
Assert-Contract ($singleResult.targets[0].refForm -eq '0x00104C80') 'Single-target summary lost refForm identity.'
Assert-Contract ($singleResult.targets[0].baseForm -eq '0x00104C7F') 'Single-target summary lost baseForm identity.'
Assert-Contract ($singleResult.screenshots[0].frame -eq 30) 'Single-target summary lost screenshot frame identity.'

$twoScreenshotEvents = New-Object System.Collections.Generic.List[object]
foreach ($event in $singleEvents) {
    if ($event.event -eq 'screenshot-request') {
        $twoScreenshotEvents.Add((New-OracleEvent 'screenshot-request' @{
            frame = 25; requestedFrame = 25; accepted = $true
        })) | Out-Null
    }
    $twoScreenshotEvents.Add($event) | Out-Null
}
$twoScreenshotArguments = @{}
foreach ($key in $singleArguments.Keys) { $twoScreenshotArguments[$key] = $singleArguments[$key] }
$twoScreenshotArguments.ScreenshotFrame = @(25, 30)
$twoScreenshotResult = Assert-FNVRetailOracleEvidence @twoScreenshotArguments `
    -Events @($twoScreenshotEvents | ForEach-Object { $_ })
Assert-Contract ($twoScreenshotResult.screenshots.Count -eq 2) `
    'Valid ordered screenshot identities did not pass.'
$case = Copy-OracleEvents @($twoScreenshotEvents | ForEach-Object { $_ })
$requests = @($case | Where-Object event -eq 'screenshot-request')
$requests[0].frame = 30
$requests[0].requestedFrame = 30
$requests[1].frame = 25
$requests[1].requestedFrame = 25
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @twoScreenshotArguments -Events $case } `
    'screenshot request 0 requested frame.*expected 25' 'Reordered screenshot identities were accepted.'

$case = Copy-OracleEvents $singleEvents
$case[0].schema = 'nikami-retail-oracle/wrong'
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'schema.*expected' 'Wrong event schema was accepted.'
$case = Copy-OracleEvents $singleEvents
$case[0].runtime = 'FalloutNV-wrong'
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'runtime.*does not match' 'Wrong runtime was accepted.'
$case = Copy-OracleEvents $singleEvents
$case[0].boneLodWriterCallsHooked = $false
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'did not confirm the Bone LOD writer hook' 'Failed start hook identity was accepted.'
$case = Copy-OracleEvents $singleEvents
$case = @($case[0]) + @($case)
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'expected one start event' 'Duplicate start was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'load-request').save = 'WrongFixture'
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'does not exactly match' 'Wrong load save was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'load-result').succeeded = $false
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'load-result did not succeed' 'Failed load-result was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'load-request').accepted = 'false'
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'accepted is not a JSON boolean' 'String-valued load acceptance was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'npc-appearance').refForm = 0x00104E85
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'appearance refForm.*does not match' 'Wrong target refForm was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'npc-appearance').baseForm = 0x00104E84
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'appearance baseForm.*does not match' 'Wrong target baseForm was accepted.'
$case = Copy-OracleEvents $singleEvents
$appearance = @($case | Where-Object event -eq 'npc-appearance')[0]
$case += $appearance
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'expected one target appearance event' 'Duplicate target appearance was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object { $_.event -eq 'behavior-snapshot' -and $_.label -eq 'before' }).frame = 11
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'before behavior-snapshot is not frame 10' 'Wrong before frame was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'screenshot-request').requestedFrame = 29
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'requested frame.*expected 30' 'Wrong requested screenshot frame was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'screenshot-request').requestedFrame = '30'
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'requestedFrame is not a JSON integer' 'String-valued screenshot frame was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'screenshot-request').frame = 31
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'was not emitted at frame 30' 'Wrong screenshot emission frame was accepted.'
$case = Copy-OracleEvents $singleEvents
($case | Where-Object event -eq 'screenshot-request').accepted = $false
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'screenshot request 0 was rejected' 'Rejected screenshot was accepted.'
$case = Copy-OracleEvents $singleEvents
$case = @($case | Where-Object event -ne 'capture-complete')
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @singleArguments -Events $case } `
    'expected one capture-complete' 'Missing capture-complete was accepted.'

$batchEvents = @(
    (New-OracleEvent 'start' $startProperties),
    (New-OracleEvent 'load-result' @{ succeeded = $true }),
    (New-OracleEvent 'load-request' @{ save = 'FixtureBatch'; accepted = $true }),
    (New-OracleEvent 'background-game-mode' @{ frame = 0; closeAllMenusAccepted = $true }),
    (New-OracleEvent 'batch-enable-parent-request' @{
        frame = 1; parentForm = 0x00105D4C; referenceAvailable = $true; accepted = $true
    }),
    (New-OracleEvent 'batch-target-load-request' @{
        frame = 1; targetIndex = 0; targetForm = 0x00104C80; referenceAvailable = $true;
        enableRequested = $false; enableAccepted = $true; moveRequested = $true; moveAccepted = $true
    }),
    (New-OracleEvent 'npc-appearance' @{ frame = 1; refForm = 0x00104C80; baseForm = 0x00104C7F }),
    (New-OracleEvent 'portrait-camera-set' @{ frame = 1; refForm = 0x00104C80 }),
    (New-OracleEvent 'batch-target-ready' @{ frame = 2; targetIndex = 0; targetForm = 0x00104C80 }),
    (New-OracleEvent 'behavior-snapshot' @{ frame = 10; label = 'before' }),
    (New-OracleEvent 'behavior-commands' @{ frame = 20 }),
    (New-OracleEvent 'batch-screenshot-request' @{
        frame = 22; targetIndex = 0; targetForm = 0x00104C80; accepted = $true
    }),
    (New-OracleEvent 'batch-target-complete' @{ frame = 25; targetIndex = 0; targetForm = 0x00104C80 }),
    (New-OracleEvent 'batch-target-load-request' @{
        frame = 26; targetIndex = 1; targetForm = 0x00104E85; referenceAvailable = $true;
        enableRequested = $false; enableAccepted = $true; moveRequested = $true; moveAccepted = $true
    }),
    (New-OracleEvent 'npc-appearance' @{ frame = 26; refForm = 0x00104E85; baseForm = 0x00104E84 }),
    (New-OracleEvent 'portrait-camera-set' @{ frame = 26; refForm = 0x00104E85 }),
    (New-OracleEvent 'batch-target-ready' @{ frame = 26; targetIndex = 1; targetForm = 0x00104E85 }),
    (New-OracleEvent 'behavior-snapshot' @{ frame = 30; label = 'after' }),
    (New-OracleEvent 'batch-screenshot-request' @{
        frame = 46; targetIndex = 1; targetForm = 0x00104E85; accepted = $true
    }),
    (New-OracleEvent 'batch-target-complete' @{ frame = 49; targetIndex = 1; targetForm = 0x00104E85 }),
    (New-OracleEvent 'capture-complete' @{ frames = 49 })
)
$batchArguments = @{
    SaveName = 'FixtureBatch'
    BatchTargetForm = @('0x00104C80', '0x00104E85')
    BatchExpectedBaseForm = @('0x00104C7F', '0x00104E84')
    BeforeFrame = 10
    CommandFrame = 20
    AfterFrame = 30
    MaxFrames = 100
    BatchSettleFrames = 20
    BatchAdvanceFrames = 3
    BatchMoveToTargets = $true
    BatchEnableTargets = $false
    BatchEnableParentForm = @('0x00105D4C')
    RequireAppearanceTelemetry = $true
    BackgroundDataMode = $true
}
$batchResult = Assert-FNVRetailOracleEvidence @batchArguments -Events $batchEvents
Assert-Contract ($batchResult.status -eq 'passed') 'Valid batch evidence did not pass.'
Assert-Contract ($batchResult.targets.Count -eq 2) 'Batch summary has the wrong target count.'
Assert-Contract ($batchResult.targets[1].targetIndex -eq 1) 'Batch summary lost target index identity.'
Assert-Contract ($batchResult.targets[1].baseForm -eq '0x00104E84') 'Batch summary lost base identity.'
Assert-Contract ($batchResult.screenshots[1].frame -eq 46) 'Batch summary lost screenshot frame identity.'

$case = Copy-OracleEvents $batchEvents
($case | Where-Object { $_.event -eq 'batch-target-ready' -and $_.targetIndex -eq 1 }).targetForm = 0x00104C80
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @batchArguments -Events $case } `
    'batch target 1 has 0 matching ready events' 'Wrong batch target/form pairing was accepted.'
$case = Copy-OracleEvents $batchEvents
($case | Where-Object { $_.event -eq 'batch-target-ready' -and $_.targetIndex -eq 1 }).targetIndex = '1'
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @batchArguments -Events $case } `
    'targetIndex is not a JSON integer' 'String-valued batch target index was accepted.'
$case = Copy-OracleEvents $batchEvents
$appearance = @($case | Where-Object { $_.event -eq 'npc-appearance' -and $_.refForm -eq 0x00104E85 })[0]
$case += $appearance
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @batchArguments -Events $case } `
    'expected 2 batch appearance event' 'Duplicate batch appearance was accepted.'
$case = Copy-OracleEvents $batchEvents
($case | Where-Object { $_.event -eq 'npc-appearance' -and $_.refForm -eq 0x00104E85 }).baseForm = 0x00104C7F
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @batchArguments -Events $case } `
    'batch target 1 baseForm.*does not match' 'Wrong batch baseForm was accepted.'
$case = Copy-OracleEvents $batchEvents
($case | Where-Object { $_.event -eq 'batch-screenshot-request' -and $_.targetIndex -eq 1 }).frame = 45
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @batchArguments -Events $case } `
    'screenshot frame 45 does not equal ready\+20' 'Wrong batch screenshot timing was accepted.'
$case = Copy-OracleEvents $batchEvents
($case | Where-Object { $_.event -eq 'batch-target-load-request' -and $_.targetIndex -eq 1 }).moveAccepted = $false
Assert-ThrowsLike { Assert-FNVRetailOracleEvidence @batchArguments -Events $case } `
    'batch target 1 move was rejected' 'Rejected batch movement was accepted.'

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "nikami-fnv-evidence-contract-$PID-$([Guid]::NewGuid().ToString('N'))")
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $artifact = Join-Path $temporaryRoot 'capture.jsonl'
    [System.IO.File]::WriteAllText($artifact, "{`"event`":`"synthetic`"}`n")
    $artifactEvidence = Get-FNVFileEvidence $artifact 'oracle-jsonl'
    Assert-Contract ($artifactEvidence.bytes -gt 0) 'File evidence omitted byte length.'
    Assert-Contract ($artifactEvidence.sha256 -match '^[0-9a-f]{64}$') 'File evidence omitted SHA-256.'

    $frameNames = @(Get-FNVExpectedScreenshotNames -Frame 25, 30)
    $targetNames = @(Get-FNVExpectedScreenshotNames `
        -BatchTargetForm '0x00104C80', '1068677')
    Assert-Contract ($frameNames[0] -eq 'frame-000025.bmp' -and
        $frameNames[1] -eq 'frame-000030.bmp') 'Frame screenshot names are not canonical.'
    Assert-Contract ($targetNames[0] -eq 'frame-target-00104c80.bmp' -and
        $targetNames[1] -eq 'frame-target-00104e85.bmp') 'Target screenshot names are not canonical.'
    $screenshotDirectory = Join-Path $temporaryRoot 'screens'
    New-Item -ItemType Directory -Path $screenshotDirectory | Out-Null
    $screenshotPaths = @($frameNames | ForEach-Object {
        $path = Join-Path $screenshotDirectory $_
        [System.IO.File]::WriteAllText($path, "synthetic-screen-$_")
        $path
    })
    $screenshotEvidence = @(Assert-FNVRetailScreenshotFiles `
        -Path $screenshotPaths -ExpectedName $frameNames)
    Assert-Contract ($screenshotEvidence.Count -eq 2) `
        'Screenshot file validator returned the wrong evidence count.'
    Assert-ThrowsLike {
        Assert-FNVRetailScreenshotFiles -Path @($screenshotPaths[1], $screenshotPaths[0]) `
            -ExpectedName $frameNames
    } 'screenshot file 0.*expected' 'Screenshot file validator accepted reordered files.'
    Assert-ThrowsLike {
        Assert-FNVRetailScreenshotFiles -Path @($screenshotPaths[0]) -ExpectedName $frameNames
    } 'expected 2 screenshot file.*got 1' 'Screenshot file validator accepted a missing file.'

    $manifestPath = "$artifact.manifest.json"
    $manifest = [ordered]@{
        schema = 'nikami-fnv-retail-oracle-run-manifest/v1'
        status = 'passed'
        capture = $artifactEvidence
    }
    $written = Write-FNVImmutableJsonManifest $manifestPath $manifest
    Assert-Contract ($written -eq $manifestPath) 'Immutable manifest returned the wrong path.'
    $loadedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Contract ($loadedManifest.schema -eq 'nikami-fnv-retail-oracle-run-manifest/v1') `
        'Immutable manifest lost its schema identity.'
    Assert-Contract ($loadedManifest.capture.sha256 -eq $artifactEvidence.sha256) `
        'Immutable manifest lost its capture hash binding.'
    $firstHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    Assert-ThrowsLike { Write-FNVImmutableJsonManifest $manifestPath @{ status = 'overwritten' } } `
        'Refusing to overwrite existing retail-oracle run manifest' 'Immutable manifest allowed overwrite.'
    Assert-Contract ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -eq $firstHash) `
        'Immutable manifest changed after rejected overwrite.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $expectedPrefix = Join-Path ([System.IO.Path]::GetTempPath()) 'nikami-fnv-evidence-contract-'
        if (-not $temporaryRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected evidence contract directory: $temporaryRoot"
        }
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'FNV retail-oracle evidence contract failures:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    throw "FNV retail-oracle evidence contract failed with $($failures.Count) error(s)."
}

Write-Host 'FNV retail-oracle evidence contract passed.'
