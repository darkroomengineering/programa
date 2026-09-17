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

        var smoke = args.Contains("--smoke", StringComparer.Ordinal);

        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
        {
            var error = eventArgs.ExceptionObject as Exception ?? new Exception($"Non-Exception unhandled object: {eventArgs.ExceptionObject}");
            LaunchLog.ReportFatal("Programa failed to start", error);
        };

        if (smoke)
        {
            // MainWindow's own smoke check only starts once the window has activated, and
            // caps itself at 20s waiting for a terminal snapshot. This is a second, wider
            // net for the case that MainWindow never activates at all -- e.g. Application.Start
            // itself blocks forever on a runner with no interactive desktop session, rather
            // than throwing. Runs on the thread pool, so it fires even if the STA/UI thread
            // is the one that's stuck; Environment.Exit terminates the whole process
            // regardless of what any other thread is doing.
            _ = Task.Delay(TimeSpan.FromSeconds(25)).ContinueWith(_ =>
            {
                LaunchLog.Write("smoke: watchdog fired -- Application.Start never reached a shown window in time");
                Environment.Exit(1);
            }, TaskScheduler.Default);
        }

        try
        {
            LaunchLog.Write($"launch: starting (smoke={smoke})");
            ComWrappersSupport.InitializeComWrappers();
            Application.Start(_1 =>
            {
                var dispatcher = DispatcherQueue.GetForCurrentThread();
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(dispatcher));
                _ = new App(smoke);
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
