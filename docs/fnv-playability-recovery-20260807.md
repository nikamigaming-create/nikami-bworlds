# Fallout: New Vegas playability recovery

Status: active recovery program  
Started: 2026-08-07  
Scope: flat `openmw.exe`, vanilla Fallout: New Vegas first; JAM only after the
vanilla promotion gate passes.

This document is the durable execution plan for recovering retail-like normal
gameplay. It supersedes pose-by-pose Pip-Boy experimentation as the active
priority, but it does not replace the whole-game scope in
`docs/fnv-100-percent-parity-plan.md` or the evidence rules in
`docs/fnv-jam-background-capture.md`.

## Active bounded subsystem: terminal hacking

As of 2026-08-07, terminal recovery is the active implementation priority at
the user's direction. The uncommitted Pip-Boy authored-animation candidate is
parked without further mutation while this slice is recovered; lockpicking is
next. Terminal completion requires generic Fallout: New Vegas behavior driven
by TERM, REFR, NOTE, script, condition, actor-skill/perk, and save-state data.
It is not satisfied by a form-ID allowlist, a read-only message-box subset, a
hardcoded password/solution, or a proof-route bypass.

The terminal gate covers activation and clean exit; authored presentation;
unlocked, locked, and password-authorized access; the hacking word/dud/attempt
rules; conditional entries and submenus; compiled result scripts and their
world effects; re-entry; save/load persistence; and safe rejection of malformed
records. Verification uses only OpenMW, one observable action at a time, with
state-based waits and retained native frames/telemetry through the canonical
unattended capture wrapper. Existing retail captures and game data may be read
as references, but the retail executable is never launched.

### Rejected terminal capture and corrected presentation contract (2026-08-07)

