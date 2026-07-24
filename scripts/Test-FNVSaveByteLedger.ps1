param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'FNVSaveByteLedger.psm1'
$failures = [Collections.Generic.List[string]]::new()
$caseCount = 0

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures.Add($Message) | Out-Null }
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-RangeSha256([byte[]]$Bytes, [int]$Offset, [int]$Length) {
    $range = New-Object 'System.Byte[]' $Length
    [Array]::Copy($Bytes, $Offset, $range, 0, $Length)
    return Get-BytesSha256 $range
}

function Copy-LedgerManifest([object]$Manifest) {
    return $Manifest | ConvertTo-Json -Depth 32 | ConvertFrom-Json
}

function Write-LedgerManifest([object]$Manifest, [string]$Name) {
    $path = Join-Path $script:temporaryRoot $Name
    $json = $Manifest | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return $path
}

function New-Range(
    [string]$Id,
    [int64]$Offset,
    [int64]$Length,
    [string]$Status,
    [AllowNull()][object]$Blocker,
    [string]$Sha256
) {
    return [pscustomobject][ordered]@{
        id = $Id
        offset = $Offset
        length = $Length
        status = $Status
        blocker = $Blocker
        provenance = [pscustomobject][ordered]@{
            producer = 'deterministic-fixture-parser'
            basis = 'fixture-layout-v1'
        }
        sha256 = $Sha256
    }
}

