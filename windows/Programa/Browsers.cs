using System.Diagnostics;
using Microsoft.Win32;

namespace Programa;

/// <summary>Which browsers this machine has, for `app.browsers` and PROGRAMA_DEFAULT_BROWSER, with the
/// macOS keys (Sources/Panels/BrowserAvailability.swift). A browser is installed when it registers under
/// Clients\StartMenuInternet or is running; the default is the https handler the user chose.</summary>
internal static class Browsers
{
    internal sealed record Known(string Key, string Name, string Exe, string? Folder = null);

    // ponytail: the browsers that ship for Windows; the macOS-only ones (Safari, Orion, Dia, SigmaOS, Atlas, Ladybird, Aside) are left out.
    internal static readonly Known[] All =
    [
        new("chrome", "Google Chrome", "chrome.exe", @"\Google\Chrome"),
        new("firefox", "Firefox", "firefox.exe"),
        new("arc", "Arc", "Arc.exe"),
        new("brave", "Brave", "brave.exe"),
        new("edge", "Microsoft Edge", "msedge.exe"),
        new("zen", "Zen Browser", "zen.exe"),
        new("vivaldi", "Vivaldi", "vivaldi.exe"),
        new("opera", "Opera", "opera.exe", @"\Opera\"),
        new("opera-gx", "Opera GX", "opera.exe", @"\Opera GX\"),
        new("comet", "Perplexity Comet", "comet.exe"),
        new("floorp", "Floorp", "floorp.exe"),
        new("waterfox", "Waterfox", "waterfox.exe"),
        new("sidekick", "Sidekick", "sidekick.exe"),
        new("chromium", "Chromium", "chrome.exe", @"\Chromium\"),
    ];

    /// <summary>The program a shell\open\command value runs: the quoted path, or what comes before the arguments.</summary>
    internal static string? ExePath(string? command)
    {
        command = command?.Trim();
        if (string.IsNullOrEmpty(command)) return null;
        if (command[0] == '"') return command.IndexOf('"', 1) is var end and > 1 ? command[1..end] : null;
        var exe = command.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        return exe < 0 ? command : command[..(exe + 4)];
    }

    internal static Known? Match(string? path) =>
        path is null ? null : All.FirstOrDefault(known =>
            string.Equals(Path.GetFileName(path), known.Exe, StringComparison.OrdinalIgnoreCase)
            && (known.Folder is null || path.Contains(known.Folder, StringComparison.OrdinalIgnoreCase)));

    /// <summary>`app.browsers`: every known browser with whether it is installed and running, and the default's key.</summary>
    internal static object Report()
    {
        var registered = Registered().ToList();
        var browsers = All.Select(known =>
        {
            var entry = registered.FirstOrDefault(item => Match(item.Path) == known);
            var (running, runningPath) = Running(known);
            return new
            {
                key = known.Key, name = known.Name, bundle_id = entry.Client ?? known.Exe, path = entry.Path ?? runningPath,
                installed = entry.Path is not null || running, running,
            };
        }).ToList();
        return new { @default = Default()?.Key, browsers };
    }

    /// <summary>The default browser: its key (the ProgId when it is none of the known ones) and its ProgId.</summary>
    internal static (string Key, string ProgId)? Default()
    {
        try
        {
            const string choice = @"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\";
            var progId = (Registry.CurrentUser.OpenSubKey(choice + "UserChoiceLatest")?.GetValue("ProgId")
                ?? Registry.CurrentUser.OpenSubKey(choice + "UserChoice")?.GetValue("ProgId")) as string;
            if (string.IsNullOrEmpty(progId)) return null;
            var path = ExePath(Registry.ClassesRoot.OpenSubKey($@"{progId}\shell\open\command")?.GetValue(null) as string);
            return (Match(path)?.Key ?? progId, progId);
        }
        catch (Exception error) when (error is System.Security.SecurityException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static IEnumerable<(string? Client, string? Path)> Registered()
    {
        var roots = new[]
        {
            (RegistryHive.CurrentUser, RegistryView.Default), (RegistryHive.LocalMachine, RegistryView.Registry64), (RegistryHive.LocalMachine, RegistryView.Registry32),
        };
        foreach (var (hive, view) in roots)
        {
            using var root = RegistryKey.OpenBaseKey(hive, view);
            using var clients = root.OpenSubKey(@"SOFTWARE\Clients\StartMenuInternet");
            foreach (var client in clients?.GetSubKeyNames() ?? [])
            {
                using var command = clients!.OpenSubKey($@"{client}\shell\open\command");
                if (ExePath(command?.GetValue(null) as string) is { } path) yield return (client, path);
            }
        }
    }

    /// <summary>Whether a copy of <paramref name="known"/> runs, and its path when that is readable.</summary>
    private static (bool Running, string? Path) Running(Known known)
    {
        var processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(known.Exe));
        try
        {
            foreach (var process in processes)
            {
                string? path;
                try { path = process.MainModule?.FileName; }
                catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException) { path = null; }
                // Without a readable path only a browser that shares its program name with no other counts.
                if (path is null ? known.Folder is null : Match(path) == known) return (true, path);
            }
            return (false, null);
        }
        finally
        {
            foreach (var process in processes) process.Dispose();
        }
    }
}
