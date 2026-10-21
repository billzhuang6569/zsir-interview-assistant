param([string]$OutputRoot, [ValidateSet("x64", "arm64")][string]$Architecture="x64")
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$rid='win-'+$Architecture
if(!$OutputRoot){$OutputRoot=Join-Path $root 'dist\release'}
$stage=Join-Path $OutputRoot ('ZSirCapture-0.1.0-preview.1-windows-'+$Architecture)
if(Test-Path $stage){throw "Package directory already exists: $stage"}
dotnet publish (Join-Path $root 'clients\windows\ZSirCapture.Windows.csproj') -c Release -r $rid -p:PlatformTarget=$Architecture --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $stage --nologo
if($LASTEXITCODE -ne 0){throw 'Publish failed'}
Copy-Item (Join-Path $root 'clients\windows\Install-RecordingTools.cmd') $stage
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
Copy-Item (Join-Path $root 'docs\releases\0.1.0-preview.1.md') (Join-Path $stage 'README.md')
# FFmpeg remains an upstream download, not a redistributed release asset.
if(Test-Path (Join-Path $stage 'tools')){throw 'Do not bundle FFmpeg binaries'}
Compress-Archive -Path $stage -DestinationPath "$stage.zip"
Get-FileHash "$stage.zip" -Algorithm SHA256
