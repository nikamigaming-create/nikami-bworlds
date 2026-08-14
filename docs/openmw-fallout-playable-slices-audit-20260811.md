# OpenMW Fallout playable-slices audit

Status: durable planning input; no playable-runtime claim  
Audit date: 2026-08-11  
Scope: Fallout: New Vegas, standalone Fallout 3, Tale of Two Wastelands,
JAM 4.6, and future mod compatibility in the local OpenMW work.

## Why this document exists

Repository source, runtime packages, test results, historical capture notes,
and compatibility catalogs have drifted apart. Broad production code exists,
but it is not presently valid to describe any Fallout target as a complete
playable OpenMW runtime.

This audit replaces conversation-only conclusions with a durable boundary
between:

- code present in a production call path;
- focused or component-tested behavior;
- retained live evidence;
- a complete persistent playable slice; and
- unsupported or unproven behavior.

No engine was launched during this audit. No historical evidence directory was
recreated or inferred from documentation alone.

## Audit method and limitation

Four lead audits and eleven completed subordinate audits independently reviewed
source wiring, test semantics, Git/runtime provenance, retained evidence,
missing systems, persistence, rendering/world gaps, FO3, TTW, JAM, and general
mod compatibility. One TTW subordinate was interrupted. The agent environment
then reached its hard thread limit and refused both a replacement and a fifth
lead. The completed reviews agreed on the conclusions below. This limitation
must remain visible; it may not be rewritten as a twenty-review consensus.

## Current factual baseline

### Source and runtime provenance

- The clean recovery source is branch
  `codex/fnv-playability-recovery-20260807` at commit
  `ab4e32941a331029202f6d328ca3d3fcebecc4a1`.
- That checkout declares OpenMW 0.50.0 and contains broad Fallout gameplay
  changes, including the ancestor commits for playable weapon work and the
  native FNV mod bridge.
- The TTW startup commits `df9419c637` and `b1c0b2d841` are not ancestors of
  `ab4e32941a`; TTW and the current FNV recovery are divergent lines.
- No build or `openmw.exe` is attached to the clean recovery checkout.
- No discovered executable matched the recovery catalog's recorded
  `F74C4AB42E797470802AE11BBA975C7D84EAFAD71701E917DC09FE8DEE09F7A3`
  hash.
- `scripts/WorldViewerPaths.ps1` names
  `local/openmw-pristine-mads-33568a` as current, but that package is absent.
- `local/paths.json` selects `local/openmw-vats-live`, an unmanifested 0.51
  package with a different binary hash, while its configured source/build
  paths are absent.
- Launch entry points do not currently resolve one consistent runtime.

Conclusion: there is no canonical reproducible Fallout runtime today.

### Evidence baseline

- `catalog/fnv-flat-acceptance-ledger.json` remains `fail` with zero certified
  playable parity and an unproven normal-session baseline.
- August recovery documents record useful bounded cold-load, Pip-Boy,
  fast-travel, and terminal results, but many referenced `run/` artifacts are
  absent and cannot be revalidated.
- Terminal candidates 6 through 15 are explicitly rejected as evidence.
- No retained provenance-complete FNV session proves ordinary gameplay,
  process exit, cold reload, and continued play on one current runtime.
- The current FO3 control is revoked because its durable artifacts are absent.
- TTW has route definitions and a historical log reaching CG01 stage 16, but
  no accepted opening capture report and no current integrated runtime.
- JAM has no passing full-proof report; the retained sprint slice cannot
  establish all-module compatibility.

Conclusion: historical bounded achievements may guide engineering, but none
currently certifies a promoted Fallout playable slice.

## Capability ledger

