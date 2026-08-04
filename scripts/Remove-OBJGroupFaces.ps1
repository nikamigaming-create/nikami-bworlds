[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$InputPath,
    [Parameter(Mandatory)] [string]$OutputPath,
    [Parameter(Mandatory)] [string]$GroupPattern
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $InputPath)) { throw "Input OBJ not found: $InputPath" }
if (Test-Path -LiteralPath $OutputPath) { throw "Refusing to overwrite: $OutputPath" }
$reader = [System.IO.StreamReader]::new($InputPath)
$writer = [System.IO.StreamWriter]::new($OutputPath, $false, [System.Text.UTF8Encoding]::new($false))
$skipGroup = $false
$removedFaces = 0
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ($line.StartsWith("g ")) {
            $skipGroup = $line.Substring(2) -match $GroupPattern
        }
        if ($skipGroup -and $line.StartsWith("f ")) {
            $removedFaces++
            continue
        }
        $writer.WriteLine($line)
    }
} finally {
    $reader.Dispose()
    $writer.Dispose()
}
if ($removedFaces -eq 0) { throw "No faces matched group pattern '$GroupPattern'." }
[ordered]@{input=$InputPath; output=$OutputPath; groupPattern=$GroupPattern; removedFaces=$removedFaces} | ConvertTo-Json
