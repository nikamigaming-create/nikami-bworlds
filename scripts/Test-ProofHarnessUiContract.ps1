param(
    [string]$ContractPath = "catalog/proof-harness-ui-contract.json",
    [string]$StartsPath = "catalog/flat-world-proof-starts.json",
    [string]$ActorAnimationPolicyPath = "catalog/actor-animation-policy.json",
    [string]$ScreenshotEvidencePolicyPath = "catalog/screenshot-evidence-policy.json",
    [string]$HarnessPath = "scripts/Invoke-RealWorldScreenshots.ps1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$failures = New-Object System.Collections.Generic.List[string]

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

foreach ($path in @($ContractPath, $StartsPath, $ActorAnimationPolicyPath, $ScreenshotEvidencePolicyPath, $HarnessPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        $failures.Add("Missing required file: $path")
    }
}

if ($failures.Count -eq 0) {
    $contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
    $starts = Get-Content -LiteralPath $StartsPath -Raw | ConvertFrom-Json
    $actorPolicy = Get-Content -LiteralPath $ActorAnimationPolicyPath -Raw | ConvertFrom-Json
    $screenshotPolicy = Get-Content -LiteralPath $ScreenshotEvidencePolicyPath -Raw | ConvertFrom-Json
    $harnessSource = Get-Content -LiteralPath $HarnessPath -Raw

    foreach ($fragment in @('[switch]$EnableSound', 'StartsWith("--no-sound"', 'soundEnabled = [bool]$EnableSound')) {
        if (-not $harnessSource.Contains($fragment)) {
            $failures.Add("Screenshot harness is missing sound-enabled proof behavior: $fragment")
        }
    }

    if ($contract.schemaVersion -ne 1) {
        $failures.Add("Unexpected proof harness UI schema version: $($contract.schemaVersion)")
    }
    if (@($contract.promotionModes) -contains "vr") {
        $failures.Add("Proof harness promotion modes must not include VR.")
    }
    if (-not (@($contract.promotionModes) -contains "flat")) {
        $failures.Add("Proof harness promotion modes must include flat.")
    }

    $requiredControls = @(
        "worldId",
        "startSlice",
        "targetKind",
        "targetId",
        "skinningMode",
        "pinActorBindRotation",
        "animationSource",
        "cameraProfile",
        "captureBurst",
        "telemetryLevel",
        "runVerdict"
    )
    $controlIds = @($contract.requiredControls | ForEach-Object { [string]$_.id })
    foreach ($control in $requiredControls) {
        if ($controlIds -notcontains $control) {
            $failures.Add("Proof harness UI missing required control: $control")
        }
    }

    $requiredActions = @(
        "proof.openPanel",
        "proof.selectSlice",
        "proof.selectTarget",
        "proof.applyRuntimeOverrides",
        "proof.captureBurst",
        "proof.emitTelemetry",
        "proof.writeManifest",
        "proof.markVisualReview"
    )
    $actionIds = @($contract.actions | ForEach-Object { [string]$_.id })
    foreach ($action in $requiredActions) {
        if ($actionIds -notcontains $action) {
            $failures.Add("Proof harness UI missing action: $action")
        }
    }

    $requiredManifestFields = @(
        "worldId",
        "startSlice",
        "targetId",
        "cameraProfile",
        "captureBurst",
        "environmentOverrides",
        "screenshots",
        "telemetryArtifacts",
        "status"
    )
    foreach ($field in $requiredManifestFields) {
        if (@($contract.requiredManifestFields) -notcontains $field) {
            $failures.Add("Proof harness UI manifest contract missing field: $field")
        }
    }

    $skinning = @($contract.requiredControls | Where-Object { $_.id -eq "skinningMode" } | Select-Object -First 1)
    foreach ($mode in @("policy", "source", "current", "auto", "invBindThenSkeleton", "skeletonThenInvBind")) {
        if (@($skinning.values) -notcontains $mode) {
            $failures.Add("Proof harness skinningMode control missing value: $mode")
        }
    }

    $captureBurst = @($contract.requiredControls | Where-Object { $_.id -eq "captureBurst" } | Select-Object -First 1)
    foreach ($burst in @("front-left-top", "orbital-8")) {
        if (@($captureBurst.values) -notcontains $burst) {
            $failures.Add("Proof harness captureBurst control missing value: $burst")
        }
    }

    $defaults = Get-PropertyValue $starts "defaults"
    $environmentPolicy = Get-PropertyValue $defaults "environmentPolicy"
    $allowedPrefixes = @((Get-PropertyValue $environmentPolicy "allowedPrefixes") | ForEach-Object { [string]$_ })
    foreach ($prefix in @("OPENMW_WORLD_VIEWER_", "OPENMW_PROOF_", "OPENMW_ESM4_")) {
        if ($allowedPrefixes -notcontains $prefix) {
            $failures.Add("Flat start environment policy missing prefix needed by proof harness UI: $prefix")
        }
    }

    foreach ($worldId in @("fallout3", "fallout_new_vegas")) {
        $worldPolicy = Get-PropertyValue $actorPolicy.worlds $worldId
        if ($null -eq $worldPolicy) {
            $failures.Add("Actor animation policy missing required world: $worldId")
            continue
        }
        $environment = Get-PropertyValue $worldPolicy "engineEnvironment"
        if ($null -eq $environment) {
            $failures.Add("Actor animation policy missing engineEnvironment for $worldId")
            continue
        }
        foreach ($name in @("OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY", "OPENMW_WORLD_VIEWER_NPC_ANIMATION_SOURCES")) {
            if ($null -eq (Get-PropertyValue $environment $name)) {
                $failures.Add("Actor animation policy $worldId missing $name")
            }
        }
    }

    if ($null -eq (Get-PropertyValue $screenshotPolicy "actorRuntimeLedger")) {
        $failures.Add("Screenshot evidence policy missing actorRuntimeLedger.")
    }
    if ($null -eq (Get-PropertyValue $screenshotPolicy "actorRenderLiveLedger")) {
        $failures.Add("Screenshot evidence policy missing actorRenderLiveLedger.")
    }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Proof harness UI contract validation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Proof harness UI contract validation passed."
