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
panics. Free stops the shell (only detaches from a hosted one, see host), is safe on null, and must be called exactly once
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
      "cell_height": 16,
      "shell_integration": true,
      "restore_text": "saved output
from the last run",
      "colors": {
        "palette": {"0": [29, 31, 33], "1": [204, 102, 102]},
        "foreground": [255, 255, 255],
        "background": [40, 44, 52],
        "cursor": [255, 255, 255]
      }
    }

restore_text is output saved by session restore; it is written into the new
terminal before the shell starts and then moved into scrollback (an erase of
the main screen), so the shell starts on an empty screen with the saved lines
above it. Control characters are dropped and at most 1 MiB of the end is kept.

shell_integration starts the default PowerShell with Programa's integration, passed
with `-NoExit -EncodedCommand` so it runs after the profile and is not blocked by the
script execution policy: at each prompt it reports the working directory (OSC 7),
the prompt marks (OSC 133;A and B) and a title naming the directory. It has no
effect on an explicit shell or explicit args.

host runs the shell in the terminal host (`programa-host.exe`, `src/host.rs`) instead
of this process, so it survives the app quitting or crashing:

    "host": {"pipe": "\\\\.\\pipe\\programa-host-...", "token": "...", "id": "surface-..."}

The session reattaches to the host's session of that id when it is still running there
(the host replays up to 4 MiB of its past output, which is parsed without answering
queries or raising notifications again, and the shell is resized to this terminal) and
otherwise starts it there; restore_text applies only to a new session. Without a
reachable host the shell runs in this process as before. Free then only detaches: the
shell keeps running.

    int32_t programa_terminal_kill(session);

Ends a hosted shell (its tab was closed); a session running in this process is
unaffected and still ends at free.

    bool programa_terminal_is_hosted(session);

True when the terminal host runs the shell, false when it runs in this process (no host
config, or the host could not be reached).

colors is the frontend's resolved theme as RGB triples; every field is
optional and replaces Ghostty's default (foreground #FFFFFF, background
#282C34, Ghostty's 256-color palette, cursor = foreground). Cells resolve
default and palette colors through it, color queries are answered from it, and
colors a program sets itself with OSC 4/10/11 take precedence in cells.

    int32_t programa_terminal_set_colors(session, const uint8_t *colors_json,
                                         size_t len);

Replaces the colors with a new colors object (same shape), for a theme change
while the session runs, and advances the generation. INVALID_ARGUMENT for bad
JSON.

Defaults: on Windows, shell is the first of pwsh.exe and powershell.exe found on
PATH (with args `-NoLogo` when none are given), else COMSPEC; elsewhere it is
SHELL. working_directory is the user's home, cols and rows are 80 and 24, and
cell size is 8 by 16 pixels. Unless env supplies them, TERM is xterm-256color,
COLORTERM is truecolor and TERM_PROGRAM is ghostty, matching the macOS app so
agents enable truecolor and kitty keyboard input. Sizes below 2 columns or
rows are raised to 2; at most 4096 columns, 4096 rows, and 1,048,576 cells are
accepted.

The emulator answers OSC 4/10/11/12 color queries from its built-in palette
and supports the kitty keyboard protocol flag stack (`CSI > u`, `CSI < u`,
`CSI ? u`); see `programa_terminal_mode` for how the frontend encodes keys.

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

    bool programa_terminal_paste_needs_confirmation(session, const uint8_t *data,
                                                    size_t len);

True when the program has not enabled bracketed paste and the text contains a
line break or another C0 control byte (tab excepted) or DEL, so pasting it
could run commands at once. The Windows app asks before pasting such text.
False for a null session or invalid data.

    uint32_t programa_terminal_mode(session);

