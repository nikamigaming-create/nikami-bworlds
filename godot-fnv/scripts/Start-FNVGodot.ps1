[CmdletBinding()]
param(
    [string]$Godot = 'D:\code\gd\Godot_v4.6.3-stable_win64_console.exe',
    [switch]$PlayIntro,
    [switch]$ShowMenu,
    [switch]$ForceSyncLoad
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifest = Join-Path $projectRoot 'generated\bootstrap.json'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw 'FNV Godot bootstrap is missing. Run scripts\Build-FNVGodotBootstrap.ps1 first.'
}
$priorSkipIntro = $env:FNV_GODOT_SKIP_INTRO
$priorAutoContinue = $env:FNV_GODOT_AUTOCONTINUE
$priorForceSyncLoad = $env:FNV_GODOT_FORCE_SYNC_LOAD
if (-not $PlayIntro) { $env:FNV_GODOT_SKIP_INTRO = '1' }
if (-not $ShowMenu) { $env:FNV_GODOT_AUTOCONTINUE = '1' }
# Desktop Vulkan uses the streamer's bounded ResourceLoader worker queue and
# commits completed resources on the main thread. OpenXR already selects the
# synchronous path inside the runtime; retain this switch only for diagnosis.
if ($ForceSyncLoad) { $env:FNV_GODOT_FORCE_SYNC_LOAD = '1' }
try {
    & $Godot --path $projectRoot --editor-pid 0
}
finally {
    if ($null -eq $priorSkipIntro) { Remove-Item Env:FNV_GODOT_SKIP_INTRO -ErrorAction SilentlyContinue } else { $env:FNV_GODOT_SKIP_INTRO = $priorSkipIntro }
    if ($null -eq $priorAutoContinue) { Remove-Item Env:FNV_GODOT_AUTOCONTINUE -ErrorAction SilentlyContinue } else { $env:FNV_GODOT_AUTOCONTINUE = $priorAutoContinue }
    if ($null -eq $priorForceSyncLoad) { Remove-Item Env:FNV_GODOT_FORCE_SYNC_LOAD -ErrorAction SilentlyContinue } else { $env:FNV_GODOT_FORCE_SYNC_LOAD = $priorForceSyncLoad }
}
