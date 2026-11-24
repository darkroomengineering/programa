using System.Numerics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Win32.SafeHandles;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;
using Windows.UI.ViewManagement;

namespace Programa;

public sealed partial class TerminalView : UserControl, IDisposable
{
    /// <summary>Space between the pane edge and the grid, as the macOS app's terminal card (8pt).</summary>
    private const float Padding = 8f;

    private readonly Grid _root = new();
    private readonly CanvasControl _canvas = new();
    private readonly TextBox _input = new();
    private readonly Border _spawnFailure = new();
    private readonly TextBlock _spawnFailureDetail = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button _retry = new();
    private readonly object _snapshotGate = new();
    private readonly AccessibilitySettings _accessibilitySettings = new();
    private readonly UISettings _uiSettings = new();
    private CanvasTextFormat _normalFormat;
    private CanvasTextFormat _boldFormat;
    private CanvasTextFormat _italicFormat;
    private CanvasTextFormat _boldItalicFormat;
    private TerminalAppearance _appearance;
    /// <summary>1 once this launch started a shell: Ghostty's initial-command is used up.</summary>
    private static int _shellStarted;
    /// <summary>Cell size in DIPs, measured from the font and snapped to whole device pixels.</summary>
    private float _cellWidth = 8f;
    private float _cellHeight = 18f;
    private float _metricsScale;
    private bool _focused;
    private readonly string? _initialDirectory;
    /// <summary>Saved output shown above the first shell, then dropped.</summary>
    private string? _restoreText;
    /// <summary>A command typed into the first shell (CLI --command), then dropped.</summary>
    private string? _initialCommand;
    private readonly IReadOnlyDictionary<string, string>? _extraEnvironment;
    private ulong _cwdGeneration;
    private float _fontSize;
    private readonly Border _findBar = new();
    private readonly TextBox _findBox = new();
    private readonly TextBlock _findStatus = new();
    private NativeTerminal.SafeSessionHandle? _session;
    private RegisteredWaitHandle? _registeredWait;
    private EventWaitHandle? _event;
    private TerminalSnapshot? _snapshot;
    private string _automationValue = string.Empty;
    private bool _resettingInput;
    private bool _composing;
    private bool _disposed;
    private bool _selecting;
    private bool _exitRaised;
    private ulong _paintedGeneration;
    private ulong _programStatusGeneration;
    private DateTimeOffset _lastClick;
    private Point _lastClickPoint;
    private uint _clickCount;
    /// <summary>The button whose press the program received, so its motion and release go there too.</summary>
    private uint? _mouseButton;
    private (nuint Col, nuint Row) _lastMouseCell = (nuint.MaxValue, nuint.MaxValue);
    private bool _suppressContextMenu;
    /// <summary>Wheel travel not yet sent, in 1/120ths of a line, so precision touchpads scroll smoothly.</summary>
    private int _wheelRemainder;

    public TerminalView(string surfaceId, string workspaceId, string? initialDirectory = null, string? restoreText = null, string? initialCommand = null, IReadOnlyDictionary<string, string>? extraEnvironment = null)
    {
        SurfaceId = surfaceId;
        WorkspaceId = workspaceId;
        _initialDirectory = initialDirectory;
        _restoreText = restoreText;
        _initialCommand = initialCommand;
        _extraEnvironment = extraEnvironment;
        IsTabStop = true;
        AutomationProperties.SetName(this, Localizer.Get("TerminalAccessibilityName"));
        _appearance = TerminalAppearance.For(Application.Current.RequestedTheme == ApplicationTheme.Dark);
        _fontSize = _appearance.FontSize;
        _normalFormat = CreateTextFormat(bold: false, italic: false);
        _boldFormat = CreateTextFormat(bold: true, italic: false);
        _italicFormat = CreateTextFormat(bold: false, italic: true);
        _boldItalicFormat = CreateTextFormat(bold: true, italic: true);
        BuildFindBar();
        BuildCopyBadge();

        _canvas.ClearColor = Colors.Transparent;
        _canvas.Draw += DrawTerminal;
        _canvas.SizeChanged += (_, _) => ResizeBackend();
        _canvas.PointerPressed += PointerPressed;
        _canvas.PointerMoved += PointerMoved;
        _canvas.PointerReleased += PointerReleased;
        _canvas.PointerWheelChanged += PointerWheelChanged;
        _canvas.ContextFlyout = BuildContextMenu();
        // A right click the program received as a mouse report must not also open the menu.
        _canvas.ContextRequested += (_, args) =>
        {
            args.Handled = _suppressContextMenu;
            _suppressContextMenu = false;
        };
        _root.Children.Add(_canvas);

        _input.Opacity = 0.01;
        _input.Width = 1;
        _input.Height = 1;
        _input.HorizontalAlignment = HorizontalAlignment.Left;
        _input.VerticalAlignment = VerticalAlignment.Top;
        _input.IsSpellCheckEnabled = false;
        _input.IsTextPredictionEnabled = false;
        _input.FontFamily = new FontFamily(_appearance.FontFamily);
        _input.FontSize = _appearance.FontSize;
        _input.Padding = new Thickness(0);
        _input.BorderThickness = new Thickness(0);
        _input.Background = new SolidColorBrush(Colors.Transparent);
        _input.DesiredCandidateWindowAlignment = CandidateWindowAlignment.Default;
        AutomationProperties.SetName(_input, Localizer.Get("TerminalAccessibilityName"));
        _input.TextChanged += InputChanged;
        _input.TextCompositionStarted += InputCompositionStarted;
        _input.TextCompositionChanged += InputCompositionChanged;
        _input.TextCompositionEnded += InputCompositionEnded;
        _input.KeyDown += InputKeyDown;
        _input.GotFocus += (_, _) => SetFocused(true);
        _input.LostFocus += (_, _) => SetFocused(false);
        _root.Children.Add(_input);

        _retry.Content = Localizer.Get("TerminalRetry");
        _retry.Click += (_, _) => StartSession();
        var failureStack = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center };
        failureStack.Children.Add(new TextBlock { Text = Localizer.Get("TerminalSpawnFailed"), FontWeight = FontWeights.SemiBold });
        failureStack.Children.Add(_spawnFailureDetail);
        failureStack.Children.Add(_retry);
        _spawnFailure.Child = failureStack;
        _spawnFailure.HorizontalAlignment = HorizontalAlignment.Center;
        _spawnFailure.VerticalAlignment = VerticalAlignment.Center;
        _spawnFailure.Padding = new Thickness(24);
        _spawnFailure.Visibility = Visibility.Collapsed;
        _root.Children.Add(_spawnFailure);

