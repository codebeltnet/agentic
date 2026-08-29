<#!
.SYNOPSIS
    Deterministically fans out runner-owned native Eval Worker arms.

.DESCRIPTION
    This helper is an external-handoff surface only. It does not run during
    preparation, validation, CI, hooks, or reporting. It starts the selected
    package-local runner once per manifest arm, redirects each runner's sole
    JSON stdout directly to the manifest-declared execution_result path, and
    owns acceptance/terminal registration and orchestration state.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IterationDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
. (Join-Path $PSScriptRoot 'runner-common.ps1')
. (Join-Path $PSScriptRoot 'manifest-paths.ps1')
. (Join-Path $PSScriptRoot 'orchestration.ps1')
. (Join-Path $PSScriptRoot 'fanout-process.ps1')
. (Join-Path $PSScriptRoot 'execution-freeze.ps1')

function Write-FanoutSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [int]$ExitCode = 0
    )

    [Console]::Out.WriteLine(($Summary | ConvertTo-Json -Depth 100 -Compress))
    if ($ExitCode -ne 0) { exit $ExitCode }
}

function Save-OrchestrationState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State
    )

    [System.IO.File]::WriteAllText($Path, (($State | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Invoke-RunnerPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [int]$TimeoutSeconds = 120
    )

    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-runner-preflight-' + [Guid]::NewGuid().ToString('N') + '.stdout')
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-runner-preflight-' + [Guid]::NewGuid().ToString('N') + '.stderr')
    $child = $null
    try {
        $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
        # ProcessStartInfo.ArgumentList escapes each argument natively, so raw
        # paths are passed without manual quoting. The child preflight runs
        # headless (no visible console window on Windows).
        $arguments = @(
            '-NoProfile'
            '-File'
            $RunnerPath
            'preflight'
            '-Run'
            $RunPath
            '-Profile'
            $ProfilePath
        )
        $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $RunPath) -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds
        $exitCode = Complete-RunnerChildProcess -Child $child
        $childTimedOut = [bool]$child.TimedOut
        $childTerminationObserved = [bool]$child.TerminationObserved
        $child = $null
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { [System.IO.File]::ReadAllText($stdoutPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
        $result = $null
        $parseError = ''
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            try {
                $result = $stdout | ConvertFrom-Json -Depth 100
            } catch {
                $parseError = $_.Exception.Message
            }
        }
        return [pscustomobject]@{
            Result = $result
            ExitCode = $exitCode
            Stdout = $stdout
            Stderr = $stderr
            ParseError = $parseError
            TimedOut = $childTimedOut
            TerminationObserved = $childTerminationObserved
        }
    } finally {
        if ($null -ne $child) { try { [void](Complete-RunnerChildProcess -Child $child) } catch { } }
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Get-RunnerGraceSeconds {
    # This is the runner-child watchdog grace advertised in the generated
    # handoff. Process termination and stream drains have their own smaller,
    # finite bounds in the process helpers.
    return 30
}

function Get-RunnerPreflightTimeoutSeconds {
    param([Parameter(Mandatory = $true)][int]$ProfileTimeoutSeconds)

    return [Math]::Max(120, [Math]::Max(1, $ProfileTimeoutSeconds) + (Get-RunnerGraceSeconds))
}

function Get-RunnerRunTurnCount {
    param([Parameter(Mandatory = $true)][string]$RunPath)

    $run = Read-RunnerJson -Path $RunPath
    $interactionFile = [string](Get-JsonProperty -Object $run -Name 'interactionFile' -Default '')
    if ([string]::IsNullOrWhiteSpace($interactionFile)) { return 1 }
    $runRoot = Split-Path -Parent $RunPath
    $interactionPath = Resolve-ContainedPath -BasePath $runRoot -RelativePath $interactionFile -FieldName 'interactionFile' -Kind File
    $interaction = Read-RunnerJson -Path $interactionPath
    $turns = @(Get-JsonProperty -Object $interaction -Name 'turns' -Default @())
    return [Math]::Max(1, $turns.Count)
}

function Get-RunnerChildTimeoutSeconds {
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][int]$ProfileTimeoutSeconds
    )

    $turnCount = Get-RunnerRunTurnCount -RunPath $RunPath
    return [pscustomobject]@{
        TurnCount = $turnCount
        RunnerGraceSeconds = Get-RunnerGraceSeconds
        TimeoutSeconds = ($turnCount * [Math]::Max(1, $ProfileTimeoutSeconds)) + (Get-RunnerGraceSeconds)
    }
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
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $preflight) {
        foreach ($reason in @(Get-JsonProperty -Object $preflight -Name 'reasons' -Default @())) {
            if (-not [string]::IsNullOrWhiteSpace([string]$reason)) { [void]$reasons.Add([string]$reason) }
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace([string]$Invocation.ParseError)) { [void]$reasons.Add("runner preflight returned invalid JSON: $($Invocation.ParseError)") }
        if ([string]::IsNullOrWhiteSpace([string]$Invocation.Stdout)) { [void]$reasons.Add('runner preflight returned no JSON result.') }
    }
    if ($null -eq $invocationExitCode -or [int]$invocationExitCode -ne 0) {
        $diagnostic = [string]::Join(' ', @([string]$Invocation.Stderr, [string]$Invocation.Stdout).Where({ -not [string]::IsNullOrWhiteSpace($_) }))
        if ([string]::IsNullOrWhiteSpace($diagnostic)) { $diagnostic = 'no diagnostic output' }
        $reportedExitCode = if ($null -eq $invocationExitCode) { 'unknown' } else { [string]$invocationExitCode }
        [void]$reasons.Add("runner preflight exited with status ${reportedExitCode}: $diagnostic")
    }
    if ($invocationTimedOut) {
        [void]$reasons.Add('runner preflight watchdog timed out; no execution was started.')
    }
    if (-not $invocationTerminated) { [void]$reasons.Add('runner preflight process termination was not observed; no execution was started.') }

    $effectivePreflight = if ($null -ne $preflight) {
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
        preflights = @($Preflights)
    }
    if (-not [string]::IsNullOrWhiteSpace($Error)) { $summary.error = $Error }
    return $summary
}

