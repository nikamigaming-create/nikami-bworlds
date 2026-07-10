# Reboot Handoff: OpenMW ESM4 Actor Rendering Proof

Date: 2026-07-08
Workspace: `D:\code\nikami-worlds`
External OpenMW source: `D:\Modlists\fnv\openmw-source`
Runtime binary copied from external build to: `D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe`

This is the exact restart note for the next thread. The important thing is not to restart the whole investigation. We have already narrowed the failure from "actors are blown apart" to a specific renderer/scene-graph mismatch that should be tested piece by piece.

## North Star

Goal:

- Keep the OpenMW overlay patches in `nikami-worlds`, separate from upstream source.
- Prove every fix with real, native in-game screenshots, not window captures.
- Stay non-VR.
- Work piece by piece, then whole actor, then whole game set.
- Preserve Morrowind as the control case. Morrowind works; do not break its generic attachment path.
- Treat FO3/FNV as first-class targets. The user specifically wants to walk in FO3 and see people as well as FNV.
- Do not promote code based only on telemetry. Promotion requires serviceable close/orbital screenshots.

Supported game targets in scope:

- Morrowind: control, expected to work.
- Oblivion: already had better actors in earlier work; must not regress.
- Skyrim: already had better actors in earlier work; must not regress.
- Fallout 3: broken actor proof, must be fixed.
- Fallout: New Vegas: broken actor proof, must be fixed.
- Fallout 4: assets/pipeline are useful and should remain a separate proof target.
- Starfield: deprioritize for now. It pulled the project off the rails. Do not use it as the next anchor.

## Current State: Keeper Proof From 2026-07-08

This section supersedes the older `0016` investigation notes below. Keep the old notes as archaeology, but do not treat `0016` as the next move.

We are no longer at "actors stuck in T-pose/exploded" for Fallout: New Vegas or Fallout 3. The current runtime renders coherent animated people in close-burst proofs, with weapons attached to the live animated hand path. As of the afternoon pass, FNV and FO3 both have native player-camera walkaround evidence. The result is not final game-quality locomotion yet: poses are still aggressive/weapon-biased and close-up faces/hands still need work, but the old FO3 walkaround blocker was a camera harness/slice problem, not an actor assembly failure.

The shared keeper runtime stack for FO3/FNV actor assembly is:

```text
OPENMW_ESM4_SKINNING_MODE=invBindThenSkeleton
OPENMW_ESM4_DROP_ACTOR_KEY_TRANSLATIONS=1
OPENMW_ESM4_STANDING_LEG_IK=1
OPENMW_ESM4_SKIP_SYNTHETIC_ATTACHMENT_HELPER_CONTROLLERS=1
```

Posture policy is now split by game. FO3 keeps `OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=1` for the stable close/walk policy. FNV uses neutral/no-IK posture with `OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=0`, `OPENMW_FNV_WEAPON_IK=0`, and `OPENMW_FNV_DISABLE_WEAPON_IK=1`.

Audit/proof runs should also add these when measuring:

```text
OPENMW_FNV_PART_MATRIX_AUDIT=1
OPENMW_ESM4_ROOT_ATTACHMENT_AUDIT=1
OPENMW_ESM4_STANDING_UPPER_AUDIT=1
OPENMW_PROOF_POSTURE_TARGET=player
OPENMW_PROOF_POSTURE_SAMPLES=8
```

The important math correction was not `0015` or `0016`. The live skeleton path was already usable once `invBindThenSkeleton` was active. The bad part was letting authored KF controllers bind onto synthetic attachment helpers such as `Weapon`. That made the helper basis stale/invalid and could push weapon transforms into NaN. Synthetic helpers are now marked in `esm4npcanimation.cpp`, and `animation.cpp` can skip those controller bindings under `OPENMW_ESM4_SKIP_SYNTHETIC_ATTACHMENT_HELPER_CONTROLLERS=1`, so carried parts inherit the real animated actor hand/body transform.

Active local/runtime changes from the keeper pass:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`
  - Marks Fallout synthetic attachment helpers with `esm4SyntheticAttachmentHelper`.
- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`
  - Adds finite matrix/vector checks to actor part matrix audit.
  - Treats non-finite center/anchor/distance as bad instead of letting NaN look OK.
  - Skips controllers targeting marked synthetic helpers named `Weapon`, `Torch`, `SideWeapon`, `BackWeapon`, or `Quiver` when the keeper env is set.
- `D:\code\nikami-worlds\local\openmw-fo4guard\resources\vfs\scripts\omw\cellhandlers.lua`
  - Guards the Morrowind fish spawner so ESM4 proof cells do not hit the `sys::default`-only handler path.
- Release build succeeded and was copied to:

```text
D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe
```

Fallout: New Vegas keeper proofs:

```text
Direct math manifest:
D:\code\nikami-worlds\run\actor-math-direct\direct-fnv-skip-helper-controllers-20260708-0750\skip-synthetic-helper-controllers\manifest.json

Visual manifest:
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-074502\manifest.json

Contact sheet:
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-074502\contact-sheet.png
```

FNV math status:

- Root attachment ledger passes: `rootAuditCount=18`, `headBelowPelvisCount=0`, `feetAbovePelvisCount=0`.
- Render/live ledger is only "questionable" because of initialization transition rows: `renderGood=24/24 valid`, `liveGood=74/74 valid`.
- No `-nan`, no `finite*=0`, no `verdict=SUSPECT` in the late part matrix rows.
- Varmint rifle sits under the weapon limit at about `12.67` units from its anchor.
- Late hand rows show render following live skeleton, not source geometry:
  - Left hand render about `9.15-9.19`, source about `78`, live about `9.81-9.85`.
  - Right hand render about `5.56-5.59`, source about `91`, live about `7.05`.
- Native/window proof captured 7 screenshots with evidence pass and no crash report.

Fallout 3 keeper proofs:

```text
Direct math manifest:
D:\code\nikami-worlds\run\actor-math-direct\direct-fo3-invbind-helper-skip-20260708-0755\fo3-invbind-helper-skip\manifest.json

Visual manifest:
D:\code\nikami-worlds\run\real-world-screenshots\fallout3-20260708-074745\manifest.json

Contact sheet:
D:\code\nikami-worlds\run\real-world-screenshots\fallout3-20260708-074745\contact-sheet.png
```

FO3 math status:

- Root attachment ledger passes: `rootAuditCount=12`, `headBelowPelvisCount=0`, `feetAbovePelvisCount=0`.
- Render/live ledger is only "questionable" because of initialization transition rows: `renderGood=24/24 valid`, `liveGood=44/44 valid`.
- No `-nan`.
- Hunting rifle sits at about `19.23` units from its anchor; assault rifle sits at about `11.61`, both under the weapon limit.
- Late hand rows show render following live skeleton, not source geometry.
- Visual proof succeeded with exit code 0 and no crash reports. Native rows trip the current magenta evidence policy, but the window fallback rows pass and the contact sheet shows actual Megaton/Lucas Simms actor rendering.

Next real moves:

1. Use the frictionless wrapper for focused actor proof runs:

```powershell
.\scripts\Invoke-ActorRenderingProof.ps1 -WorldId fallout_new_vegas -ProofKind close-burst
.\scripts\Invoke-ActorRenderingProof.ps1 -WorldId fallout_new_vegas -ProofKind walkaround
.\scripts\Invoke-ActorRenderingProof.ps1 -WorldId fallout3 -ProofKind close-burst
```

The wrapper runs `Invoke-RealWorldScreenshots.ps1` with the keeper actor policy and audit env, then generates the contact sheet plus screenshot, runtime, rig, part, render/live, face, basis, root, FABRIK, and proof-status ledgers in the same run directory. Default behavior is `-ShowGui` plus explicit window fallback because that is the stable proof path today.

2. FNV has player-camera walkaround visual proof:

```text
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-080005\contact-sheet.png
```

This shows the Goodsprings settler from the player camera after real held movement input. Math ledgers pass root attachment and keep exact FABRIK anchors, but the process emitted an after-capture crash report in that manual run.

3. FO3 now has player-camera walkaround visual proof when run with GUI hidden:

```powershell
.\scripts\Invoke-ActorRenderingProof.ps1 -WorldId fallout3 -ProofKind walkaround -RunId fo3-walkaround-nudge-settle-hidegui-20260708-1330 -HideGui
```

The proof clean-exits, captures four native screenshots, passes screenshot evidence with GUI hidden, and passes target actor runtime/part/render-live/root/face ledgers for Lucas Simms and Stockholm. The contact sheet is:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-walkaround-nudge-settle-hidegui-20260708-1330\screenshots\fallout3-walkaround\fallout3-20260708-120342\contact-sheet.png
```

4. Run Morrowind, Oblivion, Skyrim, and Fallout 4 regression controls before promoting the keeper stack beyond FO3/FNV policy.

5. Improve pose selection so the default proof reads as natural idle/walk instead of aggressive weapon upper-body pose.

Latest wrapper validation:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\wrapper-fnv-close-postfix-20260708-0814\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\wrapper-fnv-close-postfix-20260708-0814\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-081425\contact-sheet.png
```

