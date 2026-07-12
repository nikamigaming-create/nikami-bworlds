# Fallout 3 / New Vegas Flat Overlay Validation — 2026-07-10

This note is the promotion record for OpenMW overlay patches 0002 through 0005.
Patch 0002 covers actor animation and attachments, patch 0003 the first bounded
behavioral runtime, and patches 0004/0005 retail animation priority and bone-LOD
parity. It does **not** claim complete
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
Runtime root and weapon-family behavior was checked with the isolated xNVSE
overlay exported under `patches/xnvse/`.

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
- 0005: `40FA5D12D3CD71CCE4F24C597EF3F22C16ED25036794DCBDF824AD7E996E00F8`

The ordered 0001 through 0005 queue was cumulatively apply-checked from clean
OpenMW base `9acf88c34b` with `scripts/Test-OpenMWOverlayReplay.ps1`.
The complete 23-patch replay produces tree `82b7b3083932ccef1b6b401187bd56de1d1c06ed`,
exactly matching lab checkpoint `a77bf86556`; the current lab checkout is never
used as the patch target.

### Retail xNVSE oracle

The isolated oracle is an overlay against xNVSE commit `175bb28`:

- patch: `patches/xnvse/0001-add-nikami-retail-oracle.patch`
- patch SHA-256: `A82E0829AD3DE064AE9483F966962C96985553D77694EA6CD5107C9058DFC641`
- runner: `scripts/Invoke-FNVRetailOracle.ps1`
- exact capture: `run/retail-oracle/fnv-goodsprings-direct-vcg02-stage5-timescale12.jsonl`

The xNVSE patch passed `git apply --check --whitespace=error` on a detached clean
`175bb28` worktree and built Win32 Release with 0 warnings and 0 errors. The
runner now requires a manifest-verified repo-local xNVSE runtime and copies the
oracle only into a unique ephemeral plugin directory selected through the
patched loader environment. It never installs or swaps a DLL in retail
`Data\NVSE\Plugins`; process environment and temporarily isolated root hook
DLLs are restored in `finally`.

Authoritative captures now pass a schema-v4 identity gate before promotion. The
gate requires the exact retail runtime, requested save, accepted load, target
reference/base pair, configured before/command/after frames, ordered screenshot
frames, and every batch target index/FormID/stage/timing tuple. Each passing
JSONL receives an adjacent immutable `.manifest.json` sidecar containing the
validated identity summary plus SHA-256 provenance for the overlay lock,
isolated runtime, oracle DLL, retail executable, runner, fixture, raw frames,
and derived crops. A failed gate writes no passing manifest. The synthetic
contracts are `scripts/Test-FNVRetailOracleEvidence.ps1` and
`scripts/Test-FNVRetailOracleIsolation.ps1`; neither launches retail.

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

The expanded 61-node comparison then isolated the remaining finger, twist,
pauldron, and toe behavior. Patch 0005 resolves the cause described below; it
does not use a joint-name correction.

## Patches 0005-0006: Bethesda bone-LOD runtime parity

Downstream commit `0bdacbfcdd` and patch 0005 load the authored
`NiBSBoneLODController` node groups from the skeleton NIF and tag the
corresponding scene nodes. The runtime suppresses animation callbacks only for
groups below the active LOD. It therefore preserves full-detail finger and
twist animation close to the camera and freezes the same fine joints as retail
at distance. No bone-name table is embedded in the engine patch.

The extended xNVSE oracle through commit `670a18f` and downstream OpenMW commit
`980555702e` established and implement the retail rule from FNV 1.4.0.525
directly:

- the skeleton declares eight groups; group 0 contains exactly 38 finger,
  thumb, forearm/upper-arm twist, pauldron, and toe nodes;
- retail LOD 1 changes those 38 targets to manager-controlled blend flags 5
  with their active high-priority interpolator normalized weight at zero;
- live `iBoneLODDistMult` is 1000 and the actor fade multiplier is 15; the
  disassembled writer computes
  `floor((cameraDistance / actorScale) * 12 * cameraLodAdjust /
  (iBoneLODDistMult * actorFadeMultiplier))`;
- the default scale/LOD-adjust values reduce that equation to the observed
  1250-unit step: LOD 0 at 1248.22, LOD 1 at 1251.15, and LOD 2 at 2705.18;
- the player remains at LOD 0 and levels are capped by the eight authored
  groups; and
- the high-process path runs every frame, but retail does not call the writer
  while either temporary `AnimData` sequence slot at `+0x104/+0x108` is
  occupied. In the controlled one-shot `Forward` capture those slots clear and
  the original writer begins on frame 52, then runs every subsequent frame.

The exact retail captures are:

