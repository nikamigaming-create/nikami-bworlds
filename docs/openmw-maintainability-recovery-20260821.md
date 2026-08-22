# OpenMW / OpenNV Maintainability Recovery — 2026-08-21

## Objective

Keep the Fallout: New Vegas and VR implementation as a maintained downstream
product while holding every extracted engine change to the reviewability,
architecture, and regression standards expected in OpenMW itself. Actual
upstream submission is optional; upstream-quality code shape is not.

The product acceptance target is exact retail Fallout: New Vegas behavior,
including its observable quirks. Architecture cleanup and synthetic tests are
necessary gates, not substitutes for retail differential evidence. Flat OpenNV
is the canonical parity build; VR is a separate frontend over the same proven
state.

The pre-recovery lab is evidence and reference behavior. It is not the base for
new implementation work.

## Preserved identities

| Lane | Branch | Commit | Tree | Purpose |
| --- | --- | --- | --- | --- |
| Recovery lab | `codex/recovery-20260821-openmw-lab` | `8594ef323f548f8b01c86bdf7149ccdf03361933` | `07bf15bf70da1c84271e5bae7ec1398d74b815a4` | Exact 79-file pre-cleanup implementation; never promoted as a topic |
| Promoted overlay | existing locked queue | `f8863dd47a608c5534d1a89dc6d1584b4c79fd12` | `1eaaaa089807aef77c57a7cd616f8c24fb5dbf4a` | Patches 0001-0024; formal replay baseline |
| Candidate overlay | `codex/openmw-overlay-0025-checkpoint` | `79290f2a06e7fff85c17e39bd3cd1dc1412ada33` | `c5b4f00165e8a02813b443e45311ba7ea29fe605` | Patches 0001-0025; telemetry candidate only |
| Clean extraction | `codex/openmw-clean-extraction-20260821` | `e6268c309eee4577b6cf649d7de9bc0c28adc38a` | `280110379b352526fd3a7b5d9ac27cb0a43fb303` | Official-master-based parser topics and reusable synthetic fixtures |
| Clean collision | `codex/openmw-clean-collision-20260822` | `155614a8cac3eb997d25abab4f086e5df60a314d` | `6cfa5b290b8fa5c08980ef83b51e60a1cda9f076` | Twelve-topic collision/material/filter/ownership series directly over official OpenMW master |
| Maintainable downstream | `codex/openmw-maintainable-downstream-20260821` | `4b73acfdac03f3413a5ac1d2ec61d43eefa2a031` | `a57a0f3170146777fc8c54d0ac8e60f3a19ff931` | Product cleanup rooted at the immutable recovery checkpoint |

The clean extraction parent is official OpenMW `master`
`e318e7ac360cdf082459184f968986c9e93b5ca7`.

## Queue boundary

- `patches/openmw/series` is the formally promoted 24-patch queue. Its lock is
  `catalog/openmw-base-lock.json`.
- `patches/openmw/series-next` is a candidate superset. Its lock is
  `catalog/openmw-candidate-lock.json`.
- Both queues must pass `scripts/Test-OpenMWOverlayReplay.ps1` independently.
- A candidate never enters `series` merely because it applies, compiles, emits
  useful telemetry, or shares a tree with an old experiment.

Verified on 2026-08-21:

| Queue | Patch count | Replay tree | Result |
| --- | ---: | --- | --- |
| Promoted | 24 | `1eaaaa089807aef77c57a7cd616f8c24fb5dbf4a` | exact pass |
| Candidate | 25 | `c5b4f00165e8a02813b443e45311ba7ea29fe605` | exact pass |

## First clean topic: AMMO `DAT2`

### Evidence

- Target corpus: English Fallout: New Vegas Ultimate Edition.
- `FalloutNV.esm` SHA-256:
  `50991D36804B7C9EA3D6A3684A1510B8DB813303CA5118DA6D90E72D723053F2E`.
