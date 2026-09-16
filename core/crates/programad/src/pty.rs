//! PTY allocation and child process spawn.
//!
//! Uses `nix::pty::openpty` for the pty pair, then `std::process::Command`
//! with a `pre_exec` hook to do the session leadership dance by hand
//! (`setsid` + `TIOCSCTTY` + wiring the slave onto fd 0/1/2) rather than
//! `nix::unistd::fork` directly. `std::process::Command` already forks and
//! execs safely on our behalf; doing our own `fork()` in a multi-threaded
//! tokio process would be unsound (only async-signal-safe calls are legal
//! between `fork` and `exec` in a multi-threaded program, and Rust's own
//! allocator/mutex internals are not on that safe list). `pre_exec` runs
//! its closure in the freshly forked child, single-threaded, right before
//! `exec`, which is the supported way to do exactly this dance.

use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};

use nix::pty::{openpty, OpenptyResult};
use nix::sys::termios;

/// Serializes descriptor creation that cannot request CLOEXEC atomically on
/// every supported Unix platform with every `Command::spawn` fork window.
/// This is intentionally process-wide and held only around short setup calls.
pub(crate) static SPAWN_FD_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

pub struct PtySession {
    pub master: OwnedFd,
    pub child: Child,
}

pub struct SpawnParams<'a> {
    pub argv: &'a [String],
    pub cwd: Option<&'a Path>,
    pub env: &'a [(String, String)],
    pub cols: u16,
    pub rows: u16,
}

/// The user's login shell, honoring `$SHELL`, falling back to `/bin/sh`.
pub fn login_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
}

pub fn spawn(params: SpawnParams) -> io::Result<PtySession> {
    // macOS openpty(3) has no CLOEXEC flag. Holding the shared lock from
    // allocation through Command::spawn prevents another session's fork from
    // observing these descriptors before FD_CLOEXEC is set, and prevents this
    // fork from racing attachment/wakeup pipe creation.
    let spawn_guard = SPAWN_FD_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let OpenptyResult { master, slave } =
        openpty(None, None).map_err(|e| io::Error::from_raw_os_error(e as i32))?;
    set_cloexec(&master)?;
    set_cloexec(&slave)?;

    set_winsize(&slave, params.cols, params.rows)?;

    let (program, args): (&str, &[String]) = match params.argv.split_first() {
        Some((first, rest)) => (first.as_str(), rest),
        None => return Err(io::Error::new(io::ErrorKind::InvalidInput, "empty argv")),
    };

    let mut cmd = Command::new(program);
    cmd.args(args);
    if let Some(dir) = params.cwd {
        cmd.current_dir(dir);
    }
    cmd.env_clear();
    for (k, v) in params.env {
        cmd.env(k, v);
    }
    // We do our own fd wiring onto 0/1/2 inside pre_exec below; tell
    // Command not to also try to redirect these (Stdio::null() here is
    // overwritten by the dup2 calls in pre_exec before exec runs).
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::null());
    cmd.stderr(Stdio::null());

    let slave_raw: RawFd = slave.as_raw_fd();
    let master_raw: RawFd = master.as_raw_fd();

    // SAFETY: this closure runs in the child after fork(), before exec(),
    // single-threaded. Every call inside is async-signal-safe: setsid(2),
    // ioctl(2), dup2(2), close(2). We never allocate, lock, or touch Rust
    // runtime state that could have been left inconsistent by fork().
    unsafe {
        cmd.pre_exec(move || {
            // New session, new process group; slave becomes eligible to be
            // this session's controlling terminal via TIOCSCTTY next.
            nix::unistd::setsid().map_err(io::Error::from)?;

            // SAFETY: slave_raw is a valid, open fd for the lifetime of
            // this pre_exec call (the parent keeps `slave: OwnedFd` alive
            // until after spawn() returns, which is after this runs).
            let rc = libc::ioctl(slave_raw, libc::TIOCSCTTY as _, 0);
            if rc != 0 {
                return Err(io::Error::last_os_error());
            }

            for fd in [0, 1, 2] {
                if libc::dup2(slave_raw, fd) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            if slave_raw > 2 {
                libc::close(slave_raw);
            }
            // The master end belongs to the daemon; the child must not
            // inherit it (it would otherwise keep the master's read side
            // artificially alive and could let the child interfere with
            // the daemon's own PTY drain).
            if master_raw >= 0 {
                libc::close(master_raw);
            }
            Ok(())
        });
    }

    let mut child = cmd.spawn()?;
    drop(spawn_guard);
    // Parent no longer needs the slave; the child (and its own dup'd
    // copies on 0/1/2) keeps the pty pair alive.
    drop(slave);

    if let Err(error) = set_nonblocking(&master) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error);
    }

    Ok(PtySession { master, child })
}

pub(crate) fn set_cloexec(fd: &OwnedFd) -> io::Result<()> {
    use nix::fcntl::{fcntl, FcntlArg, FdFlag};
    fcntl(fd.as_raw_fd(), FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))
        .map(|_| ())
        .map_err(io::Error::from)
}

pub fn resize(master: &OwnedFd, cols: u16, rows: u16) -> io::Result<()> {
    set_winsize(master, cols, rows)
}

fn set_winsize(fd: &OwnedFd, cols: u16, rows: u16) -> io::Result<()> {
    let ws = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: fd is a valid, open pty fd (master or slave); ws is a fully
    // initialized winsize the kernel only reads from.
    let rc = unsafe { libc::ioctl(fd.as_raw_fd(), libc::TIOCSWINSZ as _, &ws) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn set_nonblocking(fd: &OwnedFd) -> io::Result<()> {
    use nix::fcntl::{fcntl, FcntlArg, OFlag};
    let raw = fd.as_raw_fd();
    let flags = fcntl(raw, FcntlArg::F_GETFL).map_err(io::Error::from)?;
    let mut flags = OFlag::from_bits_truncate(flags);
    flags.insert(OFlag::O_NONBLOCK);
    fcntl(raw, FcntlArg::F_SETFL(flags)).map_err(io::Error::from)?;
    Ok(())
}

/// Put the master fd's underlying termios in a sane default state. Not
/// currently exercised by callers (the slave/child sets its own raw/cooked
/// mode as usual); kept as a documented no-op hook because several v1
/// escrow-poc notes call this out as an easy place for future echo/flow
/// control bugs to hide.
#[allow(dead_code)]
fn ensure_default_termios(fd: &OwnedFd) -> io::Result<()> {
    let attrs = termios::tcgetattr(fd).map_err(io::Error::from)?;
    termios::tcsetattr(fd, termios::SetArg::TCSANOW, &attrs).map_err(io::Error::from)?;
    Ok(())
}
