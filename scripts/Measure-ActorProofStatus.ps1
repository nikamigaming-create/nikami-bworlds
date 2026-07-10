param(
    [string[]]$ActorRuntimePath = @(
        "run/audit/morrowind-seyda-neen-orbit-burst-actor-runtime-warnings.jsonl",
        "run/audit/oblivion-palace-front-source-skin-actor-runtime-warnings.jsonl",
        "run/audit/fallout3-megaton-lucas-face-regression-pin0-actor-runtime-warnings.jsonl",
        "run/audit/fnv-goodsprings-settler-close-actor-runtime-warnings.jsonl",
        "run/audit/fallout4-sanctuary-codsworth-close-actor-runtime-warnings.jsonl"
    ),
    [string]$ActorVisualReviewPath = "run/audit/actor-visual-review.jsonl",
    [string[]]$RigPoseSanityPath = @("run/audit/rig-pose-sanity.jsonl"),
    [string[]]$ActorPartTelemetryPath = @(),
    [string[]]$ActorRenderLivePath = @(),
    [string[]]$ActorFaceAttachmentPath = @(),
    [string[]]$ActorBasisTelemetryPath = @(),
    [string[]]$ActorRootAttachmentTelemetryPath = @(),
    [string[]]$ActorWeaponMeshTelemetryPath = @(),
    [string[]]$ActorFabrikTelemetryPath = @(),
    [string[]]$ActorLimbAnatomyPath = @(),
    [string]$OutputPath = "run/audit/latest-nonvr-actor-proof-status.jsonl",
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Convert-ToForwardSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    return ($Path -replace "\\", "/")
}

function Normalize-EvidencePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    return (Convert-ToForwardSlash $Path)
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-TextArray($Value) {
    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text)
}

function Add-UniqueText([System.Collections.Generic.List[string]]$List, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if (-not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function Set-OrderedSkinningMode($Modes, [string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Name) -or -not $Name.EndsWith("SKINNING_MODE", [StringComparison]::Ordinal)) {
        return
    }
    if ($Modes.Contains($Name)) {
        $Modes[$Name] = $Value
    }
    else {
        $Modes.Add($Name, $Value)
    }
}

function Add-OrderedSkinningModeFromText($Modes, [string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -notmatch "^(?<name>[^=]+)=(?<value>.*)$") {
        return
    }
    Set-OrderedSkinningMode -Modes $Modes -Name ([string]$matches["name"]) -Value ([string]$matches["value"])
}

function Select-EffectiveSkinningMode($Modes, [string]$WorldId) {
    if ($null -eq $Modes -or $Modes.Count -eq 0) {
        return $null
    }

    $priority = New-Object System.Collections.Generic.List[string]
    if ([string]::Equals($WorldId, "fallout_new_vegas", [StringComparison]::OrdinalIgnoreCase)) {
        $priority.Add("OPENMW_FNV_SKINNING_MODE") | Out-Null
    }
    $priority.Add("OPENMW_ESM4_SKINNING_MODE") | Out-Null

    foreach ($name in @($priority.ToArray())) {
        if ($Modes.Contains($name) -and -not [string]::IsNullOrWhiteSpace([string]$Modes[$name])) {
            return [string]$Modes[$name]
        }
    }
    foreach ($name in @($Modes.Keys)) {
        if ($name -match "HAND_SKINNING_MODE$") {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Modes[$name])) {
            return [string]$Modes[$name]
        }
    }
    return $null
}

function Read-JsonlRows([string]$Path) {
    $resolved = Resolve-RepoRelativePath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "JSONL path not found: $Path"
    }

    $rows = New-Object System.Collections.Generic.List[object]
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $resolved) {
        ++$lineNumber
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $row = $line | ConvertFrom-Json
        }
        catch {
            throw "Invalid JSON in '${Path}' line ${lineNumber}: $($_.Exception.Message)"
        }
        $rows.Add($row) | Out-Null
    }
    return @($rows.ToArray())
}

function Get-StatusFromRows([object[]]$Rows) {
    if (@($Rows).Count -eq 0) {
        return "missing"
    }
    if (@($Rows | Where-Object { [string](Get-PropertyValue $_ "status") -eq "fail" }).Count -gt 0) {
        return "fail"
    }
    if (@($Rows | Where-Object { [string](Get-PropertyValue $_ "status") -eq "questionable" }).Count -gt 0) {
        return "questionable"
    }
    return "pass"
}

