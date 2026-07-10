param(
    [string]$GameRoot = "D:\SteamLibrary\steamapps\common\Fallout New Vegas",
    [string]$PluginDll = "external\xnvse\nvse_retail_oracle\build\nvse_retail_oracle.dll",
    [string]$OutputPath = "run\retail-oracle\fnv-goodsprings-behavior.jsonl",
    [string]$SaveName = "Save 222     Goodsprings  00 01 36",
    [string[]]$QuestForm = @("0x00102037", "0x00104C1C", "0x0010A214", "0x0015D912"),
    [string[]]$GlobalForm = @("0x35", "0x36", "0x37", "0x38", "0x39", "0x3A"),
    [string[]]$Command = @(),
    [string[]]$ActorCommand = @(),
    [string]$SetStageQuestForm = "0",
    [int]$SetStageIndex = 65535,
    [int]$BeforeFrame = 10,
    [int]$CommandFrame = 20,
    [int]$AfterFrame = 30,
    [int]$MaxFrames = 40,
    [int]$TimeoutSeconds = 55,
    [int]$SampleEvery = 1,
    [string]$TargetForm = "0",
    [string]$EquipForm = "0",
    [string]$PlayGroup = "",
    [string]$DriveCommand = "",
    [int]$PrepareActorFrame = 60,
    [int]$EquipActorFrame = 60,
    [int]$DriveActorFrame = 180,
    [int]$FootIkToggleFrame = 0,
    [ValidateSet(-1, 0, 1)]
    [int]$FootIkToggleEnabled = -1,
    [switch]$CaptureAnimation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Remove-FileWithRetry([string]$Path, [int]$TimeoutMilliseconds = 5000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $Path)) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out removing file: $Path"
}

if ($BeforeFrame -lt 1 -or $CommandFrame -le $BeforeFrame -or $AfterFrame -le $CommandFrame) {
    throw "Expected 0 < BeforeFrame < CommandFrame < AfterFrame."
}
if ($MaxFrames -lt $AfterFrame) {
    throw "MaxFrames must be greater than or equal to AfterFrame."
}
if ($TimeoutSeconds -lt 10 -or $TimeoutSeconds -gt 120) {
    throw "TimeoutSeconds must be between 10 and 120."
}
if ($SampleEvery -lt 1) {
    throw "SampleEvery must be positive."
}
foreach ($form in @($TargetForm, $EquipForm)) {
    if ($form -notmatch '^(0[xX][0-9a-fA-F]+|[0-9]+)$') {
        throw "Expected a decimal or 0x-prefixed FormID, got: $form"
    }
}
if ($PlayGroup -notmatch '^[A-Za-z0-9_]*$') {
    throw "PlayGroup may contain only ASCII letters, digits, and underscores."
}
if ($CaptureAnimation -and ($PrepareActorFrame -lt 1 -or $PrepareActorFrame -gt $MaxFrames)) {
    throw "PrepareActorFrame must be between 1 and MaxFrames for animation capture."
}
if ($CaptureAnimation -and
    (-not [string]::IsNullOrWhiteSpace($PlayGroup) -or -not [string]::IsNullOrWhiteSpace($DriveCommand)) -and
    ($EquipActorFrame -lt $PrepareActorFrame -or $DriveActorFrame -lt $EquipActorFrame -or
        $DriveActorFrame -gt $MaxFrames)) {
    throw "Expected PrepareActorFrame <= EquipActorFrame <= DriveActorFrame <= MaxFrames when PlayGroup is set."
}
if ($FootIkToggleFrame -lt 0 -or ($FootIkToggleFrame -gt 0 -and
    ($FootIkToggleFrame -lt $PrepareActorFrame -or $FootIkToggleFrame -gt $MaxFrames))) {
    throw "FootIkToggleFrame must be zero or between PrepareActorFrame and MaxFrames."
}
if (($FootIkToggleFrame -eq 0) -ne ($FootIkToggleEnabled -eq -1)) {
    throw "FootIkToggleFrame and FootIkToggleEnabled must be specified together."
}
foreach ($entry in @($Command) + @($ActorCommand)) {
    if ($entry -match '[|\r\n]') {
        throw "Retail oracle commands cannot contain pipe or newline characters: $entry"
    }
}
if ($DriveCommand -match '[|\r\n]') {
    throw "Retail oracle drive command cannot contain pipe or newline characters: $DriveCommand"
}

