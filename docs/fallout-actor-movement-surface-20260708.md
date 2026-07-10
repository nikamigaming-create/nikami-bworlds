# Fallout Actor Movement Surface - 2026-07-08

This is the single working surface for what makes Fallout 3 and Fallout: New Vegas actors move in this OpenMW branch.

It is intentionally engine-facing: code paths, data paths, proof files, and the current failure. The video/modding lesson is included where it matters: FNV animation is not "just play a KF"; it is controller sequence + text keys + bone/root/helper mapping + per-frame pose application.

## Current Truth

- The handoff for today is `D:\code\nikami-worlds\docs\reboot-handoff-20260708-openmw-actor-rendering.md`.
- The active OpenMW source tree is `D:\Modlists\fnv\openmw-source`.
- The copied runtime used by proofs is `D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe`.
- Latest FO3 walkaround proof root is `D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-idle-arm-relax-ik-audit-order-20260708`.
- Latest FO3 walkaround manifest is `D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-idle-arm-relax-ik-audit-order-20260708\screenshots\fallout3-walkaround\fallout3-20260708-195448\manifest.json`.
- Latest FO3 walkaround contact sheet is `D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-idle-arm-relax-ik-audit-order-20260708\screenshots\fallout3-walkaround\fallout3-20260708-195448\contact-sheet.png`.
- Latest FNV walkaround proof root is `D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-after-idle-arm-relax-ik-20260708`.
- Latest FNV walkaround manifest is `D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-after-idle-arm-relax-ik-20260708\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-195545\manifest.json`.
- Latest FNV walkaround contact sheet is `D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-after-idle-arm-relax-ik-20260708\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-195545\contact-sheet.png`.
- Latest FNV walkaround captured 4 native OpenMW screenshots, exited `0`, and produced no crash reports.
- Latest FO3 walkaround captured 4 native OpenMW screenshots. It still hit the known post-screenshot shutdown crash (`exitCode=-1073740791`, 2 crash reports), but all target evidence was written before shutdown.
- Latest FNV proof status is `questionable` with no failure classes. Remaining warnings are scoped to non-target/player rows and missing fresh visual review: `actor-non-target-runtime-gap`, `actor-non-target-limb-anatomy-gap`, `actor-non-target-fabrik-gap`, `actor-visual-review-gap`.
- Latest FO3 proof status is `questionable` with no failure classes. Remaining warnings are scoped to non-target/player rows and missing fresh visual review: `actor-non-target-runtime-gap`, `actor-non-target-limb-anatomy-gap`, `actor-visual-review-gap`.
- FNV target actor runtime status is `pass` for `GSSettlerAAM` and `GSSettlerAM`.
- FO3 target actor runtime status is `pass` for `LucasSimms` and `Stockholm`.
- FNV target limb anatomy status is `pass` for 24 target rows.
- FO3 target limb anatomy status is `pass` for 24 target rows.
- FNV target FABRIK status is `pass` for 48 target rows.
- FO3 target FABRIK status is `pass` for 48 target rows.
- The FO3 fix is now code-baked: an idle arm relax IK pass detects the measured non-human `handSpan ~70`, `handMidPelvisZ ~62`, wide/high-arm pose and solves both arms to reachable human targets before proof posture audits and weapon/offhand logic.
- FO3 runtime logs show `idle arm relax IK ... handSpanBefore=70.029 ... handSpanAfter=23.16 ... restored=0 runtime=runtime-supported`, followed immediately by `standing upper body audit ... verdict=OK reason=ok`.
- The FNV behavior remains code-baked: `mtfast*` fallback locomotion sources are suppressed for humanoid proof actors, `mtforward`/`mtbackward`/`mtleft`/`mtright` synthesize both walk and run groups, and long-gun offhand IK is transactional so an impossible support-hand solve cannot leave the arm twisted.
- This is not "100% done" for all FO3/FNV animation. Whole-run proof status is still `questionable` because the harness includes non-target actors/player rows, FO3 still has a shutdown crash after screenshots, and visual approval needs closer/dedicated capture.

## Video/Modding Lesson

Reference supplied by user:

