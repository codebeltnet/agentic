using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Agentic.Evals
{
    // Suspend the initial thread until ownership is established. Inheriting
    // only the three pipe handles prevents sibling arms from keeping pipes open.
    public sealed class WindowsOwnedProcess : IDisposable
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo
        {
            public int Size;
            public IntPtr Reserved, Desktop, Title;
            public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
            public short Show, ReservedSize;
            public IntPtr ReservedBytes, Input, Output, Error, Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInfo
        {
            public IntPtr Process, Thread;
            public int ProcessId, ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobLimits
        {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern SafeFileHandle CreateJobObject(IntPtr attributes, IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref JobLimits value, int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(SafeFileHandle job, int kind, byte[] value, int size, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(SafeFileHandle process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(string application, StringBuilder commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
            ref StartupInfo startup, out ProcessInfo info);

        private SafeFileHandle job;
        private Process process;
        public ProcessStartInfo StartInfo { get; set; }
        public StreamWriter StandardInput { get; private set; }
        public StreamReader StandardOutput { get; private set; }
        public StreamReader StandardError { get; private set; }
        public int Id => process.Id;
        public bool HasExited => process.HasExited;
        public int ExitCode => process.ExitCode;
        public bool WaitForExit(int milliseconds) => process.WaitForExit(milliseconds);

        private static void Check(bool success, string operation)
        {
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed (" + Marshal.GetLastWin32Error() + ").");
        }

        private static string Quote(string argument)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\') { slashes++; continue; }
                result.Append('\\', character == '"' ? slashes * 2 + 1 : slashes);
                result.Append(character);
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }

        public bool Start()
        {
            job = CreateJobObject(IntPtr.Zero, IntPtr.Zero);
            Check(!job.IsInvalid, "CreateJobObject");
            var limits = new JobLimits { Flags = 0x2000 }; // KILL_ON_JOB_CLOSE
            Check(SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<JobLimits>()), "SetInformationJobObject");
            var pipes = new AnonymousPipeServerStream[3];
            IntPtr list = IntPtr.Zero, handles = IntPtr.Zero, environment = IntPtr.Zero;
            bool initialized = false;
            try
            {
                pipes[0] = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable);
                pipes[1] = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
                pipes[2] = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
                var clients = pipes.Select(pipe => pipe.ClientSafePipeHandle.DangerousGetHandle()).ToArray();
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                list = Marshal.AllocHGlobal(size);
                Check(InitializeProcThreadAttributeList(list, 1, 0, ref size), "InitializeProcThreadAttributeList");
                initialized = true;
                handles = Marshal.AllocHGlobal(clients.Length * IntPtr.Size);
                Marshal.Copy(clients, 0, handles, clients.Length);
                Check(UpdateProcThreadAttribute(list, 0, (IntPtr)0x20002, handles,
                    (IntPtr)(clients.Length * IntPtr.Size), IntPtr.Zero, IntPtr.Zero), "UpdateProcThreadAttribute");
                var startup = new StartupInfo
                {
                    Size = Marshal.SizeOf<StartupInfo>(), Flags = 0x100, // STARTF_USESTDHANDLES
                    Input = clients[0], Output = clients[1], Error = clients[2], Attributes = list
                };
                environment = Marshal.StringToHGlobalUni(string.Join("\0", StartInfo.Environment
                    .OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
                    .Select(pair => pair.Key + "=" + pair.Value)) + "\0\0");
                var commandLine = new StringBuilder(string.Join(" ", new[] { StartInfo.FileName }.Concat(StartInfo.ArgumentList).Select(Quote)));
                const uint flags = 0x08000000 | 0x00080000 | 0x00000400 | 0x00000004;
                Check(CreateProcessW(StartInfo.FileName, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                    flags, environment, StartInfo.WorkingDirectory, ref startup, out var info), "CreateProcessW");
                using (var nativeProcess = new SafeFileHandle(info.Process, true))
                using (var thread = new SafeFileHandle(info.Thread, true))
                {
                    try
                    {
                        Check(AssignProcessToJobObject(job, nativeProcess), "AssignProcessToJobObject");
                        process = Process.GetProcessById(info.ProcessId);
                        // Acquire the handle before a fast process can exit.
                        _ = process.SafeHandle;
                        foreach (var pipe in pipes) pipe.DisposeLocalCopyOfClientHandle();
                        var utf8 = new UTF8Encoding(false);
                        StandardInput = new StreamWriter(pipes[0], StartInfo.StandardInputEncoding ?? utf8) { AutoFlush = true };
                        StandardOutput = new StreamReader(pipes[1], StartInfo.StandardOutputEncoding ?? utf8);
                        StandardError = new StreamReader(pipes[2], StartInfo.StandardErrorEncoding ?? utf8);
                        Check(ResumeThread(thread) != uint.MaxValue, "ResumeThread");
                    }
                    catch
                    {
                        TerminateProcess(nativeProcess, 1);
                        throw;
                    }
                }
                return true;
            }
            catch
            {
                job.Dispose();
                foreach (var pipe in pipes) pipe?.Dispose();
                process?.Dispose();
                throw;
            }
            finally
            {
                if (initialized) DeleteProcThreadAttributeList(list);
                Marshal.FreeHGlobal(list);
                Marshal.FreeHGlobal(handles);
                Marshal.FreeHGlobal(environment);
            }
        }

        public void Kill(bool entireProcessTree) => Check(TerminateJobObject(job, 1), "TerminateJobObject");

        public void StopOwnedProcesses(int milliseconds)
        {
            Kill(true);
            // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION.ActiveProcesses is at byte 40.
            var accounting = new byte[48];
            var clock = Stopwatch.StartNew();
            do
            {
                Check(QueryInformationJobObject(job, 1, accounting, accounting.Length, IntPtr.Zero), "QueryInformationJobObject");
                if (BitConverter.ToUInt32(accounting, 40) == 0) return;
                Thread.Sleep(20);
            } while (clock.ElapsedMilliseconds < milliseconds);
            throw new TimeoutException("Windows job termination grace expired before all owned processes exited.");
        }

        public void Dispose()
        {
            job?.Dispose();
            try { StandardInput?.Dispose(); } catch (IOException) { }
            StandardOutput?.Dispose();
            StandardError?.Dispose();
            process?.Dispose();
        }
    }
}
