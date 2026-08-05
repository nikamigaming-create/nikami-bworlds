# FNV Real-Save Pip-Boy and Fast-Travel Luna Max Plan

Status: active execution plan as of 2026-08-02

Owner model: Luna Max (or any successor agent continuing the persistent goal)

## Goal

Establish one canonical real-world Fallout: New Vegas save in OpenMW, verify
its inventory and discovered map-marker parity against retail, make Pip-Boy
fast travel and item equip/use/reload/fire work through production paths in
first and third person, and finish with strict unattended evidence plus a
playable handoff.

This is an execution queue, not a design essay. Work one numbered bite at a
time. A bite is complete only when its named artifact and gate exist on disk.

## Luna Max: start here

1. Set working directory to `D:/code/nikami-worlds` and read the repository
   `AGENTS.md` instructions supplied by the task environment.
2. Read this entire file, then
   `docs/fnv-real-save-pipboy-fast-travel-progress.md`, then
   `docs/fnv-jam-background-capture.md` before any game capture.
3. Run `scripts/Test-FNVRealSaveLunaReadiness.ps1`. It must produce a passing
   `run/fnv-real-save-campaign/luna-readiness.json` before any edit or build.
4. A01 and A02 are complete. Current first action is `A03 — Produce the
   Save330 denominator`. Do not redo A01/A02, launch a game, research retail,
   create another plan, or write a second save parser.
5. Mark A03 `IN PROGRESS` in the ledger, export the already-decoded native
   `FalloutSaveLoadPlan`, verify A03's gate, mark it `PASS`, and immediately
   continue A04 while dependencies remain satisfied.
6. Reuse the tool/code map below before creating any script, parser, runner,
   test, telemetry schema, or UI path.
7. Make source edits with `apply_patch`. Preserve both dirty working trees.
8. During long builds/captures, send a concise progress update at least every
   60 seconds. Do not narrate every command.
9. Do not stop after producing a plan, a launch, or a screenshot. Continue
   until a gate passes or a concrete blocker requires new user authority.
10. The user wants playable progress. Prefer the smallest production-state
    bite that advances normal Save330 play, fast travel, Pip-Boy inventory, or
    weapon use; never replace it with a synthetic showcase claim.

## Non-negotiable operating rules

1. Before any Fallout/OpenMW screenshot or video launch, read
   `docs/fnv-jam-background-capture.md` and run
   `scripts/Test-FNVJamBackgroundCapture.ps1` with `-RuntimeReady -RequireIdle`.
2. Capture only through `scripts/Invoke-FNVJamBackgroundCapture.ps1`. Never
   launch retail and OpenMW captures concurrently. Never use Windows app
   control, focus changes, clicks, `SendInput`, or foreground input injection.
3. Never overwrite a proof directory. Every run gets a UTC-stamped directory.
4. Never infer success from an action schedule. Require before/after production
   state: FormID, count, slot, magazine/reserve, HP, cell/worldspace, marker
   state, position, game time, and save/reload persistence as applicable.
5. Preserve all existing user changes. Do not reset either working tree.
6. Do not promote a run containing a false gate, missing artifact, synthetic
   fallback inventory, mismatched save hash, or an unexplained crash.
7. Keep `docs/fnv-real-save-pipboy-fast-travel-progress.md` current after every
   bite so a new model can resume without reading chat history.

## Canonical save decision

### Primary fixture: Save 330

- Source:
  `C:/Users/nbrys/OneDrive/Documents/My Games/FalloutNV/Saves/Save 330     Goodsprings  00 16 45.fos`
- Bytes: `3,395,328`
- SHA-256:
  `07DBDD2D7C4ABE3160628E5463A9603A40F4271042C1DA1B89F1C4A4F7DBD81F`
- Embedded play state: Goodsprings, `00:16:45`.
- Masters: exactly the ten official Ultimate Edition ESMs.
- Reason: meaningful real-world state, official-only load order, and existing
  hash-locked Save330 parser/camera/world provenance throughout the repo.

