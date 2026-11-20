using System.Text.Json;
using System.Text.Json.Nodes;

namespace Programa;

internal sealed record LayoutSurface(string? Name = null, string? Command = null, string? Cwd = null, IReadOnlyDictionary<string, string>? Env = null, bool Focus = false);

internal abstract record LayoutNode;

internal sealed record LayoutPane(IReadOnlyList<LayoutSurface> Surfaces) : LayoutNode;

/// <summary><see cref="Direction"/> is the file's: "horizontal" puts the children side by side.</summary>
internal sealed record LayoutSplit(string Direction, double Split, LayoutNode First, LayoutNode Second) : LayoutNode;

internal sealed record SavedLayout(string Name, string Path, DateTimeOffset? SavedAt, LayoutNode? Layout, string? Error);

/// <summary>Named layouts, in the macOS file format (docs/programa-json.md#saved-layouts):
/// %USERPROFILE%\.config\programa\layouts\&lt;name&gt;.json, plus two built-in presets.</summary>
internal static class Layouts
{
    internal sealed class LayoutException(string code, string message) : Exception(message)
    {
        internal string Code { get; } = code;
    }

    internal static string Folder { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "programa", "layouts");

    private static readonly LayoutSurface Claude = new(Command: "claude");

    /// <summary>The built-in presets: palette-only, never files.</summary>
    internal static readonly (string Name, LayoutNode Layout)[] Presets =
    [
        ("Agent and Shell", new LayoutSplit("horizontal", 0.5, new LayoutPane([Claude with { Focus = true }]), new LayoutPane([new LayoutSurface()]))),
        ("Three Agents", new LayoutSplit("horizontal", 1.0 / 3, new LayoutPane([Claude]), new LayoutSplit("horizontal", 0.5, new LayoutPane([Claude]), new LayoutPane([Claude])))),
    ];

    /// <summary>Every layout file, broken ones included with their reason, sorted by name.</summary>
    internal static List<SavedLayout> All()
    {
        if (!Directory.Exists(Folder)) return [];
        return Directory.EnumerateFiles(Folder, "*.json").Select(Load).OrderBy(layout => layout.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    internal static SavedLayout? Find(string name) =>
        All().FirstOrDefault(layout => string.Equals(layout.Name, name, StringComparison.OrdinalIgnoreCase));

    private static SavedLayout Load(string file)
    {
        var name = Path.GetFileNameWithoutExtension(file);
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(file));
            var root = document.RootElement;
            if (!root.TryGetProperty("layout", out var layout)) throw new LayoutException("invalid", "missing key 'layout'");
            DateTimeOffset? savedAt = root.TryGetProperty("savedAt", out var saved) && saved.TryGetDateTimeOffset(out var time) ? time : null;
            return new SavedLayout(name, file, savedAt, Parse(layout, "layout"), null);
        }
        catch (Exception error) when (error is LayoutException or JsonException or IOException or InvalidOperationException)
        {
            return new SavedLayout(name, file, null, null, $"{Path.GetFileName(file)}: {error.Message}");
        }
    }

