param(
    [string]$CatalogPath = "catalog/adventure-actor-catalog.json",
    [string[]]$WorldId = @(),
    [string[]]$CategoryId = @("usual_suspects"),
    [int]$MaxTargetsPerCategory = 1,
    [string]$ProofRoot = "proof/adventure-actor-proofs",
    [switch]$DryRun,
    [switch]$ShowGui,
    [switch]$DisableSky
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Convert-ToSlug([string]$Value) {
    $slug = ($Value -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        return "target"
    }
    return $slug.ToLowerInvariant()
}

function Format-ArgValue($Value) {
    if ($Value -is [double] -or $Value -is [float]) {
        return $Value.ToString("R", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [decimal]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

$absCatalog = (Resolve-Path -LiteralPath $CatalogPath).Path
$catalog = Get-Content -LiteralPath $absCatalog -Raw | ConvertFrom-Json
$worldFilter = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in $WorldId) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        [void]$worldFilter.Add($id)
    }
}
$categoryFilter = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in $CategoryId) {
    if (-not [string]::IsNullOrWhiteSpace($id)) {
        [void]$categoryFilter.Add($id)
    }
}

$driver = Join-Path $PSScriptRoot "Invoke-FlatWorldScreenshots.ps1"
if (-not (Test-Path -LiteralPath $driver)) {
    throw "Missing screenshot harness: $driver"
}

$targets = New-Object System.Collections.Generic.List[object]
foreach ($world in $catalog.worlds) {
    $worldId = [string]$world.worldId
    if ($worldFilter.Count -gt 0 -and -not $worldFilter.Contains($worldId)) {
        continue
    }
    if ([string]$world.status -ne "actor-placement-cataloged") {
        continue
    }
    foreach ($category in $world.representativeActorKinds) {
        $categoryId = [string]$category.id
        if ($categoryFilter.Count -gt 0 -and -not $categoryFilter.Contains($categoryId)) {
            continue
        }
        $selected = @($category.targets | Select-Object -First $MaxTargetsPerCategory)
        foreach ($target in $selected) {
            $targets.Add([pscustomobject][ordered]@{
                world = $world
                category = $category
                target = $target
            }) | Out-Null
        }
    }
}

if ($targets.Count -eq 0) {
    Write-Host "No proof targets matched."
    return
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($item in $targets) {
    $worldId = [string]$item.world.worldId
    $categoryId = [string]$item.category.id
    $target = $item.target
    $targetLabel = [string]$target.label
    $targetSlug = Convert-ToSlug "$worldId-$categoryId-$targetLabel"
    $targetProofRoot = Join-Path $ProofRoot $targetSlug

    $args = New-Object System.Collections.Generic.List[object]
    foreach ($value in @($target.proofHarnessArgs)) {
        if ($null -ne $value) {
            $args.Add((Format-ArgValue $value)) | Out-Null
        }
    }
    if ($args.Count -eq 0) {
        $args.Add("-WorldId") | Out-Null
        $args.Add($worldId) | Out-Null
    }
    $args.Add("-ProofRoot") | Out-Null
    $args.Add($targetProofRoot) | Out-Null
    if ($ShowGui) {
        $args.Add("-ShowGui") | Out-Null
    }
    if ($DisableSky) {
        $args.Add("-DisableSky") | Out-Null
    }
    if ($DryRun) {
        $args.Add("-DryRun") | Out-Null
    }

    Write-Host ""
    Write-Host "[$worldId/$categoryId] $targetLabel"
    Write-Host ("& {0} {1}" -f $driver, (($args.ToArray() | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "))

    if ($DryRun) {
        $results.Add([pscustomobject][ordered]@{
            worldId = [string]$worldId
            categoryId = [string]$categoryId
            target = [string]$targetLabel
            proofRoot = [string]$targetProofRoot
            latestRun = $null
        }) | Out-Null
        continue
    }

    $beforeRuns = @()
    if (Test-Path -LiteralPath $targetProofRoot) {
        $beforeRuns = @(Get-ChildItem -LiteralPath $targetProofRoot -Directory -ErrorAction SilentlyContinue)
    }

    & $driver @($args.ToArray())

    $afterRuns = @()
    if (Test-Path -LiteralPath $targetProofRoot) {
        $afterRuns = @(Get-ChildItem -LiteralPath $targetProofRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    }
    $latestRun = $afterRuns | Where-Object { $beforeRuns.FullName -notcontains $_.FullName } | Select-Object -First 1
    if ($null -eq $latestRun) {
        $latestRun = $afterRuns | Select-Object -First 1
    }

    $results.Add([pscustomobject][ordered]@{
        worldId = [string]$worldId
        categoryId = [string]$categoryId
        target = [string]$targetLabel
        proofRoot = [string]$targetProofRoot
        latestRun = if ($null -ne $latestRun) { $latestRun.FullName } else { $null }
    }) | Out-Null
}

Write-Host ""
$results | Format-Table -AutoSize
