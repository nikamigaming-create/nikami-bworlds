[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputRoot,
    [string]$WorldsRoot = 'D:\code\nikami-worlds',
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas',
    [string]$RuntimeRoot = 'local\xnvse-retail-container-oracle',
    [string]$PluginDll = 'local\xnvse-retail-container-oracle\plugins\nvse_retail_oracle.dll',
    [string]$SavePath =
        'D:\code\nikami-worlds\local\retail-pipboy-fixtures\NikamiCleanPipBoyOracle-20260802.fos',
    [ValidateRange(60, 300)]
    [int]$TimeoutSeconds = 150
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite retail Doc-container capture: $OutputRoot"
}
if (-not (Test-Path -LiteralPath $SavePath -PathType Leaf)) {
    throw "Retail save fixture is missing: $SavePath"
}

$saveStem = 'NikamiDocContainer-{0}-{1}' -f $PID, ([Guid]::NewGuid().ToString('N'))
$saveDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\FalloutNV\Saves'
$generatedSavePaths = @(@('.fos', '.nvse', '.bak', '.fos.bak') | ForEach-Object {
    Join-Path $saveDirectory ($saveStem + $_)
})
foreach ($path in $generatedSavePaths) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite generated persistence fixture: $path"
    }
}

$oracle = Join-Path $WorldsRoot 'scripts\Invoke-FNVRetailOracle.ps1'
$shadowVerifier = Join-Path $WorldsRoot 'scripts\New-FNVRetailShadowGameRoot.ps1'
$evidenceValidator = Join-Path $WorldsRoot 'scripts\Test-FNVRetailDocContainerEvidence.ps1'
$telemetry = Join-Path $OutputRoot 'retail-doc-container.jsonl'
$reportPath = Join-Path $OutputRoot 'retail-doc-container-report.json'
$nativeFrameDirectory = Join-Path $OutputRoot 'native-frames'
$loadedModulesPath = Join-Path $OutputRoot 'retail-doc-container-loaded-modules.json'
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

