<#!
.SYNOPSIS
    Validates package-root grading.json before the exactly-once finalizer.

.DESCRIPTION
    This helper is deterministic and side-effect free. It invokes the same
    grading contract used by apply-eval-grading.ps1, but it does not apply
    grading, bridge results, finalize the package, freeze evidence, or write
    reports. Call it repeatedly until grading.json is valid, then invoke the
    finalizer exactly once.
#>
[CmdletBinding()]
param(
    [string]$IterationDirectory,
    [string]$GradingPath = 'grading.json',
    [switch]$ShowSkeleton
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'eval-grading-contract.ps1')

try {
    if ($ShowSkeleton) {
        Write-RunnerJson -Value (Get-EvalGradingSkeleton) -AsOutput
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($IterationDirectory)) {
        throw 'Validation requires -IterationDirectory unless -ShowSkeleton is used.'
    }
    $validation = Assert-EvalGradingContract -IterationDirectory $IterationDirectory -GradingPath $GradingPath
    Write-RunnerJson -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-grading-validation/1'
        status = 'valid'
        iteration = $validation.IterationDirectory
        grading_file = $validation.GradingFullPath
        graded_assertions = $validation.GradedAssertions
        execution_freeze = $validation.FreezeValidation.Path
    }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
