$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'package-integrity.ps1')
. (Join-Path $runnerRoot 'phase1-control-common.ps1')

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "Assertion failed: $Message" } }
function Assert-Equal($Expected, $Actual, [string]$Message) { if ($Expected -ne $Actual) { throw "Assertion failed: $Message (expected '$Expected', got '$Actual')" } }
function Write-TestJson([string]$Path, [object]$Value) { New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null; [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false)) }
function Read-TestJson([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 100 }
function Read-TestText([string]$Path) { return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)) }

function New-LifecyclePackage {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [int]$DelayMilliseconds = 2500,
        [int]$ArmCount = 2
    )

    $tools = Join-Path $IterationDirectory 'tools/eval-runners'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $runnerRoot -Force | Where-Object { $_.Name -ne 'tests' })) {
        Copy-Item -LiteralPath $item.FullName -Destination $tools -Recurse -Force
    }
    $fixtureDirectory = Join-Path $tools 'fixture'
    New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runnerRoot 'tests/fixtures/runner-owned-fixture.ps1') -Destination (Join-Path $fixtureDirectory 'runner.ps1') -Force

    $manifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le $ArmCount; $evalId++) {
        $evalName = 'lifecycle-eval-{0:d2}' -f $evalId
        $runRoot = Join-Path $IterationDirectory "$evalName/with_skill"
        $repo = Join-Path $runRoot 'repo'
        $homeDirectory = Join-Path $runRoot 'home'
        $skillDirectory = Join-Path $runRoot 'skill/candidate'
        New-Item -ItemType Directory -Path $repo, $homeDirectory, $skillDirectory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'input.txt'), "fixture-$evalId", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $runRoot 'prompt.md'), "fixture prompt $evalId", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $homeDirectory 'execute-delay-ms'), [string]$DelayMilliseconds, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $skillDirectory 'SKILL.md'), '# fixture', [Text.UTF8Encoding]::new($false))
        Write-TestJson -Path (Join-Path $runRoot 'run.json') -Value ([ordered]@{
            schema = (Get-RunnerSchemaNames).Run
            evalId = $evalId
            evalName = $evalName
            skillName = 'candidate'
            iteration = 1
            mode = 'with_skill'
            promptFile = 'prompt.md'
            workingDirectory = 'repo'
            homeDirectory = 'home'
            skillDirectory = 'skill/candidate'
            freshContextRequired = $true
            filesystemIsolationRequired = $true
            isolatedHomeRequired = $true
            fixtureHash = ('a' * 64)
            skillHash = ('b' * 64)
        })
        $results = Join-Path $IterationDirectory "$evalName/results"
        New-Item -ItemType Directory -Path $results -Force | Out-Null
        Write-TestJson -Path (Join-Path $results 'result.json') -Value ([ordered]@{ eval_id = $evalId; configuration = 'with_skill' })
        Write-TestJson -Path (Join-Path $IterationDirectory "$evalName/eval-metadata.json") -Value ([ordered]@{ eval_id = $evalId; eval_name = $evalName; assertions = @('fixture') })
        $manifestEvals.Add([ordered]@{
            eval_id = $evalId
            eval_name = $evalName
            directory = $evalName
            metadata = "$evalName/eval-metadata.json"
            runs = [ordered]@{
                with_skill = [ordered]@{
                    mode = 'with_skill'
                    run_manifest = "$evalName/with_skill/run.json"
                    execution_result = "$evalName/results/execution-result.json"
                    result = "$evalName/results/result.json"
                }
            }
        })
    }
    Write-TestJson -Path (Join-Path $IterationDirectory 'execution-profile.json') -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = [Math]::Max(2, $ArmCount)
    })
    $integrity = Get-PackageTreeIntegrity -Root $tools
    Write-TestJson -Path (Join-Path $IterationDirectory 'manifest.json') -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        skill_name = 'lifecycle-fixture'
        iteration = 1
        configurations = @('with_skill')
        execution_profile = 'execution-profile.json'
        runner_tools = 'tools/eval-runners'
        runner_tools_integrity = [ordered]@{ schema = 'codebeltnet/agentic/package-tree-integrity/1'; path = 'tools/eval-runners'; sha256 = $integrity.Sha256; file_count = $integrity.FileCount }
        execution_freeze = 'execution-freeze.json'
        evals = @($manifestEvals.ToArray())
    })
    return [pscustomobject]@{
        Iteration = $IterationDirectory
        Controller = Join-Path $tools 'control-runner-owned-phase1.ps1'
        Fanout = Join-Path $tools 'invoke-runner-owned-arms.ps1'
        EventLog = Join-Path $IterationDirectory 'runner-events.jsonl'
    }
}

