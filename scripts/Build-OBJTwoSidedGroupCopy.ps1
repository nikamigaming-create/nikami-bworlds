[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InputObj,
    [Parameter(Mandatory)] [string]$OutputObj,
    [Parameter(Mandatory)] [string]$GroupPattern
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $InputObj)) { throw "Missing input OBJ: $InputObj" }
if (Test-Path -LiteralPath $OutputObj) { throw "Refusing to overwrite: $OutputObj" }

$reader = [System.IO.StreamReader]::new($InputObj)
$writer = [System.IO.StreamWriter]::new($OutputObj, $false, [System.Text.UTF8Encoding]::new($false))
$active = $false
$duplicated = 0
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ($line.StartsWith('g ') -or $line.StartsWith('o ')) {
            $active = $line.Substring(2) -match $GroupPattern
        }
        $writer.WriteLine($line)
        if ($active -and $line.StartsWith('f ')) {
            $parts = $line.Substring(2).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
            [array]::Reverse($parts)
            $writer.WriteLine('f ' + ($parts -join ' '))
            $duplicated++
        }
    }
} finally {
    $reader.Dispose()
    $writer.Dispose()
}

[ordered]@{ input=$InputObj; output=$OutputObj; groupPattern=$GroupPattern; duplicatedFaces=$duplicated } | ConvertTo-Json
