param(
    [string]$PluginDll = "run\worktrees\xnvse-oracle\nvse_retail_oracle\build\nvse_retail_oracle.dll",
    [string]$OutputPath = "run\retail-oracle\fnv-easy-pete-furniture-lifecycle.jsonl",
    [int]$TimeoutSeconds = 110,
    [switch]$VisibleGame
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "Invoke-FNVRetailOracle.ps1"
try {
    & $runner `
        -PluginDll $PluginDll `
        -OutputPath $OutputPath `
        -SaveName "Save 222     Goodsprings  00 01 36" `
        -TargetForm "0x00104C80" `
        -ObserverApproachForm "0x0010634A" `
        -ObserverApproachStopDistance 1400 `
        -ObserverApproachStepDistance 64 `
        -ObserverWaypoint "-71100,2500", "-69900,2750", "-68800,3100" `
        -Command "Set GameHour To 14", "Set TimeScale To 30" `
        -FurnitureSettledCommand "SaveGame NikamiOracleEasyPeteSeated" `
        -ExitAfterFurnitureSettledSamples 3 `
        -BeforeFrame 10 `
        -CommandFrame 20 `
        -AfterFrame 30 `
        -MaxFrames 4000 `
        -TimeoutSeconds $TimeoutSeconds `
        -SampleEvery 10 `
        -FurnitureOnly `
        -BackgroundDataMode `
        -VisibleGame:$VisibleGame
}
finally {
    $saveDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FalloutNV\Saves'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $checkpointDirectory = Join-Path $repoRoot 'run\retail-oracle\checkpoints'
    New-Item -ItemType Directory -Force -Path $checkpointDirectory | Out-Null
    foreach ($extension in @('.fos', '.nvse')) {
        $created = Join-Path $saveDirectory ("NikamiOracleEasyPeteSeated" + $extension)
        if (Test-Path -LiteralPath $created -PathType Leaf) {
            Copy-Item -LiteralPath $created -Destination $checkpointDirectory -Force
            Remove-Item -LiteralPath $created -Force
        }
    }
}
