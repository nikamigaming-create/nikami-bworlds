# FNV Save330 visual oracle

`retail-save330-reference.png` is not a recreation. It is the RGB24 screenshot
embedded at byte 147 of the exact 3,395,328-byte Save330 file with SHA-256
`07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f`.
Its decoded dimensions are 512x320.

The same pinned save now proves the Player ACHR movement prefix at
`497489+28`: ACHR `0x00000014` targets the Mojave Wasteland WRLD
`0x000DA726`, position `(-72392.84375, -1240.19275, 8137.58643)`, and rotation
`(-0.0643904507, -0.0, 2.93332028)` radians. The following `5,067` Player
payload bytes are fully schema-accounted offline. The committed engine parser
decodes the first `4,180` of them through actor values, factions, encounter
zone, all 50 inventory entries, mobile-object base/low/middle/high process
state, and the exact ChangedActor/ActorMover/ChangedCharacter continuation at
`[501187,501697)`. That 510-byte continuation has SHA-256
`3802ba9e14fc6a31cba704aa523ea18205e06d65ec537815ee75425422175c7a`.
The remaining `[501697,502584)` 887-byte tail is explicitly opaque with
SHA-256
`e2c332386e74a5114e27997356e9fe24cb4d49c876847b283604b4f56e4fc9d7`;
the next implementation slice is its 148-byte second animation buffer at
`[501697,501845)`. Across the complete Save330 file, parser non-opaque
coverage is now `660,561 / 3,395,328` bytes (`19.454998162%`), leaving
`2,734,767` semantically opaque bytes. The decoder passed 20/20 FONVSaveGame
tests, including the pinned external Save330 and corruption cases. This proves a player-reference
transform, inventory, process, and actor-mover payload, not the
screenshot-bound camera eye/heading/crop or authored visible-reference set;
those gates remain closed.

`initial-historical-openmw-rejected.png` deliberately pairs that retail oracle
with the closest exterior frame found in the user's earlier OpenMW recording.
The OpenMW half is rejected evidence: it has no normal-Save330 provenance, uses
third person instead of the retail first-person view, is not camera-aligned,
shows a different/duplicated stop-sign reference set, and cannot certify the
current renderer or load path. A 170-frame review of the pinned 340.031979-second
recording at two-second intervals found no first-person frame matching the
retail Save330 scene, so the closer third-person composition remains the honest
historical baseline rather than a fabricated camera match.

Generate a review pair with `scripts/render_fnv_retail_openmw_pair.py`. A future
right-hand image may be labelled `candidate` only when `--source-provenance`
is a valid `nikami-fnv-save330-openmw-capture/v1` manifest. Existence alone is
not enough: the tool re-hashes the supplied screenshot, Save330, binary,
configuration, log, retail-reference manifest, and every referenced file. It
also rejects a dirty/uncommitted runtime, VR, diagnostics, bootstrap or state
injection, forbidden launch arguments/environment, a substitute Player FormID,
wrong content order, and a monochrome/one-color/black frame.

The retail-reference manifest currently marks exact position, heading, FOV,
crop, time, weather, and visible-reference metadata as incomplete. Therefore no
OpenMW frame can become a candidate yet. Those fields must first be populated
from hash-accounted retail evidence in
`retail-save330-reference.manifest.json`; unknown values fail closed. Once that
oracle is complete, the pairing tool independently applies the maximum camera
and time tolerances declared by the capture schema and requires exact weather
and visible-authored-reference sets.

Candidate generation additionally requires the pinned `--retail-save`, a
written `--manifest`, and visible left/right labels. The generated manifest
always starts with `accepted: false`; visual review must explicitly close all
of these gates:

- full-color image with no monochrome/black-white corruption;
- first-person camera and closely matched pose, heading, field of view, and crop;
- matching authored reference set, including one correctly oriented stop sign;
- matching terrain, buildings, poles, wires, vegetation, sky, lighting, alpha,
  hands/weapon state, and HUD state;
- no missing, duplicated, mirrored, transparent, or disappearing geometry;
- exact source commit, binary, config, content order, data roots, and Save330
  hashes in the linked run manifest.

The historical pair is a defect baseline only. It grants zero playable-parity
credit.
