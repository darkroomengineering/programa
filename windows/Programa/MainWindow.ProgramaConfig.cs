using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Programa;

/// <summary>programa.json commands and recipes in the palette, as on macOS: parameters asked one by one,
/// the trust gate, then a command typed and submitted, a workspace opened, or a prompt typed unsent.</summary>
public sealed partial class MainWindow
{
    /// <summary>Label, subtitle, search keywords and action for each loaded entry.</summary>
    private IEnumerable<(string Label, string Hint, string Keywords, Action Run)> ConfigPaletteEntries()
    {
        var directory = ActiveTerminal()?.WorkingDirectory is { Length: > 0 } cwd ? cwd : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (var entry in ProgramaConfig.Load(directory))
        {
            var hint = entry.Description is { } description && ProgramaConfig.Clean(description) is { Length: > 0 } text ? text : Localizer.Get("ConfigSubtitle");
            var label = string.Format(Localizer.Get(entry.Recipe ? "ConfigRecipeTitle" : "ConfigCustomTitle"), ProgramaConfig.Clean(entry.Name));
            yield return (label, hint, string.Join(' ', entry.Keywords), () => _ = RunConfigEntryAsync(entry, directory));
        }
    }

    private async Task RunConfigEntryAsync(ConfigEntry entry, string baseDirectory)
    {
        var truncated = Localizer.Get("ConfigTruncated");
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var parameter in entry.Parameters)
        {
            // Cancelling any value runs nothing.
            if (await AskParameterAsync(parameter, entry.Name, truncated) is not { } value) return;
            values[parameter.Name] = value;
        }
        var resolved = entry.Text is null ? null : ProgramaConfig.Substitute(entry.Text, values);
        try
        {
            if (entry.Recipe)
            {
                if (!await ConfirmConfigAsync(entry, ProgramaConfig.Display(resolved!, truncated))) return;
                if (ActiveTerminal() is not { } terminal) return;
                if (ProgramaConfig.Insertable(resolved!) is { } prompt) terminal.SendText(prompt);
                else await ShowErrorAsync(Localizer.Get("ConfigInvalidRecipeTitle"), Localizer.Get("ConfigInvalidRecipeMessage"));
                return;
            }
            if (ProgramaConfig.CommandTexts(entry, resolved).Any(ProgramaConfig.HasControlCharacters))
            {
                await ShowErrorAsync(Localizer.Get("ConfigInvalidCommandTitle"), Localizer.Get("ConfigInvalidCommandMessage"));
                return;
            }
            if (!await ConfirmConfigAsync(entry, ProgramaConfig.Describe(entry, resolved, Localizer.Get("ConfigWorkspaceSummary"), truncated))) return;
            if (entry.Workspace is { } workspace) await OpenConfigWorkspaceAsync(entry, workspace, baseDirectory);
            else ActiveTerminal()?.SendText(ProgramaConfig.ForExecution(resolved!) + "\n");
        }
        catch (Exception error) when (error is ControlException or IOException or UnauthorizedAccessException)
        {
            await ShowErrorAsync(Localizer.Get("CoreError"), error.Message);
        }
    }

    private async Task<string?> AskParameterAsync(ConfigParameter parameter, string entryName, string truncated)
    {
        if (_dialogOpen || Root.XamlRoot is null) return null;
        var box = new TextBox { Text = parameter.Default ?? string.Empty, MinWidth = 320 };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = string.Format(Localizer.Get("ConfigParameterMessage"), ProgramaConfig.Display(entryName, truncated)), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(box);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = ProgramaConfig.Display(parameter.Prompt ?? parameter.Name, truncated), Content = content,
            PrimaryButtonText = Localizer.Get("ConfigContinue"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary,
        };
        _dialogOpen = true;
        try { return await dialog.ShowAsync() == ContentDialogResult.Primary ? box.Text : null; }
        finally { _dialogOpen = false; }
    }

    /// <summary>The one gate before anything a programa.json runs or types. A file outside a trusted root,
    /// or changed since it was trusted, always asks; a trusted one asks only for `confirm: true`.</summary>
    private async Task<bool> ConfirmConfigAsync(ConfigEntry entry, string detail)
    {
        var state = ProgramaConfig.State(entry.Source, entry.Digest);
        if (state != TrustState.Changed && !ProgramaConfig.RequiresConfirmation(!entry.Recipe && entry.Confirm, state == TrustState.Trusted)) return true;
        if (_dialogOpen || Root.XamlRoot is null) return false;
        var message = string.Format(Localizer.Get(entry.Recipe ? "ConfigConfirmRecipeMessage" : "ConfigConfirmCommandMessage"), detail);
        if (state == TrustState.Changed) message = Localizer.Get(ProgramaConfig.HasRecordedDigest(entry.Source) ? "ConfigChanged" : "ConfigNeverDigested") + "\n\n" + message;
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        // A root that settings.json does not list would lose a trust granted here, so it is not offered.
        CheckBox? trust = state != TrustState.Trusted && entry.Digest is not null && !(ProgramaConfig.IsManaged && state == TrustState.Untrusted)
            ? new CheckBox { Content = Localizer.Get("ConfigTrustDirectory") }
            : null;
        if (trust is not null) content.Children.Add(trust);
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot, Title = Localizer.Get(entry.Recipe ? "ConfigConfirmRecipeTitle" : "ConfigConfirmCommandTitle"),
            Content = new ScrollViewer { Content = content, MaxHeight = 360 },
            PrimaryButtonText = Localizer.Get(entry.Recipe ? "ConfigInsert" : "ConfigRun"), CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Primary,
        };
        _dialogOpen = true;
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return false;
        }
        finally { _dialogOpen = false; }
        if (trust?.IsChecked == true) ProgramaConfig.Trust(entry.Source, entry.Digest!);
        return true;
    }

    /// <summary>A workspace command: a workspace of that name is selected (`ignore`), replaced
    /// (`recreate`) or asked about (`confirm`); otherwise one opens with its directory, color and layout.</summary>
    private async Task OpenConfigWorkspaceAsync(ConfigEntry entry, ConfigWorkspace workspace, string baseDirectory)
    {
        var name = workspace.Name ?? entry.Name;
        if (_snapshot.Workspaces.FirstOrDefault(item => item.Title == name) is { } existing)
        {
            var replace = entry.Restart == "recreate"
                || entry.Restart == "confirm" && await ConfirmAsync(Localizer.Get("ConfigRestartTitle"), Localizer.Get("ConfigRestartMessage"), Localizer.Get("ConfigRecreate"));
            if (!replace)
            {
                Apply(new { command = "select_workspace", workspace_id = existing.Id });
                return;
            }
            Apply(new { command = "close_workspace", workspace_id = existing.Id });
        }
        var id = ApplyLayout(workspace.Layout ?? new LayoutPane([new LayoutSurface()]), null, ResolveDirectory(baseDirectory, workspace.Cwd), focus: true, title: name);
        if (workspace.Color is { } color) Apply(new { command = "set_workspace_color", workspace_id = id, color });
    }
}
