[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\\code\\nikami-worlds",
    [string]$CaptureRoot = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\d01-openmw-20260802-191800",
    [string]$RuntimeRoot = "D:\\code\\nikami-worlds\\local\\openmw-real-save330-d01-inventory-20260802-191500",
    [string]$FixturePath = "D:\\code\\nikami-worlds\\local\\retail-real-save-fixtures\\NikamiRealWorldSave330-20260802.fos",
    [string]$DenominatorPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-player-denominator.json",
    [string]$InventoryJoinPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-inventory-join.json",
    [string]$A03ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\save330-a03-validation.json",
    [string]$ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\d01-inventory-validation-final.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$CaptureRoot = [IO.Path]::GetFullPath($CaptureRoot)
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$FixturePath = [IO.Path]::GetFullPath($FixturePath)
$DenominatorPath = [IO.Path]::GetFullPath($DenominatorPath)
$InventoryJoinPath = [IO.Path]::GetFullPath($InventoryJoinPath)
$A03ValidationPath = [IO.Path]::GetFullPath($A03ValidationPath)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)

if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing D01 validation artifact: $ValidationPath"
}

$OpenMwRoot = Join-Path $CaptureRoot "openmw"
$SummaryPath = Join-Path $CaptureRoot "background-capture-summary.json"
$ReportPath = Join-Path $OpenMwRoot "real-save-capture-report.json"
$StatePath = Join-Path $OpenMwRoot "real-save-state.json"
$StdoutPath = Join-Path $OpenMwRoot "openmw.stdout.log"
$StderrPath = Join-Path $OpenMwRoot "openmw.stderr.log"
$VideoPath = Join-Path $OpenMwRoot "OpenMW-Save330-D01-inventory-exact-title-raw.mp4"
$NativeSourceRoot = Join-Path $OpenMwRoot "native-source-frames"
$NamedFrameNames = @(
    "Save330-D01-inventory-weap.png",
    "Save330-D01-inventory-apparel.png",
    "Save330-D01-inventory-aid.png",
    "Save330-D01-inventory-misc.png",
    "Save330-D01-inventory-ammo.png"
)

$checks = [Collections.Generic.List[object]]::new()
$script:d01AllPass = $true

function Add-D01Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:d01AllPass = $false }
}

function Get-D01Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Read-D01Json {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { return $null }
}