        Content = _root;
        Loaded += (_, _) =>
        {
            var session = _session;
            // The window's app.appearance can differ from the app mode the terminal was built with.
            ApplyAppearance(reloadFont: false);
            if (session is null) StartSession();
            else Refresh(session);
            // A terminal shown again after a tab switch repaints from its last snapshot.
            _canvas.Invalidate();
        };
        // A "light:A,dark:B" theme follows the window's mode, like macOS appearance.
        ActualThemeChanged += (_, _) => ApplyAppearance(reloadFont: false);
    }

    /// <summary>Settings changed the terminal theme or font: picks them up, keeping this terminal's zoom.</summary>
    internal void ReloadAppearance() => ApplyAppearance(reloadFont: true);

    private void ApplyAppearance(bool reloadFont)
    {
        var zoom = FontSizeOverride;
        var appearance = TerminalAppearance.For(ActualTheme != ElementTheme.Light);
        if (!reloadFont && appearance == _appearance) return;
        _appearance = appearance;
        if (_session is { } session) NativeTerminal.SetColors(session, JsonSerializer.SerializeToUtf8Bytes(_appearance.CoreColors));
        if (reloadFont)
        {
            _input.FontFamily = new FontFamily(_appearance.FontFamily);
            SetFontSize(zoom ?? _appearance.FontSize, force: true);
        }
        if (_composing) ShowCompositionProxy();
        _canvas.Invalidate();
    }

    private void SetFocused(bool focused)
    {
        _focused = focused;
        if (_session is { } session) NativeTerminal.Focus(session, focused);
        _canvas.Invalidate();
    }

    public string SurfaceId { get; }

    /// <summary>The workspace this terminal opened in; exported to the shell as PROGRAMA_WORKSPACE_ID.</summary>
    public string WorkspaceId { get; internal set; }

    /// <summary>The working directory the shell last reported, or null before its first prompt.</summary>
    internal string? Cwd { get; private set; }

    /// <summary>Where the shell is: its last report, or the directory it started in.</summary>
    internal string? WorkingDirectory => Cwd ?? _initialDirectory ?? _startedDirectory;
    // windows.startingDirectory, kept for a shell such as cmd.exe that never reports OSC 7.
    private string? _startedDirectory;

    /// <summary>Raised on the UI thread with the surface id at each directory report (each prompt).</summary>
    internal event Action<string>? CwdChanged;

    /// <summary>Raised once, on the UI thread, when the shell has exited. The owner closes the surface.</summary>
    internal event Action<string>? Exited;

    /// <summary>The window title the shell program set (OSC 0/2), or null when none is set.</summary>
    internal string? Title { get; private set; }

    /// <summary>Raised on the UI thread with the surface id when <see cref="Title"/> changes.</summary>
    internal event Action<string>? TitleChanged;

    /// <summary>The program's own status record (OSC 7501), or null when it has not reported one.
    /// Kept current for hidden surfaces too.</summary>
    internal ProgramStatusRecord? ProgramStatus { get; private set; }

    /// <summary>When the program last changed its status records; drives the sidebar's elapsed
    /// time and the "(stale)" mark.</summary>
    internal DateTimeOffset ProgramStatusChangedAt { get; private set; } = DateTimeOffset.Now;

    /// <summary>Raised on the UI thread with the surface id when <see cref="ProgramStatus"/> changes.</summary>
    internal event Action<string>? ProgramStatusChanged;

    /// <summary>Raised on the UI thread with (surface id, title, body) when the program asks for a
    /// desktop notification (OSC 777 or OSC 9).</summary>
    internal event Action<string, string, string>? NotificationRequested;

    /// <summary>True once at least one terminal snapshot has been painted. Used by the
    /// `--smoke` CI launch check to confirm the native terminal session actually produced
    /// output, not just that the window opened.</summary>
    internal bool HasSnapshot { get; private set; }

    /// <summary>Raised exactly once, the first time a terminal snapshot is painted.</summary>
    internal event Action? FirstSnapshotReady;

    public void FocusTerminal() => _input.Focus(FocusState.Programmatic);

    /// <summary>The shell's process id, or 0 before it starts.</summary>
    internal uint ShellPid => _session is null ? 0 : NativeTerminal.ShellPid(_session);

    /// <summary>True once the shell has exited; such a terminal cannot be reopened.</summary>
    internal bool HasExited => _exitRaised;

    /// <summary>Starts the shell now, for a terminal created by a control command in a workspace
    /// that is not on screen; a terminal otherwise starts when first shown.</summary>
    internal void EnsureStarted()
    {
        if (_session is null && !_disposed) StartSession(focus: false);
    }

    /// <summary>Types text into the terminal as if pasted without brackets (surface.send_text).
    /// Line feeds become carriage returns, which Windows shells read as Enter.</summary>
    internal void SendText(string text)
    {
        EnsureStarted();
        if (_session is null) throw new ControlException("unavailable", "The terminal has not started.");
        var normalized = text.Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r');
        NativeTerminal.Write(_session, Encoding.UTF8.GetBytes(normalized));
    }

    /// <summary>Runs a command line in this terminal: now when the shell has shown its prompt, else at
    /// its first prompt (PowerShell drops input typed before that), or after 5 seconds for a shell
    /// without the integration.</summary>
    internal void QueueCommand(string command)
    {
        EnsureStarted();
        if (_session is not { } session) return;
        if (_cwdGeneration > 0)
        {
            NativeTerminal.Write(session, Encoding.UTF8.GetBytes(command.TrimEnd('\r', '\n') + "\r"));
            return;
        }
        _initialCommand = command;
        DispatcherQueue.TryEnqueue(async () => { await Task.Delay(5000); WriteInitialCommand(session); });
    }

    /// <summary>Presses a named key (surface.send_key) as the keyboard would, in the program's cursor
    /// and keyboard modes; a plain letter or space is typed. False when the key has no encoding.</summary>
    internal bool SendNamedKey(NamedKey key)
    {
        EnsureStarted();
        if (_session is null) throw new ControlException("unavailable", "The terminal has not started.");
        var mode = NativeTerminal.Mode(_session);
        var bytes = key.Character is { } character && !key.Ctrl && !key.Alt
            ? Encoding.UTF8.GetBytes((key.Shift ? char.ToUpperInvariant(character) : character).ToString())
            : EncodeKey(key.Key, key.Ctrl, key.Alt, key.Shift, (mode & NativeTerminal.ModeAppCursor) != 0, (mode & NativeTerminal.ModeKittyDisambiguate) != 0);
        if (bytes is null) return false;
        NativeTerminal.Write(_session, bytes);
        return true;
    }

    /// <summary>A directory a shell reported over the socket (surface.report_pwd), as its OSC 7 would.</summary>
    internal void ReportCwd(string path)
    {
        if (Cwd == path) return;
        Cwd = path;
        CwdChanged?.Invoke(SurfaceId);
    }

    /// <summary>Redraws the terminal (surface.refresh).</summary>
    internal void Refresh() => _canvas.Invalidate();

    /// <summary>Whether the terminal is on screen in a window (surface.health in_window).</summary>
    internal bool InWindow => XamlRoot is not null && IsLoaded;

    /// <summary>Pastes text as one block (bracketed when the program asked for it), so its newlines
    /// do not submit it line by line.</summary>
    internal void PasteText(string text)
    {
        EnsureStarted();
        if (_session is null) throw new ControlException("unavailable", "The terminal has not started.");
        NativeTerminal.Paste(_session, Encoding.UTF8.GetBytes(text.Replace("\r\n", "\n")), true);
    }

    /// <summary>The state an agent hook reported over the control pipe (surface.report_agent_state).</summary>
    internal ProgramStatusRecord? HookStatus { get; private set; }

    /// <summary>The status the sidebar and tab show: the program's own OSC 7501 report outranks a hook
    /// report, as on macOS (docs/program-status.md, Authority).</summary>
    internal ProgramStatusRecord? EffectiveStatus => ProgramStatus ?? HookStatus ?? DetectedStatus;

    /// <summary>The state read off the screen by an agent detection manifest; any report wins over it.</summary>
    internal ProgramStatusRecord? DetectedStatus { get; private set; }

    /// <summary>The last agent session this terminal ran, kept after it exits so it can be resumed.</summary>
    internal AgentSession? LastAgentSession { get; set; }

    /// <summary>A Claude Code hook named <see cref="LastAgentSession"/>, so no guess replaces it.</summary>
    internal bool AgentSessionFromHook { get; set; }

    /// <summary>The macOS agent_state (working, blocked, idle, or null for none) and who reported it:
    /// "program" (OSC 7501), "hooks" (surface.report_agent_state, agent.needs_input) or "inferred"
    /// (screen detection), in that order of authority. done and error read as idle.</summary>
    internal (string? State, string? Source) AgentState =>
        ProgramStatus is { } program ? (Tri(program.State), "program")
        : HookStatus is { } hook ? (Tri(hook.State), "hooks")
        : DetectedStatus is { } detected ? (Tri(detected.State), "inferred")
        : (null, null);

    private static string Tri(string state) => state is "working" or "blocked" ? state : "idle";

    /// <summary>The OSC 7501 root record as the socket shows it: no record text, only whether a message exists.</summary>
    internal object? ProgramStatusJson => ProgramStatus is { } record
        ? new { state = record.State, kind = record.Kind, progress = record.Progress, app = record.App, has_message = record.Msg is { Length: > 0 }, updated_at = ProgramStatusChangedAt.ToUnixTimeMilliseconds() / 1000.0 }
        : null;

    private (string? State, string? Source, string? Program) _publishedState;

    /// <summary>Raised on the UI thread when <see cref="AgentState"/> or the program's state changes.</summary>
    internal event Action<TerminalView>? AgentStateChanged;

    /// <summary>Every status change: the window's header refresh, waits, and agent_state frames for
    /// subscribers, sent when the state, its source or the program's own state changes.</summary>
    private void StatusChanged()
    {
        ProgramStatusChanged?.Invoke(SurfaceId);
        var (state, source) = AgentState;
        BadgeRouteTransition(state, source);
        var current = (state, source, ProgramStatus?.State);
        if (current == _publishedState) return;
        _publishedState = current;
        AgentStateChanged?.Invoke(this);
        EventHub.Publish("agent_state", SurfaceId, source == "program"
            ? new { @event = "agent_state", workspace_id = WorkspaceId, surface_id = SurfaceId, state, source, program_status = ProgramStatusJson, ts = EventHub.Now }
            : new { @event = "agent_state", workspace_id = WorkspaceId, surface_id = SurfaceId, state, source, ts = EventHub.Now });
    }

    private bool _draft;
    private DateTimeOffset _lastKeystroke;

    /// <summary>A person has typed input here that is not sent yet: typed since the last Return,
    /// Ctrl+C or Ctrl+U, with a keystroke in the last 60 seconds (macOS draft_in_progress).</summary>
    internal bool HasDraft => _draft && DateTimeOffset.Now - _lastKeystroke < TimeSpan.FromSeconds(60);

    private void NoteKeyBytes(byte[] bytes)
    {
        _lastKeystroke = DateTimeOffset.Now;
        // Return, Ctrl+C and Ctrl+U end a draft; anything else (text, Backspace, arrows) keeps one going.
        if (bytes is [13] or [3] or [21]) _draft = false;
        else if (bytes is [127] or [8]) { }
        else if (bytes.Length > 0 && bytes[0] != 27) _draft = true;
    }

    /// <summary>A hook's report over the socket (surface.report_agent_state, agent.needs_input). It
    /// moves the badge, unless <paramref name="routeOnly"/>, and the routes' view. A
    /// <paramref name="resumed"/> report (a tool finished) only ends a stop for input by its writer.</summary>
    internal void ReportHookState(string? state, string? app, string? sessionId = null, bool routeOnly = false, bool resumed = false, string? kind = null)
    {
        // Before the badge moves, so this report is not also seen as an untrusted badge transition.
        RoutesFromHooks = true;
        if (!routeOnly)
        {
            HookStatus = state is null ? null : new ProgramStatusRecord(state, kind, null, app, null, null);
            ProgramStatusChangedAt = DateTimeOffset.Now;
            StatusChanged();
        }
        MoveRouteView(state is null ? null : Tri(state), sessionId, resumed);
    }

    /// <summary>workspace.reset_sidebar: forgets the reported agent state, unless a prompt is showing,
    /// which stays until it is answered (macOS resetSidebarContext). Screen detection reads it again.</summary>
    internal void ResetReportedState()
    {
        if (EffectiveStatus?.State == "blocked" || (ProgramStatus is null && HookStatus is null)) return;
        ProgramStatus = HookStatus = null;
        ProgramStatusChangedAt = DateTimeOffset.Now;
        StatusChanged();
        if (RoutesFromHooks) MoveRouteView(null, null, false);
    }

    // ---- The routes' view (docs/program-status.md, Authority): only trusted reporters move it. Windows
    // has no signed program reports, so that is the hooks; it names its writer, the hook session.

    internal string? RouteState { get; private set; }
    internal string? RouteWriter { get; private set; }
    internal DateTimeOffset RouteStateAt { get; private set; }
    /// <summary>A hook has reported here, so routes follow the hooks, not the badge.</summary>
    internal bool RoutesFromHooks { get; private set; }
    /// <summary>The agent stopped for input (blocked, needs_input) and its writer has not reported working since.</summary>
    internal bool StoppedForInput { get; private set; }
    private string? _stopWriter;
    private string? _badgeRouteState;

    /// <summary>An agent state transition for event routes: the state (null for a clear), the one
    /// before, its source, and what the routes' safety rules need to know about the report.</summary>
    internal sealed record RouteTransition(string? State, string? Previous, string? Source, bool Trusted, bool SessionNamed, bool First);

    /// <summary>Raised on the UI thread for each transition routes see.</summary>
    internal event Action<TerminalView, RouteTransition>? RouteStateChanged;

    private void MoveRouteView(string? state, string? sessionId, bool resumed)
    {
        if (resumed && (!StoppedForInput || _stopWriter is null || _stopWriter != sessionId)) return;
        var previous = RouteState;
        RoutesFromHooks = true;
        if (state == "blocked")
        {
            StoppedForInput = true;
            _stopWriter = sessionId;
        }
        else if (state == "working" && StoppedForInput && _stopWriter is not null && _stopWriter == sessionId) StoppedForInput = false;
        if (state is null)
        {
            StoppedForInput = false;
            _stopWriter = null;
            RouteWriter = null;
        }
        else if (sessionId is not null) RouteWriter = sessionId;
        RouteState = state;
        RouteStateAt = DateTimeOffset.Now;
        if (state != previous)
            RouteStateChanged?.Invoke(this, new RouteTransition(state, previous, "hooks", Trusted: true, SessionNamed: sessionId is not null, First: previous is null));
    }

    /// <summary>Without hooks, routes see the badge's transitions, untrusted: only notify routes act on them.</summary>
    private void BadgeRouteTransition(string? state, string? source)
    {
        if (RoutesFromHooks || state == _badgeRouteState) return;
        var previous = _badgeRouteState;
        _badgeRouteState = state;
        RouteStateChanged?.Invoke(this, new RouteTransition(state, previous, source, Trusted: false, SessionNamed: source == "program", First: previous is null));
    }

    internal void ReportDetectedState(string? state, string? app)
    {
        if (DetectedStatus?.State == state && DetectedStatus?.App == app) return;
        DetectedStatus = state is null ? null : new ProgramStatusRecord(state, null, null, app, null, null);
        ProgramStatusChangedAt = DateTimeOffset.Now;
        StatusChanged();
    }

    /// <summary>Drops the scrollback above the screen (macOS Clear Scrollback).</summary>
    public void ClearScrollback()
    {
        if (_session is not null) NativeTerminal.ClearScrollback(_session);
    }

    /// <summary>Reset Terminal (macOS's terminal menu): a full reset of the screen, scrollback and the
    /// modes a program left on; nothing is sent to the program.</summary>
    public void ResetTerminal()
    {
        if (_session is null) return;
        NativeTerminal.Reset(_session);
        Refresh();
    }

    /// <summary>The terminal menu, as a right-click opens it (dev builds' debug.menu.open).</summary>
    internal void ShowContextMenu() => _canvas.ContextFlyout.ShowAt(_canvas);

    /// <summary>Whether text is selected (the terminal menu shows Copy only then, as on macOS).</summary>
    internal bool HasSelection => _session is not null && NativeTerminal.TryCopySelection(_session, out var text) && text.Length > 0;

    /// <summary>Grows or shrinks this terminal's font by one point, or resets it with 0, as Ghostty's
    /// increase/decrease/reset_font_size do for one surface.</summary>
    public void AdjustFontSize(int step) => SetFontSize(step == 0 ? _appearance.FontSize : _fontSize + step);

    /// <summary>The font size when it differs from the theme's, for session restore; null otherwise.</summary>
    internal float? FontSizeOverride => _fontSize != _appearance.FontSize ? _fontSize : null;

    /// <summary>The last <paramref name="lines"/> lines of output, for session restore.</summary>
    internal string OutputText(int lines) => _session is null ? string.Empty : NativeTerminal.Text(_session, (uint)lines);

    /// <summary>Saved output not shown yet because this terminal has not started (its tab was never
    /// selected since launch); kept so the next save does not lose it.</summary>
    internal string? PendingRestoreText => _restoreText;

    internal void SetFontSize(float requested, bool force = false)
    {
        var size = Math.Clamp(requested, 6f, 72f);
        if (size == _fontSize && !force) return;
        _fontSize = size;
        foreach (var format in new[] { _normalFormat, _boldFormat, _italicFormat, _boldItalicFormat }) format.Dispose();
        _normalFormat = CreateTextFormat(bold: false, italic: false);
        _boldFormat = CreateTextFormat(bold: true, italic: false);
        _italicFormat = CreateTextFormat(bold: false, italic: true);
        _boldItalicFormat = CreateTextFormat(bold: true, italic: true);
        _input.FontSize = size;
        _metricsScale = 0;
        ResizeBackend();
        _canvas.Invalidate();
    }

    public void Copy()
    {
        if (_session is null || !NativeTerminal.TryCopySelection(_session, out var text) || string.IsNullOrEmpty(text))
            return;
        SetClipboardText(text);
    }

    private static void SetClipboardText(string text)
    {
        var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    public async void Paste()
    {
        var session = _session;
        if (session is null) return;
        try
        {
            var content = Clipboard.GetContent();
            if (!content.Contains(StandardDataFormats.Text)) return;
            var text = await content.GetTextAsync();
            var bytes = Encoding.UTF8.GetBytes(text);
            if (!ReferenceEquals(_session, session)) return;
            // cmd.exe and PowerShell never enable bracketed paste, so a multi-line
            // clipboard would run every line at once.
            if (NativeTerminal.PasteNeedsConfirmation(session, bytes) && !await ConfirmPasteAsync(text)) return;
            if (ReferenceEquals(_session, session)) NativeTerminal.Paste(session, bytes, true);
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Clipboard paste failed: {error}");
        }
    }

    private async Task<bool> ConfirmPasteAsync(string text)
    {
        const int PreviewLines = 5;
        var lines = text.Replace("\r\n", "\n").Split('\n');
        var preview = string.Join("\n", lines.Take(PreviewLines));
        if (lines.Length > PreviewLines) preview += "\n\u2026";
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(new TextBlock { Text = Localizer.Get("PasteConfirmMessage"), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(new TextBlock { Text = preview, FontFamily = new FontFamily("Cascadia Mono, Consolas"), TextWrapping = TextWrapping.NoWrap, MaxLines = PreviewLines + 1 });
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Localizer.Get("PasteConfirmTitle"),
            Content = content,
            PrimaryButtonText = Localizer.Get("TerminalPaste"),
            CloseButtonText = Localizer.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    /// <summary>The terminal host runs this shell, so quitting Programa does not end it.</summary>
    internal bool Hosted => _session is { IsInvalid: false } session && NativeTerminal.IsHosted(session);

    /// <summary>The tab is gone for good: the shell ends, also when the host runs it. Dispose alone
    /// (a quit, a window closing with the app) leaves a hosted shell running.</summary>
    internal void Close()
    {
        if (_session is { IsInvalid: false } session) NativeTerminal.Kill(session);
        Dispose();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        RetireCurrentSession();
        _canvas.Draw -= DrawTerminal;
        _canvas.RemoveFromVisualTree();
        _normalFormat.Dispose();
        _boldFormat.Dispose();
        _italicFormat.Dispose();
        _boldItalicFormat.Dispose();
        GC.SuppressFinalize(this);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new TerminalViewAutomationPeer(this);

    internal string AutomationValue => _automationValue;

    private void StartSession(bool focus = true)
    {
        if (_disposed) return;
        RetireCurrentSession();
        InCopyMode = false;
        _copyBadge.Visibility = Visibility.Collapsed;
        _paintedGeneration = 0;
        _exitRaised = false;
        _programStatusGeneration = 0;
        _cwdGeneration = 0;
        if (ProgramStatus is not null)
        {
            ProgramStatus = null;
            StatusChanged();
        }
        lock (_snapshotGate) _snapshot = null;
        _automationValue = string.Empty;
        _spawnFailure.Visibility = Visibility.Collapsed;

        // The variables the macOS app exports, so the CLI and agent hooks find their terminal.
        var environment = new Dictionary<string, string>
        {
            ["PROGRAMA_SURFACE_ID"] = SurfaceId,
            ["PROGRAMA_PANEL_ID"] = SurfaceId,
            ["PROGRAMA_WORKSPACE_ID"] = WorkspaceId,
            ["PROGRAMA_TAB_ID"] = WorkspaceId,
            ["PROGRAMA_SHELL_INTEGRATION"] = "1",
            ["PROGRAMA_SOCKET_PATH"] = ControlServer.PipePath,
            ["PROGRAMA_SOCKET"] = ControlServer.PipePath,
        };
        // The bundled `programa` CLI is on PATH inside Programa terminals, as on macOS.
        var cliDirectory = McpConfig.BinDirectory;
        var settings = AppSettings.Load();
        if (File.Exists(Path.Combine(cliDirectory, "programa.exe")))
        {
            environment["PATH"] = cliDirectory + Path.PathSeparator + Environment.GetEnvironmentVariable("PATH");
            environment["PROGRAMA_BUNDLED_CLI_PATH"] = Path.Combine(cliDirectory, "programa.exe");
            // automation.claudeCodeIntegration: without these the PowerShell integration defines no `claude` wrapper.
            if (settings.ClaudeCodeIntegration && McpConfig.FilePath is { } mcp) environment["PROGRAMA_MCP_CONFIG"] = mcp;
            if (settings.ClaudeCodeIntegration && McpConfig.HooksPath is { } hooks) environment["PROGRAMA_CLAUDE_SETTINGS"] = hooks;
        }
        // automation.claudeTeamsByDefault, unless the app's own environment sets it (0 included).
        if (settings.ClaudeTeamsByDefault && Environment.GetEnvironmentVariable("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS") is null)
            environment["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1";
        // The default browser, resolved each time a terminal starts, as on macOS; unset when unknown.
        if (Browsers.Default() is { } browser)
        {
            environment["PROGRAMA_DEFAULT_BROWSER"] = browser.Key;
            environment["PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID"] = browser.ProgId;
        }
        // A layout's per-terminal variables (docs/programa-json.md, surfaces[].env).
        if (_extraEnvironment is not null) foreach (var (key, value) in _extraEnvironment) environment[key] = value;
        var terminalSettings = TerminalSettings.LoadOrDefaults();
        var directory = Cwd ?? _initialDirectory ?? terminalSettings.StartingDirectory;
        if (directory is not null && !Directory.Exists(directory)) directory = null;
        // The shell runs in the terminal host and outlives the app; one still running there from
        // before this launch is reattached as it is, so its start command does not run again.
        var host = TerminalHost.Current is { } connection ? new { pipe = connection.Pipe, token = connection.Token, id = SurfaceId } : null;
        var reattach = TerminalHost.LiveAtLaunch.Remove(SurfaceId);
        if (reattach) _initialCommand = null;
        // Ghostty's command picks the program; initial-command replaces it for the first terminal
        // this launch starts, as Ghostty does on macOS. windows.shell replaces Ghostty's command.
        var command = reattach ? null : (Interlocked.Exchange(ref _shellStarted, 1) == 0 ? _appearance.InitialCommand : null) ?? terminalSettings.Command ?? _appearance.Command;
        var config = JsonSerializer.SerializeToUtf8Bytes(new { cols = 80, rows = 24, cell_width = (ushort)MathF.Ceiling(_cellWidth), cell_height = (ushort)MathF.Ceiling(_cellHeight), colors = _appearance.CoreColors, restore_text = _restoreText, shell_integration = true, command, working_directory = directory, env = environment, host });
        var session = NativeTerminal.Create(config, out var error);
        _restoreText = null;
        if (session is null || session.IsInvalid)
        {
            _spawnFailureDetail.Text = string.IsNullOrWhiteSpace(error) ? Localizer.Get("TerminalSpawnFailed") : error;
            _spawnFailure.Visibility = Visibility.Visible;
            return;
        }
        // The command could not be used and the default shell started; error says why.
        if (!string.IsNullOrEmpty(error)) LaunchLog.Write(error);
        _session = session;
        _startedDirectory = directory;
        // PowerShell discards input typed before its first prompt, so the initial command waits for
        // the prompt's OSC 7 (see Refresh); a shell without the integration gets it after 5 seconds.
        if (_initialCommand is { Length: > 0 })
            DispatcherQueue.TryEnqueue(async () => { await Task.Delay(5000); WriteInitialCommand(session); });
        var handle = NativeTerminal.EventHandle(session);
        if (handle != nint.Zero)
            _event = new EventWaitHandle(false, EventResetMode.ManualReset) { SafeWaitHandle = new SafeWaitHandle(handle, ownsHandle: false) };
        ResizeBackend();
        Refresh(session);
        if (focus) FocusTerminal();
    }

    private void WriteInitialCommand(NativeTerminal.SafeSessionHandle session)
    {
        if (_disposed || !ReferenceEquals(_session, session) || _initialCommand is not { Length: > 0 } command) return;
        _initialCommand = null;
        NativeTerminal.Write(session, Encoding.UTF8.GetBytes(command.TrimEnd('\r', '\n') + "\r"));
    }

    private void Refresh(NativeTerminal.SafeSessionHandle session)
    {
        if (_disposed || !ReferenceEquals(_session, session)) return;
        var generation = NativeTerminal.Generation(session);
        // Checked before the visibility early-outs so a shell that exits in a background tab still closes it.
        if (!_exitRaised && NativeTerminal.IsTerminated(session))
        {
            _exitRaised = true;
            Exited?.Invoke(SurfaceId);
        }
        // OSC 52 (agents' "copy" commands). Checked before the visibility early-outs like exit.
        var clipboard = NativeTerminal.TakeClipboard(session);
        if (clipboard.Length > 0) SetClipboardText(clipboard);
        // OSC 777/9 desktop notifications, from hidden tabs too.
        foreach (var notification in NativeTerminal.TakeNotifications(session))
            NotificationRequested?.Invoke(SurfaceId, notification.Title, notification.Body);
        var cwdGeneration = NativeTerminal.CwdGeneration(session);
        if (cwdGeneration != _cwdGeneration)
        {
            _cwdGeneration = cwdGeneration;
            if (NativeTerminal.Cwd(session) is { Length: > 0 } cwd)
            {
                Cwd = cwd;
                CwdChanged?.Invoke(SurfaceId);
            }
            WriteInitialCommand(session);
        }
        var statusGeneration = NativeTerminal.ProgramStatusGeneration(session);
        if (statusGeneration != _programStatusGeneration) RefreshProgramStatus(session, statusGeneration);
        if (!IsLoaded || Visibility != Visibility.Visible)
        {
            AcknowledgeAndArm(session, generation);
            return;
        }
        if (generation == _paintedGeneration)
        {
            AcknowledgeAndArm(session, generation);
            return;
        }
        if (!NativeTerminal.TrySnapshot(session, out var json))
        {
            AcknowledgeAndArm(session, generation);
            return;
        }
        var acknowledgedGeneration = generation;
        try
        {
            var snapshot = JsonSerializer.Deserialize<TerminalSnapshot>(json, TerminalJson.Options);
            if (snapshot is null) return;
            acknowledgedGeneration = snapshot.Generation;
            lock (_snapshotGate) _snapshot = snapshot;
            _automationValue = BuildAccessibleText(snapshot);
            _paintedGeneration = snapshot.Generation;
            var title = string.IsNullOrWhiteSpace(snapshot.Title) ? null : snapshot.Title;
            if (title != Title)
            {
                Title = title;
                TitleChanged?.Invoke(SurfaceId);
            }
            UpdateInputProxyLayout(snapshot.Cursor, _composing);
            _canvas.Invalidate();
            FrameworkElementAutomationPeer.FromElement(this)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
            if (!HasSnapshot)
            {
                HasSnapshot = true;
                FirstSnapshotReady?.Invoke();
            }
        }
        catch (JsonException error)
        {
            System.Diagnostics.Debug.WriteLine($"Terminal snapshot was invalid: {error}");
        }
        finally
        {
            AcknowledgeAndArm(session, acknowledgedGeneration);
        }
    }

    /// <summary>The grid, the cell size in DIPs and the display scale, as pane.list reports them; null before the first frame.</summary>
    internal (int Columns, int Rows, double CellWidth, double CellHeight, double Scale)? GridMetrics
    {
        get
        {
            TerminalSnapshot? snapshot;
            lock (_snapshotGate) snapshot = _snapshot;
            return snapshot is null ? null : (snapshot.Columns, snapshot.Rows, _cellWidth, _cellHeight, _canvas.Dpi / 96.0);
        }
    }

    private void ResizeBackend()
    {
        if (_session is null || _canvas.ActualWidth <= 0 || _canvas.ActualHeight <= 0) return;
        var dpiScale = _canvas.Dpi / 96f;
        UpdateCellMetrics(dpiScale);
        var cols = (ushort)Math.Clamp((int)((_canvas.ActualWidth - 2 * Padding) / _cellWidth), 2, ushort.MaxValue);
        var rows = (ushort)Math.Clamp((int)((_canvas.ActualHeight - 2 * Padding) / _cellHeight), 2, ushort.MaxValue);
        var cellWidth = (ushort)Math.Clamp((int)Math.Round(_cellWidth * dpiScale), 1, ushort.MaxValue);
        var cellHeight = (ushort)Math.Clamp((int)Math.Round(_cellHeight * dpiScale), 1, ushort.MaxValue);
        NativeTerminal.Resize(_session, cols, rows, cellWidth, cellHeight);
        TerminalSnapshot? snapshot;
        lock (_snapshotGate) snapshot = _snapshot;
        if (snapshot is not null) UpdateInputProxyLayout(snapshot.Cursor, _composing);
    }

    /// <summary>Measures the cell from the font, like Ghostty: the advance of a monospace glyph by
    /// the line height, rounded to whole device pixels so cells tile without seams.</summary>
    private void UpdateCellMetrics(float scale)
    {
        if (scale == _metricsScale) return;
        _metricsScale = scale;
        const string Sample = "MMMMMMMMMM";
        using var layout = new CanvasTextLayout(CanvasDevice.GetSharedDevice(), Sample, _normalFormat, float.MaxValue, float.MaxValue);
        var advance = (float)layout.LayoutBounds.Width / Sample.Length;
        _cellWidth = MathF.Max(1, MathF.Round(advance * scale)) / scale;
        _cellHeight = MathF.Max(1, MathF.Round((float)layout.LayoutBounds.Height * scale)) / scale;
    }

    private CanvasTextFormat CreateTextFormat(bool bold, bool italic) => new()
    {
        FontFamily = _appearance.CanvasFontFamily(bold, italic),
        FontSize = _fontSize,
        FontWeight = bold ? FontWeights.Bold : FontWeights.Normal,
        FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
        Options = CanvasDrawTextOptions.EnableColorFont,
        WordWrapping = CanvasWordWrapping.NoWrap,
    };

    /// <summary>Default text and background colors: the theme's, or the system's in high contrast.</summary>
    private (Color Foreground, Color Background) DefaultColors() => _accessibilitySettings.HighContrast
        ? (_uiSettings.GetColorValue(UIColorType.Foreground), _uiSettings.GetColorValue(UIColorType.Background))
        : (_appearance.Foreground, _appearance.Background);

    private void ShowCompositionProxy()
    {
        TerminalSnapshot? snapshot;
        lock (_snapshotGate) snapshot = _snapshot;
        _input.Foreground = new SolidColorBrush(DefaultColors().Foreground);
        _input.Opacity = 1;
        UpdateInputProxyLayout(snapshot?.Cursor ?? new TerminalCursor(0, 0, true), composing: true);
    }

    private void HideCompositionProxy()
    {
        TerminalSnapshot? snapshot;
        lock (_snapshotGate) snapshot = _snapshot;
        _input.Opacity = 0.01;
        UpdateInputProxyLayout(snapshot?.Cursor ?? new TerminalCursor(0, 0, true), composing: false);
    }

    private void UpdateInputProxyLayout(TerminalCursor cursor, bool composing)
    {
        var viewportWidth = Math.Max(1, _canvas.ActualWidth);
        var viewportHeight = Math.Max(1, _canvas.ActualHeight);
        var minimumWidth = Math.Min(_cellWidth, viewportWidth);
        var height = composing ? Math.Min(_cellHeight, viewportHeight) : 1;
        var maximumX = composing ? viewportWidth - minimumWidth : viewportWidth - 1;
        var x = Math.Clamp(Padding + cursor.Column * _cellWidth, 0, maximumX);
        var y = Math.Clamp(Padding + cursor.Row * _cellHeight, 0, viewportHeight - height);

        _input.Margin = new Thickness(x, y, 0, 0);
        _input.Width = composing ? Math.Max(1, Math.Min(320, viewportWidth - x)) : 1;
        _input.Height = height;
    }

    private void RefreshProgramStatus(NativeTerminal.SafeSessionHandle session, ulong generation)
    {
        _programStatusGeneration = generation;
        if (!NativeTerminal.TryProgramStatus(session, out var json)) return;
        try
        {
            var status = JsonSerializer.Deserialize<ProgramStatusSnapshot>(json, TerminalJson.Options);
            if (status is null) return;
            _programStatusGeneration = status.Generation;
            ProgramStatusChangedAt = DateTimeOffset.Now;
            if (status.Root == ProgramStatus) return;
            ProgramStatus = status.Root;
            StatusChanged();
        }
        catch (JsonException error)
        {
            System.Diagnostics.Debug.WriteLine($"Program status was invalid: {error}");
        }
    }

    private void ArmWait(NativeTerminal.SafeSessionHandle session)
    {
        if (_disposed || !ReferenceEquals(_session, session) || _event is null || _registeredWait is not null) return;

        RegisteredWaitHandle? registration = null;
        registration = ThreadPool.RegisterWaitForSingleObject(
            _event,
            (_, timedOut) =>
            {
                if (timedOut) return;
                DispatcherQueue.TryEnqueue(() => CompleteWaitOnUiThread(session, registration));
            },
            null,
            Timeout.Infinite,
            executeOnlyOnce: true);
        _registeredWait = registration;
    }

    private void CompleteWaitOnUiThread(NativeTerminal.SafeSessionHandle session, RegisteredWaitHandle? registration)
    {
        if (_disposed || !ReferenceEquals(_session, session) || !ReferenceEquals(_registeredWait, registration))
        {
            registration?.Unregister(null);
            return;
        }

        _registeredWait = null;
        registration?.Unregister(null);
        Refresh(session);
    }

    private void AcknowledgeAndArm(NativeTerminal.SafeSessionHandle session, ulong generation)
    {
        if (_disposed || !ReferenceEquals(_session, session)) return;
        if (NativeTerminal.Acknowledge(session, generation) != 0) return;
        if (_disposed || !ReferenceEquals(_session, session)) return;
        ArmWait(session);
    }

    private void RetireCurrentSession()
    {
        var registration = _registeredWait;
        var eventHandle = _event;
        var session = _session;
        _registeredWait = null;
        _event = null;
        _session = null;

        if (registration is null)
        {
            eventHandle?.Dispose();
            session?.Dispose();
            return;
        }

        var callbacksComplete = new ManualResetEvent(false);
        if (!registration.Unregister(callbacksComplete))
        {
            callbacksComplete.Dispose();
            eventHandle?.Dispose();
            session?.Dispose();
            return;
        }

        _ = Task.Run(() =>
        {
            callbacksComplete.WaitOne();
            callbacksComplete.Dispose();
            eventHandle?.Dispose();
            session?.Dispose();
        });
    }

    private void DrawTerminal(CanvasControl sender, CanvasDrawEventArgs args)
    {
        TerminalSnapshot? snapshot;
        lock (_snapshotGate) snapshot = _snapshot;
        var (defaultForeground, defaultBackground) = DefaultColors();
        var highContrast = _accessibilitySettings.HighContrast;
        // Ghostty: unset selection and cursor colors invert the default foreground and background.
        var selectionBackground = (highContrast ? null : _appearance.SelectionBackground) ?? defaultForeground;
        var selectionForeground = (highContrast ? null : _appearance.SelectionForeground) ?? defaultBackground;
        var cursorColor = (highContrast ? null : _appearance.Cursor) ?? defaultForeground;
        var cursorText = (highContrast ? null : _appearance.CursorText) ?? defaultBackground;
        args.DrawingSession.Clear(defaultBackground);
        if (snapshot is null) return;

        var cursor = snapshot.Cursor;
        // A focused block cursor is drawn as the cell's colors; every other cursor is drawn on top.
        var blockCursor = cursor.Visible && _focused && cursor.Shape == "block";
        foreach (var cell in snapshot.Cells)
        {
            var x = Padding + cell.Column * _cellWidth;
            var y = Padding + cell.Row * _cellHeight;
            var width = _cellWidth * Math.Max(cell.Width, 1);
            var foreground = cell.ExplicitForeground ? cell.Foreground.ToColor() : defaultForeground;
            Color? background = cell.ExplicitBackground ? cell.Background.ToColor() : null;
            if (cell.Selected) (background, foreground) = (selectionBackground, selectionForeground);
            if (blockCursor && cell.Row == cursor.Row && cell.Column == cursor.Column) (background, foreground) = (cursorColor, cursorText);
            if (background is { } fill) args.DrawingSession.FillRectangle(x, y, width, _cellHeight, fill);
            if (cell.Width == 0 || string.IsNullOrEmpty(cell.Text)) continue;
            // Ghostty's default faint-opacity is 0.5.
            if (cell.Dim) foreground = Color.FromArgb((byte)(foreground.A / 2), foreground.R, foreground.G, foreground.B);
            var format = cell.Bold
                ? cell.Italic ? _boldItalicFormat : _boldFormat
                : cell.Italic ? _italicFormat : _normalFormat;
            args.DrawingSession.DrawText(cell.Text, new Vector2(x, y), foreground, format);
            if (cell.Underline || cell.Undercurl || InHoverLink(cell))
                args.DrawingSession.DrawLine(x, y + _cellHeight - 2, x + width, y + _cellHeight - 2, foreground, 1);
            if (cell.Strikethrough)
                args.DrawingSession.DrawLine(x, y + _cellHeight / 2, x + width, y + _cellHeight / 2, foreground, 1);
        }
        if (!cursor.Visible || blockCursor) return;
        const float Thickness = 2f;
        var cursorX = Padding + cursor.Column * _cellWidth;
        var cursorY = Padding + cursor.Row * _cellHeight;
        if (!_focused)
            args.DrawingSession.DrawRectangle(cursorX, cursorY, _cellWidth, _cellHeight, cursorColor, 1);
        else if (cursor.Shape == "beam")
            args.DrawingSession.FillRectangle(cursorX, cursorY, Thickness, _cellHeight, cursorColor);
        else
            args.DrawingSession.FillRectangle(cursorX, cursorY + _cellHeight - Thickness, _cellWidth, Thickness, cursorColor);
    }

    private void InputChanged(object sender, TextChangedEventArgs args)
    {
        if (!_resettingInput && !_composing) CommitInput();
    }

    private void InputCompositionStarted(TextBox sender, TextCompositionStartedEventArgs args)
    {
        _composing = true;
        ShowCompositionProxy();
    }

    private void InputCompositionChanged(TextBox sender, TextCompositionChangedEventArgs args)
    {
        if (_composing) ShowCompositionProxy();
    }

    private void InputCompositionEnded(TextBox sender, TextCompositionEndedEventArgs args)
    {
        _composing = false;
        CommitInput();
        HideCompositionProxy();
    }

    private void CommitInput()
    {
        if (_session is null || string.IsNullOrEmpty(_input.Text)) return;
        if (InCopyMode)
        {
            // Typed keys are copy mode commands; none reaches the shell.
            var keys = _input.Text;
            _resettingInput = true;
            _input.Text = string.Empty;
            _resettingInput = false;
            TypeInCopyMode(keys);
            return;
        }
        var typed = Encoding.UTF8.GetBytes(_input.Text);
        NoteKeyBytes(typed);
        NativeTerminal.Write(_session, typed);
        _resettingInput = true;
        _input.Text = string.Empty;
        _resettingInput = false;
    }

    private void InputKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Handled || _session is null || _composing) return;
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);
        var alt = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(CoreVirtualKeyStates.Down);
        var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
        var mode = NativeTerminal.Mode(_session);
        var bytes = EncodeKey(args.Key, ctrl, alt, shift, (mode & NativeTerminal.ModeAppCursor) != 0, (mode & NativeTerminal.ModeKittyDisambiguate) != 0);
        if (InCopyMode)
        {
            // Printable keys (AltGr ones too) come through the text box; every other key is copy mode's.
            if (CopyModeKeyDown(args.Key, ctrl, alt) || bytes is not null) args.Handled = true;
            return;
        }
        if (bytes is null) return;
        NoteKeyBytes(bytes);
        NativeTerminal.Write(_session, bytes);
        args.Handled = true;
    }

    /// <summary>
    /// Maps a non-text key to xterm bytes. Printable characters without Ctrl or Alt arrive through the
    /// text box instead. Ctrl+Alt is AltGr on many layouts and is left to the text box as well.
    /// </summary>
    internal static byte[]? EncodeKey(VirtualKey key, bool ctrl, bool alt, bool shift, bool appCursor, bool kitty = false)
    {
        var modifier = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
        var modified = modifier > 1;
        static byte[] Ascii(string text) => Encoding.ASCII.GetBytes(text);
        // Kitty keyboard flag 1 (disambiguate): keys whose legacy bytes are ambiguous are sent as
        // CSI code;modifier u. This is how Shift+Enter reaches agents as a newline, not a submit.
        static byte[] CsiU(int code, int modifier) => Ascii(modifier > 1 ? $"\x1b[{code};{modifier}u" : $"\x1b[{code}u");

        switch (key)
        {
            case VirtualKey.Enter: return kitty && modified ? CsiU(13, modifier) : [13];
            case VirtualKey.Back: return kitty && modified ? CsiU(127, modifier) : alt ? [27, 127] : [127];
            case VirtualKey.Tab when kitty && modified: return CsiU(9, modifier);
            case VirtualKey.Tab when !ctrl && !alt: return shift ? [27, 91, 90] : [9];
            case VirtualKey.Escape: return kitty ? CsiU(27, modifier) : [27];
        }

        var cursor = key switch { VirtualKey.Up => 'A', VirtualKey.Down => 'B', VirtualKey.Right => 'C', VirtualKey.Left => 'D', VirtualKey.Home => 'H', VirtualKey.End => 'F', _ => '\0' };
        if (cursor != '\0')
        {
            var arrow = key is VirtualKey.Up or VirtualKey.Down or VirtualKey.Right or VirtualKey.Left;
            return Ascii(modified ? $"\x1b[1;{modifier}{cursor}" : appCursor && arrow ? $"\x1bO{cursor}" : $"\x1b[{cursor}");
        }

        var function = key switch { VirtualKey.F1 => 'P', VirtualKey.F2 => 'Q', VirtualKey.F3 => 'R', VirtualKey.F4 => 'S', _ => '\0' };
        if (function != '\0') return Ascii(modified ? $"\x1b[1;{modifier}{function}" : $"\x1bO{function}");

        var tilde = key switch
        {
            VirtualKey.Insert => 2, VirtualKey.Delete => 3, VirtualKey.PageUp => 5, VirtualKey.PageDown => 6,
            VirtualKey.F5 => 15, VirtualKey.F6 => 17, VirtualKey.F7 => 18, VirtualKey.F8 => 19,
            VirtualKey.F9 => 20, VirtualKey.F10 => 21, VirtualKey.F11 => 23, VirtualKey.F12 => 24,
            _ => 0,
        };
        if (tilde != 0) return Ascii(modified ? $"\x1b[{tilde};{modifier}~" : $"\x1b[{tilde}~");

        if (!ctrl && !alt || ctrl && alt) return null;
        if (kitty)
        {
            int? code = key switch
            {
                >= VirtualKey.A and <= VirtualKey.Z => 'a' + (int)key - (int)VirtualKey.A,
                >= VirtualKey.Number0 and <= VirtualKey.Number9 => '0' + (int)key - (int)VirtualKey.Number0,
                VirtualKey.Space => ' ',
                _ when IsPunctuationKey(key) => KeyboardLayout.UnshiftedCharacter(key),
                _ => null,
            };
            return code is { } value ? CsiU(value, modifier) : null;
        }
        int character;
        if (key is >= VirtualKey.A and <= VirtualKey.Z)
            character = ctrl ? (int)key - (int)VirtualKey.A + 1 : (shift ? 'A' : 'a') + (int)key - (int)VirtualKey.A;
        else if (key is >= VirtualKey.Number0 and <= VirtualKey.Number9 && !ctrl && !shift)
            character = '0' + (int)key - (int)VirtualKey.Number0;
        else if (ctrl && key == VirtualKey.Space) character = 0;
        else if (ctrl && (int)key == 219) character = 27; // Ctrl+[
        else if (ctrl && (int)key == 220) character = 28; // Ctrl+\
        else if (ctrl && (int)key == 221) character = 29; // Ctrl+]
        else if (alt && !ctrl && key == VirtualKey.Space) character = ' ';
        else if (alt && !ctrl && !shift && IsPunctuationKey(key) && KeyboardLayout.UnshiftedCharacter(key) is { } punctuation) character = punctuation;
        else return null;
        return alt ? [27, (byte)character] : [(byte)character];
    }

    /// <summary>OEM punctuation keys and the numpad operators. Alt+these is sent as ESC plus the
    /// layout's own character; without Alt the text box already delivers the typed character.</summary>
    private static bool IsPunctuationKey(VirtualKey key)
    {
        var code = (int)key;
        return code is >= 186 and <= 192 or >= 219 and <= 222 or 106 or 107 or 109 or 110 or 111;
    }

    private static uint MouseModifiers(VirtualKeyModifiers modifiers) =>
        (modifiers.HasFlag(VirtualKeyModifiers.Shift) ? NativeTerminal.MouseModShift : 0)
        | (modifiers.HasFlag(VirtualKeyModifiers.Menu) ? NativeTerminal.MouseModAlt : 0)
        | (modifiers.HasFlag(VirtualKeyModifiers.Control) ? NativeTerminal.MouseModCtrl : 0);

    private void PointerPressed(object sender, PointerRoutedEventArgs args)
    {
        if (_session is null) return;
        var point = args.GetCurrentPoint(_canvas);
        var properties = point.Properties;
        uint? button = properties.IsLeftButtonPressed ? 0u : properties.IsMiddleButtonPressed ? 1u : properties.IsRightButtonPressed ? 2u : null;
        if (button is null) return;
        var (col, row) = CellAt(point.Position);
        if (button == 0 && OpenLinkOnClick(args, col, row)) return;
        // Shift bypasses mouse reporting so text stays selectable in mouse-driven TUIs, as in Ghostty.
        if (!args.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift))
        {
            if (NativeTerminal.Mouse(_session, button.Value, NativeTerminal.MousePress, col, row, MouseModifiers(args.KeyModifiers)))
            {
                _mouseButton = button;
                _lastMouseCell = (col, row);
                _suppressContextMenu = button == 2;
                _canvas.CapturePointer(args.Pointer);
                FocusTerminal();
                args.Handled = true;
                return;
            }
        }
        if (button != 0) return;
        var now = DateTimeOffset.UtcNow;
        var nearby = Math.Abs(point.Position.X - _lastClickPoint.X) < _cellWidth && Math.Abs(point.Position.Y - _lastClickPoint.Y) < _cellHeight;
        _clickCount = nearby && now - _lastClick < TimeSpan.FromMilliseconds(500) ? Math.Min(_clickCount + 1, 3u) : 1;
        _lastClick = now;
        _lastClickPoint = point.Position;
        var mode = _clickCount == 2 ? 2u : _clickCount >= 3 ? 3u : 0u;
        NativeTerminal.SelectionBegin(_session, col, row, mode);
        _selecting = true;
        _canvas.CapturePointer(args.Pointer);
        FocusTerminal();
        args.Handled = true;
    }

    private void PointerMoved(object sender, PointerRoutedEventArgs args)
    {
        if (_session is null) return;
        var (col, row) = CellAt(args.GetCurrentPoint(_canvas).Position);
        if (_selecting)
        {
            NativeTerminal.SelectionUpdate(_session, col, row);
            return;
        }
        UpdateHoverLink(args, col, row);
        // Report only cell changes; button 3 is plain motion, which only any-event tracking takes.
        if ((col, row) == _lastMouseCell) return;
        _lastMouseCell = (col, row);
        NativeTerminal.Mouse(_session, _mouseButton ?? 3, NativeTerminal.MouseMotion, col, row, MouseModifiers(args.KeyModifiers));
    }

    private void PointerReleased(object sender, PointerRoutedEventArgs args)
    {
        if (_mouseButton is { } button)
        {
            _mouseButton = null;
            if (_session is not null)
            {
                var (col, row) = CellAt(args.GetCurrentPoint(_canvas).Position);
                NativeTerminal.Mouse(_session, button, NativeTerminal.MouseRelease, col, row, MouseModifiers(args.KeyModifiers));
            }
            _canvas.ReleasePointerCapture(args.Pointer);
            return;
        }
        if (!_selecting) return;
        _selecting = false;
        if (_session is not null) NativeTerminal.SelectionEnd(_session);
        _canvas.ReleasePointerCapture(args.Pointer);
    }

    private void PointerWheelChanged(object sender, PointerRoutedEventArgs args)
    {
        if (_session is null) return;
        var point = args.GetCurrentPoint(_canvas);
        if (point.Properties.IsHorizontalMouseWheel) return;
        args.Handled = true;
        // 120 units is one notch, three lines (the Windows default).
        _wheelRemainder += point.Properties.MouseWheelDelta * 3;
        var lines = _wheelRemainder / 120;
        _wheelRemainder %= 120;
        if (lines == 0) return;
        var (col, row) = CellAt(point.Position);
        NativeTerminal.Wheel(_session, lines, col, row, MouseModifiers(args.KeyModifiers));
    }

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem { Text = Localizer.Get("TerminalCopy") };
        copy.Click += (_, _) => Copy();
        var paste = new MenuFlyoutItem { Text = Localizer.Get("TerminalPaste") };
        paste.Click += (_, _) => Paste();
        var reset = new MenuFlyoutItem { Text = Localizer.Get("TerminalReset"), Icon = new FontIcon { Glyph = char.ConvertFromUtf32(0xE72C) } };
        reset.Click += (_, _) => ResetTerminal();
        menu.Items.Add(copy);
        menu.Items.Add(paste);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(reset);
        // As on macOS, Copy is there only while text is selected.
        menu.Opening += (_, _) => copy.Visibility = HasSelection ? Visibility.Visible : Visibility.Collapsed;
        return menu;
    }

    private (nuint Col, nuint Row) CellAt(Point point) =>
        ((nuint)Math.Max(0, (int)((point.X - Padding) / _cellWidth)), (nuint)Math.Max(0, (int)((point.Y - Padding) / _cellHeight)));

    private static string BuildAccessibleText(TerminalSnapshot snapshot)
    {
        var rows = new StringBuilder[snapshot.Rows];
        for (var index = 0; index < rows.Length; index++) rows[index] = new StringBuilder();
        foreach (var cell in snapshot.Cells)
            if (cell.Row < rows.Length && cell.Width != 0) rows[cell.Row].Append(cell.Text.Length == 0 ? ' ' : cell.Text);
        return string.Join(Environment.NewLine, rows.Select(row => row.ToString().TrimEnd()));
    }

    private sealed class TerminalViewAutomationPeer(TerminalView owner) : FrameworkElementAutomationPeer(owner), IValueProvider
    {
        bool IValueProvider.IsReadOnly => true;
        string IValueProvider.Value => owner.AutomationValue;
        void IValueProvider.SetValue(string value) => throw new InvalidOperationException();
        protected override object? GetPatternCore(PatternInterface patternInterface) => patternInterface == PatternInterface.Value ? this : base.GetPatternCore(patternInterface);
        protected override string GetClassNameCore() => nameof(TerminalView);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Document;
        protected override string GetNameCore() => Localizer.Get("TerminalAccessibilityName");
    }
}

