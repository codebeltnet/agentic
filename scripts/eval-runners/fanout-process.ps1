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
        [Parameter(Mandatory = $true)][string]$StderrPath
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
    return [pscustomobject]@{
        Process = $process
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
        StdoutStream = $stdoutStream
        StderrStream = $stderrStream
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
    }
}

function Complete-RunnerChildProcess {
    <#
      Waits for the child to exit, drains and flushes both stdout/stderr copy
      tasks, closes the destination streams, and returns the observed exit code.
      Safe to call once per started child.
    #>
    param([Parameter(Mandatory = $true)][object]$Child)

    $Child.Process.WaitForExit()
    foreach ($task in @($Child.StdoutTask, $Child.StderrTask)) {
        try { [void]$task.Wait() } catch { }
    }
    foreach ($stream in @($Child.StdoutStream, $Child.StderrStream)) {
        try { $stream.Flush() } catch { }
        try { $stream.Dispose() } catch { }
    }
    $exitCode = [int]$Child.Process.ExitCode
    try { $Child.Process.Dispose() } catch { }
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
            if ($Running[$index].Process.HasExited) { return $index }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
}
