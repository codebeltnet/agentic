#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Runs the complete deterministic validation matrix locally, in parallel.

.DESCRIPTION
    The CI workflow (.github/workflows/validate-skill-templates.yml) is the coverage source of
    truth: every `{ name, script, suite }` entry is one independently scheduled suite. This script
    runs exactly those suites as separate processes, so local execution and CI cover the same
    checks, and it keeps a bounded number of them in flight at once.

    Improvements over running the suites by hand:

    * Coverage parity with CI is derived from the workflow, never from a hand-kept list.
    * Each suite is a separate process, so a crash or hang cannot take the run down with it.
    * Per-suite timeouts kill the whole process tree; a timeout is a failure, never a pass.
    * A failing suite does not stop the others, so one run reports every problem at once.
    * Each suite's output is streamed to its own log for post-mortem inspection.
    * Every suite must produce its terminal success marker. A suite that exits 0 while silently
      skipping its checks is reported as a failure instead of a pass.
    * Ctrl+C cancels the run, tears down every child process tree, and still writes the summary.

    A pass therefore means: every CI-matrix suite ran to completion, exited 0, reported no failing
    check, and printed its terminal success marker.

.PARAMETER MaxConcurrency
    Maximum number of suites executing at the same time. Defaults to the processor count.

.PARAMETER TimeoutSeconds
    Per-suite wall-clock budget. A suite that exceeds it has its process tree killed and is
    reported as TIMEOUT. Use 0 to disable.

.PARAMETER DeadlineSeconds
    Wall-clock budget for the entire run. Suites that have not finished are killed and reported,
    and the run fails. Use 0 to disable.

.PARAMETER OutputRoot
    Directory that receives one log per suite plus summary.json. Defaults to
    <repo>/.bot/validation-workspace. Paths inside the repository must stay under `.bot/`.

.PARAMETER WorkflowPath
    Workflow file that defines the suite matrix. Defaults to the repository CI workflow. This
    exists so the scheduler can be exercised deterministically against fixture workflows.

.PARAMETER RepositoryRoot
    Repository root the matrix script paths are resolved against. Defaults to the parent of the
    script directory.

.PARAMETER ListSuites
    Print the resolved suite matrix and exit without running anything.

.EXAMPLE
    pwsh -NoProfile -File ./scripts/validate-local.ps1

.EXAMPLE
    pwsh -NoProfile -File ./scripts/validate-local.ps1 -MaxConcurrency 24 -TimeoutSeconds 900
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 128)][int]$MaxConcurrency = [Environment]::ProcessorCount,
    [ValidateRange(0, 86400)][int]$TimeoutSeconds = 900,
    [ValidateRange(0, 86400)][int]$DeadlineSeconds = 0,
    [string]$OutputRoot,
    [string]$WorkflowPath,
    [string]$RepositoryRoot,
    [switch]$ListSuites
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# Terminal markers that prove a suite executed its checks instead of exiting early. These are the
# public summary lines each scheduled script already prints; they are asserted on top of the exit
# code so that a no-op or partially skipped suite can never be reported as a pass.
$suiteExpectations = @{
    'scripts/validate-skill-templates.ps1' = @(
        [pscustomobject]@{ Pattern = '(?m)^Failed: 0\s*$'; Description = "reports 'Failed: 0'" }
        [pscustomobject]@{ Pattern = '(?m)^Passed: [1-9][0-9]*\s*$'; Description = 'reports at least one passing check' }
    )
    'scripts/eval-runners/tests/test-runner-conformance.ps1' = @(
        [pscustomobject]@{ Pattern = '(?m)conformance( \([A-Za-z]+\))?: PASS\s*$'; Description = 'reports conformance PASS' }
    )
    'scripts/eval-runners/tests/test-integrity-finalization.ps1' = @(
        [pscustomobject]@{ Pattern = '(?m)Eval package integrity and finalization: PASS \([A-Za-z]+\)\s*$'; Description = 'reports integrity PASS' }
    )
}

$failureMarkerPattern = '(?m)^\[FAIL\]|:\s*FAIL\s*$|^Failed: [1-9][0-9]*\s*$'

function Get-RepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        return ([System.IO.Path]::GetFullPath($RepositoryRoot)).TrimEnd('\', '/')
    }

    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path.TrimEnd('\', '/')
}