function Get-D01Value {
    param(
        [Parameter(Mandatory = $false)][AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Normalize-D01FormId {
    param([Parameter(Mandatory = $true)][string]$Raw)
    $value = $Raw.Trim().ToLowerInvariant()
    if ($value.StartsWith("formid:")) { $value = $value.Substring(7) }
    if (-not $value.StartsWith("0x")) { return $value }
    $number = [Convert]::ToInt64($value.Substring(2), 16)
    return ("0x{0:x8}" -f ($number -band 0xffffff))
}

function Test-D01Pattern {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    return [regex]::IsMatch($Text, $Pattern)
}

function Get-D01InventoryRows {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $pattern = 'FNV D01 inventory row: category=(\w+) index=(\d+) formId=FormId:(0x[0-9a-f]+) count=(\d+) family=(\w+) name="([^"]*)" icon="([^"]*)" equipped=([01]) condition=([01]) current=([-0-9.]+) max=([-0-9.]+) value=([-0-9.]+) weight=([-0-9.]+) selected=([01]) source=([^ ]+) provenance=(\S+)'
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $null = $rows.Add([ordered]@{
                category = $match.Groups[1].Value
                index = [int]$match.Groups[2].Value
                formId = $match.Groups[3].Value.ToLowerInvariant()
                formKey = Normalize-D01FormId $match.Groups[3].Value
                count = [int]$match.Groups[4].Value
                family = $match.Groups[5].Value
                name = $match.Groups[6].Value
                icon = $match.Groups[7].Value
                equipped = [int]$match.Groups[8].Value
                condition = [int]$match.Groups[9].Value
                current = [double]$match.Groups[10].Value
                max = [double]$match.Groups[11].Value
                value = [double]$match.Groups[12].Value
                weight = [double]$match.Groups[13].Value
                selected = [int]$match.Groups[14].Value
                source = $match.Groups[15].Value
                provenance = $match.Groups[16].Value
            })
    }
    return @($rows)
}

function Get-D01CategorySummaries {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $pattern = 'FNV D01 inventory: category=(WEAP|APP|AID|MISC|AMMO) allRows=(\d+) visibleRows=(\d+) selectedIndex=(\d+) source=([^ ]+) provenance=(\S+)'
    $summaries = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $null = $summaries.Add([ordered]@{
                category = $match.Groups[1].Value
                allRows = [int]$match.Groups[2].Value
                visibleRows = [int]$match.Groups[3].Value
                selectedIndex = [int]$match.Groups[4].Value
                source = $match.Groups[5].Value
                provenance = $match.Groups[6].Value
            })
    }
    return @($summaries)
}

function Get-D01B04Data {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $inventorySummary = $null
    $summaryMatch = [regex]::Match($Text, 'FNV B04 persistence: OpenMW save player inventory stacks=(\d+) visible=(\d+) worn=(\d+) totalItems=(\d+) health=([-0-9.]+) actionPoints=([-0-9.]+) actionPointsMax=([-0-9.]+)')
    if ($summaryMatch.Success) {
        $inventorySummary = [ordered]@{
            stacks = [int]$summaryMatch.Groups[1].Value
            visible = [int]$summaryMatch.Groups[2].Value
            worn = [int]$summaryMatch.Groups[3].Value
            totalItems = [int]$summaryMatch.Groups[4].Value
            health = [double]$summaryMatch.Groups[5].Value
            actionPoints = [double]$summaryMatch.Groups[6].Value
            actionPointsMax = [double]$summaryMatch.Groups[7].Value
        }
    }

    $equippedRows = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, 'FNV B04 persistence equipped: slot=(\d+) form=FormId:(0x[0-9a-f]+)')) {
        $null = $equippedRows.Add([ordered]@{
                slot = [int]$match.Groups[1].Value
                form = $match.Groups[2].Value.ToLowerInvariant()
                formKey = Normalize-D01FormId $match.Groups[2].Value
            })
    }

    $modifierRows = [Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, 'FNV B04 persistence actor-value modifier: actorValue=(\d+) permanent=([-0-9.]+) damage=([-0-9.]+) temporary=([-0-9.]+)')) {
        $null = $modifierRows.Add([ordered]@{
                actorValue = [int]$match.Groups[1].Value
                permanent = [double]$match.Groups[2].Value
                damage = [double]$match.Groups[3].Value
                temporary = [double]$match.Groups[4].Value
            })
    }

    $identity = $null
    $identityMatch = [regex]::Match($Text, 'FNV B04 persistence: OpenMW save player identity initialized=([01]) base=FormId:(0x[0-9a-f]+) reference=FormId:(0x[0-9a-f]+)')
    if ($identityMatch.Success) {
        $identity = [ordered]@{
            initialized = [int]$identityMatch.Groups[1].Value
            base = $identityMatch.Groups[2].Value.ToLowerInvariant()
            reference = $identityMatch.Groups[3].Value.ToLowerInvariant()
        }
    }

    return [ordered]@{
        inventorySummary = $inventorySummary
        equippedRows = @($equippedRows)
        modifierRows = @($modifierRows)
        identity = $identity
    }
}

$summary = Read-D01Json $SummaryPath
$report = Read-D01Json $ReportPath
$state = Read-D01Json $StatePath
$denominator = Read-D01Json $DenominatorPath
$inventoryJoin = Read-D01Json $InventoryJoinPath
$a03 = Read-D01Json $A03ValidationPath
$stdout = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) { Get-Content -Raw -LiteralPath $StdoutPath } else { '' }
$stderr = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { Get-Content -Raw -LiteralPath $StderrPath } else { '' }

$summaryArtifact = Get-D01Artifact $SummaryPath
$reportArtifact = Get-D01Artifact $ReportPath
$stateArtifact = Get-D01Artifact $StatePath
$stdoutArtifact = Get-D01Artifact $StdoutPath
$stderrArtifact = Get-D01Artifact $StderrPath
$videoArtifact = Get-D01Artifact $VideoPath
$fixtureArtifact = Get-D01Artifact $FixturePath
$denominatorArtifact = Get-D01Artifact $DenominatorPath
$joinArtifact = Get-D01Artifact $InventoryJoinPath
$a03Artifact = Get-D01Artifact $A03ValidationPath
$runtimeArtifact = Get-D01Artifact (Join-Path $RuntimeRoot "openmw.exe")
$pdbFiles = @(
    if (Test-Path -LiteralPath $RuntimeRoot -PathType Container) {
        Get-ChildItem -LiteralPath $RuntimeRoot -Filter "*.pdb" -File -Recurse
    }
)

