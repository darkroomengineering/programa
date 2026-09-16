using System.Text.Json.Serialization;

namespace Programa;

public sealed record CoreSnapshot(
    [property: JsonPropertyName("abi_version")] uint AbiVersion,
    [property: JsonPropertyName("revision")] ulong Revision,
    [property: JsonPropertyName("selected_workspace_id")] string? SelectedWorkspaceId,
    [property: JsonPropertyName("workspaces")] IReadOnlyList<WorkspaceSnapshot> Workspaces);

public sealed record WorkspaceSnapshot(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("selected_pane_id")] string SelectedPaneId,
    [property: JsonPropertyName("panes")] IReadOnlyList<PaneSnapshot> Panes,
    [property: JsonPropertyName("layout")] LayoutSnapshot Layout)
{
    public PaneSnapshot? SelectedPane => Panes.FirstOrDefault(pane => pane.Id == SelectedPaneId);
}

public sealed record PaneSnapshot(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("selected_surface_id")] string SelectedSurfaceId,
    [property: JsonPropertyName("surfaces")] IReadOnlyList<SurfaceSnapshot> Surfaces)
{
    public SurfaceSnapshot? SelectedSurface => Surfaces.FirstOrDefault(surface => surface.Id == SelectedSurfaceId);
}

public sealed record SurfaceSnapshot(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("session_id")] string SessionId,
    [property: JsonPropertyName("is_pinned")] bool IsPinned);

public sealed record LayoutSnapshot
{
    [JsonPropertyName("type")]
    public required string Type { get; init; }

    [JsonPropertyName("pane_id")]
    public string? PaneId { get; init; }

    [JsonPropertyName("id")]
    public string? Id { get; init; }

    [JsonPropertyName("direction")]
    public string? Direction { get; init; }

    [JsonPropertyName("ratio")]
    public double Ratio { get; init; }

    [JsonPropertyName("first")]
    public LayoutSnapshot? First { get; init; }

    [JsonPropertyName("second")]
    public LayoutSnapshot? Second { get; init; }
}

internal sealed record DispatchResponse([property: JsonPropertyName("snapshot")] CoreSnapshot Snapshot);

internal sealed record CoreErrorEnvelope([property: JsonPropertyName("error")] CoreError Error);

internal sealed record CoreError(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("message")] string Message);
