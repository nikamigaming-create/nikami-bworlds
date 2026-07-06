param(
    [string[]]$WorldId = @(),
    [string]$SeedPath = "catalog/world-walker.seed.json",
    [string]$StartsPath = "catalog/flat-world-proof-starts.json",
    [string]$BinaryRoot = "",
    [string]$ProofRoot = "proof/flat-world-screenshots",
    [int]$RunSeconds = 0,
    [string]$ScreenshotFrames = "",
    [string]$StartCellOverride = "",
    [int]$WindowCaptureSeconds = 0,
    [int]$TelemetryInterval = 30,
    [int]$RefTelemetryLimit = 2000,
    [int]$Esm4GridRadius = -1,
    [switch]$NoTelemetry,
    [switch]$AllowBadScreenshots,
    [switch]$ShowGui,
    [switch]$DryRun,
    [switch]$KeepRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

function Convert-ToForwardSlash([string]$Path) {
    return ($Path -replace "\\", "/")
}

function Quote-CommandArg([string]$Arg) {
    if ($Arg -match '[\s"]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-ProcessEnvValue([string]$Name, $Value) {
    if ($null -eq $Value) {
        [Environment]::SetEnvironmentVariable($Name, $null, "Process")
        return
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        [Environment]::SetEnvironmentVariable($Name, $null, "Process")
        return
    }

    [Environment]::SetEnvironmentVariable($Name, $text, "Process")
}

function New-ProofRunConfig($World, [string]$WorldRunDir, [string]$UserDataDir) {
    $sourceConfigDir = [string]$World.profileDirectory
    if ([string]::IsNullOrWhiteSpace($sourceConfigDir) -or -not (Test-Path -LiteralPath $sourceConfigDir)) {
        throw "$($World.id): missing generated profile directory $sourceConfigDir"
    }

    $runConfigDir = Join-Path $WorldRunDir "config"
    $dataLocalDir = Join-Path $UserDataDir "data"
    New-Item -ItemType Directory -Force -Path $runConfigDir, $UserDataDir, $dataLocalDir | Out-Null

    foreach ($name in @("openmw.cfg", "settings.cfg", "shaders.yaml")) {
        $source = Join-Path $sourceConfigDir $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $runConfigDir $name) -Force
        }
    }

    $cfgPath = Join-Path $runConfigDir "openmw.cfg"
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        throw "$($World.id): copied proof config is missing openmw.cfg"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $hasReplaceDataLocal = $false
    foreach ($line in Get-Content -LiteralPath $cfgPath) {
        if ($line -match '^\s*replace\s*=\s*data-local\s*$') {
            $hasReplaceDataLocal = $true
        }
        if ($line -match '^\s*(user-data|data-local)\s*=') {
            continue
        }
        $lines.Add($line)
    }
    if (-not $hasReplaceDataLocal) {
        $insertAt = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*replace\s*=') {
                $insertAt = $i + 1
            }
        }
        $lines.Insert($insertAt, "replace=data-local")
    }
    $lines.Add("")
    $lines.Add("user-data=$(Convert-ToForwardSlash $UserDataDir)")
    $lines.Add("data-local=$(Convert-ToForwardSlash $dataLocalDir)")
    Set-Content -LiteralPath $cfgPath -Value $lines -Encoding ASCII

    [pscustomobject][ordered]@{
        configDirectory = (Resolve-Path -LiteralPath $runConfigDir).Path
        dataLocalDirectory = (Resolve-Path -LiteralPath $dataLocalDir).Path
        openmwCfg = (Resolve-Path -LiteralPath $cfgPath).Path
    }
}

function Copy-LatestScreenshot([string]$ScreenshotDir, [string]$DestinationDir, [string]$WorldId) {
    if (-not (Test-Path -LiteralPath $ScreenshotDir)) {
        return $null
    }
    $shot = Get-ChildItem -LiteralPath $ScreenshotDir -File -Filter "screenshot*.png" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $shot) {
        return $null
    }
    $destination = Join-Path $DestinationDir "$WorldId.png"
    Copy-Item -LiteralPath $shot.FullName -Destination $destination -Force
    return (Resolve-Path -LiteralPath $destination).Path
}

function Ensure-DrawingAssembly {
    Add-Type -AssemblyName System.Drawing
}

