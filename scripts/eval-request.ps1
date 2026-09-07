<#
.SYNOPSIS
    Deterministic helpers for the agent's explicit eval request workflow. Dot-source to use.
.DESCRIPTION
    These helpers never launch a model. The interactive host consumes an external_handoff decision
    with its fresh-context delegation tool, passing only the canonical prompt path. Do not wire
    this decision to CI, hooks, preparation, validation, or completion-gate execution.
#>
Set-StrictMode -Version Latest

function Get-EvalHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptPath,
        [switch]$Yolo,
        [switch]$ExternalOrchestratorAvailable
    )

    $path = (Resolve-Path -LiteralPath $PromptPath -ErrorAction Stop).Path
    if ([IO.Path]::GetFileName($path) -cne 'RUN-THIS.prompt.md') {
        throw 'Handoff requires the prepared RUN-THIS.prompt.md file.'
    }
    $package = Split-Path -Parent $path
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
    if (-not $ExternalOrchestratorAvailable) {
        $decision.reason = 'This host cannot hand off to a fresh external Eval Orchestrator. Use the intact manual handoff; never execute an arm in this context.'
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
        [switch]$ExternalOrchestratorAvailable
    )

    $ErrorActionPreference = 'Stop'
    # Splat existing preparation options unchanged; it alone resolves and verifies model policy.
    # Collect every success before issuing any handoff, including multi-skill explicit requests.
    if ($Preparation.ContainsKey('CollectResults')) { throw 'An eval request prepares packages; CollectResults is a separate forensic workflow.' }
    $arguments = $Preparation.Clone()
    $arguments.PassThru = $true
    $paths = @(& (Join-Path $PSScriptRoot 'prepare-skill-evals.ps1') @arguments)
    foreach ($path in $paths) {
        Get-EvalHandoff -PromptPath $path -Yolo:$Yolo -ExternalOrchestratorAvailable:$ExternalOrchestratorAvailable
    }
}
