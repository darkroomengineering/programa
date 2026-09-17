using Microsoft.UI.Xaml;

namespace Programa;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += OnUnhandledException;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }

    private static void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs args)
    {
        LaunchLog.ReportFatal("Programa failed to start", args.Exception);
        // Mark handled so WinUI does not swallow this in a second, silent termination path;
        // we take responsibility for exiting deterministically and non-zero below.
        args.Handled = true;
        Environment.Exit(1);
    }
}
