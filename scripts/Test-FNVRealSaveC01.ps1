[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\\code\\nikami-worlds",
    [string]$RunRoot = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c01-openmw-20260802-155750",
    [string]$ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c01-map-marker-validation.json",
    [string]$DenominatorPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-map-marker-denominator.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)
$DenominatorPath = [IO.Path]::GetFullPath($DenominatorPath)
$OpenMwRoot = Join-Path $RunRoot "openmw"
$SummaryPath = Join-Path $RunRoot "background-capture-summary.json"
$CombinedReportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$SavePhaseRoot = Join-Path $OpenMwRoot "save330-before-reload"
$ReloadPhaseRoot = Join-Path $OpenMwRoot "save330-after-reload"
$SavePhaseReportPath = Join-Path $SavePhaseRoot "real-save-capture-report.json"
$ReloadPhaseReportPath = Join-Path $ReloadPhaseRoot "real-save-capture-report.json"
$SavePhaseStatePath = Join-Path $SavePhaseRoot "real-save-state.json"
$ReloadPhaseStatePath = Join-Path $ReloadPhaseRoot "real-save-state.json"
$SavePhaseLogPath = Join-Path $SavePhaseRoot "openmw.stdout.log"
$ReloadPhaseLogPath = Join-Path $ReloadPhaseRoot "openmw.stdout.log"
$Save330Path = Join-Path $WorldsRoot "local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos"
$A03Path = Join-Path $WorldsRoot "run\fnv-real-save-campaign\save330-player-denominator.json"

if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing C01 validation artifact: $ValidationPath"
}
if (Test-Path -LiteralPath $DenominatorPath) {
    throw "Refusing to overwrite an existing C01 denominator: $DenominatorPath"
}

$checks = [Collections.Generic.List[object]]::new()
$script:c01AllPass = $true

function Add-C01Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) {
        $script:c01AllPass = $false
    }
}

function Read-C01Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-C01Property {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-C01Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Convert-C01FormId {
    param([AllowNull()][object]$Value)
    $match = [regex]::Match([string]$Value, '0x(?<hex>[0-9a-fA-F]{1,8})$')
    if (-not $match.Success) {
        return [string]$Value
    }
    return "0x$($match.Groups['hex'].Value.PadLeft(8, '0').ToUpperInvariant())"
}

function Test-C01Finite {
    param([double]$Value)
    return (-not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value))
}

function Get-C01MarkerRows {
    param([Parameter(Mandatory = $true)][string]$Log)

    $pattern = 'FNV C01 map marker: id=FormId:(?<id>0x[0-9a-fA-F]+) name="(?<name>.*?)" iconType=(?<iconType>\d+) worldspace=FormId:(?<worldspace>0x[0-9a-fA-F]+) cell=FormId:(?<cell>0x[0-9a-fA-F]+) grid=\((?<gridX>-?\d+),(?<gridY>-?\d+)\) pos=\((?<px>[-+0-9.eE]+),(?<py>[-+0-9.eE]+),(?<pz>[-+0-9.eE]+)\) state=(?<state>\d+) authoredVisible=(?<authoredVisible>[01]) authoredCanTravel=(?<authoredCanTravel>[01]) referenceValid=(?<referenceValid>[01]) destinationCellValid=(?<destinationCellValid>[01]) destinationWorldspaceValid=(?<destinationWorldspaceValid>[01]) destinationValid=(?<destinationValid>[01])'
    return @([regex]::Matches($Log, $pattern) | ForEach-Object {
            [ordered]@{
                formId = Convert-C01FormId $_.Groups['id'].Value
                name = $_.Groups['name'].Value
                iconType = [int]$_.Groups['iconType'].Value
                worldspace = Convert-C01FormId $_.Groups['worldspace'].Value
                cell = Convert-C01FormId $_.Groups['cell'].Value
                grid = @([int]$_.Groups['gridX'].Value, [int]$_.Groups['gridY'].Value)
                position = @([double]$_.Groups['px'].Value, [double]$_.Groups['py'].Value, [double]$_.Groups['pz'].Value)
                savedRuntimeState = [int]$_.Groups['state'].Value
                authoredVisible = $_.Groups['authoredVisible'].Value -eq '1'
                authoredCanTravel = $_.Groups['authoredCanTravel'].Value -eq '1'
                referenceValid = $_.Groups['referenceValid'].Value -eq '1'
                destinationCellValid = $_.Groups['destinationCellValid'].Value -eq '1'
                destinationWorldspaceValid = $_.Groups['destinationWorldspaceValid'].Value -eq '1'
                destinationValid = $_.Groups['destinationValid'].Value -eq '1'
            }
        })
}