function Invoke-Controller {
    param([Parameter(Mandatory = $true)][object]$Package, [int]$WaitSeconds = 0)

    $output = & pwsh -NoProfile -File $Package.Controller -IterationDirectory $Package.Iteration -WaitSeconds $WaitSeconds 2>&1
    $exitCode = $LASTEXITCODE
    $text = [string]::Join([Environment]::NewLine, @($output))
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; Result = ($text | ConvertFrom-Json -Depth 100) }
}

function Wait-ControllerTerminal {
    param([Parameter(Mandatory = $true)][object]$Package, [int]$TimeoutSeconds = 30)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $invocation = Invoke-Controller -Package $Package -WaitSeconds 1
        if ([string]$invocation.Result.status -ne 'running') { return $invocation }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Controller did not reach a terminal status for '$($Package.Iteration)'."
}

function Assert-ExactlyOnce {
    param([Parameter(Mandatory = $true)][object]$Package, [int]$ArmCount = 2)

    $events = @(Get-Content -LiteralPath $Package.EventLog | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal $ArmCount @($events | Where-Object { $_.kind -eq 'preflight' }).Count 'exactly one preflight event per arm'
    Assert-Equal $ArmCount @($events | Where-Object { $_.kind -eq 'execute' }).Count 'exactly one execute event per arm'
    $invocation = Read-TestJson -Path (Join-Path $Package.Iteration 'phase1-fanout-invocation.json')
    Assert-Equal 1 ([int]$invocation.invocation_count) 'exactly one internal fan-out invocation'
    foreach ($result in @(Get-ChildItem -LiteralPath $Package.Iteration -Recurse -File -Filter 'execution-result.json')) {
        Assert-True ($result.Length -gt 0) "$($result.FullName) is non-empty"
        [void](Assert-ExecutionResult -Result (Read-TestJson -Path $result.FullName))
    }
    Assert-Equal $ArmCount @(Get-ChildItem -LiteralPath $Package.Iteration -Recurse -File -Filter 'execution-result.json').Count 'one execution result per arm'
}

function Wait-File([string]$Path, [int]$TimeoutSeconds = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do { if (Test-Path -LiteralPath $Path -PathType Leaf) { return }; Start-Sleep -Milliseconds 25 } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for '$Path'."
}

function New-ControllerJobHarnessScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    $script = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GatePath,
    [Parameter(Mandatory = $true)][string]$ControllerPath,
    [Parameter(Mandatory = $true)][string]$IterationDirectory,
    [int]$WaitSeconds = 60
)

$ErrorActionPreference = 'Stop'
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath $GatePath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for '$GatePath'." }
    Start-Sleep -Milliseconds 25
}

& pwsh -NoProfile -File $ControllerPath -IterationDirectory $IterationDirectory -WaitSeconds $WaitSeconds
exit $LASTEXITCODE
'@
    [IO.File]::WriteAllText($Path, $script, [Text.UTF8Encoding]::new($false))
}

