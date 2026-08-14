# xOBSE retail-oracle overlay

This source-only queue targets xOBSE commit
`5078a1dcd2d115bf1f900cfe698b6334cae61707`. It adds the bounded Nikami
Oblivion telemetry plugin, a hidden-window guard DLL, and loader argument
handling required by `scripts/Invoke-OblivionRetailOracle.ps1`.

Apply it to a clean xOBSE checkout from the checkout root:

```powershell
$nikamiWorlds = Resolve-Path '<path-to-nikami-worlds-checkout>'
$patchRoot = Join-Path $nikamiWorlds 'patches/xobse'
Get-Content (Join-Path $patchRoot 'series') | ForEach-Object {
  git apply --check (Join-Path $patchRoot $_)
  git apply (Join-Path $patchRoot $_)
}
```

Build the two Win32 Release projects and the patched xOBSE loader with Visual
Studio 2022. The queue contains no Oblivion data, runtime DLLs, executables,
captures, saves, or generated build output.
