# OpenMW Fallout fast-finish plan — 2026-08-26

This is the authoritative handoff for resuming the curated OpenMW lab after a
Codex model switch. It replaces conversational estimates with an executable
queue. The target is a clean, current, Fallout: New Vegas feature-development
base. It does not claim literal retail or visual parity.

## Model and execution mode

- Recommended throughput setting: `gpt-5.6-luna` with `high` reasoning.
- Escalate only difficult ownership, transaction-safety, or architecture
  reviews to `gpt-5.6-luna` with `max` reasoning. `max` is a quality-first
  setting and may be slower; it is not the default for routine compilation,
  test repair, Git bookkeeping, or CI monitoring.
- Stay in this task so the completed history remains available. Treat this
  file and `docs/openmw-public-main-curation-20260824.md` as the durable state
  if conversation context is compacted.
- Work persistently through safe local edits, tests, ordinary commits, topic
  pushes, fast-forward publication, CI monitoring, topic deletion after green
  `main`, bundles, and provenance updates. Never force-push or rewrite public
  history without new explicit authorization.

Official model reference:
https://developers.openai.com/api/docs/models/gpt-5.6-luna

## Outcome and exclusions

Finish the previously recovered, non-VR FNV feature-ready lane as bounded
OpenMW-native contracts. Preserve wanted behavior, not historical source
shape. The following are excluded from this lane:

- B-world and Kami-world abstractions;
- OpenNV/Godot and Starfield experiments;
- FO3, TTW, JAM, and VR/OpenXR behavior;
- proof harnesses, named retail routes, private binaries, and captured retail
  evidence;
- Lua replacement runtimes and MyGUI-owned gameplay policy;
- a claim of 1:1 retail or visual parity.

Existing MyGUI APIs may own presentation after a native model/controller API
exists. Lua may be used only where the existing upstream API explicitly owns
the behavior; it is not a substitute for missing C++ engine services.

## Exact starting state

Public engine repository: `D:\code\nikami-openmw-public-clean`

- public `main`: `1b15260c3dcbc74203c3400886d91303ab253b48`;
- public `main` tree: `0035e6cad1afb9239efe282c77d97673911e7c5c`;
- last green `main` workflow: `32855446251`;
- pending RCPE topic: `codex/openmw-fallout-recipe-records-20260825`;
- pending RCPE commit: `fafc908066732a95e446170c0cc6d34888c9b242`;
- pending RCPE tree: `ce0c6c2429196cea2a41a2be80720f72ef1ece70`;
- authoritative green RCPE workflow: `32873877733`;
- open pull requests: zero;
- remote heads: `main` and the pending RCPE topic only;
- remote tags and releases: zero;
- worktree: clean, checked out on the RCPE topic.

Official OpenMW `master` was
`44c14fe735cd8beeda800cba968f24f5e6a912bd` when this handoff was written.
The public lane's recorded official base is
`03e02d034fed3e3c1d65f0ba09767df64c58b78e`, 59 official commits behind that
observed head. Resolve the live upstream SHA again immediately before the sync;
do not assume it has stopped moving.

Recovery/product repository: `D:\code\nikami-openmw-lab`

- preserved recovery head:
  `8594ef323f548f8b01c86bdf7149ccdf03361933`;
- strict crafting transaction source material:
  `50d36ebddef4fb45ecb4279f9993431b4310331a`;
- station activation source material: `12338bf5d0`;
- authored campfire route source material: `47aee54d90`.

Provenance repository: `D:\code\nikami-worlds-openmw-cleanup`

- branch: `codex/openmw-provenance-repair-20260821`;
- head before this plan: `f66bf5f9fdcf067c7f350e755a0ad476997c6d59`;
- latest published-main bundle:
  `D:\code\archives\nikami-openmw-lab-main-recipe-category-20260825-v20.bundle`;
- bundle SHA-256:
  `C114362F2DDDB05F97743CD192D9721A814B5E92BB566EAA6AB28C8F42A2988F`.

## Non-negotiable acceptance contract

For every public feature commit:

1. Begin from the current public `main` after the preceding main workflow is
   green.
2. State one implementation-neutral behavior contract and its evidence limit.
3. Use existing OpenMW APIs and ownership boundaries before adding a service.
4. Read authored Fallout values from typed game data. Keep binary layout facts
   as named format constants. Put genuine engine policy behind one explicit
   injected/configured owner. Do not scatter hardcoded IDs, thresholds,
   transforms, timing values, or fallback behavior.
