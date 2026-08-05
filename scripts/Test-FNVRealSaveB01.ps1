[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)

function Require-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Passed) {
        throw "B01 contract validation failed: $Message"
    }
}

function Require-File([string]$Path) {
    Require-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "missing file $Path"
}

$catalogPath = Join-Path $WorldsRoot "catalog\fnv-jam-background-capture-recipes.json"
$entryPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamBackgroundCapture.ps1"
$preflightPath = Join-Path $WorldsRoot "scripts\Test-FNVJamBackgroundCapture.ps1"
$runnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVRealSaveCapture.ps1"
$savePath = Join-Path $WorldsRoot "local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos"
foreach ($path in @($catalogPath, $entryPath, $preflightPath, $runnerPath, $savePath)) {
    Require-File $path
}

$catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
$recipes = @($catalog.realSaveRecipes)
Require-Condition ($recipes.Count -eq 2) "the catalog must declare exactly one Retail and one OpenMW RealSave recipe"
Require-Condition (@($recipes | Where-Object target -eq "Retail").Count -eq 1) "Retail RealSave recipe missing"
Require-Condition (@($recipes | Where-Object target -eq "OpenMW").Count -eq 1) "OpenMW RealSave recipe missing"
foreach ($recipe in $recipes) {
    Require-Condition ([string]$recipe.runner -eq "scripts/Invoke-FNVRealSaveCapture.ps1") "recipe $($recipe.id) bypasses the canonical RealSave runner"
    Require-Condition (-not [bool]$recipe.foregroundRequired) "recipe $($recipe.id) requires foreground control"
    Require-Condition (-not [bool]$recipe.windowsAppControlUsed) "recipe $($recipe.id) allows Windows app control"
    Require-Condition (-not [string]::IsNullOrWhiteSpace([string]$recipe.captureMethod)) "recipe $($recipe.id) has no capture method"
    Require-Condition (@($recipe.requiredTelemetry).Count -ge 4) "recipe $($recipe.id) has incomplete required telemetry"
}

$entry = Get-Content -Raw -LiteralPath $entryPath
$preflight = Get-Content -Raw -LiteralPath $preflightPath
$runner = Get-Content -Raw -LiteralPath $runnerPath

foreach ($text in @($entry, $runner)) {
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Require-Condition ($text -notmatch [regex]::Escape($forbidden)) "forbidden foreground/input mechanism '$forbidden' is present"
    }
}

Require-Condition ($entry -match 'ValidateSet\("Jam", "Opening", "TestMap", "PipBoy", "RealSave"\)') "public entry point does not expose RealSave"
Require-Condition ($entry -match '(?s)if \(\$Scenario -eq "RealSave" -and \$Target -eq "Both"\).*?throw') "public entry point permits concurrent Retail/OpenMW RealSave capture"
Require-Condition ($entry -match '(?s)if \(Test-Path -LiteralPath \$OutputRoot\).*?Refusing to overwrite') "public entry point does not reject output reuse"
Require-Condition ($entry -match '(?s)& \$preflight.*?-Scenario \$Scenario.*?-RuntimeReady.*?-RequireIdle') "public entry point does not run mandatory preflight before dispatch"
Require-Condition ($entry -match '(?s)if \(\$Scenario -eq "RealSave"\).*?& \$realSaveRunner') "public entry point bypasses the RealSave runner"
Require-Condition ($entry -match 'SavePath\s*=\s*""' -and $entry -match 'RealSaveRouteId' -and
    $entry -match 'RealSaveCaptureSeconds' -and $entry -match 'InteractiveHandoff') "public RealSave parameters are incomplete"

Require-Condition ($preflight -match 'ValidateSet\("Jam", "Opening", "TestMap", "PipBoy", "RealSave"\)') "preflight does not expose RealSave"
Require-Condition ($preflight -match '(?s)if \(\$Scenario -eq "RealSave" -and \$Target -eq "All"\).*?throw') "preflight permits an All/concurrent RealSave target"
Require-Condition ($preflight -match '3395328L' -and
    $preflight -match '07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f') "preflight does not hash-lock Save330"
Require-Condition ($preflight -match '(?s)if \(\$Scenario -eq "RealSave" -and \$OutputRoot.*?Test-Path') "preflight does not reject output reuse"
Require-Condition ($preflight -match '(?s)\$Scenario -eq "RealSave".*?Test-File "Immutable Save330 fixture exists"') "preflight does not require the immutable save"

Require-Condition ($runner -match 'ValidateSet\("Retail", "OpenMW"\)') "runner is not single-engine"
Require-Condition ($runner -match '"--load-savegame"' -and $runner -notmatch '"--start"' -and $runner -notmatch '"--new-game"') "runner does not use only ordinary load-savegame"
Require-Condition ($runner -notmatch 'TestMap01' -and
    $runner -notmatch 'OPENMW_FNV_BOOTSTRAP' -and
    $runner -notmatch 'OPENMW_FNV_GAMEPLAY_START_WORLDSPACE' -and
    $runner -notmatch 'executeInConsole') "runner contains synthetic placement/bootstrap/console state"
Require-Condition ($runner -match 'ScreenCaptureHandler' -and
    $runner -match 'OPENMW_PROOF_SCREENSHOT_READY_FRAMES' -and
    $runner -match 'OPENMW_WORLD_VIEWER_TELEMETRY' -and
    $runner -match 'title=OpenMW') "runner does not retain native frame, telemetry, and exact-title video"
Require-Condition ($runner -match 'Get-FileHash' -and
    $runner -match '07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f') "runner does not enforce the Save330 hash"
Require-Condition ($runner -match 'InteractiveHandoff' -and $runner -match 'RouteId' -and $runner -match 'CaptureSeconds') "runner parameters are incomplete"

foreach ($path in @($entryPath, $preflightPath, $runnerPath)) {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
    Require-Condition ($parseErrors.Count -eq 0) "PowerShell parse errors in $path"
}

$saveFile = Get-Item -LiteralPath $savePath
$saveHash = (Get-FileHash -LiteralPath $savePath -Algorithm SHA256).Hash.ToLowerInvariant()
Require-Condition ([long]$saveFile.Length -eq 3395328L) "Save330 fixture byte count changed"
Require-Condition ($saveHash -eq "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f") "Save330 fixture SHA-256 changed"

$report = [ordered]@{
    schema = "nikami-fnv-real-save-b01-contract-validation/v1"
    status = "pass"
    targetPolicy = "one engine per run; Retail and OpenMW are sequential only"
    outputPolicy = "fresh output root required; overwrite rejected"
    inputPolicy = "no foreground activation, Windows input, clicks, or SendInput"
    saveFixture = [ordered]@{
        path = $savePath
        bytes = [long]$saveFile.Length
        sha256 = $saveHash
    }
    recipes = @($recipes | ForEach-Object {
        [ordered]@{ id = [string]$_.id; target = [string]$_.target; runner = [string]$_.runner }
    })
    checks = @(
        "catalog declares two single-engine RealSave recipes",
        "public entry point runs RuntimeReady/RequireIdle preflight",
        "preflight enforces immutable Save330 size and hash",
        "output reuse and concurrent targets are rejected",
        "runner uses ordinary --load-savegame and retains native evidence"
    )
}
$outputPath = Join-Path $WorldsRoot "run\fnv-real-save-campaign\b01-contract-validation.json"
[IO.File]::WriteAllText($outputPath, ($report | ConvertTo-Json -Depth 10) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$report
