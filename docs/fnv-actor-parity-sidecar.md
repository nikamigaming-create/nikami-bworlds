# FNV actor parity sidecar

`scripts/Invoke-FNVActorParitySidecar.ps1` is a noninteractive coordinator for
one retail FNV process and one OpenMW process. Both lanes consume the same
ordered actor/action manifest. The coordinator does not click, focus, move, or
tile either window, and it does not relaunch either engine per actor.

The default `-Engine Both -ExecutionMode Parallel` path is fail-closed
lockstep. The coordinator creates one Windows memory-mapped channel, writes one
bulk retail plan, then starts the existing retail oracle and OpenMW actor sweep
once each. The two engine endpoints advance actor/action/capture state directly;
the coordinator never manufactures a ready signal or polls a file as a barrier.

## Manifest

The source manifest follows
`catalog/fnv-actor-parity-sidecar.schema.json`. Every ordered actor row carries:

- an authored retail reference FormID and expected base FormID;
- the exact OpenMW base and contiguous representative-roster index;
- a visual-type key;
- one selected main weapon (editor ID and FormID, or null for both);
- a zero-based capture index.

The scene carries a named front/full-body camera, proof anchor, target/player
coordinates, time, timescale, and retail/OpenMW weather IDs. A manifest carries
1–64 ordered action descriptors. Every descriptor has a unique stable ID, an
explicit group token for each engine, and a bounded frame count. The transport
does not assign semantic meaning to names such as `stand`, `walk`, or `shoot`.

Normalization expands the actor list into an actor-major capture sequence. A
capture row contains `captureOrdinal`, `actorIndex`, `actionIndex`, `actionId`,
and a stable action-level `captureId`.

`catalog/fnv-actor-parity-sidecar.sunny-smiles.example.json` is a real one-row
fixture for Sunny Smiles, representative index 73. Before launch, every row is
checked against the authoritative 452-visual-type roster at
`run/openmw-fnv-representative-visible-20260715/loaded-actor-roster-20260715-193048.json`.
The gate compares index, OpenMW base, visual signature, editor ID, and selected
weapon and records the roster SHA-256.

## NKSC v1 transport

The authoritative headers are:

- `oracles/xnvse/nvse_retail_oracle/sidecar_protocol.h`
- `D:\code\nikami-openmw-lab\apps\openmw\fnvsidecaripc.hpp`

The coordinator verifies both headers before any launch. NKSC v1 uses magic
`0x43534B4E`, a 65,536-byte shared block, a 512-byte header, and two 32,512-byte
payload regions. Four manual-reset events are derived from the mapping name:

- `.retail-ready`
- `.openmw-ready`
- `.capture-ack`
- `.error`

The state machine is `PlanLoaded`, `RetailPreparing`, `RetailReady`,
`BothReady`, `CaptureIssued`, `WaitingCaptureAck`, `Advancing`, `Complete`, or
`Error`. A successful run must finish in `Complete` with both
`RetailCompleteFlag` and `OpenMwCompleteFlag` and no error. Source readiness is
only a launch gate; this final shared-header state is the runtime proof.

The retail lane receives:

- `NIKAMI_ORACLE_PLAN_PATH`
- `NIKAMI_ORACLE_SHARED_MEMORY_NAME`
- `NIKAMI_ORACLE_BARRIER_TIMEOUT_MS`

OpenMW receives `OPENMW_FNV_SIDECAR_SHARED_MEMORY_NAME` and may fall back to the
retail mapping variable. The generated retail plan is a strict BOM-free,
line-oriented `nikami-fnv-retail-plan-v1` file containing one sequence row, one
scene row, 1–64 ordered action rows, ordered actor rows, and `end`.

## Validation and execution

Validate the manifest, roster, protocol headers, retail runner parameters, and
OpenMW source integration without launching either game:

```powershell
pwsh scripts/Invoke-FNVActorParitySidecar.ps1 `
  -ManifestPath catalog/fnv-actor-parity-sidecar.sunny-smiles.example.json `
  -ValidateOnly
```

Run both one-process lanes in lockstep after `capabilityPreflight.lockstepReady`
is true:

```powershell
pwsh scripts/Invoke-FNVActorParitySidecar.ps1 `
  -ManifestPath run/fnv-sidecar/representatives.json `
  -OutputRoot run/fnv-sidecar/captures `
  -Engine Both `
  -ExecutionMode Parallel
```

`Sequential` is valid for standalone/static lanes, but not for NKSC lockstep:
both endpoints must be alive together. OpenMW is visible by default;
`-BackgroundOpenMW` hides it. `-VisibleRetail` only controls the retail runner's
existing window-style option. The sidecar itself never repositions a window.

