Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'runner-common.ps1')
. (Join-Path $PSScriptRoot 'manifest-paths.ps1')

function Get-OrchestrationProfileValue {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    if ($Profile -is [System.Collections.IDictionary] -and $Profile.Contains($Name)) {
        return $Profile[$Name]
    }
    if ($Profile.PSObject.Properties.Name -contains $Name) {
        return $Profile.$Name
    }
    return $Default
}

function New-EvalOrchestrationPlan {
    <#
      Deterministic parent-side planning only. This function never starts a
      harness process, calls a model, reads grading material, or exposes a
      paired arm to a worker envelope.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$Profile,
        [object]$Descriptor = $null
    )

    $records = @(Get-ManifestRunRecords -IterationDirectory $IterationDirectory -Manifest $Manifest)
    $requestedConcurrency = [int](Get-OrchestrationProfileValue -Profile $Profile -Name 'concurrency' -Default 0)
    if ($requestedConcurrency -lt 1) {
        throw 'execution-profile.json concurrency must be at least 1 for native worker orchestration.'
    }

    $runner = [string](Get-OrchestrationProfileValue -Profile $Profile -Name 'runner' -Default '')
    $model = [string](Get-OrchestrationProfileValue -Profile $Profile -Name 'model' -Default '')
    if ([string]::IsNullOrWhiteSpace($runner) -or [string]::IsNullOrWhiteSpace($model)) {
        throw 'Native worker orchestration requires a selected runner and model.'
    }

    # Older deterministic callers can omit the descriptor and retain the
    # original orchestrator-owned contract. Package handoffs always provide
    # the selected descriptor so the native dispatch owner is explicit.
    $dispatchOwner = 'orchestrator'
    $dispatchMechanism = ''
    if ($null -ne $Descriptor) {
        $dispatchOwner = [string](Get-JsonProperty -Object (Get-JsonProperty -Object $Descriptor -Name 'delegation' -Default $null) -Name 'dispatch_owner' -Default '')
        $dispatchMechanism = [string](Get-JsonProperty -Object (Get-JsonProperty -Object $Descriptor -Name 'delegation' -Default $null) -Name 'mechanism' -Default '')
    }
    if ($dispatchOwner -notin @('orchestrator', 'runner')) {
        throw "Native worker orchestration dispatch_owner '$dispatchOwner' is unsupported."
    }

    $arms = [System.Collections.Generic.List[object]]::new()
    $seenWorkers = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $records) {
        $workerId = ('arm-{0}-{1}' -f $record.EvalId, $record.Configuration)
        if (-not $seenWorkers.Add($workerId)) {
            throw "Manifest produced duplicate native worker id '$workerId'."
        }

        # The parent retains the exact manifest-declared destinations. They are
        # deliberately kept outside the worker envelope below.
        $arms.Add([ordered]@{
            worker_id = $workerId
            eval_id = $record.EvalId
            eval_name = $record.EvalName
            configuration = $record.Configuration
            dispatch_owner = $dispatchOwner
            depends_on = @()
            parent_paths = [ordered]@{
                run_manifest = $record.RunManifestRelative
                execution_result = $record.ExecutionResultRelative
                result = $record.ResultRelative
            }
            worker = [ordered]@{
                worker_id = $workerId
                eval_id = $record.EvalId
                eval_name = $record.EvalName
                configuration = $record.Configuration
                run_manifest = $record.RunManifestRelative
                run_manifest_path = $record.RunManifestPath
                model = $model
                reasoning_effort = Get-OrchestrationProfileValue -Profile $Profile -Name 'reasoning_effort'
                configuration_profile = Get-OrchestrationProfileValue -Profile $Profile -Name 'configuration_profile'
                tool_profile = Get-OrchestrationProfileValue -Profile $Profile -Name 'tool_profile'
                timeout_seconds = [int](Get-OrchestrationProfileValue -Profile $Profile -Name 'timeout_seconds' -Default 0)
                one_arm_only = $true
                paired_arm_visible = $false
                grading_material_visible = $false
                parent_executes_arm = $false
                dispatch_owner = $dispatchOwner
                dispatch_mechanism = $dispatchMechanism
                runner_execute_invocation = if ($dispatchOwner -eq 'runner') { 'required' } else { 'forbidden' }
                nested_model_execution = $false
                model_execution_count = 1
            }
        })
    }

    $schemas = Get-RunnerSchemaNames
    $parallelDispatchRequired = @($arms).Count -gt 1 -and $requestedConcurrency -gt 1
    return [ordered]@{
        schema = $schemas.OrchestrationPlan
        protocol_version = $schemas.Protocol
        runner = $runner
        model = $model
        dispatch_owner = $dispatchOwner
        requested_concurrency = $requestedConcurrency
        parallel_dispatch_required = $parallelDispatchRequired
        minimum_parallel_workers = if ($parallelDispatchRequired) { 2 } else { 1 }
        native_worker_required = $true
        parent_executes_arms = $false
        nested_model_execution = $false
        dispatch_policy = if ($dispatchOwner -eq 'runner') { 'one fresh runner-owned native worker transport per arm; independent transports must run concurrently up to requested_concurrency when capacity permits' } else { 'one fresh orchestrator-owned harness-native worker per arm; independent workers must run concurrently up to requested_concurrency when capacity permits' }
        capacity_policy = 'harness_authoritative; a rejected delegation that did not start remains queued and is not an eval attempt'
        arms = $arms.ToArray()
    }
}

