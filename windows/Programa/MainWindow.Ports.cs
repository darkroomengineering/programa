using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.ApplicationModel.DataTransfer;

namespace Programa;

/// <summary>The Ports button in the sidebar footer and its Listening Ports panel, as on macOS:
/// TCP ports that processes started from Programa terminals listen on, grouped by workspace, plus
/// processes left running after their terminal closed. Scanned every 3 seconds.</summary>
public sealed partial class MainWindow
{
    internal sealed record PortEntry(int Port, uint Pid, string Command, string WorkspaceId, string SurfaceId);
    internal sealed record LeftRunningEntry(uint Pid, string Command, List<int> Ports, string WorkspaceTitle, DateTimeOffset ClosedAt);

    private List<PortEntry> _ports = [];
    private List<LeftRunningEntry> _leftRunning = [];
    /// <summary>Listeners last seen under a terminal: their program and workspace, so one still
    /// listening after its terminal closed is recognized as left running.</summary>
    private readonly Dictionary<uint, (string Command, string WorkspaceTitle, DateTimeOffset? ClosedAt)> _portOwners = [];
    private Button? _portsButton;
    private TextBlock? _portsCount;

    private void StartPortScan()
    {
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(3);
        timer.Tick += (_, _) => ScanPorts();
        timer.Start();
        Closed += (_, _) => timer.Stop();
    }

