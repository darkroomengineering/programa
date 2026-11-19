using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Programa;

internal sealed record ConfigParameter(string Name, string? Prompt, string? Default);

internal sealed record ConfigWorkspace(string? Name, string? Cwd, string? Color, LayoutNode? Layout);

/// <summary>A programa.json `commands` entry (exactly one of <see cref="Text"/> and <see cref="Workspace"/>),
/// or with <see cref="Recipe"/> a `recipes` entry whose <see cref="Text"/> is its prompt.
/// <see cref="Digest"/> pins trust to the bytes it was parsed from.</summary>
internal sealed record ConfigEntry(bool Recipe, string Name, string? Description, IReadOnlyList<string> Keywords, string? Text, ConfigWorkspace? Workspace,
    string Restart, bool Confirm, IReadOnlyList<ConfigParameter> Parameters, string Source, string? Digest);

internal enum TrustState { Trusted, Changed, Untrusted }

/// <summary>programa.json commands and recipes as on macOS (docs/programa-json.md, Sources/ProgramaConfig.swift,
/// ProgramaConfigExecutor.swift, ProgramaDirectoryTrust.swift): the nearest programa.json at or above the
/// workspace's directory, then the global one, and the trust store that decides what runs unasked.</summary>
internal static class ProgramaConfig
{
    private static readonly JsonDocumentOptions Options = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
    private static readonly StringComparer PathComparer = StringComparer.OrdinalIgnoreCase;

    internal static string GlobalPath { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "programa", "programa.json");

    /// <summary>Dev builds keep their own, as they do their session and hooks files.</summary>
    internal static string TrustStorePath { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programa",
        BuildIdentity.Value.Contains("0.0.0-dev", StringComparison.Ordinal) ? "trusted-directories-dev.json" : "trusted-directories.json");

    /// <summary>settings.json's customCommands.trustedDirectories, which replaces the stored roots when set.</summary>
    internal static Func<IReadOnlyList<string>?> ManagedRoots { get; set; } = () => AppSettings.Load().TrustedDirectories;

    /// <summary>The local file's entries, then the global file's; a name already taken is skipped.</summary>
    internal static List<ConfigEntry> Load(string? directory)
    {
        var entries = new List<ConfigEntry>();
        foreach (var path in new[] { directory is { Length: > 0 } ? Find(directory) : null, GlobalPath })
        {
            if (path is null) continue;
            foreach (var entry in ParseFile(path))
                if (!entries.Any(other => other.Recipe == entry.Recipe && other.Name == entry.Name)) entries.Add(entry);
        }
        return entries;
    }

    internal static string? Find(string directory)
    {
        try
        {
            for (var current = new DirectoryInfo(directory); current is not null; current = current.Parent)
            {
                var candidate = Path.Combine(current.FullName, "programa.json");
                if (File.Exists(candidate)) return candidate;
            }
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { }
        return null;
    }

    /// <summary>A file that does not load gives nothing, as on macOS, where one bad entry fails the file.</summary>
    private static List<ConfigEntry> ParseFile(string path)
    {
        try
        {
            if (!File.Exists(path)) return [];
            var text = File.ReadAllText(path);
            return text.Length == 0 ? [] : Parse(text, path);
        }
        catch (Exception error) when (error is JsonException or FormatException or IOException or UnauthorizedAccessException or Layouts.LayoutException)
        {
            LaunchLog.Write($"programa.json: skipped {path}: {error.Message}");
            return [];
        }
    }

    internal static List<ConfigEntry> Parse(string text, string source)
    {
        using var document = JsonDocument.Parse(text, Options);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new FormatException("the file is not a JSON object");
        // The digest and the reader could disagree about which of two values is real.
        if (HasDuplicateKey(root)) throw new FormatException("an object repeats a key");
        var digest = Digest(root);
        var entries = new List<ConfigEntry>();
        foreach (var item in Items(root, "commands")) entries.Add(Command(item, source, digest));
        foreach (var item in Items(root, "recipes")) entries.Add(Recipe(item, source, digest));
        return entries;
    }

    private static ConfigEntry Command(JsonElement item, string source, string? digest)
    {
        var name = Name(item, "Command");
        var command = Str(item, "command");
        if (command is not null && command.Trim().Length == 0) throw new FormatException($"Command '{name}' must not define a blank 'command'");
        ConfigWorkspace? workspace = null;
        if (Present(item, "workspace") is { } definition)
        {
            if (definition.ValueKind != JsonValueKind.Object) throw new FormatException($"Command '{name}': 'workspace' must be an object");
            var color = Str(definition, "color");
            workspace = new ConfigWorkspace(Str(definition, "name"), Str(definition, "cwd"),
                color is null ? null : HexColor(color) ?? throw new FormatException($"Invalid color \"{color}\". Expected 6-digit hex format: #RRGGBB"),
                Present(definition, "layout") is { } layout ? Layouts.Parse(layout, "workspace.layout") : null);
        }
        if (workspace is not null && command is not null) throw new FormatException($"Command '{name}' must not define both 'workspace' and 'command'");
        if (workspace is null && command is null) throw new FormatException($"Command '{name}' must define either 'workspace' or 'command'");
        var restart = Str(item, "restart") ?? "ignore";
        if (restart is not ("recreate" or "ignore" or "confirm")) throw new FormatException($"Command '{name}': 'restart' must be recreate, ignore or confirm");
        var confirm = Present(item, "confirm") is { } flag ? flag.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw new FormatException($"Command '{name}': 'confirm' must be true or false"),
        } : false;
        return new ConfigEntry(false, name, Str(item, "description"), Strings(item, "keywords"), command, workspace, restart, confirm, Parameters(item), source, digest);
    }

