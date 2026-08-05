# FNV Real-Save Pip-Boy and Fast-Travel Progress

Last updated: 2026-08-02

Plan: `docs/fnv-real-save-pipboy-fast-travel-luna-max-plan.md`

## Current bite

- `D02 — Weapon selection matrix`: IN PROGRESS

## Save decision

| Candidate | Hash / masters | Decision |
|---|---|---|
| Save330, Goodsprings 00:16:45 | `07DBDD...BD81F`, 10 official | PRIMARY |
| Save341, Goodsprings 00:02:00 | `D33A03...D8CF5`, 10 official | Retail Pip-Boy oracle only |
| Save280, Mojave 00:05:03 | `6A5D38...AE78`, 10 official | Fallback |
| Save219, Mojave 16:25:32 | `6DE8D1...B906`, 67 modded | Rejected for official campaign fixture |

## Last passing implementation proof

- Root: `run/opennv-pipboy-item-use-reload-gate-20260802-111500/openmw`
- Runtime:
  `local/openmw-pipboy-item-gates-20260802-111400/openmw.exe`
- Runtime SHA-256:
  `FE553A1598AC82A5DF2E5FD2452CD9C8E725566FCAE12A7F247BBD99DD71A778`
- Passed: real 9mm selection, real varmint selection, Stimpak `5 -> 4`,
  health `75 -> 100`, reload magazine `0 -> 5`, reserve `60 -> 55`.
- Limitation: this proof uses TestMap/new-game showcase state, not Save330.

## Bite ledger

| Bite | Status | Artifact / fact |
|---|---|---|
| A01 Freeze Save330 | PASS | Exact immutable fixture copy; manifest at `run/fnv-real-save-campaign/save330-fixture-manifest.json` |
| A02 Official load order | PASS | 10/10 exact order; save-ordered profile generated; `Test-FNVSaveProfile.ps1` passes |
| Luna readiness | PASS | Fixture/runtime hashes, exact 10-master profile, 29 required tool/source paths, and the deterministic profile contract pass; report at `run/fnv-real-save-campaign/luna-readiness.json` |
| A03 Save denominator | PASS | `save330-player-denominator.json` is the normalized native `FalloutSaveLoadPlan` output for the immutable Save330 fixture. `Test-FNVRealSaveA03.ps1` passes the pinned 3,395,328-byte hash, exact 10-master order, 50 final totals reconciled to 52 contributions, 24 conditioned stacks, 3 worn rows, actor-value modifiers and 3x77 samples, 200 globals, quest provenance, explicit unsupported marker state, and 6,600 opaque ranges totaling 2,685,310 bytes. |
| A04 Inventory join | PASS | `save330-inventory-join.json` joins all 50 positive normalized rows to the frozen ten-master corpus: MISC 13, WEAP 10, ARMO 12, ALCH 10, AMMO 4, BOOK 1, unresolved 0. `Test-FNVRealSaveA04.ps1` passes source hash, row/count parity, provenance, equipment, condition, weapon ammo/list/clip, and ALCH effect checks. |
| A05 Save330 vs Save341 | PASS | `save330-vs-save341-inventory.json` is keyed by canonical FormID: common 21, Save330-only 29, Save341-only 0, count mismatches 3, equipped mismatches 0; totals are Save330 50 rows/788 items versus Save341 21 rows/152 items. `Test-FNVRealSaveA05.ps1` passes fixture/telemetry hashes, provenance, keyed-row parity, classifications, and denominator totals. |
| B01 Canonical RealSave lane | PASS | `Test-FNVRealSaveB01.ps1` and the required `Test-FNVJamBackgroundCapture.ps1 -Target OpenMW -Scenario RealSave -RuntimeReady -RequireIdle` pass. The catalog, public entry point, hash-locked immutable Save330 path, fresh-output/concurrency policy, ordinary-load runner, native frame, telemetry, exact-title video, and no-control contract are on disk. |
| B02 Normal Save330 cold load | PASS | Corrected public run `run/fnv-real-save-campaign/b02-openmw-20260802-215000/openmw` passes the state manifest and capture report: ordinary `--load-savegame`, 10-master native parse, Player `0x00000007/0x00000014`, saved worldspace/transform, native runtime inventory rebuild without fallback, native PNG, exact-title MP4, telemetry, and logs. Output is hash-locked to the immutable Save330 fixture and staged OpenMW binary. |
| B03 Real-world settle | PASS | `Test-FNVRealSaveB03.ps1` writes `b03-settle-validation.json` and passes 20/20 deterministic checks against the fresh public run `b03-openmw-20260802-220100`: 27 world-ready telemetry samples, stable Goodsprings exterior/worldspace/camera, health 100, AP 80/80, authored actors, assembled equipment, native frame/video, and no fatal required-asset failure. |
| B04 Reload idempotence | PASS | Production Save330 quicksave/cold-reload and deterministic 34-check validator pass; exact inventory/equipment, actor modifier, quests/globals, marker list, transform/time/HP/AP, and unattended evidence are retained. |
| C01–C08 Fast travel | PASS | C01–C07 PASS; C08 remains for the sequential retail/OpenMW pair. |
| D01 Inventory | PASS | Strict 39-check validation proves all five production tabs, supported-row parity, full totals, worn/equipped rows, condition/stats, icons, and exact provenance. |
| D02–D05 Inventory | IN PROGRESS | D02 must select every supported Save330 weapon through the normal production path. |
| E01–E05 Weapons/animations | TODO | Narrow reload passes; full matrices absent |
| F01–F03 Handoff | TODO | — |

## Resume instruction

Open the plan, take the first READY/TODO bite whose dependencies are complete,
mark it IN PROGRESS here, execute its exact gate, record artifacts and facts,
then move immediately to the next bite. Never promote an unchanged rerun.

## A03/A04/A05 completion note (2026-08-02)

- Readiness gate passes at `run/fnv-real-save-campaign/luna-readiness.json`.
- A03 is complete: the native exporter serializes the normalized
  `FalloutSaveLoadPlan` into `save330-player-denominator.json`; its deterministic
  validator passes all required totals, equipment, actor values, quest/global,
  marker-status, opaque-range, and exact-provenance gates.
- A04 is complete: `save330-inventory-join.json` resolves all 50 positive rows
  through the frozen ten-master official corpus; unresolved count is zero.
- A05 is complete without a second binary parser: the existing retail oracle
  telemetry supplies the clean Save341 inventory denominator, and the comparison
  is hash-locked to both immutable fixtures and the selected frame-2 snapshot.
- A05 artifacts:
  `run/fnv-real-save-campaign/save341-inventory-denominator.json`,
  `run/fnv-real-save-campaign/save330-vs-save341-inventory.json`, and
  `run/fnv-real-save-campaign/save330-vs-save341-inventory-validation.json`.
- No game launch was used for A03/A04/A05.

## B01 completion and B02 handoff (2026-08-02)

- B01 is complete. `scripts/Test-FNVRealSaveB01.ps1` passes and writes
  `run/fnv-real-save-campaign/b01-contract-validation.json`.
- The required OpenMW RealSave preflight passes with the immutable fixture and
  current staged runtime; no game was launched during B01 contract work.
- B02 is now active: launch only through the public entry point, then inspect
  the state manifest, native frame, exact-title video, telemetry, and hashes.
- Continue using `Test-FNVJamBackgroundCapture.ps1 -RuntimeReady -RequireIdle`
  before every game task and `Invoke-FNVJamBackgroundCapture.ps1` as the only
  public capture entry point.

## B02 first-run diagnosis (2026-08-02)

- The retained first attempt proved the ordinary `--load-savegame` path,
  native structural parse, Player identity restoration, native world frame, and
  exact-title video, but its state validator selected the final settled
  telemetry sample (`z=8141.04`) instead of the first world-ready saved
  transform (`z=8137.59`), and expected `stacks=50` after conditioned stacks
  had rebuilt to `stacks=55 visible=53`.
- The capture directory is immutable evidence of that failed attempt and must
  not be overwritten. The B02 runner correction is source-only and has passed
  PowerShell parse plus the deterministic B01 contract validator.
- The second retained attempt at `run/fnv-real-save-campaign/b02-openmw-20260802-214000/openmw`
  reached the same native load state, but the expanded telemetry parser omitted
  the engine's `weatherId` and `weatherTransition` fields. Its native PNG,
  exact-title MP4, logs, and failed state manifest are also preserved; the
  parser has now been aligned to the complete telemetry line.

## B02 completion and B03 handoff (2026-08-02)

- Corrected public OpenMW RealSave run:
  `run/fnv-real-save-campaign/b02-openmw-20260802-215000/openmw`.
- Passing report: `real-save-capture-report.json`; passing state manifest:
  `real-save-state.json`.
- Retained native world frame: `Save330-native-world.png`, SHA-256
  `4D714864DEB9548D311B333D3FC4F12C0D856A6AC558700659F9368D9FBF1CD0`.
- Retained exact-title video: `OpenMW-Save330-exact-title-raw.mp4`, SHA-256
  `AA29E772C05C7222800A4B94B8145011703E1A1041F1474D873F3771434DC6A3`.
- Retained stdout/profile log SHA-256:
  `7E7BAAD1B9A895E6A45FC9A358872785F9465DD960F8C5859FA413FAB7C6BFB6`;
  state-manifest SHA-256:
  `CAA34D910BD917729DCED2C7084BF9D118811ADF98D3DDDF7C5FFDE2C75EEC9`.

## B03 completion and B04 handoff (2026-08-02)

- B03 is complete. The fresh public OpenMW RealSave run is
  `run/fnv-real-save-campaign/b03-openmw-20260802-220100/openmw`.
- Deterministic validator:
  `run/fnv-real-save-campaign/b03-settle-validation.json`, SHA-256
  `48310CAEECE6640B22A4AEF3FE27F401849DA9C18A3F9A6DF91C39C4BBB2B807`;
  status PASS with 20/20 checks. It records 27 repeated telemetry samples,
  first-to-last frame span 755, stationary final samples, Goodsprings
  `Mojave Wasteland` exterior state, finite time/weather/camera, health 100,
  AP 80/80, authored `Goodsprings Settler` and `Easy Pete`, assembled player
  equipment, and no T-pose, detached weapon, or fatal required-asset failure.
  The 37 known nonfatal missing-image warnings are retained in the validator
  evidence rather than treated as a silent pass.
- B03 evidence hashes: native frame
  `3D99B9C02B87C44D0C7D70D3436A2FF30EA4B97250EAAB874BE95F3059D953C8`;
  exact-title video
  `01E15FBB405EE1EB1240F8C317132DB0BF2B2E178F84C0689AEA62E862DEDFD2`;
  stdout/profile log
  `8C340BB21186A1F34612B2CBB21BB5AC624DD6B6E25D9F5B182C78D1079A6093`;
  state manifest
  `3C6982691F5F96E11E8D8CA1520FECB55910E232406F2A4A2BE2BBB4D5B182E4`.
  The staged B03 binary is
  `066AE1D32FA7E468AA66C3BE6ACC2E63826C20137DFE26A753FB34565333F6F9`.
- The first passing B04 candidate was retained as an intermediate audit run.
  The final public production-save/cold-reload run is
  `run/fnv-real-save-campaign/b04-openmw-20260802-155700/openmw`; it passed
  through the canonical background-capture entry point, produced
  `Save330-production-reload.omwsave`, and retained native PNG/MP4/log/state
  evidence for both sequential phases. The staged binary SHA-256 is
  `A9832277E7A87C7CC23AE45DB8A7AA18E071183F09A5662BA28F5BDE7E5BF6E8`.
  Earlier failed B04 roots remain preserved at
  `b04-openmw-20260802-220200`, `b04-openmw-20260802-152600`, and
  `b04-openmw-20260802-153700`; none was overwritten.

## B04 completion and C01 handoff (2026-08-02)

- B04 passes on the fresh public run
  `run/fnv-real-save-campaign/b04-openmw-20260802-161200/openmw`, captured
  sequentially through `Invoke-FNVJamBackgroundCapture.ps1` after the required
  55-check idle/runtime preflight. The combined report, both phase reports,
  both state manifests, native PNGs, exact-title MP4s, and stdout/profile logs
  are all retained; no host control, foreground input, concurrent capture, or
  output overwrite was used.
- Deterministic validator:
  `run/fnv-real-save-campaign/b04-reload-validation-final.json`, SHA-256
  `F42EE251CE01F02BCC606AEED266383132CF6DDAABC6435099C9879383AD2012`;
  status PASS with 34/34 checks. It proves the production
  `Save330-production-reload.omwsave` (SHA-256
  `B5990ED36813021CBC0E66006A2BDAC60775E91EA15A39E1C139C6976A3582CD`),
  native Save330 load, standard cold reload, 55 stack rows/788 items,
  three worn rows, actor-value modifier `24|10|0|0`, imported quest progress
  `stages=0 objectives=4 variables=92 states=17`, persisted quest runtime
  `640/1405/1479/4539`, globals `268 -> 268` after native import count 199,
  and all 320 authored map-marker rows with exact save/reload parity.
- B04 report SHA-256 is
  `C3742CD8D22BF7E66F678D597E13030B737F3B5A43CA87B3DF8A45DBCC863C68`;
  production manifest SHA-256 is
  `48D2298B89013E303DAF08C4D75675ECE0EEBDFFEDDA56B4B69563FE0911D8E`.
  The staged B04 binary is
  `E4C09EC4ECA6D34526AE951D81F36E351C146A719FC6D8C52DCFC65E7E698F2C`.
- C01 is now active. Its next artifact must use the same immutable Save330
  fixture and canonical capture contract to compare discovered marker state
  against the retail oracle before any natural fast-travel proof is promoted.

## C01 completion and C02 handoff (2026-08-02)

- C01 passes with the fresh public sequential run
  `run/fnv-real-save-campaign/c01-openmw-20260802-155750/openmw`. The required
  55-check idle/runtime preflight passed first; the run used the sole public
  background-capture entry point, retained both native frames, exact-title
  videos, telemetry, phase reports, state manifests, and hashes, and used no
  host control, foreground input, concurrent capture, or output overwrite.
- The deterministic validator
  `run/fnv-real-save-campaign/c01-map-marker-validation.json` has SHA-256
  `6A78F2BCF289F6995C6514063E30AA01672ACAFAA3068E411002342F08A57871` and
  passes 22/22 checks. It proves the immutable 3,395,328-byte Save330 fixture,
  A03 source provenance, 320 unique authored markers, complete finite fields,
  saved runtime states restricted to 0/1/2, one visible/travel-enabled row,
  zero runtime overrides, valid exterior-cell/worldspace destinations, exact
  native-load/cold-reload row parity, and no unlock/show-map/synthetic shortcut.
- Canonical denominator:
  `run/fnv-real-save-campaign/save330-map-marker-denominator.json`, SHA-256
  `43FB591EA5D3E117022FBABDD69EBBDB25E8E38099278DB7FD1BA9CD9C3391D9`.
  It serializes all 320 production marker rows with exact capture and fixture
  provenance, plus the cold-reload restoration rows for the next gate.
- C02 is now active. Its next bite must establish that the native Save330 load
  observes these saved states before proximity discovery and that defaults or
  the developer unlock-all switch cannot replace them.

## C02 pre-proximity instrumentation (2026-08-02)

- Added production telemetry at the existing StateManager load-return boundary:
  a complete `FNV C02 restored marker` snapshot is emitted with `state`, the
  authored fallback state, and explicit override presence, followed by a
  snapshot summary. `World::discoverFalloutMapMarkersNearPlayer` now emits a
  separate discovery-boundary marker, allowing the validator to prove ordering
  from one unattended log rather than infer it from frame timing.
- Rebuilt serially with `/m:1`; the active engine binary SHA-256 is
  `DB2373DE0DF64E22BE6C686D8ABD8CDA060C521945450BD8130440A4D1D2E78B`.
- Next bite: stage this binary under the repository runtime lane, run the
  mandatory idle/runtime preflight, and capture a fresh sequential Save330
  load/reload for the C02 ordering and state-restoration validator.

## C02 completion and C03 handoff (2026-08-02)

- C02 passes on the fresh public sequential run
  `run/fnv-real-save-campaign/c02-openmw-20260802-160545/openmw`. The combined
  production report passes; both phase reports, native frames, exact-title
  videos, state manifests, logs, and generated production save are retained.
  The report SHA-256 is
  `7504A2D1857A5A421EB359EF1D7E2D826BA1AE05A3EAD643A542278285ECF317`, the
  generated save SHA-256 is
  `EC23B988163B918CB77FD68D35D139263B0220B7C1E05ED3D810B2331F234878`, and
  the staged binary SHA-256 is
  `DB2373DE0DF64E22BE6C686D8ABD8CDA060C521945450BD8130440A4D1D2E78B`.
- Deterministic validator
  `run/fnv-real-save-campaign/c02-marker-restoration-validation-v2.json` has
  SHA-256 `26B0DDB361B2B3D6DF2DCB9BD150C8B65E1B978E5AA264EB394D2FE71DD78350`
  and passes 18/18 checks. It proves 320 native-load and 320 cold-reload
  restoration rows match the C01 denominator, all states remain in 0/1/2,
  zero explicit overrides are present, authored fallback states agree, and
  every restored row and summary precedes the first proximity-discovery
  boundary in both phases. The initial validator typo is retained as
  `c02-marker-restoration-validation.json`; it is not promoted evidence.
- C03 is now active. Its next bite is the focused fast-travel-resolution
  matrix, including retail-shaped rejection reasons for hidden, visible-only,
  travel-enabled, disabled-global, enemies-nearby, same-cell, exterior,
  interior, invalid-destination, and non-marker cases.

## C03 completion and C04 handoff (2026-08-02)

- Added the focused `FNVFastTravel.*` test suite against the existing
  production `resolveFalloutFastTravelDestination` implementation. The six
  tests cover discovered exterior/same-cell success, hidden and visible-only
  rejection, invalid/non-marker/missing destination, interior/worldspace
  mismatch, disabled/enemies rejection, and no-travel current cell/world.
  Each required retail-shaped reason is asserted exactly.
- The retained unattended test output is
  `run/fnv-real-save-campaign/c03-fast-travel-resolution-tests-20260802-161000.txt`,
  SHA-256
  `66F41CFCE7CA310F15E0E3477DCF5B194856568E2A2BBF3A1BE7A2E46FFB510D`.
  `Test-FNVRealSaveC03.ps1` passes 6/6 checks in
  `run/fnv-real-save-campaign/c03-fast-travel-resolution-validation.json`,
  SHA-256
  `85C5059E4A74F1F1581B54BDCC4643FD910B2872FB2F40082251B416C89E761E`.
  The focused components test executable was rebuilt with `/m:1` and has
  SHA-256 `FC5E52934BC7F163E698072CF72BB18380620AE1BFE93D0F6ABBE04039CE5068`.
- C04 is now active. Its next bite must exercise physical Pip-Boy MAP/WORLD
  selection against the restored Save330 marker without calling
  `showFalloutMapMarker` or using host input automation.

## C01 production marker telemetry implementation (2026-08-02)

- Added a production-only C01 marker row beside the retained B04 persistence
  row. Each authored marker now records FormID, name, icon type, resolved
  worldspace, parent cell, exterior grid, authored position, saved runtime
  state, authored visible/can-travel flags, reference validity, and the same
  exterior-cell/worldspace destination validity used by the production fast
  travel resolver. No second save parser or unlock-all switch is involved.
- Rebuilt the active engine serially with `/m:1`; the resulting binary is
  `D:/code/nikami-openmw-save330-integrated/MSVC2022_64/RelWithDebInfo/openmw.exe`
  with SHA-256
  `8FF4EE044D69B678EFCFCB2E419529A571A1EBB9C404423DDAF3CE853EBF8BC8`.
- Next bite: run a fresh sequential public Save330 capture with the required
  idle/runtime preflight, then emit and validate the immutable C01 denominator
  before moving to C02 restoration.

## C04 completion and C05 handoff (2026-08-02)

- C04 passes with a fresh public, non-overwriting OpenMW capture at
  `run/fnv-real-save-campaign/c04-openmw-20260802-171700`. The required
  `Test-FNVJamBackgroundCapture.ps1 -Target OpenMW -Scenario RealSave
  -RuntimeReady -RequireIdle` preflight passed 54/54 before capture, and the
  public wrapper report passes the ordinary `--load-savegame`, native Save330
  load, identity/transform, telemetry, three native frames, exact-title video,
  sequential-capture, and no-host-control gates.
- The physical Pip-Boy MAP/WORLD surface now draws the real Southern Passage
  cave icon from the restored production `ESM4::Reference` marker state. The
  runtime log records `FNV Pip-Boy MAP: overlay marker icons drawn=1
  source=restored-production-marker-state`; no `showFalloutMapMarker` or
  unlock-all path is used. The three retained frames are map overview,
  selected marker, and exact confirmation title
  `Fast travel to Southern Passage?` with `confirmed=0` and
  `travelExecuted=0`.
- Deterministic validator `scripts/Test-FNVRealSaveC04.ps1` passes 36/36 and
  writes `run/fnv-real-save-campaign/c04-map-selection-validation.json`,
  SHA-256
  `8D283A6054119CCC85B1AFC8287890E9E9FCA21D4B3C9A80947F15F47452D559`.
  The immutable fixture remains 3,395,328 bytes with SHA-256
  `07DBDD2D7C4ABE3160628E5463A9603A40F4271042C1DA1B89F1C4A4F7DBD81F`.
- The icon-enabled staged runtime is
  `local/openmw-real-save330-c04-icons-20260802-171500/openmw.exe`,
  81,076,224 bytes, SHA-256
  `0C4E973CEF31A1B1640E7C29E0D3BDF967ED5C73CFEBACBA4E0DFAF41FB0087F`,
  with resources/plugins present and zero PDB files. The retained raw video
  is `openmw/OpenMW-Save330-C04-map-selection-exact-title-raw.mp4`, SHA-256
  `7A32B393E6D6A65E3C87D621F394A4E8A7DE0E1E21F8BE2453DFF3C1BB2150F5`.
- C05 is now complete; the next bite is the rejection matrix.

## C05 completion and C06 handoff (2026-08-02)

- C05 passes with a fresh public, non-overwriting capture at
  `run/fnv-real-save-campaign/c05-openmw-20260802-173200`. The mandatory idle
  and runtime preflight passed 54/54, and
  `scripts/Test-FNVRealSaveC05.ps1` passes 38/38 in
  `run/fnv-real-save-campaign/c05-fast-travel-validation.json`, SHA-256
  `46BBB49089FC1C3FEB47B3C078F2259DE6E278A6B9A55C3A6A4284CA394178A6`.
- Production `requestFalloutFastTravel` opened the exact
  `Fast travel to Southern Passage?` confirmation, and production
  `confirmFalloutFastTravel` executed it. The retained telemetry proves
  marker `0x03008885` reached cell `0x0300688F`, worldspace `0x0300683B`,
  exterior grid `(-4,-11)`, with position match, `hours=4`, game hour
  `14.2243 -> 18.2243`, loading settled, menu closed, controls enabled, and
  travel flag cleared. No teleport shortcut, TestMap path, host input, or
  unlock-all path appears in the capture logs.
- The staged C05 runtime is
  `local/openmw-real-save330-c05-travel-time-20260802-173000/openmw.exe`,
  81,076,224 bytes, SHA-256
  `68EF0CD86D3CB55BDF37111A9E69426E9586A0FB5B52B4F58F29833F86947B85`,
  with resources/plugins present and zero PDB files. The exact-title raw
  video is `openmw/OpenMW-Save330-C05-map-travel-exact-title-raw.mp4`,
  SHA-256
  `3B176642CE530B1857B101C309A09384867A99A93D1ED8B24537F032E87D7ADB`.
- C06 is now active. Its next bite must exercise enemies-nearby, disabled
  travel, undiscovered/invalid destination, and cancellation through the
  production map path, proving rejection reasons and unchanged position/time
  while keeping Pip-Boy navigation usable.

## C06 completion and C07 handoff (2026-08-02)

- C06 passes with a fresh public, non-overwriting OpenMW capture at
  `run/fnv-real-save-campaign/c06-openmw-20260802-180200`. The mandatory idle
  and runtime preflight passed 54/54. The strict validator
  `scripts/Test-FNVRealSaveC06.ps1` passes 42/42 and writes
  `run/fnv-real-save-campaign/c06-rejection-matrix-validation.json`, SHA-256
  `9A10B798AC665F5033F5C6C25501221B35CF75469B9B3DCD5AD0EAAF6CFAC6D4`.
- The rejection matrix uses the restored Save330 production marker
  `Southern Passage` (`0x03008885`) and a hidden authored denominator marker.
  Through the physical Pip-Boy MAP path, cancellation, disabled travel,
  enemies nearby, undiscovered destination, and invalid destination each pass
  with the expected retail-shaped reason, unchanged position and time, and a
  usable map UI. The run records five ScreenCaptureHandler native frames and
  no successful fast-travel completion.
- The staged C06 runtime is
  `local/openmw-real-save330-c06-rejection-matrix-20260802-180000/openmw.exe`,
  81,104,896 bytes, SHA-256
  `D8A14BEB0A7C14CE718F2FD06BFF099F586FA4538F787BCE9CF0F899FB776745`, with
  resources/plugins present and zero PDB files. The retained exact-title raw
  video is
  `openmw/OpenMW-Save330-C06-rejection-matrix-exact-title-raw.mp4`, SHA-256
  `7D6CB6BC750ECCA7BCC1E8375FC39CD231C86E85FE73D73A0AE6968B0682B67C`.
- C07 was active at this handoff. Its completion and the D01 resume point are
  recorded below.

## C07 completion and D01 handoff (2026-08-02)

- C07 passes with the fresh public, non-overwriting OpenMW capture at
  `run/fnv-real-save-campaign/c07-openmw-20260802-185000`. The mandatory idle
  and runtime preflight passed 55/55. The strict validator
  `scripts/Test-FNVRealSaveC07.ps1` passes 60/60 and writes
  `run/fnv-real-save-campaign/c07-travel-persistence-validation.json`,
  603,357 bytes, SHA-256
  `EF8FBAA27F40D75C91075458EA7E6F1CDC63753B817EA054BF3F54DA1B70E037`.
- The staged production runtime is
  `local/openmw-real-save330-c07-travel-persistence-20260802-183000/openmw.exe`,
  81,104,896 bytes, SHA-256
  `2B51A8C80593AA36F8A58BB0A7B1CBDBCB3E1663C1B219941625F317921DB0D8`,
  with resources/plugins present and zero PDB files. Both phases load through
  the ordinary production save path and retain three native frames, telemetry,
  stdout/stderr, and exact-title raw video.
- The first production travel reaches the canonical discovered marker
  `Southern Passage` (`0x03008885`) at cell `0x0300688F`, worldspace
  `0x0300683B`, position `(-13248,-42631.2,7719.86)`, advances time from
  `14.2233` to `18.2233`, closes MAP, restores controls, and clears travel.
  StateManager then creates the retained production save
  `openmw/Save330-C07-travel-persistence.omwsave`, 47,364 bytes, SHA-256
  `55457B99C71481890C40FB4CA19D830DF099D98275C735B6AEBE7274AB2101D`, with
  manifest `openmw/save330-c07-production-save-manifest.json`, SHA-256
  `ACFDBAB6B6118315D60D38CCBF37306C481D5537DF5B5F47A51CFAEDCEB3793A0`.
