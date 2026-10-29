param([string]$OutputRoot, [ValidateSet("x64", "arm64")][string]$Architecture="x64", [Parameter(Mandatory=$true)][string]$ToolsArchive)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$rid='win-'+$Architecture
if(!$OutputRoot){$OutputRoot=Join-Path $root 'dist\release'}
$version=(Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$stage=Join-Path $OutputRoot ('ZSirCapture-'+$version+'-windows-'+$Architecture)
if(Test-Path $stage){throw "Package directory already exists: $stage"}
dotnet publish (Join-Path $root 'clients\windows\ZSirCapture.Windows.csproj') -c Release -r $rid -p:PlatformTarget=$Architecture --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $stage --nologo
if($LASTEXITCODE -ne 0){throw 'Publish failed'}
# Verified, self-built tools are bundled before the ZIP is produced.
$expected=(Get-Content (Join-Path $root 'clients\windows\recording-tools.sha256') -Raw).Trim().Split(' ')[0]
if((Get-FileHash -LiteralPath $ToolsArchive -Algorithm SHA256).Hash -ne $expected){throw 'Recording tools archive checksum mismatch'}
Expand-Archive -LiteralPath $ToolsArchive -DestinationPath $stage
foreach($file in @('ffmpeg.exe','ffprobe.exe','FFmpeg-LICENSE.txt','x264-LICENSE.txt','SOURCE-NOTICE.md')){
    if(!(Test-Path (Join-Path $stage ('tools\'+$file)))){throw "Missing recording component: $file"}
}
$ffmpeg=Join-Path $stage 'tools\ffmpeg.exe'
$ffprobe=Join-Path $stage 'tools\ffprobe.exe'
foreach($tool in @($ffmpeg,$ffprobe)){
    & $tool -version
    if($LASTEXITCODE -ne 0){throw "Bundled tool cannot run: $tool"}
}
$previewGate=& $ffmpeg -hide_banner -h filter=select 2>&1
if($LASTEXITCODE -ne 0 -or ($previewGate -join "`n") -notmatch 'ZSir preview gate v1\.'){
    throw 'Bundled FFmpeg is missing the required preview production gate'
}
# Exercise actual encoders, muxer and decoder, rather than just checking file presence.
$sample=Join-Path $stage 'package-check.mp4'
& $ffmpeg -v error -nostdin -n -f lavfi -i 'color=c=black:s=64x64:r=30' -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 1 -c:v libx264 -pix_fmt yuv420p -c:a aac $sample
if($LASTEXITCODE -ne 0){throw 'Bundled H.264/AAC encoding failed'}
$media=& $ffprobe -v error -show_streams -of json $sample
if($LASTEXITCODE -ne 0){throw 'Bundled ffprobe failed'}
$codecs=($media|ConvertFrom-Json).streams.codec_name
if('h264' -notin $codecs -or 'aac' -notin $codecs){throw 'Package check missing required tracks'}
& $ffmpeg -v error -xerror -i $sample -f null NUL
if($LASTEXITCODE -ne 0){throw 'Bundled media decode failed'}
$pcm=Join-Path $stage 'package-check.f32'
& $ffmpeg -v error -nostdin -n -i $sample -vn -ac 1 -ar 48000 -f f32le $pcm
if($LASTEXITCODE -ne 0 -or (Get-Item $pcm).Length -le 0){throw 'Bundled PCM analysis output failed'}
& $ffmpeg -v error -i $sample -an -vf 'scale=32:18,signalstats,metadata=print:key=lavfi.signalstats.YAVG' -f null NUL
if($LASTEXITCODE -ne 0){throw 'Bundled video analysis filters failed'}
Remove-Item -LiteralPath $sample,$pcm

$frameworks=(Get-Content (Join-Path $stage 'ZSirCapture.Windows.runtimeconfig.json') -Raw|ConvertFrom-Json).runtimeOptions.includedFrameworks
foreach($framework in $frameworks){
    $pack=Join-Path $env:USERPROFILE ('.nuget\packages\'+$framework.name.ToLower()+'.runtime.'+$rid+'\'+$framework.version)
    $notice=Join-Path $stage ('licenses\'+$framework.name)
    New-Item -ItemType Directory -Path $notice -Force|Out-Null
    $files=@(Get-ChildItem $pack -File|Where-Object {$_.Name -match '^(LICENSE|THIRD-PARTY|THIRD.PARTY)'})
    if(!$files){throw "Runtime license files not found: $pack"}
    $files|Copy-Item -Destination $notice
}
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $stage 'LICENSE.txt')
Copy-Item (Join-Path $root 'clients\windows\INSTALL.md') (Join-Path $stage 'README.md')
Get-FileHash $ffmpeg,$ffprobe -Algorithm SHA256 | ForEach-Object { $_.Hash+'  tools/'+(Split-Path $_.Path -Leaf) } | Set-Content (Join-Path $stage 'TOOLS-SHA256SUMS.txt')
Compress-Archive -Path $stage -DestinationPath "$stage.zip"
Get-FileHash "$stage.zip" -Algorithm SHA256
