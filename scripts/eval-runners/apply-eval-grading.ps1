<#!
.SYNOPSIS
    Applies the external Grader's grading-only artifact to canonical results.

.DESCRIPTION
    The Grader is allowed to author only package-root grading.json. This
    deterministic command validates its exact assertion identities, verifies
    the immutable Phase 1 freeze, and changes only canonical grading fields.
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
. (Join-Path $PSScriptRoot 'execution-freeze.ps1')
. (Join-Path $PSScriptRoot 'eval-grading-contract.ps1')

function Write-GradingResultJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)

    Write-RunnerJsonFile -Path $Path -Value $Value
}

try {
    $iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path

    $freezeValidation = Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState
    $manifest = $freezeValidation.Manifest
    $declaredGradingPath = [string](Get-JsonProperty -Object $manifest -Name 'grading' -Default '')
    if ([string]::IsNullOrWhiteSpace($declaredGradingPath) -or $declaredGradingPath -ne $GradingPath) {
        throw "grading path '$GradingPath' does not match manifest.grading '$declaredGradingPath'."
    }
    $bridgeScript = Join-Path $PSScriptRoot 'bridge-manifest-results.ps1'
    if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf)) {
        throw "Package-local manifest bridge is missing at '$bridgeScript'."
    }
    $bridgeOutput = & pwsh -NoProfile -NonInteractive -File $bridgeScript -IterationDirectory $iteration -RequireComplete 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Canonical result validation failed before grading application: $([string]::Join(' ', @($bridgeOutput | ForEach-Object { [string]$_ })))"
    }

    $gradingValidation = Assert-EvalGradingContract -IterationDirectory $iteration -GradingPath $GradingPath
    $records = @($gradingValidation.Records)
    $expected = $gradingValidation.Expected
    $canonicalByKey = $gradingValidation.CanonicalByKey
    $validated = $gradingValidation.Validated

    $updates = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $canonical = $canonicalByKey["$($record.EvalId)|$($record.Configuration)"]
        if (-not (Test-JsonProperty -Object $canonical -Name 'grading')) { throw "Canonical result '$($record.ResultRelative)' is missing its grading array." }
        $newGrading = [System.Collections.Generic.List[object]]::new()
        $assertions = @(Get-EvalMetadataAssertions -Record $record)
        for ($index = 0; $index -lt $assertions.Count; $index++) {
            $entry = $validated["$($record.EvalId)|$($record.Configuration)|$index"]
            $newGrading.Add([ordered]@{ text = [string]$entry.assertion; passed = [bool]$entry.passed; evidence = [string]$entry.evidence })
        }
        $beforeNonGrading = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $canonical -PropertyName 'grading')
        # Keep the parsed canonical values as-is. ConvertFrom-Json reparses
        # ISO timestamp strings into DateTime values and ConvertTo-Json then
        # changes their lexical precision (for example .650Z -> .65Z), which
        # would make a grading-only update look like non-grading tampering.
        $candidate = [ordered]@{}
        foreach ($property in @($canonical.PSObject.Properties)) {
            $candidate[[string]$property.Name] = $property.Value
        }
        $candidate.grading = @($newGrading.ToArray())
        $afterNonGrading = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $candidate -PropertyName 'grading')
        if ($beforeNonGrading -ne $afterNonGrading) {
            throw "Canonical non-grading field changed while applying '$($record.ResultRelative)'."
        }
        $updates.Add([pscustomobject]@{ Path = $record.ResultPath; Before = $canonical; Candidate = $candidate; Changed = (Get-JsonFingerprint -Object $canonical) -ne (Get-JsonFingerprint -Object $candidate) })
    }

    foreach ($update in $updates) {
        if ($update.Changed) { Write-GradingResultJson -Path $update.Path -Value $update.Candidate }
    }
    [void](Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState)
    foreach ($update in $updates) {
        $after = Read-RunnerJson -Path $update.Path
        $beforeFingerprint = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $update.Before -PropertyName 'grading')
        $afterFingerprint = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $after -PropertyName 'grading')
        if ($beforeFingerprint -ne $afterFingerprint) { throw "Canonical non-grading field changed after applying '$($update.Path)'." }
    }

    Write-RunnerJson -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-grading-application/1'
        status = 'applied'
        grading_file = $gradingValidation.GradingFullPath
        canonical_results = $updates.Count
        graded_assertions = $expected.Count
        changed_results = @($updates | Where-Object { $_.Changed }).Count
        execution_freeze = $freezeValidation.Path
    }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
