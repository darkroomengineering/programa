using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>Each sidebar row's pull request line ("PR #12 open"), as on macOS: the focused
/// terminal's branch looked up with `gh`, refreshed every 30 seconds and when the branch changes.</summary>
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

    private (string Directory, string Branch)? PullRequestKey(WorkspaceSnapshot workspace)
    {
        var focusedId = workspace.SelectedPane?.SelectedSurfaceId;
        if (focusedId is null || _branches.GetValueOrDefault(focusedId) is not { } branch) return null;
        // A detached HEAD shows as a short commit, which has no pull request.
        if (Regex.IsMatch(branch, "^[0-9a-f]{7}$")) return null;
        return _terminals.GetValueOrDefault(focusedId)?.Cwd is { } cwd ? (cwd, branch) : null;
    }

    /// <summary>Starts a lookup for the workspace's branch unless one is running; without
    /// <paramref name="refresh"/>, only when that branch has never been looked up.</summary>
    private void LookUpPullRequest(WorkspaceSnapshot workspace, bool refresh)
    {
        if (!PullRequests.Available || PullRequestKey(workspace) is not { } key) return;
        if (!refresh && _pullRequests.ContainsKey(key)) return;
        if (!_pullRequestLookups.Add(key)) return;
        _ = Task.Run(async () =>
        {
            var pullRequest = await PullRequests.LookupAsync(key.Directory, key.Branch);
            DispatcherQueue.TryEnqueue(() =>
            {
                _pullRequestLookups.Remove(key);
                var changed = !_pullRequests.TryGetValue(key, out var previous) || previous != pullRequest;
                _pullRequests[key] = pullRequest;
                if (!changed) return;
                foreach (var item in _snapshot.Workspaces.Where(item => PullRequestKey(item) == key)) UpdateSidebarRow(item.Id);
            });
        });
    }

    private void UpdatePullRequestLine(WorkspaceSnapshot workspace, HyperlinkButton link)
    {
        var pullRequest = PullRequestFor(workspace);
        if (pullRequest is null)
        {
            link.Visibility = Visibility.Collapsed;
            return;
        }
        var state = Localizer.Get(pullRequest.State switch { "open" => "PullRequestOpen", "merged" => "PullRequestMerged", _ => "PullRequestClosed" });
        ((TextBlock)link.Content).Text = $"{pullRequest.Label} #{pullRequest.Number} {state}";
        link.NavigateUri = new Uri(pullRequest.Url);
        ToolTipService.SetToolTip(link, pullRequest.Url);
        link.Visibility = Visibility.Visible;
    }
}
