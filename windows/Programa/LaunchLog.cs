using System.Runtime.InteropServices;

namespace Programa;

/// <summary>
/// Dependency-free crash/launch logger for the WinExe entry point, where there is no console
/// and an unhandled exception in <c>Application.Start</c> is otherwise completely silent.
/// Writes to <c>%LOCALAPPDATA%\Programa\launch.log</c> and shows a native message box so a
/// failed launch always leaves visible evidence, on machine and on screen.
/// </summary>
internal static class LaunchLog
{
    internal static string LogPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programa",
        "launch.log");

    /// <summary>Appends a single line with a timestamp. Never throws.</summary>
    internal static void Write(string message)
    {
        try
        {
            var directory = Path.GetDirectoryName(LogPath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            File.AppendAllText(LogPath, $"[{DateTimeOffset.Now:O}] {message}{Environment.NewLine}");
        }
        catch
        {
            // The logger must never throw during crash handling; losing the log line is
            // preferable to masking the original failure or crashing the handler itself.
        }
    }

    /// <summary>Logs an exception with its stack trace, then shows a message box naming the log path.</summary>
    internal static void ReportFatal(string title, Exception error)
    {
        Write($"FATAL {title}: {error}");
        ShowMessageBox(title, $"{error.Message}\n\nDetails were written to:\n{LogPath}");
    }

    internal static void ShowMessageBox(string title, string message)
    {
        try
        {
            _ = NativeMethods.MessageBoxW(nint.Zero, message, title, NativeMethods.MB_OK | NativeMethods.MB_ICONERROR | NativeMethods.MB_TOPMOST);
        }
        catch
        {
            // Best effort only; if user32 cannot be reached the log file is still the record.
        }
    }

    private static partial class NativeMethods
    {
        internal const uint MB_OK = 0x00000000;
        internal const uint MB_ICONERROR = 0x00000010;
        internal const uint MB_TOPMOST = 0x00040000;

        [LibraryImport("user32.dll", EntryPoint = "MessageBoxW", StringMarshalling = StringMarshalling.Utf16)]
        internal static partial int MessageBoxW(nint hWnd, string text, string caption, uint type);
    }
}
