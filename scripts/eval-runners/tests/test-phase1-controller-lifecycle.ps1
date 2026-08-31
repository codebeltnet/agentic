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
function ConvertTo-TestPowerShellLiteral([string]$Value) { return "'" + [string]$Value.Replace("'", "''") + "'" }

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

    $invocation = Start-ControllerHarness -Package $Package -WaitSeconds $WaitSeconds -HarnessDirectoryName ('controller-invocation-' + [Guid]::NewGuid().ToString('N')) -CaptureControllerPid $false
    $exitCode = Wait-TestPowerShellInvocation -Invocation $invocation -TimeoutSeconds ([Math]::Max(15, $WaitSeconds + 15))
    $outputBlocks = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $invocation.ControllerStdoutPath -PathType Leaf) { $outputBlocks.Add((Read-TestText -Path $invocation.ControllerStdoutPath)) }
    if (Test-Path -LiteralPath $invocation.ControllerStderrPath -PathType Leaf) { $outputBlocks.Add((Read-TestText -Path $invocation.ControllerStderrPath)) }
    $text = [string]::Join([Environment]::NewLine, @($outputBlocks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
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

function Start-TestPowerShellScriptProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][string]$ExitCodePath
    )

    foreach ($directory in @((Split-Path -Parent $StdoutPath), (Split-Path -Parent $StderrPath), (Split-Path -Parent $ExitCodePath))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    foreach ($artifact in @($StdoutPath, $StderrPath, $ExitCodePath)) {
        if (Test-Path -LiteralPath $artifact -PathType Leaf) { Remove-Item -LiteralPath $artifact -Force }
    }

    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    $invocationText = '& ' + (ConvertTo-TestPowerShellLiteral $ScriptPath)
    $fixtureLogValue = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG')
    $fixtureLogSetup = if ([string]::IsNullOrWhiteSpace($fixtureLogValue)) {
        "Remove-Item Env:AGENTIC_RUNNER_FIXTURE_LOG -ErrorAction SilentlyContinue"
    } else {
        "`$env:AGENTIC_RUNNER_FIXTURE_LOG = $(ConvertTo-TestPowerShellLiteral $fixtureLogValue)"
    }
    foreach ($argument in @($Arguments)) {
        $argumentText = [string]$argument
        if ($argumentText -match '^-[A-Za-z0-9_-]+$') {
            $invocationText += ' ' + $argumentText
        } else {
            $invocationText += ' ' + (ConvertTo-TestPowerShellLiteral $argumentText)
        }
    }
    $commandText = @"
`$ErrorActionPreference = 'Stop'
$fixtureLogSetup
`$stdoutWriter = [System.IO.StreamWriter]::new($(ConvertTo-TestPowerShellLiteral $StdoutPath), `$false, [System.Text.UTF8Encoding]::new(`$false))
`$stderrWriter = [System.IO.StreamWriter]::new($(ConvertTo-TestPowerShellLiteral $StderrPath), `$false, [System.Text.UTF8Encoding]::new(`$false))
`$stdoutWriter.AutoFlush = `$true
`$stderrWriter.AutoFlush = `$true
[Console]::SetOut(`$stdoutWriter)
[Console]::SetError(`$stderrWriter)
`$testExitCode = 1
try {
    $invocationText
    if (`$null -eq `$LASTEXITCODE) { `$testExitCode = 0 } else { `$testExitCode = [int]`$LASTEXITCODE }
} catch {
    if (`$LASTEXITCODE -is [int] -and `$LASTEXITCODE -ne 0) { `$testExitCode = [int]`$LASTEXITCODE } else { `$testExitCode = 1 }
    [Console]::Error.WriteLine(`$_.Exception.ToString())
}
try { `$stdoutWriter.Flush() } catch { }
try { `$stderrWriter.Flush() } catch { }
[System.IO.File]::WriteAllText($(ConvertTo-TestPowerShellLiteral $ExitCodePath), [string]`$testExitCode, [System.Text.UTF8Encoding]::new(`$false))
try { `$stdoutWriter.Dispose() } catch { }
try { `$stderrWriter.Dispose() } catch { }
exit `$testExitCode
"@
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))
    if ($IsWindows) {
        $create = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = ('"' + $pwshPath + '" -NoProfile -NonInteractive -EncodedCommand ' + $encodedCommand)
            CurrentDirectory = $WorkingDirectory
        }
        if ([int]$create.ReturnValue -ne 0 -or [int]$create.ProcessId -lt 1) {
            throw "Win32_Process.Create failed for '$ScriptPath' with return code $($create.ReturnValue)."
        }
        $process = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        do {
            $process = Get-Process -Id ([int]$create.ProcessId) -ErrorAction SilentlyContinue
            if ($null -ne $process) { break }
            Start-Sleep -Milliseconds 25
        } while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $ExitCodePath -PathType Leaf))
        return [pscustomobject]@{
            Process = $process
            ProcessId = [int]$create.ProcessId
            StdoutPath = $StdoutPath
            StderrPath = $StderrPath
            ExitCodePath = $ExitCodePath
        }
    }

    $process = Start-Process -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand) -WorkingDirectory $WorkingDirectory -PassThru
    return [pscustomobject]@{
        Process = $process
        ProcessId = [int]$process.Id
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
        ExitCodePath = $ExitCodePath
    }
}

