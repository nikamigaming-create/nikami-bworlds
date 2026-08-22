# OpenMW lab public-main curation — 2026-08-22

## Public result

The only public Git ref in `nikamigaming-create/nikami-openmw-lab` is now:

- branch: `main`
- commit: `a740618b6eb53a30d456c85991370a843e315ad7`
- tree: `91054c5c67a9d0de8b61ca7f172add57073bd8f8`
- official OpenMW base: `e47ad7782c6a3204f1bae0bcb42356e467319168`
- clean topics after the official base: 21

The topics are seven generic ESM4 parser/model-reference commits and fourteen
collision/material/filter/ownership commits. The combined public surface is 54
files, 4,174 insertions, and 96 deletions. There is no product merge, proof
route, B-world dependency, release artifact, or recovery branch in the public
ref graph.

The old public main was
`61e26bb058142db460a67c38de8abe61c426f0a7`. It was replaced with an exact
`--force-with-lease` guard; the operation would have aborted if the public ref
had moved.

Git and GitHub API verification after publication reported:

- one public branch: `main` at `a740618b6eb53a30d456c85991370a843e315ad7`;
- zero public tags;
- zero releases;
- zero open pull requests;
- default branch: `main`.

## Acceptance gates

The initial candidate was reconstructed in a fresh worktree on the
then-current official OpenMW `master`, not by squashing the product branch.
Its first 17 topics cherry-picked without a source conflict. Every later topic
was developed and verified locally, then published as an ordinary one-commit
fast-forward of `main` with no remote topic branch or pull request.

Fresh MSVC 19.44 `RelWithDebInfo` results:

- `components-tests.exe`: 1,481 / 1,481 passed;
- `openmw-tests.exe`: 497 / 497 passed;
- `openmw.exe`: linked;
- `openmw-navmeshtool.exe`: linked;
- `openmw-cs.exe`: linked;
- `git diff --check`: passed.

The 17-topic reconstructed baseline plus the projectile, weapon-data, and
explosion-record topics completed GitHub CI successfully on Ubuntu, Windows
2022, macOS ARM, and macOS Intel before the twenty-first topic was advanced to
public `main`.

## First post-curation topic: projectile records

Commit `b89f6377a8da15dcf0ea4f9efe65139191d48f46` adds typed FNV `PROJ`
record loading without adding weapon firing or combat policy. The immutable
Ultimate Edition corpus contains 155 winning projectile records: 17 use the
68-byte `DATA` layout and 138 use the 84-byte layout, with zero corpus audit
failures. xEdit independently defines the same field offsets.

The implementation uses `ESM4::Reader::getFormId` for every embedded
reference, stores model paths through `ESM::Path`, and skips unknown `DATA`
sizes without losing following-subrecord alignment. Its tests are entirely
synthetic: no retail bytes, assets, paths, named records, or private evidence
are committed. Three focused tests cover both accepted layouts and atomic
unknown-size fallback.

## Second post-curation topic: weapon data prefixes

Commit `18263dbb919530ac9abce6d7f21816db99061ce6` preserves FNV
`WEAP.DNAM`'s stable 16-byte animation prefix and 68-byte ballistic prefix in a
dedicated `Weapon::FalloutData` structure. It does not add firing, damage,
animation playback, physics, or presentation policy.

Parsing is gated to FNV plugin versions. The linked projectile uses
`ESM4::Reader::getFormId`; truncated and non-FNV data fail closed, while data
beyond the proven prefix is skipped without losing the next subrecord. Three
new synthetic tests cover the full prefix, the animation-only prefix, the
version gate, truncation, FormID adjustment, and alignment. No retail bytes or
private artifacts are committed.

## Fourth post-curation topic: impact data sets

Commit `a740618b6eb53a30d456c85991370a843e315ad7` adds typed FNV `IPDS`
material-to-impact tables. The bounded corpus contains 73 winning records:
two use nine entries (36 bytes), three use ten entries (40 bytes), and 68 use
twelve entries (48 bytes). xEdit independently defines the same nine-to-twelve
material-slot contract.

The loader adjusts every material FormID, preserves deterministic material
ordering, gates the observed sizes to FNV versions, and skips unsupported data
without losing alignment. Three synthetic full-reader tests cover shortened
and full tables, version gating, and fallback. No impact playback or physics
policy is included.

## Third post-curation topic: explosion records

Commit `4f1fb249a70f24a4fae82385df5c435128904e71` adds typed FNV `EXPL`
record loading without executing explosion damage, force, image-space, impact,
sound, or radiation behavior. The immutable Ultimate Edition corpus contains
223 winning explosion records and every one uses the same 52-byte `DATA`
layout; xEdit independently defines the same fields and offsets.

