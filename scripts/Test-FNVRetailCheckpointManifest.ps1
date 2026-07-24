param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$modulePath = Join-Path $PSScriptRoot 'FNVRetailCheckpointManifest.psm1'
$schemaPath = Join-Path $repoRoot 'catalog\fnv-retail-checkpoint.schema.json'
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

function Copy-CheckpointManifest([object]$Value) {
    return ($Value | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Write-CheckpointManifest([object]$Value, [string]$Name) {
    $path = Join-Path $script:temporaryRoot $Name
    $json = $Value | ConvertTo-Json -Depth 64
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return $path
}

function New-RawFloat32([double]$Value, [string]$BitsHex) {
    return [pscustomobject][ordered]@{ value = $Value; bitsHex = $BitsHex }
}

function New-PluginFormKey([string]$LocalFormId, [string]$RuntimeFormId) {
    return [pscustomobject][ordered]@{
        kind = 'plugin'
        originPlugin = 'FalloutNV.esm'
        localFormId = $LocalFormId
        winningPlugin = 'FalloutNV.esm'
        runtimeFormId = $RuntimeFormId
    }
}

function New-ArtifactEvidence(
    [string]$Id,
    [string]$Kind,
    [string]$RelativePath,
    [byte[]]$Content,
    [Nullable[int64]]$RetailFrame = $null
) {
    $fullPath = Join-Path $script:temporaryRoot $RelativePath
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllBytes($fullPath, $Content)
    $artifact = [ordered]@{
        id = $Id
        kind = $Kind
        path = $RelativePath.Replace('\', '/')
        bytes = [int64]$Content.Length
        sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        generationId = 'gen-0001'
        mediaType = if ($Kind -eq 'screenshot') { 'image/png' } else { 'application/zstd' }
    }
    if ($null -ne $RetailFrame) { $artifact.retailFrame = [int64]$RetailFrame }
    return [pscustomobject]$artifact
}

function New-ValidCheckpointManifest {
    $ledger = @(
        Get-FNVRetailCheckpointRequiredLedgerPaths | ForEach-Object {
            [pscustomobject][ordered]@{
                retailPath = $_
                required = $true
                status = 'mapped'
                source = [pscustomobject][ordered]@{
                    reader = 'retail-oracle-reader'
                    confidence = 'proven'
                }
                openMw = [pscustomobject][ordered]@{
                    target = 'openmw-checkpoint-target'
                    writer = 'openmw-checkpoint-writer'
                }
                compare = [pscustomobject][ordered]@{ mode = 'exact' }
                blocker = $null
            }
        }
    )

    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-retail-checkpoint/v1'
        complete = $true
        capture = [pscustomobject][ordered]@{
            checkpointId = 'save330-goodsprings-0001'
            generationId = 'gen-0001'
            runtime = 'FalloutNV-1.4.0.525'
            oracleBuild = 'retail-oracle-test-fixture'
            capturedAtUtc = '2026-07-18T12:00:00.000Z'
            postLoadFrame = 42
            save = [pscustomobject][ordered]@{
                requestedName = 'Save 330'
                slot = 330
                path = 'C:\Users\Fixture\Documents\My Games\FalloutNV\Saves\Save 330.fos'
                bytes = 1048576
                sha256 = ('A' * 64)
                lastWriteUtc = '2026-07-18T11:59:00.000Z'
                postLoadSucceeded = $true
            }
        }
        identity = [pscustomobject][ordered]@{
            formKeyModel = 'plugin+local-form-id/v1'
            dynamicFormModel = 'save-scoped-dynamic/v1'
            loadOrder = @(
                [pscustomobject][ordered]@{
                    index = 0
                    plugin = 'FalloutNV.esm'
                    bytes = 240000000
                    sha256 = ('B' * 64)
                }
            )
        }
        artifacts = @(
            $script:traceArtifact
            $script:startScreenshotArtifact
            $script:endScreenshotArtifact
        )
        snapshot = [pscustomobject][ordered]@{
            player = [pscustomobject][ordered]@{
                reference = New-PluginFormKey '0x000007' '0x00000007'
                base = New-PluginFormKey '0x000007' '0x00000007'
                location = [pscustomobject][ordered]@{
                    cell = New-PluginFormKey '0x0104C1' '0x000104C1'
                    worldSpace = New-PluginFormKey '0x0DA726' '0x000DA726'
                    position = [pscustomobject][ordered]@{
                        x = New-RawFloat32 0 '0x00000000'
                        y = New-RawFloat32 1 '0x3F800000'
                        z = New-RawFloat32 9.5 '0x41180000'
                    }
                    rotation = [pscustomobject][ordered]@{
                        x = New-RawFloat32 0 '0x00000000'
                        y = New-RawFloat32 0 '0x00000000'
                        z = New-RawFloat32 1 '0x3F800000'
                    }
                }
            }
            timeWeather = [pscustomobject][ordered]@{
                gameHour = New-RawFloat32 12 '0x41400000'
                timeScale = New-RawFloat32 30 '0x41F00000'
                currentWeather = New-PluginFormKey '0x00015E' '0x0000015E'
            }
            exactDoubleProbe = [pscustomobject][ordered]@{
                value = 1
                bitsHex = '0x3FF0000000000000'
            }
            dynamicFormProbe = [pscustomobject][ordered]@{
                kind = 'dynamic'
                runtimeFormId = '0xFF000123'
                saveDynamicId = '0x000123'
                baseForm = New-PluginFormKey '0x00015E' '0x0000015E'
            }
        }
        temporalEvidence = [pscustomobject][ordered]@{
            schema = 'nikami-fnv-retail-trace/v1'
            durationSeconds = 4
            sampleCount = 181
            sampleClock = 'retail-main-loop'
            coverageComplete = $true
            traceArtifactId = 'trace-main'
            screenshotArtifactIds = @('screenshot-start', 'screenshot-end')
            frameHashAlgorithm = 'sha256'
            actorEnumeration = [pscustomobject][ordered]@{
                source = 'loaded-cells-plus-process-lists'
                includePlayer = $true
                loadedCellLocking = $true
                deduplicateByReference = $true
                missingActorDisposition = 'hard-fail'
            }
            requiredActorChannels = @(
                'plugin-qualified-identity'
                'cell-world'
                'transform'
                'velocity'
                'path-target'
                'ai-package-procedure'
                'animation-group-key-phase-tween'
                'equipment'
                'combat'
                'dialogue'
                'visual-root-geometry-alpha-shader-material-texture'
            )
            requiredFrameChannels = @(
                'camera'
                'time'
                'weather'
                'frame-state-sha256'
                'screenshot-sha256'
                'generation-id'
            )
            visualHardFailCategories = @(
                'missing-loaded-actor'
                'unexpected-loaded-actor'
                'missing-actor-root'
                'missing-required-geometry'
                'unexpected-alpha-visibility'
                'geometry-signature-mismatch'
                'shader-signature-mismatch'
                'material-signature-mismatch'
                'texture-signature-mismatch'
            )
            frameEvidence = @(
                [pscustomobject][ordered]@{
                    retailFrame = 100
                    generationId = 'gen-0001'
                    frameStateSha256 = ('C' * 64)
                    screenshotArtifactId = 'screenshot-start'
                }
                [pscustomobject][ordered]@{
                    retailFrame = 280
                    generationId = 'gen-0001'
                    frameStateSha256 = ('D' * 64)
                    screenshotArtifactId = 'screenshot-end'
                }
            )
        }
        mappingLedger = $ledger
        coverage = [pscustomobject][ordered]@{
            requiredFields = $ledger.Count
            mappedRequiredFields = $ledger.Count
            partialRequiredFields = 0
            uncoveredRequiredFields = 0
        }
        hardFailures = @()
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "nikami-fnv-retail-checkpoint-$PID-$([Guid]::NewGuid().ToString('N'))")
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $modulePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Contract ($parseErrors.Count -eq 0) 'Checkpoint validator has PowerShell parse errors.'
    Import-Module $modulePath -Force

    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    Assert-Contract ($schema.'$schema' -eq 'https://json-schema.org/draft/2020-12/schema') `
        'Checkpoint schema is not JSON Schema draft 2020-12.'
    Assert-Contract ($schema.properties.schema.const -eq 'nikami-fnv-retail-checkpoint/v1') `
        'Checkpoint schema does not pin the v1 manifest identity.'
    Assert-Contract ($schema.'$defs'.saveProvenance.properties.requestedName.const -ceq 'Save 330') `
        'Checkpoint schema does not pin exact Save 330 provenance.'
    Assert-Contract ($schema.'$defs'.saveProvenance.properties.slot.const -eq 330) `
        'Checkpoint schema does not pin save slot 330.'
    Assert-Contract ($schema.'$defs'.pluginFormKey.required -contains 'originPlugin' -and
        $schema.'$defs'.pluginFormKey.required -contains 'localFormId' -and
        $schema.'$defs'.pluginFormKey.required -contains 'winningPlugin') `
        'Checkpoint schema does not require plugin-qualified FormKey provenance.'
    Assert-Contract ($schema.'$defs'.float32.properties.bitsHex.pattern -match '\{8\}') `
        'Checkpoint schema does not require exact float32 bits.'
    Assert-Contract (@($schema.'$defs'.requiredActorChannels.allOf).Count -eq 11) `
        'Checkpoint schema does not require every all-loaded-actor temporal channel.'
    Assert-Contract (@($schema.'$defs'.visualHardFailCategories.allOf).Count -eq 9) `
        'Checkpoint schema does not require every visual hard-failure category.'
    Assert-Contract (@($schema.allOf).Count -ge 4) `
        'Checkpoint schema does not contain fail-closed completeness conditionals.'

    $traceArtifact = New-ArtifactEvidence 'trace-main' 'trace' `
        'artifacts/trace.ndjson.zst' ([Text.Encoding]::UTF8.GetBytes("trace`n"))
    $startScreenshotArtifact = New-ArtifactEvidence 'screenshot-start' 'screenshot' `
        'artifacts/frame-000100.png' ([byte[]](1, 2, 3, 4)) 100
    $endScreenshotArtifact = New-ArtifactEvidence 'screenshot-end' 'screenshot' `
        'artifacts/frame-000280.png' ([byte[]](5, 6, 7, 8)) 280

    $valid = New-ValidCheckpointManifest
    $validPath = Write-CheckpointManifest $valid 'valid.json'
    try {
        $result = Assert-FNVRetailCheckpointManifest -Path $validPath -VerifyArtifactFiles
        ++$caseCount
        Assert-Contract ($result.status -eq 'valid' -and $result.complete) `
            'Valid complete checkpoint did not validate as complete.'
        Assert-Contract ($result.requiredFields -eq 32) `
            'Valid checkpoint did not retain all 32 mandatory coverage categories.'
        Assert-Contract ($result.verifiedArtifactCount -eq 3) `
            'Valid checkpoint did not verify all artifact files and hashes.'
    }
    catch {
        ++$caseCount
        $failures.Add("Valid complete checkpoint was rejected: $($_.Exception.Message) [$($_.ScriptStackTrace)]") | Out-Null
    }

    $case = Copy-CheckpointManifest $valid
    $case.capture.save.requestedName = 'Save 329'
    $casePath = Write-CheckpointManifest $case 'wrong-save.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'requestedName.*Save 330' 'Wrong save identity was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.identity.loadOrder[0].index = 1
    $casePath = Write-CheckpointManifest $case 'bad-load-order.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'loadOrder/0/index.*array position 0' 'Noncontiguous load order was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.snapshot.player.reference.runtimeFormId = '0x01000007'
    $casePath = Write-CheckpointManifest $case 'bad-form-key.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'runtimeFormId.*origin load index plus local FormID' `
        'FormKey whose runtime prefix disagreed with its origin plugin was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.snapshot.dynamicFormProbe.saveDynamicId = '0x000124'
    $casePath = Write-CheckpointManifest $case 'bad-dynamic-form-key.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'saveDynamicId.*low 24 bits' `
        'Save-scoped dynamic FormKey with inconsistent identity was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.snapshot.timeWeather.gameHour.value = 13
    $casePath = Write-CheckpointManifest $case 'bad-float-bits.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'gameHour/value.*does not round-trip.*float32 bits' `
        'Display float that disagreed with authoritative raw bits was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.artifacts[1].generationId = 'gen-stale'
    $casePath = Write-CheckpointManifest $case 'stale-artifact-generation.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'artifacts/1/generationId.*capture.generationId' `
        'Artifact from a different generation was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.artifacts[0].path = '../trace.ndjson.zst'
    $casePath = Write-CheckpointManifest $case 'artifact-traversal.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'artifacts/0/path.*normalized relative path' 'Artifact parent traversal was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.temporalEvidence.requiredActorChannels = @(
        $case.temporalEvidence.requiredActorChannels | Where-Object { $_ -ne 'ai-package-procedure' })
    $casePath = Write-CheckpointManifest $case 'missing-actor-channel.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'requiredActorChannels.*ai-package-procedure' `
        'Temporal evidence without AI package/procedure coverage was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.temporalEvidence.visualHardFailCategories = @(
        $case.temporalEvidence.visualHardFailCategories |
            Where-Object { $_ -ne 'shader-signature-mismatch' })
    $casePath = Write-CheckpointManifest $case 'missing-shader-hard-fail.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'visualHardFailCategories.*shader-signature-mismatch' `
        'Visual policy that did not hard-fail shader mismatches was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.temporalEvidence.frameEvidence[1].retailFrame = 281
    $casePath = Write-CheckpointManifest $case 'screenshot-frame-mismatch.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'screenshotArtifactId.*does not carry retail frame 281' `
        'Screenshot without exact retail-frame synchronization was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.mappingLedger[0].status = 'partial'
    $case.mappingLedger[0].blocker = 'fixture missing a lossless importer'
    $case.coverage.mappedRequiredFields = 31
    $case.coverage.partialRequiredFields = 1
    $casePath = Write-CheckpointManifest $case 'dishonest-complete.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'complete.*cannot be true.*partial or uncovered' `
        'complete:true was accepted with a required partial mapping.'

    $case.complete = $false
    $casePath = Write-CheckpointManifest $case 'honest-incomplete.json'
    try {
        $result = Assert-FNVRetailCheckpointManifest $casePath
        ++$caseCount
        Assert-Contract (-not $result.complete -and $result.partialRequiredFields -eq 1) `
            'Honest incomplete checkpoint did not retain its partial coverage count.'
    }
    catch {
        ++$caseCount
        $failures.Add("Honest complete:false checkpoint was rejected: $($_.Exception.Message)") | Out-Null
    }

    $case = Copy-CheckpointManifest $valid
    $case.mappingLedger = @($case.mappingLedger | Where-Object {
        $_.retailPath -ne '/snapshot/worldChanges/unloaded'
    })
    $case.coverage.requiredFields = 31
    $case.coverage.mappedRequiredFields = 31
    $casePath = Write-CheckpointManifest $case 'missing-ledger-domain.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'missing required coverage path.*/snapshot/worldChanges/unloaded' `
        'Ledger silently omitting unloaded world changes was accepted.'

    $case = Copy-CheckpointManifest $valid
    $case.hardFailures = @(
        [pscustomobject][ordered]@{
            category = 'missing-loaded-actor'
            path = '/trace/frames/20/actors/0x000104C1'
            message = 'Retail actor missing from OpenMW frame.'
            retailFrame = 120
        }
    )
    $casePath = Write-CheckpointManifest $case 'dishonest-visual-pass.json'
    Assert-ThrowsLike { Assert-FNVRetailCheckpointManifest $casePath } `
        'complete.*visual hard failures' `
        'complete:true was accepted with a missing loaded actor.'

    $case = Copy-CheckpointManifest $valid
    $case.artifacts[0].sha256 = ('E' * 64)
    $casePath = Write-CheckpointManifest $case 'artifact-hash-mismatch.json'
    try {
        Assert-FNVRetailCheckpointManifest $casePath | Out-Null
        ++$caseCount
    }
    catch {
        ++$caseCount
        $failures.Add("Portable structural validation unexpectedly read artifact files: $($_.Exception.Message)") |
            Out-Null
    }
    Assert-ThrowsLike {
        Assert-FNVRetailCheckpointManifest $casePath -VerifyArtifactFiles
    } 'artifacts/0/sha256.*does not match artifact file SHA-256' `
        'Artifact SHA-256 mismatch was not detected when file verification was requested.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'FNV retail checkpoint manifest contract failures:' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

[pscustomobject][ordered]@{
    cases = $caseCount
    requiredLedgerPaths = 32
    status = 'pass'
}