$namedFrames = @($NamedFrameNames | ForEach-Object { Get-D01Artifact (Join-Path $OpenMwRoot $_) })
$sourceFrameFiles = if (Test-Path -LiteralPath $NativeSourceRoot -PathType Container) { @(Get-ChildItem -LiteralPath $NativeSourceRoot -Filter "screenshot*.png" -File | Sort-Object Name) } else { @() }
$sourceFrames = @($sourceFrameFiles | ForEach-Object { Get-D01Artifact $_.FullName })

$expectedFixtureBytes = 3395328
$expectedFixtureSha = "07dbdd2d7c4abe3160628e5463a9603a40f4271042c1da1b89f1c4a4f7dbd81f"
$expectedDenominatorBytes = 849513
$expectedDenominatorSha = "ae9b020591c5cc176e4a1a47bd9715cbf758e7bb3118a0376cfe4d2a05e92b92"
$runtimePluginPath = Join-Path $RuntimeRoot "osgPlugins-3.6.5"
$expectedRoute = "save330-pipboy-inventory-v1"
$expectedProvenance = "Save330-FOS-to-InventoryItemModel-to-TradeItemModel-to-SortFilterItemModel"
$expectedSource = "restored-save330-inventory-model"
$expectedCategories = @("WEAP", "APP", "AID", "MISC", "AMMO")
$expectedVisibleCounts = [ordered]@{ WEAP = 10; APP = 15; AID = 10; MISC = 14; AMMO = 4 }
$hiddenImplicitWorn = @("0x00015038", "0x00025b83")

Add-D01Check "Public D01 capture artifacts are retained" ($null -ne $summaryArtifact -and $null -ne $reportArtifact -and $null -ne $stateArtifact -and $null -ne $stdoutArtifact -and $null -ne $stderrArtifact) ([ordered]@{ summary = $summaryArtifact; report = $reportArtifact; state = $stateArtifact; stdout = $stdoutArtifact; stderr = $stderrArtifact })
Add-D01Check "Canonical Save330 fixture is hash locked" ($null -ne $fixtureArtifact -and $fixtureArtifact.bytes -eq $expectedFixtureBytes -and $fixtureArtifact.sha256 -eq $expectedFixtureSha) ([ordered]@{ expectedBytes = $expectedFixtureBytes; expectedSha256 = $expectedFixtureSha; actual = $fixtureArtifact })
Add-D01Check "Normalized Save330 denominator is hash locked" ($null -ne $denominatorArtifact -and $denominatorArtifact.bytes -eq $expectedDenominatorBytes -and $denominatorArtifact.sha256 -eq $expectedDenominatorSha) ([ordered]@{ expectedBytes = $expectedDenominatorBytes; expectedSha256 = $expectedDenominatorSha; actual = $denominatorArtifact })
Add-D01Check "Official inventory join and A03 validation are retained" ($null -ne $inventoryJoin -and $null -ne $joinArtifact -and $null -ne $a03 -and $a03.schema -eq "nikami-fnv-real-save-a03-validation/v1" -and $a03.status -eq "pass" -and $null -ne $a03Artifact) ([ordered]@{ join = $joinArtifact; a03 = $a03Artifact })

