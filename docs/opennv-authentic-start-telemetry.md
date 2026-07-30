# OpenNV authentic-start telemetry

Use this developer test to find what is missing from a real first-character
start in standalone Fallout 3 or New Vegas. It is deliberately not a
screenshot test and does not inject a player level, opening quest, start cell,
or scripted bootstrap.

```powershell
.\scripts\Invoke-OpenNVStartupTelemetry.ps1 -Campaign Fallout3
.\scripts\Invoke-OpenNVStartupTelemetry.ps1 -Campaign NewVegas
```

The command generates an isolated profile under `profiles/_verification/` and
writes a plan plus engine telemetry under `run/opennv-startup-telemetry/`.
It starts the normal `--skip-menu --new-game` path without `--start`, waits for
the opt-in engine telemetry record, then closes only that isolated test
process.

The record checks whether the engine reached level one in an authored cell,
whether chargen is active, whether the engine fell back to a generic placement,
and which new-game cinematic asset it requested. Once exact opening-quest editor IDs are verified
from the installed masters, pass them explicitly to make them part of the
same evidence record:

```powershell
.\scripts\Invoke-OpenNVStartupTelemetry.ps1 `
  -Campaign NewVegas `
  -RequiredQuest 'VerifiedQuestEditorId'
```

`result: "gap"` is useful evidence, not a silent failure: the `gaps` array
names the unimplemented or misrouted behavior to fix. Only a record with
`result: "pass"` is suitable for promoting that scenario as compatible.
