<#!
.SYNOPSIS
    Starts or observes one durable runner-owned Phase 1 supervisor.

.DESCRIPTION
    This is the only external runner-owned Phase 1 control surface. Calls are
    short and idempotent: the first call creates one durable background
    supervisor, and every later call observes that exact process or its final
    result. A dead supervisor is never replaced for the same iteration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IterationDirectory,
    [ValidateRange(0, 60)][int]$WaitSeconds = 30
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$controlSchema = 'codebeltnet/agentic/runner-owned-phase1-control/1'
$clock = [Diagnostics.Stopwatch]::StartNew()
$iteration = $null
$ownership = $null
$manifest = $null
$profilePath = $null
$paths = $null

function Write-ControlStatus {
    param([Parameter(Mandatory = $true)][object]$Status)

    [Console]::Out.WriteLine(($Status | ConvertTo-Json -Depth 100 -Compress))
    if ([string]$Status.status -eq 'failed') { exit 2 }
    exit 0
}

function Get-ExpectedArmCount {
    param([object]$Manifest)

    if ($null -eq $Manifest) { return 0 }
    $count = 0
    foreach ($evalEntry in @(Get-JsonProperty -Object $Manifest -Name 'evals' -Default @())) {
        $runs = Get-JsonProperty -Object $evalEntry -Name 'runs' -Default $null
        $count += @(Get-JsonPropertyNames -Object $runs).Count
    }
    return $count
}

function Get-ProgressStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Error = '',
        [object]$FinalResult = $null
    )

    $expectedCount = Get-ExpectedArmCount -Manifest $manifest
    $state = $null
    if ($null -ne $paths -and (Test-Path -LiteralPath $paths.OrchestrationState -PathType Leaf)) {
        try { $state = Read-RunnerJson -Path $paths.OrchestrationState } catch { }
    }
    $entries = @(if ($null -ne $state) { Get-OrchestrationCompletedEntries -State $state })
    $activeCount = if ($null -eq $state) { 0 } else { @(Get-JsonPropertyNames -Object (Get-JsonProperty -Object $state -Name 'active' -Default $null)).Count }
    $pendingCount = if ($null -eq $state) { [Math]::Max(0, $expectedCount - $entries.Count - $activeCount) } else { @((Get-JsonProperty -Object $state -Name 'pending_worker_ids' -Default @())).Count }
    $aggregate = Get-FanoutPhase1Aggregate -ExpectedCount $expectedCount -State $state
    $runtimeExists = $null -ne $paths -and (Test-Path -LiteralPath $paths.Runtime -PathType Leaf)
    $phase = if ($Status -ne 'running') { 'phase1' } elseif ($null -eq $state) { if ($runtimeExists) { 'preflight' } else { 'starting' } } elseif ($activeCount -gt 0 -or $pendingCount -gt 0) { 'execution' } else { 'freezing' }
    $supervisorAlive = $false
    if ($null -ne $ownership -and $Status -eq 'running') {
        try { $supervisorAlive = Test-RunnerOwnedPhaseOneSupervisorAlive -Ownership $ownership } catch { throw }
    }
    $freezeExists = $null -ne $paths -and (Test-Path -LiteralPath $paths.Freeze -PathType Leaf)
    $control = [ordered]@{
        schema = $controlSchema
        status = $Status
        supervisor_id = if ($null -eq $ownership) { $null } else { [string]$ownership.supervisor_id }
        supervisor_pid = if ($null -eq $ownership) { $null } else { [int]$ownership.pid }
        supervisor_alive = $supervisorAlive
        phase = $phase
        expected_count = [int]$aggregate.expected_count
        terminal_count = [int]$aggregate.terminal_count
        completed_count = [int]$aggregate.completed_count
        failed_count = [int]$aggregate.failed_count
        timed_out_count = [int]$aggregate.timed_out_count
        cancelled_count = [int]$aggregate.cancelled_count
        incompatible_count = [int]$aggregate.incompatible_count
        active_count = $activeCount
        pending_count = $pendingCount
        evidence_validation_failed_count = [int]$aggregate.evidence_validation_failed_count
        freeze_exists = $freezeExists
    }
    if ($null -ne $FinalResult) { $control.phase1_result = Get-JsonProperty -Object $FinalResult -Name 'fanout_summary' -Default $null }
    if (-not [string]::IsNullOrWhiteSpace($Error)) { $control.error = $Error }
    return $control
}

