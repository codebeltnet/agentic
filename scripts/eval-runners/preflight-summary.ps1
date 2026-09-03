<#!
.SYNOPSIS
    Operator-facing preflight result summary constructors.

.DESCRIPTION
    Pure helpers that assemble operator-facing summaries of runner preflight
    invocations. The output boundary is strict: raw child process output
    (Stdout, Stderr, and exception text from a JSON parse failure) must never
    appear in operator-facing reasons or progress messages. Only safe
    structural facts are used: worker identity, runner identity, exit status,
    timeout state, termination observed, whether valid JSON was returned, and
    the preflight's own structured reasons.

    This file is dot-sourced by invoke-runner-owned-arms.ps1 and by the
    focused preflight-summary unit tests. It never invokes a model.
#>
Set-StrictMode -Version Latest

if (-not (Get-Command Get-JsonProperty -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'runner-common.ps1')
}

function New-PreflightWorkerSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][object]$Invocation,
        [Parameter(Mandatory = $true)][object]$Descriptor
    )

    $preflight = $Invocation.Result
    $invocationExitCode = Get-JsonProperty -Object $Invocation -Name 'ExitCode' -Default $null
    $invocationTimedOut = [bool](Get-JsonProperty -Object $Invocation -Name 'TimedOut' -Default $false)
    $invocationTerminated = [bool](Get-JsonProperty -Object $Invocation -Name 'TerminationObserved' -Default $false)
    $validJsonReturned = $null -ne $preflight
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($validJsonReturned) {
        foreach ($reason in @(Get-JsonProperty -Object $preflight -Name 'reasons' -Default @())) {
            if (-not [string]::IsNullOrWhiteSpace([string]$reason)) { [void]$reasons.Add([string]$reason) }
        }
    } else {
        # Structural diagnosis only. Raw child output (Invocation.Stderr,
        # Invocation.Stdout) and exception text from a JSON parse failure
        # (Invocation.ParseError) are deliberately excluded: they can carry
        # arbitrary child output including secrets, model content, or
        # malformed bytes. Use only safe, known-enumerable structural facts.
        if (-not [string]::IsNullOrWhiteSpace([string]$Invocation.ParseError)) {
            [void]$reasons.Add('runner preflight returned invalid JSON.')
        } elseif ([string]::IsNullOrWhiteSpace([string]$Invocation.Stdout)) {
            [void]$reasons.Add('runner preflight returned no JSON result.')
        }
    }
    if ($null -eq $invocationExitCode -or [int]$invocationExitCode -ne 0) {
        $reportedExitCode = if ($null -eq $invocationExitCode) { 'unknown' } else { [string]$invocationExitCode }
        [void]$reasons.Add("runner preflight exited with status ${reportedExitCode}.")
    }
    if ($invocationTimedOut) {
        [void]$reasons.Add('runner preflight watchdog timed out; no execution was started.')
    }
    if (-not $invocationTerminated) { [void]$reasons.Add('runner preflight process termination was not observed; no execution was started.') }

    $effectivePreflight = if ($validJsonReturned) {
        $preflight
    } else {
        [ordered]@{
            status = 'incompatible'
            delegation = [ordered]@{}
            resolved_capabilities = [ordered]@{}
        }
    }
    $status = [string](Get-JsonProperty -Object $effectivePreflight -Name 'status' -Default 'incompatible')
    if ($status -ne 'compatible' -and $reasons.Count -eq 0) { [void]$reasons.Add("runner preflight returned status '$status'.") }
    $delegationAssertion = 'passed'
    $delegationError = ''
    try {
        [void](Assert-NativeWorkerDelegation -Descriptor $Descriptor -Preflight $effectivePreflight)
    } catch {
        $delegationAssertion = 'failed'
        $delegationError = $_.Exception.Message
        [void]$reasons.Add($delegationError)
    }

    return [ordered]@{
        worker_id = 'arm-{0}-{1}' -f $Record.EvalId, $Record.Configuration
        eval_id = [int]$Record.EvalId
        eval_name = [string]$Record.EvalName
        configuration = [string]$Record.Configuration
        run_manifest = [string]$Record.RunManifestRelative
        execution_result = [string]$Record.ExecutionResultRelative
        status = if ($status -eq 'compatible' -and $delegationAssertion -eq 'passed' -and $null -ne $invocationExitCode -and [int]$invocationExitCode -eq 0 -and -not $invocationTimedOut -and $invocationTerminated) { 'compatible' } else { 'incompatible' }
        reasons = @($reasons.ToArray())
        native_delegation_assertion = [ordered]@{
            status = $delegationAssertion
            error = $delegationError
        }
        runner_exit_code = if ($null -eq $invocationExitCode) { $null } else { [int]$invocationExitCode }
    }
}

function Get-PreflightGateSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object[]]$Preflights,
        [string]$Status = 'preflight_incompatible',
        [bool]$ExecutionStarted = $false,
        [int]$ExecutionCount = 0,
        [string]$Error = ''
    )

    $incompatible = @($Preflights | Where-Object { [string]$_.status -ne 'compatible' })
    $summary = [ordered]@{
        schema = 'codebeltnet/agentic/runner-owned-fanout-summary/1'
        phase = 'preflight'
        status = $Status
        runner = [string](Get-JsonProperty -Object $Profile -Name 'runner' -Default '')
        model = [string](Get-JsonProperty -Object $Profile -Name 'model' -Default '')
        dispatch_owner = 'runner'
        requested_concurrency = [int](Get-JsonProperty -Object $Profile -Name 'concurrency' -Default 0)
        preflight_count = @($Preflights).Count
        incompatible_count = $incompatible.Count
        execution_started = $ExecutionStarted
        execution_count = $ExecutionCount
        progress_log = 'progress/phase1-progress.jsonl'
        preflights = @($Preflights)
    }
    if (-not [string]::IsNullOrWhiteSpace($Error)) { $summary.error = $Error }
    return $summary
}
