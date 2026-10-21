# Read-only Windows readiness check. Does not open cameras/microphones or change settings.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$os = Get-CimInstance Win32_OperatingSystem
$devices = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Class -in @('Camera','Image','AudioEndpoint') } | Select-Object Class,FriendlyName,Status)
$captureSupported = $null
$captureError = $null
try { $captureSupported = [Windows.Graphics.Capture.GraphicsCaptureSession, Windows.Graphics.Capture, ContentType=WindowsRuntime]::IsSupported() }
catch { $captureError = $_.Exception.Message }
$tools = @(Get-Command dotnet,ffmpeg,cmake,cl,node,cargo -ErrorAction SilentlyContinue | Select-Object Name,Source)
$sdks = @()
if (Get-Command dotnet -ErrorAction SilentlyContinue) { $sdks = @(& dotnet --list-sdks) }
[ordered]@{
    checkedAtUTC = [DateTime]::UtcNow.ToString('o')
    os = $os.Caption
    version = $os.Version
    architecture = $os.OSArchitecture
    graphics = @(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion)
    devices = $devices
    camerasFound = @($devices | Where-Object {$_.Class -in @('Camera','Image')}).Count
    graphicsCaptureSupportedInSSHSession = $captureSupported
    graphicsCaptureCheckError = $captureError
    tools = $tools
    dotnetSDKs = $sdks
    sessionID = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    nativeClientPresentInRepository = $false
    note = 'Preflight only: no real media capture, no Windows product runtime or long-duration acceptance.'
} | ConvertTo-Json -Depth 5
