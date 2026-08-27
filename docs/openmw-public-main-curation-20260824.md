# OpenMW lab public-main curation — 2026-08-27

## Published result

The public `nikamigaming-create/nikami-openmw-lab` `main` lane is current with
official OpenMW master and contains the bounded Fallout data contracts that
have passed the full platform gate:

- commit: `5b22b49243e4f4d708d2b6684a56302387d85783`;
- tree: `266b7749e89acb418593161faf1fa69aff3e173f`;
- official OpenMW base: `7d6273776b3e6fc05cb58c0b1453faf6e199d44a`;
- local upstream sync merge: `2f5e87fd797a5be8b137337b8ec297dbfb43b68f`;
- public remote topology: `main` only; the consolidated candidate, inventory,
  crafting-station, and crafting-session topic refs were deleted after their
  topic and post-push main gates passed. There are no open PRs.

The published Fallout slices are typed `WTHR`, `CLMT`, `AVIF`, `REPU`, `AMEF`,
`TERM`, `MGEF`, `SPEL`, `REFR`, `LIP`, `CLAS`, `RACE`, `FACT`, `NOTE`, `RCCT`,
and `RCPE`, plus the native crafting-station catalog
contracts on top of the data-owned UI/game identity
and collision seams. `MGEF` and `SPEL` provide strict Fallout actor-effect
record loaders, fixed native DATA/SPIT/EFIT layouts, null-preserving FormID
adjustment, and shared CTDA target-condition decoding with synthetic fixtures.
The weather contract records the complete metadata currently supported by the
clean loader: image-space
references, cloud textures/layers/speeds/colors, fog distances, the fixed
304-byte unused image-space block, named `DATA` offsets, and exact `SNAM`
sound pairs. Legacy/current color-row layouts and field presence are retained;
malformed fixed-size subrecords fail instead of being silently accepted.

The `REFR` contract preserves Fallout patrol metadata without introducing
runtime dispatch: `XLKR` is the load-order-adjusted linked reference (with a
null FormID preserved), `XPRD` is the authored idle time, and an empty `XPPA`
is the patrol-idle/script marker. Exact-size malformed payloads are skipped
without losing the following subrecord boundary. Synthetic tests cover valid,
malformed, and null-link records.

It also preserves the authored `XPRM` primitive used by model-less references:
three bounds floats, four color floats, and the named Fallout primitive type
enum. The loader accepts only the exact 32-byte layout and leaves malformed
payloads absent while retaining following-record alignment. This is metadata
only; trigger-volume dispatch remains outside public main.

The `LIP` contract decodes the tested Fallout 3/New Vegas version-1 compressed
and uncompressed animation containers, including zero-run expansion, the 33
authored target names, 30-fps voice-clock sampling, interpolation, and
fail-closed malformed/truncated input. Decode-size, duration, and target-value
limits are named policy inputs; dialogue, sound playback, and runtime animation
publication remain outside this parser slice.

The `RACE` contract decodes the exact FO3/FNV 36-byte `DATA` payload: seven
authored skill-boost pairs, reserved bytes, male/female height and weight, and
raw race flags. It publishes the existing scalar race fields while retaining
the typed payload, and rejects malformed data before publishing it. It also
preserves the FO3/FNV `GNAM` body-part-data FormID through the existing typed
Reader/FormID load-order adjustment. A valid four-byte payload is retained; a
malformed payload is skipped so the following subrecord boundary remains
intact. This is Fallout metadata only; VATS body-part selection and runtime hit
behavior remain outside the slice.

The `CLAS` contract is version-gated to FO3/FNV and decodes the exact 28-byte
`DATA` payload (four signed tag actor values, raw flags/services/teaches/training,
and reserved bytes) plus the exact seven-byte `ATTR` payload. Both subrecords
are retained through typed ESM4 fields, duplicate or malformed payloads fail
closed, and non-Fallout ESM versions keep their legacy skip behavior. This is
Fallout class metadata only; skill progression and gameplay class behavior
remain outside the slice.

The `FACT` contract is FNV-only and decodes typed faction flags, group
reactions, relation entries, ranks, localized titles, crime-gold multiplier,
and reputation through the existing ESM4 store API. Its exact XNAM/DATA/CNAM/
RNAM/WMI1 widths, short/long DATA forms, subrecord ordering, duplicate rules,
and required EDID/DATA fields are named and tested; malformed, unknown, or
non-FNV records fail closed without changing runtime policy.

