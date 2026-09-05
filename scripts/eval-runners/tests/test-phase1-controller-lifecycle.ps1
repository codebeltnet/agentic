<#!
.SYNOPSIS
    Deterministic foreground runner-owned Phase 1 lifecycle tests.

.DESCRIPTION
    Exercises the restored runner-owned topology: one foreground
    invoke-runner-owned-arms.ps1 invocation per iteration. The fixture runner
    is model-free and never calls an AI CLI.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'manifest-paths.ps1')
. (Join-Path $runnerRoot 'execution-freeze.ps1')
. (Join-Path $runnerRoot 'package-integrity.ps1')

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

function Write-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Read-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 100
}

function Invoke-ForegroundPhaseOne {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory)

    $fanout = Join-Path $IterationDirectory 'tools/eval-runners/invoke-runner-owned-arms.ps1'
    # STDOUT carries the machine protocol; STDERR carries live observability.
    # Keep them separate so heartbeats never corrupt the terminal JSON.
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('phase1-stderr-' + [Guid]::NewGuid().ToString('N') + '.log')
    try {
        $output = & pwsh -NoProfile -File $fanout -IterationDirectory $IterationDirectory 2>$stderrPath
        $exitCode = $LASTEXITCODE
        $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    $document = $text | ConvertFrom-Json -Depth 100
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; Stderr = $stderr; Document = $document }
}

