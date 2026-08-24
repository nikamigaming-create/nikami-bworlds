# FNV/JAM background capture runbook

This is the canonical procedure for unattended JAM proof recording. Start here;
do not rebuild a focus/click/keyboard automation loop.

The machine-readable authority is
[`catalog/fnv-jam-background-capture-recipes.json`](../catalog/fnv-jam-background-capture-recipes.json).
The single entry point is
[`scripts/Invoke-FNVJamBackgroundCapture.ps1`](../scripts/Invoke-FNVJamBackgroundCapture.ps1),
and its mandatory preflight is
[`scripts/Test-FNVJamBackgroundCapture.ps1`](../scripts/Test-FNVJamBackgroundCapture.ps1).

## Absolute rules

- No Computer Use or Windows app-control tool.
- No click, focus, activation, foreground-window, or `SendInput` operation.
- Never call `Invoke-FNVRetailJamInput.ps1`.
- Never record retail and OpenMW concurrently; they compete for GPU and timing.
- Never reuse an output directory.
- A launched game is not a pass. Native frames, telemetry, hashes, and semantic
  checks are the evidence.
- Keep the raw per-engine video. The split-screen edit is derivative evidence.

Run preflight first:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 -Target All -RuntimeReady -RequireIdle
```

## One command

Retail smoke:

```powershell
& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target Retail -SmokeTest `
  -OutputRoot .\run\jam-background-smoke-<unique>
```

Retail release recording:

```powershell
& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target Retail `
  -OutputRoot .\run\jam-background-retail-<unique>
```

OpenMW preflight:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -RuntimeReady -RequireIdle
```

OpenMW full proof:

```powershell
& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -SkipBuild `
  -OutputRoot .\run\jam-background-openmw-<unique>
```

Both engines, sequentially:

```powershell
& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target Both -SkipBuild `
  -OutputRoot .\run\jam-background-both-<unique>
```

## Path A: retail FNV

The retail oracle is loaded through an isolated xNVSE overlay. Its schedule
executes real xNVSE/JIP/JohnnyGuitar commands in-process. The named
`StartNewCharacter` action observes the live StartMenu and uses xNVSE buffered
menu events (`MenuHoldKey`/`MenuReleaseKey`, then a verified `MenuTapKey` for
the final confirmation); the host never sends a key.

At frame 845, `EnableBackgroundInputPolling`:

1. reads the two DirectInput device pointers from retail `OSInputGlobals`;
2. asks each device for its type;
3. selects only `DI8DEVTYPE_KEYBOARD`;
4. changes that keyboard to
   `DISCL_BACKGROUND | DISCL_NONEXCLUSIVE`; and
5. reports every device in the `background-input-polling` telemetry event.

The mouse must report `selected=false,reconfigured=false`. This is crucial:
background-reconfiguring the mouse lets unrelated physical mouse deltas move
the camera during capture.

The oracle reads the live Direct3D 9 render target with
`GetRenderTargetData`. It writes 1280x720 BMPs named by engine frame under
`screens/`. `-RecordVideo` requests a dense native sequence; ffmpeg encodes
those BMPs without screen scraping. Window focus, visibility, overlap, and the
mouse cursor do not determine the captured pixels.

The runner temporarily backs up `plugins.txt` and `FalloutPrefs.ini`, writes the
isolated proof settings, and restores the original bytes in `finally`.

Retail acceptance requires all of the following:

- every scheduled command accepted;
- every requested backbuffer frame present and hashed in the oracle manifest;
- exactly one selected/reconfigured device;
- no non-keyboard device reconfigured;
- maximum absolute player pitch no greater than 0.25 radians;
- real movement in smoke mode; and
- an encoded video when `-RecordVideo` is requested.

Failure signatures:

- `accepted=false` on `background-input-polling`: wrong device layout, missing
  game window, or stale oracle DLL;
- mouse `reconfigured=true`: reject the run immediately;
- camera pitch beyond 0.25: reject as camera contamination;
- commands stop near the start of a long schedule: check that the oracle's
  environment-string reader is the dynamic 1 MiB implementation, not the old
  4096-byte buffer;
- fewer BMPs than requested: do not make a video; retain telemetry and rerun
  with a unique directory;
- game launched but no movement: verify `HoldKey`/`ReleaseKey` acceptance and
  the keyboard background-polling event—do not add focus automation.

## Path B: OpenMW