- Corpus report:
  `local/analysis/fnv-ballistics-corpus-20260818-r4/fnv-ballistics-corpus.json`.
- Corpus report SHA-256:
  `246524D06915891EE1D07811EF45F46F25395F13AC726147810049BAC68E7586`.
- Winning AMMO records: 145 total; 11 use a 12-byte `DAT2`, 129 use a
  20-byte `DAT2`, and 5 omit `DAT2`.
- The existing OpenMW loader consumed only the 20-byte form and skipped the 11
  short records.

Confidence: `confirmed` for the record-size distribution and field offsets in
the bounded corpus; broader Bethesda-title coverage remains unclaimed.

### Behavioral contract

For a 12-byte `DAT2`, load projectiles-per-shot, projectile FormID, and weight,
then leave consumed-ammo and consumed-percentage empty. For a 20-byte `DAT2`,
load the same prefix plus consumed-ammo FormID and percentage. Use the existing
reader for FormID adjustment. Skip unknown sizes without losing the following
subrecord boundary.

### Implementation and verification

- Commit: `1a0bb044dec402e38b8cad1d0f2ee72d9bb1884d`.
- Surface: 3 files, 138 insertions, 3 deletions.
- No new public API or game-specific runtime switch.
- Three synthetic full-reader tests pass.
- Complete Release `components-tests`: 1,435 / 1,435 pass with MSVC 19.44.
- `git diff --check`: pass.

## Second clean topic: WEAP model identities

### Evidence

- xEdit source commit:
  `fd1e36020b2b5b6217e553dc0038983146a2e2dd`.
- `wbDefinitionsFNV.pas` SHA-256:
  `175360DFAC2F51BA1F041E916ED82732C8698F84D010C9C64B20DA3B224CD5EC`.
- xEdit defines WEAP `MOD4` as the world model and `WNAM` as a first-person
  model reference constrained to `STAT`.
- Generator SHA-256:
  `C7BE2F79A9DCE405A16A55C5FFDD8A1C4A334DFE1D0B86D2F59B85E3ECF5250F`.
- Fresh report SHA-256:
  `BFD506F519954D876CE3087354E6994BEA81E9A517E042FBEE27192330D88228`.
- Canonical report SHA-256, excluding local diagnostics:
  `d2ed089a3f56feb3785256e46102755b820c3116bfc9ba81cf566aa7c84cd442`.
- Winning FNV WEAP records: 496 total; 111 carry `MOD4`; 329 carry `WNAM`.
- All 245 firing held weapons resolve a first-person model: 232 through a
  `WNAM -> STAT -> MODL` chain and 13 through the held `MODL` fallback.

Confidence: `confirmed` for FNV and corroborated by the independent xEdit
definition; other Bethesda-title consumers of the same fields remain outside
this bounded claim.

### Behavioral contract

Preserve the primary held model from `MODL`, the dropped/world model path from
`MOD4`, and the load-order-adjusted first-person static-model reference from
`WNAM`. Consume the associated `MO4*` model metadata without losing the next
subrecord boundary.

### Implementation and verification

- Test-only fixture refactor: `654773f4be3d0cbcef15d6e2c132864cf95eb942`.
- Model parser topic: `e6268c309eee4577b6cf649d7de9bc0c28adc38a`.
- Production topic surface: 4 files, 58 insertions, 4 deletions.
- No combat, animation, renderer, UI, or runtime-policy changes.
- Synthetic full-reader test checks all three model identities, skipped
  `MO4*` metadata, following-record alignment, and FormID adjustment.
- Complete Release `components-tests`: 1,436 / 1,436 pass with MSVC 19.44.
- Formatting and `git diff --check`: pass.

## First downstream architecture topic: game-owned UI identity

### Defect

HUD, inventory, item view, map, spell view, stats, and window management each
rescanned content filenames to decide whether to enable the New Vegas
interface. Several also treated `OPENMW_FNV_PROOF_PIPBOY_SURFACE` as a
production game-identity override. The already-loaded `ESMStore::getESM4Game()`
was the authoritative API but was bypassed.