5. Add synthetic deterministic tests. Never add retail bytes, assets, save
   payloads, decompiler output, private paths, named actors, or named proof
   routes to the public engine.
6. Run `git diff --check`, focused tests, complete `components-tests` and
   `openmw-tests`, and link every owning executable/library affected by the
   change.
7. Push only a topic expected to pass. Require Ubuntu, Windows 2022, Intel
   macOS, and ARM macOS success before fast-forwarding `main`.
8. Require the post-push `main` matrix to pass before publishing the next
   public slice. Local preparation of the next slice may continue while that
   matrix runs.
9. Delete the temporary remote topic only after green `main`; verify one
   public head, zero open PRs, zero experimental tags/releases, and a clean
   worktree.
10. Create a new, never-overwritten bundle, verify it, hash it, and update the
    local provenance ledger.

## Phase 0 — close the already-green RCPE slice

Do this before mining more recovery code.

1. Reconfirm that local and remote topic heads both equal `fafc908066` and that
   workflow `32873877733` succeeded on all four platforms.
2. Fast-forward local `main` to the RCPE topic and push `main` normally.
3. Wait for the workflow whose `headBranch` is `main` and whose `headSha` is
   `fafc908066...`; require all four jobs to pass.
4. Delete the remote and local RCPE topic labels, fetch with prune, and verify
   that the public remote exposes only `main`.
5. Create and verify, without overwriting another file:
   `D:\code\archives\nikami-openmw-lab-main-recipe-records-20260826-v21.bundle`.
6. Record its SHA-256, exact tree, topic and main workflow URLs, tests, scope,
   and exclusions in `docs/openmw-public-main-curation-20260824.md`; commit and
   push the provenance branch.

RCPE is a typed FNV recipe-record contract only. Do not describe it as crafting
transactions, station activation, crafting UI, or retail parity.

## Phase 1 — synchronize official OpenMW

1. Record and bundle the exact post-RCPE public head before mutation.
2. Fetch `upstream/master`, resolve its live SHA, and create a new local
   `codex/openmw-upstream-sync-20260826` topic from public `main`.
3. Integrate official upstream without rewriting existing public history.
   Resolve conflicts in favor of current upstream APIs while preserving each
   accepted Fallout contract and its tests.
4. Run the full owning build/test gate and four-platform topic workflow.
5. Fast-forward and push `main`, require the post-push matrix, delete the
   temporary topic, create the next verified bundle, and update provenance.

No new Fallout behavior belongs in the upstream-sync commit.

## Phase 2 — freeze the recovery inventory once

Before implementing the runtime trains, write one table that maps each wanted
FNV behavior to:

- historical source commits/files used only as evidence;
- current OpenMW API owner;
- synthetic tests that survive or need replacement;
- authored data/configuration owner;
- disposition: `reuse contract`, `rewrite implementation`, or `exclude`;
- the one delivery train below that owns it.

Do not repeatedly re-audit the full recovery tree after this table exists.
Time-box archaeology: if the old implementation cannot explain its contract
within one focused review, recover the behavior from tests and typed Fallout
data instead of untangling its incidental architecture.

## Phase 3 — five vertical delivery trains

Keep exactly one public topic in flight. Prepare the next train locally while
CI runs, but do not publish it until the preceding `main` workflow is green.
Each train should produce one understandable public capability commit. Split a
train only when it cannot be explained by one contract or reviewed without an
unrelated subsystem.

### Train A — crafting

Contract: typed RCPE/RCCT data can plan and atomically commit a craft operation
against supported native inventory stores, and an authored station can invoke
that service through a native action.

- Recover the transaction invariants and tests from `50d36ebdde`.
- Recover station dispatch intent from `12338bf5d0`; use the named campfire
  route only as private evidence, never as a public hardcoded location.
- Remove hardcoded workbench, reloading-bench, player, currency, category, and
  script IDs. Resolve authored identities from records or one explicit injected
  Fallout crafting configuration owner.
- Preserve two-phase plan/commit, snapshot revalidation, supported item types,
  condition/skill gates, output preconstruction, and fail-closed behavior.
- Hold crafting presentation until the transaction and action APIs exist.

### Train B — combat and loot

Contract: FNV inventory condition, loot transfer, weapon damage, projectile,
and impact behavior use native OpenMW stores and the already-published typed
records/collision identity.

