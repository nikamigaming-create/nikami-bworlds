# OpenMW lab public-main curation — 2026-08-24

## Published result

The public `nikamigaming-create/nikami-openmw-lab` `main` lane is current with
official OpenMW master and contains the bounded Fallout data contracts that
have passed the full platform gate:

- commit: `dcb6aca3796b851b5884fef89b42ac8a8c2c8e60`;
- tree: `4dc1df5b3431adbcdd81b6a3f4ec61539a7599bc`;
- official OpenMW base: `03e02d034fed3e3c1d65f0ba09767df64c58b78e`;
- local upstream sync merge: `a67cb2ef47916fce2d300b1a50de5b9fe969c9e3`;
- public remote `main`: fast-forwarded; no open pull requests, tags, or releases;
- temporary review ref: `codex/openmw-fallout-metadata-records-20260824`
  (`a085f8f67b`) is currently held for the next gate and is not a PR.

The published Fallout slice is the typed `WTHR` contract on top of the
data-owned UI/game identity and collision seams. It records the complete
weather metadata currently supported by the clean loader: image-space
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

Focused local checks passed for the WTHR and CLMT translation units and
`git diff --check`. The local full MSVC build reaches the changed ESM4 sources
but is blocked later by the host's unrelated OSG header mismatch:
`GL_COMPRESSED_SRGB_S3TC_DXT{1,3,5}_EXT` is absent from the installed headers.
This is not a failure of the promoted slice; CI is authoritative.

The next local topic (`a085f8f67b`) contains four reviewable commits: CLMT
climate records, AVIF actor-value metadata, and REPU reputation metadata (the
last two are separate commits). Their synthetic tests cover valid fields,
null-preserving FormIDs, fixed-size validation, and unknown/malformed input.

## Recovery and provenance

The current weather/main recovery bundle is:

- bundle: `D:\code\archives\nikami-openmw-lab-weather-main-20260824-v8.bundle`;
- SHA-256: `FB537644B44B6F351E3A87C11B58D8AF6AA54EF0E8EA3853A9FE3B18B87575E1`;
- `git bundle verify`: passed; complete history recorded.

Earlier recovery bundles remain preserved:

- `D:\code\archives\nikami-openmw-lab-curated-20260824.bundle`, SHA-256
  `9C87DA956327B7B4E3046A391F762E1644C08D22307DA70944294F81C6D958EE`;
- `D:\code\archives\nikami-openmw-lab-ui-identity-20260824.bundle`, SHA-256
  `00FF010B8F9BA17DCBA90FF0E3D78D3939DD9D3EA89510CE4E96516E06A9803A`;
- the pre-clean bundle and all local recovery/product heads remain intact.

The public weather topic ref was deleted only after run `32749407011` was
green. The metadata ref is retained until its own gate, then it will be
fast-forwarded into `main` and deleted. No private retail binary or evidence
is present in any public ref or bundle.

## Fresh pull / exact resume

Fresh consumers can start from the clean public lane:

```powershell
git clone https://github.com/nikamigaming-create/nikami-openmw-lab.git D:\code\nikami-openmw-fresh
git -C D:\code\nikami-openmw-fresh switch main
git -C D:\code\nikami-openmw-fresh rev-parse HEAD
# expected: dcb6aca3796b851b5884fef89b42ac8a8c2c8e60
```

After the metadata topic gate passes, promote with a fast-forward only, then
delete the temporary ref and verify that the remote again exposes only
`main`. Continue using one bounded typed/API contract per commit; do not merge
the mixed recovery branch wholesale.

The next evidence gate after the data contracts is private retail
camera/placement/animation telemetry. Actor identity/export/runtime parity is
already merged, but visual parity is not claimed.

## Private observation boundary

Keep the following private and never distribute its binary or evidence:

- observer: `D:\Dev\Tools\Ghidrust\builds\wow64-i686-codex-nogpu\i686-pc-windows-msvc\release\ghidrust.exe`;
- evidence: `D:\Dev\Tools\Ghidrust\workspace\evidence\falloutnv_1_4_0_525\camera`.

The observer must run as one long-lived `mcp` session with `process_attach` in
`observe` mode. No UI automation, focus changes, or injected input are part of
the proof path. B-world is not a dependency of the public OpenMW lab.
