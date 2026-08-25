# OpenMW lab public-main curation — 2026-08-24

## Published result

The public `nikamigaming-create/nikami-openmw-lab` `main` lane is current with
official OpenMW master and contains the bounded Fallout data contracts that
have passed the full platform gate:

- commit: `a0dcaf6a289291edf8bce36e205cc7302fe81f7c`;
- tree: `a7d43170b0977545ef40eaa26a6485cdaa21f7de`;
- official OpenMW base: `03e02d034fed3e3c1d65f0ba09767df64c58b78e`;
- local upstream sync merge: `a67cb2ef47916fce2d300b1a50de5b9fe969c9e3`;
- public remote topology: only `main`; no open PRs or temporary topic refs.

The published Fallout slices are typed `WTHR`, `CLMT`, `AVIF`, `REPU`, `AMEF`,
`TERM`, `MGEF`, `SPEL`, and `REFR` contracts on top of the data-owned UI/game identity
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

Focused local checks passed for the WTHR, CLMT, AVIF, REPU, AMEF, and TERM
translation units and `git diff --check`; the MGEF/SPEL fixtures were exercised
by both green four-platform CI runs. The local full MSVC build reaches the
changed ESM4 sources
but is blocked later by the host's unrelated OSG header mismatch:
`GL_COMPRESSED_SRGB_S3TC_DXT{1,3,5}_EXT` is absent from the installed headers.
This is not a failure of the promoted slice; CI is authoritative.

The published history keeps each bounded contract reviewable: CLMT climate,
AVIF actor-value metadata, REPU reputation metadata, AMEF ammo effects, TERM
terminal records, and MGEF/SPEL actor effects are separate commits. Their
synthetic tests cover valid fields, null-preserving FormIDs, fixed-size
validation, enum/range checks, exact menu/script retention, and
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

The public weather, metadata, AMEF, TERM, actor-effect, patrol-reference, and
primitive topic refs were deleted only after their post-push `main` runs
(`32749407011`, `32762033204`, `32770688961`, `32781270416`, `32788636108`,
`32795208280`, and `32800267449`) were green. The remote now exposes only
`main`; there are no open PRs or temporary public refs. No private retail binary
or evidence is present in any public ref or bundle.

## Fresh pull / exact resume

Fresh consumers can start from the clean public lane:

```powershell
git clone https://github.com/nikamigaming-create/nikami-openmw-lab.git D:\code\nikami-openmw-fresh
git -C D:\code\nikami-openmw-fresh switch main
git -C D:\code\nikami-openmw-fresh rev-parse HEAD
# expected: a0dcaf6a289291edf8bce36e205cc7302fe81f7c
```

The public lane is at a clean stopping point for new Fallout feature work.
Continue using one bounded typed/API contract per commit for the remaining
recovery inventory; do not merge the mixed recovery branch wholesale. The next
evidence gate remains private retail camera/placement/animation telemetry.

Actor identity/export/runtime parity is already merged, but visual parity is not
claimed.

## Private observation boundary

Keep the following private and never distribute its binary or evidence:

- observer: `D:\Dev\Tools\Ghidrust\builds\wow64-i686-codex-nogpu\i686-pc-windows-msvc\release\ghidrust.exe`;
- evidence: `D:\Dev\Tools\Ghidrust\workspace\evidence\falloutnv_1_4_0_525\camera`.

The observer must run as one long-lived `mcp` session with `process_attach` in
`observe` mode. No UI automation, focus changes, or injected input are part of
the proof path. B-world is not a dependency of the public OpenMW lab.
