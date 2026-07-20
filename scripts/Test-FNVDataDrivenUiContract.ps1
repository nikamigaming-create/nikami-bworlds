[CmdletBinding()]
param(
    [string]$ContractPath = "catalog/fnv-ui-data-driven-contract.json",
    [string]$OpenMwSourceRoot = "D:\code\nikami-openmw-save330-integrated"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
function Resolve-PathStrict([string]$Path, [string]$Base) {
    $resolved = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    } else {
        [IO.Path]::GetFullPath((Join-Path $Base $Path))
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Missing required file: $resolved"
    }
    return $resolved
}

$contractFile = Resolve-PathStrict $ContractPath $repoRoot
$contract = Get-Content -LiteralPath $contractFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$contract.schema -ne "nikami-fnv-ui-data-driven-contract/v1") {
    throw "Unexpected FNV UI data-driven contract schema: $($contract.schema)"
}

$sourceRoot = [IO.Path]::GetFullPath($OpenMwSourceRoot)
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Missing OpenMW source root: $sourceRoot"
}

$failures = New-Object System.Collections.Generic.List[string]
function Add-Failure([string]$Message) {
    $script:failures.Add($Message) | Out-Null
}

function Read-Source([string]$RelativePath) {
    $path = Resolve-PathStrict $RelativePath $sourceRoot
    return [pscustomobject]@{
        Path = $path
        Text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    }
}

foreach ($source in @($contract.requiredSources)) {
    $file = Read-Source ([string]$source.owner)
    $needles = @()
    if ($null -ne $source.PSObject.Properties["proofNeedle"]) {
        $needles += [string]$source.proofNeedle
    }
    if ($null -ne $source.PSObject.Properties["proofNeedles"]) {
        $needles += @($source.proofNeedles | ForEach-Object { [string]$_ })
    }
    foreach ($needle in $needles) {
        if (-not $file.Text.Contains($needle)) {
            Add-Failure "Source '$($source.id)' no longer proves '$needle' in $($source.owner)."
        }
    }
}

$flatUiFiles = @(
    "apps/openmw/mwgui/windowmanagerimp.cpp",
    "apps/openmw/mwgui/inventorywindow.cpp",
    "apps/openmw/mwgui/tradewindow.cpp",
    "apps/openmw/mwgui/tradeitemmodel.cpp",
    "apps/openmw/mwgui/statswindow.cpp",
    "apps/openmw/mwgui/spellwindow.cpp",
    "apps/openmw/mwdialogue/dialoguemanagerimp.cpp"
) | ForEach-Object { Read-Source $_ }

$flatUiText = ($flatUiFiles | ForEach-Object { $_.Text }) -join "`n"
$prohibitedRuntimeContent = @(
    "Howdy. What can Easy Pete do for you?",
    "Why are you called Easy Pete?",
    "Was a prospector",
    "GSEasyPete",
    "Trudy",
    "Sunny Smiles",
    "GoodspringsSettler"
)
foreach ($needle in $prohibitedRuntimeContent) {
    if ($flatUiText -like "*$needle*") {
        Add-Failure "Flat UI code contains proof/named content string '$needle'; content must come from records/runtime."
    }
}

$tradeModel = Read-Source "apps/openmw/mwgui/tradeitemmodel.cpp"
if ($tradeModel.Text -like '*ESM::RefId::stringRefId("Caps001")*' -or
    $tradeModel.Text -like '*return ESM::RefId::stringRefId*') {
    Add-Failure "FNV currency must be resolved from the loaded store, not manufactured as a literal RefId."
}

$windowManager = Read-Source "apps/openmw/mwgui/windowmanagerimp.cpp"
if ($windowManager.Text -notlike '*isFalloutContentLoaded()*') {
    Add-Failure "FNV pane routing must be guarded by loaded Fallout content detection."
}
if ($windowManager.Text -like '*OPENMW_FNV_PROOF_PIPBOY_SURFACE*' -and
    $windowManager.Text -notlike '*falloutContent || std::getenv("OPENMW_FNV_PROOF_PIPBOY_SURFACE")*') {
    Add-Failure "Proof-only Pip-Boy surface override appears to be replacing, not supplementing, loaded-content routing."
}

$luaUi = Read-Source "files/data/scripts/omw/ui.lua"
if ($luaUi.Text -like "*FalloutNV.esm*" -or $luaUi.Text -like "*Caps001*" -or $luaUi.Text -like "*Easy Pete*") {
    Add-Failure "Generic Lua UI script contains FNV game content; flat FNV data belongs in runtime records/C++ models."
}

$vrCommon = Read-Source "files/data/scripts/omw/vr/ui/common.lua"
if ($vrCommon.Text -like "*Easy Pete*" -or $vrCommon.Text -like "*Caps001*") {
    Add-Failure "VR UI placement script contains FNV gameplay content instead of placement/input glue."
}

if ($failures.Count -gt 0) {
    Write-Host "FNV data-driven UI contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "FNV data-driven UI contract passed: flat UI content is sourced through C++ runtime models/records; Lua is bounded to generic/VR UI glue."
