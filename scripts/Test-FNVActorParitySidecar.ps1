param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$coordinator = Join-Path $PSScriptRoot 'Invoke-FNVActorParitySidecar.ps1'
$openMwRunner = Join-Path $PSScriptRoot 'Invoke-OpenMWFNVLoadedActorSweep.ps1'
$actorObservationRunner = Join-Path $PSScriptRoot 'Invoke-FNVActorObservationCapture.ps1'
$retailOracle = Join-Path $repoRoot 'oracles\xnvse\nvse_retail_oracle\main.cpp'
$captureRecipes = Join-Path $repoRoot 'catalog\fnv-jam-background-capture-recipes.json'
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

function New-TestTextureBinding(
    [string]$Semantic,
    [string]$Path,
    [int]$Stage = 0
) {
    return [pscustomobject][ordered]@{
        semantic = $Semantic
        path = $Path
        contentHash = 'sha256:0123456789abcdef'
        width = 1024
        height = 1024
        format = 'BC1_UNORM'
        sourceKind = 'authored'
        stage = $Stage
    }
}

function New-TestRenderPart(
    [string]$Role,
    [string]$SourceFormId,
    [int]$SourceSlot,
    [int]$Ordinal,
    [string]$TextureSemantic,
    [string]$TexturePath,
    [int]$TraversalOrder
) {
    return [pscustomobject][ordered]@{
        role = $Role
        sourceFormId = $SourceFormId
        sourceSlot = $SourceSlot
        ordinal = $Ordinal
        required = $true
        attached = $true
        drawable = $true
        visible = $true
        skinned = $false
        alphaBits = [uint32]1065353216
        materialId = 'lighting-material'
        shaderId = 'default-shader'
        modelHash = "model-$Role"
        nodeHash = "node-$Role"
        geometryName = "$Role-geometry"
        visualNodePath = "root/$TraversalOrder"
        textureBindings = @(
            New-TestTextureBinding -Semantic $TextureSemantic -Path $TexturePath
        )
        nodeAddress = "0x$('{0:X8}' -f (0x1000 + $TraversalOrder))"
        materialAddress = "0x$('{0:X8}' -f (0x2000 + $TraversalOrder))"
        traversalOrder = $TraversalOrder
    }
}

