# OpenNV mod-manager contract

The mod manager is a profile-layer manager, not a game-folder installer.

```text
official Fallout 3 / Fallout: New Vegas / TTW output  (read only)
                  +
registered untouched mod folders                         (read only)
                  ->
generated OpenNV campaign profile                        (manager-owned)
                  ->
OpenNV compatibility runtime
```

`catalog/open-nv-modules.json` is the source of truth. A module has an explicit
campaign scope, source-path key, runtime support state, and dependencies. The
manager refuses to enable a module that is missing, only partly installed, or
not yet compatible with the OpenNV runtime.

The manager is deliberately headless and emits a machine-readable plan with
`Manage-OpenNVMods.ps1 -Action Plan -Campaign TTW -Layer quality-of-life -AsJson`.
That is the stable contract for a future graphical chooser.

`Get-OpenNVLauncherState.ps1 -AsJson` is the corresponding read-only launcher
view model. It reports the three character-creation campaigns, each launch
variant's readiness, DLC availability, the TTW install state, and every
selectable or gated module/layer. A graphical client can consume that payload
without guessing from console text or changing a game directory.

Current layers:

| Layer | Purpose | OpenNV state |
| --- | --- | --- |
| `quality-of-life` | JAM | Selectable and launch-validated |
| `ttw-common` | Common Wasteland Survival Guide gameplay choices | Tracked but gated by compatibility adapters |

The gate is intentional. The mainstream TTW recommendations include native
xNVSE/JIP/Johnny/ShowOff extensions. An `.esp` appearing to load is not proof
that its native scripts run. A module becomes selectable only after its runtime
bridge is implemented and a real TTW launch passes.

The minimum compatibility target is **(Benny Humbles You) and Steals Your
Stuff**. Its behavior is the DC-to-Mojave transition: gear management,
optional level/skill changes, and the related configuration. It must be added
before that transition, and it must not be removed mid-save. Its source page
lists JIP LN NVSE, JohnnyGuitar NVSE, and ShowOff xNVSE as requirements.

For the current maintained recommendations, use the [Wasteland Survival Guide gameplay page](https://wastelandsurvival.guide/docs/gameplay) as the review source. It explicitly recommends BHYSYS and JAM, while its final notes warn that additional mods require deliberate conflict resolution. The [Benny Humbles You page](https://www.nexusmods.com/newvegas/mods/71112) is the source for its current requirements and installation timing.
