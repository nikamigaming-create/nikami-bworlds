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
| Maintainable downstream | `codex/openmw-maintainable-downstream-20260821` | `bdd46e94030fb90030ae5b641fbc073c5c003ab9` | `99a773ac48e517eb68688958bc0dd0e038332340` | Product cleanup rooted at the immutable recovery checkpoint |

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
`bhkPackedNiTriStripsShape` -> `hkPackedNiTriStripsData` geometry when exactly
one supported root owns collision. Unsupported, half-float-compressed,
malformed, or ambiguous roots fall back atomically to the legacy visual mesh;
never mix partial authored and autogenerated geometry.

### Evidence

- Target `Fallout - Meshes.bsa`: 1,970,273,055 bytes; SHA-256
  `A06C91D00859B0662E24769083768CC124E583E85B7BCA78509DF06C61010889`.
- Read-only full-archive audit: 12,976 NIFs; 12,970 parsed; 6 existing
  `NiRangeLODData` parser misses.
- Parsed packed-collision corpus: 5,221 files, 6,316 packed records, 705,629
  triangles, and 9,236 material subshapes; maximum 68 subshapes in one file.
- No packed file used half-float-compressed vertices. 2,149 files contain more
  than one five-bit Havok material, directly disproving a file-wide material
  model.
- The first root-owned packed path selects authored geometry for 4,850 of the
  5,221 packed-collision files. The remaining 371 are an explicit topology
  backlog, not claimed coverage.
- NifSkope source commit `3a85ac55e65cc60abc3434cc4aaca2a5cc712eef`
  corroborates the cumulative subshape vertex partitions and 1:7 Fallout
  Havok transform. Relevant source SHA-256 values are
  `28B84D8EB25FBDBD6733433B877A7557A8A63E509CD1E0BAE39A85410820AF8D`
  (`glnode.cpp`) and
  `6F10560F736A58A4C9B6E1D303868C44009A4A05333C8883E230CD17728AF140`
  (`moppcode.cpp`).
- Bullet 3.25 reports indexed-mesh subpart and triangle identity through
  `LocalShapeInfo`; the callback contract is covered independently.

Confidence: `confirmed` for the hashed target archive and the supported
root-owned packed topology. No claim is made yet for the 371 fallback files,
the 6 unparsed NIFs, other `bhk` shape families, or end-to-end impact timing.

### Implementation and verification

- Identity-keyed material resolver: `d6569480a7`.
- Authored packed collision loader: `bdd46e9403`.
- The converter owns its multipart vertex/index storage, applies the Fallout
  1:7 unit ratio plus rigid-body/root transforms, strips non-material flag bits,
  and preserves the compressed-vertex marker instead of decoding zeroes.
- Focused material/loader tests: 6 / 6 pass.
- Complete Release `components-tests`: 1,594 passed, 8 fixture-dependent skips.
- Complete Release `openmw-tests`: 985 / 985 pass with MSVC 19.44.
- Full Release `openmw-lib` and both owning test targets compile.
- Formatting and `git diff --check`: pass.
- Retail-parity credit is bounded to authored collision geometry and material
  routing for the supported topology. Projectile convex-sweep identity and
  natural retail/OpenNV impact differentials remain required.

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
| 5 | Havok material propagation | generic resource/physics layer | Preserve per-subshape semantics; do not collapse mixed materials | ray identity and root packed path complete at `bdd46e9403`; 371 packed topologies and convex sweeps pending |
| 6 | Projectile launch and impact | downstream OpenNV services | Separate generic physics query from FNV damage policy | pending |
| 7 | Combat cadence and ammo state | downstream OpenNV mechanics | Remove proof paths and numeric UI policy | pending |
| 8 | Pip-Boy data presentation | downstream OpenNV UI | Presenter boundary, localization, no `SpellWindow`/`StatsWindow` repurposing | redesign required |
| 9 | Content detection | downstream capability service | Runtime and pre-World consumers share one ordered immutable game identity | complete at `e3d86c5fa6` |
| 10 | Proof and capture orchestration | external harness | Remove from `Engine::frame()` and production UI | redesign required |

## Next no-detour sequence

1. Classify the 371 packed-collision fallback files by attachment/wrapper/root
   topology, then extend authored conversion one bounded shape family at a
   time. Keep the 6 `NiRangeLODData` parser misses as a separate parser topic.
2. Preserve `LocalShapeInfo` through sphere and projectile convex sweeps and
   resolve their material through the same identity-keyed API.
3. Split generic projectile query/result data from FNV ammo, damage,
   impact-set, timing, and presentation policy.
4. Introduce Pip-Boy presenters for status, inventory, data, and map, then stop
   repurposing Morrowind `StatsWindow` and `SpellWindow` as data models.
5. Move proof/capture routes out of `Engine::frame()` behind an external
   integration driver and narrow engine test commands.

Large recovery commits are mined for contracts and tests only. They are never
used as evidence that a clean topic is correctly shaped.
