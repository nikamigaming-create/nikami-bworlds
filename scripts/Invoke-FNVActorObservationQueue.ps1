[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanRoot,
    [Parameter(Mandatory)]
    [string]$CorpusRoot,
    [Parameter(Mandatory)]
    [string]$QueueRoot,
    [Parameter(Mandatory)]
    [string]$OracleSeedRoot,
    [Parameter(Mandatory)]
    [string]$OraclePluginDll,
    [Parameter(Mandatory)]
    [string]$SaveFixture,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas',
    [string]$BatchKey = '',
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaximumJobs = 0,
    [ValidateRange(0, [int]::MaxValue)]
    [int]$TimeoutSeconds = 0,
    [switch]$InitializeOnly,
    [switch]$PlanOnly,
    [string]$WorldsRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($InitializeOnly -and $PlanOnly) {
    throw 'Choose either InitializeOnly or PlanOnly.'
}
if ([string]::IsNullOrWhiteSpace($WorldsRoot)) {
    $WorldsRoot = Split-Path -Parent $PSScriptRoot
}
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)

function Resolve-QueuePath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $WorldsRoot $Path))
}

function Get-LowerSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-ImmutableJson([string]$Path, [object]$Value, [int]$Depth = 20) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite immutable JSON: $Path" }
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
}

function Add-JsonLine([string]$Path, [object]$Value, [int]$Depth = 20) {
    $line = ($Value | ConvertTo-Json -Depth $Depth -Compress) + [Environment]::NewLine
    [IO.File]::AppendAllText($Path, $line, [Text.UTF8Encoding]::new($false))
}

function Read-JsonLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @([IO.File]::ReadLines($Path) | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json }
    })
}

function Assert-ManifestFile([string]$Root, [object]$Entry, [string]$Label) {
    $path = Join-Path $Root ([string]$Entry.file)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $Label file: $path" }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -ne [int64]$Entry.bytes -or
        (Get-LowerSha256 $path) -cne [string]$Entry.sha256) {
        throw "$Label differs from its immutable manifest: $path"
    }
    return $path
}

function New-Coverage([object[]]$Jobs) {
    $expectedByJob = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal)
    $allExpectedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectedOutcomes = 0
    foreach ($job in $Jobs) {
        $jobKey = [string]$job.captureJobKey
        if ([string]::IsNullOrWhiteSpace($jobKey) -or $expectedByJob.ContainsKey($jobKey)) {
            throw "Actor-observation plan contains an invalid or duplicate job key: $jobKey"
        }
        $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($key in @($job.expectedReviewKeys)) {
            if (-not $expected.Add([string]$key) -or -not $allExpectedKeys.Add([string]$key)) {
                throw "Actor-observation plan contains a duplicate review key: $key"
            }
        }
        if ($expected.Count -ne [int]$job.expectedOutcomeCount -or $expected.Count -lt 1) {
            throw "Actor-observation plan outcome count differs for '$jobKey'."
        }
        $expectedByJob.Add($jobKey, $expected)
        $expectedOutcomes += $expected.Count
    }
    return [pscustomobject][ordered]@{
        baseJobs = $Jobs.Count
        baseJobsComplete = 0
        baseJobsPending = $Jobs.Count
        expectedOutcomes = $expectedOutcomes
        capturedOutcomes = 0
        pendingOutcomes = $expectedOutcomes
        attempts = 0
        unclassifiedAttempts = 0
        incompleteAppearanceAttempts = 0
        captureErrors = 0
        capturedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        attemptsByJob = [Collections.Generic.Dictionary[string,int]]::new(
            [StringComparer]::Ordinal)
        expectedByJob = $expectedByJob
    }
}

