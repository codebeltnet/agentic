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

    [switch]$RequireNativeDelegation
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'manifest-paths.ps1')

try {
    $iterationPath = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    $manifestPath = Join-Path $iterationPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Prepared iteration is missing manifest.json at '$iterationPath'."
    }

    $manifest = Read-RunnerJson -Path $manifestPath
    $records = @(Get-ManifestRunRecords -IterationDirectory $iterationPath -Manifest $manifest)
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

        $alreadyBridged = $false
        try {
            $existingResult = Read-RunnerJson -Path $record.ResultPath
            $rawResult = Read-RunnerJson -Path $record.ExecutionResultPath
            $expectedExecutionFile = [System.IO.Path]::GetRelativePath($record.EvalDirectory, $record.ExecutionResultPath).Replace('\', '/')
            $nativeEvidenceReady = -not $RequireNativeDelegation -or [string](Get-JsonProperty -Object $rawResult -Name 'status' -Default '') -eq 'incompatible'
            if ($RequireNativeDelegation -and -not $nativeEvidenceReady) {
                try {
                    $runData = Resolve-RunContract -RunPath $record.RunManifestPath
                    $profileData = Resolve-ExecutionProfile -ProfilePath (Join-Path $iterationPath 'execution-profile.json')
                    [void](Assert-NativeWorkerTerminalEvidence -ExecutionEvidence $rawResult -Run $runData -RequestedModel ([string]$profileData.Profile.Model))
                    $nativeEvidenceReady = $true
                } catch {
                    $nativeEvidenceReady = $false
                }
            }
            $alreadyBridged = $nativeEvidenceReady -and
                @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible') -contains [string](Get-JsonProperty -Object $rawResult -Name 'status' -Default '') -and
                [string](Get-JsonProperty -Object $existingResult -Name 'execution_status' -Default '') -eq [string](Get-JsonProperty -Object $rawResult -Name 'status' -Default '') -and
                [string](Get-JsonProperty -Object $existingResult -Name 'execution_result_file' -Default '') -eq $expectedExecutionFile -and
                -not [string]::IsNullOrWhiteSpace([string](Get-JsonProperty -Object $existingResult -Name 'execution_run_id' -Default ''))
        } catch {
            $alreadyBridged = $false
        }

        if ($alreadyBridged) {
            $bridged.Add("$($record.EvalName)/$($record.Configuration)")
            continue
        }

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
        warnings = @($validation.Warnings)
    }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