Result: wrapper completed end-to-end, captured six native FNV screenshots, generated all ledgers, and wrote the summary. The visual sheet shows the Goodsprings settler as a coherent animated armed actor. `actor-proof-status` remains conservative because unrelated rows such as player/Easy Pete/crow runtime checks fail; read the actor-specific ledgers and contact sheet before using the aggregate status as a promotion gate.

## Afternoon Update: Isolated Viewer, Staticized Hands, FO3 Walkaround

The isolated viewer was real and was found at:

```text
D:\code\vulkanOpenMW\nikami-openmw-lab-publish
```

The useful deltas from that viewer were ported instead of guessing:

- Staticized rigged Fallout hand parts now attach with normalized staticized transforms, matching the isolated viewer behavior. This removed the FNV/FO3 "roof hand" and large right-hand render path offset.
- FNV weapon IK now has the isolated viewer's light clavicle assist.
- `catalog\actor-animation-policy.json` now enables `OPENMW_FNV_STATICIZE_RIGGED_HAND_PARTS=1` for both `fallout3` and `fallout_new_vegas`.
- Generic non-static world-viewer cameras now use the same third-person nudge/settle cycle as the successful FNV startup camera before returning to requested first-person/third-person mode.
- First-person world-viewer camera pitch/yaw are converted into player rotation at the start anchor and again in delayed settle, so catalog camera angles actually drive player-camera screenshots.

Keeper proof paths from this pass:

```text
FNV close-burst policy:
D:\code\nikami-worlds\run\actor-rendering-proofs\policy-staticized-hands-close-burst-20260708-1155\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-113109\contact-sheet.png

FO3 close-burst policy:
D:\code\nikami-worlds\run\actor-rendering-proofs\policy-staticized-hands-close-burst-20260708-1155\screenshots\fallout3-close-burst\fallout3-20260708-113155\contact-sheet.png

FNV walkaround after camera nudge patch:
D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-walkaround-after-nudge-settle-20260708-1325\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-120252\contact-sheet.png

FO3 walkaround after camera nudge patch, GUI hidden:
D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-walkaround-nudge-settle-hidegui-20260708-1330\screenshots\fallout3-walkaround\fallout3-20260708-120342\contact-sheet.png
```

Current honest state:

- FNV and FO3 actors are now visible as animated people in real native walkaround proofs.
- FO3 walkaround with GUI visible still trips the magenta screenshot classifier because the Fallout UI/nameplate is magenta-heavy. The hidden-GUI run passes screenshot evidence.
- Close-up quality is still not final. Hands, arms, face parts, and weapon-biased poses still need focused improvement.
- `actor-proof-status` remains stricter than target proof status because unrelated actors/player rows can fail. Use target actor ledgers plus contact sheets when deciding whether a run proves Lucas/Stockholm or the Goodsprings settlers.

## Afternoon Update: Math Harness and Neutral Human Pose Policy

The next pass added a real weapon-IK math ledger instead of judging the close-up pose only from screenshots:

```text
scripts\Measure-ActorWeaponIkTelemetry.ps1
```

`Invoke-ActorRenderingProof.ps1` now emits `actor-weapon-ik-telemetry.jsonl` for runs with FNV weapon IK telemetry, and `Invoke-ActorMathMatrix.ps1` has targeted cases for weapon idle, no weapon IK, soft IK, low-ready targets, and explicit hand orientation.

The important FNV finding:

- The old FNV weapon-IK policy was not exploding, but it was still twisting hands/upper body. Baseline FNV math showed max hand-forward angles around 154 degrees and only 3 clean weapon-IK pass rows out of 24 in the short matrix.
- `weapon-ik-soft` made aim worse.
- `weapon-ik-low-ready` helped the sidearm briefly but made the long-gun twist worse and dirty-exited.
- `weapon-ik-hand-orientation` worsened sidearm twist and failed native capture.
- `no-weapon-idle-no-weapon-ik` produced more human close/walkaround visuals, but only cleanly exited when `OPENMW_FNV_DISABLE_WEAPON_IK=1` was explicit.

Promoted catalog policy:

```text
fallout3 stable policy:
OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=1

fallout3 neutral-idle candidate only:
OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=0
Do not promote globally until walkaround exits clean.

fallout_new_vegas:
OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=0
OPENMW_FNV_WEAPON_IK=0
OPENMW_FNV_DISABLE_WEAPON_IK=1
```

Keeper proof paths from this pass:

```text
FNV policy close-burst and walkaround, neutral/no-IK, clean exit:
D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-policy-neutral-explicit-disable-both-20260708-1254\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-policy-neutral-explicit-disable-both-20260708-1254\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-124039\contact-sheet.png
D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-policy-neutral-explicit-disable-both-20260708-1254\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-124129\contact-sheet.png

FO3 stable policy close-burst and walkaround, weapon idle, clean exit:
D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-policy-stable-weapon-idle-both-20260708-1308\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-policy-stable-weapon-idle-both-20260708-1308\screenshots\fallout3-close-burst\fallout3-20260708-125228\contact-sheet.png
D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-policy-stable-weapon-idle-both-20260708-1308\screenshots\fallout3-walkaround\fallout3-20260708-125330\contact-sheet.png

FO3 neutral idle close-burst candidate only, clean exit:
D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-close-policy-neutral-idle-20260708-1235\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\fo3-close-policy-neutral-idle-20260708-1235\screenshots\fallout3-close-burst\fallout3-20260708-123030\contact-sheet.png
```

Current honest state after this pass:

- FNV now prioritizes readable human silhouettes over weapon-biased poses. Actors are upright, animated, and serviceable in native close-burst/walkaround proofs under the neutral/no-IK policy.
- FO3 stable policy remains weapon idle because the neutral walkaround proof captured screenshots but dirty-exited with `-1073740791` and crash reports. The stable weapon-idle policy cleanly captures both close-burst and walkaround.
- Weapon handling is not final. The promoted FNV policy deliberately disables the current weapon IK because it twists hands/arms; do not re-enable it without passing `actor-weapon-ik-telemetry.jsonl` and visual contact sheets.
- FO3 neutral idle is a close-burst visual candidate only. It is not the global policy until walkaround exits clean.
- Aggregate `actor-proof-status` still fails because of unrelated/non-target actors, conservative rig-pose rows, and player rows. Target actors pass the ledgers that matter for this step.
- Regression controls are partially run: Morrowind, Oblivion, and Fallout 4 passed native screenshot smoke; Skyrim is blocked by local readiness/profile status.

Control summary from this pass:

```text
D:\code\nikami-worlds\run\control-smoke\control-summary-20260708-1258.json

Passed:
- morrowind / seyda-neen-geometry-smoke: native screenshot, exit 0, no crashes.
- oblivion / imperial-city-palace-geometry-actor-smoke: native screenshot, exit 0, no crashes.
- fallout4 / exterior-sanctuary-geometry-orbit-burst: four native screenshots, exit 0, no crashes.

Blocked:
- skyrim_vr / exterior-riverwood-actor-cluster: Invoke-RealWorldScreenshots readiness gate reports installStatus=ready profileStatus=generated.
```

## Afternoon Update: Weapon IK Diagnostic Harness

The next weapon/hand pass did not promote weapon IK, but it did improve the harness and left useful env-gated diagnostic tools:

- `scripts\Measure-ActorWeaponIkTelemetry.ps1` now parses explicit hand-orientation candidates plus forward/palm errors instead of scoring every hand as if local `+Y` were always the weapon-forward axis.
- `scripts\Invoke-ActorMathMatrix.ps1` clears `OPENMW_FNV_DISABLE_WEAPON_IK` in weapon-IK cases and adds focused cases for automatic low-ready hand orientation and class-specific forced hand axes.
- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp` now supports class-specific weapon IK target env vars and class/side-specific hand-orientation env vars. These are diagnostic only unless explicitly set.

Important result:

```text
Matrix:
D:\code\nikami-worlds\run\actor-math-matrix\fnv-weapon-ik-class-hand-20260708-1306\summary.jsonl

Best diagnostic case:
weapon-ik-low-ready-auto-hand
weaponIkRowCount=24
weaponIkPassCount=14
weaponIkFailCount=1
weaponIkQuestionableCount=9
weaponIkMaxAimAfter=0.02
weaponIkMaxRightTargetAfter=6.364
weaponIkMaxLeftTargetAfter=9.905

Diagnostic proof:
D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-low-ready-auto-hand-close-20260708-1310\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\fnv-low-ready-auto-hand-close-20260708-1310\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-130801\contact-sheet.png
```

Decision: do not promote this weapon IK policy. The low-ready auto-hand case captured six native screenshots, exited cleanly, and improved target/aim math over the old enabled IK, but it still produced IK fail/questionable rows, target `arm_asymmetry` limb rows, and a contact sheet that does not beat the current neutral/no-IK silhouette policy. The forced class-specific hand-axis case was worse mathematically and is also not a keeper.

Current policy smoke after rebuilding the runtime:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\policy-close-smoke-after-weapon-ik-diagnostics-20260708-1312\actor-rendering-proof.json

FNV close-burst: captured-native, exit 0, six screenshots, no crash reports.
FO3 close-burst: captured-native, exit 0, six screenshots, no crash reports.
```