function Get-SuiteMatrix {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Validation workflow was not found at '$Path'."
    }

    $workflow = [System.IO.File]::ReadAllText($Path)
    $entries = @([regex]::Matches($workflow, '\{ name: (?<name>[\w-]+), script: (?<script>[\w/.-]+), suite: (?<suite>\w+) \}') | ForEach-Object {
        [pscustomobject]@{
            Name   = $_.Groups['name'].Value
            Script = $_.Groups['script'].Value
            Suite  = $_.Groups['suite'].Value
        }
    })

    if ($entries.Count -eq 0) {
        throw 'The validation workflow defines no suite entries.'
    }

    if (@($entries.Name | Sort-Object -Unique).Count -ne $entries.Count) {
        throw 'Validation suite names must be unique.'
    }

    foreach ($entry in $entries) {
        if ([string]::IsNullOrWhiteSpace($entry.Suite)) {
            throw "Validation suite '$($entry.Name)' has no suite name."
        }
    }

    return $entries
}

function Assert-OutputRootIsAllowed {
    param(
        [string]$RepoRoot,
        [string]$Candidate
    )

    $full = [System.IO.Path]::GetFullPath($Candidate)
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $repoFull = ([System.IO.Path]::GetFullPath($RepoRoot)).TrimEnd('\', '/')

    $insideRepository = $full.Equals($repoFull, $comparison) -or $full.StartsWith($repoFull + $separator, $comparison)
    if (-not $insideRepository) {
        return $full
    }

    $botRoot = Join-Path $repoFull '.bot'
    if (-not ($full.Equals($botRoot, $comparison) -or $full.StartsWith($botRoot + $separator, $comparison))) {
        throw "Validation output inside the repository must stay under '$botRoot' (got '$full')."
    }

    if (Test-Path -LiteralPath (Join-Path $repoFull '.git')) {
        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git -C $repoFull check-ignore -q -- $full 2>$null
            $ignored = $LASTEXITCODE -eq 0
        } finally {
            $ErrorActionPreference = $previousErrorAction
        }

        if (-not $ignored) {
            throw "Refusing to write validation output to '$full' because git does not ignore it. Restore the `.bot/*` ignore rule before writing validation logs there."
        }
    }

    return $full
}

function Test-SuiteLog {
    param(
        [string]$Script,
        [string]$Content
    )

    $expectations = @()
    if ($suiteExpectations.ContainsKey($Script)) {
        $expectations = @($suiteExpectations[$Script])
    }

    $verified = $true
    $details = [System.Collections.Generic.List[string]]::new()

    foreach ($expectation in $expectations) {
        if ($Content -cnotmatch $expectation.Pattern) {
            $verified = $false
            $details.Add("missing terminal marker: $($expectation.Description)")
        }
    }

    if ($Content -cmatch $failureMarkerPattern) {
        $verified = $false
        $details.Add('log reports a failing check')
    }

    return [pscustomobject]@{
        Verified = $verified
        Details  = @($details)
    }
}

$repoRoot = Get-RepoRoot
$workflow = if ([string]::IsNullOrWhiteSpace($WorkflowPath)) {
    Join-Path $repoRoot '.github/workflows/validate-skill-templates.yml'
} else {
    $WorkflowPath
}

$matrix = Get-SuiteMatrix -Path $workflow

if ($ListSuites) {
    $matrix | ForEach-Object { '{0} -> {1} -Suite {2}' -f $_.Name, $_.Script, $_.Suite }
    exit 0
}

$missingScripts = @($matrix | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_.Script) -PathType Leaf) })
if ($missingScripts.Count -gt 0) {
    throw "Validation workflow references missing script(s): $($missingScripts.Script -join ', ')."
}

$outputRootFull = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    Assert-OutputRootIsAllowed -RepoRoot $repoRoot -Candidate (Join-Path $repoRoot '.bot/validation-workspace')
} else {
    Assert-OutputRootIsAllowed -RepoRoot $repoRoot -Candidate $OutputRoot
}

$logRoot = Join-Path $outputRootFull ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$pending = [System.Collections.Generic.Queue[object]]::new()
foreach ($entry in $matrix) { $pending.Enqueue($entry) }

$jobs = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$activeLimit = [Math]::Max(1, [Math]::Min($MaxConcurrency, $matrix.Count))

