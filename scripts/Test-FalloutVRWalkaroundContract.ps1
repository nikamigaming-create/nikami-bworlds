param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$launcher = Join-Path $PSScriptRoot "Start-FalloutVRWalkaround.ps1"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message) | Out-Null
    }
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $launcher, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Contract ($parseErrors.Count -eq 0) "Fallout VR walkaround launcher does not parse."

$source = Get-Content -LiteralPath $launcher -Raw
foreach ($required in @(
    'resourcesVersion = Join-Path $resourcesRoot "version"',
    'run/interactive-fallout-vr/{0}/{1}-{2}',
    '"--config", $sessionConfig',
    '"--user-data", $sessionUserData',
    'nikami-fallout-vr-session/v1',
    'executableSha256 = (Get-FileHash',
    '-WorkingDirectory $runtimeRoot'
)) {
    Assert-Contract ($source.Contains($required)) "Walkaround launcher is missing: $required"
}

Assert-Contract ($source -match '"--config", \$doorPreload,\s*\r?\n\s*"--config", \$sessionConfig') `
    "Walkaround launcher does not place its isolated writable config after immutable settings."
Assert-Contract ($source -match 'New-Item -ItemType Directory -Path \$sessionConfig, \$sessionUserData') `
    "Walkaround launcher does not create isolated config and user-data directories."
Assert-Contract ($source.IndexOf('if ($DryRun)') -lt $source.IndexOf('New-Item -ItemType Directory -Path $sessionConfig')) `
    "Walkaround dry runs can mutate the session tree."
Assert-Contract ($source -notmatch 'Set-Content -LiteralPath \(Join-Path \$doorPreload') `
    "Walkaround launcher writes into the shared door-preload config."

if ($failures.Count -gt 0) {
    Write-Host "Fallout VR walkaround contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Fallout VR walkaround contract passed."