- controller/groups and blend state: `run/retail-oracle/fnv-retail-v12-bone-lod-structured.jsonl`;
- live settings: `run/retail-oracle/fnv-retail-v16-lod-settings.jsonl`;
- 1248-to-1251 boundary: `run/retail-oracle/fnv-retail-v24-bone-lod-camera-distance.jsonl`; and
- LOD 2 at 2705 units: `run/retail-oracle/fnv-retail-v25-bone-lod-visible-2700.jsonl`;
- exact equation while moving: `run/retail-oracle/fnv-retail-v32-bone-lod-equation-walk.jsonl`; and
- hooked high-process guard transition: `run/retail-oracle/fnv-retail-v41-high-process-guard-values.jsonl`.

`scripts/Test-FNVRetailBoneLodParity.ps1` makes those facts executable. Its
report at `run/transform-oracle/fnv-retail-bone-lod-parity-v1.json` is
`matched`: 35 equation frames have maximum quotient error `6.0e-9`, the guard
and writer both transition on frame 52, and 59 sampled authored nodes match the
cumulative LOD 1 and LOD 2 group-freeze rule.

`scripts/Compare-BethesdaBoneLodMotion.ps1` reads group 0 from the NIF audit
instead of hardcoding names. Its retail-frame-84-through-96 versus OpenMW
report is `matched`: all 38 nodes were present, retail maximum retained-pose
motion was `0.00000296` degrees, and OpenMW maximum was `0.00000241` degrees.
The report is
`run/transform-oracle/fnv-retail-v10-f84-96-vs-openmw-bone-lod-motion.json`.

Final flat `openmw.exe` SHA-256 is
`DA80A4BE37B887AA234C5288483472E27C55A473BD6F4CFE7DA1682F8AEE83F6`.
Both release proofs captured 31 consecutive native frames, exited 0, produced
no crash report, and required no forced kill:

- FNV: `run/transform-oracle/bone-lod-cadence-fnv-proof/fallout_new_vegas-20260710-103300/manifest.json`;
- FNV clip: `run/transform-oracle/bone-lod-cadence-fnv-proof/fallout_new_vegas-20260710-103300/fnv-cadence-front-walk.mp4`;
- FO3: `run/transform-oracle/bone-lod-cadence-fo3-proof/fallout3-20260710-103435/manifest.json`; and
- FO3 clip: `run/transform-oracle/bone-lod-cadence-fo3-proof/fallout3-20260710-103435/fo3-cadence-front-walk.mp4`.

The close FNV actor transitions from its pre-camera distant LOD to LOD 0 and
keeps its animated fingers on the rifle. The FO3 actor likewise keeps head,
hat, beard, hands, rifle, torso, and legs attached. Only flat `openmw.exe` was
launched; no XR executable or headset runtime was started.

## Patch 0007: FaceGen color and dialogue vertical slice

Downstream commit `5d4bfa221a` and patch 0007 connect an FNV NPC activation to
the real OpenMW dialogue window and preserve the retail records needed by that
path. INFO records inherit their DIAL from the surrounding topic-child GRUP,
CTDA FormID parameters are load-order adjusted, and ESM4 NPC activation now
produces `ActionTalk`. The first selector supports the actor, race, sex,
talked-to, dead, level, quest-stage, objective, and global conditions required
by the Easy Pete slice. Unsupported conditions remain false; this is not yet a
whole-game dialogue claim.

Retail `FalloutNV.esm` establishes the exact gate:

- Easy Pete base `0x00104c7f`, authored exterior ref `0x00104c80`;
- GREETING DIAL `0x000000c8`;
- selected INFO `0x00104c60`, response `Howdy. What can Easy Pete do for you?`;
- the visible top-level topics ask about Easy Pete's name, the attackers, and
  Victor; and
- HCLR is exactly `(192,192,192)`, with FaceGen texture
  `00104c7f_0.dds` and body modulation `00104c7fmodbodymale.dds`.

The renderer treats the exported `_0.dds` as the neutral-at-0.5 FaceGen detail
map over the race diffuse, preserves the authored head material, and stops
applying HCLR repeatedly through the hair vertex arrays. The retail beard and
scalp use their authored diffuse/normal/highlight texture triplets rather than
substituting a highlight map as diffuse.

The exact staged flat executable SHA-256 is
`8EF11E84FF5F12E21ABF3630CCF9C794210BDCAE733A659CDFB57539E1009A10`.
The final dialogue run captured two native screenshots, exited 0, and produced
no crash report:

- manifest: `run/dialogue-proof/easy-pete-native-v7/fallout_new_vegas-20260710-144048/manifest.json`;
- native GUI frame: `run/dialogue-proof/easy-pete-native-v7/fallout_new_vegas-20260710-144048/screenshots/fallout_new_vegas.t012.n01.png`; and
- log selection: `GREETING FormId:0x10000c8 -> INFO FormId:0x1104c60`.

