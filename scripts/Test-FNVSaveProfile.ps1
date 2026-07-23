Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "FNVSaveProfile.ps1")

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Write-Bytes([IO.BinaryWriter]$Writer, [byte[]]$Bytes) {
    $Writer.Write($Bytes, 0, $Bytes.Length)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("nikami-fnv-save-profile-" + [guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    $savePath = Join-Path $testRoot "fixture.fos"
    $stream = [IO.File]::Create($savePath)
    $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::ASCII, $false)
    try {
        Write-Bytes $writer ([Text.Encoding]::ASCII.GetBytes("FO3SAVEGAME"))
        $writer.Write([uint32]15)
        $writer.Write([uint32]27)
        $writer.Write([byte]0x7c)
        $writer.Write([uint32]1)
        $writer.Write([byte]0x7c)
        $writer.Write([uint32]1)
        $writer.Write([byte]0x7c)
        Write-Bytes $writer ([byte[]](0, 0, 0))
        $writer.Write([byte]27)

        $masters = @("FalloutNV.esm", "TribalPack.esm")
        $masterBytes = [IO.MemoryStream]::new()
        $masterWriter = [IO.BinaryWriter]::new($masterBytes, [Text.Encoding]::ASCII, $true)
        try {
            $masterWriter.Write([byte]$masters.Count)
            $masterWriter.Write([byte]0x7c)
            foreach ($master in $masters) {
                $encoded = [Text.Encoding]::ASCII.GetBytes($master)
                $masterWriter.Write([uint16]$encoded.Length)
                $masterWriter.Write([byte]0x7c)
                Write-Bytes $masterWriter $encoded
                $masterWriter.Write([byte]0x7c)
            }
            $masterWriter.Flush()
            $writer.Write([uint32]$masterBytes.Length)
            Write-Bytes $writer $masterBytes.ToArray()
        }
        finally {
            $masterWriter.Dispose()
            $masterBytes.Dispose()
        }
    }
    finally {
        $writer.Dispose()
    }

    $parsed = @(Get-FNVSaveMasterNames -SavePath $savePath)
    Assert-Contract ($parsed.Count -eq 2) "Synthetic save did not return exactly two masters."
    Assert-Contract ($parsed[0] -ceq "FalloutNV.esm") "Synthetic save lost the base master."
    Assert-Contract ($parsed[1] -ceq "TribalPack.esm") "Synthetic save lost master order."

    $sourceProfile = Join-Path $testRoot "source"
    $destinationProfile = Join-Path $testRoot "ordered"
    [IO.Directory]::CreateDirectory($sourceProfile) | Out-Null
    [IO.File]::WriteAllLines(
        (Join-Path $sourceProfile "openmw.cfg"),
        @(
            "replace=content",
            "data=C:/Games/Fallout New Vegas/Data",
            "content=FalloutNV.esm",
            "content=GunRunnersArsenal.esm",
            "content=TribalPack.esm",
            "encoding=win1252"
        ),
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $sourceProfile "settings.cfg"),
        "[Video]`nresolution x = 2048`n",
        [Text.UTF8Encoding]::new($false))

    $result = New-FNVSaveOrderedProfile `
        -SavePath $savePath `
        -SourceProfileDirectory $sourceProfile `
        -DestinationProfileDirectory $destinationProfile
    $orderedContent = @([IO.File]::ReadAllLines((Join-Path $destinationProfile "openmw.cfg")) |
        Where-Object { $_ -match '^content=' })
    Assert-Contract ($orderedContent.Count -eq 2) "Save-ordered profile retained an extra plugin."
    Assert-Contract ($orderedContent[0] -ceq "content=FalloutNV.esm") "Save-ordered profile moved the base master."
    Assert-Contract ($orderedContent[1] -ceq "content=TribalPack.esm") "Save-ordered profile did not preserve save order."
    Assert-Contract `
        -Condition (Test-Path -LiteralPath (Join-Path $result.ProfileDirectory "settings.cfg") -PathType Leaf) `
        -Message "Save-ordered profile did not copy settings.cfg."

    Write-Host "FNV save-profile contract passed."
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