The `NOTE` contract is FNV-only and decodes the authored object bounds, data
kind, text/image/voice payloads, optional voice speaker, and bounded quest
references through the typed ESM4 store API. DATA kind selects an exact
TNAM/XNAM/FormID payload shape; EDID/DATA ordering, duplicate/unknown fields,
FormID widths, null sentinels, quest-reference bounds, and malformed records
are tested atomically. This is Fallout note metadata only; UI presentation and
runtime note behavior remain outside the slice.

The `RCCT` contract is FNV-only and decodes the recipe-category record as the
smallest independent crafting-data seam: `EDID` Z-string, `FULL` Z-string,
and the exact one-byte authored `DATA` value in that order. Duplicate,
unknown, reordered, empty, truncated, or oversized fields fail closed before
the typed store is mutated; the raw `DATA` byte is preserved for a later native
crafting API. `RCPE`, workbench activation, crafting UI, Lua/MyGUI presentation,
transactions, and retail parity remain separate scope.

The `RCPE` contract is FNV-only and decodes exact recipe EDID/FULL/CTDA*/DATA
and RCIL/RCQY plus RCOD/RCQY rows. FormIDs are adjusted through the typed
reader, null category links are preserved, and malformed ordering, widths,
duplicates, and unsupported condition forms fail closed before store mutation.
The native transaction contract now lives in `fnvcraftingruntime`; workbench
activation, station action, inventory ownership, UI, and retail parity remain
separate scope.

The current consolidated promotion adds five bounded Fallout-only slices. The
crafting runtime is a headless, data-driven transaction over typed `RCCT` and
`RCPE` records with injected station/category/skill providers and one
all-or-none inventory mutation. `ContainerStore` now owns all supported ESM4
item families, including weight, lookup, save/read state, cell/manual-ref
registration, and the Fallout special `CHIP`/`CCRD`/`CMNY` aliases. Authored
weapon and armor condition is exposed through the native class API. The
supporting tests use environment-independent iteration/count assertions, and
macOS dependency setup removes a stale Homebrew tap before updates. These are
native C++/ESM4 contracts only: no Lua, MyGUI, UI, VR, quest scripting, or
visual parity claim is implied.

The follow-up crafting-station catalog slice is also native and headless. It
resolves station/category through an injected `FnvCraftingStationRule`,
freezes a snapshot of live authored recipes, retains unsupported recipes with
explicit preparation errors, and records authored names and quantities. It
does not embed retail IDs, mutate inventory, activate workbenches, or choose a
Lua/MyGUI presentation path; activation and presentation remain separate
contracts.

The crafting-session slice adds a toolkit-neutral controller over that frozen
catalog. Page navigation, blocked-entry notices, explicit craft confirmation,
backend invocation, result notices, cancellation, invalid selections, and
redraw exhaustion are typed seams with injected policy and presenter/backend
interfaces. It adds no MyGUI or Lua dependency, retail IDs, localization text,
or inventory side effect; station activation and production presentation remain
separate contracts.

Schema facts are named constants and decoded through the typed ESM4 API. No
Lua/MyGUI replacement path, private retail bytes, generated product assets, or
runtime magic-number policy was added by this slice. The audit claim is limited
to the Fallout lab surface touched here; upstream structural literals remain
format facts unless behavior policy needs injection.

## Acceptance evidence

The authoritative post-publication workflow passed all four platform legs:

- run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32749407011;
- Ubuntu: success;
- macOS ARM: success;
- macOS Intel: success;
- Windows 2022: success.

The rebased WTHR topic workflow also passed all four legs:

- run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32745187899;
- Ubuntu, macOS ARM, macOS Intel, and Windows 2022: success.

The cumulative CLMT/AVIF/REPU topic workflow passed all four legs after a
fixture-only retry (the first attempt used reserved `XXXX` instead of a plain
unknown tag):

- corrected topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32757874352;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32762033204;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The AMEF topic and its post-push `main` workflow also passed all four legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32766468530;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32770688961;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The TERM topic and its post-push `main` workflow passed all four legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32777455756;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32781270416;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The MGEF/SPEL actor-effect topic and its post-push `main` workflow passed all
four legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32785467395;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32788636108;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The REFR patrol-reference topic and its post-push `main` workflow also passed
all four legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32792379112;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32795208280;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The follow-up REFR primitive topic and its post-push `main` workflow passed
all four legs after one fixture-only correction (the first attempt passed an
`ESM::Position` directly to a `string_view` helper; the amended commit used
the existing POD serializer):

