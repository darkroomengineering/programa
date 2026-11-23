namespace Programa;

/// <summary>Pane geometry from a workspace's split tree, as macOS reads it off bonsplit
/// (Sources/TabManager+Splits.swift): pane frames, moving a pane's border by points
/// (pane.resize) and proportional equalizing (workspace.equalize_splits). The core calls a
/// side-by-side split "vertical"; macOS names it "horizontal", and the socket speaks macOS.</summary>
internal static class PaneGeometry
{
    /// <summary>The divider between a split's two sides (MainWindow.BuildLayout).</summary>
    internal const double Divider = 8;

    internal readonly record struct Frame(double X, double Y, double Width, double Height);

    internal sealed record Resized(string SplitId, double Old, double New);

    /// <summary>The panes in layout order, first side before second.</summary>
    internal static List<string> Panes(LayoutSnapshot node) =>
        node.Type == "pane" ? [node.PaneId!] : [.. Panes(node.First!), .. Panes(node.Second!)];

    /// <summary>macOS's orientation name for a split.</summary>
    internal static string Orientation(LayoutSnapshot split) => split.Direction == "vertical" ? "horizontal" : "vertical";

    internal static Dictionary<string, Frame> Frames(LayoutSnapshot node, Frame within)
    {
        var frames = new Dictionary<string, Frame>(StringComparer.Ordinal);
        void Visit(LayoutSnapshot item, Frame frame)
        {
            if (item.Type == "pane")
            {
                frames[item.PaneId!] = frame;
                return;
            }
            var (first, second) = Sides(item, frame);
            Visit(item.First!, first);
            Visit(item.Second!, second);
        }
        Visit(node, within);
        return frames;
    }

    /// <summary>The pane next to <paramref name="paneId"/> on a side (dx -1 left, 1 right; dy -1 up,
    /// 1 down), as bonsplit's adjacentPane: the most overlap across that side, then the nearest; or null.</summary>
    internal static string? Adjacent(LayoutSnapshot root, string paneId, int dx, int dy)
    {
        var frames = Frames(root, new Frame(0, 0, 1000, 1000));
        if (!frames.TryGetValue(paneId, out var from)) return null;
        static double Overlap(double a1, double a2, double b1, double b2) => Math.Max(0, Math.Min(a2, b2) - Math.Max(a1, b1));
        // How far a pane lies past this one's edge on that side; negative is not on that side.
        double Gap(Frame b) => dx < 0 ? from.X - (b.X + b.Width) : dx > 0 ? b.X - (from.X + from.Width)
            : dy < 0 ? from.Y - (b.Y + b.Height) : b.Y - (from.Y + from.Height);
        double Across(Frame b) => dx != 0 ? Overlap(from.Y, from.Y + from.Height, b.Y, b.Y + b.Height) : Overlap(from.X, from.X + from.Width, b.X, b.X + b.Width);
        return frames.Where(entry => entry.Key != paneId && Gap(entry.Value) >= -0.001)
            .OrderByDescending(entry => Math.Round(Across(entry.Value), 3)).ThenBy(entry => Gap(entry.Value))
            .Select(entry => entry.Key).FirstOrDefault();
    }

    /// <summary>A split's two sides, as the window lays them out: star-sized around the divider.</summary>
    private static (Frame First, Frame Second) Sides(LayoutSnapshot split, Frame frame)
    {
        var ratio = Math.Clamp(split.Ratio, 0.1, 0.9);
        if (split.Direction == "vertical")
        {
            var width = Math.Max(0, frame.Width - Divider);
            return (frame with { Width = width * ratio }, frame with { X = frame.X + width * ratio + Divider, Width = width * (1 - ratio) });
        }
        var height = Math.Max(0, frame.Height - Divider);
        return (frame with { Height = height * ratio }, frame with { Y = frame.Y + height * ratio + Divider, Height = height * (1 - ratio) });
    }

