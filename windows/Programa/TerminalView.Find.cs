using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Programa;

/// <summary>Find in terminal (macOS ⌘F): a floating bar at the terminal's top right. Typing searches
/// back from the newest output; Enter goes to the previous (older) match, Shift+Enter to the next,
/// Escape closes. The match is the terminal selection, so copying it works as usual.</summary>
public sealed partial class TerminalView
{
    private void BuildFindBar()
    {
        _findBox.PlaceholderText = Localizer.Get("FindPlaceholder");
        _findBox.Width = 220;
        AutomationProperties.SetName(_findBox, Localizer.Get("FindPlaceholder"));
        _findBox.TextChanged += (_, _) => FindFromBottom();
        _findBox.KeyDown += (_, args) =>
        {
            if (args.Key == VirtualKey.Enter)
            {
                var shift = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                FindNext(forward: shift);
                args.Handled = true;
            }
            else if (args.Key == VirtualKey.Escape)
            {
                HideFind();
                args.Handled = true;
            }
        };
        _findStatus.VerticalAlignment = VerticalAlignment.Center;
        _findStatus.FontSize = 12;
        _findStatus.Opacity = 0.7;

        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        bar.Children.Add(_findBox);
        bar.Children.Add(_findStatus);
        bar.Children.Add(FindButton("", "FindPrevious", () => FindNext(forward: false)));
        bar.Children.Add(FindButton("", "FindNext", () => FindNext(forward: true)));
        bar.Children.Add(FindButton("", "CloseFind", HideFind));
        _findBar.Child = bar;
        _findBar.Padding = new Thickness(6);
        _findBar.Margin = new Thickness(0, 8, 16, 0);
        _findBar.CornerRadius = new CornerRadius(8);
        _findBar.BorderThickness = new Thickness(1);
        _findBar.Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"];
        _findBar.BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"];
        _findBar.HorizontalAlignment = HorizontalAlignment.Right;
        _findBar.VerticalAlignment = VerticalAlignment.Top;
        _findBar.Visibility = Visibility.Collapsed;
        _root.Children.Add(_findBar);
    }

    private static Button FindButton(string glyph, string labelKey, Action handler)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 12 }, Padding = new Thickness(8, 6, 8, 6) };
        AutomationProperties.SetName(button, Localizer.Get(labelKey));
        ToolTipService.SetToolTip(button, Localizer.Get(labelKey));
        button.Click += (_, _) => handler();
        return button;
    }

    public void ShowFind()
    {
        _findBar.Visibility = Visibility.Visible;
        PlaceCopyBadge();
        _findBox.Focus(FocusState.Programmatic);
        _findBox.SelectAll();
    }

    /// <summary>Find Next / Find Previous (macOS ⌘G, ⌥⌘G), as Enter and Shift+Enter; with no query the bar opens.</summary>
    public void FindAgain(bool next)
    {
        if (_findBox.Text.Length == 0) ShowFind();
        else FindNext(forward: !next);
    }

    public void CloseFind()
    {
        if (_findBar.Visibility == Visibility.Visible) HideFind();
    }

    /// <summary>Use Selection for Find (macOS ⌘E): the selection's first line becomes the query.</summary>
    public void FindSelection()
    {
        if (_session is null || !NativeTerminal.TryCopySelection(_session, out var text) || text.Split('\n')[0].TrimEnd('\r') is not { Length: > 0 } line) return;
        _findBox.Text = line;
        ShowFind();
    }

    private void HideFind()
    {
        _findBar.Visibility = Visibility.Collapsed;
        PlaceCopyBadge();
        // Copy mode picks up at the match.
        CopyModeToMatch();
        _findStatus.Text = string.Empty;
        FocusTerminal();
    }

    /// <summary>A new query starts over from the newest output.</summary>
    private void FindFromBottom()
    {
        if (_session is null) return;
        NativeTerminal.ClearSelection(_session);
        FindNext(forward: false);
    }

    private void FindNext(bool forward)
    {
        if (_session is null || _findBox.Text.Length == 0)
        {
            _findStatus.Text = string.Empty;
            return;
        }
        var found = NativeTerminal.Find(_session, Encoding.UTF8.GetBytes(_findBox.Text), forward);
        _findStatus.Text = found ? string.Empty : Localizer.Get("FindNoMatches");
    }
}