OpenMW uses the native full-proof driver. `-SelfDrive` owns movement, actions,
module transitions, telemetry, and shutdown timing. ffmpeg records the exact
`OpenMW` window title. The runner's release guard refuses
`-FullProofDrive` without `-SelfDrive`.

There is deliberately no abbreviated OpenMW JAM smoke. Its contract has 44
phases, each visible for at least three seconds; stopping early is a failed
proof, not a faster test. Use preflight for a quick check and the complete
release command for runtime evidence.

This method does not activate or focus the window and sends no host input. The
window must remain shown and unminimized, and another window must not cover it;
leave it alone while the recorder runs. Do not “fix” a capture by adding a
focus loop.

OpenMW acceptance requires:

- `capture.selfDriven=true`;
- all three app-control/input flags false;
- 44 phase starts and 44 phase completions;
- zero compatibility, proof-driver, and semantic failures;
- changing visible frames and adequate duration; and
- the complete xNVSE core, JIP LN, JohnnyGuitar, OpenMW native, JAM, and
  separately labelled kNVSE evidence in telemetry.

If the title recorder fails, check exact window title, ffmpeg availability,
window minimization, and capture logs. Do not fall back to clicking or
foreground activation.

## OpenNV R2 Chet barter observation

This small gameplay route is separate from the long JAM proof. The engine
enters the Goodsprings General Store through its authored exterior door, talks
to Chet, selects his real `Show me what you have for sale.` dialogue choice,
and lets the production `ShowBarterMenu` result open barter. It only observes
the resulting live merchant stacks: it does not directly push `GM_Barter`,
seed items or caps, select an item, or mutate proof state.

Run it only through the canonical entry point, from any checkout location:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario ChetObservation `
  -OpeningRuntimeRoot <staged-runtime> `
  -SavePath <goodsprings-save> -RuntimeReady -RequireIdle

& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario ChetObservation `
  -OpeningRuntimeRoot <staged-runtime> `
  -SavePath <goodsprings-save> `
  -OutputRoot .\run\opennv-r2-chet-<unique>
```

Acceptance retains three native frames (door, Chet, barter), an exact-title
video, and `r2-chet-observation-report.json` with all host-control flags
false. This is R2.0 only; the following slice performs an ordinary container
transfer and proves that cancelling barter makes no delta.

## OpenNV R2 persistent container and barter cancellation

The `ChetPersistent` route is the compact gameplay follow-up. It transfers one
live item from the unlocked General Store cash register through
`ContainerWindow`, enters Chet's authored barter normally, and invokes the
production cancellation path. It records the actual item/caps totals before
and after cancellation; only the container transfer may change inventory.

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario ChetPersistent `
  -OpeningRuntimeRoot <staged-runtime> `
  -SavePath <goodsprings-save> -RuntimeReady -RequireIdle

& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario ChetPersistent `
  -OpeningRuntimeRoot <staged-runtime> `
  -SavePath <goodsprings-save> `
  -OutputRoot .\run\opennv-r2-persistent-<unique>
```

Success retains six native frames and
`r2-goodsprings-persistent-report.json`, including the container-transfer and
no-delta barter-cancellation assertions. The next slice is one affordable,
observed merchant purchase followed by a native save and cold reload.

## OpenNV R2 authored Chet transaction

The `ChetTransaction` route is the compact merchant-purchase follow-up. It
uses the same authored door, cash-register container, Chet dialogue, and
production barter UI, then completes one affordable live merchant item through
TradeWindow's normal offer path. It verifies the exact player and merchant
item and Caps deltas after the UI closes.

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario ChetTransaction `
  -OpeningRuntimeRoot <staged-runtime> `
  -SavePath <goodsprings-save> -RuntimeReady -RequireIdle

& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario ChetTransaction `
  -OpeningRuntimeRoot <staged-runtime> `
  -SavePath <goodsprings-save> `
  -OutputRoot .\run\opennv-r2-transaction-<unique>
```

Success retains six native frames, an exact-title video, and
`r2-goodsprings-transaction-report.json`, including the ordinary container
transfer and authored merchant-transaction assertions. It is R2.2 evidence;
native save, clean exit, and cold reload remain R2.3.

## OpenNV R2 native persistence

