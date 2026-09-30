# Programa terminal ABI

The terminal library owns one PTY-backed terminal emulator per session and
exposes its screen as JSON snapshots. The Windows app loads it as
programa_terminal.dll through `include/programa_terminal.h`; the crate is
`crates/programa-terminal`. It is separate from the shared core ABI in `ABI.md`
and is not part of the Cargo workspace.

## C API and ownership

    typedef struct ProgramaTerminalSession ProgramaTerminalSession;
    typedef struct ProgramaTerminalBuffer {
        uint8_t *data;
        size_t len;
    } ProgramaTerminalBuffer;

    ProgramaTerminalSession *programa_terminal_create(
        const uint8_t *config_json, size_t config_len,
        ProgramaTerminalBuffer *error);
    void programa_terminal_free(ProgramaTerminalSession *session);
    void programa_terminal_buffer_free(uint8_t *data, size_t len);

Create returns an opaque handle, or null with UTF-8 text in error (when error
is nonnull) if the config is invalid, the PTY cannot start, or construction
panics. Free stops the shell, is safe on null, and must be called exactly once
per handle. A handle may be used from any thread, but the caller must not free
it while another thread is inside a call on it.

Every buffer written to an out parameter is owned by the caller. Release it
exactly once with programa_terminal_buffer_free(data, len), passing both fields
unchanged. Buffers hold UTF-8 without a nul terminator. An out parameter is
zeroed before any other work, so a failed call leaves an empty buffer that needs
no release.

Every export contains Rust unwinding. A contained panic returns status 2 from
status-returning calls, and the neutral value (0, false, or null) elsewhere,
except programa_terminal_is_terminated, which returns true.

## Status codes

Functions returning int32_t use:

    PROGRAMA_TERMINAL_OK = 0
    PROGRAMA_TERMINAL_INVALID_ARGUMENT = 1   null handle or out pointer, bad
                                             length, unknown selection mode
    PROGRAMA_TERMINAL_FAILED = 2             serialization failure or panic

## Create config

config_json is a JSON object, or empty (len 0) for all defaults. Unknown fields
are ignored.

    {
      "shell": "C:\\Windows\\System32\\cmd.exe",
      "args": ["/k"],
      "working_directory": "C:\\Users\\me",
      "env": {"NAME": "value"},
      "cols": 80,
      "rows": 24,
      "cell_width": 8,
      "cell_height": 16
    }

Defaults: shell is COMSPEC (Windows) or SHELL (elsewhere), working_directory is
the user's home, cols and rows are 80 and 24, cell size is 8 by 16 pixels, and
TERM is set to xterm-256color unless env supplies it. Sizes below 2 columns or
rows are raised to 2; at most 4096 columns, 4096 rows, and 1,048,576 cells are
accepted.

## Input

    int32_t programa_terminal_write(session, const uint8_t *data, size_t len);
    int32_t programa_terminal_paste(session, const uint8_t *data, size_t len,
                                    bool bracketed);

Write sends raw bytes to the PTY. Paste sends text; when bracketed is true and
the program has enabled bracketed paste, the text is wrapped in ESC[200~ and
ESC[201~ and every C0 control byte except tab, CR, and LF (including ESC) is
removed first, so pasted text cannot close the bracket. Without bracketing the
bytes are sent unchanged. Both calls return a scrolled-back view to the bottom. A zero
length is valid and a null data pointer is accepted only with length 0.

    bool programa_terminal_application_cursor(session);

True while the program has enabled application cursor keys (DECCKM), so the
caller sends ESC O A instead of ESC [ A for the arrow keys.

## View

    int32_t programa_terminal_resize(session, uint16_t cols, uint16_t rows,
                                     uint16_t cell_width, uint16_t cell_height);
    int32_t programa_terminal_scroll(session, int32_t lines);
    int32_t programa_terminal_scroll_to_bottom(session);

Resize applies the same bounds as create and informs the PTY; a size equal to
the current one is a no-op. Scroll moves the viewport into scrollback by lines
(positive is toward older output). Scroll to bottom returns to the live screen.

## Snapshot and change notification

    int32_t programa_terminal_snapshot_json(session, ProgramaTerminalBuffer *out);
    uint64_t programa_terminal_generation(session);
    void *programa_terminal_event_handle(session);
    int32_t programa_terminal_acknowledge_generation(session, uint64_t generation);

Snapshot writes one JSON object describing the visible viewport:

    {
      "generation": 7,
      "columns": 80,
      "rows": 24,
      "display_offset": 0,
      "cursor": {"column": 0, "row": 0, "visible": true},
      "selection": {"start_column": 0, "start_row": 0,
                    "end_column": 4, "end_row": 0, "block": false},
      "cells": [{
        "column": 0, "row": 0, "text": "A", "width": 1,
        "foreground": {"r": 220, "g": 220, "b": 220, "a": 255},
        "explicit_foreground": false,
        "background": {"r": 20, "g": 20, "b": 24, "a": 255},
        "explicit_background": false,
        "selected": false, "bold": false, "italic": false,
        "underline": false, "undercurl": false, "strikethrough": false
      }],
      "terminated": false,
      "title": "vim"
    }

cells has one entry per grid cell, row by row. width is 1, 2 for a wide
character, or 0 for the spacer that follows it; text is empty for blank cells.
selection is null when nothing is selected. The cursor is hidden while the view
is scrolled into scrollback. terminated is true once the shell has exited. title is the window title the
program set (OSC 0/2), or null when none is set.

Generation increases on every screen, title, selection, size, or lifecycle
change. On Windows, event_handle returns a manual-reset event HANDLE owned by
the session (valid until free; do not close it) that is signaled whenever the
generation changes. On other platforms it returns null. A client waits on the
handle, reads a snapshot, then calls acknowledge_generation with the snapshot's
generation: this resets the event, and sets it again if the generation moved
in between, so no change is lost.

## Selection

    enum { SIMPLE = 0, BLOCK = 1, WORD = 2, LINE = 3 };
    int32_t programa_terminal_selection_begin(session, size_t col, size_t row,
                                              uint32_t mode);
    int32_t programa_terminal_selection_update(session, size_t col, size_t row);
    int32_t programa_terminal_selection_end(session);
    int32_t programa_terminal_selection_clear(session);
    int32_t programa_terminal_copy_selection(session, ProgramaTerminalBuffer *out);

Coordinates are viewport cells and are clamped to the grid. Begin replaces any
selection; update extends it; end is accepted and leaves the selection in
place; clear removes it. Copy writes the selected text (empty when none) using
terminal semantics: soft-wrapped lines are joined and trailing blanks trimmed.

## Lifecycle and errors

    bool programa_terminal_is_terminated(session);
    int32_t programa_terminal_last_error(session, ProgramaTerminalBuffer *out);

is_terminated is true after the shell exits, and for a null handle. last_error
writes the most recent I/O failure message, or an empty buffer when there has
been none.
