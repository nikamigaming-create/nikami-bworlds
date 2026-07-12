function Test-FNVEvidenceProperty([object]$Object, [string]$Name) {
    return $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}

function ConvertTo-FNVFormId([object]$Value, [string]$Label = 'FormID') {
    try {
        if ($Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32]) {
            return [uint32]$Value
        }
        if ($Value -is [sbyte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) {
            if ([int64]$Value -lt 0 -or [uint64]$Value -gt [uint32]::MaxValue) { throw 'out of range' }
            return [uint32]$Value
        }
        $text = ([string]$Value).Trim()
        if ($text -match '^0[xX]([0-9a-fA-F]+)$') {
            return [Convert]::ToUInt32($Matches[1], 16)
        }
        if ($text -match '^[0-9]+$') {
            return [Convert]::ToUInt32($text, 10)
        }
    }
    catch {
        throw "Invalid $Label '$Value'."
    }
    throw "Invalid $Label '$Value'."
}

function Format-FNVFormId([object]$Value) {
    return '0x{0:X8}' -f (ConvertTo-FNVFormId $Value)
}

function Assert-FNVEvidence([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "Retail oracle evidence validation failed: $Message"
    }
}

function Get-FNVEvidenceBoolean([object]$Event, [string]$Property, [string]$EventLabel) {
    Assert-FNVEvidence (Test-FNVEvidenceProperty $Event $Property) "$EventLabel is missing $Property."
    $value = $Event.$Property
    Assert-FNVEvidence ($value -is [bool]) `
        "$EventLabel.$Property is not a JSON boolean."
    return [bool]$value
}

function Get-FNVEvidenceUInt32([object]$Event, [string]$Property, [string]$EventLabel) {
    Assert-FNVEvidence (Test-FNVEvidenceProperty $Event $Property) "$EventLabel is missing $Property."
    $value = $Event.$Property
    $isInteger = $value -is [byte] -or $value -is [sbyte] -or
        $value -is [uint16] -or $value -is [int16] -or
        $value -is [uint32] -or $value -is [int32] -or
        $value -is [uint64] -or $value -is [int64]
    Assert-FNVEvidence $isInteger "$EventLabel.$Property is not a JSON integer."
    if ($value -is [sbyte] -or $value -is [int16] -or $value -is [int32] -or $value -is [int64]) {
        Assert-FNVEvidence ([int64]$value -ge 0) "$EventLabel.$Property is negative."
    }
    Assert-FNVEvidence ([uint64]$value -le [uint32]::MaxValue) `
        "$EventLabel.$Property exceeds a 32-bit unsigned integer."
    return [uint32]$value
}

function Get-FNVEventForm([object]$Event, [string]$Property, [string]$EventLabel) {
    return Get-FNVEvidenceUInt32 $Event $Property $EventLabel
}

function Get-FNVEventFrame([object]$Event, [string]$EventLabel) {
    return Get-FNVEvidenceUInt32 $Event 'frame' $EventLabel
}

