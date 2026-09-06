<#!
.SYNOPSIS
    Deterministically finalizes a prepared evaluation package.

.DESCRIPTION
    This is the only normal post-grading completion boundary. It validates
    Phase 1 state and the immutable raw-evidence freeze, runs the idempotent
    bridge, applies the Grader's grading-only artifact, invokes the existing
    Anthropic-compatible report adapter, and returns one JSON summary. Any
    failure is incomplete; this command has no best-effort mode.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IterationDirectory,
    [string]$GradingPath = 'grading.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'runner-common.ps1')
. (Join-Path $PSScriptRoot 'manifest-paths.ps1')
. (Join-Path $PSScriptRoot 'orchestration.ps1')
. (Join-Path $PSScriptRoot 'execution-freeze.ps1')
. (Join-Path $PSScriptRoot 'package-integrity.ps1')

function Invoke-FinalizerCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $output = & pwsh -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = [string]::Join(' ', @($output | ForEach-Object { [string]$_ }))
        throw "$Description failed: $detail"
    }
    return @($output)
}

function Assert-FinalizerState {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Descriptor
    )

    $statePath = Join-Path $IterationDirectory 'orchestration-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'Finalization failed: orchestration-state.json is missing.'
    }
    $plan = New-EvalOrchestrationPlan -IterationDirectory $IterationDirectory -Manifest $Manifest -Profile $Profile.Profile -Descriptor $Descriptor
    [void](Assert-OrchestrationPlanContract -Plan $plan)
    $state = Read-RunnerJson -Path $statePath
    if ([string](Get-JsonProperty -Object $state -Name 'plan_schema' -Default '') -ne [string]$plan.schema -or
        [string](Get-JsonProperty -Object $state -Name 'dispatch_owner' -Default '') -ne [string]$plan.dispatch_owner) {
        throw 'Finalization failed: orchestration-state.json does not match the manifest execution plan.'
    }
    $activeWorkers = Get-JsonProperty -Object $state -Name 'active' -Default ([ordered]@{})
    if (@($state.pending_worker_ids).Count -ne 0 -or @(Get-JsonPropertyNames -Object $activeWorkers).Count -ne 0) {
        throw 'Finalization failed: orchestration still has pending or active workers.'
    }
    $completed = Get-JsonProperty -Object $state -Name 'completed' -Default ([ordered]@{})
    if (@(Get-JsonPropertyNames -Object $completed).Count -ne @($plan.arms).Count) {
        throw 'Finalization failed: orchestration terminal count does not match the manifest arm count.'
    }
    foreach ($arm in @($plan.arms)) {
        $workerId = [string]$arm.worker_id
        if (-not (Test-JsonProperty -Object $completed -Name $workerId)) { throw "Finalization failed: orchestration is missing terminal worker '$workerId'." }
        $terminal = Get-JsonProperty -Object $completed -Name $workerId -Default $null
        if ([string](Get-JsonProperty -Object $terminal -Name 'worker_id' -Default '') -ne $workerId -or
            [int](Get-JsonProperty -Object $terminal -Name 'eval_id' -Default 0) -ne [int]$arm.eval_id -or
            [string](Get-JsonProperty -Object $terminal -Name 'configuration' -Default '') -ne [string]$arm.configuration) {
            throw "Finalization failed: terminal worker '$workerId' does not match its exact plan identity."
        }
        if ([string](Get-JsonProperty -Object $terminal -Name 'status' -Default '') -notin @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')) {
            throw "Finalization failed: worker '$workerId' is not terminal."
        }
    }
    $preflight = Get-JsonProperty -Object $state -Name 'preflight' -Default $null
    if ([string](Get-JsonProperty -Object $preflight -Name 'status' -Default '') -ne 'passed') {
        throw 'Finalization failed: Phase 1 preflight gate did not pass.'
    }
    return [pscustomobject]@{ Plan = $plan; State = $state; Descriptor = $Descriptor; Concurrency = (Assert-OrchestrationConcurrency -Plan $plan -State $state) }
}