function Add-CoverageEvent([object]$Coverage, [object]$Event) {
    if ([string]$Event.schema -cne 'nikami-fnv-actor-observation-queue-event/v1' -or
        [int]$Event.sequence -ne $Coverage.attempts + 1) {
        throw 'Actor-observation queue contains an unsupported or out-of-order event.'
    }
    $jobKey = [string]$Event.captureJobKey
    if (-not $Coverage.expectedByJob.ContainsKey($jobKey) -or [int]$Event.attemptNumber -lt 1) {
        throw "Actor-observation queue event names an unknown job or invalid attempt: $jobKey"
    }
    $expected = $Coverage.expectedByJob[$jobKey]
    $eventExpected = @($Event.expectedReviewKeys | ForEach-Object { [string]$_ } | Sort-Object)
    if (($eventExpected -join "`n") -cne (@($expected | Sort-Object) -join "`n")) {
        throw "Actor-observation queue event changed the expected review set for '$jobKey'."
    }
    $status = [string]$Event.resultStatus
    if ($status -cnotin @('captured-classified-runtime-observation',
            'captured-classified-incomplete-appearance-evidence',
            'captured-unclassified-runtime-observation', 'capture-error')) {
        throw "Actor-observation queue event has unsupported status '$status'."
    }
    if ($status -cne 'capture-error') {
        foreach ($evidence in @($Event.report, $Event.backgroundCaptureSummary)) {
            $path = [string]$evidence.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-LowerSha256 $path) -cne [string]$evidence.sha256) {
                throw "Queue event evidence is missing or changed: $path"
            }
        }
        $report = Get-Content -Raw -LiteralPath ([string]$Event.report.path) | ConvertFrom-Json
        if ([string]$report.captureJob.captureJobKey -cne $jobKey -or
            [string]$report.status -cne $status -or
            [string]$report.classifiedReviewKey -cne [string]$Event.classifiedReviewKey) {
            throw "Queue event differs from its retained actor report for '$jobKey'."
        }
    }

    $wasComplete = @($expected | Where-Object {
        -not $Coverage.capturedKeys.Contains($_)
    }).Count -eq 0
    if ($status -ceq 'captured-classified-runtime-observation') {
        $classifiedKey = [string]$Event.classifiedReviewKey
        if ([string]::IsNullOrWhiteSpace($classifiedKey) -or -not $expected.Contains($classifiedKey)) {
            throw "Queue event classified an undeclared review key for '$jobKey'."
        }
        if ($Coverage.capturedKeys.Add($classifiedKey)) {
            $Coverage.capturedOutcomes++
            $Coverage.pendingOutcomes--
        }
    }
    elseif ($status -ceq 'captured-classified-incomplete-appearance-evidence') {
        $classifiedKey = [string]$Event.classifiedReviewKey
        if ([string]::IsNullOrWhiteSpace($classifiedKey) -or
            -not $expected.Contains($classifiedKey)) {
            throw "Incomplete-appearance queue event classified an undeclared review key for '$jobKey'."
        }
        $Coverage.incompleteAppearanceAttempts++
    }
    elseif ($status -ceq 'captured-unclassified-runtime-observation') {
        if (-not [string]::IsNullOrWhiteSpace([string]$Event.classifiedReviewKey)) {
            throw "Unclassified queue event retained a classified key for '$jobKey'."
        }
        $Coverage.unclassifiedAttempts++
    }
    else {
        $Coverage.captureErrors++
    }
    if ($Coverage.attemptsByJob.ContainsKey($jobKey)) { $Coverage.attemptsByJob[$jobKey]++ }
    else { $Coverage.attemptsByJob.Add($jobKey, 1) }
    $Coverage.attempts++
    $isComplete = @($expected | Where-Object {
        -not $Coverage.capturedKeys.Contains($_)
    }).Count -eq 0
    if (-not $wasComplete -and $isComplete) {
        $Coverage.baseJobsComplete++
        $Coverage.baseJobsPending--
    }
}

function Get-Coverage([object[]]$Jobs, [object[]]$Events) {
    $coverage = New-Coverage $Jobs
    foreach ($event in $Events) { Add-CoverageEvent $coverage $event }
    return $coverage
}

