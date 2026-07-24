param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$modulePath = Join-Path $PSScriptRoot 'FNVRetailOpenMWCheckpointComparator.psm1'
$schemaPath = Join-Path $repoRoot 'catalog\fnv-retail-openmw-checkpoint-pair.schema.json'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "nikami-fnv-checkpoint-pair-$PID-$([Guid]::NewGuid().ToString('N'))")
$failures = [Collections.Generic.List[string]]::new()
$caseCount = 0

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) | Out-Null }
}

function Assert-ThrowsLike([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    ++$script:caseCount
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notmatch $Pattern) {
        $detail = if ($null -eq $caught) { 'no exception' } else { $caught.Exception.Message }
        $script:failures.Add("$Message ($detail)") | Out-Null
    }
}

function Copy-Pair([object]$Value) {
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Write-Pair([object]$Value, [string]$Name) {
    $path = Join-Path $script:temporaryRoot $Name
    [IO.File]::WriteAllText(
        $path,
        ($Value | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false))
    return $path
}

function New-RawFloat32([double]$Value) {
    $single = [single]$Value
    $bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes($single), 0)
    return [pscustomobject][ordered]@{
        value = [double]$single
        bitsHex = '0x{0:X8}' -f $bits
    }
}

function New-Vector3([double]$X, [double]$Y, [double]$Z) {
    return [pscustomobject][ordered]@{
        x = New-RawFloat32 $X
        y = New-RawFloat32 $Y
        z = New-RawFloat32 $Z
    }
}

function New-FormKey([string]$LocalFormId, [string]$RuntimeFormId) {
    return [pscustomobject][ordered]@{
        kind = 'plugin'
        originPlugin = 'FalloutNV.esm'
        localFormId = $LocalFormId
        winningPlugin = 'FalloutNV.esm'
        runtimeFormId = $RuntimeFormId
    }
}

