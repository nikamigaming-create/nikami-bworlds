param(
    [string]$SweepRoot = "run/proof-harness-sweeps",
    [string]$ExperimentRoot = "patches/openmw/experiments",
    [string]$CandidateRoot = "D:/code/vulkanOpenMW",
    [string]$CandidateCatalog = "catalog/local-openmw-candidates.json",
    [string]$UpstreamRepo = "https://gitlab.com/OpenMW/openmw.git",
    [string]$RunDir = "",
    [switch]$LatestAny,
    [switch]$NoNetwork,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Convert-ToForwardSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return ($Path -replace "\\", "/")
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-TextArray($Value) {
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text)
}

function Read-JsonLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    return @(Get-Content -LiteralPath $Path | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object {
        $_ | ConvertFrom-Json
    })
}

function ConvertTo-ProcessArgumentString([string[]]$Arguments) {
    return @($Arguments | ForEach-Object {
        $argument = [string]$_
        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        }
        else {
            $argument
        }
    }) -join " "
}

function Invoke-GitText([string[]]$Arguments) {
    try {
        $gitCommand = Get-Command git -ErrorAction Stop
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $gitCommand.Source
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Arguments = ConvertTo-ProcessArgumentString $Arguments

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        [void]$process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            return @()
        }
        return @($stdout -split "\r?\n" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | ForEach-Object { [string]$_ })
    }
    catch {
        return @()
    }
}

function Select-LatestSweep([string]$Root, [bool]$AllowLatestAny) {
    $resolvedRoot = Resolve-RepoRelativePath $Root
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        return $null
    }

    $runs = @(Get-ChildItem -LiteralPath $resolvedRoot -Directory | Sort-Object Name -Descending)
    $fallback = $null
    foreach ($run in $runs) {
        $ledger = Join-Path $run.FullName "actor-proof-status.jsonl"
        if (-not (Test-Path -LiteralPath $ledger -PathType Leaf)) {
            continue
        }
        if ($null -eq $fallback) {
            $fallback = $run.FullName
        }
        if ($AllowLatestAny) {
            return $run.FullName
        }
        $rows = @(Read-JsonLines $ledger)
        $hasDiagnosticRigRows = @($rows | Where-Object {
            $rigStatus = [string](Get-PropertyValue $_ "rigPoseStatus")
            -not [string]::IsNullOrWhiteSpace($rigStatus) -and
            -not [string]::Equals($rigStatus, "missing", [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        $hasScreenshotImage = @($rows | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ "image"))
        }).Count -gt 0
        if ($hasDiagnosticRigRows -and $hasScreenshotImage) {
            return $run.FullName
        }
    }
    return $fallback
}

function Get-SweepRows([string]$RunDir) {
    if ([string]::IsNullOrWhiteSpace($RunDir)) {
        return @()
    }

    $ledger = Join-Path $RunDir "actor-proof-status.jsonl"
    return @(Read-JsonLines $ledger | ForEach-Object {
        $proofStatus = [string](Get-PropertyValue $_ "proofStatus")
        if ([string]::IsNullOrWhiteSpace($proofStatus)) {
            $proofStatus = [string](Get-PropertyValue $_ "status")
        }
        $skinningMode = [string](Get-PropertyValue $_ "skinningMode")
        if ([string]::IsNullOrWhiteSpace($skinningMode)) {
            $skinningMode = [string](Get-PropertyValue $_ "effectiveSkinningMode")
        }

        [pscustomobject][ordered]@{
            worldId = [string](Get-PropertyValue $_ "worldId")
            skinningMode = $skinningMode
            proofStatus = $proofStatus
            runtimeStatus = [string](Get-PropertyValue $_ "runtimeStatus")
            rigPoseStatus = [string](Get-PropertyValue $_ "rigPoseStatus")
            partTelemetryStatus = [string](Get-PropertyValue $_ "partTelemetryStatus")
            renderLiveStatus = [string](Get-PropertyValue $_ "renderLiveStatus")
            faceAttachmentStatus = [string](Get-PropertyValue $_ "faceAttachmentStatus")
            actorBasisStatus = [string](Get-PropertyValue $_ "actorBasisStatus")
            rootAttachmentStatus = [string](Get-PropertyValue $_ "rootAttachmentStatus")
            visualReviewStatus = [string](Get-PropertyValue $_ "visualReviewStatus")
            failureClasses = @(Get-TextArray (Get-PropertyValue $_ "failureClasses")) -join ","
            warningClasses = @(Get-TextArray (Get-PropertyValue $_ "warningClasses")) -join ","
            image = Convert-ToForwardSlash ([string](Get-PropertyValue $_ "image"))
            manifest = Convert-ToForwardSlash ([string](Get-PropertyValue $_ "manifest"))
        }
    })
}