$gameRootPath = Resolve-AbsolutePath $GameRoot
$loader = Join-Path $gameRootPath "nvse_loader.exe"
$gameExe = Join-Path $gameRootPath "FalloutNV.exe"
$sourcePlugin = Resolve-AbsolutePath $PluginDll
$output = Resolve-AbsolutePath $OutputPath
$pluginDirectory = Join-Path $gameRootPath "Data\NVSE\Plugins"
$installedPlugin = Join-Path $pluginDirectory "nvse_retail_oracle.dll"
$backupPlugin = "$installedPlugin.nikami-backup-$PID"

foreach ($required in @($loader, $gameExe, $sourcePlugin)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing required retail-oracle file: $required"
    }
}
if (Get-Process -Name "FalloutNV" -ErrorAction SilentlyContinue) {
    throw "FalloutNV is already running. Close it before starting an isolated oracle capture."
}

New-Item -ItemType Directory -Force -Path $pluginDirectory | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Force
}

$environment = [ordered]@{
    NIKAMI_ORACLE_OUTPUT = $output
    NIKAMI_ORACLE_SAMPLE_EVERY = [string]$SampleEvery
    NIKAMI_ORACLE_MAX_FRAMES = [string]$MaxFrames
    NIKAMI_ORACLE_TARGET_FORM = $TargetForm
    NIKAMI_ORACLE_EQUIP_FORM = $EquipForm
    NIKAMI_ORACLE_ALL_HIGH_ACTORS = if ($CaptureAnimation) { "1" } else { "0" }
    NIKAMI_ORACLE_CAPTURE_ANIMATION = if ($CaptureAnimation) { "1" } else { "0" }
    NIKAMI_ORACLE_SAVE = $SaveName
    NIKAMI_ORACLE_PLAY_GROUP = $PlayGroup
    NIKAMI_ORACLE_DRIVE_COMMAND = $DriveCommand
    NIKAMI_ORACLE_PREPARE_ACTOR_FRAME = [string]$PrepareActorFrame
    NIKAMI_ORACLE_EQUIP_ACTOR_FRAME = [string]$EquipActorFrame
    NIKAMI_ORACLE_DRIVE_ACTOR_FRAME = [string]$DriveActorFrame
    NIKAMI_ORACLE_FOOT_IK_TOGGLE_FRAME = [string]$FootIkToggleFrame
    NIKAMI_ORACLE_FOOT_IK_TOGGLE_ENABLED = if ($FootIkToggleEnabled -eq 1) { "1" } else { "0" }
    NIKAMI_ORACLE_QUEST_FORMS = (@($QuestForm) -join ",")
    NIKAMI_ORACLE_GLOBAL_FORMS = (@($GlobalForm) -join ",")
    NIKAMI_ORACLE_COMMANDS = (@($Command) -join "|")
    NIKAMI_ORACLE_ACTOR_COMMANDS = (@($ActorCommand) -join "|")
    NIKAMI_ORACLE_BEFORE_FRAME = [string]$BeforeFrame
    NIKAMI_ORACLE_COMMAND_FRAME = [string]$CommandFrame
    NIKAMI_ORACLE_AFTER_FRAME = [string]$AfterFrame
    NIKAMI_ORACLE_SET_STAGE_QUEST = $SetStageQuestForm
    NIKAMI_ORACLE_SET_STAGE_INDEX = [string]$SetStageIndex
    NIKAMI_ORACLE_EXIT_WHEN_DONE = "1"
}
$previousEnvironment = @{}
$gameProcess = $null
$hadInstalledPlugin = Test-Path -LiteralPath $installedPlugin -PathType Leaf

