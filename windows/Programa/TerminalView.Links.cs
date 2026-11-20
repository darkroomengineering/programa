using System.Text;
using System.Text.RegularExpressions;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Programa;

/// <summary>Links, as Ghostty opens them with ⌘-click on macOS: Ctrl+click opens a URL in the text or
/// an OSC 8 hyperlink, and holding Ctrl over one underlines it and shows the hand cursor.</summary>
public sealed partial class TerminalView
{
    private static readonly Regex UrlPattern = new(@"\b(?:https?|file)://[^\s<>""'`]+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    /// <summary>The link Ctrl is hovering: its row, first and last column, and URI.</summary>
    private (int Row, int Start, int End, string Uri)? _hoverLink;

    /// <summary>The URL in <paramref name="text"/> covering <paramref name="column"/>, without the
    /// punctuation that usually ends a sentence after it.</summary>
    internal static (int Start, int End, string Uri)? UrlAt(string text, int column)
    {
        foreach (Match match in UrlPattern.Matches(text))
        {
            var value = match.Value.TrimEnd('.', ',', ';', ':', '!', '?', '\'', '"', ']', '}');
            // A closing parenthesis belongs to the URL only when it opened one, as in Wikipedia links.
            while (value.EndsWith(')') && value.Count(c => c == '(') < value.Count(c => c == ')')) value = value[..^1].TrimEnd('.', ',', ';', ':', '!', '?');
            if (column >= match.Index && column < match.Index + value.Length) return (match.Index, match.Index + value.Length - 1, value);
        }
        return null;
    }

    /// <summary>The link at a visible cell: its OSC 8 hyperlink, else a URL in the row's text.</summary>
    private (int Row, int Start, int End, string Uri)? LinkAt(nuint column, nuint row)
    {
        if (_session is not { } session) return null;
        TerminalSnapshot? snapshot;
        lock (_snapshotGate) snapshot = _snapshot;
        if (snapshot is null || (int)row >= snapshot.Rows || (int)column >= snapshot.Columns) return null;
        if (NativeTerminal.LinkAt(session, column, row) is { Length: > 0 } uri)
        {
            // The run of cells around this one that carry the same link.
            var start = (int)column;
            var end = (int)column;
            while (start > 0 && NativeTerminal.LinkAt(session, (nuint)(start - 1), row) == uri) start--;
            while (end + 1 < snapshot.Columns && NativeTerminal.LinkAt(session, (nuint)(end + 1), row) == uri) end++;
            return ((int)row, start, end, uri);
        }
        var text = new StringBuilder(new string(' ', snapshot.Columns));
        foreach (var cell in snapshot.Cells)
            if (cell.Row == (int)row && cell.Column < snapshot.Columns && cell.Text.Length > 0) text[cell.Column] = cell.Text[0];
        return UrlAt(text.ToString(), (int)column) is { } url ? ((int)row, url.Start, url.End, url.Uri) : null;
    }

    /// <summary>Ctrl+left click on a link opens it; true when it did.</summary>
    private bool OpenLinkOnClick(PointerRoutedEventArgs args, nuint column, nuint row)
    {
        if (!args.KeyModifiers.HasFlag(VirtualKeyModifiers.Control) || LinkAt(column, row) is not { } link) return false;
        if (Uri.TryCreate(link.Uri, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" or "file" or "mailto")
            _ = Launcher.LaunchUriAsync(uri);
        args.Handled = true;
        return true;
    }

    /// <summary>Underlines the link under the pointer while Ctrl is held, with the hand cursor.</summary>
    private void UpdateHoverLink(PointerRoutedEventArgs args, nuint column, nuint row)
    {
        var hover = args.KeyModifiers.HasFlag(VirtualKeyModifiers.Control) ? LinkAt(column, row) : null;
        if (hover == _hoverLink) return;
        _hoverLink = hover;
        ProtectedCursor = hover is null ? null : InputSystemCursor.Create(InputSystemCursorShape.Hand);
        _canvas.Invalidate();
    }

    private bool InHoverLink(TerminalCell cell) =>
        _hoverLink is { } link && cell.Row == link.Row && cell.Column >= link.Start && cell.Column <= link.End;
}
