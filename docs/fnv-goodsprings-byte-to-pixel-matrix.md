# FNV Goodsprings Byte-to-Pixel Matrix

This is the first broad Fallout: New Vegas appearance gate. It replaces
character-by-character visual guessing with an exact authored-record, retail
runtime, and OpenMW-render comparison.

## Scope

`catalog/fnv-goodsprings-retail-matrix.json` contains 19 exact references:

- seven named humanoids: Easy Pete, Sunny Smiles, Trudy, Chet, Ringo, Doc
  Mitchell, and Joe Cobb;
- all four Goodsprings settler variants;
- all six Ghost Town Gunfight Powder Gangers;
- Victor; and
- Cheyenne.

That is 17 humanoids plus one robot and one creature. Wilderness fauna is a
separate creature matrix so it cannot hide human face/hair failures.

The matrix is generated directly from `FalloutNV.esm`:

```powershell
python scripts/build_fnv_goodsprings_retail_matrix.py `
  --esm 'D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\FalloutNV.esm' `
  --out catalog/fnv-goodsprings-retail-matrix.json
```

The committed output stores FormIDs, editor IDs, paths, colors, placements, and
FaceGen SHA-256 fingerprints. It does not store Bethesda meshes, textures, or
FaceGen coefficient payloads.

## Three independent layers

1. The matrix parser reads NPC race/hair/eye/head-part records and fingerprints
   FGGS/FGGA/FGTS payloads from the ESM.
2. xNVSE patch 0007 reads the effective values from the live retail `TESNPC`
   and its race slots while the screenshot is captured.
3. OpenMW must report the same selected records/material inputs and produce a
   visually matching frame under controlled state and lighting.

Run the retail side with `-RequireAppearanceTelemetry`; the runner rejects a
capture unless exactly one `npc-appearance` or `target-appearance` event exists.
For the whole humanoid matrix, use the grouped batch wrapper. `-StageReferences`
is required for initially disabled settlers and Powder Gangers; every staged
Enable/XESP-parent action is logged:

```powershell
.\scripts\Invoke-FNVGoodspringsAppearanceMatrix.ps1 `
  -RunId fnv-goodsprings-retail-baseline `
  -StageReferences
```

The wrapper groups actors by cell, uses a 90-frame post-load settle, requires
one runtime appearance event, head-frame event, raw BMP, and proof crop per
humanoid, runs the ESM differential, and creates a contact sheet. Its final
status remains `review-required`; image statistics cannot approve framing.
Compare captures with:

```powershell
python scripts/compare_fnv_goodsprings_appearance.py `
  --matrix catalog/fnv-goodsprings-retail-matrix.json `
  --capture easy-pete=run/retail-oracle/fnv-easy-pete-appearance-v2.jsonl `
  --out run/retail-oracle/fnv-goodsprings-appearance-differential.json
```

## Current evidence

All 17 humanoids pass the ESM-to-retail runtime differential in
`fnv-goodsprings-all-humanoids-differential-v3.json`. The visually reviewed
17-frame retail contact sheet is
`fnv-goodsprings-all-humanoids-contact-sheet-v3.png`. Easy Pete and
`GSSettlerAM` illustrate the contract:
Pete resolves to AfricanAmericanOldAged, HairAfricanAmericanBaseOld,
EyeDarkBrown, BeardFullOld, and HCLR `[192,192,192,0]`. GSSettlerAM resolves to
its direct Asian/HairMessy01 traits despite having `TPLT` and `EAMT`: its ACBS
flags do not set `UseTemplate`. This retail result falsified and removed the
earlier EAMT-only inheritance assumption.

These passes prove the retail input contract only. OpenMW still visibly fails
Easy Pete's skin/beard color and hair/sideburn presentation, so pixel parity is
not promoted.

The maintained flat OpenMW portrait slice is
`goodsprings-easy-pete-actor-tracked-portrait`. It follows the live
`Bip01 Head` world transform and its local +Y face-forward axis through the
world-viewer camera path; it does not stage or rotate Pete and does not enable
the legacy bind-pose or hand-bind-frame proof modes. Patch 0013 then restores
the retail-measured +90-degree Y child basis that is lost when OpenMW consumes
the `BSFaceGenNiNodeBiped` wrapper during attachment. The face-parts-only A/B
runs at `fallout_new_vegas-20260710-231306` and
`fallout_new_vegas-20260710-232016` isolate that basis: the detached cluster
coalesces only with the measured transform. The no-override full-actor run at
`run/real-world-screenshots/fallout_new_vegas-20260710-232355` keeps Pete's
head and torso framed and the static face parts attached in both native
screenshots. Visual review still rejects the pixels because skin/material
color, scalp/sideburn hair, and the hand/sidearm assembly do not match retail.
The slice therefore remains `visualReviewRequired`; a native PNG count is not
a parity pass.

Patch 0014 and the root runner now make that framing contract machine checked.
Scheduled native capture does not focus or take over the desktop. The engine
emits the live actor reference, head center/forward axis, camera eye/target,
target error, and requested/actual distance. The harness requires both that
telemetry and the named `GSEasyPete` runtime ledger before accepting the files.
The tight portrait run at
`run/real-world-screenshots/fallout_new_vegas-20260710-234240` passed with
`targetError=0`, `eyeDistance=30`, two native frames, no foreground focus, and
no equipped weapon obstructing the face/material gate. Weapon attachment is a
separate failing slice rather than a contaminant in the portrait comparison.

Patch 0016 closes the remaining evidence-quality hole exposed by the earlier
burst: a correct camera transform was not enough when an animated hand crossed
the face. The scheduled frame now waits until the live head projects inside the
portrait safe area, both `Bip01 L Hand`/`Bip01 R Hand` bones are at least 18
units below the head, and the head transform is stable for eight consecutive
frames. The runner also rejects a manifest unless every native file has a
matching `World viewer portrait capture accepted` event. The final flat run at
`run/real-world-screenshots/fallout_new_vegas-20260711-005513` accepted the two
requests at frames 248 and 277 with normalized head position `(0.5,0.5)`, hand
offsets near `(-46.9,-45.6)`, exit code 0, and no foreground focus. Both frames
retain Pete's hat and shoulders with no hand or weapon covering the head. This
promotes the composition harness only; it does not promote retail color,
hair/sideburn geometry, or weapon attachment.

The earlier color verdict also mixed environment state: retail's saved global
snapshot reports `GameHour=14.4492416`, while the OpenMW proof forced noon.
The maintained portrait now uses `14.45`. xNVSE patch 0009 additionally records
the live weather FormIDs/transition and resolved ambient, directional, and fog
colors.

That environment gate is now measured and matched. The hidden retail run
`fnv-easy-pete-seated-render-environment-v1.jsonl` reports weather
`0x001237D7` (`NVWastelandGS`), no active transition, hour `14.4118919`,
ambient `(0.369318515,0.4469423,0.578699231)`, and warm directional/fog light
`(1,0.890196145,0.666666687)`. Patch 0015 loads the record and the OpenMW run
`fallout_new_vegas-20260711-003100` resolves it as
`FormId:0x11237d7`, imports 98 FNV weather records, and reproduces those vectors
at the proof hour. The frame remains less orange/contrasty than retail, which
isolates the next missing layer to the linked day/high-noon image-space
modifier `0x000CEE18`; it is no longer evidence for retuning Pete's diffuse.
