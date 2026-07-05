# World Profile Isolation

## Rule

Each world gets a self-contained profile directory:

- `openmw.cfg` owns data paths, archive order, content order, resources, encoding, and user-data.
- `settings.cfg` owns detail settings, model loading flags, map/HUD defaults, preload/cache behavior, and VR-adjacent knobs.
- `userdata/` owns saves and runtime output for that world.

Launches must use:

```powershell
openmw_vr.exe --replace config --config profiles/<world-id>
```

`--replace config` is not optional for the viewer. Without it, OpenMW can load ambient user config directories and reintroduce Morrowind or stale detail settings.

## Baseline Data

Baseline game data is cataloged in `catalog/bethesda-openmw-capabilities.json`:

- `content`: required ESM/ESP/ESL order for the base world.
- `archives`: required BSA/BA2 order for meshes, textures, sounds, voices, and startup assets.
- `defaultEncoding`: text encoding for that world profile.

Generated profiles use `replace=data`, `replace=fallback-archive`, and `replace=content`, so a Fallout, Oblivion, Skyrim, or Fallout 4 profile does not inherit Morrowind content.

The `resources=` line points at OpenMW engine resources. It is not game content and should not be used as a way to smuggle Morrowind data into ESM4 profiles.

## Detail Presets

Detail presets live in `catalog/world-settings-presets.json`:

- `morrowind_full_balanced`: full-playable Morrowind with balanced high detail.
- `esm4_world_viewer_high_detail`: Oblivion/Fallout 3/FNV/Skyrim-era walking-sim browsing.
- `fo4_ba2_research`: Fallout 4/Fallout 4 VR browsing with BA2/material assumptions kept isolated.

Generated viewer profiles disable `write to navmeshdb` and `enable nav mesh disk cache` by default. That keeps exploratory profile runs from writing shared navigation state while we are still proving world loading.

## Validation

After regenerating profiles, run:

```powershell
.\scripts\Test-WorldProfiles.ps1
```

The validator checks:

- generated `openmw.cfg` and `settings.cfg` both exist;
- content/archive/data replacement directives exist;
- non-Morrowind profiles do not reference `Morrowind.esm` or `Morrowind.bsa`;
- required detail sections exist;
- viewer profiles keep navmeshdb writes disabled.

## Future Split

Flat and VR can share the same world baseline, but they should not permanently share every setting. The next clean split is:

- `profiles/<world>/settings.cfg` for world-safe baseline detail.
- `profiles/<world>/settings.vr.cfg` or a generated VR overlay for headset-specific FOV, hands, HUD, and pointer settings.
- `profiles/<world>/settings.flat.cfg` for desktop proof runs.

For now, FNV's recovered hands/Pip-Boy launcher remains separate and documented in `docs/vr-hands-pipboy.md`.