function New-ArmSummary {
    param([Parameter(Mandatory = $true)][object]$State)

    return @(Get-OrchestrationCompletedEntries -State $State | Sort-Object { [string](Get-JsonProperty -Object $_ -Name 'worker_id' -Default '') } | ForEach-Object {
        $evidenceValidation = Get-JsonProperty -Object $_ -Name 'evidence_validation' -Default $null
        [ordered]@{
            worker_id = [string](Get-JsonProperty -Object $_ -Name 'worker_id' -Default '')
            eval_id = [int](Get-JsonProperty -Object $_ -Name 'eval_id' -Default 0)
            eval_name = [string](Get-JsonProperty -Object $_ -Name 'eval_name' -Default '')
            configuration = [string](Get-JsonProperty -Object $_ -Name 'configuration' -Default '')
            status = [string](Get-JsonProperty -Object $_ -Name 'status' -Default '')
            worker_session_id = Get-JsonProperty -Object $_ -Name 'worker_session_id' -Default $null
            evidence_validation = [ordered]@{
                status = [string](Get-JsonProperty -Object $evidenceValidation -Name 'status' -Default '')
                reasons = @((Get-JsonProperty -Object $evidenceValidation -Name 'reasons' -Default @()))
            }
            native_worker_evidence = [string](Get-JsonProperty -Object $_ -Name 'native_worker_evidence' -Default '')
            native_worker_evidence_failures = @((Get-JsonProperty -Object $_ -Name 'native_worker_evidence_failures' -Default @()))
        }
    })
}

