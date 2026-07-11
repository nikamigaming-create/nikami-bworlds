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
| Retail oracle queue | `patches/xnvse` | `0001` through `0008` |
| OpenMW queue | `patches/openmw` | promoted queue through `0011` |
| Retail captures | `run/retail-oracle` | immutable evidence; add a new version instead of overwriting |
| OpenMW proof captures | under `run/`, plus the configured OpenMW proof directory | never promote on image statistics alone |

The external OpenMW and xNVSE checkouts are build/debug state. The reviewable,
replayable source of truth is the patch queue in this repository. Never vendor
either external source tree here.

## Current checkpoint (2026-07-10)

Promoted OpenMW commits before the active furniture change:

- `0d7383112e` — retail compressed LIP decoding and condition expansion.
- `f508102307` — active FURN marker selection and settled chair state.

The clean OpenMW queue through `0010` applied from `c30c830d8e`, and the focused
component suite passed 1295/1295 at that checkpoint. Commit `20dab7436f`
exports patch `0011` for retail furniture entry/root sampling and measured head
attachments. The cumulative `0001` through `0011` replay produced Git tree
`39ffd8c2b8f49fae16c2f2416b2d4eb3452f9b32`, exactly matching the clean OpenMW
branch. Release `openmw.exe` and `components-tests.exe` rebuilt successfully,
and `NifOsgControllerTest.shouldUseClampedBSplineEndpoints` passed.

The patch `0011` source surface is:

```text
apps/openmw/mwclass/esm4npc.cpp
apps/openmw/mwclass/esm4npc.hpp
apps/openmw/mwmechanics/character.cpp
apps/openmw/mwrender/animation.cpp
apps/openmw/mwrender/esm4npcanimation.cpp
apps/openmw/mwworld/scene.cpp
components/nifosg/controller.cpp
```

The OpenMW worktree is clean. The retail hat position is improved, but missing
hair/sideburn geometry and the wrong OpenMW skin/beard result remain explicit
failures; do not promote whole-head parity from the hat result.

Read `docs/openmw-base-overlay-boundary.md` before changing the dependency base.
The current `c30c830d8e` base is 98 unpublished commits ahead of
`origin/openmw-vr`; it is not official OpenMW `master` and must not be described
as reproducible from a published remote until that delta becomes an explicit
queue or pinned source dependency.

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

The seated-idle hat/face hierarchy is now retail-proven. The next required
retail probes are the actual chair-release trigger and the same node hierarchy
during standing, enter, and exit. Those measurements decide the general
attachment rule; a hand-tuned hat offset is not acceptable.

### Background collector and checkpoints

Do not drive the retail UI with mouse/keyboard automation. `-BackgroundDataMode`
keeps the game minimized, closes pause menus through the in-process console,
and streams JSONL from the xNVSE main-loop callback. Observer approach uses
bounded engine `SetPos` steps through declared world-space waypoints; it does
not depend on window focus or `HoldKey`.

The full Easy Pete lifecycle is intentionally a one-time checkpoint producer:

```powershell
.\scripts\Invoke-FNVEasyPeteFurnitureOracle.ps1 `
  -OutputPath run\retail-oracle\fnv-easy-pete-background-v5.jsonl
```

It walks the observer down the road, waits for a declared furniture state,
saves `NikamiOracleEasyPeteSeated`, copies the `.fos`/`.nvse` pair to
`run/retail-oracle/checkpoints`, and removes the created files from the normal
FNV save directory. The generic runner's `-SaveFixture` option temporarily
installs such a checkpoint under a PID-qualified name and removes it in
`finally`. A fresh 30-frame furniture query completed in 12.5 seconds in
`fnv-easy-pete-checkpoint-fast-v2.jsonl`; a four-frame full scene-graph and
animation query completed in 13.1 seconds in
`fnv-easy-pete-checkpoint-animation-v2.jsonl`.

Checkpoint reload is not authoritative for the actor reference position. The
live lifecycle settled at `(-67966.9297,3447.80786,8387.31055)`, while the
reloaded checkpoint reconstructed at `(-67968.75,3450.40674,8387.31055)`.
Use the live lifecycle for world-placement comparison and checkpoints for
state, hierarchy, equipment, face, bone, controller, and animation probes.

### Head-tracked retail pixels

Patch 0006 and the generic runner capture retail pixels without taking window
focus. The plugin resolves `Bip01 Head` recursively, follows the rendered
head's face-forward axis rather than the actor-root yaw, drives the free camera
in-process, and requests the normal retail screenshot at declared frames. The
runner moves only newly created BMPs into the evidence directory, restores any
pre-existing retail screenshots, and derives a square PNG proof crop while
preserving the raw frame.

Easy Pete checkpoint example:

```powershell
.\scripts\Invoke-FNVRetailOracle.ps1 `
  -PluginDll D:\path\to\xnvse\nvse_retail_oracle\build\nvse_retail_oracle.dll `
  -OutputPath run\retail-oracle\fnv-easy-pete-portrait-camera-v5.jsonl `
  -ScreenshotDirectory run\retail-oracle\fnv-easy-pete-portrait-camera-v5-screens `
  -ScreenshotFrame 30 -PortraitCamera -PortraitDistance 70 `
  -SaveFixture run\retail-oracle\checkpoints\NikamiOracleEasyPeteSeated.fos `
  -TargetForm 0x00104C80 -BeforeFrame 10 -CommandFrame 20 -AfterFrame 30 `
  -MaxFrames 40 -SampleEvery 1 -BackgroundDataMode
```

