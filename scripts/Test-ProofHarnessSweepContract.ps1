param(
    [string]$SweepPath = "catalog/proof-harness-sweeps.json",
    [string]$StartsPath = "catalog/flat-world-proof-starts.json",
    [string]$RunnerPath = "scripts/Invoke-ProofHarnessSweep.ps1"
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

function Get-ValueCount($Value) {
    if ($null -eq $Value) {
        return 0
    }
    if ($Value -is [System.Array]) {
        return @($Value).Count
    }
    return 1
}

function Get-DelimitedValueCount([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 0
    }

    return @(($Text -split ",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

foreach ($path in @($SweepPath, $StartsPath, $RunnerPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        $failures.Add("Missing required file: $path")
    }
}

if ($failures.Count -eq 0) {
    $catalog = Get-Content -LiteralPath $SweepPath -Raw | ConvertFrom-Json
    $starts = Get-Content -LiteralPath $StartsPath -Raw | ConvertFrom-Json
    $runnerText = Get-Content -LiteralPath $RunnerPath -Raw
    $proofStatusScriptPath = "scripts/Measure-ActorProofStatus.ps1"

    if ($catalog.schemaVersion -ne 1) {
        $failures.Add("Unexpected proof harness sweep schema version: $($catalog.schemaVersion)")
    }
    foreach ($worldId in @("fallout3", "fallout_new_vegas")) {
        $world = Get-PropertyValue $catalog.worlds $worldId
        if ($null -eq $world) {
            $failures.Add("Sweep catalog missing world: $worldId")
            continue
        }
        $actorSkinning = Get-PropertyValue $world "actorSkinning"
        if (-not [bool](Get-PropertyValue $actorSkinning "enabled")) {
            $failures.Add("Sweep catalog actorSkinning disabled for $worldId")
        }
        $startSlice = [string](Get-PropertyValue $actorSkinning "startSlice")
        $startWorld = Get-PropertyValue $starts.worlds $worldId
        $slices = Get-PropertyValue $startWorld "slices"
        $slice = Get-PropertyValue $slices $startSlice
        if ($null -eq $slice) {
            $failures.Add("Sweep catalog $worldId references missing start slice: $startSlice")
        }
        else {
            $anchor = Get-PropertyValue $slice "anchor"
            $camera = Get-PropertyValue $anchor "camera"
            $sequence = Get-PropertyValue $camera "sequence"
            $sequenceCount = Get-ValueCount $sequence
            if ($sequenceCount -lt 6) {
                $failures.Add("Sweep catalog $worldId actor proof slice must include at least six close camera sequence keyframes.")
            }
            $capture = Get-PropertyValue $slice "capture"
            $frameCount = Get-DelimitedValueCount ([string](Get-PropertyValue $capture "engineScreenshotFrames"))
            $expectedScreenshotCount = Get-PropertyValue $capture "expectedScreenshotCount"
            if ($frameCount -ne $sequenceCount) {
                $failures.Add("Sweep catalog $worldId actor proof slice frame count must match camera sequence count.")
            }
            if ($null -eq $expectedScreenshotCount -or [int]$expectedScreenshotCount -ne $sequenceCount) {
                $failures.Add("Sweep catalog $worldId actor proof slice expectedScreenshotCount must match camera sequence count.")
            }
        }
        foreach ($mode in @("source", "current", "auto")) {
            if (@($actorSkinning.modes) -notcontains $mode) {
                $failures.Add("Sweep catalog $worldId missing mode: $mode")
            }
        }
    }
    foreach ($excluded in @("skyrim_vr", "fallout4_vr", "starfield")) {
        if (@($catalog.excludedWorldIds) -notcontains $excluded) {
            $failures.Add("Sweep catalog missing excluded world id: $excluded")
        }
    }
    foreach ($requiredRunnerText in @("Measure-ActorProofStatus.ps1", "Measure-ActorPartTelemetry.ps1", "Measure-ActorRenderLiveTelemetry.ps1", "Measure-ActorFaceAttachmentTelemetry.ps1", "Measure-ActorBasisTelemetry.ps1", "Measure-ActorRootAttachmentTelemetry.ps1", "Measure-ActorWeaponMeshTelemetry.ps1", "New-ScreenshotContactSheet.ps1", "actor-part-telemetry.jsonl", "actor-render-live-telemetry.jsonl", "actor-face-attachment-telemetry.jsonl", "actor-basis-telemetry.jsonl", "actor-root-attachment-telemetry.jsonl", "actor-weapon-mesh-telemetry.jsonl", "actor-proof-status.jsonl", "partTelemetryStatus", "renderLiveStatus", "faceAttachmentStatus", "actorBasisStatus", "rootAttachmentStatus", "weaponMeshStatus", "promotable")) {
        if ($runnerText -notmatch [regex]::Escape($requiredRunnerText)) {
            $failures.Add("Sweep runner must include '$requiredRunnerText' for promotion status reporting.")
        }
    }
    if (-not (Test-Path -LiteralPath "scripts/Update-ProofHarnessSweepSummary.ps1")) {
        $failures.Add("Missing proof harness sweep summary refresher.")
    }
    if (-not (Test-Path -LiteralPath $proofStatusScriptPath)) {
        $failures.Add("Missing actor proof status combiner: $proofStatusScriptPath")
    }
    else {
        $proofStatusText = Get-Content -LiteralPath $proofStatusScriptPath -Raw
        foreach ($requiredProofText in @("[string[]]`$RigPoseSanityPath", "[string[]]`$ActorPartTelemetryPath", "[string[]]`$ActorRenderLivePath", "[string[]]`$ActorFaceAttachmentPath", "[string[]]`$ActorBasisTelemetryPath", "[string[]]`$ActorRootAttachmentTelemetryPath", "[string[]]`$ActorWeaponMeshTelemetryPath", "effectiveSkinningMode", "skinningMode", "proofStatus", "environmentOverrides", "Select-EffectiveSkinningMode", "partTelemetryStatus", "renderLiveStatus", "faceAttachmentStatus", "actorBasisStatus", "rootAttachmentStatus", "weaponMeshStatus", "actorRootAttachmentTelemetry", "actorWeaponMeshTelemetry")) {
            if ($proofStatusText -notmatch [regex]::Escape($requiredProofText)) {
                $failures.Add("Actor proof status combiner must include '$requiredProofText'.")
            }
        }
    }
    if (-not (Test-Path -LiteralPath "scripts/Measure-ActorWeaponMeshTelemetry.ps1")) {
        $failures.Add("Missing actor weapon mesh telemetry measurer.")
    }
    if (-not (Test-Path -LiteralPath "scripts/Measure-ActorPartTelemetry.ps1")) {
        $failures.Add("Missing actor part telemetry measurer.")
    }
    else {
        $partTelemetryText = Get-Content -LiteralPath "scripts/Measure-ActorPartTelemetry.ps1" -Raw
        foreach ($requiredPartTelemetryText in @("runtimeFrameLevelCount", "part-space-without-frame-telemetry")) {
            if ($partTelemetryText -notmatch [regex]::Escape($requiredPartTelemetryText)) {
                $failures.Add("Actor part telemetry measurer must include '$requiredPartTelemetryText'.")
            }
        }
    }
    if (-not (Test-Path -LiteralPath "scripts/Measure-ActorRenderLiveTelemetry.ps1")) {
        $failures.Add("Missing actor render/live telemetry measurer.")
    }
    else {
        $renderLiveText = Get-Content -LiteralPath "scripts/Measure-ActorRenderLiveTelemetry.ps1" -Raw
        foreach ($requiredRenderLiveText in @("actor-render-live-split", "actor-render-live-transition", "renderInvalidRatio", "targetRenderInvalidRatio", "nonTargetRenderInvalidRatio", "live-current-pose-geometry-valid-but-render-geometry-invalid")) {
            if ($renderLiveText -notmatch [regex]::Escape($requiredRenderLiveText)) {
                $failures.Add("Actor render/live telemetry measurer must include '$requiredRenderLiveText'.")
            }
        }
    }
    if (-not (Test-Path -LiteralPath "scripts/Measure-ActorFaceAttachmentTelemetry.ps1")) {
        $failures.Add("Missing actor face attachment telemetry measurer.")
    }
    else {
        $faceAttachmentText = Get-Content -LiteralPath "scripts/Measure-ActorFaceAttachmentTelemetry.ps1" -Raw
        foreach ($requiredFaceAttachmentText in @("actor-head-render-gap", "rigged-head-source-geometry-present-but-render-geometry-missing", "FNV/ESM4 FACE DRAWABLE AUDIT", "renderSource", "headRigRenderInspectableCount")) {
            if ($faceAttachmentText -notmatch [regex]::Escape($requiredFaceAttachmentText)) {
                $failures.Add("Actor face attachment telemetry measurer must include '$requiredFaceAttachmentText'.")
            }
        }
    }
    if (-not (Test-Path -LiteralPath "scripts/Measure-ActorBasisTelemetry.ps1")) {
        $failures.Add("Missing actor basis telemetry measurer.")
    }
    else {
        $basisTelemetryText = Get-Content -LiteralPath "scripts/Measure-ActorBasisTelemetry.ps1" -Raw
        foreach ($requiredBasisTelemetryText in @("ACTOR BASIS CALLBACK AUDIT", "actor-basis-large-delta", "callbackAuditCount", "maxRotationDeltaDegrees")) {
            if ($basisTelemetryText -notmatch [regex]::Escape($requiredBasisTelemetryText)) {
                $failures.Add("Actor basis telemetry measurer must include '$requiredBasisTelemetryText'.")
            }
        }
    }
    if (-not (Test-Path -LiteralPath "scripts/Measure-ActorRootAttachmentTelemetry.ps1")) {
        $failures.Add("Missing actor root attachment telemetry measurer.")
    }
    else {
        $rootAttachmentText = Get-Content -LiteralPath "scripts/Measure-ActorRootAttachmentTelemetry.ps1" -Raw
        foreach ($requiredRootAttachmentText in @("FNV/ESM4 ACTOR ROOT ATTACHMENT AUDIT", "(?<{0}x>", "rootHandedness", "actor-root-orientation-gap", "rootAuditCount")) {
            if ($rootAttachmentText -notmatch [regex]::Escape($requiredRootAttachmentText)) {
                $failures.Add("Actor root attachment telemetry measurer must include '$requiredRootAttachmentText'.")
            }
        }
        if ($rootAttachmentText -match [regex]::Escape('(?<${0}x>')) {
            $failures.Add("Actor root attachment vector pattern must not interpolate `${0}; use String.Format placeholder '{0}'.")
        }
    }
    if (-not (Test-Path -LiteralPath "scripts/New-ScreenshotContactSheet.ps1")) {
        $failures.Add("Missing screenshot contact sheet generator.")
    }
    if (-not (Test-Path -LiteralPath "scripts/Show-ProofHarnessSweepStatus.ps1")) {
        $failures.Add("Missing proof harness sweep status viewer.")
    }
    if (-not (Test-Path -LiteralPath "scripts/Show-ActorProofArmory.ps1")) {
        $failures.Add("Missing actor proof armory viewer.")
    }
    else {
        $armoryText = Get-Content -LiteralPath "scripts/Show-ActorProofArmory.ps1" -Raw
        foreach ($requiredArmoryText in @("actor-proof-status.jsonl", "patches/openmw/experiments", "git", "ls-remote", "NoNetwork", "proofStatus", "nikami-actor-proof-armory-v1", "local-openmw-candidates.json", "actor-head-render-gap", "actor-basis-large-delta")) {
            if ($armoryText -notmatch [regex]::Escape($requiredArmoryText)) {
                $failures.Add("Actor proof armory must include '$requiredArmoryText'.")
            }
        }
    }
    if (-not (Test-Path -LiteralPath "catalog/local-openmw-candidates.json")) {
        $failures.Add("Missing local OpenMW candidate catalog.")
    }
    else {
        $candidateCatalog = Get-Content -LiteralPath "catalog/local-openmw-candidates.json" -Raw | ConvertFrom-Json
        if ($candidateCatalog.schemaVersion -ne 1) {
            $failures.Add("Unexpected local OpenMW candidate catalog schema version: $($candidateCatalog.schemaVersion)")
        }
        foreach ($requiredCandidate in @("nikami-openmw-lab-higgs-lite", "6d23344d2c Promote FNV actor truth rig basis", "b6617ab5c6 Fix FNV actor skinning and hand proof gates")) {
            if ((Get-Content -LiteralPath "catalog/local-openmw-candidates.json" -Raw) -notmatch [regex]::Escape($requiredCandidate)) {
                $failures.Add("Local OpenMW candidate catalog must include '$requiredCandidate'.")
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Proof harness sweep contract validation failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Proof harness sweep contract validation passed."
