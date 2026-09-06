<#
.SYNOPSIS
    Regression: mixed-terminal fan-out preserves raw statuses and records evidence_validation separately.
.DESCRIPTION
    MODEL-FREE deterministic check. Does not execute any model.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'orchestration.ps1')

function Assert-True { param([bool]$c,[string]$m) if (-not $c) { throw "ASSERT: $m" } }
function Assert-Equal { param($e,$a,$m) if ([string]$e -ne [string]$a) { throw "ASSERT: $m (expected '$e', got '$a')" } }

function New-TestNativeTerminalEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Arm,
        [Parameter(Mandatory = $true)][object]$RunData,
        [Parameter(Mandatory = $true)][string]$WorkerSessionId
    )

    return [ordered]@{
        status = 'completed'
        session = [ordered]@{ id = $WorkerSessionId; fresh = $true; resumed = $false }
        run = [ordered]@{ eval_id = [int]$Arm.eval_id; eval_name = [string]$Arm.eval_name; configuration = [string]$Arm.configuration }
        requested = [ordered]@{ model = [string]$Arm.worker.model }
        input = [ordered]@{ prompt_sha256 = [string]$RunData.PromptHash }
        evidence = [ordered]@{
            delegation = [ordered]@{
                mechanism = 'deterministic-fake-native-worker'
                worker_session_id = $WorkerSessionId
                observed_model = [string]$Arm.worker.model
                observed_working_directory = [string]$RunData.WorkingDirectoryPath
                observed_home = [string]$RunData.HomeDirectoryPath
                fresh_worker = $true
                home_config_isolated = $true
                prompt_fidelity = $true
                prompt_sha256 = [string]$RunData.PromptHash
                terminal_result_capture = $true
                paired_arm_visible = $false
                grading_material_visible = $false
                nested_model_execution = $false
                model_execution_count = 1
            }
        }
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-mixed-terminal-' + [Guid]::NewGuid().ToString('N'))
$iteration = Join-Path $testRoot 'iteration-1'
New-Item -ItemType Directory -Path $iteration -Force | Out-Null

# Create 4 eval arms
$manifestEvals = [System.Collections.Generic.List[object]]::new()
for ($evalId = 1; $evalId -le 4; $evalId++) {
    $evalName = 'eval-{0:d2}' -f $evalId
    $evalDirectory = Join-Path $iteration $evalName
    New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $evalDirectory 'with_skill') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $evalDirectory 'without_skill') -Force | Out-Null
    Write-Output "prepared $evalName"
    $runs = [ordered]@{}
    foreach ($configuration in @('with_skill','without_skill')) {
        $runPath = Join-Path $evalDirectory $configuration
        New-Item -ItemType Directory -Path $runPath -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runPath 'repo') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $runPath 'home') -Force | Out-Null
        if ($configuration -eq 'with_skill') {
            New-Item -ItemType Directory -Path (Join-Path $runPath 'skill') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path (Join-Path $runPath 'skill') 'SKILL.md'), '# deterministic terminal test skill', [System.Text.UTF8Encoding]::new($false))
        }
        [System.IO.File]::WriteAllText((Join-Path $runPath 'prompt.md'), "terminal test prompt for $evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
        $runJson = [ordered]@{
            schema = (Get-RunnerSchemaNames).Run
            evalId = $evalId
            evalName = $evalName
            candidateSkillName = 'candidate'
            skillName = if ($configuration -eq 'with_skill') { 'candidate' } else { $null }
            mode = $configuration
            promptFile = 'prompt.md'
            workingDirectory = 'repo'
            homeDirectory = 'home'
            skillDirectory = if ($configuration -eq 'with_skill') { 'skill' } else { $null }
            freshContextRequired = $true
            filesystemIsolationRequired = $true
            isolatedHomeRequired = $true
            mustNotReadOutsideSandbox = $true
            fixtureHash = ('a' * 64)
            skillHash = if ($configuration -eq 'with_skill') { ('b' * 64) } else { $null }
        }
        [System.IO.File]::WriteAllText((Join-Path $runPath 'run.json'), ($runJson | ConvertTo-Json -Depth 100), [System.Text.UTF8Encoding]::new($false))
        $resultsDir = Join-Path $evalDirectory 'results'
        New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
        $executionResultRel = "$evalName/results/$configuration.execution-result.json"
        $resultRel = "$evalName/results/$configuration.result.json"
        # create a canonical (empty) result.json so manifest validation is satisfied
        [System.IO.File]::WriteAllText((Join-Path $resultsDir "$configuration.result.json"), (([ordered]@{ eval_id = $evalId; configuration = $configuration; execution_status = 'unrun'; grading = @() }) | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        $runs[$configuration] = [ordered]@{ mode = $configuration; run_manifest = "$evalName/$configuration/run.json"; execution_result = $executionResultRel; result = $resultRel }
    }
    [System.IO.File]::WriteAllText((Join-Path $evalDirectory 'eval-metadata.json'), (([ordered]@{ eval_id = $evalId; eval_name = $evalName; assertions = @('assertion') }) | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    $manifestEvals.Add([ordered]@{ eval_id = $evalId; eval_name = $evalName; directory = $evalName; metadata = "$evalName/eval-metadata.json"; runs = $runs })
}

$manifest = [ordered]@{ schema = (Get-RunnerSchemaNames).OrchestrationPlan; configurations = @('with_skill'); execution_freeze = 'execution-freeze.json'; evals = @($manifestEvals) }
$profile = [ordered]@{ schema = (Get-RunnerSchemaNames).Profile; runner = 'fake'; model = 'fixture-model'; configuration_profile = 'isolated-default'; tool_profile = 'default'; timeout_seconds = 60; concurrency = 4 }

$plan = New-EvalOrchestrationPlan -IterationDirectory $iteration -Manifest $manifest -Profile $profile
$state = New-OrchestrationState -Plan $plan

# Accept all workers
$dispatches = @(Get-NextWorkerDispatches -Plan $plan -State $state)
foreach ($d in $dispatches) { [void](Register-DelegationAccepted -State $state -WorkerId $d.worker_id -WorkerSessionId ('sess-' + $d.worker_id)) }
Assert-Equal 4 (Get-OrchestrationActiveCount -State $state) 'all workers active'

# Prepare synthetic execution evidences
$arms = @($plan.arms)
$evidences = @{}
# arm1 -> timed_out
$arm1 = $arms[0]
$evidences[$arm1.worker_id] = [ordered]@{
    status = 'timed_out'
    session = [ordered]@{ id = ('sess-' + $arm1.worker_id); fresh = $true; resumed = $false }
    run = [ordered]@{ eval_id = [int]$arm1.eval_id; eval_name = [string]$arm1.eval_name; configuration = [string]$arm1.configuration }
    requested = [ordered]@{ model = [string]$arm1.worker.model }
    evidence = [ordered]@{ delegation = [ordered]@{ mechanism = 'fake'; worker_session_id = ('sess-' + $arm1.worker_id); observed_model = [string]$arm1.worker.model; terminal_result_capture = $false } }
}
# arm2 -> completed (valid)
$arm2 = $arms[1]
$runData2 = Resolve-RunContract -RunPath ([string]$arm2.worker.run_manifest_path)
$evidences[$arm2.worker_id] = New-TestNativeTerminalEvidence -Arm $arm2 -RunData $runData2 -WorkerSessionId ('sess-' + $arm2.worker_id)
# arm3 -> failed
$arm3 = $arms[2]
$evidences[$arm3.worker_id] = [ordered]@{
    status = 'failed'
    session = [ordered]@{ id = ('sess-' + $arm3.worker_id); fresh = $true; resumed = $false }
    run = [ordered]@{ eval_id = [int]$arm3.eval_id; eval_name = [string]$arm3.eval_name; configuration = [string]$arm3.configuration }
    requested = [ordered]@{ model = [string]$arm3.worker.model }
    evidence = [ordered]@{ delegation = [ordered]@{ mechanism = 'fake'; worker_session_id = ('sess-' + $arm3.worker_id); observed_model = [string]$arm3.worker.model; terminal_result_capture = $false } }
}
# arm4 -> completed
$arm4 = $arms[3]
$runData4 = Resolve-RunContract -RunPath ([string]$arm4.worker.run_manifest_path)
$evidences[$arm4.worker_id] = New-TestNativeTerminalEvidence -Arm $arm4 -RunData $runData4 -WorkerSessionId ('sess-' + $arm4.worker_id)

# Sanity: ensure evidences exist for each arm
Write-Output "ARM KEYS:"
foreach ($arm in $arms) { Write-Output " - $($arm.worker_id)" }
Write-Output "EVIDENCE KEYS:"
foreach ($k in $evidences.Keys) { Write-Output " - $k" }

# Register terminals
foreach ($arm in $arms) {
    $w = [string]$arm.worker_id
    if (-not $evidences.ContainsKey($w)) { throw "Missing synthetic evidence for $w" }
    $exec = $evidences[$w]
    [void](Register-WorkerTerminal -Plan $plan -State $state -WorkerId $w -ExecutionEvidence $exec)
}

# Verify ledger preserves raw statuses and records evidence_validation
foreach ($arm in $arms) {
    $w = $arm.worker_id
    $ledger = $state.completed[$w]
    $raw = $evidences[$w]
    Assert-Equal $raw.status $ledger.status "ledger.status should equal raw for $w"
    $ev = Get-JsonProperty -Object $ledger -Name 'evidence_validation' -Default $null
    Write-Output "ledger[$w].native_worker_evidence_failures = $([string]::Join(', ', @($ledger.native_worker_evidence_failures | Where-Object {$_} )))"
    Write-Output "ledger[$w].evidence_validation.status = $($ev.status)"
    if ($raw.status -eq 'completed') { Assert-Equal 'passed' $ev.status "evidence_validation should pass for $w" } else { Assert-Equal 'failed' $ev.status "evidence_validation should fail for $w" }
}

# Negative integrity: ledger mismatch must be rejected by Assert-FreezeTerminalLedgerEntry
# craft a fake record and raw object
$fakeRecord = [ordered]@{ EvalId = 999; Configuration = 'with_skill'; }
$fakeRaw = [ordered]@{ status = 'timed_out'; session = [ordered]@{ id = 'sess-fake' } }
# craft a state with a mismatched ledger entry
$badState = [ordered]@{ completed = [ordered]@{ 'arm-999-with_skill' = [ordered]@{ worker_id = 'arm-999-with_skill'; eval_id = 999; configuration = 'with_skill'; status = 'incompatible'; worker_session_id = 'sess-fake' } } }
$threw = $false
try { [void](Assert-FreezeTerminalLedgerEntry -Record $fakeRecord -Raw $fakeRaw -State $badState) } catch { $threw = $true }
Assert-True $threw 'Assert-FreezeTerminalLedgerEntry must reject ledger/raw status mismatch'

Write-Output 'MIXED-TERMINAL REGRESSION: PASS'