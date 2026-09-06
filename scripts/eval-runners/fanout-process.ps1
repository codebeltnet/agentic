<#!
.SYNOPSIS
    Headless child-process helpers for the runner-owned behavioral fan-out.

.DESCRIPTION
    The runner-owned fan-out starts one fresh child pwsh process per preflight
    and per eval execution. These helpers keep those children as real process
    isolation boundaries while making them headless on Windows: no visible
    console window flashes for each child, and stdout/stderr are streamed to the
    declared files as raw bytes. They also provide a wait-any primitive so a
    completed child frees its concurrency slot immediately, regardless of the
    order children were started.

    This file is dot-sourced by invoke-runner-owned-arms.ps1 and by the
    orchestration tests. It never runs during preparation, validation, CI,
    hooks, or reporting, and it never invokes a model.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Write-RunnerProgress -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'runner-progress.ps1')
}

function New-RunnerChildProcessStartInfo {
    <#
      Builds the headless child-process configuration used for every
      runner-owned preflight and execution child. UseShellExecute=false with
      CreateNoWindow=true suppresses the per-child console window on Windows,
      while redirected stdout/stderr let the parent capture the child's exact
      output. This is a deterministic, testable configuration probe.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add([string]$argument) }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    return $startInfo
}

function Start-RunnerChildProcess {
    <#
      Starts a headless child process and streams its stdout/stderr to the
      declared files as raw bytes. The returned record exposes the live process
      and the asynchronous copy tasks so the caller can wait for completion and
      flush the destination files deterministically.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [int]$TimeoutSeconds = 900,
        [string]$Runner = '',
        [string]$WorkerId = '',
        [object]$EvalId = $null,
        [string]$Configuration = '',
        [string]$Phase = '',
        [object]$Turn = $null,
        [string]$ProgressLogPath = '',
        [double]$HeartbeatSeconds = 0
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $StdoutPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $StderrPath) -Force | Out-Null
    $startInfo = New-RunnerChildProcessStartInfo -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stdoutStream = [System.IO.File]::Open($StdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $stderrStream = [System.IO.File]::Open($StderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        if (-not $process.Start()) { throw "Failed to start runner child process '$FilePath'." }
    } catch {
        $stdoutStream.Dispose()
        $stderrStream.Dispose()
        $process.Dispose()
        throw
    }
    $startedUtc = [DateTime]::UtcNow
    # Tee the child's captured streams: every byte still reaches the exact
    # evidence/result file, while the wrapper exposes live activity metadata and
    # pulls structured child progress (sentinel lines) out of the captured STDERR
    # for relay. The result STDOUT is only ever counted, never echoed.
    $stdoutActivity = New-RunnerActivityStream -Inner $stdoutStream -ClassifyProgress $false
    $stderrActivity = New-RunnerActivityStream -Inner $stderrStream -ClassifyProgress $true
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutActivity)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrActivity)
    $progressEnabled = (-not [string]::IsNullOrWhiteSpace($Runner)) -or (-not [string]::IsNullOrWhiteSpace($WorkerId))
    $heartbeat = if ($HeartbeatSeconds -gt 0) { $HeartbeatSeconds } else { Get-RunnerHeartbeatIntervalSeconds }
    $processId = try { [int]$process.Id } catch { $null }
    $child = [pscustomobject]@{
        Process = $process
        ProcessId = $processId
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
        StdoutStream = $stdoutStream
        StderrStream = $stderrStream
        StdoutActivity = $stdoutActivity
        StderrActivity = $stderrActivity
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
        StartedUtc = $startedUtc
        TimeoutSeconds = [Math]::Max(1, $TimeoutSeconds)
        DeadlineUtc = $startedUtc.AddSeconds([Math]::Max(1, $TimeoutSeconds))
        WatchdogExpired = $false
        TimedOut = $false
        TerminationObserved = $false
        OutputDrainCompleted = $false
        FinishedUtc = $null
        Runner = $Runner
        WorkerId = $WorkerId
        EvalId = $EvalId
        Configuration = $Configuration
        Phase = $Phase
        Turn = $Turn
        ProgressLogPath = $ProgressLogPath
        HeartbeatSeconds = $heartbeat
        ProgressEnabled = $progressEnabled
        LastHeartbeatUtc = $startedUtc
        LastRelayActivityUtc = $null
        FirstStdoutSeen = $false
        FirstStderrSeen = $false
        LifecycleState = 'running'
    }
    if ($progressEnabled) {
        Write-RunnerChildProgress -Child $child -State 'running' -Detail 'process launched'
    }
    return $child
}

