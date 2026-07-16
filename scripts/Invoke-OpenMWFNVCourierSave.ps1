[CmdletBinding()]
param(
    [ValidateSet('Create', 'Play')]
    [string]$Action = 'Create',
    [string]$SavePath = 'run/openmw-fnv-courier-save/Courier-Field-Test.omwsave',
    [string]$BinaryRoot = '',
    [string]$ProfileDirectory = 'profiles/fallout_new_vegas',
    [string]$Outfit = 'VaultSuit21',
    [string]$Headgear = 'CowboyHat02',
    [string]$DrawnWeapon = 'WeapNVVarmintRifle',
    [int]$QuickSaveFrame = 300,
    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 150,
    [switch]$WaitForPlay,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'WorldViewerPaths.ps1')

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $script:NikamiRepoRoot $Path))
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Resolve-ProfileUserData([string]$Profile) {
    $configPath = Join-Path $Profile 'openmw.cfg'
    foreach ($line in Get-Content -LiteralPath $configPath) {
        if ($line -notmatch '^\s*user-data\s*=\s*(.+?)\s*$') { continue }
        $value = [Environment]::ExpandEnvironmentVariables($Matches[1].Trim())
        if ([System.IO.Path]::IsPathRooted($value)) {
            return [System.IO.Path]::GetFullPath($value)
        }
        return [System.IO.Path]::GetFullPath((Join-Path $Profile $value))
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Profile 'userdata'))
}

function Get-SaveSnapshot([string]$SaveRoot) {
    $snapshot = @{}
    if (-not (Test-Path -LiteralPath $SaveRoot -PathType Container)) { return $snapshot }
    foreach ($file in Get-ChildItem -LiteralPath $SaveRoot -Recurse -File -Filter '*.omwsave') {
        $snapshot[$file.FullName] = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
    }
    return $snapshot
}