## Afternoon Update: Weapon Helper Rotation Diagnostic

The next diagnostic tried rotating the synthetic weapon helper instead of re-enabling weapon IK. This produced a real visual lead but was not promoted.

Best visual grid case:

```text
D:\code\nikami-worlds\run\weapon-helper-grid\fnv-helper-rot-grid-20260708-1320
case: rot-y--90
D:\code\nikami-worlds\run\weapon-helper-grid\fnv-helper-rot-grid-20260708-1320\rot-y--90\fallout_new_vegas-20260708-131523\screenshots\fallout_new_vegas.t010.png
```

With `OPENMW_FNV_WEAPON_ROTATION_Y=-90`, the FNV rifle reads more like a carried object than the neutral helper orientation. Explicit override proofs captured native screenshots for FNV and FO3 close/walk:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\weapon-helper-yminus90-close-both-20260708-1324\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\weapon-helper-yminus90-walk-both-20260708-1328\actor-rendering-proof.json
```

Do not promote this yet. When the value was moved into catalog policy, the full policy proof flaked, and a clean sequential FNV close proof with the catalog value still dirty-exited after native capture:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\policy-weapon-helper-yminus90-fnv-close-seq-20260708-1348\actor-rendering-proof.json

FNV close-burst with catalog OPENMW_FNV_WEAPON_ROTATION_Y=-90:
captured-native, six screenshots, crashReportCount=2, exitCode=-1.
```

The control run cleared only `OPENMW_FNV_WEAPON_ROTATION_Y` while leaving the rest of the policy intact and exited cleanly:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\control-clear-weapon-y-fnv-close-20260708-1353\actor-rendering-proof.json

FNV close-burst with OPENMW_FNV_WEAPON_ROTATION_Y cleared:
captured-native, six screenshots, crashReportCount=0, exitCode=0.
```

Decision: keep `OPENMW_FNV_WEAPON_ROTATION_Y=-90` as a diagnostic lead only. It is not in `catalog\actor-animation-policy.json` because it currently correlates with repeatable FNV after-capture shutdown crashes. The next weapon work should either find why that helper rotation dirties shutdown or use the visual clue to derive a safer helper-space fix.

Fresh current-policy proof after removing the helper rotation from catalog:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\policy-current-after-helper-y-revert-fnv-close-20260708-1359\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\policy-current-after-helper-y-revert-fnv-close-20260708-1359\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-133314\contact-sheet.png

FNV close-burst current catalog policy:
captured-native, six screenshots, crashReportCount=0, exitCode=0.
Target actors GSSettlerAAM and GSSettlerAM pass runtime binding and limb anatomy; aggregate proof status remains fail because it includes non-target/player rows and conservative rig-pose rows.
```

## Afternoon Update: Baked Harness Cleanup, Not Flag Promotion

The later pass explicitly rejected the "just set a brutal flag" path.

What changed:

- `scripts\Invoke-RealWorldScreenshots.ps1` now removes stale duplicate process-environment entries before setting or clearing an env var. This fixed a real harness bug where `-SetEnv NAME=` could leave an older `NAME=value` in the manifest/process environment.
- `scripts\Invoke-RealWorldScreenshots.ps1` now gives OpenMW 10 seconds for graceful shutdown after `CloseMainWindow()` instead of hard-killing after 2 seconds.
- `scripts\Invoke-ActorRenderingProof.ps1` no longer injects `OPENMW_FNV_PART_MATRIX_AUDIT=1` into every visual actor proof.
- `catalog\flat-world-proof-starts.json` no longer bakes `OPENMW_FNV_PART_MATRIX_AUDIT=1` into the FO3/FNV default start environments. Matrix audit remains available in the focused math path through `scripts\Invoke-ActorMathMatrix.ps1`.

Renderer experiments tried and rejected:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\baked-fnv-longgun-helper-both-20260708-1432\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\baked-fnv-longgun-attached-part-both-20260708-1448\actor-rendering-proof.json
```

Both no-override baked renderer attempts were unsafe. The helper mutation and later attached-part attitude path were reverted from `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`. Do not reintroduce a baked `-60`/`-90` weapon rotation in the attachment helper or `SceneUtil::attach` attitude path without a narrower transform proof and a crash stack.

Current visual-safe proof evidence after cleanup:

```text
D:\code\nikami-worlds\run\actor-rendering-proofs\visual-safe-default-fnv-close-20260708-1533\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\visual-safe-default-fnv-close-20260708-1533\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-140954\contact-sheet.png

FNV close-burst:
captured-native, six screenshots, crashReportCount=2, exitCode=-1073740791.
No OPENMW_FNV_WEAPON_ROTATION_Y in the manifest.
No OPENMW_FNV_PART_MATRIX_AUDIT in the manifest.
Target settlers GSSettlerAM and GSSettlerAAM pass limb anatomy in bulk.
Visual state: upright human actors, not limb explosions; weapon still reads like a low/vertical prop rather than a correctly held rifle.

D:\code\nikami-worlds\run\actor-rendering-proofs\visual-safe-default-fo3-close-20260708-1537\actor-rendering-proof.json
D:\code\nikami-worlds\run\actor-rendering-proofs\visual-safe-default-fo3-close-20260708-1537\screenshots\fallout3-close-burst\fallout3-20260708-141112\contact-sheet.png

FO3 close-burst:
captured-native, six screenshots, crashReportCount=0, exitCode=0.
No OPENMW_FNV_PART_MATRIX_AUDIT in the manifest.
Target Lucas Simms and Stockholm pass limb anatomy in bulk.
Visual state: upright human actors with visible animation, but arms/hands/weapon presentation is still not final.
```

Decision: the proof harness is now less noisy and more honest. Visual screenshot proofs should stay visual-safe by default; heavy part-matrix/FABRIK analysis belongs in focused math runs. The current renderer can show FNV and FO3 humans in-world, but the held-weapon problem is still unsolved and must be attacked as a hand/weapon transform problem, not as a global helper yaw flag.

Current promoted policy remains unchanged:

```text
fallout_new_vegas:
OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=0
OPENMW_FNV_WEAPON_IK=0
OPENMW_FNV_DISABLE_WEAPON_IK=1

fallout3:
OPENMW_ESM4_ENABLE_WEAPON_IDLE_POSE=1
```

## Pre-Breakthrough State (Historical)

External OpenMW tree:

- Measurement/audit patches are still active in `D:\Modlists\fnv\openmw-source`.
- Failed behavior experiment `0015-esm4-raw-actor-keyframe-composition.patch` was reversed from external source and rebuilt.
- Runtime was rebuilt after reversing `0015` and copied to `local\openmw-fo4guard\openmw.exe`.
- New behavior experiment `0016-esm4-refresh-cull-skin-to-skel.patch` exists in this repo and applies cleanly, but was not applied before reboot.

Important status command from before reboot:

```powershell
git -C D:\Modlists\fnv\openmw-source status --short components\sceneutil\riggeometry.cpp apps\openmw\mwrender\animation.cpp apps\openmw\mwrender\esm4npcanimation.cpp components\sceneutil\attach.cpp components\nifosg\controller.cpp
```

Expected current result:

```text
 M apps/openmw/mwrender/animation.cpp
 M apps/openmw/mwrender/esm4npcanimation.cpp
 M components/nifosg/controller.cpp
 M components/sceneutil/riggeometry.cpp
