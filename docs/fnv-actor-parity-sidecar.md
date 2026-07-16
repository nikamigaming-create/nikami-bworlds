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
animation, bone, material, FaceGen, dialogue, camera-matrix, or pixel parity;
those require the per-frame telemetry protocol and comparators described by the
remaining proof boundary.

The source capability preflight reports individual missing runner parameters,
retail endpoint tokens, and OpenMW integration calls. Execution refuses to
start lockstep while any are absent. It also records
`runtimeBinariesProven=false`: no static source check can prove that installed
binaries were rebuilt, so a stale runtime fails through the barrier timeout or
final NKSC state instead of being reported as parity.
