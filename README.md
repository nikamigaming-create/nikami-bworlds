# Nikami Worlds

Clean world-selection and patch layer for OpenMW and OpenMW VR experiments.

The goal is to make one shared catalog that both flat OpenMW and OpenMW VR can use:

1. Detect installed Bethesda worlds and existing OpenMW profiles.
2. Classify each world by what OpenMW can honestly load today.
3. Generate isolated `openmw.cfg` profiles per world.
4. Feed the same catalog into a native in-engine world/cell picker later.
5. Use the loaded profile as a world walker: search cells, click exterior maps,
   enter coordinates, and teleport there.

This repo intentionally does not vendor OpenMW or OpenMW VR source. Treat those
trees as downstream dependencies: point this repo at an external checkout/build,
apply `patches/openmw/series`, and keep the dependency replaceable.

If a downstream patch becomes generally useful, split it into a clean branch in
the external OpenMW checkout and submit a normal upstream PR. Once accepted, drop
the local patch and consume it through the dependency stream.

## Public-Safe Policy

Do not commit Bethesda assets, screenshots, extracted meshes/textures, generated
profiles, local install catalogs, crash dumps, binaries, or quarantined recovery
bundles. They are ignored by default. Public files should contain code, patch
metadata, hashes, contracts, templates, and documentation only.

Create a local machine config from the example:

```powershell
New-Item -ItemType Directory -Force local
Copy-Item config/paths.example.json local/paths.json
```

Then edit `local/paths.json`, or set the equivalent environment variables:

- `NIKAMI_OPENMW_SOURCE`
- `NIKAMI_OPENMW_BUILD`
- `NIKAMI_OPENMW_BINARY_ROOT`
- `NIKAMI_OPENMW_RESOURCES`
- `NIKAMI_FNV_ROOT`
- `NIKAMI_STEAM_APPS_ROOTS`

## Quick Start

Run the scanner:

```powershell
.\scripts\Scan-BethesdaWorlds.ps1 -GenerateProfiles
```

Outputs:

- `catalog/worlds.local.json`: local install/capability inventory.
- `profiles/<world-id>/openmw.cfg`: generated content/archive profile.
- `profiles/<world-id>/settings.cfg`: generated per-world detail/settings profile.
- `profiles/<world-id>/userdata`: isolated saves/runtime output for that world.

Validate profile isolation:

```powershell
.\scripts\Test-WorldProfiles.ps1
```

Flat-test a generated profile with the existing OpenMW binary:

```powershell
.\scripts\New-WorldWalkerSeed.ps1
.\scripts\Start-WorldProfileExisting.ps1 -WorldId fallout_new_vegas -Mode flat -DryRun
```

Apply the downstream OpenMW patch layer:

```powershell
.\scripts\Apply-OpenMWPatches.ps1 -Check
.\scripts\Apply-OpenMWPatches.ps1
```

## Current Feasibility

Yes, the walking-simulator world viewer is feasible for the games OpenMW's ESM4
prototype can already load: Morrowind, Oblivion, Fallout 3, Fallout: New Vegas,
Skyrim-era content, and Fallout 4-era content. Starfield is not in OpenMW's
official prototype target list yet; this workspace has some Starfield BA2 archive
version handling, but that is not enough for a connected Starfield world viewer.

See [architecture.md](docs/architecture.md) for the engine integration path.
See [world-walker-map.md](docs/world-walker-map.md) for the first map/search
teleport contract.
See [in-flight-testing.md](docs/in-flight-testing.md) for the flat-first, VR-next
test loop.
See [world-profile-isolation.md](docs/world-profile-isolation.md) for the
content/settings/user-data isolation rules that keep Morrowind and ESM4 worlds
from contaminating each other.

Generate the world-walker seed manifest:

```powershell
.\scripts\New-WorldWalkerSeed.ps1
.\scripts\Test-WorldWalkerContract.ps1
```

## FNV Actor Artifacts

Recovered Easy Pete and Goodsprings FaceGen/Asset Studio references are indexed in
`catalog/fnv-facegen-recovery.json`. See
[facegen-asset-studio.md](docs/facegen-asset-studio.md) for how those artifacts
fit into the later actor/material evaluation pass.

Local quarantined copies are intentionally ignored and should stay machine-local.

## FNV VR Foundations

Recovered hands, Pip-Boy, pointer, wrist HUD, and FNVXR bridge anchors are indexed
in `catalog/fnv-vr-hands-pipboy-recovery.json`. See
[vr-hands-pipboy.md](docs/vr-hands-pipboy.md).

Local quarantined copies are intentionally ignored and should stay machine-local.

No-build FNV VR dry run:

```powershell
.\scripts\Start-FNVVRExisting.ps1 -DryRun
```