```

That dirty state is expected. It includes the overlay/audit work. Do not reset it.

Workspace state:

- Many repo files are modified or untracked from this larger effort.
- Do not revert broad changes.
- The new patch file is:

```text
patches/openmw/experiments/0016-esm4-refresh-cull-skin-to-skel.patch
```

It was checked with:

```powershell
git -C D:\Modlists\fnv\openmw-source apply --check D:\code\nikami-worlds\patches\openmw\experiments\0016-esm4-refresh-cull-skin-to-skel.patch
```

That returned success.

## Critical Visual Evidence

The currently useful FNV close-burst screenshot matrix is here:

```text
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052100
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052122
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052143
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052204
```

Contact sheets were generated:

```text
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052100\contact-sheet.png
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052122\contact-sheet.png
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052143\contact-sheet.png
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052204\contact-sheet.png
```

Visual reading:

- `052100`, `OPENMW_ESM4_SKINNING_MODE=invBindThenSkeleton`, `OPENMW_ESM4_USE_SKIN_TO_SKEL=1`:
  - Body still upside down.
  - Head/face detached.
  - Weapon free-floating.
  - But the telemetry from this run is the most important because live recomputation is good while render geometry is bad.
- `052122`, `skeletonThenInvBind`:
  - Worse. Giant smeared body geometry.
- `052143`, `skeleton`:
  - Bad. Same upside-down/free-floating family.
- `052204`, `bindThenSkeleton`:
  - Bad. Same family, with major mesh distortion.

Two earlier matrix modes failed at the harness/manifest level and should not be used as proof:

```text
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052021
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052032
```

These were not useful for promotion because one crashed/bad screenshot and one produced no readable screenshots.

## The Key Pattern

This is the pattern that matters. It is repeatable and not random:

- The hand render center is correct if evaluated in the immediate parent/part space.
- The same hand render center is wrong if evaluated through the full node path.
- The live recomputed skinning bounds are correct through the full path.

That means the data knows how to place the hand, but the last-frame render geometry is stale or baked in the wrong coordinate frame.

Example from:

```text
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-052100\openmw.log
```

Left hand pattern:

```text
renderParentDistance ~= 5
renderPathDistance   ~= 270
livePathDistance     ~= 6
```

Right hand pattern:

```text
renderParentDistance ~= 5
renderPathDistance   ~= 288
livePathDistance     ~= 6
```

Interpretation:

- `renderCenterParentWorld` being near the anchor says the baked render geometry can be correct in parent space.
- `renderCenterPathWorld` being far says the scene path is applying a transform that the geometry has already effectively absorbed, or the geometry was baked before the skin-to-skeleton matrix was refreshed for that path.
- `liveCenterPathWorld` being near the anchor says the current live recomputation is capable of producing the right path-space bounds.

This is why the next step is code, not config.

## Strongest Hypothesis

Patch target:

```text
D:\Modlists\fnv\openmw-source\components\sceneutil\riggeometry.cpp
```

Function:

```cpp
SceneUtil::RigGeometry::cull(osg::NodeVisitor* nv)
```

Hypothesis:

- `RigGeometry::cull` updates bone matrices and then writes into `getLastFrameGeometry()`.
- It selects `mSkinToSkelMatrix` later when building the skinning transform.
- But `mSkinToSkelMatrix` is not refreshed in `cull` for the current draw path.
- `computeCurrentFalloutSkinningBounds` does refresh `mSkinToSkelMatrix`, and that is why `liveCenterPathWorld` is good.
- Therefore, the actual render geometry is being generated from stale or missing skin-root-to-skeleton data.

Narrow experiment:

```cpp
mSkeleton->updateBoneMatrices(traversalNumber);
if (falloutRig)
    updateSkinToSkelMatrix(nv->getNodePath());
```

This is exactly what `0016` applies.

Patch file:

```text
patches/openmw/experiments/0016-esm4-refresh-cull-skin-to-skel.patch
```

Patch content:

```diff
diff --git a/components/sceneutil/riggeometry.cpp b/components/sceneutil/riggeometry.cpp
--- a/components/sceneutil/riggeometry.cpp
+++ b/components/sceneutil/riggeometry.cpp
@@ -643,6 +643,9 @@ namespace SceneUtil
         }
 
         mSkeleton->updateBoneMatrices(traversalNumber);
+        if (falloutRig)
+            updateSkinToSkelMatrix(nv->getNodePath());
+
 
 //## VR_PATCH BEGIN
         // Tracking in VR updates bone matrices out of order, and forces bounds to be recalculated during cull.
```

This is intentionally narrow. Do not combine it with `0015`. Do not also change attachment code in the first test.

## Why Morrowind Matters

Morrowind NPCs use the working control path:

```text
apps/openmw/mwrender/npcanimation.cpp
```

Relevant pattern:

```cpp
const std::string_view bonefilter = (type == ESM::PRT_Hair) ? std::string_view{ "hair" } : bonename;
mObjectParts[type] = insertBoundedPart(mesh, bonename, bonefilter, enchantedGlow, glowColor, isLight);
```

Then:

```cpp
osg::ref_ptr<osg::Node> attached = attach(model, bonename, bonefilter, isLight);
```

And generic `ActorAnimation::attach` calls:

```cpp
SceneUtil::attach(templateNode, mObjectRoot, bonefilter, found->second, sceneManager)
```

Morrowind gives `SceneUtil::attach` a meaningful filter and an attachment bone. It does not shove all rigged piece parts through the empty-filter Fallout rig copy path.

FO3/FNV ESM4 actor assembly is different:

```text
apps/openmw/mwrender/esm4npcanimation.cpp
components/sceneutil/attach.cpp
```

FO3/FNV currently uses many runtime wrappers named:

```text
FNV Part ...
```

The rigged empty-filter path in `SceneUtil::attach` does this:

- Finds `RigGeometry`.
- With empty filter, copies the rig drawable itself.
- Skips `Bip01` and `Scene Root` parents.
- Preserves some source state/path wrappers.
- Adds the copied rig to the selected master.

This can be useful for full body/outfit meshes, but it is risky for piece parts like hands, eyes, mouth, teeth, tongue, hair, beard, and eyebrows.

Do not rewrite this yet. First test `0016`. If `0016` fixes hands, the scene-copy path may be mostly okay and the stale cull matrix was the primary bug. If `0016` does not fix hands, then the next target is the empty-filter rig copy path in `components\sceneutil\attach.cpp`.

## First 30 Minutes In The Next Thread

Start here. Do not branch off into Starfield, VR, or broad refactors.

1. Confirm `0016` still applies:

```powershell
cd D:\code\nikami-worlds
git -C D:\Modlists\fnv\openmw-source apply --check D:\code\nikami-worlds\patches\openmw\experiments\0016-esm4-refresh-cull-skin-to-skel.patch
```

2. Apply `0016`:

```powershell
git -C D:\Modlists\fnv\openmw-source apply D:\code\nikami-worlds\patches\openmw\experiments\0016-esm4-refresh-cull-skin-to-skel.patch
```

3. Build only `openmw`:

```powershell
cmake --build D:\Modlists\fnv\openmw-source\MSVC2022_64 --config Release --target openmw
```

4. Copy the rebuilt executable into the local proof runtime:

```powershell
Copy-Item -LiteralPath D:\Modlists\fnv\openmw-source\MSVC2022_64\Release\openmw.exe -Destination D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe -Force
```

5. Run the first piecewise proof: FNV hands/body with the same mode that produced the strongest live-vs-render contradiction.

```powershell
.\scripts\Invoke-RealWorldScreenshots.ps1 `
  -Mode flat `
  -WorldId fallout_new_vegas `
  -StartSlice goodsprings-settler-actor-close-burst `
  -UseActorAnimationPolicyEnvironment `
  -SetEnv OPENMW_ESM4_USE_SKIN_TO_SKEL=1,OPENMW_ESM4_SKINNING_MODE=invBindThenSkeleton,OPENMW_FNV_PART_MATRIX_AUDIT=1
```

6. Generate contact sheet from the new manifest:

```powershell
.\scripts\New-ScreenshotContactSheet.ps1 -ManifestPath <NEW_MANIFEST_PATH> -Columns 3 -ThumbnailWidth 360
```

7. Visually inspect the contact sheet.

Acceptable first-pass result:

- Hands are no longer 270-288 units away from anchors.
- Body is not exploded into giant stretched geometry.
- Character may still not be perfect; this is a piecewise proof.

Reject result:

- Same upside-down detached hand/body pattern.
- Giant smeared body geometry.
- One-color screenshots.
- Missing screenshots.

8. Measure the same run:

```powershell
.\scripts\Measure-ActorPartTelemetry.ps1 -ManifestPath <NEW_MANIFEST_PATH> -OutputPath run\audit\0016-fnv-actor-part-telemetry.jsonl
.\scripts\Measure-ActorRenderLiveTelemetry.ps1 -ManifestPath <NEW_MANIFEST_PATH> -OutputPath run\audit\0016-fnv-render-live-telemetry.jsonl
.\scripts\Measure-ActorFaceAttachmentTelemetry.ps1 -ManifestPath <NEW_MANIFEST_PATH> -OutputPath run\audit\0016-fnv-face-attachment-telemetry.jsonl
.\scripts\Measure-ActorRootAttachmentTelemetry.ps1 -ManifestPath <NEW_MANIFEST_PATH> -OutputPath run\audit\0016-fnv-root-attachment-telemetry.jsonl
```

9. If `0016` fails visually, reverse it immediately:

```powershell
git -C D:\Modlists\fnv\openmw-source apply -R D:\code\nikami-worlds\patches\openmw\experiments\0016-esm4-refresh-cull-skin-to-skel.patch
cmake --build D:\Modlists\fnv\openmw-source\MSVC2022_64 --config Release --target openmw
Copy-Item -LiteralPath D:\Modlists\fnv\openmw-source\MSVC2022_64\Release\openmw.exe -Destination D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe -Force
```

10. If `0016` improves hands, do not immediately declare victory. Next run FO3 with the same experiment:

```powershell
.\scripts\Invoke-RealWorldScreenshots.ps1 `
  -Mode flat `
  -WorldId fallout3 `
  -StartSlice megaton-entrance-lucas-actor-close-burst `
  -UseActorAnimationPolicyEnvironment `
  -SetEnv OPENMW_ESM4_USE_SKIN_TO_SKEL=1,OPENMW_ESM4_SKINNING_MODE=invBindThenSkeleton,OPENMW_FNV_PART_MATRIX_AUDIT=1
