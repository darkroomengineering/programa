using System.Text.Json.Nodes;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>Settings, as the macOS Settings window: General, Terminal, Sidebar, Notifications, Worktrees, Storage,
/// Custom Commands, Automation and Keyboard Shortcuts, saved to the shared settings.json (only the values changed here are written)
/// and applied to every window at once.</summary>
public sealed partial class MainWindow
{
    /// <summary>Settings, at Keyboard Shortcuts when <paramref name="target"/> is keyboardShortcuts (settings.open).</summary>
    private async Task ShowSettingsAsync(string? target = null)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var app = AppSettings.Load();
        var worktrees = WorktreeSettings.Load();
        var appearanceValues = new[] { "system", "light", "dark" };
        var effectiveSize = TerminalAppearance.For(Root.ActualTheme != ElementTheme.Light).FontSize;

        var appearance = new ComboBox { Header = Localizer.Get("SettingsAppearance"), ItemsSource = new[] { Localizer.Get("AppearanceSystem"), Localizer.Get("AppearanceLight"), Localizer.Get("AppearanceDark") }, SelectedIndex = Array.IndexOf(appearanceValues, app.Appearance), MinWidth = 240 };
        var warn = new ToggleSwitch { Header = Localizer.Get("WarnBeforeQuit"), IsOn = app.WarnBeforeQuit };
        var placementValues = new[] { "top", "afterCurrent", "end" };
        var placement = new ComboBox { Header = Localizer.Get("NewWorkspacePlacement"), ItemsSource = new[] { Localizer.Get("PlacementTop"), Localizer.Get("PlacementAfterCurrent"), Localizer.Get("PlacementEnd") }, SelectedIndex = Array.IndexOf(placementValues, app.NewWorkspacePlacement), MinWidth = 240 };
        var confirmLastTab = Switch("ConfirmCloseLastPane", app.ConfirmCloseLastPane);
        var paletteAll = Switch("CommandPaletteSearchesAllSurfaces", app.CommandPaletteSearchesAllSurfaces);
        var autoResume = Switch("AutoResumeAgents", app.AutoResumeAgents);
        var reapLeftovers = Switch("ReapLeftoverAgentProcesses", app.ReapLeftoverAgentProcesses);
        var saveScrollback = Switch("SaveScrollbackOnQuit", app.SaveScrollbackOnQuit);
        var screenDetection = Switch("AgentScreenDetection", app.AgentScreenDetection);
        var screenDetectionNote = new TextBlock { Text = Localizer.Get("AgentScreenDetectionNote"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7, Margin = new Thickness(0, -12, 0, 0) };
        // Reset All Settings asks in a flyout: Settings is already the one dialog WinUI shows at a time.
        ContentDialog? settingsDialog = null;
        var resetConfirm = new Button { Content = Localizer.Get("ResetAllSettingsConfirm") };
        var resetFlyout = new Flyout
        {
            Content = new StackPanel
            {
                Spacing = 12, MaxWidth = 360,
                Children = { new TextBlock { Text = Localizer.Get("ResetAllSettingsMessage"), TextWrapping = TextWrapping.Wrap }, resetConfirm },
            },
        };
        var resetError = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        var resetAll = new StackPanel { Spacing = 4, Children = { new Button { Content = Localizer.Get("ResetAllSettings"), Flyout = resetFlyout }, resetError } };
        resetConfirm.Click += (_, _) =>
        {
            resetFlyout.Hide();
            try
            {
                ShortcutSettings.RemoveValues(ResetKeys);
                WindowRegistry.ApplySettings();
                // Closed without saving, so the rows' old values are not written back; reopening shows the defaults.
                settingsDialog?.Hide();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
            {
                resetError.Text = $"{Localizer.Get("SettingsError")}: {error.Message}";
                resetError.Visibility = Visibility.Visible;
            }
        };
        var openFile = new Button { Content = Localizer.Get("SettingsFileOpen") };
        openFile.Click += (_, _) => OpenSettingsFile();
        var settingsFile = new StackPanel
        {
            Spacing = 4,
            Children = { new TextBlock { Text = Localizer.Get("SettingsFile") }, new TextBlock { Text = ShortcutSettings.SettingsPath, Opacity = 0.7, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap }, openFile },
        };
        var claudeIntegration = Switch("ClaudeCodeIntegration", app.ClaudeCodeIntegration);
        var claudeTeams = Switch("ClaudeTeamsByDefault", app.ClaudeTeamsByDefault);
        var holdText = Switch("HoldAgentTextWhileTyping", app.HoldAgentTextWhileTyping);
        var protectPrompts = Switch("ProtectApprovalPrompts", app.ProtectApprovalPrompts);
        var newTerminalsNote = new TextBlock { Text = Localizer.Get("AppliesToNewTerminals"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
        // automation.socketControlMode: allowAll and the legacy names show as Automation, which is what they mean here.
        var socketModes = new[] { "off", "programaOnly", "automation", "password" };
        string[] modeKeys = ["SocketModeOff", "SocketModeProgramaOnly", "SocketModeAutomation", "SocketModePassword"];
        var socketMode = new ComboBox { Header = Localizer.Get("SocketControlMode"), ItemsSource = modeKeys.Select(Localizer.Get).ToList(), SelectedIndex = Array.IndexOf(socketModes, app.SocketControlMode), MinWidth = 240 };
        var socketModeNote = new TextBlock { TextWrapping = TextWrapping.Wrap, Opacity = 0.7, Margin = new Thickness(0, -12, 0, 0) };
        var socketPassword = new PasswordBox { Header = Localizer.Get("SocketPassword"), PlaceholderText = Localizer.Get("SocketPasswordPlaceholder"), MinWidth = 240, HorizontalAlignment = HorizontalAlignment.Left };
        var passwordNote = new TextBlock { Text = Localizer.Get(app.SocketPassword is null ? "SocketPasswordUnset" : "SocketPasswordSet"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
        var clearPassword = new Button { Content = Localizer.Get("SocketPasswordClear"), IsEnabled = app.SocketPassword is not null };
        var passwordCleared = false;
        clearPassword.Click += (_, _) => { passwordCleared = true; socketPassword.Password = ""; clearPassword.IsEnabled = false; passwordNote.Text = Localizer.Get("SocketPasswordCleared"); };
        var passwordRow = new StackPanel { Spacing = 4, Children = { socketPassword, passwordNote, clearPassword } };
        void ShowSocketMode()
        {
            socketModeNote.Text = Localizer.Get(modeKeys[Math.Max(0, socketMode.SelectedIndex)] + "Description");
            passwordRow.Visibility = socketMode.SelectedIndex == 3 ? Visibility.Visible : Visibility.Collapsed;
        }
        socketMode.SelectionChanged += (_, _) => ShowSocketMode();
        ShowSocketMode();

        var themes = ThemeNames();
        var themeLight = EditableBox(Localizer.Get("TerminalThemeLight"), themes, app.ThemeLight);
        var themeDark = EditableBox(Localizer.Get("TerminalThemeDark"), themes, app.ThemeDark);
        var fonts = new[] { TerminalAppearance.BundledFontFamily }.Concat(CanvasTextFormat.GetSystemFontFamilies().Order(StringComparer.OrdinalIgnoreCase)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var fontFamily = EditableBox(Localizer.Get("TerminalFontFamily"), fonts, app.FontFamily);
        var fontSize = new NumberBox { Header = Localizer.Get("TerminalFontSize"), Minimum = 6, Maximum = 72, Value = app.FontSize ?? effectiveSize, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, HorizontalAlignment = HorizontalAlignment.Left };

        // notifications.sound: the Windows toast sounds, then None; a macOS name shows as the sound it plays here.
        var soundEvents = AppSettings.WindowsSounds.Select(item => (string?)item.Event).Append(null).ToList();
        var initialSound = soundEvents.IndexOf(AppSettings.SoundEventFor(app.Sound));
        var sound = new ComboBox
        {
            Header = Localizer.Get("NotificationSoundTitle"), Description = Localizer.Get("NotificationSoundSubtitle"), MinWidth = 240,
            ItemsSource = soundEvents.Select(item => Localizer.Get("Sound" + (item ?? "None"))).ToList(), SelectedIndex = initialSound,
        };
        // Beside the box, level with it: the box's description sits below.
        var playSound = new Button { Content = Localizer.Get("NotificationSoundPreview"), Margin = new Thickness(0, 28, 0, 0), VerticalAlignment = VerticalAlignment.Top };
        playSound.Click += (_, _) => NotificationCenter.PlaySound(soundEvents[Math.Max(0, sound.SelectedIndex)]);
        var soundRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { sound, playSound } };
        // Desktop notifications, as the macOS row: whether Windows shows them, and where to change it.
        var notificationState = new TextBlock { Text = Localizer.Get(NotificationCenter.DesktopNotificationsEnabled ? "DesktopNotificationsOn" : "DesktopNotificationsOff"), TextWrapping = TextWrapping.Wrap };
        var notificationSettings = new HyperlinkButton { Content = Localizer.Get("OpenWindowsNotificationSettings"), Padding = new Thickness(0) };
        notificationSettings.Click += (_, _) => _ = Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"));
        var notifications = new StackPanel { Spacing = 4, Children = { new TextBlock { Text = Localizer.Get("DesktopNotifications") }, notificationState, notificationSettings } };

        var worktreeFolder = new TextBox { Header = Localizer.Get("WorktreeDirectory"), Text = worktrees.Directory };
        var autoRemove = new ToggleSwitch { Header = Localizer.Get("WorktreeAutoRemove"), IsOn = worktrees.AutoRemoveMerged };
        var autoRemoveHours = new NumberBox { Header = Localizer.Get("WorktreeAutoRemoveHours"), Minimum = 1, Value = worktrees.AutoRemoveAfterHours, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, HorizontalAlignment = HorizontalAlignment.Left };

        var lowDisk = new NumberBox { Header = Localizer.Get("StorageLowDiskSetting"), Minimum = 0, Value = app.LowDiskWarningGB, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, HorizontalAlignment = HorizontalAlignment.Left };
        var autoCleanCaches = new ToggleSwitch { Header = Localizer.Get("StorageAutoCleanSetting"), IsOn = app.AutoCleanCaches };

        // settings.json's list, when set, replaces the stored roots and is edited there.
        var managedRoots = app.TrustedDirectories;
        var storedRoots = ProgramaConfig.StoredRoots();
        var trustedDirectories = new TextBox
        {
            Header = Localizer.Get("TrustedDirectories"), Description = Localizer.Get(managedRoots is null ? "TrustedDirectoriesSubtitle" : "TrustedDirectoriesManaged"),
            Text = string.Join("\r", managedRoots ?? storedRoots), AcceptsReturn = true, IsReadOnly = managedRoots is not null, MinHeight = 120,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"),
        };
        var trustNote = new TextBlock { Text = Localizer.Get("TrustedDirectoriesNote"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
        var showUsage = new ToggleSwitch { Header = Localizer.Get("ShowProviderUsage"), IsOn = app.ShowProviderUsage };
        var showUsageNote = new TextBlock { Text = Localizer.Get("ShowProviderUsageSubtitle"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7, Margin = new Thickness(0, -12, 0, 0) };
        var shortcutPanel = new StackPanel { Spacing = 8 };
        shortcutPanel.Children.Add(new TextBlock { Text = Localizer.Get("ShortcutRecordHint"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
        var editors = new Dictionary<string, Button>(StringComparer.Ordinal);
        foreach (var pair in _shortcuts.Values) shortcutPanel.Children.Add(ShortcutRecorder(pair.Key, pair.Value, editors));

        // Sections down the left, as the macOS Settings sidebar: a row of tabs does not fit them all.
        var bar = new ListView { SelectionMode = ListViewSelectionMode.Single, Width = 190 };
        var page = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        bar.Items.Add(Section("SettingsGeneral", appearance, warn, placement, confirmLastTab, paletteAll, autoResume, reapLeftovers, saveScrollback, settingsFile, resetAll));
        bar.Items.Add(Section("Terminal", themeLight, themeDark, fontFamily, fontSize));
        bar.Items.Add(Section("SettingsSidebar", showUsage, showUsageNote));
        bar.Items.Add(Section("Notifications", soundRow, notifications));
        bar.Items.Add(Section("SettingsWorktrees", worktreeFolder, autoRemove, autoRemoveHours));
        bar.Items.Add(Section("StorageTitle", lowDisk, autoCleanCaches));
        bar.Items.Add(Section("SettingsCustomCommands", trustedDirectories, trustNote));
        bar.Items.Add(Section("SettingsAutomation", socketMode, socketModeNote, passwordRow, claudeIntegration, claudeTeams, holdText, protectPrompts, newTerminalsNote, screenDetection, screenDetectionNote));
        bar.Items.Add(Section("SettingsShortcuts", shortcutPanel));
        bar.SelectionChanged += (_, _) => page.Content = (bar.SelectedItem as ListViewItem)?.Tag;
        var first = (ListViewItem)(target == "keyboardShortcuts" ? bar.Items[^1] : bar.Items[0]);
        bar.SelectedItem = first;
        page.Content = first.Tag;
        var sections = new Grid { ColumnSpacing = 12, ColumnDefinitions = { new() { Width = GridLength.Auto }, new() { Width = new GridLength(1, GridUnitType.Star) } } };
        Grid.SetColumn(page, 1);
        sections.Children.Add(bar);
        sections.Children.Add(page);
        var content = new StackPanel { Spacing = 8, MinWidth = 680, Children = { sections } };
        // As the macOS banner: what in settings.json is not applied.
        if (SettingsFileProblems() is { Length: > 0 } problems)
            content.Children.Insert(0, new InfoBar { Severity = InfoBarSeverity.Warning, Title = Localizer.Get("SettingsFileProblems"), Message = problems, IsOpen = true, IsClosable = false });
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme, Title = Localizer.Get("Settings"), Content = content, PrimaryButtonText = Localizer.Get("Save"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        dialog.Resources["ContentDialogMaxWidth"] = 720.0;
        settingsDialog = dialog;
        ContentDialogResult result;
        _dialogOpen = true;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        if (result != ContentDialogResult.Primary) return;

        try
        {
            var shortcuts = ShortcutSettings.Create(editors.ToDictionary(pair => pair.Key, pair => (string)pair.Value.Tag, StringComparer.Ordinal));
            var changes = new List<(string, string, JsonNode?)>();
            var chosenAppearance = appearanceValues[Math.Max(0, appearance.SelectedIndex)];
            if (chosenAppearance != app.Appearance) changes.Add(("app", "appearance", chosenAppearance));
            if (warn.IsOn != app.WarnBeforeQuit) changes.Add(("app", "warnBeforeQuit", warn.IsOn));
            var chosenPlacement = placementValues[Math.Max(0, placement.SelectedIndex)];
            if (chosenPlacement != app.NewWorkspacePlacement) changes.Add(("app", "newWorkspacePlacement", chosenPlacement));
            if (confirmLastTab.IsOn != app.ConfirmCloseLastPane) changes.Add(("app", "confirmCloseLastPane", confirmLastTab.IsOn));
            if (paletteAll.IsOn != app.CommandPaletteSearchesAllSurfaces) changes.Add(("app", "commandPaletteSearchesAllSurfaces", paletteAll.IsOn));
            if (autoResume.IsOn != app.AutoResumeAgents) changes.Add(("app", "autoResumeAgents", autoResume.IsOn));
            if (reapLeftovers.IsOn != app.ReapLeftoverAgentProcesses) changes.Add(("app", "reapLeftoverAgentProcesses", reapLeftovers.IsOn));
            if (saveScrollback.IsOn != app.SaveScrollbackOnQuit) changes.Add(("app", "saveScrollbackOnQuit", saveScrollback.IsOn));
            if (screenDetection.IsOn != app.AgentScreenDetection) changes.Add(("automation", "agentScreenDetection", screenDetection.IsOn));
            if (claudeIntegration.IsOn != app.ClaudeCodeIntegration) changes.Add(("automation", "claudeCodeIntegration", claudeIntegration.IsOn));
            if (claudeTeams.IsOn != app.ClaudeTeamsByDefault) changes.Add(("automation", "claudeTeamsByDefault", claudeTeams.IsOn));
            if (holdText.IsOn != app.HoldAgentTextWhileTyping) changes.Add(("automation", "holdAgentTextWhileTyping", holdText.IsOn));
            if (protectPrompts.IsOn != app.ProtectApprovalPrompts) changes.Add(("automation", "protectApprovalPrompts", protectPrompts.IsOn));
            var chosenMode = socketModes[Math.Max(0, socketMode.SelectedIndex)];
            if (chosenMode != app.SocketControlMode) changes.Add(("automation", "socketControlMode", chosenMode));
            if (socketPassword.Password.Length > 0) changes.Add(("automation", "socketPassword", socketPassword.Password));
            else if (passwordCleared) changes.Add(("automation", "socketPassword", null));
            var (light, dark) = (Value(themeLight), Value(themeDark));
            var themeChanged = light != app.ThemeLight || dark != app.ThemeDark;
            if (themeChanged)
                changes.Add(("app", "terminalTheme", light is null && dark is null ? null : new JsonObject { ["light"] = light, ["dark"] = dark }));
            var family = Value(fontFamily);
            var size = double.IsNaN(fontSize.Value) ? (double?)null : Math.Clamp(fontSize.Value, 6, 72);
            // A size left as it was stays unset, so the Ghostty config keeps deciding it.
            var sizeChanged = size is { } chosen && chosen != (app.FontSize ?? effectiveSize);
            var fontChanged = family != app.FontFamily || sizeChanged;
            if (fontChanged)
            {
                var font = new JsonObject();
                if (family is not null) font["family"] = family;
                if ((sizeChanged ? size : app.FontSize) is { } points) font["size"] = points;
                changes.Add(("app", "terminalFont", font.Count == 0 ? null : font));
            }
            // An untouched picker keeps the file's macOS name, even one that shares its Windows sound with others.
            if (sound.SelectedIndex != initialSound && sound.SelectedIndex >= 0)
                changes.Add(("notifications", "sound", soundEvents[sound.SelectedIndex] is { } chosenSound ? AppSettings.WindowsSounds.First(item => item.Event == chosenSound).Value : "none"));
            if (showUsage.IsOn != app.ShowProviderUsage) changes.Add(("sidebarAppearance", "showClaudeQuota", showUsage.IsOn));
            if (Blank(worktreeFolder.Text) is { } folder && !Worktrees.SamePath(folder, worktrees.Directory)) changes.Add(("worktrees", "directory", folder));
            if (autoRemove.IsOn != worktrees.AutoRemoveMerged) changes.Add(("worktrees", "autoRemoveMerged", autoRemove.IsOn));
            if (!double.IsNaN(autoRemoveHours.Value) && autoRemoveHours.Value != worktrees.AutoRemoveAfterHours) changes.Add(("worktrees", "autoRemoveAfterHours", Math.Max(1, autoRemoveHours.Value)));
            if (!double.IsNaN(lowDisk.Value) && Math.Max(0, lowDisk.Value) != app.LowDiskWarningGB) changes.Add(("storage", "lowDiskWarningGB", Math.Max(0, lowDisk.Value)));
            if (autoCleanCaches.IsOn != app.AutoCleanCaches) changes.Add(("storage", "autoCleanCaches", autoCleanCaches.IsOn));
            if (changes.Count > 0) ShortcutSettings.SetValues(changes);
            var roots = trustedDirectories.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (managedRoots is null && !roots.SequenceEqual(storedRoots, StringComparer.OrdinalIgnoreCase)) ProgramaConfig.ReplaceRoots(roots);
            // Unchanged shortcuts are not written, so the file holds only what was chosen.
            if (shortcuts.Values.Any(pair => _shortcuts.Values.GetValueOrDefault(pair.Key) != pair.Value)) shortcuts.Save();
            WindowRegistry.ApplySettings();
        }
        catch (Exception error) { await ShowErrorAsync(Localizer.Get("SettingsError"), error.Message); }
    }

    /// <summary>Applies settings.json to this window: appearance, shortcuts, and every terminal's
    /// theme and font (keeping each terminal's own zoom).</summary>
    internal void ApplySettings()
    {
        ApplyAppearance();
        // A half-saved or mistyped file keeps the shortcuts in use, as macOS keeps its last good load.
        try { _shortcuts = ShortcutSettings.Load(); }
        catch (Exception error) { LaunchLog.Write($"settings: kept the current shortcuts: {error.Message}"); }
        foreach (var terminal in _terminals.Values) terminal.ReloadAppearance();
        var settings = AppSettings.Load();
        _screenDetection = settings.AgentScreenDetection;
        // The footer is rebuilt with the sidebar.
        var showUsage = settings.ShowProviderUsage;
        if (showUsage != _showProviderUsage)
        {
            _showProviderUsage = showUsage;
            ProjectSnapshot();
        }
    }

    /// <summary>app.appearance: the window's light or dark mode, or Windows' app mode for "system".</summary>
    private void ApplyAppearance()
    {
        var theme = AppSettings.Load().Theme;
        Root.RequestedTheme = theme;
        AppWindow.TitleBar.PreferredTheme = theme switch
        {
            ElementTheme.Light => Microsoft.UI.Windowing.TitleBarTheme.Light,
            ElementTheme.Dark => Microsoft.UI.Windowing.TitleBarTheme.Dark,
            _ => Microsoft.UI.Windowing.TitleBarTheme.UseDefaultAppMode,
        };
    }

    /// <summary>What Reset All Settings removes from settings.json: every key the Settings window writes, as macOS's
    /// reset puts each row back to its default. Trusted folders, the socket password and the apps allowed to open
    /// links stay, as they do on macOS.</summary>
    internal static readonly (string Section, string Key)[] ResetKeys =
    [
        ("app", "appearance"), ("app", "warnBeforeQuit"), ("app", "newWorkspacePlacement"), ("app", "confirmCloseLastPane"),
        ("app", "commandPaletteSearchesAllSurfaces"), ("app", "autoResumeAgents"), ("app", "reapLeftoverAgentProcesses"), ("app", "saveScrollbackOnQuit"),
        ("app", "terminalTheme"), ("app", "terminalFont"), ("notifications", "sound"), ("sidebarAppearance", "showClaudeQuota"),
        ("worktrees", "directory"), ("worktrees", "autoRemoveMerged"), ("worktrees", "autoRemoveAfterHours"),
        ("storage", "lowDiskWarningGB"), ("storage", "autoCleanCaches"),
        ("automation", "socketControlMode"), ("automation", "claudeCodeIntegration"), ("automation", "claudeTeamsByDefault"),
        ("automation", "holdAgentTextWhileTyping"), ("automation", "protectApprovalPrompts"), ("automation", "agentScreenDetection"), ("windows", "shortcuts"),
    ];

    /// <summary>One Keyboard Shortcuts row, as the macOS recorder: click the binding, then press the keys. Escape keeps
    /// the old binding, Backspace or Delete removes it, and a binding that is reserved or already taken is refused on
    /// the spot. The binding lives in the button's Tag.</summary>
    private static Grid ShortcutRecorder(string action, string binding, Dictionary<string, Button> editors)
    {
        var label = Localizer.Get($"Shortcut_{action}");
        var button = new Button { Tag = binding, MinWidth = 160, HorizontalAlignment = HorizontalAlignment.Right };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.IndianRed) };
        var recording = false;
        void Show(string? text = null)
        {
            var value = (string)button.Tag;
            button.Content = text ?? (value.Length == 0 ? Localizer.Get("ShortcutNone") : ShortcutSettings.Display(value));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, $"{label}: {button.Content}");
        }
        void Stop() { recording = false; Show(); }
        button.Click += (_, _) =>
        {
            if (recording) { Stop(); return; }
            recording = true;
            error.Visibility = Visibility.Collapsed;
            Show(Localizer.Get("ShortcutPress"));
        };
        button.LostFocus += (_, _) => { if (recording) Stop(); };
        button.PreviewKeyDown += (_, args) =>
        {
            if (!recording) return;
            args.Handled = true;
            if (args.Key == Windows.System.VirtualKey.Escape) { Stop(); return; }
            var pressed = args.Key is Windows.System.VirtualKey.Back or Windows.System.VirtualKey.Delete ? "" : ShortcutSettings.BindingFor(args.Key);
            if (pressed is null) return;
            var values = editors.ToDictionary(pair => pair.Key, pair => pair.Key == action ? pressed : (string)pair.Value.Tag, StringComparer.Ordinal);
            var taken = pressed.Length == 0 ? null : editors.Keys.FirstOrDefault(other => other != action && string.Equals((string)editors[other].Tag, pressed, StringComparison.OrdinalIgnoreCase));
            try
            {
                if (taken is not null) throw new InvalidDataException(string.Format(Localizer.Get("ShortcutTakenBy"), ShortcutSettings.Display(pressed), Localizer.Get($"Shortcut_{taken}")));
                ShortcutSettings.Validate(values);
                button.Tag = pressed;
            }
            catch (InvalidDataException refused)
            {
                // Validate's own messages are not localized; anything but a duplicate is a binding the terminal keeps.
                error.Text = taken is not null ? refused.Message : string.Format(Localizer.Get("ShortcutReserved"), ShortcutSettings.Display(pressed));
                error.Visibility = Visibility.Visible;
            }
            Stop();
        };
        Show();
        editors[action] = button;
        var row = new Grid { ColumnSpacing = 12, ColumnDefinitions = { new() { Width = new GridLength(1, GridUnitType.Star) }, new() { Width = GridLength.Auto } } };
        var name = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(button, 1);
        Grid.SetRow(error, 1);
        Grid.SetColumnSpan(error, 2);
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.Children.Add(name);
        row.Children.Add(button);
        row.Children.Add(error);
        return row;
    }

    /// <summary>A switch whose on and off text say what each means, as the macOS subtitles.</summary>
    private static ToggleSwitch Switch(string key, bool on) => new()
    {
        Header = Localizer.Get(key),
        IsOn = on,
        OnContent = new TextBlock { Text = Localizer.Get(key + "On"), TextWrapping = TextWrapping.Wrap, MaxWidth = 440 },
        OffContent = new TextBlock { Text = Localizer.Get(key + "Off"), TextWrapping = TextWrapping.Wrap, MaxWidth = 440 },
    };

    /// <summary>settings.json in the default editor (Notepad when .json has none), created empty when missing.</summary>
    private static void OpenSettingsFile()
    {
        var path = ShortcutSettings.SettingsPath;
        try
        {
            if (!File.Exists(path))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, "{\n}\n");
            }
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true })?.Dispose(); }
            catch (System.ComponentModel.Win32Exception) { System.Diagnostics.Process.Start("notepad.exe", $"\"{path}\"")?.Dispose(); }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            LaunchLog.Write($"settings: could not open {path}: {error.Message}");
        }
    }

    /// <summary>The first problems `programa config check` would report, one per line, or null.</summary>
    private static string? SettingsFileProblems()
    {
        try
        {
            if (!File.Exists(ShortcutSettings.SettingsPath)) return null;
            var problems = SettingsCheck.Problems(File.ReadAllBytes(ShortcutSettings.SettingsPath));
            return problems.Count == 0 ? null : string.Join("\n", problems.Take(3).Select(problem => problem.Format(Path.GetFileName(ShortcutSettings.SettingsPath))));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>A section in the list; its page is kept in Tag.</summary>
    private static ListViewItem Section(string titleKey, params UIElement[] controls)
    {
        var panel = new StackPanel { Spacing = 16, Padding = new Thickness(4, 8, 16, 8) };
        foreach (var control in controls) panel.Children.Add(control);
        return new ListViewItem { Content = Localizer.Get(titleKey), Tag = new ScrollViewer { Content = panel, Height = 420 } };
    }

    /// <summary>A combo box that also takes a typed value; empty means "from the Ghostty config".
    /// The value lives in Tag: Text is empty until the box is first shown, and a tab never opened
    /// must save what it was given.</summary>
    private static ComboBox EditableBox(string header, List<string> items, string? value)
    {
        var box = new ComboBox { Header = header, IsEditable = true, ItemsSource = items, PlaceholderText = Localizer.Get("FromGhosttyConfig"), MinWidth = 320, Tag = value };
        box.SelectedItem = items.FirstOrDefault(item => string.Equals(item, value, StringComparison.OrdinalIgnoreCase));
        box.Loaded += (_, _) => box.Text = box.Tag as string ?? string.Empty;
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is string chosen) box.Tag = chosen; };
        box.TextSubmitted += (_, args) => box.Tag = Blank(args.Text);
        return box;
    }

    private static string? Value(ComboBox box) => Blank(box.Tag as string);

    private static string? Blank(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();

    /// <summary>Theme names from the Ghostty themes folder and the themes bundled with the app.</summary>
    private static List<string> ThemeNames()
    {
        var configHome = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") is { Length: > 0 } xdg
            ? xdg
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        return new[] { Path.Combine(configHome, "ghostty", "themes"), Path.Combine(AppContext.BaseDirectory, "themes") }
            .Where(Directory.Exists)
            .SelectMany(Directory.EnumerateFiles)
            .Select(Path.GetFileName)
            .OfType<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }
}
