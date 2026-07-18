# Fallout: New Vegas 100% Parity Plan

This is the controlling execution plan for making the English Fallout: New
Vegas Ultimate Edition naturally playable in flat-screen OpenMW. It replaces
feature-by-feature intuition with a frozen corpus, hard denominators, explicit
dependency layers, generated acceptance cases, and mechanical percentages.

The machine-readable sources are:

- `catalog/fnv-parity-denominators.json` — the frozen retail corpus;
- `catalog/fnv-parity-exclusions.json` — the versioned, currently empty exclusion ledger;
- `catalog/fnv-bite-ledger.schema.json` — the per-byte/record/opcode/mechanic mapping contract;
- `catalog/fnv-parity-control-plane.json` — 15 axes and 187 known capability cases;
- `scripts/export_fnv_parity_corpus.py` — master/BSA-aware read-only census and strict verifier;
- `scripts/New-FNVParityProfile.ps1` — pristine official-only profile generator;
- `scripts/Measure-FNVParityCoverage.ps1` — the score report; and
- `scripts/Test-FNVParityControlPlane.ps1` — the anti-overclaim contract.

## Current truth

As of 2026-07-17:

| Measure | Current value | Meaning |
|---|---:|---|
| Green engineering coverage | **43 / 187 = 22.99%** | Focused-tested, bounded-runtime, or bounded-retail-differential cases; the honest working-progress headline. |
| Implemented or better | **52 / 187 = 27.81%** | Includes nine implemented-but-not-yet-proven cases in addition to green engineering coverage. |
| Live or retail evidence | **29 / 187 = 15.51%** | Cases exercised in bounded live runtime or a bounded retail differential. |
| Mapped capability surface | **104 / 187 = 55.61%** | Everything beyond `uncovered`, including known failures that still require correction. |
| Certified one-to-one parity | **0.00%** | No axis has both a complete capability set and accepted whole-corpus instances. |
| Known capability cases complete | **0 / 187 = 0.00%** | All 187 remain open; 83 are uncovered and 45 are known failing. |
| Existing coarse FNV product gates | **1 / 13 = 7.69%** | Useful engineering checkpoint, not full-game parity. |
| Existing ledger including controls | **4 / 16 = 25%** | Includes FO3, Morrowind, and patch-replay safeguards; never report this as FNV progress. |
| Whole-corpus runtime acceptance | **0.00% in every required family** | Current proofs are bounded Goodsprings/Saloon observations, not immutable accepted rows. |

The engineering percentage and the certification percentage answer different
questions and must always be reported together. Green engineering coverage is
the appropriate progress headline; it never feeds the release gate. Zero
percent certification is deliberately strict. It does not mean no work exists. It means
none of the 15 product axes has yet crossed its complete capability contract
and its weakest required content family on one promoted build. Even the coarse
session-integrity pass lacks the normal-exit and immutable binary/corpus/profile
provenance required for a complete case. A cloud, combat, container, furniture,
or dialogue slice remains visible as bounded engineering evidence without
silently becoming full-game credit.

Run the live report at any time:

```powershell
Set-Location D:\code\nikami-worlds
.\scripts\Test-FNVParityControlPlane.ps1
.\scripts\Measure-FNVParityCoverage.ps1
```

## Frozen target

The retail scoring target is the English Ultimate Edition load order:

1. `FalloutNV.esm`
2. `DeadMoney.esm`
3. `HonestHearts.esm`
4. `OldWorldBlues.esm`
5. `LonesomeRoad.esm`
6. `GunRunnersArsenal.esm`
7. `CaravanPack.esm`
8. `ClassicPack.esm`
9. `MercenaryPack.esm`
10. `TribalPack.esm`

The exact master hashes are locked in the denominator file. The current
general-purpose profile also loads `FNVR.esp` and a loose mod-data directory.
Those are excluded from retail scoring. A pristine parity profile must remove
both. `FNVR.esp`, OpenMW graphics packs, texture packs, and shader mods belong
to a separate compatibility lane after the retail path is green. They may
never hide a failure or add retail-parity credit.

The official corpus currently contains:

| Surface | Frozen denominator |
|---|---:|
| Winning live records | 628,395 |
| Winning live placed references | 427,319 |
| Cells | 44,517 |
| Cells with an actor or interactable | 2,516 |
| Placed doors | 3,457 |
| Directed door teleports | 1,378 |
| Placed containers | 10,778 |
| Placed NPCs / creatures | 3,942 / 3,739 |
| Placed terminals / menu items | 357 / 1,350 |
| Candidate crafting stations | 304 |
| Placed radios | 425 |
| Placed ACTI/TACT references | 9,979 |
| Dialogue topics / INFOs / responses | 21,298 / 28,896 / 37,403 |
| Dialogue conditions / choice edges | 69,277 / 28,215 |
| Official quests | 640 |
| Standalone scripts / physical SCRI records / winning-live SCRI records | 3,707 / 5,151 / 5,148 |
| AI packages | 4,885 |
| Worldspaces / climates / weather / regions | 33 / 46 / 98 / 317 |
| Unique winning archive paths | 181,642 |

High-risk runtime families are also explicit, rather than hidden inside the
628,395-record total: 6,129 NAVM, 3,479 LVLI, 419 MGEF, 252 ENCH, 384 SPEL,
44 EFSH, 257 PERK, 65 AVIF, 772 FACT, 184 CHAL, 291 RCPE, 1,567 MESG, 92
IMGS, 299 IMAD, 83 WATR, 34 PWAT, 155 PROJ, 223 EXPL, 147 IPCT, 73 IPDS,
3,646 SOUN, and 29 MUSC winning-live records. Each is a required content
family and cannot be hidden by the aggregate record count.

The committed census tool must reproduce these numbers before they become a
promotion input. The current tool reproduces the master and BSA corpus locally;
its strict pristine-profile/anomaly gate is the active Layer-0 slice. Changing
language, plugin order, official DLC set, or archive hash creates a new corpus
ID and resets corpus-derived percentages.

The retail oracle is a separate frozen manifest. It records the retail
executable/distribution/version hash; master/BSA order; INIs; OS; renderer/API;
GPU and driver; resolution, aspect ratio, refresh, FOV, and preset; audio
format/device; keyboard/mouse or gamepad mode; save/camera/time/weather; and
the exact state, pixel, audio, timing, and performance tolerances for each
differential. Without that manifest a visual, audio, or timing comparison is
an observation, never acceptance.

English retail gameplay is included by default. Retail save-file interchange,
console/debug commands, platform achievements/cloud services, and deliberate
bug-for-bug compatibility stay in scope until a versioned user-approved scope
decision explicitly includes, excludes, or substitutes them. Silence is not
an exclusion.

## What “100%” means

One-to-one parity is not “the game launches,” “the screenshot is nonblack,” or
“one example worked.” It means all of the following on the same promoted
binary and frozen corpus:

1. Every physical record and override chain parses without unexplained bytes.
2. Every winning live record is stored, runtime-bound, or explicitly proven
   irrelevant to retail execution.
3. Every placed reference loads with its winning base, ownership, lock,
   enable parent, scripts, assets, and cell relationships resolved.
4. Every player-visible mechanic executes naturally, not through a proof-only
   teleport, forced weather, actor neutralization, or direct `SetStage`.
5. Every mutable mechanic survives cell unload/reload, interruption, manual
   save, quicksave/autosave where applicable, process exit, and reload.
6. Every content instance and meaningful state variant has a deterministic
   result row: `pass`, `fail`, or a user-approved exclusion. `Unseen`,
   `unknown`, and `fallback` are failures.
7. Every equivalence class has an exact retail contract and differential for
   state, pixels, audio, and timing where observable.
8. All base-game routes, all official quests, the four faction endings, every
   official DLC, companion arcs, casino games, Caravan, slides, and credits
   complete naturally from clean saves.
9. The overlay replay, focused/full tests, FNV controls, shared FO3 controls,
   Morrowind regressions, performance matrix, and long soak remain green.
10. A clean machine can install the promoted build, point it at legally
    installed data, start a game, play, save, quit, reload, and continue.

No denominator can be reduced because a feature is difficult. Any exclusion
must identify the exact row, retail reason, evidence, approving user, and scope
version.

## The percentage model

There are 15 required product axes. Each axis has capability cases and one or
more required content families:

