Set-StrictMode -Version Latest

function Read-FNVSaveDelimiter {
    param(
        [Parameter(Mandatory=$true)]
        [System.IO.BinaryReader]$Reader,
        [Parameter(Mandatory=$true)]
        [string]$Description
    )

    if ($Reader.BaseStream.Position -ge $Reader.BaseStream.Length -or $Reader.ReadByte() -ne 0x7c) {
        throw "Invalid native FNV save: missing delimiter after $Description."
    }
}

function Read-FNVSaveBytes {
    param(
        [Parameter(Mandatory=$true)]
        [System.IO.BinaryReader]$Reader,
        [Parameter(Mandatory=$true)]
        [int]$Count,
        [Parameter(Mandatory=$true)]
        [string]$Description
    )

    if ($Count -lt 0 -or $Reader.BaseStream.Length - $Reader.BaseStream.Position -lt $Count) {
        throw "Invalid native FNV save: truncated $Description."
    }
    $bytes = $Reader.ReadBytes($Count)
    if ($bytes.Length -ne $Count) {
        throw "Invalid native FNV save: truncated $Description."
    }
    return $bytes
}

function Get-FNVSaveMasterNames {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SavePath
    )

    $resolvedSave = [IO.Path]::GetFullPath($SavePath)
    if (-not (Test-Path -LiteralPath $resolvedSave -PathType Leaf)) {
        throw "Native FNV save does not exist: $resolvedSave"
    }

    $stream = [IO.File]::Open($resolvedSave, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::ASCII, $false)
    try {
        $magic = [Text.Encoding]::ASCII.GetString((Read-FNVSaveBytes -Reader $reader -Count 11 -Description "magic"))
        if ($magic -cne "FO3SAVEGAME") {
            throw "Invalid native FNV save: expected FO3SAVEGAME magic."
        }

        $headerSize = [uint64]$reader.ReadUInt32()
        $headerBegin = [uint64]$stream.Position
        $headerEnd = $headerBegin + $headerSize
        if ($headerSize -eq 0 -or $headerEnd -gt [uint64]$stream.Length) {
            throw "Invalid native FNV save: truncated header."
        }

        [void]$reader.ReadUInt32()
        Read-FNVSaveDelimiter -Reader $reader -Description "header version"
        $dimensionOrLanguage = $reader.ReadUInt32()
        $stream.Position -= 4
        if ($dimensionOrLanguage -gt 16384) {
            [void](Read-FNVSaveBytes -Reader $reader -Count 64 -Description "language")
            Read-FNVSaveDelimiter -Reader $reader -Description "language"
        }

        $width = [uint64]$reader.ReadUInt32()
        Read-FNVSaveDelimiter -Reader $reader -Description "screenshot width"
        $height = [uint64]$reader.ReadUInt32()
        Read-FNVSaveDelimiter -Reader $reader -Description "screenshot height"
        if ($width -eq 0 -or $height -eq 0 -or $width -gt 16384 -or $height -gt 16384) {
            throw "Invalid native FNV save: invalid screenshot dimensions ${width}x${height}."
        }

        $screenshotBytes = $width * $height * 3
        $postScreenshot = $headerEnd + $screenshotBytes
        if ($postScreenshot + 5 -gt [uint64]$stream.Length) {
            throw "Invalid native FNV save: truncated screenshot or master-table header."
        }
        $stream.Position = [int64]$postScreenshot
        [void]$reader.ReadByte()
        $masterTableSize = [uint64]$reader.ReadUInt32()
        $masterTableBegin = [uint64]$stream.Position
        $masterTableEnd = $masterTableBegin + $masterTableSize
        if ($masterTableSize -eq 0 -or $masterTableEnd -gt [uint64]$stream.Length) {
            throw "Invalid native FNV save: truncated master table."
        }

        $masterCount = [int]$reader.ReadByte()
        if ($masterCount -eq 0) {
            throw "Invalid native FNV save: master table is empty."
        }
        Read-FNVSaveDelimiter -Reader $reader -Description "master count"

        $masters = [Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $masterCount; ++$index) {
            $length = [int]$reader.ReadUInt16()
            Read-FNVSaveDelimiter -Reader $reader -Description "master name length"
            $name = [Text.Encoding]::ASCII.GetString(
                (Read-FNVSaveBytes -Reader $reader -Count $length -Description "master name"))
            if ([string]::IsNullOrWhiteSpace($name) -or $name.IndexOf([char]0) -ge 0) {
                throw "Invalid native FNV save: empty or malformed master name at index $index."
            }
            if ($length -gt 0) {
                Read-FNVSaveDelimiter -Reader $reader -Description "master name"
            }
            $masters.Add($name)
        }
        if ([uint64]$stream.Position -ne $masterTableEnd) {
            throw "Invalid native FNV save: master table contains unaccounted bytes."
        }
        return @($masters)
    }
    finally {
        $reader.Dispose()
    }
}

function New-FNVSaveOrderedProfile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SavePath,
        [Parameter(Mandatory=$true)]
        [string]$SourceProfileDirectory,
        [Parameter(Mandatory=$true)]
        [string]$DestinationProfileDirectory
    )

    $sourceProfile = [IO.Path]::GetFullPath($SourceProfileDirectory)
    $destinationProfile = [IO.Path]::GetFullPath($DestinationProfileDirectory)
    $sourceConfig = Join-Path $sourceProfile "openmw.cfg"
    $sourceSettings = Join-Path $sourceProfile "settings.cfg"
    if (-not (Test-Path -LiteralPath $sourceConfig -PathType Leaf)) {
        throw "Missing generated FNV profile configuration: $sourceConfig"
    }
    if (-not (Test-Path -LiteralPath $sourceSettings -PathType Leaf)) {
        throw "Missing generated FNV profile settings: $sourceSettings"
    }

    $masters = @(Get-FNVSaveMasterNames -SavePath $SavePath)
    $lines = @([IO.File]::ReadAllLines($sourceConfig))
    $available = @($lines | ForEach-Object {
        if ($_ -match '^content=(.+)$') { $Matches[1] }
    })
    foreach ($master in $masters) {
        if (@($available | Where-Object { $_ -ieq $master }).Count -ne 1) {
            throw "Native FNV save requires '$master', but the generated profile does not contain it. Regenerate the profile after installing the required plugin."
        }
    }

    $orderedLines = [Collections.Generic.List[string]]::new()
    $inserted = $false
    foreach ($line in $lines) {
        if ($line -match '^content=') {
            if (-not $inserted) {
                foreach ($master in $masters) {
                    $orderedLines.Add("content=$master")
                }
                $inserted = $true
            }
            continue
        }
        $orderedLines.Add($line)
    }
    if (-not $inserted) {
        throw "Generated FNV profile has no content entries: $sourceConfig"
    }

    [IO.Directory]::CreateDirectory($destinationProfile) | Out-Null
    [IO.File]::WriteAllLines(
        (Join-Path $destinationProfile "openmw.cfg"),
        $orderedLines,
        [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $sourceSettings -Destination (Join-Path $destinationProfile "settings.cfg") -Force

    return [pscustomobject]@{
        ProfileDirectory = $destinationProfile
        Masters = $masters
    }
}
