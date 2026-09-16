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

public sealed class TerminalView : UserControl, IDisposable
{
    private const float FontSize = 13f;
    private const float CellWidth = 8f;
    private const float CellHeight = 18f;

    private readonly Grid _root = new();
    private readonly CanvasControl _canvas = new();
    private readonly TextBox _input = new();
    private readonly Border _spawnFailure = new();
    private readonly TextBlock _spawnFailureDetail = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button _retry = new();
    private readonly object _snapshotGate = new();
    private readonly AccessibilitySettings _accessibilitySettings = new();
    private readonly UISettings _uiSettings = new();
    private readonly CanvasTextFormat _normalFormat = CreateTextFormat(bold: false, italic: false);
    private readonly CanvasTextFormat _boldFormat = CreateTextFormat(bold: true, italic: false);
    private readonly CanvasTextFormat _italicFormat = CreateTextFormat(bold: false, italic: true);
    private readonly CanvasTextFormat _boldItalicFormat = CreateTextFormat(bold: true, italic: true);
    private NativeTerminal.SafeSessionHandle? _session;
    private RegisteredWaitHandle? _registeredWait;
    private EventWaitHandle? _event;
    private TerminalSnapshot? _snapshot;
    private string _automationValue = string.Empty;
    private bool _resettingInput;
    private bool _composing;
    private bool _disposed;
    private bool _selecting;
    private ulong _paintedGeneration;
    private DateTimeOffset _lastClick;
    private Point _lastClickPoint;
    private uint _clickCount;

