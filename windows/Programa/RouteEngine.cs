using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;

namespace Programa;

/// <summary>Event routes at run time, as on macOS (docs/programa-json.md#routes): each event goes
/// through every route's topic, `when`, key, debounce, throttle and busy gate, then its action. Routes
/// load from the global programa.json only and install again when its content changes. Everything
/// here runs on the UI thread; `run` commands run on worker threads, at most 4 at once.</summary>
internal static class RouteEngine
{
    private sealed class Installed(RouteDefinition definition)
    {
        internal RouteDefinition Definition { get; } = definition;
        internal int Matched, Fired, Throttled, Busy, Expired;
        internal string? LastError;
        /// <summary>The route's last action still runs (a run, a delivery, a prompt's turn).</summary>
        internal bool Held;
        internal readonly Dictionary<string, Gate> Gates = new(StringComparer.Ordinal);
    }

    private sealed class Gate
    {
        internal DateTimeOffset? WindowStart;
        internal DispatcherQueueTimer? Debounce;
        internal RouteEvent? Pending;
    }

    private static readonly TimeSpan TextWait = TimeSpan.FromSeconds(600);
    private static readonly SemaphoreSlim RunSlots = new(4);
    private static readonly HashSet<string> PromptTurns = new(StringComparer.Ordinal);
    private static List<Installed> _routes = [];
    private static List<RouteIssue> _issues = [];
    private static string? _installed;
    private static int _generation;
    private static DispatcherQueue? _dispatcher;

    internal static string FilePath => Path.Combine(Path.GetDirectoryName(ShortcutSettings.SettingsPath)!, "programa.json");

    internal static bool HasRoutes => _routes.Count > 0;

    internal static void Start(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        Install(startup: true);
    }

    /// <summary>The global file changed on disk: installs the routes again when its content changed
    /// (comments and formatting alone do not count).</summary>
    internal static void Reload() => Install(startup: false);

