using System.Net;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>The diff review panel, as on macOS: a terminal's uncommitted changes (or its branch since a
/// base branch) beside it, with comments on new-file line ranges that Send to agent pastes into that
/// terminal. Click a line number to comment; Shift+click extends the range. Rendered in WebView2 with
/// the panel's own script, which talks to the window through web messages.</summary>
public sealed partial class ReviewPanel : Grid, IPanel
{
    private readonly WebView2 _view = new();
    private readonly Func<string?> _directory;
    private bool _ready;
    private bool _disposed;
    private int _nextComment = 1;

    internal string SourceSurfaceId { get; }
    internal string Mode { get; }
    internal string? BaseBranch { get; }
    internal ReviewSnapshot? Snapshot { get; private set; }
    internal string? Error { get; private set; }
    internal DateTimeOffset GeneratedAt { get; private set; }
    internal List<ReviewComment> Comments { get; } = [];
    /// <summary>The panel's Send to agent button was clicked.</summary>
    internal event Action<ReviewPanel>? SendRequested;
    /// <summary>The Revert Files to Before Last Turn (or Undo File Revert) button was clicked.</summary>
    internal event Action<ReviewPanel>? RevertRequested;
    /// <summary>The kind of the reviewed terminal's newest turn checkpoint, which names the header's
    /// revert button; null hides it.</summary>
    internal string? CheckpointKind { get; private set; }
    private readonly Func<string?> _workspaceId;

    public string Title => Mode == "branch" ? string.Format(Localizer.Get("ReviewTitleBranch"), BaseBranch ?? "origin/main") : Localizer.Get("ReviewTitleUncommitted");
    public string Glyph => "";
    public string? Tooltip => Snapshot?.Root;

    internal ReviewPanel(string sourceSurfaceId, string mode, string? baseBranch, Func<string?> directory, Func<string?> workspaceId, ReviewSnapshot? snapshot)
    {
        SourceSurfaceId = sourceSurfaceId;
        Mode = mode;
        BaseBranch = baseBranch;
        _directory = directory;
        _workspaceId = workspaceId;
        Snapshot = snapshot;
        GeneratedAt = DateTimeOffset.Now;
        Children.Add(_view);
        _ = InitializeAsync(refresh: snapshot is null);
    }

    private async Task InitializeAsync(bool refresh)
    {
        try { await _view.EnsureCoreWebView2Async(); }
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
        core.NavigationStarting += (sender, args) =>
        {
            if (!args.Uri.StartsWith("data:", StringComparison.Ordinal) && args.Uri != "about:blank") args.Cancel = true;
        };
        core.NewWindowRequested += (sender, args) => args.Handled = true;
        core.NavigationCompleted += (sender, args) => PostComments();
        core.WebMessageReceived += (sender, args) => OnMessage(args.WebMessageAsJson);
        _ready = true;
        if (refresh) await RefreshAsync();
        else
        {
            await RefreshCheckpointAsync(_directory());
            Render();
        }
    }

    /// <summary>Reruns the diff off the UI thread; comments whose lines are gone are kept and flagged.</summary>
    internal async Task RefreshAsync()
    {
        var directory = _directory();
        try
        {
            Snapshot = await Task.Run(() => ReviewDiff.Snapshot(directory ?? throw new ReviewDiff.ReviewException("unavailable", Localizer.Get("ReviewNotGit")), Mode, BaseBranch));
            Error = null;
        }
        catch (ReviewDiff.ReviewException error)
        {
            Snapshot = null;
            Error = error.Message;
        }
        await RefreshCheckpointAsync(directory);
        GeneratedAt = DateTimeOffset.Now;
        if (Snapshot is { } snapshot)
            for (var index = 0; index < Comments.Count; index++) Comments[index] = Comments[index] with { IsStale = !ReviewDiff.Anchored(Comments[index], snapshot.Files) };
        Render();
    }

    private async Task RefreshCheckpointAsync(string? directory)
    {
        var workspace = _workspaceId();
        CheckpointKind = directory is null || workspace is null ? null : await Task.Run(() =>
        {
            try { return Checkpoints.Newest(directory, workspace, SourceSurfaceId)?.Kind; }
            catch (Checkpoints.CheckpointException) { return null; }
        });
    }

