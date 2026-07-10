# Upstream Overlay Strategy

The direction is an OpenMW overlay that improves broad Bethesda-world loading
without turning the engine into a pile of game-specific branches.

The local repo can contain proof scripts, screenshots, generated ledgers, and
research-only Starfield experiments. An upstream PR should contain only the
smallest shared engine changes that are defensible, tested, and useful without
local assets.

## Patch Layers

1. Shared OpenMW core changes.
   These are candidates for upstream: tolerant record handling, archive format
   fixes, material/texture resolver improvements, cell lookup, logging, and
   renderer behavior that applies across multiple supported prototype games.

2. Data-driven game adapters.
   Per-game differences should be tables, capability checks, or small adapter
   functions keyed by engine family or record version. Examples: TES4 field
   shape, FO3/FNV record differences, TES5 geometry quirks, FO4 BA2/material
   variants. These should not silently change Morrowind behavior.

3. Local proof harness.
   Launchers, screenshot automation, actor proof catalogs, generated profiles,
   and machine-local paths stay in this repo. They provide evidence but do not
   ship upstream.

4. Research quarantine.
   Starfield and Fallout 76 work stays here until the lower-generation path is
   stable. Starfield can teach us about future adapters, but it should not drive
   the first upstream PR.

## PR Slices

The order should be conservative:

1. Baseline guardrails: no Morrowind regression, no profile contamination, useful
   diagnostic logging.
2. ESM4 cell/world lookup fixes that help Oblivion, Fallout 3, New Vegas, Skyrim,
   and Fallout 4-era content together.
3. Archive and asset resolver fixes with tests and no retail payloads.
4. Material/texture behavior that removes magenta, one-color, or zero-texture
   failures across multiple games.
5. Actor data and render fixes only after the actor catalog proves repeatable
   coverage by race/body/skeleton class.
6. VR integration only after the same flat pass is green.

Each PR should be able to answer:

- What upstream OpenMW behavior improves?
- Which supported prototype games benefit?
- What tests or proof ledgers show it?
- How do we know Morrowind did not regress?
- What remains intentionally unsupported?

## What Not To Upstream

- Hardcoded local install paths.
- Generated profiles, screenshots, or extracted assets.
- Starfield-specific runtime claims before the contract promotes Starfield out
  of asset research.
- Synthetic screenshot hacks as proof of renderer correctness.
- Broad claims like "supports every Bethesda game" when the actual pass only
  proves archive decode or a single cell.

