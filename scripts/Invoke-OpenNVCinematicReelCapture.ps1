[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [string]$WorldsRoot = '',
    [string]$Godot = '',
    [ValidateRange(120, 1200)][int]$TimeoutSeconds = 900
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($WorldsRoot)) { $WorldsRoot = Split-Path -Parent $PSScriptRoot }
$WorldsRoot = [IO.Path]::GetFullPath($WorldsRoot)
. (Join-Path $PSScriptRoot 'WorldViewerPaths.ps1')
$Godot = Resolve-NikamiPath -ParameterValue $Godot -EnvName 'NIKAMI_GODOT_BINARY' -ConfigName 'godotBinary'
if ([string]::IsNullOrWhiteSpace($Godot)) { $godotCommand=Get-Command godot4,godot -ErrorAction SilentlyContinue|Select-Object -First 1;if($null-ne$godotCommand){$Godot=$godotCommand.Source} }
if ([string]::IsNullOrWhiteSpace($Godot)) { throw 'Missing Godot executable. Set -Godot, env:NIKAMI_GODOT_BINARY, local/paths.json:godotBinary, or add Godot to PATH.' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if (Test-Path -LiteralPath $OutputRoot) { throw "Refusing to overwrite cinematic capture: $OutputRoot" }
$projectRoot=Join-Path $WorldsRoot 'godot-fnv'; $scenePack=Join-Path $projectRoot 'generated\cinematics\scene-pack.json'
foreach($required in @($Godot,$scenePack)){if(-not(Test-Path $required -PathType Leaf)){throw "Missing cinematic input: $required"}}
foreach($tool in @('ffmpeg','ffprobe')){if($null -eq(Get-Command $tool -ErrorAction SilentlyContinue|Select-Object -First 1)){throw "$tool is required"}}
$running=@(Get-CimInstance Win32_Process|Where-Object{$_.Name -match '^(Godot|openmw|FalloutNV|nvse_loader).*\.exe$'});if($running.Count){throw "Capture engine already active: $($running.ProcessId -join ', ')"}
New-Item -ItemType Directory $OutputRoot|Out-Null;$nativeRoot=Join-Path $OutputRoot 'native-source-frames';New-Item -ItemType Directory $nativeRoot|Out-Null
$raw=Join-Path $OutputRoot 'OpenNV-Four-Scenes-native-60fps.avi';$engineReport=Join-Path $OutputRoot 'cinematic-report.json';$godotLog=Join-Path $OutputRoot 'godot.log';$godotOut=Join-Path $OutputRoot 'godot.console.log';$godotErr=Join-Path $OutputRoot 'godot.stderr.log'
$names=@('OpenNV-Goodsprings-15s-60fps.mp4','OpenNV-Novac-15s-60fps.mp4','OpenNV-Strip-15s-60fps.mp4','OpenNV-Vault21-Inside-Outside-15s-60fps.mp4')
$envNames=@('FNV_GODOT_SKIP_INTRO','FNV_GODOT_AUTOCONTINUE','FNV_GODOT_CINEMATIC_REEL','FNV_GODOT_MOVIE_MODE','FNV_GODOT_FORCE_SYNC_LOAD','FNV_GODOT_RING_PATH','FNV_GODOT_NATIVE_FRAME_DIR','FNV_GODOT_CINEMATIC_REPORT','FNV_GODOT_OPENXR','FNV_GODOT_SELF_DRIVE');$prior=@{};foreach($n in $envNames){$prior[$n]=[Environment]::GetEnvironmentVariable($n,'Process')}
$gp=$null;$startedAt=Get-Date
try{
 $env:FNV_GODOT_SKIP_INTRO='1';$env:FNV_GODOT_AUTOCONTINUE='1';$env:FNV_GODOT_CINEMATIC_REEL='1';$env:FNV_GODOT_MOVIE_MODE='1';$env:FNV_GODOT_FORCE_SYNC_LOAD='1';$env:FNV_GODOT_RING_PATH='res://generated/cinematics/scene-pack.json';$env:FNV_GODOT_NATIVE_FRAME_DIR=$nativeRoot.Replace('\','/');$env:FNV_GODOT_CINEMATIC_REPORT=$engineReport.Replace('\','/');Remove-Item Env:FNV_GODOT_OPENXR,Env:FNV_GODOT_SELF_DRIVE -ErrorAction SilentlyContinue
 $gp=Start-Process -FilePath $Godot -ArgumentList @('--path',$projectRoot,'--rendering-method','gl_compatibility','--resolution','1280x720','--fixed-fps','60','--disable-vsync','--write-movie',$raw,'--log-file',$godotLog) -RedirectStandardOutput $godotOut -RedirectStandardError $godotErr -PassThru
 if(-not $gp.WaitForExit($TimeoutSeconds*1000)){throw 'Godot native movie capture exceeded timeout'};$gp.WaitForExit();$gp.Refresh();if($null -ne $gp.ExitCode -and $gp.ExitCode -ne 0){throw "Godot movie capture failed ($($gp.ExitCode))"}
}finally{if($null-ne$gp-and-not$gp.HasExited){Stop-Process -Id $gp.Id -Force -ErrorAction SilentlyContinue};foreach($n in $prior.Keys){if($null-eq$prior[$n]){Remove-Item ('Env:'+$n) -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($n,[string]$prior[$n],'Process')}}}
if(-not(Test-Path $engineReport)){throw 'Missing engine cinematic report'};if(-not(Test-Path $raw)){throw 'Missing native Godot movie'}
$engine=Get-Content $engineReport -Raw|ConvertFrom-Json;$start=[double]$engine.startFrame/60.0;$clips=@()
for($i=0;$i-lt 4;$i++){$clip=Join-Path $OutputRoot $names[$i];$offset=$start+15*$i;& ffmpeg -hide_banner -loglevel error -y -ss ([string]$offset) -i $raw -t 15 -map 0:v:0 -map 0:a:0 -vf 'scale=1280:720:flags=lanczos' -c:v h264_nvenc -preset p5 -cq 18 -b:v 0 -r 60 -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart $clip;if($LASTEXITCODE-ne 0){throw "Clip $i encode failed"};$p=& ffprobe -v error -show_entries format=duration:stream=codec_type,width,height,avg_frame_rate -of json -- $clip|ConvertFrom-Json;$v=@($p.streams|? codec_type -eq video);$a=@($p.streams|? codec_type -eq audio);$clips+=[ordered]@{scene=@('goodsprings','novac','strip','vault21')[$i];path=$clip;durationSeconds=[double]$p.format.duration;width=$v[0].width;height=$v[0].height;fps=$v[0].avg_frame_rate;audioStreams=$a.Count}}
$native=@(Get-ChildItem $nativeRoot -Filter '*.png' -File);$passed=$engine.status-eq'pass'-and((@($engine.scenes)-join'|')-eq'goodsprings|novac|strip|vault21')-and[bool]$engine.vaultDoorActivated-and[bool]$engine.vaultInteriorEntered-and$clips.Count-eq 4-and@($clips|?{$_.durationSeconds-lt 14.9-or$_.width-ne 1280-or$_.height-ne 720-or$_.fps-ne'60/1'-or$_.audioStreams-ne 1}).Count-eq 0
$paths=@($raw,$engineReport,$godotLog,$godotOut,$godotErr)+@($clips.path)+@($native.FullName);$artifacts=@($paths|?{Test-Path $_ -PathType Leaf}|%{$f=Get-Item $_;[ordered]@{path=$f.FullName;bytes=$f.Length;sha256=(Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
$report=[ordered]@{schema='nikami-opennv-four-scene-cinematic-capture/v1';status=$(if($passed){'pass'}else{'fail'});startedAt=$startedAt.ToString('o');completedAt=(Get-Date).ToString('o');capture=[ordered]@{method='Godot native fixed-step 60 FPS movie writer with engine-owned cinematic rails and native game audio';selfDriven=$true;windowsAppControlUsed=$false;foregroundActivationUsed=$false;foregroundInputInjected=$false;outputOverwritten=$false};engine=$engine;clips=$clips;nativeFrameCount=$native.Count;artifacts=$artifacts};$reportPath=Join-Path $OutputRoot 'opennv-cinematic-reel-report.json';[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));$report|ConvertTo-Json -Depth 10;if(-not$passed){throw "Cinematic acceptance failed: $reportPath"}