Create a read-only named fixture copy under
`local/retail-real-save-fixtures/NikamiRealWorldSave330-20260802.fos`. Never
modify or replace the source save. Record both hashes in the progress ledger.

### Rejected as the primary fixture

- `Save 219   Courier  Mojave Wasteland  16 25 32.fos`: useful personal
  campaign history, but it requires 67 masters, including YUP, VNV, weather,
  movement, UI, LOD, postgame, and content-restoration mods. Do not silently
  strip or remap it. It may become a later mod-compatibility fixture.
- `Save 341     Goodsprings  00 02 00.fos`: clean official-only Pip-Boy retail
  oracle, but too early and sparse for the real-game campaign.
- `Save 280     Mojave Wasteland  00 05 03.fos`: official-only fallback if an
  evidenced Save330 branch cannot be supported without widening the parser.

## Existing tool and code map — reuse this, do not reinvent it

### Repository roots and promoted inputs

| Purpose | Exact path |
|---|---|
| Worlds/capture repository | `D:/code/nikami-worlds` |
| Active OpenMW engine tree | `D:/code/nikami-openmw-save330-integrated` |
| Engine base commit | `5fb9e4e0aa50cda266a5ddc264d6eb166bf5f507` |
| Current passing runtime | `local/openmw-pipboy-item-gates-20260802-111400` |
| Current runtime SHA-256 | `FE553A1598AC82A5DF2E5FD2452CD9C8E725566FCAE12A7F247BBD99DD71A778` |
| Official FNV data | `D:/SteamLibrary/steamapps/common/Fallout New Vegas/Data` |
| Save330 source | `C:/Users/nbrys/OneDrive/Documents/My Games/FalloutNV/Saves/Save 330     Goodsprings  00 16 45.fos` |
| Clean retail Pip-Boy fixture | `local/retail-pipboy-fixtures/NikamiCleanPipBoyOracle-20260802.fos` |
| Latest passing item proof | `run/opennv-pipboy-item-use-reload-gate-20260802-111500/openmw` |

Both repositories are intentionally dirty. Inspect and preserve all existing
changes. Never use `git reset --hard` or discard unrelated modifications.

### Capture and profile tools

| Need | Reuse |
|---|---|
| Mandatory capture rules | `docs/fnv-jam-background-capture.md` |
| Preflight before every capture launch | `scripts/Test-FNVJamBackgroundCapture.ps1` |
| Only public capture entry point | `scripts/Invoke-FNVJamBackgroundCapture.ps1` |
| Canonical recipe data | `catalog/fnv-jam-background-capture-recipes.json` |
| Current OpenMW Pip-Boy runner internals | `scripts/Invoke-OpenNVPipBoyShowcaseCapture.ps1` |
| Retail Pip-Boy runner internals | `scripts/Invoke-FNVRetailPipBoyStateCapture.ps1` |
| Official OpenNV profile generator | `scripts/Initialize-OpenNVBaseProfile.ps1` |
| Save master parser/orderer | `scripts/FNVSaveProfile.ps1` |
| Save-profile deterministic test | `scripts/Test-FNVSaveProfile.ps1` |
| Existing synthetic Courier save helper | `scripts/Invoke-OpenMWFNVCourierSave.ps1` |
| Existing broad interaction diagnostic | `scripts/Invoke-FNVInteractionAudit.ps1` |
| Existing playable-session diagnostic | `scripts/Invoke-PlayableSessionBaseline.ps1` |
| Luna workspace/tool readiness gate | `scripts/Test-FNVRealSaveLunaReadiness.ps1` |
| Retail/OpenMW comparator | `scripts/compare_fnv_paired_proofs.py` |
| Registered pair renderer | `scripts/render_fnv_retail_openmw_pair.py` |
| Dense Pip-Boy contact sheet | `scripts/New-FNVPipBoyDenseContactSheet.ps1` |
| Official winning-record corpus export | `scripts/export_fnv_parity_corpus.py` |