function Get-OrchestrationArmByWorkerId {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$WorkerId
    )

    foreach ($arm in @($Plan.arms)) {
        if ([string]$arm.worker_id -eq $WorkerId) { return $arm }
    }
    throw "Unknown orchestration worker '$WorkerId'."
}

function New-OrchestrationState {
    param([Parameter(Mandatory = $true)][object]$Plan)

    $pending = @($Plan.arms | ForEach-Object { [string]$_.worker_id })
    return [ordered]@{
        schema = 'codebeltnet/agentic/eval-orchestration-state/1'
        plan_schema = [string]$Plan.schema
        dispatch_owner = [string](Get-JsonProperty -Object $Plan -Name 'dispatch_owner' -Default 'orchestrator')
        requested_concurrency = [int]$Plan.requested_concurrency
        parallel_dispatch_required = [bool](Get-JsonProperty -Object $Plan -Name 'parallel_dispatch_required' -Default $false)
        minimum_parallel_workers = [int](Get-JsonProperty -Object $Plan -Name 'minimum_parallel_workers' -Default 1)
        pending_worker_ids = @($pending)
        active = [ordered]@{}
        completed = [ordered]@{}
        delegation_rejections = [ordered]@{}
        capacity_limit_reported = $false
        eval_attempts = [ordered]@{}
        max_observed_active = 0
        execution_freeze = $null
    }
}

function Get-OrchestrationActiveCount {
    param([Parameter(Mandatory = $true)][object]$State)

    return @((Get-OrchestrationDictionary -Object $State -Name 'active').Keys).Count
}

function Get-OrchestrationDictionary {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-JsonProperty -Object $Object -Name $Name -Default $null
    if ($null -eq $value -or -not ($value -is [System.Collections.IDictionary])) {
        throw "Orchestration state field '$Name' must be a dictionary."
    }
    return $value
}

function Get-NextWorkerDispatches {
    <#
      Returns dispatch envelopes without consuming pending work. An external
      harness decides whether each native delegation request was accepted. That
      is what lets a harness-owned capacity limit reject a request without
      turning it into an eval attempt.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$State
    )

    $requested = [int]$Plan.requested_concurrency
    $active = Get-OrchestrationActiveCount -State $State
    $slots = [Math]::Max(0, $requested - $active)
    if ($slots -eq 0) { return @() }

    $pending = @($State.pending_worker_ids)
    $dispatches = [System.Collections.Generic.List[object]]::new()
    foreach ($workerId in $pending | Select-Object -First $slots) {
        $arm = Get-OrchestrationArmByWorkerId -Plan $Plan -WorkerId ([string]$workerId)
        $dispatches.Add((New-WorkerDispatchEnvelope -Arm $arm))
    }
    return @($dispatches)
}

