using System.Text.Json;
using Markdig;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using MarkdownInline = Markdig.Syntax.Inlines.Inline;
using XamlInline = Microsoft.UI.Xaml.Documents.Inline;

namespace Programa;

/// <summary>A sidebar row's metadata, as on macOS (Sources/TabItemView.swift): status entries (three,
/// then Show more), markdown blocks (one, then Show more details), the latest log line and the
/// progress bar, under the agent status and helpers and above the branch.</summary>
public sealed partial class MainWindow
{
    private readonly HashSet<string> _statusExpanded = new(StringComparer.Ordinal);
    private readonly HashSet<string> _blocksExpanded = new(StringComparer.Ordinal);

    // Entries an older CLI sent for the agent state, which the status pill already shows.
    private static readonly string[] AgentStatusKeys = ["claude_code", "codex", "opencode"];
    private static readonly string[] AgentStatusValues = ["Running", "Waiting", "Needs input", "Idle"];

    // SF Symbol names agents send, as Segoe Fluent glyphs; other names show no icon.
    private static readonly Dictionary<string, int> SymbolGlyphs = new(StringComparer.Ordinal)
    {
        ["checkmark"] = 0xE73E, ["xmark"] = 0xE711, ["exclamationmark.triangle"] = 0xE7BA, ["exclamationmark"] = 0xE783,
        ["info"] = 0xE946, ["hammer"] = 0xE90F, ["wrench"] = 0xE90F, ["bolt"] = 0xE945, ["clock"] = 0xE823,
        ["terminal"] = 0xE756, ["gear"] = 0xE713, ["gearshape"] = 0xE713, ["bell"] = 0xEA8F, ["star"] = 0xE734,
        ["doc"] = 0xE8A5, ["folder"] = 0xE8B7, ["globe"] = 0xE774, ["magnifyingglass"] = 0xE721, ["person"] = 0xE77B,
        ["play"] = 0xE768, ["pause"] = 0xE769, ["stop"] = 0xE71A, ["arrow.clockwise"] = 0xE72C, ["ladybug"] = 0xEBE8,
        ["lock"] = 0xE72E, ["network"] = 0xE968, ["sparkles"] = 0xE945, ["cloud"] = 0xE753, ["flag"] = 0xE7C1,
    };

    internal void OnSidebarMetadataChanged(string workspaceId) => UpdateSidebarRow(workspaceId);

    private object SidebarFromControl(string method, JsonElement p)
    {
        var workspace = WorkspaceTarget(p);
        switch (method)
        {
            case "workspace.sidebar_state":
                return SidebarState(workspace);
            case "workspace.reset_sidebar":
                SidebarMetadata.Reset(workspace.Id);
                foreach (var terminal in TerminalsOf(workspace)) terminal.ResetReportedState();
                return new { workspace_id = workspace.Id };
            default:
                return SidebarMetadata.FromControl(method, workspace.Id, p, DateTimeOffset.Now);
        }
    }

    private IEnumerable<TerminalView> TerminalsOf(WorkspaceSnapshot workspace) =>
        workspace.Panes.SelectMany(pane => pane.Surfaces).Select(surface => _terminals.GetValueOrDefault(surface.Id)).OfType<TerminalView>();

    /// <summary>The macOS workspace.sidebar_state payload. Windows does not track a dirty tree or PR checks; those are null.</summary>
    private object SidebarState(WorkspaceSnapshot workspace)
    {
        var metadata = SidebarMetadata.Of(workspace.Id);
        var focusedId = workspace.SelectedPane?.SelectedSurfaceId;
        var focusedCwd = focusedId is null ? null : _terminals.GetValueOrDefault(focusedId)?.WorkingDirectory;
        var branch = focusedId is null ? null : _branches.GetValueOrDefault(focusedId);
        var pullRequest = PullRequestFor(workspace);
        return new
        {
            workspace_id = workspace.Id,
            color = workspace.Color,
            cwd = focusedCwd ?? TerminalsOf(workspace).Select(terminal => terminal.WorkingDirectory).FirstOrDefault(directory => directory is not null)
                ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            focused_cwd = focusedCwd,
            focused_surface_id = focusedId,
            git_branch = branch is null ? null : new { branch, dirty = focusedId is null ? null : (bool?)(_reportedDirty.TryGetValue(focusedId, out var dirty) ? dirty : null) },
            pull_request = pullRequest is null ? null : new { number = pullRequest.Number, label = pullRequest.Label, url = pullRequest.Url, state = pullRequest.State, branch = pullRequest.Branch ?? branch, checks = pullRequest.Checks },
            ports = WorkspacePorts(workspace),
            progress = metadata?.Progress is { } progress ? new { value = progress.Value, label = progress.Label } : null,
            status_entries = metadata?.StatusInOrder().Select(SidebarMetadata.StatusJson).ToList() ?? [],
            metadata_blocks = metadata?.BlocksInOrder().Select(SidebarMetadata.BlockJson).ToList() ?? [],
            log_count = metadata?.Log.Count ?? 0,
            recent_log_entries = metadata?.Log.TakeLast(5).Select(entry => new { message = entry.Message, level = entry.Level, source = entry.Source }).ToList() ?? [],
        };
    }