    internal static LayoutNode Parse(JsonElement node, string at)
    {
        if (node.ValueKind != JsonValueKind.Object) throw new LayoutException("invalid", $"'{at}' is not an object");
        if (node.TryGetProperty("pane", out var pane))
        {
            if (!pane.TryGetProperty("surfaces", out var surfaces) || surfaces.ValueKind != JsonValueKind.Array)
                throw new LayoutException("invalid", $"missing key 'surfaces' in '{at}.pane'");
            var parsed = new List<LayoutSurface>();
            foreach (var surface in surfaces.EnumerateArray())
            {
                var type = String(surface, "type") ?? throw new LayoutException("invalid", $"missing key 'type' in '{at}.pane.surfaces'");
                if (type == "browser") continue; // older files; skipped as on macOS
                if (type != "terminal") throw new LayoutException("invalid", $"unknown surface type '{type}' in '{at}.pane.surfaces'");
                var env = surface.TryGetProperty("env", out var envNode) && envNode.ValueKind == JsonValueKind.Object
                    ? envNode.EnumerateObject().Where(item => item.Value.ValueKind == JsonValueKind.String).ToDictionary(item => item.Name, item => item.Value.GetString()!)
                    : null;
                parsed.Add(new LayoutSurface(String(surface, "name"), String(surface, "command"), String(surface, "cwd"), env,
                    surface.TryGetProperty("focus", out var focus) && focus.ValueKind == JsonValueKind.True));
            }
            if (parsed.Count == 0) parsed.Add(new LayoutSurface());
            return new LayoutPane(parsed);
        }
        if (String(node, "direction") is not { } direction) throw new LayoutException("invalid", $"'{at}' needs 'pane' or 'direction'");
        if (direction is not ("horizontal" or "vertical")) throw new LayoutException("invalid", $"direction '{direction}' in '{at}' is not horizontal or vertical");
        if (!node.TryGetProperty("children", out var children) || children.ValueKind != JsonValueKind.Array || children.GetArrayLength() != 2)
            throw new LayoutException("invalid", $"'{at}.children' needs exactly two nodes");
        var split = node.TryGetProperty("split", out var ratio) && ratio.ValueKind == JsonValueKind.Number ? ratio.GetDouble() : 0.5;
        return new LayoutSplit(direction, Math.Clamp(split, 0.1, 0.9), Parse(children[0], $"{at}.children[0]"), Parse(children[1], $"{at}.children[1]"));
    }

    internal static JsonNode Serialize(LayoutNode node) => node switch
    {
        LayoutPane pane => new JsonObject
        {
            ["pane"] = new JsonObject
            {
                ["surfaces"] = new JsonArray(pane.Surfaces.Select(surface =>
                {
                    var item = new JsonObject { ["type"] = "terminal" };
                    if (surface.Name is not null) item["name"] = surface.Name;
                    if (surface.Command is not null) item["command"] = surface.Command;
                    if (surface.Cwd is not null) item["cwd"] = surface.Cwd;
                    if (surface.Focus) item["focus"] = true;
                    return (JsonNode)item;
                }).ToArray()),
            },
        },
        LayoutSplit split => new JsonObject
        {
            ["direction"] = split.Direction,
            ["split"] = Math.Round(split.Split, 4),
            ["children"] = new JsonArray(Serialize(split.First), Serialize(split.Second)),
        },
        _ => throw new ArgumentOutOfRangeException(nameof(node)),
    };

    internal static string Save(string name, LayoutNode layout, bool force)
    {
        var path = PathFor(name);
        if (!force && File.Exists(path)) throw new LayoutException("already_exists", $"A layout named '{name}' already exists.");
        Directory.CreateDirectory(Folder);
        var envelope = new JsonObject
        {
            ["schemaVersion"] = 1,
            ["name"] = name,
            ["savedAt"] = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["layout"] = Serialize(layout),
        };
        // Written whole then moved into place, so a reader never sees half a file.
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, envelope.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, path, overwrite: true);
        return path;
    }

    /// <summary>Renames without replacing: a name another layout uses is refused.</summary>
    internal static void Rename(string from, string to)
    {
        var target = PathFor(to);
        var source = Find(from)?.Path ?? throw new LayoutException("not_found", $"No layout named '{from}'.");
        if (File.Exists(target) && !string.Equals(Path.GetFullPath(source), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase))
            throw new LayoutException("already_exists", $"A layout named '{to}' already exists.");
        File.Move(source, target);
    }

    internal static void Delete(string name) =>
        File.Delete(Find(name)?.Path ?? throw new LayoutException("not_found", $"No layout named '{name}'."));

    private static string PathFor(string name)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0 || trimmed.IndexOfAny(['/', '\\', ..Path.GetInvalidFileNameChars()]) >= 0 || trimmed is "." or "..")
            throw new LayoutException("invalid_name", $"'{name}' is not a valid layout name.");
        return Path.Combine(Folder, trimmed + ".json");
    }

    private static string? String(JsonElement node, string key) =>
        node.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}
