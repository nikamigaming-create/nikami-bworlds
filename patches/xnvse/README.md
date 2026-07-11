# xNVSE retail-oracle overlay

This queue adds the isolated `NikamiRetailOracle` plugin used to capture bounded
Fallout: New Vegas behavioral snapshots and to wrap the two retail bone-LOD call
sites during an oracle run. The wrappers always call the original retail
functions and record their inputs/results; they do not replace game behavior.
The queue does not include retail game data or compiled binaries.

The patch was exported against xNVSE commit `175bb28`. Apply it to a clean xNVSE
checkout from the checkout root:

```powershell
Get-Content D:\path\to\nikami-worlds\patches\xnvse\series | ForEach-Object {
  git apply --check (Join-Path D:\path\to\nikami-worlds\patches\xnvse $_)
  git apply (Join-Path D:\path\to\nikami-worlds\patches\xnvse $_)
}
```

Build the Win32 Release plugin:

```powershell
& 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe' `
  .\nvse_retail_oracle\nvse_retail_oracle.vcxproj /p:Configuration=Release /p:Platform=Win32 /m
```

Use `scripts/Invoke-FNVRetailOracle.ps1` to install the DLL only for the bounded
capture and restore the retail Data directory afterward. The current oracle
also records final local/world bone transforms, sequence controlled blocks,
per-target blend arrays and priorities, cached interpolator channels, retail
Foot IK status, `NiBSBoneLODController` state, camera distance, and the live
actor/bone-LOD settings. Its runtime-only struct views are confined to the
oracle plugin and do not modify xNVSE itself. Patch 0002 adds authored group and
blend telemetry. Patch 0003 records the exact retail distance quotient, the
temporary `AnimData` sequence gate, and every call to the original bone-LOD
writer. Patch 0004 records the retail `sitSleepState`, claimed furniture
reference, marker index, and cached marker transform, with a furniture-only
mode for long AI/package captures. Patch 0005 adds focus-independent
background collection, engine-driven observer waypoints, event-bounded
furniture completion, reusable save fixtures, and explicit scene-node parent
names. Patch 0006 adds in-process retail screenshots and a portrait camera that
resolves `Bip01 Head` recursively and follows its rendered face-forward axis;
this avoids actor-root/profile framing errors during seated idles. The capture
runner restores the pre-existing retail DLL, screenshots, temporary save
fixtures, and process environment after each run. Raw BMP frames are retained
beside derived `-proof-crop.png` images; the crop never replaces source pixels.
Patch 0007 records the effective runtime NPC race, sex, hair, eyes, HCLR bytes,
head-part models, race face model/texture slots, and FaceGen channel shapes.
The event contains stable content identifiers and paths, not runtime pointers.
`scripts/compare_fnv_goodsprings_appearance.py` checks those values against the
independently parsed ESM matrix.
Patch 0008 cycles multiple declared humanoid references in one retail process,
records every target transition, optionally enables staged references and their
authored XESP parents, moves the player through the normal console command,
waits for a live head and appearance event, and requests one screenshot per
target. Staged state is explicit telemetry and must not be presented as natural
AI/quest-state evidence.
Patch 0009 reads the public JIP LN NVSE `Sky` runtime layout used by retail
FalloutNV 1.4.0.525 and records current/previous/default/override weather
FormIDs, transition percentage, sky mode/flags, runtime game hour, and the
resolved ambient, directional, and fog light colors. This removes the need to
infer a material mismatch from screenshots taken under different weather or
time state. The Win32 Release oracle builds cleanly and the event is
runtime-proven in hidden/background mode. The authoritative seated Easy Pete
fixture event is
`run/retail-oracle/fnv-easy-pete-seated-render-environment-v1.jsonl`; it reports
current weather `0x001237D7`, no transition, `GameHour=14.4118919`, ambient
`(0.369318515,0.4469423,0.578699231)`, and directional/fog light
`(1,0.890196145,0.666666687)`.
Patch 0010 records the four Sky-owned weather IMAD instances and hooks the
retail D3D9 fullscreen draw calls read-only to identify the actual cinematic
shader by its embedded constant table. It then records the pixel-shader
constants at the draw that consumes them. The hidden/background Easy Pete run
`run/retail-oracle/fnv-easy-pete-seated-image-space-v4.jsonl` proves weather
`0x001237D7` uses `NVWastelandIS` (`0x000CEE18`) in both current time slots at
weights `0.401982009` and `0.598017991`, with no transition modifier. Retail
selects the 748-byte `hdr-cinematic` pixel shader (`FNV-1a 0x0A008802`) and
supplies `HDRParam=(1.4,0,0,0)`,
`Cinematic=(1.1,0.2,1.1,1.3)`,
`Tint=(0.992831886,0.660198152,0.0276841652,0.392156869)`, and zero Fade.
Non-finite values in unused registers are serialized as JSON `null`; the
runner parses the complete event without faults. The hook only observes state
and always forwards the original D3D9 draw call.

For the complete side-by-side capture discipline, current worktree checkpoint,
and rules for extending this oracle without changing retail behavior, read
`../../docs/fallout-retail-parity-reboot.md`. Record every new inferred or
measured rule in `../../docs/fallout-compatibility-evidence-ledger.md` before
using it to support a compatibility claim.