`Invoke-OpenMWFNVCourierSave.ps1` creates a synthetic level-one loadout and is
useful for persistence diagnostics. It is not a substitute for Save330 and
cannot earn the real-save gates in this plan. Likewise, the current Pip-Boy
showcase is a focused interaction harness, not the Save330 inventory model.

### Production source entry points

| System | Existing source; extend here first |
|---|---|
| Native FNV save decoding | `components/esm4/fonvsavegame.cpp`, `components/esm4/fonvsavegame.hpp` |
| Save validation/publication | `apps/openmw/mwworld/fnvsavepreflight.cpp`, `apps/openmw/mwworld/fnvsavepreflight.hpp` |
| Immutable native player payload | `apps/openmw/mwworld/fnvplayerstate.cpp`, `apps/openmw/mwworld/fnvplayerstate.hpp` |
| Mutable player/marker persistence | `apps/openmw/mwworld/fnvplayerruntimestate.cpp`, `apps/openmw/mwworld/fnvplayerruntimestate.hpp` |
| Save application/world transitions | `apps/openmw/mwworld/worldimp.cpp`, `apps/openmw/mwworld/worldimp.hpp` |
| Fast-travel pure resolution | `apps/openmw/mwworld/fnvfasttravel.cpp`, `apps/openmw/mwworld/fnvfasttravel.hpp` |
| Pip-Boy world-map UI/confirmation | `apps/openmw/mwgui/mapwindow.cpp`, `apps/openmw/mwgui/mapwindow.hpp` |
| Physical Pip-Boy state/actions | `apps/openmw/mwgui/windowmanagerimp.cpp`, `apps/openmw/mwgui/windowmanagerimp.hpp` |
| Inventory slots/ammo/magazines | `apps/openmw/mwworld/inventorystore.cpp`, `apps/openmw/mwworld/inventorystore.hpp` |
| Reload/fire/controller state | `apps/openmw/mwmechanics/character.cpp`, `apps/openmw/mwmechanics/character.hpp` |
| Proof schedule only | `apps/openmw/engine.cpp` |
| Pip-Boy CRT and limb display | `apps/openmw/mwrender/renderingmanager.cpp` |
| First/third-person attachments | `apps/openmw/mwrender/animation.cpp`, `apps/openmw/mwrender/esm4npcanimation.cpp` |
| Retail state oracle | `oracles/xnvse/nvse_retail_oracle/main.cpp` |

Do not put production mechanics in `engine.cpp`; it may schedule and audit a
proof, but the same operation must work from normal UI/input without proof
environment variables.

### Existing focused tests

| Slice | Existing test source |
|---|---|
| Exact native saves | `apps/components_tests/esm4/fonvsavegame.cpp` |
| Save preflight | `apps/openmw_tests/mwworld/testfnvsavepreflight.cpp` |
| Player payload | `apps/openmw_tests/mwworld/testfnvplayerstate.cpp` |
| Runtime player/marker persistence | `apps/openmw_tests/mwworld/testfnvplayerruntimestate.cpp` |
| Fast-travel resolution | `apps/openmw_tests/mwworld/testfnvfasttravel.cpp` |
| Inventory containers | `apps/openmw_tests/mwworld/testcontainerstoreesm4.cpp` |
| Inventory list policy | `apps/openmw_tests/mwgui/testinventorylistpolicy.cpp` |
| Weapons/reload/fire/damage | `apps/openmw_tests/mwmechanics/testfalloutcombat.cpp` |
| Weapon animation selection | `apps/openmw_tests/mwrender/testfalloutweaponanimation.cpp` |
| Player visual policy | `apps/openmw_tests/mwrender/testplayervisualpolicy.cpp` |

Build test executables only when needed:

```powershell
cmake --build MSVC2022_64 --config RelWithDebInfo --target components-tests -- /m:1
cmake --build MSVC2022_64 --config RelWithDebInfo --target openmw-tests -- /m:1
```

Run the smallest GoogleTest filter matching the edited source before a full
suite. Build OpenMW serially on this machine to avoid the observed shared-PDB
collision:

