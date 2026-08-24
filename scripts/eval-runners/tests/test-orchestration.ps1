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
            [void](Register-DelegationRejected -State $capacityState -WorkerId $dispatch.worker_id -Reason 'fake harness capacity is four')
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
                [void](Register-DelegationRejected -State $capacityState -WorkerId $dispatch.worker_id -Reason 'fake harness capacity is four')
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
        delegation = [ordered]@{ mode = 'native_worker'; nested_model_execution = $false }
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
        Assert-Equal 'incompatible' $Evidence.status "$Name changes the arm to incompatible"
        Assert-Equal 'incompatible' $caseState.completed[[string]$terminalArm.worker_id].status "$Name is terminally incompatible"
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
    Assert-Equal 'incompatible' $duplicateSessionState.completed[[string]$terminalArm.worker_id].status 'reused worker session makes the arm incompatible'
    Assert-True (([string]::Join(',', @($duplicateSessionState.completed[[string]$terminalArm.worker_id].native_worker_evidence_failures))) -match 'fresh_worker') 'reused worker session records fresh-worker failure'

    # A compatibility-transport answer has no native delegation evidence and
    # is rejected rather than retried through runner.ps1 execute or parent code.
    $compatibilityTransportResult = Copy-TestObject -Value $validTerminalEvidence
    $compatibilityTransportResult.evidence.PSObject.Properties.Remove('delegation')
    Invoke-TerminalEvidenceCase -Name 'compatibility transport result' -Evidence $compatibilityTransportResult -ExpectedFailure 'delegation_terminal_evidence'

    Write-Output 'Native worker orchestration: PASS'
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
