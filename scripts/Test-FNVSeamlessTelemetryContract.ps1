[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $repoRoot 'catalog\fnv-seamless-exterior-telemetry.schema.json'
$measurePath = Join-Path $PSScriptRoot 'Measure-FNVSeamlessTelemetry.ps1'
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

Assert-Contract (Test-Path -LiteralPath $schemaPath -PathType Leaf) "Missing seamless telemetry schema."
Assert-Contract (Test-Path -LiteralPath $measurePath -PathType Leaf) "Missing seamless telemetry measurer."

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($measurePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Contract ($parseErrors.Count -eq 0) "Seamless telemetry measurer does not parse."

if (Test-Path -LiteralPath $schemaPath -PathType Leaf) {
    try {
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
        Assert-Contract ([string](Get-PropertyValue $schema '$schema') -eq 'https://json-schema.org/draft/2020-12/schema') `
            "Telemetry schema must declare JSON Schema draft 2020-12."
        $schemaIdentity = Get-PropertyValue (Get-PropertyValue (Get-PropertyValue $schema 'properties') 'schema') 'const'
        Assert-Contract ([string]$schemaIdentity -eq 'nikami-fnv-seamless-exterior-telemetry/v1') `
            "Telemetry schema must lock the event schema identity."
        $actualEvents = @((Get-PropertyValue (Get-PropertyValue (Get-PropertyValue $schema 'properties') 'event') 'enum') |
                ForEach-Object { [string]$_ } | Sort-Object)
        $expectedEvents = @(
            'door-preload', 'fade-request', 'frame-sample', 'grid-change-begin', 'grid-change-end', 'grid-load-plan',
            'loading-scope-enter', 'loading-scope-exit', 'loading-screen-draw', 'scene-transition-begin',
            'scene-transition-end', 'teleport-action-begin', 'teleport-action-end'
        ) | Sort-Object
        Assert-Contract (($actualEvents -join '|') -eq ($expectedEvents -join '|')) `
            "Telemetry schema must expose the complete Phase 0 event vocabulary."
    }
    catch {
        $failures.Add("Unable to validate telemetry schema: $($_.Exception.Message)")
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("nikami-fnv-seamless-telemetry-$([guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $logPath = Join-Path $temporaryRoot 'telemetry.log'
    $prefix = '[08:42:40.284 I] FNV seamless telemetry: '
    $events = @(
        '{"schema":"nikami-fnv-seamless-exterior-telemetry/v1","event":"frame-sample","frame":60,"frameTimeMs":16.5,"memoryStatus":"not-collected"}',
        '{"schema":"nikami-fnv-seamless-exterior-telemetry/v1","event":"loading-scope-enter","depth":1,"alreadyVisible":false}',
        '{"schema":"nikami-fnv-seamless-exterior-telemetry/v1","event":"loading-screen-draw","frame":61,"drawIndex":1,"elapsedMs":75,"wallpaper":false}',
        '{"schema":"nikami-fnv-seamless-exterior-telemetry/v1","event":"fade-request","operation":"fadeScreenOut","durationSeconds":0.5,"clearQueue":false,"delaySeconds":0}',
        '{"schema":"nikami-fnv-seamless-exterior-telemetry/v1","event":"grid-change-begin","worldspace":"FormId:0x010d703c","gridX":0,"gridY":0}',
        '{"schema":"nikami-fnv-seamless-exterior-telemetry/v1","event":"scene-transition-begin","route":"exterior","destinationCell":"FormId:0x01000001","changeEvent":true,"usesFade":true,"handoffState":"not-implemented"}'
    )
    [IO.File]::WriteAllLines($logPath, [string[]]($events | ForEach-Object { $prefix + $_ }), [Text.UTF8Encoding]::new($false))
    $report = & $measurePath -LogPath $logPath -RequireEvents @('grid-change-begin', 'loading-screen-draw', 'scene-transition-begin')
    Assert-Contract ($report.status -eq 'pass') "Synthetic telemetry report must pass."
    Assert-Contract ($report.metrics.gridChangeCount -eq 1) "Synthetic telemetry must count a grid change."
    Assert-Contract ($report.metrics.loadingScreenDrawCount -eq 1) "Synthetic telemetry must count an actual loading draw."
    Assert-Contract ($report.metrics.fadeRequestCount -eq 1) "Synthetic telemetry must count a fade request."
    Assert-Contract ($report.metrics.unimplementedExteriorHandoffCount -eq 1) `
        "Synthetic telemetry must expose an unimplemented exterior handoff."
    Assert-Contract ($report.metrics.maxFrameTimeMs -eq 16.5) "Synthetic telemetry must retain frame timing."
}
catch {
    $failures.Add("Synthetic telemetry test failed: $($_.Exception.Message)")
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "FNV seamless telemetry contract failures:" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

[pscustomobject][ordered]@{
    events = 13
    status = 'pass'
}