internal static class NativeTerminal
{
    internal sealed class SafeSessionHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        private SafeSessionHandle() : base(true) { }
        protected override bool ReleaseHandle() { Free(handle); return true; }
    }

    [StructLayout(LayoutKind.Sequential)] internal struct Buffer { internal nint Data; internal nuint Length; }
    private const string Dll = "programa_terminal.dll";

    [DllImport(Dll, EntryPoint = "programa_terminal_create")] private static extern SafeSessionHandle CreateNative(byte[] config, nuint length, out Buffer error);
    [DllImport(Dll, EntryPoint = "programa_terminal_free")] private static extern void Free(nint session);
    [DllImport(Dll, EntryPoint = "programa_terminal_kill")] internal static extern int Kill(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_is_hosted")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool IsHosted(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_buffer_free")] private static extern void FreeBuffer(nint data, nuint length);
    [DllImport(Dll, EntryPoint = "programa_terminal_write")] private static extern int WriteNative(SafeSessionHandle session, byte[] data, nuint length);
    [DllImport(Dll, EntryPoint = "programa_terminal_resize")] internal static extern int Resize(SafeSessionHandle session, ushort cols, ushort rows, ushort cellWidth, ushort cellHeight);
    [DllImport(Dll, EntryPoint = "programa_terminal_scroll")] internal static extern int Scroll(SafeSessionHandle session, int lines);
    [DllImport(Dll, EntryPoint = "programa_terminal_snapshot_json")] internal static extern int Snapshot(SafeSessionHandle session, out Buffer buffer);
    [DllImport(Dll, EntryPoint = "programa_terminal_generation")] internal static extern ulong Generation(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_program_status_generation")] internal static extern ulong ProgramStatusGeneration(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_program_status_json")] private static extern int ProgramStatusJson(SafeSessionHandle session, out Buffer buffer);
    internal const uint ModeAppCursor = 1, ModeKittyDisambiguate = 8;
    internal const uint MousePress = 0, MouseRelease = 1, MouseMotion = 2;
    internal const uint MouseModShift = 1, MouseModAlt = 2, MouseModCtrl = 4;
    [DllImport(Dll, EntryPoint = "programa_terminal_mode")] internal static extern uint Mode(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_mouse")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool Mouse(SafeSessionHandle session, uint button, uint action, nuint col, nuint row, uint mods);
    [DllImport(Dll, EntryPoint = "programa_terminal_set_colors")] private static extern int SetColorsNative(SafeSessionHandle session, byte[] colors, nuint length);
    internal static int SetColors(SafeSessionHandle session, byte[] colors) => SetColorsNative(session, colors, (nuint)colors.Length);
    [DllImport(Dll, EntryPoint = "programa_terminal_focus")] internal static extern int Focus(SafeSessionHandle session, [MarshalAs(UnmanagedType.I1)] bool focused);
    [DllImport(Dll, EntryPoint = "programa_terminal_wheel")] internal static extern int Wheel(SafeSessionHandle session, int lines, nuint col, nuint row, uint mods);
    [DllImport(Dll, EntryPoint = "programa_terminal_take_clipboard")] private static extern int TakeClipboardNative(SafeSessionHandle session, out Buffer buffer);
    internal static string TakeClipboard(SafeSessionHandle session) => TakeClipboardNative(session, out var buffer) == 0 ? ReadAndFree(buffer) : string.Empty;
    [DllImport(Dll, EntryPoint = "programa_terminal_find")]
    [return: MarshalAs(UnmanagedType.I1)] private static extern bool FindNative(SafeSessionHandle session, byte[] text, nuint length, [MarshalAs(UnmanagedType.I1)] bool forward);
    internal static bool Find(SafeSessionHandle session, byte[] text, bool forward) => FindNative(session, text, (nuint)text.Length, forward);
    [DllImport(Dll, EntryPoint = "programa_terminal_text")] private static extern int TextNative(SafeSessionHandle session, uint maxLines, out Buffer buffer);
    internal static string Text(SafeSessionHandle session, uint maxLines) => TextNative(session, maxLines, out var buffer) == 0 ? ReadAndFree(buffer) : string.Empty;
    [DllImport(Dll, EntryPoint = "programa_terminal_shell_pid")] internal static extern uint ShellPid(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_cwd_generation")] internal static extern ulong CwdGeneration(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_cwd")] private static extern int CwdNative(SafeSessionHandle session, out Buffer buffer);
    internal static string Cwd(SafeSessionHandle session) => CwdNative(session, out var buffer) == 0 ? ReadAndFree(buffer) : string.Empty;
    [DllImport(Dll, EntryPoint = "programa_terminal_link_at")] private static extern int LinkAtNative(SafeSessionHandle session, nuint column, nuint row, out Buffer buffer);
    internal static string LinkAt(SafeSessionHandle session, nuint column, nuint row) => LinkAtNative(session, column, row, out var buffer) == 0 ? ReadAndFree(buffer) : string.Empty;
    [DllImport(Dll, EntryPoint = "programa_terminal_selection_clear")] internal static extern int ClearSelection(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_copy_mode")] internal static extern int CopyMode(SafeSessionHandle session, uint command, uint count);
    [DllImport(Dll, EntryPoint = "programa_terminal_clear_scrollback")] internal static extern int ClearScrollback(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_reset")] internal static extern int Reset(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_take_notifications")] private static extern int TakeNotificationsNative(SafeSessionHandle session, out Buffer buffer);
    internal static TerminalNotification[] TakeNotifications(SafeSessionHandle session)
    {
        var json = TakeNotificationsNative(session, out var buffer) == 0 ? ReadAndFree(buffer) : string.Empty;
        if (json.Length == 0) return [];
        try { return JsonSerializer.Deserialize<TerminalNotification[]>(json, TerminalJson.Options) ?? []; }
        catch (JsonException) { return []; }
    }
    [DllImport(Dll, EntryPoint = "programa_terminal_event_handle")] internal static extern nint EventHandle(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_acknowledge_generation")] internal static extern int Acknowledge(SafeSessionHandle session, ulong generation);
    [DllImport(Dll, EntryPoint = "programa_terminal_selection_begin")] internal static extern int SelectionBegin(SafeSessionHandle session, nuint col, nuint row, uint mode);
    [DllImport(Dll, EntryPoint = "programa_terminal_selection_update")] internal static extern int SelectionUpdate(SafeSessionHandle session, nuint col, nuint row);
    [DllImport(Dll, EntryPoint = "programa_terminal_selection_end")] internal static extern int SelectionEnd(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_copy_selection")] internal static extern int CopySelection(SafeSessionHandle session, out Buffer buffer);
    [DllImport(Dll, EntryPoint = "programa_terminal_is_terminated")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool IsTerminated(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_paste_needs_confirmation")]
    [return: MarshalAs(UnmanagedType.I1)] private static extern bool PasteNeedsConfirmationNative(SafeSessionHandle session, byte[] data, nuint length);
    [DllImport(Dll, EntryPoint = "programa_terminal_paste")] private static extern int PasteNative(SafeSessionHandle session, byte[] data, nuint length, [MarshalAs(UnmanagedType.I1)] bool bracketed);

    internal static SafeSessionHandle? Create(byte[] config, out string error)
    {
        var session = CreateNative(config, (nuint)config.Length, out var buffer);
        error = ReadAndFree(buffer);
        return session.IsInvalid ? null : session;
    }
    internal static int Write(SafeSessionHandle session, byte[] data) => WriteNative(session, data, (nuint)data.Length);
    internal static int Paste(SafeSessionHandle session, byte[] data, bool bracketed) => PasteNative(session, data, (nuint)data.Length, bracketed);
    internal static bool PasteNeedsConfirmation(SafeSessionHandle session, byte[] data) => PasteNeedsConfirmationNative(session, data, (nuint)data.Length);
    internal static bool TryCopySelection(SafeSessionHandle session, out string value)
    {
        var status = CopySelection(session, out var buffer);
        value = ReadAndFree(buffer);
        return status == 0;
    }
    internal static bool TryProgramStatus(SafeSessionHandle session, out string value)
    {
        var status = ProgramStatusJson(session, out var buffer);
        value = ReadAndFree(buffer);
        return status == 0;
    }
    internal static bool TrySnapshot(SafeSessionHandle session, out string value)
    {
        var status = Snapshot(session, out var buffer);
        value = ReadAndFree(buffer);
        return status == 0;
    }
    private static string ReadAndFree(Buffer buffer)
    {
        if (buffer.Data == nint.Zero || buffer.Length == 0) return string.Empty;
        try { return Marshal.PtrToStringUTF8(buffer.Data, checked((int)buffer.Length)) ?? string.Empty; }
        finally { FreeBuffer(buffer.Data, buffer.Length); }
    }
}

internal static class TerminalJson
{
    internal static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
}

internal sealed record TerminalSnapshot(ulong Generation, int Columns, int Rows, int DisplayOffset, TerminalCursor Cursor, TerminalSelection? Selection, List<TerminalCell> Cells, bool Terminated, string? Title = null);
internal sealed record TerminalCursor(int Column, int Row, bool Visible, string Shape = "block");
internal sealed record TerminalSelection(int StartColumn, int StartRow, int EndColumn, int EndRow, bool Block);
internal sealed record TerminalCell(int Column, int Row, string Text, int Width, TerminalColor Foreground, bool ExplicitForeground, TerminalColor Background, bool ExplicitBackground, bool Selected, bool Bold, bool Italic, bool Underline, bool Undercurl, bool Strikethrough, bool Dim = false);
internal sealed record TerminalNotification(string Title, string Body);
internal sealed record ProgramStatusSnapshot(ulong Generation, ProgramStatusRecord? Root);
internal sealed record ProgramStatusRecord(string State, string? Kind, int? Progress, string? App, string? Title, string? Msg);
internal sealed record TerminalColor(byte R, byte G, byte B, byte A) { internal Color ToColor() => Color.FromArgb(A, R, G, B); }

internal static class KeyboardLayout
{
    private const uint MapVkToChar = 2;

    [DllImport("user32.dll", EntryPoint = "MapVirtualKeyW")]
    private static extern uint MapVirtualKey(uint code, uint mapType);

    /// <summary>The printable ASCII character a key types without modifiers on the active layout,
    /// or null for dead keys and anything outside ASCII.</summary>
    internal static int? UnshiftedCharacter(VirtualKey key)
    {
        var mapped = MapVirtualKey((uint)key, MapVkToChar);
        // The high bit marks a dead key.
        return mapped is >= 0x20 and < 0x7F ? (int)mapped : null;
    }
}
