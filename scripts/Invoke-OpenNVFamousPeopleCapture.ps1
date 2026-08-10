[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [string]$WorldsRoot='D:\code\nikami-worlds',
    [string]$Godot='D:\code\gd\Godot_v4.6.3-stable_win64.exe',
    [ValidateRange(45,300)][int]$TimeoutSeconds=120
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw "Refusing to overwrite famous-people capture: $OutputRoot"}
$projectRoot=Join-Path $WorldsRoot 'godot-fnv';$scenePack=Join-Path $projectRoot 'generated\cinematics\scene-pack.json'
foreach($required in @($Godot,$scenePack)){if(-not(Test-Path $required -PathType Leaf)){throw "Missing portrait input: $required"}}
if($null-eq(Get-Command ffmpeg -ErrorAction SilentlyContinue)){throw 'ffmpeg is required'}
$running=@(Get-CimInstance Win32_Process|Where-Object{$_.Name-match'^(Godot|openmw|FalloutNV|nvse_loader).*\.exe$'});if($running.Count){throw "Capture engine already active: $($running.ProcessId -join ', ')"}
New-Item -ItemType Directory $OutputRoot|Out-Null;$nativeRoot=Join-Path $OutputRoot 'native-source-frames';New-Item -ItemType Directory $nativeRoot|Out-Null
$engineReport=Join-Path $OutputRoot 'portrait-engine-report.json';$godotLog=Join-Path $OutputRoot 'godot.log';$godotOut=Join-Path $OutputRoot 'godot.console.log';$godotErr=Join-Path $OutputRoot 'godot.stderr.log'
$envNames=@('FNV_GODOT_SKIP_INTRO','FNV_GODOT_AUTOCONTINUE','FNV_GODOT_CINEMATIC_REEL','FNV_GODOT_PORTRAIT_REEL','FNV_GODOT_RING_PATH','FNV_GODOT_NATIVE_FRAME_DIR','FNV_GODOT_CINEMATIC_REPORT','FNV_GODOT_OPENXR','FNV_GODOT_SELF_DRIVE');$prior=@{};foreach($n in $envNames){$prior[$n]=[Environment]::GetEnvironmentVariable($n,'Process')}
$gp=$null;$startedAt=Get-Date
try{
 $env:FNV_GODOT_SKIP_INTRO='1';$env:FNV_GODOT_AUTOCONTINUE='1';$env:FNV_GODOT_CINEMATIC_REEL='1';$env:FNV_GODOT_PORTRAIT_REEL='1';$env:FNV_GODOT_RING_PATH='res://generated/cinematics/scene-pack.json';$env:FNV_GODOT_NATIVE_FRAME_DIR=$nativeRoot.Replace('\','/');$env:FNV_GODOT_CINEMATIC_REPORT=$engineReport.Replace('\','/');Remove-Item Env:FNV_GODOT_OPENXR,Env:FNV_GODOT_SELF_DRIVE -ErrorAction SilentlyContinue
 $gp=Start-Process -FilePath $Godot -ArgumentList @('--path',$projectRoot,'--rendering-method','gl_compatibility','--log-file',$godotLog) -RedirectStandardOutput $godotOut -RedirectStandardError $godotErr -PassThru
 if(-not$gp.WaitForExit($TimeoutSeconds*1000)){throw 'Godot portrait capture exceeded timeout'};$gp.WaitForExit();$gp.Refresh();if($null-ne$gp.ExitCode-and$gp.ExitCode-ne 0){throw "Godot portrait capture failed ($($gp.ExitCode))"}
}finally{if($null-ne$gp-and-not$gp.HasExited){Stop-Process -Id $gp.Id -Force -ErrorAction SilentlyContinue};foreach($n in $prior.Keys){if($null-eq$prior[$n]){Remove-Item ('Env:'+$n) -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($n,[string]$prior[$n],'Process')}}}
if(-not(Test-Path $engineReport)){throw 'Missing portrait engine report'};$engine=Get-Content $engineReport -Raw|ConvertFrom-Json
$expected=@('easy-pete','arcade-gannon','vulpes-inculta','victor');$native=@(Get-ChildItem $nativeRoot -Filter 'portrait-*.png' -File|Sort-Object Name);if($native.Count-ne 8){throw "Expected eight native front/back candidates, found $($native.Count)"}
$photos=@();foreach($source in $native){$name=('OpenNV-{0}.jpg' -f $source.BaseName);$path=Join-Path $OutputRoot $name;& ffmpeg -hide_banner -loglevel error -y -i $source.FullName -vf 'scale=1280:720:flags=lanczos' -frames:v 1 -q:v 2 $path;if($LASTEXITCODE-ne 0){throw "Portrait encode failed: $name"};$photos+=[ordered]@{id=$source.BaseName;path=$path;bytes=(Get-Item $path).Length}}
$passed=$engine.status-eq'pass'-and((@($engine.scenes)-join'|')-eq($expected-join'|'))-and$photos.Count-eq 8
$paths=@($engineReport,$godotLog,$godotOut,$godotErr)+@($native.FullName)+@($photos.path);$artifacts=@($paths|?{Test-Path $_ -PathType Leaf}|%{$f=Get-Item $_;[ordered]@{path=$f.FullName;bytes=$f.Length;sha256=(Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
$report=[ordered]@{schema='nikami-opennv-famous-people-authored-location-capture/v1';status=$(if($passed){'pass'}else{'fail'});startedAt=$startedAt.ToString('o');completedAt=(Get-Date).ToString('o');capture=[ordered]@{method='Godot-native framebuffer portraits from decoded authored actor references at their original placements';selfDriven=$true;windowsAppControlUsed=$false;foregroundActivationUsed=$false;foregroundInputInjected=$false;outputOverwritten=$false};engine=$engine;photos=$photos;artifacts=$artifacts};$reportPath=Join-Path $OutputRoot 'opennv-famous-people-report.json';[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));$report|ConvertTo-Json -Depth 10;if(-not$passed){throw "Portrait acceptance failed: $reportPath"}
