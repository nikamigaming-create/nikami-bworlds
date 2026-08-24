# OpenMW lab public-main curation — 2026-08-24

## Published result

The public `nikamigaming-create/nikami-openmw-lab` `main` lane is current with
official OpenMW master and contains the bounded Fallout data contracts that
have passed the full platform gate:

- commit: `e1546e87117b2fcecbd7abfb9dd68b07cd97d0e7`;
- tree: `3a046ff3c4f38709a1de9dcb7dcfd06a3bb058ba`;
- official OpenMW base: `03e02d034fed3e3c1d65f0ba09767df64c58b78e`;
- local upstream sync merge: `a67cb2ef47916fce2d300b1a50de5b9fe969c9e3`;
- public remote topology: only `main`; no temporary topic refs remain.

The published Fallout slices are typed `WTHR`, `CLMT`, `AVIF`, `REPU`, `AMEF`, and
`TERM` contracts on top of the data-owned UI/game identity and collision seams.
The weather contract records the complete metadata currently supported by the
clean loader: image-space
references, cloud textures/layers/speeds/colors, fog distances, the fixed
304-byte unused image-space block, named `DATA` offsets, and exact `SNAM`
sound pairs. Legacy/current color-row layouts and field presence are retained;
malformed fixed-size subrecords fail instead of being silently accepted.

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

Focused local checks passed for the WTHR, CLMT, AVIF, REPU, AMEF, and TERM translation
units and `git diff --check`. The local full MSVC build reaches the changed ESM4 sources
but is blocked later by the host's unrelated OSG header mismatch:
`GL_COMPRESSED_SRGB_S3TC_DXT{1,3,5}_EXT` is absent from the installed headers.
This is not a failure of the promoted slice; CI is authoritative.

The published history keeps each bounded contract reviewable: CLMT climate,
AVIF actor-value metadata, REPU reputation metadata, AMEF ammo effects, and TERM
terminal records are separate commits. Their synthetic tests cover valid fields,
null-preserving FormIDs, fixed-size validation, enum/range checks, exact menu/script
retention, and unknown/malformed input.

## Recovery and provenance

The current main/recovery bundle is:

- bundle: `D:\code\archives\nikami-openmw-lab-main-term-20260824-v11.bundle`;
- SHA-256: `76A2A26FDB648B08941EBE0964C2BFE97E94F823FE1A56DDBAF8BDB36637193E`;
- `git bundle verify`: passed; complete history recorded.

Earlier recovery bundles remain preserved:

- `D:\code\archives\nikami-openmw-lab-curated-20260824.bundle`, SHA-256
  `9C87DA956327B7B4E3046A391F762E1644C08D22307DA70944294F81C6D958EE`;
- `D:\code\archives\nikami-openmw-lab-ui-identity-20260824.bundle`, SHA-256
  `00FF010B8F9BA17DCBA90FF0E3D78D3939DD9D3EA89510CE4E96516E06A9803A`;
- the pre-clean bundle and all local recovery/product heads remain intact.

The public weather, metadata, AMEF, and TERM topic refs were deleted only after
their post-push `main` runs (`32749407011`, `32762033204`, `32770688961`, and
`32781270416`) were green. No private retail binary or evidence is present in any
public ref or bundle.

## Fresh pull / exact resume

Fresh consumers can start from the clean public lane:

```powershell
git clone https://github.com/nikamigaming-create/nikami-openmw-lab.git D:\code\nikami-openmw-fresh
git -C D:\code\nikami-openmw-fresh switch main
git -C D:\code\nikami-openmw-fresh rev-parse HEAD
# expected: e1546e87117b2fcecbd7abfb9dd68b07cd97d0e7
```

The public lane is at a clean stopping point for new feature work. Continue
using one bounded typed/API contract per commit for the remaining recovery
inventory; do not merge the mixed recovery branch wholesale. The next evidence
gate remains private retail camera/placement/animation telemetry.

Actor identity/export/runtime parity is already merged, but visual parity is not
claimed.

## Private observation boundary

Keep the following private and never distribute its binary or evidence:

- observer: `D:\Dev\Tools\Ghidrust\builds\wow64-i686-codex-nogpu\i686-pc-windows-msvc\release\ghidrust.exe`;
- evidence: `D:\Dev\Tools\Ghidrust\workspace\evidence\falloutnv_1_4_0_525\camera`.

The observer must run as one long-lived `mcp` session with `process_attach` in
`observe` mode. No UI automation, focus changes, or injected input are part of
the proof path. B-world is not a dependency of the public OpenMW lab.
