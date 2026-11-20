using System.Buffers.Binary;
using System.Runtime.InteropServices;

namespace Programa;

/// <summary>Which programs run under a shell, from one Toolhelp snapshot of the process table, and
/// which processes listen on TCP ports.</summary>
internal static partial class ProcessTree
{
    private const uint SnapshotProcesses = 0x2;

    internal readonly record struct ProcessInfo(uint Parent, string Name);

    /// <summary>Every process by pid, with its parent and image name.</summary>
    internal static Dictionary<uint, ProcessInfo> Snapshot()
    {
        var processes = new Dictionary<uint, ProcessInfo>();
        var snapshot = CreateToolhelp32Snapshot(SnapshotProcesses, 0);
        if (snapshot == -1) return processes;
        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            for (var more = Process32FirstW(snapshot, ref entry); more; more = Process32NextW(snapshot, ref entry))
                processes[entry.ProcessId] = new ProcessInfo(entry.ParentProcessId, entry.ExeFile);
        }
        finally
        {
            CloseHandle(snapshot);
        }
        return processes;
    }

    /// <summary>The image names of every direct child of each shell, keyed by shell pid. A shell
    /// with no entry has nothing running.</summary>
    internal static Dictionary<uint, List<string>> ChildrenOf(IReadOnlySet<uint> shells)
    {
        var children = new Dictionary<uint, List<string>>();
        if (shells.Count == 0) return children;
        foreach (var (pid, process) in Snapshot())
        {
            if (!shells.Contains(process.Parent) || pid == process.Parent) continue;
            if (!children.TryGetValue(process.Parent, out var names)) children[process.Parent] = names = [];
            names.Add(process.Name);
        }
        return children;
    }

    /// <summary>The first of <paramref name="shells"/> found walking up from <paramref name="pid"/>
    /// (the pid itself included), or 0. Parent pids can be reused, so the walk is bounded.</summary>
    internal static uint OwningShell(uint pid, Dictionary<uint, ProcessInfo> processes, IReadOnlySet<uint> shells)
    {
        for (var depth = 0; depth < 32 && pid != 0; depth++)
        {
            if (shells.Contains(pid)) return pid;
            if (!processes.TryGetValue(pid, out var process) || process.Parent == pid) return 0;
            pid = process.Parent;
        }
        return 0;
    }

    /// <summary>Every (port, pid) listening on TCP over IPv4 or IPv6, without duplicates.</summary>
    internal static List<(int Port, uint Pid)> ListeningPorts()
    {
        var listeners = new HashSet<(int, uint)>();
        // MIB_TCPROW_OWNER_PID is 24 bytes, MIB_TCP6ROW_OWNER_PID 56; both after a 4-byte count.
        ReadTable(2, 24, 8, 20, listeners);
        ReadTable(23, 56, 20, 52, listeners);
        return listeners.OrderBy(item => item.Item1).ToList();
    }

    private static void ReadTable(int family, int rowSize, int portOffset, int pidOffset, HashSet<(int, uint)> listeners)
    {
        const int TableOwnerPidListener = 3;
        var size = 0;
        GetExtendedTcpTable(0, ref size, false, family, TableOwnerPidListener, 0);
        if (size == 0) return;
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (GetExtendedTcpTable(buffer, ref size, false, family, TableOwnerPidListener, 0) != 0) return;
            var count = Marshal.ReadInt32(buffer);
            for (var index = 0; index < count; index++)
            {
                var row = buffer + 4 + index * rowSize;
                // The port is in network byte order in the low 16 bits.
                var port = BinaryPrimitives.ReverseEndianness((ushort)Marshal.ReadInt32(row + portOffset));
                var pid = (uint)Marshal.ReadInt32(row + pidOffset);
                if (pid > 4) listeners.Add((port, pid));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint ProcessId;
        public nint DefaultHeapId;
        public uint ModuleId;
        public uint Threads;
        public uint ParentProcessId;
        public int PriorityClassBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern nint CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32FirstW(nint snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32NextW(nint snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
    [DllImport("iphlpapi.dll")] private static extern uint GetExtendedTcpTable(nint table, ref int size, bool sort, int family, int tableClass, uint reserved);
}