function Get-ExperimentRows([string]$Root) {
    $resolvedRoot = Resolve-RepoRelativePath $Root
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $resolvedRoot -File -Filter "*.patch" | Sort-Object Name | ForEach-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw
        $subject = ""
        if ($text -match "(?m)^Subject:\s*(?<subject>.+)$") {
            $subject = $Matches.subject.Trim()
        }
        $status = "experiment"
        if ($_.Name -match "\.failed\.patch$") {
            $status = "failed"
        }
        elseif ($text -match "(?m)^Status:\s*(?<status>.+)$") {
            $status = $Matches.status.Trim()
        }
        $runs = @([regex]::Matches($text, "run/proof-harness-sweeps/[0-9]{8}-[0-9]{6}") |
            ForEach-Object { $_.Value } |
            Sort-Object -Unique)

        [pscustomobject][ordered]@{
            file = $_.Name
            status = $status
            subject = $subject
            evidenceRuns = $runs -join ","
        }
    })
}

function Get-CandidateRepoRows([string]$Root) {
    $resolvedRoot = Resolve-RepoRelativePath $Root
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        return @()
    }

    $repos = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath (Join-Path $resolvedRoot ".git")) {
        $repos.Add((Get-Item -LiteralPath $resolvedRoot)) | Out-Null
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Force)) {
        if (Test-Path -LiteralPath (Join-Path $child.FullName ".git")) {
            $repos.Add($child) | Out-Null
        }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($repo in @($repos.ToArray())) {
        $path = [string]$repo.FullName
        $branch = (Invoke-GitText -Arguments @("-C", $path, "rev-parse", "--abbrev-ref", "HEAD") | Select-Object -First 1)
        $head = (Invoke-GitText -Arguments @("-C", $path, "log", "-1", "--oneline", "--decorate") | Select-Object -First 1)
        $matches = @(Invoke-GitText -Arguments @(
            "-C", $path,
            "log",
            "--oneline",
            "--decorate",
            "--all",
            "--regexp-ignore-case",
            "--grep", "FNV",
            "--grep", "FO3",
            "--grep", "Fallout",
            "--grep", "actor",
            "--grep", "RigGeometry",
            "--grep", "skinning",
            "--grep", "truth",
            "--grep", "proof",
            "--grep", "FaceGen",
            "-12"
        ))

        $rows.Add([pscustomobject][ordered]@{
            repo = [string]$repo.Name
            path = Convert-ToForwardSlash $path
            branch = if ($branch) { [string]$branch } else { "" }
            head = if ($head) { [string]$head } else { "" }
            candidateCommitCount = $matches.Count
            candidateCommits = @($matches)
        }) | Out-Null
    }

    return @($rows.ToArray() | Sort-Object @{ Expression = "candidateCommitCount"; Descending = $true }, repo)
}

