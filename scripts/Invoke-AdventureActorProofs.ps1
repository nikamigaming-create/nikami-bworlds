param(
    [string]$CatalogPath = "catalog/adventure-actor-catalog.json",
    [string]$CuratedTargetsPath = "catalog/adventure-actor-curated-targets.json",
    [string[]]$WorldId = @(),
    [string[]]$CategoryId = @("usual_suspects"),
    [int]$MaxTargetsPerCategory = 1,
    [string]$ProofRoot = "proof/adventure-actor-proofs",
    [switch]$DryRun,
    [switch]$ShowGui,
    [switch]$DisableSky,
    [string[]]$SetEnv = @(),
    [switch]$AllowBadScreenshots
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

function Get-EnvAssignmentName([string]$Assignment) {
    if ([string]::IsNullOrWhiteSpace($Assignment)) {
        return $null
    }

    $separator = $Assignment.IndexOf("=")
    if ($separator -lt 1) {
        throw "-SetEnv expects NAME=VALUE, got: $Assignment"
    }

    $name = $Assignment.Substring(0, $separator).Trim()
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "-SetEnv has an invalid environment variable name: $name"
    }

    return $name
}

function Add-HarnessSetEnv([System.Collections.Generic.List[object]]$HarnessArgs, [string]$Assignment) {
    $name = Get-EnvAssignmentName -Assignment $Assignment
    if ($null -eq $name) {
        return
    }

    $HarnessArgs.Add("-SetEnv") | Out-Null
    $HarnessArgs.Add($Assignment) | Out-Null
}

function Get-HarnessArgumentValue([System.Collections.Generic.List[object]]$HarnessArgs, [string]$Name) {
    $parameterName = "-$Name"
    $value = $null
    for ($i = 0; $i -lt $HarnessArgs.Count; $i++) {
        if ([string]$HarnessArgs[$i] -ne $parameterName) {
            continue
        }
        if ($i + 1 -ge $HarnessArgs.Count) {
            throw "Harness parameter $parameterName is missing a value."
        }
        $value = [string]$HarnessArgs[$i + 1]
        $i++
    }
    return $value
}

function Set-HarnessArgumentValue([System.Collections.Generic.List[object]]$HarnessArgs, [string]$Name, [string]$Value) {
    $parameterName = "-$Name"
    for ($i = 0; $i -lt $HarnessArgs.Count; $i++) {
        if ([string]$HarnessArgs[$i] -ne $parameterName) {
            continue
        }
        if ($i + 1 -ge $HarnessArgs.Count) {
            throw "Harness parameter $parameterName is missing a value."
        }
        $HarnessArgs[$i + 1] = $Value
        return
    }

    $HarnessArgs.Add($parameterName) | Out-Null
    $HarnessArgs.Add($Value) | Out-Null
}

function Ensure-HarnessIntMinimum([System.Collections.Generic.List[object]]$HarnessArgs, [string]$Name, [int]$Minimum) {
    $currentValue = Get-HarnessArgumentValue -HarnessArgs $HarnessArgs -Name $Name
    $currentNumber = 0
    if ([string]::IsNullOrWhiteSpace($currentValue) -or -not [int]::TryParse($currentValue, [ref]$currentNumber) -or $currentNumber -lt $Minimum) {
        Set-HarnessArgumentValue -HarnessArgs $HarnessArgs -Name $Name -Value ([string]$Minimum)
    }
}

function Get-ExistingHarnessSetEnvNames([System.Collections.Generic.List[object]]$HarnessArgs) {
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $HarnessArgs.Count; $i++) {
        if ([string]$HarnessArgs[$i] -ne "-SetEnv") {
            continue
        }
        if ($i + 1 -ge $HarnessArgs.Count) {
            throw "Harness parameter -SetEnv is missing a value."
        }
        $name = Get-EnvAssignmentName -Assignment ([string]$HarnessArgs[$i + 1])
        if ($null -ne $name) {
            [void]$names.Add($name)
        }
        $i++
    }
    return ,$names
}

