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
Compare captures with:

```powershell
python scripts/compare_fnv_goodsprings_appearance.py `
  --matrix catalog/fnv-goodsprings-retail-matrix.json `
  --capture easy-pete=run/retail-oracle/fnv-easy-pete-appearance-v2.jsonl `
  --out run/retail-oracle/fnv-goodsprings-appearance-differential.json
```

## Current evidence

Easy Pete and `GSSettlerAM` both pass the ESM-to-retail runtime differential.
Pete resolves to AfricanAmericanOldAged, HairAfricanAmericanBaseOld,
EyeDarkBrown, BeardFullOld, and HCLR `[192,192,192,0]`. GSSettlerAM resolves to
its direct Asian/HairMessy01 traits despite having `TPLT` and `EAMT`: its ACBS
flags do not set `UseTemplate`. This retail result falsified and removed the
earlier EAMT-only inheritance assumption.

These passes prove the retail input contract only. OpenMW still visibly fails
Easy Pete's skin/beard color and hair/sideburn presentation, so pixel parity is
not promoted.
