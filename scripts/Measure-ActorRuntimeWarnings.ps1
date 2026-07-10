param(
    [string[]]$Path = @(),
    [string[]]$InputPath = @(),
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/actor-runtime-warnings.jsonl",
    [string]$PolicyPath = "catalog/screenshot-evidence-policy.json",
    [switch]$IncludeManifests,
    [switch]$IncludeClean,
    [switch]$AllowProfileLogFallback,
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToForwardSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    return ([System.IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
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

function Get-ActorFieldValue($Actor, [string]$Source) {
    if ($null -eq $Actor -or [string]::IsNullOrWhiteSpace($Source)) {
        return $null
    }
    if ($Actor.Contains($Source)) {
        return $Actor[$Source]
    }
    return $null
}

function Convert-ActorLedgerValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $text = $Value.Trim()
    if ($text.Length -ge 2 -and $text.StartsWith('"') -and $text.EndsWith('"')) {
        return $text.Substring(1, $text.Length - 2)
    }
    if ($text -match '^-?\d+$') {
        return [int]$text
    }
    return $text
}

function Convert-ActorReferenceText([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $text = $Value.Trim()
    if ($text.Length -ge 2 -and $text.StartsWith('"') -and $text.EndsWith('"')) {
        return $text.Substring(1, $text.Length - 2)
    }
    return $text
}

function Convert-ActorLedgerFlag($Value) {
    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    $text = ([string]$Value).Trim()
    return $text -eq "1" -or $text -eq "true" -or $text -eq "True"
}

function Parse-ActorLedgerKeyValues([string]$Text) {
    $values = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]$values
    }

    $matches = [regex]::Matches($Text, '([A-Za-z][A-Za-z0-9_]*)=("[^"]*"|\([^)]*\)|0x[0-9a-fA-F]+|[^\s]+)')
    foreach ($match in $matches) {
        $values[$match.Groups[1].Value] = Convert-ActorLedgerValue $match.Groups[2].Value
    }
    return [pscustomobject]$values
}

function Test-ActorRuntimeRule($Actor, $Rule) {
    $unlessValue = Get-PropertyValue $Rule "unless"
    if ($null -ne $unlessValue) {
        foreach ($unless in @($unlessValue)) {
            if ($null -ne $unless -and (Test-ActorRuntimeRule -Actor $Actor -Rule $unless)) {
                return $false
            }
        }
    }

    $source = [string](Get-PropertyValue $Rule "source")
    $operator = [string](Get-PropertyValue $Rule "operator")
    $expected = Get-PropertyValue $Rule "value"
    $actual = Get-ActorFieldValue -Actor $Actor -Source $source

    if ([string]::IsNullOrWhiteSpace($operator)) {
        $operator = "equals"
    }
    if ($null -eq $actual) {
        if ($operator -eq "equals") {
            return $null -eq $expected
        }
        if ($operator -eq "notEquals") {
            return $null -ne $expected
        }
        return $false
    }

    switch ($operator) {
        "equals" {
            if ($expected -is [bool]) {
                return ([bool]$actual) -eq ([bool]$expected)
            }
            if ($expected -is [int] -or $expected -is [long] -or $expected -is [double]) {
                return ([double]$actual) -eq ([double]$expected)
            }
            return [string]$actual -eq [string]$expected
        }
        "notEquals" {
            if ($expected -is [bool]) {
                return ([bool]$actual) -ne ([bool]$expected)
            }
            if ($expected -is [int] -or $expected -is [long] -or $expected -is [double]) {
                return ([double]$actual) -ne ([double]$expected)
            }
            return [string]$actual -ne [string]$expected
        }
        "greaterThan" {
            return ([double]$actual) -gt ([double]$expected)
        }
        "greaterThanOrEqual" {
            return ([double]$actual) -ge ([double]$expected)
        }
        "lessThan" {
            return ([double]$actual) -lt ([double]$expected)
        }
        "lessThanOrEqual" {
            return ([double]$actual) -le ([double]$expected)
        }
        default {
            throw "Unsupported actor runtime rule operator '$operator' in rule '$([string](Get-PropertyValue $Rule "id"))'"
        }
    }
}

function Add-UniqueText([object[]]$Values, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @($Values)
    }
    return @(@($Values) + $Value | Select-Object -Unique)
}

