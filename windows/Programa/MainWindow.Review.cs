using System.Text.Json;

namespace Programa;

internal sealed record SessionReview(string Source, string Mode, string? BaseBranch);

/// <summary>`review.open/refresh/comment.add/comment.remove/comment.list/send_comments`, as on macOS.
/// The diff runs off the UI thread; a review refreshes itself when its terminal's agent goes from
/// working to anything else.</summary>
public sealed partial class MainWindow
{
    /// <summary>Saved review panels not created yet.</summary>
    private Dictionary<string, SessionReview> _restoreReviews = new(StringComparer.Ordinal);
    /// <summary>The last agent state seen per reviewed terminal, to catch the end of a turn.</summary>
    private readonly Dictionary<string, string?> _reviewedStates = new(StringComparer.Ordinal);

    private ReviewPanel CreateReviewPanel(string source, string mode, string? baseBranch, ReviewSnapshot? snapshot = null)
    {
        var panel = new ReviewPanel(source, mode, baseBranch, () => SourceDirectory(source), () => _terminals.GetValueOrDefault(source)?.WorkspaceId, snapshot);
        panel.RevertRequested += review => _ = RevertToCheckpointAsync(review);
        panel.SendRequested += review =>
        {
            try { SendReview(review, null); }
            catch (ControlException error) { _ = ShowErrorAsync(Localizer.Get("ReviewSendFailed"), error.Message); }
        };
        return panel;
    }

    private string? SourceDirectory(string surfaceId) =>
        _terminals.GetValueOrDefault(surfaceId)?.WorkingDirectory ?? _restore.GetValueOrDefault(surfaceId)?.Cwd;

    private async Task<object?> HandleReviewAsync(string method, JsonElement p)
    {
        if (method != "review.open")
        {
            if (method != "review.refresh") return await OnUiThread(() => ReviewFromControl(method, p));
            var refreshing = (Task<ReviewPanel>)(await OnUiThread(() => RefreshReview(ReviewTarget(p))))!;
            var refreshed = await refreshing;
            return new { file_count = refreshed.Snapshot?.Files.Count ?? 0, diffable_file_count = refreshed.Snapshot?.Files.Count(file => file.Note is null) ?? 0, generated_at = refreshed.GeneratedAt.ToUnixTimeSeconds() };
        }
        var mode = (Text(p, "mode") ?? "uncommitted") switch
        {
            "uncommitted" or "worktree" => "uncommitted",
            "branch" => "branch",
            var other => throw new ControlException("invalid_params", $"mode '{other}' is not uncommitted or branch."),
        };
        var baseBranch = mode == "branch" ? Text(p, "base_branch") ?? "origin/main" : null;
        var (source, directory) = ((string, string?))(await OnUiThread(() =>
        {
            var (_, _, surface) = SurfaceTarget(p);
            if (IsPanel(surface)) throw new ControlException("invalid_params", $"{surface} is a panel, not a terminal.");
            return (surface, SourceDirectory(surface));
        }))!;
        ReviewSnapshot snapshot;
        try { snapshot = ReviewDiff.Snapshot(directory ?? throw new ReviewDiff.ReviewException("unavailable", Localizer.Get("ReviewNotGit")), mode, baseBranch); }
        catch (ReviewDiff.ReviewException error) { throw new ControlException(error.Code, error.Message); }
        return await OnUiThread(() =>
        {
            var (surfaceId, paneId, workspaceId) = SplitPanel(p, CreateReviewPanel(source, mode, baseBranch, snapshot), Flag(p, "focus"));
            return new
            {
                surface_id = surfaceId, pane_id = paneId, workspace_id = workspaceId, source_surface_id = source, mode, base_branch = baseBranch,
                file_count = snapshot.Files.Count, diffable_file_count = snapshot.Files.Count(file => file.Note is null),
            };
        });
    }

    private async Task<ReviewPanel> RefreshReview(ReviewPanel panel)
    {
        await panel.RefreshAsync();
        return panel;
    }

