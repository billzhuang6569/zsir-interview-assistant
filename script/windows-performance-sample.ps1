# Read-only process sampling. Start/stop recording separately in the product UI.
# Targets Windows PowerShell 5.1; runtime validation pending. No modules are installed.
param(
    [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$TargetProcessId,
    [ValidateRange(1,86400)][int]$DurationSeconds = 60,
    [ValidateRange(0.2,60)][double]$IntervalSeconds = 1,
    [Parameter(Mandatory=$true)][string]$OutputJsonl,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Scenario
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this sampler on Windows.' }
$target = Get-Process -Id $TargetProcessId
$targetStart = $target.StartTime.ToUniversalTime().Ticks
$logicalProcessors = [Environment]::ProcessorCount
$outputPath = [IO.Path]::GetFullPath($OutputJsonl)
# CreateNew prevents accidentally replacing an earlier baseline.
$stream = [IO.FileStream]::new($outputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true
$clock = [Diagnostics.Stopwatch]::StartNew()
$previous = @{}
$sampleIndex = 0
function Write-Record($record) {
    $writer.WriteLine(($record | ConvertTo-Json -Depth 6 -Compress))
}
try {
    Write-Record ([ordered]@{
        type='session'; schemaVersion=1; startedAtUTC=[DateTime]::UtcNow.ToString('o')
        scenario=$Scenario; targetProcessId=$TargetProcessId; targetStartTicksUTC=$targetStart
        samplerProcessId=[Diagnostics.Process]::GetCurrentProcess().Id
        durationSeconds=$DurationSeconds; intervalSeconds=$IntervalSeconds
        logicalProcessorsVisible=$logicalProcessors
        cpuDefinition='CPU-time delta / actual monotonic sample interval; normalized percent divides by logicalProcessorsVisible; oneCorePercent may exceed 100'
        limitations=@(
            'No recording, settings changes, remote operations, or process termination.'
            'CPU first observations are null. Exit/access failures remain null, never zero.'
            'Child discovery uses a CIM process-tree snapshot; short-lived FFmpeg children between samples may be missed.'
            'CIM collection and JSONL writes add sampler overhead; compare identical sampling settings.'
            'System commit, GPU utilization, disk throughput, and encoder queue/latency counters are not collected by this script and remain null.'
            'Process working set/private bytes do not include all GPU/driver allocations and are not system commit.'
        )
    })
    while ($true) {
        $sampleStarted = $clock.Elapsed.TotalSeconds
        $rootAlive = $false
        try {
            $rootProcess = Get-Process -Id $TargetProcessId
            $rootAlive = $rootProcess.StartTime.ToUniversalTime().Ticks -eq $targetStart
        } catch { }
        $discoveryError = $null
        $descendants = [Collections.Generic.HashSet[int]]::new()
        [void]$descendants.Add($TargetProcessId)
        $childIds = @()
        if ($rootAlive) {
            try {
                $snapshot = @(Get-CimInstance -Query 'SELECT ProcessId,ParentProcessId,Name FROM Win32_Process')
                do {
                    $added = $false
                    foreach ($entry in $snapshot) {
                        if ($descendants.Contains([int]$entry.ParentProcessId) -and $descendants.Add([int]$entry.ProcessId)) { $added = $true }
                    }
                } while ($added)
                $childIds = @($snapshot | Where-Object {
                    $_.Name -ieq 'ffmpeg.exe' -and $descendants.Contains([int]$_.ProcessId) -and [int]$_.ProcessId -ne $TargetProcessId
                } | ForEach-Object { [int]$_.ProcessId })
            } catch { $discoveryError = $_.Exception.Message }
        }
        $rows = @()
        $current = @{}
        if ($rootAlive) {
            foreach ($processIdValue in @($TargetProcessId) + $childIds) {
                $row = [ordered]@{
                    processId=$processIdValue; role='ffmpeg'; name=$null; startTicksUTC=$null
                    cpuTimeSeconds=$null; cpuNormalizedPercent=$null; cpuOneCorePercent=$null
                    workingSetBytes=$null; privateBytes=$null; error=$null
                }
                if ($processIdValue -eq $TargetProcessId) { $row.role='app' }
                try {
                    $process = Get-Process -Id $processIdValue
                    $identity = $process.StartTime.ToUniversalTime().Ticks
                    $cpu = $process.TotalProcessorTime.TotalSeconds
                    $observed = $clock.Elapsed.TotalSeconds
                    $key = '{0}:{1}' -f $processIdValue,$identity
                    $row.name=$process.ProcessName; $row.startTicksUTC=$identity
                    $row.cpuTimeSeconds=$cpu; $row.workingSetBytes=$process.WorkingSet64; $row.privateBytes=$process.PrivateMemorySize64
                    if ($previous.ContainsKey($key)) {
                        $elapsed = $observed - $previous[$key].time
                        $delta = $cpu - $previous[$key].cpu
                        if ($elapsed -gt 0 -and $delta -ge 0) {
                            $row.cpuOneCorePercent=100 * $delta / $elapsed
                            $row.cpuNormalizedPercent=$row.cpuOneCorePercent / $logicalProcessors
                        }
                    }
                    $current[$key]=@{time=$observed; cpu=$cpu}
                } catch { $row.error=$_.Exception.Message }
                $rows += $row
            }
        }
        Write-Record ([ordered]@{
            type='sample'; index=$sampleIndex; sampledAtUTC=[DateTime]::UtcNow.ToString('o')
            elapsedSeconds=$clock.Elapsed.TotalSeconds; scenario=$Scenario; targetAlive=$rootAlive
            processes=$rows; childDiscoveryError=$discoveryError
            systemCommitBytes=$null; systemCommitLimitBytes=$null; gpuUtilizationPercent=$null; diskReadBytesPerSecond=$null; diskWriteBytesPerSecond=$null
            collectionSeconds=$clock.Elapsed.TotalSeconds - $sampleStarted
        })
        # Retain only the immediately preceding sample, not process history.
        $previous=$current; $sampleIndex++
        if (!$rootAlive -or $clock.Elapsed.TotalSeconds -ge $DurationSeconds) { break }
        $delay = [Math]::Min($IntervalSeconds - ($clock.Elapsed.TotalSeconds - $sampleStarted), $DurationSeconds - $clock.Elapsed.TotalSeconds)
        if ($delay -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($delay * 1000)) }
    }
    Write-Record ([ordered]@{type='end'; endedAtUTC=[DateTime]::UtcNow.ToString('o'); samples=$sampleIndex; elapsedSeconds=$clock.Elapsed.TotalSeconds; targetAlive=$rootAlive})
} finally {
    $writer.Dispose()
}