```

Then generate the contact sheet and inspect.

## If 0016 Works

If the piecewise FNV hand/body proof improves:

1. Keep `0016` applied only as an experiment.
2. Add visual review rows for the before/after.
3. Re-run the same FNV slice in policy/default mode to decide whether the policy catalog needs to change or the code needs a default.
4. Run FO3 close burst.
5. Run Oblivion and Skyrim actor slices as regression gates.
6. Run Morrowind as the control gate.
7. Only then promote the code from `patches/openmw/experiments` into the main overlay series.

Likely follow-up if it works only with env overrides:

- The policy/default for FO3/FNV probably needs to set:

```text
OPENMW_ESM4_USE_SKIN_TO_SKEL=1
OPENMW_ESM4_SKINNING_MODE=invBindThenSkeleton
```

But do not set that globally until FO4/Oblivion/Skyrim regressions are checked.

## If 0016 Fails

If `0016` does not fix the hands/body:

Next patch target becomes:

```text
D:\Modlists\fnv\openmw-source\components\sceneutil\attach.cpp
```

Specifically:

```cpp
CopyRigVisitor::apply(osg::Drawable& drawable)
```

Current risk area:

```cpp
if (mFilter.empty())
{
    CopyItem item;
    item.mNode = node;
    for (osg::Node* parent : getNodePath())
    {
        const std::string& name = parent != nullptr ? parent->getName() : std::string();
        if (Misc::StringUtils::ciStartsWith(name, "Bip01")
            || Misc::StringUtils::ciEqual(name, "Scene Root"))
            continue;
        if (parent != nullptr && (parent->getStateSet() != nullptr || parent->getUserDataContainer() != nullptr
                || dynamic_cast<const osg::MatrixTransform*>(parent) != nullptr
                || dynamic_cast<const osg::PositionAttitudeTransform*>(parent) != nullptr))
            item.mStatePath.emplace_back(parent);
    }
    mToCopy.emplace_back(std::move(item));
    return;
}
```

Hypothesis if `0016` fails:

- The copied rig drawable is correct.
- The preserved non-skeleton `mStatePath` wrappers include transforms that are appropriate in the source part NIF but wrong once the drawable is copied onto the actor skeleton.
- That would explain why immediate parent-space looks good while full path-space is wrong.

Next experiment shape if needed:

- Add an env-gated mode such as `OPENMW_ESM4_DROP_RIG_PART_STATE_PATH=1`.
- When enabled and `mFilter.empty()`, copy rig drawable state/material data, but do not preserve `MatrixTransform` or `PositionAttitudeTransform` wrappers for actor part rigs.
- Keep it env-gated first.
- Test only hands first.

Do not make this blanket behavior until Morrowind and Oblivion are checked. Morrowind uses non-empty filters, so it should not hit the empty-filter branch, but still prove it.

## Failed Experiment To Remember

`0015-esm4-raw-actor-keyframe-composition.patch`

Result:

- Built cleanly.
- Reduced actor basis telemetry large rotation deltas to zero.
- Did not fix visuals.
- FNV and FO3 remained upside down/disassembled.

Key proof:

```text
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-043645\contact-sheet.png
D:\code\nikami-worlds\run\real-world-screenshots\fallout3-20260708-043720\contact-sheet.png
```

Do not reapply `0015` together with `0016`. It is diagnostic evidence, not a promoted fix.

## Useful Earlier Proof Artifacts

Baseline after measurement patches, before `0015`:

```text
D:\code\nikami-worlds\run\real-world-screenshots\fallout3-20260708-042144\contact-sheet.png
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-042213\contact-sheet.png
```

Freeze/no-seed FNV probe:

```text
D:\code\nikami-worlds\run\real-world-screenshots\fallout_new_vegas-20260708-042556\contact-sheet.png
```

Result:

- Disabling idle seed/freezing idle animation did not fix the upside-down actor.
- So this is not just idle-time drift.

Important ledgers:

```text
run\audit\focused-20260708-0422-screenshot-evidence.jsonl
run\audit\focused-20260708-0422-actor-runtime-warnings.jsonl
run\audit\focused-20260708-0422-rig-pose-sanity.jsonl
run\audit\focused-20260708-0422-actor-part-telemetry.jsonl
run\audit\focused-20260708-0422-actor-render-live-telemetry.jsonl
run\audit\focused-20260708-0422-actor-face-attachment-telemetry.jsonl
run\audit\focused-20260708-0422-actor-basis-telemetry.jsonl
run\audit\focused-20260708-0422-actor-root-attachment-telemetry.jsonl
run\audit\focused-20260708-0436-0015-root-attachment-telemetry.jsonl
run\audit\focused-20260708-0436-0015-actor-basis-telemetry.jsonl
run\audit\focused-20260708-0436-0015-actor-part-telemetry.jsonl
run\audit\focused-20260708-0436-0015-actor-face-attachment-telemetry.jsonl
run\audit\focused-20260708-0436-0015-rig-pose-sanity.jsonl
run\audit\focused-20260708-0436-0015-render-live-telemetry.jsonl
```

The `0015` actor basis ledger passing is useful only diagnostically. It means one basis issue existed, but not the one causing the visible assembly failure.

## Harness Notes

Main real screenshot runner:

```text
scripts\Invoke-RealWorldScreenshots.ps1
```

Important features:

- Non-VR path is `-Mode flat`.
- `-StartSlice` selects catalog proof starts.
- Camera sequences are already catalog-driven.
- One executable launch can capture multiple native screenshots.
- The Goodsprings/FNV close burst captures six frames in one run.

Useful actor proof slices:

```text
fallout_new_vegas: goodsprings-settler-actor-close-burst
fallout3:          megaton-entrance-lucas-actor-close-burst
oblivion:          imperial-city-palace-actor-close-orbit-burst
fallout4:          exterior-sanctuary-codsworth-actor-close-burst
```

Sweep wrapper:

```text
scripts\Invoke-ProofHarnessSweep.ps1
```

The sweep is useful, but one important bug/limitation showed up:

- If an early mode produces no readable screenshots, contact sheet generation can throw and stop later measurement.
- For focused experiments, prefer direct `Invoke-RealWorldScreenshots.ps1` runs plus manual contact sheet generation.

Contracts that should pass before promoting:

```powershell
.\scripts\Test-ProofHarnessSweepContract.ps1
.\scripts\Test-ProofHarnessUiContract.ps1
.\scripts\Test-WorldAuditContract.ps1
```

Known harness improvements requested by user but not yet implemented:

- Add runner-level close/orbit/burst convenience params instead of requiring JSON edits.
- Let sweep pass screenshot/capture overrides through to the runner.
- Make visual review include all burst images, not just first screenshot.
- Normalize brittle absolute paths where possible.

Do not do harness ergonomics before testing `0016`. The next highest-value move is renderer proof.

## Branch And Online Archaeology

Local branch archaeology found useful commits:

```text
D:\code\vulkanOpenMW\nikami-openmw-lab-publish
branch: nikami/fnv-actor-truth-rig
commit: 6d23344d2c Promote FNV actor truth rig basis
```

Important commit:

```text
4d7450c412 Fix FNV actor pose basis and sleeve skinning
```

That became `0015`, but the visual result failed.

Important branch:

```text
D:\code\vulkanOpenMW\madsbuvi-esm4-texture-flat
commit: 8d7218c118 Take skin transform and skeleton root into account
```

That skin/root transform work is already present in the current external OpenMW source:

```text
components\nifosg\nifloader.cpp
components\sceneutil\riggeometry.cpp
components\sceneutil\riggeometry.hpp
```

So do not make the next experiment a clean transplant of `8d7218c118`. It is already there.

Online/public sweep:

- Official OpenMW public branches did not expose an obvious ready-made FO3/FNV actor fix.
- Public OpenMW release material treats beyond-Morrowind support as early/experimental.
- Initial NPC rendering in the public line appears oriented around Oblivion, Skyrim 2011, and Fallout 4 rather than FO3/FNV.

Conclusion:

- We are probably on our own for FO3/FNV actor assembly.
- Use local evidence and proof harness, not wishful upstream archaeology.

## Piecewise Order

Do not jump straight to whole-world pass.

Use this order:

1. Hands
   - Best current numeric signal.
   - Render parent good, render path bad, live path good.
   - First test target for `0016`.

2. Face parts
   - Mouth, teeth, tongue, eyes, hair, beard, eyebrows.
   - Current distances are often 58-65 units from head where limits are 22-56.
   - If hands fix but face stays wrong, target face-specific staticized/head-frame offsets next.

3. Body/outfit
   - Body sometimes reports OK by distance but is visibly upside down.
   - Needs visual judgement, not just distance.

4. Weapon
   - Often anchor-distance OK while visual can still float due actor/body being wrong.
   - Do not chase weapon before hands/body.

5. Whole actor
   - Close burst from multiple angles.
   - Must be visually serviceable.

6. Whole game
   - FNV.
   - FO3.
   - Oblivion/Skyrim regression.
   - Morrowind control.
   - Fallout 4 regression.

## Promotion Rule

An experiment can move from `patches/openmw/experiments` toward the real overlay only when:

- It builds.
- It has close native screenshots.
- Contact sheet is visually serviceable.
- Relevant telemetry improves.
- It does not regress Morrowind control.
- It does not regress Oblivion/Skyrim actor proof.
- It does not rely on Starfield.
- Failed behavior experiments are reversed from external source before stopping.

## 2026-07-08 Midday Reality Check

The old isolated viewer was found and used:

```text
D:\code\vulkanOpenMW\nikami-openmw-lab-publish
commit: 04c3d88aab Add FNV native asset studio controls
```

What carried forward:

- Current-pose rig refresh from the isolated viewer helped first-frame FNV actor preview geometry.
- The old viewer's raw actor-rotation-basis behavior did not port cleanly; a raw-basis FNV current proof looked worse, so do not flip the current runtime wholesale to that path.
- The correct measuring frame is target actors, not Player/stale actor rows. `scripts\Measure-ActorProofStatus.ps1` now reports target rows separately from all rows.
- `scripts\Measure-RigPoseSanity.ps1` now treats modest animated hand bind offsets as pass when extents, vertex deltas, and outliers are sane.

Keeper evidence from this pass:

- FNV current-skinning light proof: `run\actor-rendering-proofs\fnv-current-stability-light-audit-20260708-1030\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-101033`
  - Six native screenshots captured.
  - Front and side neutral-preview views show coherent animated human actors with weapons.
  - Target runtime passes for `FormId:0x1104f02` and `FormId:0x1104f07`.
  - Target limb anatomy passes: `FormId:0x1104f07` 1525 rows, `FormId:0x1104f02` 1522 rows.
  - Proof status remains `questionable` because render/live telemetry still sees invalid-to-valid transitions and heavy rig rows were intentionally omitted for stability.

- FO3 auto-skinning light proof: `run\actor-rendering-proofs\fo3-current-stability-light-audit-20260708-1035\screenshots\fallout3-close-burst\fallout3-20260708-101219`
  - Six native screenshots captured with exit code 0.
  - Target runtime passes for Lucas Simms and Stockholm.
  - Target limb anatomy passes: Lucas Simms 2396 rows, Stockholm 2393 rows.
  - Visual proof is not serviceable yet: the capture is not a readable full-body human preview. Treat FO3 as math-good but visual-still-open.

Important negative result:

- The attempted `refreshFalloutSkinningForCurrentPose()` bounding-callback update correlated with crashy FNV captures and was reversed. Do not reintroduce it without a crash stack or a narrower test.
- Heavy draw/matrix audit can destabilize FNV proof capture. Use light native proofs for visual confirmation, then run focused ledgers separately.

## 2026-07-08 Afternoon IK/Rotation Pass

What changed after the midday checkpoint:

- `scripts\Invoke-ActorMathMatrix.ps1` now includes basis telemetry and focused rotation/IK cases.
- `scripts\Measure-ActorFabrikTelemetry.ps1` now creates an empty output file instead of silently leaving the expected ledger path absent when no rows are found.
- `catalog\actor-animation-policy.json` now sets FO3 to:
  - `OPENMW_ESM4_ACTOR_ROTATION_COMPOSITION=raw`
  - `OPENMW_ESM4_STANDING_ARM_IK=1`
- `catalog\actor-animation-policy.json` now sets FNV to:
  - `OPENMW_ESM4_STANDING_ARM_IK=1`
- The repo-local runtime resource and source resource `scripts/omw/cellhandlers.lua` now disable the stock Morrowind fish-spawn exterior handler. Without that, FNV crashed before native proof capture inside the stock Lua exterior handler path.

Math/visual evidence:

- FO3 rotation matrix: `run\actor-math-matrix\fo3-rotation-basis-20260708-1335`
  - Baseline and runtime rotation-mode sweeps kept 244 large actor-basis deltas.
  - `controller-raw` reduced large actor-basis deltas to 0 while root attachment stayed pass.
  - Visual-only `controller-raw` was not enough: arms/weapon still looked wrong.

- FO3 arm IK matrix: `run\actor-math-matrix\fo3-arm-ik-20260708-1355`
  - `controller-raw-standing-arm-ik` kept basis pass with 0 large deltas and pulled the arms down.
  - `standing-arm-ik` without controller raw crashed after capture in one narrow run.

- FO3 policy proof: `run\actor-rendering-proofs\fo3-policy-raw-armik-close-burst-20260708-1410\screenshots\fallout3-close-burst\fallout3-20260708-104115`
  - Six native screenshots captured.
  - Exit code 0, no crash reports.
  - Actor-basis telemetry passes with 0 large rotation deltas.
  - Root and face attachment telemetry pass.
  - Target Lucas Simms and Stockholm limb anatomy pass in bulk.
  - Visual state is improved but not final: actors read as upright people, arms are no longer exploded overhead, but close panes still show hand/weapon/skin-strip artifacts.

- FNV policy proof: `run\actor-rendering-proofs\fnv-policy-arm-ik-close-burst-20260708-1510\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-104906`
  - Six native screenshots captured through catalog policy, no explicit arm env.
  - The proof dirty-exited after capture with `-1073740791` and crash reports, consistent with earlier FNV instability.
  - Visual state is improved: actors are upright with arms down and weapon carried low instead of overhead.

Current truth:

- FNV: visible, animated, human-shaped close-burst and walkaround actors are now achievable through policy with clean exits when neutral/no-IK is explicit. Weapon handling is not final.
- FO3: visible, animated, human-shaped close-burst and walkaround actors are now achievable through the stable weapon-idle policy with clean exits. Neutral idle is a close-burst candidate only because its walkaround run dirty-exits after capture.
- Next work should target stable hand/weapon orientation with the weapon-IK math ledger and visual proof harness, not whole-body attach or bind-pose assembly. The `weapon-ik-low-ready-auto-hand` diagnostic is useful evidence but not a keeper.

## Afternoon Update: Baked Weapon Mesh Runtime Harness and FNV Long-Gun Offhand IK

This pass replaced the loose weapon-orientation flag loop with baked renderer telemetry and a narrow runtime fix.

Code changes:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`
  - Added `World viewer actor weapon mesh ledger` rows for carried weapons.
  - The ledger now records insert and runtime phases, visible mesh bounds, mesh major axis, hand-to-visible-weapon distances, and weapon-frame-to-visible-center distance.
  - Added a baked FNV long-gun synthetic `Weapon` frame stabilizer. It keeps the weapon at the right-hand frame but rotates the synthetic helper so weapon local `+X` stays actor-forward with a slight low-ready drop instead of inheriting hand roll as a limb twist.
  - Added a baked FNV long-gun offhand IK pass. It targets the actual visible rifle fore-end from runtime mesh bounds, solves only the left arm with two-bone FABRIK, preserves hand roll, and does not enable the old global weapon IK path.
