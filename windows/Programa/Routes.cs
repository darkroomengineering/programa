using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Programa;

/// <summary>An event a route can act on: its topic, its fields (absent when empty), and what the
/// routes' safety rules need to know about the report behind it.</summary>
internal sealed record RouteEvent(string Topic, IReadOnlyDictionary<string, string> Fields, string? WorkspaceId, string? SurfaceId,
    bool Trusted = false, bool SessionNamed = false, bool First = false, string? Source = null);

internal sealed record RouteIssue(int? Index, string? Name, string Message);

internal abstract record RouteAction(string Kind);
internal sealed record NotifyAction(string Title, string? Subtitle, string? Body) : RouteAction("notify");
internal sealed record TextAction(string Kind, string Text, bool Steer) : RouteAction(Kind);
internal sealed record RunAction(string Command, long TimeoutMs) : RouteAction("run");
internal sealed record ReviewAction(string Mode, string? BaseBranch) : RouteAction("review");

/// <summary>One `when` condition on a field; every set part must hold.</summary>
internal sealed record RouteCondition(string Field, string? EqualsValue, string? NotEqual, IReadOnlyList<string>? In, bool? Exists, string? Pattern, RegexOptions Options);

internal sealed record RouteDefinition(string Name, string On, string[] Levels, IReadOnlyList<RouteCondition> When, long DebounceMs, long ThrottleMs, string Key, RouteAction Action);

/// <summary>The `routes` block of the global programa.json, as on macOS (docs/programa-json.md#routes):
/// parsing and validation, topic matching and `when`. A route that does not load is an issue; the
/// others still load.</summary>
internal static partial class Routes
{
    /// <summary>Fields that only Programa writes; they may go into text sent to an agent.</summary>
    internal static readonly HashSet<string> IdentifierFields = ["topic", "workspace_id", "surface_id", "state", "previous_state", "source", "kind", "ts", "worktree"];
    /// <summary>Fields an agent (or what it read) can write.</summary>
    internal static readonly HashSet<string> FreeTextFields = ["provider", "title", "subtitle", "body", "cwd", "git_branch",
        "program_status.state", "program_status.kind", "program_status.progress", "program_status.app", "program_status.has_message", "program_status.updated_at"];

    private static bool IsField(string name) => IdentifierFields.Contains(name) || FreeTextFields.Contains(name);

    [GeneratedRegex(@"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}")]
    private static partial Regex Placeholder();

    // A group that repeats and holds a repeat itself, such as (a+)+ or (\w+\s?)*: exponential time.
    [GeneratedRegex(@"\((?:[^()\\]|\\.)*(?:[+*]|\{\d+,\d*\})(?:[^()\\]|\\.)*\)(?:[+*]|\{\d+,\d*\})")]
    private static partial Regex NestedRepeat();