function Get-CandidateCatalogRows([string]$Path) {
    $resolvedPath = Resolve-RepoRelativePath $Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return @()
    }

    $catalog = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -ne 1) {
        return @()
    }

    return @($catalog.repos | ForEach-Object {
        $commits = @(Get-TextArray (Get-PropertyValue $_ "candidateCommits"))
        [pscustomobject][ordered]@{
            repo = [string](Get-PropertyValue $_ "repo")
            path = Convert-ToForwardSlash ([string](Get-PropertyValue $_ "path"))
            branch = [string](Get-PropertyValue $_ "branch")
            head = [string](Get-PropertyValue $_ "head")
            candidateCommitCount = $commits.Count
            candidateCommits = @($commits)
            source = "catalog"
            notes = [string](Get-PropertyValue $_ "notes")
        }
    } | Sort-Object @{ Expression = "candidateCommitCount"; Descending = $true }, repo)
}

function Get-UpstreamBranchSummary([string]$Repo, [bool]$SkipNetwork) {
    if ($SkipNetwork) {
        return [pscustomobject][ordered]@{
            repo = $Repo
            checked = $false
            branchCount = 0
            matchingBranches = @()
            note = "skipped by -NoNetwork"
        }
    }

    $heads = @(Invoke-GitText -Arguments @("ls-remote", "--heads", $Repo))
    $branches = @($heads | ForEach-Object {
        if ($_ -match "refs/heads/(?<name>.+)$") {
            $Matches.name
        }
    })
    if ($branches.Count -eq 0) {
        return [pscustomobject][ordered]@{
            repo = $Repo
            checked = $true
            branchCount = 0
            matchingBranches = @()
            note = "git ls-remote returned no rows from this runner"
        }
    }
    $matching = @($branches | Where-Object {
        $_ -match "(?i)(fallout|fnv|fo3|esm4|actor|starfield|oblivion|skyrim)"
    })

    [pscustomobject][ordered]@{
        repo = $Repo
        checked = $true
        branchCount = $branches.Count
        matchingBranches = @($matching)
        note = if ($matching.Count -eq 0) { "no obvious public actor/ESM4 side branch found" } else { "matching branch names found" }
    }
}

$latestSweep = if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
    Resolve-RepoRelativePath $RunDir
} else {
    Select-LatestSweep $SweepRoot ([bool]$LatestAny)
}
$sweepRows = @(Get-SweepRows $latestSweep)
$experimentRows = @(Get-ExperimentRows $ExperimentRoot)
$candidateRows = @(Get-CandidateRepoRows $CandidateRoot)
if ($candidateRows.Count -gt 0 -and @($candidateRows | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.branch) -or
    -not [string]::IsNullOrWhiteSpace([string]$_.head) -or
    [int]$_.candidateCommitCount -gt 0
}).Count -eq 0) {
    $candidateRows = @(Get-CandidateRepoRows $CandidateRoot)
}
if ($candidateRows.Count -eq 0 -or @($candidateRows | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.branch) -or
    -not [string]::IsNullOrWhiteSpace([string]$_.head) -or
    [int]$_.candidateCommitCount -gt 0
}).Count -eq 0) {
    $catalogRows = @(Get-CandidateCatalogRows $CandidateCatalog)
    if ($catalogRows.Count -gt 0) {
        $candidateRows = $catalogRows
    }
}
$upstream = Get-UpstreamBranchSummary $UpstreamRepo ([bool]$NoNetwork)

