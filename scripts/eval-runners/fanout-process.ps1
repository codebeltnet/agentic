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
        [int]$TimeoutSeconds = 900
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
    $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
    $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
    $startedUtc = [DateTime]::UtcNow
    return [pscustomobject]@{
        Process = $process
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
        StdoutStream = $stdoutStream
        StderrStream = $stderrStream
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
    }
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

    # An explicit timeout is a cleanup override (used by the supervisor's
    # error path); otherwise honor the absolute deadline captured at start.
    $deadline = if ($TimeoutSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds)) } elseif ($null -ne $Child.DeadlineUtc) { [DateTime]$Child.DeadlineUtc } else { [DateTime]::UtcNow.AddSeconds(1) }
    $timedOut = [bool]$Child.WatchdogExpired
    try {
        if (-not $Child.Process.HasExited -and -not $timedOut) {
            while (-not $Child.Process.HasExited) {
                $remainingTotal = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
                if ($remainingTotal -le 0) {
                    $timedOut = $true
                    break
                }
                $remaining = [int][Math]::Max(1, [Math]::Min(5000, $remainingTotal))
                if ($Child.Process.WaitForExit($remaining)) { break }
            }
        }
    } catch { $timedOut = $true }

    if ($timedOut) {
        $Child.TimedOut = $true
        try { $Child.Process.Kill($true) } catch { }
        try { if (-not $Child.Process.HasExited) { [void]$Child.Process.WaitForExit(5000) } } catch { }
    }
    try { $Child.TerminationObserved = [bool]$Child.Process.HasExited } catch { $Child.TerminationObserved = $false }

    # Use one finite drain deadline. A descendant holding an inherited pipe
    # open must not make the fan-out supervisor wait forever.
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