function Get-C01MarkerSummary {
    param([Parameter(Mandatory = $true)][string]$Log)
    $match = [regex]::Match($Log, 'FNV B04 persistence: OpenMW save map markers authored=(?<authored>\d+) visible=(?<visible>\d+) travel=(?<travel>\d+) overrides=(?<overrides>\d+)')
    if (-not $match.Success) {
        return $null
    }
    return [ordered]@{
        authored = [int]$match.Groups['authored'].Value
        visible = [int]$match.Groups['visible'].Value
        travel = [int]$match.Groups['travel'].Value
        overrides = [int]$match.Groups['overrides'].Value
    }
}

function Get-C01MarkerSignature {
    param([Parameter(Mandatory = $true)][object]$Row)
    return @(
        [string]$Row.formId,
        [string]$Row.name,
        [string]$Row.iconType,
        [string]$Row.worldspace,
        [string]$Row.cell,
        "$($Row.grid[0]),$($Row.grid[1])",
        "$($Row.position[0]),$($Row.position[1]),$($Row.position[2])",
        [string]$Row.savedRuntimeState,
        [int]$Row.authoredVisible,
        [int]$Row.authoredCanTravel,
        [int]$Row.referenceValid,
        [int]$Row.destinationCellValid,
        [int]$Row.destinationWorldspaceValid,
        [int]$Row.destinationValid
    ) -join '|'
}

function Get-C01NestedArtifact {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $path = Get-C01Property $Object 'path'
    if ($null -eq $path) {
        return $null
    }
    return Get-C01Artifact ([string]$path)
}

$summary = Read-C01Json $SummaryPath
$combinedReport = Read-C01Json $CombinedReportPath
$saveReport = Read-C01Json $SavePhaseReportPath
$reloadReport = Read-C01Json $ReloadPhaseReportPath
$saveState = Read-C01Json $SavePhaseStatePath
$reloadState = Read-C01Json $ReloadPhaseStatePath
$saveLog = if (Test-Path -LiteralPath $SavePhaseLogPath -PathType Leaf) { Get-Content -Raw -LiteralPath $SavePhaseLogPath } else { '' }
$reloadLog = if (Test-Path -LiteralPath $ReloadPhaseLogPath -PathType Leaf) { Get-Content -Raw -LiteralPath $ReloadPhaseLogPath } else { '' }
$saveRows = @(Get-C01MarkerRows $saveLog)
$reloadRows = @(Get-C01MarkerRows $reloadLog)
$saveMarkerSummary = Get-C01MarkerSummary $saveLog
$reloadMarkerSummary = Get-C01MarkerSummary $reloadLog

$fixtureArtifact = Get-C01Artifact $Save330Path
$a03Artifact = Get-C01Artifact $A03Path
$summaryArtifact = Get-C01Artifact $SummaryPath
$combinedReportArtifact = Get-C01Artifact $CombinedReportPath
$saveLogArtifact = Get-C01Artifact $SavePhaseLogPath
$reloadLogArtifact = Get-C01Artifact $ReloadPhaseLogPath
$binaryPath = [string](Get-C01Property (Get-C01Property $combinedReport 'source') 'binary' | ForEach-Object { Get-C01Property $_ 'path' })
$binaryArtifact = if ([string]::IsNullOrWhiteSpace($binaryPath)) { $null } else { Get-C01Artifact $binaryPath }

Add-C01Check 'Run summary exists and passes' `
    ($null -ne $summary -and (Get-C01Property $summary 'status') -eq 'pass') `
    $SummaryPath
Add-C01Check 'Combined RealSave report passes' `
    ($null -ne $combinedReport -and (Get-C01Property $combinedReport 'status') -eq 'pass') `
    $CombinedReportPath
Add-C01Check 'Both sequential phase reports pass' `
    ($null -ne $saveReport -and (Get-C01Property $saveReport 'status') -eq 'pass' -and
     $null -ne $reloadReport -and (Get-C01Property $reloadReport 'status') -eq 'pass') `
    "save=$SavePhaseReportPath reload=$ReloadPhaseReportPath"
