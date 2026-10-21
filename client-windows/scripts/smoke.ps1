param(
    [string]$Recorder = (Join-Path $PSScriptRoot '../Recorder/bin/Release/net8.0-windows10.0.19041.0/zsir-recorder.exe'),
    [string]$Output = (Join-Path $env:TEMP ('zsir-smoke-' + [guid]::NewGuid())),
    [int]$Duration = 10,
    [switch]$PlayTone,
    [switch]$KillTest
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
$OutputEncoding = [Console]::OutputEncoding
$Recorder = (Resolve-Path $Recorder).Path
$ffmpeg = Join-Path (Split-Path $Recorder) 'ffmpeg/ffmpeg.exe'
$ffprobe = Join-Path (Split-Path $Recorder) 'ffmpeg/ffprobe.exe'
New-Item -ItemType Directory $Output | Out-Null
$Output = (Resolve-Path $Output).Path
$devices = & $Recorder devices --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'devices failed' }
$devices | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Output 'devices.json')
$pf = Start-Process $Recorder -ArgumentList @('preflight', '--json') -PassThru -Wait -RedirectStandardOutput (Join-Path $Output 'preflight.raw.json') -RedirectStandardError (Join-Path $Output 'preflight.stderr.txt')
$preflight = Get-Content (Join-Path $Output 'preflight.raw.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$preflight | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Output 'preflight.json')
if ($devices.cameras.Count -eq 0 -and !($preflight.errors | Where-Object { $_ -like 'CAM_NOT_FOUND:*' })) { throw 'Missing CAM_NOT_FOUND' }
if (!$preflight.screen.ok) { throw 'screen preflight failed; run in the logged-in desktop, not SSH session 0' }
$player = $null
try {
    if ($PlayTone) {
        $wave = Join-Path $Output 'test-tone.wav'
        & $ffmpeg -v error -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' -af 'volume=0.15' -ac 2 $wave
        if ($LASTEXITCODE -ne 0) { throw 'tone generation failed' }
        $player = New-Object System.Media.SoundPlayer $wave
        $player.PlayLooping()
    }
    $recording = Join-Path $Output 'recording'
    $stdout = Join-Path $Output 'capture.jsonl'
    $stderr = Join-Path $Output 'capture.stderr.txt'
    $process = Start-Process $Recorder -ArgumentList @('capture', '--tracks', 'screen', '--duration', $Duration, '--out', ('"' + $recording + '"')) -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    # Cache the process handle before Refresh/HasExited; Windows PowerShell otherwise loses ExitCode.
    $null = $process.Handle
    $cpu = @()
    $previous = @{}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastTime = 0.0
    while (!$process.HasExited) {
        Start-Sleep -Seconds 1
        $now = $watch.Elapsed.TotalSeconds
        $sum = 0.0
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" | Select-Object -ExpandProperty ProcessId)
        foreach ($item in @(Get-Process -Id (@($process.Id) + $children) -ErrorAction SilentlyContinue)) {
            if ($previous.ContainsKey($item.Id)) { $sum += [Math]::Max(0, $item.CPU - $previous[$item.Id]) }
            $previous[$item.Id] = $item.CPU
        }
        $cpu += 100 * $sum / ($now - $lastTime) / [Environment]::ProcessorCount
        $lastTime = $now
        if ($KillTest -and $now -gt 12) {
            & taskkill /PID $process.Id /F | Out-Null
            foreach ($child in $children) {
                $remaining = Get-Process -Id $child -ErrorAction SilentlyContinue
                if ($remaining -and !$remaining.WaitForExit(10000)) {
                    & taskkill /PID $child /F | Out-Null
                    throw 'ffmpeg did not exit on recorder pipe EOF'
                }
            }
            break
        }
        if ($now -gt $Duration + 120) { & taskkill /PID $process.Id /T /F | Out-Null; throw 'capture timed out' }
        $process.Refresh()
    }
    $process.WaitForExit()
    if (!$KillTest -and $process.ExitCode -ne 0) { throw "capture exit $($process.ExitCode)" }
    $file = Join-Path $recording 'screen.mp4'
    $probeText = & $ffprobe -v error -show_streams -show_format -of json $file
    if ($LASTEXITCODE -ne 0) { throw 'ffprobe failed' }
    $probeText | Set-Content (Join-Path $Output 'ffprobe.json')
    $probe = $probeText | ConvertFrom-Json
    if ($KillTest -and ([double]$probe.format.duration -lt 2 -or [double]$probe.format.duration -gt 15)) { throw 'invalid recovered duration' }
    if (!$KillTest -and [Math]::Abs([double]$probe.format.duration - $Duration) -gt 1) { throw 'duration outside tolerance' }
    if (@($probe.streams | Where-Object codec_name -eq 'h264').Count -ne 1 -or @($probe.streams | Where-Object codec_name -eq 'aac').Count -ne 1) { throw 'missing H264/AAC' }
    $decode = Start-Process $ffmpeg -ArgumentList @('-hide_banner', '-i', ('"' + $file + '"'), '-vn', '-af', 'volumedetect', '-f', 'null', 'NUL') -Wait -PassThru -RedirectStandardError (Join-Path $Output 'audio-levels.txt')
    if ($decode.ExitCode -ne 0) { throw 'audio decode failed' }
    if ($PlayTone) {
        $levels = Get-Content (Join-Path $Output 'audio-levels.txt') -Raw
        if ($levels -notmatch 'max_volume: (-?[0-9.]+) dB' -or [double]$Matches[1] -lt -80) { throw 'loopback has no waveform' }
    }
    $decode = Start-Process $ffmpeg -ArgumentList @('-v', 'error', '-i', ('"' + $file + '"'), '-map', '0:v', '-f', 'null', 'NUL') -Wait -PassThru -RedirectStandardError (Join-Path $Output 'video-decode.txt')
    if ($decode.ExitCode -ne 0) { throw 'video decode failed' }
    $summary = [ordered]@{ result='PASS'; duration=[double]$probe.format.duration; killed=[bool]$KillTest; loopbackTone=[bool]$PlayTone; cpuAveragePercent=($cpu | Measure-Object -Average).Average; cpuMaxPercent=($cpu | Measure-Object -Maximum).Maximum; logicalProcessors=[Environment]::ProcessorCount; output=$Output }
    $summary | ConvertTo-Json | Set-Content (Join-Path $Output 'result.json')
    $summary | ConvertTo-Json
} finally { if ($player) { $player.Stop(); $player.Dispose() } }
