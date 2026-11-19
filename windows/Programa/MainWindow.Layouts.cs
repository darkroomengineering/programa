using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>Named layouts as on macOS: `layout.save/apply/list`, `programa layout`, and the palette's
/// Save current layout…, Apply/Rename/Delete layout: &lt;name&gt; and the built-in presets.</summary>
public sealed partial class MainWindow
{
    internal sealed record TerminalSpec(string? Cwd, string? Command, IReadOnlyDictionary<string, string>? Env);

    /// <summary>What a layout asked of each surface it created, consumed when its terminal starts.</summary>
    private readonly Dictionary<string, TerminalSpec> _pendingTerminals = new(StringComparer.Ordinal);

    /// <summary>Builds <paramref name="layout"/> in a new workspace (selected when <paramref name="focus"/>)
    /// or in an unused one, with relative directories resolved against <paramref name="baseDirectory"/>.</summary>
    private string ApplyLayout(LayoutNode layout, string? workspaceId, string? baseDirectory, bool focus, string? title = null)
    {
        var root = baseDirectory ?? ActiveTerminal()?.Cwd ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var previous = SelectedWorkspace();
        var previousPane = previous?.SelectedPane;
        string paneId, surfaceId;
        if (workspaceId is null)
        {
            workspaceId = Id("workspace");
            paneId = Id("pane");
            surfaceId = Id("surface");
            _snapshot = Dispatch(new { command = "create_workspace", workspace_id = workspaceId, pane_id = paneId, surface_id = surfaceId, session_id = Id("session") });
        }
        else
        {
            var id = workspaceId;
            var workspace = _snapshot.Workspaces.FirstOrDefault(item => item.Id == id) ?? throw NotFound("workspace", id);
            if (workspace.Panes.Count != 1 || workspace.Panes[0].Surfaces.Count != 1)
                throw new ControlException("invalid_params", "A layout only fills a workspace with a single tab.");
            paneId = workspace.Panes[0].Id;
            surfaceId = workspace.Panes[0].Surfaces[0].Id;
        }
        (string Pane, string Surface)? focusTarget = null;
        Build(layout, paneId, surfaceId);
        if (title is not null) _snapshot = Dispatch(new { command = "rename_workspace", workspace_id = workspaceId, title });
        if (focusTarget is { } target) _snapshot = Dispatch(new { command = "select_surface", workspace_id = workspaceId, pane_id = target.Pane, surface_id = target.Surface });
        if (focus) _snapshot = Dispatch(new { command = "select_workspace", workspace_id = workspaceId });
        else if (previous is not null && previousPane is not null)
            _snapshot = Dispatch(new { command = "select_surface", workspace_id = previous.Id, pane_id = previousPane.Id, surface_id = previousPane.SelectedSurfaceId });
        ProjectSnapshot();
        // Terminals in a workspace that is not on screen start now, so their commands run.
        var created = _snapshot.Workspaces.First(item => item.Id == workspaceId);
        foreach (var surface in created.Panes.SelectMany(pane => pane.Surfaces)) TerminalFor(workspaceId, surface.Id).EnsureStarted();
        return workspaceId;

        void Build(LayoutNode node, string pane, string firstSurface)
        {
            if (node is LayoutSplit split)
            {
                var newPane = Id("pane");
                var newSurface = Id("surface");
                // The file's "horizontal" is side by side, which the core calls a vertical split.
                var direction = split.Direction == "horizontal" ? "vertical" : "horizontal";
                _snapshot = Dispatch(new { command = "split_pane", workspace_id = workspaceId, pane_id = pane, split_id = Id("split"), new_pane_id = newPane, new_surface_id = newSurface, session_id = Id("session"), direction, ratio = split.Split });
                Build(split.First, pane, firstSurface);
                Build(split.Second, newPane, newSurface);
                return;
            }
            var surfaces = ((LayoutPane)node).Surfaces;
            for (var index = 0; index < surfaces.Count; index++)
            {
                var surface = surfaces[index];
                var id = index == 0 ? firstSurface : Id("surface");
                if (index > 0) _snapshot = Dispatch(new { command = "create_surface", workspace_id = workspaceId, pane_id = pane, surface_id = id, session_id = Id("session") });
                var spec = new TerminalSpec(ResolveDirectory(root, surface.Cwd), surface.Command, surface.Env);
                // A terminal already running (an unused workspace's) gets the command typed instead.
                if (_terminals.TryGetValue(id, out var running)) { if (surface.Command is { Length: > 0 } command) running.SendText(command + "\n"); }
                else _pendingTerminals[id] = spec;
                if (surface.Name is { Length: > 0 } name) _snapshot = Dispatch(new { command = "rename_surface", workspace_id = workspaceId, pane_id = pane, surface_id = id, title = name });
                if (surface.Focus) focusTarget = (pane, id);
            }
            if (focusTarget is null && surfaces.Count > 1)
                _snapshot = Dispatch(new { command = "select_surface", workspace_id = workspaceId, pane_id = pane, surface_id = firstSurface });
        }
    }