function New-TestPng([string]$RelativePath, [Drawing.Color]$Color) {
    $fullPath = Join-Path $script:temporaryRoot $RelativePath
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $bitmap = [Drawing.Bitmap]::new(3, 2)
    try {
        for ($y = 0; $y -lt $bitmap.Height; ++$y) {
            for ($x = 0; $x -lt $bitmap.Width; ++$x) { $bitmap.SetPixel($x, $y, $Color) }
        }
        $bitmap.Save($fullPath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
    return $fullPath
}

function New-FileArtifact(
    [string]$Id,
    [string]$Kind,
    [string]$RelativePath,
    [string]$GenerationId,
    [string]$MediaType,
    [AllowNull()][string]$SampleId = $null
) {
    $fullPath = Join-Path $script:temporaryRoot $RelativePath
    $file = Get-Item -LiteralPath $fullPath
    $artifact = [ordered]@{
        id = $Id
        kind = $Kind
        path = $RelativePath.Replace('\', '/')
        bytes = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        generationId = $GenerationId
        mediaType = $MediaType
    }
    if ($Kind -eq 'screenshot') { $artifact.sampleId = $SampleId }
    return [pscustomobject]$artifact
}

function Update-ArtifactEvidence([object]$Artifact) {
    $fullPath = Join-Path $script:temporaryRoot ([string]$Artifact.path)
    $file = Get-Item -LiteralPath $fullPath
    $Artifact.bytes = [int64]$file.Length
    $Artifact.sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
}

function New-VisualPart([string]$PartId, [double]$Alpha = 1) {
    return [pscustomobject][ordered]@{
        partId = $PartId
        present = $true
        effectiveAlpha = New-RawFloat32 $Alpha
        geometrySha256 = ('A' * 64)
        shaderSha256 = ('B' * 64)
        materialSha256 = ('C' * 64)
        textureSha256 = ('D' * 64)
    }
}

function New-TestActor(
    [string]$ActorKind,
    [string]$ReferenceLocal,
    [string]$ReferenceRuntime,
    [string]$BaseLocal,
    [string]$BaseRuntime,
    [double]$X,
    [double]$Phase,
    [string]$PartId
) {
    $target = New-FormKey '0x0105AA' '0x000105AA'
    $package = New-FormKey '0x010100' '0x00010100'
    $topic = New-FormKey '0x010200' '0x00010200'
    $equipment = [object[]]@()
    if ($ActorKind -ne 'creature') {
        $equipment = @(
            [pscustomobject][ordered]@{
                instanceId = 'weapon-main-0'
                form = New-FormKey '0x010300' '0x00010300'
                slot = 'right-hand'
                count = 1
                condition = New-RawFloat32 0.75
                equipped = $true
            }
        )
    }
    return [pscustomobject][ordered]@{
        reference = New-FormKey $ReferenceLocal $ReferenceRuntime
        base = New-FormKey $BaseLocal $BaseRuntime
        actorKind = $ActorKind
        cell = New-FormKey '0x0104C1' '0x000104C1'
        worldSpace = New-FormKey '0x0DA726' '0x000DA726'
        transform = [pscustomobject][ordered]@{
            position = New-Vector3 $X 20 30
            rotation = New-Vector3 0 0 1
            scale = New-RawFloat32 1
        }
        velocity = New-Vector3 1 0 0
        pathTarget = New-Vector3 ($X + 10) 20 30
        pathTargetReference = $target
        ai = [pscustomobject][ordered]@{
            package = $package
            procedure = 'travel'
            target = $target
        }
        animation = [pscustomobject][ordered]@{
            group = if ($ActorKind -eq 'creature') { 'DeathClawIdle' } else { 'Idle' }
            key = if ($ActorKind -eq 'creature') { 'deathclaw_idle.kf' } else { 'mtidle.kf' }
            phase = New-RawFloat32 $Phase
            tween = New-RawFloat32 0.1
        }
        equipment = $equipment
        combat = [pscustomobject][ordered]@{
            inCombat = $false
            target = $null
            lifeState = 'alive'
        }
        dialogue = [pscustomobject][ordered]@{
            active = ($ActorKind -ne 'creature')
            partner = if ($ActorKind -eq 'creature') { $null } else { New-FormKey '0x000007' '0x00000007' }
            topic = if ($ActorKind -eq 'creature') { $null } else { $topic }
        }
        visual = [pscustomobject][ordered]@{
            rootPresent = $true
            parts = @(New-VisualPart $PartId)
        }
    }
}

function New-TestFrame(
    [string]$SampleId,
    [double]$Elapsed,
    [string]$GenerationId,
    [int64]$SourceFrame,
    [string]$ScreenshotId,
    [double]$ActorOffset,
    [double]$Phase
) {
    return [pscustomobject][ordered]@{
        sampleId = $SampleId
        elapsedSeconds = $Elapsed
        generationId = $GenerationId
        sourceFrame = $SourceFrame
        frameStateSha256 = if ($SampleId -eq 'sample-start') { ('1' * 64) } else { ('2' * 64) }
        screenshotArtifactId = $ScreenshotId
        actors = @(
            (New-TestActor 'npc' '0x0104C2' '0x000104C2' '0x0104C0' '0x000104C0' `
                (10 + $ActorOffset) $Phase 'npc-body')
            (New-TestActor 'creature' '0x0105AA' '0x000105AA' '0x0105A9' '0x000105A9' `
                (50 + $ActorOffset) $Phase 'creature-body')
        )
        camera = [pscustomobject][ordered]@{
            position = New-Vector3 5 10 15
            rotation = New-Vector3 0 0 1
            fovDegrees = New-RawFloat32 75
        }
        timeWeather = [pscustomobject][ordered]@{
            gameHour = New-RawFloat32 12
            timeScale = New-RawFloat32 30
            currentWeather = New-FormKey '0x00015E' '0x0000015E'
            previousWeather = New-FormKey '0x00015E' '0x0000015E'
            transition = New-RawFloat32 0
        }
    }
}

function New-CoverageLedger {
    return @(
        Get-FNVRetailCheckpointRequiredLedgerPaths | ForEach-Object {
            [pscustomobject][ordered]@{
                retailPath = $_
                required = $true
                status = 'mapped'
                retail = [pscustomobject][ordered]@{
                    observedBytes = 16; mappedBytes = 16; unmappedBytes = 0
                }
                openMw = [pscustomobject][ordered]@{
                    observedBytes = 24; mappedBytes = 24; unmappedBytes = 0
                }
                compareMode = if ($_ -match 'visual|hashesScreenshots') {
                    'visual-signature'
                } else { 'semantic' }
                blocker = $null
            }
        }
    )
}

function New-TestEndpoint([string]$Lane, [string]$GenerationId) {
    $prefix = if ($Lane -eq 'retail') { 'retail' } else { 'openmw' }
    return [pscustomobject][ordered]@{
        generationId = $GenerationId
        traceArtifactId = "$prefix-trace"
        artifacts = @(
            (Get-Variable -Scope Script -Name "$($prefix)TraceArtifact" -ValueOnly)
            (Get-Variable -Scope Script -Name "$($prefix)StartArtifact" -ValueOnly)
            (Get-Variable -Scope Script -Name "$($prefix)EndArtifact" -ValueOnly)
        )
        frames = @(
            (New-TestFrame 'sample-start' 0 $GenerationId `
                $(if ($Lane -eq 'retail') { 100 } else { 400 }) "$prefix-start" 0 0.25)
            (New-TestFrame 'sample-end' 4 $GenerationId `
                $(if ($Lane -eq 'retail') { 340 } else { 640 }) "$prefix-end" 4 0.5)
        )
    }
}

function New-ValidPair {
    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-retail-openmw-checkpoint-pair/v1'
        pairId = 'save330-goodsprings-pair-0001'
        loadOrder = @(
            [pscustomobject][ordered]@{
                index = 0
                plugin = 'FalloutNV.esm'
                bytes = 240000000
                sha256 = ('E' * 64)
            }
        )
        tolerances = [pscustomobject][ordered]@{
            frameSyncSecondsMaximum = 0.01
            positionAbsoluteMaximum = 0.01
            rotationRadiansMaximum = 0.001
            scaleAbsoluteMaximum = 0.001
            velocityAbsoluteMaximum = 0.01
            targetPositionAbsoluteMaximum = 0.01
            animationPhaseMaximum = 0.01
            animationTweenMaximum = 0.01
            conditionAbsoluteMaximum = 0.001
            alphaAbsoluteMaximum = 0.001
            cameraPositionAbsoluteMaximum = 0.01
            cameraRotationRadiansMaximum = 0.001
            fovAbsoluteMaximum = 0.01
            gameHourMaximum = 0.01
            timeScaleMaximum = 0.01
            weatherTransitionMaximum = 0.01
            pixelMaeMaximum = 0.001
            pixelRmseMaximum = 0.001
        }
        coverageLedger = New-CoverageLedger
        retail = New-TestEndpoint 'retail' 'retail-gen-0001'
        openMw = New-TestEndpoint 'openmw' 'openmw-gen-0001'
    }
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $modulePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Contract ($parseErrors.Count -eq 0) 'Pair comparator has PowerShell parse errors.'
    Import-Module $modulePath -Force
    Import-Module (Join-Path $PSScriptRoot 'FNVRetailCheckpointManifest.psm1') -Force

    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    Assert-Contract ($schema.'$schema' -eq 'https://json-schema.org/draft/2020-12/schema') `
        'Pair schema is not JSON Schema draft 2020-12.'
    Assert-Contract ($schema.properties.schema.const -eq 'nikami-fnv-retail-openmw-checkpoint-pair/v1') `
        'Pair schema does not pin the v1 identity.'
    Assert-Contract ($schema.'$defs'.actor.required -contains 'pathTarget' -and
        $schema.'$defs'.actor.required -contains 'ai' -and
        $schema.'$defs'.actor.required -contains 'animation' -and
        $schema.'$defs'.actor.required -contains 'visual') `
        'Pair schema omits mandatory actor trace channels.'
    Assert-Contract ($schema.'$defs'.visualPart.required -contains 'geometrySha256' -and
        $schema.'$defs'.visualPart.required -contains 'shaderSha256' -and
        $schema.'$defs'.visualPart.required -contains 'materialSha256' -and
        $schema.'$defs'.visualPart.required -contains 'textureSha256') `
        'Pair schema omits a visual hard-failure signature.'

    $retailTracePath = Join-Path $temporaryRoot 'retail/trace.ndjson.zst'
    $openmwTracePath = Join-Path $temporaryRoot 'openmw/trace.ndjson.zst'
    foreach ($path in @($retailTracePath, $openmwTracePath)) {
        $parent = Split-Path -Parent $path
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes("normalized trace fixture`n"))
    }
    New-TestPng 'retail/sample-start.png' ([Drawing.Color]::FromArgb(255, 80, 100, 120)) | Out-Null
    New-TestPng 'retail/sample-end.png' ([Drawing.Color]::FromArgb(255, 90, 110, 130)) | Out-Null
    New-TestPng 'openmw/sample-start.png' ([Drawing.Color]::FromArgb(255, 80, 100, 120)) | Out-Null
    New-TestPng 'openmw/sample-end.png' ([Drawing.Color]::FromArgb(255, 90, 110, 130)) | Out-Null

    $retailTraceArtifact = New-FileArtifact 'retail-trace' 'trace' 'retail/trace.ndjson.zst' `
        'retail-gen-0001' 'application/zstd'
    $retailStartArtifact = New-FileArtifact 'retail-start' 'screenshot' 'retail/sample-start.png' `
        'retail-gen-0001' 'image/png' 'sample-start'
    $retailEndArtifact = New-FileArtifact 'retail-end' 'screenshot' 'retail/sample-end.png' `
        'retail-gen-0001' 'image/png' 'sample-end'
    $openmwTraceArtifact = New-FileArtifact 'openmw-trace' 'trace' 'openmw/trace.ndjson.zst' `
        'openmw-gen-0001' 'application/zstd'
    $openmwStartArtifact = New-FileArtifact 'openmw-start' 'screenshot' 'openmw/sample-start.png' `
        'openmw-gen-0001' 'image/png' 'sample-start'
    $openmwEndArtifact = New-FileArtifact 'openmw-end' 'screenshot' 'openmw/sample-end.png' `
        'openmw-gen-0001' 'image/png' 'sample-end'

    $valid = New-ValidPair
    $validPath = Write-Pair $valid 'valid-pair.json'
    try {
        $result = Compare-FNVRetailOpenMWCheckpointPair $validPath
        ++$caseCount
        Assert-Contract ($result.status -eq 'pass') 'Valid paired checkpoint did not pass.'
        Assert-Contract ($result.comparedFrames -eq 2) 'Comparator did not compare both synchronized frames.'
        Assert-Contract ($result.comparedActorSamples -eq 4) `
            'Comparator did not compare the complete two-actor set across both frames.'
        Assert-Contract ($result.coverageCategories -eq 32) `
            'Comparator did not enforce all 32 coverage categories.'
        Assert-Contract (@($result.visualMetrics).Count -eq 2) `
            'Comparator did not measure both synchronized screenshot pairs.'
    }
    catch {
        ++$caseCount
        $failures.Add("Valid paired checkpoint was rejected: $($_.Exception.Message) [$($_.ScriptStackTrace)]") |
            Out-Null
    }

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors = @($case.openMw.frames[0].actors[0])
    $path = Write-Pair $case 'missing-actor.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'OpenMW is missing loaded actor/creature' 'Missing loaded creature was accepted.'

    $case = Copy-Pair $valid
    $extra = Copy-Pair $case.openMw.frames[0].actors[1]
    $extra.reference.localFormId = '0x0105AB'
    $extra.reference.runtimeFormId = '0x000105AB'
    $case.openMw.frames[0].actors += $extra
    $path = Write-Pair $case 'unexpected-actor.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'OpenMW has unexpected loaded actor/creature' 'Unexpected loaded creature was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].animation.PSObject.Properties.Remove('tween')
    $path = Write-Pair $case 'missing-animation-field.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'animation.*missing required field.*tween' 'Missing animation tween was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].transform.position.x = New-RawFloat32 10.25
    $path = Write-Pair $case 'position-tolerance.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'transform/position/x.*exceeds tolerance' 'Actor position outside tolerance was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].transform.position.x.value = 11
    $path = Write-Pair $case 'raw-float-disagreement.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'transform/position/x/value.*does not round-trip to authoritative bits' `
        'Float display value disagreeing with its captured raw bits was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].reference.runtimeFormId = '0x010104C2'
    $path = Write-Pair $case 'form-key-load-index.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'reference/runtimeFormId.*does not match origin index and local FormID' `
        'Actor identity with an invalid plugin-qualified runtime FormID was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].transform.scale = New-RawFloat32 1.25
    $path = Write-Pair $case 'scale-tolerance.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'transform/scale.*exceeds tolerance' 'Actor scale outside tolerance was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].velocity.x = New-RawFloat32 1.2
    $path = Write-Pair $case 'velocity-tolerance.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '/velocity/x.*exceeds tolerance' 'Actor velocity outside tolerance was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].pathTarget = $null
    $path = Write-Pair $case 'path-target-missing.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '/pathTarget.*null in only one endpoint' 'Missing path target was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].ai.package = New-FormKey '0x010101' '0x00010101'
    $case.openMw.frames[0].actors[0].ai.procedure = 'sandbox'
    $path = Write-Pair $case 'ai-procedure.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '(?s)/ai/package.*does not equal.*/ai/procedure.*does not equal' `
        'Wrong AI package/procedure was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].animation.phase = New-RawFloat32 0.4
    $path = Write-Pair $case 'animation-phase.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '/animation/phase.*exceeds tolerance' 'Animation phase outside tolerance was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].animation.group = 'Walk'
    $case.openMw.frames[0].actors[0].animation.key = 'mtforward.kf'
    $path = Write-Pair $case 'animation-identity.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '(?s)/animation/group.*does not equal.*/animation/key.*does not equal' `
        'Wrong animation group/key was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].equipment[0].condition = New-RawFloat32 0.5
    $path = Write-Pair $case 'equipment-condition.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '/equipment/weapon-main-0/condition.*exceeds tolerance' `
        'Equipment condition outside tolerance was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].combat.inCombat = $true
    $case.openMw.frames[0].actors[0].dialogue.active = $false
    $path = Write-Pair $case 'combat-dialogue.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '(?s)/combat/inCombat.*does not equal.*dialogue/active.*does not equal' `
        'Combat/dialogue state mismatch was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].camera.position.x = New-RawFloat32 6
    $case.openMw.frames[0].timeWeather.currentWeather = New-FormKey '0x00015F' '0x0000015F'
    $path = Write-Pair $case 'camera-weather.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '(?s)/camera/position/x.*exceeds tolerance.*currentWeather.*does not equal' `
        'Camera/weather mismatch was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].timeWeather.gameHour = New-RawFloat32 13
    $case.openMw.frames[0].timeWeather.transition = New-RawFloat32 0.5
    $path = Write-Pair $case 'time-weather-transition.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '(?s)/timeWeather/gameHour.*exceeds tolerance.*timeWeather/transition.*exceeds tolerance' `
        'World time/weather transition outside tolerance was accepted.'

    $case = Copy-Pair $valid
    $case.coverageLedger = @($case.coverageLedger | Where-Object {
        $_.retailPath -ne '/snapshot/worldChanges/unloaded'
    })
    $path = Write-Pair $case 'missing-coverage-category.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'coverageLedger.*missing required category.*/snapshot/worldChanges/unloaded' `
        'Omitted unloaded-world coverage category was accepted.'

    $case = Copy-Pair $valid
    $case.coverageLedger[0].openMw.mappedBytes = 23
    $case.coverageLedger[0].openMw.unmappedBytes = 1
    $path = Write-Pair $case 'unmapped-byte.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'unmappedBytes.*must be zero' 'Unmapped OpenMW byte was accepted.'

    $case = Copy-Pair $valid
    $case.coverageLedger[0].status = 'partial'
    $case.coverageLedger[0].blocker = 'fixture lacks a complete mapper'
    $path = Write-Pair $case 'partial-coverage.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '/coverageLedger/0/status.*must be mapped' 'Partial required coverage was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].visual.rootPresent = $false
    $path = Write-Pair $case 'missing-actor-root.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'rootPresent.*missing actor root' 'Missing actor scene root was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].visual.parts[0].shaderSha256 = ('F' * 64)
    $path = Write-Pair $case 'shader-mismatch.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '/shaderSha256.*does not equal' 'Shader signature mismatch was accepted.'

    foreach ($signature in @('geometrySha256', 'materialSha256', 'textureSha256')) {
        $case = Copy-Pair $valid
        $case.openMw.frames[0].actors[0].visual.parts[0].$signature = ('F' * 64)
        $path = Write-Pair $case "visual-$signature.json"
        Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
            "/$signature.*does not equal" "$signature mismatch was accepted."
    }

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].visual.parts[0].effectiveAlpha = New-RawFloat32 0.5
    $path = Write-Pair $case 'alpha-mismatch.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '/effectiveAlpha.*exceeds tolerance' 'Effective-alpha mismatch was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.frames[0].actors[0].visual.parts = @()
    $path = Write-Pair $case 'missing-geometry.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '/visual/parts.*at least one required geometry part' 'Missing geometry was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.artifacts[1].generationId = 'stale-generation'
    $path = Write-Pair $case 'stale-artifact-generation.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'artifacts/1/generationId.*endpoint generationId' `
        'Screenshot from a stale generation was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.generationId = 'retail-gen-0001'
    foreach ($artifact in $case.openMw.artifacts) { $artifact.generationId = 'retail-gen-0001' }
    foreach ($frame in $case.openMw.frames) { $frame.generationId = 'retail-gen-0001' }
    $path = Write-Pair $case 'shared-generation.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'openMw/generationId.*distinct from the retail generationId' `
        'Retail and OpenMW evidence sharing one generation identity was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.artifacts[1].path = 'openmw/missing.png'
    $path = Write-Pair $case 'missing-artifact.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'artifact is missing' 'Missing synchronized screenshot artifact was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.artifacts[1].sha256 = ('F' * 64)
    $path = Write-Pair $case 'artifact-hash-mismatch.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'artifacts/1/sha256.*does not match file SHA-256' `
        'Synchronized screenshot with a false content hash was accepted.'

    $case = Copy-Pair $valid
    $case.openMw.artifacts[1].path = 'retail/sample-start.png'
    $path = Write-Pair $case 'cross-lane-artifact.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        'artifacts/1/path.*must remain under the endpoint directory' `
        'OpenMW evidence pointing at the retail artifact lane was accepted.'

    # Keep the raster mismatch last because it deliberately changes a shared fixture file.
    New-TestPng 'openmw/sample-start.png' ([Drawing.Color]::FromArgb(255, 220, 10, 10)) | Out-Null
    $case = Copy-Pair $valid
    Update-ArtifactEvidence $case.openMw.artifacts[1]
    $path = Write-Pair $case 'pixel-tolerance.json'
    Assert-ThrowsLike { Compare-FNVRetailOpenMWCheckpointPair $path } `
        '(?s)/screenshot/pixelMae.*exceeds tolerance.*/screenshot/pixelRmse.*exceeds tolerance' `
        'Synchronized raster outside visual tolerances was accepted.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'FNV retail/OpenMW checkpoint comparator failures:' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

[pscustomobject][ordered]@{
    cases = $caseCount
    comparedFrames = 2
    comparedActorSamples = 4
    coverageCategories = 32
    status = 'pass'
}
