# OpenMW / OpenNV Maintainability Recovery — 2026-08-21

## Objective

Keep the Fallout: New Vegas and VR implementation as a maintained downstream
product while holding every extracted engine change to the reviewability,
architecture, and regression standards expected in OpenMW itself. Actual
upstream submission is optional; upstream-quality code shape is not.

The pre-recovery lab is evidence and reference behavior. It is not the base for
new implementation work.

## Preserved identities

| Lane | Branch | Commit | Tree | Purpose |
| --- | --- | --- | --- | --- |
| Recovery lab | `codex/recovery-20260821-openmw-lab` | `8594ef323f548f8b01c86bdf7149ccdf03361933` | `07bf15bf70da1c84271e5bae7ec1398d74b815a4` | Exact 79-file pre-cleanup implementation; never promoted as a topic |
| Promoted overlay | existing locked queue | `f8863dd47a608c5534d1a89dc6d1584b4c79fd12` | `1eaaaa089807aef77c57a7cd616f8c24fb5dbf4a` | Patches 0001-0024; formal replay baseline |
| Candidate overlay | `codex/openmw-overlay-0025-checkpoint` | `79290f2a06e7fff85c17e39bd3cd1dc1412ada33` | `c5b4f00165e8a02813b443e45311ba7ea29fe605` | Patches 0001-0025; telemetry candidate only |
| Clean extraction | `codex/openmw-clean-extraction-20260821` | `e6268c309eee4577b6cf649d7de9bc0c28adc38a` | `280110379b352526fd3a7b5d9ac27cb0a43fb303` | Official-master-based parser topics and reusable synthetic fixtures |

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
| 3 | NIF `SPEC` material channel token | generic NIF loader | One controller fixture; no other NIF changes | pending |
| 4 | Blend-bool visibility shell handling | generic NIF loader | Demonstrate duplicate callback overwrite in isolation | pending |
| 5 | Havok material propagation | generic resource/physics layer | Preserve per-subshape semantics; do not collapse mixed materials | redesign required |
| 6 | Projectile launch and impact | downstream OpenNV services | Separate generic physics query from FNV damage policy | pending |
| 7 | Combat cadence and ammo state | downstream OpenNV mechanics | Remove proof paths and numeric UI policy | pending |
| 8 | Pip-Boy data presentation | downstream OpenNV UI | Presenter boundary, localization, no `SpellWindow`/`StatsWindow` repurposing | redesign required |
| 9 | Content detection | downstream capability service | One parsed content profile; no repeated filename scans | redesign required |
| 10 | Proof and capture orchestration | external harness | Remove from `Engine::frame()` and production UI | redesign required |

Large recovery commits are mined for contracts and tests only. They are never
used as evidence that a clean topic is correctly shaped.