    private static void Install(bool startup)
    {
        JsonNode? root = null;
        var issues = new List<RouteIssue>();
        try
        {
            if (File.Exists(FilePath))
                root = JsonNode.Parse(File.ReadAllText(FilePath), null, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            issues.Add(new(null, null, $"programa.json could not be read: {error.Message}"));
        }
        var content = root?.ToJsonString() ?? issues.FirstOrDefault()?.Message;
        if (!startup && content == _installed) return;
        _installed = content;
        var (routes, routeIssues) = root is JsonObject file ? Routes.Parse(file["routes"]) : (new List<RouteDefinition>(), new List<RouteIssue>());
        issues.AddRange(routeIssues);
        // Installing again resets every counter and window, and drops deliveries still waiting.
        _generation++;
        foreach (var gate in _routes.SelectMany(route => route.Gates.Values)) gate.Debounce?.Stop();
        PromptTurns.Clear();
        _routes = routes.Select(route => new Installed(route)).ToList();
        _issues = issues;
        if (issues.Count > 0)
        {
            var first = issues[0];
            var body = $"{first.Name ?? (first.Index is { } index ? $"#{index + 1}" : "routes")}: {first.Message}";
            if (issues.Count > 1) body += " " + string.Format(Localizer.Get("RoutesMoreIssues"), issues.Count - 1);
            WindowRegistry.Notifications.ShowAppToast(Localizer.Get("RoutesNotLoaded"), body);
        }
    }

    /// <summary>`routes.list`: the routes in use with their counters, and the ones that did not load.</summary>
    internal static object List() => new
    {
        source = "file",
        routes = _routes.Select(route => new
        {
            name = route.Definition.Name, on = route.Definition.On, action = route.Definition.Action.Kind,
            matched = route.Matched, fired = route.Fired, throttled = route.Throttled, busy = route.Busy, expired = route.Expired, last_error = route.LastError,
        }),
        issues = _issues.Select(issue => new { index = issue.Index, name = issue.Name, message = issue.Message }),
    };

    /// <summary>Offers an event to every route. Returns whether a notify route matched it (topic and
    /// when) and whether one fired for it now, which decide the built-in needs_input banner.</summary>
    internal static (bool NotifyMatched, bool NotifyFired) Fire(RouteEvent routeEvent)
    {
        bool notifyMatched = false, notifyFired = false;
        if (_routes.Count == 0) return (false, false);
        var budget = Stopwatch.StartNew();
        foreach (var route in _routes.ToList())
        {
            var definition = route.Definition;
            if (!Routes.TopicMatches(definition.Levels, routeEvent.Topic)) continue;
            if (!Routes.Holds(definition, routeEvent.Fields, budget, out var error))
            {
                if (error is not null) route.LastError = error;
                continue;
            }
            route.Matched++;
            if (definition.Action is NotifyAction) notifyMatched = true;
            // Any text in a terminal can claim a state; run and review act only on reports Programa trusts.
            if (definition.Action is RunAction or ReviewAction && !routeEvent.Trusted)
            {
                route.LastError = $"refused: the agent state came from {Reporter(routeEvent.Source)}, which run and review routes do not trust";
                continue;
            }
            if (IsPrompt(definition) && routeEvent.SurfaceId is { } held && PromptTurns.Contains(held))
            {
                route.Busy++;
                continue;
            }
            var key = Routes.Render(definition.Key, routeEvent.Fields, keepMissing: true);
            if (!route.Gates.TryGetValue(key, out var gate)) route.Gates[key] = gate = new Gate();
            if (definition.DebounceMs > 0)
            {
                // The newest event of a burst goes on once the burst is over.
                gate.Pending = routeEvent;
                if (gate.Debounce is null)
                {
                    gate.Debounce = _dispatcher!.CreateTimer();
                    gate.Debounce.IsRepeating = false;
                    var generation = _generation;
                    gate.Debounce.Tick += (_, _) =>
                    {
                        if (generation == _generation && gate.Pending is { } pending) Pass(route, gate, pending);
                        gate.Pending = null;
                    };
                }
                gate.Debounce.Interval = TimeSpan.FromMilliseconds(definition.DebounceMs);
                gate.Debounce.Stop();
                gate.Debounce.Start();
                continue;
            }
            if (Pass(route, gate, routeEvent) && definition.Action is NotifyAction) notifyFired = true;
        }
        return (notifyMatched, notifyFired);
    }

    private static string Reporter(string? source) => source switch
    {
        "program" => "an unsigned status report (OSC 7501)",
        "inferred" => "screen detection",
        null => "a clear no hook reported",
        _ => source,
    };

    private static bool IsPrompt(RouteDefinition definition) => definition.Action is TextAction { Kind: "prompt" };

    /// <summary>The throttle, then the busy check, then the action.</summary>
    private static bool Pass(Installed route, Gate gate, RouteEvent routeEvent)
    {
        var now = DateTimeOffset.Now;
        if (route.Definition.ThrottleMs > 0)
        {
            if (gate.WindowStart is { } start && now - start < TimeSpan.FromMilliseconds(route.Definition.ThrottleMs))
            {
                route.Throttled++;
                return false;
            }
            gate.WindowStart = now;
        }
        if (route.Held || (IsPrompt(route.Definition) && routeEvent.SurfaceId is { } surface && PromptTurns.Contains(surface)))
        {
            route.Busy++;
            return false;
        }
        route.Fired++;
        switch (route.Definition.Action)
        {
            case NotifyAction notify: Notify(routeEvent, notify); break;
            case ReviewAction review: Review(route, routeEvent, review); break;
            case RunAction run: Run(route, routeEvent, run); break;
            case TextAction text: _ = DeliverAsync(route, routeEvent, text); break;
        }
        return true;
    }

    // ---- notify

    private static void Notify(RouteEvent routeEvent, NotifyAction notify)
    {
        var title = Routes.Render(notify.Title, routeEvent.Fields);
        var body = string.Join(" — ", new[] { notify.Subtitle, notify.Body }.OfType<string>().Select(text => Routes.Render(text, routeEvent.Fields)).Where(text => text.Length > 0));
        var window = (routeEvent.SurfaceId is { } surface ? WindowRegistry.OwnerOfSurface(surface) : null)
            ?? (routeEvent.WorkspaceId is { } workspace ? WindowRegistry.OwnerOfWorkspace(workspace) : null);
        if (window is null || !window.PostRouteNotification(routeEvent.WorkspaceId!, routeEvent.SurfaceId, title, body))
            WindowRegistry.Notifications.ShowAppToast(title, body);
    }

    // ---- review

    private static void Review(Installed route, RouteEvent routeEvent, ReviewAction review)
    {
        if (routeEvent.WorkspaceId is null || WindowRegistry.OwnerOfWorkspace(routeEvent.WorkspaceId) is not { } window)
        {
            route.LastError = "review: the event names no workspace";
            return;
        }
        _ = OpenReviewAsync(route, window, routeEvent, review);
    }

    private static async Task OpenReviewAsync(Installed route, MainWindow window, RouteEvent routeEvent, ReviewAction review)
    {
        try { await window.OpenReviewForRoute(routeEvent.WorkspaceId!, routeEvent.SurfaceId, review.Mode, review.BaseBranch); }
        catch (ControlException error) { route.LastError = $"review: {error.Code}: {error.Message}"; }
    }

    // ---- run

    private static void Run(Installed route, RouteEvent routeEvent, RunAction run)
    {
        if (!routeEvent.Fields.TryGetValue("cwd", out var directory) || !Directory.Exists(directory))
        {
            Failed(route, "could not start: the surface's working directory is unknown or does not exist", null);
            return;
        }
        route.Held = true;
        var generation = _generation;
        var environment = routeEvent.Fields.ToDictionary(field => Routes.EnvironmentName(field.Key), field => field.Value);
        _ = Task.Run(async () =>
        {
            string? error = null, output = null;
            var timeout = TimeSpan.FromMilliseconds(run.TimeoutMs);
            var clock = Stopwatch.StartNew();
            if (!await RunSlots.WaitAsync(timeout)) error = $"never started: no run slot was free within {Seconds(run.TimeoutMs)}";
            else
            {
                try
                {
                    if (generation != _generation) error = "never started: the routes changed while it waited for a run slot";
                    else (error, output) = await RunCommandAsync(run.Command, directory, environment, timeout - clock.Elapsed, run.TimeoutMs);
                }
                finally { RunSlots.Release(); }
            }
            _dispatcher!.TryEnqueue(() =>
            {
                route.Held = false;
                if (error is not null && generation == _generation) Failed(route, error, output);
            });
        });
    }

    private static async Task<(string? Error, string? Output)> RunCommandAsync(string command, string directory, Dictionary<string, string> environment, TimeSpan left, long timeoutMs)
    {
        var shell = FindOnPath("pwsh.exe") ?? Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(shell) { WorkingDirectory = directory, CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
        foreach (var argument in new[] { "-NoLogo", "-NonInteractive", "-Command", command }) start.ArgumentList.Add(argument);
        foreach (var (name, value) in environment) start.Environment[name] = value;
        Process process;
        try { process = Process.Start(start)!; }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { return ($"could not start: {error.Message}", null); }
        using (process)
        {
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            using var cancel = new CancellationTokenSource(left > TimeSpan.Zero ? left : TimeSpan.Zero);
            try { await process.WaitForExitAsync(cancel.Token); }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                return ($"timed out after {Seconds(timeoutMs)}", null);
            }
            if (process.ExitCode == 0) return (null, null);
            var output = (await stdout) + (await stderr);
            return ($"exited with status {process.ExitCode}", output.Length > 600 ? output[^600..] : output);
        }
    }

    private static string Seconds(long milliseconds) => milliseconds % 1000 == 0 ? $"{milliseconds / 1000} s" : $"{milliseconds} ms";

    private static void Failed(Installed route, string error, string? output)
    {
        route.LastError = error;
        WindowRegistry.Notifications.ShowAppToast(string.Format(Localizer.Get("RouteFailed"), route.Definition.Name), output is { Length: > 0 } ? output.Trim() : error);
    }

    private static string? FindOnPath(string name) =>
        (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Select(directory => { try { return Path.Combine(directory.Trim('"'), name); } catch (ArgumentException) { return null; } })
            .FirstOrDefault(path => path is not null && File.Exists(path));

    // ---- send and prompt

    /// <summary>Why text may not go to this agent now, or null (docs/programa-json.md, send and prompt).</summary>
    internal static string? Refusal(TerminalView terminal, RouteEvent routeEvent)
    {
        if (terminal.RouteState is null && terminal.AgentState.State is null) return "refused: the surface has no agent; nothing was sent";
        if (terminal.AgentState.State == "blocked" || terminal.RouteState == "blocked")
            return $"refused: a {terminal.HookStatus?.Kind ?? terminal.ProgramStatus?.Kind ?? "permission"} prompt is showing; nothing was sent";
        if (terminal.HasDraft) return "refused: the surface has unsent typed input; nothing was sent";
        if (!terminal.RoutesFromHooks || terminal.RouteWriter is null) return "refused: the agent's state reports name no session; nothing was sent";
        if (terminal.StoppedForInput) return "refused: waiting for the agent to resume after it stopped for input";
        if (!routeEvent.SessionNamed) return "refused: the report that fired this route names no session; nothing was sent";
        if (routeEvent.First) return "refused: the report that fired this route is the first from this agent; nothing was sent";
        return null;
    }

    private static TerminalView? Terminal(string? surfaceId) =>
        surfaceId is null ? null : WindowRegistry.Windows.Select(window => window.TerminalById(surfaceId)).FirstOrDefault(terminal => terminal is not null);

    private static async Task DeliverAsync(Installed route, RouteEvent routeEvent, TextAction action)
    {
        var generation = _generation;
        if (Terminal(routeEvent.SurfaceId) is not { } terminal)
        {
            route.LastError = "the event's surface is gone";
            return;
        }
        if (Refusal(terminal, routeEvent) is { } refused)
        {
            route.LastError = refused;
            return;
        }
        route.Held = true;
        try
        {
            if (!action.Steer && terminal.RouteState == "working")
            {
                // queue: the text waits for the end of that work, an idle after working from the same writer.
                var writer = terminal.RouteWriter;
                var outcome = await WaitAsync(terminal, transition => transition.State is null ? false : transition.State == "idle" && transition.Previous == "working" && terminal.RouteWriter == writer ? true : null, TextWait);
                if (generation != _generation) return;
                if (outcome is null)
                {
                    route.Expired++;
                    return;
                }
                if (outcome == false || Terminal(routeEvent.SurfaceId) is null)
                {
                    route.LastError = "the agent stopped before the text was delivered";
                    return;
                }
                if (Refusal(terminal, routeEvent) is { } later)
                {
                    route.LastError = later;
                    return;
                }
            }
            var text = Routes.Render(action.Text, routeEvent.Fields);
            if (action.Kind == "send")
            {
                terminal.PasteText(text);
                return;
            }
            if (PromptTurns.Contains(terminal.SurfaceId))
            {
                route.Busy++;
                return;
            }
            var stale = terminal.RouteState is "working" or "blocked" && DateTimeOffset.Now - terminal.RouteStateAt > TimeSpan.FromMinutes(10);
            terminal.PasteText(text);
            if (terminal.RouteState is null or "blocked" || stale)
            {
                route.LastError = "pasted without submitting: no agent ready for a prompt";
                return;
            }
            terminal.SendText("\r");
            // A submitted prompt holds its route and the surface for its turn: idle after working, or a clear.
            PromptTurns.Add(terminal.SurfaceId);
            var sawWorking = false;
            await WaitAsync(terminal, transition =>
            {
                if (transition.State is null) return false;
                if (transition.State == "working") sawWorking = true;
                return transition.State == "idle" && sawWorking ? true : null;
            }, TextWait);
            if (generation == _generation) PromptTurns.Remove(terminal.SurfaceId);
        }
        finally { route.Held = false; }
    }

    /// <summary>Waits for a routes-view transition the decider answers (true or false); null on timeout.</summary>
    private static async Task<bool?> WaitAsync(TerminalView terminal, Func<TerminalView.RouteTransition, bool?> decide, TimeSpan timeout)
    {
        var done = new TaskCompletionSource<bool?>(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnTransition(TerminalView _, TerminalView.RouteTransition transition)
        {
            if (decide(transition) is { } answer) done.TrySetResult(answer);
        }
        terminal.RouteStateChanged += OnTransition;
        try { return await Task.WhenAny(done.Task, Task.Delay(timeout)) == done.Task ? done.Task.Result : null; }
        finally { terminal.RouteStateChanged -= OnTransition; }
    }
}
