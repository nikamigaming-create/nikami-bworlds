# Repository capture rules

For any Fallout: New Vegas/JAM screenshot or video task, read
[`docs/fnv-jam-background-capture.md`](docs/fnv-jam-background-capture.md) and run
`scripts/Test-FNVJamBackgroundCapture.ps1` before launching either engine.

The only canonical unattended paths are declared in
`catalog/fnv-jam-background-capture-recipes.json`:

- retail FNV: xNVSE-scheduled input plus native Direct3D 9 backbuffer frames;
- OpenMW: `-SelfDrive` plus exact-title recording.

Never use Computer Use, clicks, focus changes, `AppActivate`,
`SetForegroundWindow`, `BringWindowToTop`, `SetFocus`, `SendInput`, or
`scripts/Invoke-FNVRetailJamInput.ps1` for proof capture. Do not run retail FNV
and OpenMW capture concurrently. Do not overwrite an existing proof directory.

Use `scripts/Invoke-FNVJamBackgroundCapture.ps1` as the single entry point. A
run is not evidence merely because the game launched: its summary/report must
name the capture method, state that Windows app control and foreground input
were unused, retain native source frames/telemetry, and pass the relevant
validator.