- After a cold `--load-savegame` reload, the destination cell/worldspace and
  position persist, marker state remains `2`, the production MAP reopens with
  the `Southern Passage` icon selected, and inventory/equipment, actor-value
  modifier, quest/global, and all 320 marker rows match the first phase. The
  second production confirmation completes on the same destination with
  `timeAdvanced=0`, usable controls, and cleared travel state. The canonical
  marker denominator remains retail-parity (`authored=320`, `visible=1`,
  `travelEnabled=1`); the other authored markers correctly remain hidden.
- D01 is now active. Its next bite must exercise the real Save330 WEAP, APP,
  AID, MISC, and AMMO Pip-Boy tabs with production rows, icons, counts, stats,
  condition, and selection markers, then validate the complete supported-row
  denominator without showcase-only inventory replacement.

## D01 production inventory implementation checkpoint (2026-08-02)

- The production physical ITEMS path now selects WEAP, APP, AID, MISC, and
  AMMO through `InventoryWindow::setFalloutPipBoyCategory`; AMMO is a distinct
  `SortFilterItemModel` category and ordinary MISC records remain MISC.
- The physical terminal body and retained logs read the existing
  `InventoryItemModel -> TradeItemModel -> SortFilterItemModel` chain. Each
  visible row records FormID, count, family, name, inventory icon, equipped
  state, condition/current/max, value, weight, selected state, and the
  Save330-to-production-model provenance. No inventory mutation is scheduled.
- The D01 public route is `save330-pipboy-inventory-v1`. The `/m:1` OpenMW
  build passed and is staged at
  `local/openmw-real-save330-d01-inventory-20260802-190000/openmw.exe`,
  81,306,624 bytes, SHA-256
  `3A1A3B16C4E59B5C104ABD76217D926E54944BE264A7675EEF25D73B3E34544D`, with
  resources/plugins present and zero PDB files.
- The first D01 capture at
  `run/fnv-real-save-campaign/d01-openmw-20260802-190500` is retained as an
  invalid visual attempt because an engine pane-reset loop put MAP on every
  named frame; it is not promoted. The corrected no-reset runtime is staged at
  `local/openmw-real-save330-d01-inventory-20260802-191500/openmw.exe`,
  81,306,624 bytes, SHA-256
  `840D4EC916FCDE22C9FDC7EEE33223EB300B0F9324F252634B6B476C6080A292`, with
  resources and `osgPlugins-3.6.5` present and zero PDB files.

## D01 completion and D02 handoff (2026-08-02)

- D01 passes with the fresh public, non-overwriting OpenMW capture at
  `run/fnv-real-save-campaign/d01-openmw-20260802-191800`. The mandatory
  background-capture preflight passed 55/55. The five retained native frames
  show the real ITEMS categories WEAP, APP, AID, MISC, and AMMO; their source
  hashes are distinct, and the exact-title raw video is
  `openmw/OpenMW-Save330-D01-inventory-exact-title-raw.mp4`, 4,670,800 bytes,
  SHA-256
  `BDE98707460BED9F77A5F7DB60F37CB1867D830CC10389A8033FD225EDA0EF30`.
- The strict validator `scripts/Test-FNVRealSaveD01.ps1` passes 39/39 and
  writes
  `run/fnv-real-save-campaign/d01-inventory-validation-final.json`, 225,101
  bytes, SHA-256
  `3A6E3DC2381AD42AADC7B520ABF4AFE5D89359D0D17696083EB86C9CC61A009B`.
  The failed first validator artifact remains separately retained and is not
  used as evidence.
- Production category rows are WEAP 10, APP 15, AID 10, MISC 14, and AMMO 4.
  All 48 supported Save330 FormIDs and their final counts reconcile through
  `InventoryItemModel -> TradeItemModel -> SortFilterItemModel` (786 supported
  items); the two implicit worn Pip-Boy rows plus runtime telemetry account for
  the full 55-stack/53-visible/788-item total. Every row has a real icon,
  name, count, condition/stat fields, selection state, and exact
  `Save330-FOS-to-InventoryItemModel-to-TradeItemModel-to-SortFilterItemModel`
  provenance. Runtime telemetry retains worn slots 1/5/11 and actor-value
  modifier `24:10:0:0`.
- D02 is now active. It must select every supported Save330 weapon through the
  normal Pip-Boy production path, close the Pip-Boy, and verify exact weapon
  FormID, compatible ammo, magazine/reserve state, model, and HUD state before
  proceeding to D03.

## D02 visual hand-gate correction checkpoint (2026-08-03)

- The repeated C04 retail-manipulation frames were retained as a failed visual
  diagnostic, not promoted as evidence: the native Pip-Boy screen settled with
  the arm at the outside edge and no visible hand contacting a button or knob.
  The latest diagnostic raw video is
  `run/fnv-real-save-campaign/c04-openmw-20260803-031000-retail-manipulate-potbeat/openmw/OpenMW-Save330-C04-map-selection-exact-title-raw.mp4`;
  its 12.0--14.0 second contact sequence is the same no-support-hand result.
- `esm4npcanimation.cpp` now applies the existing production two-bone player
  skeleton IK after the retail `pipboymanipulate.kf` updates the authored right
  arm. It targets the live physical button/knob node and refreshes the real
  right-hand rig geometry; no second mesh or screen overlay was added. This is
  a correction under test, not yet a visual pass.
- The `/m:1` `openmw` build and the focused Save330 exporter test pass. The
  candidate runtime is
  `local/openmw-real-save330-pipboy-hybrid-contact-20260803-042000/openmw.exe`,
  81,325,568 bytes, SHA-256
  `93ED7560497854F0A1FB1ACE14B795A97E11E5189AE755BA7CCC5C34E5D2C505`, with
  resources/plugins present and no PDB files. Next bite: run the mandatory
  idle/runtime preflight, capture one new non-overwriting contact-focused C04
  route, and inspect native frames plus the new contact-IK telemetry before
  returning to the D02 weapon matrix. D02 remains IN PROGRESS.

## D02 visual hand-gate runner correction (2026-08-03)

- The first preflight with no runtime override failed because the repo-local
  `local/openmw-vats-live` default is absent; the correctly parameterized
  OpenMW RealSave preflight then passed 55/55 against the hybrid runtime.
- The first hybrid public run is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-044000-hybrid-contact` as a
  failed runner attempt. It reached the natural C04 route and retained native
  frames/video, but the denominator had been accidentally replaced by the v1
  raw exporter test output, so the runner failed parsing the expected v2
  transform (`property 'value' cannot be found`). No visual conclusion is
  drawn from that run.
- The canonical v2 denominator was regenerated with the existing
  `fnv-save330-denominator.exe` and the pinned official profile
  `run/fnv-real-save-campaign/save330-official-profile-20260802/openmw.cfg`,
  restored to `save330-player-denominator.json`, and `Test-FNVRealSaveA03.ps1`
  passes again. Its pinned SHA-256 is
  `AE9B020591C5CC176E4A1A47BD9715CBF758E7BB3118A0376CFE4D2A05E92B92`.
- Next bite remains one fresh public hybrid C04 capture with the restored v2
  denominator, followed by native-frame inspection and contact-IK telemetry.
  D02 remains IN PROGRESS.

## D02 bind-space diagnostic attempt (2026-08-03)

- A fresh `/m:1` OpenMW build completed and was staged without overwriting an
  earlier runtime at
  `local/openmw-real-save330-pipboy-hand-pose-audit-20260802-213835/openmw.exe`,
  81,325,568 bytes, SHA-256
  `493BF52E66111617CFEDA364E30B359300C6CEAA42F43EDBF3F8AFB51E4D9D71`,
  with resources and plugins present. The public capture runner now records
  the explicit hand-skinning diagnostic mode and audit flag in both state and
  capture manifests.
- Mandatory `Test-FNVJamBackgroundCapture.ps1 -RuntimeReady -RequireIdle`
  preflight passed 55/55 before the new public C04 run at
  `run/fnv-real-save-campaign/c04-openmw-20260802-214000-hand-pose-audit`.
  The run is retained as a failed evidence attempt: ordinary Save330 load,
  marker selection, confirmation, and no-host-control telemetry all pass, but
  only two queued screenshot files were saved before the scheduled clean exit,
  so the required three native frames were not retained. The raw video and
  logs are retained; no visual result is promoted.
- The first audit emission occurred during first-person assembly, before the
  retail manipulation plus player-skeleton contact solve. It therefore does
  not answer the current bind-space question. Its candidate bounds are
  retained in `openmw/openmw.stdout.log`, along with a real contact solve
  (`error=0.024898`, `handGeometry=1`, `refreshed=1`), but it is not a basis
  for choosing a production skinning mode.
- Next bite: arm the audit only from the post-KF Pip-Boy contact solve, make
  the C04 drain wait for all native screenshots to be written, then run one
  fresh non-overwriting OpenMW capture and inspect its retained native frames
  and post-contact candidate bounds. Retail xNVSE remains the mandatory 1:1
  reference capture after the OpenMW production frame is genuinely correct.
  D02 remains IN PROGRESS.

## D02 post-contact capture and retail-reference checkpoint (2026-08-03)

- The proof schedule now serializes C04 ScreenCaptureHandler writes: each
  source PNG must exist and remain stable for two engine frames before the
  next production MAP transition is allowed. This prevents asynchronous
  filename collisions from being mistaken for three retained frames. The
  hand-pose audit is armed only by the first-person right-hand refresh after
  the retail manipulation plus player-skeleton contact solve.
- The fresh, non-overwriting OpenMW capture
  `run/fnv-real-save-campaign/c04-openmw-20260802-214700-postcontact-audit`
  passes its public runner with the immutable fixture, canonical v2
  denominator, no host-control policy, exact-title video, and three distinct
  native source frames. Runtime SHA-256 is
  `462617BEDE21B62A78C0F881D9D5278E555B7DEE27EBE6FF746F1C31AE869064`.
  Source-frame SHA-256 values are `636C852CF0AD263E2C08E7E1FD0C3A8CB59C8051F46BB26B5382837B21FC4D5A`,
  `A5DE0CAFD7DA1BCF5694DAFFBB540FF27C48844C6DE3C082DBD55B51D6AFD73B`,
  and `3E8B6F74FD852E8F2EF2999A183894182D982E45550F8C7840D190A72DC0C88A`.
- This capture is **not** a D02 visual pass. Human inspection of the native
  focused-map frame and an extracted existing-video contact sheet confirms the
  same visible defect: the oversized Pip-Boy is centered, the cuff/arm seam is
  exposed at the right edge, and no reaching hand is visible on a control.
  The audit is retained in `openmw/openmw.stdout.log` after the contact solve;
  it reports compact `invBindThenSkeleton` bounds and huge bounds for the
  alternate formulas, but a map-rest frame cannot be promoted as an
  interaction-hand proof.
- A sequential retail xNVSE Save330 reference was started only after OpenMW
  had exited, through the public capture wrapper, at
  `run/fnv-real-save-campaign/retail-save330-pipboy-reference-20260802-215000`.
  It retained 1,536 xNVSE events and 156 native D3D9 frames with no host input,
  but is retained as failed evidence because the retail close/lower lifecycle
  remained mode 3 at the end (`verifiedAfterLowerSnapshots=0`). Do not use it
  as the passing 1:1 retail pair. Its valid raise/held frames are diagnostic
  only and show the retail device/hand framing is materially different from
  the current OpenMW centered presentation.
- Next bite: derive the production first-person Pip-Boy presentation transform
  and hand-part attachment from the retained retail xNVSE node/frame evidence,
  add a strict contact-phase native frame (not a post-contact MAP rest frame),
  then correct the arm/cuff/hand rendering before retrying the retail oracle
  lifecycle and returning to the D02 weapon-selection matrix. D02 remains IN
  PROGRESS.

## D02 hand-bind/contact visual gate (2026-08-03)

- The fresh serial build was staged without overwriting prior runtimes at
  `local/openmw-real-save330-pipboy-hand-bind-contact-20260803-223000/openmw.exe`,
  SHA-256 `336A7FE993533D2F6C89BECF2F42A581E62476545236C1DB63C603022867E7D9`.
  It retains the live hand bind-frame diagnostic path, the post-solve pose
  audit, and a four-frame C04 schedule including a dedicated
  `map-world-toggle-contact` frame.
- The required OpenMW RealSave preflight passed 54/54 before the fresh public,
  non-overwriting capture at
  `run/fnv-real-save-campaign/c04-openmw-20260803-223100-hand-bind-contact`.
  The public runner retained its exact-title MP4, four named native source
  frames, ordinary Save330 load provenance, and no-host-control telemetry.
- This is deliberately retained as a **failed visual and semantic gate**, not
  promoted evidence. `Test-FNVRealSaveC04.ps1` fails because source frames 1
  and 2 have the same SHA-256 and the live contact solve remained the earlier
  MAP button pose (`variant=2`) instead of emitting the required ScrollKnob
  pose (`variant=4`). More importantly, direct inspection of
  `openmw/Save330-C04-map-world-toggle-contact.png` shows the Pip-Boy still
  centered and oversized, the display occluding its controls, the visible
  right cuff/skin seam, and no second hand at the knob.
- No C04/D02 visual success, retail pair, or playable handoff is claimed from
  this run. Next bite: trace the first-person hand RigGeometry skeleton/bind
  ownership and replay lifecycle, derive the held Pip-Boy camera-space
  placement from retained xNVSE reference telemetry, then require distinct
  native contact/overview/focus/confirmation frames before any further video
  or D02 weapon-matrix attempt. D02 remains IN PROGRESS.

## D02 retail timing and control-order correction (2026-08-03)

- Source inspection isolated two production defects in the failed contact run:
  `RenderingManager` advanced `setPipBoyInteractionProgress` before it applied
  the MAP/WORLD control state, so the midpoint manipulation logged the stale
  MAP button (`variant=2`) instead of the ScrollKnob (`variant=4`); and the
  held presentation drove `pipboy.kf` to its final return sample even though
  the retained xNVSE reference freezes the retail held pose at 0.36 seconds.
- The production order now resolves `setPipBoyControlState` before advancing
  the interaction pulse. Each nonzero production pulse also starts a fresh
  manipulate clip rather than inheriting a prior UI beat. The raise/held/lower
  path now clamps to the observed 0.36-second retail held sample, so its
  controls are not rotated behind the display by the KF tail.
- `cmake --build MSVC2022_64 --config RelWithDebInfo --target openmw -- /m:1`
  passed after this cohesive correction. No game was launched during the
  diagnosis or build. Next bite: stage this distinct binary, run one required
  preflight and one fresh C04 native contact capture, then require live
  `variant=4`, distinct source frames, visible controls, and the actual right
  hand at the knob before proceeding. D02 remains IN PROGRESS.

## D02 unattended capture runner repair (2026-08-03)

- The first capture of the retail-timing/knob candidate is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-052300-retail-timing-knob`
  as a failed, non-evidence attempt. It preserved its exact-title MP4 and
  logs but timed out with zero of four required native source frames; no C04
  or visual conclusion is drawn from it.
- The retained trace identifies the runner defect precisely: every frame
  reached `sound.begin` and then returned before `sound.end`/world update
  because its unattended capture window was hidden while
  `OPENMW_PLAYABLE_SESSION_BACKGROUND` was absent. The public real-save
  runner now scopes and sets that existing background-simulation flag for the
  launched OpenMW process. It neither injects host input nor changes the
  ordinary Save330 load or production Pip-Boy route.
- Next bite: perform the required idle/runtime preflight and one fresh,
  non-overwriting C04 capture of the same staged binary. It must first retain
  all four native frames and emit the ScrollKnob contact before the visible
  cuff/hand/device gate is evaluated. D02 remains IN PROGRESS.

## D02 visible unattended-window repair (2026-08-03)

- The first background-enabled retry is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-053100-hidden-window-repair`
  as failed, non-evidence diagnostics. Its engine did complete the ordinary
  Save330 C04 route and logged all four native capture requests, proving the
  background simulation fix worked, but the engine intentionally created a
  hidden SDL window and the strict exact-title recorder could not obtain a
  native window handle. No source PNGs or video transport were retained by the
  public runner.
- The engine now distinguishes a hidden background session from an unattended
  exact-title capture: `OPENMW_PROOF_CAPTURE_KEEP_WINDOW_VISIBLE` preserves a
  normal titled SDL surface while `OPENMW_PLAYABLE_SESSION_BACKGROUND` keeps
  simulation running without foreground control. The real-save runner scopes
  both flags only to its launched process; it does not inject input, move
  focus, or alter the production Pip-Boy route.
- A serial `/m:1` OpenMW build passed and is staged at
  `local/openmw-real-save330-pipboy-retail-timing-knob-visible-window-20260803-053700/openmw.exe`,
  81,345,024 bytes, SHA-256
  `D5964C4DD77C9A5B2E49534AB76225814F06C6C792314DDA9BA94F48D91C1D85`,
  with resources/plugins present and no PDB files. No game launch occurred
  after this build. Next bite is the required preflight followed by one fresh
  C04 native capture of this runtime. D02 remains IN PROGRESS.

## D02 ScrollKnob and physical-frame sequencing correction (2026-08-03)

- The fresh public capture at
  `run/fnv-real-save-campaign/c04-openmw-20260803-054200-visible-window` passed
  its runner contract: ordinary immutable Save330 load, no host-control
  policy, four retained native source files, telemetry, hashes, and exact-title
  MP4. Its strict C04 validator is nevertheless retained as a failure (37/39):
  source frames 1 and 2 had the same SHA-256, and the only midpoint hand solve
  remained `variant=2` / `Button3` even though the later production route
  logged ScrollKnob. Native-frame inspection also shows that this was captured
  before the physical map glass had settled: it is not a visible map-icon,
  cuff-seam, or operating-hand pass.
- Source tracing found two concrete route defects. A MAP/WORLD operation begun
  before the preceding tab pulse returned to zero reused its old manipulate
  clip, so the right arm never restarted on the ScrollKnob. The C04 schedule
  also used absolute elapsed thresholds; an asynchronous screenshot write made
  later focus/confirmation mutations and their next-frame captures collapse
  together. The live interaction now rearms whenever its target physical
  control changes, and each retained C04 frame starts a new settle interval.
  The route waits for the normal raise/waver pose before issuing MAP/WORLD,
  then waits again after focus and confirmation surface updates.
- A serial `/m:1` build passed. The fresh runtime is staged without overwriting
  any predecessor at
  `local/openmw-real-save330-pipboy-scrollknob-settle-20260803-054700/openmw.exe`,
  81,346,560 bytes, SHA-256
  `95919EBDF71DFE0724E77E58437072143538891D48ABB6468D25C59B2D4247DC`,
  with resources/plugins present and no PDB files. No game was launched after
  this build. Next bite: required preflight, one new C04 capture, strict
  validator, then direct inspection of its native contact and map-icon frames.
  D02 remains IN PROGRESS.

## D02 definitive MAP/WORLD knob-action correction (2026-08-03)

- The non-overwriting retry at
  `run/fnv-real-save-campaign/c04-openmw-20260803-055000-scrollknob-settle`
  is retained as failed diagnostic evidence, not a visual pass. It reached
  the ordinary Save330 MAP route but retained zero required native source
  frames because its required action pulse never began.
- The precise cause is now recorded in the production state path: Save330
  enters the MAP pane with `mFalloutPipBoyWorldMap` already true. The prior
  route therefore treated the requested WORLD transition as complete and
  skipped `A_Activate`, leaving the prior Button3 pulse as the only contact.
  C04 now deliberately performs WORLD -> LOCAL after the normal raise,
  waits for that pulse to finish, then performs LOCAL -> WORLD as a fresh
  production activation. That final operation is the real ScrollKnob contact
  required by the strict validator; it is not an injected or synthetic pose.
- A serial `/m:1` build passed and is staged without replacing a predecessor
  at
  `local/openmw-real-save330-pipboy-scrollknob-toggle-20260803-055700/openmw.exe`,
  81,346,560 bytes, SHA-256
  `25F52C3680AD3684F3C6D63F575E5BA4C3807478572567C358C5A49252B1A4B7`,
  with resources/plugins present and no PDB files. No game launch has occurred
  after this build. Next bite: mandated idle/runtime preflight, one fresh C04
  capture, strict validation, and direct native-frame inspection. D02 remains
  IN PROGRESS.

- Required preflight completed immediately before that fresh capture:
  `Test-FNVJamBackgroundCapture.ps1 -Target OpenMW -Scenario RealSave` with
  the immutable Save330 fixture and the staged runtime passed 53/53 checks
  with `-RuntimeReady -RequireIdle`. No game was launched during preflight.

- The fresh, non-overwriting public C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-060000-scrollknob-toggle`.
  Its runner contract passed with the immutable Save330 fixture, four retained
  native source frames, telemetry, hashes, and an exact-title MP4; its scoped
  policy report records no foreground activation, Windows-app control, or
  injected input. This is transport evidence only until the strict C04
  validator and direct frame inspection pass. D02 remains IN PROGRESS.

- The strict validator retained `c04-validation.json` for that capture and
  failed exactly one gate: contact and overview native source PNGs are
  byte-identical (`d377682a...c36401a`). The production log now does contain
  a fresh `variant=4` / `ScrollKnob` right-hand contact with
  `solved=1 handGeometry=1 refreshed=1`, the restored one-icon overlay,
  marker focus, and the exact Southern Passage confirmation. Those telemetry
  signals do not waive the duplicate-frame or direct visual gates. Next bite:
  inspect all four native frames, then correct the capture-state separation
  and any remaining visible device/hand/seam mismatch. D02 remains IN
  PROGRESS.

- Direct inspection of all four native PNGs confirms the strict failure is
  meaningful: the physical terminal remains stranded across the bottom of the
  frame, the map/icon surface is mostly below the viewport, and no visible
  right hand reaches the ScrollKnob. The current telemetry must therefore not
  be described as an operating-hand or seam pass. xNVSE reference inspection
  then exposed a concrete source mismatch: retail
  `1stPPipboyWaver.kf` controls `Bip01 L Clavicle`, `Bip01 L UpperArm`, and
  `Bip01 L Forearm` (plus their left-arm support tracks), whereas the OpenMW
  held path was incorrectly masking that sequence to `BlendMask_RightArm`
  while freezing `pipboy.kf`. Next bite: restore the retail left-arm waver
  baseline, rebuild serially, and inspect a fresh native capture before
  touching the seam or validator criteria. D02 remains IN PROGRESS.

- The held presentation source now follows that exact retail ownership: on
  reaching the raised state it stops `pipboy.kf` and plays
  `1stPPipboyWaver.kf` on `BlendMask_LeftArm`; it no longer freezes a raise
  sample while applying the left-arm animation to the right arm. The right
  arm remains available for the separately authored `pipboymanipulate.kf`
  contact overlay. This is a production animation-path correction, not a
  replacement hand mesh or a capture-only transform. Next bite: serial build,
  staged runtime, then the mandated preflight and fresh C04 capture. D02
  remains IN PROGRESS.

- The serial `/m:1` OpenMW build passed. A new no-overwrite runtime is staged
  at
  `local/openmw-real-save330-pipboy-left-waver-20260803-061400/openmw.exe`,
  81,346,560 bytes, SHA-256
  `25BB11C58729AA8BB480E371EE41A66D35E3EDF64BB9D3212FA6F8E2D2688727`,
  with resources/plugins present and zero PDB files. No game has been launched
  after this build. Next bite: the required idle/runtime preflight and one
  fresh C04 capture of this exact binary. D02 remains IN PROGRESS.

- The required OpenMW/RealSave preflight against that staged binary and the
  immutable fixture passed 53/53 checks with `-RuntimeReady -RequireIdle`.
  No game is launched by the preflight. Next bite: one fresh, non-overwriting
  C04 capture through the public background-capture entry point. D02 remains
  IN PROGRESS.

- The fresh public C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-061600-left-waver` with the
  new binary. Its transport contract passed: ordinary immutable Save330 load,
  four retained native source frames with four different SHA-256 values,
  telemetry/hashes, and exact-title MP4; the policy report records no host
  input, foreground activation, or overwrite. This still awaits strict C04
  validation and direct visual inspection. D02 remains IN PROGRESS.

- `Test-FNVRealSaveC04.ps1` passed all 39/39 strict checks for that capture,
  including four distinct native source frames, the real production
  `variant=4` ScrollKnob contact, restored one-marker overlay, focus, and
  Southern Passage confirmation. The validator result is retained at
  `c04-validation.json`. It is not yet a cuff/seam or visible-hand conclusion:
  direct inspection of the native frames is the next required D02 gate. D02
  remains IN PROGRESS.

- Direct native-frame inspection after the left-arm correction is materially
  better but still not a visual pass: the physical device is raised into the
  viewport, its MAP surface shows the restored Southern Passage icon, and the
  controls are visible. The visible right hand nevertheless remains at the
  lower-right edge rather than visibly operating the ScrollKnob, and the
  wrist/cuff discontinuity is still apparent. Therefore 39/39 C04 validates
  the production route and capture integrity, not the requested hand/seam
  appearance. Next bite: one scoped, public-entry-point C04 capture with the
  existing right-hand skin-palette audit enabled, then use that evidence to
  correct the live hand geometry or target path. D02 remains IN PROGRESS.

- The mandatory preflight for that scoped audit passed 53/53 checks with the
  same immutable fixture and left-waver runtime, using `-RuntimeReady` and
  `-RequireIdle`. No game launch occurred during preflight. D02 remains IN
  PROGRESS.

- The scoped, public-entry-point hand-palette audit completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-062000-hand-skin-audit`.
  Its capture contract passed with the ordinary immutable Save330 MAP/WORLD
  route, four native frames, telemetry, hashes, and no host input, foreground
  activation, or overwrite. The audit establishes that the live right-hand
  rig's selected `invBindThenSkeleton` palette is compact and valid; every
  alternate palette expands the mesh by roughly one to several hundred units.
  This rules out a skinning-mode swap as a seam fix. The remaining visible
  failure is contact-pose/occlusion under the supplemental right-hand IK, not
  a stale or invalid palette. Next bite: inspect the authored
  `pipboymanipulate.kf` knob beat on the corrected left-arm waver baseline
  before retaining or adjusting supplemental IK. D02 remains IN PROGRESS.

- xNVSE held-frame comparison then isolated a further source mismatch: retail
  keeps `1stPPipboyWaver.kf` at its observed `0.196`-second sample while the
  OpenMW held path left the sequence advancing. The production path now pins
  that exact sample when the physical Pip-Boy enters the retail held state;
  it does not freeze or reintroduce `pipboy.kf`. The strict C04 validator now
  requires the retained `heldSample=0.196` telemetry in addition to the real
  ScrollKnob path. The serial `/m:1` OpenMW build passed and a fresh,
  no-overwrite runtime is staged at
  `local/openmw-real-save330-pipboy-waver-held-20260803-063000/openmw.exe`
  (81,346,560 bytes, SHA-256
  `C6FAF6E5849E54361A5296E76C5D235D35749C33CF7D77CB0E63D5CCFFE3017B`;
  resources/plugins present; zero PDB files). No game launch occurred during
  this bite. Next bite: mandatory preflight, then one fresh native C04
  capture and direct inspection of the settled held/contact frames. D02
  remains IN PROGRESS.

- The mandated preflight for that exact staged runtime passed 53/53 checks
  with `-RuntimeReady -RequireIdle` against the immutable Save330 fixture.
  It launched neither game. Next bite: one fresh C04 capture solely through
  `Invoke-FNVJamBackgroundCapture.ps1`, followed by strict validation and
  native-frame inspection. D02 remains IN PROGRESS.

