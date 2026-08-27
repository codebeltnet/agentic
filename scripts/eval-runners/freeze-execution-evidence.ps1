<#!
.SYNOPSIS
    Closes Phase 1 by writing the package execution-freeze.json ledger.

.DESCRIPTION
    This is the shared deterministic boundary for orchestrator-owned packages.
    Runner-owned fan-out calls the same library directly after its queue is
    terminal. It never overwrites an existing freeze and never repairs raw
    evidence.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IterationDirectory,
    [string]$OrchestrationStatePath = 'orchestration-state.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'runner-common.ps1')
. (Join-Path $PSScriptRoot 'manifest-paths.ps1')
. (Join-Path $PSScriptRoot 'orchestration.ps1')
. (Join-Path $PSScriptRoot 'execution-freeze.ps1')

function Save-FreezeOrchestrationState {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$State)

    [System.IO.File]::WriteAllText($Path, (($State | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

try {
    $iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    Assert-SafeRelativePath -RelativePath $OrchestrationStatePath -FieldName 'orchestration state path'
    $statePath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $OrchestrationStatePath -FieldName 'orchestration state' -Kind File -RequireExists
    $manifest = Read-RunnerJson -Path (Join-Path $iteration 'manifest.json')
    $freezeRelativePath = [string](Get-JsonProperty -Object $manifest -Name 'execution_freeze' -Default '')
    if ([string]::IsNullOrWhiteSpace($freezeRelativePath)) { throw 'manifest.json must declare execution_freeze.' }
    $freezePath = Get-ExecutionFreezePath -IterationDirectory $iteration -RelativePath $freezeRelativePath
    if (Test-Path -LiteralPath $freezePath) {
        throw "Execution integrity failure: execution-freeze.json already exists at '$freezePath'; refusing to re-freeze raw evidence. Requires fresh Phase 1 execution."
    }
    $profile = Resolve-ExecutionProfile -ProfilePath (Join-Path $iteration 'execution-profile.json')
    $descriptor = Get-PackageRunnerDescriptor -RunnerName $profile.Runner
    $plan = New-EvalOrchestrationPlan -IterationDirectory $iteration -Manifest $manifest -Profile $profile.Profile -Descriptor $descriptor
    [void](Assert-OrchestrationPlanContract -Plan $plan)
    $state = Read-RunnerJson -Path $statePath
    if ([string](Get-JsonProperty -Object $state -Name 'schema' -Default '') -ne 'codebeltnet/agentic/eval-orchestration-state/1') {
        throw 'Execution freeze requires a valid orchestration-state.json.'
    }
    $activeWorkers = Get-JsonProperty -Object $state -Name 'active' -Default ([ordered]@{})
    if (@($state.pending_worker_ids).Count -ne 0 -or @(Get-JsonPropertyNames -Object $activeWorkers).Count -ne 0) {
        throw 'Execution freeze requires every orchestration worker to be terminal.'
    }
    $records = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest $manifest)
    $completed = Get-JsonProperty -Object $state -Name 'completed' -Default ([ordered]@{})
    if (@(Get-JsonPropertyNames -Object $completed).Count -ne $records.Count) {
        throw 'Execution freeze requires one terminal orchestration record per manifest arm.'
    }
    foreach ($record in $records) {
        $workerId = Get-FreezeArmKey -Record $record
        if (-not (Test-JsonProperty -Object $completed -Name $workerId)) { throw "Execution freeze is missing terminal worker '$workerId'." }
        $terminal = Get-JsonProperty -Object $completed -Name $workerId -Default $null
        if ([string](Get-JsonProperty -Object $terminal -Name 'status' -Default '') -notin @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')) {
            throw "Execution freeze cannot close non-terminal worker '$workerId'."
        }
    }
    $concurrency = Assert-OrchestrationConcurrency -Plan $plan -State $state
    $freeze = New-ExecutionFreezeDocument -IterationDirectory $iteration -Manifest $manifest -Records $records -Profile $profile
    $freezePath = Write-ExecutionFreezeDocument -IterationDirectory $iteration -Freeze $freeze -RelativePath $freezeRelativePath
    $state.execution_freeze = [ordered]@{
        schema = (Get-RunnerSchemaNames).ExecutionFreeze
        path = [System.IO.Path]::GetRelativePath($iteration, $freezePath).Replace('\', '/')
        sha256 = Get-Sha256HexFromFile -Path $freezePath
    }
    Save-FreezeOrchestrationState -Path $statePath -State $state
    Write-RunnerJson -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-execution-freeze-summary/1'
        status = 'frozen'
        execution_freeze = $freezePath
        execution_freeze_sha256 = [string]$state.execution_freeze.sha256
        executions = $records.Count
        concurrency = $concurrency
    }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
