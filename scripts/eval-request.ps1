<#
.SYNOPSIS
    Deterministic helpers for the agent's explicit eval request workflow. Dot-source to use.
.DESCRIPTION
    These helpers never launch a model. The interactive host consumes Get-EvalHandoff's
    machine-readable decision and, when action=external_handoff, must treat authorization as
    complete: confirmation_required=false, dispatch_immediately=true, and exactly one fresh
    external Eval Orchestrator may be created. After launch, New-ExternalEvalOrchestratorState and
    Update-ExternalEvalOrchestratorState model the outer host lifecycle: keep the same native
    handle, treat a bounded wait with no terminal result as still running, and wait again on that
    same handle until a true terminal completed/failed status exists. Do not wire this decision to
    CI, hooks, preparation, validation, or completion-gate execution. For GitHub Copilot CLI,
    task + general-purpose delegation is a valid external-orchestrator capability for this one-shot
    handoff.
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
        $runnerPromptHash = [string](Get-JsonProperty -Object $manifest -Name 'runner_prompt_sha256' -Default '')
        if ([string]::IsNullOrWhiteSpace($runnerPromptHash)) {
            throw 'manifest.json must declare runner_prompt_sha256.'
        }
        if (-not (Test-Sha256 -Value $runnerPromptHash) -or $runnerPromptHash -cne $runnerPromptHash.ToLowerInvariant()) {
            throw 'manifest.runner_prompt_sha256 must be a lowercase SHA-256.'
        }
        $resolvedPrompt = Resolve-ManifestDeclaredPath -IterationDirectory $package -RelativePath $runnerPrompt -FieldName 'runner_prompt' -Kind File -RequireExists
        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not [string]::Equals([System.IO.Path]::GetFullPath($resolvedPrompt), [System.IO.Path]::GetFullPath($path), $comparison)) {
            throw 'The supplied RUN-THIS.prompt.md is not the manifest-declared runner_prompt.'
        }
        $currentRunnerPromptHash = Get-Sha256HexFromFile -Path $resolvedPrompt
        if ($currentRunnerPromptHash -cne $runnerPromptHash) {
            throw 'manifest.runner_prompt_sha256 does not match the current RUN-THIS.prompt.md bytes. Requires a fresh package.'
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

function New-EvalHandoffDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('manual_handoff', 'external_handoff', 'already_started')][string]$Action,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$Reason,
        [switch]$UserAuthorized,
        [switch]$HostCanDelegateFreshOrchestrator,
        [switch]$DispatchImmediately,
        [int]$MaxNewExternalOrchestrators = 0,
        [switch]$SameHandleRequired
    )

    $pendingWaitAction = if ($SameHandleRequired) { 'wait_same_handle_again' } else { 'none' }
    $terminalStatuses = if ($SameHandleRequired) { @('completed', 'failed') } else { @() }
    return [pscustomobject][ordered]@{
        schema = 'codebeltnet/agentic/eval-handoff-decision/1'
        action = $Action
        prompt_path = $PromptPath
        reason = $Reason
        user_authorized = $UserAuthorized.IsPresent
        host_can_delegate_fresh_orchestrator = $HostCanDelegateFreshOrchestrator.IsPresent
        confirmation_required = $false
        dispatch_immediately = $DispatchImmediately.IsPresent
        max_new_external_orchestrators = $MaxNewExternalOrchestrators
        same_handle_required = $SameHandleRequired.IsPresent
        pending_wait_action = $pendingWaitAction
        terminal_statuses = @($terminalStatuses)
    }
}

