param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$runner = Join-Path $PSScriptRoot 'Invoke-FNVRetailOracle.ps1'
$token = "$PID-$([Guid]::NewGuid().ToString('N'))"
$runtimeRoot = Join-Path $repoRoot "local\xnvse-isolation-contract-$token"
$gameRoot = Join-Path ([System.IO.Path]::GetTempPath()) "nikami-fnv-game-$token"
$output = Join-Path ([System.IO.Path]::GetTempPath()) "nikami-fnv-output-$token.jsonl"
$runManifest = $output + '.manifest.json'
$sidecarPlanPaths = [System.Collections.Generic.List[string]]::new()
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}

function Assert-ThrowsLike([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.Exception.Message -notmatch $Pattern) {
        $detail = if ($null -eq $caught) { 'no exception' } else { $caught.Exception.Message }
        $script:failures.Add("$Message ($detail)") | Out-Null
    }
}

try {
    $runnerSource = Get-Content -LiteralPath $runner -Raw
    $oracleSource = Get-Content -LiteralPath (
        Join-Path $repoRoot 'oracles\xnvse\nvse_retail_oracle\main.cpp') -Raw
    $furnitureWrapperSource = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'Invoke-FNVEasyPeteFurnitureOracle.ps1') -Raw
    $appearanceWrapperSource = Get-Content -LiteralPath (
        Join-Path $PSScriptRoot 'Invoke-FNVGoodspringsAppearanceMatrix.ps1') -Raw
    Assert-Contract ($runnerSource -notmatch 'Data\\NVSE\\Plugins') `
        'Runner source still names the retail xNVSE plugin directory.'
    Assert-Contract ($runnerSource -notmatch 'ShowWindowAsync|SetForegroundWindow|user32\.dll') `
        'Runner source still contains foreground/window-control APIs.'
    Assert-Contract ($runnerSource -match 'Assert-FNVRetailOracleEvidence') `
        'Runner does not invoke the exact evidence validator.'
    Assert-Contract ($runnerSource -match 'Write-FNVImmutableJsonManifest') `
        'Runner does not write an immutable run manifest.'
    Assert-Contract ($oracleSource -notmatch 'CreateFileMappingA|CreateEventA') `
        'Retail sidecar endpoint can still create coordinator-owned transport objects.'
    Assert-Contract ($oracleSource -match 'OpenFileMappingA\s*\(\s*FILE_MAP_ALL_ACCESS') `
        'Retail sidecar endpoint does not open the coordinator-owned mapping.'
    Assert-Contract (
        $oracleSource -match 'OpenEventA\s*\(\s*eventAccess\s*,\s*FALSE' -and
        $oracleSource -match 'EVENT_MODIFY_STATE\s*\|\s*SYNCHRONIZE') `
        'Retail sidecar endpoint does not open coordinator-owned events with strict access.'
    Assert-Contract ($oracleSource -match 'shared-memory-initial-state-mismatch') `
        'Retail sidecar endpoint does not validate the coordinator initial state.'
    Assert-Contract ($oracleSource -match 'shared-memory-peer-error-active') `
        'Retail sidecar endpoint does not preserve an existing coordinator/peer error.'
    Assert-Contract ($oracleSource -notmatch 'header\.flags\s*=\s*0') `
        'Retail sidecar endpoint still clears coordinator-owned flags during startup.'
    Assert-Contract ($oracleSource -notmatch 'header\.errorCode\s*=\s*0') `
        'Retail sidecar endpoint still clears a coordinator/peer error code during startup.'
    Assert-Contract ($oracleSource -notmatch 'expectedActionIds|seven-action') `
        'Retail sidecar endpoint still hardcodes a fixed action identity list.'
    Assert-Contract ($runnerSource -notmatch 'expectedSidecarActions|seven-action') `
        'Retail sidecar runner still hardcodes a fixed action identity list.'
    $manifestGuardIndex = $runnerSource.IndexOf('if (Test-Path -LiteralPath $runManifest)')
    $launchIndex = $runnerSource.IndexOf('$launcherProcess = Start-Process')
    Assert-Contract ($manifestGuardIndex -ge 0 -and $launchIndex -gt $manifestGuardIndex) `
        'Existing-manifest refusal is not ordered before retail launch.'
    Assert-Contract ($furnitureWrapperSource -match 'local\\xnvse-retail-oracle\\plugins\\nvse_retail_oracle\.dll') `
        'Easy Pete wrapper does not default to the local isolated plugin.'
    Assert-Contract ($furnitureWrapperSource -match '-RuntimeRoot\s+\$RuntimeRoot') `
        'Easy Pete wrapper does not pass RuntimeRoot to the runner.'
    Assert-Contract ($furnitureWrapperSource -match '-ExpectedTargetBaseForm\s+"0x00104C7F"') `
        'Easy Pete wrapper does not bind the expected retail base identity.'
    Assert-Contract ($appearanceWrapperSource -match 'local/xnvse-retail-oracle/plugins/nvse_retail_oracle\.dll') `
        'Appearance wrapper does not default to the local isolated plugin.'
    Assert-Contract ($appearanceWrapperSource -match 'RuntimeRoot\s*=\s*Resolve-AbsolutePath\s+\$RuntimeRoot') `
        'Appearance wrapper does not pass RuntimeRoot to the runner.'
    Assert-Contract ($appearanceWrapperSource -match 'BatchExpectedBaseForm\s*=\s*\$baseForms') `
        'Appearance wrapper does not bind matrix base identities.'

    $pluginSourceDirectory = Join-Path $runtimeRoot 'plugins'
    $retailPluginDirectory = Join-Path $gameRoot 'Data\NVSE\Plugins'
    New-Item -ItemType Directory -Path $pluginSourceDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $retailPluginDirectory -Force | Out-Null

    $runtimeFiles = [ordered]@{
        loader = Join-Path $runtimeRoot 'nvse_loader.exe'
        steamLoader = Join-Path $runtimeRoot 'nvse_steam_loader.dll'
        core = Join-Path $runtimeRoot 'nvse_1_4.dll'
        plugin = Join-Path $pluginSourceDirectory 'nvse_retail_oracle.dll'
    }
    foreach ($entry in $runtimeFiles.GetEnumerator()) {
        [System.IO.File]::WriteAllText($entry.Value, "contract-$($entry.Key)-$token")
    }
    $gameExe = Join-Path $gameRoot 'FalloutNV.exe'
    $d3d9 = Join-Path $gameRoot 'd3d9.dll'
    $dinput8 = Join-Path $gameRoot 'dinput8.dll'
    $retailSentinel = Join-Path $retailPluginDirectory 'nvse_retail_oracle.dll'
    [System.IO.File]::WriteAllText($gameExe, "not-an-executable-$token")
    [System.IO.File]::WriteAllText($d3d9, "retail-d3d9-$token")
    [System.IO.File]::WriteAllText($dinput8, "retail-dinput8-$token")
    [System.IO.File]::WriteAllText($retailSentinel, "retail-plugin-sentinel-$token")

    $overlayLock = Get-Content -LiteralPath (Join-Path $repoRoot 'catalog\oracle-overlay-lock.json') -Raw |
        ConvertFrom-Json
    $replayedTree = [string]$overlayLock.overlays.xnvse.replayedTree
    $manifest = [ordered]@{
        schema = 'nikami-xnvse-isolated-runtime/v1'
        overlay = [ordered]@{
            name = 'xnvse'
            replayedTree = $replayedTree
        }
        files = [ordered]@{
            loader = [ordered]@{
                path = 'nvse_loader.exe'
                sha256 = (Get-FileHash -LiteralPath $runtimeFiles.loader -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            steamLoader = [ordered]@{
                path = 'nvse_steam_loader.dll'
                sha256 = (Get-FileHash -LiteralPath $runtimeFiles.steamLoader -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            core = [ordered]@{
                path = 'nvse_1_4.dll'
                sha256 = (Get-FileHash -LiteralPath $runtimeFiles.core -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            plugin = [ordered]@{
                path = 'plugins/nvse_retail_oracle.dll'
                sha256 = (Get-FileHash -LiteralPath $runtimeFiles.plugin -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
    $manifestPath = Join-Path $runtimeRoot 'oracle-runtime-manifest.json'
    [System.IO.File]::WriteAllText(
        $manifestPath, (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine))

    $sentinelHash = (Get-FileHash -LiteralPath $retailSentinel -Algorithm SHA256).Hash
    $d3d9Hash = (Get-FileHash -LiteralPath $d3d9 -Algorithm SHA256).Hash
    $dinput8Hash = (Get-FileHash -LiteralPath $dinput8 -Algorithm SHA256).Hash
    $arguments = @{
        GameRoot = $gameRoot
        RuntimeRoot = $runtimeRoot
        PluginDll = $runtimeFiles.plugin
        OutputPath = $output
        DryRun = $true
    }
    $validation = & $runner @arguments

    Assert-Contract ($validation.status -eq 'validated-no-launch') 'DryRun did not return validated-no-launch.'
    Assert-Contract ($validation.replayedTree -eq $replayedTree) 'DryRun did not bind to the overlay-lock replayedTree.'
    Assert-Contract ($validation.loader -eq $runtimeFiles.loader) 'DryRun did not select the isolated loader.'
    Assert-Contract ($validation.steamLoader -eq $runtimeFiles.steamLoader) 'DryRun did not select the isolated steam loader.'
    Assert-Contract ($validation.coreDll -eq $runtimeFiles.core) 'DryRun did not select the isolated core DLL.'
    Assert-Contract ($validation.pluginSource -eq $runtimeFiles.plugin) 'DryRun did not select the manifest plugin.'
    Assert-Contract ($validation.runManifest -eq $runManifest) 'DryRun did not plan the adjacent run manifest.'
    Assert-Contract (-not [bool]$validation.wouldOverwrite.output) 'DryRun falsely reported output overwrite.'
    Assert-Contract (-not [bool]$validation.wouldOverwrite.runManifest) 'DryRun falsely reported manifest overwrite.'
    Assert-Contract (-not [bool]$validation.retailPluginDirectoryUsed) 'DryRun claimed use of the retail plugin directory.'
    Assert-Contract ([bool]$validation.rootHookIsolation) 'Root d3d9/dinput8 isolation was not safe-by-default.'
    Assert-Contract (@($validation.rootHookDlls).Count -eq 2) 'DryRun did not plan both root hook DLL moves.'
    Assert-Contract ($validation.launch.filePath -eq $runtimeFiles.loader) 'Launch plan did not use the isolated loader.'
    Assert-Contract ($validation.launch.workingDirectory -eq $gameRoot) 'Launch plan did not retain retail GameRoot as CWD.'
    Assert-Contract ($validation.launch.argumentList[0] -eq '-altdll') 'Launch plan omitted -altdll.'
    Assert-Contract ($validation.launch.argumentList[1] -eq $runtimeFiles.core) 'Launch plan did not bind -altdll to the isolated core.'
    Assert-Contract (
        $validation.isolationEnvironment.NIKAMI_NVSE_PLUGIN_DIR -eq $validation.isolatedPluginDirectory) `
        'NIKAMI_NVSE_PLUGIN_DIR did not select the ephemeral directory.'
    Assert-Contract (
        $validation.isolationEnvironment.NIKAMI_NVSE_STEAM_LOADER -eq $runtimeFiles.steamLoader) `
        'NIKAMI_NVSE_STEAM_LOADER did not select the isolated DLL.'
    Assert-Contract (
        $validation.isolationEnvironment.NIKAMI_NVSE_CORE_DLL -eq $runtimeFiles.core) `
        'NIKAMI_NVSE_CORE_DLL did not select the isolated DLL.'
    Assert-Contract (
        $validation.isolatedPluginDirectory.StartsWith(
            $runtimeRoot + [System.IO.Path]::DirectorySeparatorChar,
            [System.StringComparison]::OrdinalIgnoreCase)) `
        'Ephemeral plugin directory was not planned beneath RuntimeRoot.'
    Assert-Contract (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot '.runs'))) 'DryRun created an ephemeral run directory.'
    Assert-Contract (-not (Test-Path -LiteralPath $output)) 'DryRun created oracle output.'
    Assert-Contract (-not (Test-Path -LiteralPath $runManifest)) 'DryRun created a run manifest.'
    Assert-Contract ((Get-FileHash -LiteralPath $retailSentinel -Algorithm SHA256).Hash -eq $sentinelHash) `
        'DryRun modified the retail plugin sentinel.'
    Assert-Contract ((Get-FileHash -LiteralPath $d3d9 -Algorithm SHA256).Hash -eq $d3d9Hash) `
        'DryRun modified root d3d9.dll.'
    Assert-Contract ((Get-FileHash -LiteralPath $dinput8 -Algorithm SHA256).Hash -eq $dinput8Hash) `
        'DryRun modified root dinput8.dll.'

    $validSidecarLines = @(
        'nikami-fnv-retail-plan-v1'
        "sequence`tcontract-$token"
        "scene`t0x00104c72`t0x001237d7`t14`t0`t-65306.375`t-2088.550537109375`t8384`t5.639382839202881`t-63668`t-860`t8384`t1.6`t48`t16`t30`t15"
        "action`t0`tinspect`tIdle`t24"
        "action`t1`tadvance`tForward`t24"
        "action`t2`tgesture`tIdle`t24"
        "actor`t0`t0x00104e85`t0x00104e84`t0x0007ea24`t0"
        'end'
    )
    $validSidecarPlan = Join-Path ([System.IO.Path]::GetTempPath()) `
        "nikami-fnv-sidecar-plan-valid-$token.tsv"
    $sidecarPlanPaths.Add($validSidecarPlan)
    [System.IO.File]::WriteAllLines($validSidecarPlan, $validSidecarLines)
    $sidecarArguments = @{}
    foreach ($key in $arguments.Keys) { $sidecarArguments[$key] = $arguments[$key] }
    $sidecarArguments.PlanPath = $validSidecarPlan
    $sidecarArguments.SharedMemoryName = "Local\NikamiFNVSidecar.contract-$token"
    $sidecarValidation = & $runner @sidecarArguments
    Assert-Contract ($sidecarValidation.status -eq 'validated-no-launch') `
        'Sidecar DryRun did not return validated-no-launch.'
    Assert-Contract ([bool]$sidecarValidation.sidecar.enabled) `
        'Sidecar DryRun did not enable the sidecar plan.'
    Assert-Contract ($sidecarValidation.sidecar.sequenceId -eq "contract-$token") `
        'Sidecar DryRun did not preserve the sequence identity.'
    Assert-Contract ($sidecarValidation.sidecar.sharedMemoryName -eq $sidecarArguments.SharedMemoryName) `
        'Sidecar DryRun did not preserve the shared-memory identity.'
    Assert-Contract ($sidecarValidation.sidecar.actors -eq 1) `
        'Sidecar DryRun did not retain the actor count.'
    Assert-Contract ($sidecarValidation.sidecar.actionsPerActor -eq 3) `
        'Sidecar DryRun did not retain the data-driven three-action contract.'
    Assert-Contract ($sidecarValidation.sidecar.expectedCaptures -eq 3) `
        'Sidecar DryRun did not derive the exact capture count.'

    $invalidPlans = @(
        [pscustomobject]@{
            label = 'trailing-record'
            lines = @($validSidecarLines) + "actor`t1`t0`t0x00104e84`t0`t0"
            expected = 'record after end'
        }
        [pscustomobject]@{
            label = 'action-index-gap'
            lines = @($validSidecarLines | ForEach-Object {
                if ($_ -ceq "action`t1`tadvance`tForward`t24") {
                    "action`t2`tadvance`tForward`t24"
                }
                else { $_ }
            })
            expected = 'invalid action'
        }
        [pscustomobject]@{
            label = 'duplicate-action-id'
            lines = @($validSidecarLines | ForEach-Object {
                if ($_ -ceq "action`t1`tadvance`tForward`t24") {
                    "action`t1`tinspect`tForward`t24"
                }
                else { $_ }
            })
            expected = 'invalid action'
        }
        [pscustomobject]@{
            label = 'duplicate-authored-ref'
            lines = @($validSidecarLines[0..6]) +
                "actor`t1`t0x00104e85`t0x00104e84`t0`t0" + 'end'
            expected = 'invalid actor'
        }
        [pscustomobject]@{
            label = 'console-injection'
            lines = @($validSidecarLines | ForEach-Object {
                if ($_ -ceq "action`t0`tinspect`tIdle`t24") {
                    "action`t0`tinspect`tIdle;Quit`t24"
                }
                else { $_ }
            })
            expected = 'invalid action'
        }
    )
    foreach ($invalidPlan in $invalidPlans) {
        $invalidPath = Join-Path ([System.IO.Path]::GetTempPath()) `
            "nikami-fnv-sidecar-plan-$($invalidPlan.label)-$token.tsv"
        $sidecarPlanPaths.Add($invalidPath)
        [System.IO.File]::WriteAllLines($invalidPath, [string[]]$invalidPlan.lines)
        $invalidArguments = @{}
        foreach ($key in $sidecarArguments.Keys) { $invalidArguments[$key] = $sidecarArguments[$key] }
        $invalidArguments.PlanPath = $invalidPath
        Assert-ThrowsLike {
            & $runner @invalidArguments
        } $invalidPlan.expected "Runner accepted the $($invalidPlan.label) sidecar plan."
    }

    [System.IO.File]::WriteAllText($output, "immutable-output-$token")
    [System.IO.File]::WriteAllText($runManifest, "immutable-manifest-$token")
    $overwriteValidation = & $runner @arguments
    Assert-Contract ([bool]$overwriteValidation.wouldOverwrite.output) `
        'DryRun did not report an existing output artifact.'
    Assert-Contract ([bool]$overwriteValidation.wouldOverwrite.runManifest) `
        'DryRun did not report an existing adjacent manifest.'
    Remove-Item -LiteralPath $output -Force
    Remove-Item -LiteralPath $runManifest -Force

    $optOut = & $runner @arguments -AllowRootHookDlls
    Assert-Contract (-not [bool]$optOut.rootHookIsolation) 'AllowRootHookDlls did not disable root DLL isolation.'
    Assert-Contract (@($optOut.rootHookDlls).Count -eq 0) 'AllowRootHookDlls still planned root DLL moves.'
    $legacyOptOut = & $runner @arguments -IsolateFromFNVXR:$false
    Assert-Contract (-not [bool]$legacyOptOut.rootHookIsolation) 'Explicit legacy isolation opt-out was not preserved.'

    Assert-ThrowsLike {
        & $runner @arguments -ScreenshotFrame 30, 30
    } 'ScreenshotFrame contains duplicate frame identities' `
        'Runner accepted duplicate screenshot identities.'
    Assert-ThrowsLike {
        & $runner @arguments -BatchTargetForm '0x00104C80', '0x00104C80'
    } 'BatchTargetForm contains duplicate target identities' `
        'Runner accepted duplicate batch target identities.'
    Assert-ThrowsLike {
        & $runner @arguments -BatchTargetForm '0x00104C80', '1068160'
    } 'BatchTargetForm contains duplicate target identities' `
        'Runner accepted duplicate batch targets expressed in different radices.'
    Assert-ThrowsLike {
        & $runner @arguments -BatchTargetForm '0x00104C80', '0x00104E85' `
            -BatchExpectedBaseForm '0x00104C7F'
    } 'BatchExpectedBaseForm count must be zero or equal BatchTargetForm count' `
        'Runner accepted incomplete batch base identities.'
    Assert-ThrowsLike {
        & $runner @arguments -ExpectedTargetBaseForm '0x00104C7F'
    } 'ExpectedTargetBaseForm requires a nonzero TargetForm' `
        'Runner accepted a base identity without a reference identity.'
    Assert-ThrowsLike {
        & $runner @arguments -TargetForm '0x100000000'
    } 'Expected a 32-bit decimal or 0x-prefixed FormID' `
        'Runner accepted an out-of-range target identity.'
    Assert-ThrowsLike {
        & $runner @arguments -TargetForm '0x00104C80' -BatchTargetForm '0x00104E85'
    } 'BatchTargetForm cannot be combined with single TargetForm/base identities' `
        'Runner accepted ambiguous single and batch target identities.'

    $outsidePlugin = Join-Path $gameRoot 'outside-oracle.dll'
    [System.IO.File]::WriteAllText($outsidePlugin, "outside-$token")
    $outsideArguments = @{}
    foreach ($key in $arguments.Keys) { $outsideArguments[$key] = $arguments[$key] }
    $outsideArguments.PluginDll = $outsidePlugin
    Assert-ThrowsLike {
        & $runner @outsideArguments
    } 'PluginDll must be the manifest-verified RuntimeRoot plugin' `
        'Runner accepted a plugin outside the isolated runtime.'

    $manifest.overlay.replayedTree = '0000000000000000000000000000000000000000'
    [System.IO.File]::WriteAllText(
        $manifestPath, (($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine))
    Assert-ThrowsLike {
        & $runner @arguments
    } 'does not match catalog lock' 'Runner accepted a mismatched replayedTree.'
}
finally {
    if (Test-Path -LiteralPath $runtimeRoot) {
        $expectedPrefix = (Join-Path $repoRoot 'local\xnvse-isolation-contract-')
        if (-not $runtimeRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected contract RuntimeRoot: $runtimeRoot"
        }
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $gameRoot) {
        $expectedPrefix = Join-Path ([System.IO.Path]::GetTempPath()) 'nikami-fnv-game-'
        if (-not $gameRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected contract GameRoot: $gameRoot"
        }
        Remove-Item -LiteralPath $gameRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Force
    }
    if (Test-Path -LiteralPath $runManifest) {
        Remove-Item -LiteralPath $runManifest -Force
    }
    foreach ($sidecarPlanPath in $sidecarPlanPaths) {
        if (-not $sidecarPlanPath.StartsWith(
            (Join-Path ([System.IO.Path]::GetTempPath()) 'nikami-fnv-sidecar-plan-'),
            [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected sidecar contract plan: $sidecarPlanPath"
        }
        if (Test-Path -LiteralPath $sidecarPlanPath) {
            Remove-Item -LiteralPath $sidecarPlanPath -Force
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'FNV retail-oracle isolation contract failures:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    throw "FNV retail-oracle isolation contract failed with $($failures.Count) error(s)."
}

Write-Host 'FNV retail-oracle isolation contract passed.'
