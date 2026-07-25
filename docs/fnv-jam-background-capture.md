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
executes real xNVSE/JIP/JohnnyGuitar commands in-process. `HoldKey` and
`ReleaseKey` drive the retail input layer; the host never sends a key.

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

## Provenance and recovery

Every successful directory must retain:

- raw retail BMPs and `retail-core.jsonl`, or the raw OpenMW MP4 and
  `stdout.log`;
- the engine-specific manifest/report;
- SHA-256 hashes;
- ffmpeg logs;
- the final MP4; and
- the command/recipe identity in `background-capture-summary.json`.

If a run aborts, wait for the scoped game process to exit, confirm the retail
preferences/plugin list were restored, and start again with a new directory.
Never delete or overwrite the failed evidence while diagnosing it.

Known-good anchors are recorded in the recipe catalog. They prove the workflow,
but they do not waive preflight for a new run.

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