    private void ScanPorts()
    {
        var shells = _terminals.Values.Where(terminal => terminal.ShellPid != 0).GroupBy(terminal => terminal.ShellPid).ToDictionary(group => group.Key, group => group.First());
        var shellPids = shells.Keys.ToHashSet();
        var processes = ProcessTree.Snapshot();
        var ports = new List<PortEntry>();
        var orphans = new Dictionary<uint, List<int>>();
        foreach (var (port, pid) in ProcessTree.ListeningPorts())
        {
            if (pid == Environment.ProcessId) continue;
            var command = processes.TryGetValue(pid, out var process) ? Path.GetFileNameWithoutExtension(process.Name) : string.Empty;
            if (ProcessTree.OwningShell(pid, processes, shellPids) is var shell and not 0)
            {
                var terminal = shells[shell];
                ports.Add(new PortEntry(port, pid, command, terminal.WorkspaceId, terminal.SurfaceId));
                var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == terminal.WorkspaceId);
                _portOwners[pid] = (command, workspace is null ? string.Empty : WorkspaceTitle(workspace), null);
            }
            // Only the same program under the same pid counts; a reused pid is someone else's.
            else if (_portOwners.TryGetValue(pid, out var owner) && owner.Command == command)
            {
                if (!orphans.TryGetValue(pid, out var list)) orphans[pid] = list = [];
                list.Add(port);
            }
        }
        foreach (var pid in _portOwners.Keys.ToList())
        {
            var owner = _portOwners[pid];
            if (orphans.ContainsKey(pid)) _portOwners[pid] = owner with { ClosedAt = owner.ClosedAt ?? DateTimeOffset.Now };
            else if (!ports.Any(entry => entry.Pid == pid)) _portOwners.Remove(pid);
        }
        _ports = ports;
        _leftRunning = orphans.Select(item => new LeftRunningEntry(item.Key, _portOwners[item.Key].Command, item.Value, _portOwners[item.Key].WorkspaceTitle, _portOwners[item.Key].ClosedAt!.Value)).ToList();
        UpdatePortsButton();
    }

    /// <summary>The footer's Ports button: a count of listening ports, shown only while something listens.</summary>
    private Button PortsButton()
    {
        _portsCount = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new FontIcon { Glyph = "", FontSize = 14 });
        content.Children.Add(_portsCount);
        _portsButton = new Button { Content = content, Height = 32, Padding = new Thickness(10, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center, Background = ThemeBrush("SubtleFillColorTransparentBrush"), BorderThickness = new Thickness(0) };
        _portsButton.Click += (_, _) => ShowPortsPanel();
        UpdatePortsButton();
        return _portsButton;
    }

    private void UpdatePortsButton()
    {
        if (_portsButton is null || _portsCount is null) return;
        // Every window's ports, as on macOS; each window scans its own terminals.
        var count = WindowRegistry.Windows.Sum(window => window._ports.Count + window._leftRunning.Sum(entry => entry.Ports.Count));
        _portsCount.Text = count.ToString();
        _portsButton.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var label = Localizer.Get("PortsTitle");
        AutomationProperties.SetName(_portsButton, $"{label}: {count}");
        ToolTipService.SetToolTip(_portsButton, label);
    }

    private void ShowPortsPanel()
    {
        if (_portsButton is null) return;
        var panel = new StackPanel { Spacing = 4, MinWidth = 340 };
        panel.Children.Add(new TextBlock { Text = Localizer.Get("PortsTitle"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 4) });
        var flyout = new Flyout { Placement = FlyoutPlacementMode.TopEdgeAlignedLeft };
        foreach (var window in WindowRegistry.Windows)
        {
            foreach (var workspace in window._snapshot.Workspaces)
            {
                var entries = window._ports.Where(entry => entry.WorkspaceId == workspace.Id).ToList();
                if (entries.Count == 0) continue;
                panel.Children.Add(SectionHeader(window.WorkspaceTitle(workspace)));
                foreach (var entry in entries)
                    panel.Children.Add(PortRow(entry.Command, entry.Port, entry.Pid, flyout, () =>
                    {
                        window.Activate();
                        window.RevealPort(entry);
                    }));
            }
        }
        var leftRunning = WindowRegistry.Windows.SelectMany(window => window._leftRunning).ToList();
        if (leftRunning.Count > 0)
        {
            panel.Children.Add(SectionHeader(Localizer.Get("PortsLeftRunning")));
            foreach (var entry in leftRunning)
                foreach (var port in entry.Ports)
                    panel.Children.Add(PortRow(entry.Command, port, entry.Pid, flyout, reveal: null));
        }
        flyout.Content = new ScrollViewer { Content = panel, MaxHeight = 420 };
        ShowFooterFlyout(flyout, _portsButton);
    }

    private static TextBlock SectionHeader(string text) =>
        new() { Text = text, FontSize = 12, Opacity = 0.7, Margin = new Thickness(0, 6, 0, 0), TextTrimming = TextTrimming.CharacterEllipsis };

    private FrameworkElement PortRow(string command, int port, uint pid, Flyout flyout, Action? reveal)
    {
        var url = $"http://localhost:{port}";
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = $"{(command.Length > 0 ? command : Localizer.Get("PortsUnnamed"))}  :{port}", TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock { Text = string.Format(Localizer.Get("PortsPid"), pid), FontSize = 11, Opacity = 0.6 });
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(PortAction("", "PortsOpen", () => _ = Windows.System.Launcher.LaunchUriAsync(new Uri(url))));
        actions.Children.Add(PortAction("", "PortsCopyUrl", () =>
        {
            var package = new DataPackage();
            package.SetText(url);
            Clipboard.SetContent(package);
        }));
        if (reveal is not null) actions.Children.Add(PortAction("", "PortsReveal", () => { flyout.Hide(); reveal(); }));
        actions.Children.Add(PortAction("", "PortsStop", () => { flyout.Hide(); _ = ConfirmStopPortAsync(command, port, pid); }));
        row.Children.Add(text);
        row.Children.Add(actions);
        Grid.SetColumn(actions, 1);
        return row;
    }

    private static Button PortAction(string glyph, string labelKey, Action handler)
    {
        var label = Localizer.Get(labelKey);
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 13 }, Width = 32, Height = 30, Padding = new Thickness(0), Background = ThemeBrush("SubtleFillColorTransparentBrush"), BorderThickness = new Thickness(0) };
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        button.Click += (_, _) => handler();
        return button;
    }

    private void RevealPort(PortEntry entry)
    {
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Id == entry.WorkspaceId) is not { } workspace) return;
        if (workspace.Panes.FirstOrDefault(pane => pane.Surfaces.Any(surface => surface.Id == entry.SurfaceId)) is not { } pane) return;
        Apply(new { command = "select_workspace", workspace_id = workspace.Id });
        Apply(new { command = "select_surface", workspace_id = workspace.Id, pane_id = pane.Id, surface_id = entry.SurfaceId });
        _terminals.GetValueOrDefault(entry.SurfaceId)?.FocusTerminal();
    }

    /// <summary>Asks first, with Cancel as the default button so a stray Enter stops nothing.</summary>
    private async Task ConfirmStopPortAsync(string command, int port, uint pid)
    {
        if (_dialogOpen || Root.XamlRoot is null) return;
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = string.Format(Localizer.Get("PortsStopTitle"), command, port),
            Content = string.Format(Localizer.Get("PortsStopMessage"), pid),
            PrimaryButtonText = Localizer.Get("PortsStop"),
            CloseButtonText = Localizer.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        _dialogOpen = true;
        try { if (await dialog.ShowAsync() != ContentDialogResult.Primary) return; }
        finally { _dialogOpen = false; }
        // The window whose terminal runs it sends the Ctrl+C.
        (WindowRegistry.Windows.FirstOrDefault(window => window.HasPortProcess((int)pid)) ?? this).StopPort(pid);
    }

    /// <summary>Windows has no SIGTERM: a process under a terminal gets Ctrl+C through that terminal,
    /// as if you pressed it there, then is force-stopped if it still runs 3 seconds later. A process
    /// left running has no terminal and is force-stopped at once.</summary>
    private void StopPort(uint pid)
    {
        Process process;
        try { process = Process.GetProcessById((int)pid); }
        catch (ArgumentException) { return; }
        if (_ports.FirstOrDefault(entry => entry.Pid == pid) is { } entry && _terminals.TryGetValue(entry.SurfaceId, out var terminal))
        {
            terminal.SendText("\x03");
            _ = Task.Run(async () =>
            {
                using (process)
                {
                    if (!process.WaitForExit(3000)) try { process.Kill(); } catch (Exception) { }
                }
                DispatcherQueue.TryEnqueue(ScanPorts);
            });
            return;
        }
        using (process) try { process.Kill(); } catch (Exception) { }
        ScanPorts();
    }

    /// <summary>This window's workspaces with listening ports, for `ports.list` across windows.</summary>
    internal IEnumerable<object> DescribePortWorkspaces() => _snapshot.Workspaces
        .Select(workspace => new
        {
            id = workspace.Id,
            title = WorkspaceTitle(workspace),
            window_id = WindowId,
            ports = _ports.Where(entry => entry.WorkspaceId == workspace.Id).Select(entry => new { port = entry.Port, pid = entry.Pid, command = entry.Command, surface_id = entry.SurfaceId }).ToList(),
        })
        .Where(workspace => workspace.ports.Count > 0)
        .ToList();

    internal IEnumerable<object> DescribeLeftRunning() =>
        _leftRunning.Select(entry => new { pid = entry.Pid, command = entry.Command, ports = entry.Ports, workspace_title = entry.WorkspaceTitle, closed_at = entry.ClosedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }).ToList();

    internal void RescanPorts() => ScanPorts();

    internal bool HasPortProcess(int pid) => _ports.Any(entry => entry.Pid == pid) || _leftRunning.Any(entry => entry.Pid == pid);

    private object StopPortFromControl(JsonElement p)
    {
        var pid = Number(p, "pid") ?? throw new ControlException("invalid_params", "pid is required.");
        if (pid <= 4 || pid == Environment.ProcessId) throw new ControlException("invalid_params", $"pid {pid} cannot be stopped.");
        // Only what ports.list reports, checked against a fresh scan so an exited or reused pid is refused.
        ScanPorts();
        if (_ports.All(entry => entry.Pid != pid) && _leftRunning.All(entry => entry.Pid != pid)) throw NotFound("pid", pid.ToString());
        StopPort((uint)pid);
        return new { pid, signaled = true };
    }
}
