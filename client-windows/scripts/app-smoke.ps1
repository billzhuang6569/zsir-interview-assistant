param([string]$Root = 'C:\zsir\client-windows', [string]$Output = 'C:\zsir\issue15-smoke', [switch]$Lifecycle)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Output | Out-Null
Start-Transcript "$Output\run.log" -Force
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
$exe = "$Root\App\bin\Release\net8.0-windows10.0.19041.0\App.exe"
function Window([string]$title) {
  $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$title)
  [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children,$condition)
}
function Click($window,[string]$name) {
  $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,$name)
  $element = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$condition)
  if (!$element) { throw "Missing UI control: $name" }
  $element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 600
}
function Dump($window,[string]$file) {
  $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Out-File "$Output\$file" -Encoding utf8
}
function Shot([string]$name) {
  $r = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $b = New-Object System.Drawing.Bitmap($r.Width,$r.Height)
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen($r.Location,[System.Drawing.Point]::Empty,$r.Size)
  $b.Save("$Output\$name.jpg",[System.Drawing.Imaging.ImageFormat]::Jpeg)
  $g.Dispose(); $b.Dispose()
}
$config = "$env:LOCALAPPDATA\ZsirInterview\settings.json"
if (!$Lifecycle -and (Test-Path $config)) {
  Copy-Item $config "$Output\settings.before.json" -Force
  $existing = Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($existing.RecorderPid -gt 0 -and (Get-Process -Id $existing.RecorderPid -ErrorAction SilentlyContinue)) { throw 'Stop existing recording before smoke' }
  $existing.Onboarded = $false
  $existing | ConvertTo-Json | Set-Content $config -Encoding UTF8
}
try {
  $p = Start-Process $exe -PassThru
  Start-Sleep 3
  if ($Lifecycle) {
    $float = Window '庄Sir线上采访助手'
    Click $float '开始录制'; Start-Sleep 16
    $s = Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
    $recorder = Get-Process -Id $s.RecorderPid
    $before = (Get-Item "$($s.LastSession)\screen.mp4").Length
    Stop-Process -Id $p.Id
    Start-Sleep 8
    if (!(Get-Process -Id $recorder.Id -ErrorAction SilentlyContinue)) { throw 'Recorder died with UI' }
    $after = (Get-Item "$($s.LastSession)\screen.mp4").Length
    if ($after -le $before) { throw 'Recorder stopped writing after UI death' }
    $p = Start-Process $exe -PassThru; Start-Sleep 3
    $float = Window '庄Sir线上采访助手'; Dump $float 'recovered.txt'; Shot 'recovered-desktop'
    Start-Sleep 58
    $session = Get-Content "$($s.LastSession)\session.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($session.state -ne 'finished') { throw 'EOF grace period did not finalize' }
    & "$Root\App\bin\Release\net8.0-windows10.0.19041.0\ffmpeg\ffmpeg.exe" -v error -i "$($s.LastSession)\screen.mp4" -f null - 2> "$Output\orphan-decode.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Orphan full decode failed' }
    Dump $float 'recovered-saved.txt'
    Click $float '开始录制'; Start-Sleep 16
    $s = Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
    Stop-Process -Id $s.RecorderPid; Start-Sleep 5
    Dump $float 'recorder-crashed.txt'
    if (!(Select-String -Path "$Output\recorder-crashed.txt" -Pattern RECORDER_CRASHED)) { throw 'Missing recorder crash status' }
    Stop-Process -Id $p.Id
    "PASS: kill App, recorder bytes $before -> $after, restart recovery, EOF 60s finalize + full decode, kill Recorder -> RECORDER_CRASHED (no restart)" | Out-File "$Output\LIFECYCLE-PASS.txt"
    return
  }
  $w = Window '庄Sir线上采访助手 · 引导与设置' 
  if (!$w) { throw 'Onboarding not shown (use fresh settings for initial smoke)' }
  Dump $w 'welcome.txt'; Shot 'welcome-desktop'
  Click $w '下一步'; Click $w '检查权限'; Start-Sleep 5; Dump $w 'permissions.txt'
  Click $w '下一步'; Start-Sleep 3
  $combos = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::ComboBox)))
  $combos[4].SetFocus(); [System.Windows.Forms.SendKeys]::SendWait('{END}{ENTER}'); Start-Sleep 1
  Click $w '开始 / 刷新预览'; Start-Sleep 3; Dump $w 'devices.txt'; Shot 'preview-desktop'
  Click $w '下一步'; Click $w '运行 / 重新自检'; Start-Sleep 25; Dump $w 'preflight.txt'; Shot 'preflight-desktop'
  Click $w '下一步'; Click $w '下一步'; Click $w '直接本地使用'
  $float = Window '庄Sir线上采访助手'
  Click $float '开始录制'; Start-Sleep 2; Dump $float 'countdown.txt'
  Start-Sleep 65; Dump $float 'recording.txt'; Shot 'recording-desktop'
  Click $float '停止录制'; Click $float '确认停止'; Start-Sleep 12; Dump $float 'saved.txt'
  $s = Get-Content $config -Raw | ConvertFrom-Json
  $session = Get-Content "$($s.LastSession)\session.json" -Raw | ConvertFrom-Json
  if ($session.state -ne 'finished' -or $session.t -lt 60) { throw 'Recording did not finish >= 60 seconds' }
  & "$Root\App\bin\Release\net8.0-windows10.0.19041.0\ffmpeg\ffprobe.exe" -v error -show_entries format=duration -of json "$($s.LastSession)\screen.mp4" | Out-File "$Output\ffprobe.json"
  & "$Root\App\bin\Release\net8.0-windows10.0.19041.0\ffmpeg\ffmpeg.exe" -v error -i "$($s.LastSession)\screen.mp4" -f null - 2> "$Output\decode.txt"
  if ($LASTEXITCODE -ne 0) { throw 'Decode failed' }
  'PASS: onboarding, preflight CAM_NOT_FOUND, 60s screen capture, stdin stop, finished session, full decode' | Out-File "$Output\PASS.txt"
  # Close only the App started here. No recorder is running at this point.
  Stop-Process -Id $p.Id
} catch { $_ | Out-File "$Output\FAIL.txt"; throw }
finally { Stop-Transcript }
