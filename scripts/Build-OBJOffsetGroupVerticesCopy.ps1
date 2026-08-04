[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InputObj,
    [Parameter(Mandatory)] [string]$OutputObj,
    [Parameter(Mandatory)] [string]$GroupPattern,
    [double]$X = 0.0,
    [double]$Y = 0.0,
    [double]$Z = 0.0
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $InputObj)) { throw "Missing input OBJ: $InputObj" }
if (Test-Path -LiteralPath $OutputObj) { throw "Refusing to overwrite: $OutputObj" }
$culture = [Globalization.CultureInfo]::InvariantCulture
$reader = [IO.StreamReader]::new($InputObj)
$writer = [IO.StreamWriter]::new($OutputObj, $false, [Text.UTF8Encoding]::new($false))
$active = $false
$changed = 0
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ($line.StartsWith('g ') -or $line.StartsWith('o ')) {
            $active = $line.Substring(2) -match $GroupPattern
        }
        if ($active -and $line.StartsWith('v ')) {
            $p = $line.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            if ($p.Count -ge 4) {
                $vx = [double]::Parse($p[1], $culture) + $X
                $vy = [double]::Parse($p[2], $culture) + $Y
                $vz = [double]::Parse($p[3], $culture) + $Z
                $line = 'v {0:F6} {1:F6} {2:F6}' -f $vx,$vy,$vz
                $changed++
            }
        }
        $writer.WriteLine($line)
    }
} finally {
    $reader.Dispose()
    $writer.Dispose()
}
[ordered]@{input=$InputObj; output=$OutputObj; groupPattern=$GroupPattern; changedVertices=$changed; offset=@($X,$Y,$Z)} | ConvertTo-Json