function Get-FabrikEffectiveStatus($Row) {
    $status = [string](Get-PropertyValue $Row "status")
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        return $status
    }

    $verdict = [string](Get-PropertyValue $Row "verdict")
    if ([string]::Equals($verdict, "exploded", [StringComparison]::OrdinalIgnoreCase)) {
        return "fail"
    }
    if ([string]::Equals($verdict, "suspect", [StringComparison]::OrdinalIgnoreCase)) {
        return "questionable"
    }
    if (-not [string]::IsNullOrWhiteSpace($verdict)) {
        return "pass"
    }
    return "missing"
}

function Get-FabrikStatusFromRows([object[]]$Rows) {
    if (@($Rows).Count -eq 0) {
        return "missing"
    }
    if (@($Rows | Where-Object { (Get-FabrikEffectiveStatus $_) -eq "fail" }).Count -gt 0) {
        return "fail"
    }
    if (@($Rows | Where-Object { (Get-FabrikEffectiveStatus $_) -eq "questionable" }).Count -gt 0) {
        return "questionable"
    }
    return "pass"
}

function New-StatusCountsObject([object[]]$Rows) {
    $counts = [ordered]@{}
    foreach ($group in @($Rows | Group-Object status | Sort-Object Name)) {
        $name = [string]$group.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "missing"
        }
        $counts[$name] = [int]$group.Count
    }
    return [pscustomobject]$counts
}

function New-FabrikStatusCountsObject([object[]]$Rows) {
    $counts = [ordered]@{}
    foreach ($row in @($Rows)) {
        $name = Get-FabrikEffectiveStatus $row
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "missing"
        }
        if (-not $counts.Contains($name)) {
            $counts[$name] = 0
        }
        $counts[$name] = [int]$counts[$name] + 1
    }
    return [pscustomobject]$counts
}

function Normalize-ActorIdentity([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $text = $Value.Trim()
    while ($text.Length -ge 2 -and $text.StartsWith('"', [StringComparison]::Ordinal) -and $text.EndsWith('"', [StringComparison]::Ordinal)) {
        $text = $text.Substring(1, $text.Length - 2).Trim()
    }
    return $text
}

function Test-IsPlayerIdentity([string]$Value) {
    return [string]::Equals((Normalize-ActorIdentity $Value), "Player", [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsPlayerRuntimeRow($Row) {
    foreach ($propertyName in @("actorName", "formId", "baseRef", "modelRecord", "traits")) {
        if (Test-IsPlayerIdentity ([string](Get-PropertyValue $Row $propertyName))) {
            return $true
        }
    }
    return $false
}

function Select-ProofTargetRuntimeRows([object[]]$Rows) {
    $nonPlayerRows = @($Rows | Where-Object { -not (Test-IsPlayerRuntimeRow $_) })
    $namedLiveActors = @($nonPlayerRows | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ "actorName")) -and
        [bool](Get-PropertyValue $_ "registeredCharacterController") -and
        [bool](Get-PropertyValue $_ "objectRoot") -and
        [bool](Get-PropertyValue $_ "skeletonNode")
    })
    if ($namedLiveActors.Count -gt 0) {
        return @($namedLiveActors)
    }

    $registeredRows = @($nonPlayerRows | Where-Object { [bool](Get-PropertyValue $_ "registeredCharacterController") })
    if ($registeredRows.Count -gt 0) {
        return @($registeredRows)
    }

    if ($nonPlayerRows.Count -gt 0) {
        return @($nonPlayerRows)
    }

    return @($Rows)
}

function Select-ProofTargetLimbRows([object[]]$Rows) {
    $nonPlayerRows = @($Rows | Where-Object { -not (Test-IsPlayerIdentity ([string](Get-PropertyValue $_ "actor"))) })
    if ($nonPlayerRows.Count -gt 0) {
        return @($nonPlayerRows)
    }

    return @($Rows)
}

function Select-ProofTargetFabrikRows([object[]]$Rows) {
    $nonPlayerRows = @($Rows | Where-Object { -not (Test-IsPlayerIdentity ([string](Get-PropertyValue $_ "actor"))) })
    if ($nonPlayerRows.Count -gt 0) {
        return @($nonPlayerRows)
    }

    return @($Rows)
}

function Select-LatestVisualReview([object[]]$Rows) {
    if (@($Rows).Count -eq 0) {
        return $null
    }

    return @($Rows | Sort-Object {
        $assessedAt = [string](Get-PropertyValue $_ "assessedAt")
        if ([string]::IsNullOrWhiteSpace($assessedAt)) {
            return [DateTimeOffset]::MinValue
        }
        return [DateTimeOffset]::Parse($assessedAt, [System.Globalization.CultureInfo]::InvariantCulture)
    } | Select-Object -Last 1)[0]
}

function Get-ManifestActorPolicy([string]$ManifestPath) {
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        return [pscustomobject][ordered]@{
            sourceSkinningContainment = $false
            effectiveSkinningMode = $null
            skinningModes = [pscustomobject][ordered]@{}
        }
    }

    $resolvedManifest = Resolve-RepoRelativePath $ManifestPath
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            sourceSkinningContainment = $false
            effectiveSkinningMode = $null
            skinningModes = [pscustomobject][ordered]@{}
        }
    }

    $manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
    $worldId = [string](Get-PropertyValue $manifest "worldId")
    $policy = Get-PropertyValue $manifest "actorAnimationPolicy"
    $environment = Get-PropertyValue $policy "environment"
    $modes = [ordered]@{}
    if ($null -ne $environment) {
        foreach ($property in @($environment.PSObject.Properties)) {
            Set-OrderedSkinningMode -Modes $modes -Name $property.Name -Value ([string]$property.Value)
        }
    }
    foreach ($entry in @((Get-PropertyValue $manifest "processEnvironment"))) {
        Add-OrderedSkinningModeFromText -Modes $modes -Text ([string]$entry)
    }
    foreach ($entry in @((Get-PropertyValue $manifest "environmentOverrides"))) {
        Add-OrderedSkinningModeFromText -Modes $modes -Text ([string]$entry)
    }
    $effectiveSkinningMode = Select-EffectiveSkinningMode -Modes $modes -WorldId $worldId
    $sourceSkinningContainment = [string]::Equals($effectiveSkinningMode, "source", [StringComparison]::OrdinalIgnoreCase)

    return [pscustomobject][ordered]@{
        sourceSkinningContainment = $sourceSkinningContainment
        effectiveSkinningMode = $effectiveSkinningMode
        skinningModes = [pscustomobject]$modes
    }
}

