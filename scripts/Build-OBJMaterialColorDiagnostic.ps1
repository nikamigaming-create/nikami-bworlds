[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InputObj,
    [Parameter(Mandatory)] [string]$InputMtl,
    [Parameter(Mandatory)] [string]$OutputObj,
    [Parameter(Mandatory)] [string]$OutputMtl,
    [Parameter(Mandatory)] [string]$Material,
    [string]$Kd = '0.000000 1.000000 0.000000'
)
$ErrorActionPreference = 'Stop'
foreach ($p in @($InputObj,$InputMtl)) { if (-not (Test-Path -LiteralPath $p)) { throw "Missing input: $p" } }
foreach ($p in @($OutputObj,$OutputMtl)) { if (Test-Path -LiteralPath $p) { throw "Refusing to overwrite: $p" } }
$lines = Get-Content -LiteralPath $InputMtl
$writer = [IO.StreamWriter]::new($OutputMtl,$false,[Text.UTF8Encoding]::new($false)); $active=$false; $changed=0
try {
    foreach ($line in $lines) {
        if ($line -match '^newmtl\s+(.+)$') { $active = $Matches[1].Trim() -eq $Material }
        if ($active -and $line -match '^Kd\s+') { $writer.WriteLine('Kd ' + $Kd); $changed++ }
        else { $writer.WriteLine($line) }
    }
} finally { $writer.Dispose() }
if ($changed -ne 1) { throw "Expected one Kd for $Material, changed $changed" }
$reader=[IO.StreamReader]::new($InputObj); $objWriter=[IO.StreamWriter]::new($OutputObj,$false,[Text.UTF8Encoding]::new($false))
try {
    while (($line=$reader.ReadLine()) -ne $null) {
        if ($line.StartsWith('mtllib ')) { $objWriter.WriteLine('mtllib ' + (Split-Path $OutputMtl -Leaf)) }
        else { $objWriter.WriteLine($line) }
    }
} finally { $reader.Dispose(); $objWriter.Dispose() }
[ordered]@{outputObj=$OutputObj; outputMtl=$OutputMtl; material=$Material; kd=$Kd} | ConvertTo-Json