$summaryRealSave = Get-D01Value $summary "realSave"
$summaryPolicy = Get-D01Value $summary "policy"
$reportCapture = Get-D01Value $report "capture"
$reportAssertions = Get-D01Value $report "assertions"
$summaryPass = $null -ne $summary -and $summary.schema -eq "nikami-fnv-jam-background-capture-run/v1" -and $summary.status -eq "pass" -and $summary.target -eq "OpenMW" -and $summary.scenario -eq "RealSave" -and $null -ne $summaryRealSave -and $summaryRealSave.status -eq "pass" -and $summaryRealSave.routeId -eq $expectedRoute
Add-D01Check "Public sequential capture summary passes the D01 route" $summaryPass ([ordered]@{ schema = Get-D01Value $summary "schema"; status = Get-D01Value $summary "status"; routeId = Get-D01Value $summaryRealSave "routeId" })
$policyPass = $null -ne $summaryPolicy -and $summaryPolicy.windowsAppControlUsed -eq $false -and $summaryPolicy.foregroundActivationUsed -eq $false -and $summaryPolicy.foregroundInputInjected -eq $false -and $summaryPolicy.capturesRanSequentially -eq $true -and $summaryPolicy.outputOverwritten -eq $false
Add-D01Check "Capture policy has no host control, concurrency, or overwrite" $policyPass $summaryPolicy
$reportPass = $null -ne $report -and $report.schema -eq "nikami-fnv-real-save-capture/v1" -and $report.status -eq "pass" -and $report.target -eq "OpenMW" -and $report.routeId -eq $expectedRoute
Add-D01Check "Combined real-save report passes the D01 route" $reportPass ([ordered]@{ schema = Get-D01Value $report "schema"; status = Get-D01Value $report "status"; routeId = Get-D01Value $report "routeId" })
$capturePass = $null -ne $reportCapture -and $reportCapture.nativeFrameCount -eq 5 -and $reportCapture.sourceFrameRetained -eq $true -and $reportCapture.telemetryRetained -eq $true -and $reportCapture.exactTitleVideoRetained -eq $true -and $reportCapture.recorderExitCode -eq 0 -and $reportCapture.gameTermination -eq "engine-exited" -and $reportCapture.userConfigurationRestored -eq $true
Add-D01Check "D01 capture retains five native frames, telemetry, and exact-title video" $capturePass $reportCapture
$assertionPass = $null -ne $reportAssertions -and (Get-D01Value $reportAssertions "stateManifestPass") -eq $true -and (Get-D01Value $reportAssertions "ordinaryLoadPathObserved") -eq $true -and (Get-D01Value $reportAssertions "nativeSaveLoadComplete") -eq $true -and (Get-D01Value $reportAssertions "playerIdentityRestored") -eq $true -and (Get-D01Value $reportAssertions "savedTransformApplied") -eq $true -and (Get-D01Value $reportAssertions "fallbackInventoryAbsent") -eq $true -and (Get-D01Value $reportAssertions "syntheticPlacementAbsent") -eq $true -and (Get-D01Value $reportAssertions "d01InventoryFramesRetained") -eq $true -and (Get-D01Value $reportAssertions "exactTitleVideoRetained") -eq $true
Add-D01Check "Production real-save assertions pass without fallback or synthetic placement" $assertionPass $reportAssertions

$reportedRuntime = Get-D01Value (Get-D01Value $report "source") "binary"
$expectedRuntimePath = [IO.Path]::GetFullPath((Join-Path $RuntimeRoot "openmw.exe"))
$reportedRuntimePath = if ($null -ne $reportedRuntime) { [IO.Path]::GetFullPath([string](Get-D01Value $reportedRuntime "path")) } else { '' }
$reportedRuntimeSha = if ($null -ne $reportedRuntime) { ([string](Get-D01Value $reportedRuntime "sha256")).ToLowerInvariant() } else { '' }
$runtimePass = $null -ne $runtimeArtifact -and $runtimeArtifact.bytes -gt 0 -and $reportedRuntimePath -eq $expectedRuntimePath -and $reportedRuntimeSha -eq $runtimeArtifact.sha256 -and (Test-Path -LiteralPath (Join-Path $RuntimeRoot "resources") -PathType Container) -and (Test-Path -LiteralPath $runtimePluginPath -PathType Container) -and $pdbFiles.Count -eq 0
Add-D01Check "Report matches the supplied staged no-PDB runtime" $runtimePass ([ordered]@{ expectedPath = $expectedRuntimePath; reportedPath = $reportedRuntimePath; runtime = $runtimeArtifact; reportedSha256 = $reportedRuntimeSha; resources = Test-Path -LiteralPath (Join-Path $RuntimeRoot "resources") -PathType Container; osgPlugins = Test-Path -LiteralPath $runtimePluginPath -PathType Container; pdbFiles = @($pdbFiles | ForEach-Object { $_.FullName }) })

