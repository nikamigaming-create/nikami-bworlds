# Fallout: New Vegas parity toolchain

The project treats external tools as independent format and behavior
authorities. Passing one demo is not parity: each subsystem needs repeatable
evidence from real, legally owned FNV content.

Run the implemented checks:

```powershell
.\scripts\Invoke-FNVParityToolchain.ps1
```

Generated/proprietary content stays under ignored `run/`.

| Area | Authority | Automated evidence | Current boundary |
|---|---|---|---|
| ObScript syntax and emission | `BarryThePirate/obscript-pipeline` at `9de1a5d` | Extract every official FNV ESM, compare Python/Lua ASTs and emitted Lua, rank commands | Parser/emitter parity is not runtime command parity |
| Engine object-script runtime | OpenMW MR 5444 port | OpenMW build plus parser/transpiler/runtime/VFS tests | Initial Enable, Disable, IsActionRef, player AddItem, and OnOpen vocabulary |
| NIF/KF/EGM structure | NifTools PyFFI at `7f4404d` and `nif.xml` at `970a623` | Parse Victor, humanoid, face, 10mm pistol, and animated-door samples | Structural acceptance does not prove animation timing/render parity |
| OpenMW asset interpretation | OpenMW `niftest` | Parse the same NIF/KF inputs accepted by NifTools | Add semantic block/bone/controller comparisons |
| ESM/ESP metadata and overlap | `Ortham/esplugin` reviewed at `e01c5b0` | Pending pinned Rust audit runner | `esplugin` is a library, not a ready CLI |
| Native saves and launch order | BWorlds `.fos` master parser and synthetic contract | Generate an isolated profile in exact save master order | Expand state coverage inside OpenMW |
| Retail gameplay behavior | Scripted retail oracle and deterministic traces | Compare quests, dialogue, AI, combat, inventory, crime, animation, and VATS | Must be expanded subsystem by subsystem |

Tool upgrades are deliberate: change the pinned revisions in the verifier,
rerun the complete evidence set, and review any changed output before merging.
