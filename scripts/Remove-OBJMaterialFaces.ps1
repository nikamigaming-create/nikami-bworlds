[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InputPath,
    [Parameter(Mandatory)] [string]$OutputPath,
    [Parameter(Mandatory)] [string]$Material
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $InputPath)) { throw "Input OBJ not found: $InputPath" }
if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to overwrite: $OutputPath" }

$reader = [System.IO.StreamReader]::new($InputPath)
$writer = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.UTF8Encoding]::new($false))
$activeMaterial = ""
$removedFaces = 0
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ($line.StartsWith("usemtl ")) {
            $activeMaterial = $line.Substring(7).Trim()
        }
        if ($activeMaterial -eq $Material -and $line.StartsWith("f ")) {
            $removedFaces++
            continue
        }
        $writer.WriteLine($line)
    }
} finally {
    $reader.Dispose()
    $writer.Dispose()
}
if ($removedFaces -eq 0) { throw "No faces found for material '$Material'." }
[ordered]@{input=$InputPath; output=$OutputPath; material=$Material; removedFaces=$removedFaces} | ConvertTo-Json
