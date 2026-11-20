using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Velopack;
using WinRT;

namespace Programa;

public static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        // Must run before anything else, --version included: Velopack's install, update and
        // uninstall hooks start the app with arguments that are handled and exit here.
        VelopackApp.Build().Run();

        if (args.Any(argument => argument is "--version" or "-V"))
        {
            Console.WriteLine(BuildIdentity.Value);
            return;
        }
        // Headless modes behind `programa config check` and `programa themes`, which read stdout from a pipe.
        if (args.FirstOrDefault() is SettingsCheck.LaunchArgument or ThemesCommand.LaunchArgument)
        {
            using var output = SettingsCheck.Utf8Writer(Console.OpenStandardOutput());
            using var error = SettingsCheck.Utf8Writer(Console.OpenStandardError());
            Environment.Exit(args[0] == SettingsCheck.LaunchArgument
                ? SettingsCheck.Run(args.ElementAtOrDefault(1), ShortcutSettings.SettingsPath, output, error)
                : ThemesCommand.Run(args[1..], ShortcutSettings.SettingsPath, ThemesCommand.ThemeDirectories(), output, error));
        }
        var conptyLoaded = LoadBundledConpty();
        // Markdown panels' WebView2 data lives with the app's other data, not beside the executable,
        // whose folder an update replaces.
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER")))
            Environment.SetEnvironmentVariable("WEBVIEW2_USER_DATA_FOLDER", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programa", $"WebView2{BuildIdentity.DevSuffix}"));
        if (args.Contains("--verify-native-libraries", StringComparer.Ordinal))
        {
            using var core = new CoreClient();
            _ = core.Snapshot();
            _ = NativeProbe.programa_terminal_is_terminated(nint.Zero);
            var openConsole = File.Exists(Path.Combine(AppContext.BaseDirectory, "OpenConsole.exe"));
            Console.WriteLine(conptyLoaded && openConsole ? "ok" : "bundled ConPTY missing (conpty.dll or OpenConsole.exe)");
            if (!conptyLoaded || !openConsole) Environment.Exit(1);
            return;
        }

        var smoke = BuildIdentity.IsSmoke;

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
            // A second UI would restore the same session IDs and prune the first one's live shells.
            using var identity = WindowsIdentity.GetCurrent();
            var user = identity.User ?? throw new InvalidOperationException("Could not identify the current Windows user.");
            using var instance = new Mutex(false, $"Darkroom.Programa{BuildIdentity.DevSuffix}.{user}",
                new NamedWaitHandleOptions { CurrentSessionOnly = false }, out var firstInstance);
            if (!firstInstance)
            {
                LaunchLog.Write("launch skipped: this Programa instance is already running");
                return;
            }
            LaunchLog.Write($"launch: starting (smoke={smoke}, conpty={(conptyLoaded ? "bundled" : "inbox")})");
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

    /// <summary>Loads the bundled conpty.dll from the app folder (the extraction folder for
    /// single-file builds, where the exe's own folder is not). The terminal library asks for
    /// "conpty.dll" by name and Windows reuses a loaded module of that name, so every session runs
    /// on the OpenConsole.exe beside it. False leaves sessions on the inbox ConPTY.</summary>
    private static bool LoadBundledConpty() =>
        NativeLibrary.TryLoad(Path.Combine(AppContext.BaseDirectory, "conpty.dll"), out _);
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

    public static string Version => Get("ProgramaVersion");

    private static string Get(string key) => Metadata.TryGetValue(key, out var value) ? value : "unknown";

    internal static bool IsSmoke { get; } = Environment.GetCommandLineArgs().Contains("--smoke", StringComparer.Ordinal);

    /// <summary>What a development build adds to the names of its pipe and files: "-dev", or "-dev-<tag>"
    /// with PROGRAMA_DEV_TAG (letters, digits and hyphens), so tagged dev builds run side by side as
    /// macOS reload.sh --tag builds do. Empty for an installed build.</summary>
    public static string DevSuffix { get; } = IsSmoke ? "-smoke" : DevSuffixFor(Value, Environment.GetEnvironmentVariable("PROGRAMA_DEV_TAG"));

    internal static string DevSuffixFor(string identity, string? tag) =>
        !identity.Contains("0.0.0-dev", StringComparison.Ordinal) ? string.Empty
        : tag is { Length: > 0 and <= 32 } && tag.All(c => char.IsAsciiLetterOrDigit(c) || c == '-') ? $"-dev-{tag.ToLowerInvariant()}"
        : "-dev";
}