    private object ReviewFromControl(string method, JsonElement p)
    {
        var panel = ReviewTarget(p);
        switch (method)
        {
            case "review.comment.add":
                var start = Number(p, "start_line") ?? throw new ControlException("invalid_params", "start_line is required.");
                var comment = panel.AddComment(Required(p, "file_path"), start, Number(p, "end_line") ?? start, Required(p, "text"));
                return new { comment_id = comment.Id };
            case "review.comment.remove":
                var id = Required(p, "comment_id");
                return panel.RemoveComment(id) ? new { ok = true } : throw NotFound("comment", id);
            case "review.comment.list":
                return new
                {
                    comments = panel.Comments.Select(item => new
                    {
                        id = item.Id, file_path = item.FilePath, start_line = item.Start, end_line = item.End, text = item.Text,
                        created_at = item.CreatedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"), is_stale = item.IsStale,
                    }),
                };
            default: // review.send_comments
                return SendReview(panel, Text(p, "preamble"));
        }
    }

    /// <summary>The review panel named by surface_id, else the first in the selected workspace.</summary>
    private ReviewPanel ReviewTarget(JsonElement p)
    {
        if (Text(p, "surface_id") is { } id)
            return (PanelFor(id) as ReviewPanel) ?? throw NotFound("review panel", id);
        return SelectedWorkspace()?.Panes.SelectMany(pane => pane.Surfaces).Select(surface => PanelFor(surface.Id)).OfType<ReviewPanel>().FirstOrDefault()
            ?? throw NotFound("review panel");
    }

    /// <summary>Pastes the pending comments into the reviewed terminal as one block and submits them.
    /// Refused, keeping every comment, while its agent waits on a prompt.</summary>
    private object SendReview(ReviewPanel panel, string? preamble)
    {
        if (panel.Comments.Count == 0) return new { sent_count = 0, target_surface_id = panel.SourceSurfaceId };
        if (!_terminals.TryGetValue(panel.SourceSurfaceId, out var terminal) || terminal.HasExited)
            throw new ControlException("unavailable", Localizer.Get("ReviewSourceUnavailable"));
        if (terminal.EffectiveStatus?.State == "blocked")
            throw new ControlException("agent_awaiting_approval", Localizer.Get("ReviewAwaitingApproval"));
        var count = panel.Comments.Count;
        terminal.PasteText(ReviewDiff.Serialize(panel.Comments, preamble));
        terminal.SendText("\r");
        panel.ClearComments();
        return new { sent_count = count, target_surface_id = panel.SourceSurfaceId };
    }

    /// <summary>Refreshes the reviews of a terminal whose agent just stopped working.</summary>
    private void RefreshReviewsAfterTurn(string surfaceId)
    {
        var reviews = _panels.Values.OfType<ReviewPanel>().Where(panel => panel.SourceSurfaceId == surfaceId).ToList();
        if (reviews.Count == 0) return;
        var state = _terminals.GetValueOrDefault(surfaceId)?.EffectiveStatus?.State;
        var previous = _reviewedStates.GetValueOrDefault(surfaceId);
        _reviewedStates[surfaceId] = state;
        if (previous == "working" && state != "working")
            foreach (var review in reviews) _ = review.RefreshAsync();
    }

    /// <summary>The palette's Review changes: the focused terminal's uncommitted changes beside it.</summary>
    private async Task OpenReviewFromUiAsync()
    {
        if (ActiveTerminal() is not { } terminal) return;
        var directory = terminal.WorkingDirectory;
        try
        {
            var snapshot = await Task.Run(() => ReviewDiff.Snapshot(directory ?? throw new ReviewDiff.ReviewException("unavailable", Localizer.Get("ReviewNotGit")), "uncommitted", null));
            SplitPanel(default, CreateReviewPanel(terminal.SurfaceId, "uncommitted", null, snapshot), focus: true);
        }
        catch (ReviewDiff.ReviewException error)
        {
            await ShowErrorAsync(Localizer.Get("ReviewError"), error.Message);
        }
    }

    private Dictionary<string, SessionReview> SavedReviews() =>
        _panels.Where(item => item.Value is ReviewPanel).ToDictionary(item => item.Key, item =>
        {
            var review = (ReviewPanel)item.Value;
            return new SessionReview(review.SourceSurfaceId, review.Mode, review.BaseBranch);
        }, StringComparer.Ordinal).Concat(_restoreReviews).ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
}
