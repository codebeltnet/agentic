<#
.SYNOPSIS
    Deterministic helpers for the agent's explicit eval request workflow. Dot-source to use.
.DESCRIPTION
    These helpers never launch a model. The interactive host consumes an external_handoff decision
    with its fresh-context delegation tool, passing only the canonical prompt path. Do not wire
    this decision to CI, hooks, preparation, validation, or completion-gate execution.
    For GitHub Copilot CLI, task + general-purpose delegation is a valid external-orchestrator
    capability for this one-shot handoff.
#>
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'eval-runners/runner-common.ps1')
. (Join-Path $PSScriptRoot 'eval-runners/manifest-paths.ps1')
. (Join-Path $PSScriptRoot 'eval-runners/package-integrity.ps1')

function Assert-PreparedEvalHandoffPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptPath
    )

    $path = (Resolve-Path -LiteralPath $PromptPath -ErrorAction Stop).Path
    if ([IO.Path]::GetFileName($path) -cne 'RUN-THIS.prompt.md') {
        throw 'Handoff requires the prepared RUN-THIS.prompt.md file.'
    }

    $package = Split-Path -Parent $path
    try {
        $manifestPath = Resolve-ManifestDeclaredPath -IterationDirectory $package -RelativePath 'manifest.json' -FieldName 'manifest.json' -Kind File -RequireExists
        $manifest = Read-RunnerJson -Path $manifestPath
        if ([string](Get-JsonProperty -Object $manifest -Name 'schema' -Default '') -ne 'codebeltnet/agentic/eval-package/2') {
            throw "manifest.json must declare 'codebeltnet/agentic/eval-package/2'."
        }
        if ([string](Get-JsonProperty -Object $manifest -Name 'execution' -Default '') -ne 'runner_handoff') {
            throw "manifest.execution must be 'runner_handoff'."
        }
        $runnerPrompt = [string](Get-JsonProperty -Object $manifest -Name 'runner_prompt' -Default '')
        if ([string]::IsNullOrWhiteSpace($runnerPrompt)) {
            throw 'manifest.json must declare runner_prompt.'
        }
        $resolvedPrompt = Resolve-ManifestDeclaredPath -IterationDirectory $package -RelativePath $runnerPrompt -FieldName 'runner_prompt' -Kind File -RequireExists
        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not [string]::Equals([System.IO.Path]::GetFullPath($resolvedPrompt), [System.IO.Path]::GetFullPath($path), $comparison)) {
            throw 'The supplied RUN-THIS.prompt.md is not the manifest-declared runner_prompt.'
        }
        [void](Get-ManifestRunRecords -IterationDirectory $package -Manifest $manifest)
        [void](Assert-PackageRunnerToolsIntegrity -IterationDirectory $package -Manifest $manifest)
        [void](Assert-PackageRunnerIdentity -IterationDirectory $package -Manifest $manifest)
    } catch {
        throw "Handoff requires a valid prepared eval package produced by this repository: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        PromptPath = $path
        Package = $package
    }
}

function Get-EvalHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptPath,
        [switch]$Yolo,
        [Alias('ExternalOrchestratorAvailable')][switch]$CanDelegateFreshOrchestrator
    )

    $validated = Assert-PreparedEvalHandoffPackage -PromptPath $PromptPath
    $path = [string]$validated.PromptPath
    $package = [string]$validated.Package
    $decision = [ordered]@{ action = 'manual_handoff'; prompt_path = $path; reason = 'Preparation complete; hand this file to an external Eval Orchestrator.' }
    if (-not $Yolo) { return [pscustomobject]$decision }

    # Reserve the handoff before the host delegates. An uncertain launch must never be retried.
    $claim = Join-Path $package '.external-handoff-started'
    if ((Test-Path -LiteralPath $claim) -or
        (Test-Path -LiteralPath (Join-Path $package 'orchestration-state.json')) -or
        (Test-Path -LiteralPath (Join-Path $package 'execution-freeze.json'))) {
        $decision.action = 'already_started'
        $decision.reason = 'Do not dispatch again or invoke Phase 1 again. Observe the existing Orchestrator; interrupted execution remains incomplete.'
        return [pscustomobject]$decision
    }
    if (-not $CanDelegateFreshOrchestrator) {
        $decision.reason = 'This host cannot delegate one fresh external Eval Orchestrator context. Keep the intact manual handoff and never execute an arm in this context.'
        return [pscustomobject]$decision
    }
    try {
        $stream = [IO.File]::Open($claim, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
    } catch [IO.IOException] {
        if (-not (Test-Path -LiteralPath $claim)) { throw }
        $decision.action = 'already_started'
        $decision.reason = 'A handoff was already reserved. Do not dispatch again.'
        return [pscustomobject]$decision
    }
    $decision.action = 'external_handoff'
    $decision.reason = 'Pass only this canonical file path to one fresh external Eval Orchestrator under the explicit user yolo authorization; wait for its final result.'
    return [pscustomobject]$decision
}

function Invoke-EvalRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Preparation,
        [switch]$Yolo,
        [Alias('ExternalOrchestratorAvailable')][switch]$CanDelegateFreshOrchestrator
    )

    $ErrorActionPreference = 'Stop'
    # Splat existing preparation options unchanged; it alone resolves and verifies model policy.
    # Collect every success before issuing any handoff, including multi-skill explicit requests.
    if ($Preparation.ContainsKey('CollectResults')) { throw 'An eval request prepares packages; CollectResults is a separate forensic workflow.' }
    $arguments = $Preparation.Clone()
    $arguments.PassThru = $true
    $paths = @(& (Join-Path $PSScriptRoot 'prepare-skill-evals.ps1') @arguments)
    foreach ($path in $paths) {
        Get-EvalHandoff -PromptPath $path -Yolo:$Yolo -CanDelegateFreshOrchestrator:$CanDelegateFreshOrchestrator
    }
}