function Get-RunnerChildRecord {
    <#
      The live fan-out queue wraps the process helper as `.child`; focused helper
      tests pass the process record directly. Accept both shapes.
    #>
    param([Parameter(Mandatory = $true)][object]$Item)

    if ($null -ne $Item.PSObject.Properties['child'] -and $null -ne $Item.child) { return $Item.child }
    return $Item
}

function Test-RunnerChildProgressEnabled {
    param([object]$Child)

    if ($null -eq $Child) { return $false }
    $property = $Child.PSObject.Properties['ProgressEnabled']
    return ($null -ne $property -and [bool]$Child.ProgressEnabled)
}

function Get-RunnerChildSnapshot {
    <#
      Safe, live activity metadata for one child: elapsed runtime, remaining
      timeout budget, real stdout/stderr event and byte counts, and the age of the
      most recent real (non-progress) output. Never returns output content.
    #>
    param([Parameter(Mandatory = $true)][object]$Child)

    $now = [DateTime]::UtcNow
    $elapsed = [Math]::Max(0, ($now - [DateTime]$Child.StartedUtc).TotalSeconds)
    $remaining = $null
    if ($null -ne $Child.PSObject.Properties['DeadlineUtc'] -and $null -ne $Child.DeadlineUtc) {
        $remaining = [Math]::Max(0, ([DateTime]$Child.DeadlineUtc - $now).TotalSeconds)
    }
    $stdoutAge = Get-RunnerActivityAgeSeconds -ActivityStream $Child.StdoutActivity
    $stderrAge = Get-RunnerActivityAgeSeconds -ActivityStream $Child.StderrActivity
    $lastActivity = $null
    foreach ($age in @($stdoutAge, $stderrAge)) {
        if ($null -ne $age -and ($null -eq $lastActivity -or $age -lt $lastActivity)) { $lastActivity = $age }
    }
    return [pscustomobject]@{
        ElapsedSeconds = $elapsed
        TimeoutRemainingSeconds = $remaining
        LastActivitySeconds = $lastActivity
        StdoutEvents = if ($null -ne $Child.StdoutActivity) { [int64]$Child.StdoutActivity.RealEvents } else { 0 }
        StderrEvents = if ($null -ne $Child.StderrActivity) { [int64]$Child.StderrActivity.RealEvents } else { 0 }
        StdoutBytes = if ($null -ne $Child.StdoutActivity) { [int64]$Child.StdoutActivity.RealBytes } else { 0 }
        StderrBytes = if ($null -ne $Child.StderrActivity) { [int64]$Child.StderrActivity.RealBytes } else { 0 }
    }
}

