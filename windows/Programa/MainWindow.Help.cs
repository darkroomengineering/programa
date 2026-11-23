using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>The sidebar footer's Help menu (macOS Sources/SidebarVisuals.swift) and what macOS keeps in
/// its app menu, here in the Help menu and the command palette: About Programa, Check for Updates,
/// Ghostty Settings…, Install Codex Integration… and the jump to a blocked agent.</summary>
public sealed partial class MainWindow
{
    internal const string RepositoryUrl = "https://github.com/darkroomengineering/programa";

    // ponytail: the Windows release publishes no feed Velopack's UpdateManager can read (`rolling` carries
    // only programa-windows.exe), so Check for Updates opens the releases page. Check and install with
    // UpdateManager once ship-windows.yml publishes releases.win.json there.
    internal const string ReleasesUrl = RepositoryUrl + "/releases/latest";

    /// <summary>The Help menu's links, as on macOS.</summary>
    internal static readonly (string LabelKey, string Url)[] HelpLinks =
    [
        ("HelpDocs", RepositoryUrl + "/tree/main/docs"),
        ("HelpChangelog", RepositoryUrl + "/blob/main/CHANGELOG.md"),
        ("HelpGitHub", RepositoryUrl),
        ("HelpGitHubIssues", RepositoryUrl + "/issues"),
        ("HelpTwitter", "https://x.com/darkroomdevs"),
        ("HelpWebsite", "https://darkroom.engineering"),
    ];

    private AppBarButton HelpButton()
    {
        var label = Localizer.Get("Help");
        var button = new AppBarButton { Icon = new FontIcon { Glyph = char.ConvertFromUtf32(0xE897) }, LabelPosition = CommandBarLabelPosition.Collapsed, Width = 44, MinHeight = 44 };
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        button.Click += (_, _) => ShowFooterFlyout(HelpMenu(), button);
        return button;
    }

    private MenuFlyout HelpMenu()
    {
        var menu = new MenuFlyout();
        menu.Items.Add(MenuItem(Localizer.Get("HelpWelcome"), ShowWelcome));
        var feedback = MenuItem(Localizer.Get("HelpSendFeedback"), () => OpenFeedback());
        feedback.KeyboardAcceleratorTextOverride = ShortcutSettings.Display(_shortcuts.Values["send_feedback"]);
        menu.Items.Add(feedback);
        menu.Items.Add(MenuItem(Localizer.Get("SettingsShortcuts"), () => _ = ShowSettingsAsync("keyboardShortcuts")));
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var (key, url) in HelpLinks)
        {
            var link = MenuItem(Localizer.Get(key), () => OpenUrl(url));
            AutomationProperties.SetHelpText(link, url);
            menu.Items.Add(link);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var updates = MenuItem(Localizer.Get("CheckForUpdates"), CheckForUpdates);
        AutomationProperties.SetHelpText(updates, ReleasesUrl);
        menu.Items.Add(updates);
        menu.Items.Add(MenuItem(Localizer.Get("AboutPrograma"), () => _ = ShowAboutAsync()));
        return menu;
    }

    /// <summary>Palette entries for what macOS keeps in its menu bar and app menu.</summary>
    private IEnumerable<(string Label, string Hint, string Keywords, Action Run)> HelpPaletteEntries()
    {
        if (BlockedAgentsLabel() is { } blocked) yield return (Localizer.Get("JumpToBlockedAgent"), blocked, "blocked agent waiting input", JumpToFirstBlockedAgent);
        if (_notifications.HasUnread) yield return (Localizer.Get("MarkAllRead"), Localizer.Get("Notifications"), "notifications read", _notifications.MarkAllRead);
        yield return (Localizer.Get("GhosttySettings"), string.Empty, "ghostty config configuration terminal theme font", OpenGhosttyConfig);
        yield return (Localizer.Get("InstallCodexIntegration"), Localizer.Get("Integrations"), "codex openai integration hooks agent install setup", InstallCodexIntegration);
        yield return (Localizer.Get("ShowWelcome"), Localizer.Get("Help"), "welcome onboarding intro help", ShowWelcome);
        yield return (Localizer.Get("CheckForUpdates"), string.Empty, "update upgrade version release", CheckForUpdates);
        yield return (Localizer.Get("AboutPrograma"), string.Empty, "about version build licenses", () => _ = ShowAboutAsync());
    }

    /// <summary>Welcome to Programa!: a new workspace running `programa welcome`, as on macOS.</summary>
    private void ShowWelcome() => NewWorkspaceRunning("programa welcome");

