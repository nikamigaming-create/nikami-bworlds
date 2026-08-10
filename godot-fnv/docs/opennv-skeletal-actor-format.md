# OpenNV skeletal actor payload v1

`ONVSKEL1` is the lossless boundary between the live OpenMW actor assembler and
Godot. It exists because OBJ actor exports contain only one already-skinned
frame and cannot represent animation.

All values are little-endian. Strings are UTF-8 prefixed by a `uint32` byte
length. Matrices contain 16 row-major `float32` values in source coordinates.

1. Eight-byte magic `ONVSKEL1`
2. `uint32` version (`1`)
3. `uint32` surface count
4. For each rigged surface:
   - drawable name, root-bone name, diffuse-texture path
   - `uint32` vertex count, index count, bone count
   - mesh transform and skin-to-skeleton matrices
   - eight floats per bind vertex: position XYZ, normal XYZ, UV
   - triangle indices as `uint32`
   - each bone: name, signed `int32` parent index (`-1` for a root), inverse-bind matrix, current local matrix, current
     skeleton-space matrix
   - each vertex: `uint16` influence count followed by `(uint16 bone,
     float32 weight)` pairs

The payload deliberately preserves every authored influence rather than
silently truncating to four. A Godot importer may select four or eight weights,
but must report the discarded-weight error and fail its fidelity gate when that
error exceeds the configured tolerance. Animation clips and package state are
separate versioned products; a bind payload must never be labeled animation
complete.

## Authored animation companion

`ONVANIM1` stores the source KF text keys and each sampled optional
translation, quaternion rotation, and scale channel. The runtime binds those
tracks by authored bone name to every compatible surface skeleton. The first
experimental payloads are the retail humanoid and Securitron `mtidle`
sequences, sampled at 30 Hz. They are not runtime-promoted yet: rigid face,
hair, equipment, and robot attachments still require a v2 shared
skeleton/node graph before visible animation can be enabled. PACK-driven action
selection and navigation are also separate, explicit gameplay gates.