The run is acceptable only when it has one accepted `screenshot-request`, one
`portrait-camera-set`, one BMP, one proof crop, and no `*-fault` event. For v5,
the resolved head was `(-67952.6484,3446.4502,8462.33789)`, about 75 world units
above the actor root; this explicitly rejects the earlier actor-root framing
mistake. Pixel evidence proves what retail drew at that frame, not that OpenMW
matches it. Record OpenMW hair, beard, skin, eye, or attachment differences as
failures until a controlled side-by-side comparison passes.

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

To audit the exact retail fullscreen shader selected by patch 0010, read the
active package number from `RendererInfo.txt` and keep all extracted bytecode in
ignored quarantine storage. For the current FNV fixture the active package is
013:

```powershell
python .\scripts\inspect_fallout_shader_package.py `
  --package 'D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\Shaders\shaderpackage013.sdp' `
  --name ISHDRBLENDINSHADERCIN.pso `
  --output-dir .\run\retail-oracle\shaderpackage013-audit-v1 `
  --fxc 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\fxc.exe'
```

The script validates the whole SDP boundary, hashes the selected bytecode, and
uses Microsoft's SDK disassembler. It must report 100 vertex entries, 1,007
total entries, a 748-byte selected shader, and FNV-1a `0x0A008802`, matching the
runtime hook. Do not commit the extracted `.pso`; only the hashes, constants,
and derived formula belong in the public evidence ledger.

Patch 0017 is the maintained OpenMW execution slice for that evidence. It adds
the `IMGS`/`IMAD` stores and record readers, preserves `WRLD.INAM` and
`CELL.XCIM`, composes the base and active weather modifier instances, applies
the sunlight multiplier, and runs the final cinematic/tint/fade shader in the
flat post-processor. Verify the byte contracts before launching:

```powershell
cmake --build D:\Modlists\fnv\openmw-source\MSVC2022_64 `
  --config Release --target components-tests -- /m:4

& D:\Modlists\fnv\openmw-source\MSVC2022_64\Release\components-tests.exe `
  --gtest_filter=Esm4ImageSpaceTest.*:Esm4WeatherTest.*
```

The five tests must pass. The maintained no-focus native proof is:

```powershell
.\scripts\Invoke-RealWorldScreenshots.ps1 `
  -WorldId fallout_new_vegas -Mode flat -SkipMenu `
  -StartSlice goodsprings-easy-pete-actor-tracked-portrait
```

The catalog pins `NVDefaultExterior` as load-order-adjusted
`FormId:0x108809d` because the generated Goodsprings bridge cell is ESM3 and
cannot yet expose its underlying ESM4 world link. The engine still resolves
the weather IMADs from `NVWastelandGS` data. The reference run is
`run/real-world-screenshots/fallout_new_vegas-20260711-020053`: exit 0, two
accepted native frames, and exact live constants `skinDimmer=0.1925`,
`sunlightDimmer=1.21`, cinematic `(1.1,0.2,1.1,1.3)`, tint
`(0.992832,0.660198,0.0276842,0.392157)`. Do not call this full retail color
parity: the HDR adaptation/bright-pass/bloom chain, skin-only material dimmer,
automatic generated-cell world link, remaining time transitions, and FO3
matrix are still open.

Furniture evidence already captured:

```text
run/retail-oracle/fnv-easy-pete-sit-state-v3.jsonl
run/retail-oracle/fnv-easy-pete-sit-animation-v1.jsonl
run/retail-oracle/fnv-easy-pete-background-v5.jsonl
run/retail-oracle/fnv-easy-pete-checkpoint-fast-v2.jsonl
run/retail-oracle/fnv-easy-pete-checkpoint-animation-v2.jsonl
run/retail-oracle/fnv-easy-pete-portrait-camera-v5.jsonl
run/retail-oracle/fnv-easy-pete-portrait-camera-v5-screens/frame-000030.bmp
run/retail-oracle/fnv-easy-pete-portrait-camera-v5-screens/frame-000030-proof-crop.png
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
| Seated head parent | `Bip01 Neck1 -> Bip01 Head` |
| Seated hat parent | `Bip01 Head -> Hair  (001083E0) -> cowboyhat2:0` |
| Seated biped face controls | `Bip01 Head -> BSFaceGenNiNodeBiped -> mouth/eyes` |
| Seated skinned face | `Scene Root -> BSFaceGenNiNodeSkinned -> FaceGenFace` |

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

The matching `chair_forwardexit.kf` track runs in reverse: approximately
`(-0.02681,54.32169,0.00080)` at `0.0` seconds to
`(0.00080,-1.10450,0.00080)` at `1.533333` seconds. This proves the serialized
exit curve but does not by itself establish how retail transfers that curve
between the skeleton root and actor reference. Capture the retail exit actor
and root transforms before changing OpenMW's exit placement.

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

An accelerated-world-time OpenMW run in `easy_pete_20260710_181841.log`
previously made the schedule inactive, played `chairforwardexit`, and completed
at the wrong endpoint (`x=-68022.3`). Retail capture v14 accepted both
`Set GameHour To 19` and `00104C80.EvaluatePackage` but kept Easy Pete seated,
with the same chair claim, for more than 1,600 frames. That falsifies the
assumption that expiry of this package window is itself the retail release
trigger. Do not promote the OpenMW schedule-driven exit. Keep the actor seated
until the actual retail release event is identified and captured.

The spatial exit and OpenMW headgear/face gates still fail. The older image
`easy_pete_20260710_165942_shot03.png` remains useful failure evidence for the
pre-fix chair placement and detached hat; never reuse it as a success image.
The latest attachment audit still reports `mouth-not-front`, `eye-not-front`,
and `facehair-not-front`, while the loose headgear check incorrectly accepts
the cowboy hat. Retail animation v2 explicitly records the parent chain
`Bip01 Head -> Hair (001083E0) -> cowboyhat2:0`; use that hierarchy to replace
the loose-frame guess, then compare standing, enter, seated, and exit frames.

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
