# FNV Seamless Exteriors and TestMap01 Gameplay Plan

Status: approved for the Phase 0 foundation; implementation in progress.
Later phase checkpoints remain review-gated.

Date: 2026-08-01

## Outcome

Fallout: New Vegas should remain continuously playable whenever the player is
visibly outdoors. Walking across an ordinary exterior cell boundary must never
show a loading screen or fade. An authored transition between separate outdoor
worldspaces, such as an open-air gate, must also complete without a loading
screen. A loading screen remains acceptable only for a deliberately classified
real doorway into or out of an interior, plus explicit operations such as
starting/loading a game or fast travel.

Before returning to quest work, `TestMap01` becomes the flat-screen vertical
slice for the normal game: native player initialization, HUD, Pip-Boy and
inventory, equipment, gunplay, AI combat, damage and death, containers and
loot, harvesting, doors, audio, pause/save/reload, and exterior streaming. The gate is
all-or-nothing: every checked-in case must pass on the same exact build and the
combined logs must contain zero warnings, errors, missing assets, fallbacks,
unknown opcodes, unsupported opcodes, skipped opcodes, or unhandled opcodes.

This is 100% of the declared TestMap01 gameplay contract. It is not a claim of
100% whole-game or quest parity; that claim remains governed by
`docs/fnv-100-percent-parity-plan.md`.

## Definitions

- **Exterior boundary**: movement between neighboring exterior CELL records in
  the same WRLD.
- **Outdoor portal**: an authored transition whose source and destination are
  both perceived as outdoors, even if the records use separate WRLDs or an
  exterior-like CELL. Open-air gates are the main example.
- **Real doorway**: a reviewed transition where the art and gameplay clearly
  enter or leave an enclosed interior. This is a policy decision, not merely a
  `CELL::isExterior()` test.
- **Seamless**: no loading GUI, wallpaper, black frame, fade, frozen presented
  frame, input discontinuity, audio reset, camera snap, or visible missing
  geometry during normal traversal.
- **Clean log**: zero warning/error/fatal records and zero compatibility
  fallback, missing asset, unsupported feature, or missing/unhandled opcode
  events. Messages may not be hidden, downgraded, filtered, or allow-listed to
  manufacture a pass.

## Scope boundary

In scope:

1. Same-worldspace exterior streaming.
2. Exterior-to-exterior and visually outdoor worldspace transitions.
3. Full normal gameplay regression in `TestMap01`.
4. Flat OpenMW first, then the same promoted behavior in OpenMW VR.
5. Official English Ultimate Edition content and its frozen load order.

Not in the first implementation:

- physically rewriting or merging Bethesda WRLD/CELL records;
- renumbering FormIDs or replacing authored quest/script references;
- removing loading from boot, manual load, fast travel, or a reviewed real
  interior doorway;
- using a proof-only player, forced equipment, neutralized actors, console
  commands, or special combat implementations to make TestMap01 pass;
- treating the existing TestMap01 renderer diagnostic as gameplay evidence.

## What exists now

### Engine path

The current source makes the two outdoor problems distinct:

1. `apps/openmw/mwworld/scene.cpp::changeCellGrid` creates a
   `Loading::ScopedLoad` for every exterior grid shift. The loading widget draws
   when synchronous work lasts long enough, so an ordinary boundary can become
   a visible loading screen.
2. The balanced FNV profile deliberately has `preload enabled = false`,
   `preload exterior grid = false`, and `preload instances = false` because the
   broad preloader was previously too expensive. Merely turning every preload
   setting on is therefore not an acceptable solution.
3. Patch `0021-Preload-ESM4-teleport-door-destinations.patch` discovers ESM4
   teleport doors and warms destination resources. It does not keep a complete
   destination scene, terrain world, physics world, or navmesh ready for an
   atomic handoff.
4. `ActionTeleport` still calls `World::changeToCell`. An exterior destination
   then goes through `Scene::changeToExteriorCell`, fades, unloads the active
   worldspace, switches terrain/worldspace state, synchronously loads the new
   grid, and enters the generic loading-screen scope.
