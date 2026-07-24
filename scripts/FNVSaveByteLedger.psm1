Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FNVSaveByteLedgerSchema = 'nikami-fnv-save-byte-ledger/v1'
$script:FNVSaveByteLedgerSha256Pattern = '^[0-9A-Fa-f]{64}$'
$script:FNVSaveByteLedgerStatuses = @('mapped', 'partial', 'uncovered')

function Get-FNVSaveByteLedgerProperty {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-FNVSaveByteLedgerHasProperty {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) { return $false }
    if ($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Test-FNVSaveByteLedgerInteger {
    param([AllowNull()][object]$Value)

    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Add-FNVSaveByteLedgerFailure {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $Failures.Add("${Path}: $Message") | Out-Null
}

function ConvertTo-FNVSaveByteLedgerSha256 {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    return [BitConverter]::ToString($Bytes).Replace('-', '').ToLowerInvariant()
}

function Get-FNVSaveByteLedgerStreamSha256 {
    param(
        [Parameter(Mandatory)]
        [IO.Stream]$Stream
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return ConvertTo-FNVSaveByteLedgerSha256 $sha256.ComputeHash($Stream)
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-FNVSaveByteLedgerRangeSha256 {
    param(
        [Parameter(Mandatory)]
        [IO.Stream]$Stream,

        [Parameter(Mandatory)]
        [int64]$Offset,

        [Parameter(Mandatory)]
        [int64]$Length
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object 'System.Byte[]' 65536
    $empty = [byte[]]@()
    try {
        $Stream.Position = $Offset
        $remaining = $Length
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min([int64]$buffer.Length, $remaining)
            $read = $Stream.Read($buffer, 0, $requested)
            if ($read -le 0) {
                throw "unexpected end of file at offset $($Stream.Position)"
            }
            [void]$sha256.TransformBlock($buffer, 0, $read, $buffer, 0)
            $remaining -= $read
        }
        [void]$sha256.TransformFinalBlock($empty, 0, 0)
        return ConvertTo-FNVSaveByteLedgerSha256 $sha256.Hash
    }
    finally {
        $sha256.Dispose()
    }
}

function New-FNVSaveByteLedgerResult {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Failures,

        [AllowNull()]
        [object]$Complete,

        [AllowNull()]
        [string]$FosPath,

        [AllowNull()]
        [string]$ManifestPath,

        [int64]$FileBytes = 0,

        [string]$FileSha256 = '',

        [int]$RangeCount = 0,

        [int64]$MappedBytes = 0,

        [int64]$PartialBytes = 0,

        [int64]$UncoveredBytes = 0
    )

    return [pscustomobject][ordered]@{
        schema = $script:FNVSaveByteLedgerSchema
        valid = $Failures.Count -eq 0
        complete = $Complete
        fosPath = $FosPath
        manifestPath = $ManifestPath
        fileBytes = $FileBytes
        fileSha256 = $FileSha256
        rangeCount = $RangeCount
        mappedBytes = $MappedBytes
        partialBytes = $PartialBytes
        uncoveredBytes = $UncoveredBytes
        failures = [string[]]$Failures.ToArray()
    }
}

function Test-FNVSaveByteLedger {
    [CmdletBinding(DefaultParameterSetName = 'ManifestPath')]
    param(
        [Parameter(Mandatory)]
        [string]$FosPath,

        [Parameter(Mandatory, ParameterSetName = 'ManifestPath')]
        [string]$ManifestPath,

        [Parameter(Mandatory, ParameterSetName = 'ManifestObject')]
        [object]$Manifest
    )

    $failures = [Collections.Generic.List[string]]::new()
    $resolvedFosPath = $null
    $resolvedManifestPath = $null
    $manifestValue = $null
    $complete = $null
    $fileBytes = [int64]0
    $fileSha256 = ''
    $mappedBytes = [int64]0
    $partialBytes = [int64]0
    $uncoveredBytes = [int64]0
    $normalizedRanges = [Collections.Generic.List[object]]::new()

    try {
        $resolvedFosPath = [IO.Path]::GetFullPath($FosPath)
    }
    catch {
        Add-FNVSaveByteLedgerFailure $failures '/fos' "path is invalid: $($_.Exception.Message)"
    }
    if ($null -ne $resolvedFosPath) {
        if (-not [IO.File]::Exists($resolvedFosPath)) {
            Add-FNVSaveByteLedgerFailure $failures '/fos' "file does not exist: $resolvedFosPath"
        }
        elseif ([IO.Path]::GetExtension($resolvedFosPath) -ine '.fos') {
            Add-FNVSaveByteLedgerFailure $failures '/fos' 'must have the .fos extension'
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'ManifestPath') {
        try {
            $resolvedManifestPath = [IO.Path]::GetFullPath($ManifestPath)
            if (-not [IO.File]::Exists($resolvedManifestPath)) {
                Add-FNVSaveByteLedgerFailure $failures '/manifest' "file does not exist: $resolvedManifestPath"
            }
            else {
                try {
                    $manifestValue = Get-Content -LiteralPath $resolvedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                }
                catch {
                    Add-FNVSaveByteLedgerFailure $failures '/manifest' "is not valid JSON: $($_.Exception.Message)"
                }
            }
        }
        catch {
            Add-FNVSaveByteLedgerFailure $failures '/manifest' "path is invalid: $($_.Exception.Message)"
        }
    }
    else {
        $manifestValue = $Manifest
    }

    if ($null -eq $manifestValue) {
        Add-FNVSaveByteLedgerFailure $failures '/manifest' 'is missing or null'
    }
    else {
        $schema = Get-FNVSaveByteLedgerProperty $manifestValue 'schema'
        if ($schema -isnot [string] -or $schema -cne $script:FNVSaveByteLedgerSchema) {
            Add-FNVSaveByteLedgerFailure $failures '/schema' "must equal '$($script:FNVSaveByteLedgerSchema)'"
        }

        $completeValue = Get-FNVSaveByteLedgerProperty $manifestValue 'complete'
        if ($completeValue -isnot [bool]) {
            Add-FNVSaveByteLedgerFailure $failures '/complete' 'must be a JSON boolean'
        }
        else {
            $complete = [bool]$completeValue
        }

        $source = Get-FNVSaveByteLedgerProperty $manifestValue 'source'
        if ($null -eq $source) {
            Add-FNVSaveByteLedgerFailure $failures '/source' 'is missing or null'
        }
        else {
            $declaredBytes = Get-FNVSaveByteLedgerProperty $source 'bytes'
            if (-not (Test-FNVSaveByteLedgerInteger $declaredBytes)) {
                Add-FNVSaveByteLedgerFailure $failures '/source/bytes' 'must be a non-negative JSON integer'
            }
            else {
                try {
                    $declaredBytes = [int64]$declaredBytes
                    if ($declaredBytes -lt 0) {
                        Add-FNVSaveByteLedgerFailure $failures '/source/bytes' 'must be non-negative'
                    }
                }
                catch {
                    Add-FNVSaveByteLedgerFailure $failures '/source/bytes' 'cannot be represented as a signed 64-bit integer'
                }
            }

            $declaredSha256 = Get-FNVSaveByteLedgerProperty $source 'sha256'
            if ($declaredSha256 -isnot [string] -or $declaredSha256 -notmatch $script:FNVSaveByteLedgerSha256Pattern) {
                Add-FNVSaveByteLedgerFailure $failures '/source/sha256' 'must contain exactly 64 hexadecimal SHA-256 characters'
            }
        }

        if (-not (Test-FNVSaveByteLedgerHasProperty $manifestValue 'ranges')) {
            Add-FNVSaveByteLedgerFailure $failures '/ranges' 'is missing'
            $rangeValues = @()
        }
        else {
            $rangeProperty = Get-FNVSaveByteLedgerProperty $manifestValue 'ranges'
            if ($null -eq $rangeProperty -or $rangeProperty -is [string]) {
                Add-FNVSaveByteLedgerFailure $failures '/ranges' 'must be a non-empty JSON array'
                $rangeValues = @()
            }
            else {
                $rangeValues = @($rangeProperty)
                if ($rangeValues.Count -eq 0) {
                    Add-FNVSaveByteLedgerFailure $failures '/ranges' 'must be a non-empty JSON array'
                }
            }
        }

        $rangeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        for ($index = 0; $index -lt $rangeValues.Count; ++$index) {
            $range = $rangeValues[$index]
            $rangePath = "/ranges/$index"
            if ($null -eq $range) {
                Add-FNVSaveByteLedgerFailure $failures $rangePath 'must be an object'
                continue
            }

            $id = Get-FNVSaveByteLedgerProperty $range 'id'
            if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$id)) {
                Add-FNVSaveByteLedgerFailure $failures "$rangePath/id" 'must be a non-empty string'
                $id = "range-$index"
            }
            elseif (-not $rangeIds.Add([string]$id)) {
                Add-FNVSaveByteLedgerFailure $failures "$rangePath/id" "duplicates range id '$id'"
            }

            $offsetValue = Get-FNVSaveByteLedgerProperty $range 'offset'
            $lengthValue = Get-FNVSaveByteLedgerProperty $range 'length'
            $offset = [int64]-1
            $length = [int64]-1
            $numericRange = $true
            if (-not (Test-FNVSaveByteLedgerInteger $offsetValue)) {
                Add-FNVSaveByteLedgerFailure $failures "$rangePath/offset" 'must be a non-negative JSON integer'
                $numericRange = $false
            }
            else {
                try { $offset = [int64]$offsetValue } catch { $numericRange = $false }
                if (-not $numericRange -or $offset -lt 0) {
                    Add-FNVSaveByteLedgerFailure $failures "$rangePath/offset" 'must be a non-negative signed 64-bit integer'
                    $numericRange = $false
                }
            }
            if (-not (Test-FNVSaveByteLedgerInteger $lengthValue)) {
                Add-FNVSaveByteLedgerFailure $failures "$rangePath/length" 'must be a positive JSON integer'
                $numericRange = $false
            }
            else {
                try { $length = [int64]$lengthValue } catch { $numericRange = $false }
                if (-not $numericRange -or $length -le 0) {
                    Add-FNVSaveByteLedgerFailure $failures "$rangePath/length" 'must be a positive signed 64-bit integer'
                    $numericRange = $false
                }
            }

            $status = Get-FNVSaveByteLedgerProperty $range 'status'
            if ($status -isnot [string] -or $script:FNVSaveByteLedgerStatuses -cnotcontains [string]$status) {
                Add-FNVSaveByteLedgerFailure $failures "$rangePath/status" 'must be exactly mapped, partial, or uncovered'
                $status = ''
            }

            if (-not (Test-FNVSaveByteLedgerHasProperty $range 'blocker')) {
                Add-FNVSaveByteLedgerFailure $failures "$rangePath/blocker" 'property is required'
            }
            $blocker = Get-FNVSaveByteLedgerProperty $range 'blocker'
            if ($status -ceq 'mapped') {
                if ($null -ne $blocker) {
                    Add-FNVSaveByteLedgerFailure $failures "$rangePath/blocker" 'must be null when status is mapped'
                }
            }
            elseif ($status -ceq 'partial' -or $status -ceq 'uncovered') {
                if ($blocker -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$blocker)) {
                    Add-FNVSaveByteLedgerFailure $failures "$rangePath/blocker" "must be a non-empty string when status is $status"
                }
            }

            $provenance = Get-FNVSaveByteLedgerProperty $range 'provenance'
            if ($null -eq $provenance -or $provenance -is [string] -or $provenance.GetType().IsPrimitive -or
                $provenance -is [Collections.IEnumerable] -and $provenance -isnot [Collections.IDictionary]) {
                Add-FNVSaveByteLedgerFailure $failures "$rangePath/provenance" 'must be an object'
            }
            else {
                foreach ($name in @('producer', 'basis')) {
                    $provenanceValue = Get-FNVSaveByteLedgerProperty $provenance $name
                    if ($provenanceValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$provenanceValue)) {
                        Add-FNVSaveByteLedgerFailure $failures "$rangePath/provenance/$name" 'must be a non-empty string'
                    }
                }
            }

            $rangeSha256 = Get-FNVSaveByteLedgerProperty $range 'sha256'
            if ($rangeSha256 -isnot [string] -or $rangeSha256 -notmatch $script:FNVSaveByteLedgerSha256Pattern) {
                Add-FNVSaveByteLedgerFailure $failures "$rangePath/sha256" 'must contain exactly 64 hexadecimal SHA-256 characters'
                $rangeSha256 = ''
            }

            if ($numericRange) {
                $normalizedRanges.Add([pscustomobject][ordered]@{
                        index = $index
                        id = [string]$id
                        offset = $offset
                        length = $length
                        status = [string]$status
                        sha256 = [string]$rangeSha256
                    }) | Out-Null
                switch -CaseSensitive ($status) {
                    'mapped' { $mappedBytes += $length }
                    'partial' { $partialBytes += $length }
                    'uncovered' { $uncoveredBytes += $length }
                }
            }
        }

        if ($complete -eq $true) {
            $notMapped = @($normalizedRanges | Where-Object { $_.status -ceq 'partial' -or $_.status -ceq 'uncovered' })
            if ($notMapped.Count -gt 0) {
                Add-FNVSaveByteLedgerFailure $failures '/complete' `
                    'cannot be true while any byte range is partial or uncovered'
            }
        }
    }

    $stream = $null
    if ($null -ne $resolvedFosPath -and [IO.File]::Exists($resolvedFosPath)) {
        try {
            $stream = [IO.File]::Open($resolvedFosPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $fileBytes = [int64]$stream.Length
            $fileSha256 = Get-FNVSaveByteLedgerStreamSha256 $stream

            if ($null -ne $manifestValue) {
                $source = Get-FNVSaveByteLedgerProperty $manifestValue 'source'
                $declaredBytes = Get-FNVSaveByteLedgerProperty $source 'bytes'
                if (Test-FNVSaveByteLedgerInteger $declaredBytes) {
                    try {
                        if ([int64]$declaredBytes -ne $fileBytes) {
                            Add-FNVSaveByteLedgerFailure $failures '/source/bytes' `
                                "declares $declaredBytes but the .fos contains $fileBytes bytes"
                        }
                    }
                    catch { }
                }
                $declaredSha256 = Get-FNVSaveByteLedgerProperty $source 'sha256'
                if ($declaredSha256 -is [string] -and $declaredSha256 -match $script:FNVSaveByteLedgerSha256Pattern -and
                    -not [string]::Equals([string]$declaredSha256, $fileSha256, [StringComparison]::OrdinalIgnoreCase)) {
                    Add-FNVSaveByteLedgerFailure $failures '/source/sha256' `
                        "declares $declaredSha256 but the .fos hashes to $fileSha256"
                }
            }

            $orderedRanges = @($normalizedRanges | Sort-Object -Property offset, index)
            $cursor = [int64]0
            foreach ($range in $orderedRanges) {
                $rangePath = "/ranges/$($range.index)"
                if ($range.offset -gt $fileBytes -or $range.length -gt ($fileBytes - [Math]::Min($range.offset, $fileBytes))) {
                    Add-FNVSaveByteLedgerFailure $failures $rangePath `
                        "half-open range [$($range.offset),$($range.offset + $range.length)) exceeds file size $fileBytes"
                    continue
                }

                $end = $range.offset + $range.length
                if ($range.offset -gt $cursor) {
                    Add-FNVSaveByteLedgerFailure $failures '/ranges' `
                        "gap [$cursor,$($range.offset)) leaves bytes unassigned"
                }
                elseif ($range.offset -lt $cursor) {
                    Add-FNVSaveByteLedgerFailure $failures $rangePath `
                        "overlap starts at $($range.offset) before prior coverage ends at $cursor"
                }
                if ($end -gt $cursor) { $cursor = $end }

                if ($range.sha256 -match $script:FNVSaveByteLedgerSha256Pattern) {
                    try {
                        $actualRangeSha256 = Get-FNVSaveByteLedgerRangeSha256 $stream $range.offset $range.length
                        if (-not [string]::Equals($range.sha256, $actualRangeSha256, [StringComparison]::OrdinalIgnoreCase)) {
                            Add-FNVSaveByteLedgerFailure $failures "$rangePath/sha256" `
                                "declares $($range.sha256) but bytes hash to $actualRangeSha256"
                        }
                    }
                    catch {
                        Add-FNVSaveByteLedgerFailure $failures "$rangePath/sha256" `
                            "could not hash range: $($_.Exception.Message)"
                    }
                }
            }
            if ($cursor -lt $fileBytes) {
                Add-FNVSaveByteLedgerFailure $failures '/ranges' `
                    "gap [$cursor,$fileBytes) leaves bytes unassigned"
            }
        }
        catch {
            Add-FNVSaveByteLedgerFailure $failures '/fos' "could not open and hash the file read-only: $($_.Exception.Message)"
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    return New-FNVSaveByteLedgerResult -Failures $failures -Complete $complete -FosPath $resolvedFosPath `
        -ManifestPath $resolvedManifestPath -FileBytes $fileBytes -FileSha256 $fileSha256 `
        -RangeCount $normalizedRanges.Count -MappedBytes $mappedBytes -PartialBytes $partialBytes `
        -UncoveredBytes $uncoveredBytes
}

function Assert-FNVSaveByteLedger {
    [CmdletBinding(DefaultParameterSetName = 'ManifestPath')]
    param(
        [Parameter(Mandatory)]
        [string]$FosPath,

        [Parameter(Mandatory, ParameterSetName = 'ManifestPath')]
        [string]$ManifestPath,

        [Parameter(Mandatory, ParameterSetName = 'ManifestObject')]
        [object]$Manifest
    )

    $arguments = @{ FosPath = $FosPath }
    if ($PSCmdlet.ParameterSetName -eq 'ManifestPath') { $arguments.ManifestPath = $ManifestPath }
    else { $arguments.Manifest = $Manifest }
    $result = Test-FNVSaveByteLedger @arguments
    if (-not $result.valid) {
        throw "FNV save byte ledger validation failed:`n - $(@($result.failures) -join "`n - ")"
    }
    return $result
}

Export-ModuleMember -Function Test-FNVSaveByteLedger, Assert-FNVSaveByteLedger
