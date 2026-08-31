Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RunnerOwnedPhaseOnePaths {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory)

    return [pscustomobject]@{
        Lock = Join-Path $IterationDirectory 'phase1-controller.lock'
        Ownership = Join-Path $IterationDirectory 'phase1-supervisor.json'
        Runtime = Join-Path $IterationDirectory 'phase1-supervisor-runtime.json'
        Result = Join-Path $IterationDirectory 'phase1-supervisor-result.json'
        FanoutInvocation = Join-Path $IterationDirectory 'phase1-fanout-invocation.json'
        Stdout = Join-Path $IterationDirectory 'phase1-supervisor.stdout.log'
        Stderr = Join-Path $IterationDirectory 'phase1-supervisor.stderr.log'
        BootstrapStdout = Join-Path $IterationDirectory 'phase1-supervisor.bootstrap.stdout.log'
        BootstrapStderr = Join-Path $IterationDirectory 'phase1-supervisor.bootstrap.stderr.log'
        OrchestrationState = Join-Path $IterationDirectory 'orchestration-state.json'
        Freeze = Join-Path $IterationDirectory 'execution-freeze.json'
    }
}

function Write-RunnerOwnedPhaseOneAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporaryPath, (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-RunnerOwnedPhaseOneOwnershipState {
    param([Parameter(Mandatory = $true)][object]$Ownership)

    $state = [string](Get-JsonProperty -Object $Ownership -Name 'ownership_state' -Default '')
    if ($state -in @('reserved', 'committed', 'failed')) { return $state }
    if ([int](Get-JsonProperty -Object $Ownership -Name 'pid' -Default 0) -gt 0 -and [int64](Get-JsonProperty -Object $Ownership -Name 'process_start_ticks_utc' -Default 0) -gt 0) {
        return 'committed'
    }
    return 'reserved'
}

function Get-RunnerOwnedPhaseOneOwnershipFailure {
    param([Parameter(Mandatory = $true)][object]$Ownership)

    $failure = [string](Get-JsonProperty -Object $Ownership -Name 'failure' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($failure)) { return $failure }

    $fallback = switch (Get-RunnerOwnedPhaseOneOwnershipState -Ownership $Ownership) {
        'reserved' { 'The durable Phase 1 supervisor ownership was reserved but never committed. It will not be adopted or restarted; requires a fresh package.' }
        'failed' { 'The durable Phase 1 supervisor failed before ownership could be committed. It will not be retried; requires a fresh package.' }
        default { '' }
    }
    return $fallback
}

function Stop-RunnerOwnedPhaseOneProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [int64]$ExpectedStartTicksUtc = 0,
        [int]$WaitMilliseconds = 5000
    )

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
    } catch {
        return $false
    }

    try {
        if ($ExpectedStartTicksUtc -gt 0 -and $process.StartTime.ToUniversalTime().Ticks -ne $ExpectedStartTicksUtc) { return $false }
        $process.Kill($true)
        try { [void]$process.WaitForExit([Math]::Max(1, $WaitMilliseconds)) } catch { }
        return $true
    } finally {
        $process.Dispose()
    }
}

