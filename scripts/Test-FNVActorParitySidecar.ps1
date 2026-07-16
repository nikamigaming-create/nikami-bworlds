param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$coordinator = Join-Path $PSScriptRoot 'Invoke-FNVActorParitySidecar.ps1'
$openMwRunner = Join-Path $PSScriptRoot 'Invoke-OpenMWFNVLoadedActorSweep.ps1'
$retailOracle = Join-Path $repoRoot 'oracles\xnvse\nvse_retail_oracle\main.cpp'
$fixture = Join-Path $repoRoot 'catalog\fnv-actor-parity-sidecar.sunny-smiles.example.json'
$schema = Join-Path $repoRoot 'catalog\fnv-actor-parity-sidecar.schema.json'
$failures = [System.Collections.Generic.List[string]]::new()
$temporaryFiles = [System.Collections.Generic.List[string]]::new()

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

function Copy-JsonDocument([object]$Value) {
    return ($Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
}

try {
    foreach ($scriptPath in @($coordinator, $openMwRunner)) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptPath, [ref]$tokens, [ref]$parseErrors)
        Assert-Contract ($parseErrors.Count -eq 0) "$scriptPath has PowerShell parse errors."
    }
    $coordinatorSource = Get-Content -LiteralPath $coordinator -Raw
    Assert-Contract ($coordinatorSource -notmatch
        '\[uint32\]\s*0x[89A-Fa-f][0-9A-Fa-f]{7}') `
        'Coordinator contains a signed PowerShell hex literal cast to UInt32.'
    Assert-Contract ($coordinatorSource -match
        '\$defects\s*=\s*@\(\)\s*\r?\n\s*if\s*\(\$null -ne \$openMwEvidence\)') `
        'Coordinator does not preserve an empty defect collection under strict mode.'
    $openMwRunnerSource = Get-Content -LiteralPath $openMwRunner -Raw
    Assert-Contract ($openMwRunnerSource -match
        'if \(-not \$SidecarMode\)[\s\S]{0,120}OPENMW_PROOF_ACTOR_REPRESENTATIVE_POSES=1') `
        'SidecarMode still enables the semantic representative-pose surrogate.'
    $retailOracleSource = Get-Content -LiteralPath $retailOracle -Raw
    $loadProofVolume = [regex]::Match($retailOracleSource,
        'case SidecarPhase::LoadProofVolume:[\s\S]*?case SidecarPhase::WaitProofVolume:').Value
    $waitProofVolume = [regex]::Match($retailOracleSource,
        'case SidecarPhase::WaitProofVolume:[\s\S]*?case SidecarPhase::SelectActor:').Value
    $freezeTimePhase = [regex]::Match($retailOracleSource,
        'case SidecarPhase::FreezeTime:[\s\S]*?case SidecarPhase::SelectActor:').Value
    $requestScreenshotPhase = [regex]::Match($retailOracleSource,
        'case SidecarPhase::RequestScreenshot:[\s\S]*?case SidecarPhase::WaitScreenshotFile:').Value
    $sceneCommandFunction = [regex]::Match($retailOracleSource,
        'bool sidecarRequestSceneStateCommand[\s\S]*?bool sidecarRequestTimeFreeze').Value
    $faceGenReader = [regex]::Match($retailOracleSource,
        'bool sidecarReadFaceGenChannel[\s\S]*?void\* sidecarGetSceneCameraUnsafe').Value
    Assert-Contract ($loadProofVolume -notmatch 'sidecarRequestSceneState\(\)') `
        'Retail sidecar still forces time and weather on the player move/load frame.'
    Assert-Contract ($waitProofVolume -match
        'gSidecarSceneStateRequested[\s\S]*gSidecarPlan\.initializationFrames[\s\S]*sidecarRequestSceneStateCommand') `
        'Retail sidecar does not gate staged scene commands behind manifest initializationFrames.'
    Assert-Contract ($sceneCommandFunction -match
        'case 0:[\s\S]*GameHour[\s\S]*case 1:[\s\S]*fw') `
        'Retail sidecar does not stage hour and weather on distinct frames.'
    Assert-Contract ($sceneCommandFunction -notmatch 'TimeScale') `
        'Retail sidecar still freezes time before proof-volume readiness.'
    Assert-Contract ($waitProofVolume -match
        'sidecarSetPhase\(SidecarPhase::FreezeTime') `
        'Retail sidecar does not defer time freezing until the proof volume is verified.'
    Assert-Contract ($freezeTimePhase -match
        'gSidecarPhaseFrame[\s\S]*gSidecarPlan\.targetSettleFrames[\s\S]*sidecarRequestTimeFreeze\(\)[\s\S]*gSidecarTimeFreezeRequestFrame[\s\S]*gSidecarPlan\.targetSettleFrames') `
        'Retail sidecar does not settle both before and after the deferred time-freeze request.'
    Assert-Contract ($requestScreenshotPhase -match 'sidecarCaptureBackBuffer') `
        'Retail sidecar does not capture the rendered backbuffer directly.'
    Assert-Contract ($requestScreenshotPhase -notmatch 'TapKey 183') `
        'Retail sidecar still depends on focus-sensitive synthetic keyboard input.'
    Assert-Contract ($faceGenReader -match
        'reinterpret_cast<const float\*>\(channel\.values\)') `
        'Retail FaceGen telemetry does not read FGGS/FGGA/FGTS as contiguous float buffers.'
    Assert-Contract ($faceGenReader -notmatch
        'safeRead\(channel\.values \+ rowIndex, row\)') `
        'Retail FaceGen telemetry still treats contiguous channel data as a float-pointer table.'
    Assert-Contract ($faceGenReader -match
        'usedEndAddress[\s\S]*valuesBaseAddress[\s\S]*usedEndAddress - valuesBaseAddress') `
        'Retail FaceGen telemetry does not convert its absolute end pointer into a used-byte count.'
    Assert-Contract ($faceGenReader -match
        'capacityEndAddress[\s\S]*valuesBaseAddress[\s\S]*capacityEndAddress - valuesBaseAddress') `
        'Retail FaceGen telemetry does not convert its absolute end pointer into a capacity-byte count.'
    [void](Get-Content -LiteralPath $schema -Raw | ConvertFrom-Json)

    # Load only function declarations from the coordinator. This exercises its
    # actual normalizer and plan writer without executing either game lane.
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $coordinator, [ref]$tokens, [ref]$parseErrors)
    $functionDefinitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
    foreach ($definition in $functionDefinitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    try {
        $crcVector = Get-Crc32 ([Text.Encoding]::ASCII.GetBytes('123456789'))
        Assert-Contract ([uint32]$crcVector -eq [uint32]3421780262) `
            'CRC32 does not match the canonical CBF43926 test vector.'
    }
    catch {
        $failures.Add("CRC32 rejected the canonical test vector: $($_.Exception.Message)") | Out-Null
    }

    $validationRows = @(& $coordinator -ManifestPath $fixture -ValidateOnly)
    Assert-Contract ($validationRows.Count -eq 1) 'ValidateOnly did not return exactly one plan object.'
    $validation = $validationRows[0]
    Assert-Contract ($validation.status -eq 'validated-no-launch') `
        'ValidateOnly did not return validated-no-launch.'
    Assert-Contract ([bool]$validation.lockstepRequested) 'Fixture did not request lockstep.'
    Assert-Contract (@($validation.manifest.actors).Count -eq 1) `
        'The one-actor JSON array was unwrapped or rejected.'
    Assert-Contract (@($validation.manifest.actions).Count -eq 4) `
        'The fixture action descriptor count changed.'
    Assert-Contract ($validation.manifest.actions[0].openMwPoseGroup -ceq 'idle') `
        'The fixture uses a semantic stand surrogate instead of the authored idle group.'
    Assert-Contract (@($validation.manifest.captures).Count -eq 4) `
        'Actor-major capture expansion is not 1 x 4.'
    Assert-Contract ([bool]$validation.capabilityPreflight.lockstepReady) `
        'Source capability preflight is not lockstep-ready.'

    $planPath = Join-Path ([IO.Path]::GetTempPath()) `
        ("nikami-fnv-sidecar-plan-{0}.tsv" -f [Guid]::NewGuid().ToString('N'))
    $temporaryFiles.Add($planPath) | Out-Null
    Write-RetailSidecarPlan -Manifest $validation.manifest -Path $planPath
    [byte[]]$planBytes = [IO.File]::ReadAllBytes($planPath)
    Assert-Contract ($planBytes.Length -gt 3) 'Retail plan writer produced an empty file.'
    Assert-Contract (-not ($planBytes[0] -eq 0xEF -and $planBytes[1] -eq 0xBB -and
        $planBytes[2] -eq 0xBF)) 'Retail plan writer emitted a UTF-8 BOM.'
    Assert-Contract (([IO.File]::ReadLines($planPath) | Select-Object -First 1) -ceq
        'nikami-fnv-retail-plan-v1') 'Retail plan first line is not the native parser magic.'
    Assert-Contract (@([IO.File]::ReadLines($planPath) | Where-Object {
        $_.StartsWith("action`t", [StringComparison]::Ordinal)
    }).Count -eq 4) 'Retail plan did not preserve all ordered action descriptors.'

    $longSequence = 's' * 127
    $channel = New-SidecarChannelContract -SequenceId $longSequence -RequestedChannelId ''
    Assert-Contract ($channel.mappingName.Length -le 180) `
        'Generated mapping name exceeds the native 180-character bound.'
    Assert-Contract ($channel.mappingName -match '^Local\\[A-Za-z0-9][A-Za-z0-9._-]*$') `
        'Generated mapping name violates the endpoint token contract.'

    $document = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
    $scalarActions = Copy-JsonDocument $document
    $scalarActions.actions = $scalarActions.actions[0]
    Assert-ThrowsLike {
        ConvertTo-NormalizedManifest -Document $scalarActions -SourcePath 'scalar-actions.json'
    } 'actions must be a JSON array' 'Scalar actions were accepted as an array.'

    $scalarActors = Copy-JsonDocument $document
    $scalarActors.actors = $scalarActors.actors[0]
    Assert-ThrowsLike {
        ConvertTo-NormalizedManifest -Document $scalarActors -SourcePath 'scalar-actors.json'
    } 'actors must be a JSON array' 'Scalar actors were accepted as an array.'

    $duplicateAction = Copy-JsonDocument $document
    $duplicateAction.actions[1].id = $duplicateAction.actions[0].id
    Assert-ThrowsLike {
        ConvertTo-NormalizedManifest -Document $duplicateAction -SourcePath 'duplicate-action.json'
    } 'Duplicate action descriptor' 'Duplicate action IDs were accepted.'

    $unsafeRetailGroup = Copy-JsonDocument $document
    $unsafeRetailGroup.actions[0].retailPlayGroup = 'Idle Bad'
    Assert-ThrowsLike {
        ConvertTo-NormalizedManifest -Document $unsafeRetailGroup -SourcePath 'unsafe-group.json'
    } 'endpoint token contracts' 'Unsafe retail animation token was accepted.'

    $excessFrames = Copy-JsonDocument $document
    $excessFrames.actions[0].frames = 36001
    Assert-ThrowsLike {
        ConvertTo-NormalizedManifest -Document $excessFrames -SourcePath 'excess-frames.json'
    } 'integer in \[1, 36000\]' 'Out-of-range action frame count was accepted.'

    $unknownProperty = Copy-JsonDocument $document
    $unknownProperty | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    Assert-ThrowsLike {
        ConvertTo-NormalizedManifest -Document $unknownProperty -SourcePath 'unknown-property.json'
    } 'unsupported property' 'Unknown top-level manifest property was accepted.'

    $relativeScreenshot = Join-Path ([IO.Path]::GetTempPath()) `
        ("nikami-fnv-relative-shot-{0}.bmp" -f [Guid]::NewGuid().ToString('N'))
    $temporaryFiles.Add($relativeScreenshot) | Out-Null
    [IO.File]::WriteAllBytes($relativeScreenshot, [byte[]](1, 2, 3, 4))
    $relativeEvidence = Get-ValidatedFileEvidence `
        -PathValue ([IO.Path]::GetFileName($relativeScreenshot)) -SizeValue 4 `
        -Context 'test.retail.capture' -AllowedRoots @([IO.Path]::GetTempPath()) `
        -RelativeRoot ([IO.Path]::GetTempPath())
    Assert-Contract ($relativeEvidence.path -ceq [IO.Path]::GetFullPath($relativeScreenshot)) `
        'Retail relative screenshot path did not bind to its explicit approved working root.'

    $relocatedScreenshot = Join-Path ([IO.Path]::GetTempPath()) `
        ("nikami-fnv-relocated-shot-{0}.bmp" -f [Guid]::NewGuid().ToString('N'))
    $temporaryFiles.Add($relocatedScreenshot) | Out-Null
    [IO.File]::WriteAllBytes($relocatedScreenshot, [byte[]](5, 6, 7, 8))
    $relocatedEvidence = Get-ValidatedFileEvidence `
        -PathValue 'ScreenShot999999.bmp' -SizeValue 4 `
        -Context 'test.retail.relocatedCapture' -AllowedRoots @([IO.Path]::GetTempPath()) `
        -RelativeRoot ([IO.Path]::GetTempPath()) -FallbackPaths @($relocatedScreenshot)
    Assert-Contract ($relocatedEvidence.path -ceq [IO.Path]::GetFullPath($relocatedScreenshot)) `
        'Retail screenshot relocation race did not bind to the exact approved runner destination.'

    $runnerBase = @{
        OutputRoot = Join-Path ([IO.Path]::GetTempPath()) `
            ("nikami-fnv-sidecar-no-launch-{0}" -f [Guid]::NewGuid().ToString('N'))
        PoseGroups = @('idle')
        SidecarMode = $true
        SidecarActionIds = @('idle')
    }
    $badMapping = @{} + $runnerBase
    $badMapping.SidecarSharedMemoryName = 'Global\wrong-scope'
    Assert-ThrowsLike { & $openMwRunner @badMapping } 'coordinator-owned Local' `
        'OpenMW runner accepted a non-Local mapping.'

    $reservedEnvironment = @{} + $runnerBase
    $reservedEnvironment.SidecarSharedMemoryName = 'Local\NikamiFNVSidecar-test'
    $reservedEnvironment.SetEnv = @('OPENMW_FNV_SIDECAR_ACTION_IDS=override')
    Assert-ThrowsLike { & $openMwRunner @reservedEnvironment } 'must not override' `
        'OpenMW runner accepted a sidecar environment override.'
}
finally {
    foreach ($path in $temporaryFiles) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

if ($failures.Count -gt 0) {
    throw ("FNV actor parity sidecar contract failures:`n - " + ($failures -join "`n - "))
}

[pscustomobject][ordered]@{
    schema = 'nikami-fnv-actor-parity-sidecar-test/v1'
    status = 'passed'
    tests = @(
        'powershell-parse'
        'schema-json'
        'one-actor-validate-only'
        'bom-free-retail-plan'
        'mapping-name-bound'
        'strict-manifest-shape-and-bounds'
        'relative-retail-screenshot-root'
        'retail-screenshot-relocation-race'
        'openmw-sidecar-argument-ownership'
        'retail-post-move-scene-state-delay'
        'retail-direct-backbuffer-capture'
        'crc32-canonical-vector'
        'unsigned-protocol-literals'
        'strict-empty-defect-collection'
        'retail-contiguous-facegen-channels'
        'retail-facegen-end-pointer-deltas'
    )
}