```text
capability coverage = complete capability cases / all capability cases
family coverage     = accepted instances / total instances for that family
axis score          = min(capability coverage, every required family coverage)
certified parity    = min(the 15 axis scores)
balanced progress   = mean(the 15 axis scores), diagnostic only
```

The nested minimum prevents a large asset family from hiding zero terminals,
quests, or projectiles, and prevents fourteen strong axes from hiding one
release-blocking axis. The mean remains visible only as an engineering trend.
A capability case enters the numerator only after discovery, exact
format/retail contract, runtime binding, natural behavior, state mutation,
lifecycle/save-load where applicable, retail differential, promoted-binary
provenance, and regressions all pass. Partial maturity is reported but earns
zero certified parity credit.

The 15 axes are:

1. provenance, build, replay, and controls;
2. content census and parsing;
3. world traversal, streaming, physics, navigation, and doors;
4. rendering, weather, materials, animation presentation, and pixels;
5. player rules, controls, HUD, Pip-Boy, and character creation;
6. object activation, locks, terminals, furniture, and interactions;
7. inventory, equipment, loot, economy, and crafting;
8. actor and creature appearance, animation, and physical state;
9. AI, packages, detection, factions, and companions;
10. combat, VATS, damage, reactions, death, and encounters;
11. dialogue, conditions, choices, voice, LIP, and services;
12. quests, GECK scripts, factions, perks, and campaign state;
13. audio, music, radio, voice, ambience, and video;
14. save/load, mutable world persistence, map, and fast travel; and
15. natural base-game/DLC journeys, soak, and release.

The 187 checked-in cases are the current minimum macro taxonomy, not a claim
that discovery is finished. Their fully qualified IDs and all 84 current
content-counter IDs/totals are hash-pinned. Adding a newly discovered retail
requirement increases the denominator immediately. Removing one requires a
versioned, user-approved scope revision; replacing it with a dummy changes the
pinned ID hash. A case or content row cannot enter a numerator from a hand edit:
the validator requires a committed, content-addressed result manifest/ledger
whose scope, status, counts, normal exit, and producer/corpus/profile/save/
binary provenance validate.

## The bite ledger

Discovery and implementation order are deliberately separate. We inventory
the entire game first, but implement inward-to-outward by dependency. Every
physical record, winning record, subrecord variant, placed reference, asset
edge, script opcode/event/command/condition, UI flow, mechanic variant, and
journey edge receives a stable row containing:

```text
stable ID and source byte range
  -> override/winning identity and dependencies
  -> category and meaningful state variants
  -> retail inputs, expected transitions, outputs, timing, and persistence
  -> implementation disposition
  -> handler/source path and tests
  -> observed/accepted result manifest
```

The implementation disposition is exactly one of:

- `existing-cpp-analog` — a general OpenMW C++ path already has the same
  responsibility and is extended/tested rather than duplicated;
- `new-cpp-runtime` — binary parsing, simulation, scheduling, persistence,
  rendering, audio, or performance-critical engine behavior needs new C++;
- `lua-retail-script` — Lua is appropriate only for authored/script-level
  behavior while preserving GECK event/order/state semantics;
- `data-only` — existing general runtime behavior needs a parsed contract, not
  bespoke code;
- `retail-unreachable` — proven unreachable with frozen retail evidence and a
  user-approved exclusion row; or
- `uncovered` — no analog or implementation exists yet, which is always red.

This engine is C++/Lua, not C#. We do not add a C# layer. We also do not
hand-translate individual GECK scripts into Lua or use actor/FormID/cell Lua
patches to fake parity; the VM/event system must execute the general contract.

## Peel the onion in dependency order

### Layer 0 — Freeze truth

Deliver:

- a parity-only profile containing official inputs and isolated writable
  state;
- committed master/archive hashes and load order;
- a master-aware record parser that preserves physical headers, global FormID
  resolution, override chains, deletes, and winning live records;
- strict allowlists for the one malformed GRA FormID and the exact known
  FalloutNV compressed-record checksum anomaly; every other anomaly is fatal;
- a path-independent verifier that fails on FNVR/loose overlays, unexpected
  inputs, master/BSA/tool hash drift, order drift, warnings, or count drift;
- the complete cell/reference/door/asset/interaction/dialogue/quest/script
  catalogs;
- the frozen retail-oracle environment/tolerance manifest;
- a generated case ledger and score report; and
- zero unexplained parse, missing-base, or missing-asset rows.

