<#
.SYNOPSIS
    Regression: OpenCode timed-out interaction evidence accepted as honest terminal result.
.DESCRIPTION
    MODEL-FREE deterministic check using synthetic opencode-style execution evidence.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'orchestration.ps1')

function Assert-True { param([bool]$c,[string]$m) if (-not $c) { throw "ASSERT: $m" } }
function Assert-Equal { param($e,$a,$m) if ([string]$e -ne [string]$a) { throw "ASSERT: $m (expected '$e', got '$a')" } }

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-opencode-tmo-' + [Guid]::NewGuid().ToString('N'))
$iteration = Join-Path $testRoot 'iteration-1'
New-Item -ItemType Directory -Path $iteration -Force | Out-Null

# single eval/arm
$evalName = 'eval-01'
$evalDirectory = Join-Path $iteration $evalName
New-Item -ItemType Directory -Path (Join-Path $evalDirectory 'with_skill') -Force | Out-Null
# run manifest
$runPath = Join-Path $evalDirectory 'with_skill'
$runJson = [ordered]@{ schema = (Get-RunnerSchemaNames).Run; evalId = 1; evalName = $evalName; mode = 'with_skill'; promptFile = 'prompt.md'; workingDirectory = 'repo'; homeDirectory = 'home'; freshContextRequired = $true; filesystemIsolationRequired = $true; isolatedHomeRequired = $true; fixtureHash = ('a' * 64); skillHash = ('b' * 64) }
[System.IO.File]::WriteAllText((Join-Path $runPath 'run.json'), ($runJson | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Join-Path $runPath 'repo') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runPath 'home') -Force | Out-Null
# results and metadata
$resultsDir = Join-Path $evalDirectory 'results'
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $resultsDir 'with_skill.result.json'), (([ordered]@{ eval_id = 1; configuration = 'with_skill'; execution_status = 'unrun'; grading = @() }) | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $evalDirectory 'eval-metadata.json'), (([ordered]@{ eval_id = 1; eval_name = $evalName; assertions = @('assertion') }) | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))

$manifest = [ordered]@{ schema = (Get-RunnerSchemaNames).OrchestrationPlan; configurations = @('with_skill'); execution_freeze = 'execution-freeze.json'; evals = @([ordered]@{ eval_id = 1; eval_name = $evalName; directory = $evalName; metadata = "$evalName/eval-metadata.json"; runs = [ordered]@{ with_skill = [ordered]@{ mode = 'with_skill'; run_manifest = "$evalName/with_skill/run.json"; execution_result = "$evalName/results/with_skill.execution-result.json"; result = "$evalName/results/with_skill.result.json" } } }) }

$profile = [ordered]@{ schema = (Get-RunnerSchemaNames).Profile; runner = 'opencode'; model = 'opencode/muse-spark-1.2-contributor-free'; configuration_profile = 'isolated-default'; tool_profile = 'default'; timeout_seconds = 900; concurrency = 1 }

$plan = New-EvalOrchestrationPlan -IterationDirectory $iteration -Manifest $manifest -Profile $profile
$state = New-OrchestrationState -Plan $plan

# accept the single worker
$dispatches = @(Get-NextWorkerDispatches -Plan $plan -State $state)
[void](Register-DelegationAccepted -State $state -WorkerId $dispatches[0].worker_id -WorkerSessionId ('sess-' + $dispatches[0].worker_id))

# craft opencode-style timed_out execution evidence
$workerId = $dispatches[0].worker_id
$execEvidence = [ordered]@{
    status = 'timed_out'
    session = [ordered]@{ id = ('opencode-session-' + $workerId); fresh = $true; resumed = $false }
    run = [ordered]@{ eval_id = 1; eval_name = $evalName; configuration = 'with_skill' }
    requested = [ordered]@{ model = $profile.model }
    input = [ordered]@{ prompt_sha256 = ('a' * 64) }
    evidence = [ordered]@{
        delegation = [ordered]@{
            mechanism = 'opencode-native'
            worker_session_id = ('opencode-session-' + $workerId)
            observed_model = $profile.model
            observed_working_directory = (Join-Path $runPath 'repo')
            observed_home = (Join-Path $runPath 'home')
            fresh_worker = $true
            home_config_isolated = $true
            # No terminal_result_capture because timed out before assistant response
            terminal_result_capture = $false
            # include HTTP timeout metadata
            http = [ordered]@{ request_start_utc = (Get-Date).ToUniversalTime().ToString('o'); timeout_utc = (Get-Date).AddSeconds(30).ToUniversalTime().ToString('o'); classification = 'request_timeout' }
            terminal_event = [ordered]@{ type = 'timeout'; reason = 'request_timeout' }
        }
        execution_paths = [ordered]@{ logical_working_directory = (Join-Path $runPath 'repo'); logical_home_directory = (Join-Path $runPath 'home') }
    }
}

# Register terminal; orchestration should preserve raw 'timed_out' and record evidence_validation failed
[void](Register-WorkerTerminal -Plan $plan -State $state -WorkerId $workerId -ExecutionEvidence $execEvidence)
$ledger = $state.completed[$workerId]
Assert-Equal 'timed_out' $ledger.status 'ledger must preserve raw timed_out status'
$ev = Get-JsonProperty -Object $ledger -Name 'evidence_validation' -Default $null
Assert-Equal 'failed' $ev.status 'evidence_validation should be recorded as failed for a timed_out (no terminal capture)'

Write-Output 'OPENCODE TIMED-OUT REGRESSION: PASS'