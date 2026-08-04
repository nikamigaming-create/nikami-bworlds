# Dragon Age: Origins to OpenMW POC

This POC uses Haven Tools to extract the real Redcliffe Village level from the
installed Dragon Age: Origins data and composes the resulting meshes into an
OBJ that OpenMW's OpenSceneGraph loader can consume.

## Proven in the 2026-08-02 run

- Source geometry: `packages/core/env/lak100d/lak100d.rim`
- Source gameplay cell: `modules/single player/data/al_arl01al_redcliffe_villag.rim`
- Haven export: 44 terrain kinds, 165 prop kinds, 10 tree kinds, and 185 GLB
  resources.
- Scene composition: 3,289 visible mesh objects in a 183 MB OBJ.
- OpenMW load: the engine logged the OBJ as loaded with bounds
  `(-240,-694,-14.7794)` to `(760,544.042,129.962)`.
- Gameplay parsing: 54 authored creature placements, including 12 active
  placements, and 156 authored gameplay placeables.

## Important boundary

The world, setpieces, and actor records are real DAO content. Haven Tools does
not currently turn a humanoid UTC into its assembled body, equipment, hair,
and MOR-derived face during level export. Therefore the current OpenMW OBJ
contains the world and setpieces, while the `.havenarea` contains the exact
actor templates/transforms/active flags. It does **not** yet show visible
humanoid actors. No proxy people or fabricated placements are used.

For example, the live source template for Tomas resolves to the real
`arl100cr_tomas.utc`, human male appearance 15, head morph
`hm_arl100cr_tomas.mor`, commoner clothing `gen_im_cth_com_b02`, bow, and
dagger. The next integration step is to make Haven assemble those parts and
export one visual character asset per unique UTC template.

## Headless usage

```powershell
pwsh -File scripts/Invoke-DAOOpenMWPoc.ps1
```

The command refuses to overwrite an existing output directory. OpenMW engine
verification is optional because it needs a world-viewer-enabled OpenMW build
and a configured base world; pass `-OpenMWBinary`, `-OpenMWConfig`, and
`-OpenMWResources` to enable it.

