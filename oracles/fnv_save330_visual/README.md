# FNV Save330 visual oracle

`retail-save330-reference.png` is not a recreation. It is the RGB24 screenshot
embedded at byte 147 of the exact 3,395,328-byte Save330 file with SHA-256
`07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f`.
Its decoded dimensions are 512x320.

`initial-historical-openmw-rejected.png` deliberately pairs that retail oracle
with the closest exterior frame found in the user's earlier OpenMW recording.
The OpenMW half is rejected evidence: it has no normal-Save330 provenance, uses
third person instead of the retail first-person view, is not camera-aligned,
shows a different/duplicated stop-sign reference set, and cannot certify the
current renderer or load path.

Generate a review pair with `scripts/render_fnv_retail_openmw_pair.py`. A future
right-hand image may be labelled `candidate` only when `--source-provenance`
points to an existing manifest for a committed binary that consumed this exact
Save330 through the ordinary `.fos` load path. The generated manifest always
starts with `accepted: false`; visual review must explicitly close all of these
gates:

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
