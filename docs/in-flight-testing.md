# In-Flight Testing

## Rule

Every world-walker feature should pass flat first, then VR.

Flat testing gives us fast iteration on profile isolation, menu layout, cell
search, map coordinates, and travel. VR testing comes after the same action works
on desktop, using the existing menu quad, pointer, hands, and Pip-Boy path.

## Existing Binary Launch

Use the generated world-walker seed and existing OpenMW binaries:

```powershell
.\scripts\New-WorldWalkerSeed.ps1
.\scripts\Start-WorldProfileExisting.ps1 -WorldId fallout_new_vegas -Mode flat -DryRun
```

When the dry run looks right, remove `-DryRun`:

```powershell
.\scripts\Start-WorldProfileExisting.ps1 -WorldId fallout_new_vegas -Mode flat
```

Optional start-cell smoke test:

```powershell
.\scripts\Start-WorldProfileExisting.ps1 -WorldId fallout_new_vegas -Mode flat -SkipMenu -StartCell Goodsprings
```

The launcher uses:

```text
--replace config --config <profileDirectory>
```

That keeps each run on the generated profile and avoids ambient Morrowind or old
settings leakage.

## Interactive Fallout Walkaround

Use the dedicated walkaround launcher for a persistent, hands-on flat world session.
It applies the proven player anchor and first-person camera, enables the explicit
Fallout weather/cloud bootstrap, accepts live keyboard and mouse input, and does
not inject proof input or stop on a timer:

```powershell
.\scripts\Start-FalloutWalkaround.ps1 -WorldId fallout_new_vegas
.\scripts\Start-FalloutWalkaround.ps1 -WorldId fallout3
```

Close one game before starting the other. Use `-DryRun` to inspect the selected
cell, coordinates, environment, and command without launching OpenMW.

The named cell is only the initial spawn. The complete generated world profile is
loaded, neighboring exterior cells stream as the player crosses boundaries, and
the launcher imposes no one-cell restriction.

This is still a walking-simulator compatibility session rather than a complete
retail-game playthrough. Weather is explicitly bootstrapped until natural
CLMT/REGN selection is implemented.

## Screenshot Proofs

Capture one flat native screenshot for every ready generated world profile:

```powershell
.\scripts\Invoke-FlatWorldScreenshots.ps1
```

The runner writes a timestamped bundle under:

```text
proof/flat-world-screenshots
```

The current start-cell guesses live in
`catalog/flat-world-proof-starts.json`. These are smoke-test anchors only; the
cell catalog exporter will replace them with real searchable cells and
worldspace-aware coordinates.

## VR Pass

For generic profile VR launch dry runs:

```powershell
.\scripts\Start-WorldProfileExisting.ps1 -WorldId fallout_new_vegas -Mode vr -DryRun
```

For the calibrated FNV hands/Pip-Boy proof path, keep using:

```powershell
.\scripts\Start-FNVVRExisting.ps1 -DryRun
```

That batch path carries the known hand, finger, Pip-Boy, pointer, and save-profile
calibration. The generic profile launcher is for testing the world viewer shell;
the FNV VR launcher is for testing the full hands/Pip-Boy baseline.

## Flat Acceptance

A flat build is ready to promote to VR when:

- it launches the selected generated profile;
- the main/menu window opens without loading the wrong content;
- cell search resolves names or grid strings;
- exterior coordinate/map jump moves the player;
- crossing a cell boundary loads neighbors;
- logs do not show profile contamination or missing required archives.

## VR Acceptance

A VR build is ready when:

- the world-walker window appears on the VR menu quad;
- pointer aim and click activate controls;
- map click and search use the same travel bridge as flat;
- hands/Pip-Boy/HUD still attach in the FNV calibrated path;
- the player can jump, close the menu, and walk normally.