- corrected topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32797607992;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32800267449;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The LIP topic and its post-push `main` workflow passed all four platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32803780778;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32806400610;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The RACE body-part metadata topic and its post-push `main` workflow passed all
four platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32809341998;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32812037770;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The CLAS/RACE class-and-race data topic and its post-push `main` workflow also
passed all four platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32815337608;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32818383821;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The FACT topic and its post-push `main` workflow passed all four platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32824274960;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32828347705;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The NOTE topic and its post-push `main` workflow passed all four platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32841961351;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32845678839;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The RCCT recipe-category topic and its post-push `main` workflow passed all
four platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32851192054;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32855446251;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The RCPE recipe topic and its post-push `main` workflow passed all four
platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32873877733;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/33029970571;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The first two Ubuntu attempts of the post-push run were transient Launchpad
`GPGKeyTemporarilyNotFoundError` HTTP 500 responses before compilation; the
Ubuntu-only retry completed successfully without any source or workflow
change.

The consolidated upstream/crafting/inventory candidate and its post-push
`main` workflow both passed all four platform legs:

- candidate run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/33045391257;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/33047983858;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The candidate run was repeated once after a documentation-only trailing-blank
line correction; the final tested and published SHA is `f8aeeab300`.

The crafting-station catalog topic and its post-push `main` workflow passed
all four platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/33051910830;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/33055029474;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The final published station-catalog SHA is `72e46eddfc`.

The crafting-session controller topic and its post-push `main` workflow passed
all four platform legs:

- topic run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/33063850253;
- post-push `main` run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/33066923395;
- Ubuntu, Windows 2022, macOS ARM, and macOS Intel: success on both runs.

The final published crafting-session SHA is `5b22b49243`.

Focused local checks passed for the WTHR, CLMT, AVIF, REPU, AMEF, TERM, and
crafting-catalog/session translation units and `git diff --check`; the MGEF/SPEL,
LIP, RACE, CLAS, FACT,
and NOTE/RCCT fixtures were exercised by green four-platform CI runs. The local full MSVC
build reaches the
changed ESM4 sources
but is blocked later by the host's unrelated OSG header mismatch:
`GL_COMPRESSED_SRGB_S3TC_DXT{1,3,5}_EXT` is absent from the installed headers.
This is not a failure of the promoted slice; CI is authoritative.

The published history keeps each bounded contract reviewable: CLMT climate,
AVIF actor-value metadata, REPU reputation metadata, AMEF ammo effects, TERM
terminal records, MGEF/SPEL actor effects, LIP animation decoding, RACE
body-part metadata, CLAS/RACE class-and-race data, FACT faction data, NOTE
note metadata, RCCT recipe-category data, the native crafting transaction,
ESM4 inventory storage, Fallout special-inventory aliases, and authored item
condition, and the crafting-station catalog are separate commits. Their
synthetic tests cover valid fields,
null-preserving FormIDs, fixed-size validation, enum/range checks, exact
menu/script retention, environment-independent container iteration, and
unknown/malformed input.

The public scope is Fallout-only. Starfield/OpenXR/OpenNV/Godot/VR/runtime
experiments remain in private recovery history and were not promoted. Names
that remain in the tree because they are part of official OpenMW upstream are
not lab additions. Future public work must use one bounded Fallout typed/API
slice per commit, with named data-layout constants, synthetic tests, and a
green four-platform gate before fast-forwarding `main`.

The mixed recovery trigger-volume commit `9112e6bfe4` is intentionally still
private. Only its standalone `REFR.XPRM` data contract was extracted. Its Lua
event plumbing, world/runtime dispatch, and authored trigger behavior are not
part of public main; they require a separate native API contract and retail
evidence before they can be considered feature work.

## Feature-mode guardrails

The recovery experiment is closed as a public-history practice once a slice
has completed this sequence; new feature work follows the same sequence:

1. Start from the current `main` and select one bounded Fallout data/API
   contract. Do not merge the mixed recovery branch or carry an experimental
   runtime/UI path into a feature topic.