$stateD01 = Get-D01Value $state "d01Inventory"
$stateLaunch = Get-D01Value $state "launch"
$statePass = $null -ne $state -and $state.schema -eq "nikami-fnv-real-save-state/v1" -and $state.status -eq "pass" -and $state.routeId -eq $expectedRoute -and $null -ne $stateD01 -and $stateD01.enabled -eq $true -and $stateD01.expectedNativeFrameCount -eq 5 -and $stateD01.retainedNativeFrameCount -eq 5 -and $null -ne $stateLaunch -and $stateLaunch.ordinaryLoadSavegame -eq $true -and $stateLaunch.usedStart -eq $false -and $stateLaunch.usedTestMapPlacement -eq $false -and $stateLaunch.usedBootstrapInventory -eq $false -and $stateLaunch.usedConsoleInjection -eq $false
Add-D01Check "State manifest records ordinary Save330 load and the complete D01 route" $statePass ([ordered]@{ state = $state; d01 = $stateD01; launch = $stateLaunch })

$rows = @(Get-D01InventoryRows $stdout)
$duplicateRowKeys = @($rows | Group-Object { "{0}:{1}" -f $_.category, $_.index } | Where-Object { $_.Count -ne 1 } | ForEach-Object { $_.Name })
Add-D01Check "Exactly 53 real production inventory rows are logged without duplicate row identities" ($rows.Count -eq 53 -and $duplicateRowKeys.Count -eq 0) ([ordered]@{ rowCount = $rows.Count; duplicateRowKeys = $duplicateRowKeys })

$summaries = @(Get-D01CategorySummaries $stdout)
$summaryByCategory = @{}
foreach ($item in $summaries) {
    if (-not $summaryByCategory.ContainsKey($item.category)) { $summaryByCategory[$item.category] = $item }
}
$summaryCategoryPass = $true
$summaryCategoryDetails = [ordered]@{}
foreach ($category in $expectedCategories) {
    $item = if ($summaryByCategory.ContainsKey($category)) { $summaryByCategory[$category] } else { $null }
    $pass = $null -ne $item -and $item.allRows -eq 53 -and $item.visibleRows -eq $expectedVisibleCounts[$category] -and $item.selectedIndex -eq 0 -and $item.source -eq $expectedSource -and $item.provenance -eq $expectedProvenance
    $summaryCategoryPass = $summaryCategoryPass -and $pass
    $summaryCategoryDetails[$category] = [ordered]@{ pass = $pass; observed = $item; expectedVisibleRows = $expectedVisibleCounts[$category] }
}
Add-D01Check "Each production Pip-Boy category reports its exact supported visible-row count" $summaryCategoryPass $summaryCategoryDetails

$rowFieldFailures = @($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.name) -or [string]::IsNullOrWhiteSpace($_.icon) -or $_.source -ne $expectedSource -or $_.provenance -ne $expectedProvenance -or $_.count -le 0 -or $_.value -lt 0 -or $_.weight -lt 0 -or [double]::IsNaN($_.current) -or [double]::IsNaN($_.max) -or [double]::IsNaN($_.value) -or [double]::IsNaN($_.weight) })
Add-D01Check "Every visible row has a real name, icon, count, stats, and Save330 model provenance" ($rowFieldFailures.Count -eq 0) $rowFieldFailures
$familyFailures = @($rows | Where-Object {
        ($_.category -eq "WEAP" -and $_.family -ne "WEAP") -or
        ($_.category -eq "APP" -and $_.family -ne "ARMO") -or
        ($_.category -eq "AID" -and $_.family -ne "ALCH") -or
        ($_.category -eq "MISC" -and $_.family -notin @("MISC", "BOOK")) -or
        ($_.category -eq "AMMO" -and $_.family -ne "AMMO")
    })
Add-D01Check "Production category families match the official record families" ($familyFailures.Count -eq 0) $familyFailures
$selectionDetails = [ordered]@{}
$selectionPass = $true
foreach ($category in $expectedCategories) {
    $selectedRows = @($rows | Where-Object { $_.category -eq $category -and $_.selected -eq 1 })
    $pass = $selectedRows.Count -eq 1 -and $selectedRows[0].index -eq 0
    $selectionPass = $selectionPass -and $pass
    $selectionDetails[$category] = [ordered]@{ pass = $pass; selected = $selectedRows }
}
Add-D01Check "Every production category retains one selected row at index zero" $selectionPass $selectionDetails
$conditionedRows = @($rows | Where-Object { $_.condition -eq 1 })
Add-D01Check "Condition-bearing production rows retain current/max condition fields" ($conditionedRows.Count -gt 0 -and @($conditionedRows | Where-Object { $_.current -lt 0 -or $_.max -le 0 -or $_.current -gt $_.max }).Count -eq 0) ([ordered]@{ conditionedRows = $conditionedRows.Count; invalid = @($conditionedRows | Where-Object { $_.current -lt 0 -or $_.max -le 0 -or $_.current -gt $_.max }) })