function New-ActorRuntimeRow([string]$FormId) {
    return [ordered]@{
        formId = $FormId
        actorShellSeen = $false
        placementRef = $null
        baseRef = $null
        game = $null
        actorType = $null
        actorName = $null
        level = $null
        health = $null
        race = $null
        raceEditor = $null
        female = $null
        traits = $null
        modelRecord = $null
        modelKfCount = $null
        aiPackageRecord = $null
        packageCount = $null
        weapon = $null
        skeleton = $null
        skeletonExists = $null
        objectRoot = $null
        skeletonNode = $null
        nodeMap = $null
        animationSourceCount = 0
        animationSourceBoundCount = 0
        animationSources = @()
        crossCellPrePlacement = $false
        crossCellPackage = $null
        crossCellMovedPtrCell = $null
        registeredCharacterController = $false
        idleAnimationMissingCount = 0
        idleAnimationMissingGroups = @()
    }
}

function Get-ManifestEvidenceKind($Manifest) {
    foreach ($screenshot in @((Get-PropertyValue $Manifest "screenshots"))) {
        $source = [string](Get-PropertyValue $screenshot "source")
        switch ($source) {
            "openmw-native-screenshot" { return "real-native-screenshot" }
            "window-screenshot-fallback" { return "real-window-screenshot-fallback" }
            default {
                if (-not [string]::IsNullOrWhiteSpace($source)) {
                    return $source
                }
            }
        }
    }
    return "real-screenshot"
}

function Get-ManifestFirstImage($Manifest) {
    foreach ($screenshot in @((Get-PropertyValue $Manifest "screenshots"))) {
        $path = [string](Get-PropertyValue $screenshot "path")
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            return $path
        }
    }
    return $null
}

function Test-ProcessEnvironmentFlagEnabled([string[]]$ProcessEnvironment, [string]$Name) {
    foreach ($entry in @($ProcessEnvironment)) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        $parts = $entry -split "=", 2
        if ($parts.Count -eq 0 -or -not [string]::Equals($parts[0], $Name, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($parts.Count -eq 1) {
            return $true
        }
        $value = $parts[1].Trim()
        return -not ([string]::IsNullOrWhiteSpace($value) -or $value -eq "0" -or [string]::Equals($value, "false", [StringComparison]::OrdinalIgnoreCase))
    }
    return $false
}

function Test-LogHasActorRuntimeSignal([string]$LogPath, $ActorRuntimePolicy) {
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return $false
    }

    $text = Get-Content -LiteralPath $LogPath -Raw
    if ($text -match "World viewer actor ledger:") {
        return $true
    }
    foreach ($patternName in @("initializedActorPattern", "idleAnimationMissingPattern", "registeredCharacterControllerPattern")) {
        $pattern = [string](Get-PropertyValue $ActorRuntimePolicy $patternName)
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $text -match $pattern) {
            return $true
        }
    }
    return $false
}

function New-ActorRuntimeGapRow {
    param(
        [string]$LogPath,
        [string]$WorldId,
        [string]$EvidenceKind = "actor-runtime",
        [string]$ScreenshotEvidenceKind = "",
        [string]$ManifestPath = "",
        [string]$ImagePath = "",
        [string]$StartCell = ""
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        assessedAt = (Get-Date).ToString("o")
        worldId = $WorldId
        evidenceKind = $EvidenceKind
        screenshotEvidenceKind = if ($ScreenshotEvidenceKind) { $ScreenshotEvidenceKind } else { $null }
        status = "questionable"
        failureClasses = @()
        warningClasses = @("actor-runtime-gap")
        rules = @("actor-runtime-gap")
        manifest = if ($ManifestPath) { Convert-ToForwardSlash $ManifestPath } else { $null }
        log = Convert-ToForwardSlash $LogPath
        image = if ($ImagePath) { Convert-ToForwardSlash $ImagePath } else { $null }
        startCell = if ($StartCell) { $StartCell } else { $null }
        formId = $null
        placementRef = $null
        baseRef = $null
        game = $null
        actorName = $null
        actorType = $null
        level = $null
        health = $null
        race = $null
        raceEditor = $null
        female = $null
        traits = $null
        modelRecord = $null
        modelKfCount = $null
        aiPackageRecord = $null
        packageCount = $null
        weapon = $null
        skeleton = $null
        skeletonExists = $null
        objectRoot = $null
        skeletonNode = $null
        nodeMap = $null
        animationSourceCount = 0
        animationSourceBoundCount = 0
        animationSources = @()
        actorRuntimeSuppressed = $false
        actorShellSeen = $false
        registeredCharacterController = $null
        idleAnimationMissingCount = $null
        idleAnimationMissingGroups = @()
    }
}