- The fresh public capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-063100-waver-held` using
  only the staged `C6FA...017B` runtime and immutable Save330 fixture. Its
  runner contract passed: ordinary save load, four retained native source
  frames with distinct hashes, telemetry, an exact-title MP4, and policy
  reports with no host input, foreground activation, concurrent retail run,
  or overwrite. This is transport evidence only pending the strengthened
  strict validator and direct native-frame inspection. D02 remains IN
  PROGRESS.

- The first strengthened strict-validator invocation retained
  `c04-validation.json` as a non-evidence failure solely because its new
  regular expression escaped a literal backslash before `0.196`; the runtime
  log itself contains the required exact line with `heldSample=0.196`.
  Corrected the validator expression to match the literal decimal point; no
  engine behavior or proof artifact was altered. Next bite: parse the changed
  validator, rerun it on the same immutable capture, then inspect the native
  frames regardless of outcome. D02 remains IN PROGRESS.

- The corrected validator parses and passes all 40/40 checks for the waver
  capture; it confirms the exact xNVSE `heldSample=0.196`, four distinct
  native frames, restored marker, production ScrollKnob route, and exact
  confirmation. Direct frame inspection nevertheless remains a visual failure:
  the device is stable, but the contact frame occludes the right hand and the
  normal frames still expose the cuff/skin discontinuity. No visual success is
  claimed. Source tracing places the solved wrist on the physical-control
  plane, which is behind the display depth surface from the camera. Next bite:
  preserve the real fingertip/control target while adding a small live
  camera-facing wrist approach offset, then rebuild and inspect a new proof.
  D02 remains IN PROGRESS.

- The camera-facing approach correction is now in the production
  right-hand-skeleton solve: the fingertip remains at the selected authored
  physical control while the wrist is offset four units toward the live
  `Bip01 Looking` camera side. It adds no mesh, overlay, or capture-only
  geometry. The serial `/m:1` build passed and a distinct runtime is staged
  at
  `local/openmw-real-save330-pipboy-contact-clearance-20260803-063300/openmw.exe`
  (81,346,560 bytes, SHA-256
  `94C1C11A8CB1716440369DC632E7A6CF5019A9D09A387D990FF7B02271CA170A`;
  resources/plugins present; zero PDB files). No game launch occurred in this
  bite. Next bite: mandated preflight, fresh public C04 capture, strict
  validation, and direct contact-frame inspection. D02 remains IN PROGRESS.

- The required preflight for the contact-clearance binary passed 53/53 with
  `-RuntimeReady -RequireIdle` against the immutable fixture. Neither game was
  launched by that check. Next bite: one fresh non-overwriting public C04
  capture of this exact binary. D02 remains IN PROGRESS.

- The fresh public contact-clearance capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-063400-contact-clearance`
  against the staged `94C1...170A` runtime. Its runner contract passed with
  four retained, distinct native frames, telemetry/video hashes, and no host
  input, foreground activation, concurrent retail run, or proof-directory
  overwrite. Direct inspection is a visual failure: the live ScrollKnob
  variant-4 solve is present in telemetry, but the contact frame still has no
  visible hand at the knob; the normal frames still show the bare right hand
  low at frame right and the cuff/skin discontinuity. The four-unit
  camera-facing wrist clearance changed the solved wrist coordinates but not
  the image, so it is not promoted as a repair. Next bite: validate this
  retained proof, then instrument the post-skin real-hand geometry bounds and
  visibility to determine whether it is occluded or failing to follow the
  solved skeleton. D02 remains IN PROGRESS.

- The strengthened strict C04 validator passes 40/40 checks for the retained
  contact-clearance capture at
  `c04-openmw-20260803-063400-contact-clearance/c04-validation-final.json`.
  It verifies the exact pinned retail held sample, real map-marker restoration,
  production ScrollKnob route, live right-hand solve telemetry, native-frame
  hashes, and confirmation. That is pipeline evidence only: it does not
  override the failed direct visual inspection of the absent contact hand and
  exposed seam. Next bite: add a post-skin real-hand geometry bounds/visibility
  diagnostic to the existing production telemetry, serial-build it, and inspect
  one fresh native capture. D02 remains IN PROGRESS.

- Added a no-behavior-change contact diagnostic beside the live production
  solve. After forcing the real right-hand `RigGeometry` to refresh, it records
  the post-skin rendered mesh bounds, the solved wrist and authored fingertip
  transformed into that same hand-root coordinate frame, their distances from
  the rendered mesh center, and the current visibility audit. This is intended
  to prove whether the absent knob hand is occluded/masked or whether the
  skinned vertices are not following the solved bones; it creates no duplicate
  mesh, overlay, or capture-only pose. The serial `/m:1` `openmw` build passed
  (the existing PCH warning only). A failed first staging attempt at
  `local/openmw-real-save330-pipboy-hand-mesh-probe-20260803-000000` flattened
  the plug-in files after PowerShell rejected `New-Item -LiteralPath`; it is
  retained but incomplete and will never be launched. A separate complete,
  no-overwrite runtime is staged at
  `local/openmw-real-save330-pipboy-hand-mesh-probe-20260803-000100/openmw.exe`
  (81,346,560 bytes, SHA-256
  `EC3DBCD96F7EF88D4603DB6B7D20E45EFF9A6BBB9AC2650CB9ABE359A50B9E4B`;
  resources/plugins present; zero PDB files). No game was launched during this
  bite. Next bite: mandatory idle/runtime preflight, one fresh capture, and
  direct comparison of the mesh/bone diagnostic with the native contact frame.
  D02 remains IN PROGRESS.

- The required background-capture preflight for the complete hand-mesh-probe
  runtime passed all 53 checks with `-RuntimeReady -RequireIdle` against the
  immutable Save330 fixture. It launched neither game. Next bite: one fresh,
  non-overwriting public C04 capture through the sole approved capture entry
  point, followed by the strict validator and retained-frame/log inspection.
  D02 remains IN PROGRESS.

- The fresh public hand-mesh-probe capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-000200-hand-mesh-probe`
  against the staged `EC3D...B9E4` runtime. Its runner contract passed using
  only the engine-owned Save330 MAP/WORLD production route: four distinct
  native frames, telemetry, exact-title MP4, and artifact hashes are retained;
  the policy records no Windows app control, foreground activation/input,
  concurrent retail capture, or overwrite. `-RealSaveHandPoseAudit` was passed
  only to the launched OpenMW process to retain the existing skin-basis audit;
  it injects no input and does not alter the route. This is diagnostic transport
  evidence pending strict validation and comparison of the new post-skin bounds
  with the direct native frames. D02 remains IN PROGRESS.

- The strict C04 validator passes 40/40 checks for the retained hand-mesh-probe
  capture at
  `c04-openmw-20260803-000200-hand-mesh-probe/c04-validation-final.json`.
  Direct native-frame inspection remains a visual failure: the physical display
  is still low/oversized and occludes the control area; the normal overview and
  focused frames retain the right cuff/skin seam, while the live contact frame
  has no exposed hand at the ScrollKnob.

  The new telemetry rules out the prior hypotheses. At the actual variant-4
  contact the real skinned `RightHand:0` bounds are valid, unmasked, and centered
  at `(4.73563,6.28443,120.547)` in the hand-root frame; the solved wrist and
  authored fingertip are `(8.00711,3.40912,117.463)` and
  `(1.74504,10.5516,117.385)`, only `5.34` and `6.09` units from that live mesh.
  Thus the mesh is following the production skeleton rather than being absent,
  unskinned, or masked—it is being hidden by the Pip-Boy/device depth and
  presentation placement. The failed image is not promoted. Next bite: trace
  the physical Pip-Boy screen/device render-state and camera-space placement,
  then make a source correction that preserves the real mesh and production
  controls before another capture. D02 remains IN PROGRESS.

- xNVSE Save330 snapshots establish a discrete real model-FOV transition:
  frames 840/900 are 55 degrees before the Pip-Boy, while frame 930 and every
  held frame through 1140 are 47 degrees (`mode=2/3`; physical render begins
  at frame 940). OpenMW had retained the save's 55-degree first-person model
  FOV throughout, explaining part of the low, non-retail device composition.
  The existing first-person projection callback now updates in place from 55
  to the exact retail 47 on physical Pip-Boy entry and restores 55 on close;
  it preserves the world FOV, render bin, callback chain, real device, and real
  hand mesh. The serial `/m:1` `openmw` build passed (existing PCH warning
  only), and a complete no-overwrite runtime is staged at
  `local/openmw-real-save330-pipboy-retail-fov-20260803-000500/openmw.exe`
  (81,350,656 bytes, SHA-256
  `473881D5A7B80A2D5F189A8E26CCB07B7B82B669D1533E20FEF35190F621B144`;
  resources/plugins present; zero PDB files). No game launch occurred during
  this bite. Next bite: add the logged retail-FOV transition to strict C04
  validation, run preflight, and take one fresh native capture. D02 remains IN
  PROGRESS.

- The strict C04 validator now requires the live
  `FNV Pip-Boy first-person FOV: source=xNVSE-save330-retail requested=47
  baseline=55 presentationActive=1 applied=1` telemetry in addition to its
  prior 40 checks. The updated PowerShell validator parses and its diff check
  is clean. Next bite: mandatory `-RuntimeReady -RequireIdle` preflight for
  the FOV runtime, then one fresh non-overwriting native capture. D02 remains
  IN PROGRESS.

- The mandated preflight for the retail-FOV runtime passed all 53 checks with
  `-RuntimeReady -RequireIdle` against the immutable Save330 fixture. It
  launched neither game. Next bite: one fresh public C04 capture only through
  `Invoke-FNVJamBackgroundCapture.ps1`, then strict validation and direct
  native-frame comparison with the retail frame-980 oracle. D02 remains IN
  PROGRESS.

- The fresh public retail-FOV capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-000700-retail-fov` against
  staged runtime `4738...B144`. The runner contract passed: four distinct
  retained native frames, telemetry, exact-title MP4, hashes, and policy
  reports; no Windows app control, foreground activation/input, concurrent
  retail run, or overwrite occurred. This is transport evidence pending the
  strengthened 41-check validator and direct side-by-side native-frame
  inspection. D02 remains IN PROGRESS.

- The strengthened validator intentionally retained
  `c04-validation-final.json` as a non-evidence failure: the new runtime log
  proves the FOV callback executed, but reports `requested=47 baseline=42.6539`
  rather than the validator's incorrect direct-44/55 expectation. Direct frame
  inspection shows the device has moved upward/enlarged but is still low and
  still occludes the contact hand; it is not a visual pass. Source tracing
  establishes the exact cause: xNVSE's `47` and the Save330 `55` are Fallout
  horizontal FOV values at the 4:3 reference aspect, while OpenMW's first-person
  callback consumes vertical FOV. The save path correctly converts `55` to
  `42.6539`; the new Pip-Boy path erroneously supplied `47` directly instead of
  converting it to `36.1233`. Next bite: make the same canonical conversion for
  the held Pip-Boy source FOV, strengthen the validator around reference versus
  vertical values, then rebuild and inspect a new proof. D02 remains IN
  PROGRESS.

- Corrected the Pip-Boy transition to call the existing canonical
  `convertFalloutReferenceFovToOpenMwVertical(47)` conversion: the real source
  value is now logged as `referenceHorizontal=47`, while the first-person
  cull callback receives the correct `requestedVertical=36.1233`; the restored
  Save330 baseline remains `42.6539`. The strict pattern now checks those
  distinct semantics rather than equating reference and render FOVs. The
  validator parses, diff checks are clean, and the serial `/m:1` `openmw` build
  passed (existing PCH warning only). A complete no-overwrite runtime is staged
  at
  `local/openmw-real-save330-pipboy-retail-fov-converted-20260803-001300/openmw.exe`
  (81,350,656 bytes, SHA-256
  `6ADDE78030099D25F6F2C6A511CD0290306A69CB2A9C894DA4C9AC512089611F`;
  resources/plugins present; zero PDB files). No game launched in this bite.
  Next bite: mandatory preflight and a fresh native capture; direct frame
  inspection decides whether this actually repairs placement. D02 remains IN
  PROGRESS.

- The required preflight for the converted-retail-FOV runtime passed all 53
  checks with `-RuntimeReady -RequireIdle` against the immutable fixture. It
  launched neither game. Next bite: one fresh non-overwriting public C04
  capture through the sole approved entry point, followed by 41-check
  validation and native-frame inspection. D02 remains IN PROGRESS.

- The fresh public converted-retail-FOV capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-001400-retail-fov-converted`
  against staged `6ADD...611F`. The runner contract passed with four distinct
  retained native frames, telemetry, exact-title MP4 and hashes, and policy
  reports confirming no host input/focus control, concurrent retail capture,
  or overwrite. It is transport evidence pending the 41-check validator and
  direct native-frame inspection. D02 remains IN PROGRESS.

- The strict converted-retail-FOV validator passed all 41 checks for
  `c04-openmw-20260803-001400-retail-fov-converted`: the source semantics are
  exact (`referenceHorizontal=47`, `requestedVertical=36.1233`, restored
  baseline `42.6539`) and the runner contract, native frames, telemetry,
  hashes, and policy reports all remain valid. Direct inspection is still a
  visual failure, not a promotion: the physical device is enormous and low in
  the viewport, the live ScrollKnob contact hand remains hidden behind it, and
  the overview/focus frames retain the cuff-to-skin seam. The FOV correction
  is retained as a verified projection transition, but it does not repair
  placement or contact. Next bite: log the live Camera1st-relative transforms
  for the retail-comparable left arm, physical screen, and right contact hand,
  then derive a production camera-space attachment correction from the
  frame-980 xNVSE oracle rather than making another blind FOV or clearance
  adjustment. D02 remains IN PROGRESS.

- Added a production-only, contact-edge Camera1st audit to the real
  `pipboymanipulate`/ScrollKnob path. It records the live left forearm,
  foretwist, hand bone and left-hand skin, Pip-Boy presentation root, arm,
  physical `pipboyscreen` origin/center, ScrollKnob, actual selected control,
  right hand/finger, and right-hand skin in the same Camera1st-relative space
  as xNVSE frame 980. The C04 validator now requires all anchors and finite
  screen/knob/hand fields, so a capture cannot silently omit the comparison
  data. The serial `/m:1` `openmw` build passed (existing PCH warning only).
  A first new stage at
  `local/openmw-real-save330-pipboy-camera-space-audit-20260803-001500` was
  rejected before launch because the copy did not contain `osgPlugins-3.6.5`;
  it remains preserved and is not a candidate. A complete, no-overwrite stage
  is now ready at
  `local/openmw-real-save330-pipboy-camera-space-audit-20260803-001510/openmw.exe`
  (81,356,288 bytes, SHA-256
  `E9BB052B3EAC14C440CD5610F0C258EC0C15793709643B4495A25BA1522A1220`;
  resources/plugins present; zero PDB files). No game launched in this bite.
  Next bite: parse-check the strengthened validator, run the required
  `-RuntimeReady -RequireIdle` preflight, then take one fresh native C04
  capture and compare the emitted camera-space vectors against the xNVSE
  frame-980 oracle. D02 remains IN PROGRESS.

- The mandatory preflight for the camera-space-audit runtime passed all 53
  checks with `-RuntimeReady -RequireIdle`. The single approved C04 runner was
  then invoked against a fresh proof directory, but stopped before OpenMW
  launched: its report records `status=fail`, zero retained evidence, and the
  PowerShell error `The property 'Count' cannot be found on this object.` The
  isolated profile was restored; no frame, video, or telemetry from
  `c04-openmw-20260803-001600-camera-space-audit` is admissible. The directory
  is preserved without overwrite. Next bite: isolate and correct that
  pre-launch capture-runner cardinality bug, parse-check it, then repeat the
  mandatory idle preflight and a fresh capture directory. D02 remains IN
  PROGRESS.

- Correction to the preceding runner note: the approved runner did launch
  OpenMW, but the invocation omitted `-RealSaveRouteId
  save330-pipboy-map-selection-v1`, so it executed the default cold-load route
  (`save330-cold-load-settle-v1`) rather than C04. Its generic report then hit
  the unrelated cardinality failure; it retained a generic world PNG/video and
  no C04 MAP, contact, or camera-space audit data. This was an invocation error,
  not an engine or visual result. The run remains preserved and inadmissible.
  Next bite: use the explicit C04 route in both the required preflight and the
  sole public capture entry point, with a new non-overwriting proof directory.
  D02 remains IN PROGRESS.

- The corrected explicit C04 capture passed its public-runner contract at
  `run/fnv-real-save-campaign/c04-openmw-20260803-001700-camera-space-audit`:
  ordinary Save330 load, production MAP/WORLD selection, four distinct native
  frames, telemetry, exact-title video, hashes, and no-control policy all pass.
  It is deliberately not promoted. The strengthened validator passed 41/42
  checks and correctly failed only because the initial audit did not resolve a
  physical `pipboyscreen` node. Its usable vector evidence is decisive: xNVSE
  frame-980 expects left foretwist `(-12.48023,11.35355,-7.26515)` and left
  hand `(5.27945,14.98709,-7.35517)` in Camera1st space; the live OpenMW bones
  are respectively `(-13.2478,11.5464,-7.61372)` and
  `(4.51743,15.1548,-7.32284)`. The sub-unit deltas rule out a broad arm or
  camera correction. Direct native-frame inspection still shows the physical
  device low/oversized and the knob hand occluded. The failed audit also
  established that raw control coordinates are device-local, not world-space.

- The audit now captures the actual `pipboyscreen:*` node through the existing
  physical-control locator, promotes its local origin/bounds and real knob
  coordinates through the wrist presentation transform, and records both
  skinned hand-mesh centers. This changes no pose, screen texture, map state,
  or control behavior. The serial `/m:1` build passed (existing PCH warning
  only); complete no-overwrite runtime
  `local/openmw-real-save330-pipboy-physical-screen-audit-20260803-001800/openmw.exe`
  is staged (81,358,848 bytes, SHA-256
  `47C92661DE2EC39552A63F302F6BE43C6DF898178EFBDC8319D46DD9EC02F9E1`;
  resources/plugins present; zero PDB files). No game launched after this
  audit correction. Next bite: mandatory C04 preflight and one fresh capture
  to obtain physical screen/knob camera-space values, then derive and apply
  the specific production device transform. D02 remains IN PROGRESS.

- The fresh physical-screen audit capture at
  `run/fnv-real-save-campaign/c04-openmw-20260803-001900-physical-screen-audit`
  passed the public contract (ordinary Save330 route, four distinct native
  frames, telemetry, exact-title video, hashes, and no-control policy). The
  original 42-check validator artifact is preserved as an intentional pattern
  failure; the parser-corrected companion
  `c04-validation-pattern-repaired.json` passed all 43 checks. This is proof
  of the route and diagnostic data only, not visual promotion. The current
  screen bounds center is `(-2.19802,13.5159,-3.38012)` in Camera1st space,
  near the xNVSE frame-980 screen pivot `(-1.34543,13.34260,-3.26523)`, while
  the current ScrollKnob target is `(1.75160,14.2858,-0.615331)` versus the
  retail physical ScrollKnob `(-4.96888,13.06616,-3.93592)`. This directly
  explains the absent knob hand: the skeleton/wrist is close to retail, but
  the interaction path is solving to a wrapper-space point instead of the
  rendered knob geometry. Next bite: promote the actual rendered control
  bounds center through the wrist presentation transform for the production
  fingertip target, retain a fallback plus telemetry, and prove it in a fresh
  capture. D02 remains IN PROGRESS.

- Replaced the production contact target's double-promoted wrapper coordinate
  with the exact original `PipBoyPhysicalControl::mBaseMatrix` pivot retained
  from the named retail NIF node. For ScrollKnob this is the verified retail
  local `7.68621683,1.23748183,3.13685203`; the existing wrist presentation,
  real right-hand mesh, manipulate KF, two-bone solve, and physical controls
  remain in place. Contact telemetry now declares
  `controlTarget=authored-nif-base` and its exact local pivot, and C04 requires
  that provenance. One serial compile caught an audit ternary Vec3d/Vec3f
  ambiguity; it was corrected explicitly and the subsequent `/m:1` build
  passed (existing PCH warning only). Complete no-overwrite stage
  `local/openmw-real-save330-pipboy-authored-control-contact-20260803-002000/openmw.exe`
  is ready (81,358,848 bytes, SHA-256
  `732DE60FCB8E9B15A0BCB26DF6845AD630EFAB2D4B07B24BF707BB45E1E1D85E`;
  resources/plugins present; zero PDB files). No game launched in this bite.
  Next bite: mandatory C04 preflight, fresh native capture, strict validation,
  and direct review of the real ScrollKnob hand/cuff frame. D02 remains IN
  PROGRESS.

- The mandatory preflight for the authored-control runtime passed 54/54 checks
  with `-RuntimeReady -RequireIdle`; the fresh, non-overwriting public C04
  capture at
  `run/fnv-real-save-campaign/c04-openmw-20260803-002100-authored-control-contact`
  then passed its ordinary Save330 MAP/WORLD route contract with four native
  frames, exact-title MP4, telemetry, hashes, and no foreground/input control.
  It used staged `732DE60F...E1E1D85E`. The strict C04 report is intentionally
  retained as a failure, but its sole failing field is a stale validator
  baseline that hard-codes the superseded `c04-icons` runtime path/SHA; the
  report itself correctly names the newly staged binary. The live route data
  proves the production path is now using the authored ScrollKnob pivot
  `controlBaseLocal=(7.68622,1.23748,3.13685)` and reports
  `scrollKnobCamera=(-5.80843,13.2730,-4.12579)`, rather than the prior
  wrapper-space target. This is not yet a visual promotion: next bite is to
  inspect the retained native contact frame, repair the validator's staged
  runtime provenance check deterministically, and only then decide whether
  the visible hand/contact and cuff seam actually improved. D02 remains IN
  PROGRESS.

- Correction to the preceding validator note: the C04 validator was invoked
  once without its `-RuntimeRoot`, which selected its historical default and
  therefore correctly rejected the newer capture binary. The original failed
  report remains immutable. Re-validating the exact same retained capture with
  the explicit authored-control stage produced the separate, strict
  `c04-validation-runtime-provenance.json` artifact, passing all 43/43 checks.
  This proves the current runner, hashes, native frames, logs, and provenance
  contract; it does not alter the direct visual finding that the right hand is
  not visibly contacting the ScrollKnob and the cuff presentation remains
  wrong. D02 remains IN PROGRESS.

- A second mandatory 54/54 idle preflight preceded the separate retained
  `c04-openmw-20260803-002200-right-hand-pose-audit` capture. Its public
  Save330 contract passed with four native frames, a video, hashes, no host
  control, and `handPoseAudit=true`. The actual `RightHand:0` audit rules out
  a skinning-mode guess: the selected `invBindThenSkeleton` mesh is compact
  (`extent=(14.3243,7.88651,7.43699)`), while every alternate candidate
  expands to at least `114x130x136` or worse. The real remaining defect is
  kinematic: at ScrollKnob contact the solved wrist/right-hand is
  `(3.06144,6.83241,-2.90122)` in Camera1st space, while the selected control
  is `(-5.80868,13.2718,-4.12572)`; the current code only rotates the first
  index segment, whose fixed length cannot close that gap. Next bite: use the
  existing authored `Finger1 -> Finger11 -> Finger12` chain as the end
  effector, derive the wrist standoff from its measured live reach, add
  terminal-finger telemetry, and inspect a fresh native frame. D02 remains IN
  PROGRESS.

- Replaced the unreachable first-knuckle contact solve with the real authored
  index chain: `Bip01 R Finger1 -> Finger11 -> Finger12`. The wrist is now
  placed one measured terminal-chain reach on the camera-facing side of the
  named physical control, and the distal-to-proximal chain then drives the
  existing player bones and already-rigged right-hand mesh to the actual
  contact. No proxy, duplicate hand, screen overlay, or synthetic input was
  added. Contact telemetry now records terminal bone, measured reach,
  standoff, and terminal error; the C04 validator additionally requires the
  distal `Finger12` ScrollKnob contact to be within `1.5` units. The first
  `/m:1` compile caught only a `Vec3d`/`float` clamp ambiguity; casting the
  measured length fixed it, and the follow-up serial build passed (existing
  PCH warning only). A complete no-overwrite no-PDB stage is ready at
  `local/openmw-real-save330-pipboy-distal-index-contact-20260803-002300/openmw.exe`
  (81,358,848 bytes, SHA-256
  `9DEE730330F67BEC2CE46CF4690121A4125C27D0482464D5607C68273769C42A`;
  resources/plugins present). No game launched after this change. Next bite:
  mandatory preflight, fresh C04 capture, strict validator, and direct image
  review of the terminal index hand and both cuff seams. D02 remains IN
  PROGRESS.

- The preflight for that distal-index stage again passed 54/54, and the fresh
  `c04-openmw-20260803-002400-distal-index-contact` runner contract passed.
  Its strict `c04-validation-final.json` passed 44/44: terminal `Finger12`
  error was `0.161900` (then `0.150631`) at the authored ScrollKnob, with
  native frames, hashes, telemetry, and no-control policy all valid. Direct
  native-frame review rejects the result despite those narrow checks: the
  per-joint distal-to-proximal rotations stretch the real skin into a giant
  peach triangle across the viewport. This is a visual regression, not a
  promotion, and the evidence remains preserved. Next bite: retain the
  measured distal endpoint and wrist standoff but remove the skinning-unsafe
  individual finger rotations, aligning only the actual hand/root toward the
  terminal endpoint before a new proof. D02 remains IN PROGRESS.

- The visual-regression correction preserves the measured `Finger12` endpoint
  and dynamic wrist standoff but stops overriding `Finger1`/`Finger11` joint
  matrices. The retail manipulate KF continues to own those finger rotations;
  only the real hand/wrist is aligned to its distal endpoint, avoiding the
  weighted-vertex shear seen in the rejected frame. The serial `/m:1` build
  passed (existing PCH warning only). A separate complete no-PDB stage is
  ready at
  `local/openmw-real-save330-pipboy-distal-index-whole-hand-20260803-002500/openmw.exe`
  (81,358,848 bytes, SHA-256
  `E9977304DC17403297EA92E54912B3546A1BA81602B4998DF8472E21E63227FE`).
  No game launched after this correction. Next bite: mandatory preflight,
  fresh C04 native capture, strict terminal-contact validation, and frame
  review; any remaining seam or offscreen hand blocks promotion. D02 remains
  IN PROGRESS.

- The whole-hand stage passed its required 54/54 preflight, public Save330
  C04 capture contract, and strict 44/44 validator (terminal errors
  `0.238448` and `0.245304`). It successfully removes the peach-triangle
  regression, but direct inspection of
  `c04-openmw-20260803-002600-distal-index-whole-hand` still shows no visible
  right hand on the knob; it is not promoted. The measured cause is now a
  hand-roll policy issue: the Pip-Boy solve presents its palm against generic
  actor-forward, rather than the camera-facing side of the physical display.
  Next bite: retain the real hand and terminal contact but use the existing
  live camera-facing vector as the Pip-Boy palm orientation target, then
  prove the resulting frame. D02 remains IN PROGRESS.

- The Pip-Boy whole-hand contact now supplies `towardViewer` as the palm
  target to the existing orientation chooser, instead of generic
  actor-forward. It retains the real terminal endpoint, measured standoff,
  authored manipulate KF finger tracks, and existing rigged mesh; telemetry
  declares `palmTarget=camera-facing`, which the strict terminal-contact gate
  now requires. The validator parses and the serial `/m:1` build passed
  (existing PCH warning only). Complete no-overwrite stage:
  `local/openmw-real-save330-pipboy-camera-facing-palm-20260803-002700/openmw.exe`
  (81,358,848 bytes, SHA-256
  `59917FCE84FCBA27A3629C34633DF117903A4874B3A0415EF550334AEA1D9753`;
  zero PDB files, resources/plugins present). No game launched in this bite.
  Next bite: mandatory preflight, one fresh C04 capture, strict validation,
  and direct image review of hand visibility, seams, screen framing, and map
  icon. D02 remains IN PROGRESS.

- The camera-facing-palm stage completed its mandatory 54/54 idle preflight
  and retained a distinct no-overwrite proof at
  `c04-openmw-20260803-002800-camera-facing-palm`. Its public C04 runner and
  `c04-validation-final.json` both passed (44/44), with terminal `Finger12`
  errors `0.280` and `0.250`, native frames, video, hashes, telemetry, and
  no-host-control policy intact. Direct inspection still rejects the result:
  the contact frame does not visibly show the right hand at the ScrollKnob,
  the cuff seams remain, and the screen/device framing remains unacceptable.
  The log queues the interaction frame at engine frame 480 but reports the
  retained file at frame 501; that may be asynchronous file completion rather
  than source-frame timing, so it is not being assumed as the cause. Next
  bite: inspect `ScreenCaptureHandler` and the C04 production interaction
  lifecycle to determine whether the visible pose is absent at capture time
  or the rigged hand is being rendered/cull-transformed incorrectly. D02
  remains IN PROGRESS.

- Capture-path inspection establishes that `ScreenCaptureHandler` captures
  the next rendered frame and only writes that retained image asynchronously;
  the delayed file-retention log is therefore not evidence that the queued
  contact pose was missed. The concrete seam defect found in the live source
  is Save330's equipped `LeftHandPipboyGlove1st.NIF`: it was excluded from the
  first-person hand-surface classification, so it was mounted in generic
  `Bip01` space while `pipboyarm.nif` followed `Bip01 L ForeTwist`. The
  classification now routes both Pip-Boy glove hand variants through the
  existing animated-hand bind-frame helper (and selects the left helper
  correctly). The required serial `/m:1` build passed, with only the existing
  PCH warning. A staging attempt using unsupported `New-Item -LiteralPath`
  created the incomplete non-proof directory
  `local/openmw-real-save330-pipboy-glove-bind-frame-20260803-003000`; it is
  preserved and will never be used or overwritten. Next bite: make a new
  complete no-overwrite runtime stage, then run the mandatory capture preflight
  and inspect a fresh native contact frame for the glove/cuff seam and visible
  right hand. D02 remains IN PROGRESS.

- The replacement runtime stage is complete and isolated at
  `local/openmw-real-save330-pipboy-glove-bind-frame-20260803-003100`:
  `openmw.exe` is 81,358,848 bytes with SHA-256
  `AF42E8358FAE56A7DB17D3B064DE5C662ACC774E12A0F1889B8FC0C138191152`,
  has zero PDB files, and retains `resources` plus `osgPlugins-3.6.5`.
  It was copied only from the prior complete stage and the just-built executable;
  no game has launched in this staging bite. Next bite: mandatory idle
  preflight, new no-overwrite C04 capture, strict validation, and direct
  native-frame review. D02 remains IN PROGRESS.

- The glove-bind-frame stage completed its required 54/54 `-RuntimeReady
  -RequireIdle` preflight and retained a separate public-runner proof at
  `run/fnv-real-save-campaign/c04-openmw-20260803-003200-glove-bind-frame`.
  The strict C04 validator passed 44/44 with native frames, video, hashes,
  telemetry, and no-host-control policy valid. The new source routing is
  confirmed in the log: Save330's `LeftHandPipboyGlove1st.NIF` now attaches
  through `FNV Animated L Hand Bind Frame` (`handSurface=1`) rather than the
  generic actor root. Direct review still rejects this as a visual repair:
  `Save330-C04-map-world-toggle-contact.png` shows no visible right hand at
  the ScrollKnob and does not prove a cuff-seam correction. The separately
  retained map-focused native frame does show the canonical discovered marker
  text and icon (`SELECTED: SOUTHERN PASSAGE 0x03008885`); it also shows the
  visible lower-right peach hand/sleeve boundary with the reported cuff gap.
  Thus the canonical marker source is functioning, but neither the visible
  second-hand interaction nor the seam is accepted. Next bite: trace the
  independently skinned Vault-suit arm and bare right-hand attachment/depth
  frames before changing another contact-orientation parameter. D02 remains
  IN PROGRESS.

- Frame-order tracing found a concrete proof-route defect, not a visual
  judgment issue: C04 queued `map-world-toggle-contact` at engine frame 478
  when the UI pulse was `0.587407`, while the production
  `pipboymanipulate.kf`/distal-index ScrollKnob solve first ran at frame 482.
  `ScreenCaptureHandler` therefore captured a genuinely pre-contact render
  frame; its later asynchronous file write was unrelated. C04 now queues that
  frame only after the retail transition boundary (`0.45 <= pulse <= 0.55`)
  and logs `captureAfterRetailTransition=1`. The deterministic C04 validator
  now requires that post-transition provenance rather than accepting the old
  broad pre-contact window. The serial `/m:1` OpenMW build passed (existing
  PCH warning only); no game launched in this source/build bite. Next bite:
  stage this exact binary in a new no-overwrite runtime, run the mandatory
  idle preflight, capture one fresh C04 proof, and inspect the actual live
  contact frame before assessing remaining seam or placement work. D02 remains
  IN PROGRESS.

- The post-transition runtime is staged without overwriting any predecessor at
  `local/openmw-real-save330-pipboy-post-contact-capture-20260803-003300`.
  Its `openmw.exe` is 81,358,848 bytes with SHA-256
  `A5702C18C42E13A4A3EA6BFC89F2CB38CB69AA30DF864D49B6F1549C228EACDA`;
  it has zero PDB files and retains `resources` and `osgPlugins-3.6.5`. No
  game launched during staging. Next bite: mandatory `-RuntimeReady
  -RequireIdle` preflight, then a new public C04 capture and direct review of
  the actual post-transition native contact frame. D02 remains IN PROGRESS.

- The mandatory OpenMW/RealSave preflight for the post-transition runtime
  passed 54/54 with `-RuntimeReady -RequireIdle` against the immutable Save330
  fixture and `save330-pipboy-map-selection-v1` route. It launched neither
  game and found the capture lane idle. Next bite: one fresh non-overwriting
  public C04 capture only through `Invoke-FNVJamBackgroundCapture.ps1`, then
  strict validation and direct native-frame review. D02 remains IN PROGRESS.

- The post-transition public C04 capture is retained without overwrite at
  `run/fnv-real-save-campaign/c04-openmw-20260803-003400-post-contact-transition`.
  Its runner contract passed and its deterministic validator passed 44/44,
  including `captureAfterRetailTransition=1`, native frames/video/hashes,
  canonical Southern Passage marker state, and the real ScrollKnob terminal
  contact. Direct native-frame review rejects it as a visual pass: unlike the
  old pre-contact image, `Save330-C04-map-world-toggle-contact.png` now
  contains a huge dark right-arm/hand mesh sweeping across the top of the
  viewport. It still does not show a readable hand operating the knob and
  blocks the view; the right cuff/sleeve seam is therefore not repaired. This
  proves the missing hand was partly a capture-timing error, but the actual
  post-contact rig pose has a separate visible arm-root/bind-frame failure.
  Next bite: derive that mesh-frame failure from the live post-transition pose
  and correct the real skeleton/skin path before another capture. D02 remains
  IN PROGRESS.

- The post-transition frame made the interaction source error unambiguous.
  Save330's retained xNVSE telemetry says ordinary MAP/WORLD navigation stays
  on `1stPPipboyWaver.kf`; it does not invoke `pipboymanipulate.kf` per UI
  action. The latter plus supplemental two-bone IK was the non-retail branch
  creating the huge dark arm across the actual contact frame. The canonical
  production path now keeps the measured `retail-waver` held pose while still
  animating the real physical control nodes through `setPipBoyControlState`;
  it logs `pipboyManipulate=0` for the MAP/WORLD action. The C04 validator was
  correspondingly tightened to require that xNVSE-held-input provenance and
  reject a synthetic right-arm reach. Its PowerShell parse check and the
  serial `/m:1` OpenMW build both passed (only the existing PCH warning). No
  game launched in this bite. Next bite: stage the exact binary, preflight,
  then inspect the true retail-held native frame for the remaining hand/cuff
  seam and physical-control framing. D02 remains IN PROGRESS.

- The retail-held-input runtime is staged without overwrite at
  `local/openmw-real-save330-pipboy-retail-held-input-20260803-003500`.
  Its `openmw.exe` is 81,339,904 bytes with SHA-256
  `48645204BA2B339561092477BFB5B0E010DA0F3D0B8A21EECF5799E55DD94A22`,
  retains `resources` and `osgPlugins-3.6.5`, and contains zero PDB files. No
  game launched during staging. Next bite: mandatory idle/runtime preflight,
  one new public C04 capture, strict xNVSE-held-input validation, and direct
  frame review. D02 remains IN PROGRESS.

- The mandatory preflight for the retail-held-input runtime passed 54/54 with
  `-RuntimeReady -RequireIdle` for the immutable Save330 fixture and explicit
  C04 map-selection route. Neither game was launched by the check. Next bite:
  one fresh non-overwriting public OpenMW C04 capture only through the approved
  entry point, followed by strict validation and native-frame inspection. D02
  remains IN PROGRESS.

- The retail-held-input public C04 capture is retained without overwrite at
  `run/fnv-real-save-campaign/c04-openmw-20260803-003600-retail-held-input`.
  The approved runner passed its normal Save330 contract with no host input;
  the direct native MAP/WORLD transition frame removes the giant dark arm and
  visibly retains the canonical discovered/travel marker (`SOUTHERN PASSAGE
  0x03008885`). This confirms the xNVSE-measured held-waver path rather than
  an invented per-key reach. It is not a visual promotion: the lower-right
  bare-hand/cuff gap remains. The strict C04 validator currently fails only
  because the former IK-derived camera audit disappeared and the still-idle
  overview image hashes identically to the contact image. Next bite: restore
  a read-only held-waver camera-space audit and make the overview a distinct,
  truthful production MAP action before tracing the sleeve/hand bind-frame
  mismatch. D02 remains IN PROGRESS.

- The held-waver camera audit and production-overview correction compile in a
  serial `/m:1` OpenMW build (only the existing PCH warning; zero errors), and
  `Test-FNVRealSaveC04.ps1` parses successfully. C04 phase 9 now performs one
  real `A_MoveRight` MAP pan through `handleFalloutPipBoyAction`, verifies that
  `panAfter > panBefore`, waits for the terminal surface, and only then retains
  the overview; phase 2 still recentres the canonical marker before focus.
  The validator requires that production pan provenance as well as four unique
  native-frame hashes. The new non-overwriting runtime is
  `local/openmw-real-save330-pipboy-waver-camera-audit-map-pan-20260803-003700`
  (`openmw.exe` 81,348,608 bytes, SHA-256
  `A89AE563495EAFDD81BC373837C68CC6B616CEF2D84C708949BD2E83716726CE`,
  zero PDB files, resources/plugins retained). No game launched during this
  source/build/stage bite. Next bite: run the mandatory idle/runtime preflight,
  then one fresh public C04 capture and inspect both the restored audit and the
  real bare-hand/cuff seam. D02 remains IN PROGRESS.

- The required preflight for that runtime passed 54/54 (`-RuntimeReady
  -RequireIdle`) and the sole fresh public C04 capture is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-020000-waver-audit-map-pan`.
  Its public runner passed with no host input/foreground activation, retained
  four native screenshots, telemetry, hashes, and exact-title video. The C04
  validator passes 46/46 against the canonical map-marker denominator; the
  first attempted validator call used the player denominator and stopped
  before writing an artifact because C04 correctly contracts the map-marker
  denominator. The production MAP pan changed `0 -> 0.08`, giving four unique
  native-source hashes without a synthetic overlay. Direct inspection shows
  the non-retail giant arm is gone and the real Southern Passage icon remains,
  but does not promote D02: the lower-right bare hand/cuff join is still
  visibly discontinuous and the device remains displaced from the retail
  frame. The restored xNVSE audit narrows this down: live left wrist bones are
  near the frame-980 oracle while separately copied hand-part roots report a
  distinct bind-space origin. Next bite: add a read-only live Arms-part mesh
  audit, compare the sleeve and bare-hand skin frames at the wrist, then make
  only the attachment/skin correction that the values support. D02 remains IN
  PROGRESS.

