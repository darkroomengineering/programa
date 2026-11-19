using Windows.System;

namespace Programa;

/// <summary>A key surface.send_key names: a key with modifiers, or a character typed as text.</summary>
internal readonly record struct NamedKey(VirtualKey Key, bool Ctrl, bool Alt, bool Shift, char? Character = null);

/// <summary>The key names macOS accepts (TerminalSurface.pendingKeyEvent): enter, tab, escape,
/// backspace, delete, space, the arrows, home, end, page up/down, the signal aliases (sigint, eof,
/// sigtstp, sigquit), and ctrl/shift/alt joined with + or - to one of those or a letter. Windows has
/// no Command key for a terminal, so cmd combinations are unknown here.</summary>
internal static class NamedKeys
{
    private static readonly Dictionary<string, NamedKey> Aliases = new(StringComparer.Ordinal)
    {
        ["ctrl-c"] = new(VirtualKey.C, true, false, false), ["ctrl+c"] = new(VirtualKey.C, true, false, false), ["sigint"] = new(VirtualKey.C, true, false, false),
        ["ctrl-d"] = new(VirtualKey.D, true, false, false), ["ctrl+d"] = new(VirtualKey.D, true, false, false), ["eof"] = new(VirtualKey.D, true, false, false),
        ["ctrl-z"] = new(VirtualKey.Z, true, false, false), ["ctrl+z"] = new(VirtualKey.Z, true, false, false), ["sigtstp"] = new(VirtualKey.Z, true, false, false),
        ["ctrl-\\"] = new(Backslash, true, false, false), ["ctrl+\\"] = new(Backslash, true, false, false), ["sigquit"] = new(Backslash, true, false, false),
        ["arrow_up"] = new(VirtualKey.Up, false, false, false), ["arrowup"] = new(VirtualKey.Up, false, false, false),
        ["arrow_down"] = new(VirtualKey.Down, false, false, false), ["arrowdown"] = new(VirtualKey.Down, false, false, false),
        ["arrow_left"] = new(VirtualKey.Left, false, false, false), ["arrowleft"] = new(VirtualKey.Left, false, false, false),
        ["arrow_right"] = new(VirtualKey.Right, false, false, false), ["arrowright"] = new(VirtualKey.Right, false, false, false),
        ["shift+tab"] = new(VirtualKey.Tab, false, false, true), ["shift-tab"] = new(VirtualKey.Tab, false, false, true), ["backtab"] = new(VirtualKey.Tab, false, false, true),
        ["home"] = new(VirtualKey.Home, false, false, false), ["end"] = new(VirtualKey.End, false, false, false),
        ["del"] = new(VirtualKey.Delete, false, false, false), ["forward_delete"] = new(VirtualKey.Delete, false, false, false),
        ["pageup"] = new(VirtualKey.PageUp, false, false, false), ["page_up"] = new(VirtualKey.PageUp, false, false, false),
        ["pagedown"] = new(VirtualKey.PageDown, false, false, false), ["page_down"] = new(VirtualKey.PageDown, false, false, false),
    };

    /// <summary>The OEM backslash key on US layouts.</summary>
    private const VirtualKey Backslash = (VirtualKey)220;

    internal static NamedKey? Parse(string name)
    {
        var normalized = name.ToLowerInvariant();
        if (Aliases.TryGetValue(normalized, out var alias)) return alias;
        var parts = normalized.Split('+', '-').Where(part => part.Length > 0).ToList();
        if (parts.Count == 0 || Base(parts[^1]) is not { } key) return null;
        bool ctrl = false, alt = false, shift = false;
        foreach (var modifier in parts[..^1])
        {
            switch (modifier)
            {
                case "ctrl" or "control": ctrl = true; break;
                case "shift": shift = true; break;
                case "alt" or "opt" or "option": alt = true; break;
                default: return null;
            }
        }
        return key with { Ctrl = ctrl, Alt = alt, Shift = shift };
    }

    /// <summary>A key without modifiers: a named key, or a letter typed as itself.</summary>
    private static NamedKey? Base(string name) => name switch
    {
        "enter" or "return" => new(VirtualKey.Enter, false, false, false),
        "tab" => new(VirtualKey.Tab, false, false, false),
        "escape" or "esc" => new(VirtualKey.Escape, false, false, false),
        "backspace" => new(VirtualKey.Back, false, false, false),
        "delete" => new(VirtualKey.Delete, false, false, false),
        "space" => new(VirtualKey.Space, false, false, false, ' '),
        "up" => new(VirtualKey.Up, false, false, false),
        "down" => new(VirtualKey.Down, false, false, false),
        "left" => new(VirtualKey.Left, false, false, false),
        "right" => new(VirtualKey.Right, false, false, false),
        "\\" => new(Backslash, false, false, false, '\\'),
        [var letter] when letter is >= 'a' and <= 'z' => new(VirtualKey.A + (letter - 'a'), false, false, false, letter),
        _ => null,
    };
}