function Enter-ControllerLock {
    param([Parameter(Mandatory = $true)][string]$Path)

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        try { return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Another Phase 1 controller call holds the ownership lock; retry the same controller command.' }
            Start-Sleep -Milliseconds 25
        }
    } while ($true)
}

function New-WindowsPhaseOneDetachmentFailure {
    param(
        [string]$Reason = '',
        [AllowNull()][object]$LaunchContext = $null
    )

    $details = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $LaunchContext) {
        $controllerJob = Get-JsonProperty -Object $LaunchContext -Name 'ControllerJob' -Default $null
        $details.Add("controller_in_job=$([bool](Get-JsonProperty -Object $controllerJob -Name 'InJob' -Default $false))")
        $details.Add("controller_job_kill_on_close=$([bool](Get-JsonProperty -Object $controllerJob -Name 'KillOnJobClose' -Default $false))")
        $details.Add("controller_job_breakaway_ok=$([bool](Get-JsonProperty -Object $controllerJob -Name 'BreakawayOk' -Default $false))")
        $details.Add("controller_job_silent_breakaway_ok=$([bool](Get-JsonProperty -Object $controllerJob -Name 'SilentBreakawayOk' -Default $false))")
        $details.Add("durable_parent_pid=$([int](Get-JsonProperty -Object $LaunchContext -Name 'ParentProcessId' -Default 0))")
        $details.Add("durable_parent_in_job=$([bool](Get-JsonProperty -Object $LaunchContext -Name 'ParentInJob' -Default $false))")
        $details.Add("breakaway_required=$([bool](Get-JsonProperty -Object $LaunchContext -Name 'BreakawayRequired' -Default $false))")
        $details.Add("breakaway_requested=$([bool](Get-JsonProperty -Object $LaunchContext -Name 'BreakawayRequested' -Default $false))")
    }

    $message = 'Durable Phase 1 cannot escape the caller Windows Job Object in this environment. No eval execution was started. Use a host that permits durable Phase 1 detachment.'
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $message += ' ' + $Reason.Trim() }
    if ($details.Count -gt 0) { $message += ' Details: ' + [string]::Join('; ', @($details.ToArray())) }
    return $message
}

function Get-WindowsDurableSupervisorLaunchContext {
    if (-not $IsWindows) { return $null }

    $controllerProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
    $durableParentPid = [int]$controllerProcess.ParentProcessId
    if ($durableParentPid -lt 1) { throw 'Could not resolve a stable parent process for the durable Phase 1 supervisor.' }

    $controllerJob = Get-WindowsCurrentProcessJobInfo
    $parentJob = Get-WindowsProcessJobMembership -ProcessId $durableParentPid
    return [pscustomobject]@{
        ParentProcessId = $durableParentPid
        ParentInJob = [bool]$parentJob.InJob
        ControllerJob = $controllerJob
        BreakawayRequired = [bool]($controllerJob.InJob -or $parentJob.InJob)
        BreakawayRequested = [bool]($controllerJob.InJob -and -not $controllerJob.SilentBreakawayOk)
    }
}

