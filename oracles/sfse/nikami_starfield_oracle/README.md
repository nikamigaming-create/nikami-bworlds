# Nikami Starfield retail oracle

This is a read-only, version-pinned SFSE DLL used to compare Starfield 1.16.244 native composition with Nikami Worlds/OpenMW. It records reference transforms and loaded 3D node trees for the player and requested actor or static-reference FormIDs, then exits its own hidden process.

It does not inject input, move actors, change inventory, save the game, or interact with any foreground window. The sole native function entry point is `Starfield.exe + 0x005DE3B0` (`TESForm::GetFormByNumericID`), taken from the matching open-source SFSE revision. All other engine data is read directly from the matching source-defined structures on the game main thread.

Build:

```powershell
cmake -B build -S . -A x64
cmake --build build --config Release --parallel 8
```