$cancellation = [System.Threading.CancellationTokenSource]::new()
$cancelHandler = [System.ConsoleCancelEventHandler] {
    param($sender, $eventArgs)
    $eventArgs.Cancel = $true
    $cancellation.Cancel()
}
[Console]::add_CancelKeyPress($cancelHandler)

function Start-SuiteJob {
    param(
        [object]$Entry,
        [string]$LogRoot,
        [string]$RepoRoot,
        [double]$Started
    )

    $logPath = Join-Path $LogRoot ($Entry.Name + '.log')
    $writer = [System.IO.StreamWriter]::new($logPath, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot $Entry.Script), '-Suite', $Entry.Suite)) {
        $startInfo.ArgumentList.Add($argument)
    }
    if ($Entry.Suite -eq 'Docfx') {
        $startInfo.ArgumentList.Add('-Full')
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)

    $job = [pscustomobject]@{
        Entry   = $Entry
        Process = $process
        Writer  = $writer
        Log     = $logPath
        Started = $Started
        OutTask = $process.StandardOutput.ReadLineAsync()
        ErrTask = $process.StandardError.ReadLineAsync()
        TimedOut = $false
    }

    Write-Host ("[RUN ] {0}" -f $Entry.Name)
    return $job
}

function Receive-SuiteOutput {
    param([object]$Job)

    $outTask = $Job.OutTask
    while ($null -ne $outTask -and $outTask.IsCompleted) {
        $line = $outTask.GetAwaiter().GetResult()
        if ($null -eq $line) {
            $outTask = $null
            break
        }
        $Job.Writer.WriteLine($line)
        $outTask = $Job.Process.StandardOutput.ReadLineAsync()
    }
    $Job.OutTask = $outTask

    $errTask = $Job.ErrTask
    while ($null -ne $errTask -and $errTask.IsCompleted) {
        $line = $errTask.GetAwaiter().GetResult()
        if ($null -eq $line) {
            $errTask = $null
            break
        }
        $Job.Writer.WriteLine($line)
        $errTask = $Job.Process.StandardError.ReadLineAsync()
    }
    $Job.ErrTask = $errTask
}

function Complete-SuiteJob {
    param(
        [object]$Job,
        [string]$Status,
        [ref]$Results
    )

    # Close the log before reading it back for terminal-marker verification.
    $Job.Writer.Flush()
    $Job.Writer.Dispose()

    $seconds = [Math]::Round($watch.Elapsed.TotalSeconds - $Job.Started, 2)
    $exitCode = if ($Job.Process.HasExited) { $Job.Process.ExitCode } else { $null }
    $content = if (Test-Path -LiteralPath $Job.Log -PathType Leaf) {
        [System.IO.File]::ReadAllText($Job.Log, $utf8NoBom)
    } else {
        ''
    }

    $verification = Test-SuiteLog -Script $Job.Entry.Script -Content $content
    $verified = $verification.Verified

    if ($Status -eq 'PASS' -and -not $verified) {
        $Status = 'FAIL'
    }

    $result = [pscustomobject]@{
        Name     = $Job.Entry.Name
        Script   = $Job.Entry.Script
        Suite    = $Job.Entry.Suite
        Status   = $Status
        ExitCode = $exitCode
        Seconds  = $seconds
        Log      = $Job.Log
        Verified = $verified
        Details  = @($verification.Details)
    }

    $Results.Value.Add($result)
    Write-Host ("[{0}] {1} ({2:n1}s, exit {3})" -f $Status.PadRight(7), $result.Name, $seconds, $exitCode)
    foreach ($detail in $result.Details) {
        Write-Host ("       {0}" -f $detail)
    }

    $Job.Process.Dispose()
}

Write-Host ("Full validation: {0} CI-matrix suites, {1} worker(s), {2}s per-suite timeout." -f $matrix.Count, $activeLimit, $TimeoutSeconds)
Write-Host ("Logs: {0}" -f $logRoot)