| System | Production wiring | Focused evidence | Live/playable status | Important boundary |
| --- | --- | --- | --- | --- |
| Containers and keys | Yes | Strong in-memory action, inventory, and serialization tests | No retained executable slice | UI, ordinary transfer, process reload, and composition unproven |
| Doors and teleports | Yes | Key, action, and door-state tests | Historical bounded results only | Current runtime and natural transition proof absent |
| Barter | Yes | Two transaction/filter/cancel tests plus bounded dialogue dispatch | No retained Chet play slice | Visible UI and save/reload composition unproven |
| Crafting | Yes | Catalog, skill, transaction, and drift tests | No retained in-world slice | Conditional recipes are rejected |
| Combat | Yes | Broad helper/state coverage for melee, guns, projectiles, damage, VATS, explosives, criticals, and condition | Older bounded weapon evidence only | Modern integrated input-animation-collision-death-loot-save route unproven |
| Dialogue and quests | Bounded production paths | INFO selection, conditions, result scripts, and quest state tests | No complete natural quest | CTDA/opcode coverage is narrow; source fallback may skip commands |
| Terminals | Yes | Substantial access, hacking, note, condition, submenu, and persistence tests | Physical route rejected/unaccepted | Presentation, ordinary activation, full flags/opcodes, and save/reload gate remain |
| Lockpicking | No gameplay caller | Eligibility/preparation tests for an exact frozen corpus | Not playable | No UI, input, pin breakage, success, unlock mutation, cancellation, or persistence |
| Pip-Boy | Partial | Pane/XML/policy tests and historical bounded screen transport | Not accepted | Fixed/synthetic/no-op rows remain; physical animation/control ownership incomplete |
| HUD | Partial/legacy suppression | No complete native Fallout HUD acceptance | Uncovered | Player feedback is not yet a reliable slice surface |
| AI/packages/furniture | Bounded | Policy, state, and selected lifecycle tests | No natural multi-actor daily-life slice | Only selected procedures; linked targets/offscreen composition remain limited |
| Native `.fos` import | Partial | Player/save planning and bounded cold-load tests | Not full continuation | Importer explicitly describes a visual slice; major retail state families are missing |
| OpenMW-native persistence | Selected types | Containers, doors, NPCs, creatures, and quest/player state have tests | No cumulative process-reload slice | Generic ESM4 changed-reference persistence is missing |
| Radio | Narrow | One quest-owned one-shot family | Not general radio | Conditioned/random/continuous variants are rejected |
| Weather/world/rendering | Broad bounded support | Weather, terrain, actor, animation, material, and image-space tests/proofs | Not retail-complete | Ambience, attenuation, KF/material variants, visual parity, and soak remain open |

## Compatibility reality

### Standalone Fallout 3

FO3 profile, DLC/BSA mounting, record parsing, world loading, and bounded
rendering exist. Many gameplay paths are explicitly restricted to
`FalloutNewVegas`, including player state, combat entry, package behavior,
terminal, crafting, radio, and lockpick logic. FNV implementations must not be
credited to FO3 until those gates are removed or replaced by format-derived
rules and an FO3 slice passes.

Current honest status: walking-sim/bounded-interaction candidate, not a
playable system control.

### Tale of Two Wastelands

TTW has a legitimate low-to-high FO3/FNV/TTW overlay, isolated campaign saves,
launcher/profile infrastructure, and authored nursery routes. Its startup work
lives on a divergent OpenMW 0.51 line rather than the clean FNV recovery line.
A historical log advanced CG00 to CG01 stage 16 while also reporting unsupported
compiled opcodes and whole-source fallbacks.

Current honest status: historical opening prototype without a current
integrated, manifested, accepted runtime.

### JAM and other mods

The FNV recovery contains a real SCPT-to-Lua host, broad xNVSE/JIP/Johnny
bindings, focused ObScript tests, and native JAM sprint behavior. Unknown
commands may still fall back to zero, compilation failures can be skipped, no
full JAM report exists, and ShowOff is absent. Catalog `validated` labels must
not be read as all-module playable compatibility.

Current honest status: substantial partial mod-runtime implementation; JAM
sprint is the best bounded module, while full JAM and general mods are
unproven.

## Decisions

1. Stop using global parity percentage as the active engineering queue.
   Preserve the corpus as discovery and final certification.
2. Use the fastest viable existing OpenMW 0.51 line for the first FNV slice.
   Port only code required by the next observable slice; do not reconcile TTW,
   JAM, Pip-Boy, terminals, or the entire 0.50 recovery before first play.
3. Give that runtime a minimal honest manifest before launch. Full release
   packaging, launcher unification, and historical provenance cleanup follow a
   successful smoke rather than blocking it.
