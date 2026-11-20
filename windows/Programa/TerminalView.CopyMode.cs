using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Programa;

internal enum CopyAction
{
    None, Exit, ToggleVisual, Copy, CopyLines, Up, Down, Left, Right, LineStart, LineEnd, FirstText,
    PageUp, PageDown, HalfPageUp, HalfPageDown, Top, Bottom, Search, SearchNext, SearchPrevious,
    PromptUp, PromptDown,
}

/// <summary>The copy mode keys, as macOS resolves them (Sources/TerminalCopyMode.swift): a count prefix,
/// yy and gg, and vi motions. A key is the character typed ("j", "G", "$") or a name ("esc", "up",
/// "pagedown", "home", "ctrl-u").</summary>
internal sealed class CopyModeKeys
{
    private const int MaxCount = 9_999;
    private int? _count;
    private bool _pendingYank;
    private bool _pendingG;

    internal void Reset() => (_count, _pendingYank, _pendingG) = (null, false, false);

    internal (CopyAction Action, int Count) Resolve(string key, bool visual)
    {
        if (key == "esc")
        {
            Reset();
            return (CopyAction.Exit, 1);
        }
        var count = Math.Clamp(_count ?? 1, 1, MaxCount);
        if (_pendingYank)
        {
            if (key is "y" or "Y")
            {
                Reset();
                return (CopyAction.CopyLines, count);
            }
            _pendingYank = false;
        }
        if (_pendingG)
        {
            if (key == "g")
            {
                Reset();
                return (CopyAction.Top, count);
            }
            _pendingG = false;
        }
        if (key is [>= '0' and <= '9'] && (key != "0" || _count is not null))
        {
            _count = Math.Min((_count ?? 0) * 10 + (key[0] - '0'), MaxCount);
            return (CopyAction.None, 1);
        }
        if (key == "y" && !visual)
        {
            _pendingYank = true;
            return (CopyAction.None, 1);
        }
        if (key == "g")
        {
            _pendingG = true;
            return (CopyAction.None, 1);
        }
        Reset();
        var action = key switch
        {
            "q" => CopyAction.Exit,
            "v" => CopyAction.ToggleVisual,
            "y" => CopyAction.Copy,
            "Y" => visual ? CopyAction.Copy : CopyAction.CopyLines,
            "j" or "down" or "ctrl-e" => CopyAction.Down,
            "k" or "up" or "ctrl-y" => CopyAction.Up,
            "h" or "left" => CopyAction.Left,
            "l" or "right" => CopyAction.Right,
            "pageup" or "ctrl-b" => CopyAction.PageUp,
            "pagedown" or "ctrl-f" => CopyAction.PageDown,
            "ctrl-u" => CopyAction.HalfPageUp,
            "ctrl-d" => CopyAction.HalfPageDown,
            "home" => CopyAction.Top,
            "end" or "G" => CopyAction.Bottom,
            "0" => CopyAction.LineStart,
            "^" => CopyAction.FirstText,
            "$" => CopyAction.LineEnd,
            "/" => CopyAction.Search,
            "n" => CopyAction.SearchNext,
            "N" => CopyAction.SearchPrevious,
            "{" => CopyAction.PromptUp,
            "}" => CopyAction.PromptDown,
            _ => CopyAction.None,
        };
        return (action, count);
    }
}

/// <summary>Keyboard copy mode (macOS ⌘⇧M): vi keys move a cursor of its own through the screen and
/// scrollback, v selects from it, y copies and leaves, Escape or q leaves. A "vim" badge shows while
/// it is on. The terminal core keeps the cursor (programa_terminal_copy_mode).</summary>
public sealed partial class TerminalView
{
    private readonly CopyModeKeys _copyKeys = new();
    private readonly Border _copyBadge = new();
    private bool _copyVisual;
    /// <summary>A find left its match selected; the next key other than n or N clears it.</summary>
    private bool _copyMatchSelected;

    public bool InCopyMode { get; private set; }

