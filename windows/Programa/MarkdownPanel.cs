using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Markdig;
using Markdig.Extensions.CustomContainers;
using Markdig.Renderers;
using Markdig.Renderers.Html;
using Markdig.Syntax;
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

/// <summary>The words the rendered page shows, passed in so the renderer needs no app resources.</summary>
internal sealed record MarkdownLabels(string Before, string After, string Truncated, string UnavailableTitle, string UnavailableMessage)
{
    internal static MarkdownLabels Localized() => new(
        Localizer.Get("MarkdownCompareBefore"), Localizer.Get("MarkdownCompareAfter"), Localizer.Get("MarkdownTruncated"),
        Localizer.Get("MarkdownFileUnavailableTitle"), Localizer.Get("MarkdownFileUnavailableMessage"));
}

/// <summary>A `:::compare` block's two sides, as macOS MarkdownAlertParser reads them.</summary>
internal sealed record MarkdownCompare(string Language, string Before, string After);

/// <summary>What the page shows: the rendered body, and whether it has mermaid diagrams to draw.</summary>
internal sealed record MarkdownBody(string Html, bool HasMermaid);

/// <summary>A markdown file shown in a pane, as on macOS (`programa markdown open`): rendered with Markdig
/// into WebView2 under the file's path, reloaded in place when the file changes on disk, following the
/// app theme. ```mermaid blocks are drawn by the bundled offline mermaid.js, `:::compare` blocks show
/// Before and After side by side, and `> [!NOTE]` alerts are callouts. The page's only scripts are its
/// own (a nonce CSP blocks any in the file). Web links open in the browser, markdown links in a new tab,
/// other targets after asking.</summary>
public sealed partial class MarkdownPanel : Grid, IPanel
{
    private const string FileHost = "programa-markdown.local";
    private const string AssetHost = "programa-markdown-assets.local";
    /// <summary>Largest prefix of the file that is read and rendered, as on macOS.</summary>
    internal const int MaxDisplayBytes = 2 * 1024 * 1024;
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder().UseAdvancedExtensions().Build();
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private readonly WebView2 _view = new();
    private readonly FileSystemWatcher? _watcher;
    private readonly DispatcherQueueTimer _debounce;
    private MarkdownBody? _body;
    private int _generation;
    private bool _ownNavigation;
    private bool _ready;
    private bool _disposed;

