Set-StrictMode -Version Latest

function Import-FNVGoodspringsActorRoster {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Missing canonical Goodsprings actor roster: $resolved"
    }

    $document = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    if ([string]$document.schema -ne 'nikami-fnv-goodsprings-actor-roster/v1') {
        throw "Unsupported Goodsprings actor roster schema in ${resolved}: $($document.schema)"
    }

    $targets = @($document.targets)
    if ([int]$document.targetCount -ne 37 -or $targets.Count -ne 37) {
        throw "Canonical Goodsprings actor roster must contain exactly 37 targets; found $($targets.Count)."
    }

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $references = [System.Collections.Generic.HashSet[uint32]]::new()
    foreach ($target in $targets) {
        $id = [string]$target.id
        $category = [string]$target.category
        $authoredRef = [string]$target.authoredRef
        $base = [string]$target.base
        if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($category) -or
            $authoredRef -notmatch '^0[xX][0-9a-fA-F]{1,8}$' -or $base -notmatch '^0[xX][0-9a-fA-F]{1,8}$') {
            throw "Invalid canonical Goodsprings roster target: $($target | ConvertTo-Json -Compress)"
        }
        if (-not $ids.Add($id)) {
            throw "Duplicate target id in canonical Goodsprings roster: $id"
        }
        $referenceValue = [Convert]::ToUInt32($authoredRef.Substring(2), 16)
        if (-not $references.Add($referenceValue)) {
            throw "Duplicate authored reference in canonical Goodsprings roster: $authoredRef"
        }
        if ($null -ne $target.enableParent -and
            -not [string]::IsNullOrWhiteSpace([string]$target.enableParent) -and
            [string]$target.enableParent -notmatch '^0[xX][0-9a-fA-F]{1,8}$') {
            throw "Invalid enable parent for canonical Goodsprings target ${id}: $($target.enableParent)"
        }
    }

    return $targets
}
