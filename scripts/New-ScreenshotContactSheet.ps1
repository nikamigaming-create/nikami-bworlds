param(
    [Parameter(Mandatory=$true)]
    [string]$ManifestPath,
    [string]$OutputPath = "",
    [int]$Columns = 3,
    [int]$ThumbnailWidth = 420,
    [int]$LabelHeight = 28,
    [int]$Padding = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Convert-ToForwardSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    return ($Path -replace "\\", "/")
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

$resolvedManifest = Resolve-RepoRelativePath $ManifestPath
if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
    throw "Manifest not found: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
$screenshotEntries = Get-PropertyValue $manifest "screenshots"
if ($null -eq $screenshotEntries) {
    $evidence = Get-PropertyValue $manifest "evidence"
    $screenshotEntries = Get-PropertyValue $evidence "screenshots"
}
$screenshotPaths = @($screenshotEntries | ForEach-Object {
    [string](Get-PropertyValue $_ "path")
} | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf)
})
if ($screenshotPaths.Count -eq 0) {
    throw "Manifest has no readable screenshots: $ManifestPath"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $resolvedManifest) "contact-sheet.png"
}
$resolvedOutput = Resolve-RepoRelativePath $OutputPath
$outputDir = Split-Path -Parent $resolvedOutput
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

Add-Type -AssemblyName System.Drawing

$columnsToUse = [Math]::Max(1, $Columns)
$rowsToUse = [int][Math]::Ceiling($screenshotPaths.Count / [double]$columnsToUse)
$loadedImages = New-Object System.Collections.Generic.List[object]
try {
    foreach ($path in $screenshotPaths) {
        $image = [System.Drawing.Image]::FromFile($path)
        $scale = $ThumbnailWidth / [double]$image.Width
        $thumbHeight = [int][Math]::Round($image.Height * $scale)
        $loadedImages.Add([pscustomobject][ordered]@{
            path = $path
            image = $image
            width = [int]$ThumbnailWidth
            height = $thumbHeight
        }) | Out-Null
    }

    $cellWidth = $ThumbnailWidth + ($Padding * 2)
    $cellHeight = (@($loadedImages.ToArray()) | ForEach-Object { [int]$_.height } | Measure-Object -Maximum).Maximum + $LabelHeight + ($Padding * 2)
    $sheetWidth = $columnsToUse * $cellWidth
    $sheetHeight = $rowsToUse * $cellHeight
    $bitmap = [System.Drawing.Bitmap]::new($sheetWidth, $sheetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::FromArgb(245, 247, 250))
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $font = [System.Drawing.Font]::new("Segoe UI", 10)
            $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(28, 31, 35))
            $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(190, 195, 200))
            try {
                for ($i = 0; $i -lt $loadedImages.Count; ++$i) {
                    $entry = $loadedImages[$i]
                    $column = $i % $columnsToUse
                    $row = [int][Math]::Floor($i / [double]$columnsToUse)
                    $x = ($column * $cellWidth) + $Padding
                    $y = ($row * $cellHeight) + $Padding
                    $graphics.DrawImage($entry.image, $x, $y, $entry.width, $entry.height)
                    $graphics.DrawRectangle($pen, $x, $y, $entry.width, $entry.height)
                    $label = "{0}: {1}" -f ($i + 1), (Split-Path -Leaf $entry.path)
                    $graphics.DrawString($label, $font, $brush, [System.Drawing.RectangleF]::new($x, $y + $entry.height + 4, $entry.width, $LabelHeight))
                }
            }
            finally {
                $pen.Dispose()
                $brush.Dispose()
                $font.Dispose()
            }
        }
        finally {
            $graphics.Dispose()
        }
        $bitmap.Save($resolvedOutput, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}
finally {
    foreach ($entry in @($loadedImages.ToArray())) {
        $entry.image.Dispose()
    }
}

[pscustomobject][ordered]@{
    schemaVersion = 1
    manifest = Convert-ToForwardSlash $resolvedManifest
    output = Convert-ToForwardSlash $resolvedOutput
    screenshotCount = $screenshotPaths.Count
    columns = $columnsToUse
}
