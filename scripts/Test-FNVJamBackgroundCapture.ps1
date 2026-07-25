[CmdletBinding()]
param(
    [ValidateSet("All", "Retail", "OpenMW")]
    [string]$Target = "All",
    [switch]$RuntimeReady,
    [switch]$RequireIdle,
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$ParityRoot = "D:\code\nikami-worlds-fnv-parity",
    [string]$EngineRoot = "D:\code\nikami-openmw-save330-integrated",
    [string]$RetailShadowRoot =
        "D:\code\nikami-worlds\run\jam-retail-side-video-20260724-191235\retail-game",
    [string]$JamRoot = "D:\code\nikami-worlds\local\mods\jam-4.6-original",
    [string]$JamArchive =
        "C:\Users\nbrys\Downloads\Just Assorted Mods-66666-4-6-1717763151.7z",
    [string]$SavePath =
        "C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Save 331     Goodsprings  00 17 36.fos"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail) {
    $checks.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $Passed
        detail = $Detail
    })
}

function Test-File([string]$Name, [string]$Path) {
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    Add-Check $Name $exists $Path
    return $exists
}

function Test-Directory([string]$Name, [string]$Path) {
    $exists = Test-Path -LiteralPath $Path -PathType Container
    Add-Check $Name $exists $Path
    return $exists
}

function Test-PowerShellParse([string]$Path) {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$null, [ref]$parseErrors)
    Add-Check "PowerShell parses: $([IO.Path]::GetFileName($Path))" `
        ($parseErrors.Count -eq 0) `
        ($(if ($parseErrors.Count -eq 0) {
            $Path
        } else {
            ($parseErrors | ForEach-Object Message) -join "; "
        }))
}

$catalogPath = Join-Path $WorldsRoot "catalog\fnv-jam-background-capture-recipes.json"
$runbookPath = Join-Path $WorldsRoot "docs\fnv-jam-background-capture.md"
$entryPointPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamBackgroundCapture.ps1"
$preflightPath = Join-Path $WorldsRoot "scripts\Test-FNVJamBackgroundCapture.ps1"
$retailRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamFullRetailRehearsal.ps1"
$openMwRunnerPath = Join-Path $WorldsRoot "scripts\Invoke-FNVJamSprintProof.ps1"
$oracleSourcePath =
    Join-Path $ParityRoot "oracles\xnvse\nvse_retail_oracle\main.cpp"
$oracleRuntimeManifestPath =
    Join-Path $ParityRoot "local\xnvse-retail-oracle\oracle-runtime-manifest.json"
$oracleDllPath =
    Join-Path $ParityRoot "local\xnvse-retail-oracle\plugins\nvse_retail_oracle.dll"

foreach ($path in @(
    $catalogPath, $runbookPath, $entryPointPath, $preflightPath,
    $retailRunnerPath, $openMwRunnerPath, $oracleSourcePath
)) {
    [void](Test-File "Canonical file exists: $([IO.Path]::GetFileName($path))" $path)
}

$catalog = $null
try {
    $catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
    Add-Check "Recipe catalog parses" $true $catalogPath
}
catch {
    Add-Check "Recipe catalog parses" $false $_.Exception.Message
}

if ($null -ne $catalog) {
    Add-Check "Recipe schema is canonical" `
        ($catalog.schema -eq "nikami-fnv-jam-background-capture-recipes/v1" -and
            $catalog.status -eq "canonical") `
        "$($catalog.schema); status=$($catalog.status)"
    Add-Check "Windows app control forbidden" `
        (-not [bool]$catalog.policy.windowsAppControlAllowed) `
        "windowsAppControlAllowed=$($catalog.policy.windowsAppControlAllowed)"
    Add-Check "Foreground activation forbidden" `
        (-not [bool]$catalog.policy.foregroundActivationAllowed) `
        "foregroundActivationAllowed=$($catalog.policy.foregroundActivationAllowed)"
    Add-Check "Injected Windows input forbidden" `
        (-not [bool]$catalog.policy.injectedWindowsInputAllowed) `
        "injectedWindowsInputAllowed=$($catalog.policy.injectedWindowsInputAllowed)"
    Add-Check "Exactly two canonical recipes" `
        (@($catalog.recipes).Count -eq 2) `
        ((@($catalog.recipes | ForEach-Object id)) -join ", ")
    foreach ($anchor in $catalog.knownGoodEvidence.PSObject.Properties) {
        $anchorRoot = Join-Path $WorldsRoot ([string]$anchor.Value)
        $anchorExists = Test-Path -LiteralPath $anchorRoot -PathType Container
        Add-Check "Known-good anchor exists: $($anchor.Name)" `
            $anchorExists $anchorRoot
        if ($anchorExists) {
            $anchorSummaryName = if ($anchor.Name -eq "sideBySide") {
                "side-by-side-proof-manifest.json"
            } else {
                "background-capture-summary.json"
            }
            $anchorSummary = Join-Path $anchorRoot $anchorSummaryName
            $summaryExists = Test-Path -LiteralPath $anchorSummary -PathType Leaf
            Add-Check "Known-good anchor has canonical summary: $($anchor.Name)" `
                $summaryExists $anchorSummary
            if ($summaryExists) {
                try {
                    $knownGood =
                        Get-Content -Raw -LiteralPath $anchorSummary |
                        ConvertFrom-Json
                    $knownGoodPolicy = if ($anchor.Name -eq "sideBySide") {
                        $knownGood.capturePolicy
                    } else {
                        $knownGood.policy
                    }
                    $policyPassed = $knownGood.status -eq "pass" -and
                        -not [bool]$knownGoodPolicy.windowsAppControlUsed -and
                        -not [bool]$knownGoodPolicy.foregroundActivationUsed -and
                        -not [bool]$knownGoodPolicy.foregroundInputInjected
                    Add-Check "Known-good anchor passes no-control policy: $($anchor.Name)" `
                        $policyPassed $anchorSummary
                }
                catch {
                    Add-Check "Known-good anchor passes no-control policy: $($anchor.Name)" `
                        $false $_.Exception.Message
                }
            }
        }
    }
}

