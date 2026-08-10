# Nikami shared world runtime

Dragon Age: Origins and Fallout: New Vegas keep separate source-format and
script adapters, but target one engine-neutral runtime contract.

```text
DAO ERF/RIM/GFF/NCS -> DAO adapter --+
                                      +-> World IR/state kernel -> Godot runtime
FNV BSA/ESM/FOS/ObScript -> FNV adapter+                       -> OpenMW bridge
```

## Shared contracts

- Stable namespaced entity IDs and source provenance.
- World/cell graph, transforms, portals, streaming tiers, and origin rebasing.
- Interaction routing and persistent door/container state.
- Inventory stacks, equipment slots, transactions, recipes, and crafting.
- Actor locomotion, animation intents, damage events, and combat targets.
- UI-facing inventory/map/quest models independent of presentation markup.
- Save-state overlay with opaque native data retained by the game adapter.
- Deterministic telemetry and state-transition tests.

## Game adapters

The adapters decode authored data into shared types and map committed state
back to the native representation. They do not implement another inventory,
door, crafting, or streaming system.

- DAO owns GFF/UTC/ARE/MOR interpretation, NCS engine functions, party/tactics,
  and DAO dialogue/cinematic semantics.
- FNV owns ESM override/FormID interpretation, ObScript/quest conditions,
  VATS, Pip-Boy Tile XML traits, and `.fos` byte mapping.

Unknown save fields remain immutable opaque ranges. Native write-back is
enabled field-by-field only after round-trip tests prove that untouched bytes
and load order are preserved.

## Renderer adapters

Godot receives generated render caches plus semantic manifests. OpenMW may
continue consuming native formats, but its mechanics should agree with the
same state-transition contracts. Renderer-specific materials, animation
bindings, collision objects, and UI widgets remain thin adapters over shared
runtime state.

## Streaming invariant

No cell becomes visible because the player crossed its load boundary. It is
requested in an outer prefetch ring and becomes eligible for visibility only
after its required tier is resident. Unload uses a larger boundary and minimum
residency time. Full detail cross-fades with HLOD while persistent terrain/world
LOD remains visible behind both tiers.

The opening movie and interactive menu are the startup preload window; there is
no separate loading screen. Runtime requests are biased six seconds along the
player/camera velocity. Doors and teleports keep rendering the source side until
the destination portal set is resident, then swap on an occluded frame. If I/O
falls behind, the runtime retains the coarser resident tier instead of exposing
an empty cell or a newly appearing object.
