# OpenNV campaign choices

OpenNV keeps official game files, the TTW output, and mod source directories
immutable. It creates only generated profiles under `profiles/`.

Choose the campaign **before creating a character**:

| Campaign | What it is | JAM option |
| --- | --- | --- |
| `NewVegas` | Standalone Fallout: New Vegas | Yes |
| `Fallout3` / `FO3` | Standalone Fallout 3 | No; use TTW for the Capital Wasteland with JAM |
| `TTW` | One cross-wasteland TTW character | Yes |

Do not load a save in a different campaign. A New Vegas save, a Fallout 3 save,
and a TTW save each have different master data and stay in separate campaign
save stores.

Stock TTW is the **TTW-style Fallout 3 path**: it starts a single character in
the Capital Wasteland and carries that character into the Mojave. It is not a
converter for an existing standalone Fallout 3 or New Vegas save.

JAM is an optional add-on instead of a campaign choice. New Vegas and TTW each
share their campaign save store between their plain and JAM profiles, so it can
be enabled later:

```powershell
# Create or continue a New Vegas character without JAM.
.\scripts\Start-OpenNV.ps1 -Campaign NewVegas -SkipMenu -NewGame

# Add JAM to that New Vegas campaign later.
.\scripts\Start-OpenNV.ps1 -Campaign NewVegas -EnableJam

# Create a standalone Fallout 3 character.
.\scripts\Start-OpenNV.ps1 -Campaign Fallout3 -SkipMenu -NewGame

# Create a TTW character; TTW includes both the Capital Wasteland and Mojave.
.\scripts\Start-OpenNV.ps1 -Campaign TTW -SkipMenu -NewGame

# Add JAM to a TTW campaign now or later.
.\scripts\Start-OpenNV.ps1 -Campaign TTW -EnableJam
```

Once a save has been made with JAM, continue that save with JAM enabled. The
launcher makes this visible on every start rather than silently changing a
character's mod stack.

The old style shortcuts still work:

| Shortcut | Equivalent |
| --- | --- |
| `-Style Vanilla` / `-Style FNV` | `-Campaign NewVegas` |
| `-Style JAM` / `-Style FNV-JAM` | `-Campaign NewVegas -EnableJam` |
| `-Style FO3` | `-Campaign Fallout3` |
| `-Style TTW` | `-Campaign TTW` |
| `-Style TTW-JAM` | `-Campaign TTW -EnableJam` |

## DLC ownership

Standalone Fallout 3 and New Vegas profiles use `-DlcPolicy Auto` by default:
they mount a DLC only when its master and all of its archives are present. This
lets someone launch a legal base-game install without pretending they own DLC.
Use `-DlcPolicy RequireAll` when a profile should refuse a partial ownership
set.

JAM itself requires `DeadMoney.esm`, `HonestHearts.esm`, and `LonesomeRoad.esm`
in addition to `FalloutNV.esm`, so a New Vegas owner without those DLCs can use
the vanilla profile but the manager will refuse the JAM variant.

TTW is different: its official installer requires both games' DLC and preorder
packs. Its full TTW profile never bypasses that requirement.

## Mod manager

`Manage-OpenNVMods.ps1` and `catalog/open-nv-modules.json` form the profile
mod manager. It registers untouched source directories from `local/paths.json`,
then mounts validated modules into generated profiles. It never copies files
into a game or the TTW installer output.

```powershell
# See every known module and its OpenNV compatibility state.
.\scripts\Manage-OpenNVMods.ps1 -Action List

# Preview a layer without changing a profile or game directory.
.\scripts\Manage-OpenNVMods.ps1 -Action Plan -Campaign TTW -Layer ttw-common

# Persist a compatible selection, then use it on launch.
.\scripts\Manage-OpenNVMods.ps1 -Action Enable -Campaign TTW -Layer quality-of-life
.\scripts\Start-OpenNV.ps1 -Campaign TTW -UseManagedMods
```

The first validated module is JAM. `ttw-common` records the current common TTW
recommendations and is deliberately blocked until each one has a verified
OpenNV runtime adapter. In particular, **(Benny Humbles You) and Steals Your
Stuff** needs the xNVSE/JIP/Johnny/ShowOff compatibility bridge and must be
enabled before the DC-to-Mojave transition; it is not safe to silently bolt
onto a transitioned character.