The `ChetPersistence` route runs the completed cash-register transfer and Chet
merchant purchase, requests the production state-manager save, and exits
normally. It then starts a second OpenMW process that cold-loads the generated
save, verifies the retained inventory and Caps deltas, and opens the same
ordinary cash register through `ContainerWindow`.

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario ChetPersistence `
  -OpeningRuntimeRoot <staged-runtime> `
  -SavePath <goodsprings-save> -RuntimeReady -RequireIdle

& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario ChetPersistence `
  -OpeningRuntimeRoot <staged-runtime> `
  -SavePath <goodsprings-save> `
  -OutputRoot .\run\opennv-r2-persistence-<unique>
```

Acceptance requires the generated `.omwsave`, clean exits from both processes,
seven save-side and two reload-side native frames, exact-title video, retained
telemetry, and false Windows app-control/foreground-input flags. The route is
fully checkout-relative: supply the staged runtime, starting native save, and a
unique output directory for the current machine.

## Authored opening comparison route

## TestMap01 renderer diagnostic

This is a deliberately separate, non-gameplay visual diagnostic for the FNV
developer cell `TestMap01`. It proves that the selected OpenMW runtime can
render that cell without the pervasive magenta, brown-void, black, or missing
legacy-water fallback seen during recovery. It does **not** prove the authored
New Vegas opening; the explicit start-cell override is recorded as such.

Run its dedicated preflight and capture only through the canonical entry point:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario TestMap -RuntimeReady -RequireIdle

& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario TestMap `
  -OutputRoot .\run\opennv-testmap-clean-<unique>
```

The output retains an engine-native `TestMap01-native.png`, an exact-title raw
transport MP4, and a mobile-friendly MP4 made from that retained native frame.
The report rejects a pervasive-magenta native frame and missing legacy-water
fallbacks. No focus action, click, keyboard injection, or in-game console is
used.

## Live Pip-Boy panel showcase

This is the real playable-UI companion to the renderer diagnostic. It starts a
normal New Game, applies the final TestMap01 developer placement only after
that initialization, equips an authored FalloutNV.esm-only test loadout, then
captures the dedicated `Tab` Pip-Boy's live `STATS`, `ITEMS`, `DATA`, and
`MAP` panels through OpenMW's native `ScreenCaptureHandler`.

Run it only through the canonical entry point:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario PipBoy -RuntimeReady -RequireIdle

& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario PipBoy `
  -OutputRoot .\run\opennv-pipboy-live-<unique>
```

It retains all four unmodified native PNGs, an exact-title transport MP4,
telemetry, hashes, and a labelled collage derived only by arranging those
native PNGs. The report rejects the run if normal New Game did not complete,
the final TestMap01 placement did not occur, any panel is missing, a
`FNV_PROOF_*` inventory fallback is observed, or the named FalloutNV.esm
loadout cannot be resolved. No Windows input, focus operation, click, or
console command reaches the game.

## Live Pip-Boy VR interaction proof

Run the matching VR slice immediately after the flat Pip-Boy showcase. This
route launches `openmw_vr.exe` against the repo-local OpenXR simulator, keeps
the Pip-Boy powered on the left wrist, and drives the production right-finger
ray through Knife, Varmint Rifle, and 9mm Pistol selection. It then exercises
the ordinary melee, reload, and fire paths. The firearm sockets must report a
forward barrel convention and the knife must report its separate forward blade
convention.

Run it only through the canonical entry point and pass the staged VR runtime;
the command is repository-relative and does not depend on a drive letter:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario PipBoyVR `
  -OpeningRuntimeRoot '<staged VR runtime>' `
  -RuntimeReady -RequireIdle

& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario PipBoyVR `
  -OpeningRuntimeRoot '<staged VR runtime>' `
  -OutputRoot .\run\opennv-vr-pipboy-weapons-<unique>
```

The runner retains every projection-eye BMP, the simulator telemetry, the
profile-local OpenMW log, the live Pip-Boy RTT, hashes, a contact sheet, and a
short square MP4 encoded only from those native frames. The report rejects a
missing screen binding, wrong pointer row, failed inventory mutation, wrong
weapon convention, failed reload/fire/melee action, incomplete source-frame
sequence, static capture, or any Windows app control or foreground input.

## Authored opening comparison route

The opening route is a separate, declared OpenMW TTW capture scenario. It is
for comparing the actual authored `PlayBink` opening and its immediate Vault
101 nursery handoff, not for claiming that a source Bink file alone is game
playback.

Run its dedicated preflight first:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario Opening -RuntimeReady -RequireIdle
```

