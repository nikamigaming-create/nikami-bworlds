# OpenNV Godot

This is the isolated Godot runtime lane for Fallout: New Vegas. It consumes a
legally owned installation and native `.fos` saves; no Bethesda assets or
generated conversions are committed.

## Current end-to-end spine

1. The existing native OpenMW FOS decoder normalizes the selected save.
2. `tools/build_bootstrap_manifest.py` creates a small, engine-neutral Godot
   boot contract with the exact save hash, load order, player transform,
   camera, weather, inventory, equipment, globals, and quest state.
3. The owned `Video/FNVIntro.bik` is converted locally for Godot playback.
4. Authored menu XML is extracted locally from `Fallout - Misc.bsa`.
5. Godot plays the opening movie, presents the menu, and Continue boots a
   first-person session backed by the native save state.
6. The save-centered ESM cell ring is reduced to engine-neutral placements;
   owned NIF render geometry is cached as Godot-importable meshes on `D:`.
7. The complete 9x9 full-detail neighborhood becomes resident behind the
   movie/menu, so Continue reveals 81 authored LAND heightfields and their
   placed objects atomically with no dedicated loading screen.

Movies and cutscenes are always skippable with Escape, Space, Enter, or the
controller cancel button. Escape from play returns to a live pause menu without
destroying the resident world, so Resume is immediate.

Normal play/development launches skip the intro and quick-resume the selected
native save. Use `Start-FNVGodot.ps1 -ShowMenu` when testing the menu or add
`-PlayIntro` only when deliberately testing the movie. `Play-OpenNV.cmd` is the
one-click quick-play entry point.

Build and validate:

```powershell
pwsh -File godot-fnv/scripts/Build-FNVGodotBootstrap.ps1
python godot-fnv/tools/export_fnv_cell_ring.py --esm "D:/SteamLibrary/steamapps/common/Fallout New Vegas/Data/FalloutNV.esm" --bootstrap godot-fnv/generated/bootstrap.json --radius 4 --output godot-fnv/generated/world/cell-ring.json
pwsh -File godot-fnv/scripts/Prepare-FNVGodotCellAssets.ps1 -Radius 2
pwsh -File godot-fnv/scripts/Test-FNVGodot.ps1
pwsh -File godot-fnv/scripts/Start-FNVGodot.ps1
```

The bootstrap ground remains a temporary collision fallback beneath 1,797
authored placements, but the 25-cell resident set now includes decoded LAND
heightfields and terrain collision. Authored materials/textures and NIF
collision are the next fidelity boundary; this is not yet a claim that every
gameplay interaction is complete.

## Gameplay promotion ladder

Each gate must operate from the same native-save manifest and retain FormIDs:

1. Authored exterior terrain/static geometry and collision around the saved
   cell.
2. Door activation, connected interior streaming, and return travel.
3. Containers and persistent inventory transfer.
4. Crafting station activation and recipe transactions.
5. Complete saved weapon inventory, equip, draw, fire, reload, ammo, and
   condition state.
6. Authored inventory/stats/map Pip-Boy Tile XML with shared gameplay models.
7. Save write-back/interchange only after state round trips can be proven
   without destroying unsupported native fields.