function Assert-InvalidLike([object]$Manifest, [string]$Pattern, [string]$Name) {
    ++$script:caseCount
    $path = Write-LedgerManifest $Manifest "$Name.json"
    $result = Test-FNVSaveByteLedger -FosPath $script:fixturePath -ManifestPath $path
    $joined = @($result.failures) -join "`n"
    if ($result.valid -or $joined -notmatch $Pattern) {
        $script:failures.Add("$Name expected failure /$Pattern/ and received valid=$($result.valid): $joined") | Out-Null
    }
    $caught = $null
    try { Assert-FNVSaveByteLedger -FosPath $script:fixturePath -ManifestPath $path | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught) {
        $script:failures.Add("$Name Assert-FNVSaveByteLedger did not throw") | Out-Null
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "nikami-fnv-save-byte-ledger-$PID-$([Guid]::NewGuid().ToString('N'))")
$save330Checked = $false
$save330Invocation = $null
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $modulePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-Contract ($parseErrors.Count -eq 0) 'FNV save byte ledger module has PowerShell parse errors.'
    Import-Module $modulePath -Force

    $fixtureBytes = New-Object 'System.Byte[]' 64
    for ($index = 0; $index -lt $fixtureBytes.Length; ++$index) {
        $fixtureBytes[$index] = [byte](($index * 37 + 11) % 256)
    }
    $fixturePath = Join-Path $temporaryRoot 'deterministic.fos'
    [IO.File]::WriteAllBytes($fixturePath, $fixtureBytes)

    $valid = [pscustomobject][ordered]@{
        schema = 'nikami-fnv-save-byte-ledger/v1'
        complete = $true
        source = [pscustomobject][ordered]@{
            bytes = [int64]$fixtureBytes.Length
            sha256 = Get-BytesSha256 $fixtureBytes
        }
        ranges = @(
            New-Range 'header' 0 8 'mapped' $null (Get-RangeSha256 $fixtureBytes 0 8)
            New-Range 'tables' 8 24 'mapped' $null (Get-RangeSha256 $fixtureBytes 8 24)
            New-Range 'body' 32 32 'mapped' $null (Get-RangeSha256 $fixtureBytes 32 32)
        )
    }

    ++$caseCount
    $validPath = Write-LedgerManifest $valid 'valid.json'
    $validResult = Assert-FNVSaveByteLedger -FosPath $fixturePath -ManifestPath $validPath
    Assert-Contract $validResult.valid 'Valid deterministic ledger did not pass.'
    Assert-Contract $validResult.complete 'Valid deterministic ledger lost complete=true.'
    Assert-Contract ($validResult.fileBytes -eq 64) 'Valid deterministic ledger reported the wrong file size.'
    Assert-Contract ($validResult.rangeCount -eq 3) 'Valid deterministic ledger reported the wrong range count.'
    Assert-Contract ($validResult.mappedBytes -eq 64 -and $validResult.partialBytes -eq 0 -and
        $validResult.uncoveredBytes -eq 0) 'Valid deterministic ledger reported the wrong status byte totals.'

    ++$caseCount
    $objectResult = Assert-FNVSaveByteLedger -FosPath $fixturePath -Manifest $valid
    Assert-Contract $objectResult.valid 'In-memory manifest parameter set did not pass.'

    $case = Copy-LedgerManifest $valid
    $case.source.bytes = 63
    Assert-InvalidLike $case '/source/bytes.*declares 63.*contains 64' 'source-size-mismatch'

    $case = Copy-LedgerManifest $valid
    $case.source.sha256 = '0' * 64
    Assert-InvalidLike $case '/source/sha256.*hashes to' 'source-hash-mismatch'

    $case = Copy-LedgerManifest $valid
    $case.ranges[0].length = 7
    $case.ranges[0].sha256 = Get-RangeSha256 $fixtureBytes 0 7
    Assert-InvalidLike $case 'gap \[7,8\)' 'range-gap'

    $case = Copy-LedgerManifest $valid
    $case.ranges[0].length = 9
    $case.ranges[0].sha256 = Get-RangeSha256 $fixtureBytes 0 9
    Assert-InvalidLike $case 'overlap starts at 8.*ends at 9' 'range-overlap'

    $case = Copy-LedgerManifest $valid
    $case.ranges[1].sha256 = 'f' * 64
    Assert-InvalidLike $case '/ranges/1/sha256.*bytes hash to' 'range-hash-mismatch'

    $case = Copy-LedgerManifest $valid
    $case.ranges[1].status = 'parsed-validated'
    Assert-InvalidLike $case '/ranges/1/status.*mapped, partial, or uncovered' 'range-status-closed-set'

    $case = Copy-LedgerManifest $valid
    $case.ranges[0].PSObject.Properties.Remove('blocker')
    Assert-InvalidLike $case '/ranges/0/blocker.*property is required' 'range-requires-blocker-property'

    $case = Copy-LedgerManifest $valid
    $case.ranges[1].status = 'partial'
    $case.ranges[1].blocker = 'record payload only partly decoded'
    Assert-InvalidLike $case '/complete.*cannot be true.*partial or uncovered' 'partial-cannot-complete'

    $case = Copy-LedgerManifest $valid
    $case.ranges[1].status = 'uncovered'
    $case.ranges[1].blocker = 'global tables and change forms not implemented'
    Assert-InvalidLike $case '/complete.*cannot be true.*partial or uncovered' 'uncovered-cannot-complete'

    ++$caseCount
    $honestlyIncomplete = Copy-LedgerManifest $valid
    $honestlyIncomplete.complete = $false
    $honestlyIncomplete.ranges[2].status = 'uncovered'
    $honestlyIncomplete.ranges[2].blocker = 'global tables and change forms not implemented'
    $incompleteResult = Assert-FNVSaveByteLedger -FosPath $fixturePath -Manifest $honestlyIncomplete
    Assert-Contract (-not $incompleteResult.complete -and $incompleteResult.uncoveredBytes -eq 32) `
        'Honest incomplete coverage did not pass conservatively.'

    $case = Copy-LedgerManifest $valid
    $case.ranges[0].status = 'partial'
    $case.ranges[0].blocker = $null
    $case.complete = $false
    Assert-InvalidLike $case '/ranges/0/blocker.*non-empty string' 'partial-requires-blocker'

    $case = Copy-LedgerManifest $valid
    $case.ranges[0].PSObject.Properties.Remove('provenance')
    Assert-InvalidLike $case '/ranges/0/provenance.*must be an object' 'range-requires-provenance'

    $case = Copy-LedgerManifest $valid
    $case.ranges[0].PSObject.Properties.Remove('sha256')
    Assert-InvalidLike $case '/ranges/0/sha256.*64 hexadecimal' 'range-requires-hash'

    $case = Copy-LedgerManifest $valid
    $case.ranges[2].offset = 65
    Assert-InvalidLike $case 'exceeds file size 64' 'range-out-of-bounds'

    $case = Copy-LedgerManifest $valid
    $case.ranges[2].id = $case.ranges[1].id
    Assert-InvalidLike $case 'duplicates range id' 'range-id-unique'

    $save330Path = 'C:\Users\nbrys\OneDrive\Documents\My Games\FalloutNV\Saves\Save 330     Goodsprings  00 16 45.fos'
    if ([IO.File]::Exists($save330Path)) {
        ++$caseCount
        $save330ExpectedBytes = [int64]3395328
        $save330ExpectedSha256 = '07DBDD2D7C4ABE3160628E5463A9603A40F4271042C1DA1B89F1C4A4F7DBD81F'
        $save330Manifest = [pscustomobject][ordered]@{
            schema = 'nikami-fnv-save-byte-ledger/v1'
            complete = $false
            source = [pscustomobject][ordered]@{
                bytes = $save330ExpectedBytes
                sha256 = $save330ExpectedSha256
            }
            ranges = @(
                New-Range 'save330-awaiting-parser-export' 0 $save330ExpectedBytes 'uncovered' `
                    'parser-exported range manifest not supplied to this smoke invocation' $save330ExpectedSha256
            )
        }
        $save330ManifestPath = Write-LedgerManifest $save330Manifest 'save330-exact-smoke.json'
        $save330Invocation = "Assert-FNVSaveByteLedger -FosPath '$save330Path' -ManifestPath '$save330ManifestPath'"
        $save330Result = Assert-FNVSaveByteLedger -FosPath $save330Path -ManifestPath $save330ManifestPath
        Assert-Contract ($save330Result.fileBytes -eq $save330ExpectedBytes) `
            'Exact Save330 invocation did not preserve the pinned file size.'
        Assert-Contract ([string]::Equals($save330Result.fileSha256, $save330ExpectedSha256,
                [StringComparison]::OrdinalIgnoreCase)) `
            'Exact Save330 invocation did not preserve the pinned SHA-256.'
        Assert-Contract (-not $save330Result.complete -and $save330Result.uncoveredBytes -eq $save330ExpectedBytes) `
            'Exact Save330 smoke invocation did not remain honestly uncovered.'
        $save330Checked = $true
    }
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    throw "FNV save byte ledger tests failed:`n - $($failures -join "`n - ")"
}

[pscustomobject][ordered]@{
    cases = $caseCount
    status = 'pass'
    save330Checked = $save330Checked
    save330Invocation = $save330Invocation
}