The closest clean color run is
`run/facegen-audit/easy-pete-color-v6/fallout_new_vegas-20260710-143352/manifest.json`.
It captured four native angles, exited 0, and produced no crash report. The
beard changed from the rejected teal/charcoal rendering to gray/white while
retaining the record-authored skin, eye, hair, beard, and body assets. The
camera remains an in-world moving-pose proof, so a controlled retail/OpenMW
pixel-differential and a broader NPC matrix are still required before claiming
every-pixel color parity.

### Patch 0013: retail FaceGen child basis

Retail xNVSE scene-graph telemetry in
`run/retail-oracle/fnv-easy-pete-checkpoint-animation-v2.jsonl` records an
identity `BSFaceGenNiNodeBiped` below `Bip01 Head` and the same +90-degree Y
local rotation on its static mouth, teeth, tongue, eye, brow, beard, and
scalp-hair children. OpenMW consumes the wrapper while attaching those parts,
so patch 0013 restores the measured child basis at the attachment boundary.

The face-parts-only run `fallout_new_vegas-20260710-231306` retained the
detached cluster with the zero default. The otherwise identical measured-basis
run `fallout_new_vegas-20260710-232016` coalesced it. The full-actor,
no-environment-override run `fallout_new_vegas-20260710-232355` kept mouth,
eyes, beard, hat, and head together in both native frames. The remaining wrong
skin/material response, scalp/sideburn presentation, and hand/sidearm assembly
are separate failing gates; this patch does not claim whole-head parity.

### Patch 0014: actor-aware, background-safe portrait capture

The static world-viewer camera now reports the exact live actor reference,
head center and forward axis, camera eye and target, target error, and actual
versus requested distance every 30 frames. `Invoke-RealWorldScreenshots.ps1`
requires a named actor ledger and a passing framing row when the catalog asks
for actor-aware validation; otherwise it marks the capture
`rejected-native-validation`. Scheduled native capture with no input events no
longer calls the foreground-window focus path.

The proof run `fallout_new_vegas-20260710-234240` kept the window in the
background, observed `GSEasyPete`, recorded `targetError=0` and
`eyeDistance=30`, captured two 800x600 native frames, exited 0, and passed the
machine framing gate. Its weapon-free, tight composition is suitable for the
remaining skin/material and hair/sideburn differential, but visual review is
still mandatory and still failing those pixels.

### Patch 0015: FO3/FNV weather records and measured afternoon lighting

xNVSE patch 0009 captured the seated retail fixture in hidden background mode:
current WTHR `0x001237D7` (`NVWastelandGS`), no transition, runtime hour
`14.4118919`, ambient `(0.369318515,0.4469423,0.578699231)`, and directional
and fog light `(1,0.890196145,0.666666687)`. The source event is
`run/retail-oracle/fnv-easy-pete-seated-render-environment-v1.jsonl`.

Patch 0015 adds FO3/FNV WTHR parsing/storage for linked IMADs, four cloud
layers, cloud colors and speed, FO3 four-time and FNV six-time color tables,
fog values, weather data, and sounds. Two parser tests cover the actual FNV
layout and the shorter FO3 table. A focused runtime test reproduces the exact
xNVSE high-noon-to-day interpolation at 14.4118919; unmeasured day segments
still use the established four-sample path rather than a guessed formula.

The native flat run `fallout_new_vegas-20260711-003100` imported 98 FNV weather
records, resolved `FormId:0x11237d7` to runtime slot 33, matched the retail
ambient/sun vectors, passed actor-aware framing, captured two native frames,
and exited 0. Retail's linked day/high-noon IMAD `0x000CEE18` is preserved by
the WTHR loader but not executed yet; the final orange/contrast differential
therefore remains an explicit image-space failure.

### Authored dialogue voice and result execution

Patch `0008` advances the bridge from visible INFO text to data-backed runtime
behavior. It preserves the one-byte FO3/FNV TRDT response number separately
from its three padding bytes, orders multi-response INFO records by that
authored number, resolves the matching voice from the mounted BSA index, and
streams it through OpenMW's actor voice path. INFO begin/end source now reaches
the Fallout quest runtime for `SetStage`, objective display/completion,
start/stop/complete/fail/active quest commands, and named
`set Quest.variable to value` assignments. Named quest variables are initialized
from the linked SCPT locals, participate in `GetQuestVariable`, and persist in
load-order-remapped saves.

The native FNV result-and-voice proof is
`run/dialogue-proof/easy-pete-result-voice-v13/fallout_new_vegas-20260710-151502/manifest.json`.
It exited 0 with two native screenshots and no crash report. Retail INFO
`0010515c` selected “Why are you called Easy Pete?”, loaded
`sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_0010515c_1.ogg`,
and applied all four authored `VFreeformGoodsprings` assignments:
`bMetPete`, `bMentionedProspecting`, `bMentionedBigHorners`, and
`bEasyPeteNCR`, each to 1 with `unsupportedAdded=0`.

