param(
    [ValidateSet("fallout_new_vegas", "fallout3", "all")]
    [string[]]$WorldId = @("fallout_new_vegas", "fallout3"),
    [ValidateSet("walkaround", "close-burst", "both")]
    [string]$ProofKind = "walkaround",
    [string]$RunId = "",
    [string]$OutputRoot = "run/actor-rendering-proofs",
    [string]$BinaryRoot = "",
    [string[]]$SetEnv = @(),
    [switch]$HideGui,
    [switch]$NoWindowCaptureFallback,
    [switch]$NoMeasure,
    [switch]$DryRun
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
    return ([System.IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

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

function Get-ActorProofStartSlice([string]$WorldId, [string]$Kind) {
    if ($WorldId -eq "fallout_new_vegas") {
        if ($Kind -eq "walkaround") { return "goodsprings-settler-actor-walkaround" }
        if ($Kind -eq "close-burst") { return "goodsprings-settler-actor-close-burst" }
    }
    if ($WorldId -eq "fallout3") {
        if ($Kind -eq "walkaround") { return "megaton-entrance-lucas-actor-walkaround" }
        if ($Kind -eq "close-burst") { return "megaton-entrance-lucas-actor-close-burst" }
    }
    throw "No actor proof start slice for world '$WorldId' proof kind '$Kind'."
}

function Get-JsonlStatuses([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $statuses = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $row = $line | ConvertFrom-Json
        $status = [string](Get-PropertyValue $row "status")
        if (-not [string]::IsNullOrWhiteSpace($status)) {
            $statuses.Add($status) | Out-Null
        }
    }
    return @($statuses.ToArray())
}

function Select-CombinedStatus([string[]]$Statuses) {
    $hasAny = $false
    $hasFail = $false
    $hasQuestionable = $false
    $hasOther = $false
    foreach ($status in @($Statuses)) {
        if ([string]::IsNullOrWhiteSpace($status)) {
            continue
        }
        $hasAny = $true
        if ($status -eq "fail") {
            $hasFail = $true
        }
        elseif ($status -eq "questionable") {
            $hasQuestionable = $true
        }
        elseif ($status -ne "pass") {
            $hasOther = $true
        }
    }
    if (-not $hasAny) { return "missing" }
    if ($hasFail) { return "fail" }
    if ($hasQuestionable) { return "questionable" }
    if ($hasOther) { return "mixed" }
    return "pass"
}

function Get-ValueCount($Value) {
    $count = 0
    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            ++$count
        }
    }
    return $count
}

function Invoke-MeasureScript([string]$ScriptName, [hashtable]$Params, [System.Collections.Generic.List[object]]$Steps) {
    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    $outputPath = [string]$Params["OutputPath"]
    try {
        & $scriptPath @Params | Out-Host
        $Steps.Add([pscustomobject][ordered]@{
            step = $ScriptName
            status = "pass"
            outputPath = (Convert-ToForwardSlash $outputPath)
            error = $null
        }) | Out-Null
        return $true
    }
    catch {
        $Steps.Add([pscustomobject][ordered]@{
            step = $ScriptName
            status = "fail"
            outputPath = (Convert-ToForwardSlash $outputPath)
            error = $_.Exception.Message
        }) | Out-Null
        Write-Warning "$ScriptName failed: $($_.Exception.Message)"
        return $false
    }
}

$expandedWorldIds = New-Object System.Collections.Generic.List[string]
foreach ($id in @($WorldId)) {
    if ($id -eq "all") {
        foreach ($expanded in @("fallout_new_vegas", "fallout3")) {
            if (-not $expandedWorldIds.Contains($expanded)) {
                $expandedWorldIds.Add($expanded) | Out-Null
            }
        }
        continue
    }
    if (-not $expandedWorldIds.Contains($id)) {
        $expandedWorldIds.Add($id) | Out-Null
    }
}

$proofKinds = if ($ProofKind -eq "both") { @("close-burst", "walkaround") } else { @($ProofKind) }
$runStamp = if ([string]::IsNullOrWhiteSpace($RunId)) { (Get-Date).ToString("yyyyMMdd-HHmmss") } else { $RunId }
$runRoot = Resolve-RepoRelativePath (Join-Path $OutputRoot $runStamp)
$screensRoot = Join-Path $runRoot "screenshots"
New-Item -ItemType Directory -Force -Path $screensRoot | Out-Null

$keeperAuditEnv = @(
    "OPENMW_ESM4_ROOT_ATTACHMENT_AUDIT=1",
    "OPENMW_ESM4_STANDING_UPPER_AUDIT=1",
    "OPENMW_PROOF_POSTURE_TARGET=player",
    "OPENMW_PROOF_POSTURE_SAMPLES=8"
)
$effectiveSetEnv = @($keeperAuditEnv + $SetEnv)

$runner = Join-Path $PSScriptRoot "Invoke-RealWorldScreenshots.ps1"
$rows = New-Object System.Collections.Generic.List[object]

foreach ($kind in @($proofKinds)) {
    foreach ($world in @($expandedWorldIds.ToArray())) {
        $startSlice = Get-ActorProofStartSlice -WorldId $world -Kind $kind
        $caseId = "$world-$kind"
        $caseScreensRoot = Join-Path $screensRoot $caseId

        $runnerParams = @{
            WorldId = @($world)
            Mode = "flat"
            StartSlice = $startSlice
            UseActorAnimationPolicyEnvironment = $true
            OutputRoot = $caseScreensRoot
            SetEnv = $effectiveSetEnv
        }
        if (-not [string]::IsNullOrWhiteSpace($BinaryRoot)) {
            $runnerParams["BinaryRoot"] = $BinaryRoot
        }
        if (-not $HideGui) {
            $runnerParams["ShowGui"] = $true
        }
        if (-not $NoWindowCaptureFallback) {
            $runnerParams["AllowWindowCaptureFallback"] = $true
        }
        if ($DryRun) {
            $runnerParams["DryRun"] = $true
        }

        Write-Host ""
        Write-Host "Actor proof: world=$world kind=$kind slice=$startSlice"
        $runnerOutput = @(& $runner @runnerParams)
        $manifestPath = $null
        if (@($runnerOutput).Count -gt 0) {
            $last = $runnerOutput[-1]
            $outputDirectory = [string](Get-PropertyValue $last "outputDirectory")
            if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
                $candidateManifest = Join-Path $outputDirectory "manifest.json"
                if (Test-Path -LiteralPath $candidateManifest -PathType Leaf) {
                    $manifestPath = [System.IO.Path]::GetFullPath($candidateManifest)
                }
            }
        }

        $measureSteps = New-Object System.Collections.Generic.List[object]
        $measure = [ordered]@{
            contactSheet = $null
            screenshotEvidence = $null
            actorRuntimeWarnings = $null
            rigPoseSanity = $null
            actorPartTelemetry = $null
            actorRenderLiveTelemetry = $null
            actorFaceAttachmentTelemetry = $null
            actorBasisTelemetry = $null
            actorRootAttachmentTelemetry = $null
            actorFabrikTelemetry = $null
            actorWeaponIkTelemetry = $null
            actorWeaponMeshTelemetry = $null
            actorLimbAnatomy = $null
            actorProofStatus = $null
        }
        $statusSummary = [ordered]@{}

        if (-not [string]::IsNullOrWhiteSpace($manifestPath) -and -not $DryRun -and -not $NoMeasure) {
            $manifestDir = Split-Path -Parent $manifestPath
            $measure.contactSheet = Join-Path $manifestDir "contact-sheet.png"
            Invoke-MeasureScript -ScriptName "New-ScreenshotContactSheet.ps1" -Params @{
                ManifestPath = $manifestPath
                OutputPath = $measure.contactSheet
            } -Steps $measureSteps | Out-Null

            $measure.screenshotEvidence = Join-Path $manifestDir "screenshot-evidence.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ScreenshotEvidence.ps1" -Params @{
                ManifestPath = @($manifestPath)
                OutputPath = $measure.screenshotEvidence
            } -Steps $measureSteps | Out-Null

            $measure.actorRuntimeWarnings = Join-Path $manifestDir "actor-runtime-warnings.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorRuntimeWarnings.ps1" -Params @{
                ManifestPath = @($manifestPath)
                IncludeClean = $true
                OutputPath = $measure.actorRuntimeWarnings
            } -Steps $measureSteps | Out-Null

            $measure.rigPoseSanity = Join-Path $manifestDir "rig-pose-sanity.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-RigPoseSanity.ps1" -Params @{
                ManifestPath = $manifestPath
                OutputPath = $measure.rigPoseSanity
            } -Steps $measureSteps | Out-Null

            $measure.actorPartTelemetry = Join-Path $manifestDir "actor-part-telemetry.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorPartTelemetry.ps1" -Params @{
                ManifestPath = @($manifestPath)
                OutputPath = $measure.actorPartTelemetry
            } -Steps $measureSteps | Out-Null

            $measure.actorRenderLiveTelemetry = Join-Path $manifestDir "actor-render-live-telemetry.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorRenderLiveTelemetry.ps1" -Params @{
                ManifestPath = @($manifestPath)
                OutputPath = $measure.actorRenderLiveTelemetry
            } -Steps $measureSteps | Out-Null

            $measure.actorFaceAttachmentTelemetry = Join-Path $manifestDir "actor-face-attachment-telemetry.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorFaceAttachmentTelemetry.ps1" -Params @{
                ManifestPath = @($manifestPath)
                OutputPath = $measure.actorFaceAttachmentTelemetry
            } -Steps $measureSteps | Out-Null

            $measure.actorBasisTelemetry = Join-Path $manifestDir "actor-basis-telemetry.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorBasisTelemetry.ps1" -Params @{
                ManifestPath = @($manifestPath)
                OutputPath = $measure.actorBasisTelemetry
            } -Steps $measureSteps | Out-Null

            $measure.actorRootAttachmentTelemetry = Join-Path $manifestDir "actor-root-attachment-telemetry.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorRootAttachmentTelemetry.ps1" -Params @{
                ManifestPath = @($manifestPath)
                OutputPath = $measure.actorRootAttachmentTelemetry
            } -Steps $measureSteps | Out-Null

            $measure.actorFabrikTelemetry = Join-Path $manifestDir "actor-fabrik-telemetry.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorFabrikTelemetry.ps1" -Params @{
                ManifestPath = $manifestPath
                OutputPath = $measure.actorFabrikTelemetry
            } -Steps $measureSteps | Out-Null

            $measure.actorWeaponIkTelemetry = Join-Path $manifestDir "actor-weapon-ik-telemetry.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorWeaponIkTelemetry.ps1" -Params @{
                ManifestPath = @($manifestPath)
                OutputPath = $measure.actorWeaponIkTelemetry
            } -Steps $measureSteps | Out-Null

            $measure.actorWeaponMeshTelemetry = Join-Path $manifestDir "actor-weapon-mesh-telemetry.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorWeaponMeshTelemetry.ps1" -Params @{
                ManifestPath = @($manifestPath)
                OutputPath = $measure.actorWeaponMeshTelemetry
            } -Steps $measureSteps | Out-Null

            $measure.actorLimbAnatomy = Join-Path $manifestDir "actor-limb-anatomy.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorLimbAnatomy.ps1" -Params @{
                ManifestPath = $manifestPath
                OutputPath = $measure.actorLimbAnatomy
            } -Steps $measureSteps | Out-Null

            $measure.actorProofStatus = Join-Path $manifestDir "actor-proof-status.jsonl"
            Invoke-MeasureScript -ScriptName "Measure-ActorProofStatus.ps1" -Params @{
                ActorRuntimePath = @($measure.actorRuntimeWarnings)
                RigPoseSanityPath = @($measure.rigPoseSanity)
                ActorPartTelemetryPath = @($measure.actorPartTelemetry)
                ActorRenderLivePath = @($measure.actorRenderLiveTelemetry)
                ActorFaceAttachmentPath = @($measure.actorFaceAttachmentTelemetry)
                ActorBasisTelemetryPath = @($measure.actorBasisTelemetry)
                ActorRootAttachmentTelemetryPath = @($measure.actorRootAttachmentTelemetry)
                ActorWeaponMeshTelemetryPath = @($measure.actorWeaponMeshTelemetry)
                ActorFabrikTelemetryPath = @($measure.actorFabrikTelemetry)
                ActorLimbAnatomyPath = @($measure.actorLimbAnatomy)
                OutputPath = $measure.actorProofStatus
            } -Steps $measureSteps | Out-Null

            foreach ($entry in @($measure.GetEnumerator())) {
                if ([string]::IsNullOrWhiteSpace([string]$entry.Value) -or [string]$entry.Key -eq "contactSheet") {
                    continue
                }
                $statusSummary[$entry.Key] = Select-CombinedStatus (Get-JsonlStatuses ([string]$entry.Value))
            }
        }

        $manifest = if (-not [string]::IsNullOrWhiteSpace($manifestPath) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        } else {
            $null
        }

        $rows.Add([pscustomobject][ordered]@{
            worldId = $world
            proofKind = $kind
            startSlice = $startSlice
            manifestPath = (Convert-ToForwardSlash $manifestPath)
            status = if ($null -ne $manifest) { [string](Get-PropertyValue $manifest "status") } else { "missing-manifest" }
            exitCode = if ($null -ne $manifest) { Get-PropertyValue $manifest "exitCode" } else { $null }
            screenshotCount = if ($null -ne $manifest) { Get-ValueCount (Get-PropertyValue $manifest "screenshots") } else { 0 }
            crashReportCount = if ($null -ne $manifest) { Get-ValueCount (Get-PropertyValue $manifest "crashReports") } else { 0 }
            contactSheet = (Convert-ToForwardSlash ([string]$measure.contactSheet))
            measure = [ordered]@{
                paths = $measure
                statuses = $statusSummary
                steps = @($measureSteps.ToArray())
            }
        }) | Out-Null
    }
}

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    createdAt = (Get-Date).ToString("o")
    runRoot = (Convert-ToForwardSlash $runRoot)
    proofKind = $ProofKind
    worldIds = @($expandedWorldIds.ToArray())
    dryRun = [bool]$DryRun
    noMeasure = [bool]$NoMeasure
    hideGui = [bool]$HideGui
    allowWindowCaptureFallback = -not [bool]$NoWindowCaptureFallback
    keeperAuditEnvironment = @($keeperAuditEnv)
    extraEnvironment = @($SetEnv)
    rows = @($rows.ToArray())
}

$summaryPath = Join-Path $runRoot "actor-rendering-proof.json"
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding ASCII
Write-Host ""
Write-Host "Actor rendering proof summary: $summaryPath"
$summary