    public TerminalView(string surfaceId, string sessionId)
    {
        SurfaceId = surfaceId;
        SessionId = sessionId;
        IsTabStop = true;
        AutomationProperties.SetName(this, Localizer.Get("TerminalAccessibilityName"));

        _canvas.ClearColor = Colors.Transparent;
        _canvas.Draw += DrawTerminal;
        _canvas.SizeChanged += (_, _) => ResizeBackend();
        _canvas.PointerPressed += PointerPressed;
        _canvas.PointerMoved += PointerMoved;
        _canvas.PointerReleased += PointerReleased;
        _canvas.PointerWheelChanged += PointerWheelChanged;
        _canvas.ContextFlyout = BuildContextMenu();
        _root.Children.Add(_canvas);

        _input.Opacity = 0.01;
        _input.Width = 1;
        _input.Height = 1;
        _input.HorizontalAlignment = HorizontalAlignment.Left;
        _input.VerticalAlignment = VerticalAlignment.Top;
        _input.IsSpellCheckEnabled = false;
        _input.IsTextPredictionEnabled = false;
        _input.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        _input.FontSize = FontSize;
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
            if (session is null) StartSession();
            else Refresh(session);
        };
        ActualThemeChanged += (_, _) =>
        {
            if (_composing) ShowCompositionProxy();
            _canvas.Invalidate();
        };
    }

    public string SurfaceId { get; }
    public string SessionId { get; }

    public void FocusTerminal() => _input.Focus(FocusState.Programmatic);

    public void Copy()
    {
        if (_session is null || !NativeTerminal.TryCopySelection(_session, out var text) || string.IsNullOrEmpty(text))
            return;
        var package = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    public async void Paste()
    {
        if (_session is null) return;
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text)) return;
        try
        {
            var text = await content.GetTextAsync();
            NativeTerminal.Paste(_session, Encoding.UTF8.GetBytes(text), true);
        }
        catch (Exception error)
        {
            System.Diagnostics.Debug.WriteLine($"Clipboard paste failed: {error}");
        }
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

    private void StartSession()
    {
        if (_disposed) return;
        RetireCurrentSession();
        _paintedGeneration = 0;
        lock (_snapshotGate) _snapshot = null;
        _automationValue = string.Empty;
        _spawnFailure.Visibility = Visibility.Collapsed;

        var config = JsonSerializer.SerializeToUtf8Bytes(new { cols = 80, rows = 24, cell_width = (ushort)CellWidth, cell_height = (ushort)CellHeight });
        var session = NativeTerminal.Create(config, out var error);
        if (session is null || session.IsInvalid)
        {
            _spawnFailureDetail.Text = string.IsNullOrWhiteSpace(error) ? Localizer.Get("TerminalSpawnFailed") : error;
            _spawnFailure.Visibility = Visibility.Visible;
            return;
        }
        _session = session;
        var handle = NativeTerminal.EventHandle(session);
        if (handle != nint.Zero)
            _event = new EventWaitHandle(false, EventResetMode.ManualReset) { SafeWaitHandle = new SafeWaitHandle(handle, ownsHandle: false) };
        ResizeBackend();
        Refresh(session);
        FocusTerminal();
    }

    private void Refresh(NativeTerminal.SafeSessionHandle session)
    {
        if (_disposed || !ReferenceEquals(_session, session)) return;
        var generation = NativeTerminal.Generation(session);
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
            UpdateInputProxyLayout(snapshot.Cursor, _composing);
            _canvas.Invalidate();
            FrameworkElementAutomationPeer.FromElement(this)?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
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

    private void ResizeBackend()
    {
        if (_session is null || _canvas.ActualWidth <= 0 || _canvas.ActualHeight <= 0) return;
        var cols = (ushort)Math.Clamp((int)(_canvas.ActualWidth / CellWidth), 2, ushort.MaxValue);
        var rows = (ushort)Math.Clamp((int)(_canvas.ActualHeight / CellHeight), 2, ushort.MaxValue);
        var dpiScale = _canvas.Dpi / 96f;
        var cellWidth = (ushort)Math.Clamp((int)Math.Round(CellWidth * dpiScale), 1, ushort.MaxValue);
        var cellHeight = (ushort)Math.Clamp((int)Math.Round(CellHeight * dpiScale), 1, ushort.MaxValue);
        NativeTerminal.Resize(_session, cols, rows, cellWidth, cellHeight);
        TerminalSnapshot? snapshot;
        lock (_snapshotGate) snapshot = _snapshot;
        if (snapshot is not null) UpdateInputProxyLayout(snapshot.Cursor, _composing);
    }

    private static CanvasTextFormat CreateTextFormat(bool bold, bool italic) => new()
    {
        FontFamily = "Cascadia Mono, Consolas",
        FontSize = FontSize,
        FontWeight = bold ? FontWeights.Bold : FontWeights.Normal,
        FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
        Options = CanvasDrawTextOptions.EnableColorFont,
    };

    private void ShowCompositionProxy()
    {
        TerminalSnapshot? snapshot;
        lock (_snapshotGate) snapshot = _snapshot;
        var dark = ActualTheme != ElementTheme.Light;
        var foreground = _accessibilitySettings.HighContrast
            ? _uiSettings.GetColorValue(UIColorType.Foreground)
            : dark ? Color.FromArgb(255, 220, 220, 220) : Color.FromArgb(255, 28, 28, 30);
        _input.Foreground = new SolidColorBrush(foreground);
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
        var minimumWidth = Math.Min(CellWidth, viewportWidth);
        var height = composing ? Math.Min(CellHeight, viewportHeight) : 1;
        var maximumX = composing ? viewportWidth - minimumWidth : viewportWidth - 1;
        var x = Math.Clamp(cursor.Column * CellWidth, 0, maximumX);
        var y = Math.Clamp(cursor.Row * CellHeight, 0, viewportHeight - height);

        _input.Margin = new Thickness(x, y, 0, 0);
        _input.Width = composing ? Math.Max(1, Math.Min(320, viewportWidth - x)) : 1;
        _input.Height = height;
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
        var dark = sender.ActualTheme != ElementTheme.Light;
        var defaultBackground = _accessibilitySettings.HighContrast ? _uiSettings.GetColorValue(UIColorType.Background) : dark ? Color.FromArgb(255, 20, 20, 24) : Color.FromArgb(255, 250, 250, 250);
        var defaultForeground = _accessibilitySettings.HighContrast ? _uiSettings.GetColorValue(UIColorType.Foreground) : dark ? Color.FromArgb(255, 220, 220, 220) : Color.FromArgb(255, 28, 28, 30);
        args.DrawingSession.Clear(defaultBackground);
        if (snapshot is null) return;

        foreach (var cell in snapshot.Cells)
        {
            var x = cell.Column * CellWidth;
            var y = cell.Row * CellHeight;
            if (cell.ExplicitBackground)
                args.DrawingSession.FillRectangle(x, y, CellWidth * Math.Max(cell.Width, 1), CellHeight, cell.Background.ToColor());
            if (cell.Selected)
                args.DrawingSession.FillRectangle(x, y, CellWidth * Math.Max(cell.Width, 1), CellHeight, Color.FromArgb(180, 48, 105, 152));
            if (cell.Width == 0 || string.IsNullOrEmpty(cell.Text)) continue;
            var format = cell.Bold
                ? cell.Italic ? _boldItalicFormat : _boldFormat
                : cell.Italic ? _italicFormat : _normalFormat;
            args.DrawingSession.DrawText(cell.Text, new Vector2(x, y), cell.ExplicitForeground ? cell.Foreground.ToColor() : defaultForeground, format);
            if (cell.Underline || cell.Undercurl)
                args.DrawingSession.DrawLine(x, y + CellHeight - 2, x + CellWidth * Math.Max(cell.Width, 1), y + CellHeight - 2, cell.Foreground.ToColor(), 1);
            if (cell.Strikethrough)
                args.DrawingSession.DrawLine(x, y + CellHeight / 2, x + CellWidth * Math.Max(cell.Width, 1), y + CellHeight / 2, cell.Foreground.ToColor(), 1);
        }
        if (snapshot.Cursor.Visible)
            args.DrawingSession.DrawRectangle(snapshot.Cursor.Column * CellWidth, snapshot.Cursor.Row * CellHeight, CellWidth, CellHeight, Color.FromArgb(255, 120, 190, 255), 1);
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
        NativeTerminal.Write(_session, Encoding.UTF8.GetBytes(_input.Text));
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
        var appCursor = NativeTerminal.ApplicationCursor(_session);
        byte[]? bytes = args.Key switch
        {
            VirtualKey.Enter => [13], VirtualKey.Back => [127],
            VirtualKey.Tab when !ctrl && !alt => shift ? [27, 91, 90] : [9],
            VirtualKey.Escape => [27],
            VirtualKey.Up => Encoding.ASCII.GetBytes(appCursor ? "\x1bOA" : "\x1b[A"), VirtualKey.Down => Encoding.ASCII.GetBytes(appCursor ? "\x1bOB" : "\x1b[B"),
            VirtualKey.Right => Encoding.ASCII.GetBytes(appCursor ? "\x1bOC" : "\x1b[C"), VirtualKey.Left => Encoding.ASCII.GetBytes(appCursor ? "\x1bOD" : "\x1b[D"),
            VirtualKey.Home => Encoding.ASCII.GetBytes("\x1b[H"), VirtualKey.End => Encoding.ASCII.GetBytes("\x1b[F"),
            VirtualKey.PageUp => Encoding.ASCII.GetBytes("\x1b[5~"), VirtualKey.PageDown => Encoding.ASCII.GetBytes("\x1b[6~"),
            VirtualKey.Delete => Encoding.ASCII.GetBytes("\x1b[3~"),
            >= VirtualKey.A and <= VirtualKey.Z when ctrl && !alt => [(byte)((int)args.Key - (int)VirtualKey.A + 1)],
            _ => null,
        };
        if (bytes is null) return;
        NativeTerminal.Write(_session, bytes);
        args.Handled = true;
    }

    private void PointerPressed(object sender, PointerRoutedEventArgs args)
    {
        if (_session is null) return;
        var point = args.GetCurrentPoint(_canvas);
        if (!point.Properties.IsLeftButtonPressed) return;
        var now = DateTimeOffset.UtcNow;
        var nearby = Math.Abs(point.Position.X - _lastClickPoint.X) < CellWidth && Math.Abs(point.Position.Y - _lastClickPoint.Y) < CellHeight;
        _clickCount = nearby && now - _lastClick < TimeSpan.FromMilliseconds(500) ? Math.Min(_clickCount + 1, 3u) : 1;
        _lastClick = now;
        _lastClickPoint = point.Position;
        var mode = _clickCount == 2 ? 2u : _clickCount >= 3 ? 3u : 0u;
        var (col, row) = CellAt(point.Position);
        NativeTerminal.SelectionBegin(_session, col, row, mode);
        _selecting = true;
        _canvas.CapturePointer(args.Pointer);
        FocusTerminal();
        args.Handled = true;
    }

    private void PointerMoved(object sender, PointerRoutedEventArgs args)
    {
        if (!_selecting || _session is null) return;
        var (col, row) = CellAt(args.GetCurrentPoint(_canvas).Position);
        NativeTerminal.SelectionUpdate(_session, col, row);
    }

    private void PointerReleased(object sender, PointerRoutedEventArgs args)
    {
        if (!_selecting) return;
        _selecting = false;
        if (_session is not null) NativeTerminal.SelectionEnd(_session);
        _canvas.ReleasePointerCapture(args.Pointer);
    }

    private void PointerWheelChanged(object sender, PointerRoutedEventArgs args)
    {
        if (_session is null) return;
        var delta = args.GetCurrentPoint(_canvas).Properties.MouseWheelDelta;
        NativeTerminal.Scroll(_session, Math.Sign(delta) * 3);
        args.Handled = true;
    }

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();
        var copy = new MenuFlyoutItem { Text = Localizer.Get("TerminalCopy") };
        copy.Click += (_, _) => Copy();
        var paste = new MenuFlyoutItem { Text = Localizer.Get("TerminalPaste") };
        paste.Click += (_, _) => Paste();
        menu.Items.Add(copy);
        menu.Items.Add(paste);
        return menu;
    }

    private static (nuint Col, nuint Row) CellAt(Point point) => ((nuint)Math.Max(0, (int)(point.X / CellWidth)), (nuint)Math.Max(0, (int)(point.Y / CellHeight)));

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
    [DllImport(Dll, EntryPoint = "programa_terminal_buffer_free")] private static extern void FreeBuffer(nint data, nuint length);
    [DllImport(Dll, EntryPoint = "programa_terminal_write")] private static extern int WriteNative(SafeSessionHandle session, byte[] data, nuint length);
    [DllImport(Dll, EntryPoint = "programa_terminal_resize")] internal static extern int Resize(SafeSessionHandle session, ushort cols, ushort rows, ushort cellWidth, ushort cellHeight);
    [DllImport(Dll, EntryPoint = "programa_terminal_scroll")] internal static extern int Scroll(SafeSessionHandle session, int lines);
    [DllImport(Dll, EntryPoint = "programa_terminal_snapshot_json")] internal static extern int Snapshot(SafeSessionHandle session, out Buffer buffer);
    [DllImport(Dll, EntryPoint = "programa_terminal_generation")] internal static extern ulong Generation(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_application_cursor")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool ApplicationCursor(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_event_handle")] internal static extern nint EventHandle(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_acknowledge_generation")] internal static extern int Acknowledge(SafeSessionHandle session, ulong generation);
    [DllImport(Dll, EntryPoint = "programa_terminal_selection_begin")] internal static extern int SelectionBegin(SafeSessionHandle session, nuint col, nuint row, uint mode);
    [DllImport(Dll, EntryPoint = "programa_terminal_selection_update")] internal static extern int SelectionUpdate(SafeSessionHandle session, nuint col, nuint row);
    [DllImport(Dll, EntryPoint = "programa_terminal_selection_end")] internal static extern int SelectionEnd(SafeSessionHandle session);
    [DllImport(Dll, EntryPoint = "programa_terminal_copy_selection")] internal static extern int CopySelection(SafeSessionHandle session, out Buffer buffer);
    [DllImport(Dll, EntryPoint = "programa_terminal_paste")] private static extern int PasteNative(SafeSessionHandle session, byte[] data, nuint length, [MarshalAs(UnmanagedType.I1)] bool bracketed);

    internal static SafeSessionHandle? Create(byte[] config, out string error)
    {
        var session = CreateNative(config, (nuint)config.Length, out var buffer);
        error = ReadAndFree(buffer);
        return session.IsInvalid ? null : session;
    }
    internal static int Write(SafeSessionHandle session, byte[] data) => WriteNative(session, data, (nuint)data.Length);
    internal static int Paste(SafeSessionHandle session, byte[] data, bool bracketed) => PasteNative(session, data, (nuint)data.Length, bracketed);
    internal static bool TryCopySelection(SafeSessionHandle session, out string value)
    {
        var status = CopySelection(session, out var buffer);
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

internal sealed record TerminalSnapshot(ulong Generation, int Columns, int Rows, int DisplayOffset, TerminalCursor Cursor, TerminalSelection? Selection, List<TerminalCell> Cells, bool Terminated);
internal sealed record TerminalCursor(int Column, int Row, bool Visible);
internal sealed record TerminalSelection(int StartColumn, int StartRow, int EndColumn, int EndRow, bool Block);
internal sealed record TerminalCell(int Column, int Row, string Text, int Width, TerminalColor Foreground, bool ExplicitForeground, TerminalColor Background, bool ExplicitBackground, bool Selected, bool Bold, bool Italic, bool Underline, bool Undercurl, bool Strikethrough);
internal sealed record TerminalColor(byte R, byte G, byte B, byte A) { internal Color ToColor() => Color.FromArgb(A, R, G, B); }