    /// <summary>Empty or "." is the base; "~" is home; anything else relative is under the base.</summary>
    internal static string ResolveDirectory(string root, string? cwd)
    {
        if (string.IsNullOrWhiteSpace(cwd) || cwd == ".") return root;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (cwd == "~") return home;
        if (cwd.StartsWith("~/", StringComparison.Ordinal) || cwd.StartsWith(@"~\", StringComparison.Ordinal)) return Path.GetFullPath(Path.Combine(home, cwd[2..]));
        return Path.GetFullPath(Path.IsPathRooted(cwd) ? cwd : Path.Combine(root, cwd));
    }

    /// <summary>The selected workspace's panes, splits, tab names and directories (relative to the
    /// focused terminal's directory where possible); not commands, variables or focus, as on macOS.</summary>
    private LayoutNode CaptureLayout(WorkspaceSnapshot workspace)
    {
        var root = (workspace.SelectedPane?.SelectedSurfaceId is { } focused ? _terminals.GetValueOrDefault(focused)?.WorkingDirectory : null) ?? string.Empty;
        return Capture(workspace.Layout);

        LayoutNode Capture(LayoutSnapshot node)
        {
            if (node.Type == "split" && node.First is not null && node.Second is not null)
                return new LayoutSplit(node.Direction == "vertical" ? "horizontal" : "vertical", node.Ratio, Capture(node.First), Capture(node.Second));
            var pane = workspace.Panes.First(item => item.Id == node.PaneId);
            return new LayoutPane(pane.Surfaces.Select(surface => new LayoutSurface(
                Name: surface.Title,
                Cwd: RelativeDirectory(root, _terminals.GetValueOrDefault(surface.Id)?.WorkingDirectory))).ToList());
        }
    }

    internal static string? RelativeDirectory(string root, string? directory)
    {
        if (directory is null) return null;
        if (root.Length == 0 || !Worktrees.Contains(root, directory)) return directory;
        var relative = Path.GetRelativePath(root, directory);
        return relative == "." ? null : relative.Replace('\\', '/');
    }

    private object LayoutFromControl(string method, JsonElement p)
    {
        try
        {
            switch (method)
            {
                case "layout.list":
                    return new { layouts = Layouts.All().Where(layout => layout.Error is null).Select(layout => new { name = layout.Name, saved_at = layout.SavedAt?.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }) };
                case "layout.save":
                    var name = Required(p, "name");
                    var workspace = SelectedWorkspace() ?? throw new ControlException("no_active_workspace", "No workspace is selected.");
                    return new { name, path = Layouts.Save(name, CaptureLayout(workspace), Flag(p, "force")) };
                default: // layout.apply
                    var layoutName = Required(p, "name");
                    var saved = Layouts.Find(layoutName);
                    if (saved?.Layout is null) throw new ControlException("not_found", saved?.Error ?? $"No layout named '{layoutName}'.");
                    return new { workspace_id = ApplyLayout(saved.Layout, Text(p, "workspace_id"), Text(p, "cwd"), focus: false) };
            }
        }
        catch (Layouts.LayoutException error)
        {
            throw new ControlException(error.Code, error.Message);
        }
    }

    /// <summary>The palette's layout entries: label, subtitle, action.</summary>
    private IEnumerable<(string Label, string Hint, Action Run)> LayoutPaletteEntries()
    {
        yield return (Localizer.Get("LayoutSave"), string.Empty, () => _ = SaveLayoutFromPaletteAsync(null));
        foreach (var layout in Layouts.All())
        {
            var saved = layout;
            yield return (string.Format(Localizer.Get("LayoutApply"), saved.Name), saved.Error ?? string.Empty, () =>
            {
                if (saved.Layout is null) _ = ShowErrorAsync(Localizer.Get("LayoutBroken"), saved.Error ?? string.Empty);
                else ApplyLayout(saved.Layout, null, null, focus: true);
            });
            yield return (string.Format(Localizer.Get("LayoutRename"), saved.Name), string.Empty, () => _ = RenameLayoutAsync(saved.Name));
            yield return (string.Format(Localizer.Get("LayoutDelete"), saved.Name), string.Empty, () => _ = DeleteLayoutAsync(saved.Name));
        }
        foreach (var (name, preset) in Layouts.Presets)
        {
            var label = Localizer.Get(name == "Agent and Shell" ? "LayoutPresetAgentAndShell" : "LayoutPresetThreeAgents");
            yield return (string.Format(Localizer.Get("LayoutApply"), label), Localizer.Get("LayoutBuiltIn"), () => ApplyLayout(preset, null, null, focus: true, title: label));
            yield return (string.Format(Localizer.Get("LayoutSaveCopy"), label), Localizer.Get("LayoutBuiltIn"), () => _ = SaveLayoutFromPaletteAsync(preset));
        }
    }

    private async Task<string?> AskForNameAsync(string title, string action, string initial)
    {
        if (_dialogOpen || Root.XamlRoot is null) return null;
        var box = new TextBox { Text = initial, MinWidth = 320 };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = box, PrimaryButtonText = action, CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary };
        _dialogOpen = true;
        try { return await dialog.ShowAsync() == ContentDialogResult.Primary && box.Text.Trim().Length > 0 ? box.Text.Trim() : null; }
        finally { _dialogOpen = false; }
    }

    private async Task<bool> ConfirmAsync(string title, string message, string action)
    {
        if (_dialogOpen || Root.XamlRoot is null) return false;
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, Content = message, PrimaryButtonText = action, CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Close };
        _dialogOpen = true;
        try { return await dialog.ShowAsync() == ContentDialogResult.Primary; }
        finally { _dialogOpen = false; }
    }

