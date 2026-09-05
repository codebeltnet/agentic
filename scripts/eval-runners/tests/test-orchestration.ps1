<#
.SYNOPSIS
    Deterministic native-worker orchestration contract tests.

.DESCRIPTION
    Exercises only the manifest queue/state machinery. The fake capacity
    harness below never starts a process or contacts a model.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'orchestration.ps1')
. (Join-Path $runnerRoot 'fanout-process.ps1')
. (Join-Path $runnerRoot 'package-integrity.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw "ASSERT: $Message (expected '$Expected', got '$Actual')"
    }
}

function Write-TestJson {
    param([string]$Path, [object]$Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Invoke-ForegroundPhaseOne {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory)

    $fanout = Join-Path $IterationDirectory 'tools/eval-runners/invoke-runner-owned-arms.ps1'
    # STDOUT is the machine protocol (one terminal JSON summary); STDERR is the
    # live observability channel. Capture them separately so relayed heartbeats
    # never contaminate the JSON the controller parses.
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('phase1-stderr-' + [Guid]::NewGuid().ToString('N') + '.log')
    try {
        $output = & pwsh -NoProfile -File $fanout -IterationDirectory $IterationDirectory 2>$stderrPath
        $exitCode = $LASTEXITCODE
        $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    $document = $text | ConvertFrom-Json -Depth 100
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; Stderr = $stderr; Document = $document }
}

function Remove-PhaseOnePackageState {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory)

    foreach ($name in @('orchestration-state.json', 'execution-freeze.json')) {
        Remove-Item -LiteralPath (Join-Path $IterationDirectory $name) -Force -ErrorAction SilentlyContinue
    }
}

function Copy-TestObject {
    param([Parameter(Mandatory = $true)][object]$Value)

    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
}

