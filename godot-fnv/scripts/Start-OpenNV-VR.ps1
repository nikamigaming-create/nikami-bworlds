[CmdletBinding()]
param(
    [string]$Godot = 'D:\code\gd\Godot_v4.6.3-stable_win64_console.exe',
    [string]$OculusRuntime = 'C:\Program Files\Oculus\Support\oculus-runtime\oculus_openxr_64.json',
    [switch]$ShowMenu
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifest = Join-Path $projectRoot 'generated\bootstrap.json'
foreach ($required in @($Godot, $OculusRuntime, $manifest)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "OpenNV VR requirement missing: $required" }
}

$priorRuntime = $env:XR_RUNTIME_JSON
$priorOpenXR = $env:FNV_GODOT_OPENXR
$priorSkipIntro = $env:FNV_GODOT_SKIP_INTRO
$priorContinue = $env:FNV_GODOT_AUTOCONTINUE
try {
    $env:XR_RUNTIME_JSON = $OculusRuntime
    $env:FNV_GODOT_OPENXR = '1'
    $env:FNV_GODOT_SKIP_INTRO = '1'
    if (-not $ShowMenu) { $env:FNV_GODOT_AUTOCONTINUE = '1' }
    & $Godot --xr-mode on --path $projectRoot --editor-pid 0
}
finally {
    foreach ($row in @(
        @{ Name = 'XR_RUNTIME_JSON'; Value = $priorRuntime },
        @{ Name = 'FNV_GODOT_OPENXR'; Value = $priorOpenXR },
        @{ Name = 'FNV_GODOT_SKIP_INTRO'; Value = $priorSkipIntro },
        @{ Name = 'FNV_GODOT_AUTOCONTINUE'; Value = $priorContinue }
    )) {
        if ($null -eq $row.Value) {
            Remove-Item ("Env:" + $row.Name) -ErrorAction SilentlyContinue
        } else {
            Set-Item ("Env:" + $row.Name) ([string]$row.Value)
        }
    }
}