Hard stop: no percentage beyond provisional engineering metadata is valid
while the corpus or denominator can change.

### Layer 1 — Establish the runtime kernel

This is the deepest technical blocker and must precede broad quest work, but
it is not a multi-year big-bang implementation. Inventory every dependency
now; implement the general architecture plus the exact subset required by the
first natural spine; then use that spine to validate the architecture before
completing every opcode and record family in Layer 3.

Deliver:

- generated red rows for every still-unbound gameplay-bearing record family;
- a native FNV player and actor-value model: SPECIAL, skills, perks, derived
  values, limbs, factions, reputation, karma, inventory, and equipment;
- the general GECK bytecode VM, event scheduler, command/condition registries,
  target/RunOn, timer, error, and persistence architecture, with the precise
  spine-required subset implemented;
- complete mutable ESM4 state schemas for references, actors, inventories,
  quests, scripts, dialogue history, AI, terminals, radios, time, and weather;
- deterministic save/load with stable IDs and content-version handling; and
- no gameplay-bearing generic `NullAction` or silently skipped ESM4 save row.

Hard stop: do not build the spine on an ESM3 player proxy, synthetic quest
advancement, record-specific Lua, or state that disappears on reload. Also do
not defer architecture validation until every opcode has been implemented.

### Layer 2 — Prove one natural playable spine

The first real-player milestone is not another cinematic. It is:

```text
Main Menu
  -> New Game
  -> retail intro
  -> Doc Mitchell wake-up and character creation
  -> Goodsprings tutorial
  -> movement, dialogue, inventory, Pip-Boy, containers and crafting
  -> player-fired and NPC combat with reactions/death/loot
  -> natural quest progression
  -> manual save
  -> quit process
  -> reload
  -> continue with identical state
```

This spine must use authored references and scripts. A harness may observe it
and collect evidence but may not drive its stages, select its dialogue result,
force its weather, neutralize its AI, or substitute its player state.

Hard stop: do not call the game playable until this exact spine passes.

### Layer 3 — Complete mechanic equivalence classes

For each mechanic family, first inventory every serialized/runtime variant,
then implement the general rule, then prove boundaries before crawling all
instances. This layer closes every still-red record family, GECK opcode/event/
command/condition, and state schema. The required families include:

- all placed base types and activation modes;
- locks, keys, ownership, theft, crimes, traps, enable parents, and resets;
- loose items, containers, corpses, equipment, aid, condition, mods, ammo,
  repair, barter, services, pickpocket, and all crafting stations;
- terminals, hacking, radios, furniture, beds, books, notes, flora, switches,
  scripted movers, and minigames;
- NPC/creature appearance, every skeleton/controller/animation/attachment,
  locomotion, furniture, dialogue, combat, hit, death, ragdoll, and gore;
- AI package conditions and procedures, cross-cell navigation, detection,
  factions, reputation, crime, companions, scenes, and respawn;
- hitscan, projectiles, shotguns, melee, explosives, DT/DR, criticals, limbs,
  effects, reloads, jams, condition, reactions, death, loot, and VATS;
- dialogue ordering, conditions, choices, compiled results, voice/LIP,
  services, interruption, and history;
- quest objectives, markers, scripts, event ordering, globals, actor values,
  perks, factions, endings, and persistent consequences;
- terrain, NIFs, materials, water, LOD, weather, lighting, image space,
  particles, decals, UI, pixels, music, ambience, spatial audio, and video; and
- every mutation class across unload/reload and save/load.

Hard stop: no actor-, cell-, quest-, weather-, or FormID-specific gameplay
patch can substitute for a format/runtime rule.

### Layer 4 — Crawl the whole corpus

Generate, do not hand-pick, deterministic cases for every effective record and
meaningful state variant. The durable outputs are:

```text
run/audit/fallout_new_vegas/corpus.json
run/audit/fallout_new_vegas/records.jsonl
run/audit/fallout_new_vegas/cells.jsonl
run/audit/fallout_new_vegas/references.jsonl
run/audit/fallout_new_vegas/assets.jsonl
run/audit/fallout_new_vegas/features/*.jsonl
run/audit/fallout_new_vegas/journey-graph.json
run/audit/fallout_new_vegas/cases.jsonl
run/audit/fallout_new_vegas/results.jsonl
run/audit/fallout_new_vegas/coverage.json
```