function Register-DelegationAccepted {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [string]$WorkerSessionId = ''
    )

    $active = Get-OrchestrationDictionary -Object $State -Name 'active'
    $completed = Get-OrchestrationDictionary -Object $State -Name 'completed'
    if ($active.Contains($WorkerId) -or $completed.Contains($WorkerId)) {
        throw "Worker '$WorkerId' was already accepted or completed; delegation acceptance is exactly-once and must not be retried."
    }
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($State.pending_worker_ids)) { [void]$pending.Add([string]$id) }
    if (-not $pending.Contains($WorkerId)) {
        throw "Worker '$WorkerId' cannot be accepted because it is not pending; preserve the orchestration state and do not register a second attempt."
    }

    [void]$pending.Remove($WorkerId)
    $State.pending_worker_ids = @($pending)
    $attempts = Get-OrchestrationDictionary -Object $State -Name 'eval_attempts'
    $attempts[$WorkerId] = 1
    $active[$WorkerId] = [ordered]@{
        worker_id = $WorkerId
        worker_session_id = if ([string]::IsNullOrWhiteSpace($WorkerSessionId)) { $null } else { $WorkerSessionId }
        accepted_utc = [DateTime]::UtcNow.ToString('o')
        attempt_count = 1
    }
    $activeCount = Get-OrchestrationActiveCount -State $State
    if ($activeCount -gt [int]$State.max_observed_active) { $State.max_observed_active = $activeCount }
    return $true
}

function Register-DelegationRejected {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [Parameter(Mandatory = $true)][string]$Reason,
        [switch]$CapacityLimited
    )

    $pending = @($State.pending_worker_ids)
    if ($pending -notcontains $WorkerId) {
        throw "Delegation rejection for '$WorkerId' is invalid because the arm is not pending."
    }
    $rejections = Get-OrchestrationDictionary -Object $State -Name 'delegation_rejections'
    $count = if ($rejections.Contains($WorkerId)) { [int]$rejections[$WorkerId].count } else { 0 }
    $rejections[$WorkerId] = [ordered]@{
        count = $count + 1
        last_reason = $Reason
        last_rejected_utc = [DateTime]::UtcNow.ToString('o')
        capacity_limited = [bool]$CapacityLimited
        eval_attempt_started = $false
    }
    if ($CapacityLimited) {
        $State.capacity_limit_reported = $true
    }
    return $true
}

function Register-DelegationSession {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [Parameter(Mandatory = $true)][string]$WorkerSessionId
    )

    if ([string]::IsNullOrWhiteSpace($WorkerSessionId)) {
        throw "Runner-produced session id for '$WorkerId' is empty."
    }
    $active = Get-OrchestrationDictionary -Object $State -Name 'active'
    if (-not $active.Contains($WorkerId)) {
        throw "Worker '$WorkerId' cannot register a session because it is not active."
    }
    $existing = [string](Get-JsonProperty -Object $active[$WorkerId] -Name 'worker_session_id' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($existing) -and $existing -ne $WorkerSessionId) {
        throw "Worker '$WorkerId' attempted to replace its runner-produced session id."
    }
    $active[$WorkerId].worker_session_id = $WorkerSessionId
    return $true
}