$joinRows = if ($null -ne $inventoryJoin) { @(Get-D01Value $inventoryJoin "rows") } else { @() }
$expectedByForm = @{}
foreach ($joinRow in $joinRows) {
    $key = Normalize-D01FormId ([string](Get-D01Value $joinRow "formId"))
    $record = Get-D01Value $joinRow "record"
    $expectedByForm[$key] = [ordered]@{
        formKey = $key
        count = [int](Get-D01Value $joinRow "count")
        family = [string](Get-D01Value $record "family")
        name = [string](Get-D01Value $record "displayName")
        icon = [string](Get-D01Value $record "icon")
    }
}
$d01ByForm = @{}
$d01NameFailures = [Collections.Generic.List[object]]::new()
foreach ($row in $rows) {
    if (-not $d01ByForm.ContainsKey($row.formKey)) { $d01ByForm[$row.formKey] = 0 }
    $d01ByForm[$row.formKey] += $row.count
    if ($expectedByForm.ContainsKey($row.formKey)) {
        $expected = $expectedByForm[$row.formKey]
        $familyCompatible = $row.family -eq $expected.family
        $nameCompatible = $row.name -eq $expected.name
        if (-not $familyCompatible -or -not $nameCompatible) {
            $null = $d01NameFailures.Add([ordered]@{ formKey = $row.formKey; observedFamily = $row.family; expectedFamily = $expected.family; observedName = $row.name; expectedName = $expected.name })
        }
    }
}
$supportedKeys = @($expectedByForm.Keys | Where-Object { $_ -notin $hiddenImplicitWorn })
$missingSupported = @($supportedKeys | Where-Object { -not $d01ByForm.ContainsKey($_) })
$extraSupported = @($d01ByForm.Keys | Where-Object { -not $expectedByForm.ContainsKey($_) -or $_ -in $hiddenImplicitWorn })
$countDifferences = [Collections.Generic.List[object]]::new()
foreach ($key in $supportedKeys) {
    if ($d01ByForm.ContainsKey($key) -and [int]$d01ByForm[$key] -ne [int]$expectedByForm[$key].count) {
        $null = $countDifferences.Add([ordered]@{ formKey = $key; observed = $d01ByForm[$key]; expected = $expectedByForm[$key].count })
    }
}
$supportedExpectedTotal = [int](($supportedKeys | ForEach-Object { $expectedByForm[$_].count } | Measure-Object -Sum).Sum)
$supportedObservedTotal = [int](($d01ByForm.Keys | ForEach-Object { $d01ByForm[$_] } | Measure-Object -Sum).Sum)
$fullExpectedTotal = [int](($expectedByForm.Keys | ForEach-Object { $expectedByForm[$_].count } | Measure-Object -Sum).Sum)
$hiddenExpectedTotal = [int](($hiddenImplicitWorn | ForEach-Object { if ($expectedByForm.ContainsKey($_)) { $expectedByForm[$_].count } else { 0 } } | Measure-Object -Sum).Sum)
$unresolvedRows = @(Get-D01Value $inventoryJoin "unresolved")
Add-D01Check "All supported Save330 FormIDs and final counts reconcile through the production model" ($joinRows.Count -eq 50 -and $unresolvedRows.Count -eq 0 -and $supportedKeys.Count -eq 48 -and $d01ByForm.Count -eq 48 -and $missingSupported.Count -eq 0 -and $extraSupported.Count -eq 0 -and $countDifferences.Count -eq 0 -and $supportedExpectedTotal -eq 786 -and $supportedObservedTotal -eq 786 -and $fullExpectedTotal -eq 788 -and $hiddenExpectedTotal -eq 2) ([ordered]@{ joinRows = $joinRows.Count; unresolvedRows = $unresolvedRows.Count; supportedKeys = $supportedKeys.Count; observedForms = $d01ByForm.Count; missing = $missingSupported; extra = $extraSupported; countDifferences = $countDifferences; supportedExpectedTotal = $supportedExpectedTotal; supportedObservedTotal = $supportedObservedTotal; implicitWornTotal = $hiddenExpectedTotal; fullExpectedTotal = $fullExpectedTotal })
Add-D01Check "Supported row names and families match the official winning records" ($d01NameFailures.Count -eq 0) @($d01NameFailures)