try {
    foreach ($scriptPath in @($coordinator, $openMwRunner, $actorObservationRunner)) {
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
    Assert-Contract ($openMwRunnerSource -notmatch
        'OPENMW_PROOF_ACTOR_REPRESENTATIVE_POSES') `
        'OpenMW actor sweep still enables the removed semantic representative-pose surrogate.'
    Assert-Contract ($openMwRunnerSource -match
        '\[switch\]\$AllAvailablePoses[\s\S]*OPENMW_PROOF_ACTOR_POSE_ALL_AVAILABLE=1') `
        'OpenMW actor sweep does not expose exact authored animation inventory traversal.'
    Assert-Contract ($openMwRunnerSource -match
        '\[switch\]\$PriorityOrder[\s\S]*OPENMW_PROOF_ACTOR_BATCH_PRIORITY_ORDER=1') `
        'OpenMW actor sweep does not expose fanout-priority ordering.'
    Assert-Contract ($openMwRunnerSource -match
        'actor native state gate:[\s\S]*nikami-fnv-actor-native-state-gate/v1') `
        'OpenMW actor sweep does not require a post-sweep native-state gate.'
    Assert-Contract ($openMwRunnerSource -match
        'OPENMW_PROOF_ACTOR_PHASE_TIMEOUT_FRAMES[\s\S]*complete-with-failures') `
        'OpenMW actor sweep cannot advance and report bounded per-actor failures.'
    $retailOracleSource = Get-Content -LiteralPath $retailOracle -Raw
    $actorObservationRunnerSource = Get-Content -LiteralPath $actorObservationRunner -Raw
    $captureRecipeDocument = Get-Content -LiteralPath $captureRecipes -Raw | ConvertFrom-Json
    $actorObservationRecipe = @($captureRecipeDocument.actorObservationRecipes | Where-Object {
        [string]$_.target -ceq 'Retail'
    })
    Assert-Contract ($actorObservationRecipe.Count -eq 1 -and
        [string]$actorObservationRecipe[0].telemetryPolicy.appearanceSchema -ceq
            'nikami-fnv-sidecar-appearance/v4') `
        'ActorObservation recipe does not require appearance v4.'
    Assert-Contract ($retailOracleSource -match
        'nikami-fnv-sidecar-appearance/v4') `
        'Retail oracle does not emit appearance v4.'
    Assert-Contract ($retailOracleSource -match
        'part\.geometryName = safeRuntimeString\(nameAddress\)' -and
        $retailOracleSource -match
        'part\.visualNodePath = visualNodePath' -and
        $retailOracleSource -match
        'part\.skinned = skinInstanceReadable && skinInstance != nullptr') `
        'Retail appearance does not bind render parts to exact runtime geometry paths.'
    $compactNodeWriter = [regex]::Match($retailOracleSource,
        'void writeCompactActorNodes[\s\S]*?void writeCompactActorVisualSnapshotUnsafe').Value
    Assert-Contract ($compactNodeWriter -match
        'if \(name != nullptr && name\[0\] !=') `
        'Retail visual snapshots still omit named geometry objects.'
    Assert-Contract ($retailOracleSource -notmatch 'equipped-unrendered') `
        'Retail oracle still conflates logical equip state with per-frame render visibility.'
    Assert-Contract ($actorObservationRunnerSource -notmatch 'equipped-unrendered') `
        'ActorObservation runner still accepts the transitional equipped-unrendered state.'
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
    $weaponCollector = [regex]::Match($retailOracleSource,
        'void sidecarCollectEquippedWeaponAttachment[\s\S]*?void sidecarCollectAppearanceSourcesAndAttachments').Value
    Assert-Contract ($weaponCollector -match
        'capture\.sources\.actorBaseType == kFormType_TESNPC[\s\S]*candidate\.sourceForm != capture\.equippedWeaponForm') `
        'Retail appearance does not bind NPC weapon geometry through the exact biped WEAP source.'
    Assert-Contract ($weaponCollector.IndexOf('capture.sources.actorBaseType == kFormType_TESNPC',
            [StringComparison]::Ordinal) -lt
        $weaponCollector.IndexOf('middleHigh->weaponNode', [StringComparison]::Ordinal)) `
        'Retail appearance reaches the broad process weapon node before applying the NPC biped rule.'
    Assert-Contract ($weaponCollector -match
        'safeRead\(&middleHigh->isWeaponOut, capture\.equippedWeaponOut\)') `
        'Retail appearance does not bind equipped-weapon visibility to the same-frame weapon-out state.'
    Assert-Contract ($weaponCollector -match
        'weaponAttachment->required = capture\.equippedWeaponOut') `
        'Retail NPC weapon attachment still treats every logical equip as required visible geometry.'
    Assert-Contract ($weaponCollector -match
        'capture\.equippedWeaponModelPath\.empty\(\)\)\s*return;') `
        'Retail creature weapon collection still fabricates attachments for model-less WEAP records.'
    $weaponValidator = [regex]::Match($retailOracleSource,
        'void sidecarValidateEquippedWeaponAppearance[\s\S]*?void sidecarAssignAppearanceOrdinals').Value
    Assert-Contract ($weaponValidator -match 'sSidecarWeaponRenderStateVisibleSourceBound' -and
        $weaponValidator -match 'sSidecarWeaponRenderStateNotVisibleAtFrame') `
        'Retail appearance does not distinguish source-bound visible weapons from nonvisible equipped state.'
    Assert-Contract ($actorObservationRunnerSource -match "'visible-source-bound'" -and
        $actorObservationRunnerSource -match "'not-visible-at-frame'" -and
        $actorObservationRunnerSource -match '\$equippedWeaponOut -ne \$poseWeaponOut') `
        'ActorObservation runner does not enforce the v4 same-frame weapon render contract.'
    Assert-Contract ($retailOracleSource -notmatch 'visible-skin-body-color-missing') `
        'Retail appearance still rejects authored unbound bodyColor stages.'
    $textureBindingCollector = [regex]::Match($retailOracleSource,
        'void sidecarAppendTextureBinding[\s\S]*?void sidecarCollectShaderTextures').Value
    Assert-Contract ($textureBindingCollector -match
        'if \(texture == nullptr\)\s*return;') `
        'Retail appearance does not preserve path-only texture slots as unbound.'
    Assert-Contract ($textureBindingCollector -match
        'texture-runtime-object-path-unreadable:role=[\s\S]*sidecarFormatFormId\(part\.sourceForm\)[\s\S]*:stage=') `
        'Retail appearance texture faults omit the exact render-part source and stage.'
    $schemaDocument = Get-Content -LiteralPath $schema -Raw | ConvertFrom-Json
    Assert-Contract ($null -ne $schemaDocument.'$defs'.appearance) `
        'Schema does not declare generic post-frame appearance evidence.'
    Assert-Contract ($null -ne $schemaDocument.'$defs'.renderPart) `
        'Schema does not declare generic render-part evidence.'
    Assert-Contract ($null -ne $schemaDocument.'$defs'.textureBinding) `
        'Schema does not declare generic texture-binding evidence.'
    Assert-Contract ([bool]$schemaDocument.'$defs'.renderPart.additionalProperties) `
        'Render-part schema does not permit later endpoint diagnostics.'

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

    $retailRenderParts = @(
        New-TestRenderPart -Role 'body' -SourceFormId '0x00001001' -SourceSlot 0 `
            -Ordinal 0 -TextureSemantic 'bodyColor' `
            -TexturePath 'Data\Textures\Characters\Raul\body_d.dds' -TraversalOrder 0
        New-TestRenderPart -Role 'leftHand' -SourceFormId '0x00001001' -SourceSlot 3 `
            -Ordinal 0 -TextureSemantic 'bodyColor' `
            -TexturePath 'Data\Textures\Characters\Raul\hand_d.dds' -TraversalOrder 1
        New-TestRenderPart -Role 'rightHand' -SourceFormId '0x00001001' -SourceSlot 3 `
            -Ordinal 1 -TextureSemantic 'bodyColor' `
            -TexturePath 'Data\Textures\Characters\Raul\hand_d.dds' -TraversalOrder 2
        New-TestRenderPart -Role 'equipment' -SourceFormId '0x00002002' -SourceSlot 2 `
            -Ordinal 0 -TextureSemantic 'gearColor' `
            -TexturePath 'Data\Textures\Armor\Wastelander\outfit_d.dds' -TraversalOrder 3
    )
    $openMwRenderParts = Copy-JsonDocument @(
        $retailRenderParts[3], $retailRenderParts[1],
        $retailRenderParts[0], $retailRenderParts[2]
    )
    for ($index = 0; $index -lt @($openMwRenderParts).Count; ++$index) {
        $part = $openMwRenderParts[$index]
        $part.sourceFormId = "FormId:$($part.sourceFormId)"
        $part.textureBindings[0].path = `
            ([string]$part.textureBindings[0].path).Replace('Data\', './').Replace('\', '/').ToUpperInvariant()
        $part.textureBindings[0].contentHash = `
            ([string]$part.textureBindings[0].contentHash).ToUpperInvariant()
        $part.textureBindings[0].format = `
            ([string]$part.textureBindings[0].format).ToLowerInvariant()
        $part.nodeAddress = "0x$('{0:X8}' -f (0x9000 + $index))"
        $part.materialAddress = "0x$('{0:X8}' -f (0xA000 + $index))"
        $part.traversalOrder = 100 - $index
    }
    $retailAppearance = [pscustomobject]@{
        document = [pscustomobject]@{
            appearance = [pscustomobject]@{
                complete = $true
                truncated = $false
                renderParts = $retailRenderParts
            }
        }
    }
    $openMwAppearance = [pscustomobject]@{
        document = [pscustomobject]@{
            appearance = [pscustomobject]@{
                complete = $true
                truncated = $false
                renderParts = $openMwRenderParts
            }
        }
    }
    try {
        $appearanceState = Assert-SidecarAppearanceParity `
            -Retail $retailAppearance -OpenMw $openMwAppearance
        Assert-Contract ([int]$appearanceState.renderPartCount -eq 4) `
            'Appearance parity did not retain the four unordered render parts.'
    }
    catch {
        $failures.Add("Appearance parity rejected reordered equivalent records: $($_.Exception.Message)") | Out-Null
    }

    $incompleteRetailAppearance = Copy-JsonDocument $retailAppearance
    $incompleteRetailAppearance.document.appearance.complete = $false
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $incompleteRetailAppearance -OpenMw $openMwAppearance
    } 'Retail appearance evidence is incomplete' `
        'Appearance parity accepted incomplete retail evidence.'

    $truncatedOpenMwAppearance = Copy-JsonDocument $openMwAppearance
    $truncatedOpenMwAppearance.document.appearance.truncated = $true
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $retailAppearance -OpenMw $truncatedOpenMwAppearance
    } 'OpenMW appearance evidence is truncated' `
        'Appearance parity accepted truncated OpenMW evidence.'

    $missingRightHand = Copy-JsonDocument $openMwAppearance
    $missingRightHand.document.appearance.renderParts = @(
        $missingRightHand.document.appearance.renderParts | Where-Object role -ne 'rightHand'
    )
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $retailAppearance -OpenMw $missingRightHand
    } 'missing required render part.*righthand' `
        'Appearance parity accepted a missing right hand.'

    $hiddenEquipment = Copy-JsonDocument $openMwAppearance
    ($hiddenEquipment.document.appearance.renderParts | Where-Object role -eq 'equipment').visible = $false
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $retailAppearance -OpenMw $hiddenEquipment
    } 'required render part.*equipment.*not visible' `
        'Appearance parity accepted hidden required equipment.'

    $alphaZeroEquipment = Copy-JsonDocument $openMwAppearance
    ($alphaZeroEquipment.document.appearance.renderParts | Where-Object role -eq 'equipment').alphaBits = 0
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $retailAppearance -OpenMw $alphaZeroEquipment
    } 'required render part.*equipment.*alpha-zero' `
        'Appearance parity accepted alpha-zero required equipment.'

    $handWithoutBodyColor = Copy-JsonDocument $openMwAppearance
    ($handWithoutBodyColor.document.appearance.renderParts | Where-Object role -eq 'rightHand').textureBindings = @()
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $retailAppearance -OpenMw $handWithoutBodyColor
    } 'texture binding mismatch.*righthand.*bodycolor' `
        'Appearance parity accepted a unilateral missing bodyColor binding.'

    $retailHandWithoutBodyColor = Copy-JsonDocument $retailAppearance
    ($retailHandWithoutBodyColor.document.appearance.renderParts |
        Where-Object role -eq 'rightHand').textureBindings = @()
    try {
        [void](Assert-SidecarAppearanceParity `
            -Retail $retailHandWithoutBodyColor -OpenMw $handWithoutBodyColor)
    }
    catch {
        $failures.Add("Appearance parity rejected matching unbound bodyColor stages: $($_.Exception.Message)") | Out-Null
    }

    $textureSemanticMismatch = Copy-JsonDocument $openMwAppearance
    (($textureSemanticMismatch.document.appearance.renderParts | Where-Object role -eq 'equipment').textureBindings[0]).semantic = 'gearNormal'
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $retailAppearance -OpenMw $textureSemanticMismatch
    } 'texture binding mismatch.*gearcolor' `
        'Appearance parity accepted different retail/OpenMW texture semantics.'

    $neutralFallback = Copy-JsonDocument $openMwAppearance
    (($neutralFallback.document.appearance.renderParts | Where-Object role -eq 'rightHand').textureBindings[0]).path = `
        'Runtime\FalloutNV\neutral-facegen-female.dds'
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $retailAppearance -OpenMw $neutralFallback
    } 'neutral FaceGen fallback' `
        'Appearance parity accepted a normalized neutral FaceGen fallback.'

    $extraVisiblePart = Copy-JsonDocument $openMwAppearance
    $extraVisiblePart.document.appearance.renderParts = @(
        @($extraVisiblePart.document.appearance.renderParts) + @(
            New-TestRenderPart -Role 'equipment' -SourceFormId 'FormId:0x00003003' `
                -SourceSlot 6 -Ordinal 0 -TextureSemantic 'gearColor' `
                -TexturePath 'textures/armor/extra/extra_d.dds' -TraversalOrder 4
        )
    )
    Assert-ThrowsLike {
        Assert-SidecarAppearanceParity -Retail $retailAppearance -OpenMw $extraVisiblePart
    } 'extra visible render part.*equipment' `
        'Appearance parity accepted an extra visible part.'

    [uint32[]]$holsterRotationBits = @(
        3210826934, 3203525720, 1026989424,
        3189668151, 1045015346, 3212302068,
        1055242061, 3210471966, 3195822950
    )
    [uint32[]]$holsterTranslationBits = @(1100293858, 3239811472, 3235687431)
    $retailHolsterAttachment = [pscustomobject][ordered]@{
        available = $true
        sourceForm = 518692
        evaluatedSlot = 5
        evaluatedState = 0
        modelRootName = 'Weapon  (0007EA24)'
        frameName = 'Weapon'
        parentName = 'Bip01 Spine2'
        rotationBits = $holsterRotationBits
        translationBits = $holsterTranslationBits
        scaleBits = [uint32]1065353217
    }
    $retailHolstered = [pscustomobject]@{
        document = [pscustomobject]@{
            animation = [pscustomobject]@{ weaponOut = $false }
            appearance = Copy-JsonDocument $retailAppearance.document.appearance
            weaponPolicy = [pscustomobject]@{
                requestedForm = 518692
                attachment = $retailHolsterAttachment
            }
        }
    }
    $openMwHolstered = [pscustomobject]@{
        document = [pscustomobject]@{
            animation = [pscustomobject]@{ retailWeaponOut = $false; weaponOut = $false }
            appearance = Copy-JsonDocument $openMwAppearance.document.appearance
            weaponPolicy = [pscustomobject]@{
                attachment = [pscustomobject]@{
                    consumed = Copy-JsonDocument $retailHolsterAttachment
                    observed = [pscustomobject][ordered]@{
                        applied = $true
                        attached = $true
                        visible = $true
                        frameName = 'Weapon'
                        parentName = 'Bip01 Spine2'
                        rotationBits = $holsterRotationBits
                        translationBits = $holsterTranslationBits
                        scaleBits = [uint32]1065353217
                    }
                }
            }
        }
    }
    try {
        $drawState = Assert-SidecarObservedStateParity -Retail $retailHolstered -OpenMw $openMwHolstered
        Assert-Contract (-not [bool]$drawState.weaponOut) `
            'Observed-state parity did not retain the shared holstered state.'
    }
    catch {
        $failures.Add("Observed-state parity rejected matching holstered state: $($_.Exception.Message)") | Out-Null
    }
    $openMwDrawn = [pscustomobject]@{
        document = [pscustomobject]@{
            animation = [pscustomobject]@{ retailWeaponOut = $false; weaponOut = $true }
        }
    }
    Assert-ThrowsLike {
        Assert-SidecarObservedStateParity -Retail $retailHolstered -OpenMw $openMwDrawn
    } 'weapon draw-state mismatch' 'Coordinator accepted mismatched retail/OpenMW weapon draw state.'

    $openMwTransposedHolster = Copy-JsonDocument $openMwHolstered
    $openMwTransposedHolster.document.weaponPolicy.attachment.observed.rotationBits[1] = `
        $holsterRotationBits[3]
    Assert-ThrowsLike {
        Assert-SidecarObservedStateParity -Retail $retailHolstered -OpenMw $openMwTransposedHolster
    } 'observed holster rotation differs' `
        'Coordinator accepted a live holster frame with a transposed retail basis.'

    $openMwHiddenHolster = Copy-JsonDocument $openMwHolstered
    $openMwHiddenHolster.document.weaponPolicy.attachment.observed.visible = $false
    Assert-ThrowsLike {
        Assert-SidecarObservedStateParity -Retail $retailHolstered -OpenMw $openMwHiddenHolster
    } 'missing, detached, hidden, or under the wrong retail parent' `
        'Coordinator accepted a hidden live holstered weapon.'

    $validationFixturePath = Join-Path ([IO.Path]::GetTempPath()) `
        ("nikami-fnv-sidecar-fixture-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    $validationRosterPath = Join-Path ([IO.Path]::GetTempPath()) `
        ("nikami-fnv-sidecar-roster-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    $temporaryFiles.Add($validationFixturePath) | Out-Null
    $temporaryFiles.Add($validationRosterPath) | Out-Null
    $validationDocument = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
    $validationDocument.openMw.representativeOffset = 0
    $validationDocument.actors[0].openMwRepresentativeIndex = 0
    [IO.File]::WriteAllText($validationFixturePath,
        ($validationDocument | ConvertTo-Json -Depth 32), [Text.UTF8Encoding]::new($false))
    $validationRoster = [pscustomobject][ordered]@{
        schema = 'nikami-fnv-loaded-actor-roster/v1'
        selectedCount = 1
        distinctVisualTypes = 1
        actors = @([pscustomobject][ordered]@{
            index = 0
            form = [string]$validationDocument.actors[0].openMwBaseId
            visualSignature = [string]$validationDocument.actors[0].visualTypeKey
            selectedWeapon = [string]$validationDocument.actors[0].selectedMainWeapon.editorId
            editorId = [string]$validationDocument.actors[0].editorId
        })
    }
    [IO.File]::WriteAllText($validationRosterPath,
        ($validationRoster | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $validationRows = @(& $coordinator -ManifestPath $validationFixturePath `
        -OpenMwRosterPath $validationRosterPath -ValidateOnly)
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
        'observed-weapon-draw-state-parity'
        'post-frame-appearance-render-parts-parity'
        'retail-contiguous-facegen-channels'
        'retail-facegen-end-pointer-deltas'
    )
}
