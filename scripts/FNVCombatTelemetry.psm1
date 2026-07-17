Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-InvariantDouble {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $parsed = 0.0
    if (-not [double]::TryParse(
            $Value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed)) {
        return [double]::NaN
    }
    return $parsed
}

function Read-FNVCombatTelemetry {
    param(
        [Parameter(Mandatory)]
        [string]$LogPath
    )

    $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
    if (-not (Test-Path -LiteralPath $resolvedLogPath -PathType Leaf)) {
        throw "FNV combat telemetry log does not exist: $resolvedLogPath"
    }

    $shots = [System.Collections.Generic.List[object]]::new()
    $rejections = [System.Collections.Generic.List[object]]::new()
    $parseFailures = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0

    foreach ($line in [System.IO.File]::ReadLines($resolvedLogPath)) {
        ++$lineNumber

        if ($line -match 'FNV combat shot: actor=.*?\((?:NPC_4|CREA), (?<form>FormId:[^)\s]+)\) weapon=(?<weapon>\S+) ammo=(?<ammo>\S+) ammoBefore=(?<ammoBefore>-?[0-9]+) ammoAfter=(?<ammoAfter>-?[0-9]+) projectile=(?<projectile>\S+) projectileRange=(?<range>\S+) damage=(?<damage>\S+) rayHit=(?<rayHit>[01]) actorHit=(?<actorHit>[01]) hitObject=(?<hitObject>.*?) healthBefore=(?<healthBefore>\S+) healthAfter=(?<healthAfter>\S+) exact=1 status=pass') {
            $shooterForm = [string]$Matches.form
            $weapon = [string]$Matches.weapon
            $ammo = [string]$Matches.ammo
            $ammoBefore = [int]$Matches.ammoBefore
            $ammoAfter = [int]$Matches.ammoAfter
            $projectile = [string]$Matches.projectile
            $projectileRange = ConvertTo-InvariantDouble ([string]$Matches.range)
            $damage = ConvertTo-InvariantDouble ([string]$Matches.damage)
            $rayHit = $Matches.rayHit -eq '1'
            $actorHit = $Matches.actorHit -eq '1'
            $hitObject = [string]$Matches.hitObject
            $healthBefore = ConvertTo-InvariantDouble ([string]$Matches.healthBefore)
            $healthAfter = ConvertTo-InvariantDouble ([string]$Matches.healthAfter)
            $ammoConsumed = $ammoBefore - $ammoAfter
            $failures = [System.Collections.Generic.List[string]]::new()

            if ($ammoConsumed -ne 1) { $failures.Add('ammo-consumed-not-one') }
            if (-not $rayHit) { $failures.Add('ray-missed') }
            if (-not $actorHit) { $failures.Add('actor-not-hit') }
            if ([string]::IsNullOrWhiteSpace($hitObject) -or $hitObject -eq 'none') {
                $failures.Add('missing-hit-object')
            }
            if ([double]::IsNaN($healthBefore) -or [double]::IsInfinity($healthBefore)) {
                $failures.Add('health-before-not-finite')
            }
            if ([double]::IsNaN($healthAfter) -or [double]::IsInfinity($healthAfter)) {
                $failures.Add('health-after-not-finite')
            }
            if (-not [double]::IsNaN($healthBefore) -and -not [double]::IsInfinity($healthBefore) -and
                -not [double]::IsNaN($healthAfter) -and -not [double]::IsInfinity($healthAfter) -and
                $healthAfter -ge $healthBefore) {
                $failures.Add('health-not-reduced')
            }
            if ([double]::IsNaN($damage) -or [double]::IsInfinity($damage) -or $damage -le 0.0) {
                $failures.Add('damage-not-positive')
            }
            if ([double]::IsNaN($projectileRange) -or [double]::IsInfinity($projectileRange) -or
                $projectileRange -le 0.0) {
                $failures.Add('projectile-range-not-positive')
            }

            $shots.Add([pscustomobject][ordered]@{
                schema = 'nikami-fnv-combat-shot-telemetry/v1'
                lineNumber = $lineNumber
                shooterForm = $shooterForm
                weapon = $weapon
                ammo = $ammo
                ammoBefore = $ammoBefore
                ammoAfter = $ammoAfter
                ammoConsumed = $ammoConsumed
                projectile = $projectile
                projectileRange = $projectileRange
                damage = $damage
                rayHit = $rayHit
                actorHit = $actorHit
                hitObject = $hitObject
                healthBefore = $healthBefore
                healthAfter = $healthAfter
                healthReduced = $healthAfter -lt $healthBefore
                failures = @($failures)
                status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
            }) | Out-Null
            continue
        }

        if ($line -match 'FNV combat shot rejected: actor=.*?\((?:NPC_4|CREA), (?<form>FormId:[^)\s]+)\) weapon=(?<weapon>\S+) reason=(?<reason>[a-z0-9-]+) exact=1') {
            $rejections.Add([pscustomobject][ordered]@{
                lineNumber = $lineNumber
                shooterForm = [string]$Matches.form
                weapon = [string]$Matches.weapon
                reason = [string]$Matches.reason
            }) | Out-Null
            continue
        }

        if ($line.Contains('FNV combat shot:') -or $line.Contains('FNV combat shot rejected:')) {
            $parseFailures.Add([pscustomobject][ordered]@{
                lineNumber = $lineNumber
                reason = 'unrecognized-combat-telemetry'
                line = $line
            }) | Out-Null
        }
    }

    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-combat-telemetry-log/v1'
        log = $resolvedLogPath
        shots = @($shots)
        rejections = @($rejections)
        parseFailures = @($parseFailures)
    }
}