$runtimeRows = New-Object System.Collections.Generic.List[object]
foreach ($path in @($ActorRuntimePath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    foreach ($row in Read-JsonlRows -Path $path) {
        $runtimeRows.Add($row) | Out-Null
    }
}

$visualRows = @()
if (-not [string]::IsNullOrWhiteSpace($ActorVisualReviewPath) -and (Test-Path -LiteralPath (Resolve-RepoRelativePath $ActorVisualReviewPath) -PathType Leaf)) {
    $visualRows = @(Read-JsonlRows -Path $ActorVisualReviewPath)
}
$rigPoseRows = @()
foreach ($path in @($RigPoseSanityPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $rigPoseRows += @(Read-JsonlRows -Path $path)
    }
}
$partTelemetryRows = @()
foreach ($path in @($ActorPartTelemetryPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $partTelemetryRows += @(Read-JsonlRows -Path $path)
    }
}
$renderLiveRows = @()
foreach ($path in @($ActorRenderLivePath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $renderLiveRows += @(Read-JsonlRows -Path $path)
    }
}
$faceAttachmentRows = @()
foreach ($path in @($ActorFaceAttachmentPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $faceAttachmentRows += @(Read-JsonlRows -Path $path)
    }
}
$basisTelemetryRows = @()
foreach ($path in @($ActorBasisTelemetryPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $basisTelemetryRows += @(Read-JsonlRows -Path $path)
    }
}
$rootAttachmentRows = @()
foreach ($path in @($ActorRootAttachmentTelemetryPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $rootAttachmentRows += @(Read-JsonlRows -Path $path)
    }
}
$weaponMeshRows = @()
foreach ($path in @($ActorWeaponMeshTelemetryPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $weaponMeshRows += @(Read-JsonlRows -Path $path)
    }
}
$limbAnatomyRows = @()
foreach ($path in @($ActorLimbAnatomyPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $limbAnatomyRows += @(Read-JsonlRows -Path $path)
    }
}
$fabrikRows = @()
foreach ($path in @($ActorFabrikTelemetryPath)) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-Path -LiteralPath (Resolve-RepoRelativePath $path) -PathType Leaf) {
        $fabrikRows += @(Read-JsonlRows -Path $path)
    }
}