function Get-ScreenshotQuality([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    Ensure-DrawingAssembly
    $bitmap = New-Object System.Drawing.Bitmap($Path)
    try {
        $width = $bitmap.Width
        $height = $bitmap.Height
        if ($width -le 0 -or $height -le 0) {
            return [pscustomobject][ordered]@{
                width = $width
                height = $height
                sampledPixels = 0
                acceptable = $false
                reasons = @("empty image")
            }
        }

        $targetSamples = 30000.0
        $step = [Math]::Max(1, [int][Math]::Floor([Math]::Sqrt(($width * $height) / $targetSamples)))
        $sampled = 0
        $brightnessSum = 0.0
        $brightnessSquaredSum = 0.0
        $dark = 0
        $magenta = 0
        $purple = 0
        $brightLowSaturation = 0
        $blueSkyLike = 0
        $nearWhite = 0
        $skyOrVoid = 0
        $worldSignal = 0

        for ($y = 0; $y -lt $height; $y += $step) {
            for ($x = 0; $x -lt $width; $x += $step) {
                $pixel = $bitmap.GetPixel($x, $y)
                $brightness = (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
                $maxChannel = [Math]::Max($pixel.R, [Math]::Max($pixel.G, $pixel.B))
                $minChannel = [Math]::Min($pixel.R, [Math]::Min($pixel.G, $pixel.B))
                $channelSpread = $maxChannel - $minChannel
                $brightnessSum += $brightness
                $brightnessSquaredSum += ($brightness * $brightness)
                $sampled++

                if ($brightness -lt 20) {
                    $dark++
                }
                $isMagenta = ($pixel.R -gt 180 -and $pixel.B -gt 180 -and $pixel.G -lt 110 -and ($pixel.R - $pixel.G) -gt 70 -and ($pixel.B - $pixel.G) -gt 70)
                $isPurple = ($pixel.R -gt 110 -and $pixel.B -gt 130 -and $pixel.G -lt 105 -and ($pixel.B - $pixel.G) -gt 45)
                $isBrightLowSaturation = ($brightness -gt 145 -and $channelSpread -lt 45)
                $isBlueSkyLike = ($brightness -gt 80 -and $pixel.B -gt ($pixel.R + 20) -and $pixel.B -gt ($pixel.G + 15))
                $isNearWhite = ($brightness -gt 220 -and $channelSpread -lt 38)
                $isSkyOrVoid = ($isNearWhite -or ($isBlueSkyLike -and $brightness -gt 150))

                if ($isMagenta) {
                    $magenta++
                }
                if ($isPurple) {
                    $purple++
                }
                if ($isBrightLowSaturation) {
                    $brightLowSaturation++
                }
                if ($isBlueSkyLike) {
                    $blueSkyLike++
                }
                if ($isNearWhite) {
                    $nearWhite++
                }
                if ($isSkyOrVoid) {
                    $skyOrVoid++
                }
                elseif ($brightness -gt 25 -and -not $isMagenta -and -not $isPurple) {
                    $worldSignal++
                }
            }
        }

        if ($sampled -le 0) {
            return [pscustomobject][ordered]@{
                width = $width
                height = $height
                sampledPixels = 0
                acceptable = $false
                reasons = @("no sampled pixels")
            }
        }

        $mean = $brightnessSum / $sampled
        $variance = [Math]::Max(0.0, ($brightnessSquaredSum / $sampled) - ($mean * $mean))
        $stddev = [Math]::Sqrt($variance)
        $darkRatio = $dark / $sampled
        $magentaRatio = $magenta / $sampled
        $purpleRatio = $purple / $sampled
        $brightLowSaturationRatio = $brightLowSaturation / $sampled
        $blueSkyLikeRatio = $blueSkyLike / $sampled
        $nearWhiteRatio = $nearWhite / $sampled
        $skyOrVoidRatio = $skyOrVoid / $sampled
        $worldSignalRatio = $worldSignal / $sampled
        $reasons = New-Object System.Collections.Generic.List[string]

        if ($mean -lt 18 -or $darkRatio -gt 0.92) {
            $reasons.Add("too dark or blank")
        }
        if ($stddev -lt 4 -and $mean -lt 35) {
            $reasons.Add("low-variance loading/blank frame")
        }
        if ($magentaRatio -gt 0.005 -or $purpleRatio -gt 0.04) {
            $reasons.Add("purple/magenta fallback pixels detected")
        }
        if ($brightLowSaturationRatio -gt 0.68 -and $stddev -lt 55) {
            $reasons.Add("large bright low-saturation fallback/void surface")
        }
        if ($blueSkyLikeRatio -gt 0.8) {
            $reasons.Add("mostly sky/blue void")
        }
        if ($nearWhiteRatio -gt 0.65) {
            $reasons.Add("mostly near-white frame")
        }
        if ($skyOrVoidRatio -gt 0.72) {
            $reasons.Add("sky/void dominates frame")
        }
        if ($worldSignalRatio -lt 0.18) {
            $reasons.Add("too little non-void world signal")
        }
        if ($mean -gt 210 -and $stddev -lt 25 -and $skyOrVoidRatio -gt 0.55) {
            $reasons.Add("washed-out low-detail frame")
        }

        [pscustomobject][ordered]@{
            width = $width
            height = $height
            sampledPixels = $sampled
            meanBrightness = [Math]::Round($mean, 2)
            brightnessStdDev = [Math]::Round($stddev, 2)
            darkRatio = [Math]::Round($darkRatio, 4)
            magentaRatio = [Math]::Round($magentaRatio, 4)
            purpleRatio = [Math]::Round($purpleRatio, 4)
            brightLowSaturationRatio = [Math]::Round($brightLowSaturationRatio, 4)
            blueSkyLikeRatio = [Math]::Round($blueSkyLikeRatio, 4)
            nearWhiteRatio = [Math]::Round($nearWhiteRatio, 4)
            skyOrVoidRatio = [Math]::Round($skyOrVoidRatio, 4)
            worldSignalRatio = [Math]::Round($worldSignalRatio, 4)
            acceptable = ($reasons.Count -eq 0)
            reasons = @($reasons)
        }
    }
    finally {
        $bitmap.Dispose()
    }
}

function Get-ProofLogSummary([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $specs = @(
        [pscustomobject]@{ Name = "renderFailures"; Pattern = "failed to render|failed to load|Error loading|cannot load" },
        [pscustomobject]@{ Name = "missingAssets"; Pattern = "not found|missing|does not exist|cannot find|could not find" },
        [pscustomobject]@{ Name = "unsupportedAssets"; Pattern = "unsupported|not supported|unhandled" },
        [pscustomobject]@{ Name = "shaderIssues"; Pattern = "shader|purple|magenta|fallback" },
        [pscustomobject]@{ Name = "actorIssues"; Pattern = "actor|npc|creature|skeleton|bone|animation|rig" },
        [pscustomobject]@{ Name = "terrainIssues"; Pattern = "World viewer terrain:|LandTexture not found|missing ESM4 LTEX|missing ESM4 LTEX diffuse" },
        [pscustomobject]@{ Name = "viewerTelemetry"; Pattern = "World viewer telemetry:|World viewer ref:|World viewer cell:|World viewer ray:|World viewer actor ledger:" }
    )

    $categories = [ordered]@{}
    foreach ($spec in $specs) {
        $categories[$spec.Name] = [ordered]@{
            count = 0
            examples = New-Object System.Collections.Generic.List[string]
        }
    }

    $lineCount = 0
    $warningCount = 0
    $errorCount = 0
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        $lineCount++
        if ($line -match "\bWarning\b|WARN|warning:") {
            $warningCount++
        }
        if ($line -match "\bError\b|ERROR|error:|failed") {
            $errorCount++
        }

        foreach ($spec in $specs) {
            if ($line -match $spec.Pattern) {
                $entry = $categories[$spec.Name]
                $entry.count++
                if ($entry.examples.Count -lt 20) {
                    $entry.examples.Add($line)
                }
            }
        }
    }

    $normalized = [ordered]@{}
    foreach ($spec in $specs) {
        $entry = $categories[$spec.Name]
        $normalized[$spec.Name] = [pscustomobject][ordered]@{
            count = $entry.count
            examples = @($entry.examples)
        }
    }

    [pscustomobject][ordered]@{
        totalLines = $lineCount
        warnings = $warningCount
        errors = $errorCount
        categories = $normalized
    }
}

function Convert-WorldViewerTelemetryValue([string]$Value) {
    if ($null -eq $Value) {
        return $null
    }

    $text = $Value.Trim()
    if ($text.Length -ge 2 -and $text.StartsWith('"') -and $text.EndsWith('"')) {
        return $text.Substring(1, $text.Length - 2)
    }
    if ($text.Length -ge 2 -and $text.StartsWith('(') -and $text.EndsWith(')')) {
        return $text
    }
    if ($text -eq '<none>') {
        return $text
    }
    if ($text -match '^0x[0-9a-fA-F]+$') {
        return $text
    }

    $intValue = 0
    if ([int]::TryParse($text, [ref]$intValue)) {
        return $intValue
    }

    $doubleValue = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue)) {
        return $doubleValue
    }

    return $text
}