function Write-CoverageCheckpoint(
    [string]$Directory,
    [int]$Sequence,
    [object]$Coverage,
    [string]$PlanManifestHash,
    [string]$CorpusManifestHash) {
    $checkpointPath = Join-Path $Directory ('checkpoint-{0}.json' -f $Sequence)
    $checkpoint = [ordered]@{
        schema = 'nikami-fnv-actor-observation-coverage/v1'
        status = if ($Coverage.pendingOutcomes -eq 0) {
            'retail-reference-coverage-complete'
        } else { 'retail-reference-coverage-pending' }
        planManifestSha256 = $PlanManifestHash
        corpusManifestSha256 = $CorpusManifestHash
        baseJobs = $Coverage.baseJobs
        baseJobsComplete = $Coverage.baseJobsComplete
        baseJobsPending = $Coverage.baseJobsPending
        expectedOutcomes = $Coverage.expectedOutcomes
        capturedOutcomes = $Coverage.capturedOutcomes
        pendingOutcomes = $Coverage.pendingOutcomes
        attempts = $Coverage.attempts
        unclassifiedAttempts = $Coverage.unclassifiedAttempts
        incompleteAppearanceAttempts = $Coverage.incompleteAppearanceAttempts
        captureErrors = $Coverage.captureErrors
        parityVerdictStatus = 'not-evaluated-by-retail-reference-queue'
    }
    if (Test-Path -LiteralPath $checkpointPath -PathType Leaf) {
        $existing = Get-Content -Raw -LiteralPath $checkpointPath | ConvertFrom-Json
        if ([string]$existing.schema -cne [string]$checkpoint.schema -or
            [int]$existing.attempts -ne [int]$checkpoint.attempts -or
            [int]$existing.capturedOutcomes -ne [int]$checkpoint.capturedOutcomes -or
            [int]$existing.incompleteAppearanceAttempts -ne
                [int]$checkpoint.incompleteAppearanceAttempts -or
            [int]$existing.captureErrors -ne [int]$checkpoint.captureErrors -or
            [string]$existing.planManifestSha256 -cne $PlanManifestHash -or
            [string]$existing.corpusManifestSha256 -cne $CorpusManifestHash) {
            throw "Existing coverage checkpoint differs at sequence $Sequence."
        }
    }
    else {
        Write-ImmutableJson $checkpointPath $checkpoint
    }
    return $checkpointPath
}

$planDirectory = Resolve-QueuePath $PlanRoot
$corpusDirectory = Resolve-QueuePath $CorpusRoot
$queueDirectory = Resolve-QueuePath $QueueRoot
$seedDirectory = Resolve-QueuePath $OracleSeedRoot
$pluginPath = Resolve-QueuePath $OraclePluginDll
$savePath = Resolve-QueuePath $SaveFixture
$gameDirectory = Resolve-QueuePath $GameRoot
$catalogPath = Join-Path $WorldsRoot 'catalog\fnv-jam-background-capture-recipes.json'
$entryPoint = Join-Path $PSScriptRoot 'Invoke-FNVJamBackgroundCapture.ps1'
$seedManifestPath = Join-Path $seedDirectory 'oracle-runtime-manifest.json'

foreach ($directory in @($planDirectory, $corpusDirectory, $seedDirectory, $gameDirectory)) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Missing actor queue directory: $directory"
    }
}
foreach ($file in @($pluginPath, $savePath, $seedManifestPath, $catalogPath, $entryPoint,
        (Join-Path $gameDirectory 'FalloutNV.exe'))) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Missing actor queue file: $file"
    }
}
if ([IO.Path]::GetExtension($savePath) -ine '.fos') {
    throw "Actor queue SaveFixture must be a legally owned .fos file: $savePath"
}

$planManifestPath = Join-Path $planDirectory 'manifest.json'
$corpusManifestPath = Join-Path $corpusDirectory 'manifest.json'
$planManifest = Get-Content -Raw -LiteralPath $planManifestPath | ConvertFrom-Json
$corpusManifest = Get-Content -Raw -LiteralPath $corpusManifestPath | ConvertFrom-Json
if ([string]$planManifest.schema -cne 'opennv-actor-capture-plan/v1' -or
    [string]$corpusManifest.schema -cne 'opennv-actor-parity-corpus/v1') {
    throw 'Actor queue requires canonical v1 plan and corpus manifests.'
}
$jobsPath = Assert-ManifestFile $planDirectory $planManifest.outputs.jobs 'capture jobs'
$batchesPath = Assert-ManifestFile $planDirectory $planManifest.outputs.batches 'capture batches'
[void](Assert-ManifestFile $corpusDirectory $corpusManifest.outputs.appearanceReview 'appearance review')
if ([string]$planManifest.sourceCorpus.appearanceReviewSha256 -cne
    [string]$corpusManifest.outputs.appearanceReview.sha256) {
    throw 'Actor queue plan is not bound to the supplied corpus.'
}

$catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
$recipes = @($catalog.actorObservationRecipes | Where-Object {
    [string]$_.id -ceq 'fnv-official-actor-retail-observation-v1'
})
if ($recipes.Count -ne 1) { throw 'Canonical actor-observation recipe is missing or duplicated.' }
$queuePolicy = $recipes[0].queuePolicy
if ([int]$queuePolicy.attemptsPerExpectedOutcomePerSweep -lt 1 -or
    [int]$queuePolicy.checkpointEveryAttempts -lt 1) {
    throw 'Actor-observation queue policy is incomplete.'
}
if ($TimeoutSeconds -eq 0) { $TimeoutSeconds = [int]$recipes[0].capturePolicy.timeoutSeconds }

$allJobs = @(Read-JsonLines $jobsPath)
$batches = @(Read-JsonLines $batchesPath)
$selectedJobs = $allJobs
if (-not [string]::IsNullOrWhiteSpace($BatchKey)) {
    $batch = @($batches | Where-Object { [string]$_.batchKey -ceq $BatchKey })
    if ($batch.Count -ne 1) { throw "BatchKey '$BatchKey' matched $($batch.Count) rows." }
    $jobKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in @($batch[0].jobKeys)) { [void]$jobKeys.Add([string]$key) }
    $selectedJobs = @($allJobs | Where-Object { $jobKeys.Contains([string]$_.captureJobKey) })
    if ($selectedJobs.Count -ne $jobKeys.Count) { throw "BatchKey '$BatchKey' has unresolved jobs." }
}
if ($MaximumJobs -gt 0) { $selectedJobs = @($selectedJobs | Select-Object -First $MaximumJobs) }

$planManifestHash = Get-LowerSha256 $planManifestPath
$corpusManifestHash = Get-LowerSha256 $corpusManifestPath
$binding = [ordered]@{
    schema = 'nikami-fnv-actor-observation-queue/v1'
    planManifest = [ordered]@{ path = $planManifestPath; sha256 = $planManifestHash }
    corpusManifest = [ordered]@{ path = $corpusManifestPath; sha256 = $corpusManifestHash }
    jobs = [ordered]@{ path = $jobsPath; sha256 = Get-LowerSha256 $jobsPath }
    batches = [ordered]@{ path = $batchesPath; sha256 = Get-LowerSha256 $batchesPath }
    catalog = [ordered]@{ path = $catalogPath; sha256 = Get-LowerSha256 $catalogPath }
    oracleSeedManifest = [ordered]@{
        path = $seedManifestPath
        sha256 = Get-LowerSha256 $seedManifestPath
    }
    oraclePlugin = [ordered]@{ path = $pluginPath; sha256 = Get-LowerSha256 $pluginPath }
    saveFixture = [ordered]@{ path = $savePath; sha256 = Get-LowerSha256 $savePath }
    gameExecutable = [ordered]@{
        path = Join-Path $gameDirectory 'FalloutNV.exe'
        sha256 = Get-LowerSha256 (Join-Path $gameDirectory 'FalloutNV.exe')
    }
    eventLedger = 'observation-events.jsonl'
    proofDirectory = 'proofs'
    checkpointDirectory = 'coverage-checkpoints'
}

$manifestPath = Join-Path $queueDirectory 'queue-manifest.json'
if (-not (Test-Path -LiteralPath $queueDirectory)) {
    New-Item -ItemType Directory -Path $queueDirectory | Out-Null
    Write-ImmutableJson $manifestPath $binding
}
else {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Existing queue directory lacks its immutable manifest: $queueDirectory"
    }
    $existingBinding = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    foreach ($property in @('planManifest', 'corpusManifest', 'jobs', 'batches', 'catalog',
            'oracleSeedManifest', 'oraclePlugin', 'saveFixture', 'gameExecutable')) {
        if ([string]$existingBinding.$property.sha256 -cne [string]$binding.$property.sha256) {
            throw "Queue binding changed for '$property'; create a new queue root."
        }
    }
}

