using Microsoft.UI.Xaml;

namespace Programa;

public partial class App : Application
{
    private readonly bool _smoke;

    public App(bool smoke = false)
    {
        _smoke = smoke;
        InitializeComponent();
        UnhandledException += OnUnhandledException;
    }

    /// <summary>Opens every window of the last session, or one fresh window.</summary>
    protected override void OnLaunched(LaunchActivatedEventArgs args) => WindowRegistry.Launch(_smoke);

    private static void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs args)
    {
        if (LaunchLog.LaunchCompleted)
        {
            // The window is up: a stray UI exception should not take the user's terminals with it.
            LaunchLog.Write($"Unhandled UI exception (continuing): {args.Exception}");
            args.Handled = true;
            return;
        }
        LaunchLog.ReportFatal("Programa failed to start", args.Exception);
        // Mark handled so WinUI does not swallow this in a second, silent termination path;
        // we take responsibility for exiting deterministically and non-zero below.
        args.Handled = true;
        Environment.Exit(1);
    }
}