function Convert-WorldViewerFlag($Value) {
    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return $Value
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return ([double]$Value) -ne 0.0
    }

    $text = ([string]$Value).Trim()
    return -not ([string]::IsNullOrWhiteSpace($text) -or $text -eq "0" -or $text -ieq "false" -or $text -ieq "no" -or $text -ieq "off")
}

function Convert-WorldViewerInt($Value) {
    if ($null -eq $Value) {
        return 0
    }
    $intValue = 0
    if ([int]::TryParse(([string]$Value), [ref]$intValue)) {
        return $intValue
    }
    return 0
}

function Convert-WorldViewerDouble($Value) {
    if ($null -eq $Value) {
        return 0.0
    }
    $doubleValue = 0.0
    if ([double]::TryParse(([string]$Value), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$doubleValue)) {
        return $doubleValue
    }
    return 0.0
}

function Parse-WorldViewerKeyValues([string]$Text) {
    $values = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]$values
    }

    $matches = [regex]::Matches($Text, '([A-Za-z][A-Za-z0-9_]*)=("[^"]*"|\([^)]*\)|0x[0-9a-fA-F]+|[^\s]+)')
    foreach ($match in $matches) {
        $values[$match.Groups[1].Value] = Convert-WorldViewerTelemetryValue $match.Groups[2].Value
    }
    return [pscustomobject]$values
}