Then record it through the same entry point:

```powershell
& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target OpenMW -Scenario Opening `
  -OutputRoot .\run\opennv-ttw-opening-<unique>
```

The engine receives the authored `PlayBink` source command normally. A
generic, environment-configured capture gate pauses only the named video until
the exact-title recorder is live, then resumes it and stops it at the explicit
capture duration. The gate is neither a content replacement nor simulated
player input; it records marker files and log events so the timing is
auditable.

The raw MP4 retains the lead-in, exact-title transport video, and a DirectShow
Stereo Mix audio track. The engine also retains a profile-local sequence of
native framebuffer screenshots; the runner hashes and copies those frames,
then makes the presentation copy from that sequence plus the retained audio.
This matters on GPU backends where Windows title capture returns a black client
surface even though the engine is rendering normally. A black exact-title video
is never accepted as visual proof.

The report rejects a run unless the native frames are contiguous and visibly
changing, the presentation retains one audible audio stream, the movie gate and
completion are proven, and character-generation overlay suppression is active
after the handoff. Keep other desktop audio quiet during this run because Stereo
Mix records audible system output.

## Godot Goodsprings-to-Strip route

The Godot route is a third declared lane. It uses the same no-control policy:
Godot owns all walking and door activation. The runner verifies the exact
launched process has an `OpenNV` title, then ffmpeg records that process's
native window handle; native framebuffer checkpoints are retained. Run:

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target Godot -Scenario GodotRoute -RuntimeReady -RequireIdle
& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target Godot -Scenario GodotRoute `
  -OutputRoot .\run\opennv-godot-route-<unique>
```

This route enters and exits a connected Goodsprings interior, walks the streamed
exterior corridor, crosses the authored Freeside and Strip seams, and ends inside
the collapsed Strip. It is not accepted unless the route report, thirteen native
checkpoints, exact-title video, audio stream, hashes, and no-control flags all pass.

## Whole-game retail actor observation

`ActorObservation` is the canonical single-base probe used by the whole-game
actor and creature review corpus. It consumes one immutable OpenNV capture-plan
job, spawns that official runtime base inside retail, resolves the new reference,
and retains runtime template identity, live bounds, compact pose samples, camera
matrices, and native Direct3D 9 frames. One live reference supplies four still
views plus an idle-motion clip: humanoids use front portrait, left profile,
right profile, and front full body; creatures substitute front detail for front
portrait. The recipe owns the shared timeline and declares only the record-type
detail-name override, so the two paths cannot drift independently. Run retail
and Godot sequentially.

```powershell
& .\scripts\Test-FNVJamBackgroundCapture.ps1 `
  -Target Retail -Scenario ActorObservation `
  -ActorPlanRoot '<immutable capture plan>' `
  -ActorCorpusRoot '<immutable actor corpus>' `
  -ActorCaptureJobKey 'FalloutNV.esm:000a84' `
  -ActorOracleSeedRoot '<isolated xNVSE runtime>' `
  -ActorOraclePluginDll '<built nvse_retail_oracle.dll>' `
  -ActorSaveFixture '<immutable legal retail save>' `
  -RuntimeReady -RequireIdle
& .\scripts\Invoke-FNVJamBackgroundCapture.ps1 `
  -Target Retail -Scenario ActorObservation `
  -ActorPlanRoot '<immutable capture plan>' `
  -ActorCorpusRoot '<immutable actor corpus>' `
  -ActorCaptureJobKey 'FalloutNV.esm:000a84' `
  -ActorOracleSeedRoot '<isolated xNVSE runtime>' `
  -ActorOraclePluginDll '<built nvse_retail_oracle.dll>' `
  -ActorSaveFixture '<immutable legal retail save>' `
  -OutputRoot .\run\fnv-actor-observation-<unique>
