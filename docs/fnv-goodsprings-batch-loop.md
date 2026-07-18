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

## Frozen town inventory and interaction matrix

The retail record census contains 42 authored actor placements in the town
slice: 21 humanoids and 21 creatures. Inventory completeness is 42/42, but it
does not count as behavioral parity.

The natural dialogue matrix contains 12 targets: Doc Mitchell, Sunny Smiles,
Trudy, Joe Cobb, Ringo, Chet, Easy Pete, four Goodsprings settlers, and the
active Victor reference. Each target must be tested in every authored
enabled/disabled quest-state variant. Cheyenne and ambient/hostile creatures
remain in the activation and combat matrices but are not normal dialogue-menu
targets.

Every dialogue target must pass all of these assertions:

- the authored reference is enabled exactly when its conditions require;
- natural activation opens the correct ESM4 greeting;
- every visible prompt maps to the same topic and INFO FormIDs as the response;
- quest-owner and INFO conditions are both evaluated against the actor/player;
- result scripts and quest, local, inventory, caps, and enable-state deltas persist;
- right-side choices rebuild after every response without display-text collisions;
- voice and LIP drive the matching expression/phoneme lifecycle;
- the actor looks toward the player during dialogue and resumes its package afterward;
- Chet, Doc, and Trudy expose their authored barter inventory and caps; and
- save/quit/reload preserves the resulting dialogue and quest state.

## Regression-first invariants

The initial port already rendered ordinary furniture and clutter. Actor-package,
paging, HUD, and material work may not replace that working behavior with a new
special case. These invariants are now mandatory:

1. A live reference is either individually rendered or represented by a current
   visible paging chunk, never neither and never both. Stale cached chunks cannot
   suppress current chairs, crates, rocks, doors, or flags.
2. HUD, menu, dialogue, and VR quads never write world depth or mutate a world
   object's node mask, cull state, material, or transparency.
3. Human and creature DATA positions are root/feet or authored contact pivots.
   Capsule centers and half-heights are never added to DATA. Furniture and perch
   markers own their authored height.
4. Cell re-entry retains a matching active furniture claim, phase, anchor, and
   animation. Easy Pete must remain in `chairsit` after two Saloon round trips and
   after save/quit/reload.
5. The Nevada flag remains one world reference with its intentional front/back
   faces deforming together. Paging may not overlap a static copy with the live
   animated copy.
6. Interior entry immediately replaces the exterior image-space grade and
   composes XCIM plus LTMP/LNAM inheritance. Exterior color state cannot leak
   into Doc Mitchell's house.

Exact transition probes include Easy Pete chair `0x10634A`, exterior chairs
`0x106349` and `0x106348`, crates `0x10B8CF` and `0x10B8D0`, raven perch crate
`0x10B1B3`, Nevada flag `0x10A18D`, and Doc's shell refs `0x174771`, `0x103E19`,
`0x103E1B`, `0x103E1F`, `0x174772`, `0x103E60`, `0x103E20`-`0x103E2F`,
`0x103E32`-`0x103E33`, and `0x103E5F`-`0x103E67`.

## Current immutable diagnostic baseline

Engine commit `aa5b9294c14f54f4525dc0d4017e276cfde4d6aa` passed 699 unit tests and was
deployed to both flat and VR executables. The bounded flat interaction run at
`run/fnv-interaction-audit-aa5/20260718-092130` passed its narrow Easy Pete,
quest-notification, Saloon population, radio, and door circuit. It is diagnostic
evidence only: the capture also proves that Pete can return standing on his chair,
so the complete town gate remains red.

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