function ConvertTo-HarnessParameterMap($ArgList) {
    $switchNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(
        "NoTelemetry",
        "DisableActors",
        "DisableSky",
        "AllowOsgUpdateTraversal",
        "StripOsgUpdateCallbacks",
        "StripOsgNodeUpdateCallbacks",
        "StripOsgStateSetUpdateCallbacks",
        "AllowBadScreenshots",
        "ShowGui",
        "DryRun",
        "KeepRunning",
        "PreserveNativeMaterials",
        "FullbrightActorMaterialsOnly",
        "FullbrightNativeMaterials",
        "RenderDisabledActors"
    )) {
        [void]$switchNames.Add($name)
    }

    $arrayNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @("WorldId", "StripOsgUpdateCallbackClass", "KeepOsgUpdateCallbackPath", "SetEnv")) {
        [void]$arrayNames.Add($name)
    }

    $map = @{}
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $token = [string]$ArgList[$i]
        if (-not $token.StartsWith("-")) {
            throw "Unexpected harness argument value without parameter name: $token"
        }
        $name = $token.TrimStart("-")
        if ($switchNames.Contains($name)) {
            $map[$name] = $true
            continue
        }
        if ($i + 1 -ge $ArgList.Count) {
            throw "Harness parameter -$name is missing a value."
        }
        $value = [string]$ArgList[$i + 1]
        $i++
        if ($arrayNames.Contains($name)) {
            if ($map.ContainsKey($name)) {
                $existing = @($map[$name])
                $map[$name] = @($existing + $value)
            }
            else {
                $map[$name] = @($value)
            }
        }
        else {
            $map[$name] = $value
        }
    }
    return $map
}

function Test-CuratedTargetMatch($Target, [string]$WorldId, [string]$CategoryId) {
    $targetWorldId = [string](Get-PropertyValue $Target "worldId")
    if ([string]::IsNullOrWhiteSpace($targetWorldId) -or $targetWorldId -ne $WorldId) {
        return $false
    }

    $categoryIds = @()
    $categoryIdsValue = Get-PropertyValue $Target "categoryIds"
    if ($null -ne $categoryIdsValue) {
        $categoryIds = @($categoryIdsValue)
    }
    else {
        $categoryIdValue = Get-PropertyValue $Target "categoryId"
        if ($null -ne $categoryIdValue) {
            $categoryIds = @($categoryIdValue)
        }
    }

    if ($categoryIds.Count -eq 0) {
        return $true
    }

    foreach ($id in $categoryIds) {
        if ([string]$id -eq $CategoryId) {
            return $true
        }
    }

    return $false
}

