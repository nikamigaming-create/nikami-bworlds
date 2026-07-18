[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("nikami-fnv-parity-profile-" + [Guid]::NewGuid().ToString("N"))
try {
    $data = Join-Path $temporary "Data"
    $output = Join-Path $temporary "profile/openmw.cfg"
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $generated = & (Join-Path $PSScriptRoot "New-FNVParityProfile.ps1") -DataRoot $data `
        -OutputPath $output -SkipFileValidation
    if ([IO.Path]::GetFullPath($generated) -ne [IO.Path]::GetFullPath($output)) {
        throw "Profile generator returned an unexpected path."
    }
    $lines = @(Get-Content -LiteralPath $output -Encoding UTF8)
    $content = @($lines | Where-Object { $_ -like "content=*" })
    $archives = @($lines | Where-Object { $_ -like "fallback-archive=*" })
    $dataRoots = @($lines | Where-Object { $_ -like "data=*" })
    if ($content.Count -ne 10 -or $archives.Count -ne 21 -or $dataRoots.Count -ne 1) {
        throw "Generated profile does not contain exactly 10 masters, 21 archives, and one retail data root."
    }
    if (($lines -join "`n") -match "FNVR\.esp|Modlists|openmw-config/data") {
        throw "Generated parity profile contains a non-retail overlay."
    }
    if ($content[0] -ne "content=FalloutNV.esm" -or $content[-1] -ne "content=TribalPack.esm") {
        throw "Generated official master order differs from the frozen denominator."
    }
    if ($archives[-1] -ne "fallback-archive=Update.bsa") {
        throw "Generated archive order differs from the frozen denominator."
    }
    Write-Host "FNV pristine parity profile contract passed."
} finally {
    if (Test-Path -LiteralPath $temporary) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporary)
        $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemporary.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $resolvedTemporary) -notlike "nikami-fnv-parity-profile-*") {
            throw "Refusing to remove unexpected test directory: $resolvedTemporary"
        }
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
    }
}