5. Worldspace changes also affect renderer state, projectile lifetime,
   navigation, weather, water, audio, scripts/Lua, followers, the local map,
   save state, and window/HUD notifications. Suppressing the loading widget
   alone would leave a hitch and state bugs.

### TestMap01 path

The existing `Invoke-OpenNVTestMapDiagnostic.ps1` is intentionally a no-input,
renderer-only check. It uses `--skip-menu --start TestMap01`, records that normal
new-game mechanics were bypassed, and rejects only visual recovery failures.
That contract should remain unchanged.

A read-only audit of the installed base `FalloutNV.esm` on 2026-08-01 found that
`TestMap01` is a substantial exterior WRLD (`FormId:0x010d703c`), not a single
interior cell:

| Surface | Installed base-master inventory |
|---|---:|
| Exterior cells | 302 |
| Grid bounds | x `-36..51`, y `-5..35` |
| Placed references | 884 |
| NPC / creature references | 2 / 4 |
| Weapon / ammo references | 3 / 4 |
| Containers | 32 |
| Aid items | 60 |
| Activators / authored harvestables | 8 / 7 |
| Door references | 40 |
| Crafting stations | 0 |
| Teleport-door references | 0 |

Useful existing areas include the weapon/ammo/aid and harvest bench around grid `(-3, 6)`,
the weapon/container/creature area around `(-2, -2)`, the door gallery around
`(-3, -1)`, and actors around `(0, 0)`. The official map is already suitable
for most of the vertical slice. A small generated test overlay is needed only
for missing deterministic cases such as a paired outdoor portal, a real
interior-door control, armor, the official workbench/reloading bench/campfire,
terminal/furniture coverage, and repeatable combat reset. The overlay may
arrange official records; it may not replace the production mechanics being
tested, and its generated binary remains local.

The seven installed harvest references are authored pickable Nevada agave,
banana yucca, barrel cactus, coyote tobacco, honey mesquite, prickly pear, and
a second banana-yucca variant. Use these original references for the harvest
gate instead of creating substitutes.

## Architecture decision

Keep authored records and save identities intact. Do not begin by flattening all
outdoor WRLDs into one rewritten master. A data merge would create coordinate
overlap, FormID, navmesh, quest condition, weather, map-marker, enable-parent,
and save compatibility problems before it proves the basic streaming path.

Implement two engine facilities instead:

1. A budgeted exterior grid streamer for ordinary adjacent cells.
2. A staged, double-buffered exterior-worldspace handoff for classified outdoor
   portals.

The source world remains live until the destination is fully ready. At the
crossing point, the engine atomically swaps authoritative worldspace state and
applies the authored portal transform while preserving camera, velocity,
weapon, HUD, input, audio, actor, and script state. The source stays warm for a
short bounded return window. Real interior doors continue through the existing
door transition path.

## Visible automation design

Yes, the existing scripts and engine proof machinery provide most of the
orchestration needed to make the TestMap01 run visible and automatic without
desktop control.

Reuse these existing boundaries:

| Existing component | Reuse |
|---|---|
| `scripts/Invoke-FNVJamBackgroundCapture.ps1` | Canonical scenario routing, mandatory preflight, unique proof directories and no-app-control policy |
| `scripts/Invoke-OpenNVTestMapDiagnostic.ps1` | Isolated TestMap profile construction, explicit WRLD/grid resolution, native frame handling and exact-title recording patterns |
| `scripts/Invoke-FNVJamSprintProof.ps1 -FullProofDrive -SelfDrive` | Proven visible `WindowStyle Normal` launch, in-engine real-time phase driving, exact-title ffmpeg transport, semantic phase accounting and self-driven/no-host-input report fields |
| `scripts/Invoke-FNVInteractionAudit.ps1` | In-engine activation, door, actor, inventory/radio and result-gate patterns |
| `catalog/proof-harness-ui-contract.json` | Starting contract for an in-game phase dashboard and telemetry ledger |