    private static ConfigEntry Recipe(JsonElement item, string source, string? digest)
    {
        var name = Name(item, "Recipe");
        var prompt = Str(item, "prompt") ?? throw new FormatException($"Recipe '{name}' needs a 'prompt'");
        if (prompt.Trim().Length == 0) throw new FormatException($"Recipe '{name}' must not define a blank 'prompt'");
        return new ConfigEntry(true, name, Str(item, "description"), Strings(item, "keywords"), prompt, null, "ignore", false, Parameters(item), source, digest);
    }

    private static string Name(JsonElement item, string kind)
    {
        if (item.ValueKind != JsonValueKind.Object) throw new FormatException($"every {kind.ToLowerInvariant()} must be an object");
        var name = Str(item, "name") ?? throw new FormatException($"{kind} needs a 'name'");
        return name.Trim().Length == 0 ? throw new FormatException($"{kind} name must not be blank") : name;
    }

    private static List<ConfigParameter> Parameters(JsonElement item) =>
        Items(item, "parameters").Select(parameter => parameter.ValueKind == JsonValueKind.Object
            ? new ConfigParameter(Str(parameter, "name") ?? throw new FormatException("a parameter needs a 'name'"), Str(parameter, "prompt"), Str(parameter, "default"))
            : throw new FormatException("every parameter must be an object")).ToList();

    private static JsonElement? Present(JsonElement item, string key) =>
        item.TryGetProperty(key, out var value) && value.ValueKind != JsonValueKind.Null ? value : null;

    private static string? Str(JsonElement item, string key) => Present(item, key) switch
    {
        null => null,
        { ValueKind: JsonValueKind.String } value => value.GetString(),
        _ => throw new FormatException($"'{key}' must be a string"),
    };

    private static List<string> Strings(JsonElement item, string key) =>
        Items(item, key).Select(value => value.ValueKind == JsonValueKind.String ? value.GetString()! : throw new FormatException($"'{key}' must hold strings")).ToList();

    private static IEnumerable<JsonElement> Items(JsonElement item, string key) => Present(item, key) switch
    {
        null => [],
        { ValueKind: JsonValueKind.Array } value => value.EnumerateArray().ToList(),
        _ => throw new FormatException($"'{key}' must be an array"),
    };

    /// <summary>"#RRGGBB" or "RRGGBB", as #RRGGBB in capitals; anything else is null.</summary>
    internal static string? HexColor(string raw)
    {
        var body = raw.Trim().TrimStart('#');
        return body.Length == 6 && body.All(Uri.IsHexDigit) && raw.Trim().Length - body.Length <= 1 ? "#" + body.ToUpperInvariant() : null;
    }

    private static bool HasDuplicateKey(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => element.EnumerateObject().GroupBy(property => property.Name, StringComparer.Ordinal).Any(group => group.Count() > 1)
            || element.EnumerateObject().Any(property => HasDuplicateKey(property.Value)),
        JsonValueKind.Array => element.EnumerateArray().Any(HasDuplicateKey),
        _ => false,
    };

    // Trust

