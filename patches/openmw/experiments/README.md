# OpenMW Patch Experiments

This directory keeps failed or incomplete engine hypotheses with their proof
links. Files here are not part of the active patch queue and must not be
promoted by `patches/openmw/series`.

Move an experiment back into the active queue only after a fresh build and
non-VR proof sweep show passing actor proof-status rows for each affected world.

Current actor telemetry experiments:

- `0003-esm4-actor-runtime-part-space-telemetry.patch`: measurement-only part
  3D-space gate for FO3/FNV actor attachment proof. It is not an actor fix and
  should remain quarantined unless paired with frame-level telemetry and visual
  proof. The 20260707-205427 proof sweep showed the expected telemetry
  improvement but still failed visual/runtime actor proof.
- `0004-esm4-actor-attachment-matrix-telemetry.patch`: measurement-only final
  attachment matrix origin telemetry for head-relative ESM4 actor parts. It is
  intended to explain the floating head/weapon/torso fragments seen in the
  20260707-205427 sweep. The 20260707-210134 proof sweep confirmed frame-level
  part telemetry for FO3/FNV current and auto, but runtime, rig, and visual
  actor proof still failed.
- `0005-esm4-fo3-fnv-shared-actor-animation-context.patch`: small FO3/FNV parity
  experiment that allows FO3 NPCs through the same Fallout actor animation
  context gate currently used for FNV. The 20260707-210852 proof sweep failed
  all FO3/FNV current and auto rows: part telemetry passed, but actor runtime,
  rig pose, and visual proof still failed. Keep quarantined until a deeper
  actor-root/bind fix passes both games separately.
- `0006-esm4-live-rig-bounds-telemetry.patch`: measurement-only live rig bounds
  experiment for the 20260707-213811 FO3/FNV current visual failure. It adds
  last-frame render geometry and live/current-pose bounds to the existing part
  matrix audit so the next proof sweep can separate stale render buffers from
  bad skinning math. It must not be promoted without passing screenshots.
- `0007-esm4-part-matrix-runtime-audit-gate.patch`: measurement-only follow-up
  to `0006`. It calls the runtime part audit directly when
  `OPENMW_FNV_PART_MATRIX_AUDIT=1` because the 20260707-215128 proof showed
  screenshot/rig failures but no frame-level part audit rows.
- `0008-esm4-refresh-rig-render-pose.patch`: guarded runtime experiment for the
  20260707-215634 render/live split. It calls
  `RigGeometry::refreshFalloutSkinningForCurrentPose()` behind
  `OPENMW_FNV_REFRESH_RIG_RENDER_POSE=1` after animation update. The
  20260707-220315 proof produced no native screenshots for FO3 or FNV, so keep
  it failed/quarantined and do not carry the env flag in active proof config.
- `0009-esm4-disable-native-actor-basis-experiment.patch`: failed guarded
  recovery of the HIGGS-lite actor-basis slice. The 20260707-222230 proof kept
  FO3 visually inverted/disassembled and made FNV produce no native screenshots
  with a crash dump, so it was reversed and its env gate is not active.
- `0010-esm4-face-rig-render-buffer-audit.patch`: measurement-only follow-up
  for the `actor-head-render-gap` rows found in the 20260707-215634 and
  20260707-222230 sweeps. It teaches the face drawable audit to inspect the
  last-frame `SceneUtil::RigGeometry` render buffer instead of treating rigged
  head drawables as uninspectable. The 20260707-223752 proof made the FO3 and
  FNV face attachment ledger pass, but visual proof still failed with
  inverted/disassembled actors and FNV crash evidence, so this remains a
  diagnostic patch and is not a behavior fix.
- `0011-esm4-actor-controller-basis-audit.patch`: measurement-only controller
  basis audit after 0010. It preserves current actor behavior, exposes raw
  keyframe sampling beside the current basis-applied sampling, and logs
  `FNV/ESM4 ACTOR BASIS AUDIT` rows when
  `OPENMW_FNV_ACTOR_BASIS_AUDIT=1` is set. Use it to decide whether the next
  behavior patch should move FO3/FNV manual controller application to raw
  samples instead of trying another broad actor-basis disable. The
  20260707-224708/20260707-224736 runs emitted no rows because the current
  runtime uses native scene graph callbacks.
- `0012-esm4-native-callback-basis-audit.patch`: measurement-only follow-up to
  0011. The 20260707-224708/20260707-224736 close-burst runs emitted no 0011
  rows because FO3/FNV now use native scene graph callbacks. This patch keeps
  behavior unchanged and logs applied-versus-raw controller basis deltas from
  `NifOsg::KeyframeController::operator()` when
  `OPENMW_FNV_ACTOR_BASIS_AUDIT=1` is set. The 20260707-225321 proof emitted
  256 callback rows for each game, with 238 large rotation-delta samples and
  180-degree head/neck deltas; visual proof still failed, so this remains
  diagnostic evidence for a narrow basis behavior gate.
- `0013-esm4-native-callback-basis-mode.patch`: failed guarded behavior
  experiment that keeps the default native callback behavior intact while allowing
  `OPENMW_ESM4_NATIVE_CALLBACK_ACTOR_BASIS_MODE=current|raw|no-half-turn|bind`
  for FO3/FNV actor-basis bones. Raw and no-half-turn kept actors inverted and
  made FNV crash after capture; bind exited cleanly and made limbs/weapon
  somewhat more coherent, but both games stayed upside down. Do not carry this
  patch in the runtime; the next slice is actor root/world transform or part
  attachment basis.
- `0014-esm4-actor-root-attachment-audit.patch`: measurement-only follow-up to
  the failed 0013 basis modes and failed plain root-wrapper probes. It logs
  actor root world basis, Bip01/head/hand/foot/weapon positions, and major
  root-relative deltas when `OPENMW_FNV_ROOT_ATTACHMENT_AUDIT=1` is set.
