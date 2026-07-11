# Fallout 3 / New Vegas Retail-Parity Reboot Guide

This is the durable handoff for continuing the flat-screen Fallout 3 and
Fallout: New Vegas compatibility work. It is written for a person or an agent
starting with no conversation history.

The target is a clean OpenMW overlay that can be rebased onto downstream
OpenMW and can run the original Bethesda worlds from the user's legally
installed data. The xNVSE plugin is a measurement oracle for retail New Vegas;
it is not shipped in, linked into, or required by the OpenMW runtime.

## Non-negotiable scope

- Test `openmw.exe` only. Do not launch `openmw_vr.exe`, OpenXR, SteamVR, or a
  headset while this flat gate is active.
- Do not redistribute Bethesda assets, executable code, or extracted records.
- Do not replace record/KF/NIF behavior with hand-authored per-character fixes.
- Treat a screenshot classifier, a successful build, and a single good frame
  as insufficient evidence of retail parity.
- Keep failures visible. A path with missing retail/file-format evidence must
  be marked `unproven`, not described as compatible.

## Source-of-truth layout

| Purpose | Path | Expected branch/base |
|---|---|---|
| Overlay repository | `D:\code\nikami-worlds` | `codex/bethesda-flat-overlay` |
| OpenMW working checkout | `D:\Modlists\fnv\openmw-source` | `codex/bethesda-baked-flat-overlay-snapshot` |
| OpenMW clean queue base | external checkout commit `c30c830d8e` | patches apply in `patches/openmw/series` order |
| FNV/xNVSE working checkout | configured by the retail runner | xNVSE base `175bb28` |
| Retail oracle queue | `patches/xnvse` | `0001` through `0004` |
| OpenMW queue | `patches/openmw` | currently promoted through `0010` |
| Retail captures | `run/retail-oracle` | immutable evidence; add a new version instead of overwriting |
| OpenMW proof captures | under `run/`, plus the configured OpenMW proof directory | never promote on image statistics alone |

The external OpenMW and xNVSE checkouts are build/debug state. The reviewable,
replayable source of truth is the patch queue in this repository. Never vendor
either external source tree here.

## Current checkpoint (2026-07-10)

Promoted OpenMW commits before the active furniture change:

- `0d7383112e` — retail compressed LIP decoding and condition expansion.
- `f508102307` — active FURN marker selection and settled chair state.

Promoted overlay commit: `13669c2` (`Add Fallout lip and furniture overlay
patches`). The clean OpenMW queue `0001` through `0010` applied from
`c30c830d8e`, and the focused component suite passed 1295/1295 at that
checkpoint.

The active, **unpromoted** furniture work touches:

```text
apps/openmw/mwclass/esm4npc.cpp
apps/openmw/mwclass/esm4npc.hpp
apps/openmw/mwmechanics/character.cpp
apps/openmw/mwrender/animation.cpp
apps/openmw/mwrender/esm4npcanimation.cpp
apps/openmw/mwworld/scene.cpp
components/nifosg/controller.cpp
```

Do not discard those changes on reboot. Inspect `git diff` and continue from
the retail comparisons below.

## Retail/OpenMW side-by-side method

Every compatibility claim follows the same loop:

1. Identify one observable retail behavior and the exact actor/reference.
2. Capture retail state through the isolated xNVSE oracle without replacing
   the retail function.
3. Inspect the original ESM/NIF/KF/LIP/TRI payload independently.
4. Run the equivalent OpenMW slice and capture state plus native frames.
5. Compare values in the same coordinate space and at the same lifecycle
   point.
6. Implement the general format/runtime rule, not an actor-specific value.
7. Re-run FNV, a representative FO3 control, focused tests, and patch replay.
8. Record proof and known limitations in this guide and the validation record.

If retail telemetry and the source asset disagree, stop and identify whether
the disagreement is a runtime transform, cached value, load-order remap, or
sampling-time difference. Do not average the values or introduce a visual
offset.

Each investigated behavior should leave one evidence bundle with these four
parts, even when the result fails:

| Part | Required contents |
|---|---|
| Retail | Versioned xNVSE JSONL with game build, actor/reference form IDs, frame/time, active sequence, and measured runtime values |
| Format | Parsed ESM/NIF/KF/LIP/TRI values and the extraction command used |
| OpenMW | Native log with the same IDs, lifecycle point, coordinate space, and values |
| Review | Comparison/tolerance result plus native frames when appearance is part of the claim |

Never overwrite a capture to make a comparison pass. Add a new version and
record why the old version was insufficient.

## Extending the oracle safely

xNVSE gives access to the running retail process, but it is not a substitute
for implementing Bethesda formats and behavior in OpenMW. Extend the isolated
oracle when OpenMW needs a value that cannot be established from the file
format alone.

For every new probe:

