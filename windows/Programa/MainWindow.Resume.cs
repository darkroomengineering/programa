using System.Text.Json;

namespace Programa;

/// <summary>Resume Agent Session, as on macOS: each terminal remembers the last Claude Code session it
/// ran (saved with the session, since agents do not survive a quit on Windows), and the palette's
/// Resume Agent Session or `programa resume` types its resume command at the shell prompt.</summary>
public sealed partial class MainWindow
{
    /// <summary>Called on each status change: a Claude Code turn that ended names its session, guessed
    /// from Claude's store only when no hook reported it (Claude started without the `claude` function).</summary>
    private void NoteAgentSession(TerminalView terminal)
    {
        if (terminal.EffectiveStatus is not { App: "claude-code", State: not "working" } || terminal.Cwd is not { } cwd) return;
        if (terminal.AgentSessionFromHook) return;
        if (AgentSessions.LatestClaude(cwd) is { } session) terminal.LastAgentSession = session;
    }

    /// <summary>`agent.event`, from the agent hooks and `programa agent-event`: session.started records
    /// the exact session Claude runs in the terminal; session.exited keeps it for resume. Every event
    /// reports its state, as macOS does, and the result names it.</summary>
    private object AgentEventFromControl(JsonElement p)
    {
        var eventType = Text(p, "event_type")?.Trim().ToLowerInvariant() ?? "";
        if (!AgentEventStates.TryGetValue(eventType, out var state))
            throw new ControlException("invalid_params", "Invalid event_type — use: " + string.Join(", ", AgentEventStates.Keys));
        var (workspace, _, surfaceId) = SurfaceTarget(p);
        var terminal = TerminalFor(workspace.Id, surfaceId);
        if (eventType == "session.started" && Text(p, "session_id") is { } id && AgentSessions.IsSessionId(id))
        {
            terminal.LastAgentSession = new AgentSession(Text(p, "provider") ?? "claude", id, terminal.Cwd);
            terminal.AgentSessionFromHook = true;
        }
        // The state the event means (docs/plans/agent-events.md); session.exited clears it. The hooks'
        // provider "claude" is the badge's "claude-code", which their state reports name.
        var provider = Text(p, "provider") is "claude" ? "claude-code" : Text(p, "provider");
        terminal.ReportHookState(state, provider, Text(p, "session_id"), false, false);
        return state is null
            ? new { workspace_id = workspace.Id, surface_id = surfaceId, event_type = eventType }
            : new { workspace_id = workspace.Id, surface_id = surfaceId, event_type = eventType, state, source = "hooks" };
    }

    /// <summary>Each agent event's state, as macOS's AgentEventNormalizer.</summary>
    internal static readonly IReadOnlyDictionary<string, string?> AgentEventStates = new Dictionary<string, string?>(StringComparer.Ordinal)
    {
        ["session.started"] = "idle", ["session.exited"] = null,
        ["turn.started"] = "working", ["turn.completed"] = "idle", ["turn.aborted"] = "idle",
        ["request.opened"] = "blocked", ["request.resolved"] = "working",
        ["user-input.requested"] = "blocked", ["user-input.resolved"] = "working",
        ["item.started"] = "working", ["item.completed"] = "working",
    };

    /// <summary>Whether the terminal's shell runs anything (an agent, a build) instead of sitting at its prompt.</summary>
    private static bool IsBusy(TerminalView terminal) =>
        terminal.ShellPid != 0 && ProcessTree.ChildrenOf(new HashSet<uint> { terminal.ShellPid }).Count > 0;

    /// <summary>`surface.resume_agent`: the recorded (or given) session's resume command, typed and
    /// submitted unless `print`. Refused while something runs in the terminal.</summary>
    private object ResumeAgentFromControl(JsonElement p)
    {
        var (workspace, _, surfaceId) = SurfaceTarget(p);
        var terminal = TerminalFor(workspace.Id, surfaceId);
        AgentSession? session = terminal.LastAgentSession;
        if (Text(p, "session") is { } id)
        {
            if (!AgentSessions.IsSessionId(id)) throw new ControlException("invalid_params", $"'{id}' is not a session id.");
            var provider = Text(p, "provider") ?? (session?.Id == id ? session.Provider : "claude");
            if (provider is not ("claude" or "codex" or "opencode")) throw new ControlException("invalid_params", $"provider '{provider}' is not claude, codex or opencode.");
            session = new AgentSession(provider, id, session?.Id == id ? session.Cwd : null);
        }
        if (session is null) throw new ControlException("not_found", "No agent session was recorded for this terminal.");
        var command = AgentSessions.ResumeCommand(session, terminal.WorkingDirectory);
        if (Flag(p, "print")) return new { command, sent = false };
        if (IsBusy(terminal)) throw new ControlException("unavailable", "Something is still running in this terminal; resume once it is back at its prompt.");
        terminal.SendText(command + "\r");
        return new { command, sent = true };
    }

    private void ResumeAgentFromPalette(TerminalView terminal)
    {
        if (terminal.LastAgentSession is not { } session || IsBusy(terminal)) return;
        terminal.SendText(AgentSessions.ResumeCommand(session, terminal.WorkingDirectory) + "\r");
        terminal.FocusTerminal();
    }
}