function Get-WorldViewerTelemetrySummary([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $cells = New-Object System.Collections.Generic.List[object]
    $rays = New-Object System.Collections.Generic.List[object]
    $actorLedger = New-Object System.Collections.Generic.List[object]
    $problemRefs = New-Object System.Collections.Generic.List[object]
    $refsByType = [ordered]@{}
    $rayKinds = [ordered]@{}
    $latestTelemetry = $null
    $refDumpTruncated = $null

    $cellRefs = 0
    $cellEnabled = 0
    $cellRendered = 0
    $cellMissingRenderNode = 0
    $cellActors = 0
    $cellRenderedActors = 0
    $cellDoors = 0
    $cellDeleted = 0
    $loggedRefs = 0
    $loggedRenderedRefs = 0
    $loggedActorRefs = 0
    $loggedRenderedActorRefs = 0
    $proxyActorRefs = 0
    $proxyTposeRefs = 0
    $proxyAnimatedRefs = 0
    $nativeActorLedgerEvents = 0
    $nativeActorRenderBegins = 0
    $nativeActorRenderEnds = 0
    $nativeActorCustomData = 0
    $nativeActorRootBegins = 0
    $nativeActorRootEnds = 0
    $nativeActorRootExceptions = 0
    $nativeActorModelFallbacks = 0
    $nativeActorPartsRequested = 0
    $nativeActorPartsTemplated = 0
    $nativeActorPartsAttached = 0
    $nativeActorPartsMissing = 0
    $nativeActorTemplateExceptions = 0
    $nativeActorAnimSources = 0
    $nativeActorAnimSourcesBound = 0
    $nativeActorControllerSources = 0
    $nativeActorControllersBound = 0
    $nativeActorControllersTotal = 0
    $nativeActorControllerZeroSources = 0
    $rayHits = 0
    $groundRayHits = 0
    $centerRenderHits = 0
    $actorRayHits = 0
    $actorRayActorHits = 0

    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        $telemetryIndex = $line.IndexOf("World viewer telemetry:")
        if ($telemetryIndex -ge 0) {
            $body = $line.Substring($telemetryIndex + "World viewer telemetry:".Length).Trim()
            if ($body -match '^ref dump truncated') {
                $refDumpTruncated = Parse-WorldViewerKeyValues $body
            }
            elseif ($body -match '\bframe=') {
                $latestTelemetry = Parse-WorldViewerKeyValues $body
            }
            continue
        }

        $cellIndex = $line.IndexOf("World viewer cell:")
        if ($cellIndex -ge 0) {
            $cell = Parse-WorldViewerKeyValues ($line.Substring($cellIndex + "World viewer cell:".Length).Trim())
            $cellRefs += Convert-WorldViewerInt (Get-PropertyValue $cell "refs")
            $cellEnabled += Convert-WorldViewerInt (Get-PropertyValue $cell "enabled")
            $cellRendered += Convert-WorldViewerInt (Get-PropertyValue $cell "rendered")
            $cellMissingRenderNode += Convert-WorldViewerInt (Get-PropertyValue $cell "missingRenderNode")
            $cellActors += Convert-WorldViewerInt (Get-PropertyValue $cell "actors")
            $cellRenderedActors += Convert-WorldViewerInt (Get-PropertyValue $cell "renderedActors")
            $cellDoors += Convert-WorldViewerInt (Get-PropertyValue $cell "doors")
            $cellDeleted += Convert-WorldViewerInt (Get-PropertyValue $cell "deleted")
            if ($cells.Count -lt 80) {
                $cells.Add($cell)
            }
            continue
        }

        $proxyIndex = $line.IndexOf("World viewer: inserted ESM4 actor proxy")
        if ($proxyIndex -ge 0) {
            $proxy = Parse-WorldViewerKeyValues ($line.Substring($proxyIndex + "World viewer: inserted ESM4 actor proxy".Length).Trim())
            $proxyActorRefs++
            if (([string](Get-PropertyValue $proxy "pose")) -eq "tpose") {
                $proxyTposeRefs++
            }
            if (Convert-WorldViewerFlag (Get-PropertyValue $proxy "animated")) {
                $proxyAnimatedRefs++
            }
            continue
        }

        $actorLedgerIndex = $line.IndexOf("World viewer actor ledger:")
        if ($actorLedgerIndex -ge 0) {
            $entry = Parse-WorldViewerKeyValues ($line.Substring($actorLedgerIndex + "World viewer actor ledger:".Length).Trim())
            $nativeActorLedgerEvents++
            $phaseValue = Get-PropertyValue $entry "phase"
            $phase = if ($null -ne $phaseValue) { [string]$phaseValue } else { "<unknown>" }
            switch ($phase) {
                "render-insert-begin" { $nativeActorRenderBegins++ }
                "render-insert-end" { $nativeActorRenderEnds++ }
                "npc-custom-data" { $nativeActorCustomData++ }
                "npc-root-begin" { $nativeActorRootBegins++ }
                "npc-root-end" { $nativeActorRootEnds++ }
                "npc-root-exception" { $nativeActorRootExceptions++ }
                "npc-model-fallback" { $nativeActorModelFallbacks++ }
                "part-request" { $nativeActorPartsRequested++ }
                "part-template" { $nativeActorPartsTemplated++ }
                "part-attached" { $nativeActorPartsAttached++ }
                "part-missing" { $nativeActorPartsMissing++ }
                "part-template-exception" { $nativeActorTemplateExceptions++ }
                "animation-source" {
                    $nativeActorAnimSources++
                    if (Convert-WorldViewerFlag (Get-PropertyValue $entry "bound")) {
                        $nativeActorAnimSourcesBound++
                    }
                }
            }
            if ($actorLedger.Count -lt 240) {
                $actorLedger.Add($entry)
            }
            continue
        }

        $controllerMatch = [regex]::Match($line, 'FNV/ESM4 diag: animation source (?<source>.+?) bound (?<bound>\d+)/(?<total>\d+) controller\(s\) to (?<base>.+?), missing (?<missing>\d+)')
        if ($controllerMatch.Success) {
            $boundControllers = [int]$controllerMatch.Groups["bound"].Value
            $totalControllers = [int]$controllerMatch.Groups["total"].Value
            $nativeActorControllerSources++
            $nativeActorControllersBound += $boundControllers
            $nativeActorControllersTotal += $totalControllers
            if ($totalControllers -gt 0 -and $boundControllers -eq 0) {
                $nativeActorControllerZeroSources++
            }
            if ($actorLedger.Count -lt 240) {
                $actorLedger.Add([pscustomobject][ordered]@{
                    phase = "animation-controller-bind"
                    source = $controllerMatch.Groups["source"].Value
                    skeleton = $controllerMatch.Groups["base"].Value
                    bound = $boundControllers
                    total = $totalControllers
                    missing = [int]$controllerMatch.Groups["missing"].Value
                })
            }
            continue
        }

        $refIndex = $line.IndexOf("World viewer ref:")
        if ($refIndex -ge 0) {
            $ref = Parse-WorldViewerKeyValues ($line.Substring($refIndex + "World viewer ref:".Length).Trim())
            $loggedRefs++
            $typeValue = Get-PropertyValue $ref "type"
            $typeName = if ($null -ne $typeValue) { [string]$typeValue } else { "<unknown>" }
            if (-not $refsByType.Contains($typeName)) {
                $refsByType[$typeName] = 0
            }
            $refsByType[$typeName]++

            $rendered = Convert-WorldViewerFlag (Get-PropertyValue $ref "rendered")
            $actor = Convert-WorldViewerFlag (Get-PropertyValue $ref "actor")
            if ($rendered) {
                $loggedRenderedRefs++
            }
            if ($actor) {
                $loggedActorRefs++
                if ($rendered) {
                    $loggedRenderedActorRefs++
                }
            }
            if ((-not $rendered -or ($actor -and -not $rendered)) -and $problemRefs.Count -lt 40) {
                $problemRefs.Add($ref)
            }
            continue
        }

        $rayIndex = $line.IndexOf("World viewer ray:")
        if ($rayIndex -ge 0) {
            $ray = Parse-WorldViewerKeyValues ($line.Substring($rayIndex + "World viewer ray:".Length).Trim())
            $kindValue = Get-PropertyValue $ray "kind"
            $kind = if ($null -ne $kindValue) { [string]$kindValue } else { "<unknown>" }
            if (-not $rayKinds.Contains($kind)) {
                $rayKinds[$kind] = 0
            }
            $rayKinds[$kind]++

            $hit = Convert-WorldViewerFlag (Get-PropertyValue $ray "hit")
            $actorHit = Convert-WorldViewerFlag (Get-PropertyValue $ray "actorHit")
            if ($hit) {
                $rayHits++
            }
            if ($hit -and ($kind -eq "playerGround" -or $kind -eq "cameraGround")) {
                $groundRayHits++
            }
            if ($hit -and $kind -eq "cameraCenterRender") {
                $centerRenderHits++
            }
            if ($hit -and ($kind -eq "cameraActorRender" -or $kind -eq "actorCrossPhysics")) {
                $actorRayHits++
            }
            if ($actorHit -and ($kind -eq "cameraActorRender" -or $kind -eq "actorCrossPhysics")) {
                $actorRayActorHits++
            }
            if ($rays.Count -lt 120) {
                $rays.Add($ray)
            }
            continue
        }
    }

    [pscustomobject][ordered]@{
        latestTelemetry = $latestTelemetry
        cellCount = $cells.Count
        cellRefs = $cellRefs
        cellEnabled = $cellEnabled
        cellRendered = $cellRendered
        cellMissingRenderNode = $cellMissingRenderNode
        cellActors = $cellActors
        cellRenderedActors = $cellRenderedActors
        cellDoors = $cellDoors
        cellDeleted = $cellDeleted
        loggedRefs = $loggedRefs
        loggedRenderedRefs = $loggedRenderedRefs
        loggedActorRefs = $loggedActorRefs
        loggedRenderedActorRefs = $loggedRenderedActorRefs
        proxyActorRefs = $proxyActorRefs
        proxyTposeRefs = $proxyTposeRefs
        proxyAnimatedRefs = $proxyAnimatedRefs
        nativeActorLedgerEvents = $nativeActorLedgerEvents
        nativeActorRenderBegins = $nativeActorRenderBegins
        nativeActorRenderEnds = $nativeActorRenderEnds
        nativeActorCustomData = $nativeActorCustomData
        nativeActorRootBegins = $nativeActorRootBegins
        nativeActorRootEnds = $nativeActorRootEnds
        nativeActorRootExceptions = $nativeActorRootExceptions
        nativeActorModelFallbacks = $nativeActorModelFallbacks
        nativeActorPartsRequested = $nativeActorPartsRequested
        nativeActorPartsTemplated = $nativeActorPartsTemplated
        nativeActorPartsAttached = $nativeActorPartsAttached
        nativeActorPartsMissing = $nativeActorPartsMissing
        nativeActorTemplateExceptions = $nativeActorTemplateExceptions
        nativeActorAnimSources = $nativeActorAnimSources
        nativeActorAnimSourcesBound = $nativeActorAnimSourcesBound
        nativeActorControllerSources = $nativeActorControllerSources
        nativeActorControllersBound = $nativeActorControllersBound
        nativeActorControllersTotal = $nativeActorControllersTotal
        nativeActorControllerZeroSources = $nativeActorControllerZeroSources
        refsByType = [pscustomobject]$refsByType
        refDumpTruncated = $refDumpTruncated
        rayCount = $rays.Count
        rayHits = $rayHits
        groundRayHits = $groundRayHits
        centerRenderHits = $centerRenderHits
        actorRayHits = $actorRayHits
        actorRayActorHits = $actorRayActorHits
        rayKinds = [pscustomobject]$rayKinds
        cells = @($cells.ToArray())
        rays = @($rays.ToArray())
        actorLedger = @($actorLedger.ToArray())
        problemRefs = @($problemRefs.ToArray())
    }
}