The corresponding FO3 proof is
`run/dialogue-proof/fo3-lucas-topic-v2/fallout3-20260710-151646/manifest.json`.
It exited 0 with six native screenshots and no crash report. Lucas Simms loaded
the authored greeting voice from `fallout3.esm/maleuniquesimms`, then selected
“What can you tell me about Megaton?”, streamed
`dialogueme_megtownmegaton_0001e371_1.ogg`, and produced four authored choices.

The focused `ESM4QuestRuntimeTest` suite (five tests) and the four
`Esm4BehaviorRecordTest` cases pass in Release. The staged flat executable for
these proofs has SHA-256
`DD2E882EBA0AF7D17B1C72FB926E111E3E8A06DD1D9633FB0E14EFCC68E79948`.

## Patch 0009: retail LIP playback and wider conditions

Downstream commit `0d7383112e` decodes FO3/FNV's authored FaceFX LIP stream.
The 12-byte header is followed by a zero-run-coded payload containing start
frame, frame count, and 33 float targets at 30 Hz. The target order was checked
against the FNV executable table and includes the 16 phonemes, eye/brow/look
tracks, and head pitch/roll/yaw. OpenMW loads the sibling `.lip` from the same
mounted voice archive and samples it with the sound backend's actual stream
offset rather than a render-frame counter.

The FNV telemetry proof is
`run/dialogue-proof/easy-pete-retail-lip-telemetry-v7/fallout_new_vegas-20260710-160643/openmw.log`.
It attaches drivers to Easy Pete's head, mouth, lower teeth, tongue, and beard,
then reports authored values including `Th=0.917837`, `BigAah=0.87165`, and
`OohQ=0.947465` at their retail frames. The corresponding FO3 run is
`run/dialogue-proof/fo3-lucas-retail-lip-v1/fallout3-20260710-155921/manifest.json`.
Release `components-tests` passes all 1,295 tests, including compressed LIP,
track-order, interpolation, and malformed-run cases.

## Patch 0010: scheduled furniture settling

The xNVSE oracle extension at commit `0fbd8b4` records the private retail
furniture process fields without changing game behavior. The completed Easy
Pete state trace is
`run/retail-oracle/fnv-easy-pete-sit-state-v3.jsonl`; the accompanying sequence
trace is `run/retail-oracle/fnv-easy-pete-sit-animation-v1.jsonl`.

Retail claims chair ref `0010634A`, base `0008B5DE`, and marker index 2. While
state 3 waits for the enter animation, Pete is at the cached marker
`(-67911.5781,3445.1416,8387.31055)`, yaw `4.761`, type 14. State 4 then settles
at the furniture origin/yaw while retaining the marker height. The persistent
sequence is the 13.333-second `dynamicidle_chairsit.kf`; the concurrent forward
entry sequence ends at 1.733 seconds.

Downstream commit `f508102307` selects the active MNAM marker bit, loads an
already scheduled actor at the settled transform, assigns the persistent chair
idle its own full-body group, and suppresses the standing weapon-pose overlay.
The OpenMW live log is
`run/furniture-proof/easy-pete-settled-v1/openmw.log`:
it selects marker 2, places Easy Pete at `(-67970,3445.57,8387.31)` with yaw
`1.62`, and plays `dynamicidle_chairsit.kf` as `chairsit`. This promotes
scheduled settled-chair loading only. Runtime approach/enter, chair ownership,
stand-up/exit, and arbitrary activation remain required before furniture is a
complete state machine.

The staged flat `openmw.exe` SHA-256 after patches 0009 and 0010 is
`D3C0DA887AC583799B053E75418016156A2ABFB0CEA77F094985243CE31D8FE8`.

## Remaining compatibility work

The first behavior slices are green, but the whole-game claim remains open. The
next matrices are broad CTDA function and RunOn coverage, compiled Fallout
script bytecode execution, multi-line voice sequencing, complete furniture
enter/idle/exit transitions, package scheduling/navigation, combat and inventory semantics, and representative
quest/save differentials across both base games and every configured DLC.
Animation work must still broaden the oracle across more weapons and animation
groups and validate equivalent FO3 retail timing before claiming complete pose
parity.

Visual parity also remains a permanent release gate: head, face, hair, beard or
headgear, hands, body, feet, weapon sockets, muzzle and magazine helpers, and
every sampled animation frame must remain finite, correctly placed, and
attached in native flat front-walking proofs. A T-pose or a single good frame is
not sufficient. No 100% whole-game or every-pixel claim is valid until the
behavioral and visual matrices are green for FO3 and FNV.