function Test-FNVCombatTelemetryForActor {
    param(
        [Parameter(Mandatory)]
        [object]$Telemetry,

        [Parameter(Mandatory)]
        [string]$ActorForm,

        [Parameter(Mandatory)]
        [ValidateRange(0, 1024)]
        [int]$ExpectedShotCount
    )

    if ($ExpectedShotCount -eq 0) {
        return [pscustomobject][ordered]@{
            schema = 'nikami-fnv-combat-telemetry-gate/v1'
            actorForm = $ActorForm
            required = $false
            expectedShotCount = 0
            observedShotCount = 0
            rejectionCount = 0
            shots = @()
            rejections = @()
            failures = @()
            status = 'not-required'
        }
    }

    $shots = @($Telemetry.shots | Where-Object { [string]$_.shooterForm -ieq $ActorForm })
    $rejections = @($Telemetry.rejections | Where-Object { [string]$_.shooterForm -ieq $ActorForm })
    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($parseFailure in @($Telemetry.parseFailures)) {
        $failures.Add("telemetry-parse-failure-line-$([int]$parseFailure.lineNumber)")
    }
    if ($shots.Count -ne $ExpectedShotCount) {
        $failures.Add("shot-count-$($shots.Count)-expected-$ExpectedShotCount")
    }
    foreach ($rejection in $rejections) {
        $failures.Add("shot-rejected-$([string]$rejection.reason)")
    }
    for ($index = 0; $index -lt $shots.Count; ++$index) {
        foreach ($shotFailure in @($shots[$index].failures)) {
            $failures.Add("shot-$index-$shotFailure")
        }
    }

    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-combat-telemetry-gate/v1'
        actorForm = $ActorForm
        required = $true
        expectedShotCount = $ExpectedShotCount
        observedShotCount = $shots.Count
        rejectionCount = $rejections.Count
        shots = $shots
        rejections = $rejections
        failures = @($failures)
        status = if ($failures.Count -eq 0) { 'pass' } else { 'fail' }
    }
}

Export-ModuleMember -Function Read-FNVCombatTelemetry, Test-FNVCombatTelemetryForActor