function Initialize-RunnerOwnedPhaseOneWindowsInterop {
    if (-not $IsWindows) { throw 'Windows Phase 1 job probing is available only on Windows hosts.' }
    if ($null -ne ('AgenticPhaseOne.WindowsProcess' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace AgenticPhaseOne
{
    public sealed class ProcessJobInfo
    {
        public bool InJob { get; set; }
        public bool KillOnJobClose { get; set; }
        public bool BreakawayOk { get; set; }
        public bool SilentBreakawayOk { get; set; }
    }

    public static class WindowsProcess
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint CREATE_ALWAYS = 2;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const uint STARTF_USESTDHANDLES = 0x00000100;
        private const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private const uint CREATE_SUSPENDED = 0x00000004;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint PROCESS_CREATE_PROCESS = 0x0080;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint PROCESS_SET_QUOTA = 0x0100;
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint HANDLE_FLAG_INHERIT = 0x00000001;
        private const uint JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800;
        private const uint JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const int ERROR_MORE_DATA = 234;
        private const int JobObjectBasicProcessIdList = 3;
        private const int JobObjectExtendedLimitInformation = 9;
        private const int STD_INPUT_HANDLE = -10;
        private const int STD_OUTPUT_HANDLE = -11;
        private const int STD_ERROR_HANDLE = -12;
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PARENT_PROCESS = new IntPtr(0x00020000);
        private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);

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

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public IntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
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

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsProcessInJob(IntPtr processHandle, IntPtr jobHandle, [MarshalAs(UnmanagedType.Bool)] out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryInformationJobObject(IntPtr jobHandle, int jobObjectInformationClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION jobObjectInformation, int cbJobObjectInformationLength, IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryInformationJobObject(IntPtr jobHandle, int jobObjectInformationClass, IntPtr jobObjectInformation, int cbJobObjectInformationLength, out int returnLength);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObjectW(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(IntPtr jobHandle, int jobObjectInformationClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION jobObjectInformation, int cbJobObjectInformationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr jobHandle, IntPtr processHandle);

        private static IntPtr RequireProcessHandle(int processId, uint desiredAccess, string message)
        {
            IntPtr handle = OpenProcess(desiredAccess, false, processId);
            if (handle == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), message);
            return handle;
        }

        public static int Start(string application, string commandLine, string currentDirectory, string stdoutPath, string stderrPath, int parentProcessId, bool requestBreakawayFromJob)
        {
            var attributes = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(), bInheritHandle = true };
            IntPtr stdin = CreateFileW("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            IntPtr stdout = CreateFileW(stdoutPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            IntPtr stderr = CreateFileW(stderrPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            if (stdin == InvalidHandleValue || stdout == InvalidHandleValue || stderr == InvalidHandleValue)
            {
                int error = Marshal.GetLastWin32Error();
                if (stdin != InvalidHandleValue) CloseHandle(stdin);
                if (stdout != InvalidHandleValue) CloseHandle(stdout);
                if (stderr != InvalidHandleValue) CloseHandle(stderr);
                throw new Win32Exception(error, "Could not open durable supervisor standard-stream files.");
            }
            try
            {
                IntPtr parentProcess = RequireProcessHandle(parentProcessId, PROCESS_CREATE_PROCESS, "Could not open the durable supervisor parent process.");
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
                        if (controllerStandardHandles[index] != IntPtr.Zero && controllerStandardHandles[index] != InvalidHandleValue && GetHandleInformation(controllerStandardHandles[index], out handleFlags))
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
                    uint flags = CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT;
                    if (requestBreakawayFromJob) { flags |= CREATE_BREAKAWAY_FROM_JOB; }
                    if (!CreateProcessW(application, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, currentDirectory, ref startup, out process))
                    {
                        int error = Marshal.GetLastWin32Error();
                        throw new Win32Exception(error, "Could not create the durable Phase 1 supervisor process (Win32 error " + error + ").");
                    }
                    try { return process.dwProcessId; }
                    finally
                    {
                        CloseHandle(process.hThread);
                        CloseHandle(process.hProcess);
                    }
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

        public static ProcessJobInfo GetCurrentProcessJobInfo()
        {
            IntPtr processHandle = RequireProcessHandle(Process.GetCurrentProcess().Id, PROCESS_QUERY_LIMITED_INFORMATION, "Could not open the current process for Windows Job Object probing.");
            try
            {
                bool inJob;
                if (!IsProcessInJob(processHandle, IntPtr.Zero, out inJob))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not determine whether the current process is in a Windows Job Object.");
                var info = new ProcessJobInfo { InJob = inJob };
                if (!inJob) { return info; }

                var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                if (!QueryInformationJobObject(IntPtr.Zero, JobObjectExtendedLimitInformation, ref limits, Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>(), IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not query the current Windows Job Object limits.");
                info.KillOnJobClose = (limits.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE) != 0;
                info.BreakawayOk = (limits.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_BREAKAWAY_OK) != 0;
                info.SilentBreakawayOk = (limits.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK) != 0;
                return info;
            }
            finally
            {
                CloseHandle(processHandle);
            }
        }

        public static ProcessJobInfo GetProcessJobMembership(int processId)
        {
            IntPtr processHandle = RequireProcessHandle(processId, PROCESS_QUERY_LIMITED_INFORMATION, "Could not open the process for Windows Job Object probing.");
            try
            {
                bool inJob;
                if (!IsProcessInJob(processHandle, IntPtr.Zero, out inJob))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not determine whether the process is in a Windows Job Object.");
                return new ProcessJobInfo { InJob = inJob };
            }
            finally
            {
                CloseHandle(processHandle);
            }
        }

        public static bool CurrentJobContainsProcess(int processId)
        {
            IntPtr currentHandle = RequireProcessHandle(Process.GetCurrentProcess().Id, PROCESS_QUERY_LIMITED_INFORMATION, "Could not open the current process for Windows Job Object probing.");
            try
            {
                bool inJob;
                if (!IsProcessInJob(currentHandle, IntPtr.Zero, out inJob))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not determine whether the current process is in a Windows Job Object.");
                if (!inJob) { return false; }

                int bufferSize = 1024;
                while (true)
                {
                    IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
                    try
                    {
                        int returnLength;
                        if (QueryInformationJobObject(IntPtr.Zero, JobObjectBasicProcessIdList, buffer, bufferSize, out returnLength))
                        {
                            int count = Marshal.ReadInt32(buffer, sizeof(uint));
                            int listOffset = sizeof(uint) * 2;
                            for (int index = 0; index < count; index++)
                            {
                                long candidate = IntPtr.Size == 8
                                    ? Marshal.ReadInt64(buffer, listOffset + (index * IntPtr.Size))
                                    : Marshal.ReadInt32(buffer, listOffset + (index * IntPtr.Size));
                                if ((int)candidate == processId) { return true; }
                            }
                            return false;
                        }

                        int error = Marshal.GetLastWin32Error();
                        if (error == ERROR_MORE_DATA || returnLength > bufferSize)
                        {
                            bufferSize = Math.Max(bufferSize * 2, returnLength + IntPtr.Size);
                            continue;
                        }
                        throw new Win32Exception(error, "Could not query the current Windows Job Object process list.");
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(buffer);
                    }
                }
            }
            finally
            {
                CloseHandle(currentHandle);
            }
        }

        public static bool IsProcessInSpecificJob(int processId, IntPtr jobHandle)
        {
            if (jobHandle == IntPtr.Zero || jobHandle == InvalidHandleValue)
                throw new InvalidOperationException("The Windows Job Object handle is invalid.");

            IntPtr processHandle = RequireProcessHandle(processId, PROCESS_QUERY_LIMITED_INFORMATION, "Could not open the process for Windows Job Object probing.");
            try
            {
                bool inJob;
                if (!IsProcessInJob(processHandle, jobHandle, out inJob))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not determine whether the process is in the specified Windows Job Object.");
                return inJob;
            }
            finally
            {
                CloseHandle(processHandle);
            }
        }

        public static IntPtr CreateJob(bool killOnJobClose, bool breakawayOk, bool silentBreakawayOk)
        {
            IntPtr jobHandle = CreateJobObjectW(IntPtr.Zero, null);
            if (jobHandle == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the Windows Job Object test harness.");

            try
            {
                var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                uint flags = 0;
                if (killOnJobClose) { flags |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; }
                if (breakawayOk) { flags |= JOB_OBJECT_LIMIT_BREAKAWAY_OK; }
                if (silentBreakawayOk) { flags |= JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK; }
                limits.BasicLimitInformation.LimitFlags = flags;
                if (!SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation, ref limits, Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not configure the Windows Job Object test harness.");
                return jobHandle;
            }
            catch
            {
                CloseHandle(jobHandle);
                throw;
            }
        }

        public static void AssignProcessToJob(IntPtr jobHandle, int processId)
        {
            if (jobHandle == IntPtr.Zero || jobHandle == InvalidHandleValue)
                throw new InvalidOperationException("The Windows Job Object handle is invalid.");

            IntPtr processHandle = RequireProcessHandle(processId, PROCESS_SET_QUOTA | PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, "Could not open the process for Windows Job Object assignment.");
            try
            {
                if (!AssignProcessToJobObject(jobHandle, processHandle))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not assign the process to the Windows Job Object.");
            }
            finally
            {
                CloseHandle(processHandle);
            }
        }

        public static void CloseNativeHandle(IntPtr handle)
        {
            if (handle != IntPtr.Zero && handle != InvalidHandleValue) { CloseHandle(handle); }
        }
    }
}
'@ -ErrorAction Stop | Out-Null
}

function Get-WindowsCurrentProcessJobInfo {
    if (-not $IsWindows) { return [pscustomobject]@{ InJob = $false; KillOnJobClose = $false; BreakawayOk = $false; SilentBreakawayOk = $false } }
    Initialize-RunnerOwnedPhaseOneWindowsInterop
    $info = [AgenticPhaseOne.ProcessJobInfo][AgenticPhaseOne.WindowsProcess]::GetCurrentProcessJobInfo()
    return [pscustomobject]@{
        InJob = [bool]$info.InJob
        KillOnJobClose = [bool]$info.KillOnJobClose
        BreakawayOk = [bool]$info.BreakawayOk
        SilentBreakawayOk = [bool]$info.SilentBreakawayOk
    }
}

function Get-WindowsProcessJobMembership {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if (-not $IsWindows) { return [pscustomobject]@{ ProcessId = $ProcessId; InJob = $false } }
    Initialize-RunnerOwnedPhaseOneWindowsInterop
    $info = [AgenticPhaseOne.ProcessJobInfo][AgenticPhaseOne.WindowsProcess]::GetProcessJobMembership($ProcessId)
    return [pscustomobject]@{
        ProcessId = $ProcessId
        InJob = [bool]$info.InJob
    }
}

function Test-WindowsProcessInCurrentJob {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if (-not $IsWindows) { return $false }
    Initialize-RunnerOwnedPhaseOneWindowsInterop
    return [bool][AgenticPhaseOne.WindowsProcess]::CurrentJobContainsProcess($ProcessId)
}

function Test-WindowsProcessInJobObject {
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    if (-not $IsWindows) { return $false }
    Initialize-RunnerOwnedPhaseOneWindowsInterop
    $handle = if ($Job -is [IntPtr]) { $Job } elseif ($null -ne $Job -and $Job.PSObject.Properties.Name -contains 'Handle') { [IntPtr]$Job.Handle } else { throw 'The Windows Job Object handle is missing.' }
    return [bool][AgenticPhaseOne.WindowsProcess]::IsProcessInSpecificJob($ProcessId, $handle)
}

function Start-WindowsDetachedPhaseOneProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Application,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$CurrentDirectory,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][int]$ParentProcessId,
        [bool]$RequestBreakawayFromJob = $false
    )

    Initialize-RunnerOwnedPhaseOneWindowsInterop
    return [int][AgenticPhaseOne.WindowsProcess]::Start($Application, $CommandLine, $CurrentDirectory, $StdoutPath, $StderrPath, $ParentProcessId, $RequestBreakawayFromJob)
}

function New-WindowsJobObject {
    param(
        [switch]$KillOnJobClose,
        [switch]$BreakawayOk,
        [switch]$SilentBreakawayOk
    )

    if (-not $IsWindows) { throw 'Windows Job Objects are available only on Windows hosts.' }
    Initialize-RunnerOwnedPhaseOneWindowsInterop
    return [pscustomobject]@{
        Handle = [AgenticPhaseOne.WindowsProcess]::CreateJob([bool]$KillOnJobClose, [bool]$BreakawayOk, [bool]$SilentBreakawayOk)
        KillOnJobClose = [bool]$KillOnJobClose
        BreakawayOk = [bool]$BreakawayOk
        SilentBreakawayOk = [bool]$SilentBreakawayOk
    }
}

function Add-WindowsProcessToJobObject {
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][int]$ProcessId
    )

    if (-not $IsWindows) { throw 'Windows Job Objects are available only on Windows hosts.' }
    Initialize-RunnerOwnedPhaseOneWindowsInterop
    $handle = if ($Job -is [IntPtr]) { $Job } elseif ($null -ne $Job -and $Job.PSObject.Properties.Name -contains 'Handle') { [IntPtr]$Job.Handle } else { throw 'The Windows Job Object handle is missing.' }
    [AgenticPhaseOne.WindowsProcess]::AssignProcessToJob($handle, $ProcessId)
}

function Close-WindowsHandle {
    param([Parameter(Mandatory = $true)][object]$Handle)

    if (-not $IsWindows) { return }
    Initialize-RunnerOwnedPhaseOneWindowsInterop
    $nativeHandle = if ($Handle -is [IntPtr]) { $Handle } elseif ($null -ne $Handle -and $Handle.PSObject.Properties.Name -contains 'Handle') { [IntPtr]$Handle.Handle } else { throw 'The Windows native handle is missing.' }
    [AgenticPhaseOne.WindowsProcess]::CloseNativeHandle($nativeHandle)
}

function Get-RunnerOwnedPhaseOneProcessIdentity {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $startedUtc = $process.StartTime.ToUniversalTime()
    $executablePath = ''
    try { $executablePath = [System.IO.Path]::GetFullPath([string]$process.Path) } catch { }
    $identity = [pscustomobject]@{
        Pid = [int]$process.Id
        StartedUtc = $startedUtc
        StartedUtcText = $startedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        StartTicksUtc = $startedUtc.Ticks
        ExecutablePath = $executablePath
        ExecutableSha256 = if ([string]::IsNullOrWhiteSpace($executablePath) -or -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { '' } else { Get-Sha256HexFromFile -Path $executablePath }
    }
    $process.Dispose()
    return $identity
}

function Assert-RunnerOwnedPhaseOneOwnershipRecord {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Ownership,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    if ([string](Get-JsonProperty -Object $Ownership -Name 'schema' -Default '') -ne 'codebeltnet/agentic/runner-owned-phase1-supervisor/1') {
        throw 'phase1-supervisor.json has an unsupported schema.'
    }
    $ownershipState = Get-RunnerOwnedPhaseOneOwnershipState -Ownership $Ownership
    if ($ownershipState -ne 'committed') {
        throw (Get-RunnerOwnedPhaseOneOwnershipFailure -Ownership $Ownership)
    }
    $supervisorId = [string](Get-JsonProperty -Object $Ownership -Name 'supervisor_id' -Default '')
    if ($supervisorId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'phase1-supervisor.json has an invalid supervisor_id.' }
    $iterationIdentity = Get-JsonProperty -Object $Ownership -Name 'iteration' -Default $null
    $recordedIterationPath = [System.IO.Path]::GetFullPath([string](Get-JsonProperty -Object $iterationIdentity -Name 'path' -Default ''))
    if ($recordedIterationPath -ne [System.IO.Path]::GetFullPath($IterationDirectory)) {
        throw 'phase1-supervisor.json belongs to a different iteration directory.'
    }
    if ([string](Get-JsonProperty -Object $Ownership -Name 'manifest_sha256' -Default '') -ne (Get-Sha256HexFromFile -Path (Join-Path $IterationDirectory 'manifest.json'))) {
        throw 'manifest.json changed after Phase 1 supervisor ownership was created. Requires a fresh package.'
    }
    if ([string](Get-JsonProperty -Object $Ownership -Name 'profile_sha256' -Default '') -ne (Get-Sha256HexFromFile -Path $ProfilePath)) {
        throw 'execution-profile.json changed after Phase 1 supervisor ownership was created. Requires a fresh package.'
    }
    [void](Assert-PackageRunnerToolsIntegrity -IterationDirectory $IterationDirectory -Manifest $Manifest)
    foreach ($tool in @(
            [pscustomobject]@{ Field = 'internal_fanout'; Name = 'invoke-runner-owned-arms.ps1' },
            [pscustomobject]@{ Field = 'supervisor'; Name = 'supervise-runner-owned-phase1.ps1' },
            [pscustomobject]@{ Field = 'controller'; Name = 'control-runner-owned-phase1.ps1' }
        )) {
        $record = Get-JsonProperty -Object $Ownership -Name $tool.Field -Default $null
        $path = [string](Get-JsonProperty -Object $record -Name 'path' -Default '')
        $hash = [string](Get-JsonProperty -Object $record -Name 'sha256' -Default '')
        $expectedPath = Join-Path (Join-Path $IterationDirectory ([string]$Manifest.runner_tools)) $tool.Name
        if ([System.IO.Path]::GetFullPath($path) -ne [System.IO.Path]::GetFullPath($expectedPath) -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Sha256HexFromFile -Path $path) -ne $hash) {
            throw "Phase 1 control tool '$($tool.Name)' changed after supervisor ownership was created. Requires a fresh package."
        }
    }
    $windowsJob = Get-JsonProperty -Object $Ownership -Name 'windows_job' -Default $null
    if ($IsWindows -and $null -eq $windowsJob) {
        throw 'Phase 1 supervisor ownership does not record Windows Job Object proof.'
    }
    if ($IsWindows -and $null -ne $windowsJob) {
        $controllerInJob = [bool](Get-JsonProperty -Object $windowsJob -Name 'controller_in_job' -Default $false)
        $supervisorInAnyJob = [bool](Get-JsonProperty -Object $windowsJob -Name 'supervisor_in_any_job' -Default $true)
        if ($controllerInJob -and [bool](Get-JsonProperty -Object $windowsJob -Name 'supervisor_in_controller_job' -Default $true)) {
            throw 'Phase 1 supervisor ownership does not prove detachment from the controller Windows Job Object.'
        }
        if ($supervisorInAnyJob) {
            throw 'Phase 1 supervisor ownership does not prove Windows Job Object independence.'
        }
        if ([bool](Get-JsonProperty -Object $windowsJob -Name 'breakaway_required' -Default $false) -and -not [bool](Get-JsonProperty -Object $windowsJob -Name 'breakaway_succeeded' -Default $false)) {
            throw 'Phase 1 supervisor ownership does not prove durable Windows Job Object detachment.'
        }
    }
    return $true
}

function Test-RunnerOwnedPhaseOneSupervisorAlive {
    param([Parameter(Mandatory = $true)][object]$Ownership)

    $pidValue = [int](Get-JsonProperty -Object $Ownership -Name 'pid' -Default 0)
    if ($pidValue -lt 1) { throw 'phase1-supervisor.json does not contain a valid supervisor PID.' }
    try {
        $identity = Get-RunnerOwnedPhaseOneProcessIdentity -ProcessId $pidValue
    } catch {
        return $false
    }
    $expectedTicks = [int64](Get-JsonProperty -Object $Ownership -Name 'process_start_ticks_utc' -Default 0)
    if ($identity.StartTicksUtc -ne $expectedTicks) {
        throw "Supervisor PID $pidValue is alive but its process start identity differs; refusing PID reuse. Requires a fresh package."
    }
    $expectedExecutable = [string](Get-JsonProperty -Object $Ownership -Name 'process_executable' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($expectedExecutable) -and $identity.ExecutablePath -ne $expectedExecutable) {
        throw "Supervisor PID $pidValue is alive but its executable identity differs. Requires a fresh package."
    }
    $expectedExecutableHash = [string](Get-JsonProperty -Object $Ownership -Name 'process_executable_sha256' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($expectedExecutableHash) -and $identity.ExecutableSha256 -ne $expectedExecutableHash) {
        throw "Supervisor PID $pidValue is alive but its executable hash differs. Requires a fresh package."
    }
    return $true
}

function Assert-RunnerOwnedFanoutAuthorization {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [AllowNull()][AllowEmptyString()][string]$SupervisorId
    )

    if ([string]::IsNullOrWhiteSpace($SupervisorId)) { throw 'Direct runner-owned fan-out invocation is forbidden. Use control-runner-owned-phase1.ps1.' }
    $paths = Get-RunnerOwnedPhaseOnePaths -IterationDirectory $IterationDirectory
    if (-not (Test-Path -LiteralPath $paths.Ownership -PathType Leaf) -or -not (Test-Path -LiteralPath $paths.Runtime -PathType Leaf)) {
        throw 'Runner-owned fan-out requires a valid durable Phase 1 supervisor ownership/runtime record. Use control-runner-owned-phase1.ps1.'
    }
    $ownership = Read-RunnerJson -Path $paths.Ownership
    $runtime = Read-RunnerJson -Path $paths.Runtime
    if ([string](Get-JsonProperty -Object $runtime -Name 'schema' -Default '') -ne 'codebeltnet/agentic/runner-owned-phase1-supervisor-runtime/1') {
        throw 'Runner-owned fan-out requires a valid Phase 1 supervisor runtime record.'
    }
    if ([string]$ownership.supervisor_id -ne $SupervisorId -or [string]$runtime.supervisor_id -ne $SupervisorId) {
        throw 'Runner-owned fan-out supervisor identity does not match the durable ownership record.'
    }
    if ([int]$runtime.pid -ne [int]$ownership.pid -or [int64]$runtime.process_start_ticks_utc -ne [int64]$ownership.process_start_ticks_utc) {
        throw 'Runner-owned fan-out runtime process identity does not match the durable ownership record.'
    }
    $manifestPath = Join-Path $IterationDirectory 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Runner-owned fan-out requires manifest.json.' }
    $manifest = Read-RunnerJson -Path $manifestPath
    $profileRelativePath = [string](Get-JsonProperty -Object $manifest -Name 'execution_profile' -Default 'execution-profile.json')
    Assert-SafeRelativePath -RelativePath $profileRelativePath -FieldName 'manifest.execution_profile'
    [void](Assert-RunnerOwnedPhaseOneOwnershipRecord -IterationDirectory $IterationDirectory -Ownership $ownership -Manifest $manifest -ProfilePath (Join-Path $IterationDirectory $profileRelativePath))
    $environmentId = [Environment]::GetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_ID')
    $environmentPid = [Environment]::GetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_PID')
    $environmentStartTicks = [Environment]::GetEnvironmentVariable('AGENTIC_PHASE1_SUPERVISOR_START_TICKS')
    if ($environmentId -ne $SupervisorId -or $environmentPid -ne [string]$ownership.pid -or $environmentStartTicks -ne [string]$ownership.process_start_ticks_utc) {
        throw 'Runner-owned fan-out was not launched by its recorded durable Phase 1 supervisor.'
    }
    if (-not (Test-RunnerOwnedPhaseOneSupervisorAlive -Ownership $ownership)) {
        throw 'The recorded durable Phase 1 supervisor is not alive; runner-owned fan-out cannot start.'
    }
    return $true
}
