using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace Programa;

/// <summary>Stop Leftover Agent Processes (app.reapLeftoverAgentProcesses), the Windows version of macOS's
/// LeftoverProcessReaper (windows/README.md). Each terminal's shell runs in a job object, and the job's
/// new-process notifications record, as each process starts, which child of the shell it descends from
/// (its root) and whether `nohup` started it or one of its ancestors. Windows parent links go stale once
/// a parent exits, so they are read when a process starts, not when the agent exits. When a root that is
/// a Claude Code session exits, what it started and left running is stopped, except under `nohup`.</summary>
internal static partial class LeftoverReaper
{
    /// <summary>A process in a watched terminal: the shell's child it descends from, and whether nohup started it.</summary>
    internal sealed record Entry(uint Pid, long Started, string Name, uint Root, bool Nohup);

    /// <summary>One terminal's processes, fed by the job's notifications. Not thread-safe; callers lock it.</summary>
    internal sealed class Lineage(uint shell)
    {
        private readonly Dictionary<uint, Entry> _entries = [];
        private readonly HashSet<uint> _agents = [];

        internal uint Shell => shell;

        /// <summary>A process joined the job. One whose parent is unknown (started before the job, or the parent
        /// was never seen) has no root, so it is never stopped.</summary>
        internal void Started(uint pid, uint parent, long started, string name)
        {
            if (pid == shell || (_entries.TryGetValue(pid, out var known) && known.Started == started)) return;
            var nohup = string.Equals(name, "nohup.exe", StringComparison.OrdinalIgnoreCase);
            if (parent == shell)
            {
                _entries[pid] = new Entry(pid, started, name, pid, nohup);
                if (AgentImages.Contains(name)) _agents.Add(pid);
            }
            // A parent that started after its child is someone else who got the pid.
            else if (_entries.TryGetValue(parent, out var up) && up.Started <= started) _entries[pid] = new Entry(pid, started, name, up.Root, nohup || up.Nohup);
            else _entries.Remove(pid);
        }

        /// <summary>The shell's children running now are Claude Code sessions (the terminal's status says so).</summary>
        internal void MarkAgents()
        {
            foreach (var entry in _entries.Values) if (entry.Root == entry.Pid) _agents.Add(entry.Pid);
        }

        /// <summary>A process left the job; true when it was a Claude Code session, whose leftovers are then due.</summary>
        internal bool Exited(uint pid)
        {
            _entries.Remove(pid);
            return _agents.Remove(pid);
        }

        /// <summary>What the exited session <paramref name="root"/> started and left running, forgotten here, and what nohup keeps.</summary>
        internal (List<Entry> Stop, List<Entry> Kept) TakeLeftovers(uint root)
        {
            var mine = _entries.Values.Where(entry => entry.Root == root).ToList();
            foreach (var entry in mine) _entries.Remove(entry.Pid);
            return (mine.Where(entry => !entry.Nohup).ToList(), mine.Where(entry => entry.Nohup).ToList());
        }
    }

    private sealed record Watched(nint Job, Lineage Lineage, long ShellStarted);

    private const uint NewProcess = 6, ExitProcess = 7, AbnormalExitProcess = 8, ActiveProcessZero = 4;
    private static readonly object Gate = new();
    private static readonly ConcurrentDictionary<nuint, Watched> Jobs = new();
    private static readonly ConcurrentDictionary<uint, nuint> ByShell = new();
    private static nint _port;
    private static nuint _nextKey;

    /// <summary>How long after a session exits its leftovers are stopped, as macOS's reap grace.</summary>
    internal static TimeSpan Grace { get; set; } = TimeSpan.FromSeconds(2);

    /// <summary>Images that are a Claude Code session when the shell starts them, without waiting for the terminal's status.</summary>
    internal static HashSet<string> AgentImages { get; } = new(StringComparer.OrdinalIgnoreCase) { "claude.exe" };

    /// <summary>After each reap: the session's pid, what was stopped and what nohup kept.</summary>
    internal static event Action<uint, IReadOnlyList<Entry>, IReadOnlyList<Entry>>? Reaped;

    /// <summary>Whether reaping is on when a session exits; the app reads settings.json.</summary>
    internal static Func<bool> Enabled { get; set; } = () => AppSettings.Load().ReapLeftoverAgentProcesses;

    /// <summary>Puts the shell in a job, once per shell process. Processes it already runs (a shell reattached
    /// after a restart) join as well, as far as Windows lets them.</summary>
    internal static void Watch(uint shellPid)
    {
        if (shellPid == 0 || Describe(shellPid) is not { } shell) return;
        lock (Gate)
        {
            if (ByShell.TryGetValue(shellPid, out var existing) && Jobs.TryGetValue(existing, out var known) && known.ShellStarted == shell.Started) return;
            if (_port == 0)
            {
                _port = CreateIoCompletionPort(-1, 0, 0, 1);
                if (_port == 0) return;
                new Thread(Listen) { IsBackground = true, Name = "leftover-reaper" }.Start();
            }
            var job = CreateJobObjectW(0, null);
            if (job == 0) return;
            // No limits, breakaway included: Git Bash starts every native program with CREATE_BREAKAWAY_FROM_JOB
            // when the job allows it, so allowing it would let everything an agent's Bash tool starts escape.
            var key = ++_nextKey;
            var port = new AssociatePort { CompletionKey = key, CompletionPort = _port };
            var watched = new Watched(job, new Lineage(shellPid), shell.Started);
            Jobs[key] = watched;
            var handle = OpenProcess(SetQuota | Terminate | QueryLimited, false, shellPid);
            if (!SetInformationJobObject(job, 7, ref port, Marshal.SizeOf<AssociatePort>()) ||
                handle == 0 || !AssignProcessToJobObject(job, handle))
            {
                LaunchLog.Write($"reaper: shell {shellPid} not watched (error {Marshal.GetLastWin32Error()})");
                Jobs.TryRemove(key, out _);
                if (handle != 0) CloseHandle(handle);
                CloseHandle(job);
                return;
            }
            CloseHandle(handle);
            ByShell[shellPid] = key;
            Adopt(watched);
        }
    }