Bits for the input modes the program has enabled, 0 for a null session:

    APP_CURSOR = 1          DECCKM: send ESC O A instead of ESC [ A for arrows
    MOUSE_REPORTING = 2     the program tracks the mouse (1000/1002/1003)
    FOCUS_EVENTS = 4        send ESC [ I / ESC [ O on focus gain and loss
    KITTY_DISAMBIGUATE = 8  kitty keyboard flag 1: modified Enter, Tab,
                            Backspace, Escape and Ctrl/Alt+key use CSI u
    ALT_SCREEN = 16         the alternate screen is active

ConPTY passes these modes through when the program asks for them, and passes
the resulting VT input to programs that read it raw (Node, Bun).

    bool programa_terminal_mouse(session, uint32_t button, uint32_t action,
                                 size_t col, size_t row, uint32_t mods);

Reports a mouse event to the program in the encoding it asked for (SGR, UTF-8
or X10). button is 0 left, 1 middle, 2 right, or 3 for motion with no button;
action is 0 press, 1 release, 2 motion; mods is a bit set of shift 1, alt 2,
ctrl 4; col and row are 0-based viewport cells. Returns true when the event
was sent, false when the program is not tracking that event, in which case the
frontend handles it itself (selection).

    int32_t programa_terminal_focus(session, bool focused);

Sends ESC [ I or ESC [ O when the program enabled focus events (ConPTY always
does), without moving a scrolled-back view.

    int32_t programa_terminal_wheel(session, int32_t lines, size_t col,
                                    size_t row, uint32_t mods);

One wheel gesture of lines steps (positive is up). It becomes wheel reports
when the program tracks the mouse, arrow keys when an alternate-screen program
allows alternate scroll, and a scrollback move otherwise.

    bool programa_terminal_find(session, const uint8_t *text, size_t len, bool forward);

Selects the next match of the UTF-8 text, matched literally and case-insensitively
unless it contains an uppercase letter, and scrolls it into view. With a
selection, the search continues after it (forward) or before it; without one it
starts from the bottom of the screen going back, or from the top of scrollback
going forward. Returns true when a match was found; false for no match, empty
text, invalid UTF-8 or a null session.

    int32_t programa_terminal_clear_scrollback(session);

Drops the scrollback above the screen; the screen itself is unchanged.

    int32_t programa_terminal_reset(session);

Reset Terminal: a full reset, as if the program had sent RIS (`ESC c`). The screen,
scrollback, selection and modes the program set (alternate screen, mouse
reporting, keyboard protocols) are cleared and the cursor goes home; copy mode stays.
Nothing is sent to the program, so a shell shows its prompt again after the next key.

    int32_t programa_terminal_text(session, uint32_t max_lines,
                                   ProgramaTerminalBuffer *out);

Writes the last max_lines lines of output, counted back from the last line with
text (so blank rows under the prompt do not count), scrollback included, as plain UTF-8
text: soft-wrapped lines are joined, trailing blanks are trimmed, and lines are
separated by `
`. Session restore saves it and passes it back as restore_text.

    uint32_t programa_terminal_shell_pid(session);

The shell's process id, or 0 when unknown (null session, non-Windows). The
Windows app checks it for child processes before closing, to warn that
something is still running.

    uint64_t programa_terminal_cwd_generation(session);
    int32_t programa_terminal_cwd(session, ProgramaTerminalBuffer *out);

The working directory the shell last reported with `OSC 7 ; file://host/path` or
`OSC 9 ; 9 ; path`, as a native path (`C:\Work`), or an empty buffer before the
first report. The generation moves on every report, also when the directory is
unchanged, so a client can refresh what depends on it (the git branch) at each
prompt.

    int32_t programa_terminal_link_at(session, size_t column, size_t row, ProgramaTerminalBuffer *out);

The `OSC 8` hyperlink URI of the visible cell at (`column`, `row`), or an empty
buffer when it has none or the position is off screen. The Windows app opens it
on Ctrl+click; plain URLs in the text are found by the app itself.

    int32_t programa_terminal_take_notifications(session, ProgramaTerminalBuffer *out);

Writes the desktop notifications programs asked for since the last call, oldest
first, and clears them, or an empty buffer when there are none:

    [{"title": "Claude Code", "body": "Claude needs your permission"}]

Sources are `OSC 777 ; notify ; title ; body` (Claude Code's Ghostty channel)
and `OSC 9 ; body`; ConEmu's numeric `OSC 9 ; N ; ...` forms, such as progress,
are not notifications. Control characters are removed and each field keeps at
most 256 characters. At most 64 wait; older ones are dropped. A new
notification advances the generation.

    int32_t programa_terminal_take_clipboard(session, ProgramaTerminalBuffer *out);

Writes the text the program last stored with OSC 52 and clears it, or an empty
buffer when there is none. Storing advances the generation, so a client checks
on each wake. Clipboard reads (OSC 52 with `?`) are not answered.

## View

    int32_t programa_terminal_resize(session, uint16_t cols, uint16_t rows,
                                     uint16_t cell_width, uint16_t cell_height);
    int32_t programa_terminal_scroll(session, int32_t lines);

Resize checks the same limits as create but does not raise small values: fewer
than 2 columns or rows, or a zero cell size, returns INVALID_ARGUMENT, where
create would raise it to the minimum. A valid size informs the PTY; a size
equal to the current one is a no-op. Scroll moves the viewport into scrollback by lines
(positive is toward older output).

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
      "cursor": {"column": 0, "row": 0, "visible": true, "shape": "block"},
      "selection": {"start_column": 0, "start_row": 0,
                    "end_column": 4, "end_row": 0, "block": false},
      "cells": [{
        "column": 0, "row": 0, "text": "A", "width": 1,
        "foreground": {"r": 220, "g": 220, "b": 220, "a": 255},
        "explicit_foreground": false,
        "background": {"r": 20, "g": 20, "b": 24, "a": 255},
        "explicit_background": false,
        "selected": false, "bold": false, "italic": false,
        "underline": false, "undercurl": false, "strikethrough": false,
        "dim": false
      }],
      "terminated": false,
      "title": "vim"
    }

cells has one entry per grid cell, row by row. width is 1, 2 for a wide
character, or 0 for the spacer that follows it; text is empty for blank cells.
selection is null when nothing is selected. dim marks faint (SGR 2) text. The
cursor's shape is `block`, `underline` or `beam` as the program set it
(DECSCUSR). The cursor is hidden while the view
is scrolled into scrollback; in copy mode it is the copy-mode cursor instead, a block shown
wherever it is in view. terminated is true once the shell has exited. title is the window title the
program set (OSC 0/2), or null when none is set.

Generation increases on every screen, title, selection, size, lifecycle, or
program status change. On Windows, event_handle returns a manual-reset event HANDLE owned by
the session (valid until free; do not close it) that is signaled whenever the
generation changes. On other platforms it returns null. A client waits on the
handle, reads a snapshot, then calls acknowledge_generation with the snapshot's
generation: this resets the event, and sets it again if the generation moved
in between, so no change is lost.

## Program status (OSC 7501)

    uint64_t programa_terminal_program_status_generation(session);
    int32_t programa_terminal_program_status_json(session, ProgramaTerminalBuffer *out);

The library keeps the session's Program Status Protocol records with the same
rules as the macOS app (see `docs/program-status.md`): reports are validated
and applied, OSC 133;A drops `working` and `blocked` records, a full reset
(`ESC c`) removes them all, and a feature query (`OSC 7501 ; ? ST`) is answered
on the PTY with the same terminator. Sequences longer than 4096 bytes are
dropped.

The status generation starts at 0 and increases whenever the records change;
each change also advances the main generation and signals the event, so a
client can check the cheap status generation on every wake, including for
surfaces it is not painting, and read the JSON only when it moved:

    {
      "generation": 3,
      "root": {"id": "", "state": "working", "kind": null, "progress": 40,
               "app": "cargo", "title": null, "msg": null},
      "children": [{"id": "deploy/us-east", "state": "blocked",
                    "kind": "permission", "progress": null, "app": "cargo",
                    "title": "US East", "msg": "Approve the plan?"}]
    }

root is null when the program has not reported on itself. children lists every
other record sorted by id; their app is resolved through the nearest ancestor
that has one. state is `idle`, `working`, `done`, `blocked` or `error`; kind is
`permission`, `question`, `auth` or null. title and msg are decoded text from
the program; show them as untrusted text.

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
place. Clear removes it. Copy writes the selected text (empty when none) using
terminal semantics: soft-wrapped lines are joined and trailing blanks trimmed.

## Copy mode

    int32_t programa_terminal_copy_mode(session, uint32_t command, uint32_t count);

Keyboard copy mode, on alacritty's vi mode: a cursor of its own that moves through
the screen and scrollback, and a selection that follows it. Commands: 0 leaves (and
clears the selection), 1 enters at the terminal cursor, 2 starts a selection at the
cursor, 3 clears it, 4 selects `count` whole lines from the cursor's line, 5 moves the
cursor to the selection's start and keeps the selection (a find's match), 10 to 16 move
the cursor up, down, left, right, to the line's start, its end and its first text, 20 to
23 scroll a page up, a page down, half a page up and half a page down keeping the
cursor's screen row, 24 goes to the top of scrollback and 25 back to the prompt line,
26 and 27 go to the start of the shell prompt above or below the cursor's line (a row
where the shell sent OSC 133;A; the mark stays with the row through scrolling, reflow
and scrollback, a clear drops it, and the alternate screen has none), or the
furthest one there is when fewer than `count` are left, scrolling it into view (the
cursor stays when there is none). Moves, scrolls and prompt jumps repeat `count` times
(1 to 9999). Commands other than 0 and 1 fail with
INVALID_ARGUMENT outside copy mode. A find in copy mode scrolls before it selects, so the
match stays as found.

## Lifecycle and errors

    bool programa_terminal_is_terminated(session);
    int32_t programa_terminal_last_error(session, ProgramaTerminalBuffer *out);

is_terminated is true after the shell exits, and for a null handle. last_error
writes the most recent I/O failure message, or an empty buffer when there has
been none.