    internal string FilePath { get; }
    public string Title => Path.GetFileName(FilePath);
    public string Glyph { get; } = char.ConvertFromUtf32(0xE8A5);
    public string? Tooltip => FilePath;
    /// <summary>A link to something other than the web was clicked: a local file or another scheme.</summary>
    internal event Action<MarkdownPanel, Uri>? LinkRequested;

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
            // Editors save by replacing the file, so renames count as changes too; a deletion shows
            // the file as unavailable until it comes back.
            _watcher = new FileSystemWatcher(folder, Path.GetFileName(FilePath)) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size };
            FileSystemEventHandler changed = (_, _) => DispatcherQueue.TryEnqueue(() => { _debounce.Stop(); _debounce.Start(); });
            _watcher.Changed += changed;
            _watcher.Created += changed;
            _watcher.Deleted += changed;
            _watcher.Renamed += (_, _) => DispatcherQueue.TryEnqueue(() => { _debounce.Stop(); _debounce.Start(); });
            _watcher.EnableRaisingEvents = true;
        }
        ActualThemeChanged += (_, _) => Post();
        _ = InitializeAsync();
    }

    private bool IsDark => ActualTheme == ElementTheme.Dark || (ActualTheme == ElementTheme.Default && Application.Current.RequestedTheme == ApplicationTheme.Dark);

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
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreHostObjectsAllowed = false;
        // The file's drive, so relative links and images may climb out of its folder as on macOS.
        core.SetVirtualHostNameToFolderMapping(FileHost, Path.GetPathRoot(FilePath)!, CoreWebView2HostResourceAccessKind.Allow);
        core.SetVirtualHostNameToFolderMapping(AssetHost, Path.Combine(AppContext.BaseDirectory, "Markdown"), CoreWebView2HostResourceAccessKind.Allow);
        // Only the page this panel loads; every other navigation (a link, a reload) is a click to route.
        core.NavigationStarting += (_, args) =>
        {
            if (_ownNavigation) { _ownNavigation = false; return; }
            args.Cancel = true;
            Open(args.Uri);
        };
        core.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            Open(args.Uri);
        };
        core.NavigationCompleted += (_, _) => Render();
        _ready = true;
        _ownNavigation = true;
        _view.NavigateToString(Shell(Convert.ToHexString(RandomNumberGenerator.GetBytes(16)), BaseHref(FilePath)));
    }

    private void Open(string address)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme is "data" or "about" or "javascript") return;
        if (LocalPath(FilePath, uri) is { } path) LinkRequested?.Invoke(this, new Uri(path));
        else if (uri.Scheme is "http" or "https" or "mailto") _ = Windows.System.Launcher.LaunchUriAsync(uri);
        else LinkRequested?.Invoke(this, uri);
    }

    /// <summary>The file a link on the page of <paramref name="filePath"/> names, or null for any other address.</summary>
    internal static string? LocalPath(string filePath, Uri uri) => uri.Scheme == "https" && uri.Host == FileHost
        ? Path.GetFullPath(Path.Combine(Path.GetPathRoot(filePath)!, Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/'))))
        : null;

    /// <summary>The page's base: the file's folder on the file host, each segment escaped.</summary>
    internal static string BaseHref(string filePath)
    {
        var folder = Path.GetDirectoryName(filePath)!;
        var relative = Path.GetRelativePath(Path.GetPathRoot(filePath)!, folder);
        var segments = relative == "." ? [] : relative.Split(Path.DirectorySeparatorChar).Select(Uri.EscapeDataString);
        return $"https://{FileHost}/" + string.Concat(segments.Select(segment => segment + "/"));
    }

    /// <summary>Reads and renders the file off the UI thread; only the newest read is shown.</summary>
    private async void Render()
    {
        if (!_ready || _disposed) return;
        var generation = ++_generation;
        var labels = MarkdownLabels.Localized();
        var path = FilePath;
        var body = await Task.Run(() => Body(path, labels));
        if (generation != _generation || _disposed) return;
        _body = body;
        Post();
    }

    /// <summary>Hands the page its body and theme; the page swaps them in place, keeping the scroll.</summary>
    private void Post()
    {
        if (!_ready || _disposed || _body is null) return;
        _view.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new { html = _body.Html, mermaid = _body.HasMermaid, dark = IsDark }));
    }

    /// <summary>Find in the page (macOS ⌘F), with WebView2's find bar: Enter and Shift+Enter step, Escape closes.</summary>
    internal void ShowFind()
    {
        if (!_ready || _disposed) return;
        var options = _view.CoreWebView2.Environment.CreateFindOptions();
        options.FindTerm = string.Empty;
        _ = _view.CoreWebView2.Find.StartAsync(options);
    }

    internal void FindAgain(bool next)
    {
        if (!_ready || _disposed) return;
        if (_view.CoreWebView2.Find.MatchCount <= 0) ShowFind();
        else if (next) _view.CoreWebView2.Find.FindNext();
        else _view.CoreWebView2.Find.FindPrevious();
    }

    internal void CloseFind()
    {
        if (_ready && !_disposed) _view.CoreWebView2.Find.Stop();
    }

    /// <summary>The page body for the file: its path, then the rendered markdown (the first 2 MB), or
    /// the File unavailable notice when it cannot be read.</summary>
    internal static MarkdownBody Body(string path, MarkdownLabels labels)
    {
        if (Read(path) is not { } content)
            return new($"<div class=\"unavailable\"><h3>{Encode(labels.UnavailableTitle)}</h3><code>{Encode(path)}</code><p>{Encode(labels.UnavailableMessage)}</p></div>", false);
        var rendered = Render(content.Text, labels);
        var truncated = content.Truncated ? $"<p class=\"truncated\">⚠ {Encode(labels.Truncated)}</p>" : string.Empty;
        return rendered with { Html = $"<div class=\"file-path\">{Encode(path)}</div><hr class=\"file-divider\">{truncated}{rendered.Html}" };
    }

    /// <summary>The first <paramref name="maxBytes"/> of the file as text, as macOS reads it: UTF-8 (a cut
    /// inside a character drops it), else Latin-1, which takes any byte. UTF-16 files with a byte order
    /// mark (PowerShell's Out-File) read too. Null when the file cannot be read.</summary>
    internal static (string Text, bool Truncated)? Read(string path, int maxBytes = MaxDisplayBytes)
    {
        byte[] bytes;
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            bytes = new byte[(int)Math.Min(file.Length, maxBytes + 1L)];
            bytes = bytes[..file.ReadAtLeast(bytes, bytes.Length, throwOnEndOfStream: false)];
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
        var truncated = bytes.Length > maxBytes;
        var data = truncated ? bytes[..maxBytes] : bytes;
        if (data is [0xFF, 0xFE, ..]) return (Encoding.Unicode.GetString(data, 2, (data.Length - 2) & ~1), truncated);
        if (data is [0xFE, 0xFF, ..]) return (Encoding.BigEndianUnicode.GetString(data, 2, (data.Length - 2) & ~1), truncated);
        var start = data is [0xEF, 0xBB, 0xBF, ..] ? 3 : 0;
        for (var trim = 0; trim <= (truncated ? 3 : 0) && data.Length - start - trim >= 0; trim++)
        {
            try { return (StrictUtf8.GetString(data, start, data.Length - start - trim), truncated); }
            catch (DecoderFallbackException) { }
        }
        return (Encoding.Latin1.GetString(data), truncated);
    }

    /// <summary>Markdown to HTML: GitHub-flavored, with mermaid sources marked for the page to draw and
    /// `:::compare` blocks as Before and After panes.</summary>
    internal static MarkdownBody Render(string markdown, MarkdownLabels labels)
    {
        using var writer = new StringWriter();
        var renderer = new HtmlRenderer(writer);
        Pipeline.Setup(renderer);
        var mermaid = new MermaidRenderer(renderer.ObjectRenderers.FindExact<CodeBlockRenderer>()!);
        renderer.ObjectRenderers.Replace<CodeBlockRenderer>(mermaid);
        renderer.ObjectRenderers.Replace<HtmlCustomContainerRenderer>(new CompareRenderer(renderer.ObjectRenderers.FindExact<HtmlCustomContainerRenderer>()!, labels));
        renderer.Render(Markdown.Parse(markdown, Pipeline));
        writer.Flush();
        return new(writer.ToString(), mermaid.Found);
    }

    /// <summary>A fenced block whose language is mermaid, in any case, as on macOS.</summary>
    internal static bool IsMermaid(Block block) => block is FencedCodeBlock { Info: { } info } && info.Equals("mermaid", StringComparison.OrdinalIgnoreCase);

    /// <summary>A closed `:::compare` block with exactly two fenced code blocks (other lines are ignored).
    /// A fence labeled `before` or `after` after its language takes that side; otherwise the first is
    /// Before. Null for anything else, which renders as ordinary markdown.</summary>
    internal static MarkdownCompare? Compare(CustomContainer block)
    {
        if (!string.Equals(block.Info, "compare", StringComparison.OrdinalIgnoreCase) || block.ClosingFencedCharCount == 0) return null;
        var fences = block.OfType<FencedCodeBlock>().ToList();
        if (fences.Count != 2) return null;
        static string Label(FencedCodeBlock fence) => (fence.Arguments ?? string.Empty).Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() ?? string.Empty;
        var before = fences.FirstOrDefault(fence => Label(fence) == "before") ?? fences[0];
        var after = fences.FirstOrDefault(fence => Label(fence) == "after") ?? fences[1];
        return new(before.Info is { Length: > 0 } language ? language : after.Info ?? string.Empty, before.Lines.ToString(), after.Lines.ToString());
    }

    private static string Encode(string text) => WebUtility.HtmlEncode(text);

    private sealed class MermaidRenderer(CodeBlockRenderer code) : HtmlObjectRenderer<CodeBlock>
    {
        internal bool Found { get; private set; }

        protected override void Write(HtmlRenderer renderer, CodeBlock block)
        {
            if (!IsMermaid(block))
            {
                ((IMarkdownObjectRenderer)code).Write(renderer, block);
                return;
            }
            Found = true;
            renderer.EnsureLine();
            renderer.Write("<pre class=\"mermaid\">").WriteLeafRawLines(block, true, true).WriteLine("</pre>");
        }
    }

    private sealed class CompareRenderer(HtmlCustomContainerRenderer container, MarkdownLabels labels) : HtmlObjectRenderer<CustomContainer>
    {
        protected override void Write(HtmlRenderer renderer, CustomContainer block)
        {
            if (Compare(block) is not { } compare)
            {
                ((IMarkdownObjectRenderer)container).Write(renderer, block);
                return;
            }
            var language = compare.Language.Length > 0 ? $" <span class=\"language\">({Encode(compare.Language)})</span>" : string.Empty;
            string Side(string side, string title, string code) =>
                $"<div class=\"side {side}\"><div class=\"side-title\">{Encode(title)}{language}</div><pre><code>{Encode(code)}</code></pre></div>";
            renderer.EnsureLine();
            renderer.WriteLine($"<div class=\"compare\">{Side("before", labels.Before, compare.Before)}{Side("after", labels.After, compare.After)}</div>");
        }
    }

    /// <summary>The page, loaded once: styles for both themes and the script that swaps in each body,
    /// keeps the scroll, and draws mermaid diagrams the way macOS MermaidBlockView does (theme, strict
    /// security, full width up to the diagram's own size). A diagram that fails, or a missing mermaid.js,
    /// leaves its source as a code block.</summary>
    internal static string Shell(string nonce, string baseHref) => $$"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-{{nonce}}' https://{{AssetHost}}; style-src 'unsafe-inline'; img-src https: http: data:; font-src data:; form-action 'none'; base-uri https://{{FileHost}}">
        <base href="{{Encode(baseHref)}}">
        <style>
        :root { color-scheme: light; --background: #FFFFFF; --text: #1F2328; --muted: #59636E; --border: #D1D9E0; --code: #F6F8FA;
          --blue: #007AFF; --green: #34C759; --purple: #AF52DE; --orange: #FF9500; --red: #FF3B30; --tint: 8%; --header: 7%; }
        :root.dark { color-scheme: dark; --background: #282C34; --text: #E6E6E6; --muted: #9DA5B4; --border: #3E4451; --code: #2F343F;
          --blue: #0A84FF; --green: #30D158; --purple: #BF5AF2; --orange: #FF9F0A; --red: #FF453A; --tint: 12%; --header: 10%; }
        body { background: var(--background); color: var(--text); font: 14px/1.6 "Segoe UI Variable Text", "Segoe UI", sans-serif; margin: 0; padding: 16px 24px; max-width: 900px; }
        a { color: #4493F8; } h1, h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
        code, pre { font-family: "Cascadia Mono", Consolas, monospace; font-size: 13px; background: var(--code); border-radius: 6px; }
        code { padding: .15em .35em; } pre { padding: 12px 16px; overflow-x: auto; } pre code { padding: 0; background: none; }
        blockquote { color: var(--muted); border-left: 3px solid var(--border); margin: 0; padding: 0 1em; }
        table { border-collapse: collapse; } th, td { border: 1px solid var(--border); padding: 6px 12px; }
        img { max-width: 100%; } hr { border: 0; border-top: 1px solid var(--border); }
        .file-path { font: 11px "Cascadia Mono", Consolas, monospace; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .file-divider { margin: 8px 0 16px; } .truncated { font-size: 12px; color: var(--muted); }
        .unavailable { display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 80vh; text-align: center; gap: 4px; }
        .unavailable h3 { margin: 0; } .unavailable code { background: none; color: var(--muted); user-select: text; } .unavailable p { margin: 0; font-size: 12px; color: var(--muted); }
        pre.mermaid.rendered { background: none; padding: 4px; display: flex; justify-content: center; overflow: visible; }
        pre.mermaid.rendered svg { width: 100%; max-width: 100%; height: auto; }
        .markdown-alert { --accent: var(--blue); position: relative; margin: 8px 0; padding: 12px 12px 12px 15px; border-radius: 7px; background: color-mix(in srgb, var(--accent) var(--tint), transparent); overflow: hidden; }
        .markdown-alert::before { content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 3px; background: var(--accent); }
        .markdown-alert > :last-child { margin-bottom: 0; }
        .markdown-alert-title { display: flex; align-items: center; gap: 8px; margin: 0 0 4px; font-weight: 600; color: var(--accent); } .markdown-alert-title svg { fill: currentColor; }
        .markdown-alert-tip { --accent: var(--green); } .markdown-alert-important { --accent: var(--purple); }
        .markdown-alert-warning { --accent: var(--orange); } .markdown-alert-caution { --accent: var(--red); }
        .compare { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; margin: 8px 0; }
        .side { border: 1px solid var(--border); border-radius: 7px; overflow: hidden; min-width: 0; }
        .side pre { margin: 0; border-radius: 0; } .side-title { padding: 6px 12px; font-size: 12px; font-weight: 600; color: var(--muted); border-bottom: 1px solid var(--border); }
        .side.before .side-title { background: color-mix(in srgb, var(--red) var(--header), transparent); }
        .side.after .side-title { background: color-mix(in srgb, var(--green) var(--header), transparent); }
        .side-title .language { font-weight: 400; font-size: 11px; opacity: .75; }
        </style></head><body><main id="content"></main>
        <script nonce="{{nonce}}">
        const content = document.getElementById('content');
        let cache = new Map(), generation = 0, loading = null;
        const load = () => loading ??= new Promise((resolve, reject) => {
          const script = document.createElement('script');
          script.src = 'https://{{AssetHost}}/mermaid.min.js';
          script.onload = resolve; script.onerror = reject;
          document.head.append(script);
        });
        const show = (block, svg) => { block.innerHTML = svg; block.classList.add('rendered'); };
        chrome.webview.addEventListener('message', async ({ data: page }) => {
          const current = ++generation, y = scrollY, theme = page.dark ? 'dark' : 'default';
          document.documentElement.classList.toggle('dark', page.dark);
          content.innerHTML = page.html;
          // Diagrams drawn before come back at once, so a reload does not jump.
          const blocks = [...content.querySelectorAll('pre.mermaid')].map(block => ({ block, key: theme + '\n' + block.textContent }));
          const drawn = new Map();
          for (const { block, key } of blocks) if (cache.has(key)) { drawn.set(key, cache.get(key)); show(block, cache.get(key)); }
          cache = drawn;
          scrollTo(0, y);
          if (!page.mermaid) return;
          try { await load(); } catch { return; }
          if (current !== generation) return;
          mermaid.initialize({ startOnLoad: false, theme, securityLevel: 'strict', themeVariables: { fontFamily: '"Segoe UI Variable Text", "Segoe UI", sans-serif' } });
          for (const [index, { block, key }] of blocks.entries()) {
            if (block.classList.contains('rendered')) continue;
            const id = `mermaid-${current}-${index}`;
            try {
              const { svg } = await mermaid.render(id, block.textContent);
              if (current !== generation) return;
              cache.set(key, svg);
              show(block, svg);
            } catch {
              document.getElementById('d' + id)?.remove();
              block.classList.add('failed');
            }
          }
        });
        </script></body></html>
        """;

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _debounce.Stop();
        _watcher?.Dispose();
        _view.Close();
    }
}
