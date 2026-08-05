[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\code\nikami-worlds",
    [string]$RunRoot = "D:\code\nikami-worlds\run\fnv-real-save-campaign\b04-openmw-20260802-161200",
    [string]$ValidationPath = "D:\code\nikami-worlds\run\fnv-real-save-campaign\b04-reload-validation.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)
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
$SavePhaseFramePath = Join-Path $SavePhaseRoot "Save330-native-world.png"
$ReloadPhaseFramePath = Join-Path $ReloadPhaseRoot "Save330-native-world.png"
$SavePhaseVideoPath = Join-Path $SavePhaseRoot "OpenMW-Save330-exact-title-raw.mp4"
$ReloadPhaseVideoPath = Join-Path $ReloadPhaseRoot "OpenMW-Save330-exact-title-raw.mp4"
$GeneratedSavePath = Join-Path $OpenMwRoot "Save330-production-reload.omwsave"
$ProductionManifestPath = Join-Path $OpenMwRoot "save330-production-save-manifest.json"
$Save330Path = Join-Path $WorldsRoot "local\retail-real-save-fixtures\NikamiRealWorldSave330-20260802.fos"
$DenominatorPath = Join-Path $WorldsRoot "run\fnv-real-save-campaign\save330-player-denominator.json"
$A03ValidationPath = Join-Path $WorldsRoot "run\fnv-real-save-campaign\save330-a03-validation.json"

if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing B04 validation artifact: $ValidationPath"
}

$checks = [Collections.Generic.List[object]]::new()
$script:b04AllPass = $true

function Add-B04Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) {
        $script:b04AllPass = $false
    }
}

