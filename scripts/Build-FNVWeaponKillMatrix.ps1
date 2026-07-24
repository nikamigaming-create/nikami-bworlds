[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RuntimeLogPath,
    [string]$OpenMWTests = 'D:\code\nikami-openmw-save330-integrated\MSVC2022_64\RelWithDebInfo\openmw-tests.exe',
    [string]$PostImpactScreenshotPath = '',
    [string]$OutputRoot = 'run/fnv-weapon-kill-proof/matrix'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'FNVCombatTelemetry.psm1') -Force
function Resolve-PathFromRepo([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

$log = Resolve-PathFromRepo $RuntimeLogPath
$tests = Resolve-PathFromRepo $OpenMWTests
$output = Resolve-PathFromRepo $OutputRoot
foreach ($required in @($log, $tests)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file not found: $required" }
}
New-Item -ItemType Directory -Force -Path $output | Out-Null
$runtimeEvidence = Join-Path $output 'runtime-kill.log'
Copy-Item -LiteralPath $log -Destination $runtimeEvidence -Force
$postImpactEvidence = $null
if (-not [string]::IsNullOrWhiteSpace($PostImpactScreenshotPath)) {
    $postImpactSource = Resolve-PathFromRepo $PostImpactScreenshotPath
    if (-not (Test-Path -LiteralPath $postImpactSource -PathType Leaf)) {
        throw "Post-impact screenshot not found: $postImpactSource"
    }
    $postImpactEvidence = Join-Path $output ('post-impact' + [IO.Path]::GetExtension($postImpactSource))
    Copy-Item -LiteralPath $postImpactSource -Destination $postImpactEvidence -Force
}

$combatTelemetry = Read-FNVCombatTelemetry -LogPath $log
if (@($combatTelemetry.shots).Count -ne 1) {
    throw "Runtime kill proof requires exactly one passing shot and found $(@($combatTelemetry.shots).Count)."
}
$parsedShot = @($combatTelemetry.shots)[0]
$combatGate = Test-FNVCombatTelemetryForActor -Telemetry $combatTelemetry `
    -ActorForm ([string]$parsedShot.shooterForm) -ExpectedShotCount 1
if ($combatGate.status -ne 'pass') {
    throw "Runtime combat telemetry gate failed: $(@($combatGate.failures) -join ', ')"
}
$shot = [ordered]@{
    shooterForm = [string]$parsedShot.shooterForm
    weapon = [string]$parsedShot.weapon
    ammo = [string]$parsedShot.ammo
    ammoBefore = [int]$parsedShot.ammoBefore
    ammoAfter = [int]$parsedShot.ammoAfter
    projectile = [string]$parsedShot.projectile
    projectileRange = [double]$parsedShot.projectileRange
    damage = [double]$parsedShot.damage
    rayHit = [bool]$parsedShot.rayHit
    actorHit = [bool]$parsedShot.actorHit
    healthBefore = [double]$parsedShot.healthBefore
    healthAfter = [double]$parsedShot.healthAfter
}
$shot['ammoConsumed'] = $shot.ammoBefore - $shot.ammoAfter
$shot['healthReduced'] = $shot.healthAfter -lt $shot.healthBefore
$shot['lethalHealthState'] = $shot.healthAfter -le 0

$reactionLines = @(Select-String -LiteralPath $log -Pattern 'FNV Strip sniper cinematic reaction:.*status=pass' | ForEach-Object Line)
$shot['reactionObserved'] = $reactionLines.Count -ge 2
$shot['mechanicsPass'] = $shot.ammoConsumed -eq 1 -and $shot.rayHit -and $shot.actorHit -and
    $shot.healthReduced -and $shot.lethalHealthState -and $shot.reactionObserved
$deathStateLines = @(Select-String -LiteralPath $log -Pattern 'FNV combat death:.*dead=1.*status=pass' |
    ForEach-Object Line)
$shot['explicitDeathStateObserved'] = $deathStateLines.Count -gt 0
$shot['runtimePass'] = $shot.mechanicsPass -and $shot.explicitDeathStateObserved

$testOutput = @(& $tests '--gtest_filter=FalloutCombatTest.*:FalloutWeaponAnimationTest.*:FalloutHitReactionTest.*' '--gtest_brief=1' 2>&1)
$testExit = $LASTEXITCODE
if ($testExit -ne 0) { throw "Focused weapon tests failed with exit code $testExit.`n$($testOutput -join [Environment]::NewLine)" }
$testSummary = ($testOutput | Where-Object { $_ -match '\[  PASSED  \]' } | Select-Object -Last 1)

$rows = @(
    [ordered]@{ family='unarmed'; dnam='0'; animation='pass'; equip='pass'; attackTransport='pass'; ammo='not-applicable'; damage='fail'; reaction='unproven'; death='unproven'; status='fail'; gap='FNV primary attack always enters fireFalloutWeapon, which requires an authored ammo/projectile contract; bare-hand lethal runtime is not covered.' },
    [ordered]@{ family='melee'; dnam='1,2'; animation='pass'; equip='pass'; attackTransport='pass'; ammo='not-applicable'; damage='fail'; reaction='unproven'; death='unproven'; status='fail'; gap='No FNV melee contact/range/onHit path exists; the ranged ammo/projectile path rejects melee records.' },
    [ordered]@{ family='pistol'; dnam='3'; animation='pass'; equip='pass'; attackTransport='pass'; ammo='contract-only'; damage='contract-only'; reaction='contract-only'; death='unproven'; status='unproven'; gap='Single-projectile hitscan path is generic, but no terminal runtime kill has exercised a pistol.' },
    [ordered]@{ family='rifle'; dnam='5'; animation='pass'; equip='pass'; attackTransport='pass'; ammo=$(if($shot.mechanicsPass){'pass'}else{'fail'}); damage=$(if($shot.mechanicsPass){'pass'}else{'fail'}); reaction=$(if($shot.reactionObserved){'pass'}else{'fail'}); death=$(if($shot.explicitDeathStateObserved){'pass'}elseif($shot.lethalHealthState){'health-zero-only'}else{'fail'}); status=$(if($shot.runtimePass){'pass'}elseif($shot.mechanicsPass){'partial'}else{'fail'}); gap=$(if($shot.runtimePass){''}elseif($shot.mechanicsPass){'Ammo, ray hit, damage, reaction, and health 100 -> 0 pass, but no death-state transition/animation is emitted; post-impact frames keep the coyote upright.'}else{'Runtime rifle mechanics gate failed.'}) },
    [ordered]@{ family='automatic'; dnam='6'; animation='pass'; equip='pass'; attackTransport='pass'; ammo='single-shot-only'; damage='single-shot-only'; reaction='unproven'; death='unproven'; status='fail'; gap='Attack-loop family currently calls fireFalloutWeapon once and transitions to AttackEnd; sustained automatic cadence is not implemented/proven.' },
    [ordered]@{ family='shotgun'; dnam='3,5 (weapon-authored)'; animation='pass'; equip='pass'; attackTransport='pass'; ammo='fail'; damage='fail'; reaction='unproven'; death='unproven'; status='fail'; gap='buildFalloutHitscanContract explicitly rejects numProjectiles > 1; pellet spread/multi-hit is unimplemented.' },
    [ordered]@{ family='launcher/explosive'; dnam='9,10,11,12'; animation='pass'; equip='pass'; attackTransport='pass'; ammo='fail'; damage='fail'; reaction='unproven'; death='unproven'; status='fail'; gap='Production path only accepts hitscan projectile records; physical projectiles, explosion radius, grenade throw, and mine placement are absent.' },
    [ordered]@{ family='energy'; dnam='4,7'; animation='pass'; equip='pass'; attackTransport='pass'; ammo='contract-only'; damage='hitscan-subset-only'; reaction='unproven'; death='unproven'; status='unproven'; gap='Laser-like single hitscan records can use the generic path; plasma/physical projectiles and an actual energy-weapon kill are not proven.' },
    [ordered]@{ family='thrown'; dnam='10,13'; animation='pass'; equip='pass'; attackTransport='pass'; ammo='fail'; damage='fail'; reaction='unproven'; death='unproven'; status='fail'; gap='Throw trajectory, spawned projectile, inventory decrement, fuse/explosion, and damage delivery are not implemented/proven.' }
)

$passing = @($rows | Where-Object status -eq 'pass').Count
$report = [ordered]@{
    schema = 'nikami-fnv-weapon-kill-matrix/v1'
    createdAt = (Get-Date).ToString('o')
    runtimeLog = $runtimeEvidence
    postImpactScreenshot = $postImpactEvidence
    focusedTests = [ordered]@{ executable=$tests; summary=[string]$testSummary; status='pass' }
    runtimeShot = $shot
    families = $rows
    coverage = [ordered]@{ passed=$passing; total=$rows.Count; percent=[Math]::Round(100.0*$passing/$rows.Count,1) }
    status = if ($passing -eq $rows.Count) { 'pass' } else { 'incomplete' }
}
$json = Join-Path $output 'weapon-kill-matrix.json'
$markdown = Join-Path $output 'weapon-kill-matrix.md'
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $json -Encoding UTF8

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# FNV weapon kill matrix')
$lines.Add('')
$lines.Add("Complete runtime kill coverage: **$passing/$($rows.Count) families ($($report.coverage.percent)%)**. Focused animation/contract tests: **pass**.")
$lines.Add('')
$lines.Add('| Family | DNAM | Animation | Attack | Ammo | Damage | Reaction | Death | Status |')
$lines.Add('|---|---:|---|---|---|---|---|---|---|')
foreach ($row in $rows) {
    $lines.Add("| $($row.family) | $($row.dnam) | $($row.animation) | $($row.attackTransport) | $($row.ammo) | $($row.damage) | $($row.reaction) | $($row.death) | **$($row.status)** |")
}
$lines.Add('')
$lines.Add('## Runtime rifle kill evidence')
$lines.Add('')
$lines.Add("- Weapon: $($shot.weapon); projectile: $($shot.projectile); ammo: $($shot.ammoBefore) -> $($shot.ammoAfter).")
$lines.Add("- Ray hit: $($shot.rayHit); actor hit: $($shot.actorHit); damage: $($shot.damage); health: $($shot.healthBefore) -> $($shot.healthAfter).")
$lines.Add("- Damage reaction: $($shot.reactionObserved); lethal health state: $($shot.lethalHealthState).")
$lines.Add("- Explicit death state: $($shot.explicitDeathStateObserved); post-impact screenshot: $postImpactEvidence.")
$lines.Add('')
$lines.Add('## Gaps')
$lines.Add('')
foreach ($row in $rows | Where-Object status -ne 'pass') { $lines.Add("- **$($row.family):** $($row.gap)") }
$lines | Set-Content -LiteralPath $markdown -Encoding UTF8

[pscustomobject]@{ status=$report.status; passed=$passing; total=$rows.Count; json=$json; markdown=$markdown; runtimePass=$shot.runtimePass }