function Assert-FinalizerGrading {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][string]$IterationDirectory
    )

    $graded = 0
    foreach ($record in $Records) {
        $result = Read-RunnerJson -Path $record.ResultPath
        if ([string]$result.execution_status -ne 'completed') { throw "Finalization failed: '$($record.ResultRelative)' is not a completed execution." }
        $assertions = @(Get-JsonProperty -Object (Read-RunnerJson -Path $record.MetadataPath) -Name 'assertions' -Default @())
        $grading = @(Get-JsonProperty -Object $result -Name 'grading' -Default @())
        if ($grading.Count -ne $assertions.Count) { throw "Finalization failed: '$($record.ResultRelative)' has incomplete grading cardinality." }
        foreach ($grade in $grading) {
            if ((Get-JsonProperty -Object $grade -Name 'passed' -Default $null) -isnot [bool]) {
                throw "Finalization failed: '$($record.ResultRelative)' contains an ungraded assertion."
            }
            $graded++
        }
    }
    return $graded
}

try {
    $iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    $manifestPath = Join-Path $iteration 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Finalization failed: manifest.json is missing.' }
    $manifest = Read-RunnerJson -Path $manifestPath
    [void](Assert-PackageRunnerToolsIntegrity -IterationDirectory $iteration -Manifest $manifest)
    $identity = Assert-PackageRunnerIdentity -IterationDirectory $iteration -Manifest $manifest
    $declaredGradingPath = [string](Get-JsonProperty -Object $manifest -Name 'grading' -Default '')
    if ([string]::IsNullOrWhiteSpace($declaredGradingPath) -or $declaredGradingPath -ne $GradingPath) {
        throw "Finalization failed: grading path '$GradingPath' does not match manifest.grading '$declaredGradingPath'."
    }
    $profile = $identity.Profile
    $stateValidation = Assert-FinalizerState -IterationDirectory $iteration -Manifest $manifest -Profile $profile -Descriptor $identity.Descriptor
    $freezeValidation = Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState
    $records = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest $manifest)

    $manifestBridge = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath ([string]$manifest.runner_tools + '/bridge-manifest-results.ps1') -FieldName 'manifest bridge' -Kind File -RequireExists
    $bridgeArgs = @('-IterationDirectory', $iteration, '-RequireComplete', '-RequireParallelDispatch')
    if ([string]$stateValidation.Plan.dispatch_owner -eq 'runner') {
        $bridgeArgs += '-RequireNativeDelegation'
    }
    [void](Invoke-FinalizerCommand -ScriptPath $manifestBridge -Arguments $bridgeArgs -Description 'Manifest bridge')
    [void](Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState)

    $gradingScript = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath ([string]$manifest.runner_tools + '/apply-eval-grading.ps1') -FieldName 'grading application helper' -Kind File -RequireExists
    [void](Invoke-FinalizerCommand -ScriptPath $gradingScript -Arguments @('-IterationDirectory', $iteration, '-GradingPath', $GradingPath) -Description 'Grading application')
    $gradedAssertions = Assert-FinalizerGrading -Records $records -IterationDirectory $iteration

    $reportRelative = [string](Get-JsonProperty -Object $manifest.report -Name 'tool' -Default 'tools/generate-eval-report.ps1')
    $reportScript = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $reportRelative -FieldName 'report adapter' -Kind File -RequireExists
    [void](Invoke-FinalizerCommand -ScriptPath $reportScript -Arguments @('-IterationDirectory', $iteration, '-RequireComplete') -Description 'Report generation')

    $artifactRelatives = @('report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')
    $artifacts = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in $artifactRelatives) {
        $path = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $relative -FieldName "final artifact '$relative'" -Kind File -RequireExists
        if ((Get-Item -LiteralPath $path).Length -le 0) { throw "Finalization failed: mandatory artifact '$relative' is empty." }
        $artifacts.Add([ordered]@{ path = $path; bytes = [int64](Get-Item -LiteralPath $path).Length })
    }

    Write-RunnerJson -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-finalization/1'
        status = 'completed'
        iteration = $iteration
        runner = $profile.Runner
        model = $profile.Model
        expected_arms = $records.Count
        completed_arms = $records.Count
        graded_assertions = $gradedAssertions
        execution_freeze = $freezeValidation.Path
        concurrency = $stateValidation.Concurrency
        artifacts = @($artifacts.ToArray())
    }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