    /// <summary>Whether a job holds this shell pid (a reused pid is caught by <see cref="Watch"/>).</summary>
    internal static bool Watching(uint shellPid) => ByShell.ContainsKey(shellPid);

    /// <summary>The shell's running children are Claude Code sessions.</summary>
    internal static void MarkAgents(uint shellPid)
    {
        if (ByShell.TryGetValue(shellPid, out var key) && Jobs.TryGetValue(key, out var watched))
            lock (watched.Lineage) watched.Lineage.MarkAgents();
    }

    /// <summary>Records and joins what already runs under the shell, parents first.</summary>
    private static void Adopt(Watched watched)
    {
        var processes = ProcessTree.Snapshot();
        var queue = new Queue<uint>([watched.Lineage.Shell]);
        while (queue.Count > 0)
        {
            var parent = queue.Dequeue();
            foreach (var (pid, process) in processes)
            {
                if (process.Parent != parent || pid == parent || Describe(pid) is not { } child) continue;
                lock (watched.Lineage) watched.Lineage.Started(pid, child.Parent, child.Started, child.Name);
                var handle = OpenProcess(SetQuota | Terminate, false, pid);
                if (handle != 0) { AssignProcessToJobObject(watched.Job, handle); CloseHandle(handle); }
                queue.Enqueue(pid);
            }
        }
    }

    private static void Listen()
    {
        while (GetQueuedCompletionStatus(_port, out var message, out var key, out var value, uint.MaxValue))
        {
            if (!Jobs.TryGetValue(key, out var watched)) continue;
            var pid = (uint)value;
            switch (message)
            {
                case NewProcess when Describe(pid) is { } process:
                    lock (watched.Lineage) watched.Lineage.Started(pid, process.Parent, process.Started, process.Name);
                    break;
                case ExitProcess or AbnormalExitProcess:
                    bool agent;
                    lock (watched.Lineage) agent = watched.Lineage.Exited(pid);
                    if (agent) _ = Task.Delay(Grace).ContinueWith(_ => Reap(watched, pid), TaskScheduler.Default);
                    break;
                case ActiveProcessZero:
                    Jobs.TryRemove(key, out _);
                    ByShell.TryRemove(new KeyValuePair<uint, nuint>(watched.Lineage.Shell, key));
                    CloseHandle(watched.Job);
                    break;
            }
        }
    }

    /// <summary>Stops what the exited session left running: each process still the one recorded (same start time).</summary>
    private static void Reap(Watched watched, uint root)
    {
        List<Entry> stop, kept;
        lock (watched.Lineage) (stop, kept) = watched.Lineage.TakeLeftovers(root);
        if (!Enabled())
        {
            LaunchLog.Write($"reaper: owner={root} exited reaping=off");
            return;
        }
        var stopped = new List<Entry>();
        foreach (var entry in stop)
        {
            if (entry.Pid == Environment.ProcessId) continue;
            var handle = OpenProcess(Terminate | QueryLimited, false, entry.Pid);
            if (handle == 0) continue;
            try
            {
                if (GetProcessTimes(handle, out var started, out _, out _, out _) && started == entry.Started && TerminateProcess(handle, 1)) stopped.Add(entry);
            }
            finally { CloseHandle(handle); }
        }
        LaunchLog.Write($"reaper: owner={root} exited reaped={stopped.Count} keptNohup={kept.Count} names={string.Join(",", stopped.Take(10).Select(entry => entry.Name))}");
        Reaped?.Invoke(root, stopped, kept);
    }

    /// <summary>A live process's parent, start time and image name, or null when it cannot be opened.</summary>
    internal static (uint Parent, long Started, string Name)? Describe(uint pid)
    {
        var handle = OpenProcess(QueryLimited, false, pid);
        if (handle == 0) return null;
        try
        {
            var info = new BasicInformation();
            if (NtQueryInformationProcess(handle, 0, ref info, Marshal.SizeOf<BasicInformation>(), out _) != 0) return null;
            if (!GetProcessTimes(handle, out var started, out _, out _, out _)) return null;
            var buffer = new char[1024];
            var size = buffer.Length;
            var name = QueryFullProcessImageNameW(handle, 0, buffer, ref size) ? Path.GetFileName(new string(buffer, 0, size)) : string.Empty;
            return ((uint)info.InheritedFromUniqueProcessId, started, name);
        }
        finally { CloseHandle(handle); }
    }

    private const uint Terminate = 0x1, SetQuota = 0x100, QueryLimited = 0x1000;

    [StructLayout(LayoutKind.Sequential)]
    private struct AssociatePort { public nuint CompletionKey; public nint CompletionPort; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicInformation
    {
        public nint ExitStatus, PebBaseAddress, AffinityMask, BasePriority;
        public nuint UniqueProcessId, InheritedFromUniqueProcessId;
    }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint CreateIoCompletionPort(nint file, nint existing, nuint key, uint threads);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetQueuedCompletionStatus(nint port, out uint bytes, out nuint key, out nint overlapped, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern nint CreateJobObjectW(nint attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(nint job, int infoClass, ref AssociatePort info, int size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(nint job, nint process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(nint process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(nint process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool QueryFullProcessImageNameW(nint process, uint flags, char[] name, ref int size);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
    [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(nint process, int infoClass, ref BasicInformation info, int size, out int returned);
}
