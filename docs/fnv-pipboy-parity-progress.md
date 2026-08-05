# FNV Pip-Boy and Inventory Parity Progress

Long-running real-save/fast-travel execution queue:
`docs/fnv-real-save-pipboy-fast-travel-luna-max-plan.md`.

Last updated: 2026-08-02 10:00 America/Los_Angeles

## Objective

Deliver a retail-data-driven Pip-Boy and inventory implementation in OpenMW
with connected arms, stable enter/held/exit animation, correct screen framing,
all panes/submenus/icons/stats/maps, and item use that changes production game
state. Prove weapon and consumable behavior in first person and third person.
Pair equivalent retail/OpenMW telemetry, native frames, and synchronized
side-by-side video. Semantic similarity alone is not a pass.

## Non-negotiable retail replay contract

Retail Fallout: New Vegas is the sole behavioral and visual oracle for the
Pip-Boy. Capture and retain retail native frames/video, active animation-stack
telemetry, first-person bone and mesh-node transforms, control-node transforms,
button travel, dial rotation, timing, screen layout, icons, and state changes.
OpenMW must replay those measured observations as closely as its renderer and
animation system permit.

Do not invent or hand-tune a replacement pose, IK target, bone transform,
device transform, control angle, button depth, timing curve, icon, layout, or
interaction sequence. If a required retail fact has not been captured, expand
the canonical unattended retail capture first. A validator pass without visual
retail/OpenMW comparison is not completion, and a settled screenshot is not
proof of an animation.

## Preserved clean retail fixture

- User-approved lineage: `Save 341     Goodsprings  00 02 00.fos`
- Canonical immutable copy:
  `local/retail-pipboy-fixtures/NikamiCleanPipBoyOracle-20260802.fos`
- SHA-256:
  `D33A0303D103D94417870B1EEDBA39C08A2E1884D730104DCFB5D59074CD8CF5`
- Save 331 and its `.nvse`/pre-fix companions were deleted from the user save
  directory on 2026-08-02. All JAM runner/preflight defaults now name the clean
  fixture. No script under `scripts/` references Save 331.

## Current source state

- Worlds repository base: `dec97e10ca5266ce9f104a2beb61ff5f77da496b`
- Engine repository: `D:/code/nikami-openmw-save330-integrated`
- Engine base: `5fb9e4e0aa50cda266a5ddc264d6eb166bf5f507`
- Current interaction-gated runtime:
  `local/openmw-pipboy-item-gates-20260802-111400/openmw.exe`
- Runtime SHA-256:
  `FE553A1598AC82A5DF2E5FD2452CD9C8E725566FCAE12A7F247BBD99DD71A778`
- The working trees contain intentional uncommitted Pip-Boy/capture changes.
  Inspect and preserve them; do not reset either tree.

## Implemented

- Real retail Pip-Boy 3000 wrist model and live rendered screen texture.
- Screen state for STATS, ITEMS and MAP; world/local map, pan and zoom.
- Retail `pipboy.kf` raise/lower and `1stPPipboyWaver.kf` held-arm binding.
- Pip-Boy device remains attached through the held sequence.
- Physical tab knob, scroll knob and bottom-button state are isolated from the
  housing transform, so a control cannot rotate the whole device.
- Rifle is suppressed during Pip-Boy presentation and restored after close.
- OpenMW Pip-Boy selection now binds the selected native Fallout weapon and
  compatible native ammunition FormIDs together.
- Stimpak activation consumes one real ALCH inventory entry and synchronizes
  live health plus Fallout runtime health.
- Post-close reload waits for the selected weapon controller to settle before
  transferring reserve ammunition into the selected weapon magazine.
- The interaction validator is mandatory for both lifecycle-only and complete
  panel sweeps; visual-only captures cannot pass it.
- TestMap01 plan now requires exhaustive aid/food behavior, paired state keys,
  first/third-person weapon animation gates, contact sheets and side-by-side
  video.

## Passing OpenMW interaction evidence (2026-08-02)

- Root: `run/opennv-pipboy-item-use-reload-gate-20260802-111500/openmw`
- Report: `pipboy-showcase-report.json` (`status: pass`)
- Raw video: `OpenMW-PipBoy-live-exact-title-raw.mp4`
- Native states: 8/8.
- Actual selection deltas:
  - 9mm pistol equipped as `FormId:0x10e3778` with 9mm ammo
    `FormId:0x108ed03`.
  - Stimpak count `5 -> 4`; health `75 -> 100`.
  - Varmint rifle equipped as `FormId:0x107ea24` with 5.56 ammo
    `FormId:0x1004240`.
  - Post-close reload: loaded `0 -> 5`; reserve `60 -> 55`.
