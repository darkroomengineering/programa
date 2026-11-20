using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Programa;

/// <summary>Agent automation over the socket, as on macOS (docs/socket-api.md): `surface.wait` blocks
/// one request until a surface meets a condition, `agent.prompt` submits a prompt and waits for the
/// agent to finish, and `agent.needs_input` reports an agent waiting on the person. Waits run as async
/// loops on the UI thread, checking every 100 ms and catching state changes as they happen, so they
/// hold their request, not a thread.</summary>
public sealed partial class MainWindow
{
    private static readonly string[] AgentStates = ["idle", "working", "blocked", "any_change"];
    private static readonly string[] ProgramStates = ["idle", "working", "done", "blocked", "error", "cleared", "any_change"];

    private async Task<object?> WaitFromControlAsync(JsonElement p)
    {
        var (workspace, _, surfaceId) = SurfaceTarget(p);
        var terminal = TerminalFor(workspace.Id, surfaceId);
        terminal.EnsureStarted();
        var given = new[] { "pattern", "exit", "agent_state", "program_state" }
            .Where(name => p.TryGetProperty(name, out var value) && value.ValueKind is not (JsonValueKind.Null or JsonValueKind.False))
            .ToList();
        if (given.Count != 1) throw new ControlException("invalid_params", "Exactly one of pattern, exit, agent_state or program_state is required.");
        var condition = given[0];
        var timeout = TimeoutMs(p, 30_000);
        var lines = Math.Clamp(Number(p, "lines") ?? 2000, 1, 100_000);
        Regex? regex = null;
        var wanted = condition switch { "agent_state" => Text(p, "agent_state"), "program_state" => Text(p, "program_state"), _ => null };
        if (condition == "pattern")
        {
            try { regex = new Regex(Required(p, "pattern"), RegexOptions.Multiline, TimeSpan.FromSeconds(1)); }
            catch (ArgumentException error) { throw new ControlException("invalid_params", $"pattern is not a valid regex: {error.Message}"); }
        }
        if (condition == "agent_state" && !AgentStates.Contains(wanted)) throw new ControlException("invalid_params", "agent_state must be idle, working, blocked or any_change.");
        if (condition == "program_state" && !ProgramStates.Contains(wanted)) throw new ControlException("invalid_params", "program_state must be idle, working, done, blocked, error, cleared or any_change.");

        // Transitions are caught as they happen, so none falls between two checks.
        var (agentAtStart, _) = terminal.AgentState;
        var programAtStart = terminal.ProgramStatus?.State;
        bool agentChanged = false, programChanged = false, exited = false;
        void OnChange(TerminalView view)
        {
            agentChanged |= view.AgentState.State != agentAtStart;
            programChanged |= view.ProgramStatus?.State != programAtStart;
        }
        void OnExit(string _) => exited = true;
        terminal.AgentStateChanged += OnChange;
        terminal.Exited += OnExit;
        try
        {
            var clock = Stopwatch.StartNew();
            for (var first = true; ; first = false)
            {
                var result = new Dictionary<string, object?> { ["workspace_id"] = terminal.WorkspaceId, ["surface_id"] = surfaceId, ["window_id"] = WindowId, ["condition"] = condition, ["waited"] = !first };
                var (state, source) = terminal.AgentState;
                var program = terminal.ProgramStatus?.State;
                switch (condition)
                {
                    case "pattern" when regex!.Match(terminal.OutputText(lines)) is { Success: true } match:
                        result["match"] = match.Value;
                        return result;
                    case "exit" when exited || terminal.HasExited:
                        return result;
                    case "agent_state" when wanted switch { "any_change" => agentChanged, "idle" => state is null or "idle", _ => state == wanted }:
                        result["state"] = state;
                        result["source"] = source;
                        return result;
                    case "program_state" when wanted switch { "any_change" => programChanged, "cleared" => program is null, _ => program == wanted }:
                        result["program_state"] = program;
                        return result;
                }
                if (!WindowRegistry.Windows.Any(window => window.OwnsSurface(surfaceId)))
                {
                    result["outcome"] = "closed";
                    return result;
                }
                if (clock.ElapsedMilliseconds >= timeout) throw new ControlException("timeout", $"The condition was not met within {timeout} ms.", new { timeout_ms = timeout });
                await Task.Delay(100);
            }
        }
        finally
        {
            terminal.AgentStateChanged -= OnChange;
            terminal.Exited -= OnExit;
        }
    }