    internal static (List<RouteDefinition> Routes, List<RouteIssue> Issues) Parse(JsonNode? routes)
    {
        var loaded = new List<RouteDefinition>();
        var issues = new List<RouteIssue>();
        if (routes is null) return (loaded, issues);
        if (routes is not JsonArray array)
        {
            issues.Add(new(null, null, "'routes' must be an array."));
            return (loaded, issues);
        }
        var names = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < array.Count; index++)
        {
            var entry = array[index] as JsonObject;
            var name = (entry?["name"] as JsonValue)?.TryGetValue<string>(out var text) == true ? text : null;
            try
            {
                if (entry is null) throw new FormatException("A route must be an object.");
                if (string.IsNullOrWhiteSpace(name)) throw new FormatException("'name' is required.");
                if (!names.Add(name)) throw new FormatException($"'name' {name} is used by an earlier route.");
                loaded.Add(ParseRoute(entry, name));
            }
            catch (FormatException error)
            {
                issues.Add(new(index, string.IsNullOrWhiteSpace(name) ? null : name, error.Message));
            }
        }
        return (loaded, issues);
    }

    private static RouteDefinition ParseRoute(JsonObject entry, string name)
    {
        var on = String(entry, "on") ?? throw new FormatException("'on' is required.");
        var levels = ParseTopic(on);
        var when = ParseWhen(entry["when"]);
        var debounce = Duration(entry["debounceMs"], "debounceMs");
        var throttle = Duration(entry["throttleMs"], "throttleMs");
        var key = String(entry, "key") ?? "{{topic}}";
        CheckPlaceholders(key, "key", identifiersOnly: false);
        var actions = new[] { "notify", "send", "prompt", "run", "review" }.Where(kind => entry.ContainsKey(kind)).ToList();
        if (actions.Count != 1) throw new FormatException("A route has exactly one action: notify, send, prompt, run or review.");
        var kind = actions[0];
        if (entry[kind] is not JsonObject action) throw new FormatException($"'{kind}' must be an object.");
        RouteAction parsed = kind switch
        {
            "notify" => new NotifyAction(Template(action, "title", required: true, "notify", identifiersOnly: false)!,
                Template(action, "subtitle", required: false, "notify", identifiersOnly: false), Template(action, "body", required: false, "notify", identifiersOnly: false)),
            "send" or "prompt" => ParseText(kind, action, levels, throttle),
            "run" => ParseRun(action),
            _ => ParseReview(action),
        };
        return new RouteDefinition(name, on, levels, when, debounce, throttle, key, parsed);
    }

    /// <summary>MQTT-style levels: `+` one level, `#` the rest (last only); no empty level, no mixed wildcard.</summary>
    internal static string[] ParseTopic(string on)
    {
        var levels = on.Split('/');
        for (var index = 0; index < levels.Length; index++)
        {
            var level = levels[index];
            if (level.Length == 0) throw new FormatException($"'on' has an empty level: '{on}'");
            if ((level.Contains('+') || level.Contains('#')) && level is not ("+" or "#")) throw new FormatException($"'on' cannot mix a wildcard with text in a level: '{on}'");
            if (level == "#" && index != levels.Length - 1) throw new FormatException($"'on' may use '#' only as the last level: '{on}'");
        }
        if (levels[0] == "surface") throw new FormatException("Terminal output is not a route event: 'on' cannot start with 'surface'.");
        return levels;
    }

    internal static bool TopicMatches(string[] pattern, string topic)
    {
        var levels = topic.Split('/');
        for (var index = 0; index < pattern.Length; index++)
        {
            if (pattern[index] == "#") return true;
            if (index >= levels.Length || (pattern[index] != "+" && pattern[index] != levels[index])) return false;
        }
        return levels.Length == pattern.Length;
    }

    private static TextAction ParseText(string kind, JsonObject action, string[] levels, long throttle)
    {
        var text = Template(action, "text", required: true, kind, identifiersOnly: true)!;
        var steer = String(action, "whenBusy") switch
        {
            null or "queue" => false,
            "steer" => true,
            var other => throw new FormatException($"{kind}.whenBusy must be queue or steer, not '{other}'."),
        };
        if (kind == "prompt" && throttle < 60_000) throw new FormatException("A prompt route must set throttleMs to at least 60000 (one minute).");
        // An agent waiting for the person cannot take text, so needs_input alone never fires one.
        var id = levels.Length > 1 && levels[1] is not ("+" or "#") ? levels[1] : "x";
        var reachable = new[] { "working", "blocked", "idle", "none" }.Select(state => $"agent/{id}/state/{state}")
            .Concat(new[] { "created", "closed", "renamed" }.Select(change => $"workspace/{id}/{change}"));
        if (!reachable.Any(topic => TopicMatches(levels, topic)))
            throw new FormatException($"A {kind} route cannot fire on needs_input topics only: the agent is waiting for the person then. Use an agent/+/state/… topic.");
        return new TextAction(kind, text, steer);
    }

    private static RunAction ParseRun(JsonObject action)
    {
        var command = String(action, "command");
        if (string.IsNullOrWhiteSpace(command)) throw new FormatException("run.command is required.");
        if (Placeholder().Matches(command).FirstOrDefault(match => IsField(match.Groups[1].Value)) is { } field)
            throw new FormatException($"run.command is never templated; {field.Value} arrives as the environment variable {EnvironmentName(field.Groups[1].Value)}.");
        var timeout = Duration(action["timeoutMs"], "run.timeoutMs");
        return new RunAction(command, timeout > 0 ? timeout : 600_000);
    }

    private static ReviewAction ParseReview(JsonObject action)
    {
        var mode = String(action, "mode") ?? "uncommitted";
        if (mode is not ("uncommitted" or "branch")) throw new FormatException($"review.mode must be uncommitted or branch, not '{mode}'.");
        return new ReviewAction(mode, String(action, "baseBranch"));
    }

    private static List<RouteCondition> ParseWhen(JsonNode? node)
    {
        var conditions = new List<RouteCondition>();
        if (node is null) return conditions;
        if (node is not JsonObject when) throw new FormatException("'when' must be an object.");
        foreach (var (field, value) in when)
        {
            if (!IsField(field)) throw new FormatException($"when: '{field}' is not an event field.");
            switch (value)
            {
                case JsonValue scalar:
                    conditions.Add(new(field, ScalarText(scalar, $"when.{field}"), null, null, null, null, RegexOptions.None));
                    break;
                case JsonObject operators:
                    if (operators.Count == 0) throw new FormatException($"when.{field} has no condition.");
                    string? ne = null, pattern = null, flags = null;
                    List<string>? any = null;
                    bool? exists = null;
                    foreach (var (op, operand) in operators)
                    {
                        switch (op)
                        {
                            case "ne": ne = ScalarText(operand as JsonValue, $"when.{field}.ne"); break;
                            case "in":
                                if (operand is not JsonArray values) throw new FormatException($"when.{field}.in must be an array.");
                                any = values.Select(item => ScalarText(item as JsonValue, $"when.{field}.in")).ToList();
                                break;
                            case "exists":
                                if (operand is not JsonValue flag || !flag.TryGetValue<bool>(out var present)) throw new FormatException($"when.{field}.exists must be true or false.");
                                exists = present;
                                break;
                            case "regex": pattern = (operand as JsonValue)?.TryGetValue<string>(out var regex) == true ? regex : throw new FormatException($"when.{field}.regex must be a string."); break;
                            case "flags": flags = (operand as JsonValue)?.TryGetValue<string>(out var given) == true ? given : throw new FormatException($"when.{field}.flags must be a string."); break;
                            default: throw new FormatException($"when.{field}: unknown operator '{op}'.");
                        }
                    }
                    if (flags is not null && pattern is null) throw new FormatException($"when.{field}: flags without regex.");
                    if (ne is null && any is null && exists is null && pattern is null) throw new FormatException($"when.{field} has no condition.");
                    var options = RegexOptions.None;
                    foreach (var letter in flags ?? "")
                        options |= letter switch
                        {
                            'i' => RegexOptions.IgnoreCase,
                            'm' => RegexOptions.Multiline,
                            's' => RegexOptions.Singleline,
                            'x' => RegexOptions.IgnorePatternWhitespace,
                            _ => throw new FormatException($"when.{field}.flags may hold only i, m, s and x."),
                        };
                    if (pattern is not null)
                    {
                        if (NestedRepeat().IsMatch(pattern)) throw new FormatException($"when.{field}.regex repeats a group that already repeats, which can take exponential time.");
                        try { _ = new Regex(pattern, options); }
                        catch (ArgumentException error) { throw new FormatException($"when.{field}.regex does not compile: {error.Message}"); }
                    }
                    conditions.Add(new(field, null, ne, any, exists, pattern, options));
                    break;
                default:
                    throw new FormatException($"when.{field} must be a value or an operator object.");
            }
        }
        return conditions;
    }

    /// <summary>Whether every `when` condition holds. All regexes of all routes share one 50 ms budget
    /// per event (<paramref name="budget"/>); one stopped or not started counts as unmet, with an error.</summary>
    internal static bool Holds(RouteDefinition route, IReadOnlyDictionary<string, string> fields, Stopwatch budget, out string? error)
    {
        error = null;
        foreach (var condition in route.When)
        {
            var present = fields.TryGetValue(condition.Field, out var value);
            if (condition.EqualsValue is not null && (!present || value != condition.EqualsValue)) return false;
            if (condition.NotEqual is not null && present && value == condition.NotEqual) return false;
            if (condition.In is not null && (!present || !condition.In.Contains(value!))) return false;
            if (condition.Exists is { } exists && present != exists) return false;
            if (condition.Pattern is not null)
            {
                if (!present) return false;
                var left = 50 - budget.ElapsedMilliseconds;
                try
                {
                    if (left <= 0) throw new RegexMatchTimeoutException();
                    var input = value!.Length > 4096 ? value[..4096] : value;
                    if (!Regex.IsMatch(input, condition.Pattern, condition.Options, TimeSpan.FromMilliseconds(left))) return false;
                }
                catch (RegexMatchTimeoutException)
                {
                    error = $"when.{condition.Field}: the regex ran longer than 50 ms and was stopped; the event did not match";
                    return false;
                }
            }
        }
        return true;
    }

    /// <summary>Fills `{{field}}` placeholders; an absent field renders empty, or stays as written for a key.</summary>
    internal static string Render(string template, IReadOnlyDictionary<string, string> fields, bool keepMissing = false) =>
        Placeholder().Replace(template, match => fields.TryGetValue(match.Groups[1].Value, out var value) ? value : keepMissing ? match.Value : string.Empty);

    /// <summary>A run's environment name for a field: PROGRAMA_ROUTE_ and the name upper-cased, other than letters and digits as _.</summary>
    internal static string EnvironmentName(string field) =>
        "PROGRAMA_ROUTE_" + new string(field.ToUpperInvariant().Select(c => char.IsAsciiLetterOrDigit(c) ? c : '_').ToArray());

    /// <summary>Milliseconds, or a string with a unit: "250ms", "4s", "1.5m", "5m", "1h". 0 when absent.</summary>
    internal static long Duration(JsonNode? node, string name)
    {
        if (node is null) return 0;
        if (node is JsonValue value)
        {
            if (Number(value) is { } number)
                return number >= 0 && double.IsFinite(number) ? (long)number : throw new FormatException($"{name} must not be negative.");
            if (value.TryGetValue<string>(out var text))
            {
                var match = DurationText().Match(text.Trim());
                if (match.Success && double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var amount))
                    return (long)(amount * match.Groups[2].Value switch { "ms" or "" => 1, "s" => 1000, "m" => 60_000, _ => 3_600_000 });
            }
        }
        throw new FormatException($"{name} must be milliseconds or a duration such as \"250ms\", \"4s\", \"1.5m\" or \"1h\".");
    }

    [GeneratedRegex(@"^(\d+(?:\.\d+)?)(ms|s|m|h)?$")]
    private static partial Regex DurationText();

    private static string? Template(JsonObject action, string name, bool required, string kind, bool identifiersOnly)
    {
        var text = String(action, name);
        if (text is null)
        {
            if (required) throw new FormatException($"{kind}.{name} is required.");
            return null;
        }
        CheckPlaceholders(text, $"{kind}.{name}", identifiersOnly);
        return text;
    }

    private static void CheckPlaceholders(string template, string where, bool identifiersOnly)
    {
        foreach (Match match in Placeholder().Matches(template))
        {
            var field = match.Groups[1].Value;
            if (!IsField(field)) throw new FormatException($"{where}: {{{{{field}}}}} is not an event field.");
            if (identifiersOnly && !IdentifierFields.Contains(field))
                throw new FormatException($"{where}: {{{{{field}}}}} is free text, which never goes into text sent to an agent.");
        }
    }

    /// <summary>A JSON number however it was made (parsed, or created from an int or a double).</summary>
    private static double? Number(JsonValue value) =>
        value.GetValueKind() == JsonValueKind.Number ? double.Parse(value.ToJsonString(), CultureInfo.InvariantCulture) : null;

    private static string? String(JsonObject node, string name) =>
        node[name] is null ? null
        : node[name] is JsonValue value && value.TryGetValue<string>(out var text) ? text
        : throw new FormatException($"'{name}' must be a string.");

    private static string ScalarText(JsonValue? value, string where)
    {
        if (value is null) throw new FormatException($"{where} must be a string, number or boolean.");
        if (value.TryGetValue<string>(out var text)) return text;
        if (value.TryGetValue<bool>(out var flag)) return flag ? "true" : "false";
        if (Number(value) is { } number) return number.ToString(CultureInfo.InvariantCulture);
        throw new FormatException($"{where} must be a string, number or boolean.");
    }
}
