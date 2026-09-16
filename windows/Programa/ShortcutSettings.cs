using System.Text.Json;
using System.Text.Json.Nodes;
using Windows.System;
using Microsoft.UI.Input;

namespace Programa;

public sealed class ShortcutSettings
{
    public static readonly IReadOnlyDictionary<string, string> Defaults = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["open_settings"] = "ctrl-comma",
        ["new_tab"] = "ctrl-shift-t",
        ["close_tab"] = "ctrl-shift-w",
        ["split_vertical"] = "ctrl-shift-d",
        ["split_horizontal"] = "ctrl-shift-e",
        ["select_tab_1"] = "alt-1", ["select_tab_2"] = "alt-2", ["select_tab_3"] = "alt-3",
        ["select_tab_4"] = "alt-4", ["select_tab_5"] = "alt-5", ["select_tab_6"] = "alt-6",
        ["select_tab_7"] = "alt-7", ["select_tab_8"] = "alt-8", ["select_tab_9"] = "alt-9",
        ["copy"] = "ctrl-shift-c", ["paste"] = "ctrl-shift-v", ["paste_alternate"] = "shift-insert",
    };

    private static readonly HashSet<string> Reserved = ["ctrl-c", "ctrl-d", "ctrl-w"];
    private readonly Dictionary<string, string> _values;

    private ShortcutSettings(Dictionary<string, string> values) => _values = values;

    public string this[string action] => _values[action];
    public IReadOnlyDictionary<string, string> Values => _values;

    public static ShortcutSettings Load()
    {
        var values = new Dictionary<string, string>(Defaults, StringComparer.Ordinal);
        var path = SettingsPath;
        if (!File.Exists(path)) return new(values);
        var root = JsonNode.Parse(File.ReadAllText(path))?.AsObject()
            ?? throw new InvalidDataException($"Settings must contain a JSON object: {path}");
        if (root["windows"]?["shortcuts"] is JsonObject shortcuts)
        {
            foreach (var action in Defaults.Keys)
                if (shortcuts[action] is JsonValue value && value.TryGetValue<string>(out var binding)) values[action] = binding;
        }
        Validate(values);
        foreach (var action in Defaults.Keys) values[action] = Normalize(values[action]);
        return new(values);
    }

    public static ShortcutSettings Create(IReadOnlyDictionary<string, string> values)
    {
        var copy = values.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        Validate(copy);
        foreach (var action in Defaults.Keys) copy[action] = Normalize(copy[action]);
        return new(copy);
    }

    public void Save()
    {
        Validate(_values);
        var path = SettingsPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        JsonObject root;
        try { root = File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path))?.AsObject() ?? [] : []; }
        catch (JsonException error) { throw new InvalidDataException($"Invalid JSON in {path}", error); }
        var windows = root["windows"] as JsonObject;
        if (windows is null)
        {
            windows = [];
            root["windows"] = windows;
        }
        var shortcuts = windows["shortcuts"] as JsonObject;
        if (shortcuts is null)
        {
            shortcuts = [];
            windows["shortcuts"] = shortcuts;
        }
        foreach (var pair in _values) shortcuts[pair.Key] = pair.Value;
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, true);
    }

    public bool Matches(string action, VirtualKey key)
    {
        var modifiers = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down) ? "ctrl-" : "";
        modifiers += InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down) ? "alt-" : "";
        modifiers += InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down) ? "shift-" : "";
        return string.Equals(_values[action], modifiers + KeyName(key), StringComparison.OrdinalIgnoreCase);
    }

    internal static void Validate(IReadOnlyDictionary<string, string> values)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var action in Defaults.Keys)
        {
            if (!values.TryGetValue(action, out var raw)) throw new InvalidDataException($"Missing shortcut '{action}'.");
            if (!IsValid(raw.Trim().ToLowerInvariant())) throw new InvalidDataException($"Shortcut '{action}' is invalid: '{raw}'.");
            var binding = Normalize(raw);
            if (Reserved.Contains(binding)) throw new InvalidDataException($"Shortcut '{binding}' is reserved for the terminal.");
            if (!seen.Add(binding)) throw new InvalidDataException($"Shortcut '{binding}' is assigned more than once.");
        }
    }

    private static string Normalize(string value)
    {
        var parts = value.Trim().ToLowerInvariant().Split('-', StringSplitOptions.RemoveEmptyEntries);
        var result = new List<string>(4);
        if (parts.Contains("ctrl")) result.Add("ctrl");
        if (parts.Contains("alt")) result.Add("alt");
        if (parts.Contains("shift")) result.Add("shift");
        result.Add(parts[^1]);
        return string.Join('-', result);
    }

    private static bool IsValid(string value)
    {
        var parts = value.Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || parts.Distinct(StringComparer.OrdinalIgnoreCase).Count() != parts.Length) return false;
        return parts[..^1].All(part => part is "ctrl" or "alt" or "shift")
            && (parts[^1].Length == 1 && char.IsAsciiLetterOrDigit(parts[^1][0]) || parts[^1] is "comma" or "insert");
    }

    private static string KeyName(VirtualKey key) => key switch
    {
        VirtualKey.Insert => "insert",
        (VirtualKey)188 => "comma",
        >= VirtualKey.Number0 and <= VirtualKey.Number9 => ((int)key - (int)VirtualKey.Number0).ToString(),
        >= VirtualKey.A and <= VirtualKey.Z => ((char)('a' + (int)key - (int)VirtualKey.A)).ToString(),
        _ => "",
    };

    public static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "programa", "settings.json");
}
