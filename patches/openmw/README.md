# OpenMW Patch Queue

This directory is the downstream patch layer for Nikami Worlds.

OpenMW and OpenMW VR are external dependencies. Do not vendor their source trees
here. Point `local/paths.json` or environment variables at the checkout/build you
want to use, then apply this queue onto that external tree.

Typical flow:

```powershell
Copy-Item config/paths.example.json local/paths.json
# Edit local/paths.json for this machine.

.\scripts\Apply-OpenMWPatches.ps1 -Check
.\scripts\Apply-OpenMWPatches.ps1
```

Patch files listed in `series` are applied in order. Keep patches small and
topic-focused so a later upstream rebase is survivable.

If one downstream patch matures into something upstream-worthy, split it into a
clean branch in the external OpenMW checkout and submit a normal upstream PR.
After it lands upstream, drop the local patch from this queue and update the
dependency baseline.
