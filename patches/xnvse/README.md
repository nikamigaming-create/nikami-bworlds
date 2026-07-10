# xNVSE retail-oracle overlay

This queue adds the isolated `NikamiRetailOracle` plugin used to capture bounded,
read-only Fallout: New Vegas behavioral snapshots. It does not include or modify
retail game data, and it does not include compiled binaries.

The patch was exported against xNVSE commit `175bb28`. Apply it to a clean xNVSE
checkout from the checkout root:

```powershell
git apply --check D:\path\to\nikami-worlds\patches\xnvse\0001-add-nikami-retail-oracle.patch
git apply D:\path\to\nikami-worlds\patches\xnvse\0001-add-nikami-retail-oracle.patch
```

Build the Win32 Release plugin:

```powershell
& 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe' `
  .\nvse_retail_oracle\nvse_retail_oracle.vcxproj /p:Configuration=Release /p:Platform=Win32 /m
```

Use `scripts/Invoke-FNVRetailOracle.ps1` to install the DLL only for the bounded
capture and restore the retail Data directory afterward. The current oracle
also records final local/world bone transforms, sequence controlled blocks,
per-target blend arrays and priorities, cached interpolator channels, and the
retail Foot IK status. Its runtime-only struct views are confined to the oracle
plugin and do not modify xNVSE itself.
