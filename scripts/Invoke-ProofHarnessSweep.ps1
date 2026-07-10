param(
    [string]$SweepPath = "catalog/proof-harness-sweeps.json",
    [string[]]$WorldId = @(),
    [ValidateSet("actor-skinning")]
    [string]$Sweep = "actor-skinning",
    [string[]]$Mode = @(),
    [string]$OutputRoot = "run/proof-harness-sweeps",
    [string[]]$SetEnv = @(),
    [switch]$DryRun,
    [switch]$NoMeasure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-TextArray($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text)
}

function ConvertTo-SafePathPart([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "default" }
    return ($Text -replace '[^A-Za-z0-9_.-]', '_')
}

function Find-ManifestObject($Output) {
    $objects = @($Output | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties["schemaVersion"] -and $null -ne $_.PSObject.Properties["worldId"]
    })
    if ($objects.Count -eq 0) { return $null }
    return $objects[-1]
}

if (-not (Test-Path -LiteralPath $SweepPath)) {
    throw "Missing proof harness sweep catalog: $SweepPath"
}

$catalog = Get-Content -LiteralPath $SweepPath -Raw | ConvertFrom-Json
if ($catalog.schemaVersion -ne 1) {
    throw "Unexpected proof harness sweep schema version: $($catalog.schemaVersion)"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $OutputRoot $stamp
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$defaultModes = @(Get-TextArray (Get-PropertyValue $catalog.defaults "actorSkinningModes"))
$worldProperties = @($catalog.worlds.PSObject.Properties)
$selectedWorldIds = if ($WorldId.Count -gt 0) {
    @($WorldId)
} else {
    @($worldProperties | Where-Object {
        $world = $_.Value
        [bool](Get-PropertyValue $world "enabled") -and [bool](Get-PropertyValue (Get-PropertyValue $world "actorSkinning") "enabled")
    } | ForEach-Object { [string]$_.Name })
}

$runner = Join-Path $PSScriptRoot "Invoke-RealWorldScreenshots.ps1"
if (-not (Test-Path -LiteralPath $runner)) {
    throw "Missing real screenshot runner: $runner"
}

$rows = New-Object System.Collections.Generic.List[object]
$manifestPaths = New-Object System.Collections.Generic.List[string]

foreach ($selectedWorldId in $selectedWorldIds) {
    $world = Get-PropertyValue $catalog.worlds $selectedWorldId
    if ($null -eq $world) {
        throw "Proof harness sweep catalog has no world '$selectedWorldId'."
    }
    if (@(Get-TextArray $catalog.excludedWorldIds) -contains $selectedWorldId) {
        throw "World '$selectedWorldId' is excluded by proof harness sweep policy."
    }

    $actorSkinning = Get-PropertyValue $world "actorSkinning"
    if ($null -eq $actorSkinning -or -not [bool](Get-PropertyValue $actorSkinning "enabled")) {
        throw "World '$selectedWorldId' has no enabled actorSkinning sweep."
    }

    $startSlice = [string](Get-PropertyValue $actorSkinning "startSlice")
    if ([string]::IsNullOrWhiteSpace($startSlice)) {
        throw "World '$selectedWorldId' actorSkinning sweep has no startSlice."
    }

    $worldModes = if ($Mode.Count -gt 0) {
        @($Mode)
    } else {
        $configuredModes = @(Get-TextArray (Get-PropertyValue $actorSkinning "modes"))
        if ($configuredModes.Count -gt 0) { $configuredModes } else { $defaultModes }
    }

    foreach ($skinningMode in $worldModes) {
        $modeSafe = ConvertTo-SafePathPart $skinningMode
        $outputLog = Join-Path $runDir ("{0}.{1}.runner.log" -f $selectedWorldId, $modeSafe)
        $envOverrides = New-Object System.Collections.Generic.List[string]
        foreach ($entry in @($SetEnv)) {
            if (-not [string]::IsNullOrWhiteSpace($entry)) {
                $envOverrides.Add($entry) | Out-Null
            }
        }
        if ($skinningMode -ne "policy") {
            $envOverrides.Add("OPENMW_ESM4_SKINNING_MODE=$skinningMode") | Out-Null
        }

        $childParameters = @{
            WorldId = @($selectedWorldId)
            Mode = "flat"
            StartSlice = $startSlice
            UseActorAnimationPolicyEnvironment = $true
            SetEnv = @($envOverrides.ToArray())
        }
        if ($DryRun) {
            $childParameters["DryRun"] = $true
        }

        Write-Host "Proof harness sweep: world=$selectedWorldId slice=$startSlice skinningMode=$skinningMode"
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & $runner @childParameters 2>&1
            $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        ($output | ForEach-Object { [string]$_ }) | Set-Content -LiteralPath $outputLog -Encoding UTF8

        $manifest = Find-ManifestObject $output
        $manifestPath = ""
        if ($null -ne $manifest) {
            $manifestPath = Join-Path ([string]$manifest.outputDirectory) "manifest.json"
            if (Test-Path -LiteralPath $manifestPath) {
                $manifestPaths.Add($manifestPath) | Out-Null
            }
        }

        $rows.Add([pscustomobject][ordered]@{
            worldId = $selectedWorldId
            sweep = $Sweep
            startSlice = $startSlice
            skinningMode = $skinningMode
            environmentOverrides = @($envOverrides.ToArray())
            status = if ($null -ne $manifest) { [string]$manifest.status } else { "runner-no-manifest" }
            exitCode = $exitCode
            manifestPath = $manifestPath
            outputLog = $outputLog
            payloadPolicy = [string](Get-PropertyValue $catalog.defaults "payloadPolicy")
        }) | Out-Null
    }
}

$measure = [ordered]@{
    screenshotEvidence = $null
    actorRuntimeWarnings = $null
    rigPoseSanity = @()
    screenshotContactSheets = @()
    actorPartTelemetry = $null
    actorRenderLiveTelemetry = $null
    actorFaceAttachmentTelemetry = $null
    actorBasisTelemetry = $null
    actorRootAttachmentTelemetry = $null
    actorWeaponMeshTelemetry = $null
    actorProofStatus = $null
}
$proofStatusRows = @()
if (-not $DryRun -and -not $NoMeasure -and $manifestPaths.Count -gt 0) {
    $screenshotLedger = Join-Path $runDir "screenshot-evidence.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ScreenshotEvidence.ps1") -ManifestPath @($manifestPaths.ToArray()) -OutputPath $screenshotLedger
    $measure.screenshotEvidence = $screenshotLedger

    foreach ($manifestPath in @($manifestPaths.ToArray())) {
        $contactSheet = Join-Path (Split-Path -Parent $manifestPath) "contact-sheet.png"
        & (Join-Path $PSScriptRoot "New-ScreenshotContactSheet.ps1") -ManifestPath $manifestPath -OutputPath $contactSheet | Out-Null
        $measure.screenshotContactSheets += $contactSheet
    }

    $actorLedger = Join-Path $runDir "actor-runtime-warnings.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ActorRuntimeWarnings.ps1") -ManifestPath @($manifestPaths.ToArray()) -IncludeClean -OutputPath $actorLedger
    $measure.actorRuntimeWarnings = $actorLedger

    foreach ($manifestPath in @($manifestPaths.ToArray())) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $rigLedger = Join-Path $runDir ("rig-pose-sanity.{0}.{1}.jsonl" -f $manifest.worldId, (Split-Path (Split-Path $manifestPath -Parent) -Leaf))
        & (Join-Path $PSScriptRoot "Measure-RigPoseSanity.ps1") -ManifestPath $manifestPath -OutputPath $rigLedger
        $measure.rigPoseSanity += $rigLedger
    }

    $partTelemetryLedger = Join-Path $runDir "actor-part-telemetry.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ActorPartTelemetry.ps1") -ManifestPath @($manifestPaths.ToArray()) -OutputPath $partTelemetryLedger
    $measure.actorPartTelemetry = $partTelemetryLedger

    $renderLiveTelemetryLedger = Join-Path $runDir "actor-render-live-telemetry.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ActorRenderLiveTelemetry.ps1") -ManifestPath @($manifestPaths.ToArray()) -OutputPath $renderLiveTelemetryLedger
    $measure.actorRenderLiveTelemetry = $renderLiveTelemetryLedger

    $faceAttachmentTelemetryLedger = Join-Path $runDir "actor-face-attachment-telemetry.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ActorFaceAttachmentTelemetry.ps1") -ManifestPath @($manifestPaths.ToArray()) -OutputPath $faceAttachmentTelemetryLedger
    $measure.actorFaceAttachmentTelemetry = $faceAttachmentTelemetryLedger

    $basisTelemetryLedger = Join-Path $runDir "actor-basis-telemetry.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ActorBasisTelemetry.ps1") -ManifestPath @($manifestPaths.ToArray()) -OutputPath $basisTelemetryLedger
    $measure.actorBasisTelemetry = $basisTelemetryLedger

    $rootAttachmentTelemetryLedger = Join-Path $runDir "actor-root-attachment-telemetry.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ActorRootAttachmentTelemetry.ps1") -ManifestPath @($manifestPaths.ToArray()) -OutputPath $rootAttachmentTelemetryLedger
    $measure.actorRootAttachmentTelemetry = $rootAttachmentTelemetryLedger

    $weaponMeshTelemetryLedger = Join-Path $runDir "actor-weapon-mesh-telemetry.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ActorWeaponMeshTelemetry.ps1") -ManifestPath @($manifestPaths.ToArray()) -OutputPath $weaponMeshTelemetryLedger
    $measure.actorWeaponMeshTelemetry = $weaponMeshTelemetryLedger

    $proofStatusLedger = Join-Path $runDir "actor-proof-status.jsonl"
    & (Join-Path $PSScriptRoot "Measure-ActorProofStatus.ps1") `
        -ActorRuntimePath @($actorLedger) `
        -RigPoseSanityPath @($measure.rigPoseSanity) `
        -ActorPartTelemetryPath @($partTelemetryLedger) `
        -ActorRenderLivePath @($renderLiveTelemetryLedger) `
        -ActorFaceAttachmentPath @($faceAttachmentTelemetryLedger) `
        -ActorBasisTelemetryPath @($basisTelemetryLedger) `
        -ActorRootAttachmentTelemetryPath @($rootAttachmentTelemetryLedger) `
        -ActorWeaponMeshTelemetryPath @($weaponMeshTelemetryLedger) `
        -OutputPath $proofStatusLedger
    $measure.actorProofStatus = $proofStatusLedger
    if (Test-Path -LiteralPath $proofStatusLedger) {
        $proofStatusRows = @(Get-Content -LiteralPath $proofStatusLedger | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object {
            $_ | ConvertFrom-Json
        })
    }
}

$promotable = $false
if (@($proofStatusRows).Count -gt 0 -and @($proofStatusRows | Where-Object { [string](Get-PropertyValue $_ "status") -ne "pass" }).Count -eq 0) {
    $promotable = $true
}

$summary = [pscustomobject][ordered]@{
    schema = "nikami-proof-harness-sweep-v1"
    createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    runDir = $runDir
    sweep = $Sweep
    dryRun = [bool]$DryRun
    noMeasure = [bool]$NoMeasure
    rows = @($rows.ToArray())
    measure = $measure
    actorProofStatus = @($proofStatusRows)
    promotable = $promotable
    promotionRule = [string](Get-PropertyValue $catalog "promotionRule")
}

$jsonPath = Join-Path $runDir "proof-harness-sweep.json"
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$markdownPath = Join-Path $runDir "summary.md"
$markdown = New-Object System.Collections.Generic.List[string]
$markdown.Add("# Proof Harness Sweep") | Out-Null
$markdown.Add("") | Out-Null
$markdown.Add("Sweep: $Sweep") | Out-Null
$markdown.Add("Dry run: $([bool]$DryRun)") | Out-Null
$markdown.Add("") | Out-Null
$markdown.Add("| World | Slice | Skinning | Status | Manifest |") | Out-Null
$markdown.Add("| --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in @($rows.ToArray())) {
    $markdown.Add("| $($row.worldId) | $($row.startSlice) | $($row.skinningMode) | $($row.status) | $($row.manifestPath) |") | Out-Null
}
$markdown.Add("") | Out-Null
if (@($proofStatusRows).Count -gt 0) {
    $markdown.Add("| World | Skinning | Proof | Runtime | Rig Pose | Part Telemetry | Render/Live | Face | Basis | Root | Weapon Mesh | Visual | Failures | Warnings |") | Out-Null
    $markdown.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |") | Out-Null
    foreach ($row in @($proofStatusRows)) {
        $failures = @((Get-PropertyValue $row "failureClasses")) -join ","
        $warnings = @((Get-PropertyValue $row "warningClasses")) -join ","
        $markdown.Add("| $($row.worldId) | $($row.effectiveSkinningMode) | $($row.status) | $($row.runtimeStatus) | $($row.rigPoseStatus) | $($row.partTelemetryStatus) | $($row.renderLiveStatus) | $($row.faceAttachmentStatus) | $($row.actorBasisStatus) | $($row.rootAttachmentStatus) | $($row.weaponMeshStatus) | $($row.visualReviewStatus) | $failures | $warnings |") | Out-Null
    }
    $markdown.Add("") | Out-Null
}
$markdown.Add("Promotion: $promotable. $($summary.promotionRule)") | Out-Null
$markdown | Set-Content -LiteralPath $markdownPath -Encoding UTF8

Write-Host "Proof harness sweep manifest: $jsonPath"
Write-Host "Proof harness sweep summary: $markdownPath"
$summary