$b04 = Get-D01B04Data $stdout
$b04Inventory = $b04.inventorySummary
$inventoryTotalsPass = $null -ne $b04Inventory -and $b04Inventory.stacks -eq 55 -and $b04Inventory.visible -eq 53 -and $b04Inventory.worn -eq 3 -and $b04Inventory.totalItems -eq 788 -and $b04Inventory.health -eq 100 -and $b04Inventory.actionPoints -eq 80 -and $b04Inventory.actionPointsMax -eq 80
Add-D01Check "Runtime telemetry retains the full 55-stack/53-visible/788-item Save330 inventory totals" $inventoryTotalsPass $b04Inventory
$equipped = @($b04.equippedRows | Group-Object { "{0}:{1}" -f $_.slot, $_.form } | ForEach-Object { $_.Group[0] })
$equippedSignature = @($equipped | ForEach-Object { "{0}:{1}" -f $_.slot, $_.form } | Sort-Object) -join "|"
$expectedEquippedSignature = "1:0x1015038|11:0x100431e|5:0x1025b83"
Add-D01Check "Runtime telemetry retains all three exact Save330 worn/equipped slot rows" ($equipped.Count -eq 3 -and $equippedSignature -eq $expectedEquippedSignature) ([ordered]@{ expected = $expectedEquippedSignature; observed = $equipped })
$modifierSignature = @($b04.modifierRows | Select-Object -Unique | ForEach-Object { "{0}:{1}:{2}:{3}" -f $_.actorValue, $_.permanent, $_.damage, $_.temporary } | Sort-Object) -join "|"
Add-D01Check "Runtime telemetry retains the exact Save330 actor-value modifier" ($b04.modifierRows.Count -eq 1 -and $modifierSignature -eq "24:10:0:0") ([ordered]@{ expected = "24:10:0:0"; observed = $b04.modifierRows })
Add-D01Check "Runtime telemetry retains the exact Save330 player identity" ($null -ne $b04.identity -and $b04.identity.initialized -eq 1 -and $b04.identity.base -eq "0x1000007" -and $b04.identity.reference -eq "0x1000014") $b04.identity

$completePass = Test-D01Pattern $stdout 'FNV D01 inventory: phase=complete categories=5 captured=5 allRows=53 source=production-Pip-Boy-items-tab status=pass'
Add-D01Check "D01 engine route completes all five production Pip-Boy categories" $completePass ([ordered]@{ phaseComplete = $completePass; expectedCategories = $expectedCategories })
$frameMatches = @([regex]::Matches($stdout, 'FNV D01 native frame: category=(WEAP|APP|AID|MISC|AMMO) index=(\d+) source=ScreenCaptureHandler') | ForEach-Object { $_.Groups[1].Value })
Add-D01Check "Each category retains a native ScreenCaptureHandler frame" (@($frameMatches | Sort-Object -Unique).Count -eq 5 -and @($expectedCategories | Where-Object { $_ -notin $frameMatches }).Count -eq 0) ([ordered]@{ observed = @($frameMatches | Sort-Object -Unique); expected = $expectedCategories })