$groups = @($runtimeRows.ToArray() | Group-Object {
    $manifest = Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        return $manifest
    }
    return [string](Get-PropertyValue $_ "worldId")
})

$proofRows = New-Object System.Collections.Generic.List[object]
foreach ($group in $groups) {
    $rows = @($group.Group)
    $first = $rows[0]
    $worldId = [string](Get-PropertyValue $first "worldId")
    $manifest = Normalize-EvidencePath ([string](Get-PropertyValue $first "manifest"))
    $log = Normalize-EvidencePath ([string](Get-PropertyValue $first "log"))
    $image = Normalize-EvidencePath ([string](Get-PropertyValue $first "image"))
    $startCell = [string](Get-PropertyValue $first "startCell")
    $targetRuntimeRows = @(Select-ProofTargetRuntimeRows -Rows $rows)
    $nonTargetRuntimeRows = @($rows | Where-Object {
        $targetRuntimeRows -notcontains $_ -and -not (Test-IsPlayerRuntimeRow $_)
    })

    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    foreach ($row in $targetRuntimeRows) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $nonTargetRuntimeProblemRows = @($nonTargetRuntimeRows | Where-Object {
        $rowStatus = [string](Get-PropertyValue $_ "status")
        $rowStatus -eq "fail" -or $rowStatus -eq "questionable"
    })
    if ($nonTargetRuntimeProblemRows.Count -gt 0) {
        Add-UniqueText -List $warningClasses -Value "actor-non-target-runtime-gap"
    }

    $matchingVisualRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingVisualRows = @($visualRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingRigPoseRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingRigPoseRows = @($rigPoseRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingPartTelemetryRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingPartTelemetryRows = @($partTelemetryRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingRenderLiveRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingRenderLiveRows = @($renderLiveRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingFaceAttachmentRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingFaceAttachmentRows = @($faceAttachmentRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingBasisTelemetryRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingBasisTelemetryRows = @($basisTelemetryRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingRootAttachmentRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingRootAttachmentRows = @($rootAttachmentRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingWeaponMeshRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingWeaponMeshRows = @($weaponMeshRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingLimbAnatomyRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingLimbAnatomyRows = @($limbAnatomyRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $matchingFabrikRows = @()
    if (-not [string]::IsNullOrWhiteSpace($manifest)) {
        $matchingFabrikRows = @($fabrikRows | Where-Object {
            [string]::Equals((Normalize-EvidencePath ([string](Get-PropertyValue $_ "manifest"))), $manifest, [StringComparison]::OrdinalIgnoreCase)
        })
    }
    $targetLimbAnatomyRows = @(Select-ProofTargetLimbRows -Rows @($matchingLimbAnatomyRows))
    $nonTargetLimbAnatomyRows = @($matchingLimbAnatomyRows | Where-Object {
        $targetLimbAnatomyRows -notcontains $_ -and
        -not (Test-IsPlayerIdentity ([string](Get-PropertyValue $_ "actor")))
    })
    $nonTargetLimbProblemRows = @($nonTargetLimbAnatomyRows | Where-Object {
        $rowStatus = [string](Get-PropertyValue $_ "status")
        $rowStatus -eq "fail" -or $rowStatus -eq "questionable"
    })
    if ($nonTargetLimbProblemRows.Count -gt 0) {
        Add-UniqueText -List $warningClasses -Value "actor-non-target-limb-anatomy-gap"
    }
    $targetFabrikRows = @(Select-ProofTargetFabrikRows -Rows @($matchingFabrikRows))
    $nonTargetFabrikRows = @($matchingFabrikRows | Where-Object {
        $targetFabrikRows -notcontains $_ -and
        -not (Test-IsPlayerIdentity ([string](Get-PropertyValue $_ "actor")))
    })
    $nonTargetFabrikProblemRows = @($nonTargetFabrikRows | Where-Object {
        $rowStatus = Get-FabrikEffectiveStatus $_
        $rowStatus -eq "fail" -or $rowStatus -eq "questionable"
    })
    if ($nonTargetFabrikProblemRows.Count -gt 0) {
        Add-UniqueText -List $warningClasses -Value "actor-non-target-fabrik-gap"
    }
    $latestVisual = Select-LatestVisualReview -Rows @($matchingVisualRows)
    $latestWorldVisual = Select-LatestVisualReview -Rows @($visualRows | Where-Object {
        [string]::Equals([string](Get-PropertyValue $_ "worldId"), $worldId, [StringComparison]::OrdinalIgnoreCase)
    })
    $actorPolicy = Get-ManifestActorPolicy -ManifestPath $manifest

    $visualStatus = "missing"
    if ($null -eq $latestVisual) {
        Add-UniqueText -List $warningClasses -Value "actor-visual-review-gap"
    }
    else {
        $visualStatus = [string](Get-PropertyValue $latestVisual "status")
        foreach ($class in Get-TextArray (Get-PropertyValue $latestVisual "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $latestVisual "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }

    $runtimeStatus = Get-StatusFromRows -Rows @($targetRuntimeRows)
    $rigPoseStatus = Get-StatusFromRows -Rows @($matchingRigPoseRows)
    foreach ($row in @($matchingRigPoseRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $partTelemetryStatus = Get-StatusFromRows -Rows @($matchingPartTelemetryRows)
    foreach ($row in @($matchingPartTelemetryRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $renderLiveStatus = Get-StatusFromRows -Rows @($matchingRenderLiveRows)
    foreach ($row in @($matchingRenderLiveRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $faceAttachmentStatus = Get-StatusFromRows -Rows @($matchingFaceAttachmentRows)
    foreach ($row in @($matchingFaceAttachmentRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $actorBasisStatus = Get-StatusFromRows -Rows @($matchingBasisTelemetryRows)
    foreach ($row in @($matchingBasisTelemetryRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $rootAttachmentStatus = Get-StatusFromRows -Rows @($matchingRootAttachmentRows)
    foreach ($row in @($matchingRootAttachmentRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $weaponMeshStatus = Get-StatusFromRows -Rows @($matchingWeaponMeshRows)
    foreach ($row in @($matchingWeaponMeshRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $limbAnatomyStatus = Get-StatusFromRows -Rows @($targetLimbAnatomyRows)
    foreach ($row in @($targetLimbAnatomyRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
    }
    $fabrikStatus = Get-FabrikStatusFromRows -Rows @($targetFabrikRows)
    foreach ($row in @($targetFabrikRows)) {
        foreach ($class in Get-TextArray (Get-PropertyValue $row "failureClasses")) {
            Add-UniqueText -List $failureClasses -Value $class
        }
        foreach ($class in Get-TextArray (Get-PropertyValue $row "warningClasses")) {
            Add-UniqueText -List $warningClasses -Value $class
        }
        $effectiveFabrikStatus = Get-FabrikEffectiveStatus $row
        $verdict = [string](Get-PropertyValue $row "verdict")
        if ($effectiveFabrikStatus -eq "fail" -and [string]::Equals($verdict, "exploded", [StringComparison]::OrdinalIgnoreCase)) {
            Add-UniqueText -List $failureClasses -Value "actor-fabrik-target-exploded"
        }
        elseif ($effectiveFabrikStatus -eq "questionable" -and [string]::Equals($verdict, "suspect", [StringComparison]::OrdinalIgnoreCase)) {
            Add-UniqueText -List $warningClasses -Value "actor-fabrik-target-suspect"
        }
    }
    if ($actorPolicy.sourceSkinningContainment) {
        Add-UniqueText -List $failureClasses -Value "actor-pose-invalid"
        Add-UniqueText -List $warningClasses -Value "actor-runtime-suppressed"
    }

    $status = "pass"
    if ($failureClasses.Count -gt 0 -or $runtimeStatus -eq "fail" -or $visualStatus -eq "fail" -or $rigPoseStatus -eq "fail" -or $partTelemetryStatus -eq "fail" -or $renderLiveStatus -eq "fail" -or $faceAttachmentStatus -eq "fail" -or $actorBasisStatus -eq "fail" -or $rootAttachmentStatus -eq "fail" -or $weaponMeshStatus -eq "fail" -or $limbAnatomyStatus -eq "fail" -or $fabrikStatus -eq "fail") {
        $status = "fail"
    }
    elseif ($warningClasses.Count -gt 0 -or $runtimeStatus -eq "questionable" -or $visualStatus -eq "questionable" -or $visualStatus -eq "missing" -or $rigPoseStatus -eq "questionable" -or $partTelemetryStatus -eq "questionable" -or $renderLiveStatus -eq "questionable" -or $faceAttachmentStatus -eq "questionable" -or $actorBasisStatus -eq "questionable" -or $rootAttachmentStatus -eq "questionable" -or $weaponMeshStatus -eq "questionable" -or $limbAnatomyStatus -eq "questionable" -or $fabrikStatus -eq "questionable") {
        $status = "questionable"
    }

    $actorNames = @($rows | ForEach-Object { [string](Get-PropertyValue $_ "actorName") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $proofRows.Add([pscustomobject][ordered]@{
        schemaVersion = 1
        assessedAt = (Get-Date).ToString("o")
        worldId = $worldId
        evidenceKind = "actor-proof-status"
        status = $status
        proofStatus = $status
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        manifest = $manifest
        log = $log
        image = $image
        startCell = if ($startCell) { $startCell } else { $null }
        runtimeStatus = $runtimeStatus
        runtimeStatusCounts = New-StatusCountsObject -Rows @($targetRuntimeRows)
        allRuntimeStatus = Get-StatusFromRows -Rows $rows
        allRuntimeStatusCounts = New-StatusCountsObject -Rows $rows
        targetActorRuntimeRowCount = @($targetRuntimeRows).Count
        nonTargetActorRuntimeRowCount = @($nonTargetRuntimeRows).Count
        nonTargetRuntimeStatusCounts = New-StatusCountsObject -Rows @($nonTargetRuntimeRows)
        rigPoseStatus = $rigPoseStatus
        rigPoseStatusCounts = New-StatusCountsObject -Rows @($matchingRigPoseRows)
        rigPoseRowCount = @($matchingRigPoseRows).Count
        partTelemetryStatus = $partTelemetryStatus
        partTelemetryStatusCounts = New-StatusCountsObject -Rows @($matchingPartTelemetryRows)
        partTelemetryRowCount = @($matchingPartTelemetryRows).Count
        renderLiveStatus = $renderLiveStatus
        renderLiveStatusCounts = New-StatusCountsObject -Rows @($matchingRenderLiveRows)
        renderLiveRowCount = @($matchingRenderLiveRows).Count
        faceAttachmentStatus = $faceAttachmentStatus
        faceAttachmentStatusCounts = New-StatusCountsObject -Rows @($matchingFaceAttachmentRows)
        faceAttachmentRowCount = @($matchingFaceAttachmentRows).Count
        actorBasisStatus = $actorBasisStatus
        actorBasisStatusCounts = New-StatusCountsObject -Rows @($matchingBasisTelemetryRows)
        actorBasisRowCount = @($matchingBasisTelemetryRows).Count
        actorBasisTelemetry = if (@($matchingBasisTelemetryRows).Count -gt 0) {
            $basisRow = @($matchingBasisTelemetryRows)[0]
            [pscustomobject][ordered]@{
                auditRequested = [bool](Get-PropertyValue $basisRow "auditRequested")
                basisAuditCount = [int](Get-PropertyValue $basisRow "basisAuditCount")
                callbackAuditCount = [int](Get-PropertyValue $basisRow "callbackAuditCount")
                largeRotationDeltaCount = [int](Get-PropertyValue $basisRow "largeRotationDeltaCount")
                headNeckLargeRotationDeltaCount = [int](Get-PropertyValue $basisRow "headNeckLargeRotationDeltaCount")
                maxRotationDeltaDegrees = Get-PropertyValue $basisRow "maxRotationDeltaDegrees"
                maxRotationDeltaBone = [string](Get-PropertyValue $basisRow "maxRotationDeltaBone")
            }
        } else { $null }
        rootAttachmentStatus = $rootAttachmentStatus
        rootAttachmentStatusCounts = New-StatusCountsObject -Rows @($matchingRootAttachmentRows)
        rootAttachmentRowCount = @($matchingRootAttachmentRows).Count
        weaponMeshStatus = $weaponMeshStatus
        weaponMeshStatusCounts = New-StatusCountsObject -Rows @($matchingWeaponMeshRows)
        weaponMeshRowCount = @($matchingWeaponMeshRows).Count
        actorWeaponMeshTelemetry = if (@($matchingWeaponMeshRows).Count -gt 0) {
            $weaponMeshRow = @($matchingWeaponMeshRows)[0]
            [pscustomobject][ordered]@{
                auditExpected = [bool](Get-PropertyValue $weaponMeshRow "auditExpected")
                weaponMeshRowCount = [int](Get-PropertyValue $weaponMeshRow "weaponMeshRowCount")
                runtimeWeaponMeshRowCount = [int](Get-PropertyValue $weaponMeshRow "runtimeWeaponMeshRowCount")
                reason = [string](Get-PropertyValue $weaponMeshRow "reason")
            }
        } else { $null }
        limbAnatomyStatus = $limbAnatomyStatus
        limbAnatomyStatusCounts = New-StatusCountsObject -Rows @($targetLimbAnatomyRows)
        allLimbAnatomyStatus = Get-StatusFromRows -Rows @($matchingLimbAnatomyRows)
        allLimbAnatomyStatusCounts = New-StatusCountsObject -Rows @($matchingLimbAnatomyRows)
        limbAnatomyRowCount = @($matchingLimbAnatomyRows).Count
        targetLimbAnatomyRowCount = @($targetLimbAnatomyRows).Count
        nonTargetLimbAnatomyRowCount = @($nonTargetLimbAnatomyRows).Count
        nonTargetLimbAnatomyStatusCounts = New-StatusCountsObject -Rows @($nonTargetLimbAnatomyRows)
        actorLimbAnatomy = if (@($targetLimbAnatomyRows).Count -gt 0) {
            $failedRows = @($targetLimbAnatomyRows | Where-Object { [string](Get-PropertyValue $_ "status") -eq "fail" })
            $worstRow = if (@($failedRows).Count -gt 0) { $failedRows[0] } else { @($targetLimbAnatomyRows)[0] }
            [pscustomobject][ordered]@{
                actor = [string](Get-PropertyValue $worstRow "actor")
                reason = [string](Get-PropertyValue $worstRow "reason")
                handSpreadRatio = Get-PropertyValue $worstRow "handSpreadRatio"
                footSpreadRatio = Get-PropertyValue $worstRow "footSpreadRatio"
                avgFootFromHip = Get-PropertyValue $worstRow "avgFootFromHip"
                avgFootDrop = Get-PropertyValue $worstRow "avgFootDrop"
                avgKneeDrop = Get-PropertyValue $worstRow "avgKneeDrop"
                logLine = Get-PropertyValue $worstRow "logLine"
            }
        } else { $null }
        fabrikStatus = $fabrikStatus
        fabrikStatusCounts = New-FabrikStatusCountsObject -Rows @($targetFabrikRows)
        allFabrikStatus = Get-FabrikStatusFromRows -Rows @($matchingFabrikRows)
        allFabrikStatusCounts = New-FabrikStatusCountsObject -Rows @($matchingFabrikRows)
        fabrikRowCount = @($matchingFabrikRows).Count
        targetFabrikRowCount = @($targetFabrikRows).Count
        nonTargetFabrikRowCount = @($nonTargetFabrikRows).Count
        nonTargetFabrikStatusCounts = New-FabrikStatusCountsObject -Rows @($nonTargetFabrikRows)
        actorFabrikTelemetry = if (@($targetFabrikRows).Count -gt 0) {
            $failedFabrikRows = @($targetFabrikRows | Where-Object { [string](Get-PropertyValue $_ "status") -eq "fail" })
            $candidateFabrikRows = if (@($failedFabrikRows).Count -gt 0) { @($failedFabrikRows) } else { @($targetFabrikRows) }
            $worstFabrikRow = @($candidateFabrikRows | Sort-Object {
                $value = Get-PropertyValue $_ "fabrikResidual"
                if ($null -eq $value) { return -1.0 }
                return [double]$value
            } -Descending | Select-Object -First 1)[0]
            [pscustomobject][ordered]@{
                actor = [string](Get-PropertyValue $worstFabrikRow "actor")
                side = [string](Get-PropertyValue $worstFabrikRow "side")
                target = [string](Get-PropertyValue $worstFabrikRow "target")
                verdict = [string](Get-PropertyValue $worstFabrikRow "verdict")
                status = Get-FabrikEffectiveStatus $worstFabrikRow
                failureClasses = @(Get-TextArray (Get-PropertyValue $worstFabrikRow "failureClasses"))
                warningClasses = @(Get-TextArray (Get-PropertyValue $worstFabrikRow "warningClasses"))
                fabrikResidual = Get-PropertyValue $worstFabrikRow "fabrikResidual"
                unreachableBy = Get-PropertyValue $worstFabrikRow "unreachableBy"
                animationGroup = [string](Get-PropertyValue $worstFabrikRow "animationGroup")
                animationTime = Get-PropertyValue $worstFabrikRow "animationTime"
                logLine = Get-PropertyValue $worstFabrikRow "logLine"
            }
        } else { $null }
        actorRootAttachmentTelemetry = if (@($matchingRootAttachmentRows).Count -gt 0) {
            $rootRow = @($matchingRootAttachmentRows)[0]
            [pscustomobject][ordered]@{
                auditRequested = [bool](Get-PropertyValue $rootRow "auditRequested")
                rootAuditCount = [int](Get-PropertyValue $rootRow "rootAuditCount")
                headBelowPelvisCount = [int](Get-PropertyValue $rootRow "headBelowPelvisCount")
                feetAbovePelvisCount = [int](Get-PropertyValue $rootRow "feetAbovePelvisCount")
                negativeHandednessCount = [int](Get-PropertyValue $rootRow "negativeHandednessCount")
                averageHeadMinusPelvisZ = Get-PropertyValue $rootRow "averageHeadMinusPelvisZ"
                averageFootMidMinusPelvisZ = Get-PropertyValue $rootRow "averageFootMidMinusPelvisZ"
            }
        } else { $null }
        sourceSkinningContainment = [bool]$actorPolicy.sourceSkinningContainment
        effectiveSkinningMode = $actorPolicy.effectiveSkinningMode
        skinningMode = $actorPolicy.effectiveSkinningMode
        skinningModes = $actorPolicy.skinningModes
        visualReviewStatus = $visualStatus
        visualReview = if ($null -ne $latestVisual) {
            [pscustomobject][ordered]@{
                assessedAt = Get-PropertyValue $latestVisual "assessedAt"
                image = Normalize-EvidencePath ([string](Get-PropertyValue $latestVisual "image"))
                notes = [string](Get-PropertyValue $latestVisual "notes")
            }
        } else { $null }
        latestWorldVisualReview = if ($null -ne $latestWorldVisual) {
            [pscustomobject][ordered]@{
                status = [string](Get-PropertyValue $latestWorldVisual "status")
                assessedAt = Get-PropertyValue $latestWorldVisual "assessedAt"
                manifest = Normalize-EvidencePath ([string](Get-PropertyValue $latestWorldVisual "manifest"))
                image = Normalize-EvidencePath ([string](Get-PropertyValue $latestWorldVisual "image"))
                notes = [string](Get-PropertyValue $latestWorldVisual "notes")
            }
        } else { $null }
        actorNames = @($actorNames)
        targetActorNames = @($targetRuntimeRows | ForEach-Object { [string](Get-PropertyValue $_ "actorName") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        actorRuntimeRowCount = @($rows).Count
    }) | Out-Null
}

if (-not $NoWrite) {
    $resolvedOutput = Resolve-RepoRelativePath $OutputPath
    $outputDir = Split-Path -Parent $resolvedOutput
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        Remove-Item -LiteralPath $resolvedOutput -Force
    }
    foreach ($row in @($proofRows.ToArray())) {
        ($row | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

@($proofRows.ToArray()) |
    Select-Object worldId, skinningMode, proofStatus, runtimeStatus, allRuntimeStatus, rigPoseStatus, partTelemetryStatus, renderLiveStatus, faceAttachmentStatus, actorBasisStatus, rootAttachmentStatus, weaponMeshStatus, limbAnatomyStatus, allLimbAnatomyStatus, fabrikStatus, allFabrikStatus, visualReviewStatus, sourceSkinningContainment, actorRuntimeRowCount, targetActorRuntimeRowCount, nonTargetActorRuntimeRowCount, rigPoseRowCount, partTelemetryRowCount, renderLiveRowCount, faceAttachmentRowCount, actorBasisRowCount, rootAttachmentRowCount, weaponMeshRowCount, limbAnatomyRowCount, targetLimbAnatomyRowCount, nonTargetLimbAnatomyRowCount, fabrikRowCount, targetFabrikRowCount, nonTargetFabrikRowCount, @{ Name = "failureClasses"; Expression = { @($_.failureClasses) -join "," } }, @{ Name = "warningClasses"; Expression = { @($_.warningClasses) -join "," } } |
    Format-Table -Wrap -AutoSize

if (-not $NoWrite) {
    Write-Host "Wrote actor proof status ledger: $OutputPath"
}
