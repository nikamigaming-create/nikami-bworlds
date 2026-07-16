# FNV paired retail/OpenMW proof comparator

`scripts/compare_fnv_paired_proofs.py` is an offline triage stage for a retail
sidecar harness. It never starts, focuses, or controls either game. Each engine
writes an indexed evidence directory; a shared manifest names the exact pair.
The comparator then writes machine-readable actor defects and paginated contact
sheets.

## Pair contract

Pairing is capture-key based. File order and filename similarity are not used.
Each engine index must contain one supported row array (`rows`, `captures`,
`screenshots`, or `actors`). A row needs either `captureId`, or enough explicit
identity to construct `targetId::shotKind` (also accepted: `actorId`, `editorId`,
or `id` plus `shotKind`, `poseState`, or `pose`). Common row fields are:

```json
{
  "captureId": "SunnySmiles::stand-front-full-body",
  "actorId": "SunnySmiles",
  "shotKind": "stand-front-full-body",
  "screenshot": "screens/SunnySmiles-stand.png",
  "actorMask": "masks/SunnySmiles-actor.png",
  "partMasks": {
    "hair": "masks/SunnySmiles-hair.png",
    "head": "masks/SunnySmiles-head.png"
  },
  "telemetry": {
    "cameraStateId": "goodsprings-proof-camera-v1",
    "poseState": "stand",
    "geometry": { "present": true, "vertexCount": 18342 },
    "parts": {
      "hair": { "present": true, "effectiveAlpha": 1.0 },
      "head": { "present": true, "effectiveAlpha": 1.0 }
    }
  }
}
```

Image, mask, and telemetry paths are resolved relative to the index. Telemetry
may be inline or a JSON path. Masks are optional but are the reliable source for
silhouette and image-space part coverage. Non-opaque screenshot alpha can act as
an actor mask; an ordinary composited RGB screenshot cannot expose material
alpha.

Sidecar indexes may include `requestedState`. It is copied into the report for
audit only and is never treated as observed state. Camera, pose, equipment,
time/weather, and action gates read top-level observed fields or `telemetry`;
requesting a value is not proof that either engine applied it.

The shared manifest follows
`catalog/fnv-paired-proof-manifest.schema.json`:

```json
{
  "schema": "nikami-fnv-paired-proof-manifest/v1",
  "defaults": {
    "matchedCameraState": true,
    "matchedStateFields": [
      "cameraStateId",
      "poseState",
      "weaponId",
      "weatherId",
      "gameTime"
    ],
    "retailAuthorityFields": [
      "cameraStateId",
      "poseState"
    ],
    "expectedParts": [
      "head",
      "eyes",
      "hair",
      "body",
      "leftHand",
      "rightHand",
      "weapon"
    ],
    "faceParts": ["face", "head"],
    "requireFaceOverlayEvidence": true,
    "requireSkinColorEvidence": true,
    "skinColorGroups": [
      {
        "reference": ["face", "head"],
        "peers": ["leftHand", "rightHand", "bodySkin"]
      }
    ]
  },
  "actors": [
    {
      "actorId": "SunnySmiles",
      "captureId": "SunnySmiles::stand-front-full-body",
      "displayName": "Sunny Smiles",
      "expectedSlots": ["body", "head", "weapon"],
      "actorIntact": true,
      "goreCapParts": ["neckGoreCap", "leftArmGoreCap"],
      "requireGoreCapEvidence": true
    }
  ]
}
```

Use separate `retailCaptureId` and `openmwCaptureId` only when the engines use
different capture keys. Reusing either indexed capture in the same manifest is
a contract error.

## Run

```powershell
python scripts/compare_fnv_paired_proofs.py `
  --manifest run/paired-proof/manifest.json `
  --retail-dir run/paired-proof/retail `
  --openmw-dir run/paired-proof/openmw `
  --retail-index retail-index.json `
  --openmw-index openmw-index.json `
  --output run/paired-proof/comparison
```

If a directory contains exactly one `*index*.json` (or `manifest.json`), the
explicit index argument can be omitted. Ambiguous directories fail instead of
silently selecting the newest file.

Outputs:

- `paired-proof-report.json`: status, evidence hashes, metrics, and defects for
  every actor.
- `actor-defects.json`: compact per-actor triage ledger with defect codes and
  the most useful silhouette/pixel measurements.
- `contact-sheet.png` or `contact-sheet-NNN.png`: retail, OpenMW, amplified
  absolute delta, and silhouette coverage panes.
- `contact-sheet-index.json`: deterministic page list for large sweeps.

Pass `--fail-on-defect` for a nonzero exit when any actor has a failure defect.
Without it, contract errors still fail but visual defects are reported for
triage without breaking the batch.

## What the metrics mean

- Geometry and part presence come from masks and/or telemetry. Missing evidence
  is reported as `not-measured`; the comparator never calls absence a pass.
- `retailAuthorityFields` defaults to `cameraStateId` and `poseState`. A missing
  retail authority field makes the actor status `UNKNOWN`; a value that
  contradicts `retailState` is a failure. This prevents an unproven retail
  camera/state from becoming a false pass.
- Alpha comparison uses per-part `effectiveAlpha`, `alpha`, `materialAlpha`, or
  `opacity`. Composited RGB screenshots cannot prove alpha state. Render-ID or
  part masks expose holes and missing coverage after composition.
- Silhouette metrics report IoU, recall (missing retail coverage), precision
  (OpenMW-only excess), bounds, area ratio, and centroid offset.
- Pixel metrics report RGB MAE/RMSE, P95 error, PSNR, global luma SSIM, mean
  color, and luminance. No registration, resizing, translation, warping, or
  color fitting is performed.
- Face/head diagnostics compare overlay-applied flags, layer counts, alpha,
  near-black coverage, and luminance. They classify dropped overlays and black
  head artifacts independently from whole-frame exposure.
- Skin diagnostics compare the retail hand/body-skin-to-face RGB relationship
  with the OpenMW relationship. Configure `skinColorGroups` so clothing is not
  mistaken for exposed body skin.
- `expectedSlots` is the manifest-authoritative outfit/loadout slot set. Both
  retail and OpenMW telemetry must prove each slot; absent evidence is
  `UNKNOWN`, while missing or unexpected OpenMW slots fail.
- For `actorIntact: true`, declared or telemetry-classified gore-cap parts must
  be hidden. A visible cap is reported as `intact-gore-cap-visible`; missing
  cap telemetry is `UNKNOWN` when `requireGoreCapEvidence` is true.

Pixel metrics are only valid when camera matrix and FOV, actor transform, pose
and animation frame, equipment, time/weather, lighting, post-processing,
resolution, and crop are genuinely matched. Set `matchedCameraState` only when
the sidecar telemetry proves that contract. `matchedStateFields` adds equality
gates; a missing or unequal field disables pixel scoring and creates a failure.
This prevents a camera mismatch from being misdiagnosed as a shader defect.
