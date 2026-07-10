# Fallout 3 / New Vegas Flat Overlay Validation — 2026-07-10

This note is the promotion record for OpenMW overlay patch 0002. It covers the
actor-animation and attachment milestone only. It does **not** claim complete
quest, dialogue, condition, script, combat, save, or whole-game parity.

XR is intentionally out of scope. Every promoted run used flat `openmw.exe`.

## Root causes fixed

- Compact NiBSpline quaternion control points were decoded as XYZW even though
  the serialized NIF field order is WXYZ.
- The spline sampler used an unclamped four-weight shortcut. Patch 0002 uses a
  cubic de Boor evaluator over the open/clamped uniform knot vector used by
  NIFTools/NifSkope, including the historic `0xffff` invalid-handle sentinel.
- Constant/default transform-interpolator channels were discarded when the
  corresponding key array or spline handle was absent. Authored XYZ Euler keys
  still take precedence over a valid constant default.
- The raw skeleton `Bip01` bind translation leaked into idle because
  `mtidle.kf` has no root controller. Retail xNVSE telemetry reports a neutral
  runtime `Bip01` in idle and locomotion; the overlay now extracts gameplay
  displacement and keeps the rendered Fallout root neutral in both states.
- Fallout 3 was excluded from several New Vegas actor assembly paths.
- The replacement `Weapon` animation target was a plain OSG transform and lost
  the retail FO3/FNV bind matrix. It is now a NIF transform with the authored
  bind, driven by the selected weapon animation family.
- FaceGen drawable replacement could release the source geometry before its
  vertex baseline was copied. The source geometry and vertices now remain
  owned through replacement, removing the ASan-confirmed use-after-free.
- Serialized ESM4 `FormId:0x...` explicit references were not preserved through
  the compiler/runtime reference path used by proof and gameplay scripts.

The spline behavior was cross-checked against the official
[NifSkope controller implementation](https://github.com/niftools/nifskope/blob/develop/src/gl/glcontroller.cpp).
Runtime root and weapon-family behavior was checked with the isolated modified
xNVSE oracle in `external/xnvse/nvse_retail_oracle/`.

## Reproduction

Apply the ordered queue to a clean OpenMW base:

```powershell
.\scripts\Apply-OpenMWPatches.ps1 -OpenMWSource D:\path\to\openmw -Check
.\scripts\Apply-OpenMWPatches.ps1 -OpenMWSource D:\path\to\openmw
```

Build and run focused unit tests from the OpenMW build directory:

```powershell
cmake --build . --config Release --target components-tests -j 8
.\Release\components-tests.exe --gtest_filter='NifOsgControllerTest.*:Esm4WeaponTest.*'
```

Expected result: seven passing tests covering compact WXYZ quaternion decode,
clamped spline endpoints/interior, constant and missing channels, authored XYZ
precedence, and FO3/FNV weapon DNAM selectors/truncation.

Run the flat native walking proofs:

```powershell
.\scripts\Invoke-RealWorldScreenshots.ps1 -WorldId fallout_new_vegas -Mode flat `
  -StartSlice goodsprings-settler-actor-front-walk `
  -UseActorAnimationPolicyEnvironment -ShowGui

.\scripts\Invoke-RealWorldScreenshots.ps1 -WorldId fallout3 -Mode flat `
  -StartSlice megaton-entrance-lucas-actor-front-walk `
  -UseActorAnimationPolicyEnvironment -ShowGui
```

Both release gates exited 0 and produced 31 native 800x600 screenshots. The
FO3 proof uses exact placed reference `FormId:0x1003b46`, delayed `AiTravel`, a
heading-follow camera, and the unobstructed first route segment. The FNV proof
uses exact placed reference `FormId:0x1104f0a` and delayed `AiTravel`.

## Promoted evidence

- FO3 manifest: `run/actor-rendering-proofs/release-final-fo3-front-20260710/fallout3-20260710-024304/manifest.json`
- FO3 full native video: `run/actor-rendering-proofs/release-final-fo3-front-20260710/fallout3-20260710-024304/fo3-lucas-front-walk-full-native.mp4`
- FO3 lighting-settled native cut: `run/actor-rendering-proofs/release-final-fo3-front-20260710/fallout3-20260710-024304/fo3-lucas-front-walk-bright-cut.mp4`
- FNV manifest: `run/actor-rendering-proofs/release-final-fnv-20260710/fallout_new_vegas-20260710-023849/manifest.json`
- FNV earlier close proof: `run/actor-rendering-proofs/fnv-front-walk-close-lifetime-fixed-video-20260710/fallout_new_vegas-20260710-011959/fnv-front-walk-close-lifetime-fixed.mp4`

The actor telemetry gates reported no suspect parts. FO3/FNV head, face, hair,
beard/headgear, hands, body, feet, and weapon remained finite and attached;
`Bip01` stayed coincident with the object root through idle/walk transitions.

Full native AddressSanitizer runs for both worlds exited 0 with no ASan report:

- `run/actor-rendering-proofs/asan-final-fnv-native-20260710/fallout_new_vegas-20260710-023445/manifest.json`
- `run/actor-rendering-proofs/asan-final-fo3-native-20260710/fallout3-20260710-023619/manifest.json`

## Remaining compatibility work

The next gates are behavioral rather than skeletal: quest-stage progression,
dialogue/topic selection, condition evaluation, package scheduling and
navigation, script opcode coverage, combat/inventory semantics, and save/load
differentials against the retail xNVSE oracle. No 100% whole-game claim is
valid until those matrices are green for FO3 and FNV.
