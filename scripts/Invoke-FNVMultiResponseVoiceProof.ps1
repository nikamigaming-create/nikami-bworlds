[CmdletBinding()]
param(
    [string]$BinaryRoot = "local/openmw-fo4guard",
    [string]$OutputRoot = "run/fnv-multi-response-voice-proof",
    [string]$ExistingRunDirectory = "",
    [ValidateRange(20, 120)]
    [int]$RunSeconds = 30,
    [ValidateRange(10, 120)]
    [int]$CaptureSecond = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$topic = "Do you know anything about the people who attacked me?"
$retailInfo = "FormId:0x1106635"

function Resolve-RepoPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

if ([string]::IsNullOrWhiteSpace($ExistingRunDirectory)) {
    $outputBase = Resolve-RepoPath $OutputRoot
    $startedAt = [DateTime]::UtcNow
    & (Join-Path $PSScriptRoot "Invoke-RealWorldScreenshots.ps1") `
        -WorldId fallout_new_vegas `
        -Mode flat `
        -StartSlice goodsprings-easy-pete-dialogue `
        -OutputRoot $outputBase `
        -BinaryRoot $BinaryRoot `
        -RunSeconds $RunSeconds `
        -CaptureSeconds $CaptureSecond `
        -BackgroundWindow `
        -EnableSound `
        -ShowGui `
        -SetEnv "OPENMW_PROOF_DIALOGUE_TOPIC=$topic" | Out-Host

    $runDirectory = Get-ChildItem -LiteralPath $outputBase -Directory -Filter "fallout_new_vegas-*" |
        Where-Object { $_.LastWriteTimeUtc -ge $startedAt.AddSeconds(-2) } |
        Sort-Object LastWriteTimeUtc, Name |
        Select-Object -Last 1
    if ($null -eq $runDirectory) {
        throw "The multi-response proof did not create an FNV run under $outputBase"
    }
    $runDirectory = $runDirectory.FullName
} else {
    $runDirectory = Resolve-RepoPath $ExistingRunDirectory
}

$manifestPath = Join-Path $runDirectory "manifest.json"
$logPath = Join-Path $runDirectory "openmw.log"
foreach ($required in @($manifestPath, $logPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing multi-response proof artifact: $required"
    }
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$logText = Get-Content -LiteralPath $logPath -Raw
$response1Text = 'FNV/ESM4 dialogue: resolved authored voice info=FormId:0x1106635 response=1 path="sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_00106635_1.ogg"'
$response2Text = 'FNV/ESM4 dialogue: resolved authored voice info=FormId:0x1106635 response=2 path="sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_00106635_2.ogg"'
$lip1Text = 'FNV/ESM4 dialogue: loaded authored LIP path="sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_00106635_1.lip"'
$lip2Text = 'FNV/ESM4 dialogue: loaded authored LIP path="sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_00106635_2.lip"'
$topicText = "FNV/ESM4 proof: selecting dialogue topic `"$topic`""

$topicIndex = $logText.IndexOf($topicText, [StringComparison]::Ordinal)
$response1Index = $logText.IndexOf($response1Text, [StringComparison]::Ordinal)
$response2Index = $logText.IndexOf($response2Text, [StringComparison]::Ordinal)
$lip1Index = $logText.IndexOf($lip1Text, [StringComparison]::Ordinal)
$lip2Index = $logText.IndexOf($lip2Text, [StringComparison]::Ordinal)
$screenshotCount = @($manifest.screenshots).Count
$windowFocusUsed = $false
if ($null -ne $manifest.windowFocus -and $null -ne $manifest.windowFocus.used) {
    $windowFocusUsed = [bool]$manifest.windowFocus.used
}

$checks = [ordered]@{
    capturedNative = [string]$manifest.status -eq "captured-native" -and $screenshotCount -eq 2
    soundEnabled = [bool]$manifest.soundEnabled
    hiddenWithoutFocus = [bool]$manifest.backgroundWindow -and -not $windowFocusUsed
    authoredTopicSelected = $topicIndex -ge 0
    bothResponsesResolved = $response1Index -ge 0 -and $response2Index -ge 0
    responsesResolvedInOrder = $response1Index -ge 0 -and $response2Index -gt $response1Index
    firstLipStarted = $lip1Index -gt $response1Index
    secondLipStarted = $lip2Index -gt $response2Index
    lipPlaybackAdvancedInOrder = $lip1Index -ge 0 -and $lip2Index -gt $lip1Index
}
$failures = @($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value } |
    ForEach-Object { [string]$_.Key })
$passed = $failures.Count -eq 0
$gate = [ordered]@{
    schema = "nikami-fnv-multi-response-voice-gate/v1"
    status = if ($passed) { "pass" } else { "fail" }
    evidenceClass = "driven-subsystem-harness"
    topic = $topic
    info = $retailInfo
    responseNumbers = @(1, 2)
    voicePaths = @(
        "sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_00106635_1.ogg",
        "sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_00106635_2.ogg"
    )
    lipPaths = @(
        "sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_00106635_1.lip",
        "sound/voice/falloutnv.esm/maleold02/vfreeformg_vfreeformgoodsp_00106635_2.lip"
    )
    checks = $checks
    failures = $failures
    runDirectory = $runDirectory -replace "\\", "/"
}
$manifest | Add-Member -NotePropertyName multiResponseVoiceGate -NotePropertyValue $gate -Force
$manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$gate | ConvertTo-Json -Depth 12

if (-not $passed) {
    throw "FNV multi-response voice proof failed. See $manifestPath"
}
