param(
    [Parameter(Mandatory = $true)]
    [string]$ContextPath,

    [Parameter(Mandatory = $true)]
    [string]$TranscriptPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputsPath,

    [Parameter(Mandatory = $true)]
    [string]$TimingPath,

    [Parameter(Mandatory = $true)]
    [string]$GradingPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json
$timing = Get-Content -LiteralPath $TimingPath -Raw | ConvertFrom-Json
$timedOut = [bool]$timing.cleanup.timedOut
$exitCode = [int]$timing.executor.exitCode
$failed = $timedOut -or $exitCode -ne 0

$expectations = foreach ($expectation in @($context.expectations)) {
    [ordered]@{
        text = $expectation
        passed = -not $failed
        evidence = if ($timedOut) {
            'The mock executor timed out and the runner produced fallback artifacts.'
        } elseif ($exitCode -ne 0) {
            "The mock executor exited with code $exitCode."
        } else {
            'The mock executor completed and the outputs were generated.'
        }
    }
}

$passed = @($expectations | Where-Object passed).Count
$total = @($expectations).Count

[ordered]@{
    expectations = @($expectations)
    summary = [ordered]@{
        passed = $passed
        failed = $total - $passed
        total = $total
        pass_rate = if ($total -eq 0) { 0 } else { [math]::Round($passed / $total, 4) }
    }
    execution_metrics = [ordered]@{
        tool_calls = @{}
        total_tool_calls = 0
        total_steps = 1
        errors_encountered = if ($failed) { 1 } else { 0 }
        output_chars = 0
        transcript_chars = (Get-Content -LiteralPath $TranscriptPath -Raw).Length
    }
    timing = $timing
    claims = @()
    user_notes_summary = [ordered]@{
        uncertainties = @()
        needs_review = @()
        workarounds = @()
    }
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $GradingPath -Encoding utf8