Every result row is tied to corpus hash, engine commit/tree, binary hash,
profile hash, save hash, case version, and evidence files. A row cannot be
promoted from a force-killed run lacking a binary hash, and nonblack/variance
statistics cannot satisfy visual parity.

The crawler has separate passes:

1. static parse and reference/asset resolution;
2. load every cell and exterior adjacency edge;
3. activate every interactable in every authored state variant;
4. execute every dialogue response/condition/choice and voice/LIP mapping;
5. execute every script command/opcode/event attachment;
6. execute every quest stage/objective/branch through natural prerequisites;
7. execute every weapon, damage, AI, reaction, death, loot, and respawn class;
8. unload/reload and save/reload after every mutation class; and
9. revisit every previously green row after each promoted slice.

Hard stop: `unseen`, `unsupported`, `unknown`, `fallback`, missing evidence,
and unexplained warning all count as failures.

### Layer 5 — Complete natural campaigns and DLCs

Run clean-save journey graphs for:

- New Game, Doc Mitchell, and the Goodsprings tutorial;
- NCR, Legion, Mr. House, and Yes Man main routes;
- every official quest, failure branch, objective, reward, and consequence;
- every companion and personal quest;
- Blackjack, roulette, slots, Caravan, chips, bans, and Luck behavior;
- Dead Money, Honest Hearts, Old World Blues, and Lonesome Road;
- GRA challenges/content and all preorder packs; and
- every ending predicate, slide, narration, music cue, order, and credits path.

Forced `SetStage` remains useful to diagnose an isolated handler but earns no
journey credit.

### Layer 6 — Differential, lifecycle, and soak

For every equivalence class and every failure/outlier:

1. capture exact retail state through the isolated oracle;
2. inspect the original ESM/NIF/KF/LIP/TRI/shader/audio bytes;
3. capture OpenMW at the same state, time, camera, weather, and lifecycle;
4. compare state transitions, transforms, pixels, audio events, and timing;
5. save, quit, reload, unload/reload, interrupt, and repeat;
6. run FNV, shared FO3 controls, Morrowind regression, full tests, and replay;
7. run worst-case performance and long mixed-action soak; and
8. keep every failure visible until fixed or explicitly excluded.

Hard stop: a clean exit, focused unit test, good-looking frame, or single
representative does not waive breadth, lifecycle, or retail-differential gates.

### Layer 7 — Release and optional graphics mods

Release requires a clean-machine install and immutable manifest containing
source commits/trees, patch queue, compiler/dependency versions, binary hashes,
corpus hashes, profile hash, settings, test results, coverage, and known
user-approved exclusions. The promoted build must reproduce the full green
matrix from scratch.

Only then establish an optional graphics-mod lane. Each mod gets its own
manifest, license/source, deterministic install order, conflict list, asset
hashes, performance cost, and full regression result. Better graphics are
welcome; they are never evidence that the retail engine behavior is correct.

## The slice loop

Every implementation slice follows the same loop and is committed separately:

1. Select the earliest red case in the earliest incomplete onion layer.
2. Query the census for every affected record, field, variant, reference,
   script, asset, and downstream consumer.
3. Capture the exact retail behavior and serialized contract.
4. Decide the engine analog: existing OpenMW path, new C++, Lua only where the
   retail responsibility is genuinely script-level, or an explicit gap.
5. Write parser/unit/state-machine/boundary/failure tests first or alongside
   the implementation.
6. Implement the general rule without fuzzy matching or record-specific hacks.
7. Build the focused targets and the real `openmw.exe`.
8. Run a natural background FNV case with immutable telemetry and native
   evidence; do not control the user's foreground desktop or browser.
9. Run retail differential, cell lifecycle, save/quit/reload, FO3 shared
   control, Morrowind regression, and overlay replay as applicable.
10. Update only the exact generated result rows and recompute percentages.
11. Review screenshots/audio/state logs manually where the contract is visual
    or audible.
12. Commit the smallest verified slice. Never stage unrelated dirty work.
13. Re-run every previously green impacted case before selecting the next row.

If a slice fails, the row stays red and the same loop repeats. We do not move
outward merely because the code compiled or the token/time budget is low.

