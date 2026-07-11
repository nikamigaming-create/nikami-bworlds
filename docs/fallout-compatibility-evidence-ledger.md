# Fallout Compatibility Evidence Ledger

This ledger prevents inferred or experimental behavior from silently becoming
a retail-parity claim. Update it whenever a compatibility rule is introduced,
removed, or promoted. Links are repository-relative unless an external
worktree is explicitly named.

Status meanings are defined in
`docs/fallout-retail-parity-reboot.md#guessevidence-gate`.

| Surface | Decision or invariant | Classification | Evidence | Current gate |
|---|---|---|---|---|
| Compact KF rotation | Serialized compact quaternion components are W,X,Y,Z and are reordered for OSG | format-proven + differential-proven | NIF schema/NifSkope; patch 0002 controller tests and transform comparisons | promoted |
| KF spline evaluation | Use clamped cubic de Boor evaluation and honor `0xffff` invalid handles | format-proven | NIFTools/NifSkope implementation; patch 0002 tests | promoted |
| KF spline accumulation | `getTranslation(time)` must sample compressed B-spline translation, not return zero | format-proven + differential-proven for Easy Pete entry | `chair_forwardenter.kf` Bip01 endpoints in `run/furniture-proof/chair-forwardenter-offline.jsonl`; xNVSE marker/settled delta; OpenMW `easy_pete_20260710_180700.log` | active; add focused unit test before promotion |
| Fallout rendered root | Accumulated `Bip01` X/Y drives gameplay movement and rendered root is reset | retail-proven + differential-proven for locomotion and Easy Pete enter-to-seat | xNVSE transform captures, patch 0002 walk proofs, OpenMW `easy_pete_20260710_180700.log` | promoted for locomotion; active furniture slice matches retail |
| Animation priorities | Locomotion/aim priorities and weapon target layering match retail blend arrays | retail-proven | `run/retail-oracle/fnv-retail-v8-core-priority-map.jsonl` and patch 0004 comparison | promoted |
| Bone LOD | Authored groups, retail distance equation, temporary-sequence gate | retail-proven + format-proven | retail captures v12/v16/v24/v25/v32/v41 and parity reports | promoted |
| FaceGen color | `_0.dds` neutral detail modulation, HCLR handling, authored beard/scalp texture slots | format-proven for asset selection; broad pixel differential unproven | patch 0007 Easy Pete records and color proof | partial; broader controlled retail/OpenMW pixel matrix required |
| Face-part attachment basis | Mouth, teeth, tongue, eyes, beard and hair stay in retail head space through every animation | unproven | current actor audit reports `mouth-not-front`, `eye-not-front`, and `facehair-not-front` | failing |
| Headgear during chair idle | Hat follows the animated retail head frame through enter, idle and exit | unproven | detached hat in `easy_pete_20260710_165942_shot03.png` | failing |
| Dialogue selection | Easy Pete GREETING/INFO and bounded CTDA functions | format-proven + runtime-proven for stated slice | patch 0007/0009 tests and dialogue logs | partial; unsupported CTDA remains false |
| Voice path | Authored response order and archive-resolved FO3/FNV voice playback | format-proven + runtime-proven for stated actors | patch 0008 proof manifests | partial; broad/multi-response queues pending |
| LIP decoding | Retail compressed LIP, 33 targets, voice-clock sampling | format-proven + differential-proven for FNV and FO3 samples | patch 0009 tests and telemetry proof directories | promoted for tested formats |
| FURN active marker | `activeMarkers=0x40000004` selects marker index 2 for Easy Pete's chair | retail-proven + format-proven + differential-proven for stated slice | `fnv-easy-pete-sit-state-v3.jsonl`, chair NIF marker scan, OpenMW `easy_pete_20260710_180700.log` | passed for marker 2; other marker directions pending |
| Furniture entry transform | Use marker world transform and marker heading; Easy Pete entry is `(-67911.5781,3445.1416,8387.31055)`, yaw about `4.761` | retail-proven + differential-proven for stated slice | xNVSE furniture state v3; OpenMW `easy_pete_20260710_180700.log` | passed for Easy Pete marker 2 |
| Furniture settled transform | Do not snap to FURN model origin; use the retail KF/runtime transition to reach `(-67966.9297,3447.80762,8387.31055)` | differential-proven for Easy Pete enter-to-seat | xNVSE furniture state/animation captures, Bip01 KF delta, OpenMW `easy_pete_20260710_180700.log` | passed within about 0.03 units for stated slice; broader matrix pending |
| Furniture enter group | Directional `chair_forwardenter.kf`, duration `1.733333` for marker 2 | retail-proven + format-proven + differential-proven for stated slice | xNVSE animation v1, KF sequence, OpenMW `easy_pete_20260710_180700.log` | passed for forward enter; other directions pending |
| Furniture idle | `dynamicidle_chairsit.kf` is the persistent full-body idle | retail-proven + format-proven | xNVSE animation v1 and source KF | active; visual/headgear gate failing |
| Furniture exit | Directional exit group and schedule-driven completion | unproven in OpenMW | source asset exists; retail exit capture still required for exact lifecycle differential | failing/pending |
| Furniture fast-forward | Correct offscreen/fast-forward settled placement | unproven | current model-origin fallback is not sufficient evidence | failing; must not promote silently |
| AI schedule subset | Travel/UseItemAt furniture package lifecycle and hour window | format-proven for parsed fields; broad behavior unproven | package records and current runtime logs | partial |
| Whole quest/script compatibility | All quests and compiled scripts execute as retail | unproven | bounded quest commands and save tests do not cover the full VM | open major milestone |
| Flat-only release gate | No XR executable/runtime is required or launched | explicit project contract | commands and proof manifests use `openmw.exe` | required for every promotion |

## Promotion rule

No row marked `unproven`, `failing`, or `partial` may be summarized as complete.
If a workaround is necessary to continue debugging, record it here and keep it
behind an explicit diagnostic switch until evidence promotes or removes it.