- A read-only wrist-seam audit is now compiled in a serial `/m:1` OpenMW build
  (the existing PCH warning only). It retains the live Save330 `Arms` rig
  handle after the exact `1 kept / 5 hidden` filter and logs its root and
  rendered mesh center beside both hand skins during the same held-waver
  transition. This changes no attachment transform, skinning mode, inventory,
  or UI state. The fresh no-overwrite runtime is
  `local/openmw-real-save330-pipboy-wrist-seam-audit-20260803-020700`
  (`openmw.exe` 81,348,608 bytes, SHA-256
  `504E0D392C291EBEDDE9610534744A15A82BC65AA747B1DC02E6B44CA73E4034`,
  zero PDB files, resources/plugins retained). No game launched during this
  source/build/stage bite. Next bite: mandatory idle/runtime preflight, one
  fresh C04 capture, then use the new live sleeve/hand values to select a
  specific seam correction. D02 remains IN PROGRESS.

- The first post-skin seam-probe build stopped at compile time before any game
  launch because its helper referenced a later local transform utility. That
  was corrected in place by using the equivalent OSG matrix multiplication;
  the serial `/m:1` rebuild passed (the existing PCH warning only), and the
  C04 validator script parses. The probe now samples each current
  double-buffered `RigGeometry` vertex within the same 16-unit camera-space
  wrist neighborhood, records each skin's closest wrist vertex, and records
  the closest live sleeve/hand pair for both sides. The fresh no-overwrite
  runtime is
  `local/openmw-real-save330-pipboy-postskin-wrist-seam-20260803-021300`
  (`openmw.exe` 81,356,288 bytes, SHA-256
  `87EC873681176014A1DC71473B95AC69E00DA112A142CBED6E269382C26BED3B`,
  zero PDB files, resources/plugins retained). No game launched during this
  correction/build/stage bite. Next bite: mandatory preflight and one fresh
  C04 run to obtain the actual sleeve-to-hand gap values; no visual attachment
  change is being claimed. D02 remains IN PROGRESS.

- The first post-skin C04 probe run retained its normal Save330 proof and
  validator pass, but its seam values were intentionally not promoted: the
  diagnostic double-applied the source node's parent transform after
  `RigGeometry` had already emitted skeleton/world-space vertices. That made
  otherwise plausible raw values appear tens of thousands of units away and
  correctly yielded `available=0`; it made no rendering change. The collector
  now converts those live vertices directly from the skinning output into
  camera space. The correction compiles in a serial `/m:1` OpenMW build with
  zero errors (only the pre-existing PCH warning). Next bite: stage this exact
  binary under a fresh non-overwriting runtime root, run the mandatory
  idle/runtime preflight, and take one public C04 capture to obtain valid
  sleeve/hand seam coordinates before changing mesh attachment or skinning.
  D02 remains IN PROGRESS.

- The corrected diagnostic is staged without overwriting a prior runtime at
  `local/openmw-real-save330-pipboy-postskin-wrist-seam-world-coords-20260803-021600`
  (`openmw.exe` 81,356,288 bytes, SHA-256
  `8C808B2042C3C03AD40A8E2B285CE2C8EF19D3E3C4911D2FFA16BDB4728B4B3C`,
  zero PDB files, resources/plugins retained). No game launched during this
  stage bite. Next bite: the required background-capture preflight and a sole
  public OpenMW C04 run against the immutable canonical Save330 fixture.
  D02 remains IN PROGRESS.

- The mandatory `Test-FNVJamBackgroundCapture.ps1` gate passed 54/54 for that
  fresh runtime with `-RuntimeReady -RequireIdle`; no retail or OpenMW process
  was launched by the gate. Next bite: retain one fresh non-overwriting public
  OpenMW C04 capture, then validate and inspect the native MAP contact frame.
  D02 remains IN PROGRESS.

- The sole public capture for the corrected seam diagnostic is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-021800-postskin-wrist-seam-world-coords`.
  Its runner passed the normal Save330 load and production MAP/WORLD route with
  four native source frames, exact-title video, sequential policy, no host
  input, and no foreground activation. Next bite: run the strict C04 validator
  against the canonical map-marker denominator and read the post-skin wrist
  audit before selecting any rendering correction. D02 remains IN PROGRESS.

- That capture's strict C04 validator passes 46/46 against the canonical
  map-marker denominator. The visual/probe bite is still not promoted: the
  live seam audit again reports the same raw post-skin vertex domain near
  `(-71066, 13203, -9022)` and `available=0`, so the previous assumption that
  those vertices were already world-space was wrong. No mesh, camera, or hand
  transform changed. Next bite: trace the `RigGeometry` buffer's actual space
  and compose the collector through the exact skin/bind transform it uses;
  only then take another capture. D02 remains IN PROGRESS.

- Direct comparison of the retained native frame against the xNVSE retail
  frames found a production placement error independent of the unresolved seam:
  xNVSE reports `firstPersonFov=47` while the held Pip-Boy is rendered, but
  OpenMW treated that observed render value as a 4:3 horizontal reference and
  converted it to `36.1233`. The result is visibly about 1.4x too large and
  low. The active Pip-Boy callback now applies the observed 47 degrees
  directly, preserving the ordinary save baseline after close. This is a
  rendering-path correction, not a synthetic overlay. The serial `/m:1`
  OpenMW build passed with zero errors (only the existing PCH warning). Next
  bite: stage this exact binary under a new runtime root, preflight it, and
  inspect one native Save330 MAP frame for the visible FOV/placement change
  before continuing the cuff seam trace. D02 remains IN PROGRESS.

- The FOV correction is staged without overwriting prior proof runtimes at
  `local/openmw-real-save330-pipboy-fov47-native-20260803-022700`
  (`openmw.exe` 81,356,288 bytes, SHA-256
  `6896CEB80EA67F36FE7A28C2FD77EF7A13EE3159A577E6E6903C5C06E2CFAAF4`,
  zero PDB files, resources/plugins retained). No game launched during the
  build/stage bite. Next bite: mandatory idle/runtime preflight, then exactly
  one non-overwriting public Save330 C04 capture for direct visual comparison.
  D02 remains IN PROGRESS.

- The required background-capture gate passed 54/54 for the FOV-corrected
  runtime with `-RuntimeReady -RequireIdle`; it did not launch a game. Next
  bite: one fresh public OpenMW C04 capture and direct native-frame inspection.
  D02 remains IN PROGRESS.

- The FOV-corrected public C04 capture is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-022900-fov47-native` and
  passed the normal Save330 production route with no host input. Direct native
  inspection confirms a visible size correction, but not acceptance: the
  screen is still materially below the retained retail footprint and the bare
  right hand/cuff seam remains. The xNVSE frame-980 node data now supplies a
  concrete next correction: retail `pipboyscreen` origin is
  `(-6.254269, 11.873332, -3.225682)` in `Camera1st` space. Next bite:
  retarget the existing physical wrist presentation root smoothly to that
  observed origin (not a GUI overlay), then build and inspect one fresh native
  C04 frame before resuming the wrist-skin trace. D02 remains IN PROGRESS.

- The first build of that calibration stopped before linking or launch because
  `osg::Vec3f` is not constexpr under this toolchain. The target remains the
  same measured xNVSE value; it is now a regular immutable local. Next bite:
  serial `/m:1` rebuild, then stage only if it passes. D02 remains IN PROGRESS.

- The corrected physical-wrist calibration compiles in a serial `/m:1` OpenMW
  build with zero errors (only the existing PCH warning). It resets the wrapper
  to its authored identity each frame, then applies only the measured
  camera-to-wrist translation at the current raise progress; it does not add
  geometry, UI, input automation, or an invented hand clip. Next bite: stage
  the exact binary under a fresh runtime root and retain one public native C04
  frame for direct inspection. D02 remains IN PROGRESS.

- The physical screen-origin calibration is staged without overwriting prior
  runtimes at `local/openmw-real-save330-pipboy-screen-origin-20260803-023500`
  (`openmw.exe` 81,359,360 bytes, SHA-256
  `A67DD0554B60A85275F6117E2FF7748E48CC3CF4921F479CC4D3C77A372A026E`,
  zero PDB files, resources/plugins retained). No game launched during this
  stage bite. Next bite: mandatory preflight and a single public C04 capture
  for visual/telemetry validation of the real wrist-root correction.
  D02 remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 for the
  screen-origin runtime with `-RuntimeReady -RequireIdle`; it launched neither
  game. Next bite: one fresh non-overwriting public OpenMW C04 run and direct
  inspection of its native MAP contact frame. D02 remains IN PROGRESS.

- The first screen-origin capture is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-024000-screen-origin` but
  explicitly rejected for visual use: its normal runner passed, yet the
  Pip-Boy disappeared because `getNodeWorldMatrix(screenNode)` selected a
  stale template parent path. Telemetry proves the mismatch (`beforeCamera`
  near `(-71085, 13193, -9133)`) while the live wrist root remains near the
  local Camera1st origin. No earlier proof directory was overwritten. Next
  bite: resolve the screen through the parent path that contains the live
  presentation root and make the calibration a no-op if that path cannot be
  found; rebuild before any further capture. D02 remains IN PROGRESS.

- The live-parent-path resolver and its fail-closed calibration guard compile
  in a serial `/m:1` OpenMW build with zero errors (only the existing PCH
  warning). It will use a `pipboyscreen` path only when that path contains
  `FNV Pip-Boy Authored Wrist Presentation`; otherwise the root remains at its
  authored identity. The accompanying audit now measures the screen/control
  through that same live path instead of double-transforming it. Next bite:
  stage this exact binary in a new runtime root, preflight, and take one public
  capture to determine whether the live path is available and visually correct.
  D02 remains IN PROGRESS.

- The live-path guarded binary is staged without overwriting a proof runtime at
  `local/openmw-real-save330-pipboy-screen-livepath-20260803-024200`
  (`openmw.exe` 81,359,360 bytes, SHA-256
  `8CF1CE2394DD4CB173FE9555A90D12E55C89CEF33B83AF1E9E131E26E5DD2197`,
  zero PDB files, resources/plugins retained). No game launched during this
  build/stage bite. Next bite: required preflight and exactly one public native
  C04 capture for the guarded screen-origin solve. D02 remains IN PROGRESS.

- The mandatory background-capture gate passed 54/54 for the live-path runtime
  with `-RuntimeReady -RequireIdle`, without launching either game. Next bite:
  one fresh public OpenMW C04 capture, then read the `screenPath` telemetry and
  inspect the retained native MAP contact image. D02 remains IN PROGRESS.

- The live-path capture is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-024400-screen-livepath`, but
  is rejected for visual use after direct native-frame inspection. Its normal
  production runner passed and the live path resolved, yet telemetry proves
  that `pipboyscreen` is a container at the wrist-presentation origin
  (`screenOriginCamera=(-6.25, 11.87, -3.23)`) while its bounded pane remains
  elsewhere (`screenCenterCamera=(4.80, 13.85, 1.01)`). Retargeting that
  container moved the entire device into the camera and made it enormous. The
  source has therefore removed the screen-origin calibration and restores the
  authored wrist mount every frame, retaining the independently verified
  47-degree FOV correction. No new capture or game launch occurred in this
  rollback bite. Next bite: serial build this fail-closed visual baseline, then
  resume the RigGeometry-space trace needed to repair the visible cuff seam.
  D02 remains IN PROGRESS.

- The fail-closed visual-baseline build completed with `/m:1` and zero errors;
  the only output was the pre-existing C4653 PCH-option warning in
  `esm4npcanimation.cpp`. It has not been staged or captured yet, so no proof
  runtime or previous evidence was overwritten. Direct comparison of retained
  frame 980 retail and the FOV-47 OpenMW native frame confirms that the current
  problem is the independently skinned arm/hand composition, not a need for a
  larger or more centered synthetic Pip-Boy transform. Next bite: instrument
  the exact RigGeometry-to-camera transform domain for the sleeve and hands,
  then correct only the proven bind/skin path. D02 remains IN PROGRESS.

- The existing public real-save capture runner now makes its already explicit
  `-RealSaveHandPoseAudit` switch also set `OPENMW_FNV_RIG_DRAW_AUDIT=1` and
  records that fact in the launch report. This is cull-path telemetry only; it
  changes no animation, skinning, camera, input, or proof route. PowerShell
  syntax validation passed and no game launched in this bite. Next bite: stage
  the fail-closed baseline in a fresh runtime, pass the required idle preflight,
  and take one diagnostic C04 capture to identify the sleeve/glove render path
  before making any visual change. D02 remains IN PROGRESS.

- The fail-closed FOV-47 baseline is staged in the new, non-overwritten runtime
  `local/openmw-real-save330-pipboy-rigpath-audit-20260803-025100` from the
  verified FOV runtime, with only the freshly built `openmw.exe` replaced. The
  staged binary is 81,359,360 bytes, SHA-256
  `DE23B7F1C7672525706A0773940D31CDA6175DD264D98FC0C70AE6C68184EDFE`, has
  zero PDB files, and retains `resources`. No game launched during this stage
  bite. Next bite: run the mandatory `-RuntimeReady -RequireIdle` gate, then
  one public C04 diagnostic capture from this exact runtime. D02 remains IN
  PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the fresh rig-path-audit runtime; neither
  retail nor OpenMW was running at the gate. Next bite: make exactly one public
  OpenMW `save330-pipboy-map-selection-v1` capture with the explicit hand/rig
  audit enabled, then inspect its native frame and cull-path telemetry. D02
  remains IN PROGRESS.

- A single fresh public C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-025300-rigpath-audit` using
  the staged baseline and production `save330-pipboy-map-selection-v1` route.
  The normal runner reports pass, ordinary save load, four native frames,
  retained telemetry/video, no foreground automation, and no overwritten
  output. It is a diagnostic capture only: visual acceptance and cull-path
  interpretation are still pending. Next bite: inspect the native MAP contact
  frame and correlate its sleeve/glove geometry with the retained draw audit.
  D02 remains IN PROGRESS.

- Direct inspection of that retained native frame rejects it for visual use:
  the screen and right cuff/hand boundary are still visibly wrong. The new cull
  audit identifies why the seam metric had been unusable: the live sleeve,
  glove, and right-hand `RigGeometry` paths all pass through `FNV First Person
  Camera1st Alignment` and `FNV Native First Person Root`, but the collector
  applied only `worldToCamera` to local post-skin vertices. The collector now
  resolves each drawable's parent path under its exact live part root before
  applying `worldToCamera`, and reports path-resolution counts; this is
  measurement-only and does not alter the renderer. Next bite: serial-build
  this instrumentation, then take one fresh diagnostic capture to obtain the
  real cuff gap before applying a visual correction. D02 remains IN PROGRESS.

- The first serial instrumentation build stopped before producing a runtime on
  one C++ diagnostic-only type error: `RigGeometry::getParent()` returns an
  `osg::Group*`, not `osg::Geode*`. The collector now uses the correct base
  type; no game launched, no proof directory changed, and the renderer remains
  untouched. Next bite: repeat the required serial build and proceed only on a
  zero-error result. D02 remains IN PROGRESS.

- The corrected collector build completed with `/m:1` and zero errors; the
  only output was the pre-existing C4653 PCH-option warning. No game launched
  and no prior runtime or proof directory changed. Next bite: stage this exact
  binary under a new runtime root, then use the required preflight before one
  diagnostic C04 capture. D02 remains IN PROGRESS.

- The corrected seam-measurement build is staged in the new, non-overwritten
  runtime `local/openmw-real-save330-pipboy-seamworld-audit-20260803-030100`.
  Its `openmw.exe` is 81,359,360 bytes with SHA-256
  `699FADFA5952301DFA5119A1532C9D61C22A852CB6B370C2F25DE5AE2145C2E1`, has
  zero PDB files, and retains `resources`. No game launched in this stage bite.
  Next bite: required `-RuntimeReady -RequireIdle` preflight, then one fresh
  public C04 diagnostic run. D02 remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the corrected seam-measurement runtime;
  neither retail nor OpenMW was running at the gate. Next bite: one public C04
  capture with the explicit rig/hand audit, then use the resulting numeric seam
  points to choose a narrowly scoped visual correction. D02 remains IN
  PROGRESS.

- The one fresh public C04 diagnostic capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-030300-seamworld-audit` with
  normal runner pass, ordinary Save330 load, four native frames, retained
  telemetry/video, no foreground automation, and no overwritten output. It is
  still diagnostic only; next bite is to read its resolved-path and seam-point
  telemetry before changing any renderer transform. D02 remains IN PROGRESS.

