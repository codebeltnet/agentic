Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-Json {
    param([string]$Path, $Value)
    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Write-Text {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('skill-benchmark-test-' + [Guid]::NewGuid().ToString('N'))
$skillRoot = Join-Path $workspace 'mock-skill'

try {
    New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
    Write-Text -Path (Join-Path $skillRoot 'SKILL.md') -Content @"
---
name: mock-benchmark-skill
description: >
  Mock benchmark skill for runner self-tests.
---

Answer mock tasks.
"@
    Write-Json -Path (Join-Path $skillRoot 'evals\evals.json') -Value ([ordered]@{
        skill_name = 'mock-benchmark-skill'
        evals = @(
            [ordered]@{
                id = 1
                prompt = 'Mock success prompt.'
                expected_output = 'A successful run.'
                expectations = @('The mock run succeeds')
                files = @('evals/files/eval-1/src/Seed.cs')
            }
            [ordered]@{
                id = 2
                prompt = 'Mock timeout prompt.'
                expected_output = 'A failed or timed out run still produces artifacts.'
                expectations = @('The mock run handles failure safely')
                files = @('evals/files/eval-2/src/Seed.cs')
            }
        )
    })
    Write-Text -Path (Join-Path $skillRoot 'evals\files\eval-1\src\Seed.cs') -Content 'public static class Seed { }'
    Write-Text -Path (Join-Path $skillRoot 'evals\files\eval-2\src\Seed.cs') -Content 'public static class Seed { }'

    $benchmarkScript = Join-Path $repoRoot 'scripts\run-skill-benchmark.ps1'
    $executor = Join-Path $repoRoot 'scripts\skill-benchmark\mock-executor.ps1'
    $grader = Join-Path $repoRoot 'scripts\skill-benchmark\mock-grader.ps1'

    & pwsh -NoProfile -File $benchmarkScript `
        -SkillPath $skillRoot `
        -WorkspaceRoot (Join-Path $workspace 'benchmark') `
        -ExecutorCommand $executor `
        -GraderCommand $grader `
        -MaxParallel 2 `
        -MaxGradeParallel 2 `
        -RunTimeoutSeconds 30 `
        -GradeTimeoutSeconds 30 `
        -Model 'gpt-5.4-mini' `
        -CompareWithLegacy

    if ($LASTEXITCODE -ne 0) {
        throw "Benchmark runner exited with code $LASTEXITCODE."
    }

    $summaryPath = Join-Path $workspace 'benchmark\iteration-optimized\runner-summary.json'
    $benchmarkPath = Join-Path $workspace 'benchmark\iteration-optimized\benchmark.json'
    $reviewPath = Join-Path $workspace 'benchmark\review-optimized.html'
    $comparisonPath = Join-Path $workspace 'benchmark\comparison.json'

    foreach ($required in @($summaryPath, $benchmarkPath, $reviewPath, $comparisonPath)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Missing required benchmark artifact: $required"
        }
    }

    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ($summary.maxConcurrentExecutorsObserved -gt 2) {
        throw "Bounded concurrency failed. Expected at most 2 active executors, found $($summary.maxConcurrentExecutorsObserved)."
    }
    if ($summary.timedOutRuns -ne 1) {
        throw "Expected one timed out run, found $($summary.timedOutRuns)."
    }
    if ($summary.cleanupFailures -ne 0) {
        throw "Expected zero cleanup failures, found $($summary.cleanupFailures)."
    }

    $timeoutRunRoot = Join-Path $workspace 'benchmark\iteration-optimized\eval-02-mock-timeout-prompt\with_skill\run-1'
    $childPidPath = Join-Path $timeoutRunRoot 'outputs\child.pid'
    if (-not (Test-Path -LiteralPath $childPidPath)) {
        throw 'Mock timeout run did not write child.pid.'
    }
    $childPid = [int]((Get-Content -LiteralPath $childPidPath -Raw).Trim())
    if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) {
        throw "Timed-out child process $childPid is still running."
    }

    foreach ($runDir in Get-ChildItem -LiteralPath (Join-Path $workspace 'benchmark\iteration-optimized') -Directory | Where-Object { $_.Name -like 'eval-*' } | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -Recurse | Where-Object { $_.Name -eq 'run-1' } }) {
        foreach ($artifact in @('transcript.md', 'result-summary.md', 'grading.json', 'timing.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $runDir.FullName $artifact))) {
                throw "Missing $artifact in $($runDir.FullName)."
            }
        }
    }

    $benchmark = Get-Content -LiteralPath $benchmarkPath -Raw | ConvertFrom-Json
    $failedRun = @($benchmark.runs | Where-Object { $_.configuration -eq 'without_skill' -and $_.eval_id -eq 2 })[0]
    if ($null -eq $failedRun) {
        throw 'Missing failed run in benchmark aggregation.'
    }
    if ($failedRun.result.pass_rate -ne 0) {
        throw "Expected failed run pass rate 0, found $($failedRun.result.pass_rate)."
    }

    Write-Output 'run-skill-benchmark.ps1 self-test: PASS'
} finally {
    if (Test-Path -LiteralPath $workspace) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}
