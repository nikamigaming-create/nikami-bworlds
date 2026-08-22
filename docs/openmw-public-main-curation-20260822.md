# OpenMW lab public-main curation — 2026-08-22

## Public result

The only public Git ref in `nikamigaming-create/nikami-openmw-lab` is now:

- branch: `main`
- commit: `440e4dcc41251317d2564b9628c4ffc29073b39a`
- tree: `2206377991a33e2ac0a21854945816a4df232818`
- official OpenMW base: `e47ad7782c6a3204f1bae0bcb42356e467319168`
- clean topics after the official base: 17

The 17 topics are the three generic ESM4 parser/model-reference commits and
the fourteen collision/material/filter/ownership commits. The combined public
surface is 43 files, 3,239 insertions, and 90 deletions. There is no product
merge, proof route, B-world dependency, release artifact, or recovery branch
in the public ref graph.

The old public main was
`61e26bb058142db460a67c38de8abe61c426f0a7`. It was replaced with an exact
`--force-with-lease` guard; the operation would have aborted if the public ref
had moved.

Git and GitHub API verification after publication reported:

- one public branch: `main` at `440e4dcc41251317d2564b9628c4ffc29073b39a`;
- zero public tags;
- zero releases;
- zero open pull requests;
- default branch: `main`.

## Acceptance gates

The candidate was reconstructed in a fresh worktree on the then-current
official OpenMW `master`, not by squashing the product branch. All 17 topics
cherry-picked without a source conflict.

Fresh MSVC 19.44 `RelWithDebInfo` results:

- `components-tests.exe`: 1,469 / 1,469 passed;
- `openmw-tests.exe`: 497 / 497 passed;
- `openmw.exe`: linked;
- `openmw-navmeshtool.exe`: linked;
- `git diff --check`: passed.

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