- The first post-capture C04 validator invocation did not run because the
  script parameter is `-CaptureRoot`, not `-OutputRoot`; it made no file or
  runtime change. The validator header was checked and requires a fresh
  `-ValidationPath` as well. Next bite: run it against the retained diagnostic
  capture with the canonical marker denominator and a non-overwriting
  validation artifact, then continue from the real seam measurement. D02
  remains IN PROGRESS.

- The corrected C04 validator invocation retained its fresh validation JSON but
  failed two stale textual expectations: it still expected the superseded
  36.123-degree vertical conversion instead of the source's evidence-backed
  47-degree retail FOV, and it did not allow the now-required `screenPath=1`
  audit field. The route itself is not accepted on this result. Next bite:
  update only those deterministic validator patterns to the active, logged
  retail provenance, syntax-check the script, and rerun it against the same
  retained capture with a new validation path. D02 remains IN PROGRESS.

- `Test-FNVRealSaveC04.ps1` now requires the actual logged retail FOV
  (`requestedVertical=47`) and the explicit live `screenPath=1` audit while
  retaining a deterministic `scrollKnobPath` presence check. PowerShell syntax
  validation passed; no game or artifact was changed by this validator-only
  bite. Next bite: rerun against the retained capture with a new validation
  path, then use the measured left seam rather than an arbitrary transform.
  D02 remains IN PROGRESS.

- The rerun retained a second, non-overwritten validation artifact but still
  failed one pattern: the source log labels its retail measurement
  `observedFirstPerson=47`, not the stale `referenceHorizontal=47`. The route
  remains unaccepted. Next bite: correct that exact deterministic field name,
  syntax-check, and rerun once more with a third fresh validation path. D02
  remains IN PROGRESS.

- The FOV validator now exactly requires the retained source line
  `observedFirstPerson=47 requestedVertical=47` with the existing baseline and
  presentation checks. PowerShell syntax validation passed; no runtime or
  proof capture changed. Next bite: one final validator run against the same
  retained capture using a third fresh validation path. D02 remains IN
  PROGRESS.

- The third, non-overwriting C04 validator run passed all 46 checks at
  `run/fnv-real-save-campaign/c04-openmw-20260803-030300-seamworld-audit/c04-map-selection-validation-fov47.json`.
  This proves only the canonical MAP-selection route, source fixture,
  retained marker, production callback sequence, and hashes; it does not
  accept the visually broken cuff/screen frame. The resolved seam telemetry is
  now usable: the steady right cuff is 0.059 units while the left Pip-Boy glove
  gap is 2.597 units. Next bite: trace the left glove's first-person rig basis
  against the outfit Arms rig and repair that specific mismatch, without
  disturbing the validated map route. D02 remains IN PROGRESS.

- The seam telemetry establishes a narrow target: steady right cuff alignment
  is 0.059 units, while the left Pip-Boy glove-to-sleeve seam is 2.597 units.
  The diagnostic skin-data probe now includes the existing canonical
  `armor/vaultsuit/m/outfit.nif` parser path so its Arms inverse-bind bases can
  be compared with the already logged left glove bases. This is telemetry only;
  no transform, animation, or renderer behavior changed. Next bite: serial
  build, then one preflighted diagnostic capture to retrieve the shared parser
  data before applying a left-only repair. D02 remains IN PROGRESS.

- The parser-probe build completed with `/m:1` and zero errors. No game or
  proof artifact changed. Next bite: stage this exact binary into a fresh
  runtime, pass the mandatory idle gate, and make one diagnostic C04 capture
  to obtain the canonical outfit Arms skin bases. D02 remains IN PROGRESS.

- The parser-probe binary is staged in fresh runtime
  `local/openmw-real-save330-pipboy-leftbasis-audit-20260803-031100` with
  `openmw.exe` SHA-256
  `9ADA73AD04F61127564CA73C77EC60B8027F9FCABCAB8F48498C07E7AFD01CA0`,
  81,359,360 bytes, zero PDB files, and retained `resources`. No game launched
  during staging. Next bite: mandatory idle preflight then one public diagnostic
  C04 capture. D02 remains IN PROGRESS.

- The mandatory background-capture gate passed 54/54 with
  `-RuntimeReady -RequireIdle` for the left-basis parser runtime, with neither
  game running. Next bite: exactly one public OpenMW C04 diagnostic capture;
  then inspect the retained `Arms` inverse-bind data and choose a left-only
  repair. D02 remains IN PROGRESS.

- The one public left-basis C04 diagnostic capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-031300-leftbasis-audit` with
  normal runner pass, ordinary Save330 load, four native frames, retained
  telemetry/video, no foreground automation, and no overwritten output. It is
  diagnostic only. Next bite: compare the retained outfit Arms inverse-bind
  bases with the left glove bases and constrain the repair to the mismatched
  left first-person surface. D02 remains IN PROGRESS.

- The retained parser data proves the shared `Bip01 L ForeTwist` inverse-bind
  basis is identical in `Arms` and `LeftHandPipBoyGlove`, so a synthetic
  glove translation would have been the wrong repair. The real missing bridge
  is canonical content: the worn outfit contains two `PipBoyOn` rig partitions
  (33 and 111 vertices) that share the left forearm/hand bases but the existing
  first-person filter hid them along with the body. The filter now retains
  `Arms` plus those two partitions, keeps the latter hidden normally, and
  toggles them only with physical Pip-Boy presentation; the seam collector is
  explicitly restricted to `Arms` so its metric remains meaningful. This is a
  scoped left-cuff renderer change. Next bite: serial build, fresh runtime,
  required preflight, and one native C04 capture for direct visual inspection.
  D02 remains IN PROGRESS.

- The first build invocation for the cuff change did not start: the PowerShell
  command used an invalid MSBuild path and exited immediately before compiling,
  linking, staging, or launching a game. Next bite: rerun the required `/m:1`
  build with the verified MSBuild path. D02 remains IN PROGRESS.

- The verified `/m:1` cuff build completed with zero errors; only the existing
  C4653 PCH-option warning remains. No game or proof artifact changed. Next
  bite: stage this binary under a new runtime, run the mandatory idle gate, and
  capture one native C04 frame for direct inspection of the `PipBoyOn` cuff
  bridge. D02 remains IN PROGRESS.

- The cuff-build binary is staged in new runtime
  `local/openmw-real-save330-pipboy-pboncuff-20260803-032100` with
  `openmw.exe` 81,360,896 bytes, SHA-256
  `19B4C7979C3D9F019E9B0EBB38D0603F0527266ED92BB19295ABD6402F20AC14`,
  zero PDB files, and retained `resources`. No game launched during staging.
  Next bite: mandatory `-RuntimeReady -RequireIdle` gate, then exactly one
  public C04 capture for direct visual inspection. D02 remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the cuff runtime, with neither game running.
  Next bite: one public OpenMW C04 capture from this runtime, then inspect the
  native MAP contact frame before accepting or revising the cuff bridge. D02
  remains IN PROGRESS.

- The one fresh public cuff C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-032300-pboncuff` with normal
  runner pass, ordinary Save330 load, four native frames, retained telemetry
  and video, no foreground automation, and no overwritten output. It is not
  visually accepted until the retained MAP contact frame is inspected. Next
  bite: direct native-frame inspection plus cuff/seam telemetry review. D02
  remains IN PROGRESS.

- Direct inspection rejects the cuff capture: the frame is still visually
  broken, and the retained log explains why the new bridge did not render.
  Although setup retained the expected `Arms=1/PipBoyOn=2/other=3` partitions,
  the visibility visitor reported `partitions=0` because its traversal honored
  the intentionally zeroed PipBoyOn masks. The visitor now overrides node masks
  during the toggle, matching the existing hidden-branch traversal idiom. No
  other transform, animation, or screen placement changed. Next bite: serial
  build and one fresh preflighted native capture to inspect the real cuff bridge
  rather than this rejected frame. D02 remains IN PROGRESS.

- The visible-cuff retry proves the mask traversal worked (`partitions=2` and a
  first-person `PipBoyOn` cull path), but the direct native frame rejects the
  content: it adds visibly misplaced black geometry while leaving the screen
  distortion and non-operating hand unresolved. The source has therefore
  explicitly restored the original Arms-only filter and removed the rejected
  PipBoyOn presentation path; no prior capture was overwritten. Next bite:
  serial-build the restored baseline, then target the physical screen material
  mapping and canonical interaction evidence rather than forcing third-person
  cuff partitions into first person. D02 remains IN PROGRESS.

- The Arms-only restoration built with `/m:1` and zero errors (only the
  existing C4653 warning). No game or evidence artifact changed. Next bite:
  trace the physical screen state's texture units and UV/projection path, then
  apply a source-backed correction before a fresh native capture. D02 remains
  IN PROGRESS.

- The next diagnostic is scoped to the physical screen material, not its
  mount: under the existing explicit hand-audit switch, the screen binder now
  records each real `pipboyscreen` geometry's vertex count and texture-coordinate
  range before it replaces its state set. This uses the live OSG geometry and
  existing screen binder; it does not alter UVs, shaders, transforms, input, or
  rendering behavior. Next bite: serial build, fresh runtime, required
  preflight, and one native capture to determine whether the map warp comes
  from raw atlas UVs or the custom map viewport shader. D02 remains IN
  PROGRESS.

- The first serial screen-audit build stopped before creating a runtime on one
  diagnostic-only API typo (`osg::Geometry` has no `getNumVertices`). It now
  uses the existing `getVertexArray()->getNumElements()` idiom. No game,
  runtime, or proof artifact changed. Next bite: rerun the required `/m:1`
  build and proceed only on zero errors. D02 remains IN PROGRESS.

- The corrected screen-UV audit build completed with `/m:1` and zero errors;
  only the existing C4653 warning remains. No game or proof artifact changed.
  Next bite: stage the binary in a fresh runtime, pass the mandatory idle gate,
  and take one diagnostic C04 capture for the actual UV range. D02 remains IN
  PROGRESS.

- The screen-UV audit binary is staged in fresh runtime
  `local/openmw-real-save330-pipboy-screenuv-audit-20260803-034100` with
  `openmw.exe` 81,360,896 bytes, SHA-256
  `D8E671C08C3D4BD369E15726EEF26F8EACA258457CDB34E8EC0E768B6A2D3FFD`,
  zero PDB files, and retained `resources`. No game launched during staging.
  Next bite: mandatory preflight then one public diagnostic C04 capture. D02
  remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the screen-UV runtime, with neither game
  running. Next bite: one public OpenMW C04 capture with the existing explicit
  audit switch, then inspect UV telemetry before touching the shader. D02
  remains IN PROGRESS.

- The hidden-mask traversal correction built successfully with `/m:1` and zero
  errors (only the pre-existing C4653 warning). No game or evidence artifact
  changed. Next bite: stage a fresh runtime, pass the mandatory gate, and take
  exactly one public native C04 capture to confirm whether both retained cuff
  partitions now render. D02 remains IN PROGRESS.

- The hidden-mask correction is staged in new runtime
  `local/openmw-real-save330-pipboy-pboncuffvisible-20260803-033100` with
  `openmw.exe` 81,360,896 bytes, SHA-256
  `C4209E0F5E578794552996252DF7B288F8D0D5906D014542923AD42D462427C7`,
  zero PDB files, and retained `resources`. No game launched during staging.
  Next bite: mandatory idle preflight followed by exactly one public C04
  capture. D02 remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the visible-cuff runtime, with neither game
  running. Next bite: one public OpenMW C04 capture and direct native-frame
  inspection; no result will be claimed without both the telemetry and image.
  D02 remains IN PROGRESS.

- The one public visible-cuff C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-033300-pboncuffvisible` with
  normal runner pass, ordinary Save330 load, four native frames, retained
  telemetry/video, no foreground automation, and no overwritten output. It is
  pending direct visual inspection and cuff telemetry review. D02 remains IN
  PROGRESS.

- The one public screen-UV-audit C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-034300-screenuv-audit` with
  normal runner pass, ordinary Save330 load, four native frames, retained
  telemetry/video, no foreground automation, and no overwritten output. Direct
  inspection rejects the frame for visual acceptance: the MAP texture remains
  severely warped across the physical screen. The intended UV-audit telemetry
  did not emit, so no shader change has been guessed or applied. Next bite:
  trace the screen state's real geometry/material owner and make the diagnostic
  observe that live path before changing projection code. D02 remains IN
  PROGRESS.

- The UV diagnostic now follows an authenticated `pipboyscreen` state owner
  through both node and geode traversal, and audits its child geometry even
  when the screen texture is inherited rather than stored on the drawable.
  Binding criteria are unchanged: only an owner named `pipboyscreen` with the
  authenticated retail screen texture can receive the live terminal material.
  This is diagnostics-only; it does not alter UVs, maps, transforms, input, or
  animation. Next bite: serial build, fresh runtime, mandatory idle preflight,
  and one non-overwriting capture to obtain the actual live UV range. D02
  remains IN PROGRESS.

- The inherited-screen UV diagnostic built with `/m:1` and zero errors; only
  the existing C4653 precompiled-header warning remains. No game, runtime, or
  proof artifact changed. Next bite: stage the resulting binary in a fresh
  runtime, then pass the mandatory idle gate before one non-overwriting native
  capture. D02 remains IN PROGRESS.

- The inherited-owner diagnostic is staged without overwriting a prior runtime
  at `local/openmw-real-save330-pipboy-screenuv-owner-audit-20260803-034200`.
  Its `openmw.exe` is 81,360,896 bytes, SHA-256
  `38A53EBBE30A769FEEE1A8CE3903696605223A5C1621A9C1C5B1136DD83141AC`, has
  zero PDB files, and retains `resources` plus `osgPlugins-3.6.5`. No game
  launched during staging. Next bite: mandatory background-capture preflight,
  then exactly one public OpenMW C04 capture. D02 remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the inherited-owner runtime, with neither
  game running. Next bite: one public, non-overwriting OpenMW C04 capture with
  the existing explicit audit switch, then inspect the live screen-UV telemetry
  before changing the map shader. D02 remains IN PROGRESS.

- The one public inherited-owner C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-034400-screenuv-owner-audit`
  with normal runner pass, ordinary Save330 load, four native frames, retained
  telemetry/video, no foreground automation, and no overwritten output. The
  live geometry audit emitted exactly one authenticated screen mesh:
  `pipboyscreen:0`, 56 vertices/UVs, raw retail atlas range
  `min=(-0.0104533,0.237521) max=(0.752926,0.998031)`. This disproves the
  shader's prior “already normalized” claim and explains the rejected warped
  MAP frame. Next bite: normalize only this measured retail atlas island in
  the screen shader, then build and inspect a fresh native frame. D02 remains
  IN PROGRESS.

- The screen shader now normalizes the measured `pipboyscreen:0` retail atlas
  island exactly once before it samples the full live terminal render target.
  No device, wrist, cuff, inventory, map-marker, input, or animation path was
  changed. Next bite: serial build; on zero errors, stage a fresh runtime,
  pass the mandatory idle gate, and directly inspect a new native MAP frame.
  D02 remains IN PROGRESS.

- The retail-atlas normalization built with `/m:1` and zero errors; only the
  existing C4653 precompiled-header warning remains. No game, runtime, or proof
  artifact changed. Next bite: stage a fresh no-overwrite runtime, then run the
  mandatory background-capture idle gate before one visual C04 capture. D02
  remains IN PROGRESS.

- The retail-atlas-normalized binary is staged without overwriting a prior
  runtime at
  `local/openmw-real-save330-pipboy-screen-atlas-normalized-20260803-034500`.
  Its `openmw.exe` is 81,360,896 bytes, SHA-256
  `FB0C57AF8DE7FE5C02208D8286D351CFE9ACADB7298C42A2168512C74D090B80`, has
  zero PDB files, and retains `resources` plus `osgPlugins-3.6.5`. No game
  launched during staging. Next bite: mandatory idle preflight then exactly one
  public OpenMW C04 capture for direct native-frame inspection. D02 remains IN
  PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the atlas-normalized runtime, with neither
  game running. Next bite: one public non-overwriting OpenMW C04 capture, then
  direct inspection of its native MAP frame before any further source change.
  D02 remains IN PROGRESS.

- The one public atlas-normalized C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-034600-screen-atlas-normalized`
  with normal runner pass, ordinary Save330 load, four native frames, retained
  telemetry/video, no foreground automation, and no overwritten output. Direct
  inspection rejects it: the live content now spans the intended glass, proving
  atlas normalization is active, but the green scanlines remain geometrically
  distorted. Next bite: audit the authenticated source screen state's texture
  transform before changing coordinates again; the current shader may be
  bypassing a required retail material transform. D02 remains IN PROGRESS.

- A diagnostic now records the authenticated original screen state's unit-zero
  `TexMat` matrix (or its absence) immediately before the live terminal
  material replaces its texture. It is gated by the existing explicit audit
  switch and changes no material, UV, transform, input, or animation behavior.
  Next bite: serial build, a fresh runtime, mandatory idle preflight, and one
  native capture to read that source-material provenance. D02 remains IN
  PROGRESS.

- The source-material transform diagnostic built with `/m:1` and zero errors;
  only the existing C4653 precompiled-header warning remains. No game, runtime,
  or proof artifact changed. Next bite: stage a fresh runtime, pass the
  mandatory idle gate, and take one non-overwriting native C04 capture to read
  the actual source `TexMat` provenance. D02 remains IN PROGRESS.

- The source-material-transform diagnostic is staged without overwriting a
  prior runtime at
  `local/openmw-real-save330-pipboy-screen-texmat-audit-20260803-034900`.
  Its `openmw.exe` is 81,360,896 bytes, SHA-256
  `FB4D46BF603A93F088FA6EAD474945D97C4207BBF5F7E99B43F41158106EEB1B`, has
  zero PDB files, and retains `resources` plus `osgPlugins-3.6.5`. No game
  launched during staging. Next bite: mandatory idle preflight then one public
  native C04 capture. D02 remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the source-material-transform runtime, with
  neither game running. Next bite: exactly one public non-overwriting OpenMW
  C04 capture, then inspect the retained `TexMat` provenance before another
  shader revision. D02 remains IN PROGRESS.

- The one public source-material-transform C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-035000-screen-texmat-audit`
  with normal runner pass, ordinary Save330 load, four native frames, retained
  telemetry/video, no foreground automation, and no overwritten output. The
  authenticated original `pipboyscreen:0` state reports `texMat=none`; texture
  transform omission cannot explain the rejected scanline distortion. The live
  terminal raster draws retail-style lines every four source pixels and was
  explicitly forced to non-mipmapped linear sampling, so the next evidence-led
  correction is generated mipmaps plus anisotropic filtering for the oblique
  physical screen. D02 remains IN PROGRESS.

- The live terminal texture now uses generated mipmaps and 8x anisotropic
  filtering while retaining the same 1024x768 retail-style terminal raster,
  including its scanlines. This targets only the confirmed oblique-sampling
  aliasing; it changes no Pip-Boy geometry, atlas coordinates, player state,
  markers, controls, or animation. Next bite: serial build, fresh runtime,
  mandatory idle preflight, and direct inspection of one new native C04 MAP
  frame. D02 remains IN PROGRESS.

- The sampling correction built with `/m:1` and zero errors (and zero warnings
  in this incremental build). No game, runtime, or proof artifact changed. Next
  bite: stage a fresh no-overwrite runtime, pass the required idle gate, and
  inspect one new native C04 MAP frame. D02 remains IN PROGRESS.

- The mipmap/anisotropic-screen binary is staged without overwriting a prior
  runtime at
  `local/openmw-real-save330-pipboy-screen-mipmap-aniso-20260803-035300`.
  Its `openmw.exe` is 81,360,896 bytes, SHA-256
  `DDD7900D85626C26146DA4F794ACFE693C90CA74CA313C311D87D2CB6705D399`, has
  zero PDB files, and retains `resources` plus `osgPlugins-3.6.5`. No game
  launched during staging. Next bite: mandatory idle preflight then one public
  native C04 capture for direct inspection. D02 remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the mipmap/anisotropic runtime, with neither
  game running. Next bite: one public non-overwriting OpenMW C04 capture, then
  direct inspection of the native MAP frame. D02 remains IN PROGRESS.

- The one public mipmap/anisotropic C04 capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-035400-screen-mipmap-aniso`
  with normal runner pass, ordinary Save330 load, four native frames, retained
  telemetry/video, no foreground automation, and no overwritten output. Direct
  inspection accepts the screen correction: live content fills the authentic
  glass, title/text/map icon are readable, and the rejected moire/warped bands
  are absent while the display retains fine scanlines. This does not claim the
  cuff seam or right-hand physical-control animation solved. Next bite: run the
  deterministic C04 validator against this retained proof, then continue from
  the plan's next unmet gate. D02 remains IN PROGRESS.

- `Test-FNVRealSaveC04.ps1` accepted the retained mipmap/anisotropic proof:
  46/46 checks passed and the non-overwriting validation artifact is
  `run/fnv-real-save-campaign/c04-openmw-20260803-035400-screen-mipmap-aniso/c04-map-selection-validation.json`.
  This verifies canonical fixture/provenance, normal production MAP selection,
  retained frames/video/telemetry, and deterministic marker evidence; it does
  not substitute for the pending cuff/right-hand or travel acceptance gates.
  Next bite: resume the plan at the next unmet fast-travel gate. D02 remains IN
  PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the verified screen runtime and the exact
  `save330-pipboy-map-travel-v1` route, with neither game running. Next bite:
  one public non-overwriting OpenMW C05 capture through the production
  confirmation/travel handler, then validate the retained before/confirmation/
  destination frames and telemetry. C05 is now IN PROGRESS.

- The one public C05 capture completed at
  `run/fnv-real-save-campaign/c05-openmw-20260803-035600-screen-mipmap-aniso`
  with normal runner pass, ordinary Save330 load, three native
  before/confirmation/destination frames, retained telemetry/video, no
  foreground automation, and no overwritten output. Direct review confirms the
  production confirmation question and Southern Passage arrival frame. The
  first deterministic validator pass failed only because its arrival regex did
  not allow the already-logged `sameDestinationCell=0` field between
  `timeAdvanced=1` and `menuClosed=1`; the actual arrival log also confirms
  destination cell/worldspace/grid/position, time advancement, closed menu,
  controls restored, and cleared travel. Next bite: tighten that validator
  pattern to require the field, then validate again with a fresh artifact. C05
  remains IN PROGRESS.

- The C05 arrival validator now explicitly requires
  `sameDestinationCell=0`, preserving the stronger proof that the production
  travel actually moved the player rather than merely re-confirming the same
  cell. No game, runtime, or capture artifact changed. Next bite: validate the
  retained C05 proof under a new no-overwrite validation path. C05 remains IN
  PROGRESS.

- `Test-FNVRealSaveC05.ps1` accepted the retained travel proof: 38/38 checks
  passed and the fresh validation artifact is
  `run/fnv-real-save-campaign/c05-openmw-20260803-035600-screen-mipmap-aniso/c05-fast-travel-validation-same-destination.json`.
  The production confirmation handler moved the canonical save from its source
  to Southern Passage, advanced four hours, closed the menu, restored controls,
  cleared the pending travel state, and retained all required native evidence.
  C05 is COMPLETE. Next bite: C06 fast-travel rejection matrix. D02 remains IN
  PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the exact
  `save330-pipboy-rejection-matrix-v1` route, with neither game running. Next
  bite: one public non-overwriting OpenMW C06 capture through production map
  paths, then validate cancellation, disabled travel, enemies-nearby,
  undiscovered, and invalid-destination behavior. C06 is now IN PROGRESS.

- The one public C06 capture completed at
  `run/fnv-real-save-campaign/c06-openmw-20260803-035900-screen-mipmap-aniso`
  with normal runner pass, five retained native frames, telemetry/video, no
  foreground automation, and no overwrite. Its deterministic validator passes,
  and telemetry proves all five production rejection cases preserve position and
  time. Direct frame review nevertheless rejects the capture as final C06
  evidence: `ScreenCaptureHandler` was queued in the same engine update as each
  UI string change, so the named frames visibly lag the requested rejection
  state by one case. Next bite: defer each C06 native capture until its UI state
  has crossed at least one render update, then take one fresh strict capture;
  no rejection behavior itself will be changed. C06 remains IN PROGRESS.

- C06 now schedules each named native frame for two proof-ready frames after
  the production UI changes, dispatches it only after that settle window, and
  holds the final drain until its pending invalid-destination frame has been
  issued. The fast-travel decision/override paths are untouched; this fixes only
  native-frame provenance so visible content matches the logged rejection case.
  Next bite: serial build, fresh runtime, mandatory idle preflight, one
  non-overwriting C06 capture, and direct review of all five labels. C06 remains
  IN PROGRESS.

- The C06 frame-settle correction built with `/m:1` and zero errors (and zero
  warnings in this incremental build). No game, runtime, or proof artifact
  changed. Next bite: stage the binary in a fresh no-overwrite runtime, pass
  the mandatory idle gate, and make one fresh C06 capture for direct label
  review. C06 remains IN PROGRESS.

- The C06 frame-settle binary is staged without overwriting a prior runtime at
  `local/openmw-real-save330-c06-frame-settle-20260803-040800`. Its
  `openmw.exe` is 81,370,112 bytes, SHA-256
  `F5B380BB8AE7BDA27DEA314E4688715D50FBD018E803CB27507D6F3D259E33A5`, has
  zero PDB files, and retains `resources` plus `osgPlugins-3.6.5`. No game
  launched during staging. Next bite: mandatory idle preflight then one public
  C06 capture. C06 remains IN PROGRESS.

- The mandatory background-capture preflight passed 54/54 with
  `-RuntimeReady -RequireIdle` for the C06 frame-settle runtime and exact
  rejection-matrix route, with neither game running. Next bite: one public
  non-overwriting OpenMW C06 capture and direct review of all five native
  rejection frames. C06 remains IN PROGRESS.