Do not copy the current large hard-coded proof state machines into another
`Engine::frame` block. Extract a generic native `GameplayScenarioRunner` that
loads a checked-in JSON action list, resolves stable FormIDs, calls production
gameplay APIs, observes production state, and emits one structured start/result
event per action. The JSON chooses *what* to do; it cannot inject a substitute
implementation of movement, inventory, damage, AI, or combat.

Proposed additions:

- `catalog/fnv-testmap01-gameplay-scenario.schema.json`
- `catalog/fnv-testmap01-gameplay-scenario.json`
- `scripts/Start-FNVTestMapGameplay.ps1` for interactive or visible watch mode
- `scripts/Invoke-FNVTestMapGameplay.ps1` as the inner self-driven runner
- `scripts/Test-FNVTestMapGameplayContract.ps1`
- a new `TestMapGameplay` recipe and scenario routed only through
  `Invoke-FNVJamBackgroundCapture.ps1` when recording evidence

The visible command should ultimately be one line similar to:

```powershell
& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario TestMapGameplay `
  -OutputRoot .\run\opennv-testmap-gameplay-<unique>
```

The OpenMW window remains shown, normal-sized, and unfocused. The user can watch
it but should not cover, minimize, or interact with it during an evidence run.
The engine drives the player and menus directly through its normal input/action
interfaces. ffmpeg only records the exact `OpenMW` title. No Computer Use,
`AppActivate`, focus change, click, `SendInput`, or host keyboard/mouse event is
allowed.

Add a small native `TESTMAP n/N - <action> - RUN/PASS/FAIL` status strip that is
visibly separate from the normal HUD. It shows the current action, expected
result, latest measurement, clean-log count, loading-screen count and overall
verdict. The strip must hide during dedicated HUD pixel checks so it cannot
mask HUD defects. On failure, freeze only the automation sequence, leave the
ordinary game rendering responsive long enough to read the result, write the
report, and exit normally. Never freeze gameplay to conceal streaming work.

The initial visible reel should be slow enough to inspect, with a two-to-three
second hold after each result:

| Order | Visible automated action | Production result that must be checked |
|---:|---|---|
| 1 | Load and stand at TestMap01 start | Native player, world, weather, camera and normal HUD are ready |
| 2 | Walk forward and turn | Walk animation, speed, collision, camera and footsteps |
| 3 | Run, then sprint | Run/sprint speeds, animation, AP drain and recovery |
| 4 | Sneak past a target, stand, then jump | Sneak state/detection, sneak HUD, movement and landing |
| 5 | Harvest a placed plant and pick up a loose item | Activation, inventory delta, harvested state and sound persist |
| 6 | Open a container, take/return stacks and close it | Real container menu, counts, ownership and world state |
| 7 | Open Pip-Boy/inventory and equip armor | Normal tabs, selection, equip state, stats and player visual |
| 8 | Use workbench, reloading bench and campfire | Real recipe UI, requirements, ingredient consumption, output, cancel/failure behavior and station audio |
| 9 | Equip pistol, aim, fire, partial/empty reload and dry-fire | Weapon model/animation, magazine/chamber, ammo, condition, recoil, muzzle/impact/audio |
| 10 | Switch standard/AP/HP/hand-load ammo and reload | Compatible ammo selection, HUD type/count, exact consumption, effects and persistence |
| 11 | Change to rifle/shotgun, then energy weapon | Selection/hotkey, holster/draw, reload family, ammo type and firing behavior |
| 12 | Change to melee and strike a target | Swing, collision, damage, reaction and weapon condition |
| 13 | Throw/use a projectile or explosive | Inventory decrement, projectile physics, explosion, area damage and audio |
| 14 | Let a hostile detect, pursue and hit the player | AI, nav, attack, armor/limb/health damage, HUD and reactions |
| 15 | Shoot and kill a hostile | Hitscan/projectile result, damage, death, XP and combat end |
| 16 | Loot the corpse and use aid | Corpse inventory, transfer, healing/effects and HUD update |
| 17 | Run one VATS attack and return to real time | Targeting, AP cost, execution, damage and control restoration |
| 18 | Drop, pick up and re-equip an item | World reference and inventory/equipment state stay exact |
| 19 | Open/close an animated ordinary door | Animation, collision, activation and sound without teleport |
| 20 | Cross repeated neighboring CELL boundaries | Continuous world, zero loading/fade, bounded frame time and stable state |
| 21 | Cross the paired outdoor portal both ways | Seamless WRLD handoff with camera, motion, HUD, weapon, AI and audio continuity |
| 22 | Enter/leave the real interior-door control | Allowed door transition remains correct and is classified accurately |
| 23 | Manual save and normal process exit | Save succeeds, artifacts flush and exit code is zero |
| 24 | Automatic process relaunch and save load | The outer PowerShell runner relaunches by process arguments only; all persisted state is verified |
| 25 | Repeat movement, crafting, inventory, combat and both crossings | Reload did not create state drift or a clean-log regression |
| 26 | Display final checklist, hashes and verdict | Every declared action passed and every forbidden count is zero |

The PowerShell layer may start, wait for, and relaunch the process for the
save/load half. It must never control the game window or provide gameplay
input. The native runner owns all in-game actions and requests a normal save
and shutdown at a declared checkpoint.

The watch reel and the strict semantic run use the same scenario file. Watch
mode adds visible holds and the status strip; it does not relax a gate. A fast
CI mode can shorten only the display holds, never skip actions. Any newly
requested normal action is added to the checked-in denominator immediately so
"all the things" cannot silently shrink to whichever phases already pass.

### Exhaustive weapons, ammo, reload and crafting suites

The readable reel above proves the end-to-end experience, but it is not enough
to interpret "all guns and ammo" literally. Generate additional contracts from
the frozen official load order:

- `catalog/fnv-testmap01-weapon-ammo-matrix.json`
- `catalog/fnv-testmap01-crafting-matrix.json`

The engine exporter must enumerate every winning WEAP, every compatible AMMO
and alternate-ammo relationship, every reload/attack animation family, every
weapon mod, and every winning crafting recipe/station association. Newly found
records enter the denominator automatically.

For every weapon/ammo row, the automated TestMap suite checks model resolution,
equip/holster, correct ammo compatibility, standard and alternate ammo
selection, HUD identity/count, full and partial reload, per-round versus
magazine reload, empty/dry behavior, exact rounds consumed, projectile or
hitscan result, damage/effect differences, condition, weapon mods, audio, drop
and pickup, save/load and clean logs. This includes revolvers, pistols,
automatic weapons, rifles, lever actions, shotguns, energy cells, charge-based
weapons, launchers, thrown/explosive weapons and melee/unarmed families. A
record can share an equivalence-class visual observation, but its state row
still must run and pass; no official weapon or compatible ammo pair disappears
from the denominator.

Every weapon action is a two-camera gate. Equip, draw, idle, aim/iron sights,
fire/attack, recoil, reload, dry state, holster, drop and pickup must pass in
first person and third person on the same inventory state. First-person success
does not cover a missing full-body animation, and third-person success does not
cover a detached hand, bad sight alignment or incorrect viewmodel. Pip-Boy
entry, held operation and exit additionally require the complete connected
first-person arm chains; any authored third-person transition or full-body
state exposed by retail is included rather than substituted.

Aid and food are exhaustive too. Generate a row for every winning official
ALCH/ingestible record present in the fixture or selected suite. Each row checks
the retail Pip-Boy name, icon, category, displayed stats and effects; selection
and activation; exact stack decrement; HP/AP/radiation/limb and timed-effect
deltas; unavailable-use rejection; HUD feedback; first-person and third-person
use animation where retail authors one; and save/load persistence.

Each strict row produces paired retail/OpenMW evidence. Retail and OpenMW run
sequentially from declared equivalent state and emit the same checkpoint keys:
camera, animation sequence/group and normalized phase, Pip-Boy pane/submenu and
selected FormID, equipped FormID, ammo/count/condition, actor values/effects,
and action result. The validator joins on those keys and fails missing or
unequal state before visual comparison. It then retains matched native frames,
a labeled side-by-side contact sheet, and a synchronized side-by-side video.
Two unrelated successful recordings are not a parity proof.

For every crafting row, the suite checks the correct station and recipe list,
skill/perk and item requirements, exact ingredient and ammo-component
consumption, exact output/quantity/condition, insufficient-material rejection,
cancel with no mutation, repeated crafting, inventory/HUD refresh, station
sound/animation where authored, and save/load. The visible core reel includes
the official workbench, reloading bench and campfire. The exhaustive matrix
also includes every other official station/recipe category discovered in the
frozen corpus rather than relying on a hand-written list.

Both exhaustive suites remain watchable. The launcher should accept
`-Suite Core`, `-Suite WeaponsAll`, `-Suite CraftingAll`, or `-Suite All`; the
release/quest re-entry gate always selects `All`. `-Watch` slows and labels the
same actions, while the default strict run omits only the extra viewing delay.

## Phase 0 - Freeze the contracts and measure the real failures

Deliverables:

- `catalog/fnv-seamless-exterior-policy.schema.json`
- `catalog/fnv-seamless-exterior-policy.json`
- `scripts/export_fnv_exterior_transition_graph.py`
- `scripts/Test-FNVSeamlessExteriorContract.ps1`
- `catalog/fnv-seamless-exterior-telemetry.schema.json`
- `scripts/Measure-FNVSeamlessTelemetry.ps1`
- `scripts/Test-FNVSeamlessTelemetryContract.ps1`
- structured engine telemetry for loading scopes, actual loading-screen draws,
  fades, grid changes, preload state, handoff state, frame time, and memory

The transition exporter must resolve every directed XTEL edge to source door,
source CELL/WRLD, destination door, destination CELL/WRLD, reverse edge, door
base/model, lock, script, enable parent, and record provenance. Each edge then
has one reviewed policy value:

- `same-worldspace-boundary`
- `outdoor-portal`
- `real-interior-door`
- `scripted-or-unsafe`
- `unreviewed`

`unreviewed` and ambiguous edges fail closed and retain their authored
activation/loading behavior. They can never be silently guessed from record
flags or a door filename.

Baseline routes must record cold-cache and warm-cache behavior in TestMap01,
Goodsprings, and at least one official open-air cross-worldspace gate. The
report must distinguish a loading scope being entered from a loading frame
actually being drawn.

Review checkpoint 0: approve the definition of a real doorway, the initial
transition classifications, and the performance budgets before engine changes.

## Phase 1 - Make TestMap01 a normal-game vertical slice

Add a new interactive launcher, tentatively
`scripts/Start-FNVTestMapGameplay.ps1`. Do not repurpose the renderer diagnostic.
The gameplay launcher must:

- use the frozen official content/profile and the production FNV Player record;
- run the same player, mechanics, UI, input, inventory, combat, audio, and save
  initialization used by an ordinary session;
- make only the final developer-worldspace placement deterministic;
- load no proof outfit, actor neutralization, forced weather/image space,
  skipped actors, self-drive behavior, or screenshot hooks;
- accept normal keyboard/mouse input and exit normally;
- write a unique per-run profile and never mutate shared input configuration.

Add `catalog/fnv-testmap01-gameplay-contract.json` with stable FormIDs, cells,
positions, initial player inventory, targets, expected state changes, and reset
rules. A generated local test overlay may place the missing fixtures, but all
items, actors, weapons, damage, AI, UI, and persistence must use production
handlers.

The checked-in gameplay matrix must cover at least:

| Gate | Required behavior |
|---|---|
| Startup/player | Native FNV player, stats, controls, first/third person, normal input, normal exit |
| HUD | HP, AP, compass, crosshair, sneak/detection, prompts, ammo, weapon condition, messages, subtitles |
| Pip-Boy/inventory | Open/close, every pane/category, selection, equip/unequip, hotkeys, stack counts, aid, drop/pickup |
| Containers/loot | Open, transfer both directions, stack merge/split, ownership/lock behavior, corpse loot |
| Harvesting/activation | Harvest flora, pick up loose objects, use ordinary activators, persist the changed world/inventory state |
| Equipment | Armor and representative melee, pistol, rifle/shotgun, energy, projectile/explosive families |
| Crafting | Workbench, reloading bench, campfire and every corpus-discovered station/recipe; requirements, components, outputs, cancel/failure and persistence |
| Gunplay | Change weapons/ammo, draw/holster, aim/iron sights, fire, exact ammo decrement, every reload family, dry fire, muzzle/audio, projectile/hitscan collision |
| Combat | Detection, pursuit, attacks, player/actor damage, limb/armor effects, stagger/reaction, death, XP, loot |
| VATS | Enter, target, AP cost, execute/cancel, damage result, return to ordinary control |
| Movement/world | Walk/run/sprint, jump, sneak, collision, water/terrain, repeated adjacent-cell crossings |
| Doors | Animated non-teleport door, real interior-door control, outdoor-portal control, lock/key/script preservation |
| Persistence | Manual save, quit, cold reload, inventory/ammo/health/death/reference/worldspace state preserved |
| Presentation/audio | World, actor, weapon, HUD and menu rendering plus UI, weapon, impact, actor and ambient audio |

Every row receives exact setup, action, expected state delta, telemetry, visual
or audio check where applicable, save/reload check, and a binary pass/fail. No
`partial`, `mostly works`, or warning-bearing pass is allowed.

Review checkpoint 1: interactively play the first complete TestMap01 route and
agree that it represents normal gameplay before automating it.

## Phase 2 - Remove same-worldspace boundary loading

Replace the current boundary-time synchronous ring load with a budgeted state
machine:

1. Predict the next ring from player position, velocity, and maximum legal
   movement speed.
2. Prepare terrain, meshes, textures, instances, collision, scripts, and
   required navmesh tiles before the player reaches the commit line.
3. Keep a one-cell guard ring staged outside the authoritative active grid.
4. Promote the staged ring atomically on boundary crossing.
5. Retire cells behind the player incrementally under a per-frame budget.
6. Precompile required graphics objects so shader/GL compilation is not moved
   to the crossing frame.

`changeCellGrid` must not create a GUI loading scope for a normal neighboring
boundary. This removal is permitted only after readiness telemetry proves the
destination ring is complete; hiding the widget while retaining synchronous
work is a failure.

The streamer must enforce explicit RAM/VRAM, cell-count, work-queue, and
per-frame CPU budgets. This replaces the previous all-or-nothing preload switch
and addresses why broad FNV preloading is currently disabled.

Phase 2 acceptance on the agreed reference machine:

- cold start, warm start, run, sprint, and direction-reversal routes;
- at least 100 consecutive TestMap01 boundary crossings and a 30-minute soak;
- zero loading GUI frames and zero fades;
- zero visibly repeated/frozen presented frames;
- target p99 frame time at or below 16.7 ms and hard crossing-frame maximum at
  or below 33.3 ms at the 60 FPS profile;
- no missing terrain/objects, collision holes, actor duplication, AI reset,
  script loss, audio reset, or state drift;
- bounded memory reaches a stable plateau rather than growing with distance.

Review checkpoint 2: compare the cold-cache boundary loop before and after and
approve the frame-time/memory result.

## Phase 3 - Make outdoor worldspace portals seamless

Add a `SeamlessExteriorTransition` path selected only by the reviewed policy.
It needs a complete destination bundle, not just resource-cache entries:

- destination exterior cells and references;
- terrain and distant presentation needed at the gate;
- physics/collision and required navmesh;
- sky, weather, region, water and image-space state;
- audio environment and music continuity;
- scripts/Lua, enable state, actors/followers and local-map state;
- renderer compilation/readiness and a bounded reverse-transition cache.

Use the paired door transforms to compute the rigid source-to-destination
mapping. At handoff, preserve player-relative position, yaw/pitch, velocity,
camera mode, weapon state, current animation, ammo/reload state, HUD state,
input state, effects, combat, followers, and pending authored events. Change the
authoritative CELL/WRLD and save identity exactly once. Do not clear projectiles
or combat merely because the WRLD changed unless retail content explicitly
requires it.

Implement this in two risk-controlled slices:

1. Preserve the authored activation key but remove the fade/loading screen and
   perform the ready atomic handoff.
2. For policy rows explicitly marked `walkThrough: true`, add a crossing plane
   so an open-air gate can be walked through without pressing Activate. Fire the
   authored activation/script events exactly once and retain locks, enable
   parents, quest conditions, sounds, and reverse travel.

If the destination is not ready, the transition must not show a loading screen
or expose an incomplete world. The test should fail with readiness telemetry so
the preload distance/budget or implementation is fixed. Shipping an invisible
freeze, fake fade, or input lock is not a fallback.

Phase 3 acceptance:

- paired TestMap01 outdoor portal crossed in both directions at least 50 times;
- one official open-air gate, then every reviewed official outdoor edge;
- zero loading GUI/fade/black/frozen frames and zero camera snap;
- transform, velocity, HUD, weapon/ammo, audio, AI/combat, follower, script and
  enable state continuity;
- save on both sides, quit, reload, and reverse-travel persistence;
- the real-interior-door control still uses its allowed transition and remains
  functionally correct.

Review checkpoint 3: choose whether each official gate should retain Activate
or become true walk-through after seeing both behaviors in the TestMap fixture.

## Phase 4 - Zero-tolerance TestMap01 release gate

Add a semantic runner and log auditor. Any future video/screenshot proof must be
declared as a new scenario in
`catalog/fnv-jam-background-capture-recipes.json` and routed through
`scripts/Invoke-FNVJamBackgroundCapture.ps1`. It must use in-engine self-drive
plus native/exact-title capture and obey `docs/fnv-jam-background-capture.md`;
Windows app control and foreground input remain forbidden. The ordinary
interactive launcher is separate and does not capture proof.

The auditor must consume stdout, stderr, `openmw.log`, structured engine events,
and the test report. The run fails on:

- any warning, error, fatal, assertion, exception, crash or nonzero exit;
- `missing`, `failed to load`, placeholder, fallback, unresolved, unsupported,
  unimplemented, unknown, skipped, or ignored compatibility behavior;
- any missing/unhandled script, result-script, condition, or VM opcode;
- any absent required telemetry or unvisited gameplay matrix row;
- any loading GUI/fade during an exterior boundary or outdoor portal;
- any artifact/config/content/binary provenance mismatch.

Use structured severity and event codes where possible. Do not pass by regex
excluding a known warning, changing its severity, or disabling the subsystem
that emits it. Fix the source cause.

The opcode claim has two explicit denominators:

1. **TestMap runtime cleanliness:** zero missing/unsupported/unhandled opcode
   events in every TestMap01 run.
2. **Whole official corpus completeness:** the frozen Ultimate Edition audit
   has zero unknown or unimplemented opcode frames before anyone claims global
   opcode completeness. Unexercised quest opcodes do not make the TestMap gate
   red, but they remain visible in the whole-game ledger and prevent a global
   100% claim.

The release candidate must pass three cold runs, three warm runs, save/quit/load
replay, the boundary and portal stress loops, a 30-minute combat/streaming soak,
all focused unit/integration tests, and the full existing `openmw-tests` suite
on one exact executable and profile. Every artifact and input is hashed.

## Quest-work re-entry gate

Quest implementation/testing resumes only when all of the following are green
on the same promoted flat build:

1. Every TestMap01 gameplay matrix row passes.
2. The zero-tolerance log auditor reports exactly zero findings.
3. Same-WRLD exterior boundaries meet the seamless and frame-time contract.
4. The TestMap outdoor portal passes both ways; the representative official
   gate passes both ways.
5. The real-interior-door control still works.
6. HUD, inventory, equipment, gunplay, combat, VATS, loot, audio and
   save/reload remain green after streaming and portal changes.
7. The generated exhaustive weapon/ammo/reload and crafting matrices have no
   missing or failing official rows.
8. Focused tests and the complete existing engine regression suite pass.
9. Flat evidence is reviewed and the patch queue contains the exact promoted
   source diff.

After that freeze, quest work returns to the Goodsprings spine. The complete
TestMap01 gate runs before every quest-campaign promotion so a quest fix cannot
silently regress ordinary play or seamless travel.

## Source and repository slices

Expected engine surfaces:

- `apps/openmw/mwworld/scene.cpp/.hpp`
- `apps/openmw/mwworld/cellpreloader.cpp/.hpp`
- `apps/openmw/mwworld/actionteleport.cpp/.hpp`
- `apps/openmw/mwworld/worldimp.cpp/.hpp`
- rendering terrain/worldspace activation and compile queues
- navigator/recast worldspace switching
- weather, water, audio, projectiles, mechanics/followers, Lua and save state
- loading-screen structured telemetry
- focused `apps/openmw_tests` coverage

Repository-owned work stays in small replayable `patches/openmw` topics, with
contracts/catalogs/scripts in this repository. The external OpenMW checkout is
build state, not the source of truth. Existing public-safe and patch ownership
rules remain in force.

## Main risks and required defenses

| Risk | Defense |
|---|---|
| RAM/VRAM spike from two resident worlds | Explicit budgets, small portal radius, bounded reverse cache, plateau soak |
| Moving the hitch off-screen without removing it | Frame-time and presented-frame telemetry; readiness required before commit |
| Thread-unsafe object/physics/nav construction | Stage immutable data off-thread; perform bounded authoritative attachment on the engine thread |
| Duplicate actors or script events | One authoritative scene, transition transaction ID, exactly-once event tests |
| Save corruption or FormID drift | Preserve original CELL/WRLD/ref IDs and round-trip saves on both sides |
| Weather/audio/camera pop | Stage both environments and test continuity at the exact handoff frame |
| Gate scripts/locks bypassed by walk-through | Per-edge policy, normal activation predicates, exactly-once script dispatch |
| Test fixture hides a real defect | Fixture only arranges official records; production handlers and normal player state are mandatory |
| Warning suppression creates a false green run | Empty allowlist, structured strict mode, source fix required |

## Decisions for our review

Recommended defaults are listed first:

1. **Real doorway rule:** reviewed visual/gameplay policy, not CELL flags alone.
2. **Initial gate behavior:** prove activation-preserving no-screen handoff, then
   enable true walk-through per reviewed gate.
3. **World architecture:** preserve WRLD/FormID identity with staged handoff;
   do not merge masters.
4. **TestMap fixture:** allow a minimal generated local overlay for missing
   cases while keeping every mechanic on production code.
5. **Performance gate:** 60 FPS target, p99 <= 16.7 ms and crossing max <= 33.3
   ms on the agreed reference machine.
6. **Quest pause:** no quest promotion until the complete TestMap01 and
   seamless-travel re-entry gate is green.
7. **First official rollout edge:** choose one open-air gate from the generated
   transition graph after reviewing its scripts, locks, reverse edge, and art.
8. **Visible automation:** one catalog drives both the slow watch reel and the
   strict self-driven proof; normal HUD stays enabled and desktop input remains
   forbidden.