- `scripts\Measure-ActorWeaponMeshTelemetry.ps1`
  - New measured ledger: `actor-weapon-mesh-telemetry.jsonl`.
  - Scores runtime rows when present and retains insert rows for diagnosis.
  - Long guns now fail if the offhand is detached or the major axis is vertical.
- The actor proof wrapper, sweep runner, sweep refresher, proof-status combiner, and sweep contract all include the new weapon-mesh ledger.

Evidence:

- FNV keeper proof after baked frame stabilizer plus offhand IK:
  `run\actor-rendering-proofs\fnv-baked-offhand-ik-20260708\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-144604`
  - Six native screenshots captured.
  - Exit code 0, crash reports 0.
  - Varmint Rifle runtime major axis is now stable low-ready: `majorActorDots forward≈0.984, right≈0, up≈-0.177`.
  - Varmint Rifle left hand to visible weapon center improved from construction `99.799` and runtime default `~35-46` down to `~12-20`.
  - Weapon mesh status remains `questionable` only because sidearm rows still raise `actor-weapon-major-axis-vertical`; the long-gun failure is gone.
- FO3 control proof after the FNV-specific change:
  `run\actor-rendering-proofs\fo3-after-fnv-offhand-ik-20260708\screenshots\fallout3-close-burst\fallout3-20260708-144726`
  - Six native screenshots captured.
  - Exit code 0, crash reports 0.
  - Weapon mesh telemetry passes.

Current truth:

- FNV now has a clean close-burst proof with baked long-gun frame stabilization and left-arm offhand IK. This is real code, not a promoted yaw flag.
- The old global `OPENMW_FNV_WEAPON_IK` path is still not default policy. The new offhand pass is independent of that path and targets visible weapon geometry directly.
- Remaining weapon work is sidearm orientation/hand presentation and broader walkaround proof, not basic long-gun axis or offhand detachment.

## Afternoon Update: Sidearm Frame Stabilizer and Baked UI Relay Fix

This pass continued the "real code and data analysis" path and removed one dead proof flag instead of adding another launch switch.