function Assert-OrchestrationConcurrency {
    <#
      The queue exposes concurrent slots; this completion gate proves that
      the external orchestrator used them. A serial run is valid only when the
      harness explicitly rejected additional workers for its own capacity.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$State
    )

    $requestedConcurrency = [int](Get-JsonProperty -Object $Plan -Name 'requested_concurrency' -Default 0)
    $armCount = @((Get-JsonProperty -Object $Plan -Name 'arms' -Default @())).Count
    $defaultRequired = if ($armCount -gt 1 -and $requestedConcurrency -gt 1) { 2 } else { 1 }
    $required = [int](Get-JsonProperty -Object $Plan -Name 'minimum_parallel_workers' -Default $defaultRequired)
    $maxObserved = [int](Get-JsonProperty -Object $State -Name 'max_observed_active' -Default 0)
    $capacityReported = [bool](Get-JsonProperty -Object $State -Name 'capacity_limit_reported' -Default $false)

    if ($required -gt 1 -and $maxObserved -lt $required -and -not $capacityReported) {
        throw "Native worker orchestration was serial: max_observed_active=$maxObserved, required_parallel_workers=$required, requested_concurrency=$requestedConcurrency. A serial dispatch is incompatible unless the harness records an explicit capacity rejection."
    }

    return [ordered]@{
        status = if ($maxObserved -ge $required) { 'verified' } else { 'capacity_limited' }
        requested_concurrency = $requestedConcurrency
        required_parallel_workers = $required
        max_observed_active = $maxObserved
        capacity_limit_reported = $capacityReported
    }
}

function Register-WorkerTerminal {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [Parameter(Mandatory = $true)][object]$ExecutionEvidence
    )

    $active = Get-OrchestrationDictionary -Object $State -Name 'active'
    if (-not $active.Contains($WorkerId)) {
        $completed = Get-OrchestrationDictionary -Object $State -Name 'completed'
        $stateDescription = if ($completed.Contains($WorkerId)) { 'already terminal' } else { 'not accepted' }
        throw "Worker '$WorkerId' cannot become terminal because it is $stateDescription; terminal registration is exactly-once and must not be retried."
    }
    $status = [string](Get-JsonProperty -Object $ExecutionEvidence -Name 'status' -Default '')
    if ($status -notin @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')) {
        throw "Worker '$WorkerId' returned non-terminal status '$status'."
    }
    $arm = Get-OrchestrationArmByWorkerId -Plan $Plan -WorkerId $WorkerId
    $activeWorker = $active[$WorkerId]
    $expectedSessionId = [string](Get-JsonProperty -Object $activeWorker -Name 'worker_session_id' -Default '')
    $terminalEvidenceFailures = [System.Collections.Generic.List[string]]::new()

    # Preserve runner-owned failure codes before the common validator runs.
    foreach ($reportedFailure in @(Get-NativeWorkerReportedFailures -ExecutionEvidence $ExecutionEvidence)) {
        $terminalEvidenceFailures.Add([string]$reportedFailure)
    }

    # The plan stores the exact manifest-declared run path. Resolve only that
    # arm here; do not infer a path from configuration or inspect grading data.
    try {
        $runData = Resolve-RunContract -RunPath ([string]$arm.worker.run_manifest_path)
        $validation = Test-NativeWorkerTerminalEvidence -ExecutionEvidence $ExecutionEvidence -Run $runData -RequestedModel ([string]$arm.worker.model) -ExpectedWorkerSessionId $expectedSessionId -ExpectedMechanism ([string](Get-JsonProperty -Object $arm.worker -Name 'dispatch_mechanism' -Default ''))
        foreach ($failure in @($validation.Failures)) {
            if ($terminalEvidenceFailures -notcontains [string]$failure) { $terminalEvidenceFailures.Add([string]$failure) }
        }
        $evidenceSessionId = [string](Get-JsonProperty -Object $validation.Delegation -Name 'worker_session_id' -Default '')
        if ($terminalEvidenceFailures.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($evidenceSessionId)) {
            $completedWorkers = Get-OrchestrationDictionary -Object $State -Name 'completed'
            foreach ($completedWorker in @($completedWorkers.Values)) {
                if ([string](Get-JsonProperty -Object $completedWorker -Name 'worker_session_id' -Default '') -eq $evidenceSessionId) {
                    $terminalEvidenceFailures.Add('fresh_worker')
                    break
                }
            }
        }
    } catch {
        $terminalEvidenceFailures.Add('terminal_evidence_unresolvable')
        $terminalEvidenceFailures.Add($_.Exception.Message)
    }

    # Do NOT rewrite the runner-produced terminal status. Keep it authoritative.
    # Record evidence-validation separately so the execution status remains honest.
    $evidenceValidationStatus = if ($terminalEvidenceFailures.Count -gt 0) { 'failed' } else { 'passed' }

    if ($status -eq 'incompatible' -and $terminalEvidenceFailures.Count -eq 0) {
        # Runner explicitly reported incompatible; surface that as evidence failure
        $terminalEvidenceFailures.Add('runner_reported_incompatible')
        $evidenceValidationStatus = 'failed'
    }

    # Persist reported failures into the execution-evidence object without
    # mutating the runner-reported terminal status field.
    try { [void](Set-NativeWorkerReportedFailures -ExecutionEvidence $ExecutionEvidence -Failures @($terminalEvidenceFailures.ToArray())) } catch { }

    $active.Remove($WorkerId)
    $completed = Get-OrchestrationDictionary -Object $State -Name 'completed'
    $completed[$WorkerId] = [ordered]@{
        worker_id = $WorkerId
        eval_id = [int]$arm.eval_id
        eval_name = [string]$arm.eval_name
        configuration = [string]$arm.configuration
        # ledger status mirrors the raw runner status exactly (authority retained)
        status = $status
        terminal_utc = [DateTime]::UtcNow.ToString('o')
        worker_session_id = if ([string]::IsNullOrWhiteSpace($expectedSessionId)) {
            Get-JsonProperty -Object (Get-JsonProperty -Object (Get-JsonProperty -Object $ExecutionEvidence -Name 'evidence' -Default $null) -Name 'delegation' -Default $null) -Name 'worker_session_id' -Default $null
        } else { $expectedSessionId }
        # Preserve existing compatibility field for backward consumers but do not
        # let it mutate the authoritative execution status. Mark evidence level.
        native_worker_evidence = if ($status -eq 'incompatible' -or $terminalEvidenceFailures.Count -gt 0) { 'incompatible' } else { 'verified' }
        native_worker_evidence_failures = @($terminalEvidenceFailures.ToArray())
        evidence_validation = [ordered]@{
            status = $evidenceValidationStatus
            reasons = @($terminalEvidenceFailures.ToArray())
        }
    }
    return $true
}