function Start-DurableSupervisor {
    param(
        [Parameter(Mandatory = $true)][string]$SupervisorId,
        [Parameter(Mandatory = $true)][string]$SupervisorPath,
        [AllowNull()][object]$WindowsLaunchContext = $null
    )

    $scriptBase64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($SupervisorPath))
    $iterationBase64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($iteration))
    $commandText = "& ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptBase64'))) -IterationDirectory ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$iterationBase64'))) -SupervisorId '$SupervisorId'"
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))
    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    foreach ($logPath in @($paths.BootstrapStdout, $paths.BootstrapStderr)) { [System.IO.File]::WriteAllBytes($logPath, [byte[]]::new(0)) }
    $processId = if ($IsWindows) {
        $windowsCommandLine = '"' + $pwshPath + '" -NoProfile -NonInteractive -EncodedCommand ' + $encodedCommand
        if ($null -eq $WindowsLaunchContext) { throw 'Windows durable supervisor launch requires a validated job-detachment context.' }
        Start-WindowsDetachedPhaseOneProcess -Application $pwshPath -CommandLine $windowsCommandLine -CurrentDirectory $iteration -StdoutPath $paths.BootstrapStdout -StderrPath $paths.BootstrapStderr -ParentProcessId ([int]$WindowsLaunchContext.ParentProcessId) -RequestBreakawayFromJob ([bool]$WindowsLaunchContext.BreakawayRequested)
    } else {
        $setsid = Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $setsid) { throw 'Durable Phase 1 supervisor start requires the platform setsid utility on non-Windows hosts.' }
        function ConvertTo-ShellLiteral([string]$Value) { return "'" + $Value.Replace("'", "'\''") + "'" }
        $shellCommand = 'nohup ' + (ConvertTo-ShellLiteral $setsid.Source) + ' ' + (ConvertTo-ShellLiteral $pwshPath) + ' -NoProfile -NonInteractive -EncodedCommand ' + (ConvertTo-ShellLiteral $encodedCommand) + ' > ' + (ConvertTo-ShellLiteral $paths.BootstrapStdout) + ' 2> ' + (ConvertTo-ShellLiteral $paths.BootstrapStderr) + ' < /dev/null & printf %s $!'
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new('/bin/sh')
        $startInfo.ArgumentList.Add('-c')
        $startInfo.ArgumentList.Add($shellCommand)
        $startInfo.WorkingDirectory = $iteration
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $shell = [System.Diagnostics.Process]::new()
        $shell.StartInfo = $startInfo
        if (-not $shell.Start()) { throw 'Failed to start the non-Windows durable supervisor launcher.' }
        $pidText = $shell.StandardOutput.ReadToEnd().Trim()
        $launcherError = $shell.StandardError.ReadToEnd().Trim()
        $shell.WaitForExit()
        $launcherExit = $shell.ExitCode
        $shell.Dispose()
        if ($launcherExit -ne 0 -or $pidText -notmatch '^\d+$') { throw "Non-Windows durable supervisor launcher failed ($launcherExit): $launcherError" }
        [int]$pidText
    }
    $identity = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($null -eq $identity -and [DateTime]::UtcNow -lt $deadline) {
        try { $identity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId $processId } catch { Start-Sleep -Milliseconds 10 }
    }
    if ($null -eq $identity) {
        [void](Stop-RunnerOwnedPhaseOneProcessIdentity -ProcessId $processId)
        throw 'Durable Phase 1 supervisor started but its exact process identity could not be captured.'
    }
    return $identity
}

