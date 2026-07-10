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

Patch 0001 contains dormant downstream VR work inherited from the source fork,
but the promoted runtime evidence is flat `openmw.exe` only. Do not launch or
test `openmw_vr.exe` as part of the flat compatibility gate.

See `docs/fallout-flat-overlay-validation-20260710.md` for the exact retail
oracle evidence, unit/sanitizer gates, record-load manifests, quest/save
differentials, and native FO3/FNV walking proofs used to promote patches 0002
through 0006. The reproducible xNVSE oracle overlay lives separately under
`patches/xnvse/`; it is never part of the OpenMW apply queue. Patch 0007's
current proof boundary is the Easy Pete greeting/topic and FaceGen slice; voice,
result-script execution, broader CTDA coverage, service menus, and FO3 dialogue
remain explicit follow-on gates rather than implied compatibility claims.

If one downstream patch matures into something upstream-worthy, split it into a
clean branch in the external OpenMW checkout and submit a normal upstream PR.
After it lands upstream, drop the local patch from this queue and update the
dependency baseline.