    /// <summary>Saves the selected workspace's layout, or a copy of a preset; a taken name asks first.</summary>
    private async Task SaveLayoutFromPaletteAsync(LayoutNode? preset)
    {
        var layout = preset ?? (SelectedWorkspace() is { } workspace ? CaptureLayout(workspace) : null);
        if (layout is null || await AskForNameAsync(Localizer.Get("LayoutName"), Localizer.Get("Save"), string.Empty) is not { } name) return;
        try
        {
            var force = false;
            if (Layouts.Find(name) is not null)
            {
                if (!await ConfirmAsync(string.Format(Localizer.Get("LayoutReplaceTitle"), name), Localizer.Get("LayoutReplaceMessage"), Localizer.Get("LayoutReplace"))) return;
                force = true;
            }
            Layouts.Save(name, layout, force);
        }
        catch (Exception error) when (error is Layouts.LayoutException or IOException or UnauthorizedAccessException)
        {
            await ShowErrorAsync(Localizer.Get("LayoutSaveFailed"), error.Message);
        }
    }

    private async Task RenameLayoutAsync(string name)
    {
        if (await AskForNameAsync(string.Format(Localizer.Get("LayoutRename"), name), Localizer.Get("Rename"), name) is not { } to || to == name) return;
        try { Layouts.Rename(name, to); }
        catch (Exception error) when (error is Layouts.LayoutException or IOException or UnauthorizedAccessException)
        {
            await ShowErrorAsync(string.Format(Localizer.Get("LayoutRename"), name), error.Message);
        }
    }

    private async Task DeleteLayoutAsync(string name)
    {
        if (!await ConfirmAsync(string.Format(Localizer.Get("LayoutDeleteTitle"), name), string.Format(Localizer.Get("LayoutDeleteMessage"), name), Localizer.Get("LayoutDeleteAction"))) return;
        try { Layouts.Delete(name); }
        catch (Exception error) when (error is Layouts.LayoutException or IOException or UnauthorizedAccessException)
        {
            await ShowErrorAsync(string.Format(Localizer.Get("LayoutDeleteTitle"), name), error.Message);
        }
    }
}
