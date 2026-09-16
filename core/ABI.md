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

## Process layer

`programa-domain` (above) is a state model with no process of its own: it is
linked into whatever owns the window. Two things link it today, and they
share the same state model but not a process.

- **`programa-ffi`** wraps `programa-domain::Core` behind the C ABI documented
  above and is statically linked into the macOS app (`libprograma_core.a`,
  built by `scripts/build-shared-core.sh`). It runs in the app's own process,
  on the app's own thread, with no IPC in the loop.
- **`programad`** (`core/crates/programad`, moved in from
  `darkroomengineering/programa-core`) is a separate headless process that
  owns PTYs, session write-ahead logs, and attach/detach/fd-handoff, and now
  also links `programa-domain` directly to expose the same state model over
  its Unix-socket wire protocol (`core/docs/programad.md`): `workspace.snapshot`
  and `workspace.dispatch` take and return the exact JSON documented above
  under "Snapshot" and "Commands" -- a client sends the same `Command` object
  either as C ABI request bytes or as a `workspace.dispatch` request's
  `params`, and gets the same `Snapshot` JSON back either way.

**What `programad` owns:** PTYs and their child processes, the per-session
WAL, attach/detach and `SCM_RIGHTS` fd handoff, and now the `workspace.*`
surface over that same socket. A domain surface that is a terminal carries a
`session_id` that names one of `programad`'s own sessions; `workspace.dispatch`
rejects any command that would attach a *new* surface to a `session_id`
`programad` doesn't recognize (`create_workspace`, `create_surface`,
`split_pane`, and every surface named in a `seed_snapshot`).

**What `programa-domain` owns:** the state model itself --
workspaces/panes/surfaces/layout/selection -- with no opinion on what a
session ID means or how to reach it. It doesn't know sessions exist; it only
stores the ID a caller gave it.

**How a client attaches:** connect to `programad`'s Unix socket, call
`session.open` (or `session.attach` to an existing session) to get a PTY, and
call `workspace.dispatch` to create or update a surface with that session's
`id`. `system.capabilities` advertises `workspace.snapshot` and
`workspace.dispatch` alongside the `session.*` methods, so a client can probe
for the feature before using it.

**Session/surface lifecycle:** closing a session that backs a domain surface
closes that surface too (`session.close` reconciles the domain state before
returning). The surface is removed outright rather than marked terminated --
`programa-domain` has no terminated state today, and removal matches what a
client already does when a terminal process exits. If a future need arises
for a surface to outlive its session (e.g. showing a "process exited" state
in the pane instead of collapsing it), that's a `programa-domain` schema
change, not a `programad` one.

**What remains:** the macOS app still runs its own in-process adapter
(`Sources/SharedWorkspaceCore.swift`) against `programa-ffi` rather than
`programad`'s socket, so today there are two live links to the same state
model and no single source of truth yet. Remote transport
(`core/docs/remote-transport.md`) and org mode
(`docs/plans/rust-core-spike.md` "Reframe") are unimplemented; both build on
`programad` owning the socket, not on anything `workspace.*` changes here.