function Wait-TestPowerShellInvocation {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    if ($null -ne $Invocation.Process) {
        try {
            if ($Invocation.Process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
                if (-not (Test-Path -LiteralPath $Invocation.ExitCodePath -PathType Leaf)) { Wait-File -Path $Invocation.ExitCodePath -TimeoutSeconds 5 }
                return [int]((Read-TestText -Path $Invocation.ExitCodePath).Trim())
            }
        } finally {
            $Invocation.Process.Dispose()
            $Invocation.Process = $null
        }
    }

    do {
        if (Test-Path -LiteralPath $Invocation.ExitCodePath -PathType Leaf) {
            return [int]((Read-TestText -Path $Invocation.ExitCodePath).Trim())
        }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for isolated PowerShell script PID $($Invocation.ProcessId) to finish."
}

function New-ControllerJobHarnessScript {
    param([Parameter(Mandatory = $true)][string]$Path)

    $script = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ControllerPath,
    [Parameter(Mandatory = $true)][string]$IterationDirectory,
    [Parameter(Mandatory = $true)][string]$ControllerStdoutPath,
    [Parameter(Mandatory = $true)][string]$ControllerStderrPath,
    [string]$GatePath = '',
    [string]$ControllerPidPath = '',
    [int]$WaitSeconds = 60
)

$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($GatePath)) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $GatePath -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw "Timed out waiting for '$GatePath'." }
        Start-Sleep -Milliseconds 25
    }
}

$pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
$controller = Start-Process -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $ControllerPath, '-IterationDirectory', $IterationDirectory, '-WaitSeconds', [string]$WaitSeconds) -RedirectStandardOutput $ControllerStdoutPath -RedirectStandardError $ControllerStderrPath -PassThru
try {
    if (-not [string]::IsNullOrWhiteSpace($ControllerPidPath)) {
        [IO.File]::WriteAllText($ControllerPidPath, [string]$controller.Id, [Text.UTF8Encoding]::new($false))
    }
    if (-not $controller.WaitForExit([Math]::Max(15, $WaitSeconds + 15) * 1000)) {
        throw "Timed out waiting for controller PID $($controller.Id)."
    }
    exit $controller.ExitCode
} finally {
    $controller.Dispose()
}
'@
    [IO.File]::WriteAllText($Path, $script, [Text.UTF8Encoding]::new($false))
}