### Contract

New Vegas UI selection is true only for `ESM4Game::FalloutNewVegas` after a
World exists. It is false for Unknown, Oblivion, Fallout 3, Skyrim, Fallout 4,
and Starfield. Proof configuration cannot redefine the loaded game.

One VFS check remains at WindowManager construction because the engine creates
the GUI before it creates and loads World/ESMStore. Removing that check requires
passing an explicit startup content profile into the constructor; calling the
runtime store API at that lifecycle point would always return false.

### Implementation and verification

- Central policy and enum coverage: `57d5c55adc8437c8486c7779a386829821303a8f`.
- Seven-consumer migration: `40efc220ea4f357b090e3b331a2fab3e96e73e1a`.
- Net surface from recovery: 12 files, 78 insertions, 119 deletions.
- Removed every GUI content-list scan and every
  `OPENMW_FNV_PROOF_PIPBOY_SURFACE` identity override.
- Release `openmw-tests`: 979 / 979 pass with MSVC 19.44.
- Full `openmw-lib`, including Engine, ESM4 NPC animation, physics, mechanics,
  VR, and all affected GUI translation units, compiles successfully.
- `git diff --check`: pass.

### Startup identity completion

- Ordered startup classifier: `d20540af81634bdac3c0cc76badf7e9befcfd520`.
- Engine-to-WindowManager profile threading:
  `e3d86c5fa683517eb28e0e5781c1a926bb4e2617`.
- The first recognized base game is computed once from configured content
  order; built-in scripts and addons are ignored and filename case is
  normalized.
- Engine reuses the immutable session value for its pre-load FNV gates and
  passes it explicitly into WindowManager.
- Removed the final GUI VFS master probe and four repeated Engine scans.
- Focused startup/profile tests: 4 / 4 pass.
- Release `openmw-tests`: 982 / 982 pass with MSVC 19.44.

## Collision foundation: closest-hit geometry identity

### Defect

The recovery implementation attached one optional Havok material to an entire
loaded NIF and copied that value into ray results. That loses the distinction
between collision subshapes and triangles, so a mixed-material mesh can report
the wrong surface even when Bullet selected the correct primitive.

### Contract

For an accepted closest ray hit, preserve Bullet's shape-part and triangle
indices through `RayCastingResult`. A closer hit without local shape metadata
must clear stale identity, and a filtered hit must not overwrite the accepted
identity. This contract does not infer or select a material.

### Implementation and verification

- Hit-identity topic: `fb41613273b9c826a195b7bff38dcdd6f7af3f2f`.
- Surface: 6 files, 97 insertions, 1 deletion.
- Focused synthetic callback tests: 3 / 3 pass.

### Material and authored-collision contract

Resolve impact material from Bullet's accepted `(shapePart, triangleIndex)`
identity in this order: exact triangle, containing shape part, then an explicit
uniform fallback. For Fallout 3 / New Vegas packed collision, convert each
contiguous `hkSubPartData` vertex partition into its own Bullet indexed-mesh
part and attach that subshape's five-bit impact material. Use authored
`bhkCollisionObject` -> `bhkRigidBody(T)` -> `bhkMoppBvTreeShape` ->
`bhkPackedNiTriStripsShape` -> `hkPackedNiTriStripsData` geometry only when a
BSX collision-enabled root has exactly one supported active body, no active
transform ownership, no `AvoidNode` ownership, and the packed scale mirrors
the owning node scale. Inspect the complete active tree before selecting it.
Unsupported, half-float-compressed, malformed, animated, independently scaled,
or multi-body trees fall back atomically to the legacy visual mesh; never mix
partial authored and autogenerated geometry.

### Evidence

- Retail target: untouched English Fallout: New Vegas
  `Fallout - Meshes.bsa`, 1,061,624,491 bytes; SHA-256
  `054E299829FF24FD4BD4EDF69F6424346B400C87379CEE39BEC02E4D082BF85A`.
