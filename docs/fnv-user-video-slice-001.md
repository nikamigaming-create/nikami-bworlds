# FNV User Video Slice 001

Status: ready for user capture with the locally stamped build below

This protocol records a natural, user-controlled flat-screen observation. It is
diagnostic evidence, not retail parity credit. No console, fast travel, staged
actor, forced weather, forced image space, browser control, or desktop control
is permitted.

## Capture contract

- Record MP4/H.264 at 1920x1080 and at least 30 FPS when available.
- Capture game audio, HUD, prompts, menus, loading, failures, and process exit.
- Begin before launch; use no cuts, speed changes, or post-processing.
- Move the camera slowly and hold every inspected view for three seconds.
- On a crash or freeze, leave the state visible for ten seconds and end the file.
- Output names are `fnv-slice-001-goodsprings.mp4` and
  `fnv-slice-001-repcon-radio.mp4`.

Allow about 20-30 minutes for the Goodsprings file and 3-5 minutes for the
REPCON file. Record them as two separate, continuous files.

## Stamped local capture build

This build was compiled, deployed, and full-game launch checked on 2026-07-18. It is a
local diagnostic capture build, not a promoted release and not parity credit.

| Field | Exact value |
|---|---|
| Engine commit | `ee0f6154fa466950a07c5ce0bb0dc40a06d330bc` |
| Engine branch | `codex/fnv-parity-slices` |
| Build configuration | `RelWithDebInfo` |
| Executable | `D:\code\nikami-worlds-fnv-parity\local\openmw-fo4guard\openmw.exe` |
| Physical executable | `D:\code\nikami-worlds\local\openmw-fo4guard\openmw.exe` |
| Executable SHA-256 | `0455e3b7d845c1d8fb399218a6b6126a59471bb6415e7e1b052c5cb25275ce31` |
| Executable bytes | `77434368` |
| Executable timestamp | `2026-07-18T04:05:06.9046705-07:00` |
| Resource version SHA-256 | `0dcbb0af4c45a563b75bd52c3d31e3955f29e18ecb305b5f8dcb5b9a9a5d60f6` |
| Activation handler SHA-256 | `741544032baee66842fa9f49aa14191c5cf42dec704997fc555ef0d97cc089d1` |
| Configuration contract | `5d094682f55afa77d16d66de0f309415e3477d17deb2e3055d5180a50217fa63` |
| Official-corpus contract | `731929947dbb7c1083038e69d1bb9d796eca0e5e596b4787d2c19bc5a4695a15` |
| Denominator file SHA-256 | `983708e08fdb5193c36a669db3494682020a010cbf64760c73891c758f0d49b3` |
| Graphics preset | `fnv_max_quality` |
| NMC Small assets | `5431` files / `2071810318` bytes |
| NMC source SHA-256 | `ac5b6f25b4c9dca1c8ca74f14ef9e5065bcee559f8c092273e30721ef50f65c6` |

The bounded input contract deliberately does not hash the complete resources
tree, `FNVR.esp`, loose overlays, or shared UI data. That limitation is why this
capture is diagnostic and cannot certify parity by itself.

## Launch commands

Open PowerShell and run:

```powershell
Set-Location D:\code\nikami-worlds-fnv-parity
.\scripts\Start-FalloutWalkaround.ps1 -WorldId fallout_new_vegas
```

Complete the Goodsprings actions below, quit normally, and stop the first
recording. Then begin the second recording before running:

```powershell
Set-Location D:\code\nikami-worlds-fnv-parity
.\scripts\Start-FalloutWalkaround.ps1 -WorldId fallout_new_vegas -StartSlice repcon-platform-radio-walkaround
```

The Goodsprings command was full-game launch verified against the stamped executable; the
REPCON command was dry-run verified. They do
not use the browser, desktop automation, the console, or injected input.

## Exact Goodsprings route anchors

The maintained walkaround starts in first person at
`(-71355, 4001, 8425)`, yaw `1.5707964`, with natural authored region weather
and game hour `14.45`.

