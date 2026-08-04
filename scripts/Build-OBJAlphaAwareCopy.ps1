[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InputObj,
    [Parameter(Mandatory)] [string]$InputMtl,
    [Parameter(Mandatory)] [string]$OutputObj,
    [Parameter(Mandatory)] [string]$OutputMtl
)

$ErrorActionPreference = "Stop"
foreach ($path in @($InputObj, $InputMtl)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing input: $path" }
}
foreach ($path in @($OutputObj, $OutputMtl)) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite: $path" }
}
Add-Type -AssemblyName System.Drawing

$mtlRoot = Split-Path $InputMtl -Parent
$lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $InputMtl)
$alphaMaterials = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$current = ""
foreach ($line in $lines) {
    if ($line -match '^newmtl\s+(.+)$') { $current = $Matches[1].Trim(); continue }
    if ($line -notmatch '^map_Kd\s+(.+)$' -or -not $current) { continue }
    $texture = Join-Path $mtlRoot (($Matches[1].Trim()) -replace '/', '\')
    if (-not (Test-Path -LiteralPath $texture)) { continue }
    $bitmap = [System.Drawing.Bitmap]::new($texture)
    try {
        if (($bitmap.PixelFormat -band [System.Drawing.Imaging.PixelFormat]::Alpha) -eq 0 -and
            ($bitmap.PixelFormat -band [System.Drawing.Imaging.PixelFormat]::PAlpha) -eq 0) { continue }
        $hasTransparentPixel = $false
        $stepX = [Math]::Max(1, [int]($bitmap.Width / 48))
        $stepY = [Math]::Max(1, [int]($bitmap.Height / 48))
        for ($y = 0; $y -lt $bitmap.Height -and -not $hasTransparentPixel; $y += $stepY) {
            for ($x = 0; $x -lt $bitmap.Width; $x += $stepX) {
                if ($bitmap.GetPixel($x, $y).A -lt 250) { $hasTransparentPixel = $true; break }
            }
        }
        if ($hasTransparentPixel) { [void]$alphaMaterials.Add($current) }
    } finally { $bitmap.Dispose() }
}

$writer = [System.IO.StreamWriter]::new($OutputMtl, $false, [System.Text.UTF8Encoding]::new($false))
$current = ""
try {
    foreach ($line in $lines) {
        if ($line -match '^newmtl\s+(.+)$') { $current = $Matches[1].Trim() }
        if ($line -match '^d\s+' -and $alphaMaterials.Contains($current)) {
            $writer.WriteLine('d 0.999000')
        } else {
            $writer.WriteLine($line)
        }
    }
} finally { $writer.Dispose() }

$reader = [System.IO.StreamReader]::new($InputObj)
$objWriter = [System.IO.StreamWriter]::new($OutputObj, $false, [System.Text.UTF8Encoding]::new($false))
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ($line.StartsWith('mtllib ')) { $objWriter.WriteLine('mtllib ' + (Split-Path $OutputMtl -Leaf)) }
        else { $objWriter.WriteLine($line) }
    }
} finally {
    $reader.Dispose()
    $objWriter.Dispose()
}
[ordered]@{outputObj=$OutputObj; outputMtl=$OutputMtl; alphaMaterials=$alphaMaterials.Count; names=@($alphaMaterials)} | ConvertTo-Json -Depth 3