function New-ForegroundPackage {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [int]$EvalCount = 2,
        [int]$Concurrency = 2
    )

    $tools = Join-Path $IterationDirectory 'tools\eval-runners'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    foreach ($toolItem in @(Get-ChildItem -LiteralPath $runnerRoot -Force | Where-Object { $_.Name -ne 'tests' })) {
        Copy-Item -LiteralPath $toolItem.FullName -Destination $tools -Recurse -Force
    }
    $fixtureRunnerDirectory = Join-Path $tools 'fixture'
    New-Item -ItemType Directory -Path $fixtureRunnerDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runnerRoot 'tests\fixtures\runner-owned-fixture.ps1') -Destination (Join-Path $fixtureRunnerDirectory 'runner.ps1') -Force
    Write-TestJson -Path (Join-Path $IterationDirectory 'execution-profile.json') -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = $Concurrency
    })

    $manifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le $EvalCount; $evalId++) {
        $evalName = 'foreground-eval-{0:d2}' -f $evalId
        $evalDirectory = Join-Path $IterationDirectory $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
        Write-TestJson -Path (Join-Path $evalDirectory 'eval-metadata.json') -Value ([ordered]@{ eval_id = $evalId; eval_name = $evalName; assertions = @('fixture') })
        $runs = [ordered]@{}
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $runDirectory = Join-Path $evalDirectory $configuration
            $repoDirectory = Join-Path $runDirectory 'repo'
            $homeDirectory = Join-Path $runDirectory 'home'
            $resultDirectory = Join-Path $evalDirectory 'results'
            New-Item -ItemType Directory -Path $repoDirectory, $homeDirectory, $resultDirectory -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repoDirectory 'input.txt'), "$evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'prompt.md'), "foreground prompt $evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            $skillDirectory = $null
            $skillHash = $null
            if ($configuration -eq 'with_skill') {
                $skillDirectory = 'skill/candidate'
                New-Item -ItemType Directory -Path (Join-Path $runDirectory 'skill\candidate') -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $runDirectory 'skill\candidate\SKILL.md'), '# fixture', [System.Text.UTF8Encoding]::new($false))
                $skillHash = ('b' * 64)
            }
            Write-TestJson -Path (Join-Path $runDirectory 'run.json') -Value ([ordered]@{
                schema = (Get-RunnerSchemaNames).Run
                evalId = $evalId
                evalName = $evalName
                skillName = if ($configuration -eq 'with_skill') { 'candidate' } else { $null }
                iteration = 1
                mode = $configuration
                promptFile = 'prompt.md'
                workingDirectory = 'repo'
                homeDirectory = 'home'
                skillDirectory = $skillDirectory
                freshContextRequired = $true
                filesystemIsolationRequired = $true
                isolatedHomeRequired = $true
                fixtureHash = ('a' * 64)
                skillHash = $skillHash
            })
            $resultName = if ($configuration -eq 'with_skill') { 'with-skill.result.json' } else { 'without-skill.result.json' }
            $executionName = if ($configuration -eq 'with_skill') { 'with-skill.execution-result.json' } else { 'without-skill.execution-result.json' }
            Write-TestJson -Path (Join-Path $resultDirectory $resultName) -Value ([ordered]@{ eval_id = $evalId; configuration = $configuration; execution_status = 'unrun' })
            $runs[$configuration] = [ordered]@{
                mode = $configuration
                run_manifest = "$evalName/$configuration/run.json"
                execution_result = "$evalName/results/$executionName"
                result = "$evalName/results/$resultName"
            }
        }
        $manifestEvals.Add([ordered]@{ eval_id = $evalId; eval_name = $evalName; directory = $evalName; metadata = "$evalName/eval-metadata.json"; runs = $runs })
    }

    $toolIntegrity = Get-PackageTreeIntegrity -Root $tools
    Write-TestJson -Path (Join-Path $IterationDirectory 'manifest.json') -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_selection = [ordered]@{
            harness = 'Deterministic runner-owned fixture'
            runner = 'fixture'
            model = 'fixture-model'
            preset = 'Phase 1 lifecycle fixture'
        }
        execution_profile = 'execution-profile.json'
        runner_tools = 'tools/eval-runners'
        runner_tools_integrity = [ordered]@{ schema = 'codebeltnet/agentic/package-tree-integrity/1'; path = 'tools/eval-runners'; sha256 = $toolIntegrity.Sha256; file_count = $toolIntegrity.FileCount }
        execution_freeze = 'execution-freeze.json'
        evals = @($manifestEvals.ToArray())
    })

    return [pscustomobject]@{
        IterationDirectory = $IterationDirectory
        Tools = $tools
        LogPath = Join-Path $IterationDirectory 'fixture-events.jsonl'
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-foreground-phase1-' + [Guid]::NewGuid().ToString('N'))
$oldFixtureLogPath = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG')
try {
    $success = New-ForegroundPackage -IterationDirectory (Join-Path $testRoot 'success') -EvalCount 2 -Concurrency 2
    foreach ($obsolete in @('phase1-control-common.ps1', 'control-runner-owned-phase1.ps1', 'supervise-runner-owned-phase1.ps1')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $success.Tools $obsolete) -PathType Leaf)) "foreground package does not carry obsolete $obsolete"
    }
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $success.LogPath)
    $first = Invoke-ForegroundPhaseOne -IterationDirectory $success.IterationDirectory
    Assert-Equal 0 $first.ExitCode 'foreground Phase 1 exits successfully'
    Assert-Equal 'phase1' ([string]$first.Document.phase) 'foreground Phase 1 returns the fan-out summary directly'
    Assert-Equal 'completed' ([string]$first.Document.status) 'foreground Phase 1 completes'
    Assert-Equal 4 ([int]$first.Document.expected_count) 'foreground Phase 1 sees four paired arms'
    Assert-Equal 4 ([int]$first.Document.terminal_count) 'foreground Phase 1 registers every arm terminal'
    Assert-Equal 4 ([int]$first.Document.execution_count) 'foreground Phase 1 executes every compatible arm'
    Assert-True ([int]$first.Document.max_observed_active -gt 1) 'foreground Phase 1 honors requested concurrency when capacity permits'
    Assert-True (Test-Path -LiteralPath (Join-Path $success.IterationDirectory 'execution-freeze.json') -PathType Leaf) 'foreground Phase 1 writes execution-freeze.json only after terminal arms'
    $freeze = Assert-ExecutionFreeze -IterationDirectory $success.IterationDirectory -RequireOrchestrationState
    Assert-True ([bool]$freeze.PhaseOneSuccess) 'foreground Phase 1 freeze validates as successful'
    Assert-Equal 4 @($freeze.Freeze.executions).Count 'foreground Phase 1 freeze contains every expected arm'
    $events = @(Get-Content -LiteralPath $success.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal 8 $events.Count 'foreground Phase 1 invokes each preflight and execution exactly once'
    Assert-Equal 4 @($events | Where-Object { $_.kind -eq 'preflight' }).Count 'foreground Phase 1 preflights every arm'
    Assert-Equal 4 @($events | Where-Object { $_.kind -eq 'execute' }).Count 'foreground Phase 1 executes every compatible arm'
    $firstExecuteIndex = -1
    $lastPreflightIndex = -1
    for ($index = 0; $index -lt $events.Count; $index++) {
        if ($events[$index].kind -eq 'preflight') { $lastPreflightIndex = $index }
        if ($events[$index].kind -eq 'execute' -and $firstExecuteIndex -lt 0) { $firstExecuteIndex = $index }
    }
    Assert-True ($firstExecuteIndex -gt $lastPreflightIndex) 'foreground Phase 1 starts zero executions before all preflights pass'

    $second = Invoke-ForegroundPhaseOne -IterationDirectory $success.IterationDirectory
    Assert-Equal 2 $second.ExitCode 'foreground Phase 1 refuses a second invocation after freeze'
    Assert-True ([string]$second.Document.error -match 'already frozen|existing orchestration state') 'foreground Phase 1 reports why rerun is refused'
    $eventsAfterSecond = @(Get-Content -LiteralPath $success.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal 4 @($eventsAfterSecond | Where-Object { $_.kind -eq 'execute' }).Count 'foreground Phase 1 rerun starts zero additional executions'

    $interrupted = Join-Path $testRoot 'interrupted'
    Copy-Item -LiteralPath $success.IterationDirectory -Destination $interrupted -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $interrupted 'execution-freeze.json') -Force
    foreach ($raw in @(Get-ChildItem -LiteralPath $interrupted -Recurse -File -Filter '*.execution-result.json')) {
        Remove-Item -LiteralPath $raw.FullName -Force
    }
    $interruptedLog = Join-Path $interrupted 'new-events.jsonl'
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $interruptedLog)
    $interruptedResult = Invoke-ForegroundPhaseOne -IterationDirectory $interrupted
    Assert-Equal 2 $interruptedResult.ExitCode 'foreground Phase 1 fails closed on interrupted state without a freeze'
    Assert-True ([string]$interruptedResult.Document.error -match 'refuses to replace an existing orchestration state') 'foreground Phase 1 does not adopt or rerun incomplete state'
    Assert-True (-not (Test-Path -LiteralPath $interruptedLog -PathType Leaf)) 'foreground Phase 1 interrupted-state refusal starts zero executions'

    $preflightGate = New-ForegroundPackage -IterationDirectory (Join-Path $testRoot 'preflight-gate') -EvalCount 2 -Concurrency 2
    [System.IO.File]::WriteAllText((Join-Path $preflightGate.IterationDirectory 'foreground-eval-02\with_skill\home\preflight-incompatible'), 'fixture', [System.Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $preflightGate.LogPath)
    $gate = Invoke-ForegroundPhaseOne -IterationDirectory $preflightGate.IterationDirectory
    Assert-Equal 2 $gate.ExitCode 'foreground Phase 1 exits non-zero for incompatible preflight'
    Assert-Equal 'preflight' ([string]$gate.Document.phase) 'foreground Phase 1 reports preflight phase failure'
    Assert-Equal 'preflight_incompatible' ([string]$gate.Document.status) 'foreground Phase 1 reports incompatible preflight'
    Assert-Equal 4 ([int]$gate.Document.preflight_count) 'foreground Phase 1 still probes every arm'
    Assert-True (-not [bool]$gate.Document.execution_started) 'foreground Phase 1 starts zero executions when any preflight is incompatible'
    $gateEvents = @(Get-Content -LiteralPath $preflightGate.LogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal 4 @($gateEvents | Where-Object { $_.kind -eq 'preflight' }).Count 'foreground Phase 1 preflight gate records every preflight'
    Assert-Equal 0 @($gateEvents | Where-Object { $_.kind -eq 'execute' }).Count 'foreground Phase 1 preflight gate records zero executions'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $preflightGate.IterationDirectory 'execution-freeze.json') -PathType Leaf)) 'foreground Phase 1 writes no freeze before a failed preflight gate'

    $fanoutText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'invoke-runner-owned-arms.ps1'), [System.Text.UTF8Encoding]::new($false))
    Assert-True ($fanoutText -notmatch '(?i)Job Object|breakaway|process ancestry|supervisor independence|phase1-control-common|AGENTIC_PHASE1_SUPERVISOR_ID') 'foreground Phase 1 has no Windows host-security/durable-detachment requirement'

    Write-Output 'Runner-owned foreground Phase 1 lifecycle: PASS'
} finally {
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $oldFixtureLogPath)
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
