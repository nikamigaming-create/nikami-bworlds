param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$settingsPath = Join-Path $repoRoot "config\fnv-playable-graphics\settings.cfg"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}

Assert-Contract (Test-Path -LiteralPath $settingsPath -PathType Leaf) `
    "FNV playable graphics settings are missing."
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw
    foreach ($required in @(
        'viewing distance = 32768',
        'distant terrain = true',
        'object paging = true',
        'object paging active grid = false',
        'object paging min size = 0.01'
    )) {
        Assert-Contract ($settings.Contains($required)) "FNV playable graphics setting is missing: $required"
    }
    Assert-Contract (-not $settings.Contains('[Fog]')) `
        "FNV playable graphics layer must not opt into Morrowind-derived distant fog."
}

$catalog = Get-Content -LiteralPath (Join-Path $repoRoot "catalog\world-settings-presets.json") -Raw |
    ConvertFrom-Json
$fnv = $catalog.worlds.fallout_new_vegas.sections
Assert-Contract ([bool]$fnv.Terrain.'distant terrain') `
    "Generated FNV profile does not enable distant terrain."
Assert-Contract ([bool]$fnv.Terrain.'object paging') `
    "Generated FNV profile does not enable object paging."
Assert-Contract (-not [bool]$fnv.Terrain.'object paging active grid') `
    "Generated FNV profile enables unsafe active-grid paging."
Assert-Contract ([double]$fnv.Terrain.'object paging min size' -eq 0.01) `
    "Generated FNV profile does not use the safe object paging minimum size."

$baseline = Get-Content -LiteralPath (Join-Path $repoRoot "config\playable-baseline\settings.cfg") -Raw
foreach ($bounded in @(
    'viewing distance = 16384',
    'distant terrain = false',
    'object paging = false',
    'object paging active grid = false',
    'object paging min size = 0.1'
)) {
    Assert-Contract ($baseline.Contains($bounded)) "Shared bounded baseline changed unexpectedly: $bounded"
}

$launchers = @(
    "Invoke-PlayableSessionBaseline.ps1",
    "Invoke-FNVInteractionAudit.ps1",
    "Start-FalloutVRWalkaround.ps1"
)
foreach ($launcher in $launchers) {
    $path = Join-Path $PSScriptRoot $launcher
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Contract ($parseErrors.Count -eq 0) "$launcher does not parse."
    $source = Get-Content -LiteralPath $path -Raw
    Assert-Contract ($source.Contains('config/fnv-playable-graphics')) `
        "$launcher does not reference the FNV playable graphics layer."
}

if ($failures.Count -gt 0) {
    Write-Host "FNV playable graphics contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host "FNV playable graphics contract passed."