    /// <summary>SHA-256 of the content with comments and formatting dropped and keys sorted, so editing a
    /// comment keeps trust and changing a command does not.</summary>
    private static string Digest(JsonElement root)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream)) Canonical(root, writer);
        return Convert.ToHexStringLower(SHA256.HashData(stream.ToArray()));

        static void Canonical(JsonElement element, Utf8JsonWriter writer)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.Object:
                    writer.WriteStartObject();
                    foreach (var property in element.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
                    {
                        writer.WritePropertyName(property.Name);
                        Canonical(property.Value, writer);
                    }
                    writer.WriteEndObject();
                    break;
                case JsonValueKind.Array:
                    writer.WriteStartArray();
                    foreach (var item in element.EnumerateArray()) Canonical(item, writer);
                    writer.WriteEndArray();
                    break;
                default:
                    element.WriteTo(writer);
                    break;
            }
        }
    }

    internal static string? DigestOf(string path)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path), Options);
            return HasDuplicateKey(document.RootElement) ? null : Digest(document.RootElement);
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>The global file is the person's own and always trusted. A project file is trusted when its
    /// root (the git repo, else its folder) is, and the digest recorded for it matches both the content it
    /// was parsed from and the file now; a trusted root without that match is Changed.</summary>
    internal static TrustState State(string source, string? digest)
    {
        if (PathComparer.Equals(Normalize(source), Normalize(GlobalPath))) return TrustState.Trusted;
        if (digest is null) return TrustState.Untrusted;
        var store = ReadStore();
        var root = TrustRoot(source);
        if (!TrustedRoots(store).Contains(root, PathComparer)) return TrustState.Untrusted;
        if (store.GetValueOrDefault(root)?.GetValueOrDefault(Normalize(source)) != digest) return TrustState.Changed;
        return DigestOf(source) switch
        {
            null => TrustState.Untrusted,
            var current when current == digest => TrustState.Trusted,
            _ => TrustState.Changed,
        };
    }

    /// <summary>Untrusted always asks, whatever the file says; trusted asks only for `confirm: true`.</summary>
    internal static bool RequiresConfirmation(bool confirmFlag, bool trusted) => !trusted || confirmFlag;

    internal static bool HasRecordedDigest(string source) =>
        ReadStore().GetValueOrDefault(TrustRoot(source))?.ContainsKey(Normalize(source)) == true;

    internal static bool IsManaged => ManagedRoots() is not null;

    internal static void Trust(string source, string digest)
    {
        var store = ReadStore();
        var root = TrustRoot(source);
        if (!store.TryGetValue(root, out var digests)) store[root] = digests = new Dictionary<string, string>(PathComparer);
        digests[Normalize(source)] = digest;
        WriteStore(store);
    }

    /// <summary>The stored roots, for the Settings editor.</summary>
    internal static List<string> StoredRoots() => ReadStore().Keys.Order(PathComparer).ToList();

    /// <summary>Replaces the stored roots; roots that stay keep their digests, new ones prompt once.</summary>
    internal static void ReplaceRoots(IEnumerable<string> roots)
    {
        var store = ReadStore();
        var replacement = new Dictionary<string, Dictionary<string, string>>(PathComparer);
        foreach (var root in roots.Select(Normalize).Where(root => root.Length > 0))
            replacement[root] = store.GetValueOrDefault(root) ?? new Dictionary<string, string>(PathComparer);
        WriteStore(replacement);
    }

    private static IEnumerable<string> TrustedRoots(Dictionary<string, Dictionary<string, string>> store) =>
        ManagedRoots()?.Select(Normalize) ?? store.Keys;

    internal static string TrustRoot(string configPath)
    {
        var folder = Path.GetDirectoryName(Normalize(configPath)) ?? configPath;
        for (var current = folder; current is not null; current = Path.GetDirectoryName(current))
            if (Directory.Exists(Path.Combine(current, ".git")) || File.Exists(Path.Combine(current, ".git"))) return Normalize(current);
        return Normalize(folder);
    }

    private static string Normalize(string path)
    {
        try
        {
            var full = Path.GetFullPath(path.Trim());
            return full.Length > (Path.GetPathRoot(full)?.Length ?? 0) ? full.TrimEnd('\\', '/') : full;
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { return path.Trim(); }
    }

    /// <summary>Version 3 of the macOS store: root to (config path to digest).</summary>
    private static Dictionary<string, Dictionary<string, string>> ReadStore()
    {
        var store = new Dictionary<string, Dictionary<string, string>>(PathComparer);
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(TrustStorePath));
            foreach (var root in document.RootElement.GetProperty("directories").EnumerateObject())
            {
                var digests = new Dictionary<string, string>(PathComparer);
                if (root.Value.ValueKind == JsonValueKind.Object)
                    foreach (var config in root.Value.EnumerateObject().Where(config => config.Value.ValueKind == JsonValueKind.String))
                        digests[config.Name] = config.Value.GetString()!;
                store[root.Name] = digests;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException) { }
        return store;
    }

    private static void WriteStore(Dictionary<string, Dictionary<string, string>> store)
    {
        var directories = new JsonObject();
        foreach (var (root, digests) in store)
        {
            var configs = new JsonObject();
            foreach (var (config, digest) in digests) configs[config] = digest;
            directories[root] = configs;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(TrustStorePath)!);
        var temporary = TrustStorePath + ".tmp";
        File.WriteAllText(temporary, new JsonObject { ["version"] = 3, ["directories"] = directories }.ToJsonString());
        File.Move(temporary, TrustStorePath, overwrite: true);
    }

    // Text

    /// <summary>Every {{name}} of a declared parameter becomes its value; any other {{…}} stays as written.</summary>
    internal static string Substitute(string template, IReadOnlyDictionary<string, string> values) =>
        values.Count == 0 ? template : Regex.Replace(template, @"\{\{([^{}]*)\}\}", match => values.TryGetValue(match.Groups[1].Value.Trim(), out var value) ? value : match.Value);

    /// <summary>Zero-width and bidi marks, which can make shown text lie about itself.</summary>
    private static readonly int[] Dangerous = [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF];

    private static string Strip(string text) => string.Concat(text.Where(character => !Dangerous.Contains(character)));

    /// <summary>A palette title or subtitle.</summary>
    internal static string Clean(string text) => Strip(text).Trim();

    /// <summary>What a command types: the marks stripped and trimmed, never shortened.</summary>
    internal static string ForExecution(string text) => Strip(text).Trim();

    /// <summary>A control character other than a newline: the shell acts on it but the dialog cannot show it.</summary>
    internal static bool HasControlCharacters(string text) => text.Any(character => (character < 0x20 && character != '\n') || character is >= '\u007F' and <= '\u009F');

    /// <summary>Every text a command types: its command, or each surface command of its layout.</summary>
    internal static IEnumerable<string> CommandTexts(ConfigEntry entry, string? resolved) =>
        (resolved ?? entry.Text) is { } text ? [text] : Surfaces(entry.Workspace?.Layout).Select(surface => surface.Command).OfType<string>();

    /// <summary>A recipe's prompt as typed, or null when it holds a line break or control character.</summary>
    internal static string? Insertable(string prompt) =>
        prompt.Any(character => character < 0x20 || character is >= (char)0x7F and <= (char)0x9F or (char)0x2028 or (char)0x2029) ? null : Strip(prompt);

    /// <summary>One value as the dialog shows it: line breaks as ⏎, at most 200 characters with a visible marker.</summary>
    internal static string Display(string text, string truncated)
    {
        var collapsed = Regex.Replace(Clean(text), "\r\n|\r|\n", " ⏎ ").Trim();
        return collapsed.Length <= 200 ? collapsed : collapsed[..200] + truncated;
    }

    /// <summary>Everything a command would do, for its confirmation: the substituted command, or the
    /// workspace with every surface that runs a command, changes directory or sets variables.</summary>
    internal static string Describe(ConfigEntry entry, string? resolved, string workspaceFormat, string truncated)
    {
        if ((resolved ?? entry.Text) is { } command) return Display(command, truncated);
        if (entry.Workspace is not { } workspace) return Display(entry.Name, truncated);
        var lines = new List<string> { string.Format(workspaceFormat, Display(workspace.Name ?? entry.Name, truncated)) };
        if (workspace.Cwd is { Length: > 0 } cwd) lines.Add("  cwd=" + Display(cwd, truncated));
        var surfaces = Surfaces(workspace.Layout).Select(surface =>
        {
            var parts = new List<string>();
            if (surface.Command is { Length: > 0 } run) parts.Add(Display(run, truncated));
            if (surface.Cwd is { Length: > 0 } directory) parts.Add("cwd=" + Display(directory, truncated));
            if (surface.Env is { Count: > 0 } env)
                parts.Add("env: " + string.Join(' ', env.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => $"{Display(pair.Key, truncated)}={Display(pair.Value, truncated)}")));
            if (parts.Count == 0) return null;
            return (surface.Name is { Length: > 0 } name ? Display(name, truncated) + ": " : string.Empty) + string.Join("  ", parts);
        }).OfType<string>().ToList();
        if (surfaces.Count > 0) lines.AddRange(["", .. surfaces.Select(line => "  " + line)]);
        return string.Join('\n', lines);
    }

    private static IEnumerable<LayoutSurface> Surfaces(LayoutNode? node) => node switch
    {
        LayoutPane pane => pane.Surfaces,
        LayoutSplit split => Surfaces(split.First).Concat(Surfaces(split.Second)),
        _ => [],
    };
}
