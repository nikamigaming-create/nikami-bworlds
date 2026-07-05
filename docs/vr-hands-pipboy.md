# FNV VR Hands, Pip-Boy, Pointer, And HUD Recovery

## Verdict

The important work is recoverable. Keep the recovered package in ignored local
quarantine; the public repo stores only provenance and acceptance notes.

There are two separate baselines:

- Native OpenMWVR hands/Pip-Boy/pointer/HUD source: proven at commit `5266335943`, with a latest clean snapshot from `7cf9e6806a`.
- Retail FNVXR sidecar bridge: latest local working tree copy, based on commit
  `d690f6a` plus uncommitted local changes.

No literal `.epp` files or `EPP` markers were found in the targeted source/proof search. The preserved files are the actual source, launcher configs, and hand proof JSONs.

## What Was Preserved

- `source-snapshot/openmwvr-native-hands-proven-5266335943.zip`
- `source-snapshot/openmwvr-native-hands-current-7cf9e6806a.zip`
- `source-snapshot/fnvxr-retail-bridge-working-tree-20260705.zip`
- `configs/run_vr.bat`
- `configs/settings.cfg`
- `configs/openmw.cfg`
- latest hand mesh proof JSONs for `RightHand` and `LeftHandPipBoyGlove`

The extracted retail NIFs in the FNVXR proof tree were not copied into this workspace. They remain runtime-only references in `catalog/fnv-vr-hands-pipboy-recovery.json`.

## No-Rebuild Path

Configure `fnvRoot` in `local/paths.json`, then use the wrapper:

```powershell
.\scripts\Start-FNVVRExisting.ps1 -DryRun
```

## Anchors To Reuse

- `apps/openmw/mwvr/vranimation.cpp`: hand mesh attachment, finger curl, Pip-Boy wrist offset.
- `apps/openmw/mwvr/vrpointer.cpp`: controller pointer source and activation.
- `apps/openmw/mwvr/vrgui.cpp`: VR GUI focus and click injection.
- `apps/openmw/mwvr/openxrinput.cpp`: OpenXR actions and pose/action sources.
- `files/data/scripts/omw/vr/ui/common.lua`: wrist pointer and VR UI behavior.
- The ignored local `run_vr.bat`: authoritative calibration constants for the
  recovered FNV VR path.

## Integration Shape

For the world viewer, keep this order:

1. Use OpenMW/OpenMWVR as the shell, hands, pointer, and menu quad owner.
2. Use the world/cell picker to launch the selected generated profile.
3. Reuse the native OpenMWVR pointer for menu selection and later world object selection.
4. Keep FNVXR retail sidecar work as a separate bridge layer for Fallout New Vegas specific gameplay/UI proof.
5. Only start a full rebuild when the existing binary cannot validate the next slice.
