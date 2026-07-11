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

For the complete side-by-side capture discipline, current worktree checkpoint,
and rules for extending this oracle without changing retail behavior, read
`../../docs/fallout-retail-parity-reboot.md`. Record every new inferred or
measured rule in `../../docs/fallout-compatibility-evidence-ledger.md` before
using it to support a compatibility claim.