$proofDirectory = Join-Path $queueDirectory 'proofs'
$checkpointDirectory = Join-Path $queueDirectory 'coverage-checkpoints'
foreach ($directory in @($proofDirectory, $checkpointDirectory)) {
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
}
$eventsPath = Join-Path $queueDirectory 'observation-events.jsonl'
$events = @(Read-JsonLines $eventsPath)
$coverage = Get-Coverage $allJobs $events
$pendingSelectedJobs = @($selectedJobs | Where-Object {
    $job = $_
    @($job.expectedReviewKeys | Where-Object {
        -not $coverage.capturedKeys.Contains([string]$_)
    }).Count -gt 0
})

if ($InitializeOnly -or $PlanOnly) {
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-actor-observation-queue-plan/v1'
        status = if ($InitializeOnly) { 'initialized' } else { 'planned' }
        queueRoot = $queueDirectory
        selectedBaseJobs = $selectedJobs.Count
        selectedPendingBaseJobs = $pendingSelectedJobs.Count
        coverage = [ordered]@{
            baseJobs = $coverage.baseJobs
            baseJobsComplete = $coverage.baseJobsComplete
            expectedOutcomes = $coverage.expectedOutcomes
            capturedOutcomes = $coverage.capturedOutcomes
            pendingOutcomes = $coverage.pendingOutcomes
            attempts = $coverage.attempts
            incompleteAppearanceAttempts = $coverage.incompleteAppearanceAttempts
            captureErrors = $coverage.captureErrors
        }
    } | ConvertTo-Json -Depth 8
    return
}