function Assert-FNVRetailOracleEvidence {
    param(
        [Parameter(Mandatory)]
        [object[]]$Events,
        [Parameter(Mandatory)]
        [string]$SaveName,
        [string]$TargetForm = '0',
        [string]$ExpectedTargetBaseForm = '0',
        [string[]]$BatchTargetForm = @(),
        [string[]]$BatchExpectedBaseForm = @(),
        [int[]]$ScreenshotFrame = @(),
        [int]$BeforeFrame = 10,
        [int]$CommandFrame = 20,
        [int]$AfterFrame = 30,
        [int]$MaxFrames = 40,
        [int]$BatchSettleFrames = 20,
        [int]$BatchAdvanceFrames = 3,
        [bool]$BatchMoveToTargets = $false,
        [bool]$BatchEnableTargets = $false,
        [string[]]$BatchEnableParentForm = @(),
        [bool]$PortraitCamera = $false,
        [bool]$RequireAppearanceTelemetry = $false,
        [bool]$BackgroundDataMode = $false,
        [string]$ExpectedRuntime = 'FalloutNV-1.4.0.525',
        [string]$ExpectedSchema = 'nikami-retail-oracle/v4'
    )

    $allEvents = @($Events)
    Assert-FNVEvidence ($allEvents.Count -gt 0) 'capture contains no events.'
    for ($eventIndex = 0; $eventIndex -lt $allEvents.Count; ++$eventIndex) {
        $event = $allEvents[$eventIndex]
        Assert-FNVEvidence (Test-FNVEvidenceProperty $event 'event') "event $eventIndex has no event name."
        Assert-FNVEvidence (Test-FNVEvidenceProperty $event 'schema') "event $eventIndex has no schema."
        Assert-FNVEvidence ([string]$event.schema -eq $ExpectedSchema) `
            "event $eventIndex has schema '$($event.schema)', expected '$ExpectedSchema'."
    }

    $faults = @($allEvents | Where-Object { [string]$_.event -match 'fault' })
    Assert-FNVEvidence ($faults.Count -eq 0) "capture contains $($faults.Count) fault event(s)."
    Assert-FNVEvidence (@($allEvents | Where-Object { $_.event -eq 'load-rejected' }).Count -eq 0) `
        'capture contains load-rejected.'

    $startEvents = @($allEvents | Where-Object { $_.event -eq 'start' })
    Assert-FNVEvidence ($startEvents.Count -eq 1) "expected one start event, got $($startEvents.Count)."
    Assert-FNVEvidence ([string]$allEvents[0].event -eq 'start') 'start is not the first event.'
    Assert-FNVEvidence (Test-FNVEvidenceProperty $startEvents[0] 'runtime') 'start is missing runtime.'
    Assert-FNVEvidence ([string]$startEvents[0].runtime -eq $ExpectedRuntime) `
        "runtime '$($startEvents[0].runtime)' does not match '$ExpectedRuntime'."
    Assert-FNVEvidence (Get-FNVEvidenceBoolean $startEvents[0] 'boneLodWriterCallsHooked' 'start') `
        'start did not confirm the Bone LOD writer hook.'
    Assert-FNVEvidence (Get-FNVEvidenceBoolean $startEvents[0] 'highProcessBoneLodPathHooked' 'start') `
        'start did not confirm the HighProcess Bone LOD path hook.'
    Assert-FNVEvidence (Test-FNVEvidenceProperty $startEvents[0] 'niAvObjectTransformLayout') `
        'start is missing niAvObjectTransformLayout.'
    $expectedTransformLayout = 'local@0x34/world@0x68/NiTransform@0x34'
    Assert-FNVEvidence ([string]$startEvents[0].niAvObjectTransformLayout -ceq $expectedTransformLayout) `
        "start transform layout does not exactly match '$expectedTransformLayout'."

    $loadRequests = @($allEvents | Where-Object { $_.event -eq 'load-request' })
    $loadResults = @($allEvents | Where-Object { $_.event -eq 'load-result' })
    Assert-FNVEvidence ($loadRequests.Count -eq 1) "expected one load-request, got $($loadRequests.Count)."
    Assert-FNVEvidence ($loadResults.Count -eq 1) "expected one load-result, got $($loadResults.Count)."
    Assert-FNVEvidence (Test-FNVEvidenceProperty $loadRequests[0] 'save') 'load-request is missing save.'
    Assert-FNVEvidence ([string]$loadRequests[0].save -ceq $SaveName) `
        "load-request save '$($loadRequests[0].save)' does not exactly match '$SaveName'."
    Assert-FNVEvidence (Get-FNVEvidenceBoolean $loadRequests[0] 'accepted' 'load-request') `
        'load-request was not accepted.'
    Assert-FNVEvidence (Get-FNVEvidenceBoolean $loadResults[0] 'succeeded' 'load-result') `
        'load-result did not succeed.'

    $backgroundEvents = @($allEvents | Where-Object { $_.event -eq 'background-game-mode' })
    if ($BackgroundDataMode) {
        Assert-FNVEvidence ($backgroundEvents.Count -eq 1) `
            "expected one background-game-mode event, got $($backgroundEvents.Count)."
        Assert-FNVEvidence ((Get-FNVEventFrame $backgroundEvents[0] 'background-game-mode') -eq 0) `
            'background-game-mode was not frame 0.'
        Assert-FNVEvidence (Get-FNVEvidenceBoolean $backgroundEvents[0] 'closeAllMenusAccepted' `
            'background-game-mode') `
            'background-game-mode did not accept CloseAllMenus.'
    }
    else {
        Assert-FNVEvidence ($backgroundEvents.Count -eq 0) 'unexpected background-game-mode event.'
    }

    $beforeSnapshots = @($allEvents | Where-Object { $_.event -eq 'behavior-snapshot' -and $_.label -eq 'before' })
    $afterSnapshots = @($allEvents | Where-Object { $_.event -eq 'behavior-snapshot' -and $_.label -eq 'after' })
    $commandEvents = @($allEvents | Where-Object { $_.event -eq 'behavior-commands' })
    Assert-FNVEvidence ($beforeSnapshots.Count -eq 1) `
        "expected one before behavior-snapshot, got $($beforeSnapshots.Count)."
    Assert-FNVEvidence ($afterSnapshots.Count -eq 1) `
        "expected one after behavior-snapshot, got $($afterSnapshots.Count)."
    Assert-FNVEvidence ($commandEvents.Count -eq 1) `
        "expected one behavior-commands event, got $($commandEvents.Count)."
    Assert-FNVEvidence ((Get-FNVEventFrame $beforeSnapshots[0] 'before behavior-snapshot') -eq $BeforeFrame) `
        "before behavior-snapshot is not frame $BeforeFrame."
    Assert-FNVEvidence ((Get-FNVEventFrame $commandEvents[0] 'behavior-commands') -eq $CommandFrame) `
        "behavior-commands is not frame $CommandFrame."
    Assert-FNVEvidence ((Get-FNVEventFrame $afterSnapshots[0] 'after behavior-snapshot') -eq $AfterFrame) `
        "after behavior-snapshot is not frame $AfterFrame."

    $completeEvents = @($allEvents | Where-Object { $_.event -eq 'capture-complete' })
    Assert-FNVEvidence ($completeEvents.Count -eq 1) `
        "expected one capture-complete event, got $($completeEvents.Count)."
    $completeFrame = Get-FNVEvidenceUInt32 $completeEvents[0] 'frames' 'capture-complete'
    Assert-FNVEvidence ($completeFrame -ge $AfterFrame -and $completeFrame -le $MaxFrames) `
        "capture-complete frames '$completeFrame' is outside [$AfterFrame,$MaxFrames]."
    foreach ($event in $allEvents) {
        if (-not (Test-FNVEvidenceProperty $event 'frame')) { continue }
        $frame = Get-FNVEventFrame $event ([string]$event.event)
        Assert-FNVEvidence ($frame -le $completeFrame) `
            "event '$($event.event)' frame $frame exceeds capture-complete frame $completeFrame."
    }

    $expectedTarget = ConvertTo-FNVFormId $TargetForm 'TargetForm'
    $expectedBase = ConvertTo-FNVFormId $ExpectedTargetBaseForm 'ExpectedTargetBaseForm'
    $batchTargets = @($BatchTargetForm | ForEach-Object { ConvertTo-FNVFormId $_ 'BatchTargetForm' })
    $batchBases = @($BatchExpectedBaseForm | ForEach-Object { ConvertTo-FNVFormId $_ 'BatchExpectedBaseForm' })
    $parentForms = @($BatchEnableParentForm | ForEach-Object { ConvertTo-FNVFormId $_ 'BatchEnableParentForm' })
    Assert-FNVEvidence ($batchBases.Count -eq 0 -or $batchBases.Count -eq $batchTargets.Count) `
        'BatchExpectedBaseForm count must be zero or equal BatchTargetForm count.'
    Assert-FNVEvidence (@($batchTargets | Select-Object -Unique).Count -eq $batchTargets.Count) `
        'BatchTargetForm contains duplicates.'

    $appearanceEvents = @($allEvents | Where-Object { $_.event -in @('npc-appearance', 'target-appearance') })
    $portraitEvents = @($allEvents | Where-Object { $_.event -eq 'portrait-camera-set' })
    $singleScreenshots = @($allEvents | Where-Object { $_.event -eq 'screenshot-request' })
    $batchScreenshots = @($allEvents | Where-Object { $_.event -eq 'batch-screenshot-request' })
    $targetIdentities = New-Object System.Collections.Generic.List[object]
    $screenshotIdentities = New-Object System.Collections.Generic.List[object]

    if ($batchTargets.Count -eq 0) {
        Assert-FNVEvidence ($batchScreenshots.Count -eq 0) 'single-target capture contains batch screenshot events.'
        if ($expectedTarget -eq 0) {
            Assert-FNVEvidence ($appearanceEvents.Count -eq 0) 'zero TargetForm capture contains appearance telemetry.'
            Assert-FNVEvidence ($portraitEvents.Count -eq 0) 'zero TargetForm capture contains portrait telemetry.'
        }
        else {
            Assert-FNVEvidence ($appearanceEvents.Count -eq 1) `
                "expected one target appearance event, got $($appearanceEvents.Count)."
            $appearance = $appearanceEvents[0]
            $actualRef = Get-FNVEventForm $appearance 'refForm' 'target appearance'
            $actualBase = Get-FNVEventForm $appearance 'baseForm' 'target appearance'
            Assert-FNVEvidence ($actualRef -eq $expectedTarget) `
                "appearance refForm $(Format-FNVFormId $actualRef) does not match $(Format-FNVFormId $expectedTarget)."
            Assert-FNVEvidence ($actualBase -ne 0) 'appearance baseForm is zero.'
            if ($expectedBase -ne 0) {
                Assert-FNVEvidence ($actualBase -eq $expectedBase) `
                    "appearance baseForm $(Format-FNVFormId $actualBase) does not match $(Format-FNVFormId $expectedBase)."
            }
            if ($RequireAppearanceTelemetry) {
                Assert-FNVEvidence ([string]$appearance.event -eq 'npc-appearance') `
                    'RequireAppearanceTelemetry resolved a non-NPC target.'
            }
            $appearanceFrame = Get-FNVEventFrame $appearance 'target appearance'
            $portraitFrame = $null
            if ($PortraitCamera) {
                Assert-FNVEvidence ($portraitEvents.Count -eq 1) `
                    "expected one portrait-camera-set, got $($portraitEvents.Count)."
                $portraitRef = Get-FNVEventForm $portraitEvents[0] 'refForm' 'portrait-camera-set'
                Assert-FNVEvidence ($portraitRef -eq $expectedTarget) `
                    "portrait refForm $(Format-FNVFormId $portraitRef) does not match target."
                $portraitFrame = Get-FNVEventFrame $portraitEvents[0] 'portrait-camera-set'
            }
            else {
                Assert-FNVEvidence ($portraitEvents.Count -eq 0) 'unexpected portrait-camera-set event.'
            }
            $targetIdentities.Add([pscustomobject][ordered]@{
                targetIndex = 0
                refForm = Format-FNVFormId $actualRef
                baseForm = Format-FNVFormId $actualBase
                appearanceFrame = $appearanceFrame
                portraitFrame = $portraitFrame
            }) | Out-Null
        }

        $expectedScreenshots = @($ScreenshotFrame | Sort-Object -Unique)
        Assert-FNVEvidence ($singleScreenshots.Count -eq $expectedScreenshots.Count) `
            "expected $($expectedScreenshots.Count) screenshot-request event(s), got $($singleScreenshots.Count)."
        for ($index = 0; $index -lt $expectedScreenshots.Count; ++$index) {
            $request = $singleScreenshots[$index]
            $expectedFrame = [int]$expectedScreenshots[$index]
            Assert-FNVEvidence ((Get-FNVEvidenceUInt32 $request 'requestedFrame' "screenshot-request $index") `
                -eq $expectedFrame) `
                "screenshot request $index requested frame '$($request.requestedFrame)', expected $expectedFrame."
            Assert-FNVEvidence ((Get-FNVEventFrame $request "screenshot-request $index") -eq $expectedFrame) `
                "screenshot request $index was not emitted at frame $expectedFrame."
            Assert-FNVEvidence (Get-FNVEvidenceBoolean $request 'accepted' "screenshot-request $index") `
                "screenshot request $index was rejected."
            $screenshotIdentities.Add([pscustomobject][ordered]@{
                kind = 'frame'
                frame = $expectedFrame
                targetIndex = $null
                targetForm = if ($expectedTarget -ne 0) { Format-FNVFormId $expectedTarget } else { $null }
            }) | Out-Null
        }
    }
    else {
        Assert-FNVEvidence ($singleScreenshots.Count -eq 0) 'batch capture contains single screenshot-request events.'
        Assert-FNVEvidence ($appearanceEvents.Count -eq $batchTargets.Count) `
            "expected $($batchTargets.Count) batch appearance event(s), got $($appearanceEvents.Count)."
        Assert-FNVEvidence ($portraitEvents.Count -eq $batchTargets.Count) `
            "expected $($batchTargets.Count) batch portrait event(s), got $($portraitEvents.Count)."

        $loadEvents = @($allEvents | Where-Object { $_.event -eq 'batch-target-load-request' })
        $readyEvents = @($allEvents | Where-Object { $_.event -eq 'batch-target-ready' })
        $targetCompleteEvents = @($allEvents | Where-Object { $_.event -eq 'batch-target-complete' })
        $parentEvents = @($allEvents | Where-Object { $_.event -eq 'batch-enable-parent-request' })
        Assert-FNVEvidence ($loadEvents.Count -eq $batchTargets.Count) `
            "expected $($batchTargets.Count) batch load event(s), got $($loadEvents.Count)."
        Assert-FNVEvidence ($readyEvents.Count -eq $batchTargets.Count) `
            "expected $($batchTargets.Count) batch ready event(s), got $($readyEvents.Count)."
        Assert-FNVEvidence ($batchScreenshots.Count -eq $batchTargets.Count) `
            "expected $($batchTargets.Count) batch screenshot event(s), got $($batchScreenshots.Count)."
        Assert-FNVEvidence ($targetCompleteEvents.Count -eq $batchTargets.Count) `
            "expected $($batchTargets.Count) batch complete event(s), got $($targetCompleteEvents.Count)."
        Assert-FNVEvidence ($parentEvents.Count -eq $parentForms.Count) `
            "expected $($parentForms.Count) batch parent event(s), got $($parentEvents.Count)."

        for ($parentIndex = 0; $parentIndex -lt $parentForms.Count; ++$parentIndex) {
            $parent = $parentEvents[$parentIndex]
            $actualParent = Get-FNVEventForm $parent 'parentForm' "batch parent $parentIndex"
            Assert-FNVEvidence ($actualParent -eq $parentForms[$parentIndex]) `
                "batch parent $parentIndex form does not match expected order."
            Assert-FNVEvidence ((Get-FNVEvidenceBoolean $parent 'referenceAvailable' "batch parent $parentIndex") -and
                (Get-FNVEvidenceBoolean $parent 'accepted' "batch parent $parentIndex")) `
                "batch parent $parentIndex was unavailable or rejected."
            Assert-FNVEvidence ((Get-FNVEventFrame $parent "batch parent $parentIndex") -eq 1) `
                "batch parent $parentIndex was not emitted at frame 1."
        }

        $previousCompleteFrame = -1
        for ($index = 0; $index -lt $batchTargets.Count; ++$index) {
            $target = $batchTargets[$index]
            $expectedBatchBase = if ($batchBases.Count -eq $batchTargets.Count) { $batchBases[$index] } else { 0 }
            $load = @($loadEvents | Where-Object {
                (Get-FNVEvidenceUInt32 $_ 'targetIndex' 'batch load') -eq $index -and
                    (Get-FNVEventForm $_ 'targetForm' 'batch load') -eq $target
            })
            $ready = @($readyEvents | Where-Object {
                (Get-FNVEvidenceUInt32 $_ 'targetIndex' 'batch ready') -eq $index -and
                    (Get-FNVEventForm $_ 'targetForm' 'batch ready') -eq $target
            })
            $screenshot = @($batchScreenshots | Where-Object {
                (Get-FNVEvidenceUInt32 $_ 'targetIndex' 'batch screenshot') -eq $index -and
                    (Get-FNVEventForm $_ 'targetForm' 'batch screenshot') -eq $target
            })
            $targetComplete = @($targetCompleteEvents | Where-Object {
                (Get-FNVEvidenceUInt32 $_ 'targetIndex' 'batch complete') -eq $index -and
                    (Get-FNVEventForm $_ 'targetForm' 'batch complete') -eq $target
            })
            $appearance = @($appearanceEvents | Where-Object {
                (Get-FNVEventForm $_ 'refForm' 'batch appearance') -eq $target
            })
            $portrait = @($portraitEvents | Where-Object {
                (Get-FNVEventForm $_ 'refForm' 'batch portrait') -eq $target
            })
            Assert-FNVEvidence ($load.Count -eq 1) "batch target $index has $($load.Count) matching load events."
            Assert-FNVEvidence ($ready.Count -eq 1) "batch target $index has $($ready.Count) matching ready events."
            Assert-FNVEvidence ($screenshot.Count -eq 1) `
                "batch target $index has $($screenshot.Count) matching screenshot events."
            Assert-FNVEvidence ($targetComplete.Count -eq 1) `
                "batch target $index has $($targetComplete.Count) matching complete events."
            Assert-FNVEvidence ($appearance.Count -eq 1) `
                "batch target $index has $($appearance.Count) matching appearance events."
            Assert-FNVEvidence ($portrait.Count -eq 1) `
                "batch target $index has $($portrait.Count) matching portrait events."

            Assert-FNVEvidence (Get-FNVEvidenceBoolean $load[0] 'referenceAvailable' "batch target $index load") `
                "batch target $index reference was unavailable."
            Assert-FNVEvidence ((Get-FNVEvidenceBoolean $load[0] 'enableRequested' "batch target $index load") `
                -eq $BatchEnableTargets) `
                "batch target $index enableRequested did not match the runner."
            Assert-FNVEvidence (Get-FNVEvidenceBoolean $load[0] 'enableAccepted' "batch target $index load") `
                "batch target $index enable was rejected."
            Assert-FNVEvidence ((Get-FNVEvidenceBoolean $load[0] 'moveRequested' "batch target $index load") `
                -eq $BatchMoveToTargets) `
                "batch target $index moveRequested did not match the runner."
            Assert-FNVEvidence (Get-FNVEvidenceBoolean $load[0] 'moveAccepted' "batch target $index load") `
                "batch target $index move was rejected."
            Assert-FNVEvidence (Get-FNVEvidenceBoolean $screenshot[0] 'accepted' `
                "batch target $index screenshot") "batch target $index screenshot was rejected."
            if ($RequireAppearanceTelemetry) {
                Assert-FNVEvidence ([string]$appearance[0].event -eq 'npc-appearance') `
                    "batch target $index is not an NPC appearance event."
            }

            $actualBase = Get-FNVEventForm $appearance[0] 'baseForm' "batch target $index appearance"
            Assert-FNVEvidence ($actualBase -ne 0) "batch target $index baseForm is zero."
            if ($expectedBatchBase -ne 0) {
                Assert-FNVEvidence ($actualBase -eq $expectedBatchBase) `
                    "batch target $index baseForm $(Format-FNVFormId $actualBase) does not match $(Format-FNVFormId $expectedBatchBase)."
            }

            $loadFrame = Get-FNVEventFrame $load[0] "batch target $index load"
            $appearanceFrame = Get-FNVEventFrame $appearance[0] "batch target $index appearance"
            $portraitFrame = Get-FNVEventFrame $portrait[0] "batch target $index portrait"
            $readyFrame = Get-FNVEventFrame $ready[0] "batch target $index ready"
            $batchScreenshotFrame = Get-FNVEventFrame $screenshot[0] "batch target $index screenshot"
            $targetCompleteFrame = Get-FNVEventFrame $targetComplete[0] "batch target $index complete"
            $expectedLoadFrame = if ($index -eq 0) { 1 } else { $previousCompleteFrame + 1 }
            Assert-FNVEvidence ($loadFrame -eq $expectedLoadFrame) `
                "batch target $index load frame $loadFrame does not equal $expectedLoadFrame."
            Assert-FNVEvidence ($loadFrame -le $readyFrame) "batch target $index load occurs after ready."
            Assert-FNVEvidence ($appearanceFrame -le $readyFrame) "batch target $index appearance occurs after ready."
            Assert-FNVEvidence ($portraitFrame -le $readyFrame) "batch target $index portrait occurs after ready."
            Assert-FNVEvidence ($readyFrame -gt $previousCompleteFrame) `
                "batch target $index ready is not after the previous complete frame."
            Assert-FNVEvidence ($batchScreenshotFrame -eq $readyFrame + $BatchSettleFrames) `
                "batch target $index screenshot frame $batchScreenshotFrame does not equal ready+$BatchSettleFrames."
            Assert-FNVEvidence ($targetCompleteFrame -eq $batchScreenshotFrame + $BatchAdvanceFrames) `
                "batch target $index complete frame $targetCompleteFrame does not equal screenshot+$BatchAdvanceFrames."
            $previousCompleteFrame = $targetCompleteFrame

            $targetIdentities.Add([pscustomobject][ordered]@{
                targetIndex = $index
                refForm = Format-FNVFormId $target
                baseForm = Format-FNVFormId $actualBase
                loadFrame = $loadFrame
                appearanceFrame = $appearanceFrame
                portraitFrame = $portraitFrame
                readyFrame = $readyFrame
                screenshotFrame = $batchScreenshotFrame
                completeFrame = $targetCompleteFrame
            }) | Out-Null
            $screenshotIdentities.Add([pscustomobject][ordered]@{
                kind = 'target'
                frame = $batchScreenshotFrame
                targetIndex = $index
                targetForm = Format-FNVFormId $target
            }) | Out-Null
        }
        Assert-FNVEvidence ($completeFrame -eq $previousCompleteFrame) `
            "capture-complete frame $completeFrame does not match final batch complete frame $previousCompleteFrame."
    }

    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-retail-oracle-evidence-validation/v1'
        status = 'passed'
        eventSchema = $ExpectedSchema
        runtime = $ExpectedRuntime
        start = [pscustomobject][ordered]@{
            boneLodWriterCallsHooked = $true
            highProcessBoneLodPathHooked = $true
            niAvObjectTransformLayout = $expectedTransformLayout
        }
        eventCount = $allEvents.Count
        save = $SaveName
        frames = [pscustomobject][ordered]@{
            before = $BeforeFrame
            command = $CommandFrame
            after = $AfterFrame
            complete = $completeFrame
        }
        targets = @($targetIdentities | ForEach-Object { $_ })
        screenshots = @($screenshotIdentities | ForEach-Object { $_ })
    }
}

function Get-FNVFileEvidence([string]$Path, [string]$Kind) {
    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
        throw "Missing $Kind evidence file: $absolutePath"
    }
    $item = Get-Item -LiteralPath $absolutePath
    if ($item.Length -le 0) {
        throw "Empty $Kind evidence file: $absolutePath"
    }
    return [pscustomobject][ordered]@{
        kind = $Kind
        path = $absolutePath
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-FNVExpectedScreenshotNames([int[]]$Frame = @(), [string[]]$BatchTargetForm = @()) {
    return @(
        $Frame | Sort-Object -Unique | ForEach-Object { 'frame-{0:D6}.bmp' -f $_ }
        $BatchTargetForm | ForEach-Object {
            'frame-target-' + ((Format-FNVFormId $_) -replace '^0[xX]', '').ToLowerInvariant() + '.bmp'
        }
    )
}

function Assert-FNVRetailScreenshotFiles([string[]]$Path, [string[]]$ExpectedName) {
    $files = @($Path)
    $expected = @($ExpectedName)
    Assert-FNVEvidence ($files.Count -eq $expected.Count) `
        "expected $($expected.Count) screenshot file(s), got $($files.Count)."
    $evidence = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $expected.Count; ++$index) {
        $actualName = [System.IO.Path]::GetFileName($files[$index])
        Assert-FNVEvidence ($actualName.Equals(
            $expected[$index], [System.StringComparison]::OrdinalIgnoreCase)) `
            "screenshot file $index is '$actualName', expected '$($expected[$index])'."
        $evidence.Add((Get-FNVFileEvidence $files[$index] 'retail-screenshot')) | Out-Null
    }
    return @($evidence | ForEach-Object { $_ })
}

function Write-FNVImmutableJsonManifest([string]$Path, [object]$Manifest) {
    $absolutePath = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $absolutePath) {
        throw "Refusing to overwrite existing retail-oracle run manifest: $absolutePath"
    }
    $parent = Split-Path -Parent $absolutePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Run manifest parent directory does not exist: $parent"
    }
    $temporaryPath = Join-Path $parent (
        ".{0}.{1}.{2}.tmp" -f ([System.IO.Path]::GetFileName($absolutePath)), $PID,
        [Guid]::NewGuid().ToString('N'))
    try {
        $json = ($Manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine
        [System.IO.File]::WriteAllText(
            $temporaryPath, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $absolutePath)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
    return $absolutePath
}
