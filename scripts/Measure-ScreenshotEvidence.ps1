param(
    [string[]]$Path = @(),
    [string[]]$ManifestPath = @(),
    [string]$ManifestRoot = "run/real-world-screenshots",
    [string]$OutputPath = "run/audit/screenshot-evidence.jsonl",
    [string]$PolicyPath = "catalog/screenshot-evidence-policy.json",
    [switch]$IncludeManifests,
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToForwardSlash([string]$Path) {
    return ($Path -replace "\\", "/")
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

function Test-TextListContains($Value, [string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }
    foreach ($entry in Get-TextArray $Value) {
        if ([string]::Equals($entry, $Text, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Add-UniqueTextToList([System.Collections.Generic.List[string]]$List, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if (-not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function Get-NullableInt($Value) {
    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return [int]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $null
    }
}

function Get-NullableBool($Value) {
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    if ([string]::Equals($text, "true", [StringComparison]::OrdinalIgnoreCase) -or $text -eq "1") {
        return $true
    }
    if ([string]::Equals($text, "false", [StringComparison]::OrdinalIgnoreCase) -or $text -eq "0") {
        return $false
    }

    return $null
}

function Merge-EvidenceStatus([string]$Current, [string]$Candidate) {
    if ([string]::IsNullOrWhiteSpace($Current)) {
        $Current = "pass"
    }
    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $Current
    }
    if ($Current -eq "fail" -or $Candidate -eq "fail") {
        return "fail"
    }
    if ($Current -eq "questionable" -or $Candidate -eq "questionable") {
        return "questionable"
    }
    return $Candidate
}

$script:EvidencePolicy = [pscustomobject][ordered]@{
    defaultMissingImageFailureClass = "missing-texture"
    defaultNoScreenshotFailureClass = "bad-screenshot"
    defaultNonZeroExitFailureClass = "crash"
    imageQualityRules = [pscustomobject][ordered]@{
        minimumProofWidth = 320
        minimumProofHeight = 240
        hardFailureClasses = @("bad-screenshot", "magenta-fallback", "one-color-screenshot", "void-background")
    }
    manifestStatusRules = @()
    missingImageResourceRules = @()
}
if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) {
    $resolvedPolicyPath = Resolve-RepoRelativePath $PolicyPath
    if (-not (Test-Path -LiteralPath $resolvedPolicyPath)) {
        throw "Screenshot evidence policy not found: $PolicyPath"
    }
    $script:EvidencePolicy = Get-Content -LiteralPath $resolvedPolicyPath -Raw | ConvertFrom-Json
}

function Open-EvidenceBitmap([string]$ImagePath) {
    Add-Type -AssemblyName System.Drawing

    try {
        return [System.Drawing.Bitmap]::FromFile($ImagePath)
    }
    catch {
        Write-Verbose "GDI+ failed to decode '$ImagePath': $($_.Exception.Message). Trying WIC fallback."
    }

    Add-Type -AssemblyName PresentationCore
    $stream = [System.IO.File]::OpenRead($ImagePath)
    try {
        try {
            $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                $stream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        }
        catch {
            throw "Could not decode screenshot image '$ImagePath' with GDI+ or WIC: $($_.Exception.Message)"
        }
        $frame = $decoder.Frames[0]
        $converted = [System.Windows.Media.Imaging.FormatConvertedBitmap]::new()
        $converted.BeginInit()
        $converted.Source = $frame
        $converted.DestinationFormat = [System.Windows.Media.PixelFormats]::Bgra32
        $converted.EndInit()

        $width = [int]$converted.PixelWidth
        $height = [int]$converted.PixelHeight
        $stride = $width * 4
        $pixels = [byte[]]::new($stride * $height)
        $converted.CopyPixels($pixels, $stride, 0)
    }
    finally {
        $stream.Dispose()
    }

    $bitmap = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rect = [System.Drawing.Rectangle]::new(0, 0, $width, $height)
    $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        [System.Runtime.InteropServices.Marshal]::Copy($pixels, 0, $data.Scan0, $pixels.Length)
    }
    finally {
        $bitmap.UnlockBits($data)
    }

    return $bitmap
}

function Get-ImageEvidenceMetrics([string]$ImagePath) {
    $image = Open-EvidenceBitmap -ImagePath $ImagePath
    try {
        $width = [int]$image.Width
        $height = [int]$image.Height
        $cropLeft = 0
        $cropTop = 0
        $cropRight = $width - 1
        $cropBottom = $height - 1

        $isNearWhiteBorder = {
            param([System.Drawing.Color]$Color)
            return ($Color.R -ge 245 -and $Color.G -ge 245 -and $Color.B -ge 245)
        }
        $rowIsBorder = {
            param([int]$Y, [int]$Left, [int]$Right)
            $count = 0
            $white = 0
            $step = [Math]::Max(1, [int][Math]::Floor(($Right - $Left + 1) / 96))
            for ($x = $Left; $x -le $Right; $x += $step) {
                $count++
                if (& $isNearWhiteBorder $image.GetPixel($x, $Y)) {
                    $white++
                }
            }
            return ($count -gt 0 -and ($white / $count) -ge 0.85)
        }
        $columnIsBorder = {
            param([int]$X, [int]$Top, [int]$Bottom)
            $count = 0
            $white = 0
            $step = [Math]::Max(1, [int][Math]::Floor(($Bottom - $Top + 1) / 96))
            for ($y = $Top; $y -le $Bottom; $y += $step) {
                $count++
                if (& $isNearWhiteBorder $image.GetPixel($X, $y)) {
                    $white++
                }
            }
            return ($count -gt 0 -and ($white / $count) -ge 0.85)
        }

        while ($cropTop -lt $cropBottom -and (& $rowIsBorder $cropTop $cropLeft $cropRight)) {
            $cropTop++
        }
        while ($cropBottom -gt $cropTop -and (& $rowIsBorder $cropBottom $cropLeft $cropRight)) {
            $cropBottom--
        }
        while ($cropLeft -lt $cropRight -and (& $columnIsBorder $cropLeft $cropTop $cropBottom)) {
            $cropLeft++
        }
        while ($cropRight -gt $cropLeft -and (& $columnIsBorder $cropRight $cropTop $cropBottom)) {
            $cropRight--
        }

        if (($cropRight - $cropLeft) -lt [Math]::Max(64, [int]($width * 0.25)) -or ($cropBottom - $cropTop) -lt [Math]::Max(64, [int]($height * 0.25))) {
            $cropLeft = 0
            $cropTop = 0
            $cropRight = $width - 1
            $cropBottom = $height - 1
        }

        $sampleWidth = $cropRight - $cropLeft + 1
        $sampleHeight = $cropBottom - $cropTop + 1
        $stepX = [Math]::Max(1, [int][Math]::Floor($sampleWidth / 240))
        $stepY = [Math]::Max(1, [int][Math]::Floor($sampleHeight / 180))

        $samples = 0
        $sumBrightness = 0.0
        $sumBrightness2 = 0.0
        $sumSaturation = 0.0
        $magenta = 0
        $purple = 0
        $brightLowSat = 0
        $paleBlueVoid = 0
        $paleGreenVoid = 0
        $dark = 0
        $colorSignal = 0
        $nearWhite = 0
        $bucketCounts = @{}

        for ($y = $cropTop; $y -le $cropBottom; $y += $stepY) {
            for ($x = $cropLeft; $x -le $cropRight; $x += $stepX) {
                $c = $image.GetPixel($x, $y)
                $r = [double]$c.R / 255.0
                $g = [double]$c.G / 255.0
                $b = [double]$c.B / 255.0
                $max = [Math]::Max($r, [Math]::Max($g, $b))
                $min = [Math]::Min($r, [Math]::Min($g, $b))
                $brightness = ($r + $g + $b) / 3.0
                $saturation = if ($max -le 0.0001) { 0.0 } else { ($max - $min) / $max }

                $samples++
                $sumBrightness += $brightness
                $sumBrightness2 += ($brightness * $brightness)
                $sumSaturation += $saturation

                if ($r -gt 0.75 -and $b -gt 0.75 -and $g -lt 0.35) {
                    $magenta++
                }
                if ($b -gt 0.45 -and $r -gt 0.25 -and $g -lt 0.25 -and ($b - $g) -gt 0.25) {
                    $purple++
                }
                if ($brightness -gt 0.88 -and $saturation -lt 0.18) {
                    $brightLowSat++
                }
                if ($b -gt 0.72 -and $g -gt 0.70 -and $r -gt 0.60 -and $saturation -lt 0.35) {
                    $paleBlueVoid++
                }
                if ($g -gt 0.58 -and $r -gt 0.50 -and $b -gt 0.45 -and $saturation -lt 0.28) {
                    $paleGreenVoid++
                }
                if ($brightness -lt 0.08) {
                    $dark++
                }
                if ($saturation -gt 0.20 -and $brightness -gt 0.10 -and $brightness -lt 0.92) {
                    $colorSignal++
                }
                if ($brightness -gt 0.93 -and $saturation -lt 0.08) {
                    $nearWhite++
                }

                $bucket = "{0:X2}{1:X2}{2:X2}" -f (($c.R -band 0xF0)), (($c.G -band 0xF0)), (($c.B -band 0xF0))
                if (-not $bucketCounts.ContainsKey($bucket)) {
                    $bucketCounts[$bucket] = 0
                }
                $bucketCounts[$bucket]++
            }
        }

        $mean = if ($samples -gt 0) { $sumBrightness / $samples } else { 0.0 }
        $variance = if ($samples -gt 0) { [Math]::Max(0.0, ($sumBrightness2 / $samples) - ($mean * $mean)) } else { 0.0 }
        $dominantBucketCount = 0
        foreach ($value in $bucketCounts.Values) {
            if ([int]$value -gt $dominantBucketCount) {
                $dominantBucketCount = [int]$value
            }
        }

        return [pscustomobject][ordered]@{
            width = $width
            height = $height
            cropLeft = $cropLeft
            cropTop = $cropTop
            cropRight = $cropRight
            cropBottom = $cropBottom
            samples = $samples
            meanBrightness = [Math]::Round($mean, 4)
            brightnessStdDev = [Math]::Round([Math]::Sqrt($variance), 4)
            meanSaturation = if ($samples -gt 0) { [Math]::Round($sumSaturation / $samples, 4) } else { 0.0 }
            magentaRatio = if ($samples -gt 0) { [Math]::Round($magenta / $samples, 4) } else { 0.0 }
            purpleRatio = if ($samples -gt 0) { [Math]::Round($purple / $samples, 4) } else { 0.0 }
            brightLowSaturationRatio = if ($samples -gt 0) { [Math]::Round($brightLowSat / $samples, 4) } else { 0.0 }
            paleBlueVoidRatio = if ($samples -gt 0) { [Math]::Round($paleBlueVoid / $samples, 4) } else { 0.0 }
            paleGreenVoidRatio = if ($samples -gt 0) { [Math]::Round($paleGreenVoid / $samples, 4) } else { 0.0 }
            darkRatio = if ($samples -gt 0) { [Math]::Round($dark / $samples, 4) } else { 0.0 }
            colorSignalRatio = if ($samples -gt 0) { [Math]::Round($colorSignal / $samples, 4) } else { 0.0 }
            nearWhiteRatio = if ($samples -gt 0) { [Math]::Round($nearWhite / $samples, 4) } else { 0.0 }
            dominantColorBucketRatio = if ($samples -gt 0) { [Math]::Round($dominantBucketCount / $samples, 4) } else { 0.0 }
            colorBucketCount = $bucketCounts.Count
        }
    }
    finally {
        $image.Dispose()
    }
}

function Get-MissingImageResourcePaths([string]$LogPath) {
    $paths = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return @($paths.ToArray())
    }

    $text = Get-Content -LiteralPath $LogPath -Raw
    $missingImageMatches = [regex]::Matches($text, "Resource '(?<path>[^']+\.(dds|png|tga|jpg))' not found|Failed to open image:\s*(?<path2>.+)$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($match in $missingImageMatches) {
        $resourcePath = $match.Groups["path"].Value
        if ([string]::IsNullOrWhiteSpace($resourcePath)) {
            $resourcePath = $match.Groups["path2"].Value
        }
        $resourcePath = ($resourcePath -replace "\\", "/").Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($resourcePath)) {
            continue
        }

        $paths.Add($resourcePath) | Out-Null
    }

    return @($paths.ToArray() | Select-Object -Unique)
}

function Get-MissingImageResourceRule([string]$ResourcePath, [string]$EvidenceKind) {
    foreach ($rule in @((Get-PropertyValue $script:EvidencePolicy "missingImageResourceRules"))) {
        $evidenceKinds = Get-PropertyValue $rule "evidenceKinds"
        if ($null -ne $evidenceKinds -and -not (Test-TextListContains $evidenceKinds $EvidenceKind)) {
            continue
        }
        foreach ($pattern in Get-TextArray (Get-PropertyValue $rule "patterns")) {
            if ($ResourcePath -match $pattern) {
                return $rule
            }
        }
    }

    return $null
}

function Get-MissingImageResourceClasses([string]$LogPath, [string]$EvidenceKind, [string]$Severity) {
    $classes = New-Object System.Collections.Generic.List[string]
    $defaultFailureClass = [string](Get-PropertyValue $script:EvidencePolicy "defaultMissingImageFailureClass")
    if ([string]::IsNullOrWhiteSpace($defaultFailureClass)) {
        $defaultFailureClass = "missing-texture"
    }

    foreach ($resourcePath in Get-MissingImageResourcePaths -LogPath $LogPath) {
        $rule = Get-MissingImageResourceRule -ResourcePath $resourcePath -EvidenceKind $EvidenceKind
        if ($null -eq $rule) {
            if ([string]::Equals($Severity, "failure", [StringComparison]::OrdinalIgnoreCase)) {
                $classes.Add($defaultFailureClass) | Out-Null
            }
            continue
        }

        $ruleSeverity = [string](Get-PropertyValue $rule "severity")
        if ([string]::IsNullOrWhiteSpace($ruleSeverity)) {
            $ruleSeverity = "warning"
        }
        if ([string]::Equals($ruleSeverity, $Severity, [StringComparison]::OrdinalIgnoreCase)) {
            $classes.Add([string](Get-PropertyValue $rule "id")) | Out-Null
        }
    }

    return @($classes.ToArray() | Select-Object -Unique)
}

function Get-RuntimeLogRuleClasses([string]$LogText, [string]$EvidenceKind, [string]$Severity) {
    $classes = New-Object System.Collections.Generic.List[string]
    foreach ($rule in @((Get-PropertyValue $script:EvidencePolicy "runtimeLogRules"))) {
        $ruleSeverity = [string](Get-PropertyValue $rule "severity")
        if ([string]::IsNullOrWhiteSpace($ruleSeverity)) {
            $ruleSeverity = "warning"
        }
        if (-not [string]::Equals($ruleSeverity, $Severity, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $evidenceKinds = Get-PropertyValue $rule "evidenceKinds"
        if ($null -ne $evidenceKinds -and -not (Test-TextListContains $evidenceKinds $EvidenceKind)) {
            continue
        }

        foreach ($pattern in Get-TextArray (Get-PropertyValue $rule "patterns")) {
            if ($LogText -match $pattern) {
                $classes.Add([string](Get-PropertyValue $rule "id")) | Out-Null
                break
            }
        }
    }

    return @($classes.ToArray() | Select-Object -Unique)
}

function Get-LogFailureClasses {
    param(
        [string]$LogPath,
        [string]$EvidenceKind = ""
    )

    $classes = New-Object System.Collections.Generic.List[string]
    foreach ($class in Get-MissingImageResourceClasses -LogPath $LogPath -EvidenceKind $EvidenceKind -Severity "failure") {
        $classes.Add($class) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return @($classes.ToArray() | Select-Object -Unique)
    }

    $text = Get-Content -LiteralPath $LogPath -Raw
    foreach ($class in Get-RuntimeLogRuleClasses -LogText $text -EvidenceKind $EvidenceKind -Severity "failure") {
        $classes.Add($class) | Out-Null
    }

    return @($classes.ToArray() | Select-Object -Unique)
}

function Get-LogWarningClasses {
    param(
        [string]$LogPath,
        [string]$EvidenceKind = ""
    )

    $classes = New-Object System.Collections.Generic.List[string]
    foreach ($class in Get-MissingImageResourceClasses -LogPath $LogPath -EvidenceKind $EvidenceKind -Severity "warning") {
        $classes.Add($class) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return @($classes.ToArray() | Select-Object -Unique)
    }

    $text = Get-Content -LiteralPath $LogPath -Raw
    foreach ($class in Get-RuntimeLogRuleClasses -LogText $text -EvidenceKind $EvidenceKind -Severity "warning") {
        $classes.Add($class) | Out-Null
    }

    return @($classes.ToArray() | Select-Object -Unique)
}

function Convert-CountMapToObject([hashtable]$Map) {
    $ordered = [ordered]@{}
    foreach ($key in @($Map.Keys | Sort-Object)) {
        $ordered[$key] = [int]$Map[$key]
    }
    return [pscustomobject]$ordered
}

function Convert-MatchGroupToDouble($Match, [string]$Name) {
    $value = $Match.Groups[$Name].Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    return [double]::Parse($value, [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-LogEvidenceSummary([string]$LogPath, [string]$EvidenceKind) {
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) {
        return [pscustomobject][ordered]@{
            available = $false
            path = $null
        }
    }

    $text = Get-Content -LiteralPath $LogPath -Raw
    $missingImageClassCounts = @{}
    foreach ($resourcePath in Get-MissingImageResourcePaths -LogPath $LogPath) {
        $rule = Get-MissingImageResourceRule -ResourcePath $resourcePath -EvidenceKind $EvidenceKind
        $class = if ($null -ne $rule) {
            [string](Get-PropertyValue $rule "id")
        }
        else {
            [string](Get-PropertyValue $script:EvidencePolicy "defaultMissingImageFailureClass")
        }
        if ([string]::IsNullOrWhiteSpace($class)) {
            $class = "missing-texture"
        }
        if (-not $missingImageClassCounts.ContainsKey($class)) {
            $missingImageClassCounts[$class] = 0
        }
        $missingImageClassCounts[$class]++
    }

    $idleMatches = [regex]::Matches($text, "idle animation missing for (?<id>\S+) group '(?<group>[^']+)'")
    $idleFormIds = @($idleMatches | ForEach-Object { $_.Groups["id"].Value } | Select-Object -Unique | Sort-Object)
    $recordRuntimeGapCount = ([regex]::Matches($text, "script record not found|Failed to add global script", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    $animationBindGapCount = ([regex]::Matches($text, "Unhandled controller", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count

    $weatherMatches = [regex]::Matches($text,
        "weather render state hour=(?<hour>[-+0-9.]+) currentWeather=(?<currentWeather>-?\d+) nextWeather=(?<nextWeather>-?\d+) isExterior=(?<isExterior>[01]) isDay=(?<isDay>[01]).*? sky=\((?<sky>[^)]*)\).*? skyHorizon=\((?<skyHorizon>[^)]*)\)",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $weatherState = $null
    if ($weatherMatches.Count -gt 0) {
        $match = $weatherMatches[$weatherMatches.Count - 1]
        $weatherState = [pscustomobject][ordered]@{
            hour = Convert-MatchGroupToDouble $match "hour"
            currentWeather = [int]$match.Groups["currentWeather"].Value
            nextWeather = [int]$match.Groups["nextWeather"].Value
            isExterior = [bool]([int]$match.Groups["isExterior"].Value)
            isDay = [bool]([int]$match.Groups["isDay"].Value)
            sky = $match.Groups["sky"].Value
            skyHorizon = $match.Groups["skyHorizon"].Value
        }
    }

    $atmosphereMatches = [regex]::Matches($text,
        "atmosphere vertical colors runtime-supported skyUpper=\((?<skyUpper>[^)]*)\) skyLower=\((?<skyLower>[^)]*)\) horizon=\((?<horizon>[^)]*)\)",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $atmosphereState = $null
    if ($atmosphereMatches.Count -gt 0) {
        $match = $atmosphereMatches[$atmosphereMatches.Count - 1]
        $atmosphereState = [pscustomobject][ordered]@{
            skyUpper = $match.Groups["skyUpper"].Value
            skyLower = $match.Groups["skyLower"].Value
            horizon = $match.Groups["horizon"].Value
        }
    }

    $screenshotQueueMatches = [regex]::Matches($text,
        "queuing GUI-inclusive native screenshot at frame (?<frame>\d+) hour=(?<hour>[-+0-9.]+) weatherId=(?<weatherId>-?\d+) weatherTransition=(?<weatherTransition>[-+0-9.]+)",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $screenshotQueue = $null
    if ($screenshotQueueMatches.Count -gt 0) {
        $match = $screenshotQueueMatches[$screenshotQueueMatches.Count - 1]
        $screenshotQueue = [pscustomobject][ordered]@{
            frame = [int]$match.Groups["frame"].Value
            hour = Convert-MatchGroupToDouble $match "hour"
            weatherId = [int]$match.Groups["weatherId"].Value
            weatherTransition = Convert-MatchGroupToDouble $match "weatherTransition"
        }
    }

    return [pscustomobject][ordered]@{
        available = $true
        path = Convert-ToForwardSlash ([System.IO.Path]::GetFullPath($LogPath))
        missingImageResourceCount = @((Get-MissingImageResourcePaths -LogPath $LogPath)).Count
        missingImageClassCounts = Convert-CountMapToObject $missingImageClassCounts
        idleAnimationMissingCount = $idleMatches.Count
        idleAnimationMissingFormIds = @($idleFormIds | Select-Object -First 20)
        recordRuntimeGapCount = $recordRuntimeGapCount
        animationBindGapCount = $animationBindGapCount
        weatherState = $weatherState
        atmosphereState = $atmosphereState
        screenshotQueue = $screenshotQueue
    }
}

function Get-PolicyImageQualityInt([string]$Name, [int]$DefaultValue) {
    $rules = Get-PropertyValue $script:EvidencePolicy "imageQualityRules"
    $value = Get-PropertyValue $rules $Name
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        return $DefaultValue
    }

    return [int]$value
}

function Get-PolicyHardFailureClasses {
    $rules = Get-PropertyValue $script:EvidencePolicy "imageQualityRules"
    $classes = @(Get-TextArray (Get-PropertyValue $rules "hardFailureClasses"))
    if ($classes.Count -eq 0) {
        return @("bad-screenshot", "magenta-fallback", "one-color-screenshot", "void-background")
    }

    return @($classes)
}

function Get-ScreenshotAssessment($Metrics, [string[]]$LogClasses, [string]$EvidenceKind) {
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]

    $minimumProofWidth = Get-PolicyImageQualityInt -Name "minimumProofWidth" -DefaultValue 320
    $minimumProofHeight = Get-PolicyImageQualityInt -Name "minimumProofHeight" -DefaultValue 240

    if ($Metrics.width -lt $minimumProofWidth -or $Metrics.height -lt $minimumProofHeight) {
        $failureClasses.Add("bad-screenshot") | Out-Null
        $reasons.Add("image is too small to prove rendering") | Out-Null
    }
    if ($Metrics.magentaRatio -gt 0.005 -or $Metrics.purpleRatio -gt 0.18) {
        $failureClasses.Add("magenta-fallback") | Out-Null
        $reasons.Add("magenta/purple fallback color dominates or appears significantly") | Out-Null
    }
    if ($Metrics.paleBlueVoidRatio -gt 0.52) {
        $failureClasses.Add("void-background") | Out-Null
        $reasons.Add("pale blue void/background dominates frame") | Out-Null
    }
    if ($Metrics.paleGreenVoidRatio -gt 0.45 -and $Metrics.colorSignalRatio -lt 0.20) {
        $failureClasses.Add("one-color-screenshot") | Out-Null
        $reasons.Add("pale low-saturation geometry/background dominates with weak color signal") | Out-Null
    }
    if ($Metrics.brightLowSaturationRatio -gt 0.20 -or $Metrics.nearWhiteRatio -gt 0.12) {
        $failureClasses.Add("missing-texture") | Out-Null
        $reasons.Add("large bright low-saturation/white regions suggest untextured surfaces") | Out-Null
    }
    if (($Metrics.brightnessStdDev -lt 0.045 -and $Metrics.colorSignalRatio -lt 0.04) -or $Metrics.dominantColorBucketRatio -gt 0.82) {
        $failureClasses.Add("one-color-screenshot") | Out-Null
        $reasons.Add("low brightness variation or dominant color bucket suggests one-color output") | Out-Null
    }
    if ($Metrics.colorSignalRatio -lt 0.06 -and $Metrics.meanBrightness -gt 0.20) {
        $failureClasses.Add("material-fallback") | Out-Null
        $reasons.Add("very little color signal outside neutral fallback colors") | Out-Null
    }

    foreach ($class in @($LogClasses)) {
        $failureClasses.Add($class) | Out-Null
    }
    if ($LogClasses -contains "missing-texture") {
        $reasons.Add("OpenMW log reports missing image resources") | Out-Null
    }

    $classes = @($failureClasses.ToArray() | Select-Object -Unique)
    $status = "pass"
    if ($classes.Count -gt 0) {
        $status = "questionable"
    }
    foreach ($hard in @(Get-PolicyHardFailureClasses)) {
        if ($classes -contains $hard) {
            $status = "fail"
        }
    }
    if ($EvidenceKind -eq "actor-proof" -and ($classes -contains "missing-texture" -or $classes -contains "material-fallback")) {
        $status = "fail"
    }

    return [pscustomobject][ordered]@{
        status = $status
        failureClasses = $classes
        reasons = @($reasons.ToArray() | Select-Object -Unique)
    }
}

function New-EvidenceRowFromImage {
    param(
        [string]$ImagePath,
        [string]$WorldId = "",
        [string]$EvidenceKind = "manual-image",
        [string]$ManifestPath = "",
        [string]$LogPath = "",
        [object]$Manifest = $null
    )

    $metrics = Get-ImageEvidenceMetrics -ImagePath $ImagePath
    $logClasses = Get-LogFailureClasses -LogPath $LogPath -EvidenceKind $EvidenceKind
    $warningClasses = Get-LogWarningClasses -LogPath $LogPath -EvidenceKind $EvidenceKind
    $logSummary = New-LogEvidenceSummary -LogPath $LogPath -EvidenceKind $EvidenceKind
    $assessment = Get-ScreenshotAssessment -Metrics $metrics -LogClasses $logClasses -EvidenceKind $EvidenceKind

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        assessedAt = (Get-Date).ToString("o")
        worldId = $WorldId
        evidenceKind = $EvidenceKind
        status = $assessment.status
        failureClasses = @($assessment.failureClasses)
        warningClasses = @($warningClasses)
        reasons = @($assessment.reasons)
        image = Convert-ToForwardSlash ([System.IO.Path]::GetFullPath($ImagePath))
        manifest = if ($ManifestPath) { Convert-ToForwardSlash ([System.IO.Path]::GetFullPath($ManifestPath)) } else { $null }
        log = if ($LogPath) { Convert-ToForwardSlash ([System.IO.Path]::GetFullPath($LogPath)) } else { $null }
        metrics = $metrics
        logSummary = $logSummary
        manifestSummary = if ($null -ne $Manifest) {
            [pscustomobject][ordered]@{
                status = [string](Get-PropertyValue $Manifest "status")
                startSlice = Get-PropertyValue $Manifest "startSlice"
                captureSeconds = @((Get-PropertyValue $Manifest "captureSeconds"))
                captureAttempts = @((Get-PropertyValue $Manifest "captureAttempts"))
                processTermination = Get-PropertyValue $Manifest "processTermination"
            }
        } else { $null }
    }
}

function Test-ManifestStatusRuleMatch($Rule, $Manifest, [int]$ScreenshotCount) {
    $match = Get-PropertyValue $Rule "match"
    if ($null -eq $match) {
        return $false
    }

    $ignoreWhenHarnessTerminated = Get-NullableBool (Get-PropertyValue $match "ignoreWhenHarnessTerminated")
    if ($ignoreWhenHarnessTerminated -eq $true -and (Test-ManifestHarnessTerminationRequested -Manifest $Manifest)) {
        return $false
    }

    $manifestStatus = [string](Get-PropertyValue $Manifest "status")
    $statuses = Get-PropertyValue $match "statuses"
    if ($null -ne $statuses -and -not (Test-TextListContains $statuses $manifestStatus)) {
        return $false
    }

    $statusPattern = [string](Get-PropertyValue $match "statusPattern")
    if (-not [string]::IsNullOrWhiteSpace($statusPattern) -and $manifestStatus -notmatch $statusPattern) {
        return $false
    }

    $screenshotCountEquals = Get-NullableInt (Get-PropertyValue $match "screenshotCountEquals")
    if ($null -ne $screenshotCountEquals -and $ScreenshotCount -ne $screenshotCountEquals) {
        return $false
    }

    $screenshotCountLessThan = Get-NullableInt (Get-PropertyValue $match "screenshotCountLessThan")
    if ($null -ne $screenshotCountLessThan -and $ScreenshotCount -ge $screenshotCountLessThan) {
        return $false
    }

    $screenshotCountGreaterThan = Get-NullableInt (Get-PropertyValue $match "screenshotCountGreaterThan")
    if ($null -ne $screenshotCountGreaterThan -and $ScreenshotCount -le $screenshotCountGreaterThan) {
        return $false
    }

    $exitCode = Get-NullableInt (Get-PropertyValue $Manifest "exitCode")
    $exitCodeEquals = Get-NullableInt (Get-PropertyValue $match "exitCodeEquals")
    if ($null -ne $exitCodeEquals -and ($null -eq $exitCode -or $exitCode -ne $exitCodeEquals)) {
        return $false
    }

    $exitCodeNotEquals = Get-NullableInt (Get-PropertyValue $match "exitCodeNotEquals")
    if ($null -ne $exitCodeNotEquals -and ($null -eq $exitCode -or $exitCode -eq $exitCodeNotEquals)) {
        return $false
    }

    $nonZeroExitCode = Get-NullableBool (Get-PropertyValue $match "nonZeroExitCode")
    if ($null -ne $nonZeroExitCode) {
        $actualNonZeroExitCode = ($null -ne $exitCode -and $exitCode -ne 0)
        if ($actualNonZeroExitCode -ne $nonZeroExitCode) {
            return $false
        }
    }

    return $true
}

function Add-ManifestRuleClasses {
    param(
        [object]$Rule,
        [System.Collections.Generic.List[string]]$FailureClasses,
        [System.Collections.Generic.List[string]]$WarningClasses
    )

    foreach ($class in Get-TextArray (Get-PropertyValue $Rule "failureClasses")) {
        Add-UniqueTextToList -List $FailureClasses -Value $class
    }
    foreach ($class in Get-TextArray (Get-PropertyValue $Rule "warningClasses")) {
        Add-UniqueTextToList -List $WarningClasses -Value $class
    }

    $severity = [string](Get-PropertyValue $Rule "severity")
    $class = [string](Get-PropertyValue $Rule "class")
    if ([string]::IsNullOrWhiteSpace($class)) {
        return
    }
    if ([string]::Equals($severity, "warning", [StringComparison]::OrdinalIgnoreCase)) {
        Add-UniqueTextToList -List $WarningClasses -Value $class
    }
    else {
        Add-UniqueTextToList -List $FailureClasses -Value $class
    }
}

function Test-ManifestHarnessTerminationRequested($Manifest) {
    $termination = Get-PropertyValue $Manifest "processTermination"
    if ($null -eq $termination) {
        return $false
    }

    return [bool](Get-PropertyValue $termination "requestedByHarness")
}

function New-EvidenceRowFromManifestStatus {
    param(
        $Manifest,
        [string]$WorldId,
        [string]$ManifestPath,
        [string]$LogPath,
        [int]$DeclaredScreenshotCount,
        $ExpectedScreenshotCount,
        [int]$CapturedScreenshotCount
    )

    $evidenceKind = "real-screenshot-manifest"
    $failureClasses = New-Object System.Collections.Generic.List[string]
    $warningClasses = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]
    $matchedRules = New-Object System.Collections.Generic.List[string]
    $status = "fail"

    foreach ($rule in @((Get-PropertyValue $script:EvidencePolicy "manifestStatusRules"))) {
        if (-not (Test-ManifestStatusRuleMatch -Rule $rule -Manifest $Manifest -ScreenshotCount $CapturedScreenshotCount)) {
            continue
        }

        Add-UniqueTextToList -List $matchedRules -Value ([string](Get-PropertyValue $rule "id"))
        Add-ManifestRuleClasses -Rule $rule -FailureClasses $failureClasses -WarningClasses $warningClasses
        foreach ($reason in Get-TextArray (Get-PropertyValue $rule "reasons")) {
            Add-UniqueTextToList -List $reasons -Value $reason
        }

        $ruleStatus = [string](Get-PropertyValue $rule "status")
        if ([string]::IsNullOrWhiteSpace($ruleStatus)) {
            $ruleSeverity = [string](Get-PropertyValue $rule "severity")
            $ruleStatus = if ([string]::Equals($ruleSeverity, "warning", [StringComparison]::OrdinalIgnoreCase)) { "questionable" } else { "fail" }
        }
        $status = Merge-EvidenceStatus -Current $status -Candidate $ruleStatus
    }

    if ($CapturedScreenshotCount -eq 0) {
        $defaultNoScreenshotFailureClass = [string](Get-PropertyValue $script:EvidencePolicy "defaultNoScreenshotFailureClass")
        if ([string]::IsNullOrWhiteSpace($defaultNoScreenshotFailureClass)) {
            $defaultNoScreenshotFailureClass = "bad-screenshot"
        }
        Add-UniqueTextToList -List $failureClasses -Value $defaultNoScreenshotFailureClass
        Add-UniqueTextToList -List $reasons -Value "manifest produced no usable screenshot files"
    }

    if ($null -ne $ExpectedScreenshotCount -and $ExpectedScreenshotCount -gt 0 -and $CapturedScreenshotCount -lt $ExpectedScreenshotCount) {
        Add-UniqueTextToList -List $failureClasses -Value "bad-screenshot"
        Add-UniqueTextToList -List $reasons -Value "manifest captured $CapturedScreenshotCount screenshot(s), expected $ExpectedScreenshotCount"
    }

    $exitCode = Get-NullableInt (Get-PropertyValue $Manifest "exitCode")
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        $ignoreHarnessTerminatedExit = [bool](Get-PropertyValue $script:EvidencePolicy "defaultNonZeroExitIgnoreWhenHarnessTerminated")
        if ($ignoreHarnessTerminatedExit -and (Test-ManifestHarnessTerminationRequested -Manifest $Manifest)) {
            Add-UniqueTextToList -List $reasons -Value "OpenMW exitCode=$exitCode after harness-requested shutdown"
        }
        else {
            $defaultNonZeroExitFailureClass = [string](Get-PropertyValue $script:EvidencePolicy "defaultNonZeroExitFailureClass")
            if ([string]::IsNullOrWhiteSpace($defaultNonZeroExitFailureClass)) {
                $defaultNonZeroExitFailureClass = "crash"
            }
            Add-UniqueTextToList -List $failureClasses -Value $defaultNonZeroExitFailureClass
            Add-UniqueTextToList -List $reasons -Value "OpenMW exitCode=$exitCode"
        }
    }

    foreach ($class in Get-LogFailureClasses -LogPath $LogPath -EvidenceKind $evidenceKind) {
        Add-UniqueTextToList -List $failureClasses -Value $class
    }
    foreach ($class in Get-LogWarningClasses -LogPath $LogPath -EvidenceKind $evidenceKind) {
        Add-UniqueTextToList -List $warningClasses -Value $class
    }

    if ($failureClasses.Count -gt 0) {
        $status = "fail"
    }
    elseif ($warningClasses.Count -gt 0) {
        $status = "questionable"
    }

    $logSummary = New-LogEvidenceSummary -LogPath $LogPath -EvidenceKind $evidenceKind

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        assessedAt = (Get-Date).ToString("o")
        worldId = $WorldId
        evidenceKind = $evidenceKind
        status = $status
        failureClasses = @($failureClasses.ToArray())
        warningClasses = @($warningClasses.ToArray())
        reasons = @($reasons.ToArray())
        image = $null
        manifest = if ($ManifestPath) { Convert-ToForwardSlash ([System.IO.Path]::GetFullPath($ManifestPath)) } else { $null }
        log = if ($LogPath) { Convert-ToForwardSlash ([System.IO.Path]::GetFullPath($LogPath)) } else { $null }
        metrics = $null
        logSummary = $logSummary
        manifestSummary = [pscustomobject][ordered]@{
            status = [string](Get-PropertyValue $Manifest "status")
            exitCode = $exitCode
            declaredScreenshotCount = $DeclaredScreenshotCount
            expectedScreenshotCount = $ExpectedScreenshotCount
            capturedScreenshotCount = $CapturedScreenshotCount
            matchedRules = @($matchedRules.ToArray())
            processTermination = Get-PropertyValue $Manifest "processTermination"
            captureAttempts = @((Get-PropertyValue $Manifest "captureAttempts"))
            crashReports = @((Get-PropertyValue $Manifest "crashReports"))
        }
    }
}

function Add-EvidenceRowsFromManifest {
    param(
        [string]$ManifestPath,
        [System.Collections.Generic.List[object]]$Rows
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $manifestStatus = [string](Get-PropertyValue $manifest "status")
    if (Test-TextListContains (Get-PropertyValue $script:EvidencePolicy "ignoredManifestStatuses") $manifestStatus) {
        return
    }

    $worldId = [string](Get-PropertyValue $manifest "worldId")
    $stableManifestPath = $ManifestPath
    $outputDirectory = [string](Get-PropertyValue $manifest "outputDirectory")
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        $candidateManifest = Join-Path $outputDirectory "manifest.json"
        if (Test-Path -LiteralPath $candidateManifest) {
            $stableManifestPath = $candidateManifest
        }
    }
    $profileDirectory = [string](Get-PropertyValue $manifest "profileDirectory")
    $logPath = ""
    $manifestLogPath = [string](Get-PropertyValue $manifest "logPath")
    if (-not [string]::IsNullOrWhiteSpace($manifestLogPath) -and (Test-Path -LiteralPath $manifestLogPath)) {
        $logPath = $manifestLogPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($profileDirectory)) {
        $candidateLog = Join-Path $profileDirectory "openmw.log"
        if (Test-Path -LiteralPath $candidateLog) {
            $logPath = $candidateLog
        }
    }

    $declaredScreenshotCount = @($manifest.screenshots).Count
    $expectedScreenshotCount = Get-NullableInt (Get-PropertyValue $manifest "expectedScreenshotCount")
    $capturedScreenshotCount = 0
    foreach ($screenshot in @($manifest.screenshots)) {
        $imagePath = [string](Get-PropertyValue $screenshot "path")
        if ([string]::IsNullOrWhiteSpace($imagePath) -or -not (Test-Path -LiteralPath $imagePath)) {
            continue
        }
        $source = [string](Get-PropertyValue $screenshot "source")
        $evidenceKind = switch ($source) {
            "openmw-native-screenshot" { "real-native-screenshot" }
            "window-screenshot-fallback" { "real-window-screenshot-fallback" }
            default { if ($source) { $source } else { "real-screenshot" } }
        }
        $Rows.Add((New-EvidenceRowFromImage -ImagePath $imagePath -WorldId $worldId -EvidenceKind $evidenceKind -ManifestPath $stableManifestPath -LogPath $logPath -Manifest $manifest)) | Out-Null
        $capturedScreenshotCount++
    }

    $manifestStatusRowRequired = ($capturedScreenshotCount -eq 0)
    if ($null -ne $expectedScreenshotCount -and $expectedScreenshotCount -gt 0 -and $capturedScreenshotCount -lt $expectedScreenshotCount) {
        $manifestStatusRowRequired = $true
    }

    if ($manifestStatusRowRequired) {
        $Rows.Add((New-EvidenceRowFromManifestStatus -Manifest $manifest -WorldId $worldId -ManifestPath $stableManifestPath -LogPath $logPath -DeclaredScreenshotCount $declaredScreenshotCount -ExpectedScreenshotCount $expectedScreenshotCount -CapturedScreenshotCount $capturedScreenshotCount)) | Out-Null
    }
}

$rows = New-Object System.Collections.Generic.List[object]

$hasExplicitInput = (@($ManifestPath).Count -gt 0 -or @($Path).Count -gt 0)

if ($IncludeManifests -and -not $hasExplicitInput) {
    $manifestRootPath = Resolve-RepoRelativePath $ManifestRoot
    if (Test-Path -LiteralPath $manifestRootPath) {
        $manifests = Get-ChildItem -LiteralPath $manifestRootPath -Recurse -File -Filter "manifest.json" |
            Sort-Object LastWriteTime

        foreach ($manifestFile in $manifests) {
            Add-EvidenceRowsFromManifest -ManifestPath $manifestFile.FullName -Rows $rows
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

    Add-EvidenceRowsFromManifest -ManifestPath $resolvedManifest -Rows $rows
}

foreach ($inputPath in @($Path)) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        continue
    }

    $resolved = Resolve-RepoRelativePath $inputPath
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $images = Get-ChildItem -LiteralPath $resolved -Recurse -File |
            Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|bmp)$' } |
            Sort-Object FullName
        foreach ($image in $images) {
            $rows.Add((New-EvidenceRowFromImage -ImagePath $image.FullName)) | Out-Null
        }
    }
    elseif (Test-Path -LiteralPath $resolved -PathType Leaf) {
        if ([System.IO.Path]::GetFileName($resolved) -eq "manifest.json") {
            Add-EvidenceRowsFromManifest -ManifestPath $resolved -Rows $rows
        }
        else {
            $kind = if ($resolved -match "\\.codex-remote-attachments\\") { "actor-proof" } else { "manual-image" }
            $rows.Add((New-EvidenceRowFromImage -ImagePath $resolved -EvidenceKind $kind)) | Out-Null
        }
    }
    else {
        throw "Evidence path not found: $inputPath"
    }
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
    foreach ($row in @($rows.ToArray())) {
        ($row | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

@($rows.ToArray()) |
    Select-Object worldId, evidenceKind, status, @{ Name = "failureClasses"; Expression = { @($_.failureClasses) -join "," } }, image |
    Format-Table -AutoSize

if (-not $NoWrite) {
    Write-Host "Wrote screenshot evidence ledger: $OutputPath"
}