## Ordered work from the current checkout

1. **Finish and commit strict denominator tooling (active).** Master and BSA
   counts/hashes now reproduce. Add the pristine profile, exact anomaly
   allowlists, denominator verification mode, oracle manifest, base catalogs,
   and hard failures for overlays, drift, unexplained parse/reference/assets.
2. **Persistent containers — committed at engine `c33e3df591`.** Authored CNTO
   inventory, normal UI transfer, locks/keys, and save/load persistence pass
   focused tests and the real executable links. Natural runtime acceptance is
   still required before its parity rows can turn green.
3. **Furniture lifecycle — committed at engine `c1b8bf261f`.** The active
   package is authoritative across scene/controller resets and restores the
   settled anchor without actor-specific hacks. Natural exterior/interior
   replay and immutable acceptance remain open.
4. **Build native FNV state and persistence.** Replace the ESM3 player proxy
   and the broad ESM4 save skips before adding more mutable mechanics.
5. **Build the GECK VM and event substrate.** Generate the opcode/command and
   condition inventory from all 3,707 official scripts plus attachments;
   implement until unknown coverage is zero.
6. **Make the natural new-game spine pass.** Intro, Doc Mitchell, player
   creation, HUD/Pip-Boy, inventory, dialogue, quests, combat, save/quit/reload.
7. **Complete mechanic equivalence classes** in dependency order, then expand
   their generated instance numerators.
8. **Run the entire corpus and campaign/DLC matrix**, retail differentials,
   persistence matrix, soak, replay, and clean-install release gate.

The current bounded Goodsprings cloud, fog, door, Easy Pete voice/LIP, and one
NPC-fired Service Rifle hit remain useful regression seeds. They are not the
center of the architecture and do not change the ordering above.

## Known hard blockers right now

- The formal promoted queue stops 42 local engine commits behind current
  engine head; later commits have not passed the formal replay/promotion gate.
- Only 61 of 140 cross-game ESM4 record enums are indexed in the game store.
  Parser/store percentage is not playability, but the missing runtime families
  include factions, actor values, perks, recipes, combat/effect/explosion,
  water, messages, and other campaign-bearing records.
- The Courier is still an ESM3/OpenMW player with an ESM4 visual proxy.
- There is no complete GECK bytecode VM or event scheduler. Current dialogue,
  quest, condition, and result support is a narrow interpreted subset.
- Containers now have a committed specialized state path, but almost every
  other ESM4 reference class is skipped by save/load. NPC death/state, doors,
  loose items, activators, radio, furniture/AI phase, equipment, dialogue
  history, and enable state are not generally persistent.
- Terminals, hacking, lockpicking, workbenches, crafting, beds, flora, books,
  pickups, corpse loot, barter/services, Pip-Boy, VATS, and many UI surfaces
  are absent or generic no-ops.
- Combat is one bounded single-ray NPC-fired case. Player fire, pellets,
  physical projectiles, melee, explosives, DT/DR, criticals, limbs, condition,
  reloads, reactions, death, gore, VATS, loot, and encounter breadth are open.
- AI reduces many packages to travel or wander and does not use authored NAVM
  as the retail runtime does.
- Visual acceptance still fails actor faces/skin/hair, some materials,
  lighting/image-space/HDR, water, precipitation/lightning, particles/decals,
  and Mojave-wide LOD/pixels.
- Successful bounded logs still contain ESM3 fallbacks, unhandled animation
  controllers/texture stages, and a failed radio activation sound. All must be
  classified and removed.
- Existing sky/voice captures lack full promoted-binary provenance and some
  terminate through harness force-kill. They remain bounded evidence only.
- The Strip MP4 used staged actors and a synthetic damage-driven transform. It
  is excluded from generic combat/reaction parity.

## Definition of done

The project is 100% only when this command reports 100.00%, `releaseReady=true`,
and its inputs are the immutable promoted release artifacts:

```powershell
.\scripts\Test-FNVParityControlPlane.ps1
.\scripts\Measure-FNVParityCoverage.ps1 -AsJson
```

At that point every axis, capability case, content row, campaign/DLC journey,
retail differential, lifecycle/save test, regression, performance case, and
clean-install gate is green. Anything less is reported by its exact numerator,
denominator, failing IDs, and evidence—not by optimism.
