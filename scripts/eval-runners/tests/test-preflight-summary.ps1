<#!
.SYNOPSIS
    Deterministic, model-free unit tests for the preflight raw-output boundary.

.DESCRIPTION
    Proves that New-PreflightWorkerSummary never copies raw child process output
    (Stderr, Stdout, or ParseError exception text) into operator-facing reasons
    or summaries. All tests are model-free, network-free, and authentication-free.
    They test the function directly without invoking any child process.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'preflight-summary.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        throw "ASSERT: $Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-NotContains {
    param([string]$Haystack, [string]$Needle, [string]$Message)
    if ($Haystack.Contains($Needle)) {
        throw "ASSERT: $Message (found '$Needle' in output)"
    }
}

function New-TestRecord {
    param([int]$EvalId = 1, [string]$Configuration = 'with_skill')
    return [pscustomobject]@{
        EvalId = $EvalId
        EvalName = "test-eval-$EvalId"
        Configuration = $Configuration
        RunManifestRelative = "$Configuration/run.json"
        ExecutionResultRelative = "results/$Configuration.execution-result.json"
    }
}

function New-CompatibleDescriptor {
    return [ordered]@{
        name = 'test-runner'
        delegation = [ordered]@{
            dispatch_owner = 'runner'
            mode = 'native_worker'
            nested_model_execution = $false
        }
        capabilities = [ordered]@{}
    }
}

function New-CompatiblePreflightResult {
    return [ordered]@{
        status = 'compatible'
        delegation = [ordered]@{
            status = 'supported'
            unproven_controls = @()
        }
        resolved_capabilities = [ordered]@{
            native_worker_delegation = 'supported'
            delegated_worker_full_capability = 'supported'
            delegated_worker_model_lock = 'supported'
            delegated_worker_working_directory = 'supported'
            delegated_worker_result_capture = 'supported'
            delegated_worker_capacity_signal = 'supported'
        }
        checks = @()
        reasons = @()
    }
}

function New-IncompatiblePreflightResult {
    return [ordered]@{
        status = 'incompatible'
        delegation = [ordered]@{
            status = 'unsupported'
            unproven_controls = @('network')
        }
        resolved_capabilities = [ordered]@{}
        checks = @()
        reasons = @('runner rejected the run')
    }
}

function New-Invocation {
    param(
        [string]$Stdout = '',
        [string]$Stderr = '',
        [string]$ParseError = '',
        [object]$ExitCode = 0,
        [bool]$TimedOut = $false,
        [bool]$TerminationObserved = $true
    )

    # Simulate what Invoke-RunnerPreflight does: attempt to parse Stdout as JSON.
    # If a ParseError is pre-supplied by the test, simulate a parse failure
    # (result stays $null) without actually catching an exception.
    $result = $null
    if (-not [string]::IsNullOrWhiteSpace($Stdout) -and [string]::IsNullOrWhiteSpace($ParseError)) {
        try { $result = $Stdout | ConvertFrom-Json -Depth 100 } catch { }
    }
    return [pscustomobject]@{
        Result = $result
        ExitCode = $ExitCode
        Stdout = $Stdout
        Stderr = $Stderr
        ParseError = $ParseError
        TimedOut = $TimedOut
        TerminationObserved = $TerminationObserved
    }
}

function Get-SummaryReasonsText {
    param([object]$Summary)
    return [string]::Join(' ', @($Summary.reasons | ForEach-Object { [string]$_ }))
}

$descriptor = New-CompatibleDescriptor

# ------------------------------------------------------------------
# Test 1 - STDERR secret isolation: a failed preflight whose STDERR carries a
# secret-like marker must not expose that marker in the summary or reasons.
# ------------------------------------------------------------------
$secret1 = 'PREFLIGHT_SECRET_MARKER_' + [Guid]::NewGuid().ToString('N')
$invocationWithSecret = New-Invocation -Stdout '' -Stderr "AUTH_TOKEN=$secret1 unexpected error occurred" -ExitCode 1 -TerminationObserved $true
$summaryWithSecret = New-PreflightWorkerSummary -Record (New-TestRecord) -Invocation $invocationWithSecret -Descriptor $descriptor
$reasonsText1 = Get-SummaryReasonsText -Summary $summaryWithSecret
Assert-Equal 'incompatible' ([string]$summaryWithSecret.status) 'Test 1: summary is incompatible when preflight STDERR has a secret'
Assert-NotContains -Haystack ($summaryWithSecret | ConvertTo-Json -Depth 20 -Compress) -Needle $secret1 'Test 1: secret from STDERR must not appear anywhere in summary JSON'
Assert-NotContains -Haystack $reasonsText1 -Needle $secret1 'Test 1: secret from STDERR must not appear in reasons text'
Assert-True ($summaryWithSecret.reasons.Count -gt 0) 'Test 1: at least one reason is still reported for a failed preflight'
Assert-True ($reasonsText1 -match 'exited with status 1') 'Test 1: exit status is reported as a safe structural fact'

# ------------------------------------------------------------------
# Test 2 - STDOUT isolation: arbitrary child STDOUT must not be copied into
# the summary or reasons, even when STDOUT contains model-like content.
# ------------------------------------------------------------------
$marker2 = 'STDOUT_MODEL_OUTPUT_MARKER_' + [Guid]::NewGuid().ToString('N')
$invocationWithStdout = New-Invocation -Stdout "not valid json $marker2 here" -Stderr '' -ParseError 'unexpected token' -ExitCode 0 -TerminationObserved $true
$summaryWithStdout = New-PreflightWorkerSummary -Record (New-TestRecord) -Invocation $invocationWithStdout -Descriptor $descriptor
$reasonsText2 = Get-SummaryReasonsText -Summary $summaryWithStdout
Assert-Equal 'incompatible' ([string]$summaryWithStdout.status) 'Test 2: summary is incompatible when STDOUT cannot be parsed'
Assert-NotContains -Haystack ($summaryWithStdout | ConvertTo-Json -Depth 20 -Compress) -Needle $marker2 'Test 2: STDOUT content must not appear anywhere in summary JSON'
Assert-NotContains -Haystack $reasonsText2 -Needle $marker2 'Test 2: STDOUT content must not appear in reasons text'
Assert-True ($summaryWithStdout.reasons.Count -gt 0) 'Test 2: at least one reason is still reported for a failed parse'

