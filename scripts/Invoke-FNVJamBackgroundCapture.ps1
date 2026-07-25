[CmdletBinding()]
param(
    [ValidateSet("Retail", "OpenMW", "Both")]
    [string]$Target = "Both",
    [string]$OutputRoot = "",
    [switch]$SmokeTest,
    [switch]$SkipBuild,
    [switch]$EnableSound,
    [ValidateRange(1, 30)]
    [int]$RetailVideoFrameStep = 3,
    [ValidateRange(5, 600)]
    [int]$OpenMwCaptureSeconds = 160,
    [int]$TimeoutSeconds = 240,
    [string]$WorldsRoot = "D:\code\nikami-worlds"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$preflight = Join-Path $PSScriptRoot "Test-FNVJamBackgroundCapture.ps1"
$retailRunner = Join-Path $PSScriptRoot "Invoke-FNVJamFullRetailRehearsal.ps1"
$openMwRunner = Join-Path $PSScriptRoot "Invoke-FNVJamSprintProof.ps1"

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputRoot = Join-Path $WorldsRoot "run\jam-background-$($Target.ToLowerInvariant())-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing background-capture run: $OutputRoot"
}
if ($SmokeTest -and $Target -ne "Retail") {
    throw "OpenMW has no abbreviated JAM proof: all 44 phases must run for at least three seconds. Use -SmokeTest only with -Target Retail; omit it for OpenMW or Both."
}

$preflightTarget = if ($Target -eq "Both") { "All" } else { $Target }
& $preflight -Target $preflightTarget -RuntimeReady -RequireIdle | Out-Null

New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$startedAt = Get-Date
$retailResult = $null
$openMwResult = $null

if ($Target -in @("Retail", "Both")) {
    $retailOutput = Join-Path $OutputRoot "retail"
    & $retailRunner `
        -OutputRoot $retailOutput `
        -TimeoutSeconds $TimeoutSeconds `
        -RecordVideo `
        -VideoFrameStep $RetailVideoFrameStep `
        -SmokeTest:$SmokeTest
    $retailResult =
        Get-Content -Raw -LiteralPath (Join-Path $retailOutput "rehearsal-summary.json") |
        ConvertFrom-Json
    if ($retailResult.status -ne "pass" -or
        [bool]$retailResult.backgroundCapture.windowsAppControlUsed -or
        [bool]$retailResult.backgroundCapture.foregroundRequired) {
        throw "Canonical retail background capture did not pass its policy gates."
    }
}

if ($Target -in @("OpenMW", "Both")) {
    # Retail and OpenMW are deliberately sequential. The OpenMW path is always
    # SelfDrive, which bypasses every legacy window-control/input branch.
    $openMwOutput = Join-Path $OutputRoot "openmw"
    & $openMwRunner `
        -OutputRoot $openMwOutput `
        -TimeoutSeconds $TimeoutSeconds `
        -CaptureSeconds $OpenMwCaptureSeconds `
        -FullProofDrive `
        -SelfDrive `
        -SkipBuild:$SkipBuild `
        -EnableSound:$EnableSound
    $openMwResult =
        Get-Content -Raw -LiteralPath (Join-Path $openMwOutput "proof-report.json") |
        ConvertFrom-Json
    if (-not [bool]$openMwResult.passed -or
        [bool]$openMwResult.capture.windowsAppControlUsed -or
        [bool]$openMwResult.capture.foregroundActivationUsed -or
        [bool]$openMwResult.capture.foregroundInputInjected -or
        -not [bool]$openMwResult.capture.selfDriven) {
        throw "Canonical OpenMW background capture did not pass its policy gates."
    }
}

$artifacts = [Collections.Generic.List[object]]::new()
foreach ($artifact in @(
    $(if ($null -ne $retailResult -and $null -ne $retailResult.video) {
        $retailResult.video.path
    }),
    $(if ($null -ne $openMwResult -and $null -ne $openMwResult.video) {
        $openMwResult.video.path
    })
)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$artifact) -and
        (Test-Path -LiteralPath $artifact -PathType Leaf)) {
        $file = Get-Item -LiteralPath $artifact
        $artifacts.Add([pscustomobject][ordered]@{
            path = $file.FullName
            bytes = $file.Length
            sha256 =
                (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).
                Hash.ToLowerInvariant()
        })
    }
}

$summary = [ordered]@{
    schema = "nikami-fnv-jam-background-capture-run/v1"
    status = "pass"
    target = $Target
    recipeCatalog =
        (Join-Path $WorldsRoot "catalog\fnv-jam-background-capture-recipes.json")
    startedAt = $startedAt.ToString("o")
    completedAt = (Get-Date).ToString("o")
    policy = [ordered]@{
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        capturesRanSequentially = $true
        outputOverwritten = $false
    }
    retail = $retailResult
    openMw = $openMwResult
    artifacts = @($artifacts)
}
$summaryPath = Join-Path $OutputRoot "background-capture-summary.json"
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 12),
    [Text.UTF8Encoding]::new($false))
$summary | ConvertTo-Json -Depth 12