4. Promote cumulative playable slices through ordinary input and persistent
   process-reload behavior.
5. Do not require retail `.fos` completeness, Pip-Boy, lockpicking, terminals,
   or a quest in the first slice.
6. Do not call a focused test, build, screenshot, route definition, historical
   log, or missing evidence path a playable pass.

## Results-first execution rules

The active loop is play first, diagnose the first blocker, fix it, and play
again. Repository archaeology and harness work are support activities, not
deliverables.

- A work cycle must end in one of three concrete results: a new native gameplay
  observation, a fix for the first observed blocker, or a narrowly identified
  build/runtime blocker with its failing command and owner.
- Do not port a subsystem until the next playable action requires it.
- Do not merge TTW or JAM work before the first FNV smoke runs.
- Do not build a general acceptance framework before observing the slice.
  Reuse the canonical background-capture entry point and add only the minimum
  assertion needed for the current action.
- Harness and documentation work may consume at most one bounded change before
  returning to the engine. If the engine has not been run after that change,
  stop extending the harness.
- Run the smallest relevant tests before a smoke. The full suite is required
  for promotion, not for every edit-run iteration.
- Visual imperfections are logged but do not block the first smoke unless they
  prevent navigation or interaction.
- Keep failed runs. A failed run with native frames and a precise first blocker
  is a useful result.
- Never launch retail FNV during recovery. OpenMW capture still follows
  `docs/fnv-jam-background-capture.md`, including preflight and the canonical
  unattended wrapper.

## First visible smoke

The first result is deliberately smaller than a persistent playable slice:

```text
launch one minimally manifested OpenMW 0.51 candidate
  -> reach ordinary Goodsprings gameplay
  -> move through the exterior
  -> activate one unlocked or authored-key door
  -> arrive in the interior
  -> open one unlocked container
  -> retain native frames/logs
```

This is an engineering smoke, not a promotion. Its purpose is to expose the
first real integration blocker quickly. It does not wait for TTW/JAM lineage
reconciliation, full launcher cleanup, barter, save/reload, Pip-Boy, terminal,
lockpicking, quests, or visual parity.

## First promoted playable slice

The smallest source-defensible target is:

```text
ordinary Goodsprings start
  -> exterior movement
  -> unlocked or authored-key door
  -> interior transition
  -> unlocked container transfer
  -> Chet barter cancel and committed transaction
  -> OpenMW-native save
  -> normal process exit
  -> cold reload
  -> verify mutations and repeat an interaction
```

Acceptance constraints:

- one clean manifested runtime and one exact profile;
- no `OPENMW_*PROOF*`, forced actor, forced weather, staged-reference, frozen
  animation, camera-driving, or synthetic inventory behavior;
- ordinary production input and activation paths only;
- retained logs, native frames, configuration hashes, save hashes, process exit,
  and post-reload state assertions;
- no claim beyond the state families actually serialized;
- explicit manual acceptance after the automated report passes.

## Promotion sequence after slice 1

1. Combat, hostile death, corpse loot, weapon/ammo/condition persistence, and
   usable HUD feedback.
2. Supported crafting recipes with persistent inventory results.
3. Generic HUD and Pip-Boy data/actions, followed by physical animation and
   control ownership.
4. Terminal physical activation/presentation around existing mechanics.
5. Real lockpick production integration and minigame.
6. One natural quest, adding only generic condition/opcode semantics encountered
   and treating unsupported commands as caller-visible failure.
7. Generic ESM4 changed-reference persistence.
8. AI/package expansion plus a measured exterior traversal and sustained soak.
9. Standalone FO3 equivalent slice after removing unjustified FNV gates.
10. TTW CG00/CG01 checkpoints on the reconciled runtime, each with save/reload
    and zero unsupported script fallback.
11. JAM module-by-module, requiring zero compile skips/unknown commands for the
    promoted module.
12. Other mods grouped by required provider/API family, beginning with explicit
    ShowOff support where required.

## Required next artifact

Execution is controlled by
`catalog/openmw-fallout-playable-slices-plan.json`. Update that file after every
gate. Evidence paths must exist and be hash-verifiable before a status may move
to `passed`.
