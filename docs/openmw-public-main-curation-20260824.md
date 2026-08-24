# OpenMW lab public-main curation — 2026-08-24

## Published result

The public `nikamigaming-create/nikami-openmw-lab` repository now exposes one
remote branch:

- branch: `main`
- commit: `5a62ddaa38c6acc98a1d5f68afcc9d3ba5ad5d7e`
- tree: `4bfa239fe3e944c134f76a08781921bce4a17681`
- official OpenMW base: `e47ad7782c6a3204f1bae0bcb42356e467319168`
- remote topic branches: none
- open pull requests: none
- remote tags: none
- releases: none

The previous public `main` (`a740618b6eb53a30d456c85991370a843e315ad7`) was
advanced by an ordinary fast-forward after the complete four-platform topic
workflow passed. The former IPCT topic PR (#57) is merged; no PR remains open.

The published commit is the bounded Fallout lab zero-magic audit. It
centralizes immutable ESM4 schema widths and version gates, moves collision
policy behind an injected configuration, names Havok/NIF/physics sentinels,
registers IPCT/IPDS in the existing store API, and adds synthetic tests and
review documentation. It does not add private retail bytes, product assets,
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
- direct MSVC syntax compilation of all changed translation units: passed;
- `git diff --check`: passed.

The local full CMake build is blocked before source compilation by the host's
unrelated OSG header mismatch (`GL_COMPRESSED_SRGB_S3TC_DXT{1,3,5}_EXT` is
missing). The authoritative post-publication GitHub workflow passed all legs:

- run: https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32686828062;
- Ubuntu: success;
- macOS ARM: success;
- macOS Intel: success;
- Windows 2022: success.

The earlier pre-publication four-platform run also passed:

- https://github.com/nikamigaming-create/nikami-openmw-lab/actions/runs/32683128633

## Recovery and provenance

Before deleting the two remote topic refs, the exact published and local
recovery heads were captured in:

- bundle: `D:\code\archives\nikami-openmw-lab-curated-20260824.bundle`;
- SHA-256: `9C87DA956327B7B4E3046A391F762E1644C08D22307DA70944294F81C6D958EE`;
- `git bundle verify`: passed; complete history recorded.

The bundle contains `main`, the former IPCT topic, the zero-magic audit topic,
and `codex/recovery-20260821-openmw-lab`. The local topic/recovery branches
remain available; only the public remote topic refs were removed. The earlier
pre-curation bundle remains at
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
# expected: 5a62ddaa38c6acc98a1d5f68afcc9d3ba5ad5d7e
```

The next implementation slice starts locally from `main` and is published
only after its owning focused tests, complete component/engine tests, and the
four-platform workflow pass:

```powershell
git -C D:\code\nikami-openmw-public-clean switch -c codex/openmw-next-slice-YYYYMMDD main
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