# COC is disclosed proof staging only. It does not establish natural-route or
# presentation parity. Once the authored reference is resident, activation and
# transfer use retail-native entrypoints; no host input or menu key is injected.
$scheduled = @(
    '320:COC GSDocMitchellHouse'
    '450@0x00103E37:RetailContainerSnapshot resolved-before-activate'
    '470@0x00103E37:ActivateRetailContainer'
    '500@0x00103E37:RetailContainerSnapshot active-before-take'
    '520@0x00103E37:TakeOneRetailContainer'
    '540@0x00103E37:RetailContainerSnapshot active-after-take'
    '560:CloseAllMenus'
    "600:Save $saveStem"
    "720:LoadGame `"$saveStem`""
    # PostLoadGame resets the oracle frame counter but retains the schedule
    # cursor, so this sample occurs only after the generated save reloads.
    '820@0x00103E37:RetailContainerSnapshot after-reload'
)

$captureFailure = $null
$oracleJob = $null
$shadowProcess = $null
$captureCleanExit = $false
$wrapperFailure = ''
try {
    $oracleArguments = @{
        GameRoot = $GameRoot
        RuntimeRoot = $RuntimeRoot
        PluginDll = $PluginDll
        OutputPath = $telemetry
        SaveFixture = $SavePath
        ScheduledCommand = $scheduled
        VisibleGame = $true
        IsolateFromFNVXR = $true
        SampleEvery = 5
        BeforeFrame = 450
        CommandFrame = 520
        AfterFrame = 820
        ScreenshotFrame = @(510)
        ScreenshotDirectory = $nativeFrameDirectory
        MaxFrames = 860
        TimeoutSeconds = $TimeoutSeconds
    }
    $oracleJob = Start-Job -ScriptBlock {
        param([string]$OraclePath, [hashtable]$OracleArguments)
        & $OraclePath @OracleArguments
    } -ArgumentList $oracle, $oracleArguments

    $expectedProcessPath = [IO.Path]::GetFullPath((Join-Path $GameRoot 'FalloutNV.exe'))
    $processDeadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $shadowMatches = @(Get-Process -Name FalloutNV -ErrorAction SilentlyContinue | Where-Object {
            try { [IO.Path]::GetFullPath($_.Path) -eq $expectedProcessPath } catch { $false }
        })
        if ($shadowMatches.Count -gt 1) {
            throw "More than one exact retail-shadow FalloutNV process is running."
        }
        if ($shadowMatches.Count -eq 1) {
            $shadowProcess = $shadowMatches[0]
            break
        }
        $oracleJob = Get-Job -Id $oracleJob.Id
        if ($oracleJob.State -in @('Completed', 'Failed', 'Stopped')) {
            Receive-Job -Job $oracleJob -ErrorAction Stop | Out-Null
            throw "Retail oracle ended before the exact shadow process could be verified."
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $processDeadline)
    if ($null -eq $shadowProcess) {
        throw "Timed out locating the exact retail-shadow FalloutNV process."
    }

    # FalloutNV.exe exists briefly before xNVSE finishes attaching. Verify the
    # live whitelist only after both the isolated core and oracle module are
    # resident; otherwise an early clean process is indistinguishable from a
    # launch that silently bypassed xNVSE.
    $moduleDeadline = [DateTime]::UtcNow.AddSeconds(30)
    $requiredModulesResident = $false
    $expectedCorePath = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot 'nvse_1_4.dll'))
    $isolatedRunsRoot = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot '.runs')) +
        [IO.Path]::DirectorySeparatorChar
    $expectedPluginHash = (Get-FileHash -LiteralPath $PluginDll -Algorithm SHA256).Hash
    do {
        try {
            $shadowProcess.Refresh()
            if ($shadowProcess.HasExited) { break }
            $liveModules = @($shadowProcess.Modules | ForEach-Object {
                [pscustomobject]@{
                    name = $_.ModuleName
                    path = [IO.Path]::GetFullPath($_.FileName)
                }
            })
            $coreMatches = @($liveModules | Where-Object {
                $_.name -ieq 'nvse_1_4.dll' -and $_.path -eq $expectedCorePath
            })
            $oracleMatches = @($liveModules | Where-Object {
                $_.name -ieq 'nvse_retail_oracle.dll' -and
                $_.path.StartsWith($isolatedRunsRoot, [StringComparison]::OrdinalIgnoreCase) -and
                (Get-FileHash -LiteralPath $_.path -Algorithm SHA256).Hash -eq $expectedPluginHash
            })
            $requiredModulesResident = $coreMatches.Count -eq 1 -and $oracleMatches.Count -eq 1
        }
        catch {
            $requiredModulesResident = $false
        }
        if (-not $requiredModulesResident) {
            Start-Sleep -Milliseconds 100
        }
    } while (-not $requiredModulesResident -and [DateTime]::UtcNow -lt $moduleDeadline)
    if (-not $requiredModulesResident) {
        throw "The exact retail-shadow process never loaded the isolated xNVSE core and oracle modules."
    }

    & $shadowVerifier `
        -Mode VerifyProcess `
        -ShadowRoot $GameRoot `
        -ExternalRuntimeRoot $RuntimeRoot `
        -TargetProcessId $shadowProcess.Id `
        -VerificationPath $loadedModulesPath | Out-Null

    $completedJob = Wait-Job -Job $oracleJob -Timeout ($TimeoutSeconds + 30)
    if ($null -eq $completedJob) {
        $captureCompleted = Test-Path -LiteralPath $telemetry -PathType Leaf -and
            $null -ne (Select-String -LiteralPath $telemetry -SimpleMatch '"event":"capture-complete"' |
                Select-Object -First 1)
        if (-not $captureCompleted) {
            throw "Retail oracle job exceeded its bounded capture timeout before capture-complete."
        }
        $wrapperFailure = 'Retail oracle job exceeded its bounded wrapper timeout after capture-complete.'
    }
    else {
        Receive-Job -Job $oracleJob -ErrorAction Stop | Out-Null
        $captureCleanExit = $true
    }
}
catch {
    $captureCompleted = Test-Path -LiteralPath $telemetry -PathType Leaf -and
        $null -ne (Select-String -LiteralPath $telemetry -SimpleMatch '"event":"capture-complete"' |
            Select-Object -First 1)
    if ($captureCompleted) {
        $wrapperFailure = $_.Exception.Message
    }
    else {
        $captureFailure = $_
    }
}
finally {
    if ($null -ne $oracleJob) {
        $oracleJob = Get-Job -Id $oracleJob.Id -ErrorAction SilentlyContinue
        if ($null -ne $oracleJob) {
            if ($oracleJob.State -notin @('Completed', 'Failed', 'Stopped')) {
                Stop-Job -Job $oracleJob -ErrorAction SilentlyContinue
            }
            Remove-Job -Job $oracleJob -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $shadowProcess) {
        try {
            $shadowProcess.Refresh()
            if (-not $shadowProcess.HasExited) {
                $actualProcessPath = [IO.Path]::GetFullPath($shadowProcess.Path)
                $expectedProcessPath = [IO.Path]::GetFullPath((Join-Path $GameRoot 'FalloutNV.exe'))
                if ($actualProcessPath -ne $expectedProcessPath) {
                    throw "Refusing to stop a process outside the exact retail shadow: $actualProcessPath"
                }
                Stop-Process -Id $shadowProcess.Id -Force -ErrorAction Stop
                $shadowProcess.WaitForExit(10000) | Out-Null
            }
        }
        finally {
            $shadowProcess.Dispose()
        }
    }
    foreach ($path in $generatedSavePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
if ($null -ne $captureFailure) {
    throw $captureFailure
}

$validatorArguments = @{
    EvidenceRoot = $OutputRoot
    ReportPath = $reportPath
    CaptureCleanExit = $captureCleanExit
    WrapperFailure = $wrapperFailure
}
$report = & $evidenceValidator @validatorArguments
if ([string]$report.canonicalCaptureStatus -ne 'pass') {
    throw "Retail container contract evidence was retained, but the canonical capture wrapper failed. See $reportPath"
}
$report