    /// <summary>`agent.prompt`: A. refuse at an approval prompt (unless answer_prompt); 0. hold while a
    /// person drafts (unless force), then let their turn finish; 1. send the text and Return; 2. wait
    /// up to working_grace_ms for working; 3. wait for idle on the rest of timeout_ms.</summary>
    private async Task<object?> PromptFromControlAsync(JsonElement p)
    {
        var (workspace, _, surfaceId) = SurfaceTarget(p);
        var terminal = TerminalFor(workspace.Id, surfaceId);
        terminal.EnsureStarted();
        var text = Required(p, "text").TrimEnd();
        if (text.Length == 0) throw new ControlException("invalid_params", "text is empty.");
        var timeout = TimeoutMs(p, 120_000);
        var grace = Math.Max(0, Number(p, "working_grace_ms") ?? 3000);
        var force = Flag(p, "force");
        var answerPrompt = Flag(p, "answer_prompt");
        var clock = Stopwatch.StartNew();
        long Remaining() => Math.Max(0, timeout - clock.ElapsedMilliseconds);
        var sawState = terminal.AgentState.State is not null;
        var wentWorking = false;
        void OnChange(TerminalView view)
        {
            sawState |= view.AgentState.State is not null;
            wentWorking |= view.AgentState.State == "working";
        }
        bool Closed() => !WindowRegistry.Windows.Any(window => window.OwnsSurface(surfaceId));
        void RefuseAtApproval()
        {
            if (!answerPrompt && terminal.AgentState.State == "blocked")
                throw new ControlException("agent_awaiting_approval", "The agent is waiting on an approval or sign-in prompt; answer it in its pane first, or pass answer_prompt.", new { surface_id = surfaceId });
        }
        async Task<bool> Until(Func<bool> done, long milliseconds)
        {
            var until = clock.ElapsedMilliseconds + milliseconds;
            while (!done())
            {
                if (Closed() || clock.ElapsedMilliseconds >= until) return done();
                await Task.Delay(50);
            }
            return true;
        }
        object ClosedResult() => new { workspace_id = terminal.WorkspaceId, surface_id = surfaceId, window_id = WindowId, outcome = "closed" };

        terminal.AgentStateChanged += OnChange;
        try
        {
            RefuseAtApproval();
            long? heldMs = null, settleMs = null;
            while (!force && terminal.HasDraft)
            {
                var holdStarted = clock.ElapsedMilliseconds;
                while (terminal.HasDraft)
                {
                    if (Closed()) return ClosedResult();
                    if (Remaining() == 0)
                        throw new ControlException("draft_in_progress", "A person is typing in this surface; the prompt was not sent.", new { held_ms = (heldMs ?? 0) + clock.ElapsedMilliseconds - holdStarted, timeout_ms = timeout, surface_id = surfaceId });
                    await Task.Delay(100);
                    RefuseAtApproval();
                }
                heldMs = (heldMs ?? 0) + clock.ElapsedMilliseconds - holdStarted;
                // The person's own turn goes first: a working report now belongs to it.
                var settleStarted = clock.ElapsedMilliseconds;
                wentWorking = false;
                if (terminal.AgentState.State == "working" || await Until(() => wentWorking, Math.Min(Math.Min(grace, 1500), Remaining())))
                {
                    if (!await Until(() => terminal.AgentState.State is null or "idle", Remaining()))
                        throw new ControlException("draft_in_progress", "The person's turn did not finish in time; the prompt was not sent.", new { held_ms = heldMs, settle_ms = clock.ElapsedMilliseconds - settleStarted, timeout_ms = timeout, surface_id = surfaceId });
                }
                settleMs = (settleMs ?? 0) + clock.ElapsedMilliseconds - settleStarted;
                RefuseAtApproval();
            }

            var workingBefore = terminal.AgentState.State == "working";
            wentWorking = false;
            terminal.SendText(text + "\r");
            var observed = workingBefore || await Until(() => wentWorking, Math.Min(grace, Remaining()));
            var result = new Dictionary<string, object?> { ["workspace_id"] = terminal.WorkspaceId, ["surface_id"] = surfaceId, ["window_id"] = WindowId };
            if (heldMs is not null) result["held_ms"] = heldMs;
            if (settleMs is not null) result["settle_ms"] = settleMs;
            if (Closed()) return ClosedResult();
            if (!observed)
            {
                result["working_observed"] = false;
                result["final_state"] = terminal.AgentState.State;
                if (!sawState) result["warning"] = "The surface never reported an agent state, so Programa cannot tell when the agent finishes. Its agent may not report status (OSC 7501 or hooks).";
                return result;
            }
            if (!await Until(() => terminal.AgentState.State is null or "idle", Remaining()))
            {
                if (Closed()) return ClosedResult();
                throw new ControlException("timeout", $"The agent started working but did not finish within {timeout} ms.", new { timeout_ms = timeout });
            }
            if (Closed()) return ClosedResult();
            result["working_observed"] = true;
            result["final_state"] = "idle";
            return result;
        }
        finally
        {
            terminal.AgentStateChanged -= OnChange;
        }
    }

