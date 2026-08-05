[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\\code\\nikami-worlds",
    [string]$RunRoot = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c02-openmw-20260802-160545",
    [string]$DenominatorPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-map-marker-denominator.json",
    [string]$ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c02-marker-restoration-validation.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$DenominatorPath = [IO.Path]::GetFullPath($DenominatorPath)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)
$OpenMwRoot = Join-Path $RunRoot "openmw"
$SummaryPath = Join-Path $RunRoot "background-capture-summary.json"
$CombinedReportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$SavePhaseRoot = Join-Path $OpenMwRoot "save330-before-reload"
$ReloadPhaseRoot = Join-Path $OpenMwRoot "save330-after-reload"
$SavePhaseReportPath = Join-Path $SavePhaseRoot "real-save-capture-report.json"
$ReloadPhaseReportPath = Join-Path $ReloadPhaseRoot "real-save-capture-report.json"
$SavePhaseLogPath = Join-Path $SavePhaseRoot "openmw.stdout.log"
$ReloadPhaseLogPath = Join-Path $ReloadPhaseRoot "openmw.stdout.log"
$Save330Path = Join-Path $WorldsRoot "local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos"

if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing C02 validation artifact: $ValidationPath"
}

$checks = [Collections.Generic.List[object]]::new()
$script:c02AllPass = $true

function Add-C02Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) {
        $script:c02AllPass = $false
    }
}

function Read-C02Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { return $null }
}

