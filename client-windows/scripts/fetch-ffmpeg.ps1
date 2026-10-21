param([string]$Archive)
$ErrorActionPreference = 'Stop'
# Pin the LGPL build; never substitute GPL/libx264 builds.
$url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-20-13-08/ffmpeg-n8.1.3-18-g46d899d7a0-win64-lgpl-8.1.zip'
$sha256 = '26634a5e06429c4f51ed08ba518923f928c5e4a49ed0ee62f701e035227b91a7'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('zsir-ffmpeg-' + [guid]::NewGuid())
New-Item -ItemType Directory $temp | Out-Null
try {
    if (!$Archive) {
        if (!$env:HTTPS_PROXY) { throw 'Set HTTPS_PROXY for download, or pass -Archive <zip> downloaded on the Mac.' }
        $Archive = Join-Path $temp 'ffmpeg.zip'
        Invoke-WebRequest -Uri $url -Proxy $env:HTTPS_PROXY -OutFile $Archive -UseBasicParsing
    }
    if ((Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha256) { throw 'FFmpeg archive checksum mismatch' }
    Expand-Archive -Path $Archive -DestinationPath (Join-Path $temp 'unpacked')
    $root = Get-ChildItem (Join-Path $temp 'unpacked') -Directory | Select-Object -First 1
    $target = Join-Path $PSScriptRoot '../Recorder/ffmpeg'
    New-Item -ItemType Directory $target -Force | Out-Null
    Copy-Item (Join-Path $root.FullName 'bin/ffmpeg.exe'), (Join-Path $root.FullName 'bin/ffprobe.exe'), (Join-Path $root.FullName 'LICENSE.txt') $target
    @("Source and build scripts: https://github.com/BtbN/FFmpeg-Builds", "Archive: $url", "SHA256: $sha256") | Set-Content (Join-Path $target 'BUILD.txt')
    & (Join-Path $target 'ffmpeg.exe') -version
    if ($LASTEXITCODE -ne 0) { throw 'ffmpeg -version failed' }
} finally { Remove-Item $temp -Recurse -Force }