`run/opennv-terminal-20260807-v6-candidate6` is a failed diagnostic and must
never be cited as terminal evidence. It started at the `SSHQ01` cell origin,
left the player looking across the lobby, and invoked an off-screen placed TERM
reference directly. Its hacking modal also passed the authored
`Interface\Shared\Background\pipboy.dds` filename to MyGUI without the Fallout
`textures\` VFS namespace, so the generated missing-texture diagnostic was
stretched across the menu. The resulting green X and unrelated lobby view are
the rendering and interaction failures reported by the user.

Terminal acceptance now requires a physical-shell sequence: the authored TERM
mesh is visible before activation; the player is within ordinary activation
range and uses the normal Activate action; the camera settles on the terminal
screen; computers/hacking XML is rendered in the physical monitor presentation
rather than as a free-floating generic message box; exit restores camera and
controls; and retained frames demonstrate each state. Direct `Action::execute`
or remote-reference activation may be used only as a unit diagnostic and can
never satisfy the capture validator. The validator must also reject generated
missing-texture fallbacks and require that every XML image resolves through the
loaded VFS. No further capture is launched until these presentation and staging
conditions are implemented and covered by focused tests.

The first corrective slice now normalizes authored XML image filenames into
Fallout's `textures\` VFS namespace while preserving the authored filename;
the focused terminal/player/quest/XML gate is 107/107 passing and `openmw.exe`
builds successfully. This removes the specific generated-X failure. It does
not yet satisfy the physical-shell gate, so no replacement video is claimed.
The live TERM action now also owns a scoped physical presentation camera: its
focus and distance come from the loaded reference bounds and the player's
approach side, and the previous camera mode, orientation, and FOV are restored
on every return path. The same 107-test gate and OpenMW build pass after this
change. Ordinary in-range activation and visual framing remain unverified and
therefore still block capture.

The canonical Terminal route no longer schedules `activate-form`. Its generic
diagnostic start now places the player 80 units from the loaded TERM, aims from
the player's authored approach side using the actual post-placement first-person
camera position, retains a pre-activation native frame, and waits four seconds
before dispatching production `A_Activate`. The target-aware capture command
only releases that ordinary action after `World::getFacedObject()` equals the
expected placed FormId; it never constructs or executes the terminal action.
The route
enters, navigates, cancels, verifies camera restoration, then repeats the
ordinary activation/re-entry/exit lifecycle. Its validator requires the
expected faced FormId, two physical-camera entries and restorations, seven
paced native frames, and the complete absence of direct reference activation.
This route definition is implemented but remains unverified until the new
engine build and visual capture pass.

Candidate 7 is retained and rejected. The eight-second stage boundary arrived
before `SSHQ01` finished making the placed TERM active, so the diagnostic start
aborted and its seven repeated frames contain no terminal interaction. The
staging event now waits up to 30 seconds for the target to become active in the
player's cell and shifts all later event timestamps by the actual wait, keeping
the four-second visual intervals intact without emitting a per-frame retry log.

Candidate 8 (`run/opennv-terminal-20260807-v8-candidate8`) is also preserved as
failed, non-evidence. Loading and placement succeeded, but the original staging
pitch estimated eye height from actor bounds. All seven retained frames show
the physical terminal low in the foreground while the crosshair points at the
wall above it; the first ordinary activation faced nothing and the second faced
an unrelated record. No terminal camera or hacking session began. Staging now
recomputes pitch from `Camera::getPosition()` after forcing the post-move camera
update, and capture activation is gated on the expected faced FormId while
preserving the normal `A_Activate` path and paced downstream timestamps.

Candidate 9 (`run/opennv-terminal-20260807-v9-candidate9`) remains failed,
non-evidence. Its target gate correctly prevented both wrong activations, but
the public cached camera-position accessor returned `(0,0,0)` during the input
phase even after `updateCamera()`. That produced the same wall-facing first four
frames as candidate 8. Staging now derives the real eye point from the inverse
of the freshly updated camera view matrix, and faced-object retries no longer
emit a bogus execution line every frame; only a released action is logged.

Candidate 10 (`run/opennv-terminal-20260807-v10-candidate10`) is preserved as
failed, non-evidence. Its view-matrix eye point was correct and the retained
frame displayed the engine's `Terminal` interaction label, but OpenMW's camera
pitch did not persist through the later first-person update. Later candidates
showed that this direct geometric angle was in fact the only view to produce
the `Terminal` interaction label; the previous sign diagnosis is superseded.

Candidate 11 (`run/opennv-terminal-20260807-v11-candidate11`) is preserved as
failed, non-evidence. The corrected camera pitch was transient: OpenMW restores
first-person pitch from the player reference's X rotation before the four-second
frame. Staging now writes the corresponding player pitch (`-cameraPitch`) via
the normal world rotation path and synchronizes the camera, matching the engine's
own `-ptr.rot[0]` first-person ownership contract.

Candidate 12 (`run/opennv-terminal-20260807-v12-candidate12`) is preserved as
failed, non-evidence. Persisting X rotation through `World::rotateObject` still
produced the byte-identical pre-activation frame, proving that generic object
rotation is not the live first-person player-look owner. No activation, terminal
camera, or hacking session occurred. The next gate is to drive the same bounded
player-look state used by normal input, sample the resulting faced FormId, and
only then release ordinary `A_Activate`; further camera-only guesses are rejected.

Candidate 13 (`run/opennv-terminal-20260807-v13-candidate13`) is preserved as
failed, non-evidence, but resolves the record and pitch ambiguity. `00103B3C`
is the placed TERM reference (`object0x1103b3c`), whose authored base is
`000B3B6`; the faced object was first null and later an unrelated STAT. Comparing
the retained runs also confirms candidate 10's direct geometric elevation sign
was the only one to expose the engine's `Terminal` interaction label. That sign
is restored while persistence remains owned by normal `Player::pitch` input.

Candidate 14 (`run/opennv-terminal-20260807-v14-candidate14`) is preserved as
failed, non-evidence. A one-shot normal `Player::pitch` delta still did not
preserve the exact TERM reference through the paced four-second dwell: the
first ordinary activation faced no object and the second faced an unrelated
STAT. Self-drive therefore now maintains the exact placed reference as the
normal look target between staging and ordinary `A_Activate`, then releases
that bounded state before dispatching activation. This remains generic and
opt-in: it contains no terminal coordinates and does not bypass activation.

Candidate 15 (`run/opennv-terminal-20260807-v15-candidate15`) is preserved as
failed, non-evidence even though its machine validator passed. Ordinary
activation reached the exact placed TERM, the terminal camera entered and
restored twice, and hacking opened and completed, but visual inspection rejected
the result: the actor approached from a side/rear quarter and an equal-depth CRT
background covered the authored hacking glyphs as a blank gray rectangle. The
next runtime derives approach from the placed terminal's authored Z rotation,
keeps the background behind the glyph surface, and suppresses the gameplay HUD
during the physical terminal session.

### Terminal implementation checkpoint (2026-08-07)

The active recovery worktree now has the terminal mechanics path wired through
the live OpenMW action. Authored DNAM controls Science/password access; the BSA
`menus/falloutdict.txt` supplies deterministic same-length password candidates;
successful hacks and lockouts persist by placed REFR FormId; CTDA filtering,
TNAM submenus, ANAM Add Note, terminal sounds, and supported compiled result
scripts execute through shared runtime services. Learned notes persist and feed
the Pip-Boy Notes page. DATA 0/1/2/3 NOTE payloads are preserved rather than
being rejected. Hacking word counts now use the loaded
`iHackingMinWords`, `iHackingMaxWords`, and `fHackLevelMult` records instead
of the temporary twelve-word cap, and a successful hack applies the authored
difficulty-specific XP GMST. A reusable Bethesda Tile XML parser now preserves
symbolic entities, nested trait expressions, and recursively expanded prefab
fragments as the foundation for the computers, hacking, and lockpick menus.
The parsed named-tile dependency graph now drives the first OpenMW modal
presenter: authored frame, message, and list tile geometry plus the BSA-declared
background are applied to normal terminal pages. The live hacking surface now
uses the authored 920x630 `hacking_menu.xml` geometry: two 28-row memory
columns, address prefixes, nineteen visible glyphs per row, twelve data glyphs
per address, word targets that may span a visual row, same-row bracket targets,
and the authored output-log column. Hover and controller focus select the
complete logical target, Back cleanly returns an explicit cancellation, and
the layout is included in both runtime installation manifests. Terminal
difficulty thresholds are GMST-driven, and the loaded `ComputerWhiz` perk now
grants and persists its single retry after the first lockout without a fixed
FormId dependency. The focused player-state, terminal, quest-runtime, and
menu-XML set is 106/106 passing, and the OpenMW target builds successfully.

This checkpoint is not the terminal exit gate. The hacking grid is authored
and interactive, but the surrounding presenter remains a blocking MyGUI host.
Promotion remains blocked on authored boot/type/flash timing, complete
`computers_menu.xml` tile population and transitions, image and voice notes,
the leveled DNAM flag, the compiled-opcode census, and a declared canonical
Terminal scenario with paced multi-terminal save/reload capture. The mandatory
OpenMW preflight passed against runtime `terminal-authored-grid-controls-v2` (52 checks,
zero failures), but no terminal process or video was started because Terminal
is not yet a scenario declared by the canonical capture recipe.

A read-only census of the installed official ESMs found 515 physical TERM
records: 513 four-byte DNAM payloads and two legal three-byte payloads. The
flags byte is zero on 192, leveled on 9, unlocked on 304 (including the two
three-byte records), leveled+unlocked on 4, unlocked+alternate-colors on 1,
hide-welcome on 2, and unlocked+hide-welcome on 3. Open/unlocked access is
already honored. The thirteen leveled records remain fail-closed as an open
semantic gate until the exact `fLeveledLockMult`/player-level rule is verified;
we will not invent a scaling formula from the field name. Alternate colors and
hide-welcome presentation are also explicit remaining authored-flag work.

## Problem statement

Normal gameplay regressed because proof drivers, save-specific replay logic,
input routing, animation control, UI generation, rendering, and telemetry were
allowed to share production hot paths. The visible tilted Pip-Boy is not an
isolated camera defect: engine commit `843e916fb9` deliberately holds
`pipboy.kf` at `0.333333` seconds, disables the waver animation, and freezes the
sample. That commit was incorrectly tagged as a known-good Pip-Boy state even
though it proved one frame rather than a complete playable transition.

The current recovery must restore one authoritative path from authored game
data to player-visible behavior:

```text
physical input
    -> gameplay/menu state transition
    -> inventory and equipped-slot transaction
    -> WEAP/IDLE/KFFZ/NIF/KF semantic resolution
    -> shared first-/third-person state
    -> renderer and live GUI presentation
