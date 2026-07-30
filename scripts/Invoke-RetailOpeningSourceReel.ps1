[CmdletBinding()]
param(
    [string]$NewVegasVideo =
        "D:\SteamLibrary\steamapps\common\Fallout New Vegas\Data\Video\FNVIntro.bik",
    [string]$TtwVideo =
        "D:\Modlists\fnv\mods\Tale of Two Wastelands - OpenMW\Video\Fallout INTRO Vsk.bik",
    [ValidateRange(1, 120)]
    [int]$DurationSeconds = 20,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-VideoInput {
    param(
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string]$Path
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Missing $Label video: $resolved"
    }
    $probe = & ffprobe -v error -show_entries `
        "stream=codec_type,codec_name,width,height,sample_rate,channels:format=duration" `
        -of json $resolved | ConvertFrom-Json
    $video = @($probe.streams | Where-Object { $_.codec_type -eq "video" })
    $audio = @($probe.streams | Where-Object { $_.codec_type -eq "audio" })
    if ($video.Count -ne 1 -or [string]$video[0].codec_name -ne "binkvideo") {
        throw "$Label is not a single Bink video stream: $resolved"
    }
    if ($audio.Count -lt 1) {
        throw "$Label has no audio stream: $resolved"
    }
    return [pscustomobject]@{
        label = $Label
        path = $resolved
        sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
        durationSeconds = [double]$probe.format.duration
        video = $video[0]
        audio = $audio[0]
    }
}

if ($null -eq (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or
    $null -eq (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    throw "ffmpeg and ffprobe must be available on PATH."
}

$newVegas = Assert-VideoInput -Label "Retail Fallout: New Vegas" -Path $NewVegasVideo
$ttw = Assert-VideoInput -Label "Retail TTW / Fallout 3" -Path $TtwVideo
if ($newVegas.durationSeconds -lt $DurationSeconds -or $ttw.durationSeconds -lt $DurationSeconds) {
    throw "Both source videos must be at least $DurationSeconds seconds long."
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $OutputRoot = "D:\code\nikami-worlds\run\retail-opening-source-reel-$stamp"
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Refusing to overwrite an existing retail opening source reel: $OutputRoot"
}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null

$videoPath = Join-Path $OutputRoot "Retail-FNV-and-TTW-opening-intro-20s-synchronized.mp4"
# FFmpeg filter syntax uses ':' as an option separator, including on Windows.
# Escape the drive colon before interpolating the absolute font path.
$fontPath = "C\:/Windows/Fonts/segoeuib.ttf"
$filter = @(
    "[0:v]trim=duration=$DurationSeconds,setpts=PTS-STARTPTS,drawtext=fontfile='$fontPath':text='RETAIL FALLOUT NEW VEGAS':x=24:y=24:fontsize=32:fontcolor=white:box=1:boxcolor=0x000000AA:boxborderw=12[fnv]",
    "[1:v]trim=duration=$DurationSeconds,setpts=PTS-STARTPTS,drawtext=fontfile='$fontPath':text='RETAIL TTW / FALLOUT 3 OPENING':x=24:y=24:fontsize=32:fontcolor=white:box=1:boxcolor=0x000000AA:boxborderw=12[ttw]",
    "[fnv][ttw]hstack=inputs=2[video]",
    "[0:a]atrim=duration=$DurationSeconds,asetpts=PTS-STARTPTS,asplit=2[fnvMix][fnvAudio]",
    "[1:a]atrim=duration=$DurationSeconds,asetpts=PTS-STARTPTS,asplit=2[ttwMix][ttwAudio]",
    "[fnvMix][ttwMix]amix=inputs=2:weights='0.5 0.5':normalize=0[mix]"
) -join ';'

& ffmpeg -hide_banner -nostdin -y `
    -i $newVegas.path -i $ttw.path `
    -filter_complex $filter `
    -map "[video]" -map "[mix]" -map "[fnvAudio]" -map "[ttwAudio]" `
    -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p `
    -c:a aac -b:a 192k `
    -metadata:s:a:0 title="Synchronized reference mix" `
    -metadata:s:a:1 title="Retail Fallout: New Vegas" `
    -metadata:s:a:2 title="Retail TTW / Fallout 3" `
    -metadata title="Retail FNV and TTW opening sources, synchronized" `
    -movflags +faststart $videoPath
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $videoPath -PathType Leaf)) {
    throw "ffmpeg failed to create the synchronized retail opening reel."
}

$outputProbe = & ffprobe -v error -show_entries `
    "format=duration:stream=index,codec_type,codec_name,width,height,sample_rate,channels" `
    -of json $videoPath | ConvertFrom-Json
$manifest = [ordered]@{
    schema = "opennv-retail-opening-source-reel/v1"
    status = "pass"
    purpose = "Synchronized licensed retail source-asset baseline. This is not an in-engine capture."
    durationSeconds = $DurationSeconds
    policy = [ordered]@{
        engineLaunched = $false
        windowsAppControlUsed = $false
        foregroundActivationUsed = $false
        foregroundInputInjected = $false
        sourceAssetsUnmodified = $true
    }
    sources = @($newVegas, $ttw)
    output = [ordered]@{
        path = $videoPath
        sha256 = (Get-FileHash -LiteralPath $videoPath -Algorithm SHA256).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $videoPath).Length
        probe = $outputProbe
        audioTracks = @(
            "0: synchronized reference mix",
            "1: retail Fallout: New Vegas",
            "2: retail TTW / Fallout 3"
        )
    }
}
$manifestPath = Join-Path $OutputRoot "retail-opening-source-reel-manifest.json"
[IO.File]::WriteAllText(
    $manifestPath,
    (($manifest | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false))
$manifest | ConvertTo-Json -Depth 12
