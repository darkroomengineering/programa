using System.Text.RegularExpressions;

namespace Programa;

/// <summary>Each sidebar row's pull requests ("PR #12 open"), as on macOS: every terminal's branch
/// looked up with `gh`, refreshed every 30 seconds and when a branch changes, plus any a shell reported.</summary>
public sealed partial class MainWindow
{
    /// <summary>Lookups by directory and branch; a null value means no pull request.</summary>
    private readonly Dictionary<(string Directory, string Branch), PullRequestInfo?> _pullRequests = [];
    private readonly HashSet<(string, string)> _pullRequestLookups = [];

    private void StartPullRequestPolling()
    {
        if (!PullRequests.Available) return;
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(30);
        timer.Tick += (_, _) => { foreach (var workspace in _snapshot.Workspaces) LookUpPullRequest(workspace, refresh: true); };
        timer.Start();
        Closed += (_, _) => timer.Stop();
    }

    /// <summary>The focused terminal's lookup key (workspace.sidebar_state's pull request).</summary>
    private (string Directory, string Branch)? PullRequestKey(WorkspaceSnapshot workspace) =>
        workspace.SelectedPane?.SelectedSurfaceId is { } focused ? PullRequestKey(focused) : null;

    private (string Directory, string Branch)? PullRequestKey(string surfaceId)
    {
        if (_branches.GetValueOrDefault(surfaceId) is not { } branch) return null;
        // A detached HEAD shows as a short commit, which has no pull request.
        if (Regex.IsMatch(branch, "^[0-9a-f]{7}$")) return null;
        return _terminals.GetValueOrDefault(surfaceId)?.Cwd is { } cwd ? (cwd, branch) : null;
    }

    /// <summary>Starts a lookup for each of the workspace's branches unless one is running; without
    /// <paramref name="refresh"/>, only for a branch never looked up.</summary>
    private void LookUpPullRequest(WorkspaceSnapshot workspace, bool refresh)
    {
        if (!PullRequests.Available) return;
        foreach (var surface in workspace.Panes.SelectMany(pane => pane.Surfaces))
        {
            if (PullRequestKey(surface.Id) is not { } key) continue;
            if (!refresh && _pullRequests.ContainsKey(key)) continue;
            if (!_pullRequestLookups.Add(key)) continue;
            _ = Task.Run(async () =>
            {
                var pullRequest = await PullRequests.LookupAsync(key.Directory, key.Branch);
                DispatcherQueue.TryEnqueue(() =>
                {
                    _pullRequestLookups.Remove(key);
                    var changed = !_pullRequests.TryGetValue(key, out var previous) || previous != pullRequest;
                    _pullRequests[key] = pullRequest;
                    if (!changed) return;
                    foreach (var item in _snapshot.Workspaces.Where(item => item.Panes.SelectMany(pane => pane.Surfaces).Any(surface => PullRequestKey(surface.Id) == key)))
                        UpdateSidebarRow(item.Id);
                });
            });
        }
    }

    /// <summary>Each tab's pull request in tab order, once each: one its shell reported (when it is for
    /// the tab's branch), else the one looked up for its branch.</summary>
    private List<ReportedPullRequest> WorkspacePullRequests(IEnumerable<string> surfaceIds)
    {
        var found = new List<ReportedPullRequest>();
        foreach (var surfaceId in surfaceIds)
        {
            var branch = _branches.GetValueOrDefault(surfaceId);
            if (_reportedPullRequests.TryGetValue(surfaceId, out var reported) && (reported.Branch is null || reported.Branch == branch)) found.Add(reported);
            else if (PullRequestKey(surfaceId) is { } key && _pullRequests.GetValueOrDefault(key) is { } looked)
                found.Add(new ReportedPullRequest(looked.Number, "PR", looked.Url, looked.State, key.Branch, null));
        }
        return found.DistinctBy(pullRequest => (pullRequest.Label.ToLowerInvariant(), pullRequest.Number, pullRequest.Url)).ToList();
    }
}
