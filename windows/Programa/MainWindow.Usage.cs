using System.Globalization;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Programa;

/// <summary>The sidebar footer's Provider Usage button, as on macOS: a panel with how much of the Claude and
/// OpenAI rate limits is left, read each time it opens ("Loading usage…" until the first answer).</summary>
public sealed partial class MainWindow
{
    /// <summary>The last answer, shown while a new read runs; account-wide, so every window shares it.</summary>
    private static List<UsageResult>? s_usageResults;

    private bool _showProviderUsage = AppSettings.Load().ShowProviderUsage;
    private AppBarButton? _usageButton;
    private StackPanel? _usageBody;
    private CancellationTokenSource? _usageRefresh;

    private AppBarButton UsageButton()
    {
        var label = Localizer.Get("UsageButton");
        _usageButton = new AppBarButton { Icon = new FontIcon { Glyph = ((char)0xEC4A).ToString() }, LabelPosition = CommandBarLabelPosition.Collapsed, Width = 44, MinHeight = 44 };
        AutomationProperties.SetName(_usageButton, label);
        ToolTipService.SetToolTip(_usageButton, label);
        _usageButton.Click += (_, _) => ShowUsagePanel();
        return _usageButton;
    }

    private void ShowUsagePanel()
    {
        if (_usageButton?.XamlRoot is null) return;
        _usageBody = new StackPanel { Spacing = 12, Width = 280 };
        var flyout = new Flyout { Content = new ScrollViewer { Content = _usageBody, MaxHeight = 480 } };
        // Closing stops a read still running, as on macOS.
        flyout.Closed += (_, _) => { _usageRefresh?.Cancel(); _usageBody = null; };
        RenderUsage(refreshing: true);
        ShowFooterFlyout(flyout, _usageButton);
        _ = RefreshUsageAsync();
    }

    private async Task RefreshUsageAsync()
    {
        _usageRefresh?.Cancel();
        var refresh = _usageRefresh = new CancellationTokenSource();
        try
        {
            var results = await ProviderUsage.FetchAllAsync(refresh.Token);
            if (refresh.IsCancellationRequested) return;
            s_usageResults = results;
        }
        catch (OperationCanceledException) { return; }
        if (_usageRefresh == refresh) RenderUsage(refreshing: false);
    }

