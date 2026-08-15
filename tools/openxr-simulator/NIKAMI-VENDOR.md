# OpenXR Simulator vendor record

This is a source snapshot, not a nested Git checkout or a third canonical
repository.  Nikami Worlds and nikami-openmw-lab remain the only source
repositories, each on `main`.

- Upstream: `https://github.com/elliotttate/OpenXR-Simulator`
- Imported release: `v1.5.0`
- Upstream tag commit: `8de34575bfb823254297663aaf4997bc27da0ef8`
- Archive SHA-256: `2CB552C32B360FB40CD790BC911AEF2013D5087650F5753641D105C59AFD6168`
- License: MIT; the upstream `LICENSE` is retained verbatim.
- Import date: 2026-08-15

Nikami-specific portability change: `OPENXR_SIMULATOR_DATA_DIR` overrides the
upstream `%LOCALAPPDATA%\\OpenXR-Simulator` data location.  When omitted, the
upstream default remains unchanged.  This keeps unattended per-run status,
commands, and native screenshots out of a machine-specific path.

Build products are deliberately ignored.  Use
`scripts/Build-OpenXRSimulator.ps1`; it writes a runtime deployment only under
`local/openxr-simulator` and never changes Windows' active OpenXR runtime.