- `https://www.youtube.com/watch?v=XU9BAXkn_Bs`
- Title surfaced by search: `Tutorial For Making Reload Animations work in FNV`
- Related author material surfaced from Nexus: `https://www.nexusmods.com/newvegas/mods/61307`

What matters for this engine:

- FNV animation data is organized around Gamebryo controller sequences and text-key groups, not a single anonymous pose blob.
- `NiControllerSequence` / controller blocks must bind to the intended skeleton nodes by name and semantics.
- `NiTextKeysExtraData` determines animation groups and event timing. The engine must pick the right group and not silently fall back to bind pose.
- Weapon and reload animation work relies on exact weapon/helper nodes and key timing. A helper node such as `Weapon` is not a limb and must not be treated as a normal deform bone.
- Raw FNV KF playback can turn into garbage if root motion, helper nodes, bone aliases, or controller target names are mismatched.
- In Blender/NifSkope workflows, the human solution is retarget then bake. In this OpenMW runtime, the equivalent is to validate and bake the mapping into code/harness: controller-to-node binding, root/NonAccum handling, helper skipping, text-key group selection, and per-frame limb math.

Important project-specific correction:

- We are not trying to retarget FNV animations onto a Morrowind skeleton for shipping content.
- We are trying to make OpenMW correctly render FO3/FNV actors using FO3/FNV skeletons, FO3/FNV meshes, FO3/FNV KFs, and OpenMW's OSG runtime.
- So the lesson is not "export everything as Morrowind KF first". The lesson is "prove every skeleton/controller/helper mapping and bake the runtime retarget/mapping assumptions into code".

## Data That Makes Actors Move

Actor records:

- NPC traits, race, gender, head parts, armor, clothing, weapon, model record, and AI packages are read through `MWClass::ESM4Npc`.
- Code surface: `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`.
- Constructor surface: `ESM4NpcAnimation::ESM4NpcAnimation`.

Skeleton:

- FO3/FNV humanoid skeleton: `meshes/characters/_male/skeleton.nif`.
- Runtime object root is created by `setObjectRoot(skeletonModel, true, true, false)`.
- The runtime node map is logged through `logWorldViewerNodeMapSnapshot`.

Body and equipment:

- `ESM4NpcAnimation::updateParts`.
- `updatePartsFONV`.
- `insertPart`.
- `insertAttachedPart`.
- Equipped weapon attaches under the synthetic/real weapon frame named `Weapon`.
- Rigged Fallout geometry is marked for Fallout skinning through `setFalloutCharacterSkinning(true)`.

Animation files:

- FNV/FO3 fallback idle: `meshes/characters/_male/locomotion/mtidle.kf`.
- FNV/FO3 fallback locomotion examples:
  - `meshes/characters/_male/locomotion/male/mtforward.kf`
  - `meshes/characters/_male/locomotion/male/mtbackward.kf`
  - `meshes/characters/_male/locomotion/male/mtleft.kf`
  - `meshes/characters/_male/locomotion/male/mtright.kf`
  - `meshes/characters/_male/locomotion/mtturnleft.kf`
  - `meshes/characters/_male/locomotion/mtturnright.kf`
- Authored idle/package KFs are gathered from NPC package data before fallback sources.
- Weapon idle is currently baked for FO3 by default, not FNV, because the FNV `2hraim.kf` experiment produced worse wide arms in this runtime.

Policy data:

- `D:\code\nikami-worlds\catalog\actor-animation-policy.json`
- FO3/FNV currently keep only proof-level environment:
  - `OPENMW_WORLD_VIEWER_NPC_ANIMATION_SOURCES=meshes/characters/_male/locomotion/mtidle.kf`
  - `OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=1`
- Old broad switches for skinning, helper skipping, weapon idle, standing IK, key translation dropping, and rotation composition are supposed to be baked into code, not carried as proof flags.

## Runtime Movement Pipeline

1. Actor root starts.

- File: `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`.
- Function: `ESM4NpcAnimation::ESM4NpcAnimation`.
- Logs `npc-root-begin`.
- Loads skeleton with `setObjectRoot`.
- Logs `npc-root-end` and node map.