The run writes `normalized-manifest.json`, `retail-sidecar-plan.tsv`,
`sidecar-plan.json`, both native evidence trees, and `sidecar-result.json`.
The result records the final NKSC snapshot and labels lockstep true only when
the protocol completion contract passes.

### Retail post-frame appearance evidence

The retail ready/captured payload now adds
`appearance.schema = nikami-fnv-sidecar-appearance/v1`. Its bounded
`renderParts` projection is collected from the settled actor scene graph, not
from a screenshot or an actor-specific override. A part's only comparison
identity is `role/sourceFormId/sourceSlot/ordinal`; node addresses and child
traversal order are not emitted or used as identity. Retail FormIDs use fixed
`0x%08X` strings and a part without a biped source slot uses the unsigned
sentinel `4294967295`.

The retail role vocabulary is `face`, `leftHand`, `rightHand`, `exposedBody`,
`hair`, `eyes`, `headPart`, `equipment`, `weapon`, and `actor`. Every record
reports `required`, `attached`, `drawable`, and `visible`, plus raw effective
`alphaBits`. The v1 effective alpha is
`clamp(material.alpha * shader.alpha * shader.fadeAlpha, 0, 1)` and
`alphaBits` is the raw IEEE-754 bit pattern of that result. `modelHash`,
`nodeHash`, `materialId`, and `shaderId` remain absent from v1 until both
engines share canonical algorithms for those optional fields; retail wrapper
or scene-node paths are not treated as cross-engine identity.

Resolved shader bindings are ordered by stage and carry semantic, normalized
`textures/...` path, dimensions, D3D9 format, source kind, and
`d3d9-fnv1a32:%08x`. That content hash covers canonical D3D9 subresource bytes
in mip order (and fixed face order for cube textures), excluding pitch padding
and container headers. Face/body-mod cache paths are labeled `generated`;
ordinary texture-set paths are `authored` and pathless runtime resolutions are
`runtime`. Skin stages are `baseColor`, `normal`,
`faceGenDetail`, `bodyColor`, `skinScatter`, and `environmentMask`; equipment
and weapon stages use role-prefixed color/normal semantics.

Collection is capped at 8,192 scene nodes, 128 geometry candidates, 48 emitted
parts, 64 MiB of canonical bytes per texture, and a dynamically reduced
23,000-byte render-part budget inside the existing NKSC payload. The payload
reports `complete`, `truncated`, `visitedNodes`, and `candidateCount`, so a
limit or unreadable runtime resource cannot silently become parity evidence.

## Explicit static fallback

`-AllowStaticRetailProof` intentionally bypasses NKSC. It runs the legacy
authored-reference retail batch and the existing OpenMW sweep, so it is useful
for a quick non-lockstep inventory but is never labeled matched action/camera
state. Static mode can write actor-level retail/OpenMW indexes plus a paired
manifest for `scripts/compare_fnv_paired_proofs.py`.

The legacy retail plugin reads its target/base lists through 4,096-byte
environment buffers. Canonical lists therefore stop at 372 actors (4,095
payload characters), and the runner watchdog is capped at 300 seconds. These
limits apply only to the static fallback; the NKSC plan file is not subject to
the FormID-list environment limit.

Static retail screenshots prove only the authored reference's final staged
frame. Requested weapon, actions, camera, time, and weather remain under
`requestedState`, not observed telemetry. `matchedCameraState` remains false
until both engine outputs prove equivalent camera matrices/FOV and action frame.

## Remaining proof boundary

The OpenMW harness currently requires a contiguous slice of its deterministic
representative roster. Post-run gates reject base, visual type, selected weapon,
order, or requested-action coverage defects. Arbitrary reorder/subset selection
requires an engine-side explicit actor list.

An NKSC v1 `transport-complete` result proves that both endpoints published every
planned identity under the same monotonically increasing generation, with valid
payload CRCs and durable screenshots. It deliberately does **not** claim observed
animation, bone, material, FaceGen, dialogue, camera-matrix, or pixel parity.
The additive `appearance.renderParts` projection becomes evidence only when the
coordinator validates both endpoint payloads and its deterministic appearance
comparator passes; transport completion or screenshots alone do not establish
appearance parity.

The source capability preflight reports individual missing runner parameters,
retail endpoint tokens, and OpenMW integration calls. Execution refuses to
start lockstep while any are absent. It also records
`runtimeBinariesProven=false`: no static source check can prove that installed
binaries were rebuilt, so a stale runtime fails through the barrier timeout or
final NKSC state instead of being reported as parity.