function Get-RunnerChildProgressFields {
    param(
        [Parameter(Mandatory = $true)][object]$Child,
        [Parameter(Mandatory = $true)][string]$State,
        [string]$Detail = ''
    )

    $snapshot = Get-RunnerChildSnapshot -Child $Child
    $fields = @{
        runner = [string]$Child.Runner
        worker = [string]$Child.WorkerId
        state = $State
        origin = 'parent'
    }
    if ($null -ne $Child.EvalId) { $fields.eval = $Child.EvalId }
    if (-not [string]::IsNullOrWhiteSpace([string]$Child.Configuration)) { $fields.configuration = [string]$Child.Configuration }
    if ($null -ne $Child.ProcessId) { $fields.pid = $Child.ProcessId }
    if (-not [string]::IsNullOrWhiteSpace([string]$Child.Phase)) { $fields.phase = [string]$Child.Phase }
    if ($null -ne $Child.Turn) { $fields.turn = $Child.Turn }
    $fields.elapsed = Format-RunnerElapsed -Seconds $snapshot.ElapsedSeconds
    $fields.elapsedSeconds = [Math]::Round($snapshot.ElapsedSeconds, 3)
    if ($null -ne $snapshot.TimeoutRemainingSeconds) {
        $fields.timeoutRemaining = Format-RunnerElapsed -Seconds $snapshot.TimeoutRemainingSeconds
        $fields.timeoutRemainingSeconds = [Math]::Round($snapshot.TimeoutRemainingSeconds, 3)
    }
    if ($null -ne $snapshot.LastActivitySeconds) {
        $fields.lastActivity = Format-RunnerElapsed -Seconds $snapshot.LastActivitySeconds
        $fields.lastActivitySeconds = [Math]::Round($snapshot.LastActivitySeconds, 3)
    }
    $fields.stdoutEvents = $snapshot.StdoutEvents
    $fields.stderrEvents = $snapshot.StderrEvents
    $fields.stdoutBytes = $snapshot.StdoutBytes
    $fields.stderrBytes = $snapshot.StderrBytes
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $fields.detail = $Detail }
    return $fields
}

function Write-RunnerChildProgress {
    param(
        [Parameter(Mandatory = $true)][object]$Child,
        [Parameter(Mandatory = $true)][string]$State,
        [string]$Detail = '',
        [switch]$LogOnly
    )

    if (-not (Test-RunnerChildProgressEnabled -Child $Child)) { return }
    $fields = Get-RunnerChildProgressFields -Child $Child -State $State -Detail $Detail
    Write-RunnerProgress -Fields $fields -LogPath ([string]$Child.ProgressLogPath) -Channel Operator -LogOnly:$LogOnly
    if ($null -ne $Child.PSObject.Properties['LastHeartbeatUtc']) { $Child.LastHeartbeatUtc = [DateTime]::UtcNow }
    if ($null -ne $Child.PSObject.Properties['LifecycleState']) { $Child.LifecycleState = $State }
}

function Send-RunnerChildRelay {
    <#
      Drains structured progress a child emitted to its own STDERR and re-emits it
      through the parent's operator channel, re-stamped with the correct
      runner/worker identity so concurrent arms never interleave anonymously. The
      raw bytes remain captured in the child's evidence file untouched.
    #>
    param([Parameter(Mandatory = $true)][object]$Child)

    if (-not (Test-RunnerChildProgressEnabled -Child $Child)) { return 0 }
    $logPath = [string]$Child.ProgressLogPath
    $emittedCount = 0
    foreach ($stream in @($Child.StderrActivity, $Child.StdoutActivity)) {
        if ($null -eq $stream) { continue }
        $payload = $null
        $guard = 0
        while ($stream.TryDequeueRelay([ref]$payload)) {
            $guard++
            if ($guard -gt 10000) { break }
            $fields = ConvertFrom-RunnerRelayPayload -Payload ([string]$payload)
            if ($null -eq $fields) { continue }
            $fields['origin'] = 'relay'
            $fields['runner'] = [string]$Child.Runner
            $fields['worker'] = [string]$Child.WorkerId
            if ($null -ne $Child.EvalId -and -not $fields.ContainsKey('eval')) { $fields['eval'] = $Child.EvalId }
            if (-not [string]::IsNullOrWhiteSpace([string]$Child.Configuration) -and -not $fields.ContainsKey('configuration')) { $fields['configuration'] = [string]$Child.Configuration }
            Write-RunnerProgress -Fields $fields -LogPath $logPath -Channel Operator
            $emittedCount++
        }
    }
    return $emittedCount
}