- A fresh read-only production-loader audit parsed all 14,881 retail NIFs.
  There are 6,232 active files with attached packed collision, 8,586 attached
  packed bodies, 957,375 triangles, and 11,776 material subshapes. 2,246 files
  contain more than one five-bit material, directly disproving a file-wide
  material model.
- Of those files, 6,114 have a wholly supported active collision tree: 5,499
  single-body and 615 multi-body. After BSX, animation, avoid, and scale gates,
  the production loader selects exactly 5,465 complete single-body trees
  (87.69% of the 6,232-file retail denominator).
- 514 supported retail files have both root and descendant collision. The old
  root-first return loaded only one body from those files while counting the
  file as authored coverage. The former 5,009 / 5,221 (95.94%) statement was
  therefore a partial-body selection metric, not complete-tree correctness,
  and is retired.
- A coarse packed-only audit found 83 fixed multi-body candidates. The production gate
  additionally compares broad-phase properties, entity/body response state,
  contact behavior, deactivation/quality state, body flags, and subshape
  filters. It accepts 70 and leaves the other 13 as fallback. Total authored
  selection reached 5,535 / 6,232 retail files at that checkpoint.
- Explicit animated-node ownership adds all 34 complete single-body animated
  packed trees, for 5,569 / 6,232 packed-collision files. The 663 packed
  fallbacks are 491 heterogeneous-filter multi-body trees, 35 non-fixed
  multi-body trees, 28 animated mixed/multi trees, 13 other semantic
  mismatches, and 96 packed-plus-unsupported mixed trees.
- The full active-collision denominator is 8,324 files, not merely the 6,232
  files containing packed collision. Direct convex primitives, transform/list
  wrappers, equivalent fixed primitive bodies, and the scene-unit
  `bhkNiTriStripsShape` family add 1,761 complete files. Current authored
  selection is 7,330 / 8,324 (88.06%).
- The remaining 331 non-packed files are 273 rejected multi-primitive trees,
  29 phantoms/triggers, 28 nested mixed list/MOPP wrappers, and one shared-node
  box topology. Together with the 663 packed fallbacks, the explicit remaining
  architecture boundary is 994 retail files.
- All 258 non-unit retail packed scales mirror the owning node scale. The
  converter applies the node transform once and now rejects independent or
  non-uniform packed scale instead of guessing or double-scaling.
- The earlier 1,970,273,055-byte archive with SHA-256
  `A06C91D00859B0662E24769083768CC124E583E85B7BCA78509DF06C61010889`
  is the TTW/OpenMW merged archive, not untouched retail FNV. Its separate
  audit parsed 12,970 / 12,976 NIFs, found 5,208 active packed-collision files,
  and selected 4,503 complete single-body trees. The fixed accumulator raises
  its current complete-tree selection to 4,551. It is useful compatibility
  evidence but earns no retail-denominator credit.
- NifSkope source commit `3a85ac55e65cc60abc3434cc4aaca2a5cc712eef`
  corroborates the cumulative subshape vertex partitions and 1:7 Fallout
  Havok transform. Relevant source SHA-256 values are
  `28B84D8EB25FBDBD6733433B877A7557A8A63E509CD1E0BAE39A85410820AF8D`
  (`glnode.cpp`) and
  `6F10560F736A58A4C9B6E1D303868C44009A4A05333C8883E230CD17728AF140`
  (`moppcode.cpp`).
- Bullet 3.25 reports indexed-mesh subpart and triangle identity through
  `LocalShapeInfo`; the callback contract is covered independently.

Confidence: `confirmed` for the hashed retail archive and the 7,330 selected
complete collision trees. No claim is made yet for the 994 retail fallback
files, heterogeneous/dynamic multi-object filtering, phantom/trigger behavior,
nested mixed wrappers, or natural retail impact timing. The merged TTW/OpenMW
corpus is explicitly non-retail evidence.

