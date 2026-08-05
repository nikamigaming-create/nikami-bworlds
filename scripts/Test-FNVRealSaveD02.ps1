[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$CaptureRoot = "D:\code\nikami-worlds\run\fnv-real-save-campaign\d02-openmw-20260803-000000",
    [string]$RuntimeRoot = "D:\code\nikami-worlds\local\openmw-real-save330-retail-data-only-20260803-050200",
    [string]$FixturePath = "D:\code\nikami-worlds\local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos",
    [string]$EngineRoot = "D:\code\nikami-openmw-save330-integrated",
    [string]$ValidationPath = "D:\code\nikami-worlds\run\fnv-real-save-campaign\d02-weapon-selection-validation.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$CaptureRoot = [IO.Path]::GetFullPath($CaptureRoot)
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$FixturePath = [IO.Path]::GetFullPath($FixturePath)
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)
if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing D02 validation artifact: $ValidationPath"
}

function Add-D02Check {
    param([string]$Name, [bool]$Passed, [AllowNull()][object]$Detail)
    $script:checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:d02AllPass = $false }
}

function Get-D02Artifact {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Read-D02Json {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

$OpenMwRoot = Join-Path $CaptureRoot "openmw"
$SummaryPath = Join-Path $CaptureRoot "background-capture-summary.json"
$ReportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$StateManifestPath = Join-Path $OpenMwRoot "real-save-state.json"
$StdoutPath = Join-Path $OpenMwRoot "openmw.stdout.log"
$StderrPath = Join-Path $OpenMwRoot "openmw.stderr.log"
$VideoPath = Join-Path $OpenMwRoot "OpenMW-Save330-D02-weapon-selection-exact-title-raw.mp4"
$NativeSourceRoot = Join-Path $OpenMwRoot "native-source-frames"
$EngineD02Path = Join-Path $EngineRoot "apps/openmw/engine.cpp"
$Esm4NpcPath = Join-Path $EngineRoot "apps/openmw/mwclass/esm4npc.cpp"
$Esm4NpcAnimationPath = Join-Path $EngineRoot "apps/openmw/mwrender/esm4npcanimation.cpp"
$RenderingManagerPath = Join-Path $EngineRoot "apps/openmw/mwrender/renderingmanager.cpp"
$CharacterPath = Join-Path $EngineRoot "apps/openmw/mwmechanics/character.cpp"

$script:checks = [Collections.Generic.List[object]]::new()
$script:d02AllPass = $true
$summary = Read-D02Json $SummaryPath
$report = Read-D02Json $ReportPath
$stateManifest = Read-D02Json $StateManifestPath
$stdout = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) { Get-Content -LiteralPath $StdoutPath -Raw -Encoding UTF8 } else { '' }
$stderr = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { Get-Content -LiteralPath $StderrPath -Raw -Encoding UTF8 } else { '' }
$engineD02 = if (Test-Path -LiteralPath $EngineD02Path -PathType Leaf) { Get-Content -LiteralPath $EngineD02Path -Raw -Encoding UTF8 } else { '' }
$esm4Npc = if (Test-Path -LiteralPath $Esm4NpcPath -PathType Leaf) { Get-Content -LiteralPath $Esm4NpcPath -Raw -Encoding UTF8 } else { '' }
$esm4NpcAnimation = if (Test-Path -LiteralPath $Esm4NpcAnimationPath -PathType Leaf) { Get-Content -LiteralPath $Esm4NpcAnimationPath -Raw -Encoding UTF8 } else { '' }
$renderingManager = if (Test-Path -LiteralPath $RenderingManagerPath -PathType Leaf) { Get-Content -LiteralPath $RenderingManagerPath -Raw -Encoding UTF8 } else { '' }
$character = if (Test-Path -LiteralPath $CharacterPath -PathType Leaf) { Get-Content -LiteralPath $CharacterPath -Raw -Encoding UTF8 } else { '' }
$d02Start = $engineD02.IndexOf('if (fnvRealSaveD02Enabled')
$d02End = if ($d02Start -ge 0) { $engineD02.IndexOf('if (fnvRealSaveC04Enabled', $d02Start) } else { -1 }
$engineD02Block = if ($d02Start -ge 0 -and $d02End -gt $d02Start) { $engineD02.Substring($d02Start, $d02End - $d02Start) } else { '' }

$fixtureArtifact = Get-D02Artifact $FixturePath
$runtimeArtifact = Get-D02Artifact (Join-Path $RuntimeRoot "openmw.exe")
$summaryArtifact = Get-D02Artifact $SummaryPath
$reportArtifact = Get-D02Artifact $ReportPath
$stateManifestArtifact = Get-D02Artifact $StateManifestPath
$stdoutArtifact = Get-D02Artifact $StdoutPath
$stderrArtifact = Get-D02Artifact $StderrPath
$videoArtifact = Get-D02Artifact $VideoPath

Add-D02Check "Public background-capture summary is retained" ($null -ne $summaryArtifact) $summaryArtifact
Add-D02Check "OpenMW real-save report is retained" ($null -ne $reportArtifact) $reportArtifact
Add-D02Check "D02 state manifest is retained" ($null -ne $stateManifestArtifact) $stateManifestArtifact
Add-D02Check "Immutable Save330 fixture is retained" ($null -ne $fixtureArtifact) $fixtureArtifact

$expectedFixtureBytes = 3395328
$expectedFixtureSha = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
Add-D02Check "Save330 fixture has the pinned byte length and SHA-256" ($null -ne $fixtureArtifact -and $fixtureArtifact.bytes -eq $expectedFixtureBytes -and $fixtureArtifact.sha256 -eq $expectedFixtureSha) ([ordered]@{ expectedBytes = $expectedFixtureBytes; actual = $fixtureArtifact; expectedSha256 = $expectedFixtureSha })

$expectedRoute = "save330-pipboy-weapon-selection-v1"
$summaryPass = $null -ne $summary -and $summary.schema -eq "nikami-fnv-jam-background-capture-run/v1" -and $summary.status -eq "pass" -and $summary.target -eq "OpenMW" -and $summary.scenario -eq "RealSave"
Add-D02Check "Public sequential capture summary passes" $summaryPass ([ordered]@{ schema = if ($null -ne $summary) { $summary.schema } else { $null }; status = if ($null -ne $summary) { $summary.status } else { $null } })

$policyPass = $null -ne $summary -and $summary.policy.windowsAppControlUsed -eq $false -and $summary.policy.foregroundActivationUsed -eq $false -and $summary.policy.foregroundInputInjected -eq $false -and $summary.policy.capturesRanSequentially -eq $true -and $summary.policy.outputOverwritten -eq $false
Add-D02Check "Capture policy has no host control, concurrency, or overwrite" $policyPass $(if ($null -ne $summary) { $summary.policy } else { $null })

$reportPass = $null -ne $report -and $report.schema -eq "nikami-fnv-real-save-capture/v1" -and $report.status -eq "pass" -and $report.target -eq "OpenMW" -and $report.routeId -eq $expectedRoute
Add-D02Check "Real-save report passes the exact D02 route" $reportPass ([ordered]@{ schema = if ($null -ne $report) { $report.schema } else { $null }; status = if ($null -ne $report) { $report.status } else { $null }; routeId = if ($null -ne $report) { $report.routeId } else { $null } })

$reportCapturePass = $null -ne $report -and $report.capture.windowsAppControlUsed -eq $false -and $report.capture.foregroundActivationUsed -eq $false -and $report.capture.foregroundInputInjected -eq $false -and $report.capture.sourceFrameRetained -eq $true -and $report.capture.nativeFrameCount -eq 10 -and $report.capture.telemetryRetained -eq $true -and $report.capture.exactTitleVideoRetained -eq $true -and $report.capture.recorderExitCode -eq 0 -and $report.capture.gameTermination -eq "engine-exited" -and $report.capture.userConfigurationRestored -eq $true
Add-D02Check "D02 capture retained ten native weapon frames, telemetry, and exact-title video" $reportCapturePass $(if ($null -ne $report) { $report.capture } else { $null })

$statePass = $null -ne $stateManifest -and $stateManifest.status -eq "pass" -and $stateManifest.routeId -eq $expectedRoute -and $stateManifest.d02WeaponSelection.enabled -eq $true -and [int]$stateManifest.d02WeaponSelection.expectedWeaponCount -eq 10 -and [int]$stateManifest.d02WeaponSelection.expectedNativeFrameCount -eq 10 -and [int]$stateManifest.d02WeaponSelection.retainedNativeFrameCount -eq 10
Add-D02Check "D02 state manifest locks the ten-weapon production route" $statePass $(if ($null -ne $stateManifest) { $stateManifest.d02WeaponSelection } else { $null })

$reportedRuntimePath = if ($null -ne $report) { [IO.Path]::GetFullPath([string]$report.source.binary.path) } else { '' }
$expectedRuntimePath = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot "openmw.exe"))
$runtimePass = $null -ne $runtimeArtifact -and $reportedRuntimePath -eq $expectedRuntimePath -and ([string]$report.source.binary.sha256).ToLowerInvariant() -eq $runtimeArtifact.sha256 -and @((Get-ChildItem -LiteralPath $RuntimeRoot -Filter "*.pdb" -File -Recurse)).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $RuntimeRoot "resources") -PathType Container) -and (Test-Path -LiteralPath (Join-Path $RuntimeRoot "osgPlugins-3.6.5") -PathType Container)
Add-D02Check "Report binary path and SHA match the staged no-PDB runtime" $runtimePass ([ordered]@{ expectedPath = $expectedRuntimePath; reportedPath = $reportedRuntimePath; runtime = $runtimeArtifact })

