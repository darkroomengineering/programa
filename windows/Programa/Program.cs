using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using WinRT;

namespace Programa;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Any(argument => argument is "--version" or "-V"))
        {
            Console.WriteLine(BuildIdentity.Value);
            return;
        }
        if (args.Contains("--verify-native-libraries", StringComparer.Ordinal))
        {
            using var core = new CoreClient();
            _ = core.Snapshot();
            _ = NativeProbe.programa_terminal_is_terminated(nint.Zero);
            Console.WriteLine("ok");
            return;
        }

        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
        {
            var error = eventArgs.ExceptionObject as Exception ?? new Exception($"Non-Exception unhandled object: {eventArgs.ExceptionObject}");
            LaunchLog.ReportFatal("Programa failed to start", error);
        };

        try
        {
            LaunchLog.Write("launch: starting");
            ComWrappersSupport.InitializeComWrappers();
            Application.Start(_ =>
            {
                var dispatcher = DispatcherQueue.GetForCurrentThread();
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(dispatcher));
                _ = new App();
            });
        }
        catch (Exception error)
        {
            LaunchLog.ReportFatal("Programa failed to start", error);
            Environment.Exit(1);
        }
    }
}

internal static partial class NativeProbe
{
    [LibraryImport("programa_terminal")]
    internal static partial byte programa_terminal_is_terminated(nint session);
}

public static class BuildIdentity
{
    private static readonly IReadOnlyDictionary<string, string> Metadata = Assembly
        .GetExecutingAssembly()
        .GetCustomAttributes<AssemblyMetadataAttribute>()
        .ToDictionary(attribute => attribute.Key, attribute => attribute.Value ?? "", StringComparer.Ordinal);

    public static string Value => $"programa {Get("ProgramaVersion")} (build {Get("ProgramaBuild")}, commit {Get("ProgramaCommit")})";

    private static string Get(string key) => Metadata.TryGetValue(key, out var value) ? value : "unknown";
}
