# xOBSE retail-oracle overlay

This source-only queue targets xOBSE commit
`5078a1dcd2d115bf1f900cfe698b6334cae61707`. It adds the bounded Nikami
Oblivion telemetry plugin, a hidden-window guard DLL, and loader argument
handling required by `scripts/Invoke-OblivionRetailOracle.ps1`.

Apply it to a clean xOBSE checkout from the checkout root:

```powershell
Get-Content D:\path\to\nikami-worlds\patches\xobse\series | ForEach-Object {
  git apply --check (Join-Path D:\path\to\nikami-worlds\patches\xobse $_)
  git apply (Join-Path D:\path\to\nikami-worlds\patches\xobse $_)
}
```

Build the two Win32 Release projects and the patched xOBSE loader with Visual
Studio 2022. The queue contains no Oblivion data, runtime DLLs, executables,
captures, saves, or generated build output.
