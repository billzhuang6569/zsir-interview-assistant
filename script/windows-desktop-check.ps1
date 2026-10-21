# Diagnostic only, not the Windows product client. Run in the signed-in desktop session.
param([Parameter(Mandatory=$true)][string]$FFmpegDirectory)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$folder = Join-Path ([Environment]::GetFolderPath('MyVideos')) ('ZSir Windows Checks\Take-' + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory $folder | Out-Null
$report = [ordered]@{ sessionID=[Diagnostics.Process]::GetCurrentProcess().SessionId; productClient=$false; audioTested=$false; captureBackend='gdigrab'; encoder='libx264'; outputFolder=$folder }
try {
    if ($report.sessionID -eq 0) { throw 'Run this check in the signed-in desktop session, not SSH session 0.' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class DpiCheck { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
    [DpiCheck]::SetProcessDPIAware() | Out-Null
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $width = $bounds.Width - ($bounds.Width % 2)
    $height = $bounds.Height - ($bounds.Height % 2)
    $rate = [int][Math]::Max(12000000, 12000000.0 * $width * $height / (1920*1080))
    $ffmpeg = Join-Path $FFmpegDirectory 'ffmpeg.exe'
    $ffprobe = Join-Path $FFmpegDirectory 'ffprobe.exe'
    $video = Join-Path $folder 'desktop.mp4'
    # Native tool stderr is a log; its exit code determines failure.
    $ErrorActionPreference = 'Continue'
    & $ffmpeg -hide_banner -nostdin -n -f gdigrab -framerate 30 -offset_x $bounds.X -offset_y $bounds.Y -video_size "${width}x${height}" -i desktop -t 10 -an -c:v libx264 -preset veryfast -b:v $rate -g 60 -bf 0 -pix_fmt yuv420p -movflags '+frag_keyframe+empty_moov+default_base_moof' $video 2> (Join-Path $folder 'capture.log')
    $captureExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($captureExit -ne 0) { throw "Capture failed: exit $captureExit; see capture.log" }
    $report.media = (& $ffprobe -v error -show_entries 'stream=codec_name,width,height,avg_frame_rate,nb_frames:format=duration,size' -of json $video | Out-String | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'ffprobe failed' }
    $ErrorActionPreference = 'Continue'
    & $ffmpeg -hide_banner -nostdin -v error -xerror -i $video -f null NUL 2> (Join-Path $folder 'decode.log')
    $decodeExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($decodeExit -ne 0) { throw "Decode failed: exit $decodeExit" }
    if ([double]$report.media.format.duration -lt 9) { throw 'Recorded duration is too short' }
    $report.fullDecodePassed = $true
    $report.state = 'desktop_video_probe_passed'
} catch {
    $report.state = 'failed'
    $report.error = $_.Exception.Message
} finally {
    $report.checkedAtUTC = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $folder 'report.json') -Encoding UTF8
}
if ($report.state -eq 'failed') { exit 1 }
