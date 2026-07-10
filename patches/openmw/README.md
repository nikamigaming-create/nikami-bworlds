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

Patch files listed in `series` are applied in order. The current queue is one
snapshot patch exported from downstream commit `01f8b0935f` against OpenMW VR
base `c30c830d8e`. It intentionally consolidates the previously loose Bethesda
world work so a fresh checkout can reproduce the proven flat runtime exactly.

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

The current patch contains dormant downstream VR work inherited from the source
fork, but the promoted runtime evidence is flat `openmw.exe` only. Do not launch
or test `openmw_vr.exe` as part of the flat compatibility gate.

If one downstream patch matures into something upstream-worthy, split it into a
clean branch in the external OpenMW checkout and submit a normal upstream PR.
After it lands upstream, drop the local patch from this queue and update the
dependency baseline.