- Start with inventory/condition and atomic transfer ownership.
- Connect weapon/projectile/damage behavior only through existing mechanics,
  world, physics, and sound APIs.
- Keep VATS, animation presentation, and retail tuning out unless they are
  independently evidenced and required by the contract.
- Split into at most three commits only if inventory transactions, combat
  calculation, and projectile publication cannot be reviewed together.

### Train C — generic Pip-Boy and HUD

Contract: a non-VR FNV controller exposes inventory, stats, quests, notes, and
HUD state through native OpenMW interfaces; presentation consumes that state
without owning gameplay policy.

- Reuse current window/input/store APIs first.
- MyGUI may render the view after the controller contract is tested.
- Exclude wrist attachment, OpenXR input, live-frame surfaces, VR shaders, and
  retail sidecars.

### Train D — physical terminals and lockpicking

Contract: typed TERM/reference data dispatches a native terminal session, and
locked references dispatch a native lockpick session, with deterministic state
transitions and no named-world shortcuts.

- Terminal runtime/action and lockpick runtime/action may be separate commits.
- Presentation follows the tested session models through existing UI APIs.
- Fail closed on unsupported scripts, malformed data, or unavailable owners.

### Train E — quest, persistence, and AI

Contract: one natural FNV quest route can load required state, execute the
minimal supported native result-script/AI operations, save, reload, and resume
without a product-specific fallback stack.

- Select the route by required record/command coverage, not by a named retail
  actor or cell in public code.
- Keep save parsing, quest-state mutation, command execution, and AI package
  ownership explicit and independently tested inside the train.
- Unsupported commands remain explicit blockers; do not guess behavior.

## Throughput rules

- No more record-field micro-slices unless a missing typed record is a hard
  dependency. RCPE is the last currently known crafting-data prerequisite.
- Do not push exploratory compile failures. Preflight all changed translation
  units and focused tests locally first.
- While topic CI runs, mine and test the next train in a separate local
  worktree. Never expose that next topic publicly early.
- While post-push `main` CI runs, continue local preparation, but do not publish
  the next train until `main` is green.
- If a train spends more time explaining old code than rewriting its contract,
  stop porting and reimplement against current APIs.
- Fix only source/test failures caused by the train. Retry CI only for a
  demonstrated transient infrastructure failure.
- Maintain a changed-file checklist for format constants, authored values,
  policy injection, Lua/MyGUI ownership, private paths, portability, tests, and
  unrelated files. This is the zero-magic/upstream review gate.

## Completion gate for returning to new feature work

The migration experiment is closed only when all of the following are true:

- RCPE, the current official upstream sync, and all five trains are on public
  `main`;
- every final topic and post-push `main` workflow is green on four platforms;
- a fresh clone resolves to the documented head and builds/tests through the
  owning suites;
- the public remote exposes only `main`, with zero open PRs and zero
  experimental tags/releases;
- all public Fallout additions pass the final authored-data/configuration and
  private-artifact audit;
- every published state has a unique verified recovery bundle and ledger
  entry;
- excluded experiments remain recoverable locally but absent from public
  engine history.

At that point the lab is feature-ready. It is still not evidence of literal
retail parity. The 144 differential cases and camera/placement/animation visual
evidence remain a separate parity queue and must not silently expand this
migration queue.

## Private observation boundary

If a later contract genuinely requires new retail evidence, keep it private:

- observer:
  `D:\Dev\Tools\Ghidrust\builds\wow64-i686-codex-nogpu\i686-pc-windows-msvc\release\ghidrust.exe`;
- evidence:
  `D:\Dev\Tools\Ghidrust\workspace\evidence\falloutnv_1_4_0_525\camera`.

Use one long-lived `mcp` session and `process_attach` in `observe` mode. Do not
use UI automation, focus changes, or injected input. Never distribute the
binary or evidence.

## Exact resume prompt

Use this after switching the current task to Luna:

> Continue the OpenMW Fallout cleanup from
> `D:\code\nikami-worlds-openmw-cleanup\docs\openmw-fast-finish-plan-20260826.md`.
> Treat that file and the curation ledger as authoritative. Begin at the first
> incomplete phase, verify every recorded ref before mutation, and continue
> persistently through safe in-scope work. Keep one public topic at a time,
> overlap CI with local preparation, use current OpenMW APIs, enforce authored
> Fallout data/configuration ownership, and do not claim retail visual parity.
> Do not merge the mixed recovery branch, force-push, use UI automation, or
> publish private evidence.
