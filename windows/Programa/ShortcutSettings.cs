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
    };

    private static readonly HashSet<string> Reserved = ["ctrl-c", "ctrl-d", "ctrl-w"];

    // The file is shared with the macOS app, which writes JSON with comments and trailing commas.
    private static readonly JsonDocumentOptions DocumentOptions = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
    private static readonly JsonReaderOptions ReaderOptions = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
    private readonly Dictionary<string, string> _values;

    private ShortcutSettings(Dictionary<string, string> values) => _values = values;

    public string this[string action] => _values[action];
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