function Start-ControllerHarness {
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [int]$WaitSeconds = 60,
        [string]$HarnessDirectoryName = 'job-harness',
        [bool]$UseGate = $false,
        [bool]$CaptureControllerPid = $true
    )

    $harnessRoot = Join-Path $Package.Iteration $HarnessDirectoryName
    New-Item -ItemType Directory -Path $harnessRoot -Force | Out-Null
    $gatePath = Join-Path $harnessRoot 'launch.gate'
    $scriptPath = Join-Path $harnessRoot 'harness.ps1'
    $stdoutPath = Join-Path $harnessRoot 'harness.stdout'
    $stderrPath = Join-Path $harnessRoot 'harness.stderr'
    $controllerStdoutPath = Join-Path $harnessRoot 'controller.stdout'
    $controllerStderrPath = Join-Path $harnessRoot 'controller.stderr'
    $controllerPidPath = Join-Path $harnessRoot 'controller.pid'
    New-ControllerJobHarnessScript -Path $scriptPath
    $arguments = [System.Collections.Generic.List[string]]::new()
    if ($UseGate) {
        $arguments.Add('-GatePath')
        $arguments.Add($gatePath)
    }
    if ($CaptureControllerPid) {
        $arguments.Add('-ControllerPidPath')
        $arguments.Add($controllerPidPath)
    }
    foreach ($value in @(
            '-ControllerPath', $Package.Controller,
            '-IterationDirectory', $Package.Iteration,
            '-ControllerStdoutPath', $controllerStdoutPath,
            '-ControllerStderrPath', $controllerStderrPath,
            '-WaitSeconds', [string]$WaitSeconds
        )) {
        $arguments.Add([string]$value)
    }
    $processInfo = Start-TestPowerShellScriptProcess -ScriptPath $scriptPath -Arguments $arguments.ToArray() -WorkingDirectory $Package.Iteration -StdoutPath $stdoutPath -StderrPath $stderrPath -ExitCodePath (Join-Path $harnessRoot 'harness.exitcode')
    return [pscustomobject]@{
        Process = $processInfo.Process
        ProcessId = $processInfo.ProcessId
        ExitCodePath = $processInfo.ExitCodePath
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        ControllerStdoutPath = $controllerStdoutPath
        ControllerStderrPath = $controllerStderrPath
        ControllerPidPath = $controllerPidPath
        GatePath = $gatePath
        ScriptPath = $scriptPath
    }
}

function Start-ControllerHarnessInJob {
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][object]$Job,
        [int]$WaitSeconds = 60
    )

    return Start-ControllerHarnessInJobs -Package $Package -Jobs @($Job) -WaitSeconds $WaitSeconds
}

function Start-ControllerHarnessInJobs {
    param(
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][object[]]$Jobs,
        [int]$WaitSeconds = 60
    )

    if (@($Jobs).Count -lt 1) { throw 'At least one Windows Job Object is required.' }
    $harness = Start-ControllerHarness -Package $Package -WaitSeconds $WaitSeconds -HarnessDirectoryName 'job-harness' -UseGate $true
    $process = $harness.Process
    if ($null -eq $process) { throw "Could not capture the job-harness process for '$($Package.Iteration)'." }
    try {
        foreach ($job in @($Jobs)) { Add-WindowsProcessToJobObject -Job $job -ProcessId $process.Id }
    } catch {
        try {
            if (-not $process.HasExited) { $process.Kill($true) }
        } catch {         }
        $process.Dispose()
        throw
    }
    [IO.File]::WriteAllText($harness.GatePath, "go`n", [Text.UTF8Encoding]::new($false))
    return $harness
}

function Wait-RunnerOwnedPhaseOneProcessIdentityGone {
    param(
        [Parameter(Mandatory = $true)][object]$Ownership,
        [int]$TimeoutSeconds = 10
    )

    $pidValue = [int](Get-JsonProperty -Object $Ownership -Name 'pid' -Default 0)
    if ($pidValue -lt 1) { throw 'phase1-supervisor.json does not contain a valid supervisor PID.' }
    $expectedTicks = [int64](Get-JsonProperty -Object $Ownership -Name 'process_start_ticks_utc' -Default 0)
    if ($expectedTicks -lt 1) { throw 'phase1-supervisor.json does not contain a valid supervisor process identity.' }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if ($null -eq $process) { return }
        try {
            if ($process.StartTime.ToUniversalTime().Ticks -ne $expectedTicks) { return }
        } finally {
            $process.Dispose()
        }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for supervisor PID $pidValue to exit."
}