function Invoke-RunnerChildHeartbeatTick {
    <#
      One non-blocking observability tick for a running child: relay structured
      child progress, announce first observed real activity once per stream, and
      emit a heartbeat when the child has been silent past its interval. Never
      blocks the process, and is a no-op for progress-disabled children.

      Console coalescing: when the nested relay is actively producing useful
      progress for this worker, the parent periodic heartbeat is still recorded
      in structured JSONL evidence but suppressed from the human console. The
      parent heartbeat resumes on the console once the relay has been quiet for
      at least one heartbeat interval, so a genuinely silent worker remains
      visibly alive. Terminal events and state transitions are never suppressed.
    #>
    param([Parameter(Mandatory = $true)][object]$Child)

    if (-not (Test-RunnerChildProgressEnabled -Child $Child)) { return }
    $relayedCount = Send-RunnerChildRelay -Child $Child
    if ($relayedCount -gt 0 -and $null -ne $Child.PSObject.Properties['LastRelayActivityUtc']) {
        $Child.LastRelayActivityUtc = [DateTime]::UtcNow
    }
    if ($null -ne $Child.PSObject.Properties['FirstStderrSeen'] -and -not $Child.FirstStderrSeen -and $null -ne $Child.StderrActivity -and [int64]$Child.StderrActivity.RealEvents -gt 0) {
        $Child.FirstStderrSeen = $true
        Write-RunnerChildProgress -Child $Child -State 'active' -Detail 'first stderr activity'
        return
    }
    if ($null -ne $Child.PSObject.Properties['FirstStdoutSeen'] -and -not $Child.FirstStdoutSeen -and $null -ne $Child.StdoutActivity -and [int64]$Child.StdoutActivity.RealEvents -gt 0) {
        $Child.FirstStdoutSeen = $true
        Write-RunnerChildProgress -Child $Child -State 'active' -Detail 'first stdout activity'
        return
    }
    $interval = if ($null -ne $Child.PSObject.Properties['HeartbeatSeconds'] -and [double]$Child.HeartbeatSeconds -gt 0) { [double]$Child.HeartbeatSeconds } else { Get-RunnerHeartbeatIntervalSeconds }
    $last = if ($null -ne $Child.PSObject.Properties['LastHeartbeatUtc'] -and $null -ne $Child.LastHeartbeatUtc) { [DateTime]$Child.LastHeartbeatUtc } else { [DateTime]$Child.StartedUtc }
    if (([DateTime]::UtcNow - $last).TotalSeconds -ge $interval) {
        # Always write to JSONL for structured evidence. Suppress the human
        # console line when the nested relay is actively demonstrating liveness
        # for this worker within the same heartbeat interval: the relay already
        # satisfies the operator-facing liveness requirement.
        $lastRelayActivity = if ($null -ne $Child.PSObject.Properties['LastRelayActivityUtc'] -and $null -ne $Child.LastRelayActivityUtc) { [DateTime]$Child.LastRelayActivityUtc } else { [DateTime]::MinValue }
        $relaySuppressConsole = (([DateTime]::UtcNow - $lastRelayActivity).TotalSeconds -lt $interval)
        Write-RunnerChildProgress -Child $Child -State 'running' -LogOnly:$relaySuppressConsole
    }
}

function Write-RunnerChildDiagnostic {
    <#
      Final safe diagnostic snapshot answering "what was this child doing just
      before it failed or timed out?": identity, PID, elapsed, timeout budget,
      last-activity age, phase, stdout/stderr counts, exit code, whether
      termination was required and observed, whether bounded output draining
      finished, and a structured state detail. Raw stderr remains in evidence.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Child,
        [Parameter(Mandatory = $true)][string]$State,
        [object]$ExitCode = $null
    )

    if (-not (Test-RunnerChildProgressEnabled -Child $Child)) { return }
    $fields = Get-RunnerChildProgressFields -Child $Child -State $State
    if ($null -ne $ExitCode) { $fields['exitCode'] = [int]$ExitCode }
    if ($null -ne $Child.PSObject.Properties['TimedOut']) { $fields['terminationRequested'] = [bool]$Child.TimedOut }
    if ($null -ne $Child.PSObject.Properties['TerminationObserved']) { $fields['terminationObserved'] = [bool]$Child.TerminationObserved }
    if ($null -ne $Child.PSObject.Properties['OutputDrainCompleted']) { $fields['outputDrainCompleted'] = [bool]$Child.OutputDrainCompleted }
    switch ($State) {
        'timed-out' { $fields['detail'] = 'watchdog timeout expired' }
        'failed' { $fields['detail'] = 'process exited with non-zero status' }
    }
    Write-RunnerProgress -Fields $fields -LogPath ([string]$Child.ProgressLogPath) -Channel Operator
    if ($null -ne $Child.PSObject.Properties['LifecycleState']) { $Child.LifecycleState = $State }
}