function Start-ControllerHarnessInJob {
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][object]$Job,
        [int]$WaitSeconds = 60
    )

    $harnessRoot = Join-Path $Package.Iteration 'job-harness'
    New-Item -ItemType Directory -Path $harnessRoot -Force | Out-Null
    $gatePath = Join-Path $harnessRoot 'launch.gate'
    $scriptPath = Join-Path $harnessRoot 'harness.ps1'
    $stdoutPath = Join-Path $harnessRoot 'harness.stdout'
    $stderrPath = Join-Path $harnessRoot 'harness.stderr'
    New-ControllerJobHarnessScript -Path $scriptPath
    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    $process = Start-Process -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $scriptPath, '-GatePath', $gatePath, '-ControllerPath', $Package.Controller, '-IterationDirectory', $Package.Iteration, '-WaitSeconds', [string]$WaitSeconds) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    Add-WindowsProcessToJobObject -Job $Job -ProcessId $process.Id
    [IO.File]::WriteAllText($gatePath, "go`n", [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{
        Process = $process
        GatePath = $gatePath
        ScriptPath = $scriptPath
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-phase1-controller-' + [Guid]::NewGuid().ToString('N'))
$oldEventLog = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG')
try {
    # A controller exits while delayed fake workers remain active. A fresh
    # controller process observes the same supervisor and never redispatches.
    $survival = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'caller-exits') -DelayMilliseconds 3000
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $survival.EventLog)
    $firstClock = [Diagnostics.Stopwatch]::StartNew()
    $first = Invoke-Controller -Package $survival -WaitSeconds 0
    $firstClock.Stop()
    Assert-Equal 0 $first.ExitCode "first controller call exits successfully while running; output=$($first.Text)"
    Assert-Equal 'running' ([string]$first.Result.status) 'first controller call returns running'
    Assert-True ($firstClock.Elapsed.TotalSeconds -lt 10) 'first controller call is short and detached'
    Wait-File -Path (Join-Path $survival.Iteration 'phase1-supervisor-runtime.json')
    $ownership = Read-TestJson -Path (Join-Path $survival.Iteration 'phase1-supervisor.json')
    Assert-True ($null -ne (Get-Process -Id ([int]$ownership.pid) -ErrorAction SilentlyContinue)) "supervisor remains alive after controller A exits; controller_elapsed=$($firstClock.Elapsed.TotalSeconds)"
    Start-Sleep -Milliseconds 300
    $second = Invoke-Controller -Package $survival -WaitSeconds 0
    Assert-Equal ([string]$first.Result.supervisor_id) ([string]$second.Result.supervisor_id) 'controller B observes the same supervisor id'
    Assert-Equal ([int]$first.Result.supervisor_pid) ([int]$second.Result.supervisor_pid) 'controller B observes the same supervisor pid while running'
    $terminal = Wait-ControllerTerminal -Package $survival
    Assert-Equal 0 $terminal.ExitCode 'surviving Phase 1 completes'
    Assert-Equal 'completed' ([string]$terminal.Result.status) 'surviving Phase 1 reports completed'
    Assert-True ([bool]$terminal.Result.freeze_exists) 'surviving Phase 1 writes the freeze'
    Assert-ExactlyOnce -Package $survival

    # Kill the waiting controller process after the supervisor runtime record
    # exists. The supervisor and fan-out must finish independently.
    $killed = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'caller-killed') -DelayMilliseconds 4000
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $killed.EventLog)
    $controllerStdout = Join-Path $killed.Iteration 'controller-a.stdout'
    $controllerStderr = Join-Path $killed.Iteration 'controller-a.stderr'
    $controllerProcess = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-File', ('"' + $killed.Controller + '"'), '-IterationDirectory', ('"' + $killed.Iteration + '"'), '-WaitSeconds', '60') -RedirectStandardOutput $controllerStdout -RedirectStandardError $controllerStderr -PassThru
    Wait-File -Path (Join-Path $killed.Iteration 'phase1-supervisor-runtime.json')
    $killedOwnership = Read-TestJson -Path (Join-Path $killed.Iteration 'phase1-supervisor.json')
    $controllerProcess.Kill($true)
    [void]$controllerProcess.WaitForExit(5000)
    Assert-True ($null -ne (Get-Process -Id ([int]$killedOwnership.pid) -ErrorAction SilentlyContinue)) 'supervisor remains alive after controller process is killed'
    $adopted = Invoke-Controller -Package $killed -WaitSeconds 0
    Assert-Equal ([string]$killedOwnership.supervisor_id) ([string]$adopted.Result.supervisor_id) 'new controller observes killed caller supervisor id'
    Assert-Equal ([int]$killedOwnership.pid) ([int]$adopted.Result.supervisor_pid) 'new controller observes killed caller supervisor pid'
    $killedTerminal = Wait-ControllerTerminal -Package $killed
    Assert-Equal 'completed' ([string]$killedTerminal.Result.status) 'Phase 1 completes after controller kill'
    Assert-ExactlyOnce -Package $killed

    if ($IsWindows) {
        # Closing the caller job (KILL_ON_JOB_CLOSE) must not kill the durable
        # supervisor when the controller job explicitly permits breakaway.
        $jobClose = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'job-close-survival') -DelayMilliseconds 4000
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $jobClose.EventLog)
        $jobHandle = $null
        $jobClosed = $false
        $harness = $null
        try {
            $jobHandle = New-WindowsJobObject -KillOnJobClose -BreakawayOk
            $harness = Start-ControllerHarnessInJob -Package $jobClose -Job $jobHandle -WaitSeconds 60
            Wait-File -Path (Join-Path $jobClose.Iteration 'phase1-supervisor.json')
            Wait-File -Path (Join-Path $jobClose.Iteration 'phase1-supervisor-runtime.json')
            $jobCloseOwnership = Read-TestJson -Path (Join-Path $jobClose.Iteration 'phase1-supervisor.json')
            Assert-Equal 'committed' (Get-RunnerOwnedPhaseOneOwnershipState -Ownership $jobCloseOwnership) 'breakaway-enabled job commits Phase 1 ownership'
            [void](Assert-RunnerOwnedPhaseOneOwnershipRecord -IterationDirectory $jobClose.Iteration -Ownership $jobCloseOwnership -Manifest (Read-TestJson -Path (Join-Path $jobClose.Iteration 'manifest.json')) -ProfilePath (Join-Path $jobClose.Iteration 'execution-profile.json'))
            $jobMetadata = Get-JsonProperty -Object $jobCloseOwnership -Name 'windows_job' -Default $null
            Assert-True ([bool](Get-JsonProperty -Object $jobMetadata -Name 'breakaway_required' -Default $false)) 'breakaway-enabled job requires Windows job detachment'
            Assert-True ([bool](Get-JsonProperty -Object $jobMetadata -Name 'breakaway_requested' -Default $false)) 'breakaway-enabled job requests CREATE_BREAKAWAY_FROM_JOB'
            Assert-True ([bool](Get-JsonProperty -Object $jobMetadata -Name 'breakaway_succeeded' -Default $false)) 'breakaway-enabled job records successful detachment'
            Assert-True (-not [bool](Get-JsonProperty -Object $jobMetadata -Name 'supervisor_in_controller_job' -Default $true)) 'breakaway-enabled job proves the supervisor escaped the controller job'
            Assert-True (-not (Test-WindowsProcessInJobObject -Job $jobHandle -ProcessId ([int]$jobCloseOwnership.pid))) 'breakaway-enabled job proves the supervisor is not in the caller job before closure'
            $preCloseIdentity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId ([int]$jobCloseOwnership.pid)
            Close-WindowsHandle -Handle $jobHandle
            $jobClosed = $true
            Assert-True ([bool]$harness.Process.WaitForExit(5000)) 'KILL_ON_JOB_CLOSE terminates the caller harness/controller job'
            Assert-True ($null -ne (Get-Process -Id ([int]$jobCloseOwnership.pid) -ErrorAction SilentlyContinue)) 'durable supervisor survives caller job closure'
            $postCloseIdentity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId ([int]$jobCloseOwnership.pid)
            Assert-Equal $preCloseIdentity.StartTicksUtc $postCloseIdentity.StartTicksUtc 'job-close survival preserves the exact supervisor process identity'
            $jobCloseObserved = Invoke-Controller -Package $jobClose -WaitSeconds 0
            Assert-Equal ([string]$jobCloseOwnership.supervisor_id) ([string]$jobCloseObserved.Result.supervisor_id) 'new controller observes the same supervisor id after caller job closure'
            Assert-Equal ([int]$jobCloseOwnership.pid) ([int]$jobCloseObserved.Result.supervisor_pid) 'new controller observes the same supervisor pid after caller job closure'
            $jobCloseTerminal = Wait-ControllerTerminal -Package $jobClose
            Assert-Equal 0 $jobCloseTerminal.ExitCode 'breakaway-enabled caller-job closure still completes Phase 1'
            Assert-Equal 'completed' ([string]$jobCloseTerminal.Result.status) 'breakaway-enabled caller-job closure reports completed'
            Assert-True ([bool]$jobCloseTerminal.Result.freeze_exists) 'breakaway-enabled caller-job closure writes the freeze'
            Assert-ExactlyOnce -Package $jobClose
        } finally {
            if ($null -ne $harness) {
                try {
                    if (-not $harness.Process.HasExited) { $harness.Process.Kill($true) }
                } catch { }
                $harness.Process.Dispose()
            }
            if ($null -ne $jobHandle -and -not $jobClosed) { Close-WindowsHandle -Handle $jobHandle }
        }

        # A controller inside a non-breakaway caller job must fail before any
        # runtime, fan-out, preflight, execute, or freeze work begins.
        $jobForbidden = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'job-breakaway-forbidden') -DelayMilliseconds 4000
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $jobForbidden.EventLog)
        $forbiddenJobHandle = $null
        $forbiddenJobClosed = $false
        $forbiddenHarness = $null
        try {
            $forbiddenJobHandle = New-WindowsJobObject -KillOnJobClose
            $forbiddenHarness = Start-ControllerHarnessInJob -Package $jobForbidden -Job $forbiddenJobHandle -WaitSeconds 0
            Assert-True ([bool]$forbiddenHarness.Process.WaitForExit(15000)) 'breakaway-forbidden controller exits deterministically'
            $forbiddenText = (Read-TestText -Path $forbiddenHarness.StdoutPath).Trim()
            Assert-True (-not [string]::IsNullOrWhiteSpace($forbiddenText)) 'breakaway-forbidden controller emits machine-readable failure'
            $forbiddenDocument = $forbiddenText | ConvertFrom-Json -Depth 100
            Assert-Equal 2 $forbiddenHarness.Process.ExitCode 'breakaway-forbidden controller exits non-zero'
            Assert-Equal 'failed' ([string]$forbiddenDocument.status) 'breakaway-forbidden controller reports failed'
            Assert-True ([string]$forbiddenDocument.error -match 'Durable Phase 1 cannot escape the caller Windows Job Object') 'breakaway-forbidden controller names the Windows Job Object detachment failure'
            $forbiddenOwnership = Read-TestJson -Path (Join-Path $jobForbidden.Iteration 'phase1-supervisor.json')
            Assert-Equal 'failed' (Get-RunnerOwnedPhaseOneOwnershipState -Ownership $forbiddenOwnership) 'breakaway-forbidden ownership is recorded as failed, not committed'
            $forbiddenJobMetadata = Get-JsonProperty -Object $forbiddenOwnership -Name 'windows_job' -Default $null
            Assert-True ([bool](Get-JsonProperty -Object $forbiddenJobMetadata -Name 'breakaway_required' -Default $false)) 'breakaway-forbidden controller records that Windows detachment was required'
            Assert-True (-not [bool](Get-JsonProperty -Object $forbiddenJobMetadata -Name 'controller_job_breakaway_ok' -Default $false)) 'breakaway-forbidden controller records that the job did not permit BREAKAWAY_OK'
            Assert-True (-not [bool](Get-JsonProperty -Object $forbiddenJobMetadata -Name 'controller_job_silent_breakaway_ok' -Default $false)) 'breakaway-forbidden controller records that the job did not permit SILENT_BREAKAWAY_OK'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobForbidden.Iteration 'phase1-supervisor-runtime.json') -PathType Leaf)) 'breakaway-forbidden controller writes no runtime record'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobForbidden.Iteration 'orchestration-state.json') -PathType Leaf)) 'breakaway-forbidden controller writes no orchestration state'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobForbidden.Iteration 'phase1-fanout-invocation.json') -PathType Leaf)) 'breakaway-forbidden controller starts no fan-out'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $jobForbidden.Iteration 'execution-freeze.json') -PathType Leaf)) 'breakaway-forbidden controller writes no execution freeze'
            Assert-True (-not (Test-Path -LiteralPath $jobForbidden.EventLog -PathType Leaf)) 'breakaway-forbidden controller emits no preflight or execute events'
            $forbiddenAgain = Invoke-Controller -Package $jobForbidden -WaitSeconds 0
            Assert-Equal 2 $forbiddenAgain.ExitCode 'repeat controller call keeps the breakaway-forbidden package failed'
            Assert-Equal 'failed' ([string]$forbiddenAgain.Result.status) 'repeat controller call keeps the breakaway-forbidden package terminal'
            Assert-Equal ([string]$forbiddenOwnership.supervisor_id) ([string]$forbiddenAgain.Result.supervisor_id) 'repeat controller call observes the same failed supervisor ownership'
            Assert-True ([string]$forbiddenAgain.Result.error -match 'Durable Phase 1 cannot escape the caller Windows Job Object') 'repeat controller call preserves the Windows job detachment failure'
        } finally {
            if ($null -ne $forbiddenHarness) {
                try {
                    if (-not $forbiddenHarness.Process.HasExited) { $forbiddenHarness.Process.Kill($true) }
                } catch { }
                $forbiddenHarness.Process.Dispose()
            }
            if ($null -ne $forbiddenJobHandle -and -not $forbiddenJobClosed) { Close-WindowsHandle -Handle $forbiddenJobHandle }
        }
    }

    # Concurrent and sequential controller calls race through one exclusive
    # ownership lock and all observe one supervisor.
    $race = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'controller-race') -DelayMilliseconds 3000
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $race.EventLog)
    $raceProcesses = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 4; $index++) {
        $out = Join-Path $race.Iteration "race-$index.stdout"
        $err = Join-Path $race.Iteration "race-$index.stderr"
        $process = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-File', ('"' + $race.Controller + '"'), '-IterationDirectory', ('"' + $race.Iteration + '"'), '-WaitSeconds', '0') -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
        $raceProcesses.Add([pscustomobject]@{ Process = $process; Out = $out; Err = $err })
    }
    $raceIds = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $raceProcesses) {
        [void]$entry.Process.WaitForExit(15000)
        Assert-Equal 0 $entry.Process.ExitCode "concurrent controller $($entry.Process.Id) exits running/success"
        $raceResult = Read-TestJson -Path $entry.Out
        $raceIds.Add([string]$raceResult.supervisor_id)
    }
    Assert-Equal 1 @($raceIds | Select-Object -Unique).Count 'concurrent controller calls create one supervisor id'
    $raceTerminal = Wait-ControllerTerminal -Package $race
    Assert-Equal 'completed' ([string]$raceTerminal.Result.status) 'raced controller package completes'
    Assert-ExactlyOnce -Package $race

    # Direct raw fan-out is rejected before state, preflight, or execution.
    $direct = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'direct-fanout') -DelayMilliseconds 0
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $direct.EventLog)
    $directOutput = & pwsh -NoProfile -File $direct.Fanout -IterationDirectory $direct.Iteration 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'direct fan-out without supervisor ownership fails'
    Assert-True ([string]::Join(' ', @($directOutput)) -match 'Direct runner-owned fan-out invocation is forbidden') 'direct fan-out names the controller boundary'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $direct.Iteration 'orchestration-state.json') -PathType Leaf)) 'direct fan-out creates no orchestration state'
    Assert-True (-not (Test-Path -LiteralPath $direct.EventLog -PathType Leaf)) 'direct fan-out performs no preflight or execute'

    # Prepared tool integrity is the existing package integrity boundary. A
    # changed controller/supervisor/fan-out tree cannot acquire ownership.
    $tamperedTools = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'tampered-tools') -DelayMilliseconds 0
    [IO.File]::AppendAllText((Join-Path $tamperedTools.Iteration 'tools/eval-runners/supervise-runner-owned-phase1.ps1'), "`n# tampered", [Text.UTF8Encoding]::new($false))
    $tamperedStatus = Invoke-Controller -Package $tamperedTools -WaitSeconds 0
    Assert-Equal 2 $tamperedStatus.ExitCode 'tampered package-local supervisor exits 2'
    Assert-Equal 'failed' ([string]$tamperedStatus.Result.status) 'tampered package-local supervisor reports failed'
    Assert-True ([string]$tamperedStatus.Result.error -match 'tools changed after preparation') 'tool-tree integrity identifies package mutation'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tamperedTools.Iteration 'phase1-supervisor.json') -PathType Leaf)) 'tool-tree mutation creates no supervisor ownership'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $tamperedTools.Iteration 'orchestration-state.json') -PathType Leaf)) 'tool-tree mutation starts no Phase 1 work'

    # A valid ownership identity whose exact process has died is fail-closed and
    # is never replaced. This package intentionally has no final result/freeze.
    $dead = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'dead-supervisor') -DelayMilliseconds 0
    $shortProcess = Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 500') -PassThru
    $shortIdentity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId $shortProcess.Id
    $deadSupervisorId = [Guid]::NewGuid().ToString('D')
    Write-TestJson -Path (Join-Path $dead.Iteration 'phase1-supervisor.json') -Value ([ordered]@{
        schema = 'codebeltnet/agentic/runner-owned-phase1-supervisor/1'; supervisor_id = $deadSupervisorId
        ownership_state = 'committed'
        iteration = [ordered]@{ path = $dead.Iteration; skill_name = 'lifecycle-fixture'; number = 1 }
        manifest_sha256 = Get-Sha256HexFromFile -Path (Join-Path $dead.Iteration 'manifest.json')
        profile_sha256 = Get-Sha256HexFromFile -Path (Join-Path $dead.Iteration 'execution-profile.json')
        pid = $shortIdentity.Pid; process_started_utc = $shortIdentity.StartedUtcText; process_start_ticks_utc = $shortIdentity.StartTicksUtc
        process_executable = $shortIdentity.ExecutablePath; process_executable_sha256 = $shortIdentity.ExecutableSha256
        started_utc = [DateTime]::UtcNow.ToString('o')
        internal_fanout = [ordered]@{ path = $dead.Fanout; sha256 = Get-Sha256HexFromFile -Path $dead.Fanout }
        supervisor = [ordered]@{ path = Join-Path (Split-Path -Parent $dead.Fanout) 'supervise-runner-owned-phase1.ps1'; sha256 = Get-Sha256HexFromFile -Path (Join-Path (Split-Path -Parent $dead.Fanout) 'supervise-runner-owned-phase1.ps1') }
        controller = [ordered]@{ path = $dead.Controller; sha256 = Get-Sha256HexFromFile -Path $dead.Controller }
        windows_job = if ($IsWindows) { [ordered]@{
                controller_in_job = $false
                controller_job_kill_on_close = $false
                controller_job_breakaway_ok = $false
                controller_job_silent_breakaway_ok = $false
                durable_parent_pid = 0
                durable_parent_in_job = $false
                breakaway_required = $false
                breakaway_requested = $false
                supervisor_in_controller_job = $false
                supervisor_in_any_job = $false
                breakaway_succeeded = $true
            }
        } else { $null }
        final_result_path = 'phase1-supervisor-result.json'; stdout_path = 'phase1-supervisor.stdout.log'; stderr_path = 'phase1-supervisor.stderr.log'
    })
    [void]$shortProcess.WaitForExit(5000)
    $deadStatus = Invoke-Controller -Package $dead -WaitSeconds 0
    Assert-Equal 2 $deadStatus.ExitCode 'dead supervisor without result exits 2'
    Assert-Equal 'failed' ([string]$deadStatus.Result.status) 'dead supervisor without result reports failed'
    Assert-True ([string]$deadStatus.Result.error -match 'died without a valid final result') 'dead supervisor failure requires a fresh package'
    Assert-Equal $deadSupervisorId ([string](Read-TestJson -Path (Join-Path $dead.Iteration 'phase1-supervisor.json')).supervisor_id) 'dead supervisor ownership is not replaced'

    # Terminal calls are read-only: freeze, raw evidence, and orchestration state
    # remain byte-identical and no process is restarted.
    $terminalPaths = @((Join-Path $survival.Iteration 'execution-freeze.json'), (Join-Path $survival.Iteration 'orchestration-state.json')) + @(Get-ChildItem -LiteralPath $survival.Iteration -Recurse -File -Filter 'execution-result.json' | ForEach-Object FullName)
    $terminalHashes = @{}
    foreach ($path in $terminalPaths) { $terminalHashes[$path] = Get-Sha256HexFromFile -Path $path }
    $terminalAgain = Invoke-Controller -Package $survival -WaitSeconds 0
    Assert-Equal 'completed' ([string]$terminalAgain.Result.status) 'terminal controller call returns completed again'
    Assert-Equal ([string]$first.Result.supervisor_id) ([string]$terminalAgain.Result.supervisor_id) 'terminal controller call preserves supervisor id'
    foreach ($path in $terminalPaths) { Assert-Equal $terminalHashes[$path] (Get-Sha256HexFromFile -Path $path) "terminal controller call does not mutate $path" }

    Write-Output 'Runner-owned Phase 1 controller lifecycle: PASS'
} finally {
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $oldEventLog)
    if (Test-Path -LiteralPath $testRoot) {
        foreach ($ownershipFile in @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter 'phase1-supervisor.json' -ErrorAction SilentlyContinue)) {
            try {
                $record = Read-TestJson -Path $ownershipFile.FullName
                $process = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
                if ($null -ne $process -and $process.StartTime.ToUniversalTime().Ticks -eq [int64]$record.process_start_ticks_utc) { $process.Kill($true) }
            } catch { }
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
