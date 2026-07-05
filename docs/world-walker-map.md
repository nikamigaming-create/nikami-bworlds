# World Walker Map And Search

## First Cut

The first in-world walker should do four things well:

1. Open a native OpenMW window from the existing menu/VR quad.
2. Search cells by name, editor ID, worldspace, and grid coordinate.
3. Let exterior worlds be clicked on a coarse map and converted to coordinates.
4. Teleport the player to that cell/coordinate, then let normal neighboring-cell
   loading take over.

This is enough to turn a loaded profile into a dead-world explorer.

## UI Shape

The first window should have:

- A search field.
- A worldspace selector for games with multiple exterior worldspaces.
- A result list with interior cells, exterior cells, and named spawn markers.
- A map pane for exterior worldspaces.
- Coordinate fields for direct `x`, `y`, optional `z`, grid `cellX`, and `cellY`.
- A single go action.

Interior cells do not need map click support in the first pass. They can use the
search/list path and the existing spawn-marker fallback chain.

## Engine Travel Chain

Existing code already gives us most of the travel path:

- `apps/openmw/mwworld/worldimp.cpp`: `World::findInteriorPosition`
- `apps/openmw/mwworld/worldimp.cpp`: `World::findExteriorPosition`
- `apps/openmw/mwworld/worldimp.cpp`: `World::changeToCell`
- `apps/openmw/mwlua/objectbindings.cpp`: player teleport plumbing
- `apps/openmw/mwgui/mapwindow.cpp`: local-map coordinate conversion patterns

The viewer bridge should expose a small native API instead of pushing this logic
into the UI widget:

```text
ViewerTravel::travelToInterior(cellNameOrId)
ViewerTravel::travelToExteriorCell(worldspaceId, cellX, cellY)
ViewerTravel::travelToExteriorPosition(worldspaceId, worldX, worldY, optionalZ)
ViewerTravel::travelToNamedCell(nameOrGridText)
```

The bridge resolves the cell, chooses a safe position, and calls
`World::changeToCell(cellId, position, true, true)`.

## Map Click Coordinates

Exterior map click is a coordinate transform:

1. The cell catalog provides worldspace bounds in cell coordinates.
2. The UI converts click pixels to normalized map coordinates.
3. Normalized map coordinates become `cellX`, `cellY`, and local cell fraction.
4. Cell size comes from the loaded worldspace.
5. World coordinates become:

```text
worldX = (cellX + localX) * cellSize
worldY = (cellY + localY) * cellSize
```

For the first cut, `z` can be omitted. The bridge can set `z = 0` and allow
OpenMW's normal adjust-player-position path to settle the player. When terrain
height is reliable for a worldspace, the bridge can use
`getTerrainHeightAt({ worldX, worldY, 0 }, worldspaceId)` plus a small safety
offset.

## Cell Catalog

The native window can enumerate cells at runtime, but a catalog is still useful
because it lets the menu show searchable data and world bounds before every cell
has been loaded.

The first catalog exporter should write:

- world ID and content/profile hash;
- worldspaces with display names, IDs, cell size, and grid bounds;
- exterior cells with grid coordinates and center positions;
- interior cells with name/editor ID and preferred spawn marker;
- warnings for missing land, missing model data, or unresolved parent
  worldspaces.

The schema stub lives in `catalog/cell-catalog.schema.json`.

## Existing Tool Check

There may be a built `esmtool.exe` next to the configured external OpenMW
binary root:

```text
<openmwBinaryRoot>/esmtool.exe
```

It can parse files and expose some record filters, but this build reports that
raw TES4 printing is not supported. That means it is not a reliable no-build
source for clean JSON CELL/WRLD catalogs. The practical next step is a tiny
runtime/exporter pass inside the OpenMW fork that walks the already-loaded
`ESMStore` and writes the schema above.

## What We Still Need

1. Runtime or offline cell catalog export from `ESMStore`.
2. Explicit worldspace-aware exterior coordinate travel. Current text-grid travel
   is mostly default-worldspace oriented.
3. A MyGUI `WorldWalkerWindow` layout and controller.
4. A main-menu/VR-menu entry that opens the world walker after a profile is
   loaded.
5. Flat and VR smoke tests: open window, click map, jump, walk across a boundary.
6. Later: object/person search using the same pointer/HUD path.