```powershell
cmake --build MSVC2022_64 --config RelWithDebInfo --target openmw -- /m:1
```

If a timed-out shell leaves `MSBuild.exe` or `cl.exe` alive, inspect command
lines and ownership before stopping only the orphaned build processes. Never
start a second parallel build against the same PDB.

### Known-good telemetry contracts already implemented

- Pip-Boy selection event contains pane/submenu/row/result and before/after
  right-hand FormID, ammunition FormID, loaded rounds, Stimpak count, and HP.
- Passing selected FormIDs are 9mm pistol `0x010E3778`, varmint rifle
  `0x0107EA24`, 9mm ammo `0x0108ED03`, and 5.56 ammo `0x01004240` in the current
  runtime load order.
- Passing Stimpak delta is count `5 -> 4`, HP `75 -> 100`.
- Passing varmint reload delta is magazine `0 -> 5`, reserve `60 -> 55`.
- The capture validator now requires these interaction deltas in both lifecycle
  and complete-panel modes. Do not weaken it.
- Fast-travel runtime state already uses marker states `0=hidden`, `1=visible`,
  `2=visible+travel`; it already persists map marker states and scripted
  `EnableFastTravel` state.
- `MapWindow` already renders native markers, requests confirmation, and calls
  `World::fastTravelToFalloutMapMarker`; extend and prove this path instead of
  writing another map UI.
- `World` already performs proximity discovery and destination resolution.
  Save restoration and natural UI proof are the first unknowns, not whether a
  fast-travel class exists.

### Rejected approaches and traps

1. Do not use Save219 for the official campaign lane; its 67-master mod stack
   changes records, scripts, UI, weather, movement, LOD, and world state.
2. Do not go back to deleted/tainted Save331 or unnamed oracle copies.
3. Do not use TestMap placement as evidence for Save330 loading or fast travel.
4. Do not unlock all map markers with `OPENMW_FNV_UNLOCK_ALL_MAP_MARKERS` (or an
   equivalent proof switch) in a natural restoration gate.
5. Do not call `showFalloutMapMarker` to make C04 pass; C04 must select a marker
   restored/discovered by production state. Direct discovery remains diagnostic.
6. Do not report the 2026-08-02 11:03 full-panel run as an interaction pass. It
   exposed a validator bug and stale-controller reload. The corrected passing
   lifecycle run is `...-111500`.
7. Do not add a `std::vector` directly into `ESM4::Potion` merely to parse ALCH
   effects without rebuilding/auditing all record consumers. That experiment
   crashed at the ALCH load boundary and was removed. Build a reviewed record
   schema/action path with deterministic parser tests.
8. Do not infer reload from `requested=1`. Require matching loaded/reserve
   conservation after the selected weapon controller settles.
9. Do not accept screenshots with blank CRT, clipped screen edges, detached
   limbs, stale/duplicate weapons, T-pose, or collage-label overlap.
10. Do not delete personal saves. Only create immutable fixture copies and
    generated OpenMW campaign saves under named repo paths.

### Exact capture command pattern

After B01 adds the `RealSave` scenario, every unattended OpenMW run follows
this shape with fresh paths:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario RealSave `
  -SavePath '<immutable Save330 fixture>' `
  -OpeningRuntimeRoot '<staged runtime>' `
  -RuntimeReady -RequireIdle

& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario RealSave `
  -SavePath '<immutable Save330 fixture>' `
  -OpeningRuntimeRoot '<staged runtime>' `
  -OutputRoot '.\run\fnv-real-save-campaign\<unique-run-id>'