function Get-C02Property {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-C02Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Convert-C02FormId {
    param([AllowNull()][object]$Value)
    $match = [regex]::Match([string]$Value, '0x(?<hex>[0-9a-fA-F]{1,8})$')
    if (-not $match.Success) { return [string]$Value }
    return "0x$($match.Groups['hex'].Value.PadLeft(8, '0').ToUpperInvariant())"
}

function Get-C02Rows {
    param([Parameter(Mandatory = $true)][string]$Log)
    $pattern = 'FNV C02 restored marker: phase=pre-proximity-discovery id=FormId:(?<id>0x[0-9a-fA-F]+) name="(?<name>.*?)" state=(?<state>\d+) authoredState=(?<authoredState>\d+) override=(?<override>-?\d+) overridePresent=(?<overridePresent>[01])'
    return @([regex]::Matches($Log, $pattern) | ForEach-Object {
            [ordered]@{
                formId = Convert-C02FormId $_.Groups['id'].Value
                name = $_.Groups['name'].Value
                state = [int]$_.Groups['state'].Value
                authoredState = [int]$_.Groups['authoredState'].Value
                override = [int64]$_.Groups['override'].Value
                overridePresent = $_.Groups['overridePresent'].Value -eq '1'
                index = [int64]$_.Index
                end = [int64]($_.Index + $_.Length)
            }
        })
}

function Get-C02SummaryMatch {
    param([Parameter(Mandatory = $true)][string]$Log)
    return [regex]::Match($Log, 'FNV C02 marker restoration snapshot: phase=pre-proximity-discovery rows=(?<rows>\d+) visible=(?<visible>\d+) travel=(?<travel>\d+) overrides=(?<overrides>\d+)')
}

function Get-C02Summary {
    param([Parameter(Mandatory = $true)][string]$Log)
    $match = Get-C02SummaryMatch $Log
    if (-not $match.Success) { return $null }
    return [ordered]@{
        rows = [int]$match.Groups['rows'].Value
        visible = [int]$match.Groups['visible'].Value
        travel = [int]$match.Groups['travel'].Value
        overrides = [int]$match.Groups['overrides'].Value
        index = [int64]$match.Index
        end = [int64]($match.Index + $match.Length)
    }
}

function Get-C02CaptureArtifact {
    param(
        [AllowNull()][object]$Report,
        [Parameter(Mandatory = $true)][string]$Property
    )
    $entry = Get-C02Property $Report $Property
    $path = Get-C02Property $entry 'path'
    if ($null -eq $path) { return $null }
    return Get-C02Artifact ([string]$path)
}

$summary = Read-C02Json $SummaryPath
$combinedReport = Read-C02Json $CombinedReportPath
$saveReport = Read-C02Json $SavePhaseReportPath
$reloadReport = Read-C02Json $ReloadPhaseReportPath
$denominator = Read-C02Json $DenominatorPath
$saveLog = if (Test-Path -LiteralPath $SavePhaseLogPath -PathType Leaf) { Get-Content -Raw -LiteralPath $SavePhaseLogPath } else { '' }
$reloadLog = if (Test-Path -LiteralPath $ReloadPhaseLogPath -PathType Leaf) { Get-Content -Raw -LiteralPath $ReloadPhaseLogPath } else { '' }
$saveRows = @(Get-C02Rows $saveLog)
$reloadRows = @(Get-C02Rows $reloadLog)
$saveSummary = Get-C02Summary $saveLog
$reloadSummary = Get-C02Summary $reloadLog
$denominatorRows = @($denominator.markers)

$save330Artifact = Get-C02Artifact $Save330Path
$denominatorArtifact = Get-C02Artifact $DenominatorPath
$summaryArtifact = Get-C02Artifact $SummaryPath
$combinedReportArtifact = Get-C02Artifact $CombinedReportPath
$saveLogArtifact = Get-C02Artifact $SavePhaseLogPath
$reloadLogArtifact = Get-C02Artifact $ReloadPhaseLogPath
$binaryEntry = Get-C02Property (Get-C02Property $combinedReport 'source') 'binary'
$binaryArtifact = if ($null -eq $binaryEntry) { $null } else { Get-C02Artifact ([string](Get-C02Property $binaryEntry 'path')) }

Add-C02Check 'Run summary and combined report pass' `
    ($null -ne $summary -and (Get-C02Property $summary 'status') -eq 'pass' -and
     $null -ne $combinedReport -and (Get-C02Property $combinedReport 'status') -eq 'pass') `
    ([ordered]@{ summary = $SummaryPath; combined = $CombinedReportPath })
Add-C02Check 'Both sequential phase reports pass' `
    ($null -ne $saveReport -and (Get-C02Property $saveReport 'status') -eq 'pass' -and
     $null -ne $reloadReport -and (Get-C02Property $reloadReport 'status') -eq 'pass') `
    ([ordered]@{ save = $SavePhaseReportPath; reload = $ReloadPhaseReportPath })
$policy = Get-C02Property $summary 'policy'
Add-C02Check 'Capture has no host control, no foreground input, and no overwrite' `
    ($null -ne $policy -and -not [bool](Get-C02Property $policy 'windowsAppControlUsed') -and
     -not [bool](Get-C02Property $policy 'foregroundActivationUsed') -and
     -not [bool](Get-C02Property $policy 'foregroundInputInjected') -and
     [bool](Get-C02Property $policy 'capturesRanSequentially') -and
     -not [bool](Get-C02Property $policy 'outputOverwritten')) `
    $policy
Add-C02Check 'Immutable Save330 fixture hash is exact' `
    ($null -ne $save330Artifact -and $save330Artifact.bytes -eq 3395328 -and
     $save330Artifact.sha256 -eq '07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f') `
    $save330Artifact
Add-C02Check 'C01 denominator hash is exact and contains 320 rows' `
    ($null -ne $denominator -and $null -ne $denominatorArtifact -and
     $denominatorArtifact.sha256 -eq '43fb591ea5d3e117022fbabdd69ebbdb25e8e38099278db7fd1ba9cd9c3391d9' -and
     $denominatorRows.Count -eq 320) `
    ([ordered]@{ artifact = $denominatorArtifact; rows = $denominatorRows.Count })
Add-C02Check 'Captured binary provenance is retained and hash-consistent' `
    ($null -ne $binaryArtifact -and $null -ne $binaryEntry -and
     $binaryArtifact.sha256 -eq [string](Get-C02Property $binaryEntry 'sha256')) `
    $binaryArtifact
Add-C02Check 'C02 phase logs are retained' `
    ($null -ne $saveLogArtifact -and $null -ne $reloadLogArtifact) `
    ([ordered]@{ save = $saveLogArtifact; reload = $reloadLogArtifact })

$expectedRows = 320
Add-C02Check 'Native-load C02 snapshot has 320 rows and summary' `
    ($saveRows.Count -eq $expectedRows -and $null -ne $saveSummary -and $saveSummary.rows -eq $expectedRows) `
    ([ordered]@{ rows = $saveRows.Count; summary = $saveSummary })
Add-C02Check 'Cold-reload C02 snapshot has 320 rows and summary' `
    ($reloadRows.Count -eq $expectedRows -and $null -ne $reloadSummary -and $reloadSummary.rows -eq $expectedRows) `
    ([ordered]@{ rows = $reloadRows.Count; summary = $reloadSummary })

$saveIds = @($saveRows | ForEach-Object { $_.formId })
$reloadIds = @($reloadRows | ForEach-Object { $_.formId })
Add-C02Check 'C02 native-load FormIDs are unique' `
    ($saveIds.Count -eq @($saveIds | Sort-Object -Unique).Count) `
    "rows=$($saveIds.Count) unique=$(@($saveIds | Sort-Object -Unique).Count)"
Add-C02Check 'C02 cold-reload FormIDs are unique' `
    ($reloadIds.Count -eq @($reloadIds | Sort-Object -Unique).Count) `
    "rows=$($reloadIds.Count) unique=$(@($reloadIds | Sort-Object -Unique).Count)"

$denominatorById = @{}
foreach ($row in $denominatorRows) {
    $denominatorById[[string]$row.formId] = $row
}

function Test-C02RowsAgainstDenominator {
    param([Parameter(Mandatory = $true)][object[]]$Rows)
    $mismatches = [Collections.Generic.List[object]]::new()
    foreach ($row in $Rows) {
        if (-not $denominatorById.ContainsKey([string]$row.formId)) {
            $mismatches.Add([ordered]@{ formId = $row.formId; reason = 'missing-from-c01-denominator' })
            continue
        }
        $base = $denominatorById[[string]$row.formId]
        $authoredState = if ([bool]$base.authoredCanTravel) { 2 } elseif ([bool]$base.authoredVisible) { 1 } else { 0 }
        if ([string]$row.name -ne [string]$base.name -or
            [int]$row.state -ne [int]$base.savedRuntimeState -or
            [int]$row.authoredState -ne $authoredState -or
            [bool]$row.overridePresent -or
            ([int64]$row.override -ne -1 -and [int64]$row.override -ne [uint32]::MaxValue)) {
            $mismatches.Add([ordered]@{
                    formId = $row.formId
                    expectedName = $base.name
                    observedName = $row.name
                    expectedState = $base.savedRuntimeState
                    observedState = $row.state
                    expectedAuthoredState = $authoredState
                    observedAuthoredState = $row.authoredState
                    overridePresent = $row.overridePresent
                    override = $row.override
                })
        }
    }
    $extra = @($denominatorById.Keys | Where-Object { $_ -notin @($Rows | ForEach-Object { $_.formId }) })
    foreach ($id in $extra) {
        $mismatches.Add([ordered]@{ formId = $id; reason = 'missing-from-c02-snapshot' })
    }
    return @($mismatches)
}

$saveMismatches = @(Test-C02RowsAgainstDenominator $saveRows)
$reloadMismatches = @(Test-C02RowsAgainstDenominator $reloadRows)
Add-C02Check 'Native-load restored states and authored fallback match C01 exactly' `
    ($saveMismatches.Count -eq 0) `
    "mismatches=$($saveMismatches.Count)"
Add-C02Check 'Cold-reload restored states and authored fallback match C01 exactly' `
    ($reloadMismatches.Count -eq 0) `
    "mismatches=$($reloadMismatches.Count)"

$saveInvalidState = @($saveRows | Where-Object { $_.state -notin @(0, 1, 2) -or $_.authoredState -notin @(0, 1, 2) })
$reloadInvalidState = @($reloadRows | Where-Object { $_.state -notin @(0, 1, 2) -or $_.authoredState -notin @(0, 1, 2) })
Add-C02Check 'C02 state values remain in the 0/1/2 domain' `
    ($saveInvalidState.Count -eq 0 -and $reloadInvalidState.Count -eq 0) `
    ([ordered]@{ saveInvalid = $saveInvalidState.Count; reloadInvalid = $reloadInvalidState.Count })
Add-C02Check 'No explicit map-marker runtime override is restored' `
    (@($saveRows | Where-Object { $_.overridePresent }).Count -eq 0 -and
     @($reloadRows | Where-Object { $_.overridePresent }).Count -eq 0 -and
     $saveSummary.overrides -eq 0 -and $reloadSummary.overrides -eq 0) `
    ([ordered]@{ save = $saveSummary.overrides; reload = $reloadSummary.overrides })

$saveFirstRow = if ($saveRows.Count -gt 0) { $saveRows[0] } else { $null }
$saveLastRow = if ($saveRows.Count -gt 0) { $saveRows[-1] } else { $null }
$saveBoundaryMatch = [regex]::Match($saveLog, 'FNV C02 proximity discovery boundary: phase=post-load')
$reloadFirstRow = if ($reloadRows.Count -gt 0) { $reloadRows[0] } else { $null }
$reloadLastRow = if ($reloadRows.Count -gt 0) { $reloadRows[-1] } else { $null }
$reloadBoundaryMatch = [regex]::Match($reloadLog, 'FNV C02 proximity discovery boundary: phase=post-load')
$saveOrder = ($null -ne $saveFirstRow -and $null -ne $saveLastRow -and $saveSummary.index -gt $saveLastRow.end -and
    $saveBoundaryMatch.Success -and $saveBoundaryMatch.Index -gt $saveSummary.end)
$reloadOrder = ($null -ne $reloadFirstRow -and $null -ne $reloadLastRow -and $reloadSummary.index -gt $reloadLastRow.end -and
    $reloadBoundaryMatch.Success -and $reloadBoundaryMatch.Index -gt $reloadSummary.end)
Add-C02Check 'Native-load restored snapshot precedes the first proximity-discovery boundary' `
    $saveOrder `
    ([ordered]@{ firstRow = if ($null -eq $saveFirstRow) { $null } else { $saveFirstRow.index }; lastRow = if ($null -eq $saveLastRow) { $null } else { $saveLastRow.end }; summary = if ($null -eq $saveSummary) { $null } else { $saveSummary.index }; boundary = if ($saveBoundaryMatch.Success) { $saveBoundaryMatch.Index } else { $null } })
Add-C02Check 'Cold-reload restored snapshot precedes the first proximity-discovery boundary' `
    $reloadOrder `
    ([ordered]@{ firstRow = if ($null -eq $reloadFirstRow) { $null } else { $reloadFirstRow.index }; lastRow = if ($null -eq $reloadLastRow) { $null } else { $reloadLastRow.end }; summary = if ($null -eq $reloadSummary) { $null } else { $reloadSummary.index }; boundary = if ($reloadBoundaryMatch.Success) { $reloadBoundaryMatch.Index } else { $null } })

$shortcutPattern = '(?i)(unlocked all authored exterior markers|OPENMW_FNV_UNLOCK_ALL_MAP_MARKERS|TestMap01|bootstrap inventory|fallback inventory|FNV_PROOF inventory|ShowMap id=)'
Add-C02Check 'No unlock-all, ShowMap, synthetic, or fallback shortcut appears' `
    ($saveLog -notmatch $shortcutPattern -and $reloadLog -notmatch $shortcutPattern) `
    $shortcutPattern

$validation = [ordered]@{
    schema = 'nikami-fnv-real-save-c02-validation/v1'
    status = if ($script:c02AllPass) { 'pass' } else { 'fail' }
    objective = 'Prove the canonical Save330 marker states are restored before proximity discovery and survive cold reload.'
    source = [ordered]@{
        fixture = $save330Artifact
        c01Denominator = $denominatorArtifact
        capture = [ordered]@{
            runRoot = $RunRoot
            summary = $summaryArtifact
            combinedReport = $combinedReportArtifact
            binary = $binaryArtifact
            nativeLoadLog = $saveLogArtifact
            coldReloadLog = $reloadLogArtifact
        }
    }
    expected = [ordered]@{
        markerRows = 320
        restoredStateDomain = @(0, 1, 2)
        ordering = 'All 320 restored rows and the snapshot summary precede the first FNV C02 proximity discovery boundary.'
        overridePolicy = 'No explicit runtime marker override or unlock-all proof switch is accepted.'
    }
    phases = [ordered]@{
        nativeLoad = [ordered]@{ rows = $saveRows.Count; summary = $saveSummary; mismatches = $saveMismatches; orderingPass = $saveOrder }
        coldReload = [ordered]@{ rows = $reloadRows.Count; summary = $reloadSummary; mismatches = $reloadMismatches; orderingPass = $reloadOrder }
    }
    checks = @($checks)
}
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 18) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

if (-not $script:c02AllPass) {
    throw "C02 validation failed. See $ValidationPath"
}

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $checks.Count
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-C02Artifact $ValidationPath
    nativeRows = $saveRows.Count
    coldReloadRows = $reloadRows.Count
    nativeOrderingPass = $saveOrder
    coldReloadOrderingPass = $reloadOrder
}
