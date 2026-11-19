using System.Diagnostics;
using System.Text.Json;

namespace Programa;

internal sealed record PullRequestInfo(int Number, string State, string Url);

/// <summary>A branch's pull request, from the GitHub CLI as on macOS: `gh pr list --head`, preferring
/// an open one, then merged, then closed, then the most recently updated.</summary>
internal static class PullRequests
{
    private static readonly string? Gh = FindGh();

    internal static bool Available => Gh is not null;

    internal static PullRequestInfo? Preferred(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Array) return null;
        return document.RootElement.EnumerateArray()
            .Select(item => (
                Number: item.TryGetProperty("number", out var number) && number.TryGetInt32(out var value) ? value : 0,
                State: item.TryGetProperty("state", out var state) ? state.GetString()?.ToLowerInvariant() : null,
                Url: item.TryGetProperty("url", out var url) ? url.GetString() : null,
                Updated: item.TryGetProperty("updatedAt", out var updated) ? updated.GetString() ?? string.Empty : string.Empty))
            .Where(item => item.Number > 0 && item.Url is not null && item.State is "open" or "merged" or "closed")
            .OrderByDescending(item => item.State switch { "open" => 3, "merged" => 2, _ => 1 })
            .ThenByDescending(item => item.Updated, StringComparer.Ordinal)
            .Select(item => new PullRequestInfo(item.Number, item.State!, item.Url!))
            .FirstOrDefault();
    }

    /// <summary>Null when there is no pull request, `gh` is missing or fails (not signed in, no
    /// GitHub remote), or it takes over 15 seconds.</summary>
    internal static async Task<PullRequestInfo?> LookupAsync(string directory, string branch)
    {
        if (Gh is null || !Directory.Exists(directory)) return null;
        var start = new ProcessStartInfo(Gh) { WorkingDirectory = directory, CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "pr", "list", "--state", "all", "--head", branch, "--json", "number,state,url,updatedAt" })
            start.ArgumentList.Add(argument);
        Process? process = null;
        try
        {
            process = Process.Start(start);
            if (process is null) return null;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var output = await process.StandardOutput.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            return process.ExitCode == 0 ? Preferred(output) : null;
        }
        catch (OperationCanceledException)
        {
            try { process?.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            return null;
        }
        catch (Exception error) when (error is JsonException or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return null;
        }
        finally
        {
            process?.Dispose();
        }
    }

    private static string? FindGh() =>
        (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(directory => Path.Combine(directory.Trim('"'), "gh.exe"))
            .FirstOrDefault(File.Exists);
}
