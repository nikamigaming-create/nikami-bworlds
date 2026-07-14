param(
    [string]$MatrixPath = "catalog/fnv-goodsprings-retail-matrix.json",
    [string]$OutputRoot = "run/openmw-goodsprings-face-roundup-20260713",
    [int]$RunSeconds = 8,
    [int]$ScreenshotFrame = 180,
    [string[]]$Angle = @("front"),
    [string[]]$TargetId = @(),
    [string[]]$SetEnv = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function ConvertTo-FnvRuntimeForm([string]$OpenMwForm) {
    if ($OpenMwForm -notmatch '0x([0-9a-fA-F]+)') {
        return $OpenMwForm
    }
    $value = [Convert]::ToUInt32($Matches[1], 16)
    $runtime = (0x01000000 -bor ($value -band 0x00ffffff))
    return ("FormId:0x{0:x}" -f $runtime)
}

$matrixFile = Resolve-RepoRelativePath $MatrixPath
$outputRootAbs = Resolve-RepoRelativePath $OutputRoot
New-Item -ItemType Directory -Force -Path $outputRootAbs | Out-Null

$matrix = Get-Content -LiteralPath $matrixFile -Raw | ConvertFrom-Json
$runner = Join-Path $PSScriptRoot "Invoke-RealWorldScreenshots.ps1"
$rows = New-Object System.Collections.Generic.List[object]
$angleTable = @{
    front = 0
    left = -70
    right = 70
}
$anglesToCapture = New-Object System.Collections.Generic.List[object]
foreach ($angleNameRaw in $Angle) {
    $angleName = ([string]$angleNameRaw).ToLowerInvariant()
    if (-not $angleTable.ContainsKey($angleName)) {
        throw "Unknown actor roundup angle '$angleNameRaw'. Expected one of: $(@($angleTable.Keys) -join ', ')"
    }
    $anglesToCapture.Add([pscustomobject][ordered]@{
        name = $angleName
        orbitDeg = [float]$angleTable[$angleName]
    }) | Out-Null
}
if ($anglesToCapture.Count -eq 0) {
    throw "No actor roundup angles requested."
}
$targetFilter = @{}
foreach ($filterId in $TargetId) {
    if (-not [string]::IsNullOrWhiteSpace($filterId)) {
        $targetFilter[$filterId] = $true
    }
}

foreach ($target in @($matrix.targets | Where-Object { $_.category -like "*humanoid" })) {
    $id = [string]$target.id
    if ($targetFilter.Count -gt 0 -and -not $targetFilter.ContainsKey($id)) {
        continue
    }
    $ref = ConvertTo-FnvRuntimeForm ([string]$target.reference.openmwForm)
    $cellName = [string]$target.cell.name
    $cellEditor = [string]$target.cell.editorId
    $isExterior = [bool]$target.cell.isExterior
    $startCell = if (-not $isExterior -and -not [string]::IsNullOrWhiteSpace($cellEditor)) {
        $cellEditor
    } elseif (-not [string]::IsNullOrWhiteSpace($cellName)) {
        $cellName
    } elseif (-not [string]::IsNullOrWhiteSpace($cellEditor)) {
        $cellEditor
    } else {
        "Goodsprings"
    }
    $pos = @($target.authoredPlacement.position)
    foreach ($angleSpec in @($anglesToCapture.ToArray())) {
        $angleName = [string]$angleSpec.name
        $caseRoot = Join-Path $outputRootAbs (Join-Path $id $angleName)
        $minForwardDot = if ($angleName -eq "front") { "0.90" } else { "-1.0" }
        $env = @(
            "OPENMW_WORLD_VIEWER_ACTOR_TELEMETRY=1",
            "OPENMW_WORLD_VIEWER_MESH_LOAD_TELEMETRY=1",
            "OPENMW_WORLD_VIEWER_MATERIAL_TELEMETRY=1",
            "OPENMW_FNV_PART_MATRIX_AUDIT=1",
            "OPENMW_WORLD_VIEWER_RENDER_DISABLED_ACTORS=1",
            "OPENMW_PROOF_HIDE_PLAYER_VISUAL=1",
            "OPENMW_WORLD_VIEWER_START_DRY=1",
            "OPENMW_WORLD_VIEWER_START_POS_X=$($pos[0])",
            "OPENMW_WORLD_VIEWER_START_POS_Y=$($pos[1])",
            "OPENMW_WORLD_VIEWER_START_POS_Z=$($pos[2])",
            "OPENMW_WORLD_VIEWER_START_ROT_X=0",
            "OPENMW_WORLD_VIEWER_START_ROT_Y=0",
            "OPENMW_WORLD_VIEWER_START_ROT_Z=0",
            "OPENMW_WORLD_VIEWER_START_CAMERA_MODE=static",
            "OPENMW_WORLD_VIEWER_START_CAMERA_FOLLOW_REF=$ref",
            "OPENMW_WORLD_VIEWER_START_CAMERA_FOLLOW_HEAD=1",
            "OPENMW_WORLD_VIEWER_START_CAMERA_FOLLOW_HEAD_ORBIT_DEG=$($angleSpec.orbitDeg)",
            "OPENMW_WORLD_VIEWER_START_CAMERA_FOLLOW_HEAD_DISTANCE=90",
            "OPENMW_WORLD_VIEWER_START_CAMERA_FOLLOW_HEAD_FOCUS=2",
            "OPENMW_WORLD_VIEWER_START_CAMERA_FOLLOW_HEAD_EYE_Z=16",
            "OPENMW_WORLD_VIEWER_REQUIRE_PORTRAIT_CLEAR=1",
            "OPENMW_WORLD_VIEWER_PORTRAIT_MIN_HEAD_X=0.12",
            "OPENMW_WORLD_VIEWER_PORTRAIT_MAX_HEAD_X=0.88",
            "OPENMW_WORLD_VIEWER_PORTRAIT_MIN_HEAD_Y=0.12",
            "OPENMW_WORLD_VIEWER_PORTRAIT_MAX_HEAD_Y=0.88",
            "OPENMW_WORLD_VIEWER_PORTRAIT_CLEAR_FRAMES=2",
            "OPENMW_WORLD_VIEWER_PORTRAIT_MAX_HAND_OFFSET_Z=28",
            "OPENMW_WORLD_VIEWER_PORTRAIT_MAX_HEAD_MOTION=6",
            "OPENMW_WORLD_VIEWER_PORTRAIT_MIN_FORWARD_DOT=$minForwardDot"
        ) + @($SetEnv)

        Write-Host "Capturing $id/$angleName in $startCell ($ref)"
        $runnerOutput = @(& $runner `
            -WorldId fallout_new_vegas `
            -Mode flat `
            -NoCatalogStart `
            -SkipMenu `
            -StartCell $startCell `
            -OutputRoot $caseRoot `
            -RunSeconds $RunSeconds `
            -CaptureSeconds ([Math]::Max(1, $RunSeconds - 1)) `
            -EngineScreenshotFrames $ScreenshotFrame `
            -CrashReportSettleSeconds 1 `
            -ExtraArgs "--no-sound" `
            -SetEnv $env)

        $last = $runnerOutput[-1]
        $outputDirectory = [string]$last.outputDirectory
        $manifest = if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            Join-Path $outputDirectory "manifest.json"
        } else {
            ""
        }
        $shot = ""
        if (-not [string]::IsNullOrWhiteSpace($manifest) -and (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            $m = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
            $shotObj = @($m.screenshots) | Select-Object -First 1
            if ($null -ne $shotObj) {
                $shot = [string]$shotObj.path
            }
        }
        $rows.Add([pscustomobject][ordered]@{
            id = $id
            angle = $angleName
            orbitDeg = [float]$angleSpec.orbitDeg
            reference = $ref
            startCell = $startCell
            manifest = $manifest
            screenshot = $shot
            log = [string]$last.logPath
            status = [string]$last.status
        }) | Out-Null
    }
}

$indexPath = Join-Path $outputRootAbs "roundup-index.json"
[pscustomobject][ordered]@{
    schema = "nikami-openmw-goodsprings-face-roundup/v1"
    createdAt = (Get-Date).ToString("o")
    rows = @($rows.ToArray())
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $indexPath -Encoding UTF8

[pscustomobject][ordered]@{
    index = $indexPath
    count = $rows.Count
    screenshots = @($rows.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_.screenshot) }).Count
}