```

Telemetry observes this path. It must never drive it during a normal session.

## Non-negotiable rules

- OpenMW is the only engine that may be launched during recovery and live
  verification. Do not launch `FalloutNV.exe`. Retail is a read-only reference
  corpus: previously retained captures plus authored ESM/BSA/NIF/KF data only.
- Preserve all dirty worktrees and experimental runtimes until their source,
  binary, resources, profile, environment, and save provenance are recorded.
- Never promote a runtime from a dirty or unidentified source tree.
- Never call a single held frame, screenshot, launch, or component-test pass a
  playable baseline.
- Normal gameplay may not depend on a proof environment variable, generated
  inventory record, Save330-specific branch, frozen KF time, synthetic contact
  transform, or hard-coded weapon FOV.
- Behavior must be derived from loaded ESM/BSA records and authored NIF/KF
  controllers, plus generic engine rules checked against retained retail evidence.
- Test vanilla FNV before JAM. A JAM failure must not obscure a vanilla engine
  regression.
- For screenshot or video evidence, follow
  `docs/fnv-jam-background-capture.md`: run the mandatory preflight, use only
  `scripts/Invoke-FNVJamBackgroundCapture.ps1` with its OpenMW target, retain
  native evidence, and never use Windows app control or foreground input.
- Test only flat `openmw.exe` during this recovery. Do not launch VR.

## Paced interaction policy

Automated in-game actions must wait for observable state completion. Fixed
delays are a lower bound, not the completion signal.

| Transition | Required observation | Minimum settle | Failure timeout |
|---|---|---:|---:|
| Ordinary button press | press edge observed | 100 ms before release | 1 s |
| Ordinary button release | release edge observed | 150 ms after release | 1 s |
| Draw or holster | draw state and expected animation phase agree | 750 ms | 4 s |
| ADS raise/lower | aim state, FOV ownership, and pose agree | 500 ms | 3 s |
| Reload | authored reload group reaches completion/exit | 250 ms after completion | authored duration + 3 s |
| Pip-Boy raise | physical presentation and menu-open state agree | 750 ms after held state | 5 s |
| Pip-Boy page change | selected pane and live GUI frame agree | 350 ms | 3 s |
| Pip-Boy item use/equip | inventory transaction is committed | 500 ms | 4 s |
| Pip-Boy lower | menu closed, arms released, draw state restored | 750 ms | 5 s |
| First-/third-person switch | camera mode and actor presentation agree | 500 ms | 3 s |
| Dialogue enter/exit | GUI mode and camera ownership agree | 500 ms | 5 s |
| Cell transition | destination loaded and player controls restored | 1 s | 20 s |

If the observation does not arrive before the timeout, record a failure and
stop that route. Do not issue the next input to force progress. Capture routes
must make each major state visible for long enough to inspect; the existing
full-proof three-second phase visibility remains valid.

## Candidate ladder

Build each candidate from a clean isolated worktree with the same compiler,
configuration, installed resources, vanilla profile, asset load order, save,
and settings:

| Order | Commit | Purpose |
|---:|---|---|
| 1 | `babcda4f57` | Last explicit playable weapon-fire checkpoint |
| 2 | `41fc45f2e5` | Native FNV compatibility before Pip-Boy integration |
| 3 | `b1c0b2d841` | Clean Aug. 5 candidate; 850 tests passed, interactive pending |
| 4 | `5fb9e4e0aa` | Large Pip-Boy/player-control integration boundary |
| 5 | `483127f6d2` | Save330 replay-stack boundary |
| 6 | `843e916fb9` | Frozen retail-mode-3 Pip-Boy sample |

The first candidate that fails after a passing candidate defines the initial
regression interval. Do not assume commit order across unrelated recovery
branches; record parentage and tree identity in each build manifest.

## Phase 0: make the test subject deterministic

1. Inventory every candidate source tree and packaged runtime.
2. Record clean/dirty state, commit, tree, branch, binary SHA-256, resource
   provenance, build configuration, runtime DLL set, profile, settings, ESM/BSA
   load order, save hash, and effective `OPENMW_*`/`NIKAMI_*` environment.
3. Repair the launcher so its declared player runtime exists and matches one
   immutable promoted manifest. Missing configured paths must fail with a
   direct remediation message; they may not silently select an experiment.
4. Make proof/diagnostic variables forbidden in normal-session manifests.
5. Preserve current experimental packages as rejected or forensic candidates;
   do not delete or overwrite them.

Exit gate: a dry run can name exactly which source, binary, resources, profile,
settings, content, save, and environment would be used without launching.

## Phase 1: locate the playable boundary

Run the same paced vanilla route on every clean candidate:

1. Load the immutable test save.
2. Walk, run, jump, crouch, and turn.
3. Test unarmed primary attack and right-button block.
4. Open inventory/Pip-Boy, equip a pistol, close it, and verify the pistol
   reaches the correct hand through the normal equipped-slot transaction.
5. Draw, holster, fire, reload, and ADS.
6. Repeat with a two-handed weapon and a melee weapon.
7. Use an aid item and verify inventory count/effect state.
8. Visit STATS, ITEMS, DATA, and MAP, allowing every transition to settle.
9. Switch first-/third-person repeatedly with weapon drawn and holstered.
10. Enter and exit dialogue and one interior/exterior transition.
11. Continue normal play for at least 20 minutes without synthesized actions.

Each route retains transition events, animation group/source/time, equipped
slots, input edges, GUI state, camera/FOV ownership, native frames at declared
checkpoints, logs, hashes, and an explicit pass/fail report.

Exit gate: one passing candidate and the next failing candidate are identified,
or all candidates fail and the older promoted patch-queue baseline is added to
the ladder.

## Phase 2: restore bounded subsystems

Start from the best-playing clean candidate. Transplant and validate only one
bounded subsystem at a time:

1. Inventory and equipped-slot transactions.
2. Ordinary unarmed, melee, and ranged combat.
3. Shared first-/third-person animation selection and attachment.
4. Live Pip-Boy GUI without physical presentation.
5. Authored physical Pip-Boy raise, hold, interaction, and lower.
6. Data-driven ADS using `WEAP` sight FOV and authored selectors.
7. UI/world shader separation and material-driven compatibility.
8. JAM/xNVSE compatibility.
9. Read-only, rate-limited diagnostics.

After every change, rerun focused tests and the complete paced vanilla route.
Do not land another multi-thousand-line cross-system integration commit.

## Required normal input matrix

| Player state | Primary input | Secondary input |
|---|---|---|
| Unarmed | H2H attack | Block only |
| Melee weapon | Melee attack | Block only |
| Ranged, holstered | Retail draw/aim transition; never phantom fire | Retail draw/aim transition |
| Ranged, drawn | Fire | ADS |
| Pip-Boy open | Live GUI action | Live GUI back/secondary action |
| Other GUI open | GUI only | GUI only |

Every action is edge-driven and gated by current mode, control switches,
equipped item, draw state, and animation availability. Proof code may not set
normal attack/aim fields, rotate the player, or retry attacks.

## Promotion gates

A runtime is promoted only when all are true:

- Clean, reproducible source and build.
- Binary and installed resources come from the same commit/tree.
- Focused and component tests pass.
- Paced vanilla route passes from start to finish.
- Pip-Boy completes raise, hold, interaction, equip/use, and lower.
- First-/third-person equipped state and animation family agree.
- Unarmed secondary input blocks without ADS or phantom actions.
- Weapon fire, reload, ADS, holster, and equipment restoration pass.
- Menu, HUD, Pip-Boy, map, icon, skin, hand, weapon, and world shader gates pass.
- No normal-run proof variables, proof inventory, save-specific behavior,
  frozen KF times, generated Pip-Boy terminal, or synthetic contact transforms.
- Twenty-minute sustained session has no stuck input, animation, GUI, camera,
  or FOV ownership.
- OpenMW evidence is compared with already-retained retail reference artifacts;
  no new retail runtime session is part of recovery verification.
- Interactive gameplay is explicitly accepted; `pending-user-test` is not a
  promotable state.

## Active first actions

1. Add the machine-readable recovery contract.
2. Add a read-only provenance auditor and contract tests.
3. Run it against the existing candidate runtimes and preserve the report.
4. Prepare clean candidate worktrees/build manifests.
5. Run canonical preflight before the first engine launch.

`scripts/Test-FNVGameplaySourceOwnership.ps1` is the read-only architectural
gate. It rejects normal GUI dependence on proof/save environment variables,
save-specific production routes in `engine.cpp`, frame-scheduled Pip-Boy
showcases, telemetry/trace coupling, and frozen Pip-Boy KF times. Its findings
are promotion failures even when a screenshot route passes.

The input regression begins in `5fb9e4e0aa`. That commit globally replaces
the shared right-mouse inventory binding with `A_FalloutAim`, checks ADS every
update, supports only the drawn-weapon path, and hard-codes an FOV of 35.
There is no unarmed/melee secondary-action fallback to the ordinary block
path. It also assigns the physical Pip-Boy to `P` in the shared default map.
This directly explains the reported unarmed right-click behavior and makes
the remedy concrete: secondary action must dispatch from current equipped
item/draw/GUI state, ADS FOV must come from the equipped `WEAP` data, and FNV
defaults must come from the FNV content profile rather than global bindings.

## Execution record: 2026-08-07

The first baseline pass found two capture-harness defects before identifying an
engine baseline:

- `Invoke-FNVRealSaveCapture.ps1` enabled
  `OPENMW_PLAYABLE_SESSION_BACKGROUND=1` while waiting for an exact-title
  window. Early candidates intentionally create a hidden flat window for that
  switch, so the old route could never satisfy its own window gate. The route
  now explicitly disables the hidden-background mode; it still uses no focus,
  foreground activation, Windows app control, or host input.
- The RealSave validator required health/AP telemetry and the later
  `Player identity restored` wording. The first native-FOS-capable candidate
  emits the same transform/camera denominator without health/AP and reports a
  normalized `validated native Player` FormID pair. The validator now accepts
  both telemetry generations while retaining the exact worldspace, position,
  rotation, and data-derived player FormID comparisons.

Candidate results so far:

| Candidate | Component tests | Canonical visible cold load | Result |
|---|---:|---|---|
| `babcda4f57` | 1,555 pass, 7 fixture skips | not rerun after harness fix | pre-native-FOS comparison only |
| `41fc45f2e5` | 1,570 pass, 7 fixture skips | pass | first native-Save330 recovery baseline |
| `b1c0b2d841` | 1,600 pass, 0 skips | visible window, native `.fos` rejected | playable-era engine but not a native-Save330 baseline |
| `5fb9e4e0aa` | 1,570 pass, 7 fixture skips | pass | cold-load capable; rejected at architectural promotion gate |
| `483127f6d2` | 1,577 pass, 8 fixture skips | pass | upright D01 visual failure; D02 first weapon pose stuck |
| `843e916fb9` | 1,577 pass, 8 fixture skips | pass | frozen low/cut-off Pip-Boy and stranded right arm reproduced |

The passing `41fc45f2e5` proof is retained at
`run/fnv-playability-recovery-20260807/41fc45f2e5-v1-cold-load-pass-20260807-1258`.
It proves the ordinary command-line load path, native save completion, player
identity, saved worldspace/transform, restored inventory, first-person camera,
native framebuffer frame, and exact-title video. It does not yet promote the
runtime: Pip-Boy interaction, equip/use handoff, combat, ADS, camera switching,
shader/UI gates, and the sustained session remain pending.

Telemetry bloat is independently confirmed. In these candidates,
`worldViewerTraceEnabled()` treats summary telemetry as permission to log every
frame phase. A four-minute failed route produced a 196,606,789-byte stdout log.
Recovery work must separate interval telemetry from opt-in per-frame tracing
before any sustained-session gate.

The `5fb9e4e0aa` proof is retained at
`run/fnv-playability-recovery-20260807/5fb9e4e0aa-v1-cold-load-20260807-1316`.
It passes the same native Save330 cold-load denominator as `41fc45f2e5`, and
its retained native frame shows a stable Goodsprings world with both
first-person arms. It is not promotable. This is the first large Pip-Boy
integration commit, and inspection found normal GUI paths branching on
`OPENMW_FNV_PROOF_PIPBOY_SURFACE`, frame-scheduled
`OPENMW_FNV_PIPBOY_SHOWCASE` engine behavior, hand-authored presentation
transforms, and OpenXR/VR presentation code compiled into the shared non-VR
engine library. It also predates the production Save330 action routes, so its
cold-load pass says nothing about normal inventory, weapon, ADS, or Pip-Boy
interaction. These findings convert the suspected regression boundary into a
testable ownership boundary: keep native FOS/data support, but do not promote
proof presentation or shared VR ownership into ordinary desktop gameplay.

`483127f6d2` has now been exercised through its first Save330 action routes.
Its component suite passes 1,577 tests with 8 fixture-dependent skips and its
ordinary 30-second cold load passes. D01 also reports a mechanical pass after
retaining all five inventory categories with a 90-frame dwell per category.
Visual inspection overrides that nominal result: the device is upright and
centered at this boundary, but the content is a generated terminal-style list,
all five item previews are solid green squares, the bottom controls are crude
emissive blocks, and both sleeve/arm presentations are malformed. Therefore
the severe device tilt was introduced after `483127f6d2`, while the menu,
shader/preview, and hand-presentation regressions already exist here.

D02 found the first deterministic animation failure on restored weapon index
0. The ordinary inventory row callback equipped FormID `0x0100434f`, the
right-hand slot bridge completed, the physical Pip-Boy closed, and the
mechanics controller synchronized. The first-person pose then remained stuck
with `activeRightArm="equip"`; authored `1hpaim.kf` reported `playing=0`, so no
stable frame was ever captured. The old harness would wait four minutes while
per-frame trace inflated the log. The route was stopped after the unchanged
state exceeded the recovery timeout, and the harness now fails D01/D02 when
no new settled native frame appears for 15 seconds. This is progress-based,
not rushed: each successful frame resets the deadline.

The same D01 route on `843e916fb9` reproduces the reported presentation
regression without calibration overrides. All five paced category frames hold
the Pip-Boy low at the bottom edge with most of the device outside the viewport
and the right arm stranded at screen right. The intervening implementation
forces `pipboy.kf` to the 10/30-second (`0.333333`) sample, sets animation speed
to zero, disables `pipboywaver`, and removes the authored right-arm manipulate
clip. Since `483127f6d2` is upright under the identical save, camera, route, and
capture method, the frozen “retail mode-3” sample is now a reproduced
regression—not a known-good checkpoint. The first repair candidate will remove
that frozen hold while leaving the native FOS/inventory denominator intact.

Repair commit `6719b2cc97` removes the forced 10/30-second mode-3 sample and
restores the authored left-arm waver. Its clean `repair-remove-frozen-mode3-v2`
runtime passes 1,577 component tests with 8 fixture-dependent skips, the
30-second native Save330 cold-load denominator, and all five paced D01 category
captures. The resulting device is upright and centered in every retained
frame, proving the low/cut-off presentation was caused by the frozen sample.
This is a bounded regression repair, not promotion: the generated terminal UI,
green preview squares, emissive control blocks, sleeves/right hand, proof
ownership, ADS dispatch, and weapon animation handoff remain open gates.

### Weapon handoff execution, 2026-08-07

The repaired Pip-Boy candidate reproduced D02 independently: weapon index 0
equipped normally, but first-person `1hpaim.kf` never became the active steady
pose. Source inspection found that `ESM4NpcAnimation` derives directly from
`Animation`, so it has no `NpcAnimation::WeaponAnimationTime`; the controller
was setting a weapon group that cannot keep an ESM4 aim pose alive.

Commit `86cee815f1` makes the archive-resolved `weaponpose` the explicit steady
state between equip, attack, reload, and unequip actions on the visible
third- and first-person rigs. In canonical D02 evidence, the first 10mm pistol
then completed equip and reload, selected
`meshes/characters/_1stperson/1hpaim.kf`, reported
`activeRightArm="weaponpose" playing=1`, remained stable across two engine
updates, and produced a native framebuffer frame. This proves the initial D02
failure is repaired without a timer or proof-only animation write.

The full ten-weapon matrix then exposed two subsequent defects instead of
being declared complete:

- D02 cached the old roster index for the same frame in which it advanced.
  Commit `a756aa8a90` waits one engine frame before the next ordinary Pip-Boy
  activation, preserving the action dwell and selecting the intended row.
- Rebinding a new weapon family while the prior steady pose was active left
  controller state referring to the retired animation source and terminated
  during the next render traversal. Commit `31c5cb684e` disables a semantic
  state before replacing its `AnimSource`. The next canonical run changed
  from the 10mm pistol to the baseball bat without terminating.

The current remaining D02 failure is bounded to the interrupted-action
fallback. Weapon index 1 reaches the authoritative carried-right slot and the
new `2hmaim.kf` family, but an interrupted outgoing action leaves the weapon
usable with no steady pose. Reload correctly returns false for this melee
weapon (`authored-ammo-candidates-unavailable`); that is not a reload failure.
Commit `b9474def69` restores the exact data-resolved steady pose when this
fallback retains gameplay usability. It is committed and awaiting a clean
candidate build plus the full D02 rerun. No candidate is promoted yet.

Retained evidence:

- `run/fnv-playability-recovery-20260807/weapon-idle-handoff-v1-cold-load-20260807-081026`
- `run/fnv-playability-recovery-20260807/weapon-idle-handoff-v1-d02-20260807-081118`
- `run/fnv-playability-recovery-20260807/weapon-idle-handoff-v2-d02-20260807-083228`
- `run/fnv-playability-recovery-20260807/weapon-family-rebind-v1-d02-20260807-085350`

### Ten-weapon handoff gate, 2026-08-07

The immediate interrupted-handoff restoration in `b9474def69` mutated an
animation source before the same-frame render traversal and crashed. Commit
`1c32ed5b42` moved recovery to a later stable update, and `58d1f54da5` limited
it to an actually equipped Fallout weapon so an unarmed player does not retry
the pose every frame. The final failure was weapon index 9 retaining the stale
`reload` semantic group. Commit `033edc9a40` retires that old action before
starting the archive-resolved `weaponpose`.

Clean candidate `ten-weapon-handoff-v1` now passes 1,577 component tests with
8 fixture skips and no failures. Its canonical D02 route equips all ten Save330
weapons through the ordinary Pip-Boy row callback, observes each authoritative
carried-right slot, waits for two stable authored-pose updates, and retains ten
native framebuffer frames. The final pistol transitions from `reload` to the
playing `meshes/characters/_1stperson/1hpaim.kf` `weaponpose` instead of
stalling. The immutable runtime also passes an independent 60-second cold load.

Canonical D01 passes mechanically with all five categories and retained native
frames. Visual inspection establishes a split result: the Pip-Boy is upright,
centered, and stable in every frame, so the reported severe tilt is repaired.
It is not retail-correct yet. The solid-green item preview, generated
terminal-style labels, exposed surrogate controls, flat scanline surface, and
sleeve/right-hand presentation remain UI/shader/animation gates. This candidate
is therefore a recovery checkpoint, not a promoted release.

Retained final-candidate evidence:

- `run/fnv-playability-recovery-20260807/ten-weapon-handoff-v1-d02-20260807-104708`
- `run/fnv-playability-recovery-20260807/ten-weapon-handoff-v1-cold60-20260807-104830`
- `run/fnv-playability-recovery-20260807/ten-weapon-handoff-v1-d01-20260807-105000`

The next bounded cleanup separates high-volume frame tracing from interval
telemetry: `OPENMW_WORLD_VIEWER_TELEMETRY` must not implicitly enable
`OPENMW_WORLD_VIEWER_TRACE`. This is independent of the animation repair and
will be committed and rebuilt separately before sustained-session testing.

Commit `f679fd1c13` implements that boundary. Its clean runtime passes the full
component suite and reduces the canonical D02 stdout from the earlier
per-frame-trace scale to 2,805,794 bytes while retaining interval world
telemetry. That quieter run also exposed a real state-agreement defect masked
by timing/noise: on weapon index 9 the gameplay/third-person rig continued to
report `reload` while the visible first-person rig had lost that group during
a later dynamic animation-source replacement. The route correctly failed
rather than accepting ten copied filenames as a completed ten-pose audit.

Commit `1757e43546` makes a player weapon action remain `Running` only while
the visible first-person and gameplay rigs both own the same authored semantic
group. If either rig loses it, the existing interrupted-action path retires the
stale state and restores the archive-resolved steady pose. This is production
first/third-person state agreement, not a D02 timer. Its clean candidate and
canonical rerun pass: all ten weapons reach stable authored poses and retain ten
fresh native frames. On index 9, `reload` is visibly lost, the controller
retires it, `1hpaim.kf` returns as a playing `weaponpose`, and only then does the
route accept the final frame.

The explicit frame trace count is now zero, but stdout remains 2,697,608 bytes
because detailed actor, attachment, inventory-category, and proximity logs are
still emitted at frame cadence when only summary telemetry was requested.
Telemetry cleanup therefore remains open and must split every detailed channel
from the summary flag before the sustained-session gate.

Retained diagnostic evidence:

- `run/fnv-playability-recovery-20260807/telemetry-boundary-v1-d02-20260807-111231`
- `run/fnv-playability-recovery-20260807/visible-action-agreement-v1-d02-20260807-113658`

### Repeated-action ownership, 2026-08-07

The quieter D02 log proved that weapon draw-state synchronization detached and
reattached the already-correct weapon node to the same parent every update. It
also logged every redundant move, and D02 redundantly reapplied the WEAP
category every update. Commit `6c7bada448` makes drawn and holstered attachment
idempotent and removes that repeated category write. The incremental engine
build and all 1,585 component tests pass.

The first clean candidate attempt compiled the source but failed during final
link with MSVC `LNK1140: limit exceeded for program database`. A forced fresh
link reproduced pathological multi-gigabyte linker memory growth and was
cancelled without touching source or evidence. The candidate is not accepted
until a reproducible no-linker-PDB build path is recorded in the candidate
builder and the canonical D02 comparison confirms that repeated attachment and
systematic unequip interruptions are gone.

The candidate builder now accepts and records explicit RelWithDebInfo executable
linker flags. `/PDB:NONE` avoids the MSVC linker-PDB limit without changing
compiled gameplay code; candidate runtimes already exclude PDB files. Generated
obsolete build trees were removed only after their immutable runtimes and proof
directories existed, recovering 31 GB and then 22 GB during the candidate loop.

Clean `6c7bada448` evidence reduced `moved equipped weapon` from frame cadence
to 3 records and redundant category writes to 20, but again exposed the final
inactive reload. Commit `a8bd525801` required playback on the secondary visible
rig; it recovered several reloads but still failed index 9 because the selected
primary action rig itself returned `getInfo()` while `isPlaying()` was false.

Commit `ae7143db2f` applies the invariant to the primary action state: an
authored action is `Running` only when its selected animation rig both owns and
plays the semantic group. Its clean `active-action-state-nopdb-v1` runtime
passes 1,577 component tests with 8 fixture skips, canonical D02 with all ten
weapons and ten fresh native frames, and an independent 60-second cold load.
The final pistol now logs inactive `reload`, retires it through the ordinary
interrupted-action path, restores playing `1hpaim.kf` `weaponpose`, waits for
two stable updates, and captures screenshot 009. This removes the prior
nondeterminism while retaining the attachment-churn reduction.

The same exact candidate also passes canonical D01 mechanically with all five
categories and five fresh native frames. Visual inspection confirms that the
Pip-Boy is upright and centered instead of suffering the reported severe tilt.
It is not a retail-visual pass: the screen remains a generated terminal surface
with green-square item previews, crude emissive controls, and incomplete
first-person sleeve/right-hand presentation. Those defects remain promotion
blockers for the UI/shader and animation-ownership phase.

Detailed actor/proximity telemetry still keeps stdout at 2,393,244 bytes, and
systematic Pip-Boy-time unequip interruptions remain visible diagnostics. Those
are not hidden: both stay open for the next input/UI/telemetry ownership pass.

Retained evidence:

- `run/fnv-playability-recovery-20260807/idempotent-weapon-attachment-nopdb-v1-d02-20260807-123142`
- `run/fnv-playability-recovery-20260807/visible-action-playback-nopdb-v1-d02-20260807-125419`
- `run/fnv-playability-recovery-20260807/active-action-state-nopdb-v1-d02-20260807-131719`
- `run/fnv-playability-recovery-20260807/active-action-state-nopdb-v1-cold60-20260807-131836`
- `run/fnv-playability-recovery-20260807/active-action-state-nopdb-v1-d01-20260807-132046`

### Data ownership and live Pip-Boy screen recovery, 2026-08-07

The next source audit was run against the actual recovery worktree rather than
the stale default source path. It identified two normal-gameplay substitutions
that could be removed without changing the accepted weapon handoff:

- Commit `accadcc272` reads ADS FOV from the equipped WEAP `sightFov`, latches
  a rejected held aim until release, and removes the six generated
  `FNV_PROOF_*` store records plus the proof fallback inventory insertion.
- Commit `4ad979f04e` changes the physical screen source from the hand-written
  1024x768 C++ rasterizer to a filtered MyGUI layer render target. Its clean
  `authored-ads-gui-rtt-v1` runtime passes 1,577 component tests with 8 fixture
  skips, but canonical D01 shows a black screen in all five categories. The
  mechanical route pass is therefore explicitly rejected as visual evidence.

The black result was traced rather than masked with the generated fallback.
The filtered `PipBoyScreen` layer matched, emitted 1,578 glyph vertices every
frame, and bound one physical screen material. Commit `fac6690672` replaced the
nested render target with a direct FBO-backed MyGUI camera. Its clean runtime
again passes 1,577 tests with 8 skips, but the glyph trace exposed raw pixel
coordinates such as `(1751,-181)`: assigning the viewport before MyGUI created
its `RenderTargetInfo` left the pixel scale uninitialized, so the whole layer
was outside clip space. The resulting canonical D01 is retained and rejected.

Commit `d446ca9c61` leaves the GUI viewport unset until `GUICamera::update`
initializes the viewport and pixel scale together. The incremental diagnostic
runtime then renders live, category-changing text on the authored Pip-Boy
screen in all five paced D01 frames. This proves the GUI-to-FBO-to-NIF material
transport is working. It is not a promotion candidate: the current synthetic
MyGUI terminal occupies only a small upper-left region and is still generated
by `makeFalloutPipBoyTerminalBody` rather than loaded from Fallout's authored
Tile XML.

The current read-only ownership audit is deliberately red: 3 checks pass and 8
fail. ADS data and synthetic proof inventory are now clean; normal GUI proof
environment branches, engine-owned save/showcase drivers, hard-coded bindings,
generated Pip-Boy screen code, synthesized physical controls, missing authored
menu routing, and summary telemetry coupling remain. The more specific
data-driven UI contract reports 18 failures, including dead generated raster
code and missing `inventory_menu.xml`, `stats_menu.xml`, and `map_menu.xml`
routing. These failures are the active work list, not waivers.

Retained evidence:

- `run/fnv-playability-recovery-20260807/authored-ads-gui-rtt-v1-d01-20260807-135553`
- `run/fnv-playability-recovery-20260807/authored-ads-gui-direct-fbo-v1-d01-20260807-142046`
- `run/fnv-playability-recovery-20260807/gui-scale-fix-diag-v1-d01-20260807-142255`
- `run/fnv-playability-recovery-20260807/source-ownership-20260807-142522.json`

The next implementation boundary is authored UI ownership: delete the now
unused C++ terminal rasterizer, introduce a generic VFS-backed Fallout Tile XML
loader/evaluator, and bind the existing inventory/stats/map models to authored
tiles. Physical control synthesis and engine-owned proof scheduling remain
separate later gates so the now-readable screen transport is not destabilized
while those ownership boundaries are replaced.

### Native pane bridge and physical-screen diagnosis, 2026-08-07

Commit `195f3c3706` deletes the 717-line generated terminal rasterizer after the
live MyGUI-to-FBO transport made it dead. Commit `ceea6b175dca` then removes the
second presentation duplicate: the physical Pip-Boy now temporarily moves the
active native inventory/map/magic/stats window to `PipBoyScreen`, preserving
its real model, selection state, and input handlers, and restores every widget
to its layout-declared layer when the device lowers. The filtered camera crops
from the widget's live rectangle without resizing the widget or modifying its
persisted desktop layout; it is recreated when the active pane changes.

The component gate remains green at 1,577 passed and 8 fixture skips. Canonical
D01 passed mechanically twice, with five paced categories, five native frames,
ordinary Save330 loading, no fallback inventory, and all Windows app-control,
foreground-activation, and injected-input flags false. The first run proved the
native pane was present but compressed by the global GUI target. The cropped
run proves its background batch spans the complete RTT (`-1,+1` to `+1,-1`)
and makes the live inventory rows substantially larger.

Both runs remain visual diagnostic failures. Even a full-RTT pane appears only
in the upper-left portion of the visible glass, proving the remaining defect is
downstream of GUI layout: the skinned `pipboyscreen:0` geometry itself occupies
that region. The device is also oversized, the sleeve/right-hand presentation
is malformed, and generated physical controls remain. The next recovery
boundary is therefore the authored first-person NIF/KF and skinning denominator;
authored Tile XML routing remains open after that geometry can actually present
a full screen.

Retained evidence:

- `run/fnv-playability-recovery-20260807/native-pane-rtt-diag-v1-d01-20260807-143418`
- `run/fnv-playability-recovery-20260807/native-pane-cropped-rtt-diag-v1-d01-20260807-143815`
- `run/fnv-playability-recovery-20260807/source-ownership-20260807-143956.json`

### Data-derived physical-screen fit, 2026-08-07

The prior conclusion that `pipboyscreen:0` occupied only the upper-left of the
glass was disproved by controlled material and geometry audits. Fallout's
authored `PipBoyArm.nif` contains two nearly coincident `Screen.dds` display
surfaces (`pipboyscreen:0` and `ScreenLit:8`) with the same UV island. A
temporary full-surface tint proved that the live shader covered the complete
glass; the corner image was the desktop-sized RTT content, not broken screen
geometry.

Commit `8c897667b946` removes the guessed node-name filter and binds every
material selected by the authored `Screen.dds` reference. The filtered GUI
camera and FBO attachment now use the active widget's live dimensions rather
than a fixed 1920x1080 allocation. Each bound material computes its fit from
the RTT aspect and the loaded geometry bounds, so no Save330 resolution,
widget rectangle, or screen-node shape is encoded in the sampler. The MyGUI
origin is consumed once, and the phosphor conversion uses RGB luminance rather
than opaque alpha, restoring upright green content on black glass.

The accepted `native-pane-phosphor-v1` candidate passes 1,577 component tests
with 8 fixture skips. Canonical D01 passes with all five paced inventory
categories, five fresh native frames, an ordinary Save330 load, and no Windows
app control, foreground activation, or injected input. Visual inspection now
shows the production inventory list and live paper doll upright, readable, and
filling the curved authored display. This closes the GUI-to-FBO-to-NIF sizing
and shader boundary; it does not close the oversized device, malformed
sleeve/right hand, manual animation-time writes, synthetic physical controls,
or authored Tile XML routing.

Retained evidence:

- `run/fnv-playability-recovery-20260807/screen-material-owners-uv-audit-v1-d01-20260807-145133`
- `run/fnv-playability-recovery-20260807/screen-owner-tint-audit-v1-d01-20260807-150327`
- `run/fnv-playability-recovery-20260807/screen-aspect-audit-v1-d01-20260807-150902`
- `run/fnv-playability-recovery-20260807/native-pane-phosphor-v1-d01-20260807-151322`

The next boundary is authored first-person animation ownership: remove manual
KF time writes and synthesized NIF control pivots, allow the retail Pip-Boy
raise/hold/lower clips to own both arms, and verify the device plus right hand
in first- and third-person paced routes.

## Two OpenMW Pip-Boy UI modes

The physical Pip-Boy will support two screen modes, both hosted entirely by
OpenMW and both rendered onto the same authored device screen:

- `retail` is the default compatibility mode. Its layout and behavior come
  from the loaded New Vegas XML/assets and game data rather than a hand-written
  imitation.
- `native` retains the live OpenMW menu presentation that is now working on
  the physical screen.

The modes share one production inventory model, selection state, and equip/use
action path. They are alternate UI/layout backends, not alternate gameplay
implementations. Do not duplicate item rules, add mode-specific inventory
records, or encode Save330 cases. Implement the switch only after the authored
raise/hold/lower and first-/third-person ownership gates are stable; otherwise
UI differences would obscure the active animation regression.

The installed `Fallout - Misc.bsa` was inspected read-only on 2026-08-07 and
confirms that the OG backend can use the shipped UI directly:
`menus/main/stats_menu.xml`, `menus/main/inventory_menu.xml`,
`menus/main/map_menu.xml`, `menus/globals.xml`, and the shared
`menus/prefabs/*.xml` corpus are present. A private diagnostic extraction is
retained at `local/diagnostics/fnv-pipboy-authored-xml-20260807-01`; game assets
must never be committed or redistributed. The XML supplies the authored tile
tree, geometry, images, expressions, templates, and animations. OpenMW must
provide the runtime tile traits, localized strings, list population, selection,
input events, and gameplay callbacks expected by those documents. This is the
definition of `retail` mode; a hand-authored MyGUI likeness is not.

The generic Tile XML compatibility layer first introduced for terminals now
parses Bethesda entities and prefab fragments, resolves named tile references,
and evaluates the scalar operators observed in the installed Pip-Boy corpus,
including `min`, `max`, and `mod`. The current focused XML, terminal, quest,
runtime-state, and compatibility-GMST gate passes 104 of 104 tests. Loading the
documents does not yet constitute a complete Pip-Boy: dynamic string traits,
template instantiation, menu event dispatch, list binding, and authored
animation playback remain explicit implementation gates.

## World interaction menus

Terminal hacking and lockpicking are required playability gates. They are
OpenMW world-interaction menus, independent of the two Pip-Boy screen modes.

- Terminals must activate through the ordinary reference path, load authored
  pages/options and difficulty, run the New Vegas hacking/lockout/reset rules,
  execute the selected script result, and persist unlocked/disabled state.
- Locks must read the reference's lock level and ownership, apply the normal
  skill/perk/key rules, run the authored lockpick minigame with pick wear and
  breakage, emit the appropriate feedback, apply crime consequences, and
  persist success.

Both systems must be driven by loaded ESM/BSA/menu data and implemented opcodes.
Hard-coded answers, lock shapes, fixture-specific branches, and proof-only
bypasses are forbidden. Implement and verify their paced production routes
after input, animation, and menu ownership are stable.
