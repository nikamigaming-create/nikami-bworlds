param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot,
    [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SourceRoot = [IO.Path]::GetFullPath($SourceRoot)
if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot "apps\openmw") -PathType Container)) {
    throw "SourceRoot is not an OpenMW source tree: $SourceRoot"
}
if ($OutputPath) {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $OutputPath) {
        throw "Refusing to overwrite source-ownership report: $OutputPath"
    }
}

$checks = [Collections.Generic.List[object]]::new()
function Add-OwnershipCheck(
    [string]$Name,
    [string[]]$RelativePaths,
    [string]$Pattern,
    [string]$RequiredOwner
) {
    $findings = [Collections.Generic.List[object]]::new()
    foreach ($relativePath in $RelativePaths) {
        $path = Join-Path $SourceRoot $relativePath
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $path) {
            $lineNumber++
            if ($line -match $Pattern) {
                $findings.Add([ordered]@{
                    path = $relativePath.Replace("\", "/")
                    line = $lineNumber
                    text = $line.Trim()
                }) | Out-Null
            }
        }
    }
    $checks.Add([ordered]@{
        name = $Name
        status = if ($findings.Count -eq 0) { "pass" } else { "fail" }
        requiredOwner = $RequiredOwner
        matchCount = $findings.Count
        matches = @($findings)
    }) | Out-Null
}

function Add-ContentOwnershipCheck(
    [string]$Name,
    [string]$RelativePath,
    [string]$Pattern,
    [string]$RequiredOwner
) {
    $path = Join-Path $SourceRoot $RelativePath
    $content = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw } else { "" }
    $found = $content -match $Pattern
    $checks.Add([ordered]@{
        name = $Name
        status = if ($found) { "fail" } else { "pass" }
        requiredOwner = $RequiredOwner
        matchCount = if ($found) { 1 } else { 0 }
        matches = @()
    }) | Out-Null
}

$guiFiles = @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot "apps\openmw\mwgui") -File -Filter "*.cpp" |
    ForEach-Object { "apps\openmw\mwgui\$($_.Name)" })
Add-OwnershipCheck "Normal GUI is independent of proof environment" $guiFiles `
    'OPENMW_FNV_(PROOF|REAL_SAVE_)' "content format, live GUI mode, and ordinary input state"
Add-OwnershipCheck "Engine has no save-specific production route" @("apps\openmw\engine.cpp") `
    'OPENMW_FNV_REAL_SAVE_[A-Z0-9_]+' "external test driver invoking normal public actions"
Add-OwnershipCheck "Engine has no frame-scheduled Pip-Boy showcase" @("apps\openmw\engine.cpp") `
    'OPENMW_FNV_PIPBOY_SHOWCASE' "external test driver invoking normal public actions"
Add-OwnershipCheck "Shared bindings have no hard-coded Fallout defaults" @(
    "apps\openmw\mwinput\bindingsmanager.cpp"
) 'default(Key|MouseButton)Bindings\[A_Fallout(Aim|PipBoy)\]' `
    "content-profile control map loaded through the normal bindings system"
Add-OwnershipCheck "ADS FOV is not hard-coded" @("apps\openmw\mwinput\actionmanager.cpp") `
    'overrideFieldOfView\s*\(\s*35\.f\s*\)' "equipped WEAP sight/zoom data with normal camera ownership"
Add-OwnershipCheck "Pip-Boy screen is not generated in engine code" @(
    "apps\openmw\mwrender\renderingmanager.cpp",
    "apps\openmw\mwgui\windowmanagerimp.cpp"
) 'updatePipBoyTerminalTexture|pipBoyGlyph|drawPipBoyTerminalText|drawPipBoyRetailPanelIcon|makeFalloutPipBoyTerminalBody|makeFalloutPipBoyTabRow' `
    "authored Fallout Tile XML rendered from runtime-backed UI models"
Add-OwnershipCheck "Pip-Boy controls are not synthesized in engine code" @(
    "apps\openmw\mwrender\esm4npcanimation.cpp",
    "apps\openmw\mwrender\esm4npcanimation.hpp"
) 'PipBoyPhysicalControl|PipBoyControlLocator|initializePipBoyPhysicalControls|mPipBoyInteractionHandRoot|handContactTargets' `
    "authored NIF/KF controller data"
Add-OwnershipCheck "Normal stores contain no synthetic Fallout proof records" @(
    "apps\openmw\mwworld\esmstore.cpp",
    "apps\openmw\engine.cpp"
) 'FNV_PROOF_(9MM_PISTOL|VARMINT_RIFLE|STIMPAK|9MM_AMMO|BOBBY_PIN|CAPS)' `
    "loaded ESM/ESM4 records only"
Add-OwnershipCheck "Pip-Boy routing names authored menu assets" @(
    "apps\openmw\mwgui\windowmanagerimp.cpp"
) '(?!)' "inventory_menu.xml, stats_menu.xml, and map_menu.xml resolved through the runtime VFS"
$windowManagerPath = Join-Path $SourceRoot "apps\openmw\mwgui\windowmanagerimp.cpp"
$windowManagerText = if (Test-Path -LiteralPath $windowManagerPath) {
    Get-Content -LiteralPath $windowManagerPath -Raw
} else { "" }
$authoredMenuCheck = $checks[$checks.Count - 1]
$authoredMenuCheck.status = if (
    $windowManagerText.Contains("inventory_menu.xml") -and
    $windowManagerText.Contains("stats_menu.xml") -and
    $windowManagerText.Contains("map_menu.xml")
) { "pass" } else { "fail" }
$authoredMenuCheck.matchCount = if ($authoredMenuCheck.status -eq "pass") { 0 } else { 1 }
Add-ContentOwnershipCheck "Summary telemetry does not enable per-frame trace" "apps\openmw\engine.cpp" `
    '(?s)bool\s+worldViewerTraceEnabled\s*\(\s*\).*?OPENMW_WORLD_VIEWER_TRACE.*?OPENMW_WORLD_VIEWER_TELEMETRY.*?\}' `
    "separate opt-in trace and rate-limited summary telemetry switches"
Add-OwnershipCheck "No frozen Pip-Boy KF time" @(
    "apps\openmw\mwrender\esm4npcanimation.cpp",
    "apps\openmw\mwrender\animation.cpp"
) 'retailRaisedContactSeconds|range=start-to-retail-mode3|setTime\s*\(\s*(0\.333333|0\.0?f?)\s*\)' `
    "authored animation controller and observed transition state"

$failed = @($checks | Where-Object status -eq "fail")
$result = [ordered]@{
    schema = "nikami-fnv-gameplay-source-ownership/v1"
    status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
    readOnly = $true
    sourceRoot = $SourceRoot
    checkedAtUtc = [DateTime]::UtcNow.ToString("o")
    passedChecks = $checks.Count - $failed.Count
    failedChecks = $failed.Count
    checks = @($checks)
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}
$result
if ($failed.Count -gt 0) { exit 1 }