    private void RenderUsage(bool refreshing)
    {
        if (_usageBody is not { } body) return;
        body.Children.Clear();
        if (s_usageResults is not { } results)
        {
            var loading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center, MinHeight = 80 };
            loading.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center });
            loading.Children.Add(Secondary(Localizer.Get("UsageLoading"), 12, VerticalAlignment.Center));
            body.Children.Add(loading);
            return;
        }
        if (refreshing)
        {
            var ring = new ProgressRing { IsActive = true, Width = 12, Height = 12, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 0, -12) };
            AutomationProperties.SetName(ring, Localizer.Get("UsageRefreshing"));
            body.Children.Add(ring);
        }
        var available = results.Where(result => result.State == "available").ToList();
        var failed = results.Where(result => result.State == "failed").ToList();
        if (available.Count == 0 && failed.Count == 0)
        {
            var empty = new StackPanel { Spacing = 4 };
            empty.Children.Add(new TextBlock { Text = Localizer.Get("UsageEmptyTitle"), FontSize = 12, FontWeight = FontWeights.SemiBold });
            empty.Children.Add(Secondary(Localizer.Get("UsageEmptySubtitle"), 11));
            body.Children.Add(empty);
        }
        foreach (var result in available)
        {
            if (result != available[0]) body.Children.Add(new Border { Height = 1, Background = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"] });
            var section = new StackPanel { Spacing = 8 };
            var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            header.Children.Add(new TextBlock { Text = ProviderName(result.Provider), FontSize = 12, FontWeight = FontWeights.SemiBold });
            if (SummaryText(result.Summary) is { } summary) header.Children.Add(Secondary(summary, 10, VerticalAlignment.Bottom));
            section.Children.Add(header);
            foreach (var window in result.Windows) section.Children.Add(UsageRow(window));
            body.Children.Add(section);
        }
        foreach (var result in failed)
        {
            var section = new StackPanel { Spacing = 4 };
            section.Children.Add(new TextBlock { Text = ProviderName(result.Provider), FontSize = 12, FontWeight = FontWeights.SemiBold });
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            line.Children.Add(new FontIcon { Glyph = ((char)0xE7BA).ToString(), FontSize = 12 });
            line.Children.Add(new TextBlock { Text = Localizer.Get(result.Error switch
            {
                "claudeInvalid" => "UsageErrorClaudeInvalid",
                "claudeRead" => "UsageErrorClaudeRead",
                "codexInvalid" => "UsageErrorCodexInvalid",
                _ => "UsageErrorCodexRead",
            }), FontSize = 11, TextWrapping = TextWrapping.Wrap });
            section.Children.Add(line);
            body.Children.Add(section);
        }
    }

    /// <summary>The window's name and what is left, a bar of the rest (orange from 60% used, red from 85%), and the reset.</summary>
    private static FrameworkElement UsageRow(UsageWindow window)
    {
        var label = window.Kind switch
        {
            "session" => Localizer.Get("UsageCurrentSession"),
            "window" => Localizer.Get("UsageCurrentWindow"),
            "weekly" => Localizer.Get("UsageWeekly"),
            _ => string.Format(Localizer.Get(window.Minutes % 1_440 == 0 ? "UsageDurationDays" : window.Minutes % 60 == 0 ? "UsageDurationHours" : "UsageDurationMinutes"),
                window.Minutes % 1_440 == 0 ? window.Minutes / 1_440 : window.Minutes % 60 == 0 ? window.Minutes / 60 : window.Minutes),
        };
        var left = string.Format(Localizer.Get("UsageLeft"), 100 - window.UsedPercent);
        var remaining = window.ResetsAt - DateTimeOffset.UtcNow;
        var reset = remaining <= TimeSpan.Zero
            ? Localizer.Get("UsageResetsNow")
            : string.Format(Localizer.Get("UsageResetsIn"), remaining.TotalMinutes < 60
                ? string.Format(Localizer.Get("UsageResetMinutes"), Math.Max(1, (int)remaining.TotalMinutes))
                : remaining.TotalHours < 24
                    ? string.Format(Localizer.Get("UsageResetHours"), (int)remaining.TotalHours)
                    : string.Format(Localizer.Get("UsageResetDays"), (int)remaining.TotalHours / 24));

        var row = new StackPanel { Spacing = 5 };
        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(new TextBlock { Text = label, FontSize = 11, FontWeight = FontWeights.Medium, TextTrimming = TextTrimming.CharacterEllipsis });
        var percent = new TextBlock { Text = left, FontSize = 10, FontWeight = FontWeights.Medium, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
        Grid.SetColumn(percent, 1);
        top.Children.Add(percent);
        row.Children.Add(top);
        row.Children.Add(new ProgressBar
        {
            Minimum = 0, Maximum = 100, Value = 100 - window.UsedPercent, Height = 4, MinHeight = 4,
            Foreground = window.UsedPercent switch
            {
                < 60 => (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                < 85 => new SolidColorBrush(Colors.Orange),
                _ => new SolidColorBrush(Colors.Red),
            },
        });
        row.Children.Add(Secondary(reset, 10));
        AutomationProperties.SetName(row, $"{label}, {left}, {reset}");
        return row;
    }

    private static string ProviderName(string provider) => Localizer.Get(provider == "claude" ? "UsageClaude" : "UsageCodex");

    /// <summary>"Pro plan · 12.50 credits · 3 reset credits".</summary>
    private static string? SummaryText(UsageSummary? summary)
    {
        if (summary is null) return null;
        var parts = new List<string>();
        if (summary.Plan is { } plan) parts.Add(string.Format(Localizer.Get("UsagePlan"), CultureInfo.InvariantCulture.TextInfo.ToTitleCase(plan.ToLowerInvariant())));
        if (summary.Unlimited) parts.Add(Localizer.Get("UsageUnlimitedCredits"));
        else if (summary.Balance is { } balance) parts.Add(string.Format(Localizer.Get("UsageCreditBalance"), balance));
        if (summary.ResetCredits is { } count) parts.Add(string.Format(Localizer.Get("UsageResetCredits"), count));
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    private static TextBlock Secondary(string text, double size, VerticalAlignment alignment = VerticalAlignment.Top) => new()
    {
        Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, VerticalAlignment = alignment,
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };
}