# ------------------------------------------------------------------
# Test 3 - ParseError isolation: exception text from a JSON parse failure must
# not escape into operator-facing reasons. The exception may contain fragments
# of the malformed child output.
# ------------------------------------------------------------------
$marker3 = 'JSON_PARSE_EXCEPTION_MARKER_' + [Guid]::NewGuid().ToString('N')
$invocationBadJson = New-Invocation -Stdout "partial json fragment $marker3" -Stderr '' -ParseError "Unexpected character at position 7: $marker3 ..." -ExitCode 0 -TerminationObserved $true
$summaryBadJson = New-PreflightWorkerSummary -Record (New-TestRecord) -Invocation $invocationBadJson -Descriptor $descriptor
$reasonsText3 = Get-SummaryReasonsText -Summary $summaryBadJson
Assert-Equal 'incompatible' ([string]$summaryBadJson.status) 'Test 3: summary is incompatible when JSON parse fails'
Assert-NotContains -Haystack ($summaryBadJson | ConvertTo-Json -Depth 20 -Compress) -Needle $marker3 'Test 3: ParseError exception text must not appear anywhere in summary JSON'
Assert-NotContains -Haystack $reasonsText3 -Needle $marker3 'Test 3: ParseError exception text must not appear in reasons text'
Assert-True (@($summaryBadJson.reasons | Where-Object { [string]$_ -eq 'runner preflight returned invalid JSON.' }).Count -ge 1) 'Test 3: reason uses the stable "invalid JSON" classification'

# ------------------------------------------------------------------
# Test 4 - Useful structured facts: the safe failure reason must still carry
# actionable structural information (failure class, exit status).
# ------------------------------------------------------------------
$invocationNonZeroExit = New-Invocation -Stdout '' -Stderr 'internal error' -ExitCode 42 -TerminationObserved $true
$summaryNonZeroExit = New-PreflightWorkerSummary -Record (New-TestRecord) -Invocation $invocationNonZeroExit -Descriptor $descriptor
$reasonsText4 = Get-SummaryReasonsText -Summary $summaryNonZeroExit
Assert-Equal 42 ([int]$summaryNonZeroExit.runner_exit_code) 'Test 4: exit code is preserved as a structured field'
Assert-True ($reasonsText4 -match 'exited with status 42') 'Test 4: exit status is included in the structural reason'
Assert-True ($reasonsText4 -match 'no JSON result') 'Test 4: failure class (no JSON) is included in the reason'
Assert-True (-not $reasonsText4.Contains('internal error')) 'Test 4: raw STDERR content is excluded from the reason'

$invocationUnknownExit = New-Invocation -Stdout '' -Stderr 'crash' -ExitCode $null -TerminationObserved $true
$summaryUnknownExit = New-PreflightWorkerSummary -Record (New-TestRecord) -Invocation $invocationUnknownExit -Descriptor $descriptor
$reasonsText4b = Get-SummaryReasonsText -Summary $summaryUnknownExit
Assert-True ($reasonsText4b -match 'exited with status unknown') 'Test 4b: unknown exit code is reported as unknown (not null or empty)'
Assert-True (-not $reasonsText4b.Contains('crash')) 'Test 4b: raw STDERR crash text is excluded from the reason'

# ------------------------------------------------------------------
# Test 5 - Compatible preflight: a successful preflight with valid JSON is
# unaffected. The summary reports compatible, reasons remain empty.
# ------------------------------------------------------------------
$compatibleResult = New-CompatiblePreflightResult
$invocationCompatible = New-Invocation -Stdout '' -Stderr '' -ExitCode 0 -TerminationObserved $true
$invocationCompatible.Result = $compatibleResult
$summaryCompatible = New-PreflightWorkerSummary -Record (New-TestRecord) -Invocation $invocationCompatible -Descriptor $descriptor
Assert-Equal 'compatible' ([string]$summaryCompatible.status) 'Test 5: valid compatible preflight yields compatible summary'
Assert-Equal 0 $summaryCompatible.reasons.Count 'Test 5: compatible preflight has no reasons'
Assert-Equal 0 ([int]$summaryCompatible.runner_exit_code) 'Test 5: exit code is preserved for compatible preflight'

# The runner-provided reasons from an incompatible preflight (not raw output)
# are still forwarded, because they come from the structured JSON result.
$invocationIncompatible = New-Invocation -Stdout '' -Stderr '' -ExitCode 0 -TerminationObserved $true
$invocationIncompatible.Result = (New-IncompatiblePreflightResult)  # set parsed result directly
$summaryIncompatible = New-PreflightWorkerSummary -Record (New-TestRecord) -Invocation $invocationIncompatible -Descriptor $descriptor
Assert-Equal 'incompatible' ([string]$summaryIncompatible.status) 'Test 5b: runner-provided incompatible status is preserved'
Assert-True (@($summaryIncompatible.reasons | Where-Object { [string]$_ -eq 'runner rejected the run' }).Count -ge 1) 'Test 5b: runner-provided structured reasons are forwarded'

Write-Output 'Preflight raw-output boundary: PASS'