function Read-B04Json {
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

function Get-B04Property {
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

function Get-B04Artifact {
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

function Convert-B04FormId {
    param([AllowNull()][object]$Value)
    $match = [regex]::Match([string]$Value, '0x(?<hex>[0-9a-fA-F]{1,8})$')
    if (-not $match.Success) {
        return [string]$Value
    }
    return "0x$($match.Groups['hex'].Value.PadLeft(8, '0').ToUpperInvariant())"
}

function Test-B04Finite {
    param([double]$Value)
    return (-not [double]::IsNaN($Value) -and -not [double]::IsInfinity($Value))
}

function Get-B04PersistenceData {
    param([Parameter(Mandatory = $true)][string]$Log)

    $itemRows = @([regex]::Matches($Log, 'FNV B04 persistence inventory item: form=FormId:(?<form>0x[0-9a-fA-F]+) count=(?<count>-?\d+) visible=(?<visible>[01]) equipped=(?<equipped>[01])') |
        ForEach-Object {
            [ordered]@{
                form = Convert-B04FormId $_.Groups['form'].Value
                count = [int64]$_.Groups['count'].Value
                visible = $_.Groups['visible'].Value -eq '1'
                equipped = $_.Groups['equipped'].Value -eq '1'
            }
        })
    $equippedRows = @([regex]::Matches($Log, 'FNV B04 persistence equipped: slot=(?<slot>\d+) form=FormId:(?<form>0x[0-9a-fA-F]+)') |
        ForEach-Object {
            [ordered]@{
                slot = [int]$_.Groups['slot'].Value
                form = Convert-B04FormId $_.Groups['form'].Value
            }
        })
    $modifierRows = @([regex]::Matches($Log, 'FNV B04 persistence actor-value modifier: actorValue=(?<actor>\d+) permanent=(?<permanent>[-+0-9.eE]+) damage=(?<damage>[-+0-9.eE]+) temporary=(?<temporary>[-+0-9.eE]+)') |
        ForEach-Object {
            [ordered]@{
                actorValue = [int]$_.Groups['actor'].Value
                permanent = [double]$_.Groups['permanent'].Value
                damage = [double]$_.Groups['damage'].Value
                temporary = [double]$_.Groups['temporary'].Value
            }
        })
    $markerRows = @([regex]::Matches($Log, 'FNV B04 persistence map marker: id=FormId:(?<id>0x[0-9a-fA-F]+) name="(?<name>.*?)" state=(?<state>\d+) override=(?<override>-?\d+) authoredVisible=(?<authoredVisible>[01]) authoredCanTravel=(?<authoredCanTravel>[01])') |
        ForEach-Object {
            $override = [int64]$_.Groups['override'].Value
            [ordered]@{
                id = Convert-B04FormId $_.Groups['id'].Value
                name = $_.Groups['name'].Value
                state = [int]$_.Groups['state'].Value
                override = if ($override -eq -1 -or $override -eq [uint32]::MaxValue) { $null } else { $override }
                authoredVisible = $_.Groups['authoredVisible'].Value -eq '1'
                authoredCanTravel = $_.Groups['authoredCanTravel'].Value -eq '1'
            }
        })

    $inventoryMatch = [regex]::Match($Log, 'FNV B04 persistence: OpenMW save player inventory stacks=(?<stacks>\d+) visible=(?<visible>\d+) worn=(?<worn>\d+) totalItems=(?<totalItems>\d+) health=(?<health>[-+0-9.eE]+) actionPoints=(?<actionPoints>[-+0-9.eE]+) actionPointsMax=(?<actionPointsMax>[-+0-9.eE]+)')
    $modifierCountMatch = [regex]::Match($Log, 'FNV B04 persistence: OpenMW save actor-value modifiers count=(?<count>\d+)')
    $questMatch = [regex]::Match($Log, 'FNV B04 persistence: OpenMW save quest state states=(?<states>\d+) stages=(?<stages>\d+) objectives=(?<objectives>\d+) variables=(?<variables>\d+) active=(?<active>[^\s]+)')
    $globalMatch = [regex]::Match($Log, 'FNV B04 persistence: OpenMW save globals count=(?<count>\d+)')
    $markerSummaryMatch = [regex]::Match($Log, 'FNV B04 persistence: OpenMW save map markers authored=(?<authored>\d+) visible=(?<visible>\d+) travel=(?<travel>\d+) overrides=(?<overrides>\d+)')

    $inventorySummary = if ($inventoryMatch.Success) {
        [ordered]@{
            stacks = [int]$inventoryMatch.Groups['stacks'].Value
            visible = [int]$inventoryMatch.Groups['visible'].Value
            worn = [int]$inventoryMatch.Groups['worn'].Value
            totalItems = [int64]$inventoryMatch.Groups['totalItems'].Value
            health = [double]$inventoryMatch.Groups['health'].Value
            actionPoints = [double]$inventoryMatch.Groups['actionPoints'].Value
            actionPointsMax = [double]$inventoryMatch.Groups['actionPointsMax'].Value
        }
    }
    else { $null }
    $questSummary = if ($questMatch.Success) {
        [ordered]@{
            states = [int]$questMatch.Groups['states'].Value
            stages = [int]$questMatch.Groups['stages'].Value
            objectives = [int]$questMatch.Groups['objectives'].Value
            variables = [int]$questMatch.Groups['variables'].Value
            active = Convert-B04FormId $questMatch.Groups['active'].Value
        }
    }
    else { $null }
    $markerSummary = if ($markerSummaryMatch.Success) {
        [ordered]@{
            authored = [int]$markerSummaryMatch.Groups['authored'].Value
            visible = [int]$markerSummaryMatch.Groups['visible'].Value
            travel = [int]$markerSummaryMatch.Groups['travel'].Value
            overrides = [int]$markerSummaryMatch.Groups['overrides'].Value
        }
    }
    else { $null }

    return [ordered]@{
        inventoryRows = $itemRows
        equippedRows = $equippedRows
        modifierRows = $modifierRows
        inventorySummary = $inventorySummary
        modifierCount = if ($modifierCountMatch.Success) { [int]$modifierCountMatch.Groups['count'].Value } else { $null }
        questSummary = $questSummary
        globalsCount = if ($globalMatch.Success) { [int]$globalMatch.Groups['count'].Value } else { $null }
        markerRows = $markerRows
        markerSummary = $markerSummary
    }
}

function Get-B04Telemetry {
    param([Parameter(Mandatory = $true)][string]$Log)
    $pattern = 'World viewer telemetry: frame=(?<frame>\d+) state=(?<state>-?\d+) loadingGui=(?<loadingGui>[01]) worldReady=(?<worldReady>[01]) readyFrames=(?<readyFrames>\d+) activeCells=(?<activeCells>\d+) hour=(?<hour>[-+0-9.eE]+) weatherId=(?<weatherId>-?\d+) weatherTransition=(?<weatherTransition>[-+0-9.eE]+) playerCell="(?<cell>[^"]+)" exterior=(?<exterior>[01]) grid=\((?<gridX>-?\d+),(?<gridY>-?\d+)\) worldspace=(?<worldspace>[^ ]+) playerPos=\((?<px>[-+0-9.eE]+),(?<py>[-+0-9.eE]+),(?<pz>[-+0-9.eE]+)\) playerRot=\((?<rx>[-+0-9.eE]+),(?<ry>[-+0-9.eE]+),(?<rz>[-+0-9.eE]+)\) cameraMode=(?<cameraMode>-?\d+) cameraPos=\((?<cx>[-+0-9.eE]+),(?<cy>[-+0-9.eE]+),(?<cz>[-+0-9.eE]+)\) cameraPitch=(?<pitch>[-+0-9.eE]+) cameraYaw=(?<yaw>[-+0-9.eE]+) playerHealth=(?<health>[-+0-9.eE]+) playerActionPoints=(?<ap>[-+0-9.eE]+) playerActionPointsMax=(?<apMax>[-+0-9.eE]+)'
    return @([regex]::Matches($Log, $pattern) | ForEach-Object {
            [ordered]@{
                frame = [int]$_.Groups['frame'].Value
                state = [int]$_.Groups['state'].Value
                loadingGui = $_.Groups['loadingGui'].Value -eq '1'
                worldReady = $_.Groups['worldReady'].Value -eq '1'
                readyFrames = [int]$_.Groups['readyFrames'].Value
                activeCells = [int]$_.Groups['activeCells'].Value
                hour = [double]$_.Groups['hour'].Value
                weatherId = [int]$_.Groups['weatherId'].Value
                weatherTransition = [double]$_.Groups['weatherTransition'].Value
                cell = $_.Groups['cell'].Value
                exterior = $_.Groups['exterior'].Value -eq '1'
                grid = @([int]$_.Groups['gridX'].Value, [int]$_.Groups['gridY'].Value)
                worldspace = Convert-B04FormId $_.Groups['worldspace'].Value
                position = @([double]$_.Groups['px'].Value, [double]$_.Groups['py'].Value, [double]$_.Groups['pz'].Value)
                rotation = @([double]$_.Groups['rx'].Value, [double]$_.Groups['ry'].Value, [double]$_.Groups['rz'].Value)
                cameraMode = [int]$_.Groups['cameraMode'].Value
                cameraPosition = @([double]$_.Groups['cx'].Value, [double]$_.Groups['cy'].Value, [double]$_.Groups['cz'].Value)
                cameraPitch = [double]$_.Groups['pitch'].Value
                cameraYaw = [double]$_.Groups['yaw'].Value
                health = [double]$_.Groups['health'].Value
                actionPoints = [double]$_.Groups['ap'].Value
                actionPointsMax = [double]$_.Groups['apMax'].Value
            }
        })
}

function Get-B04RowSignatures {
    param([AllowNull()][object[]]$Rows, [Parameter(Mandatory = $true)][string]$Kind)
    if ($null -eq $Rows) { return @() }
    if ($Kind -eq 'inventory') {
        return @($Rows | ForEach-Object { "$(Convert-B04FormId $_.form)|$($_.count)|$([int]$_.visible)|$([int]$_.equipped)" } | Sort-Object)
    }
    if ($Kind -eq 'equipped') {
        return @($Rows | ForEach-Object { "$($_.slot)|$(Convert-B04FormId $_.form)" } | Sort-Object)
    }
    if ($Kind -eq 'modifier') {
        return @($Rows | ForEach-Object { "$( [int]$_.actorValue)|$([double]$_.permanent.ToString('R'))|$([double]$_.damage.ToString('R'))|$([double]$_.temporary.ToString('R'))" } | Sort-Object)
    }
    if ($Kind -eq 'marker') {
        return @($Rows | ForEach-Object {
                $override = if ($null -eq $_.override) { 'none' } else { [string]$_.override }
                "$(Convert-B04FormId $_.id)|$($_.name)|$($_.state)|$override|$([int]$_.authoredVisible)|$([int]$_.authoredCanTravel)"
            } | Sort-Object)
    }
    throw "Unknown B04 signature kind: $Kind"
}

function Get-B04RegexValue {
    param([Parameter(Mandatory = $true)][string]$Log, [Parameter(Mandatory = $true)][string]$Pattern, [Parameter(Mandatory = $true)][string]$Group)
    $match = [regex]::Match($Log, $Pattern)
    if (-not $match.Success) { return $null }
    return $match.Groups[$Group].Value
}

$summary = Read-B04Json -Path $SummaryPath
$combinedReport = Read-B04Json -Path $CombinedReportPath
$saveReport = Read-B04Json -Path $SavePhaseReportPath
$reloadReport = Read-B04Json -Path $ReloadPhaseReportPath
$saveState = Read-B04Json -Path $SavePhaseStatePath
$reloadState = Read-B04Json -Path $ReloadPhaseStatePath
$manifest = Read-B04Json -Path $ProductionManifestPath
$denominator = Read-B04Json -Path $DenominatorPath
$a03Validation = Read-B04Json -Path $A03ValidationPath
$saveLog = if (Test-Path -LiteralPath $SavePhaseLogPath -PathType Leaf) { Get-Content -Raw -LiteralPath $SavePhaseLogPath } else { '' }
$reloadLog = if (Test-Path -LiteralPath $ReloadPhaseLogPath -PathType Leaf) { Get-Content -Raw -LiteralPath $ReloadPhaseLogPath } else { '' }
$savePersistence = Get-B04PersistenceData -Log $saveLog
$reloadPersistence = Get-B04PersistenceData -Log $reloadLog
$saveTelemetry = Get-B04Telemetry -Log $saveLog
$reloadTelemetry = Get-B04Telemetry -Log $reloadLog
$saveReadyTelemetry = @($saveTelemetry | Where-Object { $_.worldReady })
$reloadReadyTelemetry = @($reloadTelemetry | Where-Object { $_.worldReady })
$saveInitial = if ($saveReadyTelemetry.Count -gt 0) { $saveReadyTelemetry[0] } else { $null }
$saveLatest = if ($saveReadyTelemetry.Count -gt 0) { $saveReadyTelemetry[-1] } else { $null }
$reloadInitial = if ($reloadReadyTelemetry.Count -gt 0) { $reloadReadyTelemetry[0] } else { $null }
$reloadLatest = if ($reloadReadyTelemetry.Count -gt 0) { $reloadReadyTelemetry[-1] } else { $null }

$requiredArtifacts = @(
    $SummaryPath, $CombinedReportPath, $SavePhaseReportPath, $ReloadPhaseReportPath,
    $SavePhaseStatePath, $ReloadPhaseStatePath, $SavePhaseLogPath, $ReloadPhaseLogPath,
    $SavePhaseFramePath, $ReloadPhaseFramePath, $SavePhaseVideoPath, $ReloadPhaseVideoPath,
    $GeneratedSavePath, $ProductionManifestPath, $Save330Path, $DenominatorPath, $A03ValidationPath
)
foreach ($path in $requiredArtifacts) {
    Add-B04Check -Name "required artifact exists: $([IO.Path]::GetFileName($path))" `
        -Passed (Test-Path -LiteralPath $path -PathType Leaf) -Detail $path
}

$policy = Get-B04Property $summary 'policy'
Add-B04Check -Name 'public background capture is a passing sequential no-control RealSave run' `
    -Passed ($null -ne $summary -and
        (Get-B04Property $summary 'schema') -eq 'nikami-fnv-jam-background-capture-run/v1' -and
        (Get-B04Property $summary 'status') -eq 'pass' -and
        (Get-B04Property $summary 'target') -eq 'OpenMW' -and
        (Get-B04Property $summary 'scenario') -eq 'RealSave' -and
        $null -ne (Get-B04Property $summary 'realSave') -and
        (Get-B04Property (Get-B04Property $summary 'realSave') 'status') -eq 'pass' -and
        (Get-B04Property $policy 'windowsAppControlUsed') -eq $false -and
        (Get-B04Property $policy 'foregroundActivationUsed') -eq $false -and
        (Get-B04Property $policy 'foregroundInputInjected') -eq $false -and
        (Get-B04Property $policy 'capturesRanSequentially') -eq $true -and
        (Get-B04Property $policy 'outputOverwritten') -eq $false) `
    -Detail $policy

$combinedAssertions = Get-B04Property $combinedReport 'assertions'
Add-B04Check -Name 'combined B04 report and both phase gates pass' `
    -Passed ($null -ne $combinedReport -and
        (Get-B04Property $combinedReport 'schema') -eq 'nikami-fnv-real-save-capture/v1' -and
        (Get-B04Property $combinedReport 'status') -eq 'pass' -and
        (Get-B04Property $combinedReport 'routeId') -eq 'save330-reload-idempotence-v1' -and
        (Get-B04Property $combinedAssertions 'productionSaveCreated') -eq $true -and
        (Get-B04Property $combinedAssertions 'productionSavePhasePass') -eq $true -and
        (Get-B04Property $combinedAssertions 'cleanQuitAfterSave') -eq $true -and
        (Get-B04Property $combinedAssertions 'coldReloadPhasePass') -eq $true -and
        (Get-B04Property $combinedAssertions 'bothStateManifestsRetained') -eq $true) `
    -Detail $combinedAssertions

$expectedSaveHash = '07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f'
$actualSaveHash = if (Test-Path -LiteralPath $Save330Path -PathType Leaf) { (Get-FileHash -LiteralPath $Save330Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
$reportSave = Get-B04Property $combinedReport 'sourceSave'
Add-B04Check -Name 'immutable Save330 fixture and report provenance match' `
    -Passed ($actualSaveHash -eq $expectedSaveHash -and
        [int64](Get-B04Property $reportSave 'bytes') -eq 3395328 -and
        [string](Get-B04Property $reportSave 'sha256') -ieq $expectedSaveHash) `
    -Detail ([ordered]@{ path = $Save330Path; expectedSha256 = $expectedSaveHash; actualSha256 = $actualSaveHash; report = $reportSave })

$denominatorHash = if (Test-Path -LiteralPath $DenominatorPath -PathType Leaf) { (Get-FileHash -LiteralPath $DenominatorPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
Add-B04Check -Name 'A03 denominator is present, passing, and hash-locked' `
    -Passed ($denominatorHash -eq 'ae9b020591c5cc176e4a1a47bd9715cbf758e7bb3118a0376cfe4d2a05e92b92' -and
        $null -ne $a03Validation -and (Get-B04Property $a03Validation 'status') -eq 'pass') `
    -Detail ([ordered]@{ denominatorPath = $DenominatorPath; denominatorBytes = if (Test-Path -LiteralPath $DenominatorPath -PathType Leaf) { (Get-Item -LiteralPath $DenominatorPath).Length } else { $null }; denominatorSha256 = $denominatorHash; a03Status = Get-B04Property $a03Validation 'status' })

$manifestGenerated = Get-B04Property $manifest 'generatedSave'
$actualGenerated = Get-B04Artifact -Path $GeneratedSavePath
$reportGenerated = Get-B04Property $combinedReport 'generatedSave'
$generatedSaveChecks = [ordered]@{
    manifestSchema = (Get-B04Property $manifest 'schema') -eq 'nikami-fnv-real-save-b04-production-save/v1'
    cleanQuit = (Get-B04Property $manifest 'cleanQuitObserved') -eq $true
    actualExists = $null -ne $actualGenerated
    manifestBytes = $null -ne $actualGenerated -and [int64](Get-B04Property $manifestGenerated 'bytes') -eq [int64](Get-B04Property $actualGenerated 'bytes')
    manifestHash = $null -ne $actualGenerated -and [string](Get-B04Property $manifestGenerated 'sha256') -ieq [string](Get-B04Property $actualGenerated 'sha256')
    reportHash = $null -ne $actualGenerated -and [string](Get-B04Property $reportGenerated 'sha256') -ieq [string](Get-B04Property $actualGenerated 'sha256')
    reportBytes = $null -ne $actualGenerated -and [int64](Get-B04Property $reportGenerated 'bytes') -eq [int64](Get-B04Property $actualGenerated 'bytes')
}
$generatedSavePass = @($generatedSaveChecks.Values | Where-Object { -not [bool]$_ }).Count -eq 0
Add-B04Check -Name 'production .omwsave path, size, and hash match the immutable manifest and combined report' `
    -Passed ($null -ne $manifest -and $generatedSavePass) `
    -Detail ([ordered]@{ checks = $generatedSaveChecks; actual = $actualGenerated; manifest = $manifestGenerated; report = $reportGenerated })

$saveAssertions = Get-B04Property $saveReport 'assertions'
$reloadAssertions = Get-B04Property $reloadReport 'assertions'
$saveCapture = Get-B04Property $saveReport 'capture'
$reloadCapture = Get-B04Property $reloadReport 'capture'
$saveStateObserved = Get-B04Property $saveState 'observed'
$reloadStateObserved = Get-B04Property $reloadState 'observed'
Add-B04Check -Name 'production native-FOS phase is independently passing with retained evidence' `
    -Passed ($null -ne $saveReport -and
        (Get-B04Property $saveReport 'status') -eq 'pass' -and
        (Get-B04Property $saveReport 'routeId') -eq 'save330-reload-idempotence-v1' -and
        (Get-B04Property $saveReport 'validationMode') -eq $null -and
        (Get-B04Property $saveAssertions 'stateManifestPass') -eq $true -and
        (Get-B04Property $saveAssertions 'ordinaryLoadPathObserved') -eq $true -and
        (Get-B04Property $saveAssertions 'nativeSaveLoadComplete') -eq $true -and
        (Get-B04Property $saveAssertions 'playerIdentityRestored') -eq $true -and
        (Get-B04Property $saveAssertions 'savedTransformApplied') -eq $true -and
        (Get-B04Property $saveAssertions 'fallbackInventoryAbsent') -eq $true -and
        (Get-B04Property $saveAssertions 'syntheticPlacementAbsent') -eq $true -and
        (Get-B04Property $saveAssertions 'nativeWorldFrameRetained') -eq $true -and
        (Get-B04Property $saveAssertions 'exactTitleVideoRetained') -eq $true -and
        (Get-B04Property $saveCapture 'recorderExitCode') -eq 0 -and
        (Get-B04Property $saveCapture 'gameTermination') -eq 'engine-exited') `
    -Detail $saveAssertions
Add-B04Check -Name 'cold standard-.omwsave reload phase is independently passing with retained evidence' `
    -Passed ($null -ne $reloadReport -and
        (Get-B04Property $reloadReport 'status') -eq 'pass' -and
        (Get-B04Property $reloadAssertions 'stateManifestPass') -eq $true -and
        (Get-B04Property $reloadAssertions 'ordinaryLoadPathObserved') -eq $true -and
        (Get-B04Property $reloadStateObserved 'openMwSaveLoadObserved') -eq $true -and
        (Get-B04Property $reloadStateObserved 'openMwPersistenceTelemetryObserved') -eq $true -and
        (Get-B04Property $reloadAssertions 'playerIdentityRestored') -eq $true -and
        (Get-B04Property $reloadAssertions 'savedTransformApplied') -eq $true -and
        (Get-B04Property $reloadAssertions 'fallbackInventoryAbsent') -eq $true -and
        (Get-B04Property $reloadAssertions 'syntheticPlacementAbsent') -eq $true -and
        (Get-B04Property $reloadAssertions 'nativeWorldFrameRetained') -eq $true -and
        (Get-B04Property $reloadAssertions 'exactTitleVideoRetained') -eq $true -and
        (Get-B04Property $reloadCapture 'recorderExitCode') -eq 0) `
    -Detail $reloadAssertions

Add-B04Check -Name 'phase state manifests use native then standard validation modes and forbid fallback/synthetic state' `
    -Passed ((Get-B04Property $saveStateObserved 'validationMode') -eq 'native-fos-save-load' -and
        (Get-B04Property $reloadStateObserved 'validationMode') -eq 'standard-openmw-save-reload' -and
        (Get-B04Property (Get-B04Property $saveStateObserved 'inventoryRebuild') 'fallbackInventoryAbsent') -eq $true -and
        (Get-B04Property (Get-B04Property $reloadStateObserved 'inventoryRebuild') 'fallbackInventoryAbsent') -eq $true -and
        (Get-B04Property $saveStateObserved 'noSyntheticPlacement') -eq $true -and
        (Get-B04Property $reloadStateObserved 'noSyntheticPlacement') -eq $true) `
    -Detail ([ordered]@{ save = $saveStateObserved; reload = $reloadStateObserved })

$quickSavePass = $saveLog -match 'FNV/ESM4 proof: requesting quicksave "Save330 B04 Reload"' -and
    $saveLog -match "Writing saved game 'Save330 B04 Reload'" -and
    $saveLog -match 'FNV/ESM4 proof: quicksave complete; exiting cleanly after delayFrames=30' -and
    $saveCapture.gameTermination -eq 'engine-exited'
$reloadPathPass = $reloadLog -match 'Reading save file Save330-production-reload\.omwsave' -and
    $reloadLog -match "Loading saved game 'Save330 B04 Reload'"
Add-B04Check -Name 'production quicksave/write/clean-quit and cold-load path are explicitly logged' `
    -Passed ($quickSavePass -and $reloadPathPass) `
    -Detail ([ordered]@{ quickSave = $quickSavePass; reloadPath = $reloadPathPass })

$sourceIdentity = [regex]::Match($saveLog, 'Native FNV save Player identity restored: base=(?<base>0x[0-9a-fA-F]+) reference=(?<reference>0x[0-9a-fA-F]+)')
$sourceNativeInventory = [regex]::Match($saveLog, 'Native FNV save Player inventory: stacks=(?<stacks>\d+) worn=(?<worn>\d+)')
$sourceRebuiltInventory = [regex]::Match($saveLog, 'Native FNV save Player runtime inventory rebuilt: stacks=(?<stacks>\d+) visible=(?<visible>\d+)')
$sourceGlobals = [regex]::Match($saveLog, 'Native FNV save restored global variables: count=(?<count>\d+)')
$sourceActors = [regex]::Match($saveLog, 'Native FNV save Player restored actor values: modifiers=(?<modifiers>\d+) perks=(?<perks>\d+) health=(?<health>[-+0-9.eE]+)')
$sourceQuest = [regex]::Match($saveLog, 'FNV/ESM4 save: imported quest progress stages=(?<stages>\d+) objectives=(?<objectives>\d+) variables=(?<variables>\d+) states=(?<states>\d+) active=(?<active>[^\s]+)')
Add-B04Check -Name 'native Save330 provenance and imported denominator are fully observed' `
    -Passed ($sourceIdentity.Success -and
        (Convert-B04FormId $sourceIdentity.Groups['base'].Value) -eq '0x01000007' -and
        (Convert-B04FormId $sourceIdentity.Groups['reference'].Value) -eq '0x01000014' -and
        $sourceNativeInventory.Success -and [int]$sourceNativeInventory.Groups['stacks'].Value -eq 50 -and [int]$sourceNativeInventory.Groups['worn'].Value -eq 3 -and
        $sourceRebuiltInventory.Success -and [int]$sourceRebuiltInventory.Groups['stacks'].Value -eq 55 -and [int]$sourceRebuiltInventory.Groups['visible'].Value -eq 53 -and
        $sourceGlobals.Success -and [int]$sourceGlobals.Groups['count'].Value -eq 199 -and
        $sourceActors.Success -and [int]$sourceActors.Groups['modifiers'].Value -eq 1 -and [int]$sourceActors.Groups['perks'].Value -eq 0 -and [double]$sourceActors.Groups['health'].Value -eq 100 -and
        $sourceQuest.Success -and [int]$sourceQuest.Groups['stages'].Value -eq 0 -and [int]$sourceQuest.Groups['objectives'].Value -eq 4 -and [int]$sourceQuest.Groups['variables'].Value -eq 92 -and [int]$sourceQuest.Groups['states'].Value -eq 17 -and
        (Convert-B04FormId $sourceQuest.Groups['active'].Value) -eq '0x04002FCA') `
    -Detail ([ordered]@{ identity = $sourceIdentity.Value; nativeInventory = $sourceNativeInventory.Value; rebuiltInventory = $sourceRebuiltInventory.Value; globals = $sourceGlobals.Value; actorValues = $sourceActors.Value; questProgress = $sourceQuest.Value })

$saveInventorySummary = $savePersistence.inventorySummary
$reloadInventorySummary = $reloadPersistence.inventorySummary
$inventorySummaryPass = $null -ne $saveInventorySummary -and $null -ne $reloadInventorySummary -and
    $saveInventorySummary.stacks -eq 55 -and $saveInventorySummary.visible -eq 53 -and $saveInventorySummary.worn -eq 3 -and $saveInventorySummary.totalItems -eq 788 -and
    $reloadInventorySummary.stacks -eq 55 -and $reloadInventorySummary.visible -eq 53 -and $reloadInventorySummary.worn -eq 3 -and $reloadInventorySummary.totalItems -eq 788
$inventorySignaturesSave = Get-B04RowSignatures -Rows $savePersistence.inventoryRows -Kind 'inventory'
$inventorySignaturesReload = Get-B04RowSignatures -Rows $reloadPersistence.inventoryRows -Kind 'inventory'
$equippedSignaturesSave = Get-B04RowSignatures -Rows $savePersistence.equippedRows -Kind 'equipped'
$equippedSignaturesReload = Get-B04RowSignatures -Rows $reloadPersistence.equippedRows -Kind 'equipped'
$expectedEquipped = @('1|0x01015038', '5|0x01025B83', '11|0x0100431E') | Sort-Object
Add-B04Check -Name 'inventory totals, every persisted stack, and every worn/equipped row are identical' `
    -Passed ($inventorySummaryPass -and
        $inventorySignaturesSave.Count -eq 55 -and $inventorySignaturesReload.Count -eq 55 -and
        ($inventorySignaturesSave -join "`n") -ceq ($inventorySignaturesReload -join "`n") -and
        ($equippedSignaturesSave -join ',') -ceq ($expectedEquipped -join ',') -and
        ($equippedSignaturesReload -join ',') -ceq ($expectedEquipped -join ',')) `
    -Detail ([ordered]@{ saveSummary = $saveInventorySummary; reloadSummary = $reloadInventorySummary; saveStacks = $inventorySignaturesSave.Count; reloadStacks = $inventorySignaturesReload.Count; saveEquipped = $equippedSignaturesSave; reloadEquipped = $equippedSignaturesReload })

$modifierSignaturesSave = Get-B04RowSignatures -Rows $savePersistence.modifierRows -Kind 'modifier'
$modifierSignaturesReload = Get-B04RowSignatures -Rows $reloadPersistence.modifierRows -Kind 'modifier'
$modifierPass = $savePersistence.modifierCount -eq 1 -and $reloadPersistence.modifierCount -eq 1 -and
    ($modifierSignaturesSave -join ',') -ceq '24|10|0|0' -and ($modifierSignaturesReload -join ',') -ceq '24|10|0|0'
Add-B04Check -Name 'actor-value modifier stack is serialized and restored exactly' `
    -Passed $modifierPass `
    -Detail ([ordered]@{ saveCount = $savePersistence.modifierCount; reloadCount = $reloadPersistence.modifierCount; save = $modifierSignaturesSave; reload = $modifierSignaturesReload })

$questSave = $savePersistence.questSummary
$questReload = $reloadPersistence.questSummary
$questPass = $null -ne $questSave -and $null -ne $questReload -and
    $questSave.states -eq 640 -and $questSave.stages -eq 1405 -and $questSave.objectives -eq 1479 -and $questSave.variables -eq 4539 -and $questSave.active -eq '0x04002FCA' -and
    ($questSave | ConvertTo-Json -Compress) -ceq ($questReload | ConvertTo-Json -Compress)
$globalPass = $savePersistence.globalsCount -eq 268 -and $reloadPersistence.globalsCount -eq 268
Add-B04Check -Name 'quest runtime and global-variable persistence counts match across save/reload' `
    -Passed ($questPass -and $globalPass) `
    -Detail ([ordered]@{ saveQuest = $questSave; reloadQuest = $questReload; saveGlobals = $savePersistence.globalsCount; reloadGlobals = $reloadPersistence.globalsCount })

$markerSignaturesSave = Get-B04RowSignatures -Rows $savePersistence.markerRows -Kind 'marker'
$markerSignaturesReload = Get-B04RowSignatures -Rows $reloadPersistence.markerRows -Kind 'marker'
$markerSummaryPass = $null -ne $savePersistence.markerSummary -and $null -ne $reloadPersistence.markerSummary -and
    $savePersistence.markerSummary.authored -eq 320 -and $savePersistence.markerSummary.visible -eq 1 -and $savePersistence.markerSummary.travel -eq 1 -and $savePersistence.markerSummary.overrides -eq 0 -and
    ($savePersistence.markerSummary | ConvertTo-Json -Compress) -ceq ($reloadPersistence.markerSummary | ConvertTo-Json -Compress)
$markerPass = $markerSummaryPass -and $markerSignaturesSave.Count -eq 320 -and $markerSignaturesReload.Count -eq 320 -and
    ($markerSignaturesSave -join "`n") -ceq ($markerSignaturesReload -join "`n") -and
    $saveLog -notmatch 'unlocked all authored exterior markers|dirty-dozen tour'
Add-B04Check -Name 'authored map-marker state list and discovery/travel summary persist without unlock shortcuts' `
    -Passed $markerPass `
    -Detail ([ordered]@{ saveSummary = $savePersistence.markerSummary; reloadSummary = $reloadPersistence.markerSummary; saveMarkers = $markerSignaturesSave.Count; reloadMarkers = $markerSignaturesReload.Count; exactList = ($markerSignaturesSave -join "`n") -ceq ($markerSignaturesReload -join "`n") })

$expectedWorldspace = '0x010DA726'
$expectedPosition = @(-72392.8438, -1240.19275, 8137.58643)
$expectedRotation = @(-0.0643904507, 0, 2.93332028)
function Test-B04Location {
    param([AllowNull()][object]$Sample, [double]$ZTolerance)
    if ($null -eq $Sample) { return $false }
    $finite = @($Sample.position + $Sample.rotation + $Sample.cameraPosition + @($Sample.hour, $Sample.weatherTransition, $Sample.health, $Sample.actionPoints, $Sample.actionPointsMax))
    if (@($finite | Where-Object { -not (Test-B04Finite -Value ([double]$_)) }).Count -ne 0) { return $false }
    return $Sample.state -eq 2 -and -not $Sample.loadingGui -and $Sample.worldReady -and $Sample.activeCells -gt 0 -and
        $Sample.cell -eq 'Mojave Wasteland' -and $Sample.exterior -and $Sample.grid[0] -eq -18 -and $Sample.grid[1] -eq -1 -and
        $Sample.worldspace -eq $expectedWorldspace -and $Sample.cameraMode -eq 1 -and
        [math]::Abs($Sample.position[0] - $expectedPosition[0]) -le 0.5 -and
        [math]::Abs($Sample.position[1] - $expectedPosition[1]) -le 0.5 -and
        [math]::Abs($Sample.position[2] - $expectedPosition[2]) -le $ZTolerance -and
        [math]::Abs($Sample.rotation[0] - $expectedRotation[0]) -le 0.01 -and
        [math]::Abs($Sample.rotation[1] - $expectedRotation[1]) -le 0.01 -and
        [math]::Abs($Sample.rotation[2] - $expectedRotation[2]) -le 0.01
}
$telemetryPass = $saveTelemetry.Count -ge 5 -and $saveReadyTelemetry.Count -ge 5 -and $reloadTelemetry.Count -ge 20 -and $reloadReadyTelemetry.Count -ge 20 -and
    (Test-B04Location -Sample $saveInitial -ZTolerance 0.5) -and (Test-B04Location -Sample $saveLatest -ZTolerance 5.0) -and
    (Test-B04Location -Sample $reloadInitial -ZTolerance 5.0) -and (Test-B04Location -Sample $reloadLatest -ZTolerance 5.0) -and
    $saveLatest.readyFrames -ge 100 -and $reloadLatest.readyFrames -ge 300
$telemetryHealthPass = @($saveTelemetry + $reloadTelemetry | Where-Object { $_.health -ne 100 -or $_.actionPoints -ne 80 -or $_.actionPointsMax -ne 80 }).Count -eq 0
$timePass = $saveInitial.hour -ge 14.20 -and $saveInitial.hour -le 14.23 -and
    [math]::Abs($reloadInitial.hour - $saveLatest.hour) -le 0.1 -and $reloadLatest.hour -ge $reloadInitial.hour
Add-B04Check -Name 'repeated native frames prove stable Save330 location, transform, camera, health/AP, and game time' `
    -Passed ($telemetryPass -and $telemetryHealthPass -and $timePass) `
    -Detail ([ordered]@{ saveSamples = $saveTelemetry.Count; reloadSamples = $reloadTelemetry.Count; saveInitial = $saveInitial; saveLatest = $saveLatest; reloadInitial = $reloadInitial; reloadLatest = $reloadLatest; healthAPPass = $telemetryHealthPass; timePass = $timePass })

$nativeCameraPass = $saveLog -match 'Native FNV save owns camera mode=1' -and $saveLog -match 'FNV first-person saveWorn: total=3 armor=3 weapon=0 source=native-save'
$actorAssemblyPass = $saveLog -match 'World viewer actor ledger: phase=actor-assembly-gate ref=FormId:@0x0 base="Player".*status=passed' -and
    $saveLog -match 'World viewer actor weapon mesh ledger: .*valid=1.*gate=actor-weapon-mesh-telemetry'
$frameEvidencePass = (Get-B04Artifact -Path $SavePhaseFramePath) -ne $null -and (Get-B04Artifact -Path $ReloadPhaseFramePath) -ne $null -and
    (Get-B04Artifact -Path $SavePhaseVideoPath) -ne $null -and (Get-B04Artifact -Path $ReloadPhaseVideoPath) -ne $null -and
    (Get-B04Property $saveCapture 'exactTitleVideoRetained') -eq $true -and (Get-B04Property $reloadCapture 'exactTitleVideoRetained') -eq $true
Add-B04Check -Name 'native first-person equipment/assembly and both visual evidence pairs are retained' `
    -Passed ($nativeCameraPass -and $actorAssemblyPass -and $frameEvidencePass) `
    -Detail ([ordered]@{ nativeCamera = $nativeCameraPass; actorAssembly = $actorAssemblyPass; framesAndVideos = $frameEvidencePass })

$fatalPatterns = @('(?i)unhandled exception', '(?i)access violation', '(?i)fatal.*(missing|failed|asset|resource)', '(?i)missing required (world )?(asset|resource)', '(?i)failed to load required')
$fatalHits = [Collections.Generic.List[string]]::new()
foreach ($pattern in $fatalPatterns) {
    foreach ($log in @($saveLog, $reloadLog)) {
        foreach ($match in [regex]::Matches($log, $pattern)) { $fatalHits.Add($match.Value) }
    }
}
Add-B04Check -Name 'no fatal crash or required-asset failure is present in either phase' `
    -Passed ($fatalHits.Count -eq 0) -Detail @($fatalHits)

$artifactSummary = [ordered]@{
    summary = Get-B04Artifact -Path $SummaryPath
    combinedReport = Get-B04Artifact -Path $CombinedReportPath
    saveReport = Get-B04Artifact -Path $SavePhaseReportPath
    reloadReport = Get-B04Artifact -Path $ReloadPhaseReportPath
    saveState = Get-B04Artifact -Path $SavePhaseStatePath
    reloadState = Get-B04Artifact -Path $ReloadPhaseStatePath
    saveStdout = Get-B04Artifact -Path $SavePhaseLogPath
    reloadStdout = Get-B04Artifact -Path $ReloadPhaseLogPath
    saveFrame = Get-B04Artifact -Path $SavePhaseFramePath
    reloadFrame = Get-B04Artifact -Path $ReloadPhaseFramePath
    saveVideo = Get-B04Artifact -Path $SavePhaseVideoPath
    reloadVideo = Get-B04Artifact -Path $ReloadPhaseVideoPath
    generatedSave = $actualGenerated
    productionManifest = Get-B04Artifact -Path $ProductionManifestPath
}
$validation = [ordered]@{
    schema = 'nikami-fnv-real-save-b04-validation/v1'
    status = if ($script:b04AllPass) { 'pass' } else { 'fail' }
    bite = 'B04'
    runRoot = $RunRoot
    source = [ordered]@{
        save330 = Get-B04Artifact -Path $Save330Path
        denominator = Get-B04Artifact -Path $DenominatorPath
        a03Validation = Get-B04Artifact -Path $A03ValidationPath
        combinedReport = $artifactSummary.combinedReport
        productionManifest = $artifactSummary.productionManifest
    }
    phases = [ordered]@{
        save = [ordered]@{ telemetrySamples = $saveTelemetry.Count; worldReadySamples = $saveReadyTelemetry.Count; persistence = $savePersistence; initial = $saveInitial; latest = $saveLatest }
        reload = [ordered]@{ telemetrySamples = $reloadTelemetry.Count; worldReadySamples = $reloadReadyTelemetry.Count; persistence = $reloadPersistence; initial = $reloadInitial; latest = $reloadLatest }
    }
    generatedSave = $actualGenerated
    artifacts = $artifactSummary
    checks = @($checks)
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    failedChecks = @($checks | Where-Object { -not $_.passed }).Count
}
$directory = Split-Path -Parent $ValidationPath
if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 30) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$validation | ConvertTo-Json -Depth 6
if (-not $script:b04AllPass) { exit 1 }
