# OpenMW 0.51 opening-flow recovery checkpoint

Created: 2026-07-29 (America/Los_Angeles)

## Checkpoint state

The OpenMW 0.51 Fallout compatibility candidate is isolated and has passed the
two canonical authored opening routes.  It has **not** replaced the known-good
live launcher/runtime.

| Item | Value |
| --- | --- |
| Source repository | `D:\code\nikami-worlds\local\labs\openmw-051-clean-integration-r2` |
| Source branch | `codex/openmw-051-full-port-integration` |
| Source revision | `cdc28310804e2f33985f1786692c951ac7f46424` |
| Source worktree | clean at checkpoint creation |
| Staged candidate | `D:\code\nikami-worlds\local\staging\openmw-051-imad-expiry-cdc2831080` |
| Candidate `openmw.exe` SHA-256 | `1284D2871735CDF0B7B89D6D8AA65B07E10D07C0A2164F589DBBE818BCE12C78` |

## Verified routes

| Campaign | Result | Evidence |
| --- | --- | --- |
| New Vegas | Passed character defaults, Doc Mitchell opening, Vigor Tester, default SPECIAL (40 total), and Doc reaction at `VCG01` stage 70. | `D:\code\nikami-worlds\run\opennv-051-fnv-doc-vigor-r5-20260729-0120` |
| TTW / Fallout 3 | Passed character defaults, toddler controls, Dad trigger, playpen gate, and SPECIAL book at `CG01` stage 50. | `D:\code\nikami-worlds\run\opennv-051-ttw-nursery-special-r11-20260729-0111` |

Both reports have `status: pass`. The captures use engine-native framebuffer
frames and engine-internal authored routes; they report no Windows app control,
foreground activation, or foreground input injection.

Evidence integrity hashes:

| File | SHA-256 |
| --- | --- |
| TTW `openmw\opening-capture-report.json` | `57F7899FCB1266C1025208B17EBE64940A2A2CD5B5020E6EF623579DA5F128D8` |
| New Vegas `openmw\opening-capture-report.json` | `A88B5E9FA298CA3C6403BB4E90E92CC04A8820742B2A84F5998AC42EBE4F2E75` |

## Safe resume point

1. Keep the live launcher/runtime untouched.
2. Resume from source revision `cdc28310804e2f33985f1786692c951ac7f46424` and the staged candidate above.
3. Before launcher promotion, run a separate visual-parity/launcher acceptance pass.
4. Do not overwrite either evidence directory; create a new uniquely named capture directory for every rerun.

This checkpoint proves the two opening routes only. It does not claim global
asset, animation, shader, mod, or API parity.