function New-WorkerDispatchEnvelope {
    param([Parameter(Mandatory = $true)][object]$Arm)

    $worker = $Arm.worker
    return [ordered]@{
        type = 'eval_worker_dispatch'
        worker_id = [string]$worker.worker_id
        arm = [ordered]@{
            eval_id = [int]$worker.eval_id
            eval_name = [string]$worker.eval_name
            configuration = [string]$worker.configuration
            run_manifest = [string]$worker.run_manifest
            run_manifest_path = [string]$worker.run_manifest_path
        }
        requested = [ordered]@{
            model = [string]$worker.model
            reasoning_effort = $worker.reasoning_effort
            configuration_profile = $worker.configuration_profile
            tool_profile = $worker.tool_profile
            timeout_seconds = [int]$worker.timeout_seconds
        }
        worker_contract = [ordered]@{
            one_arm_only = $true
            paired_arm_visible = $false
            grading_material_visible = $false
            parent_executes_arm = $false
            dispatch_owner = [string](Get-JsonProperty -Object $worker -Name 'dispatch_owner' -Default 'orchestrator')
            dispatch_mechanism = [string](Get-JsonProperty -Object $worker -Name 'dispatch_mechanism' -Default '')
            runner_execute_invocation = [string](Get-JsonProperty -Object $worker -Name 'runner_execute_invocation' -Default 'forbidden')
            nested_model_execution = $false
            model_execution_count = 1
            fresh_worker_required = $true
        }
    }
}

