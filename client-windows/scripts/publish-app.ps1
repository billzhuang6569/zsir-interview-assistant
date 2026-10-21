param([string]$Output = "$PSScriptRoot/../publish-app")
$ErrorActionPreference = 'Stop'
# Offline-capable after NuGet packages/runtime packs have been restored.
dotnet publish "$PSScriptRoot/../App" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:NuGetAudit=false -o $Output
if ($LASTEXITCODE -ne 0) { throw 'App publish failed' }
dotnet publish "$PSScriptRoot/../Recorder" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:NuGetAudit=false -o $Output
if ($LASTEXITCODE -ne 0) { throw 'Recorder publish failed' }
if (!(Test-Path "$Output/ffmpeg/ffmpeg.exe")) { throw 'Missing ffmpeg; run fetch-ffmpeg.ps1 first' }
