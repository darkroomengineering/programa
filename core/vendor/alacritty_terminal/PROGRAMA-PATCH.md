# Programa patch for alacritty_terminal 0.26.0

This directory contains the published `alacritty_terminal` 0.26.0 source and
its Apache-2.0 license. Reference-test fixtures from the crate archive are
omitted because they are not needed to build this dependency.

Programa changes `EventLoop::pty_read` so bytes already read from the PTY are
parsed before EOF completes or a non-retryable read error is returned. The published
implementation can read bytes, fail to acquire the terminal mutex, then read
again and return on EOF/EIO while the first bytes remain unprocessed. This is
observable when a short-lived child prints its final line and exits while the
UI snapshots the terminal.

The upstream reference-test target and its 46 MB of fixtures are omitted. The
focused unit test in `src/event_loop.rs` holds the terminal mutex while a fake
PTY returns bytes followed by `BrokenPipe`. It verifies both that the pending
bytes reach the terminal after the mutex becomes available and that the read
error is still returned.

Programa also changes the `ChildEvent::Exited` handling in
`EventLoop::spawn`'s event loop to drain the PTY in a short, bounded retry
loop instead of a single non-blocking read. On Windows, ConPTY output is
copied out of the OS pipe by a background reader thread
(`tty/windows/blocking.rs`) into an in-process buffer that `pty_read` drains;
the child-exit notification (`RegisterWaitForSingleObject` on the child
process handle) can fire before that thread has forwarded the process's
final output. Because the event loop breaks out and stops reading right
after this block, any bytes that arrive later are lost for the life of the
session. The retry loop keeps draining while reads keep finding new data and
backs off after a bounded number of idle attempts (~100 ms), so the last
chunk of output is not dropped on a loaded CI runner. `pty_read` now returns
whether it read any bytes (`io::Result<bool>`) instead of `io::Result<()>`
so the retry loop can tell idle reads from EOF.

Programa adds `EventListener::pty_output`, a default no-op method that
`EventLoop::pty_read` calls with each chunk of PTY output just before the
parser sees it. vte drops OSC numbers it does not know, so the OSC 7501
Program Status scanner in `programa-terminal` reads the raw bytes through this
hook instead of through the `Handler`.

Programa records shell prompts for copy mode's `{` and `}`. `Row` has a `prompt`
flag that `Row::reset` clears, so a mark moves with its row through scrolling and
scrollback and goes when the row is cleared or its scrollback line is dropped or
recycled. `pty_output` takes a `prompts` vector: the listener pushes the offset just
past each OSC 133;A in the chunk, and `pty_read` parses up to each offset, then calls
`Term::mark_prompt`, which flags the cursor's row on the primary screen (the
alternate screen gets none). A chunk without marks is parsed in one call as before.
When a reflow pulls a row's leading cells up into the previous wrapped row, the flag
moves up with them (`grid/resize.rs`). The flag makes `Row` five machine words
instead of four, so `Storage::swap` uses `slice::swap` instead of upstream's
four-word copy. The focused test `marks_the_cursor_row_at_each_prompt_mark` in
`src/event_loop.rs` feeds bytes whose BELs a test listener reports as marks and
checks which rows get flagged.
