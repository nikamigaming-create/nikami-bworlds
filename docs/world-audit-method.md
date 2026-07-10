# World Audit Method

The project moves forward by treating every supported game as a corpus to audit,
not as a one-off screenshot target.

The rule is: no new renderer or game-specific shortcut is promoted until the
current pass has repeatable evidence and a failure ledger. Starfield and
Fallout 76 stay on the asset-research track until the lower-generation OpenMW
targets have stable inventory, cell, material, and actor passes.

## World Order

1. Morrowind: baseline runtime and proof harness.
2. Oblivion: first ESM4 walking-sim target.
3. Fallout 3.
4. Fallout: New Vegas.
5. Skyrim 2011.
6. Fallout 4.
7. Fallout 76 and Starfield: asset research only until promoted by contract.

## Pass Shape

Each pass has one job and one evidence type:

- Profile isolation: generated `openmw.cfg` and `settings.cfg` reference only the
  selected world and repo-local OpenMW resources.
- Archive inventory: every BSA/BA2 in the profile is listed, hashed locally, and
  counted by extension/path class.
- Plugin record inventory: every ESM/ESP/ESL record type is counted, with cells,
  worldspaces, references, placed actors, base actors, doors, statics, lights,
  containers, and activators separated.
- Cell catalog: every interior cell and exterior grid has a stable id, display
  label, parent worldspace, reference counts, and candidate spawn point.
- Cell load smoke: representative cells launch in real OpenMW with native
  screenshots and logs. Synthetic capture is diagnostic only.
- Asset decode: every referenced mesh, texture, material, animation, sound,
  voice, UI image, and video path gets a resolved/missing/decode-failed row.
- Actor catalog: every NPC/creature reference maps to its base record, race,
  skeleton, model parts, face or head data, hair, eyes, equipment, animation
  roots, voice, and expected material set.
- Actor render proof: curated actors are rendered from real cells first, then
  broadened until the actor catalog has coverage by race/body/skeleton class.
- Zone traversal: exterior grids and door-linked interiors are loaded by slice,
  with crash, missing asset, magenta, one-color, and zero-geometry failures
  captured in a ledger.
- Regression promotion: only passes with stable evidence graduate to the next
  game.

## Harness Config

Screenshot starts and proof presentation policy live in
`catalog/flat-world-proof-starts.json`. The real screenshot runner reads the
world support tier from the seed, then applies those catalog rules; do not add
world-name conditionals to the runner for GUI hiding, camera anchors, or proof
start behavior. Start entries may declare an `environment` object for supported
OpenMW proof/viewer variables such as deterministic time or weather controls;
these settings must stay in the catalog so captures can be repeated and audited.
The same catalog declares `defaults.environmentPolicy.allowedPrefixes`; runner
and contract scripts must read that list instead of duplicating allowed
environment variable regexes.
Fallout 4 runtime evidence belongs under the `fallout4` world id and the
`Fallout4.esm` content contract. If the only local folder with those assets also
contains `Fallout4_VR.esm`, configure that folder as `fallout4Root` and keep VR
content out of the generated `fallout4` profile.

For per-game passes, keep alternate cells and capture timings as named
`slices` under the world entry. `Invoke-RealWorldScreenshots.ps1 -StartSlice`
selects one of those slices, merges it over the world-level start, and records
`startSlice`, `runSeconds`, `captureSeconds`, and the resolved catalog start in
the manifest. Use this for stable geometry/material slices, risky exterior
crash-repro slices, and focused actor slices instead of changing the world's
default start or adding world-name conditionals to the runner.
For ESM4 exterior slices, `esm4GridRadius` is also catalog-owned and is applied
as `OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS`; use this to widen or narrow a slice
without adding runner conditionals.
`defaults.capture` is the baseline for real screenshot runs. World and slice
`capture` blocks merge over it, then explicit command-line flags override the
merged config for one-off diagnostics. Resolved capture config is validated
before launch, including rejecting capture seconds that fall outside the run
window.
Command-line capture flags are explicit overrides for ad hoc diagnostics; stable
passes should move those values back into the named slice before evidence is
kept.
Known useful actor coverage cells that fall out of generated ranking belong in
`catalog/adventure-actor-retained-stops.json`. The adventure actor catalog
generator must read that file and preserve those cells without restoring staged
actor placement or camera-coordinate proof args.
Real screenshot manifests record a `captureAttempts` row for each configured
capture second. A passing screenshot can still have missed capture attempts;
those misses are telemetry for harness reliability and should not be inferred
from console output alone.
For orbital geometry reviews, prefer a single named slice with
`anchor.camera.sequence` and matching `capture.engineScreenshotFrames` over
relaunching OpenMW once per angle. The runner maps each camera keyframe to
`OPENMW_WORLD_VIEWER_CAMERA_SEQUENCE_*`, drains every new native screenshot at
the capture point, and writes one manifest screenshot row per copied file. This
keeps multi-angle world geometry evidence tied to one process, one log, and one
repeatable catalog entry. Multi-keyframe slices must also declare
`capture.expectedScreenshotCount`; the runner records it in the manifest and the
evidence classifier fails the manifest if fewer screenshot files are captured.
For one-process burst slices, `capture.expectedScreenshotCount` must match the
number of scheduled `capture.engineScreenshotFrames`; do not let those counts
drift.