2. Fallout helpers are inserted.

- Function: `ESM4NpcAnimation::ESM4NpcAnimation`.
- Helper names include `Weapon`, `Torch`, `SideWeapon`, `BackWeapon`, and `Quiver`.
- These are attachment helpers, not human limbs.

3. Body parts are assembled.

- Function: `updateParts`.
- Fallout branch: `updatePartsFONV`.
- Weapon branch attaches the equipped weapon with `insertAttachedPart(weapon->mModel, "Weapon")`.

4. Animation sources are added.

- Function: `addFonvAnimationSource`.
- Source categories:
  - authored IDLE from package/record data,
  - NPC record `KFFZ` list,
  - fallback locomotion KFs,
  - FO3 weapon idle when applicable,
  - forced diagnostic KF only when explicitly set.
- Logs are emitted as `World viewer actor ledger: phase=animation-source`.

5. Animation controllers bind to nodes.

- File: `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`.
- Relevant logs:
  - `FNV/ESM4 diag: animation source ... bound X/Y`
  - `FNV/ESM4 diag: skipped synthetic attachment helper controller`
  - `FNV/ESM4 diag: animation source ... groups=[...]`
- This is where the video lesson applies hardest: if controller blocks bind to wrong nodes or helper nodes, limbs twist or helpers explode.

6. Animation group is played.

- File: `animation.cpp`.
- Function surface around `play`.
- Relevant logs:
  - `FNV/ESM4 diag: play request`
  - `FNV/ESM4 diag: play matched`
  - `FNV/ESM4 diag: play failed to match`
  - `activeGroups=[...]`
- Text-key groups must be real; otherwise bind pose leaks through.

7. Per-frame animation runs.

- File: `esm4npcanimation.cpp`.
- Function: `ESM4NpcAnimation::runAnimation`.
- Calls base `Animation::runAnimation(duration)`.
- Then applies FNV post-pass logic:
  - wide/high idle arm relax IK when a Fallout NPC pose is mathematically non-human,
  - weapon grip IK when enabled and valid,
  - weapon frame stabilization,
  - long-gun offhand IK,
  - forced rig geometry refresh.

8. Manual Fallout pose application updates duplicate/native transforms.

- File: `animation.cpp`.
- Surface logs:
  - `FNV/ESM4 diag: manually applied ... active keyframe controller(s)`
  - `semantic pose`
  - `duplicate bone audit`
  - `mirror symmetry`
  - `runtime part audit`
- This is the engine-side equivalent of a retarget bake check: source controller transforms must land on the real target skeleton nodes, not stale duplicate/helper transforms.

9. Human IK/posture correction runs.

- File: `animation.cpp`.
- Function: `applyFalloutSeatedHumanIk`.
- Current modes:
  - seated human IK: diagnostic/off by default,
  - standing leg IK: diagnostic/off by default because it stomps locomotion,
  - standing arm IK: intended on by default for Fallout NPC context.

Current fix:

- `Animation::runAnimation` now calls the virtual Fallout post-pose hook for Fallout NPCs before runtime posture audits and again before the generic proof posture sample.
- `ESM4NpcAnimation::applyPostManualFalloutActorPose` now runs `applyFalloutIdleArmRelaxIk` before optional weapon grip IK.
- `applyFalloutIdleArmRelaxIk` is thresholded by measured body math, not a proof flag: it only fires when hands/elbows are wide, hands are above the shoulders, and hand midpoint is far above the pelvis.
- The solver treats arms as two-bone chains. It computes body right/forward from the actor's shoulders, chooses reachable down/inward hand targets, rotates upper arm and forearm toward those targets, validates final hand span/height/elbow span, and restores the original pose if validation fails.
- In the latest FO3 proof this converts the broken idle pose from `handSpanBefore=70.029`, `handMidPelvisZBefore=62.126` to `handSpanAfter=23.16`, `handMidPelvisZAfter=4.2793` with `runtime=runtime-supported`.

## Current Code Surfaces