Code changes:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`
  - Added a baked FNV sidearm synthetic `Weapon` frame stabilizer.
  - It keeps the sidearm at the right-hand frame and rotates local `+X` actor-forward with a low-ready drop, matching the long-gun stabilizer pattern without enabling the old global weapon IK path.
- `D:\Modlists\fnv\openmw-source\files\data\scripts\omw\ui.lua`
- `D:\code\nikami-worlds\local\openmw-fo4guard\resources\vfs\scripts\omw\ui.lua`
  - Sanitized the built-in `UiModeChanged` relay payload so raw UI target/userdata values are not pushed through local-event serialization.
  - Wrapped the relay with `pcall`; a bad UI relay can log and continue instead of crashing an exterior actor proof before native screenshots.
- `scripts\Invoke-ActorRenderingProof.ps1`
  - Removed stale `OPENMW_ESM4_DISABLE_MW_CELL_HANDLERS=1` from the keeper audit environment. The fish-spawner compatibility fix is already baked into `scripts/omw/cellhandlers.lua`, so the harness should not pretend that dead flag is doing work.

Evidence:

- FNV sidearm close-burst repeat:
  `run\actor-rendering-proofs\fnv-baked-sidearm-frame-stabilizer-repeat-20260708\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-145742`
  - Six native screenshots captured.
  - Exit code 0, crash reports 0.
  - Weapon mesh telemetry passes with 10 rows / 8 runtime rows.
  - `WeapNV357Revolver` runtime major axis is actor-forward low-ready: `majorActorDots forward=0.963, right=0, up=-0.2696`.
  - Revolver right hand to visible weapon center is about `7.87`; sidearm left-hand distance is ignored by the scorer.
- FNV sidearm walkaround after UI relay hardening:
  `run\actor-rendering-proofs\fnv-baked-ui-relay-sidearm-walkaround-20260708\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-150417`
  - Four native screenshots captured.
  - Exit code 0, crash reports 0.
  - Weapon mesh telemetry passes with 10 rows / 8 runtime rows.
  - The prior crash boundary was `scripts/omw/ui.lua:135` during `self:sendEvent('UiModeChanged', ...)`; after payload sanitizing, the same walkaround case captures natively.
- FO3 post-change walkaround regression:
  `run\actor-rendering-proofs\fo3-post-ui-relay-sidearm-walkaround-20260708\screenshots\fallout3-walkaround\fallout3-20260708-150520`
  - Four native screenshots captured.
  - Exit code 0, crash reports 0.
  - Weapon mesh telemetry passes with 10 rows / 8 runtime rows.
- Harness contracts still pass:
  - `.\scripts\Test-ProofHarnessSweepContract.ps1`
  - `.\scripts\Test-ProofHarnessUiContract.ps1`

Current truth:

- FNV and FO3 now have clean native walkaround proofs after the baked sidearm/UI-relay changes.
- FNV target actor weapon meshes are no longer vertical: long gun and sidearm runtime rows both score pass.
- This is not done. Overall actor proof status still fails because the combined scorer still includes player/non-target runtime gaps, FNV has `actor-pose-invalid`, FO3 has `actor-runtime-gap`, and both worlds still need stronger visual-review evidence.
- Next work should keep following this pattern: bake the invariant into renderer/runtime/script code, measure it from native runtime rows, and only then improve the visual camera/proof framing.

## Evening Update: Baked Teardown Order, Bounded Pose Scoring, and Walkaround Reality Check

This pass continued the same direction: no broad "brutal flag" sweep. The useful changes are code and scorer changes backed by exact ledgers.

Code/scorer changes:

- `D:\Modlists\fnv\openmw-source\apps\openmw\engine.cpp`
  - Replaced the proof loading-GUI clear path with a logical proof-ready state instead of mutating Lua UI modes during capture. This avoided firing the fragile `UiModeChanged` relay at the close-burst capture boundary.
  - Moved `mResourceSystem.reset()` before viewer/VR/window teardown in `OMW::Engine::~Engine()`. The crash breadcrumb showed post-capture shutdown dying after `xr-instance` and before `resource-system`; the new order drops actor/resource caches while the viewer/window context is still alive.
  - Added temporary teardown breadcrumbs around the manager destruction sequence. These should be kept until the shutdown crash stays gone across more sweeps, then trimmed.
- `scripts\Measure-RigPoseSanity.ps1`
  - Added bounded animated-pose acceptance for human arms, human heads, and creature rigs. This turns known-good animated skinning deltas into measured pass rows instead of treating every non-zero pose as explosion.
- `scripts\Measure-ActorPartTelemetry.ps1`
  - Counts `runtime-fnv-frame-rig-refresh` and runtime weapon-mesh telemetry rows as runtime frame evidence.
- `catalog\flat-world-proof-starts.json`
  - Added first-person camera settle for the FNV walkaround slice. This improves Goodsprings readability without changing actor math.

Evidence:

- FO3 walkaround after resource-system-before-viewer teardown:
  `run\actor-rendering-proofs\fo3-resource-before-viewer-walkaround-20260708\screenshots\fallout3-walkaround\fallout3-20260708-153757`
  - Four native screenshots captured.
  - Exit code 0, crash reports 0.
  - Log reaches `engine teardown resource-system`, `engine teardown viewer`, and `Quitting peacefully`.
  - Target runtime, rig pose, part telemetry, root attachment, weapon mesh, and target limb anatomy all pass.
  - Visual review is `questionable`: Megaton and an upright moving human actor are visible, but the actor is too low/small in frame.
- FNV walkaround after the same teardown change:
  `run\actor-rendering-proofs\fnv-resource-before-viewer-walkaround-20260708\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-153853`
  - Four native screenshots captured.
  - Exit code 0, crash reports 0.
  - Log reaches `engine teardown resource-system`, `engine teardown viewer`, and `Quitting peacefully`.
  - Target runtime, rig pose, part telemetry, root attachment, weapon mesh, and target limb anatomy all pass.
  - Visual review is `pass`: Goodsprings actor is upright and walking/settling by the doorway across the sequence.
- Harness contracts still pass:
  - `.\scripts\Test-ProofHarnessSweepContract.ps1`
  - `.\scripts\Test-ProofHarnessUiContract.ps1`

Current truth:

- Yes, we are making real progress. FO3 and FNV now both run native walkaround proofs with visible in-world humans, clean exit, zero crash reports, target limb anatomy pass, and target weapon mesh pass.
- This is not yet a final green proof. Overall proof status remains `questionable`, not `pass`, because `actor-render-live-telemetry` is still missing, non-target/player rows still produce `actor-runtime-gap` and non-target limb warnings, and FO3 needs better walkaround camera framing.
- The next highest-value work is to bake render/live telemetry from the actual drawable hand/head/weapon nodes and then tighten the FO3 camera/readability. Do not go back to root-yaw/up-axis flag sweeps.

## Late Update: Baked Render/Live Hand Geometry Telemetry

This pass moved the render/live hand-geometry rows out of the old `OPENMW_FNV_PART_MATRIX_AUDIT` diagnostic-only path and into the existing proof actor telemetry path.

Code changes:

- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`
  - Added `shouldAuditFalloutActorRenderLiveGeometry()`.
  - Split verbose part-matrix dumps from the hand render/live rows the scorer needs.
  - Calls `auditFalloutRuntimeParts(..., true)` from the outer runtime actor path, so native Fallout animation callbacks no longer bypass render/live telemetry.
  - The old matrix dump remains gated; proof hand geometry telemetry is now baked into actor telemetry/root/upper audit mode.

Evidence:

- FNV walkaround after baked render/live emitter:
  `run\actor-rendering-proofs\fnv-baked-render-live-outer-walkaround-20260708\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-154826`
  - Four native screenshots captured.
  - Exit code 0, crash reports 0.
  - Target runtime, rig pose, part telemetry, root attachment, weapon mesh, target limb anatomy, and visual review pass.
  - Render/live telemetry is now present but `questionable`: 84 rows, 60 render-good, 20 live-good, 24 render-invalid, `renderInvalidRatio=0.2857`, warning `actor-render-live-transition`.
  - This means the next FNV issue is not "no data"; it is a real render-buffer freshness/transition issue on some hand geometry, especially the player's Pip-Boy glove path.
- FO3 walkaround after baked render/live emitter:
  `run\actor-rendering-proofs\fo3-baked-render-live-outer-walkaround-20260708\screenshots\fallout3-walkaround\fallout3-20260708-154934`
  - Four native screenshots captured.
  - Exit code 0, crash reports 0.
  - Target runtime, rig pose, part telemetry, render/live telemetry, root attachment, weapon mesh, and target limb anatomy all pass.
  - Render/live telemetry passes with 48 rows, 48 render-good, `renderInvalidRatio=0`.
  - Visual review remains `questionable` only because the Megaton camera frames the actor too low/small.
- Harness contracts still pass after the engine/code changes:
  - `.\scripts\Test-ProofHarnessSweepContract.ps1`
  - `.\scripts\Test-ProofHarnessUiContract.ps1`

Current truth:

- FO3 is now mechanically strong in the walkaround proof: native capture, clean shutdown, render/live pass, target limbs pass, target weapon pass. Remaining FO3 work is mostly camera/readability and non-target/player warning cleanup.
- FNV is also rendering upright animated humans in native walkaround frames, with target limbs and target weapon pass. Remaining FNV work is the newly exposed `actor-render-live-transition` on hand geometry plus non-target/player warning cleanup.
- The next renderer-side move should inspect why `SceneUtil::RigGeometry` live pose is good while `getLastFrameGeometry()`/render buffers are intermittently invalid for the FNV player glove. That is the right "treat an arm like an arm" problem now.

## Latest Update: Baked Defaults and Renderer Shutdown Cleanup