function Wait-ForStableNewSave([string]$SaveRoot, [hashtable]$Before, [datetime]$Deadline) {
    $candidatePath = $null
    $lastStamp = $null
    $stableSince = $null
    while ((Get-Date) -lt $Deadline) {
        $candidates = @()
        if (Test-Path -LiteralPath $SaveRoot -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $SaveRoot -Recurse -File -Filter '*.omwsave' |
                Where-Object {
                    $stamp = "$($_.Length):$($_.LastWriteTimeUtc.Ticks)"
                    -not $Before.ContainsKey($_.FullName) -or $Before[$_.FullName] -ne $stamp
                } |
                Sort-Object LastWriteTimeUtc -Descending)
        }
        if ($candidates.Count -gt 0) {
            $candidate = $candidates[0]
            $stamp = "$($candidate.Length):$($candidate.LastWriteTimeUtc.Ticks)"
            if ($candidatePath -eq $candidate.FullName -and $lastStamp -eq $stamp) {
                if ($null -eq $stableSince) { $stableSince = Get-Date }
                elseif (((Get-Date) - $stableSince).TotalMilliseconds -ge 750) { return $candidate }
            }
            else {
                $candidatePath = $candidate.FullName
                $lastStamp = $stamp
                $stableSince = $null
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Set-ChildEnvironment([hashtable]$Previous, [string]$Name, [string]$Value) {
    if (-not $Previous.ContainsKey($Name)) {
        $Previous[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    [Environment]::SetEnvironmentVariable($Name,
        $(if ([string]::IsNullOrWhiteSpace($Value)) { $null } else { $Value }), 'Process')
}

function Stop-OpenMWProcess([System.Diagnostics.Process]$Process) {
    if ($null -eq $Process -or $Process.HasExited) { return }
    $null = $Process.CloseMainWindow()
    if (-not $Process.WaitForExit(10000)) {
        Stop-Process -Id $Process.Id -Force
        $Process.WaitForExit()
    }
}

function Wait-ForReloadPersistenceLedger([string]$LogPath, [datetime]$StartedAt, [datetime]$Deadline) {
    $required = @('WeapNV9mmPistol', 'WeapNVVarmintRifle', 'Ammo9mm', 'Ammo556mm',
        'Stimpak', 'BobbyPin', 'Caps001', 'VaultSuit21', 'CowboyHat02')
    while ((Get-Date) -lt $Deadline) {
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            $logFile = Get-Item -LiteralPath $LogPath
            if ($logFile.LastWriteTime -ge $StartedAt.AddSeconds(-1)) {
                $text = Get-Content -LiteralPath $LogPath -Raw
                $allRetained = $true
                foreach ($editorId in $required) {
                    if ($text -notmatch ("starter inventory retained " + [Regex]::Escape($editorId) +
                            " .*inserted=0")) {
                        $allRetained = $false
                        break
                    }
                }
                if ($allRetained -and $text -match
                    'preexistingEquipped=\{outfit:1,headgear:1,weapon:1,ammunition:1\} equipped=\{outfit:1,headgear:1,weapon:1,ammunition:1\} status=pass') {
                    return $true
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

if ($QuickSaveFrame -lt 1) { throw 'QuickSaveFrame must be at least one.' }
foreach ($entry in @($Outfit, $Headgear, $DrawnWeapon)) {
    if ([string]::IsNullOrWhiteSpace($entry)) { throw 'Outfit, Headgear, and DrawnWeapon must be non-empty editor IDs.' }
}

$runtime = Resolve-NikamiOpenMWRuntimeRoot -ParameterValue $BinaryRoot
$binary = Join-Path $runtime 'openmw.exe'
$resources = Join-Path $runtime 'resources'
$profile = Resolve-RepoPath $ProfileDirectory
$save = Resolve-RepoPath $SavePath
$profileConfig = Join-Path $profile 'openmw.cfg'
if (-not (Test-Path -LiteralPath $profileConfig -PathType Leaf)) { throw "Missing FNV profile config: $profileConfig" }
if (-not (Test-Path -LiteralPath $resources -PathType Container)) { throw "Missing OpenMW resources: $resources" }
if ($Action -eq 'Play' -and -not (Test-Path -LiteralPath $save -PathType Leaf)) {
    throw "Courier save does not exist. Run -Action Create first: $save"
}
if (-not $DryRun -and (Get-Process -Name 'openmw' -ErrorAction SilentlyContinue)) {
    throw 'openmw.exe is already running; close it before creating or loading the Courier save.'
}

$arguments = [System.Collections.Generic.List[string]]::new()
foreach ($arg in @('--replace', 'config', '--config', $profile, '--resources', $resources, '--skip-menu')) {
    $arguments.Add($arg)
}
if ($Action -eq 'Create') {
    foreach ($arg in @('--start', 'Goodsprings', '--no-sound')) { $arguments.Add($arg) }
}
else {
    foreach ($arg in @('--load-savegame', $save)) { $arguments.Add($arg) }
}
$argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '

$environmentContract = [ordered]@{
    OPENMW_ESM4_PLAYER_OUTFIT = $Outfit
    OPENMW_ESM4_PLAYER_HEADGEAR = $Headgear
    OPENMW_ESM4_PLAYER_WEAPON = $DrawnWeapon
}
if ($Action -eq 'Create') {
    $environmentContract.OPENMW_FNV_BOOTSTRAP_LEVEL1_COURIER = '1'
    $environmentContract.OPENMW_FNV_BOOTSTRAP_DOC_SENT = '1'
    $environmentContract.OPENMW_PROOF_QUICKSAVE_FRAME = [string]$QuickSaveFrame
    $environmentContract.OPENMW_PROOF_QUICKSAVE_NAME = 'Courier Field Test'
}

$contract = [ordered]@{
    schema = 'nikami-openmw-fnv-courier-save/v1'
    action = $Action
    binary = $binary
    binarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
    profile = $profile
    save = $save
    loadout = [ordered]@{
        outfit = $Outfit
        headgear = $Headgear
        sidearm = 'WeapNV9mmPistol'
        sidearmAmmo = 'Ammo9mm x60'
        longGun = 'WeapNVVarmintRifle'
        longGunAmmo = 'Ammo556mm x60'
        drawnWeapon = $DrawnWeapon
        aid = @('Stimpak x5', 'BobbyPin x5', 'Caps001 x75')
    }
    environment = $environmentContract
    arguments = @($arguments)
    commandLine = "$(Quote-ProcessArgument $binary) $argumentLine"
    status = if ($DryRun) { 'dry-run' } else { 'pending' }
}

if ($DryRun) {
    [pscustomobject]$contract
    return
}

$previousEnvironment = @{}
$process = $null
try {
    # The session must not inherit actor/sky proof controls. Preserve and restore the caller's environment.
    foreach ($key in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        $name = [string]$key
        if ($name.StartsWith('OPENMW_PROOF_', [StringComparison]::OrdinalIgnoreCase) -or
            $name.StartsWith('OPENMW_WORLD_VIEWER_', [StringComparison]::OrdinalIgnoreCase)) {
            Set-ChildEnvironment -Previous $previousEnvironment -Name $name -Value ''
        }
    }
    foreach ($name in @(
        'OPENMW_ESM4_DISABLE_PLAYER_VISUAL_PROXY',
        'OPENMW_FNV_DISABLE_PLAYER_VISUAL_PROXY',
        'OPENMW_FNV_HIDE_PLAYER_PROOF_PARTS',
        'OPENMW_FNV_BOOTSTRAP_LEVEL1_COURIER',
        'OPENMW_FNV_BOOTSTRAP_DOC_SENT',
        'OPENMW_ESM4_PLAYER_OUTFIT',
        'OPENMW_ESM4_PLAYER_HEADGEAR',
        'OPENMW_ESM4_PLAYER_WEAPON'
    )) {
        Set-ChildEnvironment -Previous $previousEnvironment -Name $name -Value ''
    }
    foreach ($entry in $environmentContract.GetEnumerator()) {
        Set-ChildEnvironment -Previous $previousEnvironment -Name ([string]$entry.Key) -Value ([string]$entry.Value)
    }

    $startParameters = @{
        FilePath = $binary
        ArgumentList = $argumentLine
        WorkingDirectory = $runtime
        PassThru = $true
    }
    if ($Action -eq 'Create') { $startParameters.WindowStyle = 'Hidden' }

    if ($Action -eq 'Play') {
        $process = Start-Process @startParameters
        $contract.pid = $process.Id
        $contract.status = 'launched'
        if ($WaitForPlay) {
            $process.WaitForExit()
            $contract.exitCode = $process.ExitCode
            $contract.status = if ($process.ExitCode -eq 0) { 'complete' } else { 'failed' }
        }
        [pscustomobject]$contract
        return
    }

    $userData = Resolve-ProfileUserData $profile
    $profileSaveRoot = Join-Path $userData 'saves'
    $before = Get-SaveSnapshot $profileSaveRoot
    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $process = Start-Process @startParameters
    $contract.pid = $process.Id
    $contract.profileSaveRoot = $profileSaveRoot
    $newSave = Wait-ForStableNewSave -SaveRoot $profileSaveRoot -Before $before -Deadline $deadline
    if ($null -eq $newSave) {
        throw "No stable OpenMW quicksave appeared within $TimeoutSeconds seconds."
    }

    $destinationDirectory = Split-Path -Parent $save
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    Copy-Item -LiteralPath $newSave.FullName -Destination $save -Force
    $copied = Get-Item -LiteralPath $save
    if ($copied.Length -le 0) { throw "Created Courier save is empty: $save" }

    $profileLog = Join-Path $profile 'openmw.log'
    $logText = if (Test-Path -LiteralPath $profileLog -PathType Leaf) {
        Get-Content -LiteralPath $profileLog -Raw
    } else { '' }
    foreach ($editorId in @('WeapNV9mmPistol', 'WeapNVVarmintRifle', 'Ammo9mm', 'Ammo556mm',
            'Stimpak', 'BobbyPin', 'Caps001', 'VaultSuit21', 'CowboyHat02')) {
        if ($logText -notmatch [Regex]::Escape("starter inventory added $editorId")) {
            throw "Courier bootstrap did not confirm retail inventory record $editorId."
        }
    }
    if ($logText -notmatch 'requesting quicksave "Courier Field Test"') {
        throw 'Courier bootstrap did not confirm its quicksave request.'
    }

    Stop-OpenMWProcess $process
    $process = $null

    # Reopen the copied artifact with the same bootstrap as an idempotence audit. Every real FNV record must be
    # retained with inserted=0, and InventoryStore must restore all four equipped slots from the save.
    Set-ChildEnvironment -Previous $previousEnvironment -Name 'OPENMW_PROOF_QUICKSAVE_FRAME' -Value ''
    Set-ChildEnvironment -Previous $previousEnvironment -Name 'OPENMW_PROOF_QUICKSAVE_NAME' -Value ''
    Set-ChildEnvironment -Previous $previousEnvironment -Name 'OPENMW_FNV_BOOTSTRAP_DOC_SENT' -Value ''
    $reloadArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @('--replace', 'config', '--config', $profile, '--resources', $resources, '--skip-menu',
            '--load-savegame', $save, '--no-sound')) {
        $reloadArguments.Add($arg)
    }
    $reloadArgumentLine = ($reloadArguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    $reloadStart = Get-Date
    $process = Start-Process -FilePath $binary -ArgumentList $reloadArgumentLine -WorkingDirectory $runtime `
        -PassThru -WindowStyle Hidden
    $reloadPass = Wait-ForReloadPersistenceLedger -LogPath $profileLog -StartedAt $reloadStart `
        -Deadline $reloadStart.AddSeconds($TimeoutSeconds)
    if (-not $reloadPass) {
        throw 'Reloaded Courier save did not retain every inventory count and equipped slot.'
    }
    $contract.reloadPersistence = [ordered]@{
        status = 'pass'
        pid = $process.Id
        inventory = 'all-retained-inserted-0'
        equippedBeforeBootstrap = 'outfit,headgear,weapon,ammunition'
    }
    Stop-OpenMWProcess $process
    $process = $null

    $contract.sourceSave = $newSave.FullName
    $contract.saveSha256 = (Get-FileHash -LiteralPath $save -Algorithm SHA256).Hash
    $contract.saveLength = $copied.Length
    $contract.createdAt = (Get-Date).ToString('o')
    $contract.status = 'complete'
    $manifestPath = "$save.json"
    $contract.manifest = $manifestPath
    $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    [pscustomobject]$contract
}
finally {
    if ($Action -eq 'Create') { Stop-OpenMWProcess $process }
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, 'Process')
    }
}