Core animation:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`
- Important functions/surfaces:
  - `shouldSkipFalloutSyntheticAttachmentHelperControllers`
  - `applyFalloutSeatedHumanIk`
  - `shouldApplyFalloutStandingLegIk`
  - `shouldApplyFalloutStandingArmIk`
  - `auditFalloutStandingUpperBody`
  - manual controller application block
  - runtime Fallout post-pass block
  - `auditFalloutRuntimeParts`
  - `auditFalloutRootAttachment`

FO3/FNV actor assembly:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`
- Important functions/surfaces:
  - `ESM4NpcAnimation::ESM4NpcAnimation`
  - `addFonvAnimationSource`
  - `collectFonvIdleAnimationSources`
  - `collectFonvPackageProcedureAnimationSources`
  - `getFonvWeaponIdlePoseKf`
  - `applyPostManualFalloutActorPose`
  - `ESM4NpcAnimation::runAnimation`
  - `applyFalloutWeaponGripIk`
  - `stabilizeFalloutLongGunWeaponFrame`
  - `stabilizeFalloutSidearmWeaponFrame`
  - `applyFalloutLongGunOffhandIk`
  - `updateParts`
  - `updatePartsFONV`
  - `insertAttachedPart`

Proof harness:

- `D:\code\nikami-worlds\scripts\Invoke-ActorRenderingProof.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorLimbAnatomy.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorRootAttachmentTelemetry.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorFabrikTelemetry.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorWeaponIkTelemetry.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorWeaponMeshTelemetry.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorRenderLiveTelemetry.ps1`
- `D:\code\nikami-worlds\scripts\Measure-ActorProofStatus.ps1`

## Latest Evidence

Latest FNV walkaround:

- Proof root: `D:\code\nikami-worlds\run\actor-rendering-proofs\walking-baseline-fnv-20260708`
- Manifest: `D:\code\nikami-worlds\run\actor-rendering-proofs\walking-baseline-fnv-20260708\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-170826\manifest.json`
- Contact sheet: `D:\code\nikami-worlds\run\actor-rendering-proofs\walking-baseline-fnv-20260708\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-170826\contact-sheet.png`
- Exit code: `0`
- Native screenshots: `4`
- Crash reports: `0`
- Proof status: `fail`
- Root attachment: `questionable`, reason `actor-root-orientation-questionable`, warning `actor-root-orientation-gap`
- Limb anatomy: `fail`
- Target failures:
  - `FormId:0x1104f07`, reason `hand_span`, `handSpan=88.6542`, `handSpreadRatio=3.2253`
  - `FormId:0x1104f02`, reason `hand_span`, `handSpan=88.6548`, `handSpreadRatio=3.2247`
- This is an upper-body pose failure with actor movement/rendering otherwise alive.

Known rejected path:

- Enabling FNV weapon idle by default through `2hraim.kf` made FNV worse in this runtime.
- It produced wide weapon/A-pose behavior, so FNV weapon idle remains opt-in diagnostic only.

Known keeper path:

- FO3 still defaults weapon idle.
- Fallout character skinning, helper controller skipping, raw FO3 rotation composition, key translation dropping, and renderer shutdown cleanup are baked into code.
- Hand-collapse detection is now in both C++ audit output and `Measure-ActorLimbAnatomy.ps1`.

## Open Source NIF Tooling Pulled In

The forum question is valid. We should not solve this in isolation when existing NIF tools already encode FO3/FNV assumptions.

Local tool clones:

- `D:\code\nikami-worlds\external\nif-tools\fnv-blender-niftools-addon`
- `D:\code\nikami-worlds\external\nif-tools\blender_niftools_addon`
- `D:\code\nikami-worlds\external\nif-tools\PyNifly`
- `D:\code\nikami-worlds\external\nif-tools\nifskope`
- `D:\code\nikami-worlds\external\nif-tools\nifxml`
- `D:\code\nikami-worlds\external\nif-tools\niflib`

Upstream references:

- `https://github.com/korri123/fnv-blender-niftools-addon`
- `https://github.com/niftools/blender_niftools_addon`
- `https://github.com/BadDogSkyrim/PyNifly`
- `https://github.com/niftools/nifskope`
- `https://github.com/niftools/nifxml`
- `https://github.com/niftools/niflib`

