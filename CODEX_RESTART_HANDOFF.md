# Codex restart handoff — FNV/OpenMW parity

## Mission

Continue deterministic, data-driven Fallout retail parity. Immediate deliverables:

1. Make the production Service Rifle combat path pass visibly and through telemetry.
2. Commit the verified combat/store/parser slice without unrelated WIP.
3. Re-create the Fallout: New Vegas intro Strip sniper sequence as a new in-engine MP4, using production actors, weapons, hit logic, camera, and slow time. Keep only the final MP4 plus a compact manifest/contact sheet; delete transient frames.

Do not stop at an animation-only proof. A combat pass requires: weapon visibly attached, exactly one round consumed, an actor hit, and target health reduced.

## Exact current state

- The Goodsprings world crash was fixed by a clean serial rebuild after hardening the `ESMStore` tuple ordering. `Store<ESM4::Projectile>` is now appended at the end; inserting it in the middle had shifted ABI-like tuple ordinals and stale objects read the wrong store.
- Latest deployed binary before the projectile-remap patch:
  - `D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe`
  - SHA-256 `7E2F2970EAC5DFC6268DEBE9BA430AFD0327CC1C19169B011AB43BD8CFB8E608`
- Last visible proof completed without a world crash and showed the Service Rifle attached plus the production `attack1` animation, but it is **not a combat pass**.
- Proof artifacts:
  - `D:\code\nikami-worlds\run\fnv-combat-live-visible-20260717\fallout_new_vegas-20260717-070516`
  - log: `D:\code\nikami-worlds\run\fnv-combat-live-visible-20260717\openmw-actor-sweep-20260717-070516.log`
  - screenshot: `D:\code\nikami-worlds\run\fnv-combat-live-visible-20260717\fallout_new_vegas-20260717-070516\screenshots\fallout_new_vegas.t001.png`
- Exact rejection in that run:
  - `FNV combat shot rejected ... weapon=FormId:0x10e9c3b reason=missing-projectile-record exact=1`
- Exact root cause: `WEAP.DNAM` parsed the projectile FormID as raw `0x426d` but did not call `reader.adjustFormId`; the loaded `PROJ` is `0x0100426d`. This is an exact load-order remap bug, not a fuzzy lookup problem.
- The corrective parser patch is present and `git diff --check` passes:
  - `components/esm4/loadweap.cpp`: adjust `mData.projectile` after DNAM parsing.
  - `components/esm4/loadproj.cpp`: adjust every embedded PROJ.DATA FormID (light, muzzle light, explosion, sounds, default weapon).
- This corrective patch has **not yet been rebuilt, deployed, or rerun visibly**.

## First actions after restart

Work in `D:\code\nikami-openmw-lab`. Use a serial MSVC build; parallel builds previously collided on PDBs.

```powershell
git diff --check -- components/esm4/loadweap.cpp components/esm4/loadproj.cpp
cmake --build MSVC2022_64 --config RelWithDebInfo --target openmw -- /m:1 /nodeReuse:false
```

Then run the relevant parser/combat tests if their binaries exist or build their targets, deploy the corrected executable to:

```text
D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe
```

Do not terminate an active proof merely because it is taking time. Only terminate a definitively failed/stale process if it blocks deployment of the corrected binary.

Run this visible production proof from `D:\code\nikami-worlds`:

```powershell
.\scripts\Invoke-OpenMWFNVLoadedActorSweep.ps1 `
  -OutputRoot 'run/fnv-combat-live-visible-projectile-remap' `
  -Offset 52 -Limit 1 `
  -PoseGroups @('mechanics-primary') `
  -PoseFrames 120 -PoseStartDelayFrames 30 -NeutralFrames 30 `
  -ActorTimeoutFrames 1200 -TimeoutMinutes 10 `
  -SetEnv @('OPENMW_PROOF_DISABLE_ACTOR_COLLISION=0','OPENMW_PROOF_PIN_PLAYER_TO_ACTOR_VIEW=1')
```