function Get-FanoutSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$State,
        [object]$Concurrency = $null,
        [object[]]$Preflights = @(),
        [string]$Status = 'failed',
        [string]$Error = ''
    )

    $expectedCount = @((Get-JsonProperty -Object $Plan -Name 'arms' -Default @())).Count
    $aggregate = Get-FanoutPhase1Aggregate -ExpectedCount $expectedCount -State $State
    $preflight = Get-JsonProperty -Object $State -Name 'preflight' -Default $null
    $executionStarted = [bool](Get-JsonProperty -Object $preflight -Name 'execution_started' -Default ($aggregate.terminal_count -gt 0))
    if ([string]::IsNullOrWhiteSpace($Status)) { $Status = [string]$aggregate.status }
    $summary = [ordered]@{
        schema = 'codebeltnet/agentic/runner-owned-fanout-summary/1'
        phase = 'phase1'
        status = $Status
        runner = [string](Get-JsonProperty -Object $Profile -Name 'runner' -Default '')
        model = [string](Get-JsonProperty -Object $Profile -Name 'model' -Default '')
        dispatch_owner = [string](Get-JsonProperty -Object $Plan -Name 'dispatch_owner' -Default 'runner')
        requested_concurrency = [int](Get-JsonProperty -Object $Plan -Name 'requested_concurrency' -Default 0)
        expected_count = [int]$aggregate.expected_count
        terminal_count = [int]$aggregate.terminal_count
        completed_count = [int]$aggregate.completed_count
        failed_count = [int]$aggregate.failed_count
        timed_out_count = [int]$aggregate.timed_out_count
        cancelled_count = [int]$aggregate.cancelled_count
        incompatible_count = [int]$aggregate.incompatible_count
        evidence_validation_failed_count = [int]$aggregate.evidence_validation_failed_count
        max_observed_active = [int](Get-JsonProperty -Object $State -Name 'max_observed_active' -Default 0)
        orchestration_state = 'orchestration-state.json'
        preflight_count = @($Preflights).Count
        execution_started = $executionStarted
        execution_count = [int]$aggregate.terminal_count
        arms = @(New-ArmSummary -State $State)
    }
    if (@($Preflights).Count -gt 0) { $summary.preflights = @($Preflights) }
    if ($null -ne $Concurrency) { $summary.concurrency = $Concurrency }
    if (-not [string]::IsNullOrWhiteSpace($Error)) { $summary.error = $Error }
    return $summary
}