    /// <summary>Moves the pane's border on the <paramref name="direction"/> side by <paramref name="amount"/>
    /// points: the innermost split of that orientation with the pane on the right side of it, within
    /// 0.1...0.9, as macOS TabManager.resizePane.</summary>
    internal static Resized Resize(LayoutSnapshot root, string paneId, string direction, int amount, Frame within)
    {
        // Innermost first: each split on the way to the pane, with whether the pane is in its first side.
        var path = new List<(LayoutSnapshot Split, Frame Frame, bool PaneInFirst)>();
        bool Find(LayoutSnapshot node, Frame frame)
        {
            if (node.Type == "pane") return node.PaneId == paneId;
            var (first, second) = Sides(node, frame);
            if (Find(node.First!, first)) path.Add((node, frame, true));
            else if (Find(node.Second!, second)) path.Add((node, frame, false));
            else return false;
            return true;
        }
        if (!Find(root, within)) throw new ControlException("not_found", "Pane not found in split tree", new { pane_id = paneId });
        var sideBySide = direction is "left" or "right";
        var matching = path.Where(item => (item.Split.Direction == "vertical") == sideBySide).ToList();
        if (matching.Count == 0)
            throw new ControlException("invalid_state", $"No {(sideBySide ? "horizontal" : "vertical")} split ancestor for pane", new { pane_id = paneId, direction });
        // A split moves the right or bottom border of a pane in its first side, the left or top of one in its second.
        var paneFirst = direction is "right" or "down";
        if (matching.FirstOrDefault(item => item.PaneInFirst == paneFirst) is not { Split: not null } candidate)
            throw new ControlException("invalid_state", $"Pane has no adjacent border in direction {direction}", new { pane_id = paneId, direction });
        var axis = Math.Max(1, sideBySide ? candidate.Frame.Width : candidate.Frame.Height);
        var old = candidate.Split.Ratio;
        return new Resized(candidate.Split.Id!, old, Math.Clamp(old + (paneFirst ? 1 : -1) * amount / axis, 0.1, 0.9));
    }

    /// <summary>Where a tab dropped on a pane goes, as bonsplit's zoneForLocation: the outer quarter
    /// (at least 80 DIPs) of each side splits that way, left and right first at the corners; the
    /// middle moves the tab into the pane.</summary>
    internal static string DropZone(double x, double y, double width, double height)
    {
        var across = Math.Max(80, width * 0.25);
        var down = Math.Max(80, height * 0.25);
        return x < across ? "left" : x > width - across ? "right" : y < down ? "up" : y > height - down ? "down" : "center";
    }

    /// <summary>The placeholder a drop zone shows: the half the tab would take, or the whole pane, 4 DIPs in.</summary>
    internal static Frame DropPlaceholder(string zone, double width, double height)
    {
        const double inset = 4;
        return zone switch
        {
            "left" => new(inset, inset, width / 2 - inset, height - 2 * inset),
            "right" => new(width / 2, inset, width / 2 - inset, height - 2 * inset),
            "up" => new(inset, inset, width - 2 * inset, height / 2 - inset),
            "down" => new(inset, height / 2, width - 2 * inset, height / 2 - inset),
            _ => new(inset, inset, width - 2 * inset, height - 2 * inset),
        };
    }

    /// <summary>Each split's ratio for equal panes: a split with N1 panes before and N2 after sits at
    /// N1/(N1+N2). With <paramref name="orientation"/> (macOS name), only splits of it.</summary>
    internal static List<(string SplitId, double Ratio)> Equalized(LayoutSnapshot node, string? orientation)
    {
        var ratios = new List<(string, double)>();
        void Visit(LayoutSnapshot item)
        {
            if (item.Type != "split") return;
            if (orientation is null || Orientation(item) == orientation)
            {
                double first = Panes(item.First!).Count, second = Panes(item.Second!).Count;
                ratios.Add((item.Id!, first / (first + second)));
            }
            Visit(item.First!);
            Visit(item.Second!);
        }
        Visit(node);
        return ratios;
    }
}