```

A successful probe reports `captured-unclassified-runtime-observation` until
observed runtime lineage selects exactly one declared review signature, then
`captured-classified-runtime-observation`. Neither status is a parity pass:
every required view must still be captured in retail and Godot and the matched
visual review must pass. Dynamic roots remain pending until every expected
signature has been observed. The compact JSONL ceiling, five camera-state
sequence, per-shot camera matrix, source-frame hash, and encoded idle clip are
validated before a run may enter the coverage ledger. A green retail probe is
still only reference evidence; it never marks the Godot rendition or matched
comparison as passed.

Run a resumable retail sweep through the queue wrapper. The queue root owns an
immutable source-binding manifest, an append-only event ledger, immutable
coverage checkpoints, and one fresh canonical proof directory per attempt.
Repeating the command skips completed jobs. Use `-BatchKey` for one declared
32-base batch or omit it for the full plan; `-MaximumJobs` is a bounded smoke
control and does not change completeness semantics.

```powershell
& .\scripts\Invoke-FNVActorObservationQueue.ps1 `
  -PlanRoot '<immutable capture plan>' `
  -CorpusRoot '<immutable actor corpus>' `
  -QueueRoot '<private resumable retail queue>' `
  -OracleSeedRoot '<isolated xNVSE runtime>' `
  -OraclePluginDll '<built nvse_retail_oracle.dll>' `
  -SaveFixture '<immutable legal retail save>' `
  -BatchKey 'actor-appearance-00000'
```

Every attempt still enters through `Invoke-FNVJamBackgroundCapture.ps1`, so it
must pass the normal idle preflight and no-app-control gate. Dynamic jobs use
the catalog-declared attempts-per-outcome sweep budget; exhausting one sweep
leaves missing signatures pending and a later sweep resumes them. A capture
error is retained as a ledger event and never converted into coverage.

## Provenance and recovery

Every successful directory must retain:

- raw retail BMPs and `retail-core.jsonl`, the raw OpenMW MP4 and `stdout.log`,
  or the Godot exact-process-window MP4, native PNG checkpoints, and Godot logs;
- the engine-specific manifest/report;
- SHA-256 hashes;
- ffmpeg logs;
- the final MP4; and
- the command/recipe identity in `background-capture-summary.json`.

If a run aborts, wait for the scoped game process to exit, confirm the retail
preferences/plugin list were restored, and start again with a new directory.
Never delete or overwrite the failed evidence while diagnosing it.

Known-good anchors are optional entries in the recipe catalog. They may name
only retained evidence directories that exist in this checkout; stale paths
must be removed rather than treated as proof. Anchors never waive preflight
for a new run.

## Validator boundary

`Test-FNVJamBackgroundCapture.ps1` validates these two recording mechanisms,
their local runtime, and the known-good no-control artifacts. The OpenMW
runner's own `proof-report.json` validates its 44 native phases and semantic
measurements.

`Test-FNVJamFullProof.ps1 -ReportPath` is a different, higher-level release
gate. It accepts only an assembled cross-engine
`fnv-jam-4.6-full-parity-v1` report containing both engines, all artifact
kinds, command coverage, layer attestations, and per-side measurements. Do not
pass a raw OpenMW `proof-report.json` to it, do not interpret that schema
mismatch as an engine failure, and never invent missing retail measurements to
make it pass. Its contract definition can be checked independently with:

```powershell
& .\scripts\Test-FNVJamFullProof.ps1 -ContractOnly
```
# OpenNV four-scene 60 FPS cinematic capture

The canonical Godot cinematic lane records one new 60-second engine-owned reel and splits it into four continuous 15-second 1280x720/60 FPS clips: Goodsprings, Novac, the Strip, and Vault 21 exterior-to-interior. Godot's native fixed-step movie writer supplies genuine rendered 60 FPS frames and native game audio; ffmpeg only trims and encodes from that retained AVI. The lane sends no Windows input, performs no focus or app-control operation, and retains native framebuffer checkpoints and engine telemetry.

```powershell
.\scripts\Test-FNVJamBackgroundCapture.ps1 -Target Godot -Scenario GodotCinematics -RuntimeReady -RequireIdle
.\scripts\Invoke-FNVJamBackgroundCapture.ps1 -Target Godot -Scenario GodotCinematics -OutputRoot .\run\opennv-godot-cinematics-<unique>
```

# OpenNV famous people in authored locations

This Godot-native screenshot lane frames decoded actor references at their original placements: Easy Pete in Goodsprings, Arcade Gannon at the Old Mormon Fort, Vulpes Inculta on the Strip, and Victor at the Lucky 38. It retains native PNGs and produces 1280x720 JPEG copies without foreground control or host input.

```powershell
.\scripts\Test-FNVJamBackgroundCapture.ps1 -Target Godot -Scenario GodotPortraits -RuntimeReady -RequireIdle
.\scripts\Invoke-FNVJamBackgroundCapture.ps1 -Target Godot -Scenario GodotPortraits -OutputRoot .\run\opennv-godot-portraits-<unique>
```