$interrupted = $false
try {
    while ($pending.Count -gt 0 -or $jobs.Count -gt 0) {
        if ($cancellation.IsCancellationRequested) {
            $interrupted = $true
            break
        }

        if ($DeadlineSeconds -gt 0 -and $watch.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
            $interrupted = $true
            Write-Host ("Run deadline of {0}s reached; stopping remaining suites." -f $DeadlineSeconds)
            break
        }

        while ($pending.Count -gt 0 -and $jobs.Count -lt $activeLimit) {
            $entry = $pending.Dequeue()
            $jobs.Add((Start-SuiteJob -Entry $entry -LogRoot $logRoot -RepoRoot $repoRoot -Started $watch.Elapsed.TotalSeconds))
        }

        foreach ($job in @($jobs.ToArray())) {
            Receive-SuiteOutput -Job $job

            if ($TimeoutSeconds -gt 0 -and -not $job.Process.HasExited -and ($watch.Elapsed.TotalSeconds - $job.Started) -ge $TimeoutSeconds) {
                $job.TimedOut = $true
                try { $job.Process.Kill($true) } catch { }
                $job.Process.WaitForExit()
            }

            if (-not $job.Process.HasExited) { continue }
            if ($null -ne $job.OutTask -or $null -ne $job.ErrTask) { continue }

            $status = if ($job.TimedOut) { 'TIMEOUT' } elseif ($job.Process.ExitCode -ne 0) { 'FAIL' } else { 'PASS' }
            Complete-SuiteJob -Job $job -Status $status -Results ([ref]$results)
            [void]$jobs.Remove($job)
        }

        if ($jobs.Count -gt 0 -or $pending.Count -gt 0) {
            Start-Sleep -Milliseconds 50
        }
    }
} finally {
    [Console]::remove_CancelKeyPress($cancelHandler)

    foreach ($job in @($jobs.ToArray())) {
        if (-not $job.Process.HasExited) {
            try { $job.Process.Kill($true) } catch { }
            try { $job.Process.WaitForExit() } catch { }
        }
        Receive-SuiteOutput -Job $job
        Complete-SuiteJob -Job $job -Status $(if ($interrupted) { 'ABORTED' } else { 'KILLED' }) -Results ([ref]$results)
    }

    foreach ($entry in $pending) {
        $results.Add([pscustomobject]@{
            Name     = $entry.Name
            Script   = $entry.Script
            Suite    = $entry.Suite
            Status   = 'NOT RUN'
            ExitCode = $null
            Seconds  = 0
            Log      = $null
            Verified = $false
            Details  = @('suite did not start')
        })
        Write-Host ("[NOT RUN] {0}" -f $entry.Name)
    }
}

$watch.Stop()

$passed = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$timedOut = @($results | Where-Object { $_.Status -eq 'TIMEOUT' }).Count
$other = @($results | Where-Object { $_.Status -notin @('PASS', 'FAIL', 'TIMEOUT') }).Count

$summary = [pscustomobject]@{
    Schema = 'codebeltnet/agentic/local-validation/1'
    StartedUtc = [DateTime]::UtcNow.ToString('o')
    ElapsedSeconds = [Math]::Round($watch.Elapsed.TotalSeconds, 2)
    RepositoryRoot = $repoRoot
    Workflow = $workflow
    MaxConcurrency = $activeLimit
    PerSuiteTimeoutSeconds = $TimeoutSeconds
    DeadlineSeconds = $DeadlineSeconds
    Interrupted = $interrupted
    Coverage = [pscustomobject]@{
        Expected  = $matrix.Count
        Executed  = @($results | Where-Object { $_.Status -ne 'NOT RUN' }).Count
        Passed    = $passed
        Failed    = $failed
        TimedOut  = $timedOut
        NotRun    = @($results | Where-Object { $_.Status -eq 'NOT RUN' }).Count
        Verified  = (@($results | Where-Object { $_.Status -eq 'PASS' -and $_.Verified }).Count -eq $matrix.Count)
    }
    Results = @($results.ToArray() | Sort-Object Name)
}
$summaryPath = Join-Path $logRoot 'summary.json'
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6), $utf8NoBom)

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}  Timed out: {2}  Not run: {3}" -f $passed, $failed, $timedOut, @($results | Where-Object { $_.Status -eq 'NOT RUN' }).Count)
Write-Host ("Full validation finished in {0:N1}s." -f $summary.ElapsedSeconds)
Write-Host ("Summary: {0}" -f $summaryPath)

$unsuccessful = $passed -ne $matrix.Count -or $failed -gt 0 -or $timedOut -gt 0 -or $other -gt 0
if ($interrupted -or $unsuccessful) {
    exit 1
}
exit 0