    private void BuildCopyBadge()
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(new FontIcon { Glyph = char.ConvertFromUtf32(0xE765), FontSize = 12 });
        content.Children.Add(new TextBlock { Text = Localizer.Get("CopyModeIndicator"), FontSize = 12 });
        _copyBadge.Child = content;
        _copyBadge.Padding = new Thickness(8, 3, 8, 3);
        _copyBadge.CornerRadius = new CornerRadius(8);
        _copyBadge.Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"];
        _copyBadge.BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"];
        _copyBadge.BorderThickness = new Thickness(1);
        _copyBadge.HorizontalAlignment = HorizontalAlignment.Right;
        _copyBadge.VerticalAlignment = VerticalAlignment.Top;
        _copyBadge.Visibility = Visibility.Collapsed;
        _copyBadge.IsHitTestVisible = false;
        AutomationProperties.SetName(_copyBadge, Localizer.Get("Shortcut_toggle_terminal_copy_mode"));
        _root.Children.Add(_copyBadge);
        PlaceCopyBadge();
    }

    /// <summary>Under the find bar while it shows, else in its place.</summary>
    private void PlaceCopyBadge() =>
        _copyBadge.Margin = new Thickness(0, _findBar.Visibility == Visibility.Visible ? 56 : 8, 16, 0);

    public void ToggleCopyMode() => SetCopyMode(!InCopyMode);

    private void SetCopyMode(bool on)
    {
        if (_session is null || NativeTerminal.CopyMode(_session, on ? 1u : 0u, 1) != 0) on = false;
        InCopyMode = on;
        _copyVisual = false;
        _copyMatchSelected = false;
        _copyKeys.Reset();
        _copyBadge.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>A key pressed in copy mode, by name; true when it was one (printable keys come as text).</summary>
    private bool CopyModeKeyDown(VirtualKey key, bool ctrl, bool alt)
    {
        var name = key switch
        {
            VirtualKey.Escape => "esc",
            VirtualKey.Up => "up",
            VirtualKey.Down => "down",
            VirtualKey.Left => "left",
            VirtualKey.Right => "right",
            VirtualKey.PageUp => "pageup",
            VirtualKey.PageDown => "pagedown",
            VirtualKey.Home => "home",
            VirtualKey.End => "end",
            >= VirtualKey.A and <= VirtualKey.Z when ctrl && !alt => $"ctrl-{(char)('a' + (key - VirtualKey.A))}",
            _ => null,
        };
        if (name is null) return false;
        RunCopyMode(name);
        return true;
    }

    /// <summary>Text typed in copy mode: each character is a key. Escape and control characters (from
    /// debug.type) stand for Escape and Ctrl+letter.</summary>
    internal void TypeInCopyMode(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (!InCopyMode) break;
            RunCopyMode(rune.Value switch
            {
                0x1b => "esc",
                >= 1 and <= 26 => $"ctrl-{(char)('a' + rune.Value - 1)}",
                _ => rune.ToString(),
            });
        }
    }

    private void RunCopyMode(string key)
    {
        if (_session is not { } session) return;
        var (action, count) = _copyKeys.Resolve(key, _copyVisual);
        if (action is CopyAction.None) return;
        // A match a find left selected is not a visual selection: it goes before anything else moves.
        if (_copyMatchSelected && action is not (CopyAction.SearchNext or CopyAction.SearchPrevious))
        {
            _copyMatchSelected = false;
            if (!_copyVisual) NativeTerminal.CopyMode(session, 3, 1);
        }
        void Core(uint command) => NativeTerminal.CopyMode(session, command, (uint)count);
        switch (action)
        {
            case CopyAction.Exit:
                SetCopyMode(false);
                return;
            case CopyAction.ToggleVisual:
                _copyVisual = !_copyVisual;
                Core(_copyVisual ? 2u : 3u);
                break;
            case CopyAction.Copy:
                Copy();
                SetCopyMode(false);
                return;
            case CopyAction.CopyLines:
                Core(4);
                Copy();
                SetCopyMode(false);
                return;
            case CopyAction.Search:
                // A find replaces the selection, so a visual one ends here.
                if (_copyVisual) Core(3);
                _copyVisual = false;
                ShowFind();
                return;
            case CopyAction.SearchNext or CopyAction.SearchPrevious:
                if (_findBox.Text.Length == 0) return;
                // Enter in the find bar goes to the older match, as n does here.
                for (var index = 0; index < count; index++) FindNext(forward: action == CopyAction.SearchPrevious);
                CopyModeToMatch();
                break;
            default:
                Core(action switch
                {
                    CopyAction.Up => 10u, CopyAction.Down => 11u, CopyAction.Left => 12u, CopyAction.Right => 13u,
                    CopyAction.LineStart => 14u, CopyAction.LineEnd => 15u, CopyAction.FirstText => 16u,
                    CopyAction.PageUp => 20u, CopyAction.PageDown => 21u, CopyAction.HalfPageUp => 22u, CopyAction.HalfPageDown => 23u,
                    CopyAction.Top => 24u, CopyAction.Bottom => 25u, CopyAction.PromptUp => 26u, _ => 27u,
                });
                break;
        }
    }

    /// <summary>After a find in copy mode: the cursor goes to the match, which stays selected (so n goes on
    /// from it) until another key. A find replaces a visual selection, so that ends too.</summary>
    private void CopyModeToMatch()
    {
        if (!InCopyMode || _session is not { } session) return;
        _copyVisual = false;
        if (!NativeTerminal.TryCopySelection(session, out var match) || match.Length == 0) return;
        NativeTerminal.CopyMode(session, 5, 1);
        _copyMatchSelected = true;
    }
}