### Implementation and verification

The reviewable acceptance lane is now reconstructed directly over official
OpenMW `master`, independent of the recovery and downstream trees:

1. `d2b2990db5` — preserve accepted ray shape-part/triangle identity.
2. `a356d8fc29` — resolve exact, part-default, and explicit uniform materials
   through a private map-backed table and the existing physics object boundary.
3. `0c1085eafc` — load only the supported complete Fallout packed-collision
   topology with root-scoped BSX, transform, scale, and atomic-fallback gates.
4. `b3f73ff2c8` — preserve the same identity/material contract for convex
   sweeps and physical projectile impacts.
5. `12f7214731` — accumulate source parts for equivalent fixed multi-body
   trees while retaining one global Bullet shape-part/material namespace.
6. `ea128d82f3` — preserve complete single animated packed bodies through the
   existing node-record-index ownership API.
7. `b49d1799d1` — convert boxes, spheres, capsules, convex hulls, transform
   wrappers, and supported list/MOPP-list shapes.
8. `9315b74432` — merge equivalent fixed primitive bodies and reject
   heterogeneous list child filters.
9. `f1cd77f276` — convert the distinct scene-unit `bhkNiTriStripsShape` path.
10. `74976d977a` — preserve accepted Fallout world-object, rigid-body, and
    distinct subshape filter tuples through `BulletShape` cloning while
    leaving rejected atomic fallbacks untagged.
11. `ae773b547d` — encode the confirmed retail primary and biped collision
    matrices in a Bullet-independent evaluator with explicit unsupported-layer
    results and exhaustive policy tests.
12. `155614a8ca` — expose the compatibility primary body and ordered additional
    bodies through one resource API while preserving independent shape,
    material, filter, cloning, and scaling identity.

The clean series is 26 files, 2,650 insertions, and 16 deletions across twelve
single-purpose commits. It introduces no Lua, MyGUI, proof route, content-name
scan, environment-controlled gameplay policy, public NIF-record scan API, or
copied retail fixture. Its synthetic loader test performs an actual Bullet
raycast through the converted multipart mesh and resolves the struck part's
material. A temporary read-only production-loader audit was removed after it
confirmed all 14,881 retail NIFs parse and exactly 7,330 files select authored
collision. A separate TTW/OpenMW sweep at the primitive/multi checkpoint
selected 6,198 complete trees.

- Clean Release `components-tests`: 1,464 / 1,464 pass.
- Clean Release `openmw-tests`: 496 / 496 pass.
- Clean `openmw.exe`, `openmw-lib`, and both owning tests compile with MSVC
  19.44.
- Clean `git diff --check`: pass.

The following downstream commits are product checkpoints rather than the
proposed upstream review base:

The maintainable product integration is branch
`codex/openmw-maintainable-downstream-20260821`, currently headed by
`4b73acfdac`. The official-master series above remains the upstream review
lane; the downstream commits below are the API-adapted product lane.

- Identity-keyed material resolver: `d6569480a7`.
- Authored packed collision loader: `bdd46e9403`.
- Sphere/projectile convex hit identity: `bfd6028cdd`.
- Single static descendant collision: `91edc6b84c`.
- File-wide material inference removal: `7ba26596ec`.
- Encapsulated identity-keyed material table: `3b3480f39e`.
- Atomic BSX/active-tree ownership: `e790d4095d`.
- Mirrored packed-scale validation: `ce6b04a8bd`.
- Equivalent fixed packed-body merge: `7f79e433c0`.
- Single animated packed-body ownership: `eae6cc20f3`.
- Primitive, convex-transform, and supported list/MOPP-list conversion:
  `a3a5c342dd`.
- Equivalent fixed primitive-body merge: `904a089a8a`.
- Scene-unit `bhkNiTriStripsShape` conversion: `2420a1ed59`.
- Downstream NIF list-child reference resolution: `25d120acbe`. The retail
  oracle exposed that this older API read `bhkListShape::mSubshapes` indices
  without the standard `postRecordList` pass; hand-wired synthetic records
  could not reveal the unresolved integer pointers. Current official OpenMW
  already has the corresponding `bhkListShape::post` hook.
