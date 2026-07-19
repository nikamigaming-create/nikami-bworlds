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
Assert-Ledger ([int]$ledger.certifiedPlayableParityPercent -eq 0) `
    "Playable parity must remain zero until a normal Save330 baseline has durable evidence."
Assert-Ledger ([string]$ledger.provenanceGate.status -eq "fail") `
    "Provenance gate must remain red until a normal Save330 baseline exists."
Assert-Ledger ([string]$ledger.provenanceGate.requiredSave.sha256 -eq `
    "07DBDD2D7C4ABE3160628E5463A9603A40F4271042C1DA1B89F1C4A4F7DBD81F") `
    "Provenance gate does not lock exact Save330."
Assert-Ledger ([long]$ledger.provenanceGate.requiredSave.bytes -eq 3395328) `
    "Provenance gate has the wrong Save330 size."
Assert-Ledger ([string]$ledger.invalidatedIncident.status -eq "discarded") `
    "The monochrome synthetic run is not explicitly discarded."
Assert-Ledger ([string]$ledger.normalSessionBaseline.status -eq "unproven") `
    "Normal-session baseline must remain unproven until Save330 loads normally."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.normalLoadGamePath) `
    "Normal-session baseline incorrectly claims the normal load-game path."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.save330ActuallyLoaded) `
    "Normal-session baseline incorrectly claims Save330 was loaded."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.committedRuntime) `
    "Normal-session baseline incorrectly claims a committed runtime."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.durableEvidencePresent) `
    "Normal-session baseline incorrectly claims durable evidence."
Assert-Ledger (-not [bool]$ledger.normalSessionBaseline.facts.visualParity) `
    "Normal-session baseline incorrectly claims visual parity."
Assert-Ledger ([string]$ledger.legacyPromotedRuntime.labCommit -eq [string]$baseLock.compositeCheckpoint.commit) `
    "Legacy acceptance-ledger commit differs from the replay lock."
Assert-Ledger ([string]$ledger.legacyPromotedRuntime.labTree -eq [string]$baseLock.compositeCheckpoint.tree) `
    "Legacy acceptance-ledger tree differs from the replay lock."
Assert-Ledger ([int]$ledger.legacyPromotedRuntime.patchCount -eq [int]$baseLock.replayVerification.patchCount) `
    "Legacy acceptance-ledger patch count differs from the replay lock."

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
