using System.Text;
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
        // Workspaces: the macOS ⌘ shortcuts with Ctrl+Shift, or plain Ctrl where it sends nothing
        // to the terminal (digits, Page Up/Down). ⌘⇧W adds Alt because Ctrl+Shift+W closes a tab.
        ["new_workspace"] = "ctrl-shift-n",
        ["close_workspace"] = "ctrl-alt-shift-w",
        ["rename_workspace"] = "ctrl-shift-r",
        ["next_workspace"] = "ctrl-pagedown",
        ["previous_workspace"] = "ctrl-pageup",
        ["toggle_sidebar"] = "ctrl-shift-b",
        // Notifications: ⌘⇧U and ⌘I on macOS.
        ["jump_to_unread"] = "ctrl-shift-u",
        ["show_notifications"] = "ctrl-shift-i",
        // Navigation, from the macOS defaults: ⌘⇧P palette, ⌃Tab tabs, ⌘⇧T reopen (Alt added:
        // Ctrl+Shift+T is new tab), ⌘⇧↩ zoom, ⌥⌘ arrows, ⌘F find, ⌘K clear, ⌘= ⌘- ⌘0 font size.
        ["command_palette"] = "ctrl-shift-p",
        ["next_tab"] = "ctrl-tab",
        ["previous_tab"] = "ctrl-shift-tab",
        ["reopen_tab"] = "ctrl-alt-shift-t",
        ["new_claude_workspace"] = "ctrl-alt-shift-c",
        ["new_window"] = "ctrl-alt-shift-n",
        ["toggle_zoom"] = "ctrl-shift-enter",
        ["focus_left"] = "ctrl-alt-left",
        ["focus_right"] = "ctrl-alt-right",
        ["focus_up"] = "ctrl-alt-up",
        ["focus_down"] = "ctrl-alt-down",
        ["find"] = "ctrl-shift-f",
        ["clear_scrollback"] = "ctrl-shift-k",
        ["font_bigger"] = "ctrl-equals",
        ["font_smaller"] = "ctrl-minus",
        ["font_reset"] = "ctrl-0",
        ["select_workspace_1"] = "ctrl-1", ["select_workspace_2"] = "ctrl-2", ["select_workspace_3"] = "ctrl-3",
        ["select_workspace_4"] = "ctrl-4", ["select_workspace_5"] = "ctrl-5", ["select_workspace_6"] = "ctrl-6",
        ["select_workspace_7"] = "ctrl-7", ["select_workspace_8"] = "ctrl-8", ["select_workspace_9"] = "ctrl-9",
        // The rest of the macOS actions, by the same rules: ⌘R ⌘⇧E, ⌘G ⌘⇧F, ⌘⇧H ⌘P ⌘O ⌘⇧, ⌘Q.
        // Ctrl+Alt+letter is AltGr on many layouts (AltGr+F types [ in Czech), so the ⌥⌘ ones add
        // Shift: close others (⌥⌘T) is Ctrl+Alt+Shift+O and find previous (⌥⌘G) Ctrl+Alt+Shift+G.
        // Full screen is F11, closing a window Ctrl+Shift+F4 and feedback (⌥⌘F) Ctrl+Shift+F1,
        // as Windows places them. An empty binding is no shortcut; Open Review has none on macOS either.
        ["rename_tab"] = "ctrl-alt-shift-r",
        ["edit_workspace_description"] = "ctrl-alt-shift-e",
        ["close_other_tabs"] = "ctrl-alt-shift-o",
        ["find_next"] = "ctrl-shift-g",
        ["find_previous"] = "ctrl-alt-shift-g",
        ["hide_find"] = "ctrl-alt-shift-f",
        ["use_selection_for_find"] = "",
        ["trigger_flash"] = "ctrl-shift-h",
        ["go_to_workspace"] = "ctrl-alt-shift-p",
        ["open_folder"] = "ctrl-shift-o",
        ["open_review"] = "",
        ["toggle_full_screen"] = "f11",
        ["reload_configuration"] = "ctrl-shift-comma",
        ["send_feedback"] = "ctrl-shift-f1",
        ["close_window"] = "ctrl-shift-f4",
        ["quit"] = "ctrl-shift-q",
    };

    private static readonly HashSet<string> Reserved = ["ctrl-c", "ctrl-d", "ctrl-w"];

    // The file is shared with the macOS app, which writes JSON with comments and trailing commas.
    private static readonly JsonDocumentOptions DocumentOptions = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
    private static readonly JsonReaderOptions ReaderOptions = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
    private readonly Dictionary<string, string> _values;
    /// <summary>Action by binding, so a key press costs one lookup.</summary>
    private readonly Dictionary<string, string> _actions;

    private ShortcutSettings(Dictionary<string, string> values)
    {
        _values = values;
        _actions = values.Where(pair => pair.Value.Length > 0).ToDictionary(pair => pair.Value, pair => pair.Key, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>The action bound to this key with the modifiers held now, or null.</summary>
    public string? ActionFor(VirtualKey key)
    {
        var name = KeyName(key);
        if (name.Length == 0) return null;
        return _actions.GetValueOrDefault(Modifiers() + name);
    }

    private static string Modifiers() =>
        (IsDown(VirtualKey.Control) ? "ctrl-" : "") + (IsDown(VirtualKey.Menu) ? "alt-" : "") + (IsDown(VirtualKey.Shift) ? "shift-" : "");

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    public IReadOnlyDictionary<string, string> Values => _values;

    public static ShortcutSettings Load()
    {
        var values = new Dictionary<string, string>(Defaults, StringComparer.Ordinal);
        var path = SettingsPath;
        if (!File.Exists(path)) return new(values);
        var text = File.ReadAllText(path);
        if (string.IsNullOrWhiteSpace(text)) return new(values);
        var root = JsonNode.Parse(text, null, DocumentOptions)?.AsObject()
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

    /// <summary>
    /// Rewrites only the <c>windows.shortcuts</c> member of the shared settings file. Every other byte,
    /// including comments and trailing commas, is kept; comments inside the rewritten member are not.
    /// </summary>
    public void Save()
    {
        Validate(_values);
        var path = SettingsPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var original = File.Exists(path) ? File.ReadAllBytes(path) : [];
        byte[] updated;
        try { updated = Patch(original, _values); }
        catch (JsonException error) { throw new InvalidDataException($"Invalid JSON in {path}", error); }
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, updated);
        File.Move(temporary, path, true);
    }

    /// <summary>Sets top-level <c>section.key</c> values in the shared settings file, keeping every
    /// other byte like <see cref="Save"/>. A null value writes JSON null.</summary>
    internal static void SetValues(IEnumerable<(string Section, string Key, JsonNode? Value)> values)
    {
        var path = SettingsPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var bytes = File.Exists(path) ? File.ReadAllBytes(path) : [];
        try
        {
            foreach (var (section, key, value) in values) bytes = PatchValue(bytes, section, key, value?.ToJsonString() ?? "null");
            JsonDocument.Parse(bytes.AsMemory(bytes.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? 3 : 0), DocumentOptions).Dispose();
        }
        catch (JsonException error) { throw new InvalidDataException($"Invalid JSON in {path}", error); }
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, path, true);
    }

    internal static byte[] PatchValue(byte[] original, string section, string key, string json)
    {
        var bom = original.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? 3 : 0;
        var text = Encoding.UTF8.GetString(original, bom, original.Length - bom);
        var nl = text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var sectionJson = $"{{{nl}    {JsonSerializer.Serialize(key)}: {json}{nl}  }}";
        if (string.IsNullOrWhiteSpace(text)) return Encoding.UTF8.GetBytes($"{{{nl}  {JsonSerializer.Serialize(section)}: {sectionJson}{nl}}}{nl}");
        var root = ScanObject(original, bom, section);
        if (root.Found is not { } found) return Insert(original, root, section, sectionJson, "  ", nl);
        if (found.Type != JsonTokenType.StartObject) return Replace(original, found, sectionJson);
        var inner = ScanObject(original, found.Start, key);
        return inner.Found is { } member ? Replace(original, member, json) : Insert(original, inner, key, json, "    ", nl);
    }

    private readonly record struct Member(int Start, int End, JsonTokenType Type);
    private readonly record struct ObjectScan(int Start, int LastValueEnd, Member? Found);

    internal static byte[] Patch(byte[] original, IReadOnlyDictionary<string, string> values)
    {
        var bom = original.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? 3 : 0;
        var text = Encoding.UTF8.GetString(original, bom, original.Length - bom);
        var nl = text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        byte[] result;
        if (string.IsNullOrWhiteSpace(text))
        {
            result = Encoding.UTF8.GetBytes($"{{{nl}  \"windows\": {WindowsJson(values, nl)}{nl}}}{nl}");
        }
        else
        {
            var root = ScanObject(original, bom, "windows");
            if (root.Found is not { } windows)
                result = Insert(original, root, "windows", WindowsJson(values, nl), "  ", nl);
            else if (windows.Type != JsonTokenType.StartObject)
                result = Replace(original, windows, WindowsJson(values, nl));
            else
            {
                var inner = ScanObject(original, windows.Start, "shortcuts");
                if (inner.Found is not { } shortcuts)
                    result = Insert(original, inner, "shortcuts", ShortcutsJson(null, values, "    ", nl), "    ", nl);
                else
                {
                    var existing = shortcuts.Type == JsonTokenType.StartObject
                        ? JsonNode.Parse(Encoding.UTF8.GetString(original, shortcuts.Start, shortcuts.End - shortcuts.Start), null, DocumentOptions) as JsonObject
                        : null;
                    result = Replace(original, shortcuts, ShortcutsJson(existing, values, "    ", nl));
                }
            }
        }
        // Never write a file the next Load could not read back.
        JsonDocument.Parse(result.AsMemory(result.AsSpan().StartsWith((ReadOnlySpan<byte>)[0xEF, 0xBB, 0xBF]) ? 3 : 0), DocumentOptions).Dispose();
        return result;
    }

    private static ObjectScan ScanObject(byte[] bytes, int from, string name)
    {
        var reader = new Utf8JsonReader(bytes.AsSpan(from), ReaderOptions);
        if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
            throw new InvalidDataException("Settings must contain a JSON object.");
        var start = from + (int)reader.TokenStartIndex;
        var lastValueEnd = -1;
        Member? found = null;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var key = reader.GetString();
            reader.Read();
            var type = reader.TokenType;
            var valueStart = from + (int)reader.TokenStartIndex;
            reader.Skip();
            lastValueEnd = from + (int)reader.BytesConsumed;
            if (string.Equals(key, name, StringComparison.Ordinal)) found = new Member(valueStart, lastValueEnd, type);
        }
        return new(start, lastValueEnd, found);
    }

    private static byte[] Replace(byte[] bytes, Member member, string json) =>
        Splice(bytes, member.Start, member.End, json);

    private static byte[] Insert(byte[] bytes, ObjectScan scan, string name, string json, string indent, string nl)
    {
        var property = $"\"{name}\": {json}";
        return scan.LastValueEnd < 0
            ? Splice(bytes, scan.Start + 1, scan.Start + 1, nl + indent + property + nl + indent[..^2])
            : Splice(bytes, scan.LastValueEnd, scan.LastValueEnd, "," + nl + indent + property);
    }

    private static byte[] Splice(byte[] bytes, int start, int end, string replacement)
    {
        var insert = Encoding.UTF8.GetBytes(replacement);
        var result = new byte[bytes.Length - (end - start) + insert.Length];
        bytes.AsSpan(0, start).CopyTo(result);
        insert.CopyTo(result, start);
        bytes.AsSpan(end).CopyTo(result.AsSpan(start + insert.Length));
        return result;
    }

    private static string WindowsJson(IReadOnlyDictionary<string, string> values, string nl) =>
        $"{{{nl}    \"shortcuts\": {ShortcutsJson(null, values, "    ", nl)}{nl}  }}";

    /// <summary>Serializes the shortcuts object, keeping keys this app does not manage.</summary>
    private static string ShortcutsJson(JsonObject? existing, IReadOnlyDictionary<string, string> values, string indent, string nl)
    {
        var members = new List<(string Key, string Json)>();
        if (existing is not null)
            foreach (var pair in existing)
                members.Add((pair.Key, pair.Value is null ? "null" : pair.Value.ToJsonString()));
        foreach (var pair in values)
        {
            var json = JsonSerializer.Serialize(pair.Value);
            var index = members.FindIndex(member => member.Key == pair.Key);
            if (index >= 0) members[index] = (pair.Key, json);
            else members.Add((pair.Key, json));
        }
        var lines = members.Select(member => $"{indent}  {JsonSerializer.Serialize(member.Key)}: {member.Json}");
        return "{" + nl + string.Join("," + nl, lines) + nl + indent + "}";
    }

    /// <summary>The action bound to a binding such as "ctrl-shift-g", or null.</summary>
    public string? ActionForBinding(string binding) => binding.Trim().Length == 0 ? null : _actions.GetValueOrDefault(Normalize(binding));

    public bool Matches(string action, VirtualKey key) => string.Equals(ActionFor(key), action, StringComparison.Ordinal);

    internal static void Validate(IReadOnlyDictionary<string, string> values)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var action in Defaults.Keys)
        {
            if (!values.TryGetValue(action, out var raw)) throw new InvalidDataException($"Missing shortcut '{action}'.");
            if (raw.Trim().Length == 0) continue;
            if (!IsValid(raw.Trim().ToLowerInvariant())) throw new InvalidDataException($"Shortcut '{action}' is invalid: '{raw}'.");
            var binding = Normalize(raw);
            if (Reserved.Contains(binding)) throw new InvalidDataException($"Shortcut '{binding}' is reserved for the terminal.");
            if (!seen.Add(binding)) throw new InvalidDataException($"Shortcut '{binding}' is assigned more than once.");
        }
    }

    private static string Normalize(string value)
    {
        var parts = value.Trim().ToLowerInvariant().Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return string.Empty;
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
        // A function key may stand alone; any other key needs a modifier, or it would never reach the terminal.
        if (parts.Length == 0 || parts.Length == 1 && !IsFunctionKey(parts[0]) || parts.Distinct(StringComparer.OrdinalIgnoreCase).Count() != parts.Length) return false;
        return parts[..^1].All(part => part is "ctrl" or "alt" or "shift")
            && (parts[^1].Length == 1 && char.IsAsciiLetterOrDigit(parts[^1][0]) || NamedKeys.Contains(parts[^1]) || IsFunctionKey(parts[^1]));
    }

    private static bool IsFunctionKey(string key) => key.Length is 2 or 3 && key[0] == 'f' && int.TryParse(key[1..], out var number) && number is >= 1 and <= 12;

    private static readonly HashSet<string> NamedKeys =
        ["comma", "insert", "pageup", "pagedown", "tab", "enter", "left", "right", "up", "down", "equals", "minus"];

    /// <summary>"ctrl-shift-n" as Windows shows shortcuts: "Ctrl+Shift+N".</summary>
    public static string Display(string binding) => string.Join('+', binding.Split('-', StringSplitOptions.RemoveEmptyEntries).Select(part => part switch
    {
        "pageup" => "PgUp",
        "pagedown" => "PgDn",
        "comma" => ",",
        "equals" => "=",
        "minus" => "-",
        _ => char.ToUpperInvariant(part[0]) + part[1..],
    }));

    private static string KeyName(VirtualKey key) => key switch
    {
        VirtualKey.Insert => "insert",
        VirtualKey.PageUp => "pageup",
        VirtualKey.PageDown => "pagedown",
        VirtualKey.Tab => "tab",
        VirtualKey.Enter => "enter",
        VirtualKey.Left => "left",
        VirtualKey.Right => "right",
        VirtualKey.Up => "up",
        VirtualKey.Down => "down",
        (VirtualKey)187 => "equals",
        (VirtualKey)189 => "minus",
        (VirtualKey)188 => "comma",
        >= VirtualKey.F1 and <= VirtualKey.F12 => $"f{(int)key - (int)VirtualKey.F1 + 1}",
        >= VirtualKey.Number0 and <= VirtualKey.Number9 => ((int)key - (int)VirtualKey.Number0).ToString(),
        >= VirtualKey.A and <= VirtualKey.Z => ((char)('a' + (int)key - (int)VirtualKey.A)).ToString(),
        _ => "",
    };

    public static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "programa", "settings.json");
}
