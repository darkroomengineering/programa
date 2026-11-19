using Markdig;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace Programa;

/// <summary>A tab that shows something other than a terminal; the panel is its own element.</summary>
internal interface IPanel : IDisposable
{
    string Title { get; }
    string Glyph { get; }
    string? Tooltip { get; }
}

/// <summary>A markdown file shown in a pane, as on macOS (`programa markdown open`): rendered with
/// Markdig into WebView2, reloaded when the file changes on disk. Scripts are off; web links open in
/// the default browser; relative images load from the file's folder.</summary>
public sealed partial class MarkdownPanel : Grid, IPanel
{
    private const string Host = "programa-markdown.local";
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder().UseAdvancedExtensions().Build();
    private readonly WebView2 _view = new();
    private readonly FileSystemWatcher? _watcher;
    private readonly DispatcherQueueTimer _debounce;
    private bool _ready;
    private bool _disposed;

    internal string FilePath { get; }
    public string Title => Path.GetFileName(FilePath);
    public string Glyph => "";
    public string? Tooltip => FilePath;

    internal MarkdownPanel(string path)
    {
        FilePath = Path.GetFullPath(path);
        Children.Add(_view);
        _debounce = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(150);
        _debounce.IsRepeating = false;
        _debounce.Tick += (_, _) => Render();
        if (Path.GetDirectoryName(FilePath) is { } folder && Directory.Exists(folder))
        {
            // Editors save by replacing the file, so renames count as changes too.
            _watcher = new FileSystemWatcher(folder, Path.GetFileName(FilePath)) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size };
            FileSystemEventHandler changed = (_, _) => DispatcherQueue.TryEnqueue(() => { _debounce.Stop(); _debounce.Start(); });
            _watcher.Changed += changed;
            _watcher.Created += changed;
            _watcher.Renamed += (_, _) => DispatcherQueue.TryEnqueue(() => { _debounce.Stop(); _debounce.Start(); });
            _watcher.EnableRaisingEvents = true;
        }
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            await _view.EnsureCoreWebView2Async();
        }
        catch (Exception error)
        {
            Children.Add(new TextBlock { Text = error.Message, Margin = new Thickness(16), TextWrapping = TextWrapping.Wrap });
            return;
        }
        if (_disposed) return;
        var core = _view.CoreWebView2;
        core.Settings.IsScriptEnabled = false;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreHostObjectsAllowed = false;
        if (Path.GetDirectoryName(FilePath) is { } folder)
            core.SetVirtualHostNameToFolderMapping(Host, folder, CoreWebView2HostResourceAccessKind.Allow);
        core.NavigationStarting += (sender, args) =>
        {
            if (args.Uri.StartsWith("data:", StringComparison.Ordinal) || args.Uri == "about:blank") return;
            args.Cancel = true;
            if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) && uri.Host != Host && uri.Scheme is "http" or "https" or "mailto")
                _ = Windows.System.Launcher.LaunchUriAsync(uri);
        };
        core.NewWindowRequested += (_, args) => args.Handled = true;
        _ready = true;
        Render();
    }

    private void Render()
    {
        if (!_ready || _disposed) return;
        string markdown;
        try { markdown = File.ReadAllText(FilePath); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            markdown = $"*{error.Message}*";
        }
        _view.NavigateToString(Html(markdown, ActualTheme == ElementTheme.Dark || (ActualTheme == ElementTheme.Default && Application.Current.RequestedTheme == ApplicationTheme.Dark)));
    }

    internal static string Html(string markdown, bool dark)
    {
        var (background, text, muted, border, code) = dark
            ? ("#282C34", "#E6E6E6", "#9DA5B4", "#3E4451", "#2F343F")
            : ("#FFFFFF", "#1F2328", "#59636E", "#D1D9E0", "#F6F8FA");
        return $$"""
            <!doctype html><html><head><meta charset="utf-8"><base href="https://{{Host}}/">
            <style>
            body { background: {{background}}; color: {{text}}; font: 14px/1.6 "Segoe UI Variable Text", "Segoe UI", sans-serif; margin: 0; padding: 20px 28px; max-width: 900px; }
            a { color: #4493F8; } h1, h2 { border-bottom: 1px solid {{border}}; padding-bottom: .3em; }
            code, pre { font-family: "Cascadia Mono", Consolas, monospace; font-size: 13px; background: {{code}}; border-radius: 6px; }
            code { padding: .15em .35em; } pre { padding: 12px 16px; overflow-x: auto; } pre code { padding: 0; background: none; }
            blockquote { color: {{muted}}; border-left: 4px solid {{border}}; margin: 0; padding: 0 1em; }
            table { border-collapse: collapse; } th, td { border: 1px solid {{border}}; padding: 6px 12px; }
            img { max-width: 100%; } hr { border: 0; border-top: 1px solid {{border}}; }
            </style></head><body>{{Markdown.ToHtml(markdown, Pipeline)}}</body></html>
            """;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _debounce.Stop();
        _watcher?.Dispose();
        _view.Close();
    }
}
