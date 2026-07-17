Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FNVCombatTelemetry.psm1') -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        $Actual,

        [Parameter(Mandatory)]
        $Expected,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "$Label expected '$Expected' and found '$Actual'."
    }
}

$actorForm = 'FormId:0x10cda99'
$prefix = '[08:42:40.284 I] '
$passingShot = $prefix + 'FNV combat shot: actor=object@0x2 (NPC_4, FormId:0x10cda99) weapon=FormId:0x10e9c3b ammo=FormId:0x1004240 ammoBefore=32 ammoAfter=31 projectile=FormId:0x100426d projectileRange=10000 damage=18 rayHit=1 actorHit=1 hitObject=object@0x1 (NPC, "Player") healthBefore=125 healthAfter=107 exact=1 status=pass'
$cases = @(
    [pscustomobject]@{ name = 'passing'; lines = @($passingShot); expected = 'pass'; failure = '' },
    [pscustomobject]@{ name = 'animation-only'; lines = @(); expected = 'fail'; failure = 'shot-count-0-expected-1' },
    [pscustomobject]@{ name = 'rejected'; lines = @($prefix + 'FNV combat shot rejected: actor=object@0x2 (NPC_4, FormId:0x10cda99) weapon=FormId:0x10e9c3b reason=missing-projectile-record exact=1'); expected = 'fail'; failure = 'shot-rejected-missing-projectile-record' },
    [pscustomobject]@{ name = 'actor-missed'; lines = @(($passingShot -replace 'actorHit=1', 'actorHit=0')); expected = 'fail'; failure = 'shot-0-actor-not-hit' },
    [pscustomobject]@{ name = 'health-not-reduced'; lines = @(($passingShot -replace 'healthAfter=107', 'healthAfter=125')); expected = 'fail'; failure = 'shot-0-health-not-reduced' },
    [pscustomobject]@{ name = 'two-rounds-consumed'; lines = @(($passingShot -replace 'ammoAfter=31', 'ammoAfter=30')); expected = 'fail'; failure = 'shot-0-ammo-consumed-not-one' }
)

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nikami-fnv-combat-telemetry-$([guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    foreach ($case in $cases) {
        $path = Join-Path $temporaryRoot ("$($case.name).log")
        [System.IO.File]::WriteAllLines($path, [string[]]$case.lines, [Text.UTF8Encoding]::new($false))
        $telemetry = Read-FNVCombatTelemetry -LogPath $path
        $gate = Test-FNVCombatTelemetryForActor -Telemetry $telemetry -ActorForm $actorForm -ExpectedShotCount 1
        Assert-Equal $gate.status $case.expected "$($case.name) status"
        if (-not [string]::IsNullOrEmpty($case.failure) -and $case.failure -notin @($gate.failures)) {
            throw "$($case.name) did not report expected failure '$($case.failure)': $(@($gate.failures) -join ', ')"
        }
    }

    $notRequired = Test-FNVCombatTelemetryForActor `
        -Telemetry (Read-FNVCombatTelemetry -LogPath (Join-Path $temporaryRoot 'animation-only.log')) `
        -ActorForm $actorForm -ExpectedShotCount 0
    Assert-Equal $notRequired.status 'not-required' 'non-mechanics status'
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject][ordered]@{
    cases = $cases.Count + 1
    status = 'pass'
}