function Wait-RunnerChildTaskBounded {
    param(
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task]$Task,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    if ($Task.IsCompleted) { return $true }
    $bounded = [Math]::Max(1, [Math]::Min($TimeoutMilliseconds, 5000))
    try { return [bool]$Task.Wait($bounded) } catch { return [bool]$Task.IsCompleted }
}

function Complete-RunnerChildProcess {
    <#
      Waits for the child to exit, drains and flushes both stdout/stderr copy
      tasks, closes the destination streams, and returns the observed exit code.
      Safe to call once per started child.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Child,
        [int]$TimeoutSeconds = 0
    )

    # An explicit timeout is a cleanup override (used by the fan-out error
    # path); otherwise honor the absolute deadline captured at start.
    $deadline = if ($TimeoutSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds)) } elseif ($null -ne $Child.DeadlineUtc) { [DateTime]$Child.DeadlineUtc } else { [DateTime]::UtcNow.AddSeconds(1) }
    $timedOut = [bool]$Child.WatchdogExpired
    try {
        if (-not $Child.Process.HasExited -and -not $timedOut) {
            # Poll in slices no longer than the heartbeat interval so the tick
            # fires on schedule even when the child is slow. The 5 s cap
            # from before would have silenced a 30 s quiet preflight.
            $heartbeatMs = if ($null -ne $Child.PSObject.Properties['HeartbeatSeconds'] -and [double]$Child.HeartbeatSeconds -gt 0) { [int][Math]::Max(50, [Math]::Min(2000, [double]$Child.HeartbeatSeconds * 1000)) } else { 2000 }
            while (-not $Child.Process.HasExited) {
                $remainingTotal = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
                if ($remainingTotal -le 0) {
                    $timedOut = $true
                    break
                }
                $remaining = [int][Math]::Max(1, [Math]::Min($heartbeatMs, $remainingTotal))
                if ($Child.Process.WaitForExit($remaining)) { break }
                # Tick heartbeat/relay so a long synchronous wait (e.g. preflight)
                # never goes externally silent past the configured interval.
                try { Invoke-RunnerChildHeartbeatTick -Child $Child } catch { }
            }
        }
    } catch { $timedOut = $true }

    if ($timedOut) {
        $Child.TimedOut = $true
        Write-RunnerChildProgress -Child $Child -State 'terminating' -Detail 'watchdog deadline reached'
        try { $Child.Process.Kill($true) } catch { }
        try { if (-not $Child.Process.HasExited) { [void]$Child.Process.WaitForExit(5000) } } catch { }
    }
    try { $Child.TerminationObserved = [bool]$Child.Process.HasExited } catch { $Child.TerminationObserved = $false }

    # Use one finite drain deadline. A descendant holding an inherited pipe
    # open must not make the fan-out process wait forever.
    $drainDeadline = [DateTime]::UtcNow.AddSeconds(5)
    $stdoutDone = $false
    $stderrDone = $false
    foreach ($entry in @(
            [pscustomobject]@{ Task = $Child.StdoutTask; Name = 'stdout' },
            [pscustomobject]@{ Task = $Child.StderrTask; Name = 'stderr' }
        )) {
        try {
            $remaining = [int][Math]::Max(1, [Math]::Min(5000, ($drainDeadline - [DateTime]::UtcNow).TotalMilliseconds))
            $done = Wait-RunnerChildTaskBounded -Task $entry.Task -TimeoutMilliseconds $remaining
            if ($entry.Name -eq 'stdout') { $stdoutDone = $done } else { $stderrDone = $done }
        } catch { }
    }
    $Child.OutputDrainCompleted = $stdoutDone -and $stderrDone
    # Account for any trailing partial line before reading final activity counts.
    foreach ($activity in @($Child.PSObject.Properties['StdoutActivity'], $Child.PSObject.Properties['StderrActivity'])) {
        if ($null -ne $activity -and $null -ne $activity.Value) { try { $activity.Value.FinalizeActivity() } catch { } }
    }
    # Surface any structured child progress that arrived just before exit.
    [void](Send-RunnerChildRelay -Child $Child)
    foreach ($stream in @($Child.StdoutStream, $Child.StderrStream)) {
        try { $stream.Flush() } catch { }
        try { $stream.Dispose() } catch { }
    }
    $exitCode = $null
    if (-not $timedOut -and $Child.TerminationObserved) {
        try { $exitCode = [int]$Child.Process.ExitCode } catch { $exitCode = $null }
    }
    try { $Child.Process.Dispose() } catch { }
    $Child.FinishedUtc = [DateTime]::UtcNow
    # Final lifecycle: a timeout or non-zero exit yields a diagnostic snapshot so
    # the operator learns the last-known state before control returns to the
    # caller (which may then throw). A clean exit reports completion.
    if ($timedOut) {
        Write-RunnerChildDiagnostic -Child $Child -State 'timed-out' -ExitCode $exitCode
    } elseif ($null -ne $exitCode -and $exitCode -ne 0) {
        Write-RunnerChildDiagnostic -Child $Child -State 'failed' -ExitCode $exitCode
    } else {
        Write-RunnerChildProgress -Child $Child -State 'completed' -Detail 'process exited'
    }
    return $exitCode
}

