param(
    [Parameter(Mandatory = $true)]
    [string]$LogRoot,
    [Parameter(Mandatory = $true)]
    [string]$Output,
    [int]$Seconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$started = Get-Date
$deadline = $started.AddSeconds(45)
$captureLog = $null
while ((Get-Date) -lt $deadline) {
    $captureLog = Get-ChildItem -LiteralPath $LogRoot -Recurse -File -Filter "skyrim_vr.stdout.log" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $started.AddSeconds(-2) } |
        Sort-Object LastWriteTimeUtc |
        Select-Object -Last 1 -ExpandProperty FullName
    if (-not [string]::IsNullOrWhiteSpace($captureLog) -and
        (Select-String -LiteralPath $captureLog -SimpleMatch "proof video: capture started" -Quiet)) {
        break
    }
    Start-Sleep -Milliseconds 100
}
if ([string]::IsNullOrWhiteSpace($captureLog) -or
    -not (Select-String -LiteralPath $captureLog -SimpleMatch "proof video: capture started" -Quiet)) {
    throw "Timed out waiting for OpenMW video capture marker."
}

$temporary = [IO.Path]::ChangeExtension($Output, ".capturing.mp4")
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
& ffmpeg -hide_banner -loglevel warning -y `
    -f gdigrab -framerate 60 -draw_mouse 0 -i "title=OpenMW" -t $Seconds `
    -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -movflags +faststart $temporary
if ($LASTEXITCODE -ne 0) { throw "60 FPS OpenMW window capture failed: $LASTEXITCODE" }
Move-Item -LiteralPath $temporary -Destination $Output -Force
ffprobe -v error -show_entries format=duration,size `
    -show_entries stream=width,height,avg_frame_rate,nb_frames -of json $Output