1. Pin it to the supported retail executable/xNVSE revision and validate every
   private structure offset before dereferencing it.
2. Observe or wrap the retail operation; always call the original function and
   never alter its arguments/result during an evidence run.
3. Emit stable JSONL fields including form IDs, sequence/group names, time,
   coordinate-space labels, and enough lifecycle state to reproduce the
   sample.
4. Add a bounded runner mode so unrelated gameplay does not flood or
   contaminate the capture.
5. Restore any pre-existing plugin DLL and environment in `finally`.
6. Export the oracle change as the next patch in `patches/xnvse/series` and
   document the new fields in `patches/xnvse/README.md`.

The next required retail probes are the complete chair exit lifecycle and the
world transforms/parents of Easy Pete's equipped cowboy hat and face nodes
during standing, enter, seated idle, and exit. Those measurements will decide
the general attachment rule; a hand-tuned hat offset is not acceptable.

## Recreate the xNVSE retail oracle

Apply the queue to a clean xNVSE checkout at `175bb28`:

```powershell
$root = 'D:\code\nikami-worlds'
$xnvse = 'D:\path\to\xNVSE'

Set-Location $xnvse
git status --short
git rev-parse HEAD

Get-Content "$root\patches\xnvse\series" | ForEach-Object {
    $patch = Join-Path "$root\patches\xnvse" $_
    git apply --check --whitespace=error $patch
    git apply --whitespace=error $patch
}
```

Build the Win32 Release oracle:

```powershell
& 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe' `
  .\nvse_retail_oracle\nvse_retail_oracle.vcxproj `
  /p:Configuration=Release /p:Platform=Win32 /m
```

Run only through `scripts/Invoke-FNVRetailOracle.ps1`. The runner temporarily
installs the oracle DLL and restores the previous retail DLL and environment in
`finally`. Never leave the oracle installed in the normal mod list.

Furniture evidence already captured:

```text
run/retail-oracle/fnv-easy-pete-sit-state-v3.jsonl
run/retail-oracle/fnv-easy-pete-sit-animation-v1.jsonl
```

Easy Pete's retail facts from those files:

| Fact | Retail value |
|---|---|
| NPC base | `00104C7F` |
| Furniture reference | `0010634A` |
| Furniture base | `0008B5DE` |
| Active marker | index `2` (`activeMarkers=0x40000004`) |
| Entry position | `(-67911.5781, 3445.1416, 8387.31055)` |
| Entry yaw | approximately `4.761` radians (normalized OpenMW value `-1.52218`) |
| Enter animation | `chair_forwardenter.kf` |
| Enter duration | `1.733333` seconds |
| Settled position | `(-67966.9297, 3447.80762, 8387.31055)` |
| Settled yaw | `1.61941481` radians |
| Persistent idle | `dynamicidle_chairsit.kf`, `13.333334` seconds |

The retail result is not the chair model origin. Any implementation that snaps
to the FURN reference origin is wrong.

## Independent KF evidence

Run the offline NIF/KF sampler against the mounted retail archive:

```powershell
python scripts/offline_fallout_pose_sweep.py `
  --manifest run/furniture-proof/fnv-profile.json `
  --kf-pattern '^meshes\\characters\\_male\\idleanims\\chair_forwardenter\.kf$' `
  --kf-limit 1 --samples-per-kf 8 --mode key `
  --output run/furniture-proof/chair-forwardenter-offline.jsonl `
  --cache-root run/furniture-proof/cache
```

The `Bip01` compressed B-spline translation begins near
`(0.000755,-1.104507,0.000755)` and ends near
`(-0.026445,54.321801,0.000755)`. Its delta, interpreted in actor-local space
at the retail entry yaw, explains the retail marker-to-seat displacement.

The active debug pass found that `NifOsg::KeyframeController::getTranslation`
returned zero for compressed B-spline controllers even though the render
callback sampled those splines correctly. The current unpromoted fix samples
the same clamped B-spline in `getTranslation`. This is a general NIF controller
fix and must receive a focused component test before promotion.

## OpenMW flat build and furniture proof

Build only the flat executable:

```powershell
Set-Location D:\Modlists\fnv\openmw-source
cmake --build MSVC2022_64 --config Release --target openmw -- /m
```

Run Easy Pete's scheduled package with the real data:

```powershell
Set-Location D:\Modlists\fnv
.\tools\run_fnv_visual_proof.ps1 `
  -TargetId easy_pete `
  -Mode screenshot `
  -PoseMode AnimatedSeatedDialogueProof `
  -UseActorFacing -UseActorRenderBounds -StaticActorCamera `
  -NoSayAudio -ProofHour 14 -SkinningMode current
```

`OPENMW_FNV_FURNITURE_ENTRY_MARKER_PLACEMENT=1` is a diagnostic shortcut that
starts at the measured entry marker. It is useful for isolating the one-shot
KF but is not the production package proof. The production proof must begin at
the NPC's real same-cell location and walk to the marker.