The implementation accepts that layout only for FNV plugin versions, adjusts
all inner and outer FormIDs through `ESM4::Reader`, stores the model through
`ESM::Path`, skips unknown or other-game data atomically, and appends the new
store so existing tuple positions remain stable. Three synthetic tests cover
the accepted layout, every FormID, the version gate, and stream alignment.

The build directory is local at
`D:\code\nikami-openmw-public-clean\build-tests`. The clean checkout is
`D:\code\nikami-openmw-public-clean`, where local `main` tracks
`origin/main` exactly.

## Local recovery boundary

No historical implementation was discarded. Before any public mutation, all
existing Git refs were captured in:

- bundle: `D:\code\archives\nikami-openmw-lab-pre-clean-20260822.bundle`
- bytes: 107,420,187
- SHA-256: `313C6C6BEE033FFA8854D987BF00E31E08CEF49A4618C696E56675B35A015EEB`
- `git bundle verify`: passed; complete history recorded

The bundle contains the former public `main`, all former public work/backup
branches and tags, and all local recovery/product/clean lane heads as they
existed before curation.

The six former GitHub prereleases were separately preserved because a Git
bundle does not contain release assets or release notes:

- directory:
  `D:\code\archives\nikami-openmw-lab-releases-pre-clean-20260822`
- releases: 6
- assets: 11
- bytes: 946,450,318
- digest mismatches against GitHub metadata: 0
- exact metadata and asset inventory: `RELEASES.md` in that directory

## Restore procedure

Verify the immutable bundle before using it:

```powershell
git bundle verify D:\code\archives\nikami-openmw-lab-pre-clean-20260822.bundle
Get-FileHash -Algorithm SHA256 D:\code\archives\nikami-openmw-lab-pre-clean-20260822.bundle
```

Recover into a new directory; never overwrite the clean main checkout:

```powershell
git clone D:\code\archives\nikami-openmw-lab-pre-clean-20260822.bundle D:\code\nikami-openmw-lab-recovered
git -C D:\code\nikami-openmw-lab-recovered show-ref
```

Important preserved heads include:

- recovery implementation: `8594ef323f548f8b01c86bdf7149ccdf03361933`;
- runnable maintainable product: `61e26bb058142db460a67c38de8abe61c426f0a7`;
- pre-curation local main: `9b9bb9328956998189454b99c660e861f4e8827e`;
- pre-curation remote main: `ce996f10773f9f06214de507d439926dd0ca40e9`;
- clean collision lane: `e65a8bbd9e54e99c9f8236dcd1f000cee0344dac`;
- clean extraction lane: `e6268c309eee4577b6cf649d7de9bc0c28adc38a`.

## Operating model from here

Public `main` is the acceptance lane. Experimental product behavior is mined
locally for an implementation-neutral contract, immutable evidence, synthetic
tests, and the smallest existing OpenMW ownership boundary that can express
it. A topic reaches public `main` only after it rebases on current official
OpenMW and passes its owning full test binaries and link gates.

B-world is not a dependency or staging branch for the public OpenMW lab. Its
separate repository may still provide local orchestration or historical
reference if a future task explicitly needs it, but no B-world commit is
merged merely to move OpenNV forward.

Before the next retail telemetry gate, refresh the separate current mains and
verify the expected commits supplied on 2026-08-22:

- OpenNV `main`: `db074bb`;
- `nikami-bworlds` `main`: `93fa6a5`.

The refresh was completed after the public-lab cleanup. OpenNV local `main`
and `origin/main` both resolve to
`db074bbd19644f8be57011e0f6197a900ec406cd`. B-world `origin/main` resolves to
`93fa6a52c6f980b8c8491b12fa3395951636ac99`; its divergent unused local
`main` at `01e90a9040512b54f089c5add0be0c13e2694a2d` was preserved as local branch
`codex/bworlds-main-pre-sync-20260822` before local `main` was aligned. The
dirty active B-world feature worktree was not checked out, rebased, merged, or
otherwise modified.

The next parity gate is retail camera/placement/animation telemetry. Actor
identity/export/runtime parity gates are already merged, but visual parity is
not yet claimed. For the retail observation step:

- use the 32-bit observer at
  `D:\Dev\Tools\Ghidrust\builds\wow64-i686-codex-nogpu\i686-pc-windows-msvc\release\ghidrust.exe`;
- run one long-lived `mcp` session;
- attach with `process_attach` in `observe` mode;
- do not chain separate CLI process commands;
- do not use UI automation, focus changes, or injected input;
- keep `D:\Dev\Tools\Ghidrust\workspace\evidence\falloutnv_1_4_0_525\camera`
  private and never distribute its binary or evidence contents.