try {
    $iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    . (Join-Path $PSScriptRoot 'runner-common.ps1')
    . (Join-Path $PSScriptRoot 'manifest-paths.ps1')
    . (Join-Path $PSScriptRoot 'orchestration.ps1')
    . (Join-Path $PSScriptRoot 'execution-freeze.ps1')
    . (Join-Path $PSScriptRoot 'package-integrity.ps1')
    . (Join-Path $PSScriptRoot 'phase1-control-common.ps1')
    $paths = Get-RunnerOwnedPhaseOnePaths -IterationDirectory $iteration
    $controllerLock = Enter-ControllerLock -Path $paths.Lock
    try {
        $manifest = Read-RunnerJson -Path (Join-Path $iteration 'manifest.json')
        $profilePath = Resolve-ContainedPath -BasePath $iteration -RelativePath ([string]$manifest.execution_profile) -FieldName 'execution_profile' -Kind File
        $profile = Resolve-ExecutionProfile -ProfilePath $profilePath
        [void](Assert-PackageRunnerToolsIntegrity -IterationDirectory $iteration -Manifest $manifest)
        $descriptor = Get-PackageRunnerDescriptor -RunnerName ([string]$profile.Runner)
        if ([string](Get-JsonProperty -Object (Get-JsonProperty -Object $descriptor -Name 'delegation' -Default $null) -Name 'dispatch_owner' -Default '') -ne 'runner') {
            throw "Selected runner '$($profile.Runner)' is not runner-owned; this controller is incompatible."
        }

        if (-not (Test-Path -LiteralPath $paths.Ownership -PathType Leaf)) {
            if (Test-Path -LiteralPath $paths.OrchestrationState -PathType Leaf) {
                throw 'Legacy/incomplete orchestration-state.json exists without durable Phase 1 supervisor ownership. It will not be adopted or restarted; requires a fresh package.'
            }
            foreach ($legacyPath in @($paths.Runtime, $paths.Result, $paths.FanoutInvocation, $paths.Freeze)) {
                if (Test-Path -LiteralPath $legacyPath -PathType Leaf) { throw 'Incomplete Phase 1 control state exists without a valid supervisor ownership record. It will not be adopted or restarted; requires a fresh package.' }
            }
            $supervisorId = [Guid]::NewGuid().ToString('D')
            $fanoutPath = Join-Path $PSScriptRoot 'invoke-runner-owned-arms.ps1'
            $supervisorPath = Join-Path $PSScriptRoot 'supervise-runner-owned-phase1.ps1'
            $controllerPath = $PSCommandPath
            $windowsLaunchContext = if ($IsWindows) { Get-WindowsDurableSupervisorLaunchContext } else { $null }
            $pendingOwnership = [ordered]@{
                schema = 'codebeltnet/agentic/runner-owned-phase1-supervisor/1'
                ownership_state = 'reserved'
                supervisor_id = $supervisorId
                iteration = [ordered]@{
                    path = $iteration
                    skill_name = [string](Get-JsonProperty -Object $manifest -Name 'skill_name' -Default '')
                    number = [int](Get-JsonProperty -Object $manifest -Name 'iteration' -Default 0)
                }
                manifest_sha256 = Get-Sha256HexFromFile -Path (Join-Path $iteration 'manifest.json')
                profile_sha256 = Get-Sha256HexFromFile -Path $profilePath
                pid = 0
                process_started_utc = $null
                process_start_ticks_utc = 0
                process_executable = $null
                process_executable_sha256 = $null
                started_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                internal_fanout = [ordered]@{ path = $fanoutPath; sha256 = Get-Sha256HexFromFile -Path $fanoutPath }
                supervisor = [ordered]@{ path = $supervisorPath; sha256 = Get-Sha256HexFromFile -Path $supervisorPath }
                controller = [ordered]@{ path = $controllerPath; sha256 = Get-Sha256HexFromFile -Path $controllerPath }
                final_result_path = [System.IO.Path]::GetRelativePath($iteration, $paths.Result).Replace('\', '/')
                stdout_path = [System.IO.Path]::GetRelativePath($iteration, $paths.Stdout).Replace('\', '/')
                stderr_path = [System.IO.Path]::GetRelativePath($iteration, $paths.Stderr).Replace('\', '/')
                failure = $null
            }
            if ($null -ne $windowsLaunchContext) {
                $pendingOwnership.windows_job = [ordered]@{
                    controller_in_job = [bool]$windowsLaunchContext.ControllerJob.InJob
                    controller_job_kill_on_close = [bool]$windowsLaunchContext.ControllerJob.KillOnJobClose
                    controller_job_breakaway_ok = [bool]$windowsLaunchContext.ControllerJob.BreakawayOk
                    controller_job_silent_breakaway_ok = [bool]$windowsLaunchContext.ControllerJob.SilentBreakawayOk
                    durable_parent_pid = [int]$windowsLaunchContext.ParentProcessId
                    durable_parent_in_job = [bool]$windowsLaunchContext.ParentInJob
                    breakaway_required = [bool]$windowsLaunchContext.BreakawayRequired
                    breakaway_requested = [bool]$windowsLaunchContext.BreakawayRequested
                    supervisor_in_controller_job = $null
                    supervisor_in_any_job = $null
                    breakaway_succeeded = $null
                }
                if ($windowsLaunchContext.ParentInJob -and -not $windowsLaunchContext.ControllerJob.InJob) {
                    $pendingOwnership.ownership_state = 'failed'
                    $pendingOwnership.failure = New-WindowsPhaseOneDetachmentFailure -Reason 'The selected durable parent process is inside a Windows Job Object and the controller process cannot request breakaway from it.' -LaunchContext $windowsLaunchContext
                    Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Ownership -Value $pendingOwnership
                    $ownership = Read-RunnerJson -Path $paths.Ownership
                    throw $pendingOwnership.failure
                }
                if ($windowsLaunchContext.BreakawayRequired -and $windowsLaunchContext.ControllerJob.InJob -and -not ($windowsLaunchContext.ControllerJob.BreakawayOk -or $windowsLaunchContext.ControllerJob.SilentBreakawayOk)) {
                    $pendingOwnership.ownership_state = 'failed'
                    $pendingOwnership.failure = New-WindowsPhaseOneDetachmentFailure -Reason 'The controller Windows Job Object does not permit durable breakaway.' -LaunchContext $windowsLaunchContext
                    Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Ownership -Value $pendingOwnership
                    $ownership = Read-RunnerJson -Path $paths.Ownership
                    throw $pendingOwnership.failure
                }
            }
            Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Ownership -Value $pendingOwnership
            try {
                $processIdentity = Start-DurableSupervisor -SupervisorId $supervisorId -SupervisorPath $supervisorPath -WindowsLaunchContext $windowsLaunchContext
            } catch {
                $pendingOwnership.ownership_state = 'failed'
                $pendingOwnership.failure = if ($null -ne $windowsLaunchContext) {
                    New-WindowsPhaseOneDetachmentFailure -Reason $_.Exception.Message -LaunchContext $windowsLaunchContext
                } else {
                    "Durable Phase 1 supervisor ownership was reserved but process start failed; it will not be retried for this iteration. Requires a fresh package. $($_.Exception.Message)"
                }
                Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Ownership -Value $pendingOwnership
                $ownership = Read-RunnerJson -Path $paths.Ownership
                throw $pendingOwnership.failure
            }
            $pendingOwnership.pid = $processIdentity.Pid
            $pendingOwnership.process_started_utc = $processIdentity.StartedUtcText
            $pendingOwnership.process_start_ticks_utc = $processIdentity.StartTicksUtc
            $pendingOwnership.process_executable = $processIdentity.ExecutablePath
            $pendingOwnership.process_executable_sha256 = $processIdentity.ExecutableSha256
            try {
                if ($null -ne $windowsLaunchContext) {
                    $supervisorAnyJob = Get-WindowsProcessJobMembership -ProcessId $processIdentity.Pid
                    $pendingOwnership.windows_job.supervisor_in_any_job = [bool]$supervisorAnyJob.InJob
                    $supervisorInControllerJob = $false
                    if ($windowsLaunchContext.ControllerJob.InJob) {
                        $supervisorInControllerJob = [bool](Test-WindowsProcessInCurrentJob -ProcessId $processIdentity.Pid)
                        $pendingOwnership.windows_job.supervisor_in_controller_job = [bool]$supervisorInControllerJob
                    } else {
                        $pendingOwnership.windows_job.supervisor_in_controller_job = $false
                    }
                    $pendingOwnership.windows_job.breakaway_succeeded = -not [bool]$supervisorAnyJob.InJob
                    if ($supervisorAnyJob.InJob) {
                        $detachmentFailure = if ($windowsLaunchContext.ControllerJob.InJob -and $supervisorInControllerJob) {
                            "Supervisor PID $($processIdentity.Pid) remained inside the controller Windows Job Object after launch."
                        } elseif ($windowsLaunchContext.ControllerJob.InJob) {
                            "Supervisor PID $($processIdentity.Pid) escaped the controller Windows Job Object but remained inside another Windows Job Object after launch."
                        } else {
                            "Supervisor PID $($processIdentity.Pid) remained inside a Windows Job Object after launch."
                        }
                        throw (New-WindowsPhaseOneDetachmentFailure -Reason $detachmentFailure -LaunchContext $windowsLaunchContext)
                    }
                }
                $pendingOwnership.ownership_state = 'committed'
                $pendingOwnership.failure = $null
                Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Ownership -Value $pendingOwnership
                $ownership = Read-RunnerJson -Path $paths.Ownership
            } catch {
                [void](Stop-RunnerOwnedPhaseOneProcessIdentity -ProcessId $processIdentity.Pid -ExpectedStartTicksUtc $processIdentity.StartTicksUtc)
                $pendingOwnership.ownership_state = 'failed'
                $pendingOwnership.failure = if ($null -ne $windowsLaunchContext) {
                    $probeFailure = $_.Exception.Message
                    if ($probeFailure -like 'Durable Phase 1 cannot escape the caller Windows Job Object*') { $probeFailure } else { New-WindowsPhaseOneDetachmentFailure -Reason $probeFailure -LaunchContext $windowsLaunchContext }
                } else {
                    "Durable Phase 1 supervisor ownership could not be committed; it will not be retried for this iteration. Requires a fresh package. $($_.Exception.Message)"
                }
                Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Ownership -Value $pendingOwnership
                $ownership = Read-RunnerJson -Path $paths.Ownership
                throw $pendingOwnership.failure
            }
        } else {
            $ownership = Read-RunnerJson -Path $paths.Ownership
            [void](Assert-RunnerOwnedPhaseOneOwnershipRecord -IterationDirectory $iteration -Ownership $ownership -Manifest $manifest -ProfilePath $profilePath)
        }
    } finally {
        $controllerLock.Dispose()
    }

    while ($clock.Elapsed.TotalSeconds -lt $WaitSeconds) {
        if (Test-Path -LiteralPath $paths.Result -PathType Leaf) { break }
        if (-not (Test-RunnerOwnedPhaseOneSupervisorAlive -Ownership $ownership)) { break }
        Start-Sleep -Milliseconds 100
    }

    if (Test-Path -LiteralPath $paths.Result -PathType Leaf) {
        $finalResult = Read-RunnerJson -Path $paths.Result
        if ([string](Get-JsonProperty -Object $finalResult -Name 'schema' -Default '') -ne 'codebeltnet/agentic/runner-owned-phase1-supervisor-result/1' -or
            [string](Get-JsonProperty -Object $finalResult -Name 'supervisor_id' -Default '') -ne [string]$ownership.supervisor_id -or
            [int](Get-JsonProperty -Object $finalResult -Name 'supervisor_pid' -Default 0) -ne [int]$ownership.pid -or
            [int64](Get-JsonProperty -Object $finalResult -Name 'process_start_ticks_utc' -Default 0) -ne [int64]$ownership.process_start_ticks_utc -or
            [int](Get-JsonProperty -Object $finalResult -Name 'fanout_invocation_count' -Default 0) -ne 1 -or
            [string](Get-JsonProperty -Object $finalResult -Name 'fanout_path' -Default '') -ne [string]$ownership.internal_fanout.path -or
            [string](Get-JsonProperty -Object $finalResult -Name 'fanout_sha256' -Default '') -ne [string]$ownership.internal_fanout.sha256) {
            throw 'The final Phase 1 supervisor result does not match its immutable ownership identity.'
        }
        $fanoutSummary = Get-JsonProperty -Object $finalResult -Name 'fanout_summary' -Default $null
        $finalStatus = [string](Get-JsonProperty -Object $finalResult -Name 'status' -Default 'failed')
        if ($finalStatus -eq 'completed') {
            $freezeValidation = Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState
            if (-not (Test-FanoutPhase1Success -Aggregate $freezeValidation.Aggregate)) { throw 'The supervisor reported completion but the immutable Phase 1 aggregate is not successful.' }
            Write-ControlStatus -Status (Get-ProgressStatus -Status 'completed' -FinalResult $finalResult)
        }
        if ($null -ne $fanoutSummary -and (Test-Path -LiteralPath $paths.Freeze -PathType Leaf)) { [void](Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState) }
        $finalError = [string](Get-JsonProperty -Object $finalResult -Name 'error' -Default '')
        if ([string]::IsNullOrWhiteSpace($finalError) -and $null -ne $fanoutSummary) { $finalError = [string](Get-JsonProperty -Object $fanoutSummary -Name 'error' -Default 'Phase 1 failed.') }
        Write-ControlStatus -Status (Get-ProgressStatus -Status 'failed' -Error $finalError -FinalResult $finalResult)
    }

    if (-not (Test-RunnerOwnedPhaseOneSupervisorAlive -Ownership $ownership)) {
        Write-ControlStatus -Status (Get-ProgressStatus -Status 'failed' -Error 'The durable Phase 1 supervisor died without a valid final result. It will not be restarted; requires a fresh package.')
    }
    Write-ControlStatus -Status (Get-ProgressStatus -Status 'running')
} catch {
    $controlFailure = $_.Exception.ToString()
    try {
        if ($null -ne $iteration -and $null -eq $manifest -and (Test-Path -LiteralPath (Join-Path $iteration 'manifest.json') -PathType Leaf)) { $manifest = Read-RunnerJson -Path (Join-Path $iteration 'manifest.json') }
        Write-ControlStatus -Status (Get-ProgressStatus -Status 'failed' -Error $controlFailure)
    } catch {
        Write-ControlStatus -Status ([ordered]@{
            schema = $controlSchema
            status = 'failed'
            supervisor_id = if ($null -eq $ownership) { $null } else { [string]$ownership.supervisor_id }
            supervisor_pid = if ($null -eq $ownership) { $null } else { [int]$ownership.pid }
            supervisor_alive = $false
            phase = 'phase1'
            expected_count = 0
            terminal_count = 0
            completed_count = 0
            failed_count = 0
            timed_out_count = 0
            cancelled_count = 0
            incompatible_count = 0
            active_count = 0
            pending_count = 0
            evidence_validation_failed_count = 0
            freeze_exists = $false
            error = $controlFailure
        })
    }
}
