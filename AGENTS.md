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

For whole-game actor or creature review, use the immutable OpenNV actor corpus
and capture plan described in `docs/fnv-jam-background-capture.md`, then run
`scripts/Invoke-FNVActorObservationQueue.ps1`. The queue may append its ledger
and create new attempt directories, but it must never modify an existing proof.
Retail coverage is reference evidence only; do not call an actor reviewed or
passed until matched Godot evidence and a visual verdict exist for every
required shot and every expected runtime appearance signature.

## OpenNV clean-room retail-state work

OpenNV is the clean Godot/OpenXR reimplementation in the sibling
`D:\code\OpenNV` repository. This repository owns retail behavior oracles and
evidence; it does not ship Bethesda files or engine-derived caches.

- Treat a user-owned Fallout: New Vegas installation as read-only input. Never
  commit, package, upload, or distribute Bethesda assets, saves, executables,
  native frames, or derived actor caches.
- Reduce reverse-engineering results to implementation-neutral state contracts.
  Do not copy decompiler output or OpenMW implementation code into OpenNV.
- Retail FNV 1.4.0.525 is a 32-bit WOW64 process. The private Win32 Ghidrust MCP
  is
  `D:\Dev\Tools\Ghidrust\builds\wow64-i686-codex-nogpu\i686-pc-windows-msvc\release\ghidrust.exe`.
  Use one long-lived MCP process and attach in observe mode. The installed x64
  Ghidrust correctly rejects WOW64 targets.
- Private camera evidence is under
  `D:\Dev\Tools\Ghidrust\workspace\evidence\falloutnv_1_4_0_525\camera` and is
  never a distribution input.
- The live calls at `0x0045C670` and `0x006629F0` are only confirmed as
  `*0x011DEB7C` and `*(owner + 0xAC)`. The latter result is not a proven
  `NiCamera`; do not resume blind `NiFrustum` offset or pointer scans.
- Current actor parity truth: exact authored Trudy identity passes, rendering
  parity fails. The active retail-state slice must retain each shot's live
  reference transform, source-labelled projection/FOV evidence, active idle
  phase, four arm-bone transforms, and complete final `FaceGenFace` and
  `FaceGenHairNoHat` geometry hashes/bounds.
- Identity success and rendering success are separate gates. Never promote a
  vanilla parity claim from identity alone, and never let optional HD textures,
  shaders, or upscaling hide a failing baseline.
