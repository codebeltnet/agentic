<#!
.SYNOPSIS
    Bridges every available execution result using only manifest-declared arm paths.

.DESCRIPTION
    Reads manifest.json, validates the exact run_manifest, execution_result, and result
    paths for every arm, rejects result-like shadow files, and invokes the existing
    one-arm bridge without reconstructing any filename from an arm or mode name.
    No model, runner, or grader is started by this helper.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IterationDirectory,

    [switch]$RequireComplete,

    [switch]$RequireNativeDelegation,

    [switch]$RequireParallelDispatch,

    [string]$OrchestrationStatePath = 'orchestration-state.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'manifest-paths.ps1')
. (Join-Path $PSScriptRoot 'orchestration.ps1')

try {
    $iterationPath = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    $manifestPath = Join-Path $iterationPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Prepared iteration is missing manifest.json at '$iterationPath'."
    }

    $manifest = Read-RunnerJson -Path $manifestPath
    $records = @(Get-ManifestRunRecords -IterationDirectory $iterationPath -Manifest $manifest)
    $parallelDispatch = $null
    if ($RequireParallelDispatch) {
        Assert-SafeRelativePath -RelativePath $OrchestrationStatePath -FieldName 'orchestration state path'
        $statePath = Join-Path $iterationPath ($OrchestrationStatePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            throw "Parallel native-worker orchestration requires '$OrchestrationStatePath' at the iteration root."
        }

        $profileData = Resolve-ExecutionProfile -ProfilePath (Join-Path $iterationPath 'execution-profile.json')
        $runnerDescriptor = Get-PackageRunnerDescriptor -RunnerName ([string]$profileData.Runner)
        $plan = New-EvalOrchestrationPlan -IterationDirectory $iterationPath -Manifest $manifest -Profile $profileData.Profile -Descriptor $runnerDescriptor
        $state = Read-RunnerJson -Path $statePath
        $parallelDispatch = Assert-OrchestrationConcurrency -Plan $plan -State $state
    }
    $shadows = @(Get-ManifestShadowResultFiles -Records $records)
    if ($shadows.Count -gt 0) {
        $messages = @($shadows | ForEach-Object {
            "$($_.EvalName)/$($_.Configuration) has unreferenced result-like sibling '$($_.Path)'; use the exact manifest result '$($_.CanonicalPath)'."
        })
        throw ($messages -join [Environment]::NewLine)
    }

    $oneArmBridge = Join-Path $PSScriptRoot 'bridge-execution-result.ps1'
    if (-not (Test-Path -LiteralPath $oneArmBridge -PathType Leaf)) {
        throw "Package-local one-arm bridge is missing at '$oneArmBridge'."
    }

    $bridged = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $records) {
        if (-not (Test-Path -LiteralPath $record.ExecutionResultPath -PathType Leaf)) {
            $missing.Add("$($record.EvalName)/$($record.Configuration)")
            continue
        }

        # Always invoke the one-arm bridge. The raw result is the authoritative
        # terminal evidence; a status/path match alone cannot prove that the
        # canonical result reflects the current raw file. The one-arm bridge
        # preserves existing grading while revalidating hashes and provenance.
        $bridgeOutput = & pwsh -NoProfile -File $oneArmBridge `
            -Run $record.RunManifestPath `
            -ExecutionResult $record.ExecutionResultPath `
            -Result $record.ResultPath `
            -RequireNativeDelegation:$RequireNativeDelegation 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "$($record.EvalName)/$($record.Configuration) bridge failed for manifest paths run='$($record.RunManifestRelative)', execution='$($record.ExecutionResultRelative)', result='$($record.ResultRelative)': $([string]::Join(' ', @($bridgeOutput)))"
        }
        $bridged.Add("$($record.EvalName)/$($record.Configuration)")
    }

    $validation = Test-ManifestResults `
        -IterationDirectory $iterationPath `
        -Manifest $manifest `
        -Records $records `
        -RequireComplete:$RequireComplete
    if (-not $validation.Success) {
        throw ([string]::Join([Environment]::NewLine, @($validation.Errors)))
    }

    Write-RunnerJson -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-manifest-bridge/1'
        iteration = $iterationPath
        expected_arms = $validation.ExpectedArmCount
        bridged_arms = $validation.BridgedResults
        terminal_execution_results = $validation.TerminalExecutionResults
        missing_execution_results = @($missing)
        complete = $validation.Complete
        parallel_dispatch = $parallelDispatch
        warnings = @($validation.Warnings)
    }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
