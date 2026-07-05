# FNV Asset Studio And FaceGen Recovery

The screenshot family is recoverable. The strongest surviving baseline is indexed
in `catalog/fnv-facegen-recovery.json`.

That render has the same structure as the image you showed: camera tiles, active
front view, Easy Pete reference inset, contract text, part profile tabs, and live
transform controls. The matching written baseline is summarized by the same
public-safe ledger.

## What To Keep

- Camera bar with front/back/left/right/top/bottom/iso views.
- Part profiles: face, body, hands, weapon.
- Reference contract text per actor.
- Transform controls and toggles, because they make visual fixes measurable.
- Contact-sheet output for Goodsprings actor batches.

## What To Add Later

- A sheen/material pass that can compare skin, beard, hair, and eye response under
  fixed light/camera settings.
- FaceGen part ledgers: head mesh, hair, eyebrows, beard, eyes, teeth, race, head
  parts, tint layers, texture paths, and missing/approximated fields.
- A stable actor QA export mode: one JSON result, one contact sheet, one set of
  camera tiles per actor.

## Recovery Manifest

See `catalog/fnv-facegen-recovery.json` for artifact IDs, hashes, and notes.

## Quarantine

The recovered Easy Pete package belongs in ignored local quarantine. Do not
commit renders, references, screenshots, extracted assets, or source snapshot
archives.

This is the baseline to reintroduce cautiously. Treat the alignment as useful and
the face defect as a material/alpha/depth ordering problem: the inside/back of
the head is drawing in front of the face, and the skin color response still needs
work.
