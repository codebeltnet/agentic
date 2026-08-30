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

function Start-DurableSupervisor {
    param(
        [Parameter(Mandatory = $true)][string]$SupervisorId,
        [Parameter(Mandatory = $true)][string]$SupervisorPath
    )

    $scriptBase64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($SupervisorPath))
    $iterationBase64 = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($iteration))
    $commandText = "& ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptBase64'))) -IterationDirectory ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$iterationBase64'))) -SupervisorId '$SupervisorId'"
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))
    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    foreach ($logPath in @($paths.BootstrapStdout, $paths.BootstrapStderr)) { [System.IO.File]::WriteAllBytes($logPath, [byte[]]::new(0)) }
    $processId = if ($IsWindows) {
        if ($null -eq ('AgenticPhaseOne.NativeProcess' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace AgenticPhaseOne
{
    public static class NativeProcess
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint CREATE_ALWAYS = 2;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const uint STARTF_USESTDHANDLES = 0x00000100;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint PROCESS_CREATE_PROCESS = 0x0080;
        private const uint HANDLE_FLAG_INHERIT = 0x00000001;
        private const int STD_INPUT_HANDLE = -10;
        private const int STD_OUTPUT_HANDLE = -11;
        private const int STD_ERROR_HANDLE = -12;
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PARENT_PROCESS = new IntPtr(0x00020000);

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES attributes, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory, ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int standardHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetHandleInformation(IntPtr handle, out uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

        public static int Start(string application, string commandLine, string currentDirectory, string stdoutPath, string stderrPath, int parentProcessId)
        {
            var attributes = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(), bInheritHandle = true };
            IntPtr stdin = CreateFileW("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            IntPtr stdout = CreateFileW(stdoutPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            IntPtr stderr = CreateFileW(stderrPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            if (stdin == new IntPtr(-1) || stdout == new IntPtr(-1) || stderr == new IntPtr(-1))
            {
                int error = Marshal.GetLastWin32Error();
                if (stdin != new IntPtr(-1)) CloseHandle(stdin);
                if (stdout != new IntPtr(-1)) CloseHandle(stdout);
                if (stderr != new IntPtr(-1)) CloseHandle(stderr);
                throw new Win32Exception(error, "Could not open durable supervisor standard-stream files.");
            }
            try
            {
                IntPtr parentProcess = OpenProcess(PROCESS_CREATE_PROCESS, false, parentProcessId);
                if (parentProcess == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the durable supervisor parent process.");
                IntPtr attributeSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeSize);
                IntPtr attributeList = Marshal.AllocHGlobal(attributeSize);
                IntPtr parentValue = Marshal.AllocHGlobal(IntPtr.Size);
                IntPtr[] controllerStandardHandles = { GetStdHandle(STD_INPUT_HANDLE), GetStdHandle(STD_OUTPUT_HANDLE), GetStdHandle(STD_ERROR_HANDLE) };
                uint[] controllerStandardFlags = new uint[3];
                try
                {
                    if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeSize))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not initialize the durable supervisor process attribute.");
                    Marshal.WriteIntPtr(parentValue, parentProcess);
                    if (!UpdateProcThreadAttribute(attributeList, 0, PROC_THREAD_ATTRIBUTE_PARENT_PROCESS, parentValue, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not reparent the durable supervisor outside the controller process tree.");
                    for (int index = 0; index < controllerStandardHandles.Length; index++)
                    {
                        uint handleFlags;
                        if (controllerStandardHandles[index] != IntPtr.Zero && controllerStandardHandles[index] != new IntPtr(-1) && GetHandleInformation(controllerStandardHandles[index], out handleFlags))
                        {
                            controllerStandardFlags[index] = handleFlags;
                            if ((handleFlags & HANDLE_FLAG_INHERIT) != 0)
                                SetHandleInformation(controllerStandardHandles[index], HANDLE_FLAG_INHERIT, 0);
                        }
                    }
                    var startup = new STARTUPINFOEX
                    {
                        StartupInfo = new STARTUPINFO
                        {
                            cb = Marshal.SizeOf<STARTUPINFOEX>(),
                            dwFlags = STARTF_USESTDHANDLES,
                            hStdInput = stdin,
                            hStdOutput = stdout,
                            hStdError = stderr
                        },
                        lpAttributeList = attributeList
                    };
                    PROCESS_INFORMATION process;
                    // PROC_THREAD_ATTRIBUTE_PARENT_PROCESS makes Windows take
                    // the job object and process-tree identity from the stable
                    // parent rather than the short controller process.
                    uint flags = CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT;
                    if (!CreateProcessW(application, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, currentDirectory, ref startup, out process))
                    {
                        int error = Marshal.GetLastWin32Error();
                        throw new Win32Exception(error, "Could not create the reparented durable Phase 1 supervisor process (Win32 error " + error + ").");
                    }
                    try { return process.dwProcessId; }
                    finally { CloseHandle(process.hThread); CloseHandle(process.hProcess); }
                }
                finally
                {
                    for (int index = 0; index < controllerStandardHandles.Length; index++)
                    {
                        if ((controllerStandardFlags[index] & HANDLE_FLAG_INHERIT) != 0)
                            SetHandleInformation(controllerStandardHandles[index], HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
                    }
                    DeleteProcThreadAttributeList(attributeList);
                    Marshal.FreeHGlobal(parentValue);
                    Marshal.FreeHGlobal(attributeList);
                    CloseHandle(parentProcess);
                }
            }
            finally
            {
                CloseHandle(stdin);
                CloseHandle(stdout);
                CloseHandle(stderr);
            }
        }
    }
}
'@
        }
        $windowsCommandLine = '"' + $pwshPath + '" -NoProfile -NonInteractive -EncodedCommand ' + $encodedCommand
        $controllerProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        $durableParentPid = [int]$controllerProcess.ParentProcessId
        if ($durableParentPid -lt 1) { throw 'Could not resolve a stable parent process for the durable Phase 1 supervisor.' }
        [AgenticPhaseOne.NativeProcess]::Start($pwshPath, $windowsCommandLine, $iteration, $paths.BootstrapStdout, $paths.BootstrapStderr, $durableParentPid)
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
    if ($null -eq $identity) { throw 'Durable Phase 1 supervisor started but its exact process identity could not be captured.' }
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
            $pendingOwnership = [ordered]@{
                schema = 'codebeltnet/agentic/runner-owned-phase1-supervisor/1'
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
            }
            Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Ownership -Value $pendingOwnership
            try {
                $processIdentity = Start-DurableSupervisor -SupervisorId $supervisorId -SupervisorPath $supervisorPath
            } catch {
                throw "Durable Phase 1 supervisor ownership was reserved but process start failed; it will not be retried for this iteration. Requires a fresh package. $($_.Exception.Message)"
            }
            $pendingOwnership.pid = $processIdentity.Pid
            $pendingOwnership.process_started_utc = $processIdentity.StartedUtcText
            $pendingOwnership.process_start_ticks_utc = $processIdentity.StartTicksUtc
            $pendingOwnership.process_executable = $processIdentity.ExecutablePath
            $pendingOwnership.process_executable_sha256 = $processIdentity.ExecutableSha256
            Write-RunnerOwnedPhaseOneAtomicJson -Path $paths.Ownership -Value $pendingOwnership
            $ownership = Read-RunnerJson -Path $paths.Ownership
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