Required successful log sequence:

```text
stacked runtime furniture package
state=entering ... group=chairforwardenter
chairforwardenter active for approximately 1.733333 seconds
state=seated ... position matches retail within the declared tolerance
chairsit active
state=exiting ... group=chairforwardexit
state=complete ... actor returned to the entry side
```

As of this checkpoint, entry group loading/timing, KF-driven entry movement,
retail-matched settled placement, and the persistent idle are implemented for
the Easy Pete slice. The latest trace is:

```text
D:\Modlists\fnv\openmw-config\proof-captures\easy_pete\easy_pete_20260710_180700.log
state=seated ... pos=(-67966.9,3447.81,8387.31)
rootDelta=(-55.3359,2.66675,0) ... yaw=1.62
```

That position differs from the xNVSE retail capture by about `0.03` world
units and proves the marker-to-seat rule for this actor/marker/animation. It
does not prove other marker directions, exit, fast-forward, or headgear.

The exit and headgear/face gates still fail. The older image
`easy_pete_20260710_165942_shot03.png` remains useful failure evidence for the
pre-fix chair placement and detached hat; never reuse it as a success image.
The latest attachment audit still reports `mouth-not-front`, `eye-not-front`,
and `facehair-not-front`, while the loose headgear check incorrectly accepts
the cowboy hat. Treat that acceptance as an audit defect, not proof.

## Guess/evidence gate

Every nontrivial compatibility decision added by this overlay must have an
entry in `docs/fallout-compatibility-evidence-ledger.md`. Use exactly one of
these classifications:

- `retail-proven`: observed in the running retail engine through the oracle.
- `format-proven`: derived directly from the serialized ESM/NIF/KF/LIP/TRI.
- `differential-proven`: retail and OpenMW traces agree across the stated
  matrix.
- `upstream-contract`: behavior inherited unchanged from a documented OpenMW
  or NIFTools contract.
- `unproven`: a fallback, approximation, inferred convention, or incomplete
  test. It cannot support a parity claim.

Search the overlay diff for likely assumptions before each promotion:

```powershell
Set-Location D:\Modlists\fnv\openmw-source
git diff c30c830d8e -- '*.cpp' '*.hpp' | `
  Select-String -Pattern 'fallback|heuristic|assum|guess|approx|default|FIXME|TODO|0\.[0-9]+f|[0-9]+\.f'
```

This is an inventory aid, not proof. Constants such as record flags and format
sentinels are legitimate when their source is recorded; a value is not safe
merely because the source code does not call it a guess.

## Patch promotion and replay

Before exporting `0011`:

```powershell
Set-Location D:\Modlists\fnv\openmw-source
git diff --check
git status --short
cmake --build MSVC2022_64 --config Release --target components-tests openmw-tests openmw -- /m
```

Run the focused controller, ESM4, animation, dialogue, quest, and save tests,
then the full component suite. Run representative flat FNV and FO3 native
proofs. Review the frames manually. A clean process exit does not waive a
visual or telemetry failure.

Commit the source change as one reviewable topic, export it with
`git format-patch`, add `0011` to `patches/openmw/series`, and replay the full
queue from a detached clean worktree at `c30c830d8e`:

```powershell
Set-Location D:\code\nikami-worlds
.\scripts\Apply-OpenMWPatches.ps1 -OpenMWSource D:\path\to\clean-openmw -Check
```

Only after replay, build, tests, FNV proof, FO3 proof, and manual frame review
pass should the queue documentation say `0011` is promoted.

## Five-minute reboot checklist

1. Read this file and `docs/fallout-compatibility-evidence-ledger.md`.
2. Run `git status --short` in all three worktrees; do not erase unrelated user
   changes in `D:\Modlists\fnv`.
3. Confirm the OpenMW branch and inspect the seven active files listed above.
4. Inspect the latest retail furniture JSONL and the latest OpenMW furniture
   log side by side.
5. Continue the first `unproven`/`failing` ledger row. Do not start XR.

Useful cold-start commands:

```powershell
git -C D:\code\nikami-worlds status --short --branch
git -C D:\Modlists\fnv\openmw-source status --short --branch
git -C D:\Modlists\fnv\openmw-source diff --check
Get-Content D:\code\nikami-worlds\patches\openmw\series
Get-Content D:\code\nikami-worlds\patches\xnvse\series
```

## Definition of the broader goal

Furniture is one milestone, not the finish line. Full completion still
requires representative and then broad FO3/FNV coverage for actors, creatures,
weapons, faces/headgear, skin/material/color, dialogue/LIP/voice, packages,
quests, scripts, saves, combat, inventory, services, world transitions, and
downstream patch replay. The current work must not redefine success around
Easy Pete or one screenshot.
