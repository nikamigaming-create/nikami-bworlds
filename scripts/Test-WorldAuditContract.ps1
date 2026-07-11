param(
    [string]$ContractPath = "catalog/world-audit-contract.json",
    [string]$SeedPath = "catalog/world-audit.seed.json",
    [string]$StartsPath = "catalog/flat-world-proof-starts.json",
    [string]$ScreenshotEvidencePolicyPath = "catalog/screenshot-evidence-policy.json",
    [string]$ActorAnimationPolicyPath = "catalog/actor-animation-policy.json",
    [string]$ActorVisualReviewPath = "run/audit/actor-visual-review.jsonl",
    [string]$ActorProofStatusPath = "run/audit/latest-nonvr-actor-proof-status.jsonl",
    [string]$AdventureActorCatalogPath = "catalog/adventure-actor-catalog.json",
    [string]$AdventureActorRetainedStopsPath = "catalog/adventure-actor-retained-stops.json",
    [string]$ActorVisualReviewScriptPath = "scripts/Add-ActorVisualReview.ps1",
    [string]$ActorProofStatusScriptPath = "scripts/Measure-ActorProofStatus.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$failures = New-Object System.Collections.Generic.List[string]

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

function Get-DelimitedValueCount([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 0
    }

    return @(($Text -split ",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

function Get-ValueCount($Value) {
    if ($null -eq $Value) {
        return 0
    }
    if ($Value -is [System.Array]) {
        return @($Value).Count
    }
    return 1
}

function Test-AdventureStopMatchesRetentionSpec($Stop, $Spec) {
    if ($null -eq $Stop -or $null -eq $Spec) {
        return $false
    }

    $cell = Get-PropertyValue $Stop "cell"
    $editorId = [string](Get-PropertyValue $cell "editorId")
    $openmwId = [string](Get-PropertyValue $cell "openmwId")
    $label = [string](Get-PropertyValue $Stop "label")
    $specEditorId = [string](Get-PropertyValue $Spec "cellEditorId")
    $specOpenmwId = [string](Get-PropertyValue $Spec "cellOpenmwId")
    $specLabel = [string](Get-PropertyValue $Spec "label")

    if (-not [string]::IsNullOrWhiteSpace($specEditorId) -and $editorId -ne $specEditorId) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($specOpenmwId) -and $openmwId -ne $specOpenmwId) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($specEditorId) -and [string]::IsNullOrWhiteSpace($specOpenmwId) -and -not [string]::IsNullOrWhiteSpace($specLabel) -and $label -ne $specLabel) {
        return $false
    }

    return (-not [string]::IsNullOrWhiteSpace($specEditorId) -or -not [string]::IsNullOrWhiteSpace($specOpenmwId) -or -not [string]::IsNullOrWhiteSpace($specLabel))
}

function Add-AdventureActorRetentionValidationFailures {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [object]$AdventureCatalog,
        [object]$RetentionCatalog
    )

    if ($null -eq $AdventureCatalog -or $null -eq $RetentionCatalog) {
        return
    }

    $retainedWorlds = Get-PropertyValue $RetentionCatalog "worlds"
    if ($null -eq $retainedWorlds) {
        $Failures.Add("Adventure actor retained stops missing worlds")
        return
    }

    foreach ($retainedWorldProperty in @($retainedWorlds.PSObject.Properties)) {
        $worldId = [string]$retainedWorldProperty.Name
        $world = @($AdventureCatalog.worlds | Where-Object { $_.worldId -eq $worldId } | Select-Object -First 1)
        if ($null -eq $world) {
            $Failures.Add("Adventure actor catalog missing retained-stop world: $worldId")
            continue
        }

        $stops = @($world.adventureStops)
        foreach ($spec in @($retainedWorldProperty.Value)) {
            $hasIdentity = -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $spec "cellEditorId")) -or -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $spec "cellOpenmwId")) -or -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $spec "label"))
            if (-not $hasIdentity) {
                $Failures.Add("Adventure actor retained stop for $worldId has no identity")
                continue
            }

            $matched = $false
            foreach ($stop in $stops) {
                if (Test-AdventureStopMatchesRetentionSpec -Stop $stop -Spec $spec) {
                    $matched = $true
                    break
                }
            }
            if (-not $matched) {
                $Failures.Add("Adventure actor catalog missing retained stop '$([string](Get-PropertyValue $spec "label"))' for $worldId")
            }
        }
    }
}

function Get-CameraSequenceCount($Spec) {
    $anchor = Get-PropertyValue $Spec "anchor"
    $camera = Get-PropertyValue $anchor "camera"
    $sequence = Get-PropertyValue $camera "sequence"
    return Get-ValueCount $sequence
}

function Merge-CatalogPropertyObject($Base, $Overlay) {
    $map = [ordered]@{}
    foreach ($source in @($Base, $Overlay)) {
        if ($null -eq $source) {
            continue
        }
        foreach ($property in @($source.PSObject.Properties)) {
            $map[[string]$property.Name] = $property.Value
        }
    }
    if ($map.Count -eq 0) {
        return $null
    }

    return [pscustomobject]$map
}

function Get-CatalogDefaultCaptureSpec($StartsCatalog) {
    if ($null -eq $StartsCatalog) {
        return $null
    }

    $defaults = Get-PropertyValue $StartsCatalog "defaults"
    if ($null -eq $defaults) {
        return $null
    }

    $capture = Get-PropertyValue $defaults "capture"
    $map = [ordered]@{}
    if ($null -ne $capture) {
        foreach ($property in @($capture.PSObject.Properties)) {
            $map[[string]$property.Name] = $property.Value
        }
    }

    $legacyRunSeconds = Get-PropertyValue $defaults "runSeconds"
    if (-not $map.Contains("runSeconds") -and $null -ne $legacyRunSeconds) {
        $map["runSeconds"] = $legacyRunSeconds
    }

    $legacyScreenshotFrames = Get-PropertyValue $defaults "screenshotFrames"
    if (-not $map.Contains("engineScreenshotFrames") -and -not [string]::IsNullOrWhiteSpace([string]$legacyScreenshotFrames)) {
        $map["engineScreenshotFrames"] = $legacyScreenshotFrames
    }

    if ($map.Count -eq 0) {
        return $null
    }

    return [pscustomobject]$map
}