- Direct review of all five fresh C06 native frames at
  `run/fnv-real-save-campaign/c06-openmw-20260803-040900-frame-settle` now
  matches their named production states. The cancellation frame deliberately
  retains the opened confirmation prompt immediately before its production
  cancel path; disabled travel, enemies nearby, undiscovered, and invalid
  destination each visibly show their own exact rejection text, with no
  one-state frame lag. `Test-FNVRealSaveC06.ps1` was hardened to require both
  the UI-settle scheduling record and the settled `ScreenCaptureHandler`
  dispatch record for every native frame, then accepted the retained run 47/47
  at
  `run/fnv-real-save-campaign/c06-openmw-20260803-040900-frame-settle/c06-rejection-validation-ui-settle.json`
  (SHA-256 `8F5B12D4F6EA149398F74B84EEE22A66B13457E6A718601E6586B7ABC7F1E796`).
  C06 is COMPLETE. C07 remains covered by its retained passing persistence
  evidence and is not repeated. Next bite: D02 production weapon selection;
  D02 remains IN PROGRESS.

- The retained xNVSE Save330 evidence was rechecked before changing the hand:
  retail `MenuTapKey` ITEMS and DOWN actions keep `1stPPipboyWaver.kf` active
  and retain the right hand low-right; they do not start
  `pipboymanipulate.kf`. The prior OpenMW early return therefore explained the
  missing knob hand but cannot honestly be called an animated retail action.
  The production route now keeps that retail waver baseline and leaves
  `pipboymanipulate=0`, while adding an explicitly labeled, pulse-only
  physical-control extension for the existing skinned right hand at the real
  ScrollKnob. It uses the already-resolved authored control pivot and player
  skeleton only—no extra hand mesh, overlay, or injected input. Next bite:
  serial-build this narrow candidate, then inspect a fresh native contact frame
  before accepting either the contact or the still-pending cuff seam. D02
  remains IN PROGRESS.

- The physical-control hand candidate built cleanly with the required `/m:1`
  OpenMW build: zero errors and zero warnings. The initial build process was
  allowed to finish before a single serial verification build confirmed the
  linked `openmw.exe`; no competing PDB build, game launch, or capture occurred.
  Next bite: stage the exact binary under a new runtime root, then pass the
  mandatory idle/runtime gate before one public C04 contact capture. D02
  remains IN PROGRESS.

- The new hand-extension binary is staged without overwriting a prior runtime
  at
  `local/openmw-real-save330-physical-hand-extension-20260803-042300`.
  Its `openmw.exe` is 81,370,112 bytes, SHA-256
  `692A63917F68701606E76E27F737203FDA7F131CC7B1619518054A27EE8718D0`,
  has zero PDB files, and retains `resources` plus `osgPlugins-3.6.5`. No game
  launched during staging. Next bite: mandatory `-RuntimeReady -RequireIdle`
  preflight, then one non-overwriting public C04 capture for direct contact and
  seam review. D02 remains IN PROGRESS.

- The mandatory background-capture gate passed 54/54 with `-RuntimeReady
  -RequireIdle` for the hand-extension runtime and exact C04 MAP-selection
  route; neither retail nor OpenMW was running. Next bite: exactly one public,
  non-overwriting OpenMW C04 capture through the approved entry point, followed
  by direct review of the ScrollKnob contact and both cuff joins. D02 remains
  IN PROGRESS.

- The public, non-overwriting C04 hand-extension capture completed at
  `run/fnv-real-save-campaign/c04-openmw-20260803-042400-physical-hand-extension`
  with the normal runner pass, four unique native frames, telemetry, and no
  foreground automation. The production telemetry proves the existing skinned
  right hand solved against the authored `ScrollKnob` (`terminalFinger=Bip01 R
  Finger12`, `contactSolved=1`), but direct review rejects its contact frame:
  `ScreenCaptureHandler` was requested in engine frame 488 and the pose solver
  ran in frame 489. The retained native image therefore predates the new pose
  and still shows the parked hand and unresolved cuff joins. Next bite: defer
  only the C04 contact capture until the real hand pose has crossed a render
  update, then make a fresh no-overwrite capture and inspect it before changing
  seam geometry. D02 remains IN PROGRESS.

- C04 now records the observed contact pulse as a scheduled state, waits two
  proof-ready frames for the real player-skeleton hand solve plus a render
  boundary, and only then asks `ScreenCaptureHandler` for
  `map-world-toggle-contact`. The native-frame log carries
  `captureAfterHandPose=1`; the MAP/WORLD action, marker state, screen, and
  extension geometry are otherwise unchanged. Next bite: serial-build this
  capture-provenance correction, stage a fresh runtime, then run the mandatory
  idle gate and one fresh C04 contact capture for direct visual review. D02
  remains IN PROGRESS.

- The C04 post-hand-pose capture correction built successfully with the single
  required `/m:1` OpenMW build (zero warnings, zero errors). No game launched
  and no runtime or proof directory was overwritten. Next bite: stage this
  exact binary under a new runtime root, verify its hash and supporting files,
  then run the mandatory idle/runtime gate before one fresh C04 capture. D02
  remains IN PROGRESS.

- The post-pose runtime is staged without overwriting any prior root at
  `local/openmw-real-save330-contact-post-pose-20260803-043100`. Its
  `openmw.exe` is 81,370,112 bytes, SHA-256
  `2C4F5F379EFEB5F4744640AF7B4391D3BAC1E3D8639ACEA9E9C9E1AAB392A618`, with
  zero PDB files and intact `resources` plus `osgPlugins-3.6.5`. Next bite:
  pass the mandatory `-RuntimeReady -RequireIdle` gate, then make one fresh
  public C04 capture and directly inspect the post-pose contact frame. D02
  remains IN PROGRESS.

- User-directed visual recovery supersedes the queued C04 proof retry: no new
  C04 harness capture is made from the staged post-pose runtime. Read-only
  attachment telemetry from the retained native run isolates the actual visual
  defect: Save330's left `LeftHandPipboyGlove1st.NIF` was mounted through
  `Bip01 L Hand` while the glove cuff and the retained VaultSuit `Arms`
  partition share `Bip01 L ForeTwist`; the contact seam was 3.94 units on the
  left versus 0.10 on the right. The production attachment now selects the
  authored L ForeTwist bind-frame helper for that one worn glove while generic
  left/right bare hands retain their normal hand bind frames. Next bite: one
  serial build, then a normal playable OpenMW session and direct visual review;
  do not resume C04 harness work before the visible cuff is corrected. D02
  remains IN PROGRESS.

- The authored left-glove bind-frame correction compiled and linked in the
  required single `/m:1` OpenMW build. There were zero errors; MSBuild emitted
  one pre-existing precompiled-header option-consistency warning for
  `esm4npcanimation.cpp`, not an attachment or link failure. Next bite: stage
  this exact production binary in a fresh runtime and use a normal playable
  route for direct cuff/hand review; no C04 harness retry is authorized before
  that visual result. D02 remains IN PROGRESS.

- The left-glove ForeTwist runtime is staged without overwriting prior runtimes
  at `local/openmw-real-save330-left-glove-foretwist-20260803-043700`. Its
  `openmw.exe` is 81,370,112 bytes, SHA-256
  `BBB6B310E675A0A7C67339373883CC500E34A8B5BDC13EAE5D0CA4896CF57CF6`, with
  zero PDB files and intact `resources` plus `osgPlugins-3.6.5`. Next bite:
  choose the existing normal playable Save330 route, pass the mandatory idle
  gate, and capture one short non-overwriting direct visual review only after
  that normal route is ready. D02 remains IN PROGRESS.

- The mandatory `-RuntimeReady -RequireIdle` gate passed 54/54 for the staged
  left-glove runtime and existing real Save330 production MAP route; both
  games were idle. This is the one direct in-game visual-review launch for the
  authored cuff correction, not a resumed C04 proof iteration. Next bite: one
  public non-overwriting OpenMW launch, then inspect its native contact frame
  before changing the geometry again. D02 remains IN PROGRESS.

- The one direct native visual-review launch passed its transport and policy
  checks at `run/fnv-real-save-campaign/visual-left-glove-foretwist-20260803-043800`.
  Direct inspection rejects the left-glove attachment hypothesis: the left
  seam metric remained about 3.94 and the visible right hand reached a
  lower-right phantom point rather than the rendered ScrollKnob. The glove
  change has been removed. The actual hand defect is now corrected in the
  production solver: it retains the authored local pivot only for provenance
  and targets `getNodeWorldMatrix(controlRoot).getTrans()`â€”the live ScrollKnob
  world pointâ€”rather than composing that pivot through the device a second
  time. Next bite: serial-build this direct control-target correction and take
  one normal in-game visual review; no further bind-frame guesses. D02 remains
  IN PROGRESS.

- User-established canonical constraint: every first-person, third-person, and
  Pip-Boy animation must be driven by verified retail data. The un-staged
  direct-control-target solver is rejected and will not be launched. The
  executable path now returns through the retail held-waver or, only if that
  asset is absent, the authored retail manipulation KF; it no longer executes
  the generated hand reach. No game was launched for this correction. The
  remaining dead procedural source and C++-animated Pip-Boy controls are being
  removed before the next build. D02 remains IN PROGRESS.

- The procedural Pip-Boy source removal is complete: there is no generated
  Pip-Boy arm IK, duplicate interaction hand, synthetic knob/button/glow
  animation, or direct C++ transform of a retail control. The canonical
  interaction path plays the verified held waver; the only fallback is the
  authored retail manipulation KF when that waver cannot bind. The Pip-Boy
  body and its controls retain their NIF/controller transforms. No game was
  launched. Next bite: add a deterministic source/asset validator and then
  serial-build this canonical retail-data-only baseline. D02 remains IN
  PROGRESS.

- The deterministic retail-animation validator is now part of the existing
  data-driven UI contract and C04 validator. It requires the authored
  `pipboy-arm` NIF plus first-person `pipboy.kf`, held
  `1stPPipboyWaver.kf`, and fallback `pipboymanipulate.kf`, while rejecting
  every removed generated-hand/control symbol. PowerShell parser validation
  and the focused rule both pass (6 required, 5 forbidden needles). The full
  pre-existing UI-contract invocation remains unrelatedly red on two stale
  `windowmanagerimp.cpp` proof needles; those dirty-worktree failures were not
  changed. No game was launched. Next bite: serial-build the retail-data-only
  baseline. D02 remains IN PROGRESS.

- The required `/m:1` RelWithDebInfo OpenMW build of the retail-data-only
  baseline succeeded with zero errors. It emitted one existing
  `esm4npcanimation.cpp` C4653 precompiled-header option-consistency warning.
  No runtime was staged or launched from that build yet. Next bite: stage one
  fresh no-PDB runtime, verify its hash/resources, then resume the D02
  production weapon route rather than another Pip-Boy visual harness. D02
  remains IN PROGRESS.

- The retail-data-only executable is staged at
  `local/openmw-real-save330-retail-data-only-20260803-050200` without
  overwriting a prior runtime. Its `openmw.exe` is 81,347,584 bytes,
  SHA-256 `19AFFCD0C76C16E5E20016BD6BE3AB92A9CB4BBC2C5595260A86D9A850693530`,
  with zero PDBs and intact `resources`, `osgPlugins-3.6.5`, and
  `components-tests.exe`. No game was launched. Next bite: inspect/validate
  the already-implemented D02 production route against this stage before a
  single evidence launch. D02 remains IN PROGRESS.

- `scripts/Test-FNVRealSaveD02.ps1` is the deterministic D02 validator.
  It hash-locks the fixture and staged binary, requires ten distinct native
  source/named frames plus exact-title video, validates all ten restored
  `SortFilterItemModel` WEAP rows through the normal inventory activation,
  production reload, production close, live right-slot/ammo/model/HUD audit,
  and checks for no host input or unlock shortcuts. Its PowerShell parser and
  six route-critical proof needles pass. No game was launched. Next bite:
  pass the mandatory idle preflight and run one non-overwriting D02 evidence
  capture from the retail-data-only stage. D02 remains IN PROGRESS.

- The first public D02 capture is retained as a failed diagnostic at
  `run/fnv-real-save-campaign/d02-openmw-retail-data-only-20260803-050500`.
  Preflight passed 54/54 and the ordinary load, restored ten-weapon roster,
  normal WEAP-row activation, Pip-Boy close, HUD, fixture hash, and recording
  policy all passed. It correctly stopped before evidence because the first
  10mm pistol audit had no selected ammo and
  `reloadFalloutWeapon` rejected the still-stale controller as
  `weapon-state-not-reloadable`; zero native D02 frames were promoted. This
  is a production state-synchronization defect, not a visual or capture
  failure. No retry is authorized until the normal post-equip mechanics state
  update is added and built. D02 remains IN PROGRESS.

- D02 now calls the existing production
  `MechanicsManager::forceStateUpdate` immediately after the normal
  `InventoryWindow::onItemSelected` equip callback, before attempting the
  existing production reload. It does not write ammo, mutate a weapon slot,
  or synthesize animation. The D02 validator requires this transition for all
  ten weapons. The required `/m:1` build succeeded with zero warnings and
  zero errors; the validator parser and four production-state proof needles
  pass. No runtime has been staged or launched from this build yet. Next bite:
  stage a fresh no-PDB runtime and retry D02 once. D02 remains IN PROGRESS.

- The state-sync build is staged at
  `local/openmw-real-save330-retail-data-only-d02-state-sync-20260803-051100`
  without overwriting the failed-capture runtime. Its `openmw.exe` is
  81,347,584 bytes, SHA-256
  `2B948E783AE169E968AA3ACEF155BA466A238AA59EEF5D9141AF6E6D850CDBC8`,
  with zero PDBs and intact `resources` and `osgPlugins-3.6.5`. Next bite:
  mandatory idle preflight, then one non-overwriting D02 retry with this exact
  stage. D02 remains IN PROGRESS.

- The state-sync retry is retained as a failed diagnostic at
  `run/fnv-real-save-campaign/d02-openmw-state-sync-20260803-052000`.
  Mandatory preflight again passed 54/54, but OpenMW exited after 18.2 seconds
  before the required ten native D02 frames were written. The exact-title video,
  state artifact, and 1,710,991-byte engine log were preserved; no native frame
  was promoted and no success is claimed. Next bite: inspect the terminal
  engine-exit trace and correct only the demonstrated production defect before
  another capture. D02 remains IN PROGRESS.

- D02 diagnosis identified a real production data-bridge omission: the normal
  Lua-backed Pip-Boy `InventoryWindow::onItemSelected` path reaches
  `ActionEquip::executeImp` and changes `Slot_CarriedRight`, but did not update
  the live Fallout NPC equipped-weapon record read by the character controller.
  The shared `ActionEquip` action now mirrors the resulting right-hand ESM4
  weapon into that record for Fallout NPCs; the D02 hook only waits for that
  production bridge, closes the Pip-Boy, then asks the ordinary controller to
  consume it before normal reload. It performs no direct slot, ammo, equipped
  record, or animation write. The retry timing is widened to 135 frames per
  weapon and the deterministic validator now requires the shared bridge,
  actual closed menu, controller update, reload, and ten native frames. No
  runtime has been built or launched from this correction. Next bite: parser
  checks and one serialized build. D02 remains IN PROGRESS.

- Parser checks for the D02 validator and capture runner pass. The required
  `/m:1` RelWithDebInfo OpenMW build of the shared `ActionEquip` bridge and
  corrected D02 lifecycle succeeded with zero warnings and zero errors. No
  runtime or proof directory was overwritten. Next bite: stage a new no-PDB
  runtime, hash it, then run exactly one preflighted D02 capture. D02 remains
  IN PROGRESS.

- The shared-bridge build is staged, without overwriting an earlier runtime,
  at `local/openmw-real-save330-retail-data-only-d02-actionequip-bridge-20260803-052600`.
  Its `openmw.exe` is 81,352,704 bytes, SHA-256
  `D1A7DF4B35323B2CBA3624E6DE640530FD2387DBD2A5F7CFFE85D37BB4BFBF60`,
  with zero PDBs and intact `resources` and `osgPlugins-3.6.5`. No game has
  launched from this stage. Next bite: run the mandatory idle preflight and,
  only if it passes, one non-overwriting D02 capture. D02 remains IN PROGRESS.

- The `d02-openmw-actionequip-bridge-20260803-052900` capture is retained as
  a failed diagnostic. Mandatory preflight passed 54/54; the normal WEAP-row
  callback placed the 10mm pistol in `Slot_CarriedRight`, then D02 exited with
  `bad cast class MWWorld::CustomData * __ptr64 to ESM4NpcCustomData` before
  a native frame. The error was in the D02 harness assumption, not an asset or
  timing issue: the canonical FNV Player is OpenMW's ordinary ESM3 Player and
  cannot read the placed-NPC-only `ESM4NpcCustomData` cache. The speculative
  NPC-cache bridge was removed. The controller now recognizes the initialized
  native Fallout Player and derives its selected ESM4 weapon from the ordinary
  carried-right inventory slot; D02 observes that same normal slot before its
  production controller update. PowerShell parser and whitespace checks pass,
  and the required `/m:1` RelWithDebInfo build succeeded with zero warnings
  and zero errors. No runtime has been staged or launched from this correction.
  Next bite: stage a fresh no-PDB runtime, preflight it, and run one D02
  capture. D02 remains IN PROGRESS.

- The Player-slot correction is staged, without overwriting an earlier runtime,
  at `local/openmw-real-save330-retail-data-only-d02-player-slot-20260803-054100`.
  Its `openmw.exe` is 81,352,704 bytes, SHA-256
  `B51B548CCEF6A6DF7A4ADB58842E4E73479331F53EC14D53FA6B1692D1ACAD92`,
  with zero PDBs and intact `resources` and `osgPlugins-3.6.5`. No game has
  launched from this stage. Next bite: mandatory idle preflight, then exactly
  one non-overwriting D02 capture. D02 remains IN PROGRESS.

- The `d02-openmw-player-slot-20260803-054400` capture is retained as a second
  failed diagnostic. Preflight again passed 54/54. Unlike the prior run, the
  normal carried-right selection, close, controller update, reload call, and
  native audit all passed for the 10mm pistol and baseball bat; two distinct
  native frames were written before the BB gun gate failed. Its live state was
  exact right-slot/model/HUD with no selected BB ammunition, no compatible
  reserve, and the ordinary `reloadFalloutWeapon` rejection (`requested=0`).
  That is canonical no-ammo behavior for this Save330 inventory, not a reason
  to synthesize ammo. D02 now accepts only that explicit no-reserve rejection,
  while still requiring a selected compatible reserve, positive post-reload
  magazine, and production reload success whenever compatible ammunition is
  actually present. PowerShell parser and whitespace checks pass. No build or
  capture has been run from this correction. Next bite: serial-build it and
  retry D02 once with a new runtime/proof directory. D02 remains IN PROGRESS.

- The canonical no-ammo policy correction is built and staged, without
  overwriting an earlier runtime, at
  `local/openmw-real-save330-retail-data-only-d02-ammo-policy-20260803-054700`.
  Its `openmw.exe` is 81,353,216 bytes, SHA-256
  `E7FBC2F3D80F3280543CBABC7FFFFD5F6EB8841D338376AEAC98860762F47838`,
  with zero PDBs and intact `resources` and `osgPlugins-3.6.5`. The policy
  distinguishes actual compatible reserve from canonical no-reserve rather
  than fabricating an AMMO record or magazine. No game has launched from this
  stage. Next bite: mandatory idle preflight, then exactly one non-overwriting
  D02 capture. D02 remains IN PROGRESS.

- The preflighted `d02-openmw-ammo-policy-20260803-055000` capture is retained
  as a failed diagnostic. Readiness passed 54/54 and the first two ordinary
  weapon rows completed with native frames. The BB Gun then exposed the actual
  remaining production defect: its restored inventory has compatible reserve
  ammunition, but no compatible ammunition was selected before the normal
  reload (`ammoState=missing-selection`, `hasCompatibleReserve=1`,
  `reloadRequested=0`). The engine exited cleanly through the D02 gate; no
  success is claimed, no proof was promoted, and no second capture is
  authorized yet. Next bite: trace the existing production ammunition
  selection path and make it select only a compatible, restored reserve row
  before normal reload. D02 remains IN PROGRESS.

- The trace proved that the compatible BB reserve was not missing; the normal
  reload was invoked while the controller still owned the previous weapon's
  authored unequip transition. `CharacterController::reloadFalloutWeapon` now
  queues that ordinary request through the existing equip/unequip lifecycle,
  and D02 waits for the real selection/magazine result instead of writing one.
  The D02 validator now requires both source facts. Parser and whitespace
  checks passed, and the required `/m:1` RelWithDebInfo OpenMW build succeeded
  with zero warnings and zero errors. No runtime has been staged or launched
  from this correction. Next bite: stage a fresh no-PDB runtime, preflight it,
  then run exactly one non-overwriting D02 capture. D02 remains IN PROGRESS.

- The queued-transition correction is staged, without overwriting an earlier
  runtime, at
  `local/openmw-real-save330-retail-data-only-d02-transition-queue-20260803-055500`.
  Its `openmw.exe` is 81,353,216 bytes, SHA-256
  `0DBEA35EB8E1E3BFD1F870AB2A47B299F539B65AECDC7C8B918673F4C6AACF4F`,
  with zero PDBs and intact `resources` and `osgPlugins-3.6.5`. No game has
  launched from this stage. Next bite: mandatory idle preflight, then exactly
  one non-overwriting D02 capture. D02 remains IN PROGRESS.

- The preflighted `d02-openmw-transition-queue-20260803-055800` OpenMW-only
  capture passed after 54/54 readiness checks. It retained the immutable
  Save330 source hash, the staged no-PDB runtime hash, ten distinct named
  native D02 frames, ten distinct native-source frames, telemetry, and the
  32,435,865-byte exact-title raw video. Capture policy reports no host
  control, no foreground activation/input, sequential execution, and no
  overwrite. Next bite: run the deterministic D02 validator before visual
  inspection or promotion. D02 remains IN PROGRESS.

- The first deterministic validation attempt against that retained passing
  capture stopped before emitting an artifact because its PowerShell roster
  used ordered dictionaries with `Select-Object -ExpandProperty`, which does
  not expose dictionary keys as properties. This is validator-only evidence
  plumbing, not a game, runtime, or capture failure. The capture remains
  immutable and will not be rerun. Next bite: make roster/audit rows explicit
  `PSCustomObject` values, parse-check the validator, then emit a fresh
  non-overwriting validation artifact. D02 remains IN PROGRESS.

- The corrected deterministic validator passed all 29 checks against the
  retained `d02-openmw-transition-queue-20260803-055800` evidence. Its
  non-overwriting artifact is
  `run/fnv-real-save-campaign/d02-openmw-transition-queue-20260803-055800/d02-weapon-selection-validation.json`
  (62,935 bytes, SHA-256
  `A94DFF744A392B305FE73DF8E2721881ABFC4300B91075DEBE258809FAAEB63C`).
  Telemetry confirms the BB Gun waited on the queued production transition,
  then selected its restored compatible ammo and loaded 50 rounds without a
  direct D02 ammo/slot write. Next bite: inspect retained native frames and
  record only what they visibly prove before moving to the next plan gate.
  D02 remains IN PROGRESS pending visual/animation acceptance.

- Native-frame inspection after the validator confirms D02's narrow behavioral
  result but does **not** promote visual acceptance: the sampled first-person
  frames still show a misplaced/occluding Pip-Boy-and-arm presentation, and
  the BB Gun source frame contains the next reopened ITEMS overlay rather than
  a clean post-close weapon frame. The ten-row production selection/reload
  evidence remains valid, but it is not evidence that cuff seams, second-hand
  contact, placement, first-person polish, or third-person animation are
  fixed. No visual success is claimed. Per the original bite queue, next work
  returns to A03's normalized player-state serialization and deterministic
  validator; no game is launched during A03. D02 remains IN PROGRESS pending
  separate visual/animation and capture-order acceptance.

- A read-only A03 audit supersedes that next-bite note: A03 was already fully
  complete on disk and must not be repeated. The immutable normalized-plan
  denominator remains
  `save330-player-denominator.json` (849,513 bytes, SHA-256
  `AE9B020591C5CC176E4A1A47BD9715CBF758E7BB3118A0376CFE4D2A05E92B92`),
  with the existing `save330-a03-validation.json` PASS artifact. Its ledger
  entry covers final totals, worn/equipped rows, actor-value modifiers, and
  exact provenance. No A03 source, denominator, or validation artifact was
  changed. Next bite returns directly to D02 visual/capture-order acceptance
  using existing retail NIF/KF/ESM bindings only.

- D02 visual-source correction: removed the remaining generated Pip-Boy
  control scene-graph path (`PipBoyPhysicalControl`, control locator, hard-coded
  pivots, and C++ node reparenting) from `esm4npcanimation.*`. The first-person
  Pip-Boy now leaves every device node in its retail NIF hierarchy. The same
  bite corrects the missing second hand by layering the verified retail
  `pipboymanipulate.kf` on `BlendMask_RightArm` during real Pip-Boy input while
  the verified `1stPPipboyWaver.kf` remains the held left-arm baseline. No
  procedural IK, duplicate hand, generated control rotation, or fabricated
  finger transform remains in that path; a targeted forbidden-symbol scan
  passed. `Test-FNVDataDrivenUiContract.ps1` currently stops on two pre-existing
  flat-pane string assertions in `windowmanagerimp.cpp` (not this renderer), so
  no broad contract pass is claimed and those unrelated dirty files were left
  untouched. No build, game launch, or capture has occurred from this bite.
  Next bite: serial-build the production executable, stage it separately, then
  run the mandatory preflight and one non-overwriting D02 visual/capture-order
  attempt.

- The required `/m:1` RelWithDebInfo `openmw` build for the D02 retail-two-arm
  correction completed successfully with zero errors. MSVC emitted one existing
  precompiled-header option-consistency warning on `esm4npcanimation.cpp`; no
  Pip-Boy compile or link error occurred. No runtime or proof directory was
  overwritten. Next bite: stage this exact executable in a new no-PDB runtime,
  then perform the required idle preflight before any capture.

- The retail-two-arm build is staged without overwriting an earlier runtime at
  `local/openmw-real-save330-retail-data-only-d02-retail-two-arm-20260803-060900`.
  Its `openmw.exe` is 81,344,000 bytes, SHA-256
  `0EDADBA0233D5218F1A9DF74E84A7A1615C1930154DB4B70804E6A9BBA3D644C`,
  with zero PDBs and intact `resources` and `osgPlugins-3.6.5`. The staging
  command emitted a non-terminating PowerShell `New-Item -LiteralPath` parameter
  warning before `robocopy` created the new target; the verified staged content
  above is from the successful `robocopy` copy (exit code 1 = files copied).
  No executable was launched. Next bite: the mandatory idle preflight against
  this exact staged runtime.

- The required 54/54 idle preflight passed, followed by one fresh, OpenMW-only,
  non-overwriting D02 capture at
  `run/fnv-real-save-campaign/d02-openmw-retail-two-arm-20260803-061000`.
  Capture policy passed with no host control, foreground activation/input,
  concurrency, or overwrite. The retained exact-title raw video is 33,865,113
  bytes (SHA-256
  `9AD4FDFD000216CC11925E0FCBF6A4E968D7EE88C9D7995649F4F5C7911B16BF`),
  and the deterministic D02 validator passed all 29 checks. Its new artifact is
  62,781 bytes (SHA-256
  `0FE1EF4ACAF5D3038767B2AE267AA3D34F0FB3B1BFA4CA1791B2E2D8F8A972B5`).
  Telemetry records ten real `retail-waver-plus-manipulate` input events and
  ten native world/source frames.