$sourceSavePass = $null -ne $report -and $null -ne $report.source.saveFixture -and [IO.Path]::GetFullPath([string]$report.source.saveFixture.path) -eq $FixturePath -and [int64]$report.source.saveFixture.bytes -eq $expectedFixtureBytes -and ([string]$report.source.saveFixture.sha256).ToLowerInvariant() -eq $expectedFixtureSha
Add-D02Check "Report is hash-locked to the immutable Save330 source" $sourceSavePass $(if ($null -ne $report) { $report.source.saveFixture } else { $null })

$nativeFrameNames = 0..9 | ForEach-Object { "Save330-D02-weapon-{0:d2}.png" -f $_ }
$nativeArtifacts = @($nativeFrameNames | ForEach-Object { Get-D02Artifact (Join-Path $OpenMwRoot $_) })
$nativeHashes = @($nativeArtifacts | Where-Object { $null -ne $_ } | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
Add-D02Check "Ten named native D02 weapon frames are present, non-empty, and distinct" ($nativeArtifacts.Count -eq 10 -and @($nativeArtifacts | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0 -and $nativeHashes.Count -eq 10) $nativeArtifacts

$sourceFrames = if (Test-Path -LiteralPath $NativeSourceRoot -PathType Container) { @(Get-ChildItem -LiteralPath $NativeSourceRoot -Filter "screenshot*.png" -File | Sort-Object Name) } else { @() }
$sourceArtifacts = @($sourceFrames | ForEach-Object { Get-D02Artifact $_.FullName })
$sourceHashes = @($sourceArtifacts | Where-Object { $null -ne $_ } | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
Add-D02Check "Ten distinct native source frames are retained" ($sourceArtifacts.Count -eq 10 -and @($sourceArtifacts | Where-Object { $_.bytes -le 0 }).Count -eq 0 -and $sourceHashes.Count -eq 10) $sourceArtifacts
Add-D02Check "Exact-title raw video is present and non-empty" ($null -ne $videoArtifact -and $videoArtifact.bytes -gt 0) $videoArtifact
Add-D02Check "Capture stdout/stderr artifacts are retained" ($null -ne $stdoutArtifact -and $null -ne $stderrArtifact) ([ordered]@{ stdout = $stdoutArtifact; stderr = $stderrArtifact })

$productionSlotSourcePass = $esm4Npc -match 'The native Fallout player is represented by OpenMW' -and $esm4Npc -match 'InventoryStore::Slot_CarriedRight' -and $character -match 'isFalloutPlayerActor' -and $character -match 'FNV reload queued across weapon transition' -and $engineD02Block -match 'action=production-equipped-right-slot-observed' -and $engineD02Block -match 'InventoryStore::Slot_CarriedRight' -and $engineD02Block -notmatch 'ESM4Npc::getEquippedWeapon\(mWorld->getPlayerPtr\(\)\)' -and $engineD02Block -match 'canonical-no-reserve' -and $engineD02Block -match 'reloadPolicyPass' -and $engineD02Block -match 'action=production-controller-state-update' -and $engineD02Block -match 'action=observed-authored-first-person-pose' -and $engineD02Block -match 'menuActuallyClosed'
Add-D02Check "Production player state derives from the normal carried-right slot, reload transition, and observed held pose" $productionSlotSourcePass ([ordered]@{ esm4Npc = $Esm4NpcPath; character = $CharacterPath; engine = $EngineD02Path })

$handAuditSourcePass = $esm4NpcAnimation -match '(?s)forceFalloutRigGeometryUpdate\(mObjectRoot\.get\(\).*?worldViewerEnvEnabled\("OPENMW_FNV_HAND_POSE_AUDIT"\)'
Add-D02Check "The requested hand-pose audit is forwarded to the live first-person rig without changing its pose" $handAuditSourcePass $Esm4NpcAnimationPath

$retailHandParentSourcePass = $esm4NpcAnimation -match 'mFirstPersonLeftHandPart\s*=\s*attach\("left-hand",\s*leftHand,\s*!state\.mSaveWornLeftHandModel\.empty\(\),\s*true\);' -and $esm4NpcAnimation -match 'mFirstPersonRightHandPart\s*=\s*attach\("right-hand",\s*rightHand,\s*false,\s*true\);'
Add-D02Check "First-person hand skins use the retail scene-root parent route rather than a synthetic hand-bone helper" $retailHandParentSourcePass $Esm4NpcAnimationPath

$retailWeaponSequenceSourcePass = $esm4NpcAnimation -match '(?s)addSingleAnimSource\(\s*std::string\(baseIdle\),\s*std::string\(skeleton\),\s*false,\s*\{\},\s*"idle"\)' -and $esm4NpcAnimation -notmatch 'mergeFonvWeaponControllerOverlay\(.*?baseIdle'
Add-D02Check "First-person mtidle remains a separate retail source instead of merging an unarmed aim controller" $retailWeaponSequenceSourcePass $Esm4NpcAnimationPath

$postKfWeaponAuditSourcePass = $esm4NpcAnimation -match '(?s)mFalloutWeaponDrawFrame\s*=\s*new NifOsg::MatrixTransform\(Nif::NiTransform::getIdentity\(\)\);.*?setName\("Weapon"\).*?mNodeMap\["Weapon"\]\s*=\s*mFalloutWeaponDrawFrame.*?void ESM4NpcAnimation::emitFalloutFirstPersonWeaponPostKfAudit\(\).*?getNodeWorldMatrixUnderAncestor.*?weaponPartInWeapon.*?source=live-post-kf' -and $renderingManager -match '(?s)updateFalloutPipBoyPresentation\(dt\);\s*if \(mFalloutPlayerFirstPersonAnimation\)\s*mFalloutPlayerFirstPersonAnimation->emitFalloutFirstPersonWeaponPostKfAudit\(\);'
Add-D02Check "Post-KF weapon telemetry uses a native NIF identity Weapon mount after the production Pip-Boy presentation update" $postKfWeaponAuditSourcePass ([ordered]@{ animation = $Esm4NpcAnimationPath; rendering = $RenderingManagerPath })

$forbiddenD02Source = @('setEquippedWeapon(mWorld->getPlayerPtr()', 'setFalloutAmmoSelection(', 'inventory.equip(MWWorld::InventoryStore::Slot_CarriedRight')
$forbiddenD02SourceFound = @($forbiddenD02Source | Where-Object { $engineD02Block.Contains($_) })
Add-D02Check "D02 hook does not write a weapon slot, ESM4 weapon record, or ammo selection directly" ($forbiddenD02SourceFound.Count -eq 0) $forbiddenD02SourceFound

$observedPoseGateSourcePass = $engineD02Block -match 'fnvRealSaveD02CurrentWeapon' -and $engineD02Block -match 'advance-after-stable-native-frame' -and $engineD02Block -match 'getFalloutWeaponAnimation\(player, true\)' -and $engineD02Block -match 'getAnimationSourceName\("weaponpose"\)' -and $engineD02Block -match 'getActiveGroup\(MWRender::BoneGroup_RightArm\)' -and $engineD02Block -match '!weaponTransform->getMatrix\(\)\.isIdentity\(\)' -and $engineD02Block -match 'fnvRealSaveD02PoseStableFrames >= 2' -and $engineD02Block -match 'action=observed-authored-first-person-pose status=pass' -and $engineD02Block -notmatch 'weaponElapsed >= 100' -and $engineD02Block -notmatch 'weaponElapsed >= 120' -and $engineD02Block -notmatch 'setMatrix\(' -and $engineD02Block -notmatch 'setTranslation\(' -and $engineD02Block -notmatch 'setRotation\(' -and $engineD02Block -notmatch 'setScale\(' -and $engineD02Block -notmatch '\.play\("weaponpose"'
Add-D02Check "D02 advances from observed authored first-person pose state, never a pose countdown or corrective transform" $observedPoseGateSourcePass $EngineD02Path

$rosterMatches = [regex]::Matches($stdout, 'FNV D02 weapon roster row: index=(?<index>\d+) form=(?<form>\S+) source=restored-save330-SortFilterItemModel')
$roster = @($rosterMatches | ForEach-Object { [pscustomobject][ordered]@{ index = [int]$_.Groups['index'].Value; form = $_.Groups['form'].Value } })
$rosterPass = $roster.Count -eq 10 -and @($roster | Select-Object -ExpandProperty index | Sort-Object -Unique).Count -eq 10 -and @($roster | Select-Object -ExpandProperty form | Sort-Object -Unique).Count -eq 10 -and @($roster | Where-Object { $_.index -lt 0 -or $_.index -gt 9 }).Count -eq 0
Add-D02Check "Runtime roster contains exactly the ten restored Save330 weapon rows" $rosterPass $roster

$selectionMatches = [regex]::Matches($stdout, 'FNV D02 weapon selection: index=(?<index>\d+) form=(?<form>\S+) action=physical-pipboy-items-weapons source=production-pipboy-navigation status=pass')
$activationMatches = [regex]::Matches($stdout, 'FNV D02 weapon selection: index=(?<index>\d+) form=(?<form>\S+) action=normal-inventory-row-activation source=InventoryWindow::onItemSelected status=pass')
$bridgeMatches = [regex]::Matches($stdout, 'FNV D02 weapon selection: index=(?<index>\d+) form=(?<form>\S+) action=production-equipped-right-slot-observed path=InventoryStore::Slot_CarriedRight source=InventoryWindow::onItemSelected->ActionEquip::executeImp status=pass')
$stateSyncMatches = [regex]::Matches($stdout, 'FNV D02 weapon selection: index=(?<index>\d+) form=(?<form>\S+) action=production-controller-state-update path=MechanicsManager::forceStateUpdate status=pass')
$closeMatches = [regex]::Matches($stdout, 'FNV D02 weapon selection: index=(?<index>\d+) form=(?<form>\S+) action=production-exit-current-gui menuClosed=1 source=physical-pipboy status=pass')
$reloadMatches = [regex]::Matches($stdout, 'FNV D02 production reload: index=(?<index>\d+) form=(?<form>\S+) requested=(?<requested>[01]) path=MechanicsManager::reloadFalloutWeapon')
$poseGateMatches = [regex]::Matches($stdout, 'FNV D02 weapon pose gate: index=(?<index>\d+) form=(?<form>\S+) source="(?<source>[^"]+)" activeRightArm="weaponpose" weaponNodeParent="Bip01 Translate" directPart=1 visible=1 playing=1 nonIdentity=1 stableFrames=(?<stable>\d+) action=observed-authored-first-person-pose status=pass')
Add-D02Check "Every roster weapon uses the production ITEMS/WEAP navigation path" ($selectionMatches.Count -eq 10) $selectionMatches.Count
Add-D02Check "Every roster weapon uses the normal inventory-row activation callback" ($activationMatches.Count -eq 10) $activationMatches.Count
Add-D02Check "Every roster weapon reaches the normal ActionEquip carried-right slot" ($bridgeMatches.Count -eq 10) $bridgeMatches.Count
Add-D02Check "Every roster weapon synchronizes the live controller only after the production Pip-Boy close" ($stateSyncMatches.Count -eq 10) $stateSyncMatches.Count
Add-D02Check "Every roster weapon invokes production reload" ($reloadMatches.Count -eq 10) $reloadMatches.Count
Add-D02Check "Every roster weapon closes the production Pip-Boy before audit" ($closeMatches.Count -eq 10) $closeMatches.Count
$poseGatePass = $poseGateMatches.Count -eq 10 -and @($poseGateMatches | ForEach-Object { [int]$_.Groups['index'].Value } | Sort-Object -Unique).Count -eq 10 -and @($poseGateMatches | Where-Object { [int]$_.Groups['stable'].Value -lt 2 -or $_.Groups['source'].Value -notmatch '(?i)^meshes/characters/_1stperson/.+aim\.kf$' }).Count -eq 0
Add-D02Check "Every D02 capture observes an active, stable authored first-person aim pose on the retail Weapon mount" $poseGatePass $poseGateMatches

$auditPattern = 'FNV D02 weapon: index=(?<index>\d+) form=(?<form>\S+) menuClosed=1 menuActuallyClosed=1 right=(?<right>\S+) ammo=(?<ammo>\S+) ammoCompatible=1 ammoState=(?<ammoState>\S+) hasCompatibleReserve=(?<hasCompatibleReserve>[01]) loaded=(?<loaded>\d+) reserve=(?<reserve>\d+) model="(?<model>[^"]+)" firstPersonModel="(?<firstPersonModel>[^"]*)" hudWeapon=1 cameraMode=1 reloadRequested=(?<reloadRequested>[01]) reloadPolicyPass=1 path=production-pipboy-close-audit status=pass'
$auditMatches = [regex]::Matches($stdout, $auditPattern)
$audits = @($auditMatches | ForEach-Object { [pscustomobject][ordered]@{ index = [int]$_.Groups['index'].Value; form = $_.Groups['form'].Value; right = $_.Groups['right'].Value; ammoState = $_.Groups['ammoState'].Value; hasCompatibleReserve = $_.Groups['hasCompatibleReserve'].Value; loaded = [int]$_.Groups['loaded'].Value; reserve = [int]$_.Groups['reserve'].Value; model = $_.Groups['model'].Value; firstPersonModel = $_.Groups['firstPersonModel'].Value; reloadRequested = $_.Groups['reloadRequested'].Value } })
$auditPass = $audits.Count -eq 10 -and @($audits | Select-Object -ExpandProperty index | Sort-Object -Unique).Count -eq 10 -and @($audits | Select-Object -ExpandProperty form | Sort-Object -Unique).Count -eq 10 -and @($audits | Where-Object { $_.right -ne $_.form -or [string]::IsNullOrWhiteSpace($_.model) -or $_.ammoState -in @('missing-selection', 'incompatible-selection') }).Count -eq 0
if ($auditPass -and $rosterPass) {
    foreach ($row in $roster) {
        $auditPass = $auditPass -and @($audits | Where-Object { $_.index -eq $row.index -and $_.form -eq $row.form }).Count -eq 1
    }
}
Add-D02Check "Every restored weapon is equipped in the right slot with a canonical ammo/reload state, model, HUD, and first-person camera" $auditPass $audits

$poseGateOrderingPass = $poseGatePass -and $auditPass
if ($poseGateOrderingPass) {
    for ($index = 0; $index -lt 10; ++$index) {
        $poseGate = @($poseGateMatches | Where-Object { [int]$_.Groups['index'].Value -eq $index })
        $audit = @($auditMatches | Where-Object { [int]$_.Groups['index'].Value -eq $index })
        $poseGateOrderingPass = $poseGateOrderingPass -and $poseGate.Count -eq 1 -and $audit.Count -eq 1 -and $poseGate[0].Index -lt $audit[0].Index
    }
}
Add-D02Check "Every weapon audit follows its observed stable authored pose gate" $poseGateOrderingPass ([ordered]@{ poseGates = $poseGateMatches.Count; audits = $auditMatches.Count })

$nativeRequestMatches = [regex]::Matches($stdout, 'FNV D02 native frame request: index=(?<index>\d+) form=(?<form>\S+) source=ScreenCaptureHandler')
$nativeLogMatches = [regex]::Matches($stdout, 'FNV D02 native frame: index=(?<index>\d+) form=(?<form>\S+) source=ScreenCaptureHandler retained=1 path="(?<path>[^"]+)" bytes=(?<bytes>\d+)')
$nativeLogPass = $nativeLogMatches.Count -eq 10 -and @($nativeLogMatches | ForEach-Object { [int]$_.Groups['index'].Value } | Sort-Object -Unique).Count -eq 10 -and @($nativeLogMatches | Where-Object { [int64]$_.Groups['bytes'].Value -le 0 }).Count -eq 0
Add-D02Check "Engine telemetry retains one stable ScreenCaptureHandler frame for every weapon" $nativeLogPass $nativeLogMatches.Count

$captureGateSourcePass = $engineD02Block -match 'fnvRealSaveD02ScreenshotPending' -and $engineD02Block -match 'newestSidecarScreenshot\(mCfgMgr\.getScreenshotPath\(\)\)' -and $engineD02Block -match 'fnvRealSaveD02ScreenshotStableFrames >= 2' -and $engineD02Block -match 'd02ReadyForNextAction' -and $engineD02Block -match 'proofWorldReadyFrames \+ d02CaptureDrainFrames'
Add-D02Check "D02 source gates the next production action on a stable native frame and a render drain" $captureGateSourcePass $EngineD02Path

$captureOrderingPass = $nativeRequestMatches.Count -eq 10 -and $nativeLogPass -and $selectionMatches.Count -eq 10
if ($captureOrderingPass) {
    for ($index = 0; $index -lt 10; ++$index) {
        $request = @($nativeRequestMatches | Where-Object { [int]$_.Groups['index'].Value -eq $index })
        $retained = @($nativeLogMatches | Where-Object { [int]$_.Groups['index'].Value -eq $index })
        $captureOrderingPass = $captureOrderingPass -and $request.Count -eq 1 -and $retained.Count -eq 1 -and $request[0].Index -lt $retained[0].Index
        if ($index -lt 9) {
            $nextSelection = @($selectionMatches | Where-Object { [int]$_.Groups['index'].Value -eq ($index + 1) })
            $captureOrderingPass = $captureOrderingPass -and $nextSelection.Count -eq 1 -and $retained[0].Index -lt $nextSelection[0].Index
        }
    }
}
Add-D02Check "Every row retains its stable native frame before the next Pip-Boy navigation" $captureOrderingPass ([ordered]@{ requests = $nativeRequestMatches.Count; retained = $nativeLogMatches.Count; selections = $selectionMatches.Count })

$handAuditMatches = [regex]::Matches($stdout, '(?i)FNV/ESM4 hand pose audit: rig=.*righthand')
Add-D02Check "Requested D02 first-person hand audit is emitted from the live rig" ($handAuditMatches.Count -gt 0) $handAuditMatches.Count

$firstPersonLeftHandAttachment = [regex]::Matches($stdout, 'FNV first-person attachment: actor=Player role=left-hand .* actorSpace=1 ')
$firstPersonRightHandAttachment = [regex]::Matches($stdout, 'FNV first-person attachment: actor=Player role=right-hand .* actorSpace=1 ')
Add-D02Check "Runtime telemetry confirms both hand skins use the retail scene-root parent route" ($firstPersonLeftHandAttachment.Count -gt 0 -and $firstPersonRightHandAttachment.Count -gt 0) ([ordered]@{ left = $firstPersonLeftHandAttachment.Count; right = $firstPersonRightHandAttachment.Count })

$separateMtidle = [regex]::Matches($stdout, 'FNV first-person animation: actor=Player semantic=idle base=meshes/characters/_1stperson/mtidle\.kf overlay=none ')
$separate10mmAim = [regex]::Matches($stdout, 'FNV/ESM4 dynamic animation-family-resolution: actor=.*firstPerson=1 .*semantic=weaponpose .*selectedPath=meshes/characters/_1stperson/1hpaim\.kf .*status=pass')
Add-D02Check "Runtime retains the retail mtidle plus independent 1hpaim sequence pair for the Save330 10mm" ($separateMtidle.Count -gt 0 -and $separate10mmAim.Count -gt 0) ([ordered]@{ mtidle = $separateMtidle.Count; oneHandPistolAim = $separate10mmAim.Count })

$postKfWeaponAuditMatches = [regex]::Matches($stdout, 'FNV first-person weapon post-KF audit: actor="Player" model="(?<model>[^"]+)"[^\r\n]*?weaponNode="Weapon"[^\r\n]*?weaponNodeParent="Bip01 Translate"[^\r\n]*?weaponNodePostKf=r=\((?<rotation>[^)]*)\) t=\((?<translation>[^)]*)\) s=\((?<scale>[^)]*)\)[^\r\n]*?weaponPartParent="Weapon"[^\r\n]*?weaponPartInWeapon=r=\([^\r\n]+\) .*source=live-post-kf')
$postKfWeaponAudits = @($postKfWeaponAuditMatches | ForEach-Object {
    $translation = @($_.Groups['translation'].Value.Split(',') | ForEach-Object {
        [double]::Parse($_.Trim(), [Globalization.CultureInfo]::InvariantCulture)
    })
    $scale = @($_.Groups['scale'].Value.Split(',') | ForEach-Object {
        [double]::Parse($_.Trim(), [Globalization.CultureInfo]::InvariantCulture)
    })
    [pscustomobject][ordered]@{
        model = $_.Groups['model'].Value
        rotation = $_.Groups['rotation'].Value
        translation = $translation
        scale = $scale
    }
})
$postKfWeaponChainPass = $postKfWeaponAudits.Count -eq 10
Add-D02Check "Runtime records the retail live post-KF Weapon chain for every D02 weapon without a corrective transform" $postKfWeaponChainPass $postKfWeaponAudits

$postKfNonDegenerateScalePass = $postKfWeaponChainPass
foreach ($postKfAudit in $postKfWeaponAudits) {
    $postKfNonDegenerateScalePass = $postKfNonDegenerateScalePass -and $postKfAudit.scale.Count -eq 3
    foreach ($scaleComponent in $postKfAudit.scale) {
        $postKfNonDegenerateScalePass = $postKfNonDegenerateScalePass -and -not [double]::IsNaN($scaleComponent) -and -not [double]::IsInfinity($scaleComponent) -and [Math]::Abs($scaleComponent - 1.0) -lt 0.001
    }
}
Add-D02Check "Every post-KF retail weapon mount preserves a finite unit NIF scale" $postKfNonDegenerateScalePass $postKfWeaponAudits

$retail10mmPostKfTranslation = @(8.67439365, 2.21316123, 1.06902444)
$retail10mmPostKfAudit = @($postKfWeaponAudits | Where-Object { $_.model -match '(?i)^(?:meshes[\\/])?weapons[\\/]1handpistol[\\/]10mmpistol\.nif$' })
$retail10mmPostKfPass = $retail10mmPostKfAudit.Count -eq 1 -and $retail10mmPostKfAudit[0].translation.Count -eq 3
if ($retail10mmPostKfPass) {
    for ($component = 0; $component -lt 3; ++$component) {
        $retail10mmPostKfPass = $retail10mmPostKfPass -and [Math]::Abs($retail10mmPostKfAudit[0].translation[$component] - $retail10mmPostKfTranslation[$component]) -lt 0.001
    }
}
Add-D02Check "Vanilla Save330 10mm reaches the retail xNVSE 1hpaim terminal translation after Pip-Boy close" $retail10mmPostKfPass ([ordered]@{ expected = $retail10mmPostKfTranslation; actual = $retail10mmPostKfAudit })

$completePass = $stdout -match 'FNV D02 weapon selection: phase=complete weapons=10 captured=10 source=production-pipboy-weapon-selection status=pass'
Add-D02Check "D02 completes all ten production weapon audits" $completePass $completePass

$forbiddenCaptureTerms = @("AppActivate", "SetForegroundWindow", "SendInput", "Computer Use", "showFalloutMapMarker", "unlock-all", "unlock all")
$forbiddenTermsFound = @($forbiddenCaptureTerms | Where-Object { $stdout -match [regex]::Escape($_) -or $stderr -match [regex]::Escape($_) })
Add-D02Check "D02 runtime logs contain no host-control or unlock shortcut" ($forbiddenTermsFound.Count -eq 0) $forbiddenTermsFound

$validation = [ordered]@{
    schema = "nikami-fnv-real-save-d02-validation/v1"
    status = if ($script:d02AllPass) { "pass" } else { "fail" }
    objective = "Validate canonical Save330 Pip-Boy WEAP row selection, normal equipped-right-slot state, production reload, and live weapon audit for every restored weapon."
    captureRoot = $CaptureRoot
    routeId = $expectedRoute
    source = [ordered]@{
        fixture = $fixtureArtifact
        runtime = $runtimeArtifact
        publicSummary = $summaryArtifact
        captureReport = $reportArtifact
        stateManifest = $stateManifestArtifact
        stdout = $stdoutArtifact
        stderr = $stderrArtifact
        video = $videoArtifact
        namedNativeFrames = $nativeArtifacts
        nativeSourceFrames = $sourceArtifacts
    }
    roster = $roster
    audits = $audits
    checks = @($script:checks)
}
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 24) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

if (-not $script:d02AllPass) {
    throw "D02 validation failed. See $ValidationPath"
}

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $script:checks.Count
    passedChecks = @($script:checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-D02Artifact $ValidationPath
    captureRoot = $CaptureRoot
}