    /// <summary>`agent.needs_input`: reports the surface blocked (source hooks) and posts the matching
    /// notification in one call, then tells needs_input subscribers.</summary>
    private object NeedsInputFromControl(JsonElement p)
    {
        var (workspace, _, surfaceId) = SurfaceTarget(p);
        var terminal = TerminalFor(workspace.Id, surfaceId);
        var provider = Text(p, "provider");
        var title = Text(p, "title") ?? provider ?? Localizer.Get("AgentNeedsInputTitle");
        var subtitle = Text(p, "subtitle");
        var body = Text(p, "body");
        var kind = Text(p, "kind") is { } given && given is "permission" or "question" ? given : null;
        terminal.ReportHookState("blocked", provider, Text(p, "session_id"), kind: kind);
        // Routes first: a notify route can stand in for the built-in banner (the entry is still listed).
        var routeBanner = RouteNeedsInput(terminal, p, kind, provider, title, subtitle, body);
        var looking = IsLookingAt(surfaceId);
        _notifications.Post(workspace.Id, surfaceId, title, string.Join(" — ", new[] { subtitle, body }.Where(part => !string.IsNullOrEmpty(part))), toast: !looking && !routeBanner && !ControlServer.BannerClaimed("needs_input"));
        if (looking) _notifications.MarkRead(new HashSet<string>(StringComparer.Ordinal) { surfaceId });
        var frame = new Dictionary<string, object?> { ["event"] = "needs_input", ["workspace_id"] = workspace.Id, ["surface_id"] = surfaceId };
        foreach (var (key, value) in new[] { ("kind", Text(p, "kind")), ("provider", provider), ("title", title), ("subtitle", subtitle), ("body", body) })
            if (!string.IsNullOrEmpty(value)) frame[key] = value;
        frame["ts"] = EventHub.Now;
        EventHub.Publish("needs_input", surfaceId, frame);
        return new { };
    }

    /// <summary>timeout_ms (or timeout), at most an hour.</summary>
    private static int TimeoutMs(JsonElement p, int fallback) =>
        Math.Clamp(Number(p, "timeout_ms") ?? Number(p, "timeout") ?? fallback, 0, 3_600_000);
}
