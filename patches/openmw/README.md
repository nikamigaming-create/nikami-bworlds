# OpenMW Patch Queue

This directory is the downstream patch layer for Nikami Worlds.

OpenMW and OpenMW VR are external dependencies. Do not vendor their source trees
here. Point `local/paths.json` or environment variables at the checkout/build you
want to use, then apply this queue onto that external tree.

Typical flow:

```powershell
Copy-Item config/paths.example.json local/paths.json
# Edit local/paths.json for this machine.

.\scripts\Apply-OpenMWPatches.ps1 -Check
.\scripts\Apply-OpenMWPatches.ps1
```

Patch files listed in `series` are applied in order. Patch 0001 is the world
viewer snapshot exported from downstream commit `01f8b0935f` against OpenMW VR
base `c30c830d8e`. Patch 0002 is the focused FO3/FNV actor animation,
attachment, FormID-script, and weapon-selector correction exported from commit
`d6c36c6b7e`. Patch 0003 is the bounded behavior-record, quest-condition,
global, VM-command, and save-state foundation exported from downstream commit
`af8eaca764`. Patch 0004 is the retail-priority weapon-pose correction and
transform-oracle instrumentation exported from downstream commit `8d59cdf54a`.
Patch 0005 reads Bethesda's authored `NiBSBoneLODController` groups, applies
the retail camera-distance ladder, and is exported from downstream commit
`0bdacbfcdd`. Patch 0006 applies the fully disassembled retail scale/camera/fade
equation and defers a LOD change while OpenMW's equivalent temporary scripted
sequence is active; it is exported from downstream commit `980555702e`.
Patch 0007 loads INFO topic inheritance and condition FormIDs, gives ESM4 NPCs
the real activation-to-dialogue path, renders the first FNV DIAL/INFO topic
slice, applies FaceGen modulation maps, and corrects FO3/FNV hair tint/material
handling. It is exported from downstream commit `5d4bfa221a`.
Patch 0008 fixes the packed TRDT response number, resolves authored FO3/FNV
voice files from the mounted archive index, executes common INFO quest/result
commands, persists named quest variables, and adds deterministic topic proof
selection. It is exported from downstream commit `7a159454ed`.
Patch 0009 decodes the retail compressed `.lip` format, samples its 33 FaceFX
targets on the real voice clock, routes them through every available TRI face
part, and expands CTDA subject/reference/faction/item/cell coverage. It is
exported from downstream commit `0d7383112e`.
Patch 0010 selects the active FURN marker bit, distinguishes the retail entry
marker from the settled chair transform, gives the persistent chair idle its
own full-body group, and suppresses standing weapon pose while seated. It is
exported from downstream commit `f508102307`.
Patch 0011 samples accumulated B-spline root translation, matches the measured
Easy Pete entry/settled chair path, removes the disproven schedule-expiry chair
release, attaches Fallout face/headgear parts to their measured retail head
basis, and adds a focused clamped-endpoint controller test. It is exported from
downstream commit `20dab7436f`. The hat placement is improved, but Easy Pete's
hair/sideburn and skin/beard differential still fails; patch 0011 is not a
whole-head parity claim.
Patch 0012 makes portrait capture follow the live `Bip01 Head` world transform
and local +Y face-forward axis instead of the actor root or conservative
skinned-drawable bounds. It also stops proof-only hidden weapons from retaining
their weapon-pose overlay and marks disabled proof AI initialization complete
so diagnostics do not flood once per actor per frame. It is exported from
downstream commit `8b0fb494b3`. The actor-tracked Easy Pete run proves stable
framing only; detached face geometry, skin color, hair/sideburns, and the
hand/sidearm assembly still fail visual review.
Patch 0013 restores the authored +90-degree Y local basis on the static
FO3/FNV FaceGen mouth, teeth, tongue, eye, brow, beard, and scalp-hair
children after the original wrapper node is consumed by attachment. It is
exported from downstream commit `7f083907cb`. Retail xNVSE hierarchy telemetry
measured the same matrix on every `BSFaceGenNiNodeBiped` child; the isolated
OpenMW run at `fallout_new_vegas-20260710-232016` coalesced the parts only when
that measured basis was supplied, and the no-override full-actor run at
`fallout_new_vegas-20260710-232355` retained the correction. Skin/material,
scalp/sideburn, and hand/sidearm parity remain failing gates.
Patch 0014 emits actor-aware portrait telemetry from the same live head pose
used by the maintained camera. It records the actor reference, head center,
forward axis, eye, target, target error, and requested/actual distance, then
marks the sample pass or fail. It is exported from downstream commit
`4e2b743d8b`. The root harness consumes that structured line together with the
expected NPC ledger; missing or failing evidence rejects the capture. The
`fallout_new_vegas-20260710-234240` run passed both gates without focusing the
game window and produced two tight, weapon-free native portraits. Visual pixel
review remains independently required.
Patch 0015 loads FO3/FNV `WTHR` records instead of substituting OpenMW's ten
Morrowind weather presets. It preserves linked image-space modifiers, four
cloud layers, cloud colors/speeds, FO3 four-time and FNV six-time color rows,
fog distances, weather data, and sounds; imports 98 base FNV weather records
into the runtime; and permits an exact load-order-adjusted weather FormID to be
selected. It is exported from downstream commit `052c704d62`. The
`fallout_new_vegas-20260711-003100` proof resolves retail `NVWastelandGS`
(`FormId:0x11237d7`) and matches the xNVSE afternoon ambient and directional
vectors. Only the retail-measured high-noon-to-day interpolation is enabled;
unmeasured time segments retain the legacy four-sample interpolation. The
remaining orange final-frame difference is now isolated to the linked weather
image-space modifier, which patch 0015 parses as a FormID but does not yet
execute.
Together they reproduce the currently proven flat runtime without vendoring
game data or the OpenMW source tree.