| Order | Authored target | Reference / base | Position or cell | Contract |
|---:|---|---|---|---|
| 1 | Goodsprings Settler 03 | ACHR `00104F0A` / NPC `00104F07` | `(-71492.375, 4000.531, 8352)` | Initially enabled; 156 units from spawn |
| 2 | General Store facade | STAT `00101CA6` / `00101CA3` | `(-69289.57, 3875.37)` | Exterior material, window, and LOD observation |
| 3 | Workbench | REFR `00171B9B` / ACTI `00075005` | `(-68975.63, 3887.40, 8369.44)` | Initially enabled; no enable parent |
| 4 | Reloading Bench | REFR `00171B9A` / ACTI `0015361F` | `(-68971.34, 3646.75, 8352.01)` | Initially enabled; no enable parent |
| 5 | Saloon facade and neon | STAT `001055E0` / `0010243E`; REFR `0016B5E3` / `0016B5E2` | `(-67970.18, 3904.49, 8368.05)` | Exterior glass, sign, and facade observation |
| 6 | Prospector Saloon front door | REFR `0010636F` / DOOR `0016B5E9` | `(-67714, 3620, 8393)` | Initially enabled, persistent, unlocked; XTEL target `0010618E` |
| 7 | Prospector Saloon interior | CELL `00106185` `GSProspectorSaloonInterior` | entry/return door `0010618E` | Sunny `00104E85` and Cheyenne `0010588E` initially enabled; Trudy `00104C6D` authored initially disabled |
| 8 | Easy Pete | ACHR `00104C80` / NPC `00104C7F` | `(-67844.87, 3333.97, 8391.50)` | Initially enabled; known bounded dialogue path and exact humanoid hit source |
| 9 | Goodsprings Gas Station gate | REFR `00109040` / DOOR `001227B6` | `(-75242, 4076, 8802)` | Initially enabled; raw lock 255, no key, XTEL `0010903F`; authored quest gate, not pickable |
| 10 | Young Bighorner | ACHR `00106B16` / CREA `0010AB79` | `(-71550.91, 6246.46)` | Initially enabled; supported hit-reaction rig |

## Goodsprings actions

1. Record the complete launch and spawn. Stand still for ten seconds.
2. Look up, slowly inspect four cardinal sky directions, then lower the view
   across the horizon and distant scenery.
3. Face Settler 03 and hold its prompt for two seconds. Record idle pose,
   attachment, facing, and prompt behavior; do not require a dialogue response
   from this generic actor.
4. Follow the town road east to the General Store. Stop at far, medium, and
   close distances; pan over the facade, windows, roof, terrain, and skyline.
   Back away roughly 50 metres and record any LOD pop, disappearing scenery,
   reflection bleed, opacity error, or transparent-sort error.
5. Hold each crafting-station prompt for two seconds. Activate the Workbench,
   leave the first page visible for five seconds, exercise next/previous once,
   craft only if an available recipe permits it, then cancel. Repeat for the
   Reloading Bench. Do not inject ingredients.
6. Continue east to the Saloon. Repeat far/medium/close facade and neon views.
   Hold the front-door prompt, activate once, and provide no input for five
   seconds during the transition.
7. Survey the interior slowly. Speak to Sunny for one complete response. Record
   whether Trudy is absent; do not enable or stage her. Exit through `0010618E`
   and provide no input for five seconds.
8. Immediately repeat the identical sky/horizon sweep after returning outside.
9. Approach Easy Pete, hold his prompt for two seconds, activate once, allow the
   complete greeting to finish, select one available topic, and allow its full
   voice line to finish without skipping. Move slightly sideways while he
   speaks to expose facing and mouth behavior.
10. Attempt a normal manual save. Preserve every menu and error in the capture.
11. With the weakest available firearm, fire exactly one nonfatal torso shot at
    Easy Pete from about ten metres and hold him in frame for at least eight
    seconds. Do not fire a second shot.
12. From the original spawn area, walk west to Gas Station door `00109040`.
    Hold the prompt and activate once. Record the locked/no-transition outcome.
    This is an authored raw-255 quest gate and must never be reported as a
    lockpick or keyed-door pass.
13. Find the authored bighorner herd north of the initial spawn. Fire exactly
    one nonfatal torso shot at `00106B16` and hold the target in frame for at
    least eight seconds. Do not continue combat.
14. Quit normally, relaunch, attempt to load the manual save, walk for twenty
    seconds, and activate one nearby ordinary door. Preserve any failure.

There is no naturally reachable keyed locked door on this route. The nearest
exterior keyed door is over 43,000 units away and its key is not naturally
loose-placed. This protocol therefore makes no keyed-door claim.

## REPCON radio actions

The launch wrapper will start a separate targeted exterior observation in cell
`000846B6` (`RepconPlatform`, WastelandNV grid `(-3,-8)`) near
`(-9000, -29236, 8875)`. This start anchor is diagnostic and earns no natural
journey credit. Do not walk there from Goodsprings and do not use the console.

The exact target is persistent TACT reference `000CE419`, base `000CD126`
(`RepconRadioStation`, display name `Launch Music`), at
`(-9218.635, -29236.271, 8875.565)`. It is initially enabled and has no enable
parent. Nearby landmarks are loudspeaker `000CE418`, Gas Valve `00164735`,
Navigation Console `000CE870`, and Launch Button `0008CD96`. The bounded
program resolves QUST `000CD18A`, INFO `000CD185`, and SOUN `00169BED`.

1. Record launch and natural settle at the supplied anchor.
2. Approach the marked radio, hold its prompt for two seconds, and activate once.
3. Stand still through the complete sound.
4. Reactivate while it is playing if the prompt remains available.
5. Walk away slowly to expose attenuation, return, activate once more, wait five
   seconds, and quit normally.

## Ingest rule

Every visible or audible deviation becomes a discrete observation row with
timestamp, subsystem, authored target, expected behavior, observed behavior,
severity, reproducibility, and implementation disposition. A video alone never
increments certified parity or accepted whole-corpus counters.