- Accepted collision filter tuple preservation: `1e55c94eb9`. Raw authored
  world-object, rigid-body, and distinct accepted subshape values now survive
  resource instancing; rejected/generated fallback resources remain untagged.
- Retail pair evaluator: `968e88bd0c`. The destination C++ function exhausts
  all 1,849 primary pairs and 1,024 biped subfield pairs in unit tests and
  replays all 8,192 retained natural retail calls with zero unsupported words
  and zero mismatches through an external probe compiled from the committed
  source.
- Ordered resource bodies: `4b73acfdac`. Existing callers retain the same
  primary-body fields, while cloning, scaling, material lookup, and raw filter
  metadata now address deterministic additional body indices.
- The converter owns its multipart vertex/index storage, applies the Fallout
  1:7 unit ratio plus rigid-body/root transforms, strips non-material flag bits,
  and preserves the compressed-vertex marker instead of decoding zeroes.
- Unattached record scanning and its `FileView` record-index API were removed;
  material identity now comes only from the accepted collision path.
- Focused ownership, material, and loader tests pass, including BSX root scope,
  equivalent fixed-body merges, heterogeneous/non-fixed atomic fallback,
  animated ownership, list-child filter rejection, Bullet-observed compound
  child identity, scene-unit strips, and scale applied exactly once.
- Focused ray/convex identity tests: 5 / 5 pass.
- Complete Release `components-tests`: 1,627 passed, 8 fixture-dependent skips.
- Complete Release `openmw-tests`: 987 / 987 pass with MSVC 19.44.
- Full Release `openmw.exe`, `openmw-lib`, and both owning test targets compile.
- A temporary read-only downstream production-loader oracle was removed after
  enumerating the immutable retail archive through OpenMW's own VFS and NIF
  reader. At product head `25d120acbe`, it parsed 14,881 / 14,881 NIFs and
  selected exactly 7,330 authored collision files, including 85 animated
  files. This matches the official-master clean oracle exactly and keeps the
  active-collision result at 7,330 / 8,324 (88.06%).
- Formatting and `git diff --check`: pass.
- Retail-parity credit is bounded to authored collision geometry and material
  routing for the supported topology. Natural retail/OpenNV impact
  differentials remain required.

## Rejected non-topics

- Compact `SPEC` material routing is not independently extractable: it belongs
  to the downstream external-KF property controller subsystem, which official
  OpenMW does not contain. Adding the alias alone would be unused code.
- `NiBlendBoolInterpolator` visibility-shell handling is not a behavior fix in
  the current upstream path. The existing loader already rejects it and adds no
  callback; the recovery change only suppresses expected error logging.

Neither item receives a commit merely to make the backlog appear to move.

## Extraction rules

Every new clean topic must satisfy all of the following:

1. Start from current official OpenMW `master` or from a short, explicit stack
   of already-clean topics.
2. State one implementation-neutral behavioral contract.
3. Name immutable source evidence and its confidence level.
4. Use existing OpenMW APIs and ownership boundaries before adding an API.
5. Use synthetic fixtures; do not copy game data or reverse-engineered
   pseudocode into the engine.
6. Contain no proof route, capture state machine, named actor/cell, or
   environment-driven gameplay policy.
7. Pass focused tests, the complete owning test binary, formatting, and
   `git diff --check`.
8. Remain understandable without the recovery branch or private game data.

## Ordered extraction backlog