function New-MergedFlatWorldStartSpec($WorldSpec, $SliceSpec, [string]$SliceId) {
    $map = [ordered]@{}
    foreach ($property in @($WorldSpec.PSObject.Properties)) {
        $name = [string]$property.Name
        if ($name -eq "slices") {
            continue
        }
        $map[$name] = $property.Value
    }

    if ($null -ne $SliceSpec) {
        foreach ($property in @($SliceSpec.PSObject.Properties)) {
            $map[[string]$property.Name] = $property.Value
        }
    }

    foreach ($mergedProperty in @("environment", "presentation", "capture")) {
        $mergedValue = Merge-CatalogPropertyObject (Get-PropertyValue $WorldSpec $mergedProperty) (Get-PropertyValue $SliceSpec $mergedProperty)
        if ($null -ne $mergedValue) {
            $map[$mergedProperty] = $mergedValue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($SliceId)) {
        $map["sliceId"] = $SliceId
    }

    return [pscustomobject]$map
}

function Test-NameStartsWithAnyPrefix([string]$Name, [string[]]$AllowedPrefixes) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    foreach ($prefix in @($AllowedPrefixes)) {
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            continue
        }
        if ($Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Add-EnvironmentValidationFailures {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Label,
        [object]$Environment,
        [string[]]$AllowedPrefixes
    )

    if ($null -eq $Environment) {
        return
    }

    foreach ($envEntry in @($Environment.PSObject.Properties)) {
        if (-not (Test-NameStartsWithAnyPrefix -Name ([string]$envEntry.Name) -AllowedPrefixes $AllowedPrefixes)) {
            $Failures.Add("$Label has unsupported environment variable '$($envEntry.Name)'")
        }
        if ($null -eq $envEntry.Value -or [string]::IsNullOrWhiteSpace([string]$envEntry.Value)) {
            $Failures.Add("$Label has empty environment value for '$($envEntry.Name)'")
        }
    }
}

function Add-CaptureValidationFailures {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Label,
        [object]$Capture
    )

    if ($null -eq $Capture) {
        return
    }

    $runSeconds = $null
    foreach ($propertyName in @("runSeconds", "crashReportSettleSeconds")) {
        $value = Get-PropertyValue $Capture $propertyName
        if ($null -eq $value) {
            continue
        }
        try {
            $number = [int]$value
            if ($propertyName -eq "runSeconds") {
                $runSeconds = $number
            }
            if ($propertyName -eq "runSeconds" -and $number -le 0) {
                $Failures.Add("$Label capture.$propertyName must be positive")
            }
            if ($propertyName -eq "crashReportSettleSeconds" -and $number -lt 0) {
                $Failures.Add("$Label capture.$propertyName must be zero or positive")
            }
        }
        catch {
            $Failures.Add("$Label capture.$propertyName is not an integer")
        }
    }

    $captureSeconds = Get-PropertyValue $Capture "captureSeconds"
    if ($null -ne $captureSeconds) {
        foreach ($value in @($captureSeconds)) {
            try {
                $number = [int]$value
                if ($number -lt 0) {
                    $Failures.Add("$Label capture.captureSeconds contains a negative value")
                }
                if ($null -ne $runSeconds -and $number -gt $runSeconds) {
                    $Failures.Add("$Label capture.captureSeconds value $number exceeds runSeconds $runSeconds")
                }
            }
            catch {
                $Failures.Add("$Label capture.captureSeconds contains a non-integer value")
            }
        }
    }

    $frameText = [string](Get-PropertyValue $Capture "engineScreenshotFrames")
    if (-not [string]::IsNullOrWhiteSpace($frameText)) {
        foreach ($frame in @($frameText -split ",")) {
            $trimmed = $frame.Trim()
            $number = 0
            if (-not [int]::TryParse($trimmed, [ref]$number) -or $number -le 0) {
                $Failures.Add("$Label capture.engineScreenshotFrames contains invalid frame '$trimmed'")
            }
        }
    }

    $readyFrame = Get-PropertyValue $Capture "engineScreenshotReadyFrames"
    if ($null -ne $readyFrame) {
        try {
            if ([int]$readyFrame -lt 0) {
                $Failures.Add("$Label capture.engineScreenshotReadyFrames must be zero or positive")
            }
        }
        catch {
            $Failures.Add("$Label capture.engineScreenshotReadyFrames is not an integer")
        }
    }

    $engineScreenshotEnabled = Get-PropertyValue $Capture "engineScreenshotEnabled"
    if ($null -ne $engineScreenshotEnabled -and $engineScreenshotEnabled -isnot [bool]) {
        $Failures.Add("$Label capture.engineScreenshotEnabled must be boolean")
    }
    elseif ($null -ne $engineScreenshotEnabled -and [bool]$engineScreenshotEnabled -and [string]::IsNullOrWhiteSpace($frameText)) {
        $Failures.Add("$Label capture.engineScreenshotEnabled requires engineScreenshotFrames")
    }

    $expectedScreenshotCount = Get-PropertyValue $Capture "expectedScreenshotCount"
    if ($null -ne $expectedScreenshotCount) {
        try {
            if ([int]$expectedScreenshotCount -le 0) {
                $Failures.Add("$Label capture.expectedScreenshotCount must be positive")
            }
        }
        catch {
            $Failures.Add("$Label capture.expectedScreenshotCount is not an integer")
        }
    }
}

