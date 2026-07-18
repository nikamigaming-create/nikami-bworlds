# FNV Goodsprings Batch Loop

Status: controlling diagnostic loop as of 2026-07-18

This loop uses flat OpenMW as the fast diagnostic bench and OpenMW VR as the
acceptance surface. It replaces free-form walkarounds and unbounded logging
with one repeatable route, state-change telemetry, evidence-backed fix batches,
and an identical replay after every build.

## Evidence lanes

| Lane | Purpose | May drive state directly? | Can earn parity credit? |
|---|---|---:|---:|
| Flat diagnostic | Locate the failing subsystem quickly | Yes, when labeled | No |
| Flat natural replay | Prove authored mouse/keyboard gameplay | No | Engineering gate only |
| VR natural replay | Prove hands, pointer, menus, HUD, performance, and gameplay together | No | Yes, when all provenance and differential requirements pass |

Diagnostic actions such as direct activation, positioning, or quest-stage
inspection must be recorded in the manifest. They may identify a defect but
must never turn a natural gate green.

## Fixed Goodsprings town loop

Every build replays these checkpoints in this order on an isolated level-one
profile. The route fails at the end rather than aborting at the first failed
checkpoint so one run produces a useful repair batch.

1. Exterior settle and four-direction sky/horizon sweep.
2. Repeat the General Store and Saloon facade views with HUD hidden, HUD shown,
   and a UI quad open. Capture scenery visibility, depth, alpha, and material
   state at each view.
3. Observe two town actors for an authored package interval. Record package,
   target, requested movement, actual displacement, equipment/prop state,
   animation group, and facing.
4. Complete one Easy Pete dialogue branch and one Sunny/Trudy branch. Record
   the visible choice list, selected INFO, response text, voice/LIP lifecycle,
   result script, topic refresh, goodbye, and actor facing.
5. Open Chet barter. Record merchant/player item counts, both pane row counts,
   prices, caps, one buy delta, one sell delta, close, and reopen persistence.
6. Exercise inventory tabs plus one equip, unequip, use, and drop operation.
   Record item and equipment deltas and the visible selected row.
7. Traverse the General Store, Saloon, and Schoolhouse door pairs in and out.
   Record source reference, XTEL destination, enable/lock state, destination
   activation, player cell, and actor population after each transition.
8. Activate the radio, workbench, and reloading bench. Record action type,
   opened UI or playing sound, available rows, one valid operation when the
   authored inventory permits it, and clean cancellation.
9. Run one bounded hostile encounter. Record detection, combat target, path
   request, requested movement, actual displacement, weapon draw/equip,
   attack start, attack event, hit, damage delta, hit reaction, death, and loot.
10. Save, quit normally, relaunch, reload, walk, reopen inventory, and traverse
    one door. Record persisted cell, quest, inventory, equipment, actor, and
    interactable state.

## Bounded telemetry contract

Telemetry is emitted only when a tracked value changes, a checkpoint begins or
ends, a timeout fires, or a final result row is written. Per-frame actor,
animation, skin, material, and nearby-reference chatter stays disabled.

Every event contains:

- run ID, build commit and binary hash;
- checkpoint and gate ID;
- game time and monotonic elapsed time;
- authored FormID/cell/package/INFO identity where applicable;
- previous and next state;
- pass, fail, timeout, or diagnostic-only classification; and
- a concise failure reason.

The run writes one JSON manifest containing every gate, not a verdict inferred
from log text. Screenshots are limited to the fixed rendering and UI
checkpoints. A normal exit and unchanged input hashes are mandatory.

## Repair cadence

1. Baseline the current build with the complete flat diagnostic loop.
2. Group three to five failures by root cause and dependency layer.
3. Make only evidence-backed changes for that batch.
4. Run focused tests, compile once, and commit the exact slice.
5. Replay the identical flat loop. Regressions reject the batch.
6. When affected flat gates are green, deploy the same commit to VR and replay
   the same natural route.
7. Update the ledger and percentages only from accepted manifests.
8. Expand the route only after the current slice is stable.

The first batch is actor locomotion/combat-package execution, renderer/HUD
visibility, and dialogue/barter selection and population. The second route is
world access: the observed vault and Strip doors, their enable parents, XTEL,
lock, condition, quest, and script gates.

## Progress rule

Engineering coverage and certified parity are always reported separately.
Finding a bug, implementing code, compiling, or passing a driven diagnostic
does not increment either numerator by itself. A capability advances only when
its checked-in gate and required lifecycle replay pass on the same immutable
build. Certified parity remains the minimum across all required axes and
content families.

