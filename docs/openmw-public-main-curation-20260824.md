# OpenMW lab public-main curation — 2026-08-24

## Published result

The public `nikamigaming-create/nikami-openmw-lab` repository now exposes one
remote branch:

- branch: `main`
- commit: `5797321209487d873734f0e934dbe1a83b6483d0`
- tree: `1fe9ee70b6581e39c34c153c312295117c06cca1`
- official OpenMW base: `e47ad7782c6a3204f1bae0bcb42356e467319168`
- remote topic branches: none
- open pull requests: none
- remote tags: none
- releases: none

The previous public `main` (`5a62ddaa38c6acc98a1d5f68afcc9d3ba5ad5d7e`) was
advanced by an ordinary fast-forward after the identity topic workflow
(`32728071203`) and the post-push `main` workflow (`32731233982`) both passed
all four platform legs. The former IPCT topic PR (#57) is merged; no PR remains
open.

The published commit is the bounded Fallout UI/content identity slice on top of
the earlier zero-magic audit. It detects the first recognized ESM4 base game in
configured content order, records the identity in `ESMStore`, centralizes the
New Vegas UI policy, and provides a safe pre-World default. Synthetic tests
cover every supported game enum, case-insensitive master names, ordering, and
unknown/add-on content. It does not add private retail bytes, product assets,
or a parallel UI/runtime implementation.

The audit scope is the Fallout lab surface touched by this slice. It is not a
claim that every unrelated structural literal in the entire upstream OpenMW
codebase should be replaced with user configuration; schema facts and API
sentinels remain named constants, while behavior policy is injected data.

## Acceptance evidence

Focused local checks on the clean checkout (`D:\code\nikami-openmw-public-clean`):

- collision-filter contract: 9 / 9;
- ESM4 loader fixtures (AMMO, EXPL, IPCT, IPDS, PROJ, WEAP): 20 / 20;
- callback/closest-hit regression fixtures: 7 / 7;
- game identity/UI policy fixtures: 6 / 6;
- direct MSVC syntax compilation of all changed translation units: passed;
- `git diff --check`: passed.

The local full CMake build is blocked before source compilation by the host's
unrelated OSG header mismatch (`GL_COMPRESSED_SRGB_S3TC_DXT{1,3,5}_EXT` is
missing). The authoritative post-publication GitHub workflow passed all legs:

- run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32731233982;
- Ubuntu: success;
- macOS ARM: success;
- macOS Intel: success;
- Windows 2022: success.

The topic workflow for the exact same commit also passed all legs:

- run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32728071203;
- Ubuntu, macOS ARM, macOS Intel, and Windows 2022: success.

The earlier pre-publication four-platform run also passed:

- https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32683128633

## Recovery and provenance

Before deleting the temporary remote topic ref, the exact published and local
recovery heads were captured in:

- bundle: `D:\code\archives\nikami-openmw-lab-ui-identity-20260824.bundle`;
- SHA-256: `00FF010B8F9BA17DCBA90FF0E3D78D3939DD9D3EA89510CE4E96516E06A9803A`;
- `git bundle verify`: passed; complete history recorded.

The earlier curated bundle remains at:

- bundle: `D:\code\archives\nikami-openmw-lab-curated-20260824.bundle`;
- SHA-256: `9C87DA956327B7B4E3046A391F762E1644C08D22307DA70944294F81C6D958EE`;
- `git bundle verify`: passed; complete history recorded.

The new bundle contains `main`, the identity topic, and the two preserved
recovery/product heads. The local recovery branches remain available; only the
public remote topic ref was removed. The earlier pre-curation bundle remains at
`D:\code\archives\nikami-openmw-lab-pre-clean-20260822.bundle` with its
original digest recorded in the 2026-08-22 ledger.

The engine-side audit record is
`D:\code\nikami-openmw-public-clean\docs\openmw-zero-magic-audit-20260823.md`.

## Fresh pull / exact resume

Fresh consumers can start from the clean public lane:

```powershell
git clone https://github.com/nikamigaming-create/nikami-openmw-lab.git D:\code\nikami-openmw-fresh
git -C D:\code\nikami-openmw-fresh switch main
git -C D:\code\nikami-openmw-fresh rev-parse HEAD
# expected: 5797321209487d873734f0e934dbe1a83b6483d0
```

The next implementation slice is the data-only Fallout `WTHR` record contract
(loader, typed store registration, and synthetic tests). It starts locally from
`main` and is published only after its owning focused tests, complete
component/engine tests, and the four-platform workflow pass:

```powershell
git -C D:\code\nikami-openmw-public-clean switch -c codex/openmw-fallout-weather-records-YYYYMMDD main
```

There is no pending local topic for this handoff. The next evidence gate is
retail camera/placement/animation telemetry; actor identity/export/runtime
parity is merged, but visual parity is not claimed.

## Private observation boundary

Keep the following private and never distribute its binary or evidence:

- observer: `D:\Dev\Tools\Ghidrust\builds\wow64-i686-codex-nogpu\i686-pc-windows-msvc\release\ghidrust.exe`;
- evidence: `D:\Dev\Tools\Ghidrust\workspace\evidence\falloutnv_1_4_0_525\camera`.

The observer must run as one long-lived `mcp` session with
`process_attach` in `observe` mode. No UI automation, focus changes, or
injected input are part of the proof path. B-world is not a dependency of the
public OpenMW lab.
