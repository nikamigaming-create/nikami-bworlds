param(
    [string]$LedgerPath = "catalog/fnv-flat-acceptance-ledger.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if (-not [System.IO.Path]::IsPathRooted($LedgerPath)) {
    $LedgerPath = Join-Path $repoRoot $LedgerPath
}
if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
    throw "Missing FNV flat acceptance ledger: $LedgerPath"
}

$ledger = Get-Content -LiteralPath $LedgerPath -Raw | ConvertFrom-Json
$baseLockPath = Join-Path $repoRoot "catalog\openmw-base-lock.json"
$baseLock = Get-Content -LiteralPath $baseLockPath -Raw | ConvertFrom-Json
$failures = New-Object System.Collections.Generic.List[string]
function Assert-Ledger([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}

Assert-Ledger ([string]$ledger.schema -eq "nikami-fnv-flat-acceptance-ledger/v1") `
    "Unexpected acceptance-ledger schema."
Assert-Ledger (@("pass", "fail", "unproven") -contains [string]$ledger.overallStatus) `
    "Invalid overall status."
Assert-Ledger ([string]$ledger.overallStatus -eq "fail") `
    "FNV overall acceptance must remain red while any subsystem is not pass."
Assert-Ledger ([string]$ledger.vrGate -eq "blocked") `
    "VR gate must remain blocked until the complete flat ledger is green."
Assert-Ledger ([string]$ledger.normalSessionBaseline.status -eq "fail") `
    "Normal-session baseline is incorrectly promoted."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.actorNeutralized) `
    "Normal-session baseline neutralizes Easy Pete."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.dryStart) `
    "Normal-session baseline uses a dry proof cell."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.forcedWeather) `
    "Normal-session baseline forces weather."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.forcedImageSpace) `
    "Normal-session baseline forces image space."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.foregroundInputUsed) `
    "Normal-session baseline used foreground input."
Assert-Ledger ([int]$ledger.normalSessionBaseline.facts.implicitPlayerEquipmentOverrides -eq 0) `
    "Normal-session baseline contains an implicit player-equipment override."
Assert-Ledger ([bool]$ledger.normalSessionBaseline.facts.isolatedWritableConfigAndUserData) `
    "Normal-session baseline did not isolate writable config and user-data."
Assert-Ledger ([string]$ledger.promotedRuntime.labCommit -eq [string]$baseLock.compositeCheckpoint.commit) `
    "Acceptance ledger lab commit differs from the replay lock."
Assert-Ledger ([string]$ledger.promotedRuntime.labTree -eq [string]$baseLock.compositeCheckpoint.tree) `
    "Acceptance ledger lab tree differs from the replay lock."
Assert-Ledger ([int]$ledger.promotedRuntime.patchCount -eq [int]$baseLock.replayVerification.patchCount) `
    "Acceptance ledger patch count differs from the replay lock."
Assert-Ledger ([string]$ledger.promotedRuntime.runtimeBinarySha256 -eq `
    [string]$ledger.normalSessionBaseline.runtimeBinarySha256) `
    "Normal session did not use the promoted runtime binary."

$requiredSubsystems = @(
    "session-integrity",
    "level-movement-camera-scale-first-third-person",
    "neighboring-exterior-cell-streaming",
    "interior-doors-and-transition-preload",
    "natural-npcs-easy-pete-and-identity",
    "bodies-heads-faces-hair-eyes-teeth-mouth-hands-clothing-weapons-skin-materials",
    "idle-walk-turn-furniture-nearby-actor-behavior",
    "terrain-sky-clouds-weather-lighting-image-space",
    "sound-music-ambience",
    "activation-dialogue-voice-lip-result-scripts-quests",
    "inventory-hud-pip-boy-equipment",
    "retail-intro-doc-mitchell-character-creation",
    "byte-color-bit-and-timing-differentials",
    "fallout3-control",
    "morrowind-regression",
    "openmw-queue-replay"
)
$ids = @($ledger.subsystems | ForEach-Object { [string]$_.id })
Assert-Ledger (@($ids | Select-Object -Unique).Count -eq $ids.Count) `
    "Acceptance ledger contains duplicate subsystem IDs."
foreach ($id in $requiredSubsystems) {
    Assert-Ledger ($ids -contains $id) "Acceptance ledger is missing subsystem '$id'."
}
foreach ($subsystem in $ledger.subsystems) {
    Assert-Ledger (@("pass", "fail", "unproven") -contains [string]$subsystem.status) `
        "Subsystem '$($subsystem.id)' has invalid status '$($subsystem.status)'."
    Assert-Ledger (-not [string]::IsNullOrWhiteSpace([string]$subsystem.reason)) `
        "Subsystem '$($subsystem.id)' has no reason."
    if ([string]$subsystem.status -eq "pass") {
        Assert-Ledger ($null -ne $subsystem.PSObject.Properties["evidence"] -and @($subsystem.evidence).Count -gt 0) `
            "Passing subsystem '$($subsystem.id)' has no structured evidence."
    }
}
$notGreen = @($ledger.subsystems | Where-Object { [string]$_.status -ne "pass" })
Assert-Ledger ($notGreen.Count -gt 0) "Ledger has no red/unproven subsystem despite overall fail."

function Test-EvidenceEntry([object]$Evidence, [string]$Owner) {
    $path = [string]$Evidence.path
    $expectedHash = [string]$Evidence.sha256
    Assert-Ledger ($expectedHash -match '^[0-9A-F]{64}$') `
        "Evidence '$path' for '$Owner' has an invalid SHA-256."
    if ([string]::IsNullOrWhiteSpace($path)) {
        Assert-Ledger $false "Evidence for '$Owner' has no path."
        return
    }
    $resolvedPath = if ([IO.Path]::IsPathRooted($path)) {
        [IO.Path]::GetFullPath($path)
    } else {
        [IO.Path]::GetFullPath((Join-Path $repoRoot $path))
    }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        Assert-Ledger $false "Evidence '$path' for '$Owner' does not exist."
        return
    }
    $actualHash = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
    Assert-Ledger ($actualHash -ceq $expectedHash) `
        "Evidence '$path' for '$Owner' has SHA-256 $actualHash, expected $expectedHash."
}

foreach ($evidence in $ledger.normalSessionBaseline.evidence) {
    Test-EvidenceEntry $evidence "normalSessionBaseline"
}
foreach ($subsystem in $ledger.subsystems) {
    if ($null -eq $subsystem.PSObject.Properties["evidence"]) { continue }
    foreach ($evidence in @($subsystem.evidence)) {
        Test-EvidenceEntry $evidence ([string]$subsystem.id)
    }
}

if ($failures.Count -gt 0) {
    Write-Host "FNV flat acceptance-ledger failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "FNV flat acceptance ledger passed ($($notGreen.Count) subsystem(s) still red or unproven)."
