[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$LogPath,
    [string]$SchemaPath = "catalog/fnv-seamless-exterior-telemetry.schema.json",
    [string[]]$RequireEvents = @(),
    [string]$ReportPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$marker = "FNV seamless telemetry: "

function Resolve-RepoInputPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
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

function Get-RequiredStringSet($Document, [string]$Name) {
    $properties = Get-PropertyValue $Document 'properties'
    $property = Get-PropertyValue $properties $Name
    return @((Get-PropertyValue $property 'enum') | ForEach-Object { [string]$_ })
}

$resolvedSchemaPath = Resolve-RepoInputPath $SchemaPath
if (-not (Test-Path -LiteralPath $resolvedSchemaPath -PathType Leaf)) {
    throw "Missing seamless telemetry schema: $resolvedSchemaPath"
}
try {
    $schema = Get-Content -LiteralPath $resolvedSchemaPath -Raw | ConvertFrom-Json
}
catch {
    throw "Invalid seamless telemetry schema '$resolvedSchemaPath': $($_.Exception.Message)"
}

$schemaProperties = Get-PropertyValue $schema 'properties'
$schemaDescriptor = Get-PropertyValue $schemaProperties 'schema'
$telemetrySchema = [string](Get-PropertyValue $schemaDescriptor 'const')
if ($telemetrySchema -ne 'nikami-fnv-seamless-exterior-telemetry/v1') {
    throw "Telemetry schema does not lock nikami-fnv-seamless-exterior-telemetry/v1."
}
$knownEvents = Get-RequiredStringSet -Document $schema -Name 'event'
if ($knownEvents.Count -eq 0) {
    throw "Telemetry schema has no event enum."
}

$events = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
$resolvedLogs = [System.Collections.Generic.List[string]]::new()
foreach ($inputPath in $LogPath) {
    $resolvedPath = Resolve-RepoInputPath $inputPath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        $failures.Add("Missing telemetry log: $resolvedPath")
        continue
    }
    $resolvedLogs.Add($resolvedPath)
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $resolvedPath) {
        ++$lineNumber
        $markerIndex = $line.IndexOf($marker, [StringComparison]::Ordinal)
        if ($markerIndex -lt 0) {
            continue
        }
        $json = $line.Substring($markerIndex + $marker.Length).Trim()
        try {
            $event = $json | ConvertFrom-Json
        }
        catch {
            $failures.Add("Invalid telemetry JSON at ${resolvedPath}:${lineNumber}: $($_.Exception.Message)")
            continue
        }
        if ([string](Get-PropertyValue $event 'schema') -ne $telemetrySchema) {
            $failures.Add("Unexpected telemetry schema at ${resolvedPath}:${lineNumber}")
            continue
        }
        $eventName = [string](Get-PropertyValue $event 'event')
        if ($eventName -notin $knownEvents) {
            $failures.Add("Unknown telemetry event '$eventName' at ${resolvedPath}:${lineNumber}")
            continue
        }
        $events.Add([pscustomobject]@{
                name = $eventName
                source = $resolvedPath
                line = $lineNumber
                payload = $event
            })
    }
}

$counts = [ordered]@{}
foreach ($knownEvent in $knownEvents | Sort-Object) {
    $counts[$knownEvent] = 0
}
foreach ($event in $events) {
    ++$counts[$event.name]
}

foreach ($requiredEvent in $RequireEvents) {
    if ([string]::IsNullOrWhiteSpace($requiredEvent)) {
        continue
    }
    if ($requiredEvent -notin $knownEvents) {
        $failures.Add("RequireEvents includes unknown telemetry event '$requiredEvent'.")
    }
    elseif ($counts[$requiredEvent] -eq 0) {
        $failures.Add("Required telemetry event '$requiredEvent' was not observed.")
    }
}

$frameTimes = @($events | Where-Object { $_.name -eq 'frame-sample' } | ForEach-Object {
        $value = Get-PropertyValue $_.payload 'frameTimeMs'
        if ($value -is [ValueType]) { [double]$value }
    })
$unimplementedExteriorHandoffs = @($events | Where-Object {
        $_.name -eq 'scene-transition-begin' -and
        [string](Get-PropertyValue $_.payload 'route') -eq 'exterior' -and
        [string](Get-PropertyValue $_.payload 'handoffState') -eq 'not-implemented'
    })

$report = [pscustomobject][ordered]@{
    schema = 'nikami-fnv-seamless-exterior-telemetry-report/v1'
    sourceLogs = @($resolvedLogs)
    eventCount = $events.Count
    eventCounts = $counts
    metrics = [pscustomobject][ordered]@{
        gridChangeCount = $counts['grid-change-begin']
        loadingScopeCount = $counts['loading-scope-enter']
        loadingScreenDrawCount = $counts['loading-screen-draw']
        fadeRequestCount = $counts['fade-request']
        doorPreloadCount = $counts['door-preload']
        exteriorTransitionCount = @($events | Where-Object {
                $_.name -eq 'scene-transition-begin' -and [string](Get-PropertyValue $_.payload 'route') -eq 'exterior'
            }).Count
        unimplementedExteriorHandoffCount = $unimplementedExteriorHandoffs.Count
        maxFrameTimeMs = if ($frameTimes.Count -gt 0) { ($frameTimes | Measure-Object -Maximum).Maximum } else { $null }
    }
    failures = @($failures)
    status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $resolvedReportPath = Resolve-RepoInputPath $ReportPath
    $reportDirectory = Split-Path -Parent $resolvedReportPath
    if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
        [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
    }
    [IO.File]::WriteAllText($resolvedReportPath, ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

if ($failures.Count -gt 0) {
    throw "FNV seamless telemetry validation failed: $($failures -join '; ')"
}

$report