- Capture policy: no Windows app control, foreground activation, or foreground
  input; native PNGs, exact-title video, telemetry and report retained.

## Prior OpenMW visual baseline

- Root: `run/opennv-pipboy-authored-split-20260802-092655/openmw`
- Raw video: `OpenMW-PipBoy-live-exact-title-raw.mp4`
- Motion strip: `transition-samples/authored-motion.png`
- Native frames: STATS, two weapon rows, map, zoom/pan, equip, restored rifle.
- Observed result: device and left arm remain stable; rifle returns. This is a
  useful OpenMW regression baseline, not retail parity completion.

## Rejected / diagnostic evidence

- `run/retail-pipboy-clean-save341-20260802-091809/retail`
  preserves the clean retail pose and inventory telemetry, but the natural
  unattended run reaches physical mode 3 without populating the rendered menu
  manager. The CRT remains blank and Tab does not complete the lower cycle.
  Keep the run for diagnosis; never label it a parity pass.
- The unsynchronized blank-screen retail/OpenMW diagnostic was removed after
  review. Do not surface or package blank, mismatched or rejected frames merely
  to demonstrate that comparison tooling runs.
- `run/opennv-pipboy-retail-exact-lifecycle-20260802-092429` regressed by
  applying the retail waver to all bones and moving the device offscreen.

## Retail facts already measured

- Clean Save 341 contains 21 positive inventory records.
- JohnnyGuitar NVSE source confirms retail `TogglePipBoy` calls
  `InterfaceManager::OpenPipboy` at `0x0070F4E0` and
  `InterfaceManager::ClosePipboy` at `0x0070F690`. The isolated oracle now
  exposes those exact native entrypoints; its deployed DLL is SHA-256
  `D7741E179900327E1DA723B7F82B13B7F238777970F16F2685D71D7C9E222E2E`.
- On the clean fixture the native open reaches physical modes 1/2/3. The
  unattended renderer misses the terminal menu callback; invoking that one
  retail callback once produces 59 mode-3 snapshots with the Stats menu
  visible and 38 snapshots with the held Pip-Boy animation. This is diagnostic
  progress, not a passing lifecycle.
- Native close reaches mode 4, but the unattended run still misses the
  completion event and remains physically open. Direct Tab key state also does
  not close after the diagnostic rendered-menu callback. The validator correctly
  rejects every such run because `after-lower` is not closed.
- Observed type families include armor, weapons, ammo and ingestibles.
- Retail input telemetry during F1/F2/F3/list navigation stayed on the held
  waver; it did not activate `pipboymanipulate.kf`. Do not invent a per-key arm
  gesture without new retail evidence.
- Current oracle inventory rows contain FormID/type/count/worn. Editor ID,
  display name, icon and effect data still need to be added or joined from the
  frozen official record corpus.

## Active failures

1. Retail unattended lifecycle does not yet populate the natural Pip-Boy menu
   manager or complete close/lower on the clean fixture.
2. No valid synchronized retail/OpenMW state pair or side-by-side video exists.
3. OpenMW pose scale/framing does not yet match the retail ballpark.
4. Full item names, icons, displayed stats and effects are not yet part of the
   paired telemetry contract.
5. The gated 9mm/varmint/Stimpak slice passes. Exhaustive remaining weapons,
   food and aid use has not been run.
6. First-person and third-person equip/aim/fire/reload/holster evidence is not
   yet paired for each weapon family.
7. The seven-panel collage compositor needs a layout fix; native frames remain
   valid.

## Next executable steps

1. Fix the xNVSE natural lifecycle path on clean Save 341. Require manager/menu
   visibility, nonblank native screen, navigation state change, and a verified
   post-lower world state. Do not weaken the validator or use the sticky forced
   manager as evidence.
2. Extend the retail item snapshot with authoritative record identity and UI
   fields; generate the clean-save item denominator on disk.
3. Add equivalent OpenMW telemetry keys and join by checkpoint/item/action.
4. Correct OpenMW presentation scale/framing against registered retail frames.
5. Capture sequential retail then OpenMW runs through
   `Invoke-FNVJamBackgroundCapture.ps1`; generate a labeled paired still and
   synchronized side-by-side video.
6. Expand from the clean-save inventory into the frozen official weapon and
   ingestible matrices. Exercise real production equip/use paths in both camera
   modes and retain per-row state deltas.

## Proof policy

Before every Fallout/OpenMW launch, run
`scripts/Test-FNVJamBackgroundCapture.ps1`. Launch and capture only through
`scripts/Invoke-FNVJamBackgroundCapture.ps1`, never run both engines at once,
never use Windows app control/foreground input, and never overwrite a proof
directory. A launch is not evidence without retained native sources,
telemetry, report, method declaration and passing validator.