function Assert-OrchestrationPlanContract {
    param([Parameter(Mandatory = $true)][object]$Plan)

    if ([string]$Plan.schema -ne (Get-RunnerSchemaNames).OrchestrationPlan) {
        throw 'Orchestration plan has an unsupported schema.'
    }
    $planDispatchOwner = [string](Get-JsonProperty -Object $Plan -Name 'dispatch_owner' -Default '')
    if ($planDispatchOwner -notin @('orchestrator', 'runner')) {
        throw "Orchestration plan dispatch_owner '$planDispatchOwner' is unsupported."
    }
    if (-not [bool]$Plan.native_worker_required -or [bool]$Plan.parent_executes_arms -or [bool]$Plan.nested_model_execution) {
        throw 'Orchestration plan must require native workers and forbid parent or nested model execution.'
    }
    $armCount = @($Plan.arms).Count
    $requestedConcurrency = [int]$Plan.requested_concurrency
    $expectedParallel = $armCount -gt 1 -and $requestedConcurrency -gt 1
    if ([bool](Get-JsonProperty -Object $Plan -Name 'parallel_dispatch_required' -Default $false) -ne $expectedParallel) {
        throw 'Orchestration plan parallel_dispatch_required does not match its independent arm count and requested concurrency.'
    }
    $minimumParallelWorkers = [int](Get-JsonProperty -Object $Plan -Name 'minimum_parallel_workers' -Default 1)
    $expectedMinimumParallelWorkers = if ($expectedParallel) { 2 } else { 1 }
    if ($minimumParallelWorkers -ne $expectedMinimumParallelWorkers) {
        throw 'Orchestration plan minimum_parallel_workers must require two workers whenever independent concurrent dispatch is requested.'
    }
    $workerIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($arm in @($Plan.arms)) {
        if (-not $workerIds.Add([string]$arm.worker_id)) { throw "Orchestration plan duplicates worker '$($arm.worker_id)'." }
        if (@($arm.depends_on).Count -ne 0) { throw "Worker '$($arm.worker_id)' has an unrelated dependency." }
        $worker = $arm.worker
        foreach ($property in @('one_arm_only', 'paired_arm_visible', 'grading_material_visible', 'parent_executes_arm', 'dispatch_owner', 'runner_execute_invocation', 'nested_model_execution', 'model_execution_count')) {
            if (-not (Test-JsonProperty -Object $worker -Name $property)) { throw "Worker '$($arm.worker_id)' is missing '$property'." }
        }
        if (-not [bool]$worker.one_arm_only -or [bool]$worker.paired_arm_visible -or [bool]$worker.grading_material_visible -or [bool]$worker.parent_executes_arm -or [bool]$worker.nested_model_execution -or [int]$worker.model_execution_count -ne 1) {
            throw "Worker '$($arm.worker_id)' violates the one-arm/one-model contract."
        }
        if ([string]$worker.worker_id -ne [string]$arm.worker_id -or [int]$worker.eval_id -ne [int]$arm.eval_id -or [string]$worker.configuration -ne [string]$arm.configuration) {
            throw "Worker '$($arm.worker_id)' does not identify exactly its manifest arm."
        }
        if ([string]$arm.dispatch_owner -ne $planDispatchOwner -or [string]$worker.dispatch_owner -ne $planDispatchOwner) {
            throw "Worker '$($arm.worker_id)' dispatch ownership does not match the plan."
        }
        $expectedRunnerExecute = if ($planDispatchOwner -eq 'runner') { 'required' } else { 'forbidden' }
        if ([string]$worker.runner_execute_invocation -ne $expectedRunnerExecute) {
            throw "Worker '$($arm.worker_id)' has runner_execute_invocation '$($worker.runner_execute_invocation)'; expected '$expectedRunnerExecute' for dispatch owner '$planDispatchOwner'."
        }
        foreach ($forbiddenProperty in @('paired_arm', 'grading', 'expected_output', 'assertions', 'eval_metadata', 'execution_result', 'result')) {
            if (Test-JsonProperty -Object $worker -Name $forbiddenProperty) {
                throw "Worker '$($arm.worker_id)' exposes forbidden parent or grading field '$forbiddenProperty'."
            }
        }
    }
    return $true
}
