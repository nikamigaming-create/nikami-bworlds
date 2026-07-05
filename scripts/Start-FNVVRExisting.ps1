param(
    [switch]$DryRun,
    [switch]$NoPause = $true,
    [string]$FnvRoot = "",
    [string[]]$RunArgs = @()
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")

$FnvRoot = Resolve-NikamiPath `
    -ParameterValue $FnvRoot `
    -EnvName "NIKAMI_FNV_ROOT" `
    -ConfigName "fnvRoot" `
    -Required `
    -Description "calibrated FNV/OpenMW VR root"

$launcher = Join-Path $FnvRoot "run_vr.bat"
$exe = Join-Path $FnvRoot "openmw-source\MSVC2022_64\Release\openmw_vr.exe"

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Missing FNV VR launcher: $launcher"
}

if (-not (Test-Path -LiteralPath $exe)) {
    throw "Missing existing OpenMW VR binary: $exe"
}

$argsList = New-Object System.Collections.Generic.List[string]
if ($DryRun) {
    $argsList.Add("dryrun")
}
if ($NoPause) {
    $argsList.Add("nopause")
}
foreach ($arg in $RunArgs) {
    if (-not [string]::IsNullOrWhiteSpace($arg)) {
        $argsList.Add($arg)
    }
}

Push-Location $FnvRoot
try {
    & cmd /c run_vr.bat @($argsList.ToArray())
    if ($LASTEXITCODE -ne 0) {
        throw "run_vr.bat exited with code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