function Assert-ExternalEvalHandoffDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Decision
    )

    $schema = [string](Get-JsonProperty -Object $Decision -Name 'schema' -Default '')
    if ($schema -ne 'codebeltnet/agentic/eval-handoff-decision/1') {
        throw "External Eval handoff requires schema 'codebeltnet/agentic/eval-handoff-decision/1'."
    }
    if ([string](Get-JsonProperty -Object $Decision -Name 'action' -Default '') -ne 'external_handoff') {
        throw "External Eval handoff requires action 'external_handoff'."
    }
    if (-not [bool](Get-JsonProperty -Object $Decision -Name 'user_authorized' -Default $false)) {
        throw 'External Eval handoff requires explicit user authorization.'
    }
    if (-not [bool](Get-JsonProperty -Object $Decision -Name 'host_can_delegate_fresh_orchestrator' -Default $false)) {
        throw 'External Eval handoff requires fresh-context host delegation capability.'
    }
    if ([bool](Get-JsonProperty -Object $Decision -Name 'confirmation_required' -Default $true)) {
        throw 'External Eval handoff must not require another user confirmation.'
    }
    if (-not [bool](Get-JsonProperty -Object $Decision -Name 'dispatch_immediately' -Default $false)) {
        throw 'External Eval handoff must dispatch immediately.'
    }
    if ([int](Get-JsonProperty -Object $Decision -Name 'max_new_external_orchestrators' -Default 0) -ne 1) {
        throw 'External Eval handoff permits exactly one fresh external Eval Orchestrator.'
    }
    if (-not [bool](Get-JsonProperty -Object $Decision -Name 'same_handle_required' -Default $false)) {
        throw 'External Eval handoff must retain the same native Orchestrator handle across waits.'
    }
    if ([string](Get-JsonProperty -Object $Decision -Name 'pending_wait_action' -Default '') -ne 'wait_same_handle_again') {
        throw "External Eval handoff must map a non-terminal bounded wait to 'wait_same_handle_again'."
    }
    $terminalStatuses = @((Get-JsonProperty -Object $Decision -Name 'terminal_statuses' -Default @()))
    if ($terminalStatuses.Count -ne 2 -or $terminalStatuses[0] -ne 'completed' -or $terminalStatuses[1] -ne 'failed') {
        throw "External Eval handoff must declare terminal statuses 'completed' and 'failed'."
    }
}

function New-ExternalEvalOrchestratorState {
    [CmdletBinding(DefaultParameterSetName = 'Launched')]
    param(
        [Parameter(Mandatory)][object]$Decision,
        [Parameter(Mandatory, ParameterSetName = 'Launched')][string]$NativeHandle,
        [Parameter(Mandatory, ParameterSetName = 'LaunchFailed')][switch]$LaunchFailed,
        [Parameter(ParameterSetName = 'LaunchFailed')][string]$FailureReason = 'The external Eval Orchestrator launch failed before a native handle existed.'
    )

    Assert-ExternalEvalHandoffDecision -Decision $Decision
    $promptPath = [string](Get-JsonProperty -Object $Decision -Name 'prompt_path' -Default '')
    if ($PSCmdlet.ParameterSetName -eq 'LaunchFailed') {
        return [pscustomobject][ordered]@{
            schema = 'codebeltnet/agentic/eval-orchestrator-lifecycle/1'
            prompt_path = $promptPath
            status = 'launch_failed'
            terminal = $true
            native_handle = $null
            wait_count = 0
            same_handle_required = $false
            pending_wait_action = 'none'
            max_new_external_orchestrators = 0
            terminal_result = $null
            reason = $FailureReason
        }
    }

    if ([string]::IsNullOrWhiteSpace($NativeHandle)) {
        throw 'A launched external Eval Orchestrator requires a non-empty native handle.'
    }

    return [pscustomobject][ordered]@{
        schema = 'codebeltnet/agentic/eval-orchestrator-lifecycle/1'
        prompt_path = $promptPath
        status = 'running'
        terminal = $false
        native_handle = $NativeHandle
        wait_count = 0
        same_handle_required = $true
        pending_wait_action = 'wait_same_handle_again'
        max_new_external_orchestrators = 0
        terminal_result = $null
        reason = 'The external Eval Orchestrator exists. Keep this same native handle and repeat bounded waits until a true terminal completed/failed result exists.'
    }
}

function Update-ExternalEvalOrchestratorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$NativeHandle,
        [Parameter(Mandatory)][ValidateSet('pending', 'completed', 'failed')][string]$NativeWaitStatus,
        [object]$TerminalResult = $null
    )

    $schema = [string](Get-JsonProperty -Object $State -Name 'schema' -Default '')
    if ($schema -ne 'codebeltnet/agentic/eval-orchestrator-lifecycle/1') {
        throw "External Eval Orchestrator state requires schema 'codebeltnet/agentic/eval-orchestrator-lifecycle/1'."
    }
    if ([bool](Get-JsonProperty -Object $State -Name 'terminal' -Default $false)) {
        throw 'A terminal external Eval Orchestrator state cannot be waited again.'
    }
    $expectedHandle = [string](Get-JsonProperty -Object $State -Name 'native_handle' -Default '')
    if ([string]::IsNullOrWhiteSpace($expectedHandle)) {
        throw 'A running external Eval Orchestrator state must retain its native handle.'
    }
    if ($NativeHandle -cne $expectedHandle) {
        throw "External Eval Orchestrator waits must retain the same native handle. Expected '$expectedHandle', received '$NativeHandle'."
    }

    $waitCount = [int](Get-JsonProperty -Object $State -Name 'wait_count' -Default 0) + 1
    $promptPath = [string](Get-JsonProperty -Object $State -Name 'prompt_path' -Default '')
    switch ($NativeWaitStatus) {
        'pending' {
            return [pscustomobject][ordered]@{
                schema = 'codebeltnet/agentic/eval-orchestrator-lifecycle/1'
                prompt_path = $promptPath
                status = 'running'
                terminal = $false
                native_handle = $expectedHandle
                wait_count = $waitCount
                same_handle_required = $true
                pending_wait_action = 'wait_same_handle_again'
                max_new_external_orchestrators = 0
                terminal_result = $null
                reason = 'The bounded native wait returned no terminal Orchestrator result yet. Still running: wait again on this same handle and do not infer Phase 1 failure or create another Orchestrator.'
            }
        }
        'completed' {
            return [pscustomobject][ordered]@{
                schema = 'codebeltnet/agentic/eval-orchestrator-lifecycle/1'
                prompt_path = $promptPath
                status = 'completed'
                terminal = $true
                native_handle = $expectedHandle
                wait_count = $waitCount
                same_handle_required = $true
                pending_wait_action = 'none'
                max_new_external_orchestrators = 0
                terminal_result = $TerminalResult
                reason = 'The same external Eval Orchestrator reached a true terminal completed state.'
            }
        }
        'failed' {
            return [pscustomobject][ordered]@{
                schema = 'codebeltnet/agentic/eval-orchestrator-lifecycle/1'
                prompt_path = $promptPath
                status = 'failed'
                terminal = $true
                native_handle = $expectedHandle
                wait_count = $waitCount
                same_handle_required = $true
                pending_wait_action = 'none'
                max_new_external_orchestrators = 0
                terminal_result = $TerminalResult
                reason = 'The same external Eval Orchestrator reached a true terminal failed state.'
            }
        }
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
    $decision = New-EvalHandoffDecision -Action 'manual_handoff' -PromptPath $path `
        -Reason 'Preparation complete; hand this file to an external Eval Orchestrator.' `
        -UserAuthorized:$Yolo.IsPresent -HostCanDelegateFreshOrchestrator:$CanDelegateFreshOrchestrator.IsPresent
    if (-not $Yolo) { return [pscustomobject]$decision }

    # Reserve the handoff before the host delegates. An uncertain launch must never be retried.
    $claim = Join-Path $package '.external-handoff-started'
    if ((Test-Path -LiteralPath $claim) -or
        (Test-Path -LiteralPath (Join-Path $package 'orchestration-state.json')) -or
        (Test-Path -LiteralPath (Join-Path $package 'execution-freeze.json'))) {
        return (New-EvalHandoffDecision -Action 'already_started' -PromptPath $path `
                -Reason 'Do not dispatch again or invoke Phase 1 again. Observe the existing Orchestrator; interrupted execution remains incomplete.' `
                -UserAuthorized:$true -HostCanDelegateFreshOrchestrator:$CanDelegateFreshOrchestrator.IsPresent -SameHandleRequired)
    }
    if (-not $CanDelegateFreshOrchestrator) {
        return (New-EvalHandoffDecision -Action 'manual_handoff' -PromptPath $path `
                -Reason 'This host cannot delegate one fresh external Eval Orchestrator context. Keep the intact manual handoff and never execute an arm in this context.' `
                -UserAuthorized:$true -HostCanDelegateFreshOrchestrator:$false)
    }
    try {
        $stream = [IO.File]::Open($claim, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
    } catch [IO.IOException] {
        if (-not (Test-Path -LiteralPath $claim)) { throw }
        return (New-EvalHandoffDecision -Action 'already_started' -PromptPath $path `
                -Reason 'A handoff was already reserved. Do not dispatch again.' `
                -UserAuthorized:$true -HostCanDelegateFreshOrchestrator:$CanDelegateFreshOrchestrator.IsPresent -SameHandleRequired)
    }
    return (New-EvalHandoffDecision -Action 'external_handoff' -PromptPath $path `
            -Reason 'Pass only this canonical file path to one fresh external Eval Orchestrator under the explicit user yolo authorization; do not ask again, dispatch immediately, and keep the same native handle across bounded waits until its final result.' `
            -UserAuthorized:$true -HostCanDelegateFreshOrchestrator:$true -DispatchImmediately `
            -MaxNewExternalOrchestrators 1 -SameHandleRequired)
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
