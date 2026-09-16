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
