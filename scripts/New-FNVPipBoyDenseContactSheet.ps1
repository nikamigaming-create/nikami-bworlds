param(
    [Parameter(Mandatory = $true)][string]$Video,
    [Parameter(Mandatory = $true)][string]$Output
)

$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
& $ffmpeg -hide_banner -loglevel error -y -i $Video `
    -vf "fps=4,scale=320:-1,drawtext=fontfile='C\:/Windows/Fonts/consola.ttf':text='%{pts\:hms}':x=6:y=6:fontsize=15:fontcolor=white:box=1:boxcolor=black@0.7,tile=20x16" `
    -frames:v 1 $Output
if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed with exit code $LASTEXITCODE" }