    internal ReviewComment AddComment(string file, int start, int end, string text)
    {
        if (start < 1 || end < start || string.IsNullOrWhiteSpace(file) || string.IsNullOrWhiteSpace(text) || text.Length > 65_536)
            throw new ControlException("invalid_params", Localizer.Get("ReviewCommentInvalid"));
        var comment = new ReviewComment($"comment-{_nextComment++}", file, start, end, text.Trim(), DateTimeOffset.Now);
        if (Snapshot is { } snapshot) comment = comment with { IsStale = !ReviewDiff.Anchored(comment, snapshot.Files) };
        Comments.Add(comment);
        PostComments();
        return comment;
    }

    internal bool RemoveComment(string id)
    {
        var removed = Comments.RemoveAll(comment => comment.Id == id) > 0;
        PostComments();
        return removed;
    }

    internal void ClearComments()
    {
        Comments.Clear();
        PostComments();
    }

    private void OnMessage(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var message = document.RootElement;
            switch (message.GetProperty("type").GetString())
            {
                case "add": AddComment(message.GetProperty("file").GetString()!, message.GetProperty("start").GetInt32(), message.GetProperty("end").GetInt32(), message.GetProperty("text").GetString()!); break;
                case "remove": RemoveComment(message.GetProperty("id").GetString()!); break;
                case "refresh": _ = RefreshAsync(); break;
                case "send": SendRequested?.Invoke(this); break;
                case "revert": RevertRequested?.Invoke(this); break;
            }
        }
        catch (Exception error) when (error is JsonException or KeyNotFoundException or InvalidOperationException or ControlException) { }
    }

    private void PostComments()
    {
        if (!_ready || _disposed) return;
        _view.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(new
        {
            type = "comments",
            comments = Comments.Select(comment => new { id = comment.Id, file = comment.FilePath, start = comment.Start, end = comment.End, text = comment.Text, stale = comment.IsStale }),
        }));
    }

    private void Render()
    {
        if (!_ready || _disposed) return;
        var dark = ActualTheme == ElementTheme.Dark || (ActualTheme == ElementTheme.Default && Application.Current.RequestedTheme == ApplicationTheme.Dark);
        _view.NavigateToString(Html(Snapshot, Error, Title, dark, CheckpointKind));
    }

    internal static string Html(ReviewSnapshot? snapshot, string? error, string title, bool dark, string? checkpointKind = null)
    {
        static string E(string text) => WebUtility.HtmlEncode(text);
        var body = new StringBuilder();
        if (error is not null) body.Append($"<div class=empty><b>{E(Localizer.Get("ReviewError"))}</b><p>{E(error)}</p></div>");
        else if (snapshot is null || snapshot.Files.Count == 0) body.Append($"<div class=empty><b>{E(Localizer.Get("ReviewEmptyTitle"))}</b><p>{E(Localizer.Get("ReviewEmptyMessage"))}</p></div>");
        else
        {
            foreach (var file in snapshot.Files)
            {
                var status = file.Status switch { "added" => "A", "deleted" => "D", "renamed" => "R", _ => "M" };
                body.Append($"<details open><summary><span class='status {E(file.Status)}'>{status}</span> {E(file.OldPath is null ? file.Path : $"{file.OldPath} → {file.Path}")}</summary>");
                if (file.Note is not null)
                {
                    var note = file.Note switch { "binary" => "ReviewBinary", "too_large" => "ReviewTooLarge", _ => "ReviewUnreadable" };
                    body.Append($"<div class=note>{E(Localizer.Get(note))}</div></details>");
                    continue;
                }
                body.Append($"<table data-file=\"{E(file.Path)}\">");
                foreach (var hunk in file.Hunks)
                {
                    body.Append($"<tr class=hunk><td colspan=3>{E(hunk.Header)}</td></tr>");
                    foreach (var line in hunk.Lines)
                    {
                        var kind = line.Kind switch { '+' => "add", '-' => "del", _ => "ctx" };
                        var anchor = line.New is { } number ? $" data-new=\"{number}\"" : string.Empty;
                        var clickable = line.New is { } target ? $" class=ln data-line=\"{target}\"" : " class=num";
                        body.Append($"<tr class={kind}{anchor}><td class=num>{line.Old}</td><td{clickable}>{line.New}</td><td class=code>{E(line.Text)}</td></tr>");
                    }
                }
                body.Append("</table></details>");
            }
        }
        var (background, text, muted, border, add, del, hunkBackground, selected) = dark
            ? ("#282C34", "#E6E6E6", "#9DA5B4", "#3E4451", "rgba(46,160,67,.18)", "rgba(248,81,73,.18)", "#2F343F", "rgba(56,139,253,.25)")
            : ("#FFFFFF", "#1F2328", "#59636E", "#D1D9E0", "#E6FFEC", "#FFEBE9", "#F6F8FA", "rgba(84,174,255,.3)");
        // Revert Files to Before Last Turn, or Undo File Revert right after a revert.
        var revert = checkpointKind is null ? string.Empty
            : $"<button data-act=revert>{E(Localizer.Get(checkpointKind == Checkpoints.BeforeRevert ? "ReviewUndoRevert" : "ReviewRevert"))}</button>";
        var strings = JsonSerializer.Serialize(new
        {
            send = Localizer.Get("ReviewSend"),
            add = Localizer.Get("ReviewAdd"),
            cancel = Localizer.Get("Cancel"),
            remove = Localizer.Get("ReviewRemove"),
            placeholder = Localizer.Get("ReviewPlaceholder"),
            stale = Localizer.Get("ReviewStale"),
        });
        return $$"""
            <!doctype html><html><head><meta charset="utf-8"><style>
            body { background: {{background}}; color: {{text}}; font: 13px "Segoe UI Variable Text", "Segoe UI", sans-serif; margin: 0; }
            header { position: sticky; top: 0; display: flex; gap: 8px; align-items: center; padding: 8px 12px; background: {{background}}; border-bottom: 1px solid {{border}}; z-index: 1; }
            header .title { flex: 1; font-weight: 600; }
            button { font: inherit; color: {{text}}; background: {{hunkBackground}}; border: 1px solid {{border}}; border-radius: 4px; padding: 3px 10px; cursor: pointer; }
            button:disabled { opacity: .5; cursor: default; }
            details { border-bottom: 1px solid {{border}}; } summary { padding: 6px 12px; cursor: pointer; font-family: "Cascadia Mono", Consolas, monospace; }
            .status { display: inline-block; width: 1.4em; text-align: center; border-radius: 3px; color: #fff; background: #6E7781; }
            .status.added { background: #2DA44E; } .status.deleted { background: #CF222E; } .status.renamed { background: #8250DF; }
            table { border-collapse: collapse; width: 100%; font: 12px/1.5 "Cascadia Mono", Consolas, monospace; }
            td { padding: 0 8px; white-space: pre; vertical-align: top; } td.code { width: 100%; tab-size: 4; }
            td.num, td.ln { color: {{muted}}; text-align: right; user-select: none; } td.ln { cursor: pointer; } td.ln:hover { color: {{text}}; text-decoration: underline; }
            tr.add { background: {{add}}; } tr.del { background: {{del}}; } tr.hunk td { background: {{hunkBackground}}; color: {{muted}}; padding: 2px 8px; }
            tr.sel td { background: {{selected}}; }
            .box { margin: 6px 12px; padding: 8px 10px; border: 1px solid {{border}}; border-radius: 6px; background: {{background}}; white-space: normal; font-family: "Segoe UI", sans-serif; }
            .box .range { color: {{muted}}; font-size: 12px; margin-bottom: 4px; } .box .text { white-space: pre-wrap; margin-bottom: 6px; }
            textarea { width: 100%; box-sizing: border-box; font: inherit; color: {{text}}; background: {{hunkBackground}}; border: 1px solid {{border}}; border-radius: 4px; margin-bottom: 6px; }
            .note, .empty { padding: 12px; color: {{muted}}; } .empty b { color: {{text}}; }
            #stale .box { border-style: dashed; }
            </style></head><body>
            <header><span class=title>{{E(title)}}</span>{{revert}}<button data-act=refresh>&#x21bb;</button><button id=send data-act=send disabled></button></header>
            <div id=stale></div>{{body}}
            <script>
            const L = {{strings}};
            let comments = [], sel = null;
            const post = m => chrome.webview.postMessage(m);
            const range = c => `${c.file}:${c.start === c.end ? c.start : c.start + '-' + c.end}`;
            const rowFor = (file, line) => document.querySelector(`table[data-file="${CSS.escape(file)}"] tr[data-new="${line}"]`);
            function box(html) { const tr = document.createElement('tr'); tr.innerHTML = `<td colspan=3><div class=box>${html}</div></td>`; return tr; }
            function showForm() {
              document.querySelectorAll('tr.sel').forEach(r => r.classList.remove('sel'));
              document.getElementById('form')?.remove();
              if (!sel) return;
              for (let l = sel.start; l <= sel.end; l++) rowFor(sel.file, l)?.classList.add('sel');
              const after = rowFor(sel.file, sel.end); if (!after) return;
              const tr = box(`<div class=range></div><textarea rows=3></textarea><div><button data-act=add></button> <button data-act=cancel></button></div>`);
              tr.id = 'form';
              tr.querySelector('.range').textContent = range(sel);
              tr.querySelector('textarea').placeholder = L.placeholder;
              tr.querySelector('[data-act=add]').textContent = L.add;
              tr.querySelector('[data-act=cancel]').textContent = L.cancel;
              after.after(tr); tr.querySelector('textarea').focus();
            }
            function addFromForm() {
              const text = document.querySelector('#form textarea')?.value.trim();
              if (text && sel) post({ type: 'add', file: sel.file, start: sel.start, end: sel.end, text });
              sel = null; showForm();
            }
            function render() {
              document.querySelectorAll('tr.comment').forEach(r => r.remove());
              const stale = document.getElementById('stale'); stale.innerHTML = '';
              for (const c of comments) {
                const tr = box(`<div class=range></div><div class=text></div><button data-act=remove></button>`);
                tr.className = 'comment';
                tr.querySelector('.range').textContent = range(c) + (c.stale ? ` (${L.stale})` : '');
                tr.querySelector('.text').textContent = c.text;
                const remove = tr.querySelector('button'); remove.textContent = L.remove; remove.dataset.id = c.id;
                const row = !c.stale && rowFor(c.file, c.end);
                if (row) row.after(tr); else stale.appendChild(tr.querySelector('.box'));
              }
              const send = document.getElementById('send');
              send.textContent = `${L.send} (${comments.length})`; send.disabled = comments.length === 0;
            }
            document.addEventListener('click', e => {
              const n = e.target.closest('td.ln');
              if (n) {
                const file = n.closest('table').dataset.file, line = +n.dataset.line;
                if (e.shiftKey && sel && sel.file === file) { sel.start = Math.min(sel.anchor, line); sel.end = Math.max(sel.anchor, line); }
                else sel = { file, anchor: line, start: line, end: line };
                showForm(); return;
              }
              const b = e.target.closest('button[data-act]'); if (!b) return;
              const act = b.dataset.act;
              if (act === 'add') addFromForm();
              else if (act === 'cancel') { sel = null; showForm(); }
              else if (act === 'remove') post({ type: 'remove', id: b.dataset.id });
              else post({ type: act });
            });
            document.addEventListener('keydown', e => {
              if (!e.target.closest('#form')) return;
              if (e.key === 'Enter' && e.ctrlKey) { e.preventDefault(); addFromForm(); }
              if (e.key === 'Escape') { sel = null; showForm(); }
            });
            chrome.webview.addEventListener('message', e => { if (e.data.type === 'comments') { comments = e.data.comments; render(); } });
            render();
            </script></body></html>
            """;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _view.Close();
    }
}
