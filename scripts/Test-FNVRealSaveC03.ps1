[CmdletBinding()]
param(
    [string]$WorldsRoot = "D:\\code\\nikami-worlds",
    [string]$EngineRoot = "D:\\code\\nikami-openmw-save330-integrated",
    [string]$TestOutputPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c03-fast-travel-resolution-tests-20260802-161000.txt",
    [string]$ValidationPath = "D:\\code\\nikami-worlds\\run\\fnv-real-save-campaign\\c03-fast-travel-resolution-validation.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$TestOutputPath = [IO.Path]::GetFullPath($TestOutputPath)
$ValidationPath = [IO.Path]::GetFullPath($ValidationPath)
$TestSourcePath = Join-Path $EngineRoot "apps\components_tests\openmw\testfnvfasttravel.cpp"
$CMakePath = Join-Path $EngineRoot "apps\components_tests\CMakeLists.txt"
$TestExecutablePath = Join-Path $EngineRoot "MSVC2022_64\RelWithDebInfo\components-tests.exe"

if (Test-Path -LiteralPath $ValidationPath) {
    throw "Refusing to overwrite an existing C03 validation artifact: $ValidationPath"
}

$checks = [Collections.Generic.List[object]]::new()
$script:c03AllPass = $true

function Add-C03Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Detail
    )
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
    if (-not $Passed) { $script:c03AllPass = $false }
}

function Get-C03Artifact {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        bytes = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$testOutput = if (Test-Path -LiteralPath $TestOutputPath -PathType Leaf) { Get-Content -Raw -LiteralPath $TestOutputPath } else { '' }
$testSource = if (Test-Path -LiteralPath $TestSourcePath -PathType Leaf) { Get-Content -Raw -LiteralPath $TestSourcePath } else { '' }
$testArtifact = Get-C03Artifact $TestOutputPath
$sourceArtifact = Get-C03Artifact $TestSourcePath
$cmakeArtifact = Get-C03Artifact $CMakePath
$executableArtifact = Get-C03Artifact $TestExecutablePath

Add-C03Check 'Focused components test output is retained' ($null -ne $testArtifact) $testArtifact
Add-C03Check 'Focused components test executable is retained' ($null -ne $executableArtifact) $executableArtifact
Add-C03Check 'Production resolver source is included in components-tests' `
    ($testSource.Length -gt 0 -and $cmakeArtifact -ne $null -and
     (Get-Content -Raw -LiteralPath $CMakePath) -match '\.\./openmw/mwworld/fnvfasttravel\.cpp' -and
     (Get-Content -Raw -LiteralPath $CMakePath) -match 'openmw/testfnvfasttravel\.cpp') `
    $CMakePath

$requiredTests = @(
    'FNVFastTravel.ResolvesDiscoveredExteriorDestinationAndSameCell',
    'FNVFastTravel.RejectsHiddenAndVisibleOnlyMarkers',
    'FNVFastTravel.RejectsInvalidMarkerAndMissingDestination',
    'FNVFastTravel.RejectsInteriorAndWorldspaceMismatch',
    'FNVFastTravel.RejectsDisabledGlobalTravelAndNearbyEnemies',
    'FNVFastTravel.RejectsNoTravelCurrentCellAndWorld'
)
$missingTests = @($requiredTests | Where-Object { $testOutput -notmatch [regex]::Escape("[       OK ] $($_)") })
Add-C03Check 'All required fast-travel test cases passed' `
    ($missingTests.Count -eq 0 -and $testOutput -match '\[  PASSED  \] 6 tests\.') `
    ([ordered]@{ expected = $requiredTests; missing = $missingTests })

$requiredReasons = @(
    'That location is not a valid map marker.',
    'You have not discovered that location.',
    'Fast travel is currently unavailable from this location.',
    'You cannot fast travel when enemies are nearby.',
    'You cannot fast travel from this location.',
    'You cannot fast travel from this worldspace.',
    'You cannot fast travel to that worldspace.',
    'The map marker has no authored exterior destination.',
    'The map marker destination has no authored worldspace.'
)
$missingReasons = @($requiredReasons | Where-Object { $testSource -notmatch [regex]::Escape($_) })
Add-C03Check 'Every required retail-shaped rejection reason is asserted in source' `
    ($missingReasons.Count -eq 0) `
    ([ordered]@{ expected = $requiredReasons; missing = $missingReasons })

Add-C03Check 'No focused test failure or skipped test is present' `
    ($testOutput -notmatch '(?m)^\[  FAILED  \]' -and $testOutput -notmatch '(?i)skipped') `
    $TestOutputPath

$validation = [ordered]@{
    schema = 'nikami-fnv-real-save-c03-validation/v1'
    status = if ($script:c03AllPass) { 'pass' } else { 'fail' }
    objective = 'Unit-test the production Fallout fast-travel resolver across the complete C03 matrix.'
    source = [ordered]@{
        testSource = $sourceArtifact
        cmake = $cmakeArtifact
        testExecutable = $executableArtifact
        testOutput = $testArtifact
    }
    requiredMatrix = [ordered]@{
        cases = $requiredTests
        retailShapedReasons = $requiredReasons
    }
    checks = @($checks)
}
[IO.File]::WriteAllText($ValidationPath, ($validation | ConvertTo-Json -Depth 16) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

if (-not $script:c03AllPass) {
    throw "C03 validation failed. See $ValidationPath"
}

[pscustomobject][ordered]@{
    schema = $validation.schema
    status = $validation.status
    checks = $checks.Count
    passedChecks = @($checks | Where-Object { $_.passed }).Count
    validationArtifact = Get-C03Artifact $ValidationPath
    testOutput = $testArtifact
}
