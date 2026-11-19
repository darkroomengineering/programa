using System.Text.Json.Nodes;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>Settings, as the macOS Settings window: General, Terminal, Sidebar, Notifications, Worktrees, Storage,
/// Custom Commands and Keyboard Shortcuts, saved to the shared settings.json (only the values changed here are written)
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

        var themes = ThemeNames();
        var themeLight = EditableBox(Localizer.Get("TerminalThemeLight"), themes, app.ThemeLight);
        var themeDark = EditableBox(Localizer.Get("TerminalThemeDark"), themes, app.ThemeDark);
        var fonts = new[] { TerminalAppearance.BundledFontFamily }.Concat(CanvasTextFormat.GetSystemFontFamilies().Order(StringComparer.OrdinalIgnoreCase)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var fontFamily = EditableBox(Localizer.Get("TerminalFontFamily"), fonts, app.FontFamily);
        var fontSize = new NumberBox { Header = Localizer.Get("TerminalFontSize"), Minimum = 6, Maximum = 72, Value = app.FontSize ?? effectiveSize, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, HorizontalAlignment = HorizontalAlignment.Left };

        var sound = new ToggleSwitch { Header = Localizer.Get("NotificationSound"), IsOn = !app.Silent };

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
        var editors = new Dictionary<string, TextBox>(StringComparer.Ordinal);
        foreach (var pair in _shortcuts.Values)
        {
            var editor = new TextBox { Header = Localizer.Get($"Shortcut_{pair.Key}"), Text = pair.Value };
            editors[pair.Key] = editor;
            shortcutPanel.Children.Add(editor);
        }

        var bar = new SelectorBar();
        var page = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        bar.Items.Add(Section("SettingsGeneral", appearance, warn));
        bar.Items.Add(Section("Terminal", themeLight, themeDark, fontFamily, fontSize));
        bar.Items.Add(Section("SettingsSidebar", showUsage, showUsageNote));
        bar.Items.Add(Section("Notifications", sound));
        bar.Items.Add(Section("SettingsWorktrees", worktreeFolder, autoRemove, autoRemoveHours));
        bar.Items.Add(Section("StorageTitle", lowDisk, autoCleanCaches));
        bar.Items.Add(Section("SettingsCustomCommands", trustedDirectories, trustNote));
        bar.Items.Add(Section("SettingsShortcuts", shortcutPanel));
        bar.SelectionChanged += (sender, _) => page.Content = sender.SelectedItem?.Tag;
        var first = target == "keyboardShortcuts" ? bar.Items[^1] : bar.Items[0];
        bar.SelectedItem = first;
        page.Content = first.Tag;
        var content = new StackPanel { Spacing = 8, MinWidth = 560, Children = { bar, page } };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, RequestedTheme = Root.ActualTheme, Title = Localizer.Get("Settings"), Content = content, PrimaryButtonText = Localizer.Get("Save"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        dialog.Resources["ContentDialogMaxWidth"] = 720.0;
        ContentDialogResult result;
        _dialogOpen = true;
        try { result = await dialog.ShowAsync(); }
        finally { _dialogOpen = false; }
        if (result != ContentDialogResult.Primary) return;

        try
        {
            var shortcuts = ShortcutSettings.Create(editors.ToDictionary(pair => pair.Key, pair => pair.Value.Text, StringComparer.Ordinal));
            var changes = new List<(string, string, JsonNode?)>();
            var chosenAppearance = appearanceValues[Math.Max(0, appearance.SelectedIndex)];
            if (chosenAppearance != app.Appearance) changes.Add(("app", "appearance", chosenAppearance));
            if (warn.IsOn != app.WarnBeforeQuit) changes.Add(("app", "warnBeforeQuit", warn.IsOn));
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
            if (sound.IsOn == app.Silent) changes.Add(("notifications", "sound", sound.IsOn ? "default" : "none"));
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
        // The footer is rebuilt with the sidebar.
        var showUsage = AppSettings.Load().ShowProviderUsage;
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

    /// <summary>A section tab; its page is kept in Tag.</summary>
    private static SelectorBarItem Section(string titleKey, params UIElement[] controls)
    {
        var panel = new StackPanel { Spacing = 16, Padding = new Thickness(4, 8, 16, 8) };
        foreach (var control in controls) panel.Children.Add(control);
        return new SelectorBarItem { Text = Localizer.Get(titleKey), Tag = new ScrollViewer { Content = panel, Height = 420 } };
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
