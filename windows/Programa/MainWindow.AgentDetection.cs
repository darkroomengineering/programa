namespace Programa;

/// <summary>Agent status for agents that report nothing themselves (Codex, OpenCode, Gemini CLI,
/// Copilot CLI, Cursor Agent, Aider, older Claude Code), read off the screen every 2 seconds with the
/// macOS manifests. A program's own OSC 7501 report or a hook report always wins. Unlike macOS, the
/// shell's process tree says when the agent has exited: a shell with no child is at its prompt.</summary>
public sealed partial class MainWindow
{
    private IReadOnlyList<AgentManifest> _manifests = [];
    /// <summary>The agent recognized in each terminal until its shell is back at a prompt.</summary>
    private readonly Dictionary<string, AgentManifest> _detectedAgents = new(StringComparer.Ordinal);

    private void StartAgentDetection()
    {
        _manifests = AgentDetection.Load(Path.Combine(AppContext.BaseDirectory, "AgentDetection"), AgentDetection.UserFolder);
        if (_manifests.Count == 0) return;
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.Tick += (_, _) => DetectAgents();
        timer.Start();
        Closed += (_, _) => timer.Stop();
    }

    private void DetectAgents()
    {
        foreach (var closed in _detectedAgents.Keys.Where(id => !_terminals.ContainsKey(id)).ToList()) _detectedAgents.Remove(closed);
        var shells = _terminals.Values.Select(terminal => terminal.ShellPid).Where(pid => pid != 0).ToHashSet();
        var busy = ProcessTree.ChildrenOf(shells).Keys.ToHashSet();
        foreach (var terminal in _terminals.Values.ToList())
        {
            var reported = terminal.ProgramStatus is not null || terminal.HookStatus is not null;
            if (reported || !busy.Contains(terminal.ShellPid))
            {
                if (_detectedAgents.Remove(terminal.SurfaceId)) terminal.ReportDetectedState(null, null);
                continue;
            }
            // The last 40 lines are enough for every manifest's anchors and recognition.
            var text = terminal.OutputText(40);
            if (!_detectedAgents.TryGetValue(terminal.SurfaceId, out var manifest))
            {
                if (AgentDetection.Recognize(_manifests, text) is not { } recognized) continue;
                _detectedAgents[terminal.SurfaceId] = manifest = recognized;
            }
            // No matching pattern keeps the last state, as a spinner frame or redraw can miss every pattern.
            if (manifest.Classify(text) is { } state) terminal.ReportDetectedState(state, manifest.Agent);
        }
    }
}
