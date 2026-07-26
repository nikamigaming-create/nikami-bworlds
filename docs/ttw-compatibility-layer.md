# TTW through the FNV compatibility layer

`Initialize-TTWCompatibilityProfile.ps1` makes an isolated OpenMW profile for
Tale of Two Wastelands. It never changes the contents or directory entries of
the Fallout 3, Fallout: New Vegas, or TTW trees. Saves and generated files stay under
`profiles/_campaigns/tale_of_two_wastelands/userdata`; the plain TTW and
TTW+JAM profiles deliberately share that campaign save store so JAM can be
added later.

The only compatibility shim is an `archive-aliases` directory inside that
profile. It provides the Fallout 3 base archives under unique `Fallout3 - …`
names, using hard links when the profile and Fallout 3 are on the same volume.
That lets the FNV base archives and the Fallout 3 base archives coexist without
copying gigabytes or renaming the licensed source files.

Example:

```powershell
.\scripts\Initialize-TTWCompatibilityProfile.ps1 `
  -TtwRoot 'D:\path\to\MO2\mods\Tale of Two Wastelands'

.\scripts\Start-TTWCompatibilityExisting.ps1 `
  -TtwRoot 'D:\path\to\MO2\mods\Tale of Two Wastelands' `
  -SkipMenu -NewGame -StartCell MegatonEntrance
```

The initializer preflights the TTW output first. Current TTW setup guidance
expects an installed mod of about 17 GB. A small tree containing only masters,
`.override` markers, and YUPTTW is not a full official installer output: the
markers are not usable archives for OpenMW. The compatibility runtime does,
however, support a narrowly defined source-archive mode when the complete TTW
master stack plus `YUPTTW - Main.bsa` and `YUPTTW - Sounds.bsa` are present. It
mounts the untouched licensed Fallout 3 and New Vegas archives alongside those
TTW files and keeps the parser changes in
`local/openmw-ttw-compat`.

That mode is explicitly labeled `source-archive compatibility` by the launcher;
it is not represented as a completed official TTW install. A fully installed
TTW tree remains the preferred asset-complete option. Other partial layouts are
diagnostic only (`-AllowPartialInstall -DryRun`) and cannot be launched.

JAM is optional, not baked into the vanilla TTW profile. Use
`Start-TTWCompatibilityExisting.ps1 -IncludeJam` (or the `TTW-JAM` OpenNV
style) to generate a separate TTW+JAM configuration that shares the TTW
campaign saves. Once a save is made with JAM, continue it with JAM enabled. See
[`open-nv-styles.md`](open-nv-styles.md) for the full selector.