Useful facts extracted from those tools:

- The FNV Blender fork has `kf_export.py::apply_skeleton_to_interpolators(controller_sequence)`. It loads sibling `skeleton.nif`, finds the matching `NiNode` for each controlled block, and copies the skeleton node scale, translation, and rotation quaternion into the interpolator. That is a strong signal that missing/default channels must inherit bind skeleton data, not zeros.
- Blender Niftools imports `NiControllerSequence` controlled blocks directly and resolves Fallout-style target names through `controlledblock.target_name` or `controlledblock.get_node_name()`.
- Blender Niftools applies bind-space correction when importing pose bones into Blender actions. That is useful as a retarget/export workflow reference, but our offline runtime sweep shows that applying bind rotation again in the OpenMW world-pose path collapses shoulders.
- NifSkope evaluates `NiBSplineCompTransformInterpolator` using compact control points, basis control count, degree 3 knots, start/stop time, offsets, half-ranges, and biases. The offline harness now ports this evaluator instead of treating PyFFI's compact control points as sampled pose frames.
- PyFFI can parse FO3/FNV NIF/KF and expose `NiControllerSequence`, `NiBSplineCompTransformInterpolator`, `get_times()`, `get_rotations()`, and `get_translations()`, but its own docstring says exact B-spline timing is TODO. So PyFFI is a parser, not the final animation oracle.

## Offline Raw KF Sweep

New harness:

- `D:\code\nikami-worlds\scripts\offline_fallout_pose_sweep.py`

Purpose:

- Load real FO3/FNV skeleton and KF data outside OpenMW.
- Extract raw assets from the active profile's BSA archives with `bsatool.exe`.
- Bind `NiControllerSequence` controlled blocks to `meshes\characters\_male\skeleton.nif`.
- Compose sampled skeleton poses under multiple transform assumptions.
- Score human anatomy with limb spans, foot/knee drops, body stack, and major rotation deltas.
- Use NifSkope-style compact B-spline evaluation for `NiBSplineCompTransformInterpolator`.

Current sweep outputs:

- `D:\code\nikami-worlds\run\offline-animation-harness\probe-sweep-bspline.jsonl`
- `D:\code\nikami-worlds\run\offline-animation-harness\fnv-locomotion-bspline-sweep-20260708.jsonl`
- `D:\code\nikami-worlds\run\offline-animation-harness\fnv-male-mtforward-sweep-20260708.jsonl`
- `D:\code\nikami-worlds\run\offline-animation-harness\fnv-male-mtfastforward-sweep-20260708.jsonl`

Results so far:

- 120 locomotion KFs, 7,072 scored rows.
- Raw key rotation modes improved from `402/884` pass to `444/884` pass after exact B-spline evaluation.
- Modes that apply bind rotation again (`bind_key`, `key_bind`, `bind_inv_key`, `niftools_corrected`) fail `884/884` in the broad locomotion sweep, usually by shoulder collapse.
- Exact `meshes/characters/_male/locomotion/male/mtforward.kf`: raw key rotation passes `11/16`, failing only on wide gait frames (`leg_spread`).
- Exact `meshes/characters/_male/locomotion/male/mtfastforward.kf`: raw key rotation fails `16/16`, all `leg_crouch`, with `avgFootDrop` around `39-47` instead of the standing/walking pass band.
- The runtime proof log confirms target `FormId:0x1104f07` switches to `runforward` using `meshes/characters/_male/locomotion/male/mtfastforward.kf` at `t=0`, then near `t=0.012`.

Proof-gate change:

- `D:\code\nikami-worlds\scripts\Measure-ActorProofStatus.ps1` now accepts `-ActorFabrikTelemetryPath`.
- `D:\code\nikami-worlds\scripts\Invoke-ActorRenderingProof.ps1` now passes `actor-fabrik-telemetry.jsonl` into the status ledger.
- The status script now treats old FABRIK rows with `verdict=exploded` as `fail`, even if the older JSONL lacks a `status` field.
- Existing proof `osg-updatevisitor-fnv-walk-20260708` now reports `fabrikStatus=fail`, `allFabrikStatus=fail`, and failure class `actor-fabrik-target-exploded`.