    /// <summary>Rebuilds a row's metadata lines when the metadata changed since they were drawn. The
    /// latest log line is left out when the status line already shows it (<paramref name="statusShowsLog"/>).</summary>
    private void UpdateMetadataLines(string workspaceId, StackPanel lines, bool statusShowsLog)
    {
        var metadata = SidebarMetadata.Of(workspaceId);
        var stamp = (metadata?.Version ?? 0, statusShowsLog, _statusExpanded.Contains(workspaceId), _blocksExpanded.Contains(workspaceId));
        if (lines.Tag is ValueTuple<int, bool, bool, bool> drawn && drawn == stamp) return;
        lines.Tag = stamp;
        lines.Children.Clear();
        lines.Visibility = Visibility.Collapsed;
        if (metadata is null) return;

        var entries = metadata.StatusInOrder().Where(entry => !(AgentStatusKeys.Contains(entry.Key) && AgentStatusValues.Contains(entry.Value))).ToList();
        var expanded = _statusExpanded.Contains(workspaceId);
        foreach (var entry in expanded ? entries : entries.Take(3)) lines.Children.Add(StatusLine(entry));
        if (entries.Count > 3) lines.Children.Add(Toggle(workspaceId, _statusExpanded, expanded ? "SidebarShowLess" : "SidebarShowMore"));

        var blocks = metadata.BlocksInOrder();
        var blocksExpanded = _blocksExpanded.Contains(workspaceId);
        foreach (var block in blocksExpanded ? blocks : blocks.Take(1))
        {
            var text = new TextBlock { FontSize = 11, Opacity = 0.75, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 1, 0, 1) };
            AddMarkdown(text.Inlines, block.Markdown, inlineOnly: false);
            lines.Children.Add(text);
        }
        if (blocks.Count > 1) lines.Children.Add(Toggle(workspaceId, _blocksExpanded, blocksExpanded ? "SidebarShowLessDetails" : "SidebarShowMoreDetails"));

        if (!statusShowsLog && metadata.Log.LastOrDefault() is { } log)
        {
            var (glyph, brush) = LogLevelStyle(log.Level);
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            line.Children.Add(new FontIcon { Glyph = char.ConvertFromUtf32(glyph), FontSize = 10, Foreground = ThemeBrush(brush), VerticalAlignment = VerticalAlignment.Center });
            line.Children.Add(new TextBlock { Text = log.Message, FontSize = 11, Opacity = 0.8, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap });
            AutomationProperties.SetName(line, log.Message);
            lines.Children.Add(line);
        }

        if (metadata.Progress is { } progress)
        {
            var bar = new ProgressBar { Minimum = 0, Maximum = 1, Value = progress.Value, Height = 3, MinHeight = 3, Margin = new Thickness(0, 4, 8, 0) };
            AutomationProperties.SetName(bar, progress.Label ?? $"{progress.Value:P0}");
            lines.Children.Add(bar);
            if (progress.Label is { } label)
                lines.Children.Add(new TextBlock { Text = label, FontSize = 11, Opacity = 0.6, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap });
        }
        lines.Visibility = lines.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private HyperlinkButton Toggle(string workspaceId, HashSet<string> expanded, string labelKey)
    {
        var toggle = new HyperlinkButton { Content = new TextBlock { Text = Localizer.Get(labelKey), FontSize = 10, FontWeight = FontWeights.SemiBold }, Padding = new Thickness(0), Margin = new Thickness(0, 1, 0, 1) };
        toggle.Click += (_, _) =>
        {
            if (!expanded.Remove(workspaceId)) expanded.Add(workspaceId);
            UpdateSidebarRow(workspaceId);
        };
        return toggle;
    }