2. Write the contract and synthetic full-reader or focused API tests first.
   Use existing OpenMW ownership and APIs; name every Fallout layout width,
   version gate, and sentinel. A value that is a file-format fact stays in the
   typed loader; a policy value gets an explicit injected/configured owner.
3. Keep parser, engine API, runtime behavior, and visual parity as separate
   review surfaces. Lua, MyGUI, OpenXR, private retail bytes, and generated
   evidence are not substitutes for the native API contract.
4. Require `git diff --check`, focused tests, the full four-platform topic CI,
   and the full four-platform post-push `main` CI. Only then delete the topic,
   verify no open PRs or extra public refs, and create a recovery bundle with
   its hash.

This prevents a feature from becoming another opaque migration: every public
commit has a named owner, a testable boundary, a clean history, and a recorded
rollback point.

## Recovery and provenance

The current main/recovery bundle is:

- bundle: `D:/code/archives/nikami-openmw-lab-main-crafting-session-20260827-v24.bundle`;
- SHA-256: `09394BFB08637031463D5324138CEE1965A47D45A8DE6664D05B6A2A751786AA`;
- `git bundle verify`: passed; complete history recorded at `5b22b49243`.

The immediately preceding upstream/crafting/inventory main bundle remains
preserved:

- bundle: `D:/code/archives/nikami-openmw-lab-main-upstream-crafting-inventory-20260826-v22.bundle`;
- SHA-256: `2A0F488D57AE5C66B84DBD363852D24793F4533DEE48A615C48B0C94DF4706EC`;
- `git bundle verify`: passed; complete history recorded at `f8aeeab300`.

The immediately preceding RCPE main bundle remains preserved:

- bundle: `D:/code/archives/nikami-openmw-lab-main-recipe-records-20260826-v21.bundle`;
- SHA-256: `CC9E6D9F2856038D146130FF4F2B2EF738533A05C71F62222960797309641B58`;
- `git bundle verify`: passed; complete history recorded at `fafc908066`.

The immediately preceding recipe-category bundle remains preserved:

- bundle: `D:/code/archives/nikami-openmw-lab-main-recipe-category-20260825-v20.bundle`;
- SHA-256: `C114362F2DDDB05F97743CD192D9721A814B5E92BB566EAA6AB28C8F42A2988F`;
- `git bundle verify`: passed; complete history recorded at `1b15260c3d`.

The immediately preceding main bundle remains preserved:

- bundle: `D:/code/archives/nikami-openmw-lab-main-note-data-20260825-v19.bundle`;
- SHA-256: `C6D5A115474AF1105AF8CAEA9F4D4ED2822C064DE1CF82967CC069DA12AC55BB`;
- `git bundle verify`: passed; complete history recorded at `b86ed5bd5f`.

The preceding faction main bundle remains preserved:

- bundle: `D:\code\archives\nikami-openmw-lab-main-faction-data-20260825-v18.bundle`;
- SHA-256: `CB7259CF7D355C0B336534211B7D2B7F8B2017259BF99357F90B33904B5989BF`;
- `git bundle verify`: passed; complete history recorded at `f4cdb06b8f`.

- bundle: `D:/code/archives/nikami-openmw-lab-main-class-race-data-20260825-v17.bundle`;
- SHA-256: `8CAC1CA141A2D3F701E60B96A5D34FAEABDDC7A8A7238E0CADBEA823BAC5D06C`;
- `git bundle verify`: passed; complete history recorded.

- bundle: `D:\code\archives\nikami-openmw-lab-main-race-body-part-20260825-v16.bundle`;
- SHA-256: `A9C8C1C8EA0B7D33F2C502159A97793C5A21A9F6FE1D327BC1C44D2CA81443E4`;
- `git bundle verify`: passed; complete history recorded.

- bundle: `D:\code\archives\nikami-openmw-lab-main-lip-data-20260825-v15.bundle`;
- SHA-256: `0A9C632BFEFE1711DBE66BD91E284A81B3B73A19EACCD569589E881EE94C0514`;
- `git bundle verify`: passed; complete history recorded.

- bundle: `D:\code\archives\nikami-openmw-lab-main-reference-primitives-20260825-v14.bundle`;
- SHA-256: `39B46F1944CAA17B698A451741CCB95CEC8F7C3EDF2F0E19F6D94A731E4DE5A4`;
- `git bundle verify`: passed; complete history recorded.

The immediately preceding main bundle remains preserved:

- bundle: `D:\code\archives\nikami-openmw-lab-main-patrol-reference-20260825-v13.bundle`;
- SHA-256: `A204047B920B4479C5281BB570E3A17C7D15476A7DC74DF9DCEFF2BBA1C4AAC8`;

The preceding actor-effects main bundle remains preserved:

- bundle: `D:\code\archives\nikami-openmw-lab-main-actor-effects-20260824-v12.bundle`;
- SHA-256: `586418582D4E2E53C7F802EB0050AA3150AF4ECFE4FD5E6FDE3776F691E85837`;

The preceding TERM main bundle remains preserved:

- bundle: `D:\code\archives\nikami-openmw-lab-main-term-20260824-v11.bundle`;
- SHA-256: `76A2A26FDB648B08941EBE0964C2BFE97E94F823FE1A56DDBAF8BDB36637193E`;

Earlier recovery bundles remain preserved:

- `D:\code\archives\nikami-openmw-lab-curated-20260824.bundle`, SHA-256
  `9C87DA956327B7B4E3046A391F762E1644C08D22307DA70944294F81C6D958EE`;
- `D:\code\archives\nikami-openmw-lab-ui-identity-20260824.bundle`, SHA-256
  `00FF010B8F9BA17DCBA90FF0E3D78D3939DD9D3EA89510CE4E96516E06A9803A`;
- the pre-clean bundle and all local recovery/product heads remain intact.

The public weather, metadata, AMEF, TERM, actor-effect, patrol-reference,
primitive, LIP, RACE, CLAS/RACE, FACT, NOTE, RCCT, RCPE, crafting-station, and
crafting-session topic refs were
deleted only after their topic and post-push `main` runs were green. The
post-push `main` runs are
(`32749407011`, `32762033204`, `32770688961`, `32781270416`, `32788636108`,
`32795208280`, `32800267449`, `32806400610`, `32812037770`,
`32818383821`, `32828347705`, `32845678839`, `32855446251`, `33029970571`,
`33047983858`, `33055029474`, and `33066923395`); the
CLAS/RACE topic run was `32815337608`, the FACT topic run was `32824274960`,
the NOTE topic run was `32841961351`, the RCCT topic run was
`32851192054`, and the RCPE topic run was `32873877733`. The consolidated
candidate run was `33045391257`; the crafting-station topic run was
`33051910830`; the crafting-session topic run was `33063850253`. The remote
now exposes `main` only; there are
no open PRs. No private retail binary or evidence is present in any public ref
or bundle.

## Fresh pull / exact resume

Fresh consumers can start from the clean public lane:

```powershell
git clone https://github.com/nikamigaming-create/nikami-openmw-lab.git D:\code\nikami-openmw-fresh
git -C D:\code\nikami-openmw-fresh switch main
git -C D:\code\nikami-openmw-fresh rev-parse HEAD
# expected: 5b22b49243e4f4d708d2b6684a56302387d85783
```

The public `main` lane is at a clean upstream-synchronized Fallout contract
stopping point; the candidate/topic refs have been removed after promotion.
The remaining FNV feature-ready lane is five larger gates—combat/loot,
crafting ownership/activation, generic Pip-Boy/HUD, physical
terminals/lockpicking, and one natural quest/persistence/AI path—split into
roughly 5–10 reviewable slices after the published NOTE, RCCT, RCPE, crafting,
and inventory contracts. This is a
cleanup estimate, not a retail-parity percentage: FO3, TTW, JAM, VR, visual
parity, and the 144 currently open differential cases remain separate scope.
Continue using one bounded typed/API contract per commit for that inventory;
do not merge the mixed recovery branch wholesale. The next evidence gate
remains private retail camera/placement/animation telemetry.

Actor identity/export/runtime parity is already merged, but visual parity is not
claimed.

## Private observation boundary

Keep the following private and never distribute its binary or evidence:

- observer: `D:\Dev\Tools\Ghidrust\builds\wow64-i686-codex-nogpu\i686-pc-windows-msvc\release\ghidrust.exe`;
- evidence: `D:\Dev\Tools\Ghidrust\workspace\evidence\falloutnv_1_4_0_525\camera`.

The observer must run as one long-lived `mcp` session with `process_attach` in
`observe` mode. No UI automation, focus changes, or injected input are part of
the proof path. B-world is not a dependency of the public OpenMW lab.
