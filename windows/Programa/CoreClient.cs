using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Programa;

public sealed partial class CoreClient : IDisposable
{
    private const uint SupportedAbiVersion = 1;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly ProgramaCoreHandle _handle;

    public CoreClient()
    {
        var actual = Native.programa_core_abi_version();
        if (actual != SupportedAbiVersion)
            throw new NotSupportedException($"programa_core ABI {actual} is not supported; expected {SupportedAbiVersion}.");
        _handle = Native.programa_core_create();
        if (_handle.IsInvalid) throw new InvalidOperationException("programa_core_create failed.");
    }

    public CoreSnapshot Snapshot() => ParseSnapshot(InvokeSnapshot());

    public CoreSnapshot Dispatch(object command)
    {
        var request = JsonSerializer.SerializeToUtf8Bytes(command, JsonOptions);
        unsafe
        {
            fixed (byte* data = request)
            {
                var status = Native.programa_core_dispatch(_handle, data, (nuint)request.Length, out var buffer);
                var json = Consume(buffer);
                if (status != 0) throw ParseError(json);
                return JsonSerializer.Deserialize<DispatchResponse>(json, JsonOptions)?.Snapshot
                    ?? throw new InvalidDataException("programa_core returned no snapshot.");
            }
        }
    }

    public void Dispose() => _handle.Dispose();

    private unsafe string InvokeSnapshot()
    {
        var status = Native.programa_core_snapshot(_handle, out var buffer);
        var json = Consume(buffer);
        if (status != 0) throw ParseError(json);
        return json;
    }

    private static CoreSnapshot ParseSnapshot(string json) =>
        JsonSerializer.Deserialize<CoreSnapshot>(json, JsonOptions)
        ?? throw new InvalidDataException("programa_core returned an empty snapshot.");

    private static Exception ParseError(string json)
    {
        try
        {
            var error = JsonSerializer.Deserialize<CoreErrorEnvelope>(json, JsonOptions)?.Error;
            if (error is not null) return new CoreCommandException(error.Code, error.Message);
        }
        catch (JsonException) { }
        return new CoreCommandException("native_error", string.IsNullOrWhiteSpace(json) ? "programa_core failed without an error payload." : json);
    }

    private static unsafe string Consume(ProgramaBuffer buffer)
    {
        try
        {
            if (buffer.Data == null || buffer.Length == 0) return "";
            if (buffer.Length > int.MaxValue) throw new InvalidDataException("programa_core returned an oversized buffer.");
            return Encoding.UTF8.GetString(buffer.Data, checked((int)buffer.Length));
        }
        finally
        {
            Native.programa_core_buffer_free(buffer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct ProgramaBuffer
    {
        public byte* Data;
        public nuint Length;
        public nuint Capacity;
    }

    private sealed class ProgramaCoreHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public ProgramaCoreHandle() : base(true) { }
        protected override bool ReleaseHandle()
        {
            Native.programa_core_destroy(handle);
            return true;
        }
    }

    private static partial class Native
    {
        private const string Library = "programa_core";

        [LibraryImport(Library)] internal static partial uint programa_core_abi_version();
        [LibraryImport(Library)] internal static partial ProgramaCoreHandle programa_core_create();
        [LibraryImport(Library)] internal static partial void programa_core_destroy(nint core);
        [LibraryImport(Library)] internal static unsafe partial int programa_core_dispatch(ProgramaCoreHandle core, byte* request, nuint len, out ProgramaBuffer result);
        [LibraryImport(Library)] internal static partial int programa_core_snapshot(ProgramaCoreHandle core, out ProgramaBuffer result);
        [LibraryImport(Library)] internal static partial void programa_core_buffer_free(ProgramaBuffer buffer);
    }
}

public sealed class CoreCommandException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