$namedNonEmpty = @($namedFrames | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0
$namedHashes = @($namedFrames | Where-Object { $null -ne $_ } | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
$sourceNonEmpty = @($sourceFrames | Where-Object { $null -eq $_ -or $_.bytes -le 0 }).Count -eq 0
$sourceHashes = @($sourceFrames | Where-Object { $null -ne $_ } | ForEach-Object { $_.sha256 } | Sort-Object -Unique)
Add-D01Check "Five named native inventory frames are present, non-empty, and distinct" ($namedFrames.Count -eq 5 -and $namedNonEmpty -and $namedHashes.Count -eq 5) $namedFrames
Add-D01Check "Five retained source frames are present, non-empty, and distinct" ($sourceFrames.Count -eq 5 -and $sourceNonEmpty -and $sourceHashes.Count -eq 5) $sourceFrames
Add-D01Check "D01 exact-title video is present and non-empty" ($null -ne $videoArtifact -and $videoArtifact.bytes -gt 0) $videoArtifact

$nativePatterns = [ordered]@{
    "ordinary Save330 load" = 'FNV/ESM4 proof: loading save from command line ".*NikamiRealWorldSave330-20260802\.fos"'
    "native structural parse" = 'Native FNV save structural parse complete: masters=10 .* inventoryEntries=50'
    "player identity" = 'Native FNV save Player identity restored: base=0x1000007 reference=0x1000014'
    "inventory denominator" = 'Native FNV save Player inventory: stacks=50 worn=3'
    "runtime inventory rebuild" = 'Native FNV save Player runtime inventory rebuilt: stacks=55 visible=53'
    "transform restoration" = 'Native FNV save restored local REFR/ACHR/ACRE transforms: applied=4 missing=0'
    "camera ownership" = 'Native FNV save owns camera mode=1 .* firstPersonModelFov='
    "production marker widget" = 'FNV/ESM4 map: rendered 1 exact world-map markers'
    "settled OpenMW inventory telemetry" = 'FNV B04 persistence: OpenMW save player inventory stacks=55 visible=53 worn=3 totalItems=788'
    "actor modifier telemetry" = 'FNV B04 persistence actor-value modifier: actorValue=24 permanent=10 damage=0 temporary=0'
}
foreach ($entry in $nativePatterns.GetEnumerator()) {
    Add-D01Check ("D01 log contains " + $entry.Key) (Test-D01Pattern $stdout $entry.Value) $entry.Value
}

$forbiddenTerms = @("AppActivate", "SetForegroundWindow", "SendInput", "Computer Use", "OPENMW_FNV_UNLOCK_ALL_MAP_MARKERS", "unlock-all", "unlock all", "teleport shortcut", "TestMap placement", "showcase-only", "fallback inventory applied", "synthetic inventory applied", "console injection used")
$forbiddenFound = @($forbiddenTerms | Where-Object { $stdout -match [regex]::Escape($_) -or $stderr -match [regex]::Escape($_) })
Add-D01Check "D01 logs contain no host-control, unlock, shortcut, fallback, or synthetic evidence" ($forbiddenFound.Count -eq 0) $forbiddenFound

$validation = [ordered]@{
    schema = "nikami-fnv-real-save-d01-validation/v1"
    status = if ($script:d01AllPass) { "pass" } else { "fail" }
    objective = "Validate the complete supported Save330 inventory through production Pip-Boy categories, with exact final totals, worn/equipped rows, actor-value modifier, icons, conditions, and source provenance."
    captureRoot = $CaptureRoot
    routeId = $expectedRoute
    inventory = [ordered]@{
        categoryCounts = $expectedVisibleCounts
        productionRows = $rows
        supportedTotals = [ordered]@{ expected = $supportedExpectedTotal; observed = $supportedObservedTotal; supportedFormIDs = $supportedKeys.Count }
        implicitWornRows = $hiddenImplicitWorn
        fullFinalTotal = $fullExpectedTotal
        runtimeTelemetry = $b04Inventory
        equippedRows = $equipped
        actorValueModifiers = $b04.modifierRows
    }
    source = [ordered]@{
        fixture = $fixtureArtifact
        playerDenominator = $denominatorArtifact
        inventoryJoin = $joinArtifact
        a03Validation = $a03Artifact
        runtime = $runtimeArtifact
        publicSummary = $summaryArtifact
        captureReport = $reportArtifact
        stateManifest = $stateArtifact
        stdout = $stdoutArtifact
        stderr = $stderrArtifact
        exactTitleVideo = $videoArtifact
        namedNativeFrames = $namedFrames
        nativeSourceFrames = $sourceFrames
    }
    checks = @($checks)
}
[IO.Directory]::CreateDirectory((Split-Path -Parent $ValidationPath)) | Out-Null
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 40) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

if (-not $script:d01AllPass) { throw "D01 validation failed. See $ValidationPath" }

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $checks.Count
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-D01Artifact $ValidationPath
    captureRoot = $CaptureRoot
}
