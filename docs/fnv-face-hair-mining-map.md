# FNV Face And Hair Mining Map

This is a public-safe map of local code and history to mine before changing
Fallout actor part transforms again. It intentionally records only code
locations, commit IDs, and validation notes; keep screenshots, extracted meshes,
textures, and retail-derived artifacts in ignored `proof/`, `local/`, or
`quarantine/` paths.

## Primary Source Tree

Use the local OpenMW downstream source at:

- `D:/Modlists/fnv/openmw-source`

The most relevant file is:

- `D:/Modlists/fnv/openmw-source/apps/openmw/mwrender/esm4npcanimation.cpp`

Mine these regions first:

- `esm4npcanimation.cpp:3285` - head-frame surface offsets and rotations
- `esm4npcanimation.cpp:3501` - FNV head-frame helpers
- `esm4npcanimation.cpp:5164` - actor part insertion and attachment policy
- `esm4npcanimation.cpp:5284` - static head attachment routing
- `esm4npcanimation.cpp:5600` - surface offset wrapper after attachment
- `esm4npcanimation.cpp:5990` - Easy Pete proof logging and FNV part assembly
- `esm4npcanimation.cpp:6258` - HDPT hair, beard, and extra head-part insertion

## Commits To Inspect

In `D:/Modlists/fnv/openmw-source`:

- `493d0506eb9ce5b2d8d3cb1be089f01c8911acc0` - Fix Fallout face part and hair alignment
- `77c47776a6a5d87464058fe778729988379ae71e` - Align Fallout face parts from head-frame data
- `7f3acdae7e13f59e811eaff5c7a5e960f0d9d870` - Fix Fallout face part attachment rendering
- `07674b0261f590dee18c993037b73ee058a58c34` - Fix FNV paper doll hair alpha and map proof
- `a391b71c1fd3aab322a194a708caecac21892a17` - Fix Fallout flag skinned mount offset
- `8d7218c118867736981bdf0bad9ba67aa3e9a1b5` - Take skin transform and skeleton root into account
- `fe40de3ec3546f3ec362950bba088296f2764ebe` - Improve Fallout FaceGen dialogue proof
- `54261acd26fa2baf2dbf9d59af2a7e8ab7ad58b3` - Fix Fallout brow classification and eye material handling

In `D:/Modlists/fnv` proof and harness history:

- `48841fcffc5136a89e255f477d424cfb2635a0c6` - Add Easy Pete dialogue proof controls
- `e44cd160be614338ffdcf1c1c32634d157e2906e` - Add Fallout transform sweep proof harness
- `3481f6ad4319064437acb1fc98f78c7965ea451f` - Record Easy Pete orbit audit baseline
- `48590bb6b9381f1ffcfe7b2c5f0e5d006d86ca2b` - Clear stale Fallout proof face transforms

In this patch-layer repository:

- `df3c05d4ef045dff4eca1ae37a377bdebf78a69a` - Capture local OpenMW world-viewer patch
- `cb0e7ad709a871897d317aeebc2483bf720a2dcc` - Capture FNV hair proof cleanup
- `patches/openmw/0001-local-world-viewer.patch` - current downstream patch export

## Matrix And Skinning Code

After reviewing the FNV actor attachment logic, inspect:

- `D:/Modlists/fnv/openmw-source/components/nifosg/nifloader.cpp:3370`
- `D:/Modlists/fnv/openmw-source/components/sceneutil/riggeometry.cpp:106`
- `D:/Modlists/fnv/openmw-source/components/sceneutil/riggeometry.cpp:856`
- `D:/Modlists/fnv/openmw-source/components/nif/node.hpp:124`
- `D:/Modlists/fnv/openmw-source/components/nif/node.cpp:201`
- `D:/Modlists/fnv/openmw-source/components/nif/niffile.cpp:105`

These are the likely places where head, hair, beard, eyes, and skinned clothing
leave the expected local space. Validate every transform change with an orbit or
head-frame proof, not a single front screenshot.

## Asset Studio Breadcrumb

The Easy Pete Asset Studio UI is documented here:

- `docs/facegen-asset-studio.md`
- `catalog/fnv-facegen-recovery.json`

The recovery ledger references source snapshot commits:

- `42fb54c2a7b29b2ed0346b4ccd564834af522fd4`
- `7cf9e6806a2ef7cdf5a1c2c162279c7d14903f8e`

Treat those as metadata breadcrumbs until the matching source snapshots are
recovered locally.

## Working Rule

If Sunny Smiles or another FNV actor has only a hair-orientation problem, do not
start by changing body or face offsets. First compare the current patch against
the FNV head-frame commits above, then run a small transform sweep that captures
front, side, and rear views.