try {
    if ($hadInstalledPlugin) {
        if (Test-Path -LiteralPath $backupPlugin) {
            throw "Refusing to overwrite stale oracle backup: $backupPlugin"
        }
        Move-Item -LiteralPath $installedPlugin -Destination $backupPlugin
    }
    Copy-Item -LiteralPath $sourcePlugin -Destination $installedPlugin

    foreach ($name in $environment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $environment[$name], "Process")
    }

    $startedAt = Get-Date
    $launcherProcess = Start-Process -FilePath $loader -WorkingDirectory $gameRootPath -WindowStyle Hidden -PassThru
    $launchDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $launchDeadline -and $null -eq $gameProcess) {
        $gameProcess = Get-Process -Name "FalloutNV" -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
            Select-Object -First 1
        if ($null -eq $gameProcess) {
            Start-Sleep -Milliseconds 250
        }
    }
    if ($null -eq $gameProcess) {
        throw "nvse_loader did not start FalloutNV within 20 seconds (loader PID $($launcherProcess.Id))."
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $gameProcess.HasExited -and (Get-Date) -lt $deadline) {
        $gameProcess.WaitForExit(1000) | Out-Null
        $gameProcess.Refresh()
    }
    if (-not $gameProcess.HasExited) {
        Stop-Process -Id $gameProcess.Id -Force
        $gameProcess.WaitForExit()
        throw "Retail oracle timed out after $TimeoutSeconds seconds."
    }
    $exitCode = $null
    try { $exitCode = $gameProcess.ExitCode } catch { $exitCode = $null }
    if ($null -ne $exitCode -and $exitCode -ne 0) {
        throw "FalloutNV oracle process exited with code $exitCode."
    }
}
finally {
    if ($null -ne $gameProcess -and -not $gameProcess.HasExited) {
        Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($name in $environment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], "Process")
    }
    if (Test-Path -LiteralPath $installedPlugin) {
        Remove-FileWithRetry -Path $installedPlugin
    }
    if ($hadInstalledPlugin -and (Test-Path -LiteralPath $backupPlugin)) {
        Move-Item -LiteralPath $backupPlugin -Destination $installedPlugin
    }
}

if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Retail oracle produced no output: $output"
}

$events = @(Get-Content -LiteralPath $output | ForEach-Object { $_ | ConvertFrom-Json })
$faults = @($events | Where-Object { $_.event -match 'fault' })
$snapshots = @($events | Where-Object { $_.event -eq "behavior-snapshot" })
$complete = @($events | Where-Object { $_.event -eq "capture-complete" })
if ($faults.Count -gt 0) {
    throw "Retail oracle reported $($faults.Count) capture fault(s)."
}
if (@($snapshots | Where-Object { $_.label -eq "before" }).Count -ne 1 -or
    @($snapshots | Where-Object { $_.label -eq "after" }).Count -ne 1) {
    throw "Retail oracle did not produce exactly one before and one after behavior snapshot."
}
if ($complete.Count -ne 1) {
    throw "Retail oracle did not report capture completion."
}

[pscustomobject][ordered]@{
    schema = "nikami-fnv-retail-oracle-run/v1"
    output = $output
    bytes = (Get-Item -LiteralPath $output).Length
    save = $SaveName
    quests = @($QuestForm)
    globals = @($GlobalForm)
    commands = @($Command)
    actorCommands = @($ActorCommand)
    setStageQuestForm = $SetStageQuestForm
    setStageIndex = $SetStageIndex
    captureAnimation = [bool]$CaptureAnimation
    sampleEvery = $SampleEvery
    targetForm = $TargetForm
    equipForm = $EquipForm
    playGroup = $PlayGroup
    driveCommand = $DriveCommand
    prepareActorFrame = $PrepareActorFrame
    equipActorFrame = $EquipActorFrame
    driveActorFrame = $DriveActorFrame
    footIkToggleFrame = $FootIkToggleFrame
    footIkToggleEnabled = $FootIkToggleEnabled
    before = @($snapshots | Where-Object { $_.label -eq "before" } | Select-Object -First 1)
    after = @($snapshots | Where-Object { $_.label -eq "after" } | Select-Object -First 1)
    status = "captured"
}