Current implication:

- Walking and idle data are not globally impossible.
- The broad failing assumption is not "we forgot to multiply by bind rotation"; that makes the offline skeleton worse.
- Missing/default channels must inherit skeleton bind data.
- Fast-forward/run KFs, especially `male/mtfastforward.kf`, need closer handling of lower-body compression/root/accumulation semantics before being trusted as a runtime locomotion source.
- The next engine patch should be driven by this ledger: compare runtime active group pose against offline `male/mtfastforward.kf` at the same sample time, then decide whether runforward needs root/NonAccum handling, sequence priority/blend handling, or substitution back to walkforward until runforward anatomy is solved.

## TDD/Math Harness Contract

The next fix must pass math before visual promotion.

Required code-level assertions through logs/ledgers:

- Animation source ledger shows FNV/FO3 actors binding fallback locomotion KFs.
- `play matched` exists for the expected group.
- `manually applied ... active keyframe controller(s)` reports nonzero controllers on target actors.
- Synthetic helpers such as `Weapon` are skipped for animation controller binding.
- Standing arm IK can run without standing leg IK.
- Leg locomotion is not overwritten by standing leg targets during walkaround unless an explicit diagnostic env enables it.
- `actor-limb-anatomy.jsonl` has no target actor `hand_span`, `hand_collapse`, `elbow_span`, `arm_collapse`, or `arm_stretch` failures.
- `actor-root-attachment-telemetry.jsonl` has no target actor inverted-root failure.
- `actor-weapon-mesh-telemetry.jsonl` keeps the equipped weapon attached to the live hand/weapon frame.
- Visual contact sheet is last-mile confirmation, not the first debugging tool.

Acceptance numbers for current FNV target actors:

- `handSpreadRatio` must come down from about `3.22` to a human range.
- `handSpan` must come down from about `88.65` to below the wide-hand gate.
- Hands must not collapse together at chest level: `handSpan >= max(18, shoulderSpan * 0.65)` when chest-level.
- Elbows must not exceed the wide-elbow gate.
- Upper/lower arm lengths must remain within the existing limb anatomy gates.

## Current Follow-Up Plan

1. Run the same walkaround proof for FO3 with the patched runtime.

- FO3 cannot regress while FNV improves.
- Same proof harness, target limb/root/FABRIK/weapon ledgers, and visual review requirement.

2. Clean up proof scoping for non-target/player rows.

- The latest FNV target actors pass, but the combined status remains `questionable` because the scorer still carries player/non-target runtime, limb, and FABRIK warnings.
- Do not hide real failures. Fix the target selection or start-slice accounting so target proof status is not polluted by actors outside the acceptance scope.

3. Improve long-gun offhand support without corrupting arms.

- Current code refuses to commit unsafe offhand IK in idle. That is correct.
- Next improvement is to make the reachable weapon-point selection produce `runtime-supported` more often while preserving the same rollback gate:
  - target reachable by upper+forearm length,
  - final hand span within human range,
  - hand lands near weapon geometry,
  - no `hand_collapse`, `arm_span`, or twist telemetry.

4. Keep using `mtforward` as the run-group proof source until `mtfast*` anatomy is solved.

- Offline sweep still rejects `male/mtfastforward.kf` under the current pose path.
- Do not reintroduce fast locomotion fallback as a default just to make `runforward` resolve.

## Do Not Do

- Do not revive broad root-yaw/up-axis sweeps as a default path.
- Do not promote FNV `2hraim.kf` weapon idle by default unless math and visuals pass.
- Do not treat `Weapon`, `Torch`, `SideWeapon`, `BackWeapon`, or `Quiver` as deform limbs.
- Do not judge the fix from screenshots alone.
- Do not keep adding proof-only flags when the behavior belongs in runtime code.

## One-Line Diagnosis

FNV target actors now render and move in the Goodsprings walkaround with target limb/FABRIK/root/weapon ledgers passing; the latest real bug was failed long-gun offhand IK committing an impossible arm solve, and the runtime now rolls those failed solves back instead of leaving people twisted.
