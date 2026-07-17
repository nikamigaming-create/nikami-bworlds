param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$proofPath = Join-Path $PSScriptRoot "Invoke-FNVMultiResponseVoiceProof.ps1"
$failures = [Collections.Generic.List[string]]::new()

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) | Out-Null }
}

$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $proofPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Contract ($parseErrors.Count -eq 0) "PowerShell parse failure: $proofPath"

$source = Get-Content -LiteralPath $proofPath -Raw
foreach ($required in @(
    'FormId:0x1106635',
    '00106635_1.ogg',
    '00106635_2.ogg',
    '00106635_1.lip',
    '00106635_2.lip',
    'responsesResolvedInOrder',
    'lipPlaybackAdvancedInOrder',
    'hiddenWithoutFocus',
    'multiResponseVoiceGate'
)) {
    Assert-Contract ($source.Contains($required)) "Multi-response voice gate is missing '$required'."
}
Assert-Contract ($source.Contains('-EnableSound')) "Multi-response voice proof does not enable authored audio."
Assert-Contract ($source.Contains('-BackgroundWindow')) "Multi-response voice proof is not background-only."
Assert-Contract ($source.Contains('-StartSlice goodsprings-easy-pete-dialogue')) `
    "Multi-response voice proof does not use the maintained Easy Pete dialogue route."

if ($failures.Count -ne 0) {
    Write-Host "FNV multi-response voice contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "FNV multi-response voice contract passed (authored order, per-line LIP, background proof)."