foreach ($script in @($entryPointPath, $preflightPath, $retailRunnerPath, $openMwRunnerPath)) {
    if (Test-Path -LiteralPath $script -PathType Leaf) {
        Test-PowerShellParse $script
    }
}

if (Test-Path -LiteralPath $entryPointPath -PathType Leaf) {
    $entryText = Get-Content -Raw -LiteralPath $entryPointPath
    foreach ($forbidden in @(
        "AppActivate", "SetForegroundWindow", "BringWindowToTop",
        "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
    )) {
        Add-Check "Entry point excludes $forbidden" `
            ($entryText -notmatch [regex]::Escape($forbidden)) `
            $entryPointPath
    }
    Add-Check "OpenMW invocation forces SelfDrive" `
        ($entryText -match '(?s)Invoke-FNVJamSprintProof.*?-SelfDrive') `
        $entryPointPath
}

if ($Target -in @("All", "Retail")) {
    if (Test-Path -LiteralPath $retailRunnerPath -PathType Leaf) {
        $retailText = Get-Content -Raw -LiteralPath $retailRunnerPath
        Add-Check "Retail schedules background polling" `
            ($retailText -match 'EnableBackgroundInputPolling') $retailRunnerPath
        Add-Check "Retail uses native HoldKey and ReleaseKey" `
            ($retailText -match 'HoldKey' -and $retailText -match 'ReleaseKey') `
            $retailRunnerPath
        Add-Check "Retail supports dense native video frames" `
            ($retailText -match '\[switch\]\$RecordVideo' -and
                $retailText -match 'retail-d3d9-backbuffer-bmp-sequence') `
            $retailRunnerPath
        foreach ($forbidden in @(
            "AppActivate", "SetForegroundWindow", "BringWindowToTop",
            "SetFocus", "SendInput", "Invoke-FNVRetailJamInput"
        )) {
            Add-Check "Retail runner excludes $forbidden" `
                ($retailText -notmatch [regex]::Escape($forbidden)) `
                $retailRunnerPath
        }
    }

    if (Test-Path -LiteralPath $oracleSourcePath -PathType Leaf) {
        $oracleText = Get-Content -Raw -LiteralPath $oracleSourcePath
        Add-Check "Oracle selects only DirectInput keyboard" `
            ($oracleText -match 'GET_DIDEVICE_TYPE\(result\.deviceType\)\s*==\s*DI8DEVTYPE_KEYBOARD') `
            $oracleSourcePath
        Add-Check "Oracle requests background nonexclusive keyboard" `
            ($oracleText -match 'DISCL_BACKGROUND\s*\|\s*DISCL_NONEXCLUSIVE') `
            $oracleSourcePath
        Add-Check "Oracle reports reconfiguration explicitly" `
            ($oracleText -match '\\"reconfigured\\"') $oracleSourcePath
        Add-Check "Oracle returns before touching non-keyboard devices" `
            ($oracleText -match '(?s)if\s*\(!result\.selected\).*?return result;.*?device->Unacquire\(\)') `
            $oracleSourcePath
        Add-Check "Oracle supports schedules larger than 4096 bytes" `
            ($oracleText -match 'maxEnvironmentValueLength\s*=\s*1024\s*\*\s*1024' -and
                $oracleText -match 'GetEnvironmentVariableA\(name,\s*nullptr,\s*0\)') `
            $oracleSourcePath
    }

    $runtimeManifestExists =
        Test-File "Oracle runtime manifest exists" $oracleRuntimeManifestPath
    $runtimeDllExists =
        Test-File "Oracle runtime DLL exists" $oracleDllPath
    if ($runtimeManifestExists -and $runtimeDllExists) {
        try {
            $runtimeManifest =
                Get-Content -Raw -LiteralPath $oracleRuntimeManifestPath |
                ConvertFrom-Json
            $expectedHash = [string]$runtimeManifest.files.plugin.sha256
            $actualHash =
                (Get-FileHash -LiteralPath $oracleDllPath -Algorithm SHA256).
                Hash.ToLowerInvariant()
            Add-Check "Oracle DLL matches runtime manifest" `
                ($actualHash -eq $expectedHash.ToLowerInvariant()) `
                "expected=$expectedHash actual=$actualHash"
        }
        catch {
            Add-Check "Oracle DLL matches runtime manifest" $false `
                $_.Exception.Message
        }
    }
}

if ($Target -in @("All", "OpenMW") -and
    (Test-Path -LiteralPath $openMwRunnerPath -PathType Leaf)) {
    $openMwText = Get-Content -Raw -LiteralPath $openMwRunnerPath
    Add-Check "Full OpenMW proof refuses non-SelfDrive runs" `
        ($openMwText -match '(?s)\$FullProofDrive\s+-and\s+-not\s+\$SelfDrive.*?throw') `
        $openMwRunnerPath
    Add-Check "OpenMW report records app-control flags" `
        ($openMwText -match 'windowsAppControlUsed' -and
            $openMwText -match 'foregroundActivationUsed' -and
            $openMwText -match 'foregroundInputInjected') `
        $openMwRunnerPath
}

if (Test-Path -LiteralPath $runbookPath -PathType Leaf) {
    $runbookText = Get-Content -Raw -LiteralPath $runbookPath
    foreach ($requiredText in @(
        "retail FNV", "OpenMW", "DI8DEVTYPE_KEYBOARD",
        "reconfigured=false", "Invoke-FNVJamBackgroundCapture.ps1",
        "Test-FNVJamBackgroundCapture.ps1"
    )) {
        Add-Check "Runbook contains '$requiredText'" `
            ($runbookText -match [regex]::Escape($requiredText)) $runbookPath
    }
}

if ($RuntimeReady) {
    foreach ($tool in @("ffmpeg", "ffprobe")) {
        $command = Get-Command $tool -ErrorAction SilentlyContinue |
            Select-Object -First 1
        Add-Check "$tool is available" ($null -ne $command) `
            $(if ($null -ne $command) { $command.Source } else { "not on PATH" })
    }
    [void](Test-File "Shared native save exists" $SavePath)

    if ($Target -in @("All", "Retail")) {
        [void](Test-Directory "Retail shadow root exists" $RetailShadowRoot)
        foreach ($file in @(
            "FalloutNV.exe",
            "Data\nvse\plugins\jip_nvse.dll",
            "Data\nvse\plugins\johnnyguitar.dll",
            "Data\nvse\plugins\kNVSE.dll",
            "Data\nvse\plugins\nvse_stewie_tweaks.dll",
            "Data\nvse\plugins\ui_organizer.dll"
        )) {
            [void](Test-File "Retail runtime file exists: $file" `
                (Join-Path $RetailShadowRoot $file))
        }
    }

    if ($Target -in @("All", "OpenMW")) {
        [void](Test-File "OpenMW binary exists" `
            (Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\openmw.exe"))
        [void](Test-Directory "OpenMW resources exist" `
            (Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\resources"))
        [void](Test-File "Untouched JAM ESP exists" `
            (Join-Path $JamRoot "JustAssortedMods.esp"))
        [void](Test-File "Published JAM archive exists" $JamArchive)
        [void](Test-File "OpenMW JAM provider exists" `
            (Join-Path $EngineRoot `
                "MSVC2022_64\RelWithDebInfo\resources\vfs\scripts\omw\fnv\compat\jam_sprint.lua"))
    }
}

if ($RequireIdle) {
    $processNames = if ($Target -eq "Retail") {
        @("FalloutNV", "nvse_loader")
    } elseif ($Target -eq "OpenMW") {
        @("openmw")
    } else {
        @("FalloutNV", "nvse_loader", "openmw")
    }
    $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
    Add-Check "Capture engines are idle" ($running.Count -eq 0) `
        $(if ($running.Count -eq 0) {
            "none"
        } else {
            ($running | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
        })
}

$failed = @($checks | Where-Object { -not $_.passed })
$result = [pscustomobject][ordered]@{
    schema = "nikami-fnv-jam-background-capture-preflight/v1"
    status = if ($failed.Count -eq 0) { "pass" } else { "fail" }
    target = $Target
    runtimeReadyChecked = [bool]$RuntimeReady
    idleChecked = [bool]$RequireIdle
    passedChecks = $checks.Count - $failed.Count
    failedChecks = $failed.Count
    checks = @($checks)
}
$result
if ($failed.Count -ne 0) {
    throw "FNV/JAM background-capture preflight failed $($failed.Count) check(s): " +
        (($failed | ForEach-Object name) -join "; ")
}