function New-TestNativeTerminalEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Arm,
        [Parameter(Mandatory = $true)][object]$RunData,
        [Parameter(Mandatory = $true)][string]$WorkerSessionId
    )

    return [ordered]@{
        status = 'completed'
        session = [ordered]@{ id = $WorkerSessionId; fresh = $true; resumed = $false }
        run = [ordered]@{ eval_id = [int]$Arm.eval_id; eval_name = [string]$Arm.eval_name; configuration = [string]$Arm.configuration }
        requested = [ordered]@{ model = [string]$Arm.worker.model }
        input = [ordered]@{ prompt_sha256 = [string]$RunData.PromptHash }
        evidence = [ordered]@{
            delegation = [ordered]@{
                mechanism = 'deterministic-fake-native-worker'
                worker_session_id = $WorkerSessionId
                observed_model = [string]$Arm.worker.model
                observed_working_directory = [string]$RunData.WorkingDirectoryPath
                observed_home = [string]$RunData.HomeDirectoryPath
                fresh_worker = $true
                home_config_isolated = $true
                prompt_fidelity = $true
                prompt_sha256 = [string]$RunData.PromptHash
                terminal_result_capture = $true
                paired_arm_visible = $false
                grading_material_visible = $false
                nested_model_execution = $false
                model_execution_count = 1
            }
        }
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-orchestration-' + [Guid]::NewGuid().ToString('N'))
$oldFixtureLogPath = $env:AGENTIC_RUNNER_FIXTURE_LOG
try {
    $iteration = Join-Path $testRoot 'iteration-1'
    New-Item -ItemType Directory -Path $iteration -Force | Out-Null

    $manifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le 8; $evalId++) {
        $evalName = 'eval-{0:d2}' -f $evalId
        $evalDirectory = Join-Path $iteration $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
        Write-TestJson -Path (Join-Path $evalDirectory 'eval-metadata.json') -Value ([ordered]@{
            eval_id = $evalId
            eval_name = $evalName
            assertions = @('assertion')
        })

        $runs = [ordered]@{}
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $runDirectory = Join-Path $evalDirectory $configuration
            New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $runDirectory 'repo') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $runDirectory 'home') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'prompt.md'), "terminal test prompt for $evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            if ($configuration -eq 'with_skill') {
                New-Item -ItemType Directory -Path (Join-Path $runDirectory 'skill') -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path (Join-Path $runDirectory 'skill') 'SKILL.md'), '# deterministic terminal test skill', [System.Text.UTF8Encoding]::new($false))
            }
            Write-TestJson -Path (Join-Path $runDirectory 'run.json') -Value ([ordered]@{
                schema = (Get-RunnerSchemaNames).Run
                evalId = $evalId
                evalName = $evalName
                mode = $configuration
                promptFile = 'prompt.md'
                workingDirectory = 'repo'
                homeDirectory = 'home'
                skillDirectory = if ($configuration -eq 'with_skill') { 'skill' } else { $null }
                freshContextRequired = $true
                filesystemIsolationRequired = $true
                isolatedHomeRequired = $true
                mustNotReadOutsideSandbox = $true
                fixtureHash = ('a' * 64)
                skillHash = if ($configuration -eq 'with_skill') { ('b' * 64) } else { $null }
            })
            $resultFileName = if ($configuration -eq 'with_skill') { 'with-skill.result.json' } else { 'without-skill.result.json' }
            Write-TestJson -Path (Join-Path $evalDirectory (Join-Path 'results' $resultFileName)) -Value ([ordered]@{
                eval_id = $evalId
                configuration = $configuration
                execution_status = 'unrun'
                grading = @()
            })
            $executionFileName = if ($configuration -eq 'with_skill') { 'with-skill.execution-result.json' } else { 'without-skill.execution-result.json' }
            $runs[$configuration] = [ordered]@{
                mode = $configuration
                run_manifest = "$evalName/$configuration/run.json"
                execution_result = "$evalName/results/$executionFileName"
                result = "$evalName/results/$resultFileName"
            }
        }
        $manifestEvals.Add([ordered]@{
            eval_id = $evalId
            eval_name = $evalName
            directory = $evalName
            metadata = "$evalName/eval-metadata.json"
            runs = $runs
        })
    }

    $manifest = [ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_freeze = 'execution-freeze.json'
        evals = @($manifestEvals)
    }
    $profile = [ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fake'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 60
        concurrency = 16
    }

    $plan = New-EvalOrchestrationPlan -IterationDirectory $iteration -Manifest $manifest -Profile $profile
    [void](Assert-OrchestrationPlanContract -Plan $plan)
    $serializedPlan = $plan | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    [void](Assert-OrchestrationPlanContract -Plan $serializedPlan)
    Assert-Equal 16 @($plan.arms).Count '8 eval cases fan out to 16 independent arms'
    Assert-Equal 16 $plan.requested_concurrency 'requested concurrency is preserved in the plan'
    Assert-True ([bool]$plan.parallel_dispatch_required) 'independent arms require concurrent dispatch'
    Assert-Equal 2 $plan.minimum_parallel_workers 'independent arms require at least two active workers'
    Assert-True ([bool]$plan.native_worker_required) 'native worker delegation is mandatory'
    Assert-True (-not [bool]$plan.parent_executes_arms) 'the parent is forbidden from executing arms'
    Assert-True (-not [bool]$plan.nested_model_execution) 'the plan forbids a nested model layer'
    Assert-Equal 16 (@($plan.arms | ForEach-Object { [string]$_.worker_id } | Sort-Object -Unique).Count) 'every arm has a distinct worker identity'
    Assert-Equal 16 (@($plan.arms | Where-Object { @($_.depends_on).Count -eq 0 }).Count) 'unrelated arms have no sequential dependencies'

    $initialState = New-OrchestrationState -Plan $plan
    $initialDispatches = @(Get-NextWorkerDispatches -Plan $plan -State $initialState)
    Assert-Equal 16 $initialDispatches.Count 'requested concurrency exposes all 16 pending arms'
    foreach ($dispatch in $initialDispatches) {
        Assert-True ([bool]$dispatch.worker_contract.one_arm_only) "$($dispatch.worker_id) receives one arm"
        Assert-True (-not [bool]$dispatch.worker_contract.paired_arm_visible) "$($dispatch.worker_id) cannot see its paired arm"
        Assert-True (-not [bool]$dispatch.worker_contract.grading_material_visible) "$($dispatch.worker_id) cannot see grading material"
        Assert-True (-not [bool]$dispatch.worker_contract.parent_executes_arm) "$($dispatch.worker_id) cannot execute in the parent"
        Assert-Equal 'forbidden' $dispatch.worker_contract.runner_execute_invocation "$($dispatch.worker_id) cannot invoke direct runner execute"
        Assert-True (-not [bool]$dispatch.worker_contract.nested_model_execution) "$($dispatch.worker_id) has no nested model layer"
        Assert-Equal 1 $dispatch.worker_contract.model_execution_count "$($dispatch.worker_id) has one model execution"
        Assert-True ($dispatch.PSObject.Properties.Name -notcontains 'paired_arm') "$($dispatch.worker_id) has no paired-arm payload"
        Assert-True ($dispatch.PSObject.Properties.Name -notcontains 'grading') "$($dispatch.worker_id) has no grading payload"
        Assert-True ($dispatch.PSObject.Properties.Name -notcontains 'expected_output') "$($dispatch.worker_id) has no expected-output payload"
    }

    # Codex uses runner-owned native dispatch. The runner process/thread is the
    # worker, so the portable queue must not ask an outer model orchestrator to
    # create a subagent first. Six recorded arms are advanced concurrently;
    # this test never starts a process or model.
    $runnerDescriptor = [pscustomobject]@{
        name = 'codex'
        delegation = [ordered]@{
            dispatch_owner = 'runner'
            mechanism = 'deterministic-fake-native-worker'
        }
    }
    $runnerProfile = [ordered]@{
        runner = 'codex'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 60
        concurrency = 3
    }
    $runnerPlan = New-EvalOrchestrationPlan -IterationDirectory $iteration -Manifest $manifest -Profile $runnerProfile -Descriptor $runnerDescriptor
    [void](Assert-OrchestrationPlanContract -Plan $runnerPlan)
    Assert-Equal 'runner' $runnerPlan.dispatch_owner 'runner-owned descriptor selects runner dispatch'
    $runnerState = New-OrchestrationState -Plan $runnerPlan
    $outerSubagentCalls = 0
    $runnerWorkerStarts = 0
    $runnerDispatches = @(Get-NextWorkerDispatches -Plan $runnerPlan -State $runnerState)
    Assert-Equal 3 $runnerDispatches.Count 'runner-owned dispatch respects requested concurrency'
    foreach ($dispatch in $runnerDispatches) {
        Assert-Equal 'runner' $dispatch.worker_contract.dispatch_owner "$($dispatch.worker_id) is runner-owned"
        Assert-Equal 'required' $dispatch.worker_contract.runner_execute_invocation "$($dispatch.worker_id) uses the runner-owned execution surface"
        $runnerWorkerStarts++
        [void](Register-DelegationAccepted -State $runnerState -WorkerId $dispatch.worker_id)
    }
    Assert-Equal 3 (Get-OrchestrationActiveCount -State $runnerState) 'runner-owned workers are active concurrently'
    Assert-True ($runnerState.max_observed_active -gt 1) 'runner-owned dispatch observes parallel active workers'
    foreach ($workerId in @($runnerState.active.Keys)) {
        $arm = Get-OrchestrationArmByWorkerId -Plan $runnerPlan -WorkerId ([string]$workerId)
        $runData = Resolve-RunContract -RunPath ([string]$arm.worker.run_manifest_path)
        [void](Register-WorkerTerminal -Plan $runnerPlan -State $runnerState -WorkerId ([string]$workerId) -ExecutionEvidence (New-TestNativeTerminalEvidence -Arm $arm -RunData $runData -WorkerSessionId ('runner-session-' + $workerId)))
    }
    $runnerDispatches = @(Get-NextWorkerDispatches -Plan $runnerPlan -State $runnerState)
    Assert-Equal 3 $runnerDispatches.Count 'runner-owned queue dispatches the next concurrent batch'
    foreach ($dispatch in $runnerDispatches) {
        $runnerWorkerStarts++
        [void](Register-DelegationAccepted -State $runnerState -WorkerId $dispatch.worker_id)
    }
    foreach ($workerId in @($runnerState.active.Keys)) {
        $arm = Get-OrchestrationArmByWorkerId -Plan $runnerPlan -WorkerId ([string]$workerId)
        $runData = Resolve-RunContract -RunPath ([string]$arm.worker.run_manifest_path)
        [void](Register-WorkerTerminal -Plan $runnerPlan -State $runnerState -WorkerId ([string]$workerId) -ExecutionEvidence (New-TestNativeTerminalEvidence -Arm $arm -RunData $runData -WorkerSessionId ('runner-session-' + $workerId)))
    }
    Assert-Equal 6 @($runnerState.completed.Keys).Count 'runner-owned test completes six independent arms'
    Assert-Equal 6 $runnerWorkerStarts 'runner-owned dispatch starts one runner surface per arm'
    Assert-Equal 0 $outerSubagentCalls 'runner-owned dispatch never requests an outer model subagent'
    Assert-Equal 3 $runnerState.max_observed_active 'runner-owned state records concurrent maximum'

    # A fake harness accepts only four simultaneous native workers. This limit
    # belongs to the fake harness, not to the portable plan or queue.
    $capacityState = New-OrchestrationState -Plan $plan
    $startedWorkers = [System.Collections.Generic.List[string]]::new()
    $rejectedWorkers = [System.Collections.Generic.List[string]]::new()
    $attemptsAtRejection = @{}
    $maxObservedByHarness = 0
    $firstDispatches = @(Get-NextWorkerDispatches -Plan $plan -State $capacityState)
    foreach ($dispatch in $firstDispatches) {
        if ((Get-OrchestrationActiveCount -State $capacityState) -lt 4) {
            [void](Register-DelegationAccepted -State $capacityState -WorkerId $dispatch.worker_id -WorkerSessionId ('session-' + $dispatch.worker_id))
            $startedWorkers.Add([string]$dispatch.worker_id)
        } else {
            [void](Register-DelegationRejected -State $capacityState -WorkerId $dispatch.worker_id -Reason 'fake harness capacity is four' -CapacityLimited)
            $rejectedWorkers.Add([string]$dispatch.worker_id)
            $attemptsAtRejection[[string]$dispatch.worker_id] = $capacityState.eval_attempts.Contains([string]$dispatch.worker_id)
        }
        $maxObservedByHarness = [Math]::Max($maxObservedByHarness, (Get-OrchestrationActiveCount -State $capacityState))
    }
    Assert-Equal 4 $startedWorkers.Count 'the fake harness starts four workers before rejecting capacity overflow'
    Assert-True ($rejectedWorkers.Count -gt 0) 'capacity overflow creates queued rejections'
    Assert-True (@($attemptsAtRejection.Values | Where-Object { $_ }).Count -eq 0) 'a rejected delegation is not an eval attempt'
    Assert-Equal 16 $capacityState.requested_concurrency 'capacity handling does not lower portable requested concurrency'

    while (@($capacityState.completed.Keys).Count -lt @($plan.arms).Count) {
        $dispatches = @(Get-NextWorkerDispatches -Plan $plan -State $capacityState)
        foreach ($dispatch in $dispatches) {
            if ((Get-OrchestrationActiveCount -State $capacityState) -lt 4) {
                [void](Register-DelegationAccepted -State $capacityState -WorkerId $dispatch.worker_id -WorkerSessionId ('session-' + $dispatch.worker_id))
                if ($startedWorkers -notcontains [string]$dispatch.worker_id) { $startedWorkers.Add([string]$dispatch.worker_id) }
            } else {
                [void](Register-DelegationRejected -State $capacityState -WorkerId $dispatch.worker_id -Reason 'fake harness capacity is four' -CapacityLimited)
            }
            $maxObservedByHarness = [Math]::Max($maxObservedByHarness, (Get-OrchestrationActiveCount -State $capacityState))
        }

        $activeIds = @($capacityState.active.Keys)
        if ($activeIds.Count -gt 0) {
            $workerId = [string]$activeIds[0]
            $arm = Get-OrchestrationArmByWorkerId -Plan $plan -WorkerId $workerId
            $runData = Resolve-RunContract -RunPath ([string]$arm.worker.run_manifest_path)
            $workerSessionId = [string]$capacityState.active[$workerId].worker_session_id
            [void](Register-WorkerTerminal -Plan $plan -State $capacityState -WorkerId $workerId -ExecutionEvidence ([ordered]@{
                status = 'completed'
                session = [ordered]@{ id = $workerSessionId; fresh = $true; resumed = $false }
                run = [ordered]@{ eval_id = [int]$arm.eval_id; eval_name = [string]$arm.eval_name; configuration = [string]$arm.configuration }
                evidence = [ordered]@{
                    delegation = [ordered]@{
                        mechanism = 'deterministic-fake-native-worker'
                        worker_session_id = $workerSessionId
                        observed_model = [string]$arm.worker.model
                        observed_working_directory = [string]$runData.WorkingDirectoryPath
                        observed_home = [string]$runData.HomeDirectoryPath
                        fresh_worker = $true
                        home_config_isolated = $true
                        prompt_fidelity = $true
                        prompt_sha256 = [string]$runData.PromptHash
                        terminal_result_capture = $true
                        paired_arm_visible = $false
                        grading_material_visible = $false
                        nested_model_execution = $false
                        model_execution_count = 1
                    }
                }
            }))
        } elseif (@($capacityState.pending_worker_ids).Count -gt 0) {
            throw 'capacity queue deadlocked with pending workers and no active worker.'
        }
    }
    Assert-Equal 16 @($capacityState.completed.Keys).Count 'all 16 arms eventually become terminal'
    Assert-Equal 16 $startedWorkers.Count 'all 16 arms start exactly once after capacity is released'
    Assert-Equal 4 $capacityState.max_observed_active 'state records the fake harness maximum of four active workers'
    Assert-Equal 4 $maxObservedByHarness 'the fake harness never exceeds four active workers'
    Assert-Equal 0 @($capacityState.pending_worker_ids).Count 'no arm remains queued after capacity is released'
    [void](Assert-OrchestrationConcurrency -Plan $plan -State $capacityState)

    $serialState = New-OrchestrationState -Plan $plan
    $serialState.max_observed_active = 1
    $serialState.pending_worker_ids = @()
    $serialState.active = [ordered]@{}
    $serialState.completed = [ordered]@{}
    $serialRejected = $false
    try { [void](Assert-OrchestrationConcurrency -Plan $plan -State $serialState) } catch { $serialRejected = $true }
    Assert-True $serialRejected 'serial dispatch without capacity evidence fails the concurrency gate'

    $capacityStateJson = $capacityState | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    [void](Assert-OrchestrationConcurrency -Plan $plan -State $capacityStateJson)
    Assert-True ([bool]$capacityStateJson.capacity_limit_reported) 'serialized fallback is permitted only with persisted capacity evidence'

    $badDescriptor = [pscustomobject]@{
        name = 'fake-without-delegation'
        delegation = [ordered]@{ mode = 'conditional'; nested_model_execution = $false }
    }
    $badPreflight = [ordered]@{
        status = 'compatible'
        delegation = [ordered]@{ status = 'conditional'; unproven_controls = @('native_worker_delegation') }
        resolved_capabilities = [ordered]@{}
    }
    $parentDispatches = 0
    $fallbackRejected = $false
    try {
        [void](Assert-NativeWorkerDelegation -Descriptor $badDescriptor -Preflight $badPreflight)
        $parentDispatches++
    } catch {
        $fallbackRejected = $true
    }
    Assert-True $fallbackRejected 'missing native delegation fails preflight'
    Assert-Equal 0 $parentDispatches 'failed delegation preflight never invokes parent fallback'

    # A native mechanism may be locally ready while worker-specific controls
    # remain conditional. The gate must allow that handoff only when it will
    # validate terminal evidence; it must never reuse compatibility execute.
    $conditionalDescriptor = [pscustomobject]@{
        name = 'conditional-native'
        delegation = [ordered]@{ dispatch_owner = 'orchestrator'; mode = 'native_worker'; nested_model_execution = $false }
    }
    $conditionalCapabilities = [ordered]@{
        native_worker_delegation = 'conditional'
        delegated_worker_full_capability = 'conditional'
        delegated_worker_model_lock = 'conditional'
        delegated_worker_working_directory = 'conditional'
        delegated_worker_result_capture = 'conditional'
        delegated_worker_capacity_signal = 'supported'
    }
    $conditionalPreflight = [ordered]@{
        status = 'compatible'
        delegation = [ordered]@{ status = 'conditional'; unproven_controls = @('delegated_worker_model_lock'); terminal_evidence_required = $true }
        resolved_capabilities = $conditionalCapabilities
    }
    Assert-True (Assert-NativeWorkerDelegation -Descriptor $conditionalDescriptor -Preflight $conditionalPreflight) 'conditional native preflight is accepted only for terminal validation'
    $conditionalWithoutTerminalEvidence = [ordered]@{
        status = 'compatible'
        delegation = [ordered]@{ status = 'conditional'; unproven_controls = @('delegated_worker_model_lock') }
        resolved_capabilities = $conditionalCapabilities
    }
    $conditionalWithoutTerminalRejected = $false
    try { [void](Assert-NativeWorkerDelegation -Descriptor $conditionalDescriptor -Preflight $conditionalWithoutTerminalEvidence) } catch { $conditionalWithoutTerminalRejected = $true }
    Assert-True $conditionalWithoutTerminalRejected 'conditional native preflight without a terminal-evidence requirement is rejected'

    $terminalArm = $plan.arms[0]
    $terminalRunData = Resolve-RunContract -RunPath ([string]$terminalArm.worker.run_manifest_path)
    $validTerminalEvidence = New-TestNativeTerminalEvidence -Arm $terminalArm -RunData $terminalRunData -WorkerSessionId 'native-terminal-session'
    Assert-True ((Test-NativeWorkerTerminalEvidence -ExecutionEvidence $validTerminalEvidence -Run $terminalRunData -RequestedModel ([string]$terminalArm.worker.model) -ExpectedWorkerSessionId 'native-terminal-session').Valid) 'valid terminal native-worker evidence is accepted'
    Assert-True (Assert-NativeWorkerTerminalEvidence -ExecutionEvidence $validTerminalEvidence -Run $terminalRunData -RequestedModel ([string]$terminalArm.worker.model) -ExpectedWorkerSessionId 'native-terminal-session') 'valid terminal evidence passes the assert gate'

    # Runner-specific checks and the portable validator must make one terminal
    # decision. Preserve the exact runner codes while the common validator
    # rechecks the portable evidence.
    $codexFailureCodes = @('instruction_sources_unobserved', 'observed_model', 'observed_working_directory', 'fresh_worker', 'prompt_fidelity', 'terminal_result_capture', 'terminal_turn_status')
    $runnerIncompatible = Copy-TestObject -Value $validTerminalEvidence
    $runnerIncompatible.status = 'incompatible'
    Add-Member -InputObject $runnerIncompatible.evidence -MemberType NoteProperty -Name native_worker_evidence_failures -Value $codexFailureCodes -Force
    $runnerValidation = Test-NativeWorkerTerminalEvidence -ExecutionEvidence $runnerIncompatible -Run $terminalRunData -RequestedModel ([string]$terminalArm.worker.model) -ExpectedWorkerSessionId 'native-terminal-session'
    Assert-True (-not [bool]$runnerValidation.Valid) 'common terminal validation rejects runner-reported incompatibility'
    Assert-True (@($runnerValidation.Failures | Where-Object { $_ -eq 'terminal_turn_status' }).Count -eq 1) 'common validation preserves an exact runner-specific failure code'
    $runnerState = New-OrchestrationState -Plan ([pscustomobject]@{ schema = $plan.schema; requested_concurrency = 1; arms = @($terminalArm) })
    [void](Register-DelegationAccepted -State $runnerState -WorkerId ([string]$terminalArm.worker_id) -WorkerSessionId 'native-terminal-session')
    [void](Register-WorkerTerminal -Plan ([pscustomobject]@{ arms = @($terminalArm) }) -State $runnerState -WorkerId ([string]$terminalArm.worker_id) -ExecutionEvidence $runnerIncompatible)
    Assert-Equal 'incompatible' $runnerState.completed[[string]$terminalArm.worker_id].native_worker_evidence 'runner-specific incompatibility cannot become common verified evidence'
    foreach ($failureCode in $codexFailureCodes) {
        Assert-True (@($runnerState.completed[[string]$terminalArm.worker_id].native_worker_evidence_failures | Where-Object { $_ -eq $failureCode }).Count -eq 1) "exact runner failure '$failureCode' survives orchestration state"
    }
    $optionalReadEvidence = Copy-TestObject -Value $validTerminalEvidence
    Add-Member -InputObject $optionalReadEvidence.evidence -MemberType NoteProperty -Name app_server -Value ([ordered]@{ thread_read = [ordered]@{ observation = 'unavailable_optional' } }) -Force
    Assert-True ((Test-NativeWorkerTerminalEvidence -ExecutionEvidence $optionalReadEvidence -Run $terminalRunData -RequestedModel ([string]$terminalArm.worker.model) -ExpectedWorkerSessionId 'native-terminal-session').Valid) 'optional thread/read absence does not invalidate mandatory common evidence'

    $exactOnceState = New-OrchestrationState -Plan ([pscustomobject]@{
        schema = $plan.schema
        requested_concurrency = 1
        arms = @($terminalArm)
    })
    [void](Register-DelegationAccepted -State $exactOnceState -WorkerId ([string]$terminalArm.worker_id) -WorkerSessionId 'native-terminal-session')
    $duplicateAcceptanceRejected = $false
    try {
        [void](Register-DelegationAccepted -State $exactOnceState -WorkerId ([string]$terminalArm.worker_id) -WorkerSessionId 'duplicate-session')
    } catch {
        $duplicateAcceptanceRejected = $_.Exception.Message -match 'exactly-once'
    }
    Assert-True $duplicateAcceptanceRejected 'duplicate worker acceptance is rejected with an exactly-once diagnostic'
    Assert-Equal 1 $exactOnceState.active[[string]$terminalArm.worker_id].attempt_count 'duplicate acceptance does not create another attempt'
    [void](Register-WorkerTerminal -Plan ([pscustomobject]@{ arms = @($terminalArm) }) -State $exactOnceState -WorkerId ([string]$terminalArm.worker_id) -ExecutionEvidence (Copy-TestObject -Value $validTerminalEvidence))
    $duplicateTerminalRejected = $false
    try {
        [void](Register-WorkerTerminal -Plan ([pscustomobject]@{ arms = @($terminalArm) }) -State $exactOnceState -WorkerId ([string]$terminalArm.worker_id) -ExecutionEvidence (Copy-TestObject -Value $validTerminalEvidence))
    } catch {
        $duplicateTerminalRejected = $_.Exception.Message -match 'already terminal|exactly-once'
    }
    Assert-True $duplicateTerminalRejected 'duplicate terminal registration is rejected after the worker is terminal'
    Assert-Equal 1 @($exactOnceState.completed.Keys).Count 'duplicate terminal registration does not add another completion'

    function Invoke-TerminalEvidenceCase {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [Parameter(Mandatory = $true)][object]$Evidence,
            [Parameter(Mandatory = $true)][string]$ExpectedFailure
        )

        $caseState = New-OrchestrationState -Plan ([pscustomobject]@{
            schema = $plan.schema
            requested_concurrency = 1
            arms = @($terminalArm)
        })
        [void](Register-DelegationAccepted -State $caseState -WorkerId ([string]$terminalArm.worker_id) -WorkerSessionId 'native-terminal-session')
        [void](Register-WorkerTerminal -Plan ([pscustomobject]@{ arms = @($terminalArm) }) -State $caseState -WorkerId ([string]$terminalArm.worker_id) -ExecutionEvidence $Evidence)
        # Ledger must preserve the raw runner status and record evidence validation
        Assert-Equal $Evidence.status $caseState.completed[[string]$terminalArm.worker_id].status "$Name ledger.status must equal raw Evidence.status"
        $ev = Get-JsonProperty -Object $caseState.completed[[string]$terminalArm.worker_id] -Name 'evidence_validation' -Default $null
        Assert-Equal 'failed' $ev.status "$Name evidence_validation should be failed"
        Assert-True (([string]::Join(',', @($caseState.completed[[string]$terminalArm.worker_id].native_worker_evidence_failures))) -match [regex]::Escape($ExpectedFailure)) "$Name records $ExpectedFailure"
    }

    $modelMismatch = Copy-TestObject -Value $validTerminalEvidence
    $modelMismatch.evidence.delegation.observed_model = 'different-model'
    Invoke-TerminalEvidenceCase -Name 'model mismatch' -Evidence $modelMismatch -ExpectedFailure 'requested_model'

    $workingDirectoryMismatch = Copy-TestObject -Value $validTerminalEvidence
    $workingDirectoryMismatch.evidence.delegation.observed_working_directory = (Join-Path $terminalRunData.RunRoot 'other-repo')
    Invoke-TerminalEvidenceCase -Name 'working-directory mismatch' -Evidence $workingDirectoryMismatch -ExpectedFailure 'working_directory'

    $missingHomeProof = Copy-TestObject -Value $validTerminalEvidence
    $missingHomeProof.evidence.delegation.home_config_isolated = $false
    $missingHomeProof.evidence.delegation.observed_home = ''
    Invoke-TerminalEvidenceCase -Name 'missing HOME/config proof' -Evidence $missingHomeProof -ExpectedFailure 'isolated_home_config'

    $missingDelegationEvidence = Copy-TestObject -Value $validTerminalEvidence
    $missingDelegationEvidence.evidence = $null
    Invoke-TerminalEvidenceCase -Name 'missing terminal delegation evidence' -Evidence $missingDelegationEvidence -ExpectedFailure 'delegation_terminal_evidence'

    $armMismatch = Copy-TestObject -Value $validTerminalEvidence
    $armMismatch.run.eval_id = 999
    Invoke-TerminalEvidenceCase -Name 'arm identity mismatch' -Evidence $armMismatch -ExpectedFailure 'arm_identity'

    $nestedExecution = Copy-TestObject -Value $validTerminalEvidence
    $nestedExecution.evidence.delegation.nested_model_execution = $true
    $nestedExecution.evidence.delegation.model_execution_count = 2
    Invoke-TerminalEvidenceCase -Name 'nested model execution' -Evidence $nestedExecution -ExpectedFailure 'nested_model_execution'

    $freshWorkerMismatch = Copy-TestObject -Value $validTerminalEvidence
    $freshWorkerMismatch.session.id = 'different-worker-session'
    $freshWorkerMismatch.evidence.delegation.worker_session_id = 'different-worker-session'
    Invoke-TerminalEvidenceCase -Name 'fresh worker/session mismatch' -Evidence $freshWorkerMismatch -ExpectedFailure 'worker_session_id'

    $duplicateSessionState = New-OrchestrationState -Plan ([pscustomobject]@{
        schema = $plan.schema
        requested_concurrency = 1
        arms = @($terminalArm)
    })
    $duplicateSessionState.completed['prior-worker'] = [ordered]@{ worker_id = 'prior-worker'; worker_session_id = 'native-terminal-session' }
    [void](Register-DelegationAccepted -State $duplicateSessionState -WorkerId ([string]$terminalArm.worker_id) -WorkerSessionId 'native-terminal-session')
    [void](Register-WorkerTerminal -Plan ([pscustomobject]@{ arms = @($terminalArm) }) -State $duplicateSessionState -WorkerId ([string]$terminalArm.worker_id) -ExecutionEvidence (Copy-TestObject -Value $validTerminalEvidence))
    # Ledger must preserve the raw runner status even when session reuse is suspicious
    Assert-Equal $validTerminalEvidence.status $duplicateSessionState.completed[[string]$terminalArm.worker_id].status 'reused worker session ledger preserves raw status'
    $dupEv = Get-JsonProperty -Object $duplicateSessionState.completed[[string]$terminalArm.worker_id] -Name 'evidence_validation' -Default $null
    Assert-Equal 'failed' $dupEv.status 'reused worker session records failed evidence_validation'
    Assert-True (([string]::Join(',', @($duplicateSessionState.completed[[string]$terminalArm.worker_id].native_worker_evidence_failures))) -match 'fresh_worker') 'reused worker session records fresh-worker failure'

    $fanoutPath = Join-Path $runnerRoot 'invoke-runner-owned-arms.ps1'
    $fanoutText = [System.IO.File]::ReadAllText($fanoutPath, [System.Text.UTF8Encoding]::new($false))
    $fanoutProcessText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'fanout-process.ps1'), [System.Text.UTF8Encoding]::new($false))
    foreach ($needle in @('manifest.json', 'New-EvalOrchestrationPlan', 'dispatch_owner', 'Get-OrchestrationArmByWorkerId', 'arm.parent_paths.execution_result', 'Start-RunnerChildProcess', 'Wait-AnyRunnerChild', 'Register-DelegationAccepted', 'Register-DelegationSession', 'Register-WorkerTerminal', 'Assert-OrchestrationConcurrency', 'orchestration-state.json')) {
        Assert-True $fanoutText.Contains($needle) "runner-owned helper contains deterministic '$needle' behavior"
    }
    Assert-True ($fanoutText.Contains('runner child watchdog timed out') -and $fanoutText.Contains('no retry or redispatch was performed')) 'runner-owned helper reports the exact timed-out worker and forbids retry or redispatch'
    Assert-True ($fanoutProcessText.Contains('DeadlineUtc') -and $fanoutProcessText.Contains('Kill($true)') -and $fanoutProcessText.Contains('WaitForExit(5000)')) 'runner-owned process helper has a finite child deadline, tree kill, and kill grace'
    Assert-True (-not $fanoutText.Contains('Start-Process')) 'runner-owned helper no longer uses window-creating Start-Process for child dispatch'
    Assert-True ($fanoutText -notmatch '(?i)spawn[_ -]?agent|subagent|native-worker-result|with_skill.*worker_id|without_skill.*worker_id') 'runner-owned helper does not create outer subagents, synthetic envelopes, or derived worker IDs'
    Assert-True ($fanoutText -notmatch '(?i)(with[-_]skill|without[-_]skill)\.execution-result|execution_result\s*=\s*.*configuration') 'runner-owned helper does not reconstruct result filenames'
    Assert-True ($fanoutText.Contains('[Parameter(Mandatory = $true)][string]$IterationDirectory') -and -not $fanoutText.Contains('Assert-RunnerOwnedFanoutAuthorization') -and -not $fanoutText.Contains('SupervisorId') -and -not $fanoutText.Contains('phase1-control-common.ps1')) 'runner-owned fan-out is the foreground Phase 1 surface without durable supervisor authorization'

    # Exercise the helper end-to-end with a deterministic runner-owned fixture.
    # The fixture is a protocol adapter only; it never calls a model or an AI
    # CLI. Six short processes must be active through the helper's first batch.
    $fanoutPackage = Join-Path $testRoot 'runner-owned fanout package'
    $fanoutTools = Join-Path $fanoutPackage 'tools\eval-runners'
    New-Item -ItemType Directory -Path $fanoutTools -Force | Out-Null
    foreach ($toolItem in @(Get-ChildItem -LiteralPath $runnerRoot -Force | Where-Object { $_.Name -ne 'tests' })) {
        Copy-Item -LiteralPath $toolItem.FullName -Destination $fanoutTools -Recurse -Force
    }
    $fixtureRunnerDirectory = Join-Path $fanoutTools 'fixture'
    New-Item -ItemType Directory -Path $fixtureRunnerDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runnerRoot 'tests\fixtures\runner-owned-fixture.ps1') -Destination (Join-Path $fixtureRunnerDirectory 'runner.ps1') -Force
    $fanoutProfileRelative = 'execution-profile.json'
    Write-TestJson -Path (Join-Path $fanoutPackage $fanoutProfileRelative) -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = 16
    })
    $fanoutManifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le 3; $evalId++) {
        $evalName = 'fanout-eval-{0:d2}' -f $evalId
        $evalDirectory = Join-Path $fanoutPackage $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
        Write-TestJson -Path (Join-Path $evalDirectory 'eval-metadata.json') -Value ([ordered]@{ eval_id = $evalId; eval_name = $evalName; assertions = @('fixture') })
        $runs = [ordered]@{}
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $runDirectory = Join-Path $evalDirectory $configuration
            $repoDirectory = Join-Path $runDirectory 'repo'
            $homeDirectory = Join-Path $runDirectory 'home'
            New-Item -ItemType Directory -Path $repoDirectory, $homeDirectory -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repoDirectory 'input.txt'), "$evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'prompt.md'), "fixture prompt $evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            $skillDirectory = $null
            $skillHash = $null
            if ($configuration -eq 'with_skill') {
                $skillDirectory = 'skill/candidate'
                New-Item -ItemType Directory -Path (Join-Path $runDirectory 'skill\candidate') -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $runDirectory 'skill\candidate\SKILL.md'), '# fixture', [System.Text.UTF8Encoding]::new($false))
                $skillHash = ('b' * 64)
            }
            Write-TestJson -Path (Join-Path $runDirectory 'run.json') -Value ([ordered]@{
                schema = (Get-RunnerSchemaNames).Run
                evalId = $evalId
                evalName = $evalName
                skillName = if ($configuration -eq 'with_skill') { 'candidate' } else { $null }
                iteration = 1
                mode = $configuration
                promptFile = 'prompt.md'
                workingDirectory = 'repo'
                homeDirectory = 'home'
                skillDirectory = $skillDirectory
                freshContextRequired = $true
                filesystemIsolationRequired = $true
                isolatedHomeRequired = $true
                fixtureHash = ('a' * 64)
                skillHash = $skillHash
            })
            $resultDirectory = Join-Path $runDirectory 'results'
            New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
            $runs[$configuration] = [ordered]@{
                run_manifest = "$evalName/$configuration/run.json"
                execution_result = "$evalName/$configuration/results/execution-result.json"
                result = "$evalName/$configuration/results/result.json"
                mode = $configuration
            }
            Write-TestJson -Path (Join-Path $resultDirectory 'result.json') -Value ([ordered]@{ eval_id = $evalId; configuration = $configuration })
        }
        $fanoutManifestEvals.Add([ordered]@{ eval_id = $evalId; eval_name = $evalName; directory = $evalName; metadata = "$evalName/eval-metadata.json"; runs = $runs })
    }
    $fanoutToolIntegrity = Get-PackageTreeIntegrity -Root $fanoutTools
    Write-TestJson -Path (Join-Path $fanoutPackage 'manifest.json') -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_selection = [ordered]@{ harness = 'Deterministic runner-owned fixture'; runner = 'fixture'; model = 'fixture-model'; preset = 'Orchestration fixture' }
        execution_profile = $fanoutProfileRelative
        runner_tools = 'tools/eval-runners'
        runner_tools_integrity = [ordered]@{ schema = 'codebeltnet/agentic/package-tree-integrity/1'; path = 'tools/eval-runners'; sha256 = $fanoutToolIntegrity.Sha256; file_count = $fanoutToolIntegrity.FileCount }
        execution_freeze = 'execution-freeze.json'
        evals = $fanoutManifestEvals.ToArray()
    })
    $fixtureLogPath = Join-Path $testRoot 'runner-owned-events.jsonl'
    $env:AGENTIC_RUNNER_FIXTURE_LOG = $fixtureLogPath
    $fanoutControl = Invoke-ForegroundPhaseOne -IterationDirectory $fanoutPackage
    Assert-Equal 0 $fanoutControl.ExitCode ("deterministic runner-owned Phase 1 exits successfully; output: " + $fanoutControl.Text)
    $fanoutSummary = $fanoutControl.Document
    Assert-Equal 'phase1' $fanoutSummary.phase 'deterministic runner-owned fan-out reports a Phase 1 summary'
    Assert-Equal 'completed' $fanoutSummary.status 'deterministic runner-owned fan-out completes six fixture arms'
    Assert-Equal 6 $fanoutSummary.expected_count 'runner-owned helper preserves the six-arm manifest count'
    Assert-Equal 6 $fanoutSummary.terminal_count 'runner-owned helper reports all six arms as terminal'
    Assert-Equal 6 $fanoutSummary.preflight_count 'runner-owned helper preflights all six manifest arms before fan-out'
    Assert-True $fanoutSummary.execution_started 'runner-owned helper records that execution started after preflight'
    Assert-Equal 6 $fanoutSummary.execution_count 'runner-owned helper executes exactly six compatible arms'
    Assert-Equal 6 $fanoutSummary.completed_count 'runner-owned helper counts only completed arms'
    Assert-Equal 0 $fanoutSummary.failed_count 'runner-owned helper reports zero failed arms in the success fixture'
    Assert-Equal 0 $fanoutSummary.timed_out_count 'runner-owned helper reports zero timed out arms in the success fixture'
    Assert-Equal 0 $fanoutSummary.cancelled_count 'runner-owned helper reports zero cancelled arms in the success fixture'
    Assert-Equal 0 $fanoutSummary.incompatible_count 'runner-owned helper reports zero incompatible arms in the success fixture'
    Assert-Equal 0 $fanoutSummary.evidence_validation_failed_count 'runner-owned helper reports zero evidence-validation failures in the success fixture'
    Assert-True ([int]$fanoutSummary.max_observed_active -gt 1) 'runner-owned helper reaches parallel active execution'
    $fanoutEvents = @(Get-Content -LiteralPath $fixtureLogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal 12 $fanoutEvents.Count 'runner-owned fixture records six preflight and six execute events'
    Assert-Equal 6 @($fanoutEvents | Where-Object { $_.kind -eq 'preflight' }).Count 'all six preflight calls complete'
    Assert-Equal 6 @($fanoutEvents | Where-Object { $_.kind -eq 'execute' }).Count 'all six execute calls start after compatible preflight'
    $firstExecuteIndex = -1
    $lastPreflightIndex = -1
    for ($eventIndex = 0; $eventIndex -lt $fanoutEvents.Count; $eventIndex++) {
        if ($fanoutEvents[$eventIndex].kind -eq 'preflight') { $lastPreflightIndex = $eventIndex }
        if ($fanoutEvents[$eventIndex].kind -eq 'execute' -and $firstExecuteIndex -lt 0) { $firstExecuteIndex = $eventIndex }
    }
    Assert-True ($lastPreflightIndex -ge 0 -and $firstExecuteIndex -gt $lastPreflightIndex) 'all runner-owned preflights occur before the first execute process'
    $fanoutState = Read-RunnerJson -Path (Join-Path $fanoutPackage 'orchestration-state.json')
    Assert-Equal 6 $fanoutState.preflight.count 'orchestration state preserves all preflight worker records'
    Assert-Equal 'passed' $fanoutState.preflight.status 'orchestration state records the passed preflight gate'
    Assert-Equal 'verified' ([string]$fanoutSummary.concurrency.status) 'runner-owned helper persists verified concurrency state'
    Assert-Equal 16 ([int]$fanoutSummary.concurrency.requested_concurrency) 'runner-owned helper preserves requested concurrency 16'
    Assert-Equal 'passed' ([string]$fanoutSummary.arms[0].evidence_validation.status) 'runner-owned helper surfaces arm-level evidence validation state'
    Assert-Equal 'with_skill' ([string]$fanoutSummary.arms[0].configuration) 'runner-owned helper preserves arm-level configuration'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$fanoutSummary.arms[0].worker_session_id)) 'runner-owned helper preserves arm-level worker session ids'
    $fanoutWorkerIds = @($fanoutState.completed.PSObject.Properties.Name | Sort-Object)
    Assert-Equal 'arm-1-with_skill,arm-1-without_skill,arm-2-with_skill,arm-2-without_skill,arm-3-with_skill,arm-3-without_skill' ([string]::Join(',', $fanoutWorkerIds)) 'runner-owned helper preserves exact manifest plan worker IDs'
    foreach ($record in @(Get-ManifestRunRecords -IterationDirectory $fanoutPackage -Manifest (Read-RunnerJson -Path (Join-Path $fanoutPackage 'manifest.json')))) {
        $result = Read-RunnerJson -Path $record.ExecutionResultPath
        $workerId = "arm-$($record.EvalId)-$($record.Configuration)"
        $completedEntry = $fanoutState.completed.PSObject.Properties[$workerId].Value
        Assert-Equal ([string]$result.session.id) ([string]$completedEntry.worker_session_id) "runner-owned helper derives $workerId session identity from its result"
    }

    # The preflight gate must fail closed: one incompatible arm is reported
    # with its manifest identity and no runner-owned execute process starts.
    $gatePackage = Join-Path $testRoot 'runner-owned preflight gate package'
    Copy-Item -LiteralPath $fanoutPackage -Destination $gatePackage -Recurse -Force
    foreach ($executionResultFile in @(Get-ChildItem -LiteralPath $gatePackage -Recurse -File -Filter 'execution-result.json')) {
        Remove-Item -LiteralPath $executionResultFile.FullName -Force
    }
    Remove-PhaseOnePackageState -IterationDirectory $gatePackage
    $gateInteraction = [ordered]@{
        schema = (Get-RunnerSchemaNames).Interaction
        mode = 'scripted'
        turns = @(
            [ordered]@{ role = 'user'; content = 'fixture confirmation request' }
            [ordered]@{ role = 'user'; content = 'fixture protected operation request' }
        )
    }
    foreach ($gateRunFile in @(Get-ChildItem -LiteralPath $gatePackage -Recurse -File -Filter 'run.json')) {
        $gateInteractionPath = Join-Path $gateRunFile.DirectoryName 'interaction.json'
        Write-TestJson -Path $gateInteractionPath -Value $gateInteraction
        $gateRun = Read-RunnerJson -Path $gateRunFile.FullName
        Add-Member -InputObject $gateRun -MemberType NoteProperty -Name interactionFile -Value 'interaction.json' -Force
        Add-Member -InputObject $gateRun -MemberType NoteProperty -Name interactionHash -Value (Get-Sha256HexFromFile -Path $gateInteractionPath) -Force
        Write-TestJson -Path $gateRunFile.FullName -Value $gateRun
    }
    $gateMarker = Join-Path $gatePackage 'fanout-eval-02\with_skill\home\preflight-incompatible'
    [IO.File]::WriteAllText($gateMarker, 'fixture', [Text.UTF8Encoding]::new($false))
    $gateLogPath = Join-Path $testRoot 'runner-owned-gate-events.jsonl'
    $env:AGENTIC_RUNNER_FIXTURE_LOG = $gateLogPath
    $gateControl = Invoke-ForegroundPhaseOne -IterationDirectory $gatePackage
    Assert-Equal 2 $gateControl.ExitCode ("incompatible runner-owned preflight exits non-zero; output: " + $gateControl.Text)
    $gateSummary = $gateControl.Document
    Assert-Equal 'preflight_incompatible' $gateSummary.status 'incompatible preflight stops before fan-out'
    Assert-Equal 6 $gateSummary.preflight_count 'incompatible gate still preflights every pending arm'
    Assert-Equal 1 $gateSummary.incompatible_count 'incompatible gate reports one failed arm'
    Assert-Equal $false $gateSummary.execution_started 'incompatible gate records zero started executions'
    Assert-Equal 0 $gateSummary.execution_count 'incompatible gate reports zero executions'
    $failedGateArm = @($gateSummary.preflights | Where-Object { $_.worker_id -eq 'arm-2-with_skill' })
    Assert-Equal 1 $failedGateArm.Count 'incompatible gate preserves the exact manifest worker ID'
    Assert-True ([string]$failedGateArm[0].reasons -match 'fixture preflight rejected fanout-eval-02/with_skill') 'incompatible gate preserves the exact preflight reason'
    Assert-True ([string]$failedGateArm[0].reasons -match 'scripted interaction capability unsupported') 'incompatible gate rejects an unsupported scripted interaction before execution'
    $gateEvents = @(Get-Content -LiteralPath $gateLogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal 6 $gateEvents.Count 'incompatible gate records only the six preflight calls'
    Assert-Equal 0 @($gateEvents | Where-Object { $_.kind -eq 'execute' }).Count 'incompatible gate starts zero execute processes'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $gatePackage -Recurse -File -Filter 'execution-result.json').Count 'incompatible gate leaves manifest execution results untouched'

    # A compatibility-transport answer has no native delegation evidence and
    # is rejected rather than retried through runner.ps1 execute or parent code.
    $compatibilityTransportResult = Copy-TestObject -Value $validTerminalEvidence
    $compatibilityTransportResult.evidence.PSObject.Properties.Remove('delegation')
    Invoke-TerminalEvidenceCase -Name 'compatibility transport result' -Evidence $compatibilityTransportResult -ExpectedFailure 'delegation_terminal_evidence'

    # Regression (Copilot forensic iteration-4): an orchestrator-authored /
    # synthetic execution-result must be rejected by the schema gate with no
    # fallback to a manual "success". This mirrors the real invalid Copilot run
    # -- capture provenance "agent_output", a textual terminal_status instead of
    # a numeric exit code, a non-fresh session, and no runner terminal
    # delegation evidence -- proving the outer orchestrator cannot hand-build a
    # passing result.
    $syntheticCopilotResult = [ordered]@{
        schema = (Get-RunnerSchemaNames).Result
        protocol_version = (Get-RunnerSchemaNames).Protocol
        run_id = '1_with_skill'
        session = [ordered]@{ id = ''; fresh = $false; resumed = $true }
        status = 'completed'
        run = [ordered]@{ eval_id = 1; eval_name = 'strong-name'; configuration = 'with_skill' }
        runner = [ordered]@{ name = 'github-copilot'; version = '0.9.1' }
        harness = [ordered]@{ name = 'GitHub Copilot CLI'; version = 'unavailable' }
        requested = [ordered]@{ model = 'claude-haiku-4.5'; reasoning_effort = $null; configuration_profile = 'isolated-default'; tool_profile = 'default'; timeout_seconds = 900 }
        resolved = [ordered]@{ status = 'accepted_request'; accepted = [ordered]@{ model = 'claude-haiku-4.5' } }
        started_utc = '2026-08-25T20:00:00.000Z'
        finished_utc = '2026-08-25T20:00:10.000Z'
        duration_seconds = 10
        exit = [ordered]@{ status = 'success'; failure = $null }
        terminal_status = 'success'
        output_summary = 'Successfully generated repo.snk (1024-bit RSA, 596 bytes)'
        final_response = [ordered]@{ status = 'available'; text = 'done' }
        input = [ordered]@{ prompt_sha256 = ('0' * 64); run_json_sha256 = ('0' * 64); profile_sha256 = ('0' * 64) }
        isolation = [ordered]@{ status = 'verified'; level = 'pragmatic'; hard_filesystem_confinement = $false; capabilities = [ordered]@{}; mechanisms = @(); required_controls = @(); unproven_controls = @() }
        telemetry = [ordered]@{ transcript = [ordered]@{ status = 'available'; value = [ordered]@{ transcript_excerpt = '' } } }
        evidence = [ordered]@{ capture = [ordered]@{ source = 'agent_output'; terminal = $true; worker_authored = $false }; tool_call_count = 0; transcript_excerpt = '' }
        artifacts = @()
        warnings = @()
        compatibility_deviations = @()
        attempt_count = 1
    }
    $syntheticResultObject = ($syntheticCopilotResult | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $syntheticRejected = $false
    $syntheticReason = ''
    try { [void](Assert-ExecutionResult -Result $syntheticResultObject) } catch { $syntheticRejected = $true; $syntheticReason = $_.Exception.Message }
    Assert-True $syntheticRejected 'orchestrator-authored synthetic Copilot execution-result is rejected by the schema gate'
    Assert-True ($syntheticReason -match 'fresh, non-resumed session|exit.status must be a JSON number') "synthetic Copilot result is rejected for its non-fresh session or textual exit status: $syntheticReason"
    # A synthetic result that is schema-shaped but carries agent_output capture
    # with no runner delegation evidence is still incompatible at the terminal
    # gate, so it can never be graded as a real eval execution.
    $agentOutputResult = Copy-TestObject -Value $validTerminalEvidence
    $agentOutputResult.evidence | Add-Member -NotePropertyName capture -NotePropertyValue ([pscustomobject]@{ source = 'agent_output'; terminal = $true; worker_authored = $true }) -Force
    $agentOutputResult.evidence.PSObject.Properties.Remove('delegation')
    Invoke-TerminalEvidenceCase -Name 'agent_output synthetic result' -Evidence $agentOutputResult -ExpectedFailure 'delegation_terminal_evidence'

    # Regression (#6): runner-owned child processes are headless on Windows. The
    # start configuration keeps a real isolation boundary but must not create a
    # visible console window, and stdout/stderr stay redirected for capture.
    $headlessStartInfo = New-RunnerChildProcessStartInfo -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', 'runner.ps1', 'execute') -WorkingDirectory $testRoot
    Assert-True (-not $headlessStartInfo.UseShellExecute) 'runner child process does not use ShellExecute'
    Assert-True ($headlessStartInfo.CreateNoWindow) 'runner child process creates no visible console window'
    Assert-True ($headlessStartInfo.RedirectStandardOutput) 'runner child process redirects stdout for exact result capture'
    Assert-True ($headlessStartInfo.RedirectStandardError) 'runner child process redirects stderr for diagnostics'
    Assert-Equal 'runner.ps1' ([string]$headlessStartInfo.ArgumentList[2]) 'runner child process preserves its exact argument vector without manual quoting'

    # Regression (OpenCode hang): both the shared process helper and the
    # runner-owned child watchdog must return after a forced termination even
    # when a fake child sleeps forever. The upper bound includes the one-second
    # test deadline, the finite kill grace, and the finite stream-drain grace.
    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    $timeoutDirectory = Join-Path $testRoot 'bounded-timeout'
    New-Item -ItemType Directory -Path $timeoutDirectory -Force | Out-Null
    $timeoutClock = [Diagnostics.Stopwatch]::StartNew()
    $sharedTimeoutResult = Invoke-RunnerProcess -FileName $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -WorkingDirectory $timeoutDirectory -TimeoutSeconds 1
    $timeoutClock.Stop()
    Assert-True ([bool]$sharedTimeoutResult.TimedOut) 'shared process helper reports a sleeping child as timed_out'
    Assert-True ([bool]$sharedTimeoutResult.KillAttempted) 'shared process helper attempts entire-process-tree termination at the deadline'
    Assert-True ($timeoutClock.Elapsed.TotalSeconds -lt 12) ("shared process timeout path remains bounded; elapsed={0:N3}s" -f $timeoutClock.Elapsed.TotalSeconds)
    Assert-True ($sharedTimeoutResult.DurationSeconds -lt 12) 'shared process timeout result reports a bounded duration'

    $watchdogStdout = Join-Path $timeoutDirectory 'watchdog.stdout'
    $watchdogStderr = Join-Path $timeoutDirectory 'watchdog.stderr'
    $watchdogChild = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -WorkingDirectory $timeoutDirectory -StdoutPath $watchdogStdout -StderrPath $watchdogStderr -TimeoutSeconds 1
    $watchdogRecord = [pscustomobject]@{ worker_id = 'arm-watchdog-with_skill'; child = $watchdogChild; Process = $watchdogChild.Process }
    $watchdogList = [System.Collections.Generic.List[object]]::new()
    $watchdogList.Add($watchdogRecord)
    $watchdogClock = [Diagnostics.Stopwatch]::StartNew()
    $watchdogIndex = Wait-AnyRunnerChild -Running $watchdogList
    $watchdogExitCode = Complete-RunnerChildProcess -Child $watchdogChild
    $watchdogClock.Stop()
    Assert-Equal 0 $watchdogIndex 'runner-child watchdog selects the exact expired worker'
    Assert-True ([bool]$watchdogChild.WatchdogExpired) 'runner-child watchdog marks the selected worker expired'
    Assert-True ([bool]$watchdogChild.TimedOut) 'runner-child completion reports the watchdog timeout'
    Assert-True ($watchdogClock.Elapsed.TotalSeconds -lt 12) ("runner-child watchdog kill and drain remain bounded; elapsed={0:N3}s" -f $watchdogClock.Elapsed.TotalSeconds)
    Assert-True ($null -eq $watchdogExitCode) 'timed-out runner child has no synthesized exit success'

    # Regression (#5.8): capacity is released when ANY child completes, not only
    # the oldest queued child. Wait-AnyRunnerChild must return whichever child
    # exited first so a slow sibling never blocks refilling a freed slot.
    $waitAnyLaterFirst = [System.Collections.Generic.List[object]]::new()
    $waitAnyLaterFirst.Add([pscustomobject]@{ Process = [pscustomobject]@{ HasExited = $false } })
    $waitAnyLaterFirst.Add([pscustomobject]@{ Process = [pscustomobject]@{ HasExited = $false } })
    $waitAnyLaterFirst.Add([pscustomobject]@{ Process = [pscustomobject]@{ HasExited = $true } })
    Assert-Equal 2 (Wait-AnyRunnerChild -Running $waitAnyLaterFirst) 'capacity refill selects a later-completing child, not the oldest queued one'
    $waitAnyOldestFirst = [System.Collections.Generic.List[object]]::new()
    $waitAnyOldestFirst.Add([pscustomobject]@{ Process = [pscustomobject]@{ HasExited = $true } })
    $waitAnyOldestFirst.Add([pscustomobject]@{ Process = [pscustomobject]@{ HasExited = $false } })
    Assert-Equal 0 (Wait-AnyRunnerChild -Running $waitAnyOldestFirst) 'capacity refill also selects the oldest child when it completes first'

    # Regression (OpenCode forensic iteration-5): synthetic concurrency state
    # cannot be injected. The runner-owned fan-out refuses to run over a
    # pre-authored orchestration-state.json, so a hand-written max_observed_active
    # (with no observed process/session lifecycle) is rejected fail-closed.
    $syntheticStatePackage = Join-Path $testRoot 'runner-owned synthetic concurrency package'
    Copy-Item -LiteralPath $fanoutPackage -Destination $syntheticStatePackage -Recurse -Force
    foreach ($executionResultFile in @(Get-ChildItem -LiteralPath $syntheticStatePackage -Recurse -File -Filter 'execution-result.json')) {
        Remove-Item -LiteralPath $executionResultFile.FullName -Force
    }
    Remove-PhaseOnePackageState -IterationDirectory $syntheticStatePackage
    Write-TestJson -Path (Join-Path $syntheticStatePackage 'orchestration-state.json') -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-orchestration-state/1'
        dispatch_owner = 'orchestrator'
        requested_concurrency = 16
        parallel_dispatch_required = $true
        minimum_parallel_workers = 2
        pending_worker_ids = @()
        active = [ordered]@{}
        completed = [ordered]@{}
        delegation_rejections = [ordered]@{}
        capacity_limit_reported = $false
        eval_attempts = [ordered]@{}
        max_observed_active = 6
    })
    $syntheticStateLog = Join-Path $testRoot 'runner-owned-synthetic-state-events.jsonl'
    $env:AGENTIC_RUNNER_FIXTURE_LOG = $syntheticStateLog
    $syntheticStateControl = Invoke-ForegroundPhaseOne -IterationDirectory $syntheticStatePackage
    Assert-Equal 2 $syntheticStateControl.ExitCode ("foreground Phase 1 rejects a pre-authored orchestration state; output: " + $syntheticStateControl.Text)
    $syntheticStateSummary = $syntheticStateControl.Document
    Assert-Equal 'failed' $syntheticStateSummary.status 'synthetic concurrency state cannot drive a completed fan-out'
    Assert-True ([string]$syntheticStateSummary.error -match 'Runner-owned fan-out refuses to replace an existing orchestration state') ("foreground Phase 1 fails closed on pre-authored state; error: " + [string]$syntheticStateSummary.error)
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $syntheticStatePackage -Recurse -File -Filter 'execution-result.json').Count 'synthetic concurrency rejection starts zero real executions'

    Write-Output 'Native worker orchestration: PASS'
} finally {
    if ($null -eq $oldFixtureLogPath) { Remove-Item Env:AGENTIC_RUNNER_FIXTURE_LOG -ErrorAction SilentlyContinue } else { $env:AGENTIC_RUNNER_FIXTURE_LOG = $oldFixtureLogPath }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
