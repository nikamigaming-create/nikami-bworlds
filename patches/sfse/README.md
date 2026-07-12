# SFSE retail-oracle overlay

This source-only queue targets SFSE commit
`48535cc4306ab345252bf740c20a1c6194929b0e`. It adds the bounded Nikami
Starfield telemetry plugin used by `scripts/Invoke-StarfieldRetailOracle.ps1`.

Apply it to a clean SFSE checkout from the checkout root:

```powershell
Get-Content D:\path\to\nikami-worlds\patches\sfse\series | ForEach-Object {
  git apply --check (Join-Path D:\path\to\nikami-worlds\patches\sfse $_)
  git apply (Join-Path D:\path\to\nikami-worlds\patches\sfse $_)
}
```

Configure and build `nikami_starfield_oracle` with CMake and Visual Studio 2022.
The queue contains no Starfield data, runtime DLLs, executables, captures,
saves, or generated build output.
