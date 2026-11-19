using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace Programa;

/// <summary>The sidebar's helpers line and popover, as on macOS (docs/workspace-interface.md#helpers-popover):
/// "N helpers running" or "N helpers finished" under a workspace's status; the popover lists running
/// helpers, then finished ones newest first, each with its state, task, role and how long it ran, and
/// opens a helper's final report (Copy, Open Report). It refreshes once a second while open.</summary>
public sealed partial class MainWindow
{
    private string? _helpersWorkspace;
    private StackPanel? _helpersBody;
    private string? _expandedHelper;
    private string _helpersShown = string.Empty;
    private readonly List<(TextBlock Text, Helper Helper)> _helperDurations = [];

    internal bool WorkspaceHasSurface(string workspaceId, string surfaceId) =>
        _snapshot.Workspaces.Any(workspace => workspace.Id == workspaceId && workspace.Panes.Any(pane => pane.Surfaces.Any(surface => surface.Id == surfaceId)));

    internal void OnHelpersChanged(string workspaceId)
    {
        UpdateSidebarRow(workspaceId);
        if (_helpersWorkspace == workspaceId) RenderHelpers();
    }

    private HyperlinkButton HelpersLine(string workspaceId)
    {
        var line = new HyperlinkButton { Content = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis }, Padding = new Thickness(0), Margin = new Thickness(0, 2, 0, 0), Visibility = Visibility.Collapsed };
        ToolTipService.SetToolTip(line, Localizer.Get("HelpersShow"));
        line.Click += (_, _) => ShowHelpersPopover(workspaceId, line);
        return line;
    }

    private static void UpdateHelpersLine(string workspaceId, HyperlinkButton line)
    {
        var helpers = Helpers.Of(workspaceId);
        var running = helpers.Count(helper => !helper.Finished);
        var finished = helpers.Count - running;
        line.Visibility = helpers.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        var text = running > 0
            ? running == 1 ? Localizer.Get("HelpersOneRunning") : string.Format(Localizer.Get("HelpersRunning"), running)
            : finished == 1 ? Localizer.Get("HelpersOneFinished") : string.Format(Localizer.Get("HelpersFinished"), finished);
        ((TextBlock)line.Content).Text = text;
        AutomationProperties.SetName(line, text);
    }

    private void ShowHelpersPopover(string workspaceId, FrameworkElement anchor)
    {
        if (anchor.XamlRoot is null) return;
        _helpersWorkspace = workspaceId;
        _expandedHelper = null;
        _helpersShown = string.Empty;
        _helpersBody = new StackPanel { Spacing = 2, Width = 360 };
        var flyout = new Flyout { Content = new ScrollViewer { Content = _helpersBody, MaxHeight = 460, IsTabStop = true, UseSystemFocusVisuals = false } };
        var tick = DispatcherQueue.CreateTimer();
        tick.Interval = TimeSpan.FromSeconds(1);
        tick.Tick += (_, _) => RenderHelpers();
        flyout.Closed += (_, _) => { tick.Stop(); _helpersWorkspace = null; _helpersBody = null; };
        RenderHelpers();
        // The sidebar is rebuilt on every projection, so the flyout hangs on the root at the line's place.
        var at = anchor.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point(anchor.ActualWidth, 0));
        _footerFlyoutOpen = true;
        flyout.Closed += (_, _) => _footerFlyoutOpen = false;
        flyout.ShowAt(Root, new FlyoutShowOptions { Position = at, Placement = FlyoutPlacementMode.RightEdgeAlignedTop });
        tick.Start();
    }

    /// <summary>Rebuilds the rows when a helper came, went or changed; otherwise only the running times move.</summary>
    private void RenderHelpers()
    {
        if (_helpersBody is not { } body || _helpersWorkspace is not { } workspaceId) return;
        var helpers = Helpers.Of(workspaceId);
        var running = helpers.Where(helper => !helper.Finished).OrderBy(helper => helper.StartedAt).ToList();
        var finished = helpers.Where(helper => helper.Finished).OrderByDescending(helper => helper.EndedAt).ToList();
        if (_expandedHelper is not null && helpers.All(helper => helper.Id != _expandedHelper)) _expandedHelper = null;
        var shown = string.Join('|', running.Concat(finished).Select(helper => $"{helper.Id}:{helper.State}:{helper.Task}:{helper.Role}:{helper.Summary?.Length}")) + "|" + _expandedHelper;
        var now = DateTimeOffset.UtcNow;
        if (shown == _helpersShown)
        {
            foreach (var (text, helper) in _helperDurations) text.Text = HelperDuration((helper.EndedAt ?? now) - helper.StartedAt);
            return;
        }
        _helpersShown = shown;
        _helperDurations.Clear();
        body.Children.Clear();
        if (helpers.Count == 0)
        {
            body.Children.Add(new TextBlock { Text = Localizer.Get("HelpersEmpty"), Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20) });
            return;
        }
        foreach (var helper in running) body.Children.Add(HelperRow(helper, now));
        if (finished.Count > 0)
        {
            var header = new Grid { Margin = new Thickness(8, running.Count == 0 ? 4 : 10, 8, 2) };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.Children.Add(new TextBlock { Text = Localizer.Get("HelpersFinishedHeader"), FontSize = 12, FontWeight = FontWeights.SemiBold, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
            var clear = new Button { Content = Localizer.Get("HelpersClear"), Padding = new Thickness(8, 2, 8, 2), FontSize = 12 };
            ToolTipService.SetToolTip(clear, Localizer.Get("HelpersClearHelp"));
            clear.Click += (_, _) => Helpers.ClearFinished(workspaceId);
            Grid.SetColumn(clear, 1);
            header.Children.Add(clear);
            body.Children.Add(header);
            foreach (var helper in finished) body.Children.Add(HelperRow(helper, now));
        }
    }

    private FrameworkElement HelperRow(Helper helper, DateTimeOffset now)
    {
        var expanded = _expandedHelper == helper.Id;
        var title = new[] { helper.Task, helper.Role }.Select(text => text?.Trim()).FirstOrDefault(text => !string.IsNullOrEmpty(text)) ?? Localizer.Get("Helper");
        var role = helper.Role is { } kind && kind.Trim() != title ? kind : null;
        var (glyph, brush, stateKey) = helper.State switch
        {
            "idle" => (0xEA3A, ThemeBrush("TextFillColorSecondaryBrush"), "HelperIdle"),
            "working" => (0xEA3B, ThemeBrush("AccentTextFillColorPrimaryBrush"), "HelperWorking"),
            "blocked" => (0xE7BA, new SolidColorBrush(Colors.Orange), "HelperNeedsInput"),
            "completed" => (0xE73E, ThemeBrush("SystemFillColorSuccessBrush"), "HelperDone"),
            "cancelled" => (0xE71A, ThemeBrush("TextFillColorSecondaryBrush"), "HelperStopped"),
            _ => (0xEB90, ThemeBrush("SystemFillColorCriticalBrush"), "HelperFailed"),
        };
        var line = new Grid { ColumnSpacing = 8 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new FontIcon { Glyph = ((char)glyph).ToString(), FontSize = 14, Foreground = brush, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
        ToolTipService.SetToolTip(icon, Localizer.Get(stateKey));
        line.Children.Add(icon);
        var names = new StackPanel { Spacing = 1 };
        names.Children.Add(new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = expanded ? TextWrapping.Wrap : TextWrapping.NoWrap, MaxLines = expanded ? 3 : 1 });
        if (role is not null) names.Children.Add(new TextBlock { Text = role, FontSize = 12, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(names, 1);
        line.Children.Add(names);
        var duration = new TextBlock { Text = HelperDuration((helper.EndedAt ?? now) - helper.StartedAt), FontSize = 12, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Top, FontFamily = new FontFamily("Segoe UI Variable Text") };
        _helperDurations.Add((duration, helper));
        Grid.SetColumn(duration, 2);
        line.Children.Add(duration);

        var toggle = new Button { Content = line, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(8, 6, 8, 6) };
        AutomationProperties.SetName(toggle, $"{title}, {Localizer.Get(stateKey)}");
        AutomationProperties.SetHelpText(toggle, Localizer.Get("HelpersToggleHint"));
        toggle.Click += (_, _) =>
        {
            _expandedHelper = expanded ? null : helper.Id;
            RenderHelpers();
        };
        var row = new StackPanel { Spacing = 6 };
        row.Children.Add(toggle);
        if (expanded) row.Children.Add(HelperReport(helper, title));
        return row;
    }

    /// <summary>The report's first 8 lines (headings as bold-less lines), with Copy and Open Report.</summary>
    private FrameworkElement HelperReport(Helper helper, string title)
    {
        var report = new StackPanel { Spacing = 6, Margin = new Thickness(30, 0, 8, 8) };
        if (string.IsNullOrEmpty(helper.Summary))
        {
            report.Children.Add(new TextBlock { Text = Localizer.Get(helper.Finished ? "HelpersReportNone" : "HelpersReportPending"), FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
            return report;
        }
        var summary = helper.Summary;
        var preview = string.Join('\n', Regex.Replace(summary, @"(?m)^#{1,6}[ \t]+(.+?)[ \t#]*$", "$1").Split('\n').Take(8));
        report.Children.Add(new TextBlock { Text = preview, FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxLines = 8, IsTextSelectionEnabled = true });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var copy = new Button { Content = Localizer.Get("HelpersCopy"), FontSize = 12 };
        copy.Click += (_, _) =>
        {
            var data = new Windows.ApplicationModel.DataTransfer.DataPackage();
            data.SetText(summary);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data);
        };
        var open = new Button { Content = Localizer.Get("HelpersOpenReport"), FontSize = 12 };
        open.Click += (_, _) => OpenHelperReport(helper, title, summary);
        buttons.Children.Add(copy);
        buttons.Children.Add(open);
        report.Children.Add(buttons);
        return report;
    }

    /// <summary>Writes the report to a temporary file and opens it in a markdown pane beside the
    /// workspace's focused pane, which titles itself after the file.</summary>
    private void OpenHelperReport(Helper helper, string title, string summary)
    {
        if (_snapshot.Workspaces.FirstOrDefault(workspace => workspace.Id == helper.WorkspaceId)?.SelectedPane?.SelectedSurfaceId is not { } surfaceId) return;
        try
        {
            var directory = Path.Combine(Path.GetTempPath(), "programa-helper-reports", helper.Id);
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, ReportFileName(title, Localizer.Get("HelperReportFileName")));
            File.WriteAllText(path, summary);
            SplitPanel(JsonSerializer.SerializeToElement(new { surface_id = surfaceId }), new MarkdownPanel(path), focus: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ControlException)
        {
            _ = ShowErrorAsync(Localizer.Get("HelpersOpenReport"), error.Message);
        }
    }

    /// <summary>The title's first 8 words of letters, digits, spaces and dashes, as a .md name.</summary>
    internal static string ReportFileName(string title, string fallback)
    {
        var cleaned = new string(title.Select(character => char.IsLetterOrDigit(character) || character is ' ' or '-' ? character : ' ').ToArray());
        var words = string.Join(' ', cleaned.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(8));
        return (words.Length == 0 ? fallback : words) + ".md";
    }

    /// <summary>At most two units, as macOS's abbreviated DateComponentsFormatter: 1h 5m, 3m 20s, 45s.</summary>
    internal static string HelperDuration(TimeSpan elapsed)
    {
        var total = Math.Max(0, (long)elapsed.TotalSeconds);
        var (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60);
        return hours > 0
            ? minutes > 0 ? string.Format(Localizer.Get("HelperHoursMinutes"), hours, minutes) : string.Format(Localizer.Get("HelperHours"), hours)
            : minutes > 0
                ? seconds > 0 ? string.Format(Localizer.Get("HelperMinutesSeconds"), minutes, seconds) : string.Format(Localizer.Get("HelperMinutes"), minutes)
                : string.Format(Localizer.Get("HelperSeconds"), seconds);
    }
}