Add-C01Check 'Both phase state manifests pass' `
    ($null -ne $saveState -and (Get-C01Property $saveState 'status') -eq 'pass' -and
     $null -ne $reloadState -and (Get-C01Property $reloadState 'status') -eq 'pass') `
    "save=$SavePhaseStatePath reload=$ReloadPhaseStatePath"

$policy = Get-C01Property $summary 'policy'
Add-C01Check 'Capture policy has no host control and is sequential' `
    ($null -ne $policy -and -not [bool](Get-C01Property $policy 'windowsAppControlUsed') -and
     -not [bool](Get-C01Property $policy 'foregroundActivationUsed') -and
     -not [bool](Get-C01Property $policy 'foregroundInputInjected') -and
     [bool](Get-C01Property $policy 'capturesRanSequentially') -and
     -not [bool](Get-C01Property $policy 'outputOverwritten')) `
    $policy

Add-C01Check 'Immutable Save330 fixture is exact' `
    ($null -ne $fixtureArtifact -and $fixtureArtifact.bytes -eq 3395328 -and
     $fixtureArtifact.sha256 -eq '07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f') `
    $fixtureArtifact
Add-C01Check 'A03 normalized denominator exists and uses the same fixture' `
    ($null -ne $a03Artifact -and $a03Artifact.sha256 -eq 'ae9b020591c5cc176e4a1a47bd9715cbf758e7bb3118a0376cfe4d2a05e92b92') `
    $a03Artifact
Add-C01Check 'Captured binary provenance is retained and readable' `
    ($null -ne $binaryArtifact -and $binaryArtifact.bytes -gt 0 -and
     $binaryArtifact.sha256 -eq [string](Get-C01Property (Get-C01Property $combinedReport 'source') 'binary' | ForEach-Object { Get-C01Property $_ 'sha256' })) `
    $binaryArtifact
Add-C01Check 'C01 production logs are retained' `
    ($null -ne $saveLogArtifact -and $null -ne $reloadLogArtifact) `
    "save=$saveLogArtifact reload=$reloadLogArtifact"

$expectedMarkerCount = 320
Add-C01Check 'Native-load phase contains the official authored marker count' `
    ($saveRows.Count -eq $expectedMarkerCount -and $null -ne $saveMarkerSummary -and
     $saveMarkerSummary.authored -eq $expectedMarkerCount) `
    ([ordered]@{ rows = $saveRows.Count; summary = $saveMarkerSummary })
Add-C01Check 'Cold-reload phase contains the official authored marker count' `
    ($reloadRows.Count -eq $expectedMarkerCount -and $null -ne $reloadMarkerSummary -and
     $reloadMarkerSummary.authored -eq $expectedMarkerCount) `
    ([ordered]@{ rows = $reloadRows.Count; summary = $reloadMarkerSummary })

$saveIds = @($saveRows | ForEach-Object { $_.formId })
$reloadIds = @($reloadRows | ForEach-Object { $_.formId })
Add-C01Check 'Native-load marker FormIDs are unique' `
    ($saveIds.Count -eq @($saveIds | Sort-Object -Unique).Count) `
    "rows=$($saveIds.Count) unique=$(@($saveIds | Sort-Object -Unique).Count)"
Add-C01Check 'Cold-reload marker FormIDs are unique' `
    ($reloadIds.Count -eq @($reloadIds | Sort-Object -Unique).Count) `
    "rows=$($reloadIds.Count) unique=$(@($reloadIds | Sort-Object -Unique).Count)"

$saveInvalidStates = @($saveRows | Where-Object { $_.savedRuntimeState -notin @(0, 1, 2) })
$reloadInvalidStates = @($reloadRows | Where-Object { $_.savedRuntimeState -notin @(0, 1, 2) })
Add-C01Check 'Saved runtime states are restricted to 0/1/2' `
    ($saveInvalidStates.Count -eq 0 -and $reloadInvalidStates.Count -eq 0) `
    ([ordered]@{ saveInvalid = $saveInvalidStates.Count; reloadInvalid = $reloadInvalidStates.Count })

$saveMalformed = @($saveRows | Where-Object {
        [string]::IsNullOrWhiteSpace($_.formId) -or [string]::IsNullOrWhiteSpace($_.name) -or
        $_.iconType -lt 0 -or $_.iconType -gt 14 -or [string]::IsNullOrWhiteSpace($_.worldspace) -or
        [string]::IsNullOrWhiteSpace($_.cell) -or $_.grid.Count -ne 2 -or $_.position.Count -ne 3 -or
        -not (Test-C01Finite $_.position[0]) -or -not (Test-C01Finite $_.position[1]) -or
        -not (Test-C01Finite $_.position[2])
    })