function Add-FlatWorldStartValidationFailures {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Label,
        [object]$Spec,
        [string[]]$AllowedPrefixes,
        [object]$DefaultCapture
    )

    if ($null -eq $Spec) {
        $Failures.Add("$Label is empty")
        return
    }

    Add-EnvironmentValidationFailures -Failures $Failures -Label $Label -Environment (Get-PropertyValue $Spec "environment") -AllowedPrefixes $AllowedPrefixes
    $capture = Merge-CatalogPropertyObject $DefaultCapture (Get-PropertyValue $Spec "capture")
    Add-CaptureValidationFailures -Failures $Failures -Label $Label -Capture $capture
}

function Add-ActorVisualReviewValidationFailures {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Path,
        [string[]]$KnownFailureClasses,
        [string[]]$KnownWarningClasses
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path) {
        ++$lineNumber
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $row = $line | ConvertFrom-Json
        }
        catch {
            $Failures.Add("Actor visual review '$Path' line $lineNumber is not valid JSON: $($_.Exception.Message)")
            continue
        }

        $label = "Actor visual review '$Path' line $lineNumber"
        if ([int](Get-PropertyValue $row "schemaVersion") -ne 1) {
            $Failures.Add("$label has unexpected schemaVersion '$([string](Get-PropertyValue $row "schemaVersion"))'")
        }
        if ([string](Get-PropertyValue $row "evidenceKind") -ne "actor-visual-review") {
            $Failures.Add("$label must have evidenceKind actor-visual-review")
        }

        $status = [string](Get-PropertyValue $row "status")
        if (@("pass", "questionable", "fail") -notcontains $status) {
            $Failures.Add("$label has invalid status '$status'")
        }

        $failureClasses = @(Get-TextArray (Get-PropertyValue $row "failureClasses"))
        $warningClasses = @(Get-TextArray (Get-PropertyValue $row "warningClasses"))
        if ($status -eq "fail" -and $failureClasses.Count -eq 0) {
            $Failures.Add("$label is fail but declares no failureClasses")
        }
        foreach ($class in $failureClasses) {
            if ($KnownFailureClasses -notcontains $class) {
                $Failures.Add("$label uses unknown failureClass '$class'")
            }
        }
        foreach ($class in $warningClasses) {
            if ($KnownWarningClasses -notcontains $class) {
                $Failures.Add("$label uses unknown warningClass '$class'")
            }
        }
    }
}

function Add-ActorProofStatusValidationFailures {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Path,
        [string[]]$KnownFailureClasses,
        [string[]]$KnownWarningClasses
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path) {
        ++$lineNumber
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $row = $line | ConvertFrom-Json
        }
        catch {
            $Failures.Add("Actor proof status '$Path' line $lineNumber is not valid JSON: $($_.Exception.Message)")
            continue
        }

        $label = "Actor proof status '$Path' line $lineNumber"
        if ([int](Get-PropertyValue $row "schemaVersion") -ne 1) {
            $Failures.Add("$label has unexpected schemaVersion '$([string](Get-PropertyValue $row "schemaVersion"))'")
        }
        if ([string](Get-PropertyValue $row "evidenceKind") -ne "actor-proof-status") {
            $Failures.Add("$label must have evidenceKind actor-proof-status")
        }

        $status = [string](Get-PropertyValue $row "status")
        if (@("pass", "questionable", "fail") -notcontains $status) {
            $Failures.Add("$label has invalid status '$status'")
        }
        if ($status -eq "fail" -and @(Get-TextArray (Get-PropertyValue $row "failureClasses")).Count -eq 0) {
            $Failures.Add("$label is fail but declares no failureClasses")
        }

        foreach ($fieldName in @("runtimeStatus", "rigPoseStatus", "visualReviewStatus")) {
            $fieldValue = [string](Get-PropertyValue $row $fieldName)
            if (@("pass", "questionable", "fail", "missing") -notcontains $fieldValue) {
                $Failures.Add("$label has invalid $fieldName '$fieldValue'")
            }
        }
        foreach ($fieldName in @("partTelemetryStatus", "renderLiveStatus", "faceAttachmentStatus", "actorBasisStatus", "rootAttachmentStatus")) {
            $fieldRawValue = Get-PropertyValue $row $fieldName
            if ($null -eq $fieldRawValue) {
                continue
            }
            $fieldValue = [string]$fieldRawValue
            if (@("pass", "questionable", "fail", "missing") -notcontains $fieldValue) {
                $Failures.Add("$label has invalid $fieldName '$fieldValue'")
            }
        }

        $failureClasses = @(Get-TextArray (Get-PropertyValue $row "failureClasses"))
        $warningClasses = @(Get-TextArray (Get-PropertyValue $row "warningClasses"))
        foreach ($class in $failureClasses) {
            if ($KnownFailureClasses -notcontains $class) {
                $Failures.Add("$label uses unknown failureClass '$class'")
            }
        }
        foreach ($class in $warningClasses) {
            if ($KnownWarningClasses -notcontains $class) {
                $Failures.Add("$label uses unknown warningClass '$class'")
            }
        }

        if ([string](Get-PropertyValue $row "visualReviewStatus") -eq "missing") {
            $Failures.Add("$label has missing visualReviewStatus; actor proof status must not hide unreviewed screenshots")
        }

        $sourceSkinningContainment = Get-PropertyValue $row "sourceSkinningContainment"
        if ($null -ne $sourceSkinningContainment -and [bool]$sourceSkinningContainment) {
            if ($status -eq "pass") {
                $Failures.Add("$label uses source skinning containment but still passes")
            }
            if ($failureClasses -notcontains "actor-pose-invalid") {
                $Failures.Add("$label uses source skinning containment without actor-pose-invalid failure class")
            }
            if ($warningClasses -notcontains "actor-runtime-suppressed") {
                $Failures.Add("$label uses source skinning containment without actor-runtime-suppressed warning class")
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $ContractPath)) {
    $failures.Add("Missing audit contract: $ContractPath")
}