Focused actor-animation experiments may opt into
`catalog/actor-animation-policy.json` engine environment with
`Invoke-RealWorldScreenshots.ps1 -UseActorAnimationPolicyEnvironment`. Do not put
unstable skeleton/KF binding experiments in broad screenshot starts.
For no-edit mode sweeps, pass explicit `-SetEnv NAME=VALUE` overrides. The
runner validates those names against `defaults.environmentPolicy.allowedPrefixes`
and records them in the manifest as `environmentOverrides`, so a one-off actor
experiment does not mutate the baseline policy. These overrides are also the
replay format for the future native proof harness UI described in
`catalog/proof-harness-ui-contract.json`.
The in-game proof panel must expose the same controls as the script path:
target selection, per-game actor policy, skinning mode, bind-rotation pin,
animation source, camera profile, capture burst, telemetry level, and visual
review verdict. FO3 and FNV may share control values and source-code paths, but
their policy rows, manifests, screenshots, and pass/fail ledgers stay separate.

Screenshot log classification lives in `catalog/screenshot-evidence-policy.json`.
Unknown missing image resources still classify as `missing-texture` failures.
Known broad-pass gaps such as UI skin, water defaults, terrain default texture,
and actor FaceGen texture warnings must be represented there, not as hardcoded
script regexes. Runtime log warning/failure patterns live in the same policy as
`runtimeLogRules`; broad screenshots can keep actor/runtime gaps as warnings
while focused actor passes promote the same evidence to failures.
Image proof thresholds also live in that policy under `imageQualityRules`.
Fallback window captures that are too small to prove rendering, such as an
OpenMW fatal-error dialog, must hard fail as `bad-screenshot`; they are useful
diagnostic evidence but not promotion evidence.
Manifest outcomes are also policy-backed. If a headless run exits before a
usable screenshot is captured, `manifestStatusRules` maps the manifest status
and exit code to failure classes such as `bad-screenshot` or `crash`; do not
add per-world no-screenshot branches to the measurement script.
The real screenshot runner records `processTermination` when it asks a still
running process to close during cleanup. A non-zero exit after
`processTermination.requestedByHarness=true` is not crash evidence by itself;
WER crash reports, profile-local `openmw-crash*.dmp` files, natural process
exit, or log evidence must carry that claim.

Actor runtime warning extraction also lives under
`catalog/screenshot-evidence-policy.json` in `actorRuntimeLedger`. The
`Measure-ActorRuntimeWarnings.ps1` ledger reads immutable screenshot manifests
and run-local logs, records actor FormIds, model animation counts, controller
registration, and idle-animation misses, then applies the configured actor
rules. Do not encode per-game actor exceptions in the script; add an explicit
policy rule or fix the underlying actor/animation binding.
If a manifest requested actor telemetry but the run-local log contains no actor
runtime signal at all, the ledger must emit a `questionable` `actor-runtime-gap`
row instead of leaving an empty file. Focused actor proof ledgers should use
`-IncludeClean` so passing actors remain visible next to failed or questionable
actors.
Profile-log fallback is off by default for this ledger; use
`-AllowProfileLogFallback` only for historical recovery diagnostics, not proof.

Actor animation asset expectations live in
`catalog/actor-animation-policy.json`. `Measure-ActorAnimationAssets.ps1` reads
the actor-runtime ledger, resolves each row's real screenshot manifest and
profile, then checks configured skeleton/KF candidates against loose data and
configured fallback archives. This separates "asset missing from the profile"
from "asset exists but the engine did not bind it." The same policy may declare
`engineEnvironment` for a focused actor pass, but that environment is applied
only when the screenshot runner is explicitly invoked with the actor-policy
switch.

