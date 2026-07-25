# JAM 4.6 full compatibility proof

The publishable claim is gated by
[`catalog/fnv-jam-4.6-full-proof-contract.json`](../catalog/fnv-jam-4.6-full-proof-contract.json).
Its command inventory is generated in
[`catalog/fnv-jam-4.6-command-footprint.json`](../catalog/fnv-jam-4.6-command-footprint.json)
from the untouched ESP and the provider source trees.
The existing sprint video is useful evidence for one slice, but it cannot pass this
contract because it excludes the other JAM modules, animations, sounds, and the
general provider layers.

## What the viewer must see

Every chapter is a synchronized retail-FNV/OpenMW split screen. A compact overlay on
each side is populated from live telemetry and shows:

`scenario -> JAM source script -> xNVSE/provider command or event -> native engine path -> resulting state`

A generic “plugin loaded” or “hello world” label is not evidence. The command/event
name must advance when the action occurs, and the shown state must be independently
measurable in the engine. The raw retail and OpenMW captures remain available beside
the edited split screen so every transition can be checked.

The final cut has chapters for Dynamic Crosshair, Hit Marker, Hit Indicator, Loot
Menu, Visual Objectives, Weapon Wheel, Bullet Time, Hold Breath, Sprint,
configuration/save-reload, and the separately labelled kNVSE animation probe.

Dynamic Crosshair is the flagship shot. It must visibly include:

1. armed and stationary;
2. walking and running spread expansion;
3. firing expansion;
4. stopped recovery;
5. aim-down-sights mode;
6. an interactable prompt without breaking the reticle; and
7. a hostile target with the correct system color.

For every chapter, the contact sheet contains side-by-side `before`, `action`, and
`after` frames. The validator also requires matching timestamped video intervals and
telemetry assertions, so a still frame cannot substitute for execution.

## Layer proof

The layer panel is cumulative and event-driven:

- **JAM** identifies the actual SCTX script/UDF that initiated the work.
- **xNVSE core** shows expression/UDF/event/serialization and command-dispatch IDs.
- **JIP LN** or **JohnnyGuitar** appears only when that provider actually dispatched
  the shown command or callback.
- **OpenMW native** names the engine subsystem that changed state.
- **kNVSE** is exercised in its own clearly labelled animation probe because JAM 4.6
  contains zero active direct kNVSE calls. It must never be falsely presented as a
  JAM dependency invocation.

## Non-negotiable gates

- The JAM archive and ESP hashes match the contract, the ESP is untouched, and no
  Windows DLL from the mod is loaded by OpenMW.
- All 52 SCTX sources parse with zero compile failures.
- Runtime coverage reconciles against the generated footprint: 109 unique xNVSE
  symbols, 120 JIP LN commands, 13 JohnnyGuitar commands, and zero active direct
  kNVSE calls.
- Unknown-command fallback, zero-return stubs, failed event registrations, and failed
  serialization round trips are all zero.
- Every gameplay chapter passes on both retail and OpenMW using the same save,
  configuration, target IDs, camera heading, route, and input sequence.
- The OpenMW behavior is driven by real UI, input, actor values, inventory, quest,
  animation, audio, physics, projection, time, and serialization systems.
- Sprint checks absolute speed, AP drain/recovery, animation, sound, turning, and
  cloud rate. Dynamic Crosshair checks changing geometry and target/prompt states,
  not merely whether a reticle texture is present.

Run the contract validator by itself while developing:

```powershell
pwsh -File scripts/Test-FNVJamFullProof.ps1 -ContractOnly
```

Run the release gate against a generated report:

```powershell
pwsh -File scripts/Test-FNVJamFullProof.ps1 `
  -ReportPath run/<full-proof-run>/proof-report.json
```

The release video and claim are publishable only when that second command exits zero.
