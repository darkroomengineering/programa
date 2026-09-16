# Programa shared core ABI v1

The shared core owns portable state below the native application window:
workspaces contain panes, panes contain ordered surfaces, and a recursive layout
describes pane splits. The session_id is an opaque caller-owned identity. The
core never owns PTY, renderer, or native UI handles.

The first macOS adapter seeds one existing pane, dispatches reorder_surface,
and projects the returned order onto existing Bonsplit tab objects. Full macOS
workspace and split lifecycle migration remains later work.

## C API and ownership

The ABI version is 1. The library basename is programa_core.

    typedef struct ProgramaBuffer {
        uint8_t *data;
        size_t len;
        size_t capacity;
    } ProgramaBuffer;

    uint32_t programa_core_abi_version(void);
    void *programa_core_create(void);
    void programa_core_destroy(void *core);
    int32_t programa_core_dispatch(
        void *core,
        const uint8_t *request,
        size_t len,
        ProgramaBuffer *result
    );
    int32_t programa_core_snapshot(void *core, ProgramaBuffer *result);
    void programa_core_buffer_free(ProgramaBuffer buffer);

Create returns an opaque handle, or null if construction panics. Destroy accepts
null. The caller must keep a handle alive and must not destroy it while another
thread is using it.

Dispatch and snapshot return 0 on success and 1 on error. A nonnull result
receives owned UTF-8 JSON bytes on both paths. Release each returned buffer
exactly once with programa_core_buffer_free. The bytes are length-delimited and
have no nul terminator. A null result returns 1 without output.

Every export contains Rust unwinding. A contained panic returns status 1 and an
error with code panic. Null pointers and lengths are validated where C permits.
A nonnull dangling pointer is outside the contract.

## Snapshot

Snapshot returns a bare snapshot. Dispatch success returns the same value under
a snapshot property.

    {
      "abi_version": 1,
      "revision": 3,
      "selected_workspace_id": "workspace-uuid",
      "workspaces": [{
        "id": "workspace-uuid",
        "selected_pane_id": "pane-uuid",
        "panes": [{
          "id": "pane-uuid",
          "selected_surface_id": "surface-uuid",
          "surfaces": [{
            "id": "surface-uuid",
            "session_id": "opaque-session-uuid",
            "is_pinned": false
          }]
        }],
        "layout": {"type":"pane","pane_id":"pane-uuid"}
      }]
    }

An empty core has a null selected_workspace_id and an empty workspaces array. A
split layout node is recursive:

    {
      "type": "split",
      "id": "split-uuid",
      "direction": "horizontal",
      "ratio": 0.5,
      "first": {"type":"pane","pane_id":"existing-pane-uuid"},
      "second": {"type":"pane","pane_id":"new-pane-uuid"}
    }

Directions are horizontal and vertical. Ratios are finite and strictly between
0 and 1. Every ID and session ID is nonempty. Workspace, pane, surface, and
split IDs share one uniqueness namespace. Every workspace and pane is nonempty,
selected IDs name owned children, and each pane appears once in its layout.
The is_pinned field defaults to false when omitted, but output includes it.

## Commands

Commands use a command tag and reject unknown fields.

    {"command":"seed_snapshot","snapshot":<snapshot>}
    {"command":"create_workspace","workspace_id":"w","pane_id":"p","surface_id":"s","session_id":"session"}
    {"command":"select_workspace","workspace_id":"w"}
    {"command":"close_workspace","workspace_id":"w"}
    {"command":"create_surface","workspace_id":"w","pane_id":"p","surface_id":"s","session_id":"session"}
    {"command":"select_surface","workspace_id":"w","pane_id":"p","surface_id":"s"}
    {"command":"close_surface","workspace_id":"w","pane_id":"p","surface_id":"s"}
    {"command":"reorder_surface","workspace_id":"w","pane_id":"p","surface_id":"s","before_surface_id":"target"}
    {"command":"reorder_surface","workspace_id":"w","pane_id":"p","surface_id":"s","before_surface_id":null}
    {"command":"move_surface","workspace_id":"w","source_pane_id":"p1","target_pane_id":"p2","surface_id":"s","before_surface_id":"target"}
    {"command":"move_surface","workspace_id":"w","source_pane_id":"p1","target_pane_id":"p2","surface_id":"s","before_surface_id":null}
    {"command":"split_pane","workspace_id":"w","pane_id":"p","split_id":"split","new_pane_id":"p2","new_surface_id":"s2","session_id":"session2","direction":"vertical","ratio":0.5}
    {"command":"resize_split","workspace_id":"w","split_id":"split","ratio":0.6}

Creating a workspace, surface, or split selects it and its ancestors. Selecting
a surface also selects its pane and workspace. Closing a selected surface
selects the item at its old index, or the preceding item at the tail. Closing a
pane's final surface removes that pane and collapses its closest split parent to
the sibling branch. If it was the workspace's final pane, the workspace closes.
Closing the final workspace is valid and yields empty state with a null
selected_workspace_id.

Reorder inserts immediately before before_surface_id; null means the trailing
gap. Source and target must belong to the named workspace and pane. The resolved
index is clamped so pinned surfaces remain a prefix. Reorder preserves surface
data, session identity, selection, and the split tree.

Move requires both panes to belong to the named workspace. Its insertion target
must belong to the target pane; null means the trailing gap. A same-pane move
uses reorder semantics. A cross-pane move transfers the complete surface,
including session_id and is_pinned, and collapses the source pane if it becomes
empty. The pinned-prefix clamp applies in the target pane. Success selects the
moved surface, target pane, and workspace.

Commands apply to a cloned candidate and fully validate before commit. Errors
never mutate state. Revision increments once after an actual mutation and stays
unchanged for a valid no-op. Seed validates input, ignores its incoming
revision, and advances the receiving core's revision once when state changes.

Errors have the shape:

    {"error":{"code":"not_found","message":"surface 'missing' was not found"}}

Stable codes include invalid_json, invalid_argument, unsupported_abi_version,
invalid_snapshot, invalid_id, duplicate_id, not_found, invalid_ratio,
revision_overflow, serialization_error, internal_error, and panic.