function Get-NestedWindowsJobSkipReason {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)

    $baseException = $Exception.GetBaseException()
    if ($baseException -is [System.ComponentModel.Win32Exception]) {
        return "Win32 error $($baseException.NativeErrorCode): $($baseException.Message)"
    }
    return $baseException.Message
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
    $controllerHarness = Start-ControllerHarness -Package $killed -WaitSeconds 60 -HarnessDirectoryName 'controller-kill-harness'
    $controllerProcessIdPath = $controllerHarness.ControllerPidPath
    Wait-File -Path $controllerProcessIdPath
    $controllerProcessId = [int]((Read-TestText -Path $controllerProcessIdPath).Trim())
    $controllerProcess = Get-Process -Id $controllerProcessId -ErrorAction Stop
    Wait-File -Path (Join-Path $killed.Iteration 'phase1-supervisor-runtime.json')
    $killedOwnership = Read-TestJson -Path (Join-Path $killed.Iteration 'phase1-supervisor.json')
    $controllerProcess.Kill($true)
    [void]$controllerProcess.WaitForExit(5000)
    $controllerProcess.Dispose()
    [void](Wait-TestPowerShellInvocation -Invocation $controllerHarness -TimeoutSeconds 15)
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
            Assert-True (-not [bool](Get-JsonProperty -Object $jobMetadata -Name 'supervisor_in_any_job' -Default $true)) 'breakaway-enabled job proves the supervisor escaped every Windows Job Object'
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
            $forbiddenText = (Read-TestText -Path $forbiddenHarness.ControllerStdoutPath).Trim()
            Assert-True (-not [string]::IsNullOrWhiteSpace($forbiddenText)) 'breakaway-forbidden controller emits machine-readable failure'
            $forbiddenDocument = $forbiddenText | ConvertFrom-Json -Depth 100
            Assert-Equal 2 ([int]((Read-TestText -Path $forbiddenHarness.ExitCodePath).Trim())) 'breakaway-forbidden controller exits non-zero'
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

        $nestedJobSkipReason = $null

        # A nested controller job that permits breakaway locally but is still
        # inside an outer non-breakaway job must fail before any Phase 1 work.
        $nestedForbidden = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'job-nested-breakaway-forbidden') -DelayMilliseconds 4000
        [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $nestedForbidden.EventLog)
        $nestedOuterForbiddenHandle = $null
        $nestedInnerForbiddenHandle = $null
        $nestedForbiddenHarness = $null
        try {
            $nestedOuterForbiddenHandle = New-WindowsJobObject -KillOnJobClose
            $nestedInnerForbiddenHandle = New-WindowsJobObject -BreakawayOk
            try {
                $nestedForbiddenHarness = Start-ControllerHarnessInJobs -Package $nestedForbidden -Jobs @($nestedOuterForbiddenHandle, $nestedInnerForbiddenHandle) -WaitSeconds 0
            } catch {
                $nestedJobSkipReason = Get-NestedWindowsJobSkipReason -Exception $_.Exception
            }
            if ($null -eq $nestedJobSkipReason) {
                Assert-True ([bool]$nestedForbiddenHarness.Process.WaitForExit(15000)) 'nested breakaway controller exits deterministically'
                $nestedForbiddenText = (Read-TestText -Path $nestedForbiddenHarness.ControllerStdoutPath).Trim()
                Assert-True (-not [string]::IsNullOrWhiteSpace($nestedForbiddenText)) 'nested breakaway controller emits machine-readable failure'
                $nestedForbiddenDocument = $nestedForbiddenText | ConvertFrom-Json -Depth 100
                Assert-Equal 2 ([int]((Read-TestText -Path $nestedForbiddenHarness.ExitCodePath).Trim())) 'nested breakaway controller exits non-zero'
                Assert-Equal 'failed' ([string]$nestedForbiddenDocument.status) 'nested breakaway controller reports failed'
                Assert-True ([string]$nestedForbiddenDocument.error -match 'Durable Phase 1 cannot escape the caller Windows Job Object') 'nested breakaway controller names the Windows Job Object detachment failure'
                Wait-File -Path (Join-Path $nestedForbidden.Iteration 'phase1-supervisor.json')
                $nestedForbiddenManifest = Read-TestJson -Path (Join-Path $nestedForbidden.Iteration 'manifest.json')
                $nestedForbiddenOwnership = Read-TestJson -Path (Join-Path $nestedForbidden.Iteration 'phase1-supervisor.json')
                Assert-Equal 'failed' (Get-RunnerOwnedPhaseOneOwnershipState -Ownership $nestedForbiddenOwnership) 'nested breakaway ownership is recorded as failed, not committed'
                $nestedForbiddenJobMetadata = Get-JsonProperty -Object $nestedForbiddenOwnership -Name 'windows_job' -Default $null
                Assert-True ([bool](Get-JsonProperty -Object $nestedForbiddenJobMetadata -Name 'controller_in_job' -Default $false)) 'nested breakaway controller records that the controller ran inside a Windows Job Object'
                Assert-True ([bool](Get-JsonProperty -Object $nestedForbiddenJobMetadata -Name 'controller_job_breakaway_ok' -Default $false)) 'nested breakaway controller records that the immediate controller job permitted BREAKAWAY_OK'
                Assert-True ([bool](Get-JsonProperty -Object $nestedForbiddenJobMetadata -Name 'breakaway_required' -Default $false)) 'nested breakaway controller records that Windows detachment was required'
                Assert-True ([bool](Get-JsonProperty -Object $nestedForbiddenJobMetadata -Name 'breakaway_requested' -Default $false)) 'nested breakaway controller requests CREATE_BREAKAWAY_FROM_JOB'
                Assert-True (-not [bool](Get-JsonProperty -Object $nestedForbiddenJobMetadata -Name 'supervisor_in_controller_job' -Default $true)) 'nested breakaway controller proves the supervisor escaped the immediate controller job'
                Assert-True ([bool](Get-JsonProperty -Object $nestedForbiddenJobMetadata -Name 'supervisor_in_any_job' -Default $false)) 'nested breakaway controller proves the supervisor remained inside another Windows Job Object'
                Assert-True (-not [bool](Get-JsonProperty -Object $nestedForbiddenJobMetadata -Name 'breakaway_succeeded' -Default $true)) 'nested breakaway controller refuses to treat outer-job membership as durable detachment'
                Assert-True ([int](Get-JsonProperty -Object $nestedForbiddenOwnership -Name 'pid' -Default 0) -gt 0) 'nested breakaway controller records the candidate supervisor pid before failing ownership'
                Wait-RunnerOwnedPhaseOneProcessIdentityGone -Ownership $nestedForbiddenOwnership
                $nestedValidatorProbe = Read-TestJson -Path (Join-Path $nestedForbidden.Iteration 'phase1-supervisor.json')
                $nestedValidatorProbe.ownership_state = 'committed'
                $nestedValidatorProbe.failure = $null
                $nestedValidatorRejected = $false
                try {
                    [void](Assert-RunnerOwnedPhaseOneOwnershipRecord -IterationDirectory $nestedForbidden.Iteration -Ownership $nestedValidatorProbe -Manifest $nestedForbiddenManifest -ProfilePath (Join-Path $nestedForbidden.Iteration 'execution-profile.json'))
                } catch {
                    $nestedValidatorRejected = $true
                    Assert-True ($_.Exception.Message -match 'Windows Job Object independence') 'ownership validation rejects a committed record that still reports supervisor_in_any_job=true'
                }
                Assert-True $nestedValidatorRejected 'ownership validation rejects committed nested ownership that remains in any Windows Job Object'
                foreach ($relativePath in @('phase1-supervisor-runtime.json', 'orchestration-state.json', 'phase1-fanout-invocation.json', 'execution-freeze.json')) {
                    Assert-True (-not (Test-Path -LiteralPath (Join-Path $nestedForbidden.Iteration $relativePath) -PathType Leaf)) "nested breakaway controller does not create $relativePath"
                }
                Assert-True (-not (Test-Path -LiteralPath $nestedForbidden.EventLog -PathType Leaf)) 'nested breakaway controller emits no preflight or execute events'
                $nestedForbiddenAgain = Invoke-Controller -Package $nestedForbidden -WaitSeconds 0
                Assert-Equal 2 $nestedForbiddenAgain.ExitCode 'repeat controller call keeps the nested breakaway package failed'
                Assert-Equal 'failed' ([string]$nestedForbiddenAgain.Result.status) 'repeat controller call keeps the nested breakaway package terminal'
                Assert-Equal ([string]$nestedForbiddenOwnership.supervisor_id) ([string]$nestedForbiddenAgain.Result.supervisor_id) 'repeat controller call observes the same failed nested supervisor ownership'
                Assert-Equal ([int]$nestedForbiddenOwnership.pid) ([int]$nestedForbiddenAgain.Result.supervisor_pid) 'repeat controller call preserves the nested failed supervisor pid'
                Assert-True ([string]$nestedForbiddenAgain.Result.error -match 'Durable Phase 1 cannot escape the caller Windows Job Object') 'repeat controller call preserves the nested Windows job detachment failure'
                foreach ($relativePath in @('phase1-supervisor-runtime.json', 'orchestration-state.json', 'phase1-fanout-invocation.json', 'execution-freeze.json')) {
                    Assert-True (-not (Test-Path -LiteralPath (Join-Path $nestedForbidden.Iteration $relativePath) -PathType Leaf)) "repeat nested breakaway controller still does not create $relativePath"
                }
                Assert-True (-not (Test-Path -LiteralPath $nestedForbidden.EventLog -PathType Leaf)) 'repeat nested breakaway controller still emits no preflight or execute events'
            }
        } finally {
            if ($null -ne $nestedForbiddenHarness) {
                try {
                    if (-not $nestedForbiddenHarness.Process.HasExited) { $nestedForbiddenHarness.Process.Kill($true) }
                } catch { }
                $nestedForbiddenHarness.Process.Dispose()
            }
            if ($null -ne $nestedInnerForbiddenHandle) { Close-WindowsHandle -Handle $nestedInnerForbiddenHandle }
            if ($null -ne $nestedOuterForbiddenHandle) { Close-WindowsHandle -Handle $nestedOuterForbiddenHandle }
        }

        if ($null -ne $nestedJobSkipReason) {
            Write-Output "Nested Windows Job Object negative regression: SKIP ($nestedJobSkipReason)"
            Write-Output "Nested Windows Job Object positive regression: SKIP ($nestedJobSkipReason)"
        } else {
            # A nested caller-job chain where every job permits breakaway must
            # let the durable supervisor escape the full chain and survive.
            $nestedJobClose = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'job-nested-close-survival') -DelayMilliseconds 4000
            [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $nestedJobClose.EventLog)
            $nestedOuterJobHandle = $null
            $nestedInnerJobHandle = $null
            $nestedOuterJobClosed = $false
            $nestedHarness = $null
            try {
                $nestedOuterJobHandle = New-WindowsJobObject -KillOnJobClose -BreakawayOk
                $nestedInnerJobHandle = New-WindowsJobObject -BreakawayOk
                $nestedHarness = Start-ControllerHarnessInJobs -Package $nestedJobClose -Jobs @($nestedOuterJobHandle, $nestedInnerJobHandle) -WaitSeconds 60
                Wait-File -Path (Join-Path $nestedJobClose.Iteration 'phase1-supervisor.json')
                Wait-File -Path (Join-Path $nestedJobClose.Iteration 'phase1-supervisor-runtime.json')
                $nestedJobCloseManifest = Read-TestJson -Path (Join-Path $nestedJobClose.Iteration 'manifest.json')
                $nestedJobCloseOwnership = Read-TestJson -Path (Join-Path $nestedJobClose.Iteration 'phase1-supervisor.json')
                Assert-Equal 'committed' (Get-RunnerOwnedPhaseOneOwnershipState -Ownership $nestedJobCloseOwnership) 'nested breakaway-enabled job commits Phase 1 ownership'
                [void](Assert-RunnerOwnedPhaseOneOwnershipRecord -IterationDirectory $nestedJobClose.Iteration -Ownership $nestedJobCloseOwnership -Manifest $nestedJobCloseManifest -ProfilePath (Join-Path $nestedJobClose.Iteration 'execution-profile.json'))
                $nestedJobMetadata = Get-JsonProperty -Object $nestedJobCloseOwnership -Name 'windows_job' -Default $null
                Assert-True ([bool](Get-JsonProperty -Object $nestedJobMetadata -Name 'breakaway_required' -Default $false)) 'nested breakaway-enabled job requires Windows job detachment'
                Assert-True ([bool](Get-JsonProperty -Object $nestedJobMetadata -Name 'breakaway_requested' -Default $false)) 'nested breakaway-enabled job requests CREATE_BREAKAWAY_FROM_JOB'
                Assert-True ([bool](Get-JsonProperty -Object $nestedJobMetadata -Name 'breakaway_succeeded' -Default $false)) 'nested breakaway-enabled job records successful full-chain detachment'
                Assert-True (-not [bool](Get-JsonProperty -Object $nestedJobMetadata -Name 'supervisor_in_controller_job' -Default $true)) 'nested breakaway-enabled job proves the supervisor escaped the immediate controller job'
                Assert-True (-not [bool](Get-JsonProperty -Object $nestedJobMetadata -Name 'supervisor_in_any_job' -Default $true)) 'nested breakaway-enabled job proves the supervisor escaped every Windows Job Object'
                Assert-True (-not (Test-WindowsProcessInJobObject -Job $nestedOuterJobHandle -ProcessId ([int]$nestedJobCloseOwnership.pid))) 'nested breakaway-enabled job proves the supervisor is not in the outer caller job before closure'
                Assert-True (-not (Test-WindowsProcessInJobObject -Job $nestedInnerJobHandle -ProcessId ([int]$nestedJobCloseOwnership.pid))) 'nested breakaway-enabled job proves the supervisor is not in the inner caller job before closure'
                $nestedPreCloseIdentity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId ([int]$nestedJobCloseOwnership.pid)
                Close-WindowsHandle -Handle $nestedOuterJobHandle
                $nestedOuterJobClosed = $true
                Assert-True ([bool]$nestedHarness.Process.WaitForExit(5000)) 'nested KILL_ON_JOB_CLOSE terminates the caller harness/controller job'
                Assert-True ($null -ne (Get-Process -Id ([int]$nestedJobCloseOwnership.pid) -ErrorAction SilentlyContinue)) 'nested durable supervisor survives outer caller job closure'
                $nestedPostCloseIdentity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId ([int]$nestedJobCloseOwnership.pid)
                Assert-Equal $nestedPreCloseIdentity.StartTicksUtc $nestedPostCloseIdentity.StartTicksUtc 'nested job-close survival preserves the exact supervisor process identity'
                $nestedObserved = Invoke-Controller -Package $nestedJobClose -WaitSeconds 0
                Assert-Equal ([string]$nestedJobCloseOwnership.supervisor_id) ([string]$nestedObserved.Result.supervisor_id) 'new controller observes the same nested supervisor id after caller job closure'
                Assert-Equal ([int]$nestedJobCloseOwnership.pid) ([int]$nestedObserved.Result.supervisor_pid) 'new controller observes the same nested supervisor pid after caller job closure'
                $nestedTerminal = Wait-ControllerTerminal -Package $nestedJobClose
                Assert-Equal 0 $nestedTerminal.ExitCode 'nested breakaway-enabled caller-job closure still completes Phase 1'
                Assert-Equal 'completed' ([string]$nestedTerminal.Result.status) 'nested breakaway-enabled caller-job closure reports completed'
                Assert-True ([bool]$nestedTerminal.Result.freeze_exists) 'nested breakaway-enabled caller-job closure writes the freeze'
                Assert-ExactlyOnce -Package $nestedJobClose
            } finally {
                if ($null -ne $nestedHarness) {
                    try {
                        if (-not $nestedHarness.Process.HasExited) { $nestedHarness.Process.Kill($true) }
                    } catch { }
                    $nestedHarness.Process.Dispose()
                }
                if ($null -ne $nestedInnerJobHandle) { Close-WindowsHandle -Handle $nestedInnerJobHandle }
                if ($null -ne $nestedOuterJobHandle -and -not $nestedOuterJobClosed) { Close-WindowsHandle -Handle $nestedOuterJobHandle }
            }
        }
    }

    # Concurrent and sequential controller calls race through one exclusive
    # ownership lock and all observe one supervisor.
    $race = New-LifecyclePackage -IterationDirectory (Join-Path $testRoot 'controller-race') -DelayMilliseconds 3000
    [Environment]::SetEnvironmentVariable('AGENTIC_RUNNER_FIXTURE_LOG', $race.EventLog)
    $raceProcesses = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 4; $index++) {
        $invocation = Start-ControllerHarness -Package $race -WaitSeconds 0 -HarnessDirectoryName "race-$index-harness" -CaptureControllerPid $false
        $raceProcesses.Add($invocation)
    }
    $raceIds = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $raceProcesses) {
        $raceExitCode = Wait-TestPowerShellInvocation -Invocation $entry -TimeoutSeconds 15
        Assert-Equal 0 $raceExitCode "concurrent controller $($entry.ProcessId) exits running/success"
        $raceResult = Read-TestJson -Path $entry.ControllerStdoutPath
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
