<#!
.SYNOPSIS
    Deterministic, model-free live-observability tests for every eval runner.

.DESCRIPTION
    Proves the shared observability contract without any model, network, or
    authenticated CLI. Synthetic child processes exercise the shared process
    primitive (heartbeats, activity tracking, tee/relay, timeout diagnostics,
    secret hygiene), and one real runner-owned fan-out run over the deterministic
    fixture proves concurrent-arm attribution, the STDOUT machine contract, and
    persisted progress evidence. No test may hang: every scenario is bounded.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'runner-progress.ps1')
. (Join-Path $runnerRoot 'fanout-process.ps1')
. (Join-Path $runnerRoot 'manifest-paths.ps1')
. (Join-Path $runnerRoot 'package-integrity.ps1')
. (Join-Path $runnerRoot 'execution-freeze.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT: $Message (expected '$Expected', got '$Actual')" }
}

function Get-Field {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

$pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-observability-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

function New-SyntheticChildScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Body
    )

    $path = Join-Path $testRoot ($Name + '.ps1')
    [System.IO.File]::WriteAllText($path, $Body, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-SyntheticChild {
    <#
      Drives one synthetic child through the shared process primitive exactly as
      the fan-out does: Start -> Wait-AnyRunnerChild (heartbeats/relay) -> Complete
      (terminal diagnostic). Returns the child, exit code, and the parsed progress
      log so a test can assert what an operator would have seen live.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [int]$TimeoutSeconds = 30,
        [double]$HeartbeatSeconds = 0.3,
        [object]$EvalId = 1,
        [string]$Configuration = 'with_skill'
    )

    $workDirectory = Join-Path $testRoot ('work-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $stdoutPath = Join-Path $workDirectory 'result.json'
    $stderrPath = Join-Path $workDirectory 'child.stderr'
    $logPath = Join-Path $workDirectory 'progress.jsonl'
    $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $ScriptPath) -WorkingDirectory $workDirectory -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds -Runner 'synthetic' -WorkerId $WorkerId -EvalId $EvalId -Configuration $Configuration -Phase 'model-cli' -ProgressLogPath $logPath -HeartbeatSeconds $HeartbeatSeconds
    $running = [System.Collections.Generic.List[object]]::new()
    $running.Add([pscustomobject]@{ worker_id = $WorkerId; child = $child; Process = $child.Process })
    $index = Wait-AnyRunnerChild -Running $running
    $exitCode = Complete-RunnerChildProcess -Child $child
    $events = @()
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $events = @(Get-Content -LiteralPath $logPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return [pscustomobject]@{
        Child = $child
        ExitCode = $exitCode
        WaitIndex = $index
        Events = $events
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        LogPath = $logPath
    }
}

function New-ObservabilityFanoutPackage {
    <#
      Builds a minimal runner-owned fixture package. The fixture is a protocol
      adapter only; it never calls a model or an AI CLI. Each arm is slowed by a
      per-run marker so heartbeats fire on the real operator-facing path.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [int]$EvalCount = 2,
        [int]$Concurrency = 4,
        [int]$DelayMs = 700
    )

    $tools = Join-Path $IterationDirectory 'tools\eval-runners'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    foreach ($toolItem in @(Get-ChildItem -LiteralPath $runnerRoot -Force | Where-Object { $_.Name -ne 'tests' })) {
        Copy-Item -LiteralPath $toolItem.FullName -Destination $tools -Recurse -Force
    }
    $fixtureRunnerDirectory = Join-Path $tools 'fixture'
    New-Item -ItemType Directory -Path $fixtureRunnerDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runnerRoot 'tests\fixtures\runner-owned-fixture.ps1') -Destination (Join-Path $fixtureRunnerDirectory 'runner.ps1') -Force

    [System.IO.File]::WriteAllText((Join-Path $IterationDirectory 'execution-profile.json'), (([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = $Concurrency
    } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

    $manifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le $EvalCount; $evalId++) {
        $evalName = 'obs-eval-{0:d2}' -f $evalId
        $evalDirectory = Join-Path $IterationDirectory $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $evalDirectory 'eval-metadata.json'), (([ordered]@{ eval_id = $evalId; eval_name = $evalName; assertions = @('fixture') } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        $runs = [ordered]@{}
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $runDirectory = Join-Path $evalDirectory $configuration
            $repoDirectory = Join-Path $runDirectory 'repo'
            $homeDirectory = Join-Path $runDirectory 'home'
            $resultDirectory = Join-Path $evalDirectory 'results'
            New-Item -ItemType Directory -Path $repoDirectory, $homeDirectory, $resultDirectory -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $repoDirectory 'input.txt'), "$evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'prompt.md'), "observability prompt $evalName/$configuration", [System.Text.UTF8Encoding]::new($false))
            # Slow each arm past the heartbeat interval so the operator path emits
            # heartbeats without any model involvement.
            [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'execute-delay-ms'), [string]$DelayMs, [System.Text.UTF8Encoding]::new($false))
            $skillDirectory = $null
            $skillHash = $null
            if ($configuration -eq 'with_skill') {
                $skillDirectory = 'skill/candidate'
                New-Item -ItemType Directory -Path (Join-Path $runDirectory 'skill\candidate') -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $runDirectory 'skill\candidate\SKILL.md'), '# fixture', [System.Text.UTF8Encoding]::new($false))
                $skillHash = ('b' * 64)
            }
            [System.IO.File]::WriteAllText((Join-Path $runDirectory 'run.json'), (([ordered]@{
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
            } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
            $resultName = if ($configuration -eq 'with_skill') { 'with-skill.result.json' } else { 'without-skill.result.json' }
            $executionName = if ($configuration -eq 'with_skill') { 'with-skill.execution-result.json' } else { 'without-skill.execution-result.json' }
            [System.IO.File]::WriteAllText((Join-Path $resultDirectory $resultName), (([ordered]@{ eval_id = $evalId; configuration = $configuration; execution_status = 'unrun' } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
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
    [System.IO.File]::WriteAllText((Join-Path $IterationDirectory 'manifest.json'), (([ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_profile = 'execution-profile.json'
        runner_tools = 'tools/eval-runners'
        runner_tools_integrity = [ordered]@{ schema = 'codebeltnet/agentic/package-tree-integrity/1'; path = 'tools/eval-runners'; sha256 = $toolIntegrity.Sha256; file_count = $toolIntegrity.FileCount }
        execution_freeze = 'execution-freeze.json'
        evals = @($manifestEvals.ToArray())
    } | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    return $IterationDirectory
}

function Invoke-ObservabilityFanout {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [int]$EvalCount = 2,
        [int]$Concurrency = 4,
        [int]$DelayMs = 700
    )

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    [void](New-ObservabilityFanoutPackage -IterationDirectory $Root -EvalCount $EvalCount -Concurrency $Concurrency -DelayMs $DelayMs)
    $fanout = Join-Path $Root 'tools/eval-runners/invoke-runner-owned-arms.ps1'
    $stderrPath = Join-Path $Root 'phase1.stderr'
    $previousHeartbeat = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS')
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS', '0.3')
    try {
        $output = & $pwshPath -NoProfile -File $fanout -IterationDirectory $Root 2>$stderrPath
        $exitCode = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS', $previousHeartbeat)
    }
    $stdout = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    return [pscustomobject]@{
        IterationDirectory = $Root
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

try {
    # Pre-warm the shared activity type so its one-time JIT/compile cost is paid
    # before any timed scenario. Otherwise, under heavy machine load, that cost
    # inflates the first child's launch timestamp and compresses its heartbeat
    # window, making timing-sensitive assertions flaky.
    Initialize-RunnerActivityType

    # ------------------------------------------------------------------
    # Test 1 - quiet but alive: a healthy but silent process must still be
    # visibly alive. Heartbeats appear even though the process emits nothing.
    # ------------------------------------------------------------------
    $quietScript = New-SyntheticChildScript -Name 'quiet' -Body @'
Start-Sleep -Milliseconds 1500
[Console]::Out.Write('{"status":"completed"}')
'@
    $quiet = Invoke-SyntheticChild -ScriptPath $quietScript -WorkerId 'arm-1-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    Assert-Equal 0 $quiet.ExitCode 'quiet-but-alive child exits cleanly'
    $quietHeartbeats = @($quiet.Events | Where-Object { [string]$_.state -eq 'running' -and [string]$_.origin -eq 'parent' -and $null -ne $_.PSObject.Properties['pid'] })
    Assert-True ($quietHeartbeats.Count -ge 2) "a quiet but alive process still emits heartbeats (got $($quietHeartbeats.Count))"
    $quietElapsed = @($quiet.Events | Where-Object { $null -ne $_.PSObject.Properties['elapsedSeconds'] } | ForEach-Object { [double]$_.elapsedSeconds })
    $quietElapsedSpan = (($quietElapsed | Measure-Object -Maximum).Maximum) - (($quietElapsed | Measure-Object -Minimum).Minimum)
    Assert-True ($quietElapsedSpan -ge 0.2) "quiet progress shows elapsed runtime advancing (span=$([Math]::Round($quietElapsedSpan,3))s)"
    Assert-True (@($quiet.Events | Where-Object { [int64](Get-Field $_ 'stderrEvents' 0) -ne 0 }).Count -eq 0) 'quiet process reports zero real stderr activity'
    Assert-True (@($quiet.Events | Where-Object { [string]$_.state -eq 'completed' }).Count -eq 1) 'quiet process reports a terminal completed state'

    # ------------------------------------------------------------------
    # Test 2 - active process: periodic output is observable as live activity
    # without corrupting the captured machine result or leaking into it.
    # ------------------------------------------------------------------
    $activeScript = New-SyntheticChildScript -Name 'active' -Body @'
for ($i = 0; $i -lt 4; $i++) {
    [Console]::Error.WriteLine("chunk $i produced")
    Start-Sleep -Milliseconds 250
}
[Console]::Error.WriteLine('@@AGENTIC-PROGRESS@@ {"state":"active","phase":"model-cli","detail":"turn-1","stdoutEvents":3}')
[Console]::Out.Write('{"status":"completed"}')
'@
    $active = Invoke-SyntheticChild -ScriptPath $activeScript -WorkerId 'arm-2-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    Assert-Equal 0 $active.ExitCode 'active child exits cleanly'
    Assert-Equal '{"status":"completed"}' ((Get-Content -LiteralPath $active.StdoutPath -Raw).Trim()) 'active child result STDOUT is captured exactly, uncorrupted by activity'
    Assert-True (@($active.Events | Where-Object { [int64](Get-Field $_ 'stderrEvents' 0) -ge 1 }).Count -ge 1) 'active process real stderr activity is observable in heartbeats'
    $activeWithAge = @($active.Events | Where-Object { $null -ne $_.PSObject.Properties['lastActivitySeconds'] })
    Assert-True ($activeWithAge.Count -ge 1) 'active process reports the age of its most recent activity'
    $relayed = @($active.Events | Where-Object { [string]$_.origin -eq 'relay' })
    Assert-True ($relayed.Count -ge 1) 'structured child progress is relayed through the parent'
    Assert-Equal 'arm-2-with_skill' ([string]$relayed[0].worker) 'a relayed event is attributed to the emitting worker'
    Assert-Equal 'turn-1' ([string]$relayed[0].detail) 'a relayed event preserves the safe child-provided detail'

    # ------------------------------------------------------------------
    # Test 3 - hanging process: the watchdog must fire, terminate the child,
    # and produce a final diagnostic. There must be no indefinite hang.
    # ------------------------------------------------------------------
    $hangScript = New-SyntheticChildScript -Name 'hang' -Body @'
while ($true) { Start-Sleep -Milliseconds 150 }
'@
    $hangClock = [System.Diagnostics.Stopwatch]::StartNew()
    $hang = Invoke-SyntheticChild -ScriptPath $hangScript -WorkerId 'arm-3-with_skill' -TimeoutSeconds 2 -HeartbeatSeconds 0.3
    $hangClock.Stop()
    Assert-True ($hangClock.Elapsed.TotalSeconds -lt 15) ("hanging process reaches a terminal state promptly; elapsed={0:N2}s" -f $hangClock.Elapsed.TotalSeconds)
    Assert-True ([bool]$hang.Child.TimedOut) 'hanging process is reported as timed out'
    Assert-True ([bool]$hang.Child.TerminationObserved) 'hanging process is actually terminated'
    Assert-True ($null -eq $hang.ExitCode) 'timed-out child has no synthesized success exit code'
    $hangHeartbeats = @($hang.Events | Where-Object { [string]$_.state -eq 'running' -and [string]$_.origin -eq 'parent' })
    Assert-True ($hangHeartbeats.Count -ge 2) 'heartbeats continue while a process hangs'
    $timedOut = @($hang.Events | Where-Object { [string]$_.state -eq 'timed-out' })
    Assert-Equal 1 $timedOut.Count 'a hanging process produces exactly one timed-out diagnostic'
    Assert-True ([bool]$timedOut[0].terminationObserved) 'the timeout diagnostic records that termination was observed'
    Assert-True ($null -ne $timedOut[0].PSObject.Properties['elapsedSeconds'] -and [double]$timedOut[0].elapsedSeconds -gt 0) 'the timeout diagnostic records elapsed runtime'
    Assert-True (@($hang.Events | Where-Object { [string]$_.state -eq 'terminating' }).Count -ge 1) 'a terminating lifecycle state precedes termination'

    # ------------------------------------------------------------------
    # Test 6 - fast successful runner: observability must not disturb a normal
    # short execution or its captured result.
    # ------------------------------------------------------------------
    $fastScript = New-SyntheticChildScript -Name 'fast' -Body @'
[Console]::Out.Write('{"status":"completed"}')
'@
    $fast = Invoke-SyntheticChild -ScriptPath $fastScript -WorkerId 'arm-6-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    Assert-Equal 0 $fast.ExitCode 'fast successful child exits cleanly'
    Assert-Equal '{"status":"completed"}' ((Get-Content -LiteralPath $fast.StdoutPath -Raw).Trim()) 'fast child result is captured exactly'
    Assert-True (@($fast.Events | Where-Object { [string]$_.state -eq 'running' -and $null -ne $_.PSObject.Properties['pid'] }).Count -ge 1) 'fast child still records a launch lifecycle event'
    Assert-True (@($fast.Events | Where-Object { [string]$_.state -eq 'completed' }).Count -eq 1) 'fast child records exactly one completed state'

    # ------------------------------------------------------------------
    # Test 7 - failure diagnostics: a runner that fails after some activity must
    # yield a diagnostic identifying meaningful last-known state.
    # ------------------------------------------------------------------
    $failScript = New-SyntheticChildScript -Name 'fail' -Body @'
[Console]::Error.WriteLine('preparing request')
Start-Sleep -Milliseconds 400
[Console]::Error.WriteLine('harness aborted unexpectedly')
exit 17
'@
    $fail = Invoke-SyntheticChild -ScriptPath $failScript -WorkerId 'arm-7-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    Assert-Equal 17 $fail.ExitCode 'failing child reports its real non-zero exit code'
    $failed = @($fail.Events | Where-Object { [string]$_.state -eq 'failed' })
    Assert-Equal 1 $failed.Count 'a failing child produces exactly one failure diagnostic'
    Assert-Equal 17 ([int]$failed[0].exitCode) 'the failure diagnostic records the exit code'
    Assert-True ([int64](Get-Field $failed[0] 'stderrEvents' 0) -ge 1) 'the failure diagnostic records observed stderr activity'
    Assert-True ([string]$failed[0].detail -match 'harness aborted') 'the failure diagnostic surfaces the last-known stderr state'

    # ------------------------------------------------------------------
    # Test 8 - sensitive value hygiene: a recognizable secret in the process
    # environment and stderr must never surface in operator progress output.
    # ------------------------------------------------------------------
    $secret = 'topsecret-' + [Guid]::NewGuid().ToString('N')
    $oldSecret = [Environment]::GetEnvironmentVariable('AGENTIC_TEST_FAKE_SECRET')
    [Environment]::SetEnvironmentVariable('AGENTIC_TEST_FAKE_SECRET', $secret)
    try {
        $secretScript = New-SyntheticChildScript -Name 'secret' -Body @'
[Console]::Error.WriteLine('AUTH_TOKEN=' + [Environment]::GetEnvironmentVariable('AGENTIC_TEST_FAKE_SECRET'))
Start-Sleep -Milliseconds 300
exit 9
'@
        $secretRun = Invoke-SyntheticChild -ScriptPath $secretScript -WorkerId 'arm-8-with_skill' -TimeoutSeconds 30 -HeartbeatSeconds 0.3
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_TEST_FAKE_SECRET', $oldSecret)
    }
    $secretLog = if (Test-Path -LiteralPath $secretRun.LogPath -PathType Leaf) { [System.IO.File]::ReadAllText($secretRun.LogPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    Assert-True (-not $secretLog.Contains($secret)) 'the raw secret value never appears in persisted progress output'
    $secretFailed = @($secretRun.Events | Where-Object { [string]$_.state -eq 'failed' })
    Assert-Equal 1 $secretFailed.Count 'the secret-bearing child still produces a failure diagnostic'
    Assert-True ([string]$secretFailed[0].detail -match 'AUTH_TOKEN=<redacted>') 'a secret-looking stderr assignment is redacted in the diagnostic tail'
    Assert-True ([bool](Test-Path -LiteralPath $secretRun.StderrPath -PathType Leaf)) 'raw child stderr evidence is still captured to its file'

    # ------------------------------------------------------------------
    # Tests 4 and 5 - one real runner-owned fan-out run over the deterministic
    # fixture proves concurrent-arm attribution, the STDOUT machine contract,
    # and persisted progress evidence, all on the true operator-facing path.
    # ------------------------------------------------------------------
    $fanoutResult = Invoke-ObservabilityFanout -Root (Join-Path $testRoot 'fanout') -EvalCount 2 -Concurrency 4 -DelayMs 700
    Assert-Equal 0 $fanoutResult.ExitCode 'observability fan-out completes successfully'

    # Test 5 - the STDOUT contract: exactly one machine-readable terminal JSON.
    $stdoutTrimmed = ([string]$fanoutResult.Stdout).Trim()
    $terminal = $null
    $terminal = $stdoutTrimmed | ConvertFrom-Json -Depth 100
    Assert-Equal 'phase1' ([string]$terminal.phase) 'STDOUT still carries exactly one machine-readable terminal summary'
    Assert-Equal 'completed' ([string]$terminal.status) 'the terminal summary reports completion'
    Assert-True (-not $stdoutTrimmed.Contains((Get-RunnerProgressSentinel))) 'no relay sentinel ever leaks onto STDOUT'
    Assert-True (-not ($stdoutTrimmed -match '(?m)^\[synthetic\]|(?m)^\[fixture\]')) 'no operator progress line contaminates STDOUT'
    Assert-True ($stdoutTrimmed.StartsWith('{') -and $stdoutTrimmed.EndsWith('}')) 'STDOUT is a single JSON object with no surrounding progress text'

    # Progress is also persisted for post-mortem inspection at the advertised path.
    Assert-Equal 'progress/phase1-progress.jsonl' ([string]$terminal.progress_log) 'the terminal summary advertises where progress is persisted'
    $persistedLog = Join-Path $fanoutResult.IterationDirectory ([string]$terminal.progress_log)
    Assert-True (Test-Path -LiteralPath $persistedLog -PathType Leaf) 'the persisted progress log exists at the advertised path'
    $persistedEvents = @(Get-Content -LiteralPath $persistedLog | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($persistedEvents.Count -ge 4) 'the persisted progress log retains events for post-mortem inspection'

    # Test 4 - concurrent-arm attribution: every progress line is attributable.
    $stderrLines = @(([string]$fanoutResult.Stderr) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $progressLines = @($stderrLines | Where-Object { $_ -match '^\[(synthetic|fixture)\]' })
    Assert-True ($progressLines.Count -ge 2) 'the concurrent fan-out emits live operator progress on STDERR'
    $unlabeled = @($progressLines | Where-Object { -not ($_ -match '\[arm-\d+-(with_skill|without_skill)\]') })
    Assert-Equal 0 $unlabeled.Count 'every operator progress line carries a resolvable worker identity'
    $workerIds = @($persistedEvents | ForEach-Object { [string]$_.worker } | Where-Object { $_ -match '^arm-\d+-' } | Sort-Object -Unique)
    Assert-True ($workerIds.Count -ge 2) "concurrent arms are individually attributable (distinct workers: $($workerIds.Count))"
    foreach ($workerId in @('arm-1-with_skill', 'arm-1-without_skill', 'arm-2-with_skill', 'arm-2-without_skill')) {
        Assert-True ($workerIds -contains $workerId) "progress is attributed to worker $workerId"
    }
    # Attribution must be exclusive: an event's fields belong to exactly its worker.
    $misattributed = @($persistedEvents | Where-Object {
            [string]$_.state -in @('running', 'active', 'completed', 'timed-out', 'failed') -and
            $null -ne $_.PSObject.Properties['configuration'] -and
            -not ([string]$_.worker).EndsWith([string]$_.configuration)
        })
    Assert-Equal 0 $misattributed.Count 'no progress event mixes one worker identity with another configuration'

    # ------------------------------------------------------------------
    # Test 9 - the shared process primitive: runner model-CLI progress is opt-in
    # via the orchestration environment, relays through STDERR, and never
    # contaminates the captured model result on STDOUT.
    # ------------------------------------------------------------------
    Assert-True ($null -eq (Get-RunnerModelProgressContext -Runner 'opencode')) 'runner model-CLI progress is silent without the orchestration flag'
    $previousFlag = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS')
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS', '1')
    try {
        $enabledContext = Get-RunnerModelProgressContext -Runner 'opencode' -Phase 'opencode-cli'
        Assert-True ($null -ne $enabledContext) 'the orchestration flag enables a runner model-CLI progress context'
        Assert-Equal 'Relayable' ([string]$enabledContext['channel']) 'runner model-CLI progress uses the relayable channel'
        Assert-Equal 'opencode' ([string]$enabledContext['runner']) 'runner model-CLI progress context carries the runner identity'
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS', $previousFlag)
    }

    $primitiveDriver = New-SyntheticChildScript -Name 'primitive-driver' -Body @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $env:AGENTIC_OBS_RUNNER_ROOT 'runner-common.ps1')
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$ctx = @{ enabled = $true; runner = 'opencode'; phase = 'opencode-cli'; channel = 'Relayable'; heartbeatSeconds = 0.3 }
$grandchild = 'Start-Sleep -Milliseconds 900; [Console]::Out.Write(''grandchild-done'')'
$r = Invoke-RunnerProcess -FileName $pwsh -ArgumentList @('-NoProfile', '-Command', $grandchild) -WorkingDirectory $env:AGENTIC_OBS_RUNNER_ROOT -TimeoutSeconds 20 -ProgressContext $ctx
[Console]::Out.Write([string]$r.Stdout)
'@
    $driverStderrPath = Join-Path $testRoot 'primitive.stderr'
    $previousRoot = [Environment]::GetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT')
    [Environment]::SetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT', $runnerRoot)
    try {
        $driverOut = & $pwshPath -NoProfile -File $primitiveDriver 2>$driverStderrPath
    } finally {
        [Environment]::SetEnvironmentVariable('AGENTIC_OBS_RUNNER_ROOT', $previousRoot)
    }
    $driverStdout = ([string]::Join('', @($driverOut | ForEach-Object { [string]$_ }))).Trim()
    $driverStderr = if (Test-Path -LiteralPath $driverStderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($driverStderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    Assert-Equal 'grandchild-done' $driverStdout 'the model result on STDOUT passes through the shared primitive uncorrupted'
    Assert-True (-not $driverStdout.Contains((Get-RunnerProgressSentinel))) 'no relayable sentinel leaks onto the shared primitive STDOUT'
    Assert-True ($driverStderr.Contains((Get-RunnerProgressSentinel))) 'the shared primitive relays model-process progress on STDERR'
    Assert-True ($driverStderr -match '"state":"running"') 'the relayed model-process progress reports a running lifecycle state'

    Write-Output 'Runner observability: PASS'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
