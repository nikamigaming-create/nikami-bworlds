# Fallout 3 / New Vegas Flat Overlay Validation — 2026-07-10

This note is the promotion record for OpenMW overlay patches 0002 and 0003.
Patch 0002 covers the actor-animation and attachment milestone. Patch 0003 is
the first bounded behavioral-runtime milestone. It does **not** claim complete
dialogue execution, AI scheduling, compiled-script interpretation, combat,
inventory, or whole-game parity.

XR is intentionally out of scope. Every promoted run used flat `openmw.exe`.

## Root causes fixed

- Compact NiBSpline quaternion control points were decoded as XYZW even though
  the serialized NIF field order is WXYZ.
- The spline sampler used an unclamped four-weight shortcut. Patch 0002 uses a
  cubic de Boor evaluator over the open/clamped uniform knot vector used by
  NIFTools/NifSkope, including the historic `0xffff` invalid-handle sentinel.
- Constant/default transform-interpolator channels were discarded when the
  corresponding key array or spline handle was absent. Authored XYZ Euler keys
  still take precedence over a valid constant default.
- The raw skeleton `Bip01` bind translation leaked into idle because
  `mtidle.kf` has no root controller. Retail xNVSE telemetry reports a neutral
  runtime `Bip01` in idle and locomotion; the overlay now extracts gameplay
  displacement and keeps the rendered Fallout root neutral in both states.
- Fallout 3 was excluded from several New Vegas actor assembly paths.
- The replacement `Weapon` animation target was a plain OSG transform and lost
  the retail FO3/FNV bind matrix. It is now a NIF transform with the authored
  bind, driven by the selected weapon animation family.
- FaceGen drawable replacement could release the source geometry before its
  vertex baseline was copied. The source geometry and vertices now remain
  owned through replacement, removing the ASan-confirmed use-after-free.
- Serialized ESM4 `FormId:0x...` explicit references were not preserved through
  the compiler/runtime reference path used by proof and gameplay scripts.

The spline behavior was cross-checked against the official
[NifSkope controller implementation](https://github.com/niftools/nifskope/blob/develop/src/gl/glcontroller.cpp).
Runtime root and weapon-family behavior was checked with the isolated modified
xNVSE oracle in `external/xnvse/nvse_retail_oracle/`.

## Reproduction

Apply the ordered queue to a clean OpenMW base:

```powershell
.\scripts\Apply-OpenMWPatches.ps1 -OpenMWSource D:\path\to\openmw -Check
.\scripts\Apply-OpenMWPatches.ps1 -OpenMWSource D:\path\to\openmw
```

Build and run focused unit tests from the OpenMW build directory:

```powershell
cmake --build . --config Release --target components-tests -j 8
.\Release\components-tests.exe --gtest_filter='NifOsgControllerTest.*:Esm4WeaponTest.*'
```

Expected result: seven passing tests covering compact WXYZ quaternion decode,
clamped spline endpoints/interior, constant and missing channels, authored XYZ
precedence, and FO3/FNV weapon DNAM selectors/truncation.

Run the flat native walking proofs:

```powershell
.\scripts\Invoke-RealWorldScreenshots.ps1 -WorldId fallout_new_vegas -Mode flat `
  -StartSlice goodsprings-settler-actor-front-walk `
  -UseActorAnimationPolicyEnvironment -ShowGui

.\scripts\Invoke-RealWorldScreenshots.ps1 -WorldId fallout3 -Mode flat `
  -StartSlice megaton-entrance-lucas-actor-front-walk `
  -UseActorAnimationPolicyEnvironment -ShowGui
```

Both release gates exited 0 and produced 31 native 800x600 screenshots. The
FO3 proof uses exact placed reference `FormId:0x1003b46`, delayed `AiTravel`, a
heading-follow camera, and the unobstructed first route segment. The FNV proof
uses exact placed reference `FormId:0x1104f0a` and delayed `AiTravel`.

## Promoted evidence

- FO3 manifest: `run/actor-rendering-proofs/release-final-fo3-front-20260710/fallout3-20260710-024304/manifest.json`
- FO3 full native video: `run/actor-rendering-proofs/release-final-fo3-front-20260710/fallout3-20260710-024304/fo3-lucas-front-walk-full-native.mp4`
- FO3 lighting-settled native cut: `run/actor-rendering-proofs/release-final-fo3-front-20260710/fallout3-20260710-024304/fo3-lucas-front-walk-bright-cut.mp4`
- FNV manifest: `run/actor-rendering-proofs/release-final-fnv-20260710/fallout_new_vegas-20260710-023849/manifest.json`
- FNV earlier close proof: `run/actor-rendering-proofs/fnv-front-walk-close-lifetime-fixed-video-20260710/fallout_new_vegas-20260710-011959/fnv-front-walk-close-lifetime-fixed.mp4`

The actor telemetry gates reported no suspect parts. FO3/FNV head, face, hair,
beard/headgear, hands, body, feet, and weapon remained finite and attached;
`Bip01` stayed coincident with the object root through idle/walk transitions.

Full native AddressSanitizer runs for both worlds exited 0 with no ASan report:

- `run/actor-rendering-proofs/asan-final-fnv-native-20260710/fallout_new_vegas-20260710-023445/manifest.json`
- `run/actor-rendering-proofs/asan-final-fo3-native-20260710/fallout3-20260710-023619/manifest.json`

## Patch 0003: behavior records, quests, conditions, and saves

Downstream commit `af8eaca764` and patch 0003 add a bounded FO3/FNV behavior
foundation without modifying or redistributing retail data:

- QUST stages, objectives, conditions, and embedded result scripts are retained.
- INFO response arrays, conditions, links, and result scripts are retained;
  DIAL shared-info connections are associated with their quest.
- SCPT compiled bytecode and references are retained for later interpreter work.
- The runtime store now retains the behavior-facing ESM4 record types, including
  quests, dialogue, dialogue info, scripts, globals, form lists, classes, and AI
  package records. Retaining a package record is not yet package execution.
- `SetStage`, `GetStage`, `StartQuest`, `SetObjectiveDisplayed`,
  `SetObjectiveCompleted`, and `ForceActiveQuest` are registered in the VM.
- The condition core implements Bethesda's combine-with-next OR grouping, every
  comparison operator, comparison-global operands, and functions 56, 58, 59,
  74, and 546 (`GetQuestRunning`, `GetStage`, `GetStageDone`,
  `GetGlobalValue`, and `GetQuestCompleted`). Unsupported functions reject the
  entry and emit a diagnostic instead of silently evaluating true.
- ESM4 globals populate the runtime global table and calendar aliases.
- New `FQST` save records preserve flags, current/completed stages, objectives,
  and the active quest using wide FormIDs remapped through the current content
  load order.

Patch SHA-256:

- 0001: `F7B166679D8224685CCBAE49DA4A31A32F397E0204F0AE9F206F3247F3FFF3E2`
- 0002: `36FCD799B930946AB1C6CE2DDAABCFEEB8E6FCC727A8EFF78C576D6299515DA0`
- 0003: `359B8D5A1E43E167B4A4B86B09783A797856F933553CD66879255434F4CA20C5`
- 0004: `B22982BA2D4458D55F009B2FC0B4B2A3430669FBBE6A47FB8F0F5B02A4AD07E8`

The ordered 0001 through 0004 queue was cumulatively apply-checked from clean
OpenMW base `c30c830d8e` with `scripts/Apply-OpenMWPatches.ps1 -Check`.

### Retail xNVSE oracle

The isolated oracle is an overlay against xNVSE commit `175bb28`:

- patch: `patches/xnvse/0001-add-nikami-retail-oracle.patch`
- patch SHA-256: `320EE72E5896578E949675D4E48527DB86F2766A43E886EE8D95758139121743`
- runner: `scripts/Invoke-FNVRetailOracle.ps1`
- exact capture: `run/retail-oracle/fnv-goodsprings-direct-vcg02-stage5-timescale12.jsonl`

The xNVSE patch passed `git apply --check --whitespace=error` on a detached clean
`175bb28` worktree and built Win32 Release with 0 warnings and 0 errors. The
runner temporarily installs only the oracle DLL, restores any prior DLL and all
process environment values in `finally`, and removes no retail data.

In retail FNV 1.4.0.525, direct native `SetStage` on VCG02 stage 5 returned true.
The exact observed delta was:

- VCG02 flags `0 -> 33`, current stage `0 -> 5`, stage 5 `false -> true`;
- VCG02 became running and visible in the Pip-Boy;
- stage result script displayed objective 3 and made VCG02 active;
- `TimeScale` changed `30 -> 12` through the independent console command; and
- neighbor quests VCG00, VCG01, and VCG03 did not change.

The patch-0003 unit test reproduces that exact quest transition rather than an
invented approximation.

### Final Release gates

Build the exact staged runtime and run the ten focused tests:

```powershell
cmake --build . --config Release --target components-tests openmw-tests openmw -j 8
.\Release\components-tests.exe --gtest_filter='Esm4BehaviorRecordTest.*:Esm4WeaponTest.*'
.\Release\openmw-tests.exe --gtest_filter='ESM4QuestRuntimeTest.*'
```

Result: 10/10 passed. These cover QUST/INFO/DIAL/SCPT preservation, condition
FormID remapping, weapon selector parsing, the retail VCG02 transition, global
import, OR-grouped quest/global conditions, and save round-trip across a changed
content slot.

The patch-0003 behavior-gate flat `openmw.exe` SHA-256 was
`52030E9FEA8CA2C569993F2243E4EE5B56258C8BBAFC4EA59F71DA42B0B51983`.
No `openmw_vr.exe` or headset runtime was launched.

Real-data record-load manifests from that exact executable:

- FNV: `run/openmw-record-load-proofs/fallout_new_vegas-20260710-045456/manifest.json`
- FO3: `run/openmw-record-load-proofs/fallout3-20260710-045503/manifest.json`

FNV loaded 642 quests, 21,298 dialogue topics, 28,896 dialogue infos, 3,709
scripts, 255 globals, and 608 form lists. FO3 loaded 192 quests, 6,381 dialogue
topics, 22,327 dialogue infos, 1,257 scripts, 155 globals, and 243 form lists.
Both exact matrices passed and both flat processes exited 0.

Run those gates reproducibly with:

```powershell
.\scripts\Invoke-OpenMWRecordLoadProof.ps1 -OpenMWExe D:\path\to\openmw.exe `
  -ResourcesRoot D:\path\to\resources -WorldId fallout_new_vegas
.\scripts\Invoke-OpenMWRecordLoadProof.ps1 -OpenMWExe D:\path\to\openmw.exe `
  -ResourcesRoot D:\path\to\resources -WorldId fallout3
```

The FNV real-runtime transition and a newly written 48,577-byte save also passed
against the exact final executable:

- transition/save manifest: `run/openmw-behavior-proofs/fnv-vcg02-20260710-045002/manifest.json`
- save/reload manifest: `run/openmw-behavior-proofs/fnv-vcg02-20260710-045054/manifest.json`

Reload preserved VCG02 stage 5, flags 33, the completed stage set, objective 3,
and active-quest state. The harness normalizes only the load-order byte when
comparing OpenMW's internal `FormId:0x110a214` with retail `0x0010a214`.

## Patch 0004: retail animation-priority validation

Downstream commit `8d59cdf54a` and patch 0004 add a bounded transform oracle,
explicit-time KF dumps, and the first retail-derived weapon-pose layer rule.
The xNVSE oracle reads the live FNV 1.4.0.525 `NiControllerSequence`,
`NiMultiTargetTransformController`, and per-target `NiBlendInterpolator`
arrays without changing retail state.

The corrected live priority map for the equipped 2hr walk is:

- lower body: locomotion 30 beats aim 25;
- torso, neck, and head: locomotion 31 beats aim 30;
- both clavicle/arm/hand branches: aim 35 beats locomotion 31; and
- `Weapon`: aim 45.

OpenMW therefore layers `2hraim.kf` over the two arm masks only. Applying it to
the full upper body was the direct cause of the frozen torso and head/neck
offset. A rejected terrain-FABRIK experiment was removed after a single live
retail walk toggled `bhkRagdollController::fikStatus` without a transform
discontinuity.

Flat proof `run/transform-oracle/retail-priority-proof/fallout_new_vegas-20260710-073222/manifest.json`
captured 31 consecutive native front frames with the head, both hands, and
rifle attached. Its patch-0004 flat `openmw.exe` SHA-256 is
`25BB164C8086A5C8DA6939928D379076A59A2A05AE64BCC1CFC6FB8D66730580`.
The corresponding clip is
`run/transform-oracle/retail-priority-proof/fallout_new_vegas-20260710-073222/fallout_new_vegas-front-walk.mp4`.
The major-bone pose-curve comparison reports exact `Weapon`, head maximum
rotation residual 0.065 degrees, arm maximum 0.055 degrees, and root-translation
shape within 0.049 units after removing sequence-start/callback phase offset.

The expanded 61-node comparison also isolates the next engine task. Retail
creates manager-controlled blend targets (blend flags 5) for finger, twist, and
toe chains; normal limbs use flags 1. OpenMW's five coarse body masks currently
select one source for all descendants and cannot reproduce those per-target
manager-controlled transitions. This is recorded as an open parity gap, not
papered over with a joint-name correction.

## Remaining compatibility work

The first behavior slice is green, but the whole-game claim remains open. The
next matrices are dialogue/topic selection and result execution, broad CTDA
function coverage, compiled Fallout script bytecode execution, package
scheduling/navigation, combat and inventory semantics, and representative
quest/save differentials across both base games and every configured DLC.
Animation work must additionally implement Gamebryo-compatible per-target
manager-controlled blend state for finger, twist, and toe targets, then rerun
the 61-node oracle comparison before claiming complete pose parity.

Visual parity also remains a permanent release gate: head, face, hair, beard or
headgear, hands, body, feet, weapon sockets, muzzle and magazine helpers, and
every sampled animation frame must remain finite, correctly placed, and
attached in native flat front-walking proofs. A T-pose or a single good frame is
not sufficient. No 100% whole-game or every-pixel claim is valid until the
behavioral and visual matrices are green for FO3 and FNV.