This is the current authoritative state for the next handoff. The important change is that the former FO3/FNV actor policy is no longer a pile of launch flags. The renderer now bakes the useful defaults into code and leaves only proof telemetry/audit variables in the harness.

Code changes now baked into the external OpenMW source:

- `D:\Modlists\fnv\openmw-source\components\sceneutil\riggeometry.cpp`
  - Fallout character skinning is explicit on actor rigs via `setFalloutCharacterSkinning(true)`.
  - Fallout rig skinning defaults to `invBindThenSkeleton` without requiring `OPENMW_ESM4_SKINNING_MODE`.
  - The old broad heuristic is no longer the normal path; marker-based actor rigs drive the behavior.
- `D:\Modlists\fnv\openmw-source\components\nifosg\controller.cpp`
  - Fallout actor key translations default to dropped for cloned actor controllers.
  - FO3 actor controller rotation composition defaults to raw composition through the real actor context path.
- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\animation.cpp`
  - Fallout NPC context now defaults helper-controller skipping, FO3 weapon idle, and standing arm/leg IK in code.
- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\esm4npcanimation.cpp`
  - Fallout actor rig geometries are marked as Fallout character skinning rigs.
  - FO3 weapon idle and rigged hand staticization are baked for the relevant FO3/FNV human parts.
- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\objects.cpp`
  - Added a real `Objects::clear()` path that removes live animations, listeners, and scene parents safely.
- `D:\Modlists\fnv\openmw-source\apps\openmw\mwrender\renderingmanager.cpp`
  - Added `RenderingManager::clearLiveObjectsForShutdown()` to detach camera/player/proxy animations and clear live object animations before renderer member destruction.
- `D:\Modlists\fnv\openmw-source\apps\openmw\mwworld\worldimp.cpp`
  - World teardown now clears live render objects between scene destruction and rendering manager reset.

Policy/harness changes:

- `catalog\actor-animation-policy.json`
  - FO3/FNV no longer carry the old baked-switch environment for skinning, helper skipping, IK, weapon idle, hand staticization, actor rotation composition, bind pinning, or key translation dropping.
  - FO3/FNV only keep proof-level `OPENMW_WORLD_VIEWER_NPC_ANIMATION_SOURCES` and `OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY`.
- `scripts\Test-ProofHarnessUiContract.ps1`
  - Updated to require the real proof telemetry/NPC animation source env, not the old `OPENMW_ESM4_SKINNING_MODE` switch.

Build:

```powershell
cmake --build D:\Modlists\fnv\openmw-source\MSVC2022_64 --config Release --target openmw
Copy-Item D:\Modlists\fnv\openmw-source\MSVC2022_64\Release\openmw.exe D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe -Force
```

The copied runtime is `D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe`, size `25904128`, timestamp `2026-07-08 16:27:20`.

Clean baked-default proof evidence after the renderer cleanup:

- FNV close-burst:
  `run\actor-rendering-proofs\baked-render-cleanup-fnv-close-20260708\screenshots\fallout_new_vegas-close-burst\fallout_new_vegas-20260708-162739`
  - Six native screenshots.
  - Exit code 0, crash reports 0.
  - Log reaches `world teardown render-live-clear`, `world teardown rendering`, and `Quitting peacefully`.
  - Target runtime, render/live, root, weapon mesh, and target limb anatomy pass.
  - Visual review is `questionable`: upright animated Goodsprings settler, no T-pose/explosion, but weapon/hand posture is not final.
- FO3 close-burst:
  `run\actor-rendering-proofs\baked-render-cleanup-fo3-close-20260708\screenshots\fallout3-close-burst\fallout3-20260708-162937`
  - Six native screenshots.
  - Exit code 0, crash reports 0.
  - Log reaches `world teardown render-live-clear`, `world teardown rendering`, and `Quitting peacefully`.
  - Target runtime, render/live, root, weapon mesh, and target limb anatomy pass.
  - Visual review is `questionable`: upright animated Megaton actors, but close arm/weapon posture is visibly wrong.
- Combined FNV/FO3 walkaround:
  `run\actor-rendering-proofs\baked-render-cleanup-walkaround-20260708`
  - FNV manifest:
    `run\actor-rendering-proofs\baked-render-cleanup-walkaround-20260708\screenshots\fallout_new_vegas-walkaround\fallout_new_vegas-20260708-163127\manifest.json`
  - FO3 manifest:
    `run\actor-rendering-proofs\baked-render-cleanup-walkaround-20260708\screenshots\fallout3-walkaround\fallout3-20260708-163210\manifest.json`
  - Both captured four native screenshots.
  - Both exit code 0, crash reports 0.
  - Both target runtime/render-live/root/weapon/limb ledgers pass.
  - Visual review is `questionable` for both because the walkaround frames prove upright animated in-world humans but remain distance-framed and do not settle the hand/weapon issue.

Contract/test status after the baked-default proofs:

```powershell
.\scripts\Test-ProofHarnessSweepContract.ps1
.\scripts\Test-ProofHarnessUiContract.ps1
.\scripts\Test-WorldAuditContract.ps1
```

All passed. JSON validation also passed for:

- `catalog\actor-animation-policy.json`
- `catalog\world-audit-contract.json`
- `catalog\flat-world-proof-starts.json`
- `catalog\proof-harness-ui-contract.json`
- `catalog\proof-harness-sweeps.json`

Current truth:

- Yes, FO3 and FNV now render upright, coherent, animated people in native close-burst and walkaround proofs with clean exits under baked code defaults.
- This is real progress and no longer depends on the old brutal actor flags.
- This is still not final animation approval. Overall proof status remains `questionable`, not `pass`, because player/non-target runtime and limb warnings still exist, rig-pose sanity is not populated in these latest runs, and close visual review still shows arm/weapon posture problems.
- Next work should stay in code/data analysis: improve real hand/weapon orientation and player/non-target cleanup using the FABRIK, limb, weapon-mesh, and render/live ledgers. Do not go back to broad root-yaw/up-axis or policy-flag sweeps.

## Short Prompt For The Next Thread

Paste this at the start of the next thread:

```text
We are continuing the Nikami Worlds OpenMW ESM4 actor rendering proof. Read docs/reboot-handoff-20260708-openmw-actor-rendering.md first and treat the "Latest Update: Baked Defaults and Renderer Shutdown Cleanup" section as authoritative. Non-VR only. External source is D:\Modlists\fnv\openmw-source. Runtime is D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe. The old FO3/FNV policy switches for skinning mode, helper-controller skipping, key translation dropping, actor rotation composition, weapon idle, staticized hands, and standing IK have been baked into real OpenMW code. Current catalog policy for FO3/FNV keeps only NPC animation sources and actor telemetry. Current clean evidence: FNV close `baked-render-cleanup-fnv-close-20260708`, FO3 close `baked-render-cleanup-fo3-close-20260708`, and combined walkaround `baked-render-cleanup-walkaround-20260708` all capture native screenshots with exit code 0 and crash reports 0. Target runtime/render-live/root/weapon/limb ledgers pass for both games, but visual review remains questionable because hands/weapon posture is still wrong and player/non-target rows still warn. Next work: improve real hand/weapon orientation and non-target/player cleanup through code and telemetry, not launch-flag sweeps.
```

## Historical Short Prompt From Earlier Pass

Paste this at the start of the next thread:

```text
We are continuing the Nikami Worlds OpenMW ESM4 actor rendering proof. Read docs/reboot-handoff-20260708-openmw-actor-rendering.md first and treat the afternoon/evening/late update sections as authoritative. Non-VR only. External source is D:\Modlists\fnv\openmw-source. Runtime is D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe. The isolated viewer is D:\code\vulkanOpenMW\nikami-openmw-lab-publish and useful deltas have already been ported. Current catalog policy still keeps the old global FNV weapon IK disabled; do not revive global yaw/up-axis flag sweeps. Current code now has baked weapon-mesh runtime telemetry, FNV long-gun synthetic Weapon-frame stabilization, FNV long-gun left-arm offhand IK targeting the visible rifle fore-end, FNV sidearm synthetic Weapon-frame stabilization, a baked UI relay guard in scripts/omw/ui.lua, logical proof loading-GUI clear in engine.cpp, resource-system teardown before viewer/window teardown, and baked render/live hand geometry telemetry in animation.cpp. Current proof truth: FNV walkaround `fnv-baked-render-live-outer-walkaround-20260708` captures four native frames with exit code 0, crash reports 0, target runtime/rig/part/root/weapon/limb pass, visual review pass, and render/live questionable due `actor-render-live-transition` (84 rows, 60 render-good, 20 live-good, renderInvalidRatio 0.2857); FO3 walkaround `fo3-baked-render-live-outer-walkaround-20260708` captures four native frames with exit code 0, crash reports 0, target runtime/rig/part/render-live/root/weapon/limb pass, and visual review questionable due camera framing. Overall proof status remains questionable because FNV render buffers still transition, FO3 camera framing is weak, and player/non-target rows still produce runtime/limb warnings. Next work: fix FNV render-buffer freshness for hand/glove RigGeometry, tighten FO3 camera/readability, and clean target vs non-target scoring without adding brutal launch flags.
```