function Wait-AnyRunnerChild {
    <#
      Returns the list index of the first child that has exited, polling until
      at least one has. Capacity is released when ANY child completes, not only
      the oldest one in the list, so a slow child never blocks refilling the
      slot that a faster sibling has already freed.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.IList]$Running,
        [int]$PollMilliseconds = 25
    )

    if ($Running.Count -eq 0) { return -1 }
    while ($true) {
        # Non-blocking observability pass: relay structured child progress and
        # emit heartbeats so no actively running arm goes silent past its
        # interval. A no-op for progress-disabled records used by focused tests.
        foreach ($item in $Running) {
            try { Invoke-RunnerChildHeartbeatTick -Child (Get-RunnerChildRecord -Item $item) } catch { }
        }
        for ($index = 0; $index -lt $Running.Count; $index++) {
            $child = $Running[$index]
            if ($child.Process.HasExited) { return $index }
            # The public queue record wraps the process helper as `.child`,
            # while the focused helper tests may pass the process record
            # directly. Accept both shapes without losing the deadline.
            $childDeadline = $null
            if ($null -ne $child.PSObject.Properties['DeadlineUtc']) {
                $childDeadline = $child.DeadlineUtc
            } elseif ($null -ne $child.PSObject.Properties['child'] -and $null -ne $child.child -and $null -ne $child.child.PSObject.Properties['DeadlineUtc']) {
                $childDeadline = $child.child.DeadlineUtc
            }
            if ($null -ne $childDeadline -and [DateTime]::UtcNow -ge [DateTime]$childDeadline) {
                if ($null -ne $child.PSObject.Properties['WatchdogExpired']) { $child.WatchdogExpired = $true }
                if ($null -ne $child.PSObject.Properties['child']) { $child.child.WatchdogExpired = $true }
                return $index
            }
        }
        $sleepMilliseconds = [Math]::Max(1, [Math]::Min($PollMilliseconds, 250))
        $nextDeadline = @($Running | ForEach-Object {
                if ($null -ne $_.PSObject.Properties['DeadlineUtc']) {
                    [DateTime]$_.DeadlineUtc
                } elseif ($null -ne $_.PSObject.Properties['child'] -and $null -ne $_.child -and $null -ne $_.child.PSObject.Properties['DeadlineUtc']) {
                    [DateTime]$_.child.DeadlineUtc
                }
            } | Sort-Object | Select-Object -First 1)
        if ($nextDeadline.Count -eq 1) {
            $untilDeadline = [int][Math]::Max(1, [Math]::Min($sleepMilliseconds, ($nextDeadline[0] - [DateTime]::UtcNow).TotalMilliseconds))
            Start-Sleep -Milliseconds $untilDeadline
        } else {
            Start-Sleep -Milliseconds $sleepMilliseconds
        }
    }
}