When telemetry and asset ledgers pass but the screenshot is visibly wrong, write
`run/audit/actor-visual-review.jsonl` with `Add-ActorVisualReview.ps1` and keep
the pass stopped. A clean actor-runtime ledger is not promotion evidence if the
actor pose, orientation, or body assembly is visually broken. Visual review
failure and warning classes must already exist in
`catalog/world-audit-contract.json`; `Test-WorldAuditContract.ps1` validates
existing visual-review rows against that vocabulary so ad hoc class names do not
silently enter the audit.
`Measure-ActorProofStatus.ps1` combines focused actor runtime ledgers with exact
manifest visual-review rows. Missing visual review for the same manifest is an
`actor-visual-review-gap` warning, not a pass.
The proof-status combiner must use the effective final skinning mode from the
manifest, including command-line `-SetEnv` overrides, before deciding whether a
row is source-skinning containment. The sweep runner writes a run-local
`actor-proof-status.jsonl` for this combined verdict.
When visual review rows are added after a sweep, refresh the run with
`Update-ProofHarnessSweepSummary.ps1` so the JSON summary and markdown summary
match the latest review ledger.
Use `Show-ProofHarnessSweepStatus.ps1` as the first readout for a sweep; it
shows the proof/runtime/rig/part-telemetry/visual gates plus the exact manifest
and screenshot paths for rows that still need work.
Use `Show-ActorProofArmory.ps1 -NoNetwork` before applying another engine
experiment. It ties the latest sweep verdict to the quarantined patch files and
local candidate branches, so the next source slice starts from recorded evidence
instead of memory. Drop `-NoNetwork` only when you explicitly want to re-check
public upstream branch names. If live Git scanning cannot read local lab
branches, the armory falls back to `catalog/local-openmw-candidates.json`; keep
that catalog limited to branch names, commit ids, and notes, never source
snapshots or rendered assets.
For head and face failures, keep the distinction between attachment-space
evidence and render-buffer evidence. A rigged head part with source vertices but
no inspected render buffer is `actor-head-render-gap` until a run with
`renderSource` proves the last-frame rig geometry is actually present.
For FO3/FNV inverted actors, do not retest native callback basis modes blindly.
The 20260707-225321 basis audit proved 256 visible callback rows per game with
large applied-versus-raw deltas, but 0013 `raw`, `no-half-turn`, and `bind`
modes still failed visual proof. Plain `OPENMW_FNV_ROOT_UP_CORRECTION=x90` and
`x-90` also failed on FO3: root orientation participates, but the next slice
must inspect actor root/world transform together with part attachment basis.
When measuring a slice, pass explicit manifest paths; `-IncludeManifests` is for
whole-archive scans when no explicit input is supplied, not for focused proof
promotion.

Every real screenshot manifest should include a run-local `openmw.log` snapshot.
The evidence classifier must prefer that immutable log over the mutable profile
log so old screenshots do not change classification when a later run overwrites
the profile output.

## Failure Classes

Failures are data, not noise. Use stable categories so fixes can be compared:

- `profile-contamination`
- `missing-archive`
- `missing-content`
- `record-parse-failed`
- `cell-load-failed`
- `bad-screenshot`
- `missing-mesh`
- `zero-geometry`
- `missing-texture`
- `texture-decode-failed`
- `material-fallback`
- `one-color-screenshot`
- `void-background`
- `magenta-fallback`
- `actor-root-missing`
- `actor-part-missing`
- `actor-pose-invalid`
- `animation-bind-failed`
- `actor-runtime-gap`
- `crash`

## Warning Classes

Warnings identify known broad-pass gaps that do not promote a pass by
themselves:

- `ui-resource-gap`
- `water-resource-gap`
- `terrain-default-resource-gap`
- `engine-placeholder-resource-gap`
- `normal-map-resource-gap`
- `actor-texture-gap`
- `missing-video`
- `record-runtime-gap`
- `animation-bind-gap`
- `actor-runtime-gap`
- `actor-render-gap`
- `actor-basis-audit-gap`
- `actor-basis-large-delta`
- `actor-runtime-suppressed`
- `actor-visual-review-gap`
- `animation-asset-optional-missing`

## Promotion Gates

Before a game moves to a broader pass:

- Morrowind must remain visually good with native screenshots.
- The game profile must pass `Test-WorldProfiles.ps1`.
- The seed/contract must pass `Test-WorldWalkerContract.ps1` and
  `Test-WorldAuditContract.ps1`.
- A pass must write local evidence under `run/` or `proof/` and summarize it in
  a ledger; screenshots alone are not enough.
- `Test-WorldAuditContract.ps1` must validate the screenshot start policy and
  screenshot evidence policy before accepting new proof output.
- A Starfield-specific fix cannot change the baseline path for Morrowind,
  Oblivion, Fallout 3, Fallout: New Vegas, Skyrim, or Fallout 4 unless those
  worlds pass the same contract afterward.