Add-C01Check 'Every native-load marker has complete finite denominator fields' `
    ($saveMalformed.Count -eq 0) `
    "malformed=$($saveMalformed.Count)"

$displayedInvalidReference = @($saveRows | Where-Object { $_.savedRuntimeState -gt 0 -and -not $_.referenceValid })
$travelInvalidDestination = @($saveRows | Where-Object {
        ($_.authoredCanTravel -or $_.savedRuntimeState -eq 2) -and -not $_.destinationValid
    })
Add-C01Check 'Every displayed marker has a valid reference' `
    ($displayedInvalidReference.Count -eq 0) `
    "invalid=$($displayedInvalidReference.Count)"
Add-C01Check 'Every travel-enabled marker resolves an authored destination' `
    ($travelInvalidDestination.Count -eq 0) `
    "invalid=$($travelInvalidDestination.Count)"
Add-C01Check 'Every authored marker resolves an exterior cell/worldspace destination' `
    (@($saveRows | Where-Object { -not $_.destinationCellValid -or -not $_.destinationWorldspaceValid -or -not $_.destinationValid }).Count -eq 0) `
    "invalid=$(@($saveRows | Where-Object { -not $_.destinationCellValid -or -not $_.destinationWorldspaceValid -or -not $_.destinationValid }).Count)"

$computedSaveSummary = [ordered]@{
    authored = $saveRows.Count
    visible = @($saveRows | Where-Object { $_.savedRuntimeState -gt 0 }).Count
    travel = @($saveRows | Where-Object { $_.savedRuntimeState -eq 2 }).Count
    overrides = 0
}
$computedReloadSummary = [ordered]@{
    authored = $reloadRows.Count
    visible = @($reloadRows | Where-Object { $_.savedRuntimeState -gt 0 }).Count
    travel = @($reloadRows | Where-Object { $_.savedRuntimeState -eq 2 }).Count
    overrides = 0
}
Add-C01Check 'Native-load summary agrees with marker rows and has no overrides' `
    ($null -ne $saveMarkerSummary -and $saveMarkerSummary.authored -eq $computedSaveSummary.authored -and
     $saveMarkerSummary.visible -eq $computedSaveSummary.visible -and $saveMarkerSummary.travel -eq $computedSaveSummary.travel -and
     $saveMarkerSummary.overrides -eq 0) `
    ([ordered]@{ observed = $saveMarkerSummary; computed = $computedSaveSummary })
Add-C01Check 'Cold-reload summary agrees with marker rows and has no overrides' `
    ($null -ne $reloadMarkerSummary -and $reloadMarkerSummary.authored -eq $computedReloadSummary.authored -and
     $reloadMarkerSummary.visible -eq $computedReloadSummary.visible -and $reloadMarkerSummary.travel -eq $computedReloadSummary.travel -and
     $reloadMarkerSummary.overrides -eq 0) `
    ([ordered]@{ observed = $reloadMarkerSummary; computed = $computedReloadSummary })

$saveSignatures = @($saveRows | ForEach-Object { Get-C01MarkerSignature $_ } | Sort-Object)
$reloadSignatures = @($reloadRows | ForEach-Object { Get-C01MarkerSignature $_ } | Sort-Object)
$exactParity = ($saveSignatures.Count -eq $reloadSignatures.Count -and
    (($saveSignatures -join "`n") -eq ($reloadSignatures -join "`n")))
Add-C01Check 'Native-load and cold-reload marker metadata/state are exact' `
    $exactParity `
    "saveRows=$($saveSignatures.Count) reloadRows=$($reloadSignatures.Count)"

$shortcutPattern = '(?i)(unlocked all authored exterior markers|OPENMW_FNV_UNLOCK_ALL_MAP_MARKERS|TestMap01|bootstrap inventory|fallback inventory|FNV_PROOF inventory|ShowMap id=)'
Add-C01Check 'No marker unlock or synthetic placement shortcut appears in production logs' `
    (($saveLog -notmatch $shortcutPattern) -and ($reloadLog -notmatch $shortcutPattern)) `
    $shortcutPattern