function Get-OpenMwCrashDumpInfo([string[]]$Roots, [datetime]$Since) {
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -File -Filter "openmw-crash*.dmp" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Since } |
            ForEach-Object { $candidates.Add($_) }
    }

    $dump = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $dump) {
        return $null
    }

    [pscustomobject][ordered]@{
        path = Convert-ToForwardSlash -Path $dump.FullName
        length = $dump.Length
        lastWriteTime = $dump.LastWriteTime.ToString("o")
    }
}

foreach ($path in @($SeedPath, $StartsPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required input: $path"
    }
}

$BinaryRoot = Resolve-NikamiPath `
    -ParameterValue $BinaryRoot `
    -EnvName "NIKAMI_OPENMW_BINARY_ROOT" `
    -ConfigName "openmwBinaryRoot" `
    -Required `
    -Description "OpenMW binary root"

$binary = Join-Path $BinaryRoot "openmw.exe"
if (-not (Test-Path -LiteralPath $binary)) {
    throw "Missing existing flat OpenMW binary: $binary"
}

$seed = Get-Content -LiteralPath $SeedPath -Raw | ConvertFrom-Json
$starts = Get-Content -LiteralPath $StartsPath -Raw | ConvertFrom-Json

$selected = @($seed.worlds | Where-Object { $_.readyForWorldWalker -eq $true })
if ($WorldId.Count -gt 0) {
    $wanted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $WorldId) {
        [void]$wanted.Add($id)
    }
    $selected = @($selected | Where-Object { $wanted.Contains($_.id) })
}
if ($selected.Count -eq 0) {
    throw "No ready worlds selected."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$proofDir = Join-Path $ProofRoot $stamp
$cwdPath = (Get-Location).Path
$absProofDir = Join-Path $cwdPath $proofDir
$screensDir = Join-Path $absProofDir "screenshots"
$logsDir = Join-Path $absProofDir "logs"
New-Item -ItemType Directory -Force -Path $screensDir, $logsDir | Out-Null

$defaultRunSeconds = [int]$starts.defaults.runSeconds
if ($RunSeconds -le 0) {
    $RunSeconds = $defaultRunSeconds
}
if ([string]::IsNullOrWhiteSpace($ScreenshotFrames)) {
    $ScreenshotFrames = [string]$starts.defaults.screenshotFrames
}
$defaultExtraArgs = @($starts.defaults.extraArgs)

$viewerStartEnvNames = @(
    "OPENMW_WORLD_VIEWER_START_POS_X",
    "OPENMW_WORLD_VIEWER_START_POS_Y",
    "OPENMW_WORLD_VIEWER_START_POS_Z",
    "OPENMW_WORLD_VIEWER_START_ROT_X",
    "OPENMW_WORLD_VIEWER_START_ROT_Y",
    "OPENMW_WORLD_VIEWER_START_ROT_Z",
    "OPENMW_WORLD_VIEWER_START_WORLDSPACE",
    "OPENMW_WORLD_VIEWER_START_GRID_X",
    "OPENMW_WORLD_VIEWER_START_GRID_Y",
    "OPENMW_WORLD_VIEWER_START_DRY",
    "OPENMW_WORLD_VIEWER_START_CAMERA_MODE",
    "OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE",
    "OPENMW_WORLD_VIEWER_START_CAMERA_PITCH",
    "OPENMW_WORLD_VIEWER_START_CAMERA_YAW",
    "OPENMW_WORLD_VIEWER_START_CAMERA_POS_X",
    "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Y",
    "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Z",
    "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_X",
    "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Y",
    "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Z"
)

$viewerProofEnvNames = @(
    "OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG",
    "OPENMW_WORLD_VIEWER_TELEMETRY",
    "OPENMW_WORLD_VIEWER_TELEMETRY_INTERVAL",
    "OPENMW_WORLD_VIEWER_REF_TELEMETRY",
    "OPENMW_WORLD_VIEWER_REF_TELEMETRY_LIMIT",
    "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY",
    "OPENMW_WORLD_VIEWER_SKIP_MISSING_ACTOR_PARTS",
    "OPENMW_WORLD_VIEWER_RAY_TELEMETRY",
    "OPENMW_WORLD_VIEWER_RAY_DISTANCE",
    "OPENMW_WORLD_VIEWER_ACTOR_RAY_LIMIT",
    "OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS",
    "OPENMW_WORLD_VIEWER_NEUTRAL_MISSING_TEXTURES",
    "OPENMW_WORLD_VIEWER_DISABLE_ESM4_ACTORS",
    "OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXIES",
    "OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXY_ANIMATE",
    "OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS",
    "OPENMW_WORLD_VIEWER_REQUIRE_CAMERA_SETTLED"
)

$previousEnv = @{}
foreach ($name in @("OPENMW_PROOF_SCREENSHOT_FRAME", "OPENMW_FNV_BOOTSTRAP_HOUR", "OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI", "OPENMW_PROOF_HIDE_GUI") + $viewerStartEnvNames + $viewerProofEnvNames) {
    $previousEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

$results = New-Object System.Collections.Generic.List[object]

try {
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SUPPRESS_FATAL_DIALOG", "1", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_PROOF_SCREENSHOT_FRAME", $ScreenshotFrames, "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_FNV_BOOTSTRAP_HOUR", "12", "Process")
    [Environment]::SetEnvironmentVariable("OPENMW_PROOF_FORCE_CLEAR_LOADING_GUI", "1", "Process")
    if ($ShowGui) {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_HIDE_GUI", $null, "Process")
    }
    else {
        [Environment]::SetEnvironmentVariable("OPENMW_PROOF_HIDE_GUI", "1", "Process")
    }
    if (-not $NoTelemetry) {
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_TELEMETRY_INTERVAL", [string]$TelemetryInterval, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_REF_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_REF_TELEMETRY_LIMIT", [string]$RefTelemetryLimit, "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_SKIP_MISSING_ACTOR_PARTS", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_RAY_TELEMETRY", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_RAY_DISTANCE", "200000", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ACTOR_RAY_LIMIT", "8", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS", "1", "Process")
        [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_NEUTRAL_MISSING_TEXTURES", "1", "Process")
    }
    else {
        foreach ($name in @("OPENMW_WORLD_VIEWER_TELEMETRY", "OPENMW_WORLD_VIEWER_REF_TELEMETRY", "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY", "OPENMW_WORLD_VIEWER_SKIP_MISSING_ACTOR_PARTS", "OPENMW_WORLD_VIEWER_RAY_TELEMETRY", "OPENMW_WORLD_VIEWER_HIDE_DIAGNOSTIC_MODELS", "OPENMW_WORLD_VIEWER_NEUTRAL_MISSING_TEXTURES")) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
    }
    [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_REQUIRE_CAMERA_SETTLED", "1", "Process")

    foreach ($world in $selected) {
        foreach ($name in $viewerStartEnvNames) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }

        $start = Get-PropertyValue $starts.worlds $world.id
        $startCell = if ($null -ne $start) { [string]$start.startCell } else { "" }
        $label = if ($null -ne $start) { [string]$start.label } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($StartCellOverride)) {
            if ($selected.Count -ne 1) {
                throw "-StartCellOverride can only be used when exactly one -WorldId is selected."
            }
            $startCell = $StartCellOverride
            $label = "manual probe"
        }

        $worldGridRadius = $Esm4GridRadius
        if ($worldGridRadius -lt 0) {
            $startGridRadius = Get-PropertyValue $start "esm4GridRadius"
            $defaultGridRadius = Get-PropertyValue $starts.defaults "esm4GridRadius"
            if ($null -ne $startGridRadius) {
                $worldGridRadius = [int]$startGridRadius
            }
            elseif ($null -ne $defaultGridRadius) {
                $worldGridRadius = [int]$defaultGridRadius
            }
        }
        if ($worldGridRadius -ge 0) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS", [string]$worldGridRadius, "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_GRID_RADIUS", $null, "Process")
        }
        $disableEsm4Actors = ((Get-PropertyValue $start "disableEsm4Actors") -eq $true)
        if ($disableEsm4Actors) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_DISABLE_ESM4_ACTORS", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_DISABLE_ESM4_ACTORS", $null, "Process")
        }
        $esm4ActorProxies = ((Get-PropertyValue $start "esm4ActorProxies") -eq $true)
        if ($esm4ActorProxies) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXIES", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXIES", $null, "Process")
        }
        $esm4ActorProxyAnimate = ((Get-PropertyValue $start "esm4ActorProxyAnimate") -eq $true)
        if ($esm4ActorProxies -and $esm4ActorProxyAnimate) {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXY_ANIMATE", "1", "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable("OPENMW_WORLD_VIEWER_ESM4_ACTOR_PROXY_ANIMATE", $null, "Process")
        }

        $worldRunDir = Join-Path $absProofDir $world.id
        $userDataDir = Join-Path $worldRunDir "userdata"
        $stdoutLog = Join-Path $logsDir "$($world.id).stdout.log"
        $stderrLog = Join-Path $logsDir "$($world.id).stderr.log"
        $windowCapture = Join-Path $screensDir "$($world.id).window.png"
        New-Item -ItemType Directory -Force -Path $worldRunDir | Out-Null
        $runConfig = New-ProofRunConfig -World $world -WorldRunDir $worldRunDir -UserDataDir $userDataDir
        $resourcesDir = Join-Path $BinaryRoot "resources"

        $argsList = New-Object System.Collections.Generic.List[string]
        $argsList.Add("--replace")
        $argsList.Add("config")
        $argsList.Add("--config")
        $argsList.Add($runConfig.configDirectory)
        $argsList.Add("--user-data")
        $argsList.Add($userDataDir)
        $argsList.Add("--data-local")
        $argsList.Add($runConfig.dataLocalDirectory)
        if (Test-Path -LiteralPath $resourcesDir) {
            $argsList.Add("--resources")
            $argsList.Add($resourcesDir)
        }
        $argsList.Add("--skip-menu")
        if (-not [string]::IsNullOrWhiteSpace($startCell)) {
            $argsList.Add("--start")
            $argsList.Add($startCell)
        }
        foreach ($arg in $defaultExtraArgs) {
            if (-not [string]::IsNullOrWhiteSpace([string]$arg)) {
                $argsList.Add([string]$arg)
            }
        }

        $argumentLine = ($argsList.ToArray() | ForEach-Object { Quote-CommandArg $_ }) -join " "
        $commandLine = "$(Quote-CommandArg $binary) $argumentLine"
        Write-Host ""
        Write-Host "[$($world.id)] $($world.displayName)"
        Write-Host "Start: $startCell"
        Write-Host "Command: $commandLine"

        $status = "not-run"
        $exitCode = $null
        $screenshot = $null
        $windowScreenshot = $null
        $candidateScreenshots = New-Object System.Collections.Generic.List[object]
        $seenNativeScreenshots = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $nativeScreenshotDir = Join-Path $userDataDir "screenshots"
        $profileLog = Join-Path $runConfig.configDirectory "openmw.log"
        $userDataLog = Join-Path $userDataDir "openmw.log"
        $copiedOpenMwLog = Join-Path $logsDir "$($world.id).openmw.log"
        $notes = New-Object System.Collections.Generic.List[string]
        $screenshotQuality = $null
        $logSummary = $null
        $worldViewerTelemetry = $null
        $crashDump = $null

        $anchor = Get-PropertyValue $start "anchor"
        if ($null -ne $anchor) {
            $position = Get-PropertyValue $anchor "position"
            $rotation = Get-PropertyValue $anchor "rotation"
            $camera = Get-PropertyValue $anchor "camera"

            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_POS_X" (Get-PropertyValue $position "x")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_POS_Y" (Get-PropertyValue $position "y")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_POS_Z" (Get-PropertyValue $position "z")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_ROT_X" (Get-PropertyValue $rotation "x")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_ROT_Y" (Get-PropertyValue $rotation "y")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_ROT_Z" (Get-PropertyValue $rotation "z")
            $exteriorLocation = Get-PropertyValue $anchor "exteriorLocation"
            if ($null -ne $exteriorLocation) {
                $grid = Get-PropertyValue $exteriorLocation "grid"
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_WORLDSPACE" (Get-PropertyValue $exteriorLocation "worldspace")
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_GRID_X" (Get-PropertyValue $grid "x")
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_GRID_Y" (Get-PropertyValue $grid "y")
            }
            if ((Get-PropertyValue $anchor "dry") -ne $false) {
                Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_DRY" "1"
            }
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_MODE" (Get-PropertyValue $camera "mode")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_DISTANCE" (Get-PropertyValue $camera "distance")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_PITCH" (Get-PropertyValue $camera "pitch")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_YAW" (Get-PropertyValue $camera "yaw")
            $cameraPosition = Get-PropertyValue $camera "position"
            $cameraTarget = Get-PropertyValue $camera "target"
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_POS_X" (Get-PropertyValue $cameraPosition "x")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Y" (Get-PropertyValue $cameraPosition "y")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_POS_Z" (Get-PropertyValue $cameraPosition "z")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_X" (Get-PropertyValue $cameraTarget "x")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Y" (Get-PropertyValue $cameraTarget "y")
            Set-ProcessEnvValue "OPENMW_WORLD_VIEWER_START_CAMERA_TARGET_Z" (Get-PropertyValue $cameraTarget "z")
            $notes.Add("used explicit local start anchor")
        }

        if ($DryRun) {
            $status = "dry-run"
        }
        else {
            $worldStartedAt = Get-Date
            $process = Start-Process -FilePath $binary -ArgumentList $argumentLine -WorkingDirectory (Split-Path -Parent $binary) -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
            if (-not $KeepRunning) {
                $captureDelay = 0
                if ($WindowCaptureSeconds -gt 0) {
                    $notes.Add("window capture disabled; native OpenMW screenshot required")
                }

                $deadline = (Get-Date).AddSeconds([Math]::Max(1, $RunSeconds - $captureDelay))
                $sawNativeScreenshot = $false
                $acceptedNativeScreenshot = $false
                while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
                    if (Test-Path -LiteralPath $nativeScreenshotDir) {
                        $shots = @(Get-ChildItem -LiteralPath $nativeScreenshotDir -File -Filter "screenshot*.png" -ErrorAction SilentlyContinue |
                            Where-Object { $_.LastWriteTime -ge $worldStartedAt.AddSeconds(-2) } |
                            Sort-Object LastWriteTime)
                        foreach ($shot in $shots) {
                            if (-not $seenNativeScreenshots.Add($shot.FullName)) {
                                continue
                            }
                            $sawNativeScreenshot = $true
                            Start-Sleep -Milliseconds 750
                            $candidateIndex = $candidateScreenshots.Count + 1
                            $candidatePath = Join-Path $screensDir ("{0}.candidate-{1:000}.png" -f $world.id, $candidateIndex)
                            Copy-Item -LiteralPath $shot.FullName -Destination $candidatePath -Force
                            $candidateQuality = Get-ScreenshotQuality -Path $candidatePath
                            $candidateAccepted = $AllowBadScreenshots -or ($null -ne $candidateQuality -and $candidateQuality.acceptable)
                            $candidateScreenshots.Add([pscustomobject][ordered]@{
                                path = (Convert-ToForwardSlash -Path $candidatePath)
                                capturedAt = $shot.LastWriteTime.ToString("o")
                                secondsAfterStart = [Math]::Round(($shot.LastWriteTime - $worldStartedAt).TotalSeconds, 1)
                                quality = $candidateQuality
                                accepted = [bool]$candidateAccepted
                            })
                            if ($candidateAccepted) {
                                $acceptedNativeScreenshot = $true
                                $screenshot = $candidatePath
                                $screenshotQuality = $candidateQuality
                                $notes.Add("accepted native screenshot candidate $candidateIndex after $([Math]::Round(((Get-Date) - $worldStartedAt).TotalSeconds, 1)) seconds")
                                break
                            }
                            elseif ($null -ne $candidateQuality) {
                                $notes.Add("rejected native screenshot candidate ${candidateIndex}: $($candidateQuality.reasons -join '; ')")
                            }
                        }
                        if ($acceptedNativeScreenshot) {
                            break
                        }
                    }
                    Start-Sleep -Milliseconds 500
                    $process.Refresh()
                }

                $process.Refresh()
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force
                    if ($acceptedNativeScreenshot) {
                        $notes.Add("stopped after accepted native screenshot")
                    }
                    elseif ($sawNativeScreenshot) {
                        $notes.Add("stopped after $RunSeconds seconds with only rejected native screenshots")
                    }
                    else {
                        $notes.Add("stopped after $RunSeconds seconds")
                    }
                }
                $process.Refresh()
                $exitCode = $process.ExitCode
            }
            else {
                $notes.Add("left running pid $($process.Id)")
            }

            Start-Sleep -Milliseconds 750
            if (-not $screenshot -and $candidateScreenshots.Count -gt 0) {
                $lastCandidate = $candidateScreenshots[$candidateScreenshots.Count - 1]
                $screenshot = $lastCandidate.path
                $screenshotQuality = $lastCandidate.quality
            }
            if (-not $screenshot) {
                $screenshot = Copy-LatestScreenshot -ScreenshotDir $nativeScreenshotDir -DestinationDir $screensDir -WorldId $world.id
            }
            if ($screenshot) {
                $status = "screenshot"
            }
            elseif ($windowScreenshot) {
                $destination = Join-Path $screensDir "$($world.id).png"
                Copy-Item -LiteralPath $windowScreenshot -Destination $destination -Force
                $screenshot = (Resolve-Path -LiteralPath $destination).Path
                $status = "window-screenshot"
            }
            else {
                $status = "no-screenshot"
                $notes.Add("no screenshot*.png found")
            }

            if (Test-Path -LiteralPath $profileLog) {
                Copy-Item -LiteralPath $profileLog -Destination $copiedOpenMwLog -Force
            }
            elseif (Test-Path -LiteralPath $userDataLog) {
                Copy-Item -LiteralPath $userDataLog -Destination $copiedOpenMwLog -Force
            }
            else {
                $notes.Add("no openmw.log found")
            }

            if ($screenshot -and $null -eq $screenshotQuality) {
                $screenshotQuality = Get-ScreenshotQuality -Path $screenshot
            }
            if ($screenshot) {
                if ($null -ne $screenshotQuality -and -not $screenshotQuality.acceptable -and -not $AllowBadScreenshots) {
                    $status = if ($status -eq "window-screenshot") { "rejected-window-screenshot" } else { "rejected-screenshot" }
                    $notes.Add("rejected screenshot quality: $($screenshotQuality.reasons -join '; ')")
                }
            }

            $logSummary = Get-ProofLogSummary -Path $copiedOpenMwLog
            $worldViewerTelemetry = Get-WorldViewerTelemetrySummary -Path $copiedOpenMwLog
            if ($null -ne $logSummary -and $null -ne $logSummary.categories.terrainIssues -and $logSummary.categories.terrainIssues.count -gt 0) {
                $notes.Add("Terrain issues: $($logSummary.categories.terrainIssues.count) logged fallback/lookup events")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.proxyActorRefs -gt 0) {
                $notes.Add("ESM4 actor proxy proof: $($worldViewerTelemetry.proxyActorRefs) proxy refs, $($worldViewerTelemetry.proxyTposeRefs) t-pose, $($worldViewerTelemetry.proxyAnimatedRefs) animated")
            }
            if ($null -ne $worldViewerTelemetry -and $worldViewerTelemetry.nativeActorLedgerEvents -gt 0) {
                $notes.Add("Native actor ledger: roots $($worldViewerTelemetry.nativeActorRootEnds)/$($worldViewerTelemetry.nativeActorRootBegins), parts $($worldViewerTelemetry.nativeActorPartsAttached)/$($worldViewerTelemetry.nativeActorPartsRequested), missing $($worldViewerTelemetry.nativeActorPartsMissing), templateErrors $($worldViewerTelemetry.nativeActorTemplateExceptions), animSources $($worldViewerTelemetry.nativeActorAnimSourcesBound)/$($worldViewerTelemetry.nativeActorAnimSources)")
                if ($worldViewerTelemetry.nativeActorModelFallbacks -gt 0) {
                    $notes.Add("Native actor model fallbacks: $($worldViewerTelemetry.nativeActorModelFallbacks)")
                }
                if ($worldViewerTelemetry.nativeActorControllerSources -gt 0) {
                    $notes.Add("Native actor controllers: $($worldViewerTelemetry.nativeActorControllersBound)/$($worldViewerTelemetry.nativeActorControllersTotal) bound across $($worldViewerTelemetry.nativeActorControllerSources) sources, zeroBoundSources $($worldViewerTelemetry.nativeActorControllerZeroSources)")
                }
                if ($worldViewerTelemetry.nativeActorRootExceptions -gt 0) {
                    $notes.Add("Native actor root exceptions: $($worldViewerTelemetry.nativeActorRootExceptions)")
                }
            }
            $crashDump = Get-OpenMwCrashDumpInfo -Roots @($runConfig.configDirectory, $userDataDir) -Since $worldStartedAt.AddSeconds(-2)
            if ($null -ne $crashDump) {
                $notes.Add("crash dump detected: $($crashDump.path)")
                if ($status -eq "no-screenshot") {
                    $status = "crash-dump-no-screenshot"
                }
            }

            if ($screenshot -and -not $NoTelemetry -and -not $AllowBadScreenshots -and ($status -eq "screenshot" -or $status -eq "window-screenshot")) {
                $telemetryRejectReasons = New-Object System.Collections.Generic.List[string]
                if ($null -eq $worldViewerTelemetry -or $null -eq $worldViewerTelemetry.latestTelemetry) {
                    $telemetryRejectReasons.Add("missing world viewer frame telemetry")
                }
                else {
                    if ($worldViewerTelemetry.cellRendered -le 0 -and $worldViewerTelemetry.loggedRenderedRefs -le 0) {
                        $telemetryRejectReasons.Add("telemetry found no rendered refs")
                    }
                    if ($worldViewerTelemetry.groundRayHits -le 0) {
                        $telemetryRejectReasons.Add("ground ray did not hit world/heightmap/water")
                    }
                    if ($worldViewerTelemetry.centerRenderHits -le 0) {
                        $telemetryRejectReasons.Add("center render ray hit nothing")
                    }
                    if ($worldViewerTelemetry.cellActors -gt 0 -and $worldViewerTelemetry.cellRenderedActors -le 0 -and -not $disableEsm4Actors) {
                        $telemetryRejectReasons.Add("actor-populated cell rendered zero actor nodes")
                    }
                    elseif ($worldViewerTelemetry.cellActors -gt 0 -and $worldViewerTelemetry.cellRenderedActors -le 0 -and $disableEsm4Actors) {
                        $notes.Add("ESM4 actor render probes skipped by world config quarantine")
                    }
                    if ($worldViewerTelemetry.cellRenderedActors -gt 0 -and $worldViewerTelemetry.actorRayActorHits -le 0 -and ($esm4ActorProxies -or $worldViewerTelemetry.nativeActorPartsAttached -gt 0)) {
                        $notes.Add("Actor render nodes exist; actor physics ray probes are diagnostic until actor collision is stabilized")
                    }
                    elseif ($worldViewerTelemetry.cellRenderedActors -gt 0 -and $worldViewerTelemetry.actorRayActorHits -le 0) {
                        $telemetryRejectReasons.Add("rendered actor nodes present but actor ray probes hit no actors")
                    }
                }

                if ($telemetryRejectReasons.Count -gt 0) {
                    $status = "rejected-telemetry-screenshot"
                    $notes.Add("rejected screenshot telemetry: $($telemetryRejectReasons -join '; ')")
                }
            }
        }

        $results.Add([pscustomobject][ordered]@{
            worldId = $world.id
            displayName = $world.displayName
            supportTier = $world.supportTier
            startCell = $startCell
            label = $label
            status = $status
            exitCode = $exitCode
            screenshot = if ($screenshot) { (Convert-ToForwardSlash -Path $screenshot) } else { $null }
            screenshotQuality = $screenshotQuality
            candidateScreenshots = @($candidateScreenshots.ToArray())
            windowScreenshot = if ($windowScreenshot) { (Convert-ToForwardSlash -Path $windowScreenshot) } else { $null }
            runDirectory = (Convert-ToForwardSlash -Path $worldRunDir)
            configDirectory = (Convert-ToForwardSlash -Path $runConfig.configDirectory)
            dataLocalDirectory = (Convert-ToForwardSlash -Path $runConfig.dataLocalDirectory)
            openmwLog = (Convert-ToForwardSlash -Path $copiedOpenMwLog)
            openmwLogSummary = $logSummary
            worldViewerTelemetry = $worldViewerTelemetry
            crashDump = $crashDump
            esm4GridRadius = $worldGridRadius
            processLog = (Convert-ToForwardSlash -Path $stdoutLog)
            processErrorLog = (Convert-ToForwardSlash -Path $stderrLog)
            command = $commandLine
            notes = @($notes)
        })
    }
}
finally {
    foreach ($entry in $previousEnv.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
    }
}

$manifest = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString("o")
    binary = (Convert-ToForwardSlash -Path $binary)
    runSeconds = $RunSeconds
    screenshotFrames = $ScreenshotFrames
    windowCaptureSeconds = $WindowCaptureSeconds
    telemetry = (-not $NoTelemetry)
    telemetryInterval = $TelemetryInterval
    esm4GridRadius = $Esm4GridRadius
    allowBadScreenshots = [bool]$AllowBadScreenshots
    showGui = [bool]$ShowGui
    proofDirectory = (Convert-ToForwardSlash -Path $absProofDir)
    results = @($results.ToArray())
}

$manifestPath = Join-Path $absProofDir "manifest.json"
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding ASCII

Write-Host ""
$results | Format-Table -AutoSize worldId, status, startCell, screenshot
Write-Host "Manifest: $manifestPath"