foreach ($path in @($StartsPath, $ScreenshotEvidencePolicyPath, $ActorAnimationPolicyPath, $AdventureActorCatalogPath, $AdventureActorRetainedStopsPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        $failures.Add("Missing audit config: $path")
    }
}

if (-not (Test-Path -LiteralPath $ActorVisualReviewScriptPath)) {
    $failures.Add("Missing actor visual review helper: $ActorVisualReviewScriptPath")
}
if (-not (Test-Path -LiteralPath $ActorProofStatusScriptPath)) {
    $failures.Add("Missing actor proof status helper: $ActorProofStatusScriptPath")
}

if ($failures.Count -eq 0) {
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
    $starts = Get-Content -LiteralPath $StartsPath -Raw | ConvertFrom-Json
    $screenshotPolicy = Get-Content -LiteralPath $ScreenshotEvidencePolicyPath -Raw | ConvertFrom-Json
    $actorAnimationPolicy = Get-Content -LiteralPath $ActorAnimationPolicyPath -Raw | ConvertFrom-Json
    $adventureActorCatalog = Get-Content -LiteralPath $AdventureActorCatalogPath -Raw | ConvertFrom-Json
    $adventureActorRetainedStops = Get-Content -LiteralPath $AdventureActorRetainedStopsPath -Raw | ConvertFrom-Json

    if ($contract.schemaVersion -ne 1) {
        $failures.Add("Unexpected audit contract schema version: $($contract.schemaVersion)")
    }
    if ($starts.schemaVersion -ne 1) {
        $failures.Add("Unexpected flat-world starts schema version: $($starts.schemaVersion)")
    }
    if ($screenshotPolicy.schemaVersion -ne 1) {
        $failures.Add("Unexpected screenshot evidence policy schema version: $($screenshotPolicy.schemaVersion)")
    }
    if ($actorAnimationPolicy.schemaVersion -ne 1) {
        $failures.Add("Unexpected actor animation policy schema version: $($actorAnimationPolicy.schemaVersion)")
    }
    if ($adventureActorCatalog.schemaVersion -ne 1) {
        $failures.Add("Unexpected adventure actor catalog schema version: $($adventureActorCatalog.schemaVersion)")
    }
    if ($adventureActorRetainedStops.schemaVersion -ne 1) {
        $failures.Add("Unexpected adventure actor retained stops schema version: $($adventureActorRetainedStops.schemaVersion)")
    }

    $failureClasses = @($contract.failureClasses | ForEach-Object { [string]$_ })
    if ($failureClasses.Count -eq 0) {
        $failures.Add("Audit contract must declare failureClasses")
    }
    $warningClasses = @($contract.warningClasses | ForEach-Object { [string]$_ })
    if ($warningClasses.Count -eq 0) {
        $failures.Add("Audit contract must declare warningClasses")
    }
    Add-ActorVisualReviewValidationFailures `
        -Failures $failures `
        -Path $ActorVisualReviewPath `
        -KnownFailureClasses $failureClasses `
        -KnownWarningClasses $warningClasses
    Add-ActorProofStatusValidationFailures `
        -Failures $failures `
        -Path $ActorProofStatusPath `
        -KnownFailureClasses $failureClasses `
        -KnownWarningClasses $warningClasses
    Add-AdventureActorRetentionValidationFailures `
        -Failures $failures `
        -AdventureCatalog $adventureActorCatalog `
        -RetentionCatalog $adventureActorRetainedStops

    $environmentPolicy = Get-PropertyValue (Get-PropertyValue $starts "defaults") "environmentPolicy"
    $allowedEnvironmentPrefixes = @(Get-TextArray (Get-PropertyValue $environmentPolicy "allowedPrefixes"))
    if ($allowedEnvironmentPrefixes.Count -eq 0) {
        $failures.Add("Flat-world starts missing defaults.environmentPolicy.allowedPrefixes")
    }
    $rawDefaultCapture = Get-PropertyValue (Get-PropertyValue $starts "defaults") "capture"
    $defaultCaptureSpec = Get-CatalogDefaultCaptureSpec $starts
    if ($null -eq $rawDefaultCapture) {
        $failures.Add("Flat-world starts missing defaults.capture")
    }
    elseif ($null -eq $defaultCaptureSpec) {
        $failures.Add("Flat-world starts defaults.capture is empty")
    }
    else {
        Add-CaptureValidationFailures -Failures $failures -Label "Flat-world starts defaults" -Capture $defaultCaptureSpec
    }

    $requiredWorlds = @(
        "morrowind",
        "oblivion",
        "fallout3",
        "fallout_new_vegas",
        "skyrim_2011",
        "skyrim_vr",
        "fallout4",
        "fallout4_vr",
        "fallout76",
        "starfield"
    )
    $worldIds = @($contract.targetWorlds | ForEach-Object { $_.id })
    foreach ($id in $requiredWorlds) {
        if ($worldIds -notcontains $id) {
            $failures.Add("Audit contract missing target world: $id")
        }
    }

    $passIds = @($contract.passes | ForEach-Object { $_.id })
    foreach ($id in @("profile-isolation", "archive-inventory", "plugin-record-inventory", "cell-catalog", "cell-load-smoke", "asset-decode", "actor-catalog", "actor-render-proof", "zone-traversal", "regression-promotion")) {
        if ($passIds -notcontains $id) {
            $failures.Add("Audit contract missing pass: $id")
        }
    }

    foreach ($pass in @($contract.passes)) {
        if (-not $pass.id) {
            $failures.Add("Audit contract contains a pass without id")
        }
        if (-not $pass.order) {
            $failures.Add("Audit pass '$($pass.id)' has no order")
        }
        if (@($pass.appliesToTracks).Count -eq 0) {
            $failures.Add("Audit pass '$($pass.id)' has no appliesToTracks")
        }
        if (@($pass.evidence).Count -eq 0) {
            $failures.Add("Audit pass '$($pass.id)' has no evidence paths")
        }
        if (-not $pass.gate) {
            $failures.Add("Audit pass '$($pass.id)' has no gate")
        }
    }

    $starfield = @($contract.targetWorlds | Where-Object { $_.id -eq "starfield" } | Select-Object -First 1)
    if ($null -eq $starfield) {
        $failures.Add("Audit contract missing Starfield target row")
    }
    else {
        if ($starfield.track -ne "asset-research") {
            $failures.Add("Starfield must stay on asset-research track until explicitly promoted")
        }
        if ($starfield.runtimePromotionAllowed -ne $false) {
            $failures.Add("Starfield runtimePromotionAllowed must be false")
        }
    }

    $fallout76 = @($contract.targetWorlds | Where-Object { $_.id -eq "fallout76" } | Select-Object -First 1)
    if ($null -ne $fallout76 -and $fallout76.runtimePromotionAllowed -ne $false) {
        $failures.Add("Fallout 76 runtimePromotionAllowed must be false")
    }

    $presentation = $starts.defaults.presentation
    if ($null -eq $presentation) {
        $failures.Add("Flat-world starts missing defaults.presentation")
    }
    else {
        if (@($presentation.hideGuiForSupportTiers).Count -eq 0) {
            $failures.Add("Flat-world starts defaults.presentation must declare hideGuiForSupportTiers")
        }
        if ($presentation.hideGuiForSupportTiers -notcontains "walking-sim") {
            $failures.Add("Flat-world starts presentation policy must cover walking-sim")
        }
    }

    if (-not $screenshotPolicy.defaultMissingImageFailureClass) {
        $failures.Add("Screenshot evidence policy missing defaultMissingImageFailureClass")
    }
    elseif ($failureClasses -notcontains [string]$screenshotPolicy.defaultMissingImageFailureClass) {
        $failures.Add("Screenshot evidence policy uses unknown defaultMissingImageFailureClass '$($screenshotPolicy.defaultMissingImageFailureClass)'")
    }
    foreach ($defaultClassName in @("defaultNoScreenshotFailureClass", "defaultNonZeroExitFailureClass")) {
        $defaultClass = [string](Get-PropertyValue $screenshotPolicy $defaultClassName)
        if ([string]::IsNullOrWhiteSpace($defaultClass)) {
            $failures.Add("Screenshot evidence policy missing $defaultClassName")
        }
        elseif ($failureClasses -notcontains $defaultClass) {
            $failures.Add("Screenshot evidence policy uses unknown $defaultClassName '$defaultClass'")
        }
    }
    if (@(Get-TextArray (Get-PropertyValue $screenshotPolicy "ignoredManifestStatuses")) -notcontains "dry-run") {
        $failures.Add("Screenshot evidence policy must ignore dry-run manifests")
    }
    $ignoreHarnessTerminatedExit = Get-PropertyValue $screenshotPolicy "defaultNonZeroExitIgnoreWhenHarnessTerminated"
    if ($null -eq $ignoreHarnessTerminatedExit -or $ignoreHarnessTerminatedExit -isnot [bool]) {
        $failures.Add("Screenshot evidence policy defaultNonZeroExitIgnoreWhenHarnessTerminated must be boolean")
    }

    $imageQualityRules = Get-PropertyValue $screenshotPolicy "imageQualityRules"
    if ($null -eq $imageQualityRules) {
        $failures.Add("Screenshot evidence policy missing imageQualityRules")
    }
    else {
        foreach ($propertyName in @("minimumProofWidth", "minimumProofHeight")) {
            $value = Get-PropertyValue $imageQualityRules $propertyName
            if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
                $failures.Add("Screenshot evidence policy imageQualityRules missing $propertyName")
                continue
            }
            try {
                $number = [int]$value
                if ($number -le 0) {
                    $failures.Add("Screenshot evidence policy imageQualityRules.$propertyName must be positive")
                }
            }
            catch {
                $failures.Add("Screenshot evidence policy imageQualityRules.$propertyName must be an integer")
            }
        }

        $hardFailureClasses = @(Get-TextArray (Get-PropertyValue $imageQualityRules "hardFailureClasses"))
        if ($hardFailureClasses.Count -eq 0) {
            $failures.Add("Screenshot evidence policy imageQualityRules must declare hardFailureClasses")
        }
        foreach ($class in $hardFailureClasses) {
            if ($failureClasses -notcontains $class) {
                $failures.Add("Screenshot evidence policy imageQualityRules uses unknown hard failure class '$class'")
            }
        }
    }

    if (@($screenshotPolicy.manifestStatusRules).Count -eq 0) {
        $failures.Add("Screenshot evidence policy has no manifestStatusRules")
    }
    foreach ($rule in @($screenshotPolicy.manifestStatusRules)) {
        if (-not $rule.id) {
            $failures.Add("Screenshot evidence manifest rule without id")
        }
        if ($rule.severity -ne "warning" -and $rule.severity -ne "failure") {
            $failures.Add("Screenshot evidence manifest rule '$($rule.id)' has invalid severity '$($rule.severity)'")
        }
        if ($rule.status -and @("pass", "questionable", "fail") -notcontains $rule.status) {
            $failures.Add("Screenshot evidence manifest rule '$($rule.id)' has invalid status '$($rule.status)'")
        }
        $match = Get-PropertyValue $rule "match"
        if ($null -eq $match) {
            $failures.Add("Screenshot evidence manifest rule '$($rule.id)' has no match")
        }
        else {
            $matchProperties = @($match.PSObject.Properties)
            if ($matchProperties.Count -eq 0) {
                $failures.Add("Screenshot evidence manifest rule '$($rule.id)' has empty match")
            }
            $statusPattern = [string](Get-PropertyValue $match "statusPattern")
            if (-not [string]::IsNullOrWhiteSpace($statusPattern)) {
                try {
                    [regex]::new($statusPattern) | Out-Null
                }
                catch {
                    $failures.Add("Screenshot evidence manifest rule '$($rule.id)' has invalid statusPattern '$statusPattern': $($_.Exception.Message)")
                }
            }
        }
        foreach ($class in @(Get-TextArray (Get-PropertyValue $rule "failureClasses"))) {
            if ($failureClasses -notcontains $class) {
                $failures.Add("Screenshot evidence manifest rule '$($rule.id)' uses unknown failureClass '$class'")
            }
        }
        foreach ($class in @(Get-TextArray (Get-PropertyValue $rule "warningClasses"))) {
            if ($warningClasses -notcontains $class) {
                $failures.Add("Screenshot evidence manifest rule '$($rule.id)' uses unknown warningClass '$class'")
            }
        }
        $genericClass = [string](Get-PropertyValue $rule "class")
        if (-not [string]::IsNullOrWhiteSpace($genericClass)) {
            if ($rule.severity -eq "warning" -and $warningClasses -notcontains $genericClass) {
                $failures.Add("Screenshot evidence manifest rule '$($rule.id)' uses unknown warning class '$genericClass'")
            }
            elseif ($rule.severity -eq "failure" -and $failureClasses -notcontains $genericClass) {
                $failures.Add("Screenshot evidence manifest rule '$($rule.id)' uses unknown failure class '$genericClass'")
            }
        }
    }
    if (@($screenshotPolicy.missingImageResourceRules).Count -eq 0) {
        $failures.Add("Screenshot evidence policy has no missingImageResourceRules")
    }
    foreach ($rule in @($screenshotPolicy.missingImageResourceRules)) {
        if (-not $rule.id) {
            $failures.Add("Screenshot evidence policy contains a rule without id")
        }
        if ($rule.severity -ne "warning" -and $rule.severity -ne "failure") {
            $failures.Add("Screenshot evidence policy rule '$($rule.id)' has invalid severity '$($rule.severity)'")
        }
        elseif ($rule.severity -eq "failure" -and $failureClasses -notcontains [string]$rule.id) {
            $failures.Add("Screenshot evidence policy rule '$($rule.id)' is not listed in contract failureClasses")
        }
        elseif ($rule.severity -eq "warning" -and $warningClasses -notcontains [string]$rule.id) {
            $failures.Add("Screenshot evidence policy rule '$($rule.id)' is not listed in contract warningClasses")
        }
        if (@($rule.patterns).Count -eq 0) {
            $failures.Add("Screenshot evidence policy rule '$($rule.id)' has no patterns")
        }
        foreach ($pattern in @($rule.patterns)) {
            try {
                [regex]::new([string]$pattern) | Out-Null
            }
            catch {
                $failures.Add("Screenshot evidence policy rule '$($rule.id)' has invalid regex '$pattern': $($_.Exception.Message)")
            }
        }
    }

    if (@($screenshotPolicy.runtimeLogRules).Count -eq 0) {
        $failures.Add("Screenshot evidence policy has no runtimeLogRules")
    }
    foreach ($rule in @($screenshotPolicy.runtimeLogRules)) {
        if (-not $rule.id) {
            $failures.Add("Screenshot evidence runtime rule without id")
        }
        if ($rule.severity -ne "warning" -and $rule.severity -ne "failure") {
            $failures.Add("Screenshot evidence runtime rule '$($rule.id)' has invalid severity '$($rule.severity)'")
        }
        elseif ($rule.severity -eq "failure" -and $failureClasses -notcontains [string]$rule.id) {
            $failures.Add("Screenshot evidence runtime rule '$($rule.id)' is not listed in contract failureClasses")
        }
        elseif ($rule.severity -eq "warning" -and $warningClasses -notcontains [string]$rule.id) {
            $failures.Add("Screenshot evidence runtime rule '$($rule.id)' is not listed in contract warningClasses")
        }
        if (@($rule.patterns).Count -eq 0) {
            $failures.Add("Screenshot evidence runtime rule '$($rule.id)' has no patterns")
        }
        foreach ($pattern in @($rule.patterns)) {
            try {
                [regex]::new([string]$pattern) | Out-Null
            }
            catch {
                $failures.Add("Screenshot evidence runtime rule '$($rule.id)' has invalid regex '$pattern': $($_.Exception.Message)")
            }
        }
    }

    $actorRuntimeLedger = Get-PropertyValue $screenshotPolicy "actorRuntimeLedger"
    if ($null -eq $actorRuntimeLedger) {
        $failures.Add("Screenshot evidence policy missing actorRuntimeLedger")
    }
    else {
        foreach ($patternName in @("initializedActorPattern", "idleAnimationMissingPattern", "registeredCharacterControllerPattern")) {
            $pattern = [string](Get-PropertyValue $actorRuntimeLedger $patternName)
            if ([string]::IsNullOrWhiteSpace($pattern)) {
                $failures.Add("Actor runtime ledger missing $patternName")
                continue
            }
            try {
                [regex]::new($pattern) | Out-Null
            }
            catch {
                $failures.Add("Actor runtime ledger $patternName has invalid regex '$pattern': $($_.Exception.Message)")
            }
        }

        if (@($actorRuntimeLedger.rules).Count -eq 0) {
            $failures.Add("Actor runtime ledger has no rules")
        }
        foreach ($rule in @($actorRuntimeLedger.rules)) {
            if (-not $rule.id) {
                $failures.Add("Actor runtime ledger contains a rule without id")
            }
            if ($rule.severity -ne "warning" -and $rule.severity -ne "failure") {
                $failures.Add("Actor runtime ledger rule '$($rule.id)' has invalid severity '$($rule.severity)'")
            }
            if (-not $rule.source) {
                $failures.Add("Actor runtime ledger rule '$($rule.id)' has no source")
            }
            if (@("equals", "notEquals", "greaterThan", "greaterThanOrEqual", "lessThan", "lessThanOrEqual") -notcontains $rule.operator) {
                $failures.Add("Actor runtime ledger rule '$($rule.id)' has unsupported operator '$($rule.operator)'")
            }
            if (-not $rule.failureClass) {
                $failures.Add("Actor runtime ledger rule '$($rule.id)' has no failureClass")
            }
            elseif ($rule.severity -eq "failure" -and $failureClasses -notcontains [string]$rule.failureClass) {
                $failures.Add("Actor runtime ledger rule '$($rule.id)' uses unknown failureClass '$($rule.failureClass)'")
            }
            elseif ($rule.severity -eq "warning" -and $warningClasses -notcontains [string]$rule.failureClass) {
                $failures.Add("Actor runtime ledger rule '$($rule.id)' uses unknown warning class '$($rule.failureClass)'")
            }
            $unlessValue = Get-PropertyValue $rule "unless"
            $unlessRules = if ($null -eq $unlessValue) { @() } else { @($unlessValue) }
            foreach ($unlessRule in $unlessRules) {
                if ($null -eq $unlessRule) {
                    continue
                }
                $unlessSource = Get-PropertyValue $unlessRule "source"
                $unlessOperator = Get-PropertyValue $unlessRule "operator"
                if (-not $unlessSource) {
                    $failures.Add("Actor runtime ledger rule '$($rule.id)' has unless clause without source")
                }
                if (@("equals", "notEquals", "greaterThan", "greaterThanOrEqual", "lessThan", "lessThanOrEqual") -notcontains $unlessOperator) {
                    $failures.Add("Actor runtime ledger rule '$($rule.id)' has unless clause with unsupported operator '$unlessOperator'")
                }
            }
        }
    }

    foreach ($worldEntry in @($starts.worlds.PSObject.Properties)) {
        $worldStartSpec = New-MergedFlatWorldStartSpec -WorldSpec $worldEntry.Value -SliceSpec $null -SliceId ""
        Add-FlatWorldStartValidationFailures -Failures $failures -Label "Flat-world start '$($worldEntry.Name)'" -Spec $worldStartSpec -AllowedPrefixes $allowedEnvironmentPrefixes -DefaultCapture $defaultCaptureSpec
        $slices = Get-PropertyValue $worldEntry.Value "slices"
        if ($null -eq $slices) {
            continue
        }
        foreach ($sliceEntry in @($slices.PSObject.Properties)) {
            $sliceLabel = "Flat-world start '$($worldEntry.Name)' slice '$($sliceEntry.Name)'"
            if ([string]::IsNullOrWhiteSpace([string]$sliceEntry.Name)) {
                $failures.Add("Flat-world start '$($worldEntry.Name)' has a slice without id")
            }
            $sliceStartSpec = New-MergedFlatWorldStartSpec -WorldSpec $worldEntry.Value -SliceSpec $sliceEntry.Value -SliceId ([string]$sliceEntry.Name)
            $resolvedStartCell = [string](Get-PropertyValue $sliceStartSpec "startCell")
            if ([string]::IsNullOrWhiteSpace($resolvedStartCell)) {
                $failures.Add("$sliceLabel has no startCell and cannot inherit one")
            }
            Add-FlatWorldStartValidationFailures -Failures $failures -Label $sliceLabel -Spec $sliceStartSpec -AllowedPrefixes $allowedEnvironmentPrefixes -DefaultCapture $defaultCaptureSpec

            $resolvedValidation = Get-PropertyValue $sliceStartSpec "validation"
            if ($true -eq (Get-PropertyValue $resolvedValidation "requirePortraitAcceptanceTelemetry")) {
                $resolvedEnvironment = Get-PropertyValue $sliceStartSpec "environment"
                if ([string](Get-PropertyValue $resolvedEnvironment "OPENMW_WORLD_VIEWER_REQUIRE_PORTRAIT_CLEAR") -ne "1") {
                    $failures.Add("$sliceLabel requires portrait acceptance telemetry but does not enable OPENMW_WORLD_VIEWER_REQUIRE_PORTRAIT_CLEAR=1")
                }
                $resolvedCapture = Merge-CatalogPropertyObject $defaultCaptureSpec (Get-PropertyValue $sliceStartSpec "capture")
                $portraitExpectedCount = Get-PropertyValue $resolvedCapture "expectedScreenshotCount"
                $portraitExpectedCountValid = $false
                if ($null -ne $portraitExpectedCount) {
                    try {
                        $portraitExpectedCountValid = [int]$portraitExpectedCount -gt 0
                    }
                    catch {
                        $portraitExpectedCountValid = $false
                    }
                }
                if (-not $portraitExpectedCountValid) {
                    $failures.Add("$sliceLabel requires portrait acceptance telemetry but has no positive capture.expectedScreenshotCount")
                }
            }

            $sequenceCount = Get-CameraSequenceCount $sliceStartSpec
            if ($sequenceCount -gt 1) {
                $resolvedCapture = Merge-CatalogPropertyObject $defaultCaptureSpec (Get-PropertyValue $sliceStartSpec "capture")
                $expectedScreenshotCount = Get-PropertyValue $resolvedCapture "expectedScreenshotCount"
                $expectedScreenshotCountInt = $null
                if ($null -eq $expectedScreenshotCount) {
                    $failures.Add("$sliceLabel has a multi-keyframe camera sequence but no capture.expectedScreenshotCount")
                }
                else {
                    try {
                        $expectedScreenshotCountInt = [int]$expectedScreenshotCount
                        if ($expectedScreenshotCountInt -lt $sequenceCount) {
                            $failures.Add("$sliceLabel capture.expectedScreenshotCount is less than camera sequence keyframe count")
                        }
                    }
                    catch {
                        $failures.Add("$sliceLabel capture.expectedScreenshotCount is not an integer")
                    }
                }

                $captureSecondCount = Get-ValueCount (Get-PropertyValue $resolvedCapture "captureSeconds")
                if ($captureSecondCount -ne 1) {
                    $failures.Add("$sliceLabel has a multi-keyframe camera sequence and must use one capture second to drain the burst from one process")
                }

                $engineScreenshotFrameCount = Get-DelimitedValueCount ([string](Get-PropertyValue $resolvedCapture "engineScreenshotFrames"))
                if ($engineScreenshotFrameCount -lt $sequenceCount) {
                    $failures.Add("$sliceLabel capture.engineScreenshotFrames count is less than camera sequence keyframe count")
                }
                if ($null -ne $expectedScreenshotCountInt -and $engineScreenshotFrameCount -ne $expectedScreenshotCountInt) {
                    $failures.Add("$sliceLabel capture.expectedScreenshotCount must match capture.engineScreenshotFrames count for one-process burst evidence")
                }
            }
        }
    }

    $actorAnimationWorlds = Get-PropertyValue $actorAnimationPolicy "worlds"
    if ($null -eq $actorAnimationWorlds -or @($actorAnimationWorlds.PSObject.Properties).Count -eq 0) {
        $failures.Add("Actor animation policy has no worlds")
    }
    else {
        foreach ($worldEntry in @($actorAnimationWorlds.PSObject.Properties)) {
            $worldId = [string]$worldEntry.Name
            $worldPolicy = $worldEntry.Value
            $engineEnvironment = Get-PropertyValue $worldPolicy "engineEnvironment"
            Add-EnvironmentValidationFailures -Failures $failures -Label "Actor animation policy '$worldId'" -Environment $engineEnvironment -AllowedPrefixes $allowedEnvironmentPrefixes

            $rulesValue = Get-PropertyValue $worldPolicy "rules"
            $rules = if ($null -eq $rulesValue) { @() } else { @($rulesValue) }
            if (@($rules).Count -eq 0) {
                $failures.Add("Actor animation policy '$worldId' has no rules")
                continue
            }

            foreach ($rule in $rules) {
                if (-not $rule.id) {
                    $failures.Add("Actor animation policy '$worldId' contains a rule without id")
                }
                $match = Get-PropertyValue $rule "match"
                if ($null -ne $match) {
                    foreach ($property in @($match.PSObject.Properties)) {
                        if ($property.Name.EndsWith("Pattern", [StringComparison]::Ordinal)) {
                            try {
                                [regex]::new([string]$property.Value) | Out-Null
                            }
                            catch {
                                $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' has invalid match regex '$($property.Name)': $($_.Exception.Message)")
                            }
                        }
                    }
                }

                $skeleton = [string](Get-PropertyValue $rule "skeleton")
                $requiredSourcesValue = Get-PropertyValue $rule "requiredSources"
                $requiredSources = if ($null -eq $requiredSourcesValue) { @() } else { @($requiredSourcesValue) }
                if ([string]::IsNullOrWhiteSpace($skeleton) -and @($requiredSources).Count -eq 0) {
                    $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' has no skeleton or requiredSources")
                }
                foreach ($source in $requiredSources) {
                    if (-not $source.role) {
                        $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' has required source without role")
                    }
                    if (-not $source.path) {
                        $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' has required source without path")
                    }
                    if (-not $source.failureClass) {
                        $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' has required source without failureClass")
                    }
                    elseif ($failureClasses -notcontains [string]$source.failureClass) {
                        $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' uses unknown failureClass '$($source.failureClass)'")
                    }
                }
                $optionalSourcesValue = Get-PropertyValue $rule "optionalSources"
                $optionalSources = if ($null -eq $optionalSourcesValue) { @() } else { @($optionalSourcesValue) }
                foreach ($source in $optionalSources) {
                    if (-not $source.role) {
                        $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' has optional source without role")
                    }
                    if (-not $source.path) {
                        $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' has optional source without path")
                    }
                    $warningClass = [string](Get-PropertyValue $source "warningClass")
                    if (-not [string]::IsNullOrWhiteSpace($warningClass) -and $warningClasses -notcontains $warningClass) {
                        $failures.Add("Actor animation policy '$worldId' rule '$($rule.id)' uses unknown warningClass '$warningClass'")
                    }
                }
            }
        }
    }
}

if (Test-Path -LiteralPath $SeedPath) {
    $seed = Get-Content -LiteralPath $SeedPath -Raw | ConvertFrom-Json
    if ($seed.schemaVersion -ne 1) {
        $failures.Add("Unexpected audit seed schema version: $($seed.schemaVersion)")
    }
    if (@($seed.worlds).Count -eq 0) {
        $failures.Add("Audit seed has no worlds")
    }
    foreach ($world in @($seed.worlds)) {
        if (@($world.passes).Count -eq 0) {
            $failures.Add("Audit seed world '$($world.id)' has no passes")
        }
        if ([bool]$world.runtimePromotionAllowed -and ([string]$world.installStatus -ne "ready" -or [string]$world.profileStatus -ne "generated")) {
            $failures.Add("Audit seed world '$($world.id)' allows runtime promotion without a ready generated profile")
        }
        if ([bool]$world.runtimePromotionAllowed -and [string]$world.id -match "_vr$") {
            $failures.Add("Audit seed world '$($world.id)' is VR but allows runtime promotion")
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "World audit contract validation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

if (Test-Path -LiteralPath $SeedPath) {
    $seed.worlds | Format-Table -AutoSize id, track, installStatus, profileStatus, runtimePromotionAllowed
}

Write-Host "World audit contract validation passed."