| Order | Topic | Destination | Required split / gate | Status |
| ---: | --- | --- | --- | --- |
| 1 | AMMO 12-byte `DAT2` | generic ESM4 component | Full-reader fixtures and load-order FormID checks | complete at `1a0bb044de` |
| 2 | WEAP `MOD4` / `WNAM` semantics | generic ESM4 component | Separate from combat, animation, and UI | complete at `e6268c309e` |
| 3 | NIF `SPEC` material channel token | external-KF property subsystem | Extract only with the owning property-controller route | blocked as standalone dead code |
| 4 | Blend-bool visibility shell handling | generic NIF loader | Existing path already skips the callback | dropped as log-only |
| 5 | Havok material propagation | generic resource/physics layer | Preserve per-subshape semantics; do not collapse mixed materials or filter tuples | official-master clean series at `74976d977a`; 7,330 / 8,324 active retail collision files selected, 994 explicit fallbacks |
| 6 | Projectile launch and impact | downstream OpenNV services | Separate generic physics query from FNV damage policy | pending |
| 7 | Combat cadence and ammo state | downstream OpenNV mechanics | Remove proof paths and numeric UI policy | pending |
| 8 | Pip-Boy data presentation | downstream OpenNV UI | Presenter boundary, localization, no `SpellWindow`/`StatsWindow` repurposing | redesign required |
| 9 | Content detection | downstream capability service | Runtime and pre-World consumers share one ordered immutable game identity | complete at `e3d86c5fa6` |
| 10 | Proof and capture orchestration | external harness | Remove from `Engine::frame()` and production UI | redesign required |

## Next no-detour sequence

The owning design is
[`openmw-multi-object-collision-contract-20260822.md`](openmw-multi-object-collision-contract-20260822.md).
Retail filter research is bound to `FalloutNV.exe` 1.4.0.525, SHA-256
`518C87F58A6C4D9826E9EF8FBB7F4213882FA70822675610D45AEA2464502A57`.
The initialized live evaluator is at VA `0x00C84740`; its primary 43-layer
table begins at `0x01267F20` and its 32-row biped subfield table at
`0x01268078`. A one-shot first-call hook captured the complete contiguous
472-byte region: all 43 primary rows and all 32 subfield rows match the decoded
matrices, the earlier first 256 bytes match byte-for-byte, and both matrices
have zero symmetry mismatches. A retained load-time zero snapshot proves the
tables initialize after NVSE plugin load and before the first verified
evaluator call. All 12,942 authored retail rigid-body groups are zero, so the
runtime instantiation transform is not an unchanged NIF copy. An isolated
Goodsprings hook captured 8,192 natural retail pair decisions over 1,361 words
and 1,142 nonzero runtime groups; the recovered evaluator and tables reproduce
all 8,192 results with zero mismatches. Runtime system-group assignment is
therefore confirmed at population level, while the exact record-to-collidable
identity transform remains to be traced and must not be guessed.

1. Make `MWPhysics::Object` own, register, transform, ignore, query, and remove
   every ordered resource body before touching the 491 heterogeneous-filter
   packed trees or the remaining multi-primitive trees. Assign runtime system
   identity only after the authored-to-live transform is confirmed, then route
   final Fallout body pairs through the immutable evaluator; 43 layers cannot
   be represented losslessly by one ordinary 32-bit mask.
2. Model `bhkSimpleShapePhantom` as trigger ownership, never as solid geometry.
3. Treat the 28 nested mixed list/MOPP wrappers as a recursive material/filter
   namespace topic after multi-object ownership exists.
4. Keep the TTW-only 6 `NiRangeLODData` parser misses separate from retail
   collision coverage.
5. Build natural retail/OpenNV impact differentials for supported uniform and
   mixed-material surfaces; staged or proof-only routes earn no parity credit.
6. Split generic projectile query/result data from FNV ammo, damage,
   impact-set, timing, and presentation policy.
7. Introduce Pip-Boy presenters for status, inventory, data, and map, then stop
   repurposing Morrowind `StatsWindow` and `SpellWindow` as data models.
8. Move proof/capture routes out of `Engine::frame()` behind an external
   integration driver and narrow engine test commands.

Large recovery commits are mined for contracts and tests only. They are never
used as evidence that a clean topic is correctly shaped.
