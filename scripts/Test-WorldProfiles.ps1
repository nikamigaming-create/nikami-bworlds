param(
    [string]$CatalogPath = "catalog/worlds.local.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $CatalogPath)) {
    throw "Missing catalog: $CatalogPath"
}

$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$failures = New-Object System.Collections.Generic.List[string]
$rows = @()

foreach ($world in $catalog.worlds) {
    if ($world.profileStatus -ne "generated") {
        continue
    }

    $profilePath = $world.generatedProfileConfig
    $settingsPath = $world.generatedSettingsConfig
    $profileText = if (Test-Path -LiteralPath $profilePath) { Get-Content -LiteralPath $profilePath -Raw } else { "" }
    $settingsText = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { "" }

    if (-not (Test-Path -LiteralPath $profilePath)) {
        $failures.Add("$($world.id): missing generated profile $profilePath")
    }
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        $failures.Add("$($world.id): missing generated settings $settingsPath")
    }

    foreach ($required in @("replace=data", "replace=data-local", "replace=fallback-archive", "replace=content", "user-data=", "data-local=")) {
        if ($profileText -notmatch [regex]::Escape($required)) {
            $failures.Add("$($world.id): openmw.cfg missing $required")
        }
    }

    if ($world.id -ne "morrowind" -and $profileText -match "Morrowind\.(esm|bsa)") {
        $failures.Add("$($world.id): non-Morrowind profile references Morrowind content/archive")
    }

    foreach ($requiredSection in @("[Camera]", "[Cells]", "[Terrain]", "[Models]", "[Navigator]")) {
        if ($settingsText -notmatch [regex]::Escape($requiredSection)) {
            $failures.Add("$($world.id): settings.cfg missing $requiredSection")
        }
    }

    if ($settingsText -notmatch "write to navmeshdb\s*=\s*false") {
        $failures.Add("$($world.id): settings.cfg should disable navmeshdb writes for viewer profiles")
    }

    $rows += [pscustomobject][ordered]@{
        id = $world.id
        preset = $world.settingsPreset
        profile = $profilePath
        settings = $settingsPath
        userData = $world.userDataDirectory
    }
}

$rows | Format-Table -AutoSize

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Profile validation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "World profile validation passed."
