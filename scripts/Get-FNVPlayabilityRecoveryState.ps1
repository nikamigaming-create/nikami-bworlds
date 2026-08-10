param(
    [string]$OutputPath = "",
    [string]$SourceSearchRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$planPath = Join-Path $repoRoot "catalog\fnv-playability-recovery-plan.json"
$pathsPath = Join-Path $repoRoot "local\paths.json"
$worldViewerPaths = Join-Path $PSScriptRoot "WorldViewerPaths.ps1"

if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Missing recovery plan: $planPath"
}
if ([string]::IsNullOrWhiteSpace($SourceSearchRoot)) {
    $SourceSearchRoot = Split-Path -Parent $repoRoot
}
$SourceSearchRoot = [IO.Path]::GetFullPath($SourceSearchRoot)

function Invoke-GitText {
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $text = & git -C $Repository @Arguments 2>$null
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "git failed in ${Repository}: git $($Arguments -join ' ')"
    }
    return [pscustomobject]@{ ExitCode = $code; Text = @($text) }
}

function Get-JsonIfPresent {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { return [pscustomobject]@{ parseError = $_.Exception.Message } }
}

function Get-RelevantEnvironment {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($scope in @("Process", "User", "Machine")) {
        $target = [EnvironmentVariableTarget]::$scope
        $variables = [Environment]::GetEnvironmentVariables($target)
        foreach ($name in @($variables.Keys | Sort-Object)) {
            if ([string]$name -match '^(OPENMW|NIKAMI)_') {
                $rows.Add([ordered]@{
                    scope = $scope.ToLowerInvariant()
                    name = [string]$name
                    value = [string]$variables[$name]
                }) | Out-Null
            }
        }
    }
    return @($rows.ToArray())
}

$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$paths = Get-JsonIfPresent -Path $pathsPath
. $worldViewerPaths
$declaredCurrentRuntime = [IO.Path]::GetFullPath((Get-NikamiOpenMWRuntimeRoot))
$configuredRuntimeValue = if ($null -ne $paths -and $null -ne $paths.PSObject.Properties["openmwBinaryRoot"]) {
    [string]$paths.openmwBinaryRoot
} else { "" }
$configuredSourceValue = if ($null -ne $paths -and $null -ne $paths.PSObject.Properties["openmwSource"]) {
    [string]$paths.openmwSource
} else { "" }

$sourceRepositories = [Collections.Generic.List[string]]::new()
foreach ($directory in @(Get-ChildItem -LiteralPath $SourceSearchRoot -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($directory.Name -notmatch '(?i)openmw') { continue }
    if (Test-Path -LiteralPath (Join-Path $directory.FullName ".git")) {
        $sourceRepositories.Add($directory.FullName) | Out-Null
    }
}
foreach ($directory in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "local\labs") -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($directory.Name -notmatch '(?i)openmw') { continue }
    if (Test-Path -LiteralPath (Join-Path $directory.FullName ".git")) {
        $sourceRepositories.Add($directory.FullName) | Out-Null
    }
}
$sourceRepositories = @($sourceRepositories.ToArray() | Sort-Object -Unique)

$candidateRows = [Collections.Generic.List[object]]::new()
foreach ($candidate in @($plan.candidateLadder)) {
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($repository in $sourceRepositories) {
        $exists = Invoke-GitText -Repository $repository -Arguments @("cat-file", "-e", "$($candidate.commit)^{commit}") -AllowFailure
        if ($exists.ExitCode -ne 0) { continue }
        $identity = Invoke-GitText -Repository $repository -Arguments @(
            "show", "-s", "--format=%H%x09%T%x09%P%x09%aI%x09%s", [string]$candidate.commit)
        $parts = ([string]$identity.Text[0]) -split "`t", 5
        $head = Invoke-GitText -Repository $repository -Arguments @("rev-parse", "HEAD")
        $status = Invoke-GitText -Repository $repository -Arguments @("status", "--porcelain=v1")
        $matches.Add([ordered]@{
            repository = $repository
            commit = $parts[0]
            tree = $parts[1]
            parents = @($parts[2] -split ' ' | Where-Object { $_ })
            authoredAt = $parts[3]
            subject = $parts[4]
            checkedOut = ([string]$head.Text[0]) -eq $parts[0]
            worktreeClean = $status.Text.Count -eq 0
            worktreeChangeCount = $status.Text.Count
        }) | Out-Null
    }
    $candidateRows.Add([ordered]@{
        requestedCommit = [string]$candidate.commit
        label = [string]$candidate.label
        found = $matches.Count -gt 0
        repositories = @($matches.ToArray())
    }) | Out-Null
}