$absCatalog = (Resolve-Path -LiteralPath $CatalogPath).Path
$catalog = Get-Content -LiteralPath $absCatalog -Raw | ConvertFrom-Json
$curatedTargets = @()
if (-not [string]::IsNullOrWhiteSpace($CuratedTargetsPath) -and (Test-Path -LiteralPath $CuratedTargetsPath)) {
    $absCuratedTargets = (Resolve-Path -LiteralPath $CuratedTargetsPath).Path
    $curatedCatalog = Get-Content -LiteralPath $absCuratedTargets -Raw | ConvertFrom-Json
    $loadedCuratedTargets = Get-PropertyValue $curatedCatalog "targets"
    if ($null -ne $loadedCuratedTargets) {
        $curatedTargets = @($loadedCuratedTargets)
    }
}
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

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$fo4GuardBinaryRoot = Join-Path $repoRoot "local\openmw-fo4guard"
$starfieldProofEnv = @(
    "OPENMW_WORLD_VIEWER_INSERT_ALL_ESM4_ARMOR_ADDONS=1",
    "OPENMW_WORLD_VIEWER_DISABLE_TES5_STATIC_FACE_SURFACE_ANCHOR=1",
    "OPENMW_WORLD_VIEWER_FORCE_FLAT_WORLD_MATERIALS=1",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_PARTS=70",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HEAD_PARTS=70",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HAIR_PARTS=70",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_FACE_HAIR_PARTS=70",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_BROW_PARTS=70",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_EYE_PARTS=70",
    "OPENMW_WORLD_VIEWER_SCALE_STATIC_ACTOR_HAND_PARTS=70"
)

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
        $selected = New-Object System.Collections.Generic.List[object]
        $selectedLabels = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($curatedTarget in @($curatedTargets)) {
            if ($selected.Count -ge $MaxTargetsPerCategory) {
                break
            }
            if (-not (Test-CuratedTargetMatch -Target $curatedTarget -WorldId $worldId -CategoryId $categoryId)) {
                continue
            }
            $label = [string](Get-PropertyValue $curatedTarget "label")
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = [string](Get-PropertyValue $curatedTarget "baseEditorId")
            }
            if (-not [string]::IsNullOrWhiteSpace($label) -and -not $selectedLabels.Add($label)) {
                continue
            }
            $selected.Add($curatedTarget) | Out-Null
        }
        foreach ($catalogTarget in @($category.targets)) {
            if ($selected.Count -ge $MaxTargetsPerCategory) {
                break
            }
            $label = [string](Get-PropertyValue $catalogTarget "label")
            if (-not [string]::IsNullOrWhiteSpace($label) -and -not $selectedLabels.Add($label)) {
                continue
            }
            $selected.Add($catalogTarget) | Out-Null
        }
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

    $harnessArgs = New-Object System.Collections.Generic.List[object]
    foreach ($value in @($target.proofHarnessArgs)) {
        if ($null -ne $value) {
            $harnessArgs.Add((Format-ArgValue $value)) | Out-Null
        }
    }
    if ($harnessArgs.Count -eq 0) {
        $harnessArgs.Add("-WorldId") | Out-Null
        $harnessArgs.Add($worldId) | Out-Null
    }
    $harnessArgs.Add("-ProofRoot") | Out-Null
    $harnessArgs.Add($targetProofRoot) | Out-Null
    $existingSetEnvNames = Get-ExistingHarnessSetEnvNames -HarnessArgs $harnessArgs
    if ($worldId -eq "fallout4" -or $worldId -eq "fallout4_vr") {
        if (Test-Path -LiteralPath (Join-Path $fo4GuardBinaryRoot "openmw.exe")) {
            Set-HarnessArgumentValue -HarnessArgs $harnessArgs -Name "BinaryRoot" -Value $fo4GuardBinaryRoot
        }
        Ensure-HarnessIntMinimum -HarnessArgs $harnessArgs -Name "RunSeconds" -Minimum 45
        Set-HarnessArgumentValue -HarnessArgs $harnessArgs -Name "ScreenshotFrames" -Value "240,420,600"
    }
    if ($worldId -eq "starfield") {
        Ensure-HarnessIntMinimum -HarnessArgs $harnessArgs -Name "RunSeconds" -Minimum 45
        if ([string]::IsNullOrWhiteSpace((Get-HarnessArgumentValue -HarnessArgs $harnessArgs -Name "ScreenshotFrames"))) {
            Set-HarnessArgumentValue -HarnessArgs $harnessArgs -Name "ScreenshotFrames" -Value "240,420,600"
        }
        foreach ($assignment in $starfieldProofEnv) {
            $name = Get-EnvAssignmentName -Assignment $assignment
            if (-not $existingSetEnvNames.Contains($name)) {
                Add-HarnessSetEnv -HarnessArgs $harnessArgs -Assignment $assignment
                [void]$existingSetEnvNames.Add($name)
            }
        }
    }
    foreach ($assignment in @($SetEnv)) {
        Add-HarnessSetEnv -HarnessArgs $harnessArgs -Assignment $assignment
    }
    if ($ShowGui) {
        $harnessArgs.Add("-ShowGui") | Out-Null
    }
    if ($DisableSky) {
        $harnessArgs.Add("-DisableSky") | Out-Null
    }
    if ($AllowBadScreenshots) {
        $harnessArgs.Add("-AllowBadScreenshots") | Out-Null
    }
    if ($DryRun) {
        $harnessArgs.Add("-DryRun") | Out-Null
    }

    Write-Host ""
    Write-Host "[$worldId/$categoryId] $targetLabel"
    Write-Host ("& {0} {1}" -f $driver, (($harnessArgs.ToArray() | ForEach-Object {
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
    $beforeRunPaths = @($beforeRuns | ForEach-Object { $_.FullName })

    $harnessParams = ConvertTo-HarnessParameterMap -ArgList $harnessArgs
    & $driver @harnessParams

    $afterRuns = @()
    if (Test-Path -LiteralPath $targetProofRoot) {
        $afterRuns = @(Get-ChildItem -LiteralPath $targetProofRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    }
    $latestRun = $afterRuns | Where-Object { $beforeRunPaths -notcontains $_.FullName } | Select-Object -First 1
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
