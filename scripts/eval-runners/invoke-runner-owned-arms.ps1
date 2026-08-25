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

function ConvertTo-StartProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -notmatch '\s|"') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-RunnerPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-runner-preflight-' + [Guid]::NewGuid().ToString('N') + '.stdout')
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-runner-preflight-' + [Guid]::NewGuid().ToString('N') + '.stderr')
    $process = $null
    try {
        $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
        $arguments = @(
            '-NoProfile'
            '-File'
            (ConvertTo-StartProcessArgument -Value $RunnerPath)
            'preflight'
            '-Run'
            (ConvertTo-StartProcessArgument -Value $RunPath)
            '-Profile'
            (ConvertTo-StartProcessArgument -Value $ProfilePath)
        )
        $process = Start-Process -FilePath $pwshPath -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $RunPath) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
        $process.WaitForExit()
        $exitCode = $process.ExitCode
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
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }
}

function New-PreflightWorkerSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][object]$Invocation,
        [Parameter(Mandatory = $true)][object]$Descriptor
    )

    $preflight = $Invocation.Result
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $preflight) {
        foreach ($reason in @(Get-JsonProperty -Object $preflight -Name 'reasons' -Default @())) {
            if (-not [string]::IsNullOrWhiteSpace([string]$reason)) { [void]$reasons.Add([string]$reason) }
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace([string]$Invocation.ParseError)) { [void]$reasons.Add("runner preflight returned invalid JSON: $($Invocation.ParseError)") }
        if ([string]::IsNullOrWhiteSpace([string]$Invocation.Stdout)) { [void]$reasons.Add('runner preflight returned no JSON result.') }
    }
    if ([int]$Invocation.ExitCode -ne 0) {
        $diagnostic = [string]::Join(' ', @([string]$Invocation.Stderr, [string]$Invocation.Stdout).Where({ -not [string]::IsNullOrWhiteSpace($_) }))
        if ([string]::IsNullOrWhiteSpace($diagnostic)) { $diagnostic = 'no diagnostic output' }
        [void]$reasons.Add("runner preflight exited with status $($Invocation.ExitCode): $diagnostic")
    }

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
        status = if ($status -eq 'compatible' -and $delegationAssertion -eq 'passed') { 'compatible' } else { 'incompatible' }
        reasons = @($reasons.ToArray())
        native_delegation_assertion = [ordered]@{
            status = $delegationAssertion
            error = $delegationError
        }
        runner_exit_code = [int]$Invocation.ExitCode
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

    $completed = Get-OrchestrationDictionary -Object $State -Name 'completed'
    return @($completed.Values | Sort-Object { [string](Get-JsonProperty -Object $_ -Name 'worker_id' -Default '') } | ForEach-Object {
        [ordered]@{
            worker_id = [string](Get-JsonProperty -Object $_ -Name 'worker_id' -Default '')
            status = [string](Get-JsonProperty -Object $_ -Name 'status' -Default '')
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

    $completed = Get-OrchestrationDictionary -Object $State -Name 'completed'
    $incompatible = @($completed.Values | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'incompatible' })
    $summary = [ordered]@{
        schema = 'codebeltnet/agentic/runner-owned-fanout-summary/1'
        status = $Status
        runner = [string](Get-JsonProperty -Object $Profile -Name 'runner' -Default '')
        model = [string](Get-JsonProperty -Object $Profile -Name 'model' -Default '')
        dispatch_owner = [string]$Plan.dispatch_owner
        requested_concurrency = [int]$Plan.requested_concurrency
        completed_count = $completed.Count
        incompatible_count = $incompatible.Count
        max_observed_active = [int]$State.max_observed_active
        orchestration_state = 'orchestration-state.json'
        preflight_count = @($Preflights).Count
        execution_started = $completed.Count -gt 0
        execution_count = $completed.Count
        arms = @(New-ArmSummary -State $State)
    }
    if (@($Preflights).Count -gt 0) { $summary.preflights = @($Preflights) }
    if ($null -ne $Concurrency) { $summary.concurrency = $Concurrency }
    if (-not [string]::IsNullOrWhiteSpace($Error)) { $summary.error = $Error }
    return $summary
}

try {
    $manifestPath = Join-Path $iteration 'manifest.json'
    $manifest = Read-RunnerJson -Path $manifestPath
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
        $invocation = Invoke-RunnerPreflight -RunnerPath $runnerPath -RunPath $record.RunManifestPath -ProfilePath ([string]$profile.Path)
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
            New-Item -ItemType Directory -Path (Split-Path -Parent $executionResultPath) -Force | Out-Null
            $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-runner-owned-' + [Guid]::NewGuid().ToString('N') + '.stderr')
            $startInfo = @(
                '-NoProfile'
                '-File'
                (ConvertTo-StartProcessArgument -Value $runnerPath)
                'execute'
                '-Run'
                (ConvertTo-StartProcessArgument -Value $runPath)
                '-Profile'
                (ConvertTo-StartProcessArgument -Value ([string]$profile.Path))
            )
            $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
            $process = Start-Process -FilePath $pwshPath -ArgumentList $startInfo -WorkingDirectory (Split-Path -Parent $runPath) -RedirectStandardOutput $executionResultPath -RedirectStandardError $stderrPath -PassThru
            if (-not [bool]$state.preflight.execution_started) {
                $state.preflight.execution_started = $true
                Save-OrchestrationState -Path $statePath -State $state
            }
            [void](Register-DelegationAccepted -State $state -WorkerId $workerId)
            Save-OrchestrationState -Path $statePath -State $state
            $running.Add([pscustomobject]@{ worker_id = $workerId; process = $process; result_path = $executionResultPath; stderr_path = $stderrPath; run_path = $runPath })
        }

        if ($running.Count -eq 0) { throw 'Runner-owned fan-out has pending arms but no active native process.' }
        $activeRun = $running[0]
        $activeRun.process.WaitForExit()
        $exitCode = $activeRun.process.ExitCode
        $activeRun.process.Dispose()
        if (-not (Test-Path -LiteralPath $activeRun.result_path -PathType Leaf)) {
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
        $running.RemoveAt(0)
    }

    $concurrency = Assert-OrchestrationConcurrency -Plan $plan -State $state
    Save-OrchestrationState -Path $statePath -State $state
    $status = if (@($state.completed.Values | Where-Object { [string](Get-JsonProperty -Object $_ -Name 'status' -Default '') -eq 'incompatible' }).Count -gt 0) { 'completed_with_incompatible_arms' } else { 'completed' }
    Write-FanoutSummary -Summary (Get-FanoutSummary -Profile $profile -Plan $plan -State $state -Concurrency $concurrency -Preflights @($preflightRecords.ToArray()) -Status $status)
} catch {
    $errorMessage = $_.Exception.Message
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
            status = 'failed'
            runner = ''
            model = ''
            dispatch_owner = 'runner'
            requested_concurrency = 0
            completed_count = 0
            incompatible_count = 0
            max_observed_active = 0
            orchestration_state = 'orchestration-state.json'
            arms = @()
            error = $errorMessage
        }) -ExitCode 2
    }
}