$runtimeRows = [Collections.Generic.List[object]]::new()
$runtimeRoot = Join-Path $repoRoot "local"
foreach ($directory in @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter "openmw-*" -Force)) {
    $binary = Join-Path $directory.FullName "openmw.exe"
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { continue }
    $binaryItem = Get-Item -LiteralPath $binary
    $manifestPath = Join-Path $directory.FullName "runtime-manifest.json"
    $manifest = Get-JsonIfPresent -Path $manifestPath
    $resources = Join-Path $directory.FullName "resources"
    $runtimeRows.Add([ordered]@{
        name = $directory.Name
        path = $directory.FullName
        binary = [ordered]@{
            path = $binary
            bytes = $binaryItem.Length
            modifiedAt = $binaryItem.LastWriteTimeUtc.ToString("o")
            sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        resources = [ordered]@{
            path = $resources
            exists = Test-Path -LiteralPath $resources -PathType Container
            fileCount = if (Test-Path -LiteralPath $resources -PathType Container) {
                @(Get-ChildItem -LiteralPath $resources -File -Recurse -ErrorAction SilentlyContinue).Count
            } else { 0 }
        }
        dllCount = @(Get-ChildItem -LiteralPath $directory.FullName -File -Filter "*.dll").Count
        manifestPath = if (Test-Path -LiteralPath $manifestPath) { $manifestPath } else { $null }
        manifest = $manifest
        manifestPresent = $null -ne $manifest
    }) | Out-Null
}

$environment = @(Get-RelevantEnvironment)
$forbiddenEnvironment = [Collections.Generic.List[object]]::new()
foreach ($row in $environment) {
    foreach ($prefix in @($plan.normalRunForbidden.environmentPrefixes)) {
        if ($row.name.StartsWith([string]$prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $forbiddenEnvironment.Add($row) | Out-Null
            break
        }
    }
}

$findings = [Collections.Generic.List[object]]::new()
function Add-Finding([string]$Code, [string]$Severity, [string]$Message) {
    $script:findings.Add([ordered]@{ code = $Code; severity = $Severity; message = $Message }) | Out-Null
}
if (-not (Test-Path -LiteralPath $declaredCurrentRuntime -PathType Container)) {
    Add-Finding "declared-current-runtime-missing" "error" "WorldViewerPaths declares a current runtime that does not exist: $declaredCurrentRuntime"
}
if (-not [string]::IsNullOrWhiteSpace($configuredRuntimeValue) -and
    -not (Test-Path -LiteralPath $configuredRuntimeValue -PathType Container)) {
    Add-Finding "configured-runtime-missing" "error" "local/paths.json openmwBinaryRoot does not exist: $configuredRuntimeValue"
}
if (-not [string]::IsNullOrWhiteSpace($configuredSourceValue) -and
    -not (Test-Path -LiteralPath $configuredSourceValue -PathType Container)) {
    Add-Finding "configured-source-missing" "error" "local/paths.json openmwSource does not exist: $configuredSourceValue"
}
if ($forbiddenEnvironment.Count -gt 0) {
    Add-Finding "proof-environment-present" "error" "One or more proof/forced variables are present in the effective environment inventory."
}
foreach ($candidate in $candidateRows) {
    if (-not $candidate.found) {
        Add-Finding "candidate-commit-missing" "error" "Candidate commit $($candidate.requestedCommit) was not found under $SourceSearchRoot or local/labs."
    }
}
$unmanifested = @($runtimeRows | Where-Object { -not $_.manifestPresent })
if ($unmanifested.Count -gt 0) {
    Add-Finding "unmanifested-runtimes" "warning" "$($unmanifested.Count) packaged OpenMW runtimes have openmw.exe but no runtime-manifest.json."
}

$result = [ordered]@{
    schema = "nikami-fnv-playability-recovery-state/v1"
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    readOnly = $true
    plan = [ordered]@{
        path = $planPath
        sha256 = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    launcher = [ordered]@{
        declaredCurrentRuntime = $declaredCurrentRuntime
        declaredCurrentRuntimeExists = Test-Path -LiteralPath $declaredCurrentRuntime -PathType Container
        configuredRuntime = $configuredRuntimeValue
        configuredRuntimeExists = -not [string]::IsNullOrWhiteSpace($configuredRuntimeValue) -and
            (Test-Path -LiteralPath $configuredRuntimeValue -PathType Container)
        configuredSource = $configuredSourceValue
        configuredSourceExists = -not [string]::IsNullOrWhiteSpace($configuredSourceValue) -and
            (Test-Path -LiteralPath $configuredSourceValue -PathType Container)
    }
    candidates = @($candidateRows.ToArray())
    runtimes = @($runtimeRows.ToArray() | Sort-Object { $_.binary.modifiedAt })
    environment = $environment
    forbiddenEnvironment = @($forbiddenEnvironment.ToArray())
    findings = @($findings.ToArray())
    status = if (@($findings | Where-Object { $_.severity -eq "error" }).Count -eq 0) { "pass" } else { "fail" }
}

$json = $result | ConvertTo-Json -Depth 20
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $resolvedOutput) {
        throw "Refusing to overwrite recovery state: $resolvedOutput"
    }
    $parent = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($resolvedOutput, $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
}
$json