$fixtureSource = [ordered]@{
    path = $fixtureArtifact.path
    bytes = $fixtureArtifact.bytes
    sha256 = $fixtureArtifact.sha256
}
$a03Source = [ordered]@{
    path = $a03Artifact.path
    bytes = $a03Artifact.bytes
    sha256 = $a03Artifact.sha256
}
$captureSource = [ordered]@{
    runRoot = $RunRoot
    summary = $summaryArtifact
    combinedReport = $combinedReportArtifact
    routeId = Get-C01Property $combinedReport 'routeId'
    binary = $binaryArtifact
    phaseLogs = [ordered]@{
        nativeLoad = $saveLogArtifact
        coldReload = $reloadLogArtifact
    }
}

$validation = [ordered]@{
    schema = 'nikami-fnv-real-save-c01-validation/v1'
    status = if ($script:c01AllPass) { 'pass' } else { 'fail' }
    objective = 'Serialize and validate the official Save330 authored map-marker denominator with saved runtime state 0/1/2.'
    source = [ordered]@{
        fixture = $fixtureSource
        normalizedSaveDenominator = $a03Source
        capture = $captureSource
    }
    expected = [ordered]@{
        authoredMarkerCount = $expectedMarkerCount
        runtimeStateDomain = @(0, 1, 2)
        destinationRule = 'Reference parent must resolve to an exterior Cell whose parent resolves to the authored Worldspace.'
        discoveryRule = 'No plugin default replacement, unlock-all proof switch, ShowMap injection, or synthetic placement is accepted.'
    }
    phases = [ordered]@{
        nativeLoad = [ordered]@{ log = $saveLogArtifact; markerSummary = $saveMarkerSummary; rows = $saveRows.Count }
        coldReload = [ordered]@{ log = $reloadLogArtifact; markerSummary = $reloadMarkerSummary; rows = $reloadRows.Count }
        exactParity = $exactParity
    }
    checks = @($checks)
}
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 18) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

if (-not $script:c01AllPass) {
    throw "C01 validation failed. See $ValidationPath"
}

$denominator = [ordered]@{
    schema = 'nikami-fnv-save330-map-marker-denominator/v1'
    status = 'authored-save-marker-denominator'
    source = [ordered]@{
        fixture = $fixtureSource
        normalizedSaveDenominator = $a03Source
        capture = $captureSource
    }
    content = [ordered]@{
        profile = 'official Fallout: New Vegas masters 0..9 from the A03 content profile'
        mapMarkerRecordRule = 'ESM4 REFR records with mIsMapMarker and a non-empty full name'
        fastTravelDestinationRule = 'Parent exterior Cell and parent Worldspace resolve exactly as production fast travel.'
    }
    counts = [ordered]@{
        authored = $saveRows.Count
        visible = $computedSaveSummary.visible
        travelEnabled = $computedSaveSummary.travel
        explicitRuntimeOverrides = $saveMarkerSummary.overrides
    }
    savedRuntimeState = [ordered]@{
        encoding = '0=hidden, 1=visible-only, 2=discovered/travel-enabled'
        phase = 'save330-before-reload'
        values = [ordered]@{
            hidden = @($saveRows | Where-Object { $_.savedRuntimeState -eq 0 }).Count
            visibleOnly = @($saveRows | Where-Object { $_.savedRuntimeState -eq 1 }).Count
            discoveredTravel = @($saveRows | Where-Object { $_.savedRuntimeState -eq 2 }).Count
        }
    }
    markers = $saveRows
    restoration = [ordered]@{
        coldReloadPhase = 'save330-after-reload'
        exactMarkerParity = $exactParity
        restoredRows = $reloadRows
    }
    validation = [ordered]@{
        path = $ValidationPath
        sha256 = $null
        status = 'pass'
        checks = $checks.Count
    }
}
[IO.File]::WriteAllText($DenominatorPath, ($denominator | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$validationHash = (Get-FileHash -LiteralPath $ValidationPath -Algorithm SHA256).Hash.ToLowerInvariant()
$denominator.validation.sha256 = $validationHash
[IO.File]::WriteAllText($DenominatorPath, ($denominator | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$denominatorArtifact = Get-C01Artifact $DenominatorPath

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $checks.Count
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-C01Artifact $ValidationPath
    denominatorArtifact = $denominatorArtifact
    authoredMarkers = $saveRows.Count
    visibleMarkers = $computedSaveSummary.visible
    travelEnabledMarkers = $computedSaveSummary.travel
    exactReloadParity = $exactParity
}