- Direct inspection rejects visual promotion again: the retained post-close
  native frames still show a detached bare right hand/Pip-Boy cuff and
  incorrectly assembled first-person weapons. The new retail two-arm clip is
  genuinely requested in production telemetry, but the D02 schedule only
  retains post-close frames, so it does not yet visibly prove the hand action.
  Inspection also disproved the suspected camera-frame cause: its branch is
  hard-disabled (`cameraLongGun = false`), so it was not changed. D02 remains
  IN PROGRESS. Next bite: use the existing C04 contact-frame capture contract
  to inspect the live retail Pip-Boy/map interaction and trace the actual
  skeleton/weapon animation binding defect; do not tune coordinates or invent
  a corrective transform.

- The fresh OpenMW-only C04 capture at
  run/fnv-real-save-campaign/c04-openmw-20260803-070000-retail-two-arm-dataonly
  retained four distinct native map frames, source-frame hashes, telemetry, and
  the 7,723,113-byte exact-title raw video (SHA-256
  CE5DBB31DC12C2AE47E022AB3905B4CEA1B0A1FE8CDA181A73F51ADAD2551012).
  The corrected non-overwriting C04 validator now passes all 47 checks against
  that immutable capture; its artifact is c04-validation-retail-two-arm.json
  (37,242 bytes, SHA-256
  A1DCDBB2F2A1759949D78D39F6F4A075C6EF423944D1A6A1011B45F9B7FEF6F7).
  This proves the production map rendered the restored Southern Passage icon,
  focused the exact discovered marker, and opened the real unconfirmed
  “Fast travel to Southern Passage?” confirmation. The validator update only
  accepted the intentional retail waver-plus-manipulate telemetry and
  post-hand-pose capture field; it did not alter the capture. Direct native
  frame review still rejects C04 visual acceptance: the contact and overview
  frames are visibly broken, and the focused/confirmation frames retain a
  skewed Pip-Boy/arm presentation. D02 and C04 both remain IN PROGRESS pending
  retail-source animation/binding diagnosis; no coordinate, mesh, or
  procedural-hand invention is authorized. Next bite: compare the retained
  retail scene-graph/frame data with the exact OpenMW retail-KF binding before
  changing production animation code.

- Retail source audit corrected the preceding two-arm conclusion. The retained
  xNVSE Save330 trace contains 595 first-person snapshots: ordinary MAP/WORLD
  navigation activates pipboy.kf for the raise and 1stPPipboyWaver.kf for the
  held pose, with zero pipboymanipulate.kf activations. The production
  interaction route therefore no longer binds or plays pipboymanipulate.kf,
  no longer labels a capture as post-hand-pose, and records the retail held
  state as waver plus resting right hand. The focused C04 source validator now
  forbids that non-observed overlay and generated hand/control paths.

- The required serial RelWithDebInfo build succeeded with zero errors and the
  usual one PCH option warning. A fresh no-PDB runtime was staged at
  local/openmw-real-save330-retail-waver-only-20260803-064700; openmw.exe is
  81,344,000 bytes with SHA-256
  4F202F7AAF02C4BCEAF50EF2E5C10F51428DF4FEED9160FAF150AB6A69B243F5,
  zero PDB files, resources, and osgPlugins-3.6.5. The required 55/55
  RuntimeReady and RequireIdle preflight passed. The single fresh OpenMW C04
  capture at
  run/fnv-real-save-campaign/c04-openmw-20260803-064900-retail-waver-only
  passed the public capture policy with no host control, foreground activation
  or input, concurrent game, or overwrite. Its updated deterministic C04
  validator passed all 47 checks; c04-validation-retail-waver-only.json is
  37,142 bytes with SHA-256
  A6444DE0037B148A1FFCFB315CD77760DE3037D9392D28B9DF9C7D6EC3349930.
  Native frames visibly remove the former giant detached right-arm contact
  geometry and show the restored Southern Passage icon, focused marker, and
  real fast-travel confirmation. They do not prove a hand-at-knob action,
  because that is not present in the captured retail route, and they do not
  yet constitute full cuff-seam, first/third-person, weapon, or overall visual
  acceptance. D02 and C04 remain IN PROGRESS. Next bite: compare retail and
  OpenMW device/hand attachment frames without introducing a transform, then
  repair only an evidence-backed binding defect.