$rowsNeedingWork = @($sweepRows | Where-Object { -not [string]::Equals($_.proofStatus, "pass", [StringComparison]::OrdinalIgnoreCase) })
$visualGaps = @($sweepRows | Where-Object { [string]::Equals($_.visualReviewStatus, "missing", [StringComparison]::OrdinalIgnoreCase) })
$hasHeadRenderGap = @($sweepRows | Where-Object {
    [string](Get-PropertyValue $_ "failureClasses") -match "(^|,)actor-head-render-gap(,|$)"
}).Count -gt 0
$hasBasisLargeDelta = @($sweepRows | Where-Object {
    [string](Get-PropertyValue $_ "warningClasses") -match "(^|,)actor-basis-large-delta(,|$)"
}).Count -gt 0
$basisModeExperimentFailed = @($experimentRows | Where-Object {
    [string](Get-PropertyValue $_ "file") -eq "0013-esm4-native-callback-basis-mode.patch" -and
    [string](Get-PropertyValue $_ "status") -match "(?i)failed"
}).Count -gt 0
$nextAction = if ($null -eq $latestSweep) {
    "Run Invoke-ProofHarnessSweep.ps1 for the current slice before patching."
}
elseif ($visualGaps.Count -gt 0) {
    "Add exact-manifest visual review rows, then refresh the sweep summary."
}
elseif ($hasHeadRenderGap) {
    "Apply the quarantined face rig render-buffer audit, rebuild non-VR OpenMW, then rerun FO3/FNV current actor slices before any behavior patch."
}
elseif ($basisModeExperimentFailed) {
    "Native callback basis modes failed; next source slice should target actor root/world transform or part attachment basis."
}
elseif ($hasBasisLargeDelta) {
    "Actor basis callback deltas are now proven in the visible path; next source slice should test a narrow raw/basis behavior patch behind an env gate."
}
elseif ($rowsNeedingWork.Count -gt 0) {
    "Keep failed experiments quarantined; next source slice should target actor root/bind evidence, not visual promotion."
}
else {
    "All latest actor proof rows pass; verify Morrowind baseline before promotion."
}

$report = [pscustomobject][ordered]@{
    schema = "nikami-actor-proof-armory-v1"
    latestSweep = Convert-ToForwardSlash $latestSweep
    latestSweepSelection = if ($LatestAny) { "latest-any" } elseif (-not [string]::IsNullOrWhiteSpace($RunDir)) { "explicit" } else { "latest-diagnostic" }
    latestSweepRows = @($sweepRows | Sort-Object worldId, skinningMode)
    quarantinedExperiments = @($experimentRows)
    localCandidateRepos = @($candidateRows)
    upstreamBranches = $upstream
    nextAction = $nextAction
}

if (@($report.localCandidateRepos).Count -gt 0 -and @($report.localCandidateRepos | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.branch) -or
    -not [string]::IsNullOrWhiteSpace([string]$_.head) -or
    [int]$_.candidateCommitCount -gt 0
}).Count -eq 0) {
    $report.localCandidateRepos = @(Get-CandidateRepoRows $CandidateRoot)
    if (@($report.localCandidateRepos | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.branch) -or
        -not [string]::IsNullOrWhiteSpace([string]$_.head) -or
        [int]$_.candidateCommitCount -gt 0
    }).Count -eq 0) {
        $catalogRows = @(Get-CandidateCatalogRows $CandidateCatalog)
        if ($catalogRows.Count -gt 0) {
            $report.localCandidateRepos = $catalogRows
        }
    }
}

if ($Json) {
    $report | ConvertTo-Json -Depth 12
    return
}

Write-Host "Actor proof armory"
if ($latestSweep) {
    Write-Host "Latest sweep: $(Convert-ToForwardSlash $latestSweep) [$($report.latestSweepSelection)]"
    @($report.latestSweepRows) |
        Format-Table worldId, skinningMode, proofStatus, runtimeStatus, rigPoseStatus, partTelemetryStatus, renderLiveStatus, faceAttachmentStatus, actorBasisStatus, rootAttachmentStatus, visualReviewStatus -AutoSize
}
else {
    Write-Host "Latest sweep: none"
}

Write-Host ""
Write-Host "Quarantined experiments"
@($report.quarantinedExperiments) |
    Format-Table file, status, evidenceRuns -AutoSize

Write-Host ""
Write-Host "Local candidate repos"
@($report.localCandidateRepos | Select-Object -First 8) |
    Format-Table repo, branch, candidateCommitCount, head, source -AutoSize

Write-Host ""
Write-Host "Upstream branch signal"
[pscustomobject][ordered]@{
    repo = $report.upstreamBranches.repo
    checked = $report.upstreamBranches.checked
    branchCount = $report.upstreamBranches.branchCount
    matchingBranches = @($report.upstreamBranches.matchingBranches) -join ","
    note = $report.upstreamBranches.note
} | Format-Table -AutoSize

Write-Host ""
Write-Host "Next action: $nextAction"