$lockPath = Join-Path $queueDirectory 'queue.lock'
$lockStream = $null
try {
    $lockStream = [IO.File]::Open(
        $lockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
    $events = @(Read-JsonLines $eventsPath)
    $coverage = Get-Coverage $allJobs $events
    $pendingSelectedJobs = @($selectedJobs | Where-Object {
        $job = $_
        @($job.expectedReviewKeys | Where-Object {
            -not $coverage.capturedKeys.Contains([string]$_)
        }).Count -gt 0
    })
    $attemptsThisRun = 0
    foreach ($job in $pendingSelectedJobs) {
        $jobKey = [string]$job.captureJobKey
        $expectedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($key in @($job.expectedReviewKeys)) { [void]$expectedKeys.Add([string]$key) }
        $attemptBudget = $expectedKeys.Count * [int]$queuePolicy.attemptsPerExpectedOutcomePerSweep
        $attemptsForJobThisRun = 0
        while ($attemptsForJobThisRun -lt $attemptBudget) {
            $missingKeys = @($expectedKeys | Where-Object { -not $coverage.capturedKeys.Contains($_) })
            if ($missingKeys.Count -eq 0) { break }
            $attemptNumber = if ($coverage.attemptsByJob.ContainsKey($jobKey)) {
                $coverage.attemptsByJob[$jobKey] + 1
            } else { 1 }
            $jobDirectoryName = $jobKey -replace '[^A-Za-z0-9._-]', '_'
            $jobDirectory = Join-Path $proofDirectory $jobDirectoryName
            if (-not (Test-Path -LiteralPath $jobDirectory)) {
                New-Item -ItemType Directory -Path $jobDirectory | Out-Null
            }
            $attemptDirectory = Join-Path $jobDirectory "attempt-$attemptNumber"
            while (Test-Path -LiteralPath $attemptDirectory) {
                $attemptNumber++
                $attemptDirectory = Join-Path $jobDirectory "attempt-$attemptNumber"
            }

            $resultStatus = 'capture-error'
            $classifiedReviewKey = $null
            $reportEvidence = $null
            $summaryEvidence = $null
            $failure = $null
            try {
                & $entryPoint `
                    -Target Retail `
                    -Scenario ActorObservation `
                    -ActorPlanRoot $planDirectory `
                    -ActorCorpusRoot $corpusDirectory `
                    -ActorCaptureJobKey $jobKey `
                    -ActorOracleSeedRoot $seedDirectory `
                    -ActorOraclePluginDll $pluginPath `
                    -ActorSaveFixture $savePath `
                    -ActorGameRoot $gameDirectory `
                    -OutputRoot $attemptDirectory `
                    -TimeoutSeconds $TimeoutSeconds | Out-Null
                $summaryPath = Join-Path $attemptDirectory 'background-capture-summary.json'
                $summary = Get-Content -Raw -LiteralPath $summaryPath | ConvertFrom-Json
                $reportPath = [string]$summary.actorObservation.report
                $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
                if ([string]$report.captureJob.captureJobKey -cne $jobKey -or
                    [string]$report.status -cne [string]$summary.actorObservation.status) {
                    throw 'Queue capture report identity differs from its requested job or summary.'
                }
                $resultStatus = [string]$report.status
                $classifiedReviewKey = if ([string]::IsNullOrWhiteSpace([string]$report.classifiedReviewKey)) {
                    $null
                } else { [string]$report.classifiedReviewKey }
                if ($null -ne $classifiedReviewKey -and -not $expectedKeys.Contains($classifiedReviewKey)) {
                    throw "Queue capture classified an undeclared review key: $classifiedReviewKey"
                }
                $reportEvidence = [ordered]@{ path = $reportPath; sha256 = Get-LowerSha256 $reportPath }
                $summaryEvidence = [ordered]@{ path = $summaryPath; sha256 = Get-LowerSha256 $summaryPath }
            }
            catch {
                $resultStatus = 'capture-error'
                $failure = $_.Exception.Message
            }

            $event = [ordered]@{
                schema = 'nikami-fnv-actor-observation-queue-event/v1'
                sequence = $coverage.attempts + 1
                observedAt = (Get-Date).ToUniversalTime().ToString('o')
                captureJobKey = $jobKey
                recordType = [string]$job.recordType
                attemptNumber = $attemptNumber
                expectedReviewKeys = @($expectedKeys | Sort-Object)
                resultStatus = $resultStatus
                classifiedReviewKey = $classifiedReviewKey
                report = $reportEvidence
                backgroundCaptureSummary = $summaryEvidence
                proofDirectory = $attemptDirectory
                error = $failure
            }
            $eventObject = [pscustomobject]$event
            Add-CoverageEvent $coverage $eventObject
            Add-JsonLine $eventsPath $eventObject
            $attemptsForJobThisRun++
            $attemptsThisRun++

            if (($attemptsThisRun % [int]$queuePolicy.checkpointEveryAttempts) -eq 0) {
                [void](Write-CoverageCheckpoint $checkpointDirectory $coverage.attempts $coverage `
                    $planManifestHash $corpusManifestHash)
            }
            if ($resultStatus -ceq 'capture-error') {
                if (-not [bool]$queuePolicy.continueAfterCaptureFailure) { throw $failure }
                break
            }
        }
    }
    $checkpointPath = Write-CoverageCheckpoint $checkpointDirectory $coverage.attempts $coverage `
        $planManifestHash $corpusManifestHash
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-actor-observation-queue-run/v1'
        status = if ($coverage.pendingOutcomes -eq 0) {
            'retail-reference-coverage-complete'
        } else { 'retail-reference-coverage-pending' }
        queueRoot = $queueDirectory
        selectedBaseJobs = $selectedJobs.Count
        attemptsThisRun = $attemptsThisRun
        checkpoint = $checkpointPath
        coverage = [ordered]@{
            baseJobs = $coverage.baseJobs
            baseJobsComplete = $coverage.baseJobsComplete
            baseJobsPending = $coverage.baseJobsPending
            expectedOutcomes = $coverage.expectedOutcomes
            capturedOutcomes = $coverage.capturedOutcomes
            pendingOutcomes = $coverage.pendingOutcomes
            attempts = $coverage.attempts
            unclassifiedAttempts = $coverage.unclassifiedAttempts
            incompleteAppearanceAttempts = $coverage.incompleteAppearanceAttempts
            captureErrors = $coverage.captureErrors
        }
        parityVerdictStatus = 'not-evaluated-by-retail-reference-queue'
    } | ConvertTo-Json -Depth 8
}
finally {
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