- Retail timeline correction and fresh C04 evidence: the saved xNVSE trace
  shows `1stPPipboyWaver.kf` advancing at frequency 1 across its authored
  0-6 second range, rather than holding the earlier 0.196-second sample. The
  production route now starts that retail KF once, leaves its authored timing
  untouched, and retains its terminal pose without restarting it. The focused
  C04 validator permanently rejects the former timestamp pin, zero speed, and
  direct time write, alongside the already-forbidden fabricated manipulation
  path. The serial `/m:1` RelWithDebInfo build passed with zero errors (one
  existing PCH warning) and was staged at
  `local/openmw-real-save330-retail-waver-live-20260803-065856`; `openmw.exe`
  is 81,344,000 bytes, SHA-256
  `929D64C2EFF5C472C726AC4385CC19D70C7AC56A32849B2EBE43129FDD66A7B5`,
  with zero PDBs and intact resources/plugins. The first preflight call found
  only a stale default runtime path; the required explicit-runtime retry
  passed 54/54 with RuntimeReady and RequireIdle. One fresh OpenMW-only C04
  capture, with no overwrite or host input, is retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-070000-retail-waver-live`.
  Its 4,993,244-byte exact-title raw video has SHA-256
  `DA414E269594B3EC1D5E040A1C7B94533CCE47DA3CC194249AA41753618FCA8E`;
  the non-overwriting C04 validator passes 48/48 and its 37,916-byte artifact
  has SHA-256 `2B6EC19C155C43920ACC1E7801A4A55FF510D43637CB405CE2C11B75110CB7FF`.
  The native frames visibly show restored MAP icons, the exact Southern
  Passage selection, and the real confirmation. They also eliminate the
  previous giant detached synthetic hand. They show the retail-authored right
  hand in its resting navigation pose, not at a knob, consistent with the
  retail trace. This is not yet cuff-seam, first-person framing, third-person,
  or weapon visual acceptance; D02 and C04 remain IN PROGRESS. Next bite:
  proceed through C05's production confirmation/travel route with this
  canonical runtime while retaining the unresolved visual acceptance gate.

- C05 now passes on the same immutable Save330/runtime lane. The required
  explicit-runtime RuntimeReady/RequireIdle preflight passed 54/54, followed by
  exactly one fresh OpenMW-only public capture at
  `run/fnv-real-save-campaign/c05-openmw-20260803-070500-retail-waver-live`.
  It retained three native frames, telemetry, and the 4,255,626-byte
  exact-title video (SHA-256
  `FA3BA9196DC17B8FD5C72460AADA8544F36C831DD94D54D476708CFD83A4258D`)
  without host control, foreground activation/input, concurrency, or output
  reuse. The non-overwriting C05 validator passed 38/38; its 30,002-byte
  artifact has SHA-256
  `5EE43C08F164B8D2536B5D6CB77B642B9EED88673CB60DCCB0ACDF228305FF9C`.
  Production UI telemetry proves the restored `0x3008885` Southern Passage
  marker was selected, its real confirmation was confirmed, and the player
  arrived at cell `0x300688f`, worldspace `0x300683b`, grid `(-4,-11)`,
  position `(-13248,-42631.2,7719.86)`. Game time changed from 14.2223 to
  18.224; the menu closed, controls returned, and no shortcut/teleport path
  was present. Native review shows the confirmation and an authored rocky
  destination world frame. C05 is functionally PASS. D02/C04 visual acceptance
  remains separately IN PROGRESS; no broad visual success is claimed. Next
  bite: C06's production fast-travel rejection matrix.

- C06 passes on the canonical lane. The required 54/54 explicit-runtime
  RuntimeReady/RequireIdle preflight preceded one fresh OpenMW-only capture at
  `run/fnv-real-save-campaign/c06-openmw-20260803-071000-retail-waver-live`.
  It retained five distinct native rejection frames and a 3,973,803-byte
  exact-title video (SHA-256
  `5C0C0764D2FB6530FC9607CB82DF8AFBD840CE26BBA53E507C13A8118A862638`)
  under the no-host-control/no-overwrite policy. The non-overwriting C06
  validator passed 47/47; its 38,526-byte artifact has SHA-256
  `012BAE2EAA1F9C22838AF1C17620392BD584F5854B49870613FDA7B80A289E82`.
  The production UI rejected cancellation, disabled travel, enemies nearby,
  an undiscovered marker, and an invalid authored destination. Each retained
  its retail-shaped reason, unchanged player position/time, and an open usable
  map. Native frames visibly retain the message states. C06 is functionally
  PASS. D02/C04 visual acceptance is still separately IN PROGRESS; the frame
  review does not promote Pip-Boy framing/cuff polish. Next bite: C07 travel
  persistence.

- C07 travel persistence passes using the same staged runtime. After the
  required 54/54 preflight, one fresh public capture at
  `run/fnv-real-save-campaign/c07-openmw-20260803-071500-retail-waver-live`
  performed the production first travel, StateManager save, clean quit, cold
  reload of the generated `.omwsave`, MAP reopen, and a second production
  travel. It retained the generated 47,363-byte campaign save (SHA-256
  `18A2AFEF9B7C490D0668315C30F50FEDAC7164483FAFC2339B3FF9D6F988AE20`),
  six native frames, and two exact-title videos. The original validator
  artifact is retained as a failed diagnostic: it had a stale hard-coded
  runtime hash and demanded exact zero clock movement during an unpaused
  same-cell action. The production code accepts a same-cell arrival and normal
  simulation advanced only 0.0047 hours; the plan requires a second travel
  success, not a fabricated zero-time rule. The corrected validator is parsed,
  makes the supplied runtime hash-lock explicit, accepts only <=0.1 hours of
  normal same-cell simulation drift, and passes 60/60 against the immutable
  capture. Its non-overwriting r2 artifact is 605,012 bytes, SHA-256
  `F971D84F7E6235C1D4B59F7D2BE64CD0766CE79E69A8CEFBFA02803B13B57FAD`.
  The first arrival, saved/cold-reloaded cell/worldspace/position, marker state,
  and second arrival all agree; no source save mutation, TestMap, or host input
  occurred. C07 is functionally PASS. Native review still does not promote
  first-person Pip-Boy framing/cuff acceptance. Next bite: D01 complete
  Save330 inventory rendering.

- D01 was rerun on the same canonical retail-waver runtime after C07, using the
  fresh, OpenMW-only, non-overwriting capture
  `run/fnv-real-save-campaign/d01-openmw-20260803-072000-retail-waver-live`.
  The required route retained five distinct native ITEMS frames for WEAP, APP,
  AID, MISC, and AMMO and the 3,537,463-byte exact-title video
  `openmw/OpenMW-Save330-D01-inventory-exact-title-raw.mp4` (SHA-256
  `D60820497F20EA2CF3272B0BDE51C0E8AB764A07DB3EEB18D57C64910A8B566B`).
  `Test-FNVRealSaveD01.ps1` now validates the supplied staged runtime rather
  than a stale binary pin and passes all 39/39 checks. Its non-overwriting
  artifact is `d01-validation-retail-waver-live.json`, 232,399 bytes,
  SHA-256 `53FB7273B54459A2446C08D4C37FCBA3918179225E5CC982066F2079CF37A6DB`.
  Native-frame inspection confirms real supported Save330 rows across all five
  categories, including the source/provenance display. It does not promote
  first-person visual acceptance: the remaining Pip-Boy/arm/cuff presentation
  still needs a retail-source binding diagnosis. No synthetic hand, seam mesh,
  coordinate adjustment, or broad visual-success claim was introduced. D01 is
  functionally PASS; D02 remains IN PROGRESS pending the normal weapon matrix
  plus separately strict first-/third-person visual acceptance.

- D02 capture-order/telemetry correction: the prior D02 source advanced its
  counter and reopened the physical Pip-Boy as soon as it requested an
  asynchronous `ScreenCaptureHandler` write. It now reuses the existing C04
  sidecar screenshot contract: baseline the screenshot directory, require the
  new file path and byte count to be stable for two engine frames, retain the
  frame only then, and wait a 30-frame render drain before the next production
  ITEMS navigation. The requested `OPENMW_FNV_HAND_POSE_AUDIT` is now forwarded
  through the live first-person rig visitor; this is diagnostic only and does
  not alter an animation, mesh, pose, or transform. The required `/m:1`
  RelWithDebInfo build passed, and its new no-PDB runtime is
  `local/openmw-real-save330-d02-stable-frame-hand-audit-20260803-073823`
  (`openmw.exe`: 81,343,488 bytes, SHA-256
  `93761451A7DF1574B8EF54B1E30F77FA98EDB0C287FE208AD3AB55462AE48098`).
  The required explicit-runtime idle preflight passed 54/54, followed by one
  fresh OpenMW-only public capture at
  `run/fnv-real-save-campaign/d02-openmw-20260803-074000-stable-frame-hand-audit`.
  It retained ten distinct native source frames, the exact-title 35,951,982-byte
  video (SHA-256
  `D3462A5BB16F04C2A05CC2F7EAA0A4ECC0B33A9C40DC9BFD5E0E2D952C8EA053`),
  and no host input, focus, concurrency, or overwrite. The corrected
  deterministic validator passes 33/33; its non-overwriting r3 artifact is
  64,743 bytes, SHA-256
  `5D9CBE194AB9135A18A2766BC269E9B905A89F45C0302BF1C78E563748B90643`.
  The native files no longer contain the following ITEMS page, and telemetry
  confirms a real `RightHand:0` hand-pose audit. Direct native-frame inspection
  nevertheless rejects visual promotion: it still shows a white weapon mesh,
  detached/misaligned arms and cuffs, and incorrect weapon orientation. D02
  therefore remains IN PROGRESS. Next bite: compare the live first-/third-
  person attachment and weapon-frame bindings to the retail xNVSE trace before
  changing production rendering; do not tune a coordinate or invent a pose.

- 2026-08-03 — D02 retail source-binding diagnosis complete (no rendering
  change in this bite). The two malformed retail weapon-reference attempts are
  retained separately and were not reused: the first used a console-style
  equip route and the second supplied the OpenMW-normalized `0100434F` instead
  of the retail `FalloutNV.esm` form. The corrected, public-only retail xNVSE
  reference is
  `run/fnv-real-save-campaign/retail-save330-weapon-reference-20260803-080153`.
  Its passing report records `EquipExact 0000434F`, a real drawn 10mm state,
  native D3D9 frames, and normal Pip-Boy navigation; it deliberately does not
  claim a complete Pip-Boy close lifecycle. At snapshot `weapon-drawn` frame
  820, retail owns the weapon through `Weapon -> Bip01 Translate` and both
  first-person hand-skin roots are direct `Scene Root` children
  (`LeftHand (00025B83)` and `RightHand Caucasian (00000019)`). Retail's
  Pip-Boy remains an identity child of `Bip01 L ForeTwist`, with its recorded
  `PipBoyArm:0/:1` transform. OpenMW instead currently creates synthetic
  `FNV Animated L/R Hand Bind Frame` helpers beneath hand bones; this has no
  retail counterpart and is the trace-backed candidate for the detached cuff
  and bare-skin seam. Next bite: replace only that synthetic first-person
  hand-parent route with the retail scene-root route, then rebuild `/m:1` and
  re-run the existing D02 production capture/validator before judging frames.

- 2026-08-03 — D02 first-person hand-parent correction complete, but not
  visually promoted. The single production change in
  `apps/openmw/mwrender/esm4npcanimation.cpp` replaces the synthetic
  first-person `FNV Animated L/R Hand Bind Frame` route with the retail
  scene-root route for both hand skins; it introduces no transform, pose, mesh,
  or animation data. The `/m:1` RelWithDebInfo build passed (existing PCH
  warning only). Its fresh no-PDB stage is
  `local/openmw-real-save330-retail-hand-scene-root-20260803-081500`
  (`openmw.exe`: 81,343,488 bytes, SHA-256
  `A5302CEB2B069F5DF4539705D01CDFB17BFE92B6BB0366292F439B87B07D0E8B`).
  The D02 validator now requires both source and runtime confirmation of the
  retail parent route. The first fresh public capture at
  `run/fnv-real-save-campaign/d02-openmw-20260803-082000-retail-hand-scene-root`
  is retained as a configuration failure: public capture passed but omitted
  `-RealSaveHandPoseAudit`, so its validator recorded 34/35 with only the
  live-hand-audit check failing. After a new 54/54 idle preflight, the separate
  public-only capture at
  `run/fnv-real-save-campaign/d02-openmw-20260803-083000-retail-hand-scene-root-audit`
  passed with no host control, focus, concurrent capture, or overwrite; its
  report and summary hashes are respectively
  `0F2E41616B668CBD3751287E55E3E75F87560B85C0D058A4A2F2B42E018360FF` and
  `EB1C90643A9DAECF6B7C8C4BA6B93A919857A1E5A06D4DBC205212E4801A3279`.
  The strengthened deterministic validator passes 35/35
  (`d02-validation-retail-hand-scene-root-r2.json`: 65,820 bytes, SHA-256
  `699ADF5A3E894DE141AC6D4CCA7D847C7EAF3735F29A1E92B567C3EDD729C5F7`), and
  the exact-title video is 20,884,365 bytes (SHA-256
  `FAB902923D3ED1905B9E73011E8B719B42B3CE9484FEAE05D46754C9E3E1F2E4`).
  Native-frame inspection still rejects visual promotion: a white weapon quad
  remains in weapon row 03 and the weapon family poses are visibly wrong in
  scale/orientation. The hand-parent change is therefore only a validated
  source-parity correction, not a cuff/Pip-Boy/weapon visual pass. Next bite:
  compare the live OpenMW `Weapon` node's post-KF transform and weapon NIF
  parentage to the retail xNVSE 10mm reference, then correct only a measured
  data-path mismatch.

- 2026-08-03 — D02 independent-retail-sequence correction complete, but
  visually rejected. The first-person startup source now keeps retail
  `mtidle.kf` independent instead of merging a synthetic-at-startup unarmed
  `h2haim` controller; the live `weaponpose` state supplies the authored
  `1hpaim.kf` through the existing production controller. No pose, transform,
  mesh, IK, or timing value was added. The `/m:1` RelWithDebInfo build passed
  (existing PCH warning only) and staged
  `local/openmw-real-save330-retail-separate-mtidle-20260803-081700`
  (`openmw.exe`: 81,343,488 bytes, SHA-256
  `45B7B39C2ABB543A401EF9D7C6534A4B8D4C23B076F407A1925338961EE40A50`).
  After the required 54/54 RuntimeReady/RequireIdle preflight, the one fresh,
  OpenMW-only public capture at
  `run/fnv-real-save-campaign/d02-openmw-20260803-084000-retail-separate-mtidle`
  passed the capture contract with hand-pose audit enabled, no host control,
  focus/input, concurrent capture, or output reuse. The deterministic
  validator passes 37/37
  (`d02-validation-retail-separate-mtidle-r3.json`: 66,132 bytes, SHA-256
  `9175A4346BE46EEB13F1C3DA4C00AA6A1F082037EA4CDAA7CC0603B9103B6BF6`);
  the exact-title video is 19,828,073 bytes (SHA-256
  `7C5BBBF73027EEC28112D0DDDDB7E84055E42479B41493A302E6A3DD5354F6C9`).
  Direct inspection of native frames 00/02/03/05/07/09 rejects promotion:
  after the early edge of the draw, the first-person hand and 10mm are absent
  rather than rendered in a retail-like held state. This proves only that the
  independent authored-sequence route is selected; it is not a visual pass
  and does not address the cuff, Pip-Boy framing, or third-person gates. Next
  bite: add observational telemetry for the live post-KF `Bip01 Translate`,
  `Weapon`, and weapon-NIF parent/world transforms, compare them directly to
  the retail xNVSE snapshot, and change only the resulting measured
  production-data mismatch.

- 2026-08-03 — D02 post-KF production audit and authored-asset diagnosis
  complete; no visual promotion and no production pose change in this bite.
  A read-only `OPENMW_FNV_HAND_POSE_AUDIT` telemetry hook now records the live
  post-KF Weapon node, parent, raw/effective transform, direct weapon-part
  relation, node mask, and renderability only after the production Pip-Boy
  presentation update. The `/m:1` build passed (existing PCH warning only);
  its fresh no-PDB runtime is
  `local/openmw-real-save330-retail-post-kf-audit-20260803-085500`
  (`openmw.exe`: 81,343,488 bytes, SHA-256
  `DA5C3B18B5FA29486DE9D41A7C08034E8533DAE8A7AE33EBC7B315A4DB0417A0`).
  The required 53/53 RuntimeReady/RequireIdle preflight preceded one fresh,
  OpenMW-only public capture at
  `run/fnv-real-save-campaign/d02-openmw-20260803-090000-post-kf-audit`;
  that capture itself passed with no host controls, concurrent capture, or
  overwrite, and retained the exact-title video (19,347,625 bytes, SHA-256
  `14E5841E083634C472A65D6B6A7B3A121CD6ED20A686F3381821C05D20F7E1EE`).
  Its r4 validator is intentionally retained as a FAIL artifact: its sole
  failing rule incorrectly treated the raw skeleton's `Weapon -> Bip01 R Hand`
  helper as retail's active render mount. The audit did not hide that failure.

  The existing `/m:1` `bsatool` and `niftest` were then used read-only against
  a fresh retail asset audit directory,
  `run/fnv-real-save-campaign/d02-authored-asset-audit-20260803-090700`.
  The immutable BSA extraction locks `_1stperson/skeleton.nif` to SHA-256
  `3FE5A3EF9718C8BFF773B328C93BF6E522E85B16AFD0DE1B9AF33CFBA550B121`,
  `mtidle.kf` to `867FFE07BE8CA6F7A7F0FE11111A4EE8591F06DB4B929673B976BCD64D6384E1`,
  and `1hpaim.kf` to `8C0FD1AFD0D99C70CFEBD224FBF1AF48442D4BD1C16C19B097316A8CA591248B`.
  The raw skeleton contains an internal `Weapon -> Bip01 R Hand` helper, but
  the retail xNVSE graph proves that the actual drawn render mount is reparented
  from `Bip01 R ForeTwist` to an identity-named `Weapon` direct child of
  `Bip01 Translate` at frame 662; its 1hpaim track reaches the recorded
  `8.67439365,2.21316123,1.06902444` local transform by frame 670. OpenMW
  currently attaches the rendered weapon to the internal helper, explaining
  why a correct KF track can still be visibly absent. Next bite: reproduce
  only that retail dynamic render-mount topology, bind the existing `Weapon`
  KF target to it, and attach the existing weapon NIF as its identity child;
  do not supply any transform, pose, or timing value by hand.

- 2026-08-03 — D02 retail dynamic-weapon-mount source bite compiled, but its
  first capture did not launch and is not evidence. The production source now
  creates an identity `Weapon` MatrixTransform directly below `Bip01 Translate`,
  overrides the existing KF node map entry to that live mount, and attaches the
  selected weapon NIF beneath it; retail’s existing `1hpaim.kf` remains the
  sole transform and timing owner. No placement, pose, IK, mesh, or timing
  value was introduced. The serialized `/m:1` RelWithDebInfo build passed
  (the existing PCH warning only), producing `openmw.exe` SHA-256
  `BDAF8C0C41A18E025ECE0D3F78D0489668236B02FBAF4C2A3E7FE3E85EDA8BDE`.
  The required OpenMW RuntimeReady/RequireIdle preflight passed 53/53 before
  the one public capture invocation. That runner then rejected the fresh
  proof directory
  `run/fnv-real-save-campaign/d02-openmw-20260803-085600-dynamic-weapon-mount`
  before gameplay because the staged runtime
  `local/openmw-real-save330-retail-dynamic-weapon-mount-20260803-085454`
  lacked `osgPlugins-3.6.5/osgdb_dds.dll`. Its retained report explicitly
  records no source frames, telemetry, or title video and no host control,
  focus, or injected input. The failed proof directory is preserved. Next
  bite: stage the same built executable into a complete canonical packaged
  runtime, run a new required preflight, and capture only to a new directory.

- 2026-08-03 — D02 complete-runtime dynamic-mount capture completed and is
  functionally validated but visually rejected. The rebuilt executable was
  staged only into the complete C07 runtime envelope at
  `local/openmw-real-save330-retail-dynamic-weapon-mount-complete-20260803-085645`
  (no PDB; `openmw.exe` SHA-256
  `BDAF8C0C41A18E025ECE0D3F78D0489668236B02FBAF4C2A3E7FE3E85EDA8BDE`).
  The required RuntimeReady/RequireIdle preflight passed 53/53, then the one
  fresh OpenMW-only public capture at
  `run/fnv-real-save-campaign/d02-openmw-20260803-085700-dynamic-weapon-mount-complete`
  passed the unattended capture contract: ten native frames, telemetry, and
  the 19,443,377-byte exact-title video (SHA-256
  `AE3C010A71CE131C97BEA8EF87790EA22B5CB27C6AA44B58E09A95CC55E17BAC`),
  with no host control, focus/input injection, concurrent capture, or output
  reuse. Its deterministic r5 validator passes 39/39
  (`d02-validation-dynamic-weapon-mount-r5.json`: 67,565 bytes, SHA-256
  `D61CB4F1A464EE0ED7D069A29163B871CA10B38BEEDA79C12C20BA258363A813`).

  That is not a visual promotion. Direct inspection of native frames
  00/03/06/09 still shows empty world frames except for an oversized forearm
  and fist in frame 06; no usable 10mm is visible. The retained post-KF
  telemetry proves the new parent chain exists, but it also exposes the
  real production-data failure: vanilla 10mm remains at identity rather than
  the retail 1hpaim held transform, while the following nine weapon rows have
  zero scale despite being marked renderable. The current generic runtime
  `osg::MatrixTransform` mount therefore does not preserve the decoder's
  authored transform-channel semantics. No corrective matrix was applied.
  Next bite: trace the exact NIF transform-node type and controller binding
  used by the existing decoder, replace the generic mount with that compatible
  runtime representation only, and strengthen the validator to reject zero
  scales and a missing retail 10mm post-KF transform before another capture.

- 2026-08-03 — D02 NIF-channel compatibility diagnosis and strict gate added;
  no game was launched in this diagnostic bite. OpenMW's existing
  `NifOsg::KeyframeController` takes a `NifOsg::MatrixTransform*` and updates
  decomposed rotation/scale fields. The generic `osg::MatrixTransform` used by
  the prior dynamic mount therefore could not safely receive the authored KF
  callback. The mount now uses the engine's own
  `NifOsg::MatrixTransform(Nif::NiTransform::getIdentity())`: this is the
  canonical NIF identity representation required by the controller, not a
  chosen placement matrix. The D02 validator was strengthened to require ten
  nondegenerate finite unit-scale post-KF mounts and the exact retail xNVSE
  vanilla-10mm terminal translation
  `(8.67439365, 2.21316123, 1.06902444)` after Pip-Boy close. Re-running it
  against the retained prior capture intentionally fails only those two new
  checks (39/41), preserving
  `d02-validation-dynamic-weapon-mount-r6-pre-nif-transform.json` (87,615
  bytes, SHA-256
  `C42F0A740946A73F9A281FF55A45BD04A18D7199872DCB73A873B7132811676C`).
  Next bite: build the NIF-compatible mount with `/m:1`, stage it into a new
  complete no-PDB runtime, preflight, capture once through the public runner,
  and require the new scale and 10mm gates before visual review.

- 2026-08-03 — D02 NIF-compatible-mount capture is retained as a strict
  partial result, not a visual or gameplay pass. The serialized `/m:1`
  RelWithDebInfo build staged a complete no-PDB runtime at
  `local/openmw-real-save330-retail-nif-weapon-mount-20260803-090617`
  (`openmw.exe`: 81,351,168 bytes, SHA-256
  `5AAC696D22D24A502785D381325E6925196F0107D452394275C905F8D57BE5BA`).
  The required 53/53 RuntimeReady/RequireIdle preflight preceded the one fresh
  OpenMW-only public capture at
  `run/fnv-real-save-campaign/d02-openmw-20260803-090700-nif-weapon-mount`.
  Its summary is 23,109 bytes (SHA-256
  `BE51C99EB1A238074C882952FBF56CC815BAB9EC5AACCCD1ED1FFF49A8E584F5`),
  and its exact-title video is 19,483,623 bytes (SHA-256
  `59B94C85515522E1AA61D06111C1FAEE848D0769415D487DCEADE6AA143F0D74`);
  the public contract reports no host control, focus/input injection,
  concurrent capture, or proof-directory reuse.

  This capture proves the NIF channel correction: all ten post-KF weapon
  mounts retain finite unit scale and the nine later rows receive their
  authored transforms. It is not promoted. The initial vanilla 10mm audit was
  taken while its dynamic mount was still identity, before the normal
  first-person `weaponpose` controller had applied the existing `1hpaim.kf`.
  The initial r7 validator failure was a path-matcher defect (`Weapons\\...`
  rather than `meshes\\Weapons\\...`) and is retained at 86,613 bytes
  (SHA-256 `700C266BF5FDEF46D37D07888A3DCF627C14CF7F1FDE2DDCA32CC85413BBC98D`).
  After correcting only that validator matcher, r8 correctly passes 40/41 and
  fails only the exact retail vanilla-10mm terminal-translation gate; it is
  retained at `d02-validation-nif-weapon-mount-r8-pre-pose-settle.json`
  (87,747 bytes, SHA-256
  `44DBB994FADE5759489825F02EA8AA07AF5A558E573E0CCEC8136F3DB13ABF19`).
  Next bite: replace the fixed audit-clock condition with a read-only,
  production-controller/scene-state readiness condition, then recapture to a
  new proof directory. No coordinate, pose, IK, or animation value may be
  added.

- 2026-08-03 — D02 capture scheduling now advances from observed retail-data
  state, not from the former per-weapon slot clock. In
  `apps/openmw/engine.cpp`, the next restored weapon is selected only after
  the prior stable native frame and render drain complete. Before any audit,
  the hook observes the ordinary first-person animation object: a non-empty
  authored `weaponpose` source, active right-arm `weaponpose`, the visible
  direct `Weapon -> weapon part` relation under `Bip01 Translate`, a
  non-identity authored local transform, and two identical observed local
  matrices. The hook does not play, seek, or transform anything; it emits a
  pass/fail telemetry row only when those production facts are true.

  `scripts/Test-FNVRealSaveD02.ps1` now rejects a fixed audit/reopen countdown
  or any corrective matrix/rotation/translation/scale call, requires ten
  observed-pose rows, and requires each to precede its audit. Its fresh
  retained no-launch diagnostic against the prior capture,
  `d02-validation-nif-weapon-mount-r10-pre-observed-pose-gate.json`, is a
  deliberate 41/44 FAIL (87,747 bytes, SHA-256
  `B31A248492544CFC84585928CFD62DF837F76C3EB273721F347CC34E6AF50535`):
  source checks pass, while the old runtime naturally lacks the new pose-gate
  records and still has the old identity vanilla-10mm audit. Next bite: build
  this observation-only change with `/m:1`, stage a fresh complete no-PDB
  runtime, run the mandatory capture preflight, and make one new OpenMW-only
  proof capture. No visual promotion is implied by this source checkpoint.

- 2026-08-03 — The observation-only D02 change compiled successfully in the
  required serialized RelWithDebInfo `/m:1` build. The new executable is
  81,355,264 bytes with SHA-256
  `B42F8E9DEE09A048CA5637EB0CA3FA637AE2C1A6330E3C0A6E03A033701C20DF`.
  A first local staging attempt is preserved at
  `local/openmw-real-save330-retail-observed-pose-gate-20260803-092000` as
  incomplete and non-launchable because this PowerShell host rejected
  `New-Item -LiteralPath` and flattened the plug-in directory; it will not be
  used for any preflight or capture. A second fresh, explicit directory-copy
  stage succeeded at
  `local/openmw-real-save330-retail-observed-pose-gate-20260803-092100` with
  `resources`, `osgPlugins-3.6.5/osgdb_dds.dll`, and zero PDB files verified.
  No game was launched during either staging attempt. Next bite: run the
  mandatory RuntimeReady/RequireIdle preflight only against the complete
  `092100` runtime, then use the public capture runner once to a new proof
  directory.

- 2026-08-03 — The required 53/53 RuntimeReady/RequireIdle preflight passed
  against the complete `092100` runtime and immutable fixture, then exactly
  one OpenMW-only public D02 capture was attempted at
  `run/fnv-real-save-campaign/d02-openmw-20260803-092200-observed-pose-gate`.
  It is retained as a failed diagnostic, not evidence of a completed route:
  after the runner's own 600-second bound it reported `expected=10 received=0`
  named D02 frames and safely terminated its owned process. The report retains
  no Windows app control, foreground activation, or injected input; stdout,
  telemetry, and the raw video are retained, but the outer public summary was
  correctly not written because the route failed.

  The live pending gate line identifies the actual state rather than a timing
  guess: the Save330 10mm had the correct first-person `1hpaim.kf` source,
  direct `Bip01 Translate -> Weapon -> weapon part` parentage, visibility, and
  a non-identity authored transform, while the active right-arm group was
  still `reload` and `weaponpose` was not playing. The retained strict
  validator `d02-validation-observed-pose-gate-r11-timeout.json` is 32,849
  bytes (SHA-256
  `732C96284F34ABF729B451640C01E866CED7E7BFE7BCA861E82CDA8CC164F531`)
  and fails 23 checks as expected for an incomplete route. Next bite: trace
  why the normal reload action does not relinquish the first-person right arm
  to the already-bound aim source, then fix that production action lifecycle
  without hard-coded transforms, clocks, or synthetic poses.

- 2026-08-03 — Pip-Boy visual-regression recovery source bite: a read-only
  audit preserved the last passing pre-regression runtime at
  `local/openmw-real-save330-pipboy-hand-bind-contact-20260803-223000`
  (SHA-256 `336a7fe993533d2f6c89becf2f42a581e62476545236c1db63c603022867e7d9`)
  without launching or modifying it. The current source was found to replace
  the direct asset lifecycle with C++ 4.5/5.5 presentation easing, a synthetic
  wrapper node, and a hand-picked frozen `pipboy` sample at 0.36 before
  `pipboywaver`; that explains the observed jump/glitch and is not retail
  data-driven behavior. The source now attaches the existing Pip-Boy NIF
  directly to `Bip01 L ForeTwist`, exposes only visibility state, starts the
  raw authored raise KF, and transitions to the raw authored waver only after
  the raise controller naturally stops. No hand, cuff, screen, weapon, IK,
  coordinate, or animation-time correction was added. This is not built,
  captured, or visually promoted yet. Next bite: inspect the existing retail
  KF/text-key data with repository tooling, update the deterministic C04
  contract to reject the removed invention paths, then perform one serialized
  build and one fresh unattended C04 capture.

- 2026-08-03 — Pip-Boy authored-asset/validator bite: existing repository
  tools (`bsatool` and `niftest --fnv-transform-dump`) extracted and inspected
  the official retail `pipboy.kf`, `1stppipboywaver.kf`, and
  `pipboymanipulate.kf` without a new binary parser. The raw raise clip has
  41 controllers across both arm chains and source text keys at `0:start` and
  `0.733333111:end`; the raw held waver has only the left-arm controllers and
  `0:start`/`6.00000048:end`; the separate 60-controller, two-arm manipulate
  clip has its own 12.6666679-second authored timeline. Therefore the direct
  raise/held lifecycle is source-backed, while MAP/WORLD must not be made to
  play the separate manipulate clip until a dedicated retail xNVSE interaction
  trace proves that route. `Test-FNVRealSaveC04.ps1` now deterministically
  requires direct `Bip01 L ForeTwist` attachment and raw raise/waver playback,
  and rejects the removed wrapper, seek/freeze, and 4.5/5.5 C++ easing paths.
  Its no-launch retained check at
  `run/fnv-real-save-campaign/c04-validation-20260803-094900-direct-authored-source-check.json`
  correctly records the older capture as FAIL only for its older/incomplete
  native-frame and telemetry contract; all new source-lifecycle checks pass.
  No runtime was launched or promoted. Next bite: serialized `/m:1` build,
  fresh no-PDB stage, mandatory preflight, then one new C04 OpenMW capture.

- 2026-08-03 — Direct-authored Pip-Boy build/stage bite: after confirming no
  `msbuild`, `cl`, or `link` process was active, the engine compiled with the
  required single `/m:1` RelWithDebInfo build. It succeeded with only the
  pre-existing PCH-option warning in `esm4npcanimation.cpp`. A fresh complete
  no-PDB runtime was staged at
  `local/openmw-real-save330-direct-authored-pipboy-20260803-100200`; its
  `openmw.exe` is 81,352,192 bytes with SHA-256
  `98E42F187CC49E2C7D847B9168793564F748C88AE8BB2BE98D0B344D5A70C242`,
  and its `resources` and `osgPlugins-3.6.5` directories were verified. No
  game launched and the retained rough-baseline runtime was not altered. Next
  bite: mandatory RuntimeReady/RequireIdle preflight, then exactly one fresh
  public OpenMW C04 capture to a non-overwriting proof directory.

- 2026-08-03 — Direct-authored Pip-Boy C04 capture/inspection bite: the
  required 55/55 RuntimeReady/RequireIdle preflight preceded exactly one
  OpenMW-only public capture at
  `run/fnv-real-save-campaign/c04-openmw-20260803-100300-direct-authored-pipboy`.
  The public report passed its no-host-control/no-concurrency/no-overwrite
  contract and retained four distinct native source PNGs plus the 3,881,459
  byte exact-title video (SHA-256
  `D9E80AD78DC479B3B24A383E6307EF67C7B4EEE86B87DFD8FA773A82F134A29E`).
  It is not visually promoted: native-frame inspection still shows the cuff/
  bare-skin seam and no acceptable right-hand-at-knob behavior, despite the
  restored production marker icon/selection and confirmation UI.

  The fresh deterministic validator at
  `run/fnv-real-save-campaign/c04-validation-20260803-100300-direct-authored-pipboy.json`
  fails exactly one check: raw `pipboy.kf` never transitions to the authored
  `1stppipboywaver.kf`. Read-only source tracing identifies the cause: the
  renderer calls first-person `runAnimation(dt)` only inside `if (!paused)`,
  while the physical Pip-Boy menu is paused; the clip begins but its authored
  time never advances. Next bite: let the existing first-person animation
  system advance on render `dt` only while the production physical Pip-Boy is
  open, then require the raw raise-to-waver transition in a fresh capture. No
  hand/arm/cuff transform, sampled time, or fixed frame countdown is allowed.

- 2026-08-03 — Paused authored-KF lifecycle source bite: the renderer now
  calls the existing first-person `runAnimation(dt)` only when the game is
  paused and the production physical Pip-Boy presentation is actually active.
  This supplies the renderer's real frame delta to the normal animation
  system, allowing the asset's own `0.733333111:end` raise and subsequent
  waver selection to occur; it does not define an alternate duration, seek a
  controller, alter a bone, or inject a pose. The C04 validator now requires
  that exact paused production condition and the normal animation call. This
  source change is not built, captured, or promoted yet. Next bite: serialized
  `/m:1` build and a single new preflighted C04 capture.

- 2026-08-03 — Paused authored-KF build/stage bite: after a clean
  no-compiler-process check, the required serialized `/m:1` RelWithDebInfo
  build succeeded. A fresh complete no-PDB runtime was staged at
  `local/openmw-real-save330-paused-authored-kf-20260803-100700`; its
  `openmw.exe` is 81,352,192 bytes with SHA-256
  `0CEBBB1ACFAD5FF8B7609BDA58C2AF2E498420B83CAC5EC2436D0F53535726A8`,
  with `resources` and `osgPlugins-3.6.5` verified. No game launched during
  the build/stage and no prior runtime was overwritten. Next bite: mandatory
  RuntimeReady/RequireIdle preflight and one new OpenMW-only C04 capture to
  prove the raw raise reaches the raw waver.

- 2026-08-03 — Paused authored-KF first-capture diagnostic: the required
  55/55 preflight preceded one fresh OpenMW-only public capture at
  `run/fnv-real-save-campaign/c04-openmw-20260803-100800-paused-authored-kf`.
  It proves the desired production lifecycle transition without a fixed clock:
  `pipboy.kf` raised and the live log then selected the authored
  `1stppipboywaver.kf` at frame 299. It is retained as a FAIL diagnostic, not
  evidence: all four native source-frame hashes are identical and native-frame
  inspection shows the world with no Pip-Boy. The raw pose advanced after the
  existing Camera1st alignment had already solved the first-person basis, so
  the animated camera anchor invalidated that frame's render alignment.

  The source now runs the same paused physical-Pip-Boy authored update before
  the existing Camera1st alignment solve; the C04 validator requires that
  presentation-call -> raw-animation -> camera-alignment ordering. No
  transform, offset, seam mesh, sampled pose, or timing constant was added.
  This correction is not built, captured, or promoted yet. Next bite:
  serialized `/m:1` rebuild and one fresh C04 proof run.

- 2026-08-03 — Camera-aligned authored-KF build/stage bite: after another
  no-compiler-process check, the required serialized `/m:1` build succeeded
  and a fresh complete no-PDB runtime was staged at
  `local/openmw-real-save330-authored-kf-prealign-20260803-101400`. Its
  `openmw.exe` is 81,352,192 bytes with SHA-256
  `139F103F9C591A7FBAC129F5FD99FC5EF83C91BE469D9FF3F97B425CB85B8EDB`,
  with `resources` and `osgPlugins-3.6.5` verified. No game launched during
  this build/stage. Next bite: mandatory preflight and exactly one new
  OpenMW-only C04 capture to test both distinct native frames and the raw
  raise-to-waver lifecycle.

- 2026-08-03 — Camera-aligned authored-KF C04 preflight bite: the mandatory
  OpenMW RealSave `RuntimeReady` and `RequireIdle` gate passed all 55 checks
  against the fresh `openmw-real-save330-authored-kf-prealign-20260803-101400`
  runtime and canonical Save330 fixture. The next proof directory,
  `run/fnv-real-save-campaign/c04-openmw-20260803-101500-authored-kf-prealign`,
  was confirmed absent before the gate. No game has launched yet and no prior
  proof directory or retained rough-baseline runtime was changed. Next bite:
  exactly one public OpenMW-only C04 capture using that new directory.

- 2026-08-03 — Camera-aligned authored-KF C04 capture bite: the required
  preflight preceded exactly one public OpenMW-only RealSave capture at
  `run/fnv-real-save-campaign/c04-openmw-20260803-101500-authored-kf-prealign`.
  The transport contract reports pass: no host control or foreground input,
  no overwrite/concurrency, normal Save330 load, four retained native source
  frames, telemetry, and a 4,634,089 byte exact-title video (SHA-256
  `AAB417B943D021323BF6FA3E480598AFD5E338F49F69A07B79E009736EAB2ED5`).
  It is not promoted: all four retained native source-frame PNGs have the
  identical 2,892,343 byte SHA-256
  `13181E9AFFC0335B8AAFE9ADEB65E29F0196C5339E4AF0E5B4C50596AB4A9FD0`.
  Next bite: run the deterministic C04 validator, inspect its failed checks
  and the actual native frame before changing any source.

- 2026-08-03 — C04 validator-input correction bite: the first retained
  validator invocation supplied the newly serialized A03 player denominator
  (`nikami-fnv-save-player-denominator/v2`) where C04's existing, explicit
  C01 map-marker denominator is required. Strict PowerShell stopped at the
  missing legacy `counts` member and wrote no validation artifact. Read-only
  verification confirms the required existing input remains
  `save330-map-marker-denominator.json` with schema
  `nikami-fnv-save330-map-marker-denominator/v1`, authored=320, visible=1,
  travelEnabled=1, and exactly one Southern Passage row. No source, runtime,
  capture, or proof was changed. Next bite: rerun the deterministic validator
  once with that canonical marker denominator, then inspect its artifact and
  native frame.

- 2026-08-03 — Camera-aligned authored-KF C04 validation/inspection bite:
  the corrected non-overwriting C04 validator wrote
  `c04-validation-20260803-101500-authored-kf-prealign-map-denominator.json`
  and failed only its distinct-native-frame check (53/54 checks passed). The
  retained source frames are a static world scene with no Pip-Boy, confirmed
  by direct native-frame inspection; this is a regression and remains a FAIL
  diagnostic. The raw lifecycle source checks, normal load, marker selection,
  icon overlay, confirmation telemetry, and capture-policy checks all pass,
  but none of those substitutes for a visible device/arm frame. No source was
  changed after the inspection. Next bite: compare the current and last
  visible direct-authored capture logs plus the xNVSE Camera1st/animation data
  to isolate the render-basis loss before proposing any source change.

- 2026-08-03 — Retail layer-composition inspection bite: read-only comparison
  of the retained xNVSE Save330 trace identifies the missing authored base
  layers. At `raising`/`rendered-held` the retail player has
  `Characters\\_1stPerson\\h2hidle.kf`,
  `Characters\\_1stPerson\\Locomotion\\Male\\pipboy.kf`, and
  `Characters\\_1stPerson\\h2haim.kf`; at `items` it has the raw
  `1stPPipboyWaver.kf` plus `h2haim.kf`. The retail Camera1st baseline returns
  from the raise to its native -3.741 Y position as the waver takes over.

  Existing `bsatool` and `niftest --fnv-transform-dump` inspection, retained
  at `local/retail-pipboy-base-layer-inspection-20260803-102300`, confirms
  `h2haim.kf` has 60 raw controller bindings while `h2hidle.kf` supplies the
  corresponding authored idle lifecycle; the current first-person code only
  keeps `mtidle.kf` beneath the waver. This is a source-backed composition
  mismatch, not evidence for an offset, seam mesh, generated hand, or fixed
  timeline. Next bite: bind and play only those observed retail H2H base clips
  beneath the existing raw raise/waver lifecycle, then extend the deterministic
  validator before building.

- 2026-08-03 — Retail H2H base-layer source bite: the first-person pipeline
  now binds the two exact xNVSE-observed Save330 clips,
  `meshes/characters/_1stperson/h2hidle.kf` and
  `meshes/characters/_1stperson/h2haim.kf`, as scoped raw animation sources.
  On physical open it plays them below the existing raw `pipboy.kf`; when the
  authored raise ends it retires only `h2hidle` and leaves `h2haim` below the
  existing left-arm `1stppipboywaver.kf`, matching the retained retail sequence
  list. Closing disables those scoped layers and restores the existing baseline.
  No transform, timing constant, pose sample, IK, hand mesh, or generated
  control movement was added. The C04 static contract now requires these exact
  asset paths and raw source selections. This source is not built, launched,
  captured, or promoted yet. Next bite: run the no-launch deterministic source
  validation against the retained failed capture, then do one serialized build
  only if the source contract is clean.

- 2026-08-03 — Retail H2H base-layer no-launch validation bite: the fresh
  non-overwriting artifact
  `c04-validation-20260803-101500-authored-kf-prealign-h2h-layers-sourcecheck.json`
  confirms all 53 source, provenance, telemetry, marker, and policy checks
  pass with the new exact H2H-layer contract. It fails only the intentionally
  retained old capture's byte-identical native-frame check, so it neither
  masks the regression nor promotes the source. No game launched. Next bite:
  verify no compiler is active, run one serialized `/m:1` build, and stage a
  fresh no-PDB runtime only if that build succeeds.

- 2026-08-03 — Retail H2H base-layer build/stage bite: after a clean check
  found zero `msbuild`, `cl`, and `link` processes, the required serialized
  `/m:1` RelWithDebInfo build succeeded. It emitted only the pre-existing
  `esm4npcanimation.cpp` PCH-option warning. A fresh complete no-PDB runtime
  is staged at `local/openmw-real-save330-retail-h2h-layers-20260803-102700`;
  `openmw.exe` is 81,355,264 bytes with SHA-256
  `C5B1853ED4A037FC21BA8EE6F9758A5319B357A147ACD700C57E8F6E029B2559`,
  zero PDB files, and verified `resources`/`osgPlugins-3.6.5`. No game was
  launched, and no retained runtime was overwritten. Next bite: mandatory
  `RuntimeReady`/`RequireIdle` preflight followed by exactly one fresh
  OpenMW-only C04 capture to a new proof directory.

- 2026-08-03 — Retail H2H C04 preflight gate bite: the mandatory preflight
  correctly refused to launch a capture because its `Capture engines are idle`
  check failed (54/55 checks passed). Read-only process inspection found two
  already-running OpenMW processes (PIDs 25704 and 50444, started 16:10:55)
  from `local/labs/openmw-051-threeway-candidate-r29/openmw.exe`, not the fresh
  staged runtime. They were not focused, controlled, or terminated. No game
  launched, no proof directory was created, and no capture was attempted.
  Next bite: continue no-launch source/evidence work while monitoring for the
  required idle gate; do not capture until it passes.

- 2026-08-03 — Cuff/arm asset-bind evidence bite: existing `bsatool` and
  `niftest --fnv-skin-bind-audit` inspected the actual first-person skeleton,
  Save330 outfit Arms partition, left Pip-Boy glove, right hand, and Pip-Boy
  arm at `local/retail-pipboy-cuff-skin-inspection-20260803-103100`. Every
  relevant skinned geometry has zero missing skeleton bones and passes the
  existing engine rest-pose invariant (the Arms and both glove surfaces are
  included). This rules out inventing a cuff seam mesh or a separate hand-bind
  transform from static asset data; the unresolved seam must be validated in
  the live authored layer composition. No game was launched. Next bite:
  recheck the idle gate, then capture only if it is clean.

- 2026-08-03 — Retail H2H C04 retry-preflight bite: after the previously
  unrelated lab-runtime processes exited naturally, the same mandatory
  OpenMW RealSave `RuntimeReady`/`RequireIdle` gate passed all 55 checks for
  `openmw-real-save330-retail-h2h-layers-20260803-102700`. The planned proof
  directory remains absent and no prior evidence/runtime was altered. Next
  bite: execute exactly one public OpenMW-only C04 capture there.

- 2026-08-03 — Retail H2H C04 capture failure bite: the single permitted
  OpenMW-only public capture was launched after the passing 55/55 gate and
  retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-102800-retail-h2h-layers`.
  It failed before writing the required four native Save330 frames; its report
  records `OpenMW exited before the required native Save330 frame sequence was
  written. expected=4`. The runtime log identifies the exact source regression:
  registering `h2hidle.kf` under the scoped retail layer caused the generic
  animation-source lookup for required `mtidle.kf` to resolve to `h2hidle.kf`,
  then the first-person initialization correctly stopped with `failed to bind
  native FNV first-person mtidle base pose`. The proof directory, failed stage,
  preserved rough-working fallback, and all unrelated dirty work remain
  untouched. No retry or game launch is authorized by this bite. Next bite:
  inspect the existing animation-source naming path and repair the alias
  collision from raw retail data before any rebuild or capture.

- 2026-08-03 — Retail H2H alias-isolation repair/no-launch validation bite:
  source inspection confirmed that `h2hidle.kf` has the retained `idle`
  text-key group despite containing only the identity `Bip01 NonAccum`
  controller; its companion `h2haim.kf` contains the 60 authored two-arm
  controllers. The generic source stack correctly selects the most recently
  loaded source for any advertised group, so the prior scoped alias also
  exposed `idle` and replaced `mtidle.kf`. The loader now has an explicit
  selected-source isolation mode: after the requested semantic alias is
  synthesized, it removes only non-selected legacy groups from that selected
  source before adding it to the source stack. The retained `h2hidle` call
  enables that mode for `pipboybaseidle`; no controller, transform, timing,
  hand mesh, or pose data changed. A fresh non-overwriting no-launch C04
  source check at
  `c04-validation-20260803-101500-authored-kf-prealign-h2hidle-isolated-matching-runtime-sourcecheck.json`
  passes 55/56 checks, including the new collision-prevention contract; its
  sole intentional failure is the retained old capture's identical native
  frames. The companion check against the newer nonmatching stage also
  correctly reports its stage-SHA mismatch rather than hiding it. Next bite:
  check the build lane, build this source once with `/m:1`, stage a new
  no-PDB runtime, then use the mandatory gate before one fresh OpenMW-only
  C04 capture.

- 2026-08-03 — Retail H2H alias-isolation build/stage/preflight bite: with no
  compiler processes active, the single serialized `/m:1` RelWithDebInfo build
  succeeded (only the pre-existing `esm4npcanimation.cpp` PCH-option warning).
  A fresh complete no-PDB runtime is retained at
  `local/openmw-real-save330-retail-h2h-idle-isolated-20260803-162301`;
  `openmw.exe` is 81,355,264 bytes with SHA-256
  `48AF32489B4C976681EBA8A12959CCE25C443F2A2FC717D9BC2F0E6F118B661A`,
  zero PDB files, and verified `resources`/`osgPlugins-3.6.5`. Its required
  `RuntimeReady`/`RequireIdle` preflight then correctly refused a new C04
  launch (54/55): two already-running OpenMW processes started at 16:23:40
  from `local/labs/openmw-051-threeway-candidate-r29/openmw.exe` held the
  capture lane. They were not focused, controlled, or terminated; no proof
  directory was created and no game launched. Next bite: continue no-launch
  deterministic validation while the required idle gate remains unavailable;
  retry the same preflight only after it can pass.

- 2026-08-03 — Retail H2H PRN-preservation / C04 functional-evidence bite:
  source isolation was narrowed to remove only the conflicting `idle` group,
  preserving the retained retail `prn: bip01 r hand` event from
  `h2hidle.kf`; a focused component test for that exact collision passed, then
  one serialized `/m:1` OpenMW build succeeded. The immutable no-PDB stage is
  `local/openmw-real-save330-retail-h2h-idle-prn-preserved-20260803-162913`
  (`openmw.exe` SHA-256
  `AD6D13972F704AFA9EDF98DE1358DD97980F0BCF063E0782CC802A766F46B438`).
  After a passing 55/55 required idle/runtime preflight, exactly one public
  OpenMW C04 capture was retained at
  `run/fnv-real-save-campaign/c04-openmw-20260803-162930-retail-h2h-idle-prn-preserved`.
  Its public capture report passed and the matching strict C04 validator
  passed 58/58: four distinct native frames, natural Save330 map-selection
  route, one restored marker icon, focus and confirmation telemetry, and raw
  retail H2H base-layer provenance. This is functional evidence only, not a
  visual promotion: direct review of those native frames still shows the
  unresolved bare cuff/arm seam and no data-proven right-hand knob contact,
  while Pip-Boy framing differs from the retained retail frames. No C05 or
  D02 work is claimed or resumed. Next bite: read the live hand-skinning and
  attachment implementation plus the exact retail controller/rig evidence to
  identify a deterministic correction; do not invent IK, transforms, timing,
  hand geometry, or run another capture until that source contract is known.