function New-ActorRuntimeRowsFromLog {
    param(
        [string]$LogPath,
        [string]$WorldId = "",
        [string]$EvidenceKind = "actor-runtime",
        [string]$ScreenshotEvidenceKind = "",
        [string]$ManifestPath = "",
        [string]$ImagePath = "",
        [string]$StartCell = "",
        [bool]$ActorRuntimeSuppressed = $false,
        $ActorRuntimePolicy
    )

    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return @()
    }

    $initializedActorPattern = [string](Get-PropertyValue $ActorRuntimePolicy "initializedActorPattern")
    $idleAnimationMissingPattern = [string](Get-PropertyValue $ActorRuntimePolicy "idleAnimationMissingPattern")
    $registeredCharacterControllerPattern = [string](Get-PropertyValue $ActorRuntimePolicy "registeredCharacterControllerPattern")
    if ([string]::IsNullOrWhiteSpace($initializedActorPattern) -or [string]::IsNullOrWhiteSpace($idleAnimationMissingPattern) -or [string]::IsNullOrWhiteSpace($registeredCharacterControllerPattern)) {
        throw "Actor runtime policy must define initializedActorPattern, idleAnimationMissingPattern, and registeredCharacterControllerPattern"
    }

    $text = Get-Content -LiteralPath $LogPath -Raw
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $actors = @{}

    foreach ($match in [regex]::Matches($text, $initializedActorPattern, $options)) {
        $formId = $match.Groups["formId"].Value
        if ([string]::IsNullOrWhiteSpace($formId)) {
            continue
        }
        if (-not $actors.ContainsKey($formId)) {
            $actors[$formId] = New-ActorRuntimeRow -FormId $formId
        }
        $actor = $actors[$formId]
        $actor["actorShellSeen"] = $true
        foreach ($name in @("actorType", "actorName", "level", "health", "race", "traits", "modelRecord", "aiPackageRecord", "weapon")) {
            $actor[$name] = $match.Groups[$name].Value
        }
        $actor["modelKfCount"] = [int]$match.Groups["modelKfCount"].Value
        $actor["packageCount"] = [int]$match.Groups["packageCount"].Value
    }

    foreach ($match in [regex]::Matches($text, "applied cross-cell package pre-placement (?<package>\S+) actor=(?<actor>\S+).*?movedPtrCell=(?<movedPtrCell>\S+)", $options)) {
        $movedActor = $match.Groups["actor"].Value
        if ([string]::IsNullOrWhiteSpace($movedActor)) {
            continue
        }

        foreach ($key in @($actors.Keys)) {
            $actor = $actors[$key]
            $candidateNames = @(
                [string]$actor["actorName"],
                [string]$actor["traits"],
                [string]$actor["modelRecord"],
                [string]$actor["aiPackageRecord"]
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($candidateNames -notcontains $movedActor) {
                continue
            }

            $actor["crossCellPrePlacement"] = $true
            $actor["crossCellPackage"] = $match.Groups["package"].Value
            $actor["crossCellMovedPtrCell"] = $match.Groups["movedPtrCell"].Value
        }
    }

    foreach ($line in Get-Content -LiteralPath $LogPath) {
        $index = $line.IndexOf("World viewer actor ledger:")
        if ($index -lt 0) {
            continue
        }
        $entry = Parse-ActorLedgerKeyValues ($line.Substring($index + "World viewer actor ledger:".Length).Trim())
        $phase = [string](Get-PropertyValue $entry "phase")
        if ($phase -ne "npc-root-begin" -and $phase -ne "npc-root-end" -and $phase -ne "animation-source") {
            continue
        }

        $formId = [string](Get-PropertyValue $entry "form")
        if ([string]::IsNullOrWhiteSpace($formId)) {
            $formId = [string](Get-PropertyValue $entry "base")
        }
        if ([string]::IsNullOrWhiteSpace($formId)) {
            continue
        }
        if (-not $actors.ContainsKey($formId)) {
            $actors[$formId] = New-ActorRuntimeRow -FormId $formId
        }
        $actor = $actors[$formId]
        if ($phase -eq "animation-source") {
            $actor["animationSourceCount"] = [int]$actor["animationSourceCount"] + 1
            if (Convert-ActorLedgerFlag (Get-PropertyValue $entry "bound")) {
                $actor["animationSourceBoundCount"] = [int]$actor["animationSourceBoundCount"] + 1
            }
            $sourcePath = [string](Get-PropertyValue $entry "kf")
            if (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
                $actor["animationSources"] = Add-UniqueText -Values $actor["animationSources"] -Value $sourcePath
            }
        }
        $actor["actorShellSeen"] = $true
        $placementRef = Get-PropertyValue $entry "ref"
        if ($null -ne $placementRef) {
            $actor["placementRef"] = [string]$placementRef
        }
        $baseRef = Get-PropertyValue $entry "base"
        if ($null -ne $baseRef) {
            $actor["baseRef"] = [string]$baseRef
        }
        foreach ($name in @("game", "raceEditor", "skeleton")) {
            $value = Get-PropertyValue $entry $name
            if ($null -ne $value) {
                $actor[$name] = [string]$value
            }
        }
        $npc = Get-PropertyValue $entry "npc"
        if ($null -ne $npc -and [string]::IsNullOrWhiteSpace([string]$actor["actorName"])) {
            $actor["actorName"] = [string]$npc
        }
        $female = Get-PropertyValue $entry "female"
        if ($null -ne $female) {
            $actor["female"] = [bool]([int]$female)
        }
        foreach ($name in @("skeletonExists", "objectRoot", "skeletonNode")) {
            $value = Get-PropertyValue $entry $name
            if ($null -ne $value) {
                $actor[$name] = [bool]([int]$value)
            }
        }
        $nodeMap = Get-PropertyValue $entry "nodeMap"
        if ($null -ne $nodeMap) {
            $actor["nodeMap"] = [int]$nodeMap
        }
    }

    foreach ($match in [regex]::Matches($text, $registeredCharacterControllerPattern, $options)) {
        $formId = Convert-ActorReferenceText $match.Groups["formId"].Value
        if ([string]::IsNullOrWhiteSpace($formId)) {
            continue
        }
        if (-not $actors.ContainsKey($formId)) {
            $actors[$formId] = New-ActorRuntimeRow -FormId $formId
        }
        if ([string]::IsNullOrWhiteSpace([string]$actors[$formId]["actorName"]) -and $formId -notmatch "^FormId:") {
            $actors[$formId]["actorName"] = $formId
        }
        $actors[$formId]["registeredCharacterController"] = $true
    }

    foreach ($match in [regex]::Matches($text, $idleAnimationMissingPattern, $options)) {
        $formId = $match.Groups["formId"].Value
        if ([string]::IsNullOrWhiteSpace($formId)) {
            continue
        }
        if (-not $actors.ContainsKey($formId)) {
            $actors[$formId] = New-ActorRuntimeRow -FormId $formId
        }
        $actor = $actors[$formId]
        $actor["idleAnimationMissingCount"] = [int]$actor["idleAnimationMissingCount"] + 1
        $actor["idleAnimationMissingGroups"] = Add-UniqueText -Values $actor["idleAnimationMissingGroups"] -Value $match.Groups["group"].Value
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($formId in @($actors.Keys | Sort-Object)) {
        $actor = $actors[$formId]
        $ruleIds = @()
        $failureClasses = @()
        $warningClasses = @()

        if ($ActorRuntimeSuppressed) {
            $ruleIds = Add-UniqueText -Values $ruleIds -Value "actor-runtime-suppressed"
            $warningClasses = Add-UniqueText -Values $warningClasses -Value "actor-runtime-suppressed"
        }
        else {
            foreach ($rule in @((Get-PropertyValue $ActorRuntimePolicy "rules"))) {
                if (-not (Test-ActorRuntimeRule -Actor $actor -Rule $rule)) {
                    continue
                }
                $ruleId = [string](Get-PropertyValue $rule "id")
                $ruleIds = Add-UniqueText -Values $ruleIds -Value $ruleId
                $severity = [string](Get-PropertyValue $rule "severity")
                if ([string]::IsNullOrWhiteSpace($severity)) {
                    $severity = "failure"
                }
                $class = [string](Get-PropertyValue $rule "failureClass")
                if ([string]::IsNullOrWhiteSpace($class)) {
                    $class = $ruleId
                }
                if ([string]::Equals($severity, "failure", [StringComparison]::OrdinalIgnoreCase)) {
                    $failureClasses = Add-UniqueText -Values $failureClasses -Value $class
                }
                else {
                    $warningClasses = Add-UniqueText -Values $warningClasses -Value $class
                }
            }
        }

        if (@($failureClasses).Count -eq 0 -and @($warningClasses).Count -eq 0 -and -not $IncludeClean) {
            continue
        }

        $status = "pass"
        if (@($failureClasses).Count -gt 0) {
            $status = "fail"
        }
        elseif (@($warningClasses).Count -gt 0) {
            $status = "questionable"
        }

        $rows.Add([pscustomobject][ordered]@{
            schemaVersion = 1
            assessedAt = (Get-Date).ToString("o")
            worldId = $WorldId
            evidenceKind = $EvidenceKind
            screenshotEvidenceKind = if ($ScreenshotEvidenceKind) { $ScreenshotEvidenceKind } else { $null }
            status = $status
            failureClasses = @($failureClasses)
            warningClasses = @($warningClasses)
            rules = @($ruleIds)
            manifest = if ($ManifestPath) { Convert-ToForwardSlash $ManifestPath } else { $null }
            log = Convert-ToForwardSlash $LogPath
            image = if ($ImagePath) { Convert-ToForwardSlash $ImagePath } else { $null }
            startCell = if ($StartCell) { $StartCell } else { $null }
            formId = $actor["formId"]
            placementRef = $actor["placementRef"]
            baseRef = $actor["baseRef"]
            game = $actor["game"]
            actorName = $actor["actorName"]
            actorType = $actor["actorType"]
            level = $actor["level"]
            health = $actor["health"]
            race = $actor["race"]
            raceEditor = $actor["raceEditor"]
            female = $actor["female"]
            traits = $actor["traits"]
            modelRecord = $actor["modelRecord"]
            modelKfCount = $actor["modelKfCount"]
            aiPackageRecord = $actor["aiPackageRecord"]
            packageCount = $actor["packageCount"]
            weapon = $actor["weapon"]
            skeleton = $actor["skeleton"]
            skeletonExists = $actor["skeletonExists"]
            objectRoot = $actor["objectRoot"]
            skeletonNode = $actor["skeletonNode"]
            nodeMap = $actor["nodeMap"]
            animationSourceCount = $actor["animationSourceCount"]
            animationSourceBoundCount = $actor["animationSourceBoundCount"]
            animationSources = @($actor["animationSources"])
            crossCellPrePlacement = $actor["crossCellPrePlacement"]
            crossCellPackage = $actor["crossCellPackage"]
            crossCellMovedPtrCell = $actor["crossCellMovedPtrCell"]
            actorRuntimeSuppressed = $ActorRuntimeSuppressed
            actorShellSeen = $actor["actorShellSeen"]
            registeredCharacterController = $actor["registeredCharacterController"]
            idleAnimationMissingCount = $actor["idleAnimationMissingCount"]
            idleAnimationMissingGroups = @($actor["idleAnimationMissingGroups"])
        }) | Out-Null
    }

    return @($rows.ToArray())
}

function Add-RowsFromManifest {
    param(
        [string]$ManifestPath,
        [System.Collections.Generic.List[object]]$Rows,
        $ActorRuntimePolicy
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $logPath = [string](Get-PropertyValue $manifest "logPath")
    $processEnvironment = @((Get-PropertyValue $manifest "processEnvironment") | ForEach-Object { [string]$_ })
    $actorRuntimeSuppressed = $processEnvironment -contains "OPENMW_WORLD_VIEWER_DISABLE_ESM4_ACTORS=1"
    $actorRuntimeRequested = (Test-ProcessEnvironmentFlagEnabled -ProcessEnvironment $processEnvironment -Name "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY") `
        -or (Test-ProcessEnvironmentFlagEnabled -ProcessEnvironment $processEnvironment -Name "OPENMW_WORLD_VIEWER_TELEMETRY")
    if (($AllowProfileLogFallback -eq $true) -and ([string]::IsNullOrWhiteSpace($logPath) -or -not (Test-Path -LiteralPath $logPath))) {
        $profileDirectory = [string](Get-PropertyValue $manifest "profileDirectory")
        if (-not [string]::IsNullOrWhiteSpace($profileDirectory)) {
            $candidate = Join-Path $profileDirectory "openmw.log"
            if (Test-Path -LiteralPath $candidate) {
                $logPath = $candidate
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($logPath) -or -not (Test-Path -LiteralPath $logPath)) {
        return
    }

    $manifestRows = @(New-ActorRuntimeRowsFromLog `
        -LogPath $logPath `
        -WorldId ([string](Get-PropertyValue $manifest "worldId")) `
        -EvidenceKind "actor-runtime" `
        -ScreenshotEvidenceKind (Get-ManifestEvidenceKind -Manifest $manifest) `
        -ManifestPath $ManifestPath `
        -ImagePath (Get-ManifestFirstImage -Manifest $manifest) `
        -StartCell ([string](Get-PropertyValue $manifest "startCell")) `
        -ActorRuntimeSuppressed $actorRuntimeSuppressed `
        -ActorRuntimePolicy $ActorRuntimePolicy)
    if ($manifestRows.Count -eq 0 -and $actorRuntimeRequested -and -not $actorRuntimeSuppressed -and -not (Test-LogHasActorRuntimeSignal -LogPath $logPath -ActorRuntimePolicy $ActorRuntimePolicy)) {
        $manifestRows = @((New-ActorRuntimeGapRow `
            -LogPath $logPath `
            -WorldId ([string](Get-PropertyValue $manifest "worldId")) `
            -EvidenceKind "actor-runtime" `
            -ScreenshotEvidenceKind (Get-ManifestEvidenceKind -Manifest $manifest) `
            -ManifestPath $ManifestPath `
            -ImagePath (Get-ManifestFirstImage -Manifest $manifest) `
            -StartCell ([string](Get-PropertyValue $manifest "startCell")))
        )
    }

    foreach ($row in $manifestRows) {
        $Rows.Add($row) | Out-Null
    }
}

function Add-RowsFromPath {
    param(
        [string]$InputPath,
        [System.Collections.Generic.List[object]]$Rows,
        $ActorRuntimePolicy
    )

    $resolved = Resolve-RepoRelativePath $InputPath
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $manifestFiles = Get-ChildItem -LiteralPath $resolved -Recurse -File -Filter "manifest.json" | Sort-Object FullName
        if (@($manifestFiles).Count -gt 0) {
            foreach ($manifestFile in $manifestFiles) {
                Add-RowsFromManifest -ManifestPath $manifestFile.FullName -Rows $Rows -ActorRuntimePolicy $ActorRuntimePolicy
            }
        }
        else {
            $logFiles = Get-ChildItem -LiteralPath $resolved -Recurse -File -Filter "*.log" |
                Where-Object { $_.Name -eq "openmw.log" } |
                Sort-Object FullName
            foreach ($logFile in $logFiles) {
                foreach ($row in New-ActorRuntimeRowsFromLog -LogPath $logFile.FullName -ActorRuntimePolicy $ActorRuntimePolicy) {
                    $Rows.Add($row) | Out-Null
                }
            }
        }
    }
    elseif (Test-Path -LiteralPath $resolved -PathType Leaf) {
        if ([System.IO.Path]::GetFileName($resolved) -eq "manifest.json") {
            Add-RowsFromManifest -ManifestPath $resolved -Rows $Rows -ActorRuntimePolicy $ActorRuntimePolicy
        }
        else {
            foreach ($row in New-ActorRuntimeRowsFromLog -LogPath $resolved -ActorRuntimePolicy $ActorRuntimePolicy) {
                $Rows.Add($row) | Out-Null
            }
        }
    }
    else {
        throw "Actor runtime evidence path not found: $InputPath"
    }
}

$resolvedPolicyPath = Resolve-RepoRelativePath $PolicyPath
if (-not (Test-Path -LiteralPath $resolvedPolicyPath)) {
    throw "Screenshot evidence policy not found: $PolicyPath"
}
$policy = Get-Content -LiteralPath $resolvedPolicyPath -Raw | ConvertFrom-Json
$actorRuntimePolicy = Get-PropertyValue $policy "actorRuntimeLedger"
if ($null -eq $actorRuntimePolicy) {
    throw "Screenshot evidence policy missing actorRuntimeLedger"
}

$allInputPaths = @($Path + $InputPath)

if ($allInputPaths.Count -eq 0 -and $ManifestPath.Count -eq 0 -and -not $IncludeManifests) {
    $IncludeManifests = $true
}

$rows = New-Object System.Collections.Generic.List[object]

$hasExplicitInput = ($allInputPaths.Count -gt 0 -or @($ManifestPath).Count -gt 0)

if ($IncludeManifests -and -not $hasExplicitInput) {
    $manifestRootPath = Resolve-RepoRelativePath $ManifestRoot
    if (Test-Path -LiteralPath $manifestRootPath) {
        $manifestFiles = Get-ChildItem -LiteralPath $manifestRootPath -Recurse -File -Filter "manifest.json" |
            Sort-Object LastWriteTime
        foreach ($manifestFile in $manifestFiles) {
            Add-RowsFromManifest -ManifestPath $manifestFile.FullName -Rows $rows -ActorRuntimePolicy $actorRuntimePolicy
        }
    }
}

foreach ($manifestPathEntry in @($ManifestPath)) {
    if ([string]::IsNullOrWhiteSpace($manifestPathEntry)) {
        continue
    }

    $resolvedManifest = Resolve-RepoRelativePath $manifestPathEntry
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        throw "Manifest path not found: $manifestPathEntry"
    }
    if ([System.IO.Path]::GetFileName($resolvedManifest) -ne "manifest.json") {
        throw "Manifest path must point to a manifest.json file: $manifestPathEntry"
    }

    Add-RowsFromManifest -ManifestPath $resolvedManifest -Rows $rows -ActorRuntimePolicy $actorRuntimePolicy
}

foreach ($inputPath in @($allInputPaths)) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        continue
    }
    Add-RowsFromPath -InputPath $inputPath -Rows $rows -ActorRuntimePolicy $actorRuntimePolicy
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
    New-Item -ItemType File -Path $resolvedOutput -Force | Out-Null
    foreach ($row in @($rows.ToArray())) {
        ($row | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No actor runtime warning rows found."
}
else {
    @($rows.ToArray()) |
        Select-Object worldId, status, formId, actorName, modelKfCount, idleAnimationMissingCount, registeredCharacterController, @{ Name = "failureClasses"; Expression = { @($_.failureClasses) -join "," } }, log |
        Format-Table -AutoSize
}

if (-not $NoWrite) {
    Write-Host "Wrote actor runtime warning ledger: $OutputPath"
}