$running = $null
try {
    $manifestPath = Join-Path $iteration 'manifest.json'
    $manifest = Read-RunnerJson -Path $manifestPath
    $freezeRelativePath = [string](Get-JsonProperty -Object $manifest -Name 'execution_freeze' -Default '')
    if ([string]::IsNullOrWhiteSpace($freezeRelativePath)) { throw 'manifest.json must declare execution_freeze.' }
    $freezePath = Get-ExecutionFreezePath -IterationDirectory $iteration -RelativePath $freezeRelativePath
    if (Test-Path -LiteralPath $freezePath) {
        throw "Execution integrity failure: Phase 1 is already frozen at '$freezePath'; refusing a second runner-owned execution. Requires fresh Phase 1 execution."
    }
    $profileRelativePath = [string](Get-JsonProperty -Object $manifest -Name 'execution_profile' -Default '')
    if ([string]::IsNullOrWhiteSpace($profileRelativePath)) { throw 'manifest.json must declare execution_profile.' }
    $profilePath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $profileRelativePath -FieldName 'execution_profile' -Kind File -RequireExists
    $profile = Resolve-ExecutionProfile -ProfilePath $profilePath
    $runnerName = [string]$profile.Runner

    $resolverPath = Join-Path $PSScriptRoot 'resolve-runner.ps1'
    $resolutionOutput = & pwsh -NoProfile -File $resolverPath $runnerName 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Selected runner '$runnerName' could not be resolved: $([string]::Join(' ', @($resolutionOutput)))" }
    $resolution = ([string]::Join([Environment]::NewLine, @($resolutionOutput)) | ConvertFrom-Json)
    $runnerPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ([string]$resolution.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) { throw "Resolved runner '$runnerName' is missing its runner.ps1." }
    $descriptor = Get-PackageRunnerDescriptor -RunnerName $runnerName
    $delegation = Get-JsonProperty -Object $descriptor -Name 'delegation' -Default $null
    if ([string](Get-JsonProperty -Object $delegation -Name 'dispatch_owner' -Default '') -ne 'runner') {
        throw "Selected runner '$runnerName' does not declare delegation.dispatch_owner=runner."
    }

    $statePath = Join-Path $iteration 'orchestration-state.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        throw "Runner-owned fan-out refuses to replace an existing orchestration state at '$statePath'."
    }
    $manifestRecords = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest $manifest)
    $preflightRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $manifestRecords) {
        $invocation = Invoke-RunnerPreflight -RunnerPath $runnerPath -RunPath $record.RunManifestPath -ProfilePath ([string]$profile.Path) -TimeoutSeconds (Get-RunnerPreflightTimeoutSeconds -ProfileTimeoutSeconds ([int]$profile.TimeoutSeconds))
        $preflightRecords.Add((New-PreflightWorkerSummary -Record $record -Invocation $invocation -Descriptor $descriptor))
    }
    $failedPreflights = @($preflightRecords | Where-Object { [string]$_.status -ne 'compatible' })
    if ($failedPreflights.Count -gt 0) {
        Write-FanoutSummary -Summary (Get-PreflightGateSummary -Profile $profile.Profile -Preflights @($preflightRecords.ToArray())) -ExitCode 2
    }

    $plan = New-EvalOrchestrationPlan -IterationDirectory $iteration -Manifest $manifest -Profile $profile -Descriptor $descriptor
    [void](Assert-OrchestrationPlanContract -Plan $plan)
    if ([string]$plan.dispatch_owner -ne 'runner') { throw 'Runner-owned fan-out requires a runner-owned orchestration plan.' }
    $state = New-OrchestrationState -Plan $plan
    $state.preflight = [ordered]@{
        status = 'passed'
        count = $preflightRecords.Count
        workers = @($preflightRecords.ToArray())
        execution_started = $false
    }
    Save-OrchestrationState -Path $statePath -State $state

    $running = [System.Collections.Generic.List[object]]::new()
    while (@($state.pending_worker_ids).Count -gt 0 -or $running.Count -gt 0) {
        foreach ($dispatch in @(Get-NextWorkerDispatches -Plan $plan -State $state)) {
            $workerId = [string]$dispatch.worker_id
            $arm = Get-OrchestrationArmByWorkerId -Plan $plan -WorkerId $workerId
            $runPath = [string]$arm.worker.run_manifest_path
            $executionResultRelativePath = [string]$arm.parent_paths.execution_result
            $executionResultPath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $executionResultRelativePath -FieldName "$workerId.execution_result" -Kind File
            if (Test-Path -LiteralPath $executionResultPath) {
                throw "$workerId has an existing manifest-declared execution result; refusing to overwrite a prior attempt."
            }
            $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-runner-owned-' + [Guid]::NewGuid().ToString('N') + '.stderr')
            # ProcessStartInfo.ArgumentList escapes each argument natively, so raw
            # paths are passed without manual quoting.
            $arguments = @(
                '-NoProfile'
                '-File'
                $runnerPath
                'execute'
                '-Run'
                $runPath
                '-Profile'
                ([string]$profile.Path)
            )
            $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
            $childBudget = Get-RunnerChildTimeoutSeconds -RunPath $runPath -ProfileTimeoutSeconds ([int]$profile.TimeoutSeconds)
            # Headless child: CreateNoWindow suppresses the per-child console
            # window on Windows while the process stays a real isolation
            # boundary. The child's sole stdout is streamed to the exact
            # manifest-declared execution result; stderr is captured separately.
            $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $runPath) -StdoutPath $executionResultPath -StderrPath $stderrPath -TimeoutSeconds ([int]$childBudget.TimeoutSeconds)
            if (-not [bool]$state.preflight.execution_started) {
                $state.preflight.execution_started = $true
                Save-OrchestrationState -Path $statePath -State $state
            }
            [void](Register-DelegationAccepted -State $state -WorkerId $workerId)
            Save-OrchestrationState -Path $statePath -State $state
            $running.Add([pscustomobject]@{ worker_id = $workerId; child = $child; Process = $child.Process; result_path = $executionResultPath; stderr_path = $stderrPath; run_path = $runPath; timeout_seconds = [int]$childBudget.TimeoutSeconds; turn_count = [int]$childBudget.TurnCount })
        }

        if ($running.Count -eq 0) { throw 'Runner-owned fan-out has pending arms but no active native process.' }
        # Release a slot as soon as ANY child completes, not only the oldest in
        # the list, so a slow eval execution never blocks refilling the slot a
        # faster sibling already freed.
        $completedIndex = Wait-AnyRunnerChild -Running $running
        $activeRun = $running[$completedIndex]
        $exitCode = Complete-RunnerChildProcess -Child $activeRun.child
        if ([bool]$activeRun.child.TimedOut) {
            throw "$($activeRun.worker_id) runner child watchdog timed out after $($activeRun.timeout_seconds) seconds (turns=$($activeRun.turn_count)); no retry or redispatch was performed."
        }
        if (-not (Test-Path -LiteralPath $activeRun.result_path -PathType Leaf) -or (Get-Item -LiteralPath $activeRun.result_path).Length -eq 0) {
            $stderr = if (Test-Path -LiteralPath $activeRun.stderr_path -PathType Leaf) { [System.IO.File]::ReadAllText($activeRun.stderr_path, [System.Text.UTF8Encoding]::new($false)).Trim() } else { '' }
            throw "$($activeRun.worker_id) runner exited with status $exitCode without writing its manifest-declared execution result. $stderr"
        }
        $executionResult = Read-RunnerJson -Path $activeRun.result_path
        [void](Assert-ExecutionResult -Result $executionResult)
        $sessionId = [string](Get-JsonProperty -Object (Get-JsonProperty -Object $executionResult -Name 'session' -Default $null) -Name 'id' -Default '')
        [void](Register-DelegationSession -State $state -WorkerId ([string]$activeRun.worker_id) -WorkerSessionId $sessionId)
        [void](Register-WorkerTerminal -Plan $plan -State $state -WorkerId ([string]$activeRun.worker_id) -ExecutionEvidence $executionResult)
        Save-OrchestrationState -Path $statePath -State $state
        if (Test-Path -LiteralPath $activeRun.stderr_path -PathType Leaf) { Remove-Item -LiteralPath $activeRun.stderr_path -Force -ErrorAction SilentlyContinue }
        $running.RemoveAt($completedIndex)
    }

    $concurrency = Assert-OrchestrationConcurrency -Plan $plan -State $state
    Save-OrchestrationState -Path $statePath -State $state
    # Phase 1 ends here. Freeze the exact runner-produced bytes and all raw
    # artifacts before any bridge, grader, or report process can run. The
    # freeze is intentionally written once; later phases can validate it but
    # cannot replace it after evidence changes.
    $freeze = New-ExecutionFreezeDocument -IterationDirectory $iteration -Manifest $manifest -Records $manifestRecords -Profile $profile
    $freezePath = Write-ExecutionFreezeDocument -IterationDirectory $iteration -Freeze $freeze -RelativePath $freezeRelativePath
    $state.execution_freeze = [ordered]@{
        schema = (Get-RunnerSchemaNames).ExecutionFreeze
        path = [System.IO.Path]::GetRelativePath($iteration, $freezePath).Replace('\', '/')
        sha256 = Get-Sha256HexFromFile -Path $freezePath
    }
    Save-OrchestrationState -Path $statePath -State $state
    $aggregate = Get-FanoutPhase1Aggregate -ExpectedCount @($plan.arms).Count -State $state
    $summary = Get-FanoutSummary -Profile $profile -Plan $plan -State $state -Concurrency $concurrency -Preflights @($preflightRecords.ToArray()) -Status ([string]$aggregate.status)
    $summary.execution_freeze = [ordered]@{
        path = $freezePath
        sha256 = [string]$state.execution_freeze.sha256
        schema = [string]$state.execution_freeze.schema
    }
    $phaseOneExitCode = if (Test-FanoutPhase1Success -Aggregate $aggregate) { 0 } else { 2 }
    Write-FanoutSummary -Summary $summary -ExitCode $phaseOneExitCode
} catch {
    $errorMessage = $_.Exception.Message
    if ($null -ne $running) {
        foreach ($active in @($running.ToArray())) {
            try { [void](Complete-RunnerChildProcess -Child $active.child -TimeoutSeconds 1) } catch { }
        }
    }
    $fallbackProfile = [ordered]@{ runner = ''; model = '' }
    $fallbackPlan = [ordered]@{ dispatch_owner = 'runner'; requested_concurrency = 0 }
    $fallbackState = [ordered]@{ max_observed_active = 0; completed = [ordered]@{} }
    try {
        if (Test-Path -LiteralPath (Join-Path $iteration 'orchestration-state.json') -PathType Leaf) { $fallbackState = Read-RunnerJson -Path (Join-Path $iteration 'orchestration-state.json') }
    } catch { }
    try {
        Write-FanoutSummary -Summary (Get-FanoutSummary -Profile $fallbackProfile -Plan $fallbackPlan -State $fallbackState -Status 'failed' -Error $errorMessage) -ExitCode 2
    } catch {
        # A persisted JSON state is intentionally deserialized and therefore no
        # longer exposes the mutable dictionaries used by the live queue. Keep
        # the failure machine-readable without masking its original reason.
        Write-FanoutSummary -Summary ([ordered]@{
            schema = 'codebeltnet/agentic/runner-owned-fanout-summary/1'
            phase = 'phase1'
            status = 'failed'
            runner = ''
            model = ''
            dispatch_owner = 'runner'
            requested_concurrency = 0
            expected_count = 0
            terminal_count = 0
            completed_count = 0
            failed_count = 0
            timed_out_count = 0
            cancelled_count = 0
            incompatible_count = 0
            evidence_validation_failed_count = 0
            max_observed_active = 0
            orchestration_state = 'orchestration-state.json'
            arms = @()
            error = $errorMessage
        }) -ExitCode 2
    }
}