For routine downstream updates, rebase the dedicated overlay branch onto the
new downstream base, resolve conflicts there, rebuild and prove the flat target,
then re-export that single commit with `git format-patch`. Split it into smaller
upstreamable topics only after the behavior and proof contracts are stable.

Failed or incomplete hypotheses live under `experiments/` and are not applied by
`series`. Keep their proof links in the patch header so a later pass can reuse
the evidence without accidentally promoting the failed state.

## Patch Ownership Discipline

The source of truth is this directory, not the external OpenMW checkout. The
external checkout is build state and may be deleted, recreated, patched, and
rebuilt at any time.

Use this flow for every engine change:

1. Reproduce the issue with a real non-VR harness run and a manifest under
   `run/real-world-screenshots/`.
2. Make the smallest source change in the external checkout needed to test the
   hypothesis.
3. Export or hand-port the exact source diff into a topic patch in this
   directory, then list it in `series`.
4. Rebuild the non-VR runtime, copy the rebuilt executable into the configured
   local runtime root, and rerun the same slice.
5. Record screenshot evidence, actor runtime evidence, and visual review rows.
   Do not promote a patch when telemetry passes but the visual review is
   questionable or failing.

Future upstream submissions should prefer topic boundaries:

- `profile` and launcher isolation
- archive and asset decoding
- ESM4 record parsing and model resolution
- actor assembly and animation binding
- renderer/material compatibility
- screenshot harness and telemetry
- temporary diagnostics, which must be removed or promoted before release

Game-specific behavior belongs in data, profiles, or policy files when the
engine behavior is genuinely configurable. Engine patches should use record
provenance, content format, or explicit runtime policy instead of brittle path
guesses when possible.

Patch 0001 contains dormant downstream VR work inherited from the unpublished
local source-fork delta, but the promoted runtime evidence is flat `openmw.exe`
only. It does not apply to official OpenMW `master`. The exact dependency and
queue boundary is recorded in `../../docs/openmw-base-overlay-boundary.md` and
`../../catalog/openmw-base-lock.json`. Do not launch or test `openmw_vr.exe` as
part of the flat compatibility gate.

See `docs/fallout-flat-overlay-validation-20260710.md` for the exact retail
oracle evidence, unit/sanitizer gates, record-load manifests, quest/save
differentials, and native FO3/FNV walking proofs used to promote patches 0002
through 0006. The reproducible xNVSE oracle overlay lives separately under
`patches/xnvse/`; it is never part of the OpenMW apply queue. Patch 0007's
FaceGen proof boundary remains the Easy Pete slice. Patch 0008 proves authored
greeting/topic voice in both FNV and FO3 plus Easy Pete's four retail quest
variable writes. Patch 0009 proves retail LIP channel delivery in FNV and FO3.
Patch 0010 proves scheduled settled-chair loading for Easy Pete. Patch 0011
matches the measured enter-to-seat slice and retail headgear basis, while the
actual retail release trigger, arbitrary runtime furniture activation, and
full face/hair/material parity remain open. Broader
CTDA/RunOn coverage, compiled bytecode, multi-line voice queues, and service
menus remain explicit follow-on gates rather than implied compatibility claims.

On a cold restart, read `../../docs/fallout-retail-parity-reboot.md` before
editing an external checkout. Every new compatibility assumption must also be
classified in `../../docs/fallout-compatibility-evidence-ledger.md`; rows
marked partial, unproven, or failing cannot support a parity claim.

If one downstream patch matures into something upstream-worthy, split it into a
clean branch in the external OpenMW checkout and submit a normal upstream PR.
After it lands upstream, drop the local patch from this queue and update the
dependency baseline.