    /// <summary>One status entry: its icon, its value (or key when blank) in its color, a link when it has a url.</summary>
    private static FrameworkElement StatusLine(StatusEntry entry)
    {
        var brush = entry.Color is { } raw && TerminalAppearance.ParseColor(raw) is { } color ? new SolidColorBrush(color) : ThemeBrush("TextFillColorSecondaryBrush");
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(0, 1, 0, 0) };
        if (StatusIcon(entry.Icon, brush) is { } icon) line.Children.Add(icon);
        var display = entry.Value.Trim() is { Length: > 0 } value ? value : entry.Key;
        var text = new TextBlock { FontSize = 11, Foreground = brush, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        if (entry.Format == "markdown") AddMarkdown(text.Inlines, display, inlineOnly: true);
        else text.Text = display;
        line.Children.Add(text);
        AutomationProperties.SetName(line, display);
        if (entry.Url is not { } url) return line;
        text.TextDecorations = Windows.UI.Text.TextDecorations.Underline;
        var link = new HyperlinkButton { Content = line, NavigateUri = new Uri(url), Padding = new Thickness(0), Foreground = brush };
        ToolTipService.SetToolTip(link, url);
        AutomationProperties.SetName(link, display);
        return link;
    }

    /// <summary>"emoji:X" and "text:X" show X; "sf:name" or a bare name shows the matching glyph.</summary>
    private static FrameworkElement? StatusIcon(string? raw, Brush brush)
    {
        if (raw?.Trim() is not { Length: > 0 } icon) return null;
        if (icon.StartsWith("emoji:", StringComparison.Ordinal) || icon.StartsWith("text:", StringComparison.Ordinal))
        {
            var text = icon[(icon.IndexOf(':') + 1)..];
            return text.Length == 0 ? null : new TextBlock { Text = text, FontSize = 11, Foreground = brush, FontWeight = icon[0] == 't' ? FontWeights.SemiBold : FontWeights.Normal };
        }
        var name = (icon.StartsWith("sf:", StringComparison.Ordinal) ? icon[3..] : icon).Replace(".fill", "").Replace(".circle", "");
        return SymbolGlyphs.TryGetValue(name, out var glyph)
            ? new FontIcon { Glyph = char.ConvertFromUtf32(glyph), FontSize = 10, Foreground = brush, VerticalAlignment = VerticalAlignment.Center }
            : null;
    }

    private static (int Glyph, string Brush) LogLevelStyle(string level) => level switch
    {
        "progress" => (0xE768, "AccentTextFillColorPrimaryBrush"),
        "success" => (0xE73E, "SystemFillColorSuccessBrush"),
        "warning" => (0xE7BA, "SystemFillColorCautionBrush"),
        "error" => (0xE783, "SystemFillColorCriticalBrush"),
        _ => (0xE946, "TextFillColorSecondaryBrush"),
    };

    private static readonly MarkdownPipeline SidebarMarkdown = new MarkdownPipelineBuilder().UseEmphasisExtras().Build();

    /// <summary>Markdown as text: emphasis, code and web links styled, each block on its own line (as
    /// SwiftUI renders a sidebar block); <paramref name="inlineOnly"/> keeps a status value on one line.</summary>
    internal static void AddMarkdown(InlineCollection target, string markdown, bool inlineOnly)
    {
        var first = true;
        foreach (var block in Markdown.Parse(markdown, SidebarMarkdown).Descendants<LeafBlock>())
        {
            if (!first) target.Add(inlineOnly ? new Run { Text = " " } : new LineBreak());
            first = false;
            if (block.Parent is ListItemBlock) target.Add(new Run { Text = "• " });
            if (block.Inline is { } inline)
            {
                var span = block is HeadingBlock ? new Bold() : new Span();
                foreach (var child in inline) span.Inlines.Add(MarkdownToXaml(child, inlineOnly));
                target.Add(span);
            }
            else target.Add(new Run { Text = block.Lines.ToString(), FontFamily = new FontFamily("Cascadia Mono, Consolas") });
        }
    }

    private static XamlInline MarkdownToXaml(MarkdownInline inline, bool inlineOnly)
    {
        static Span Wrap(Span span, ContainerInline container, bool inlineOnly)
        {
            foreach (var child in container) span.Inlines.Add(MarkdownToXaml(child, inlineOnly));
            return span;
        }
        return inline switch
        {
            LiteralInline literal => new Run { Text = literal.Content.ToString() },
            CodeInline code => new Run { Text = code.Content, FontFamily = new FontFamily("Cascadia Mono, Consolas") },
            LineBreakInline { IsHard: true } when !inlineOnly => new LineBreak(),
            LineBreakInline => new Run { Text = " " },
            EmphasisInline { DelimiterChar: '~' } strike => Wrap(new Span { TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough }, strike, inlineOnly),
            EmphasisInline emphasis => Wrap(emphasis.DelimiterCount >= 2 ? new Bold() : new Italic(), emphasis, inlineOnly),
            LinkInline { IsImage: false } link when Uri.TryCreate(link.Url, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https"
                => Wrap(new Hyperlink { NavigateUri = uri }, link, inlineOnly),
            ContainerInline container => Wrap(new Span(), container, inlineOnly),
            _ => new Run { Text = inline.ToString() },
        };
    }
}