Inspect the new log for all of:

- no `combat shot rejected`
- a real `FNV combat shot`
- Service Rifle selected and attached
- `ammoBefore - ammoAfter = 1`
- `actorHit=1`
- finite `healthBefore` and lower `healthAfter`

If `actorHit=0`, first verify the authored forward direction and player placement. Do not add an actor-specific pose or aim override.

## Combat defects already identified

- Ammo lookup was incorrectly generic; `FLST` was invisible through that cache. Source now uses exact typed Ammunition/FormIdList searches.
- Ammo removal occurred before direction/ray validation; source now removes ammo only after validation.
- `OPENMW_PROOF_DISABLE_ACTOR_COLLISION=0` was previously treated as enabled because code tested environment-variable presence. Source now uses `proofEnvEnabled(...)`.
- The mechanics proof gate can falsely pass from animation alone. Harden it so telemetry, not animation, decides combat success.
- Proof target selection is not yet a formal deterministic production contract; validate the existing player-downrange setup before changing it.

## Source state and staging discipline

Engine repo: `D:\code\nikami-openmw-lab`

Combat/parser/store work includes:

- `apps/openmw/mwworld/esmstore.hpp`
- `components/esm4/loadweap.cpp`
- `components/esm4/loadproj.cpp`
- `apps/openmw/mwmechanics/character.cpp`
- `apps/openmw/mwmechanics/character.hpp`
- `apps/openmw/mwmechanics/falloutcombat.cpp`
- `apps/openmw/mwmechanics/falloutcombat.hpp`
- `apps/openmw/mwclass/actor.cpp`
- `apps/openmw/mwclass/actor.hpp`
- `apps/openmw/CMakeLists.txt`
- `apps/openmw_tests/CMakeLists.txt`
- `apps/openmw_tests/mwmechanics/`
- one relevant environment-value hunk in `apps/openmw/engine.cpp`

Unrelated/overlapping WIP exists and must not be staged wholesale:

- `apps/openmw/engine.cpp` (large proof WIP; stage only the intended hunk)
- `apps/openmw/mwclass/esm4npc.hpp`
- `apps/openmw/mwrender/esm4npcanimation.cpp`
- `files/shaders/compatibility/bs/skin.frag`

Worlds repo currently has generated, untracked `config/door-preload/*` files. Preserve them and do not commit them.

Prior relevant engine commits include:

- `a2e484a224 Parse exact Fallout weapon projectile contracts`
- `5c8e4a4ed4 Apply exact retail weapon holster contracts`
- `8f31bd50e2 Index Fallout clothing and key records`

Commit each verified slice. Never use fuzzy bone/record matching or silent fallbacks; exact mappings should hard-fail with actionable telemetry.

## Cinematic source and storage discipline

Retail intro is already installed locally; do not download or duplicate it:

```text
D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\Video\FNVIntro.bik
```

Size: 353,301,852 bytes. Use it only to extract a compact storyboard/timing manifest for the Strip sniper beat. Render a fresh OpenMW in-engine sequence and encode the final result as MP4. Cap temporary storyboard/frame storage and delete raw frames after MP4 verification.

## New task prompt

Paste this after selecting **Full Access** for the restarted task:

> Read `D:\code\nikami-worlds\CODEX_RESTART_HANDOFF.md` completely. Set the parity/combat/cinematic goal described there, continue at “First actions after restart,” and do not stop until the visible combat telemetry gate passes and the in-engine MP4 is produced. Preserve unrelated WIP and commit each verified slice.

## Permission note

The interrupted task is currently running under a managed `workspace-write` profile rooted at `D:\code\nikami-worlds`, not Full Access. Per-command approvals may persist as approved prefixes, but the broad Full Access profile is supplied when a run/task starts and can revert to the default profile after Stop/Start. Select Full Access before sending the restart prompt.