    /// <summary>A new workspace running `programa codex install-integration`, which asks before it changes anything.</summary>
    private void InstallCodexIntegration() => NewWorkspaceRunning("programa codex install-integration");

    private void NewWorkspaceRunning(string command)
    {
        _nextTerminalCommand = command;
        NewWorkspace();
    }

    private static void CheckForUpdates() => OpenUrl(ReleasesUrl);

    private static void OpenUrl(string url) => _ = Windows.System.Launcher.LaunchUriAsync(new Uri(url));

    /// <summary>Ghostty Settings…: the Ghostty config the terminal reads, in Notepad (macOS opens TextEdit),
    /// created empty when there is none. Reload Configuration applies it.</summary>
    private static void OpenGhosttyConfig()
    {
        var path = TerminalAppearance.ConfigFileToEdit(TerminalAppearance.GhosttyDirectory);
        try
        {
            if (!File.Exists(path))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, string.Empty);
            }
            Process.Start("notepad.exe", $"\"{path}\"")?.Dispose();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            LaunchLog.Write($"ghostty: could not open {path}: {error.Message}");
        }
    }

    /// <summary>About Programa: version, build and commit, Docs, GitHub and the third-party licenses.</summary>
    private async Task ShowAboutAsync()
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = Localizer.Get("AboutAppName"), CloseButtonText = Localizer.Get("Close"), DefaultButton = ContentDialogButton.Close };
        var panel = new StackPanel { Spacing = 12, MinWidth = 360 };
        panel.Children.Add(new TextBlock { Text = Localizer.Get("AboutDescription"), TextWrapping = TextWrapping.Wrap, Opacity = 0.8 });

        var properties = new Grid { ColumnSpacing = 16, RowSpacing = 4 };
        properties.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        properties.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var commit = BuildIdentity.Commit;
        var shortCommit = commit.Length > 7 ? commit[..7] : commit;
        // A dev build's placeholder commit (all zeros) links nowhere.
        FrameworkElement commitValue = commit.Trim('0').Length == 0 || !commit.All(char.IsAsciiHexDigit)
            ? new TextBlock { Text = shortCommit, IsTextSelectionEnabled = true }
            : new HyperlinkButton { Content = shortCommit, NavigateUri = new Uri(RepositoryUrl + "/commit/" + commit), Padding = new Thickness(0) };
        var rows = new (string Key, FrameworkElement Value)[]
        {
            ("AboutVersion", new TextBlock { Text = BuildIdentity.Version, IsTextSelectionEnabled = true }),
            ("AboutBuild", new TextBlock { Text = BuildIdentity.Build, IsTextSelectionEnabled = true }),
            ("AboutCommit", commitValue),
        };
        for (var row = 0; row < rows.Length; row++)
        {
            properties.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = Localizer.Get(rows[row].Key), Opacity = 0.7 };
            Grid.SetRow(label, row);
            Grid.SetRow(rows[row].Value, row);
            Grid.SetColumn(rows[row].Value, 1);
            properties.Children.Add(label);
            properties.Children.Add(rows[row].Value);
        }
        panel.Children.Add(properties);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var (key, url) in HelpLinks.Where(link => link.LabelKey is "HelpDocs" or "HelpGitHub"))
        {
            var link = new HyperlinkButton { Content = Localizer.Get(key), NavigateUri = new Uri(url) };
            AutomationProperties.SetHelpText(link, url);
            buttons.Children.Add(link);
        }
        var licenses = new HyperlinkButton { Content = Localizer.Get("AboutLicenses") };
        licenses.Click += (_, _) =>
        {
            dialog.Title = Localizer.Get("AboutLicensesTitle");
            dialog.Content = new ScrollViewer { MaxHeight = 480, Content = new TextBlock { Text = ThirdPartyLicenses(), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12 } };
        };
        buttons.Children.Add(licenses);
        panel.Children.Add(buttons);
        const string incubator = "https://darkroom.engineering/incubator";
        var credit = new HyperlinkButton { Content = Localizer.Get("AboutIncubatorCredit"), NavigateUri = new Uri(incubator), FontSize = 12, Padding = new Thickness(0) };
        AutomationProperties.SetHelpText(credit, incubator);
        panel.Children.Add(credit);
        dialog.Content = panel;

        _dialogOpen = true;
        try { await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
    }

    /// <summary>THIRD_PARTY_LICENSES.md, which the build copies beside the app.</summary>
    private static string ThirdPartyLicenses()
    {
        try { return File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "THIRD_PARTY_LICENSES.md")); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return Localizer.Get("AboutLicensesNotFound"); }
    }
}