```

Parameter names may be finalized in B01, but preflight, immutable hash lock,
single-engine execution, native state retention, and unique output are fixed.

## Churn protocol

For every bite:

1. Mark exactly one row `IN PROGRESS` in the progress ledger.
2. Run the smallest existing deterministic test that can fail for the defect.
3. Add or strengthen a test before changing production behavior when feasible.
4. Make one cohesive production change; do not mix visual tuning, save parsing,
   fast travel, and combat in one patch.
5. Build once, then rerun the focused tests.
6. If a game launch is needed, run mandatory preflight and use a fresh proof
   root through the canonical entry point.
7. Inspect telemetry and native frames. Record exact pass/fail facts.
8. Update the progress ledger, including the next bite and blocker if any.
9. Continue immediately to the next unblocked bite. Do not repeatedly rerun an
   unchanged failing build.

Failure loop: reproduce -> isolate one state transition -> add gate -> patch ->
focused test -> build -> canonical run -> inspect -> record -> next bite.

## Phase A — Freeze and understand the real save

### A01 — Freeze Save330

- Copy Save330 to the named fixture path without altering the original.
- Write `run/fnv-real-save-campaign/save330-fixture-manifest.json` containing
  source/destination paths, bytes, hashes, timestamps, and master order.
- Gate: source and fixture hashes exactly match the pinned hash above.

### A02 — Validate official load order

- Use `Get-FNVSaveMasterNames` from `scripts/FNVSaveProfile.ps1`.
- Compare the ordered list to the generated official FNV profile.
- Gate: exactly ten required masters, each installed exactly once, no extras in
  the save-ordered profile.

### A03 — Produce the Save330 denominator

- Extend existing save inspection rather than regexing binary bytes.
- The parser is already implemented in `components/esm4/fonvsavegame.*`; the
  immutable publication model is already implemented by
  `resolveFalloutSaveLoadPlan` in `apps/openmw/mwworld/fnvplayerstate.*`.
  A03 is serialization of that model, not reverse engineering.
- Reuse the exact external-fixture setup in
  `apps/components_tests/esm4/fonvsavegame.cpp` and the exact Save330 load-plan
  assertions in `apps/openmw_tests/mwworld/testfnvplayerstate.cpp` (test
  `resolvesSave330TransformCameraSkyAndExteriorPlacement`). Do not copy pinned
  asserted values into the exporter.
- Add one narrow engine-side denominator serializer/CLI or test utility that
  calls those existing APIs, accepts `--save`, `--content-profile`, and
  `--output`, and fails closed on parser/preflight/load-plan errors. Keep it
  read-only and deterministic. Do not add gameplay behavior or launch OpenMW.
- Emit `save330-player-denominator.json` with player identity, level, cell,
  worldspace, position/rotation, game time, inventory rows, equipped rows,
  actor values, quest globals, discovered marker states, and unsupported opaque
  ranges.
- Gate: every decoded value names save byte provenance; unknown data remains
  explicit and never becomes a guessed default.

### A04 — Join inventory rows to official records

- Resolve every inventory FormID through the frozen ten-master winning-record
  corpus.
- Emit editor ID, display name, record family, count, equipped state, icon,
  weapon ammo/list, clip size, condition, and ALCH effect references.
- Gate: positive inventory rows have no unresolved FormIDs. If a row cannot be
  resolved, fail with its raw FormID and source offset.

### A05 — Compare Save330 with Save341

- Emit `save330-vs-save341-inventory.json` keyed by canonical FormID.
- Classify common, Save330-only, Save341-only, count mismatch, and equipped
  mismatch rows.
- Gate: denominator counts and every difference are machine-checkable.

## Phase B — Add one canonical real-save execution lane

### B01 — Add `RealSave` to the canonical capture contract

- Extend `catalog/fnv-jam-background-capture-recipes.json`, preflight, and
  `scripts/Invoke-FNVJamBackgroundCapture.ps1` with a single-engine `RealSave`
  scenario.
- Parameters: engine target, immutable save path, runtime root, output root,
  bounded route ID, capture seconds, and interactive handoff switch.
- Internal helpers may exist, but the public entry point remains
  `Invoke-FNVJamBackgroundCapture.ps1`.
- Gate: repository tests reject concurrent engines, foreground input, missing
  save hash, output reuse, and a runner that bypasses preflight.

### B02 — Cold-load Save330 normally

- Load the immutable fixture through the ordinary OpenMW save-load path. Do not
  use `--start`, TestMap placement, bootstrap inventory, or console injection.
- Retain log, state manifest, one native world frame, and exact-title video.
- Gate: normal load complete, Player FormID restored, saved cell/worldspace and
  transform applied, no TestMap placement, no fallback inventory.

### B03 — Real-world settle gate

- Stand still for a bounded interval in the saved Goodsprings state.
- Record current cell, exterior grid, worldspace, camera mode, nearby authored
  references, player equipment, health/AP, weather, and game time.
- Gate: finite player/camera state, authored world visible, no T-pose, no
  detached weapon, no crash, no fatal missing required world asset.

### B04 — Save330 reload idempotence

- Make no gameplay changes; save to a new OpenMW campaign artifact, quit,
  cold-reload it, and emit the same state manifest.
- Gate: cell, transform, inventory, equipment, actor values, quests, marker
  states, and game time match allowed persistence rules.

## Phase C — Make fast travel work first

### C01 — Inventory authored map markers

- Enumerate FNV map-marker references with FormID, name, icon type, worldspace,
  cell/grid, position, visible flag, can-travel flag, and destination validity.
- Emit `save330-map-marker-denominator.json` with saved runtime state `0/1/2`.
- Gate: every displayed marker has a valid reference and every travel-enabled
  marker resolves a destination.

### C02 — Verify Save330 marker restoration

- Load Save330 and log restored marker states before proximity discovery runs.
- Gate: saved discovered/visible states are not replaced by plugin defaults or
  the developer “unlock all markers” proof switch.

### C03 — Unit-test fast-travel resolution

- Cover: hidden marker, visible-only marker, travel-enabled marker, disabled
  global travel, enemies nearby, same cell, exterior destination, interior
  destination, invalid XTEL/cell, and non-marker FormID.
- Gate: focused tests pass and each rejection returns a retail-shaped reason.

### C04 — Natural Pip-Boy map selection

- Open the physical Pip-Boy, choose MAP/WORLD, focus one already-discovered
  Save330 marker, and request travel through the production UI path.
- Gate: visible marker selection changes, tooltip/name matches the FormID, and
  confirmation opens. Do not call `showFalloutMapMarker` in this natural gate.

### C05 — Confirm and execute travel

- Confirm through the production map confirmation handler.
- Record before/after marker, cell, worldspace, grid, position, game time,
  loading state, player control state, and Pip-Boy/menu state.
- Gate: destination matches the marker, time advances deterministically, menu
  closes, controls return, and no TestMap or teleport shortcut is used.

### C06 — Fast-travel rejection matrix

- Repeat C04/C05 for enemies nearby, scripted travel disabled, undiscovered
  marker, invalid destination, and cancellation.
- Gate: player position/time do not change on rejection or cancellation; the UI
  exposes a reason and remains usable.

### C07 — Travel persistence

- Travel, save, quit, cold-reload, then reopen MAP.
- Gate: destination state, discovered markers, inventory/equipment, quests,
  time, and camera mode persist; a second travel also succeeds.

### C08 — Sequential retail/OpenMW fast-travel pair

- Capture retail first, then OpenMW, from official-only compatible fixtures.
- Pair: map before selection, selected marker, confirmation, destination world.
- Gate: both reports pass independently before any side-by-side is generated.

## Phase D — Real-save Pip-Boy inventory

### D01 — Render the complete Save330 inventory

- Exercise WEAP, APP, AID, MISC, and AMMO with real rows, icons, counts, stats,
  condition, and selection markers.
- Gate: visible row count equals the Save330 denominator for supported records;
  no showcase-only hardcoded row replaces the real inventory model.

### D02 — Weapon selection matrix

- For each supported Save330 weapon: select, close Pip-Boy, confirm right-hand
  FormID, compatible ammo selection, magazine/reserve, model, and HUD text.
- Gate per row: exact selected FormID appears in production equipment state and
  no previous weapon remains attached.

### D03 — Apparel selection matrix

- Equip/unequip every supported body/head row.
- Gate: slot state, paper doll, first person, third person, armor/condition
  stats, and save/reload persistence agree.

### D04 — Aid/food matrix

- Use Stimpaks and every supported Save330 aid/food item under valid conditions.
- Gate: count decreases exactly once and authored immediate/timed effects alter
  the correct actor values. Full-health/no-applicable-effect use must reject
  without consuming unless retail proves otherwise.

### D05 — Drop/pickup/container round trip

- Drop one safe item, close UI, observe world reference, pick it up, transfer it
  to a container, and retrieve it.
- Gate: conservation of count and condition; save/reload preserves location.

## Phase E — Weapons and controls in the real world

### E01 — Return-from-Pip-Boy invariant

- For every weapon family, open/close Pip-Boy and compare pre/post hand, arm,
  weapon socket, camera, draw state, ammo, and animation controller.
- Gate: no seams, orphan hand, duplicate weapon, stale prior weapon, or changed
  camera/control state.

### E02 — Reload matrix

- Test partial, empty, full-magazine rejection, no-compatible-ammo rejection,
  and weapon-switch-during-reload.
- Gate: magazine/reserve conservation and the correct authored animation/sound.

### E03 — Aim/fire/dry-fire matrix

- Right-click aim-down-sights, fire, recoil, muzzle/impact, damage, condition,
  empty magazine, and dry-fire.
- Gate: state deltas plus human-reviewed first-person frames.

### E04 — First-person animation gate

- Cover draw, idle, aim, fire, reload, lower, holster, Pip-Boy raise/use/lower,
  and restoration.
- Gate: both arms attached, correct hand owns each control/weapon, no T-pose,
  no offscreen or inverted device, and the screen remains inset.

### E05 — Third-person animation gate

- Replay E04 from front, side, and rear views.
- Gate: weapon grip/support hand, Pip-Boy arm, locomotion layering, equipment,
  and actor root remain coherent.

## Phase F — Playable campaign handoff

### F01 — Ten-minute Goodsprings route

- Walk, sprint, jump, open/close Pip-Boy, inspect stats/items/map, fast travel,
  talk to one actor, enter/leave one building, loot one item, use one aid item,
  aim/fire/reload, and save.
- Gate: bounded checkpoint manifest passes without synthetic state mutation.

### F02 — Cold-reload continuation

- Quit normally, cold-reload the F01 save, repeat movement, inventory, map,
  travel, dialogue, door, and weapon smoke checks.
- Gate: all persisted state remains usable.

### F03 — User handoff

- Launch the promoted real-world save for interactive play only after F01/F02
  pass. Provide the exact save hash, runtime hash, launcher command, controls,
  proof video, report, and known-issues list.
- Gate: the user can take control in the real world; no capture helper, proof
  schedule, TestMap placement, or foreground automation remains active.

## Bite queue order

Execute strictly in this order until blocked:

`A01 -> A02 -> A03 -> A04 -> A05 -> B01 -> B02 -> B03 -> B04 -> C01 -> C02 -> C03 -> C04 -> C05 -> C06 -> C07 -> D01 -> D02 -> D03 -> D04 -> D05 -> E01 -> E02 -> E03 -> E04 -> E05 -> F01 -> F02 -> C08 -> F03`

Fast-travel gets priority immediately after the real save can cold-load and
persist. Retail/OpenMW paired capture waits until the OpenMW production path is
stable so time is not spent comparing known-broken states.

## Definition of done

The goal is complete only when:

- the promoted runtime normally cold-loads the immutable Save330-derived
  campaign without TestMap/bootstrap/fallback state;
- complete supported Save330 inventory and marker denominators are on disk;
- natural Pip-Boy selection, equip/use, reload, fire, map selection, fast-travel
  confirmation, destination arrival, save, quit, and cold reload pass;
- first- and third-person animation/framing gates pass human review;
- sequential retail/OpenMW reports and paired media are retained;
- the user receives an interactive real-world save and exact reproducible
  launcher with no proof automation active.
