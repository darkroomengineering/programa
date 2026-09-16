//! Session: one PTY + child process + WAL, owned by the daemon for as long
//! as the session exists, independent of any client's connection lifetime.
//!
//! The resize rule ("smallest attached client wins, last size kept when
//! none attached") is the same rule the SSH remote daemon
//! (`programad-remote`'s `main_sessions.go`) already implements and tests,
//! reused here rather than reinvented: each attachment reports the cols/
//! rows it wants, the PTY is set to the elementwise minimum across all
//! currently attached clients, and dropping to zero attachments leaves the
//! PTY at whatever size it last had (never force-reset).

use std::collections::HashMap;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use nix::poll::{poll, PollFd, PollFlags, PollTimeout};
use nix::unistd::Pid;
use uuid::Uuid;

use crate::pty::{self, PtySession, SpawnParams};
use crate::wal::WalStore;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionStatus {
    Running,
    Exited {
        code: Option<i32>,
        signal: Option<i32>,
    },
    Failed {
        error: String,
    },
}

pub struct OpenParams {
    pub argv: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(String, String)>,
    pub cols: u16,
    pub rows: u16,
}

struct Inner {
    master: OwnedFd,
    child: Mutex<ChildState>,
    wal: Mutex<WalStore>,
    attachments: Mutex<HashMap<Uuid, Attachment>>,
    status: Mutex<SessionStatus>,
    last_size: Mutex<(u16, u16)>,
    // Write end of a self-pipe used to wake the blocking reader thread for
    // a clean shutdown; see `Session::close`.
    wake_w: OwnedFd,
    reader_handle: Mutex<Option<std::thread::JoinHandle<()>>>,
}

struct ChildState {
    child: std::process::Child,
    exit: Option<(Option<i32>, Option<i32>)>,
}

struct Attachment {
    cols: u16,
    rows: u16,
    stop_w: OwnedFd,
    input_handle: Option<std::thread::JoinHandle<()>>,
}

pub struct Session {
    pub id: String,
    pub argv: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub created_at: SystemTime,
    inner: Arc<Inner>,
}

impl Session {
    pub fn open(id: String, params: OpenParams) -> io::Result<Session> {
        let PtySession { master, mut child } = pty::spawn(SpawnParams {
            argv: &params.argv,
            cwd: params.cwd.as_deref(),
            env: &params.env,
            cols: params.cols,
            rows: params.rows,
        })?;
        let setup = (|| {
            let wal_path = crate::paths::wal_path(&id)?;
            let wal = WalStore::open(wal_path)?;
            let (wake_r, wake_w) = cloexec_pipe()?;
            Ok::<_, io::Error>((wal, wake_r, wake_w))
        })();
        let (wal, wake_r, wake_w) = match setup {
            Ok(values) => values,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        };

        let inner = Arc::new(Inner {
            master,
            child: Mutex::new(ChildState { child, exit: None }),
            wal: Mutex::new(wal),
            attachments: Mutex::new(HashMap::new()),
            status: Mutex::new(SessionStatus::Running),
            last_size: Mutex::new((params.cols, params.rows)),
            wake_w,
            reader_handle: Mutex::new(None),
        });

        let reader_inner = inner.clone();
        let handle = match std::thread::Builder::new()
            .name(format!("programad-pty-{id}"))
            .spawn(move || reader_loop(reader_inner, wake_r))
        {
            Ok(handle) => handle,
            Err(error) => {
                let mut child = inner.child.lock().unwrap();
                let _ = child.child.kill();
                let _ = child.child.wait();
                return Err(io::Error::from(error));
            }
        };
        *inner.reader_handle.lock().unwrap() = Some(handle);

        Ok(Session {
            id,
            argv: params.argv,
            cwd: params.cwd,
            created_at: SystemTime::now(),
            inner,
        })
    }

    pub fn status(&self) -> SessionStatus {
        self.inner.status.lock().unwrap().clone()
    }

    pub fn wal_tail_offset(&self) -> u64 {
        self.inner.wal.lock().unwrap().tail_offset()
    }

    pub fn wal_base_offset(&self) -> u64 {
        self.inner.wal.lock().unwrap().base_offset()
    }

    pub fn read_wal(&self, offset: u64, max_len: usize) -> io::Result<(u64, Vec<u8>)> {
        self.inner.wal.lock().unwrap().read_from(offset, max_len)
    }

    pub fn write(&self, data: &[u8]) -> io::Result<usize> {
        use std::os::fd::BorrowedFd;
        // SAFETY: the session owns the master for this entire call.
        let master = unsafe { BorrowedFd::borrow_raw(self.inner.master.as_raw_fd()) };
        match nix::unistd::write(master, data) {
            Ok(written) => Ok(written),
            Err(nix::errno::Errno::EAGAIN) => Ok(0),
            Err(error) => Err(io::Error::from(error)),
        }
    }

    /// Attach an input channel. The fd returned to the client is the
    /// write-only end of a pipe; the daemon remains the only PTY master
    /// reader and forwards input from this pipe to the master.
    pub fn attach(&self, attach_id: Uuid, cols: u16, rows: u16) -> io::Result<(u64, OwnedFd)> {
        let (input_r, input_w) = cloexec_pipe()?;
        let (stop_r, stop_w) = cloexec_pipe()?;
        let inner = self.inner.clone();
        let input_handle = std::thread::Builder::new()
            .name(format!("programad-input-{}-{attach_id}", self.id))
            .spawn(move || attachment_input_loop(inner, input_r, stop_r))
            .map_err(io::Error::from)?;

        self.inner.attachments.lock().unwrap().insert(
            attach_id,
            Attachment {
                cols,
                rows,
                stop_w,
                input_handle: Some(input_handle),
            },
        );
        if let Err(error) = self.recompute_size() {
            self.detach(attach_id);
            return Err(error);
        }
        Ok((self.wal_base_offset(), input_w))
    }

    pub fn detach(&self, attach_id: Uuid) -> bool {
        let attachment = self.inner.attachments.lock().unwrap().remove(&attach_id);
        let Some(mut attachment) = attachment else {
            return false;
        };
        let _ = nix::unistd::write(&attachment.stop_w, &[0]);
        if let Some(handle) = attachment.input_handle.take() {
            let _ = handle.join();
        }
        let _ = self.recompute_size();
        true
    }

    pub fn resize(&self, attach_id: Uuid, cols: u16, rows: u16) -> io::Result<bool> {
        let previous = {
            let mut attachments = self.inner.attachments.lock().unwrap();
            let Some(attachment) = attachments.get_mut(&attach_id) else {
                return Ok(false);
            };
            let previous = (attachment.cols, attachment.rows);
            attachment.cols = cols;
            attachment.rows = rows;
            previous
        };
        if let Err(error) = self.recompute_size() {
            if let Some(attachment) = self.inner.attachments.lock().unwrap().get_mut(&attach_id) {
                attachment.cols = previous.0;
                attachment.rows = previous.1;
            }
            return Err(error);
        }
        Ok(true)
    }

    fn recompute_size(&self) -> io::Result<()> {
        let attachments = self.inner.attachments.lock().unwrap();
        if attachments.is_empty() {
            // "last size kept when none attached" — do nothing.
            return Ok(());
        }
        let cols = attachments
            .values()
            .map(|attachment| attachment.cols)
            .min()
            .unwrap();
        let rows = attachments
            .values()
            .map(|attachment| attachment.rows)
            .min()
            .unwrap();
        // Keep the attachment snapshot stable until both the PTY and cached
        // size are updated; concurrent clients must not apply an older size last.
        pty::resize(&self.inner.master, cols, rows)?;
        *self.inner.last_size.lock().unwrap() = (cols, rows);
        Ok(())
    }

    pub fn current_size(&self) -> (u16, u16) {
        *self.inner.last_size.lock().unwrap()
    }

    pub fn attachment_count(&self) -> usize {
        self.inner.attachments.lock().unwrap().len()
    }

    /// Ask the child to exit and stop this session's reader thread. Unlike
    /// a client merely disconnecting (which does nothing to the child —
    /// that's the whole point of detached sessions), this is the one path
    /// that actually terminates the process.
    pub fn close(&self, kill: bool) -> io::Result<()> {
        let mut exit = try_reap(&self.inner)?;
        if !kill && exit.is_none() {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "cannot close a running session without terminating its child",
            ));
        }
        if kill && exit.is_none() {
            exit = signal_child(&self.inner, nix::sys::signal::Signal::SIGHUP)?;
            for _ in 0..20 {
                if exit.is_some() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
                exit = try_reap(&self.inner)?;
            }
            if exit.is_none() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "child did not exit within 500ms of SIGHUP",
                ));
            }
        }
        if let Some((code, signal)) = exit {
            *self.inner.status.lock().unwrap() = SessionStatus::Exited { code, signal };
        }
        let attachment_ids: Vec<Uuid> = self
            .inner
            .attachments
            .lock()
            .unwrap()
            .keys()
            .copied()
            .collect();
        for attach_id in attachment_ids {
            self.detach(attach_id);
        }
        // Wake the reader thread out of poll() so it notices shutdown even
        // if the child never produces more output.
        let _ = nix::unistd::write(&self.inner.wake_w, &[0u8]);
        if let Some(handle) = self.inner.reader_handle.lock().unwrap().take() {
            let _ = handle.join();
        }
        self.inner.wal.lock().unwrap().flush()?;
        Ok(())
    }

    pub fn pid(&self) -> i32 {
        self.inner.child.lock().unwrap().child.id() as i32
    }
}

fn attachment_input_loop(inner: Arc<Inner>, input_r: OwnedFd, stop_r: OwnedFd) {
    let input_raw = input_r.as_raw_fd();
    let stop_raw = stop_r.as_raw_fd();
    let mut buf = [0u8; 16 * 1024];

    loop {
        use std::os::fd::BorrowedFd;
        // SAFETY: both descriptors are owned by this function and remain
        // open for the duration of this poll call.
        let input = unsafe { BorrowedFd::borrow_raw(input_raw) };
        let stop = unsafe { BorrowedFd::borrow_raw(stop_raw) };
        let mut fds = [
            PollFd::new(input, PollFlags::POLLIN),
            PollFd::new(stop, PollFlags::POLLIN),
        ];
        match poll(&mut fds, PollTimeout::NONE) {
            Ok(_) => {}
            Err(nix::errno::Errno::EINTR) => continue,
            Err(_) => return,
        }
        if fds[1]
            .revents()
            .map(|events| events.intersects(PollFlags::POLLIN | PollFlags::POLLHUP))
            .unwrap_or(false)
        {
            return;
        }
        if !fds[0]
            .revents()
            .map(|events| events.intersects(PollFlags::POLLIN | PollFlags::POLLHUP))
            .unwrap_or(false)
        {
            continue;
        }
        match nix::unistd::read(input_raw, &mut buf) {
            Ok(0) => return,
            Ok(read) => {
                if write_all_to_master(inner.master.as_raw_fd(), &buf[..read], stop_raw).is_err() {
                    return;
                }
            }
            Err(nix::errno::Errno::EINTR) => continue,
            Err(_) => return,
        }
    }
}

fn cloexec_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let _guard = crate::pty::SPAWN_FD_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let (read, write) = nix::unistd::pipe().map_err(io::Error::from)?;
    crate::pty::set_cloexec(&read)?;
    crate::pty::set_cloexec(&write)?;
    Ok((read, write))
}

fn write_all_to_master(master_raw: RawFd, data: &[u8], stop_raw: RawFd) -> io::Result<usize> {
    use std::os::fd::BorrowedFd;
    let mut written = 0;
    while written < data.len() {
        // SAFETY: callers keep the PTY master alive for this entire call.
        let master = unsafe { BorrowedFd::borrow_raw(master_raw) };
        match nix::unistd::write(master, &data[written..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "PTY write returned zero",
                ));
            }
            Ok(count) => written += count,
            Err(nix::errno::Errno::EINTR) => continue,
            Err(nix::errno::Errno::EAGAIN) => {
                // SAFETY: callers keep the PTY master alive for this entire
                // call, including while it is polled for write readiness.
                let master = unsafe { BorrowedFd::borrow_raw(master_raw) };
                let mut poll_fds = vec![PollFd::new(master, PollFlags::POLLOUT)];
                // SAFETY: the attachment thread owns stop_r until this
                // function returns.
                let stop = unsafe { BorrowedFd::borrow_raw(stop_raw) };
                poll_fds.push(PollFd::new(stop, PollFlags::POLLIN));
                poll(&mut poll_fds, PollTimeout::NONE).map_err(io::Error::from)?;
                if poll_fds
                    .get(1)
                    .and_then(|fd| fd.revents())
                    .map(|events| events.intersects(PollFlags::POLLIN | PollFlags::POLLHUP))
                    .unwrap_or(false)
                {
                    return Err(io::Error::new(
                        io::ErrorKind::Interrupted,
                        "attachment detached",
                    ));
                }
            }
            Err(error) => return Err(io::Error::from(error)),
        }
    }
    Ok(written)
}

/// The one and only reader of this session's PTY master, for its entire
/// life. Drains continuously into the WAL so the child never blocks on a
/// full PTY output buffer, regardless of whether any client is attached —
/// this is what makes "the session survives client death" true by
/// construction rather than by a special case.
fn reader_loop(inner: Arc<Inner>, wake_r: OwnedFd) {
    let master_raw: RawFd = inner.master.as_raw_fd();
    let wake_raw: RawFd = wake_r.as_raw_fd();
    let mut buf = [0u8; 32 * 1024];

    loop {
        use std::os::fd::BorrowedFd;
        // SAFETY: both fds are owned by this function's caller (`inner`,
        // `wake_r`) and stay alive for the loop's duration.
        let master_bfd: BorrowedFd = unsafe { BorrowedFd::borrow_raw(master_raw) };
        let wake_bfd: BorrowedFd = unsafe { BorrowedFd::borrow_raw(wake_raw) };
        let mut fds = [
            PollFd::new(master_bfd, PollFlags::POLLIN),
            PollFd::new(wake_bfd, PollFlags::POLLIN),
        ];
        let timeout = inner
            .wal
            .lock()
            .unwrap()
            .flush_due_in()
            .unwrap_or(Duration::from_millis(200))
            .min(Duration::from_millis(200));
        let poll_timeout = PollTimeout::try_from(timeout).unwrap_or(PollTimeout::MAX);
        let poll_result = poll(&mut fds, poll_timeout);
        match poll_result {
            Ok(_) => {}
            Err(nix::errno::Errno::EINTR) => continue,
            Err(_) => break,
        }

        let flush_result = inner.wal.lock().unwrap().flush_if_due();
        if let Err(error) = flush_result {
            fail_session(&inner, format!("WAL flush failed: {error}"));
            return;
        }

        if matches!(*inner.status.lock().unwrap(), SessionStatus::Running) {
            match try_reap(&inner) {
                Ok(Some((code, signal))) => {
                    *inner.status.lock().unwrap() = SessionStatus::Exited { code, signal };
                }
                Ok(None) => {}
                Err(error) => {
                    fail_session(&inner, format!("child status failed: {error}"));
                    return;
                }
            }
        }

        if fds[1]
            .revents()
            .map(|r| r.contains(PollFlags::POLLIN))
            .unwrap_or(false)
        {
            break; // asked to shut down
        }

        let master_ready = fds[0]
            .revents()
            .map(|r| {
                r.contains(PollFlags::POLLIN)
                    || r.contains(PollFlags::POLLHUP)
                    || r.contains(PollFlags::POLLERR)
            })
            .unwrap_or(false);
        if !master_ready {
            continue;
        }

        loop {
            match nix::unistd::read(master_raw, &mut buf) {
                Ok(0) => {
                    finish_on_exit(&inner, wake_raw);
                    return;
                }
                Ok(n) => {
                    if let Err(error) = inner.wal.lock().unwrap().append(&buf[..n]) {
                        fail_session(&inner, format!("WAL append failed: {error}"));
                        return;
                    }
                    if n < buf.len() {
                        break; // drained what's currently available
                    }
                }
                Err(nix::errno::Errno::EAGAIN) => break,
                Err(nix::errno::Errno::EINTR) => continue,
                Err(_) => {
                    // EIO on macOS/Linux: no more openers of the slave.
                    finish_on_exit(&inner, wake_raw);
                    return;
                }
            }
        }
    }
}

fn finish_on_exit(inner: &Arc<Inner>, wake_raw: RawFd) {
    if let Err(error) = inner.wal.lock().unwrap().flush() {
        fail_session(inner, format!("WAL flush failed: {error}"));
        return;
    }

    // A child can close or redirect all three standard descriptors while it
    // keeps running. The PTY then reports EOF/EIO before waitpid can reap it.
    // Stop polling the closed PTY, but keep this reader alive to reap the
    // child or to honor an explicit Session::close wakeup.
    loop {
        match try_reap(inner) {
            Ok(Some((code, signal))) => {
                *inner.status.lock().unwrap() = SessionStatus::Exited { code, signal };
                return;
            }
            Ok(None) => {}
            Err(error) => {
                fail_session(inner, format!("child status failed: {error}"));
                return;
            }
        }

        use std::os::fd::BorrowedFd;
        // SAFETY: the reader thread owns wake_r, whose descriptor remains
        // open until this function returns.
        let wake = unsafe { BorrowedFd::borrow_raw(wake_raw) };
        let mut fds = [PollFd::new(wake, PollFlags::POLLIN)];
        match poll(&mut fds, PollTimeout::from(200u16)) {
            Ok(_) => {}
            Err(nix::errno::Errno::EINTR) => continue,
            Err(error) => {
                fail_session(inner, format!("child monitor poll failed: {error}"));
                return;
            }
        }
        if fds[0]
            .revents()
            .map(|events| events.intersects(PollFlags::POLLIN | PollFlags::POLLHUP))
            .unwrap_or(false)
        {
            return;
        }
    }
}

fn fail_session(inner: &Arc<Inner>, error: String) {
    *inner.status.lock().unwrap() = SessionStatus::Failed { error };
    let _ = signal_child(inner, nix::sys::signal::Signal::SIGHUP);
}

fn try_reap(inner: &Inner) -> io::Result<Option<(Option<i32>, Option<i32>)>> {
    let mut child = inner.child.lock().unwrap();
    if child.exit.is_some() {
        return Ok(child.exit);
    }
    let status = child.child.try_wait()?;
    if let Some(status) = status {
        let exit = exit_status_parts(status);
        child.exit = Some(exit);
        Ok(Some(exit))
    } else {
        Ok(None)
    }
}

fn signal_child(
    inner: &Inner,
    signal: nix::sys::signal::Signal,
) -> io::Result<Option<(Option<i32>, Option<i32>)>> {
    let mut child = inner.child.lock().unwrap();
    if let Some(exit) = child.exit {
        return Ok(Some(exit));
    }
    if let Some(status) = child.child.try_wait()? {
        let exit = exit_status_parts(status);
        child.exit = Some(exit);
        return Ok(Some(exit));
    }

    // The child lock stays held across the liveness check and signal. No
    // reader can reap it in between, so its PID cannot be recycled here.
    let pid = Pid::from_raw(child.child.id() as i32);
    match nix::sys::signal::kill(pid, signal) {
        Ok(()) => Ok(None),
        Err(nix::errno::Errno::ESRCH) => {
            if let Some(status) = child.child.try_wait()? {
                let exit = exit_status_parts(status);
                child.exit = Some(exit);
                Ok(Some(exit))
            } else {
                Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "child disappeared before it could be signaled",
                ))
            }
        }
        Err(error) => Err(io::Error::from(error)),
    }
}

fn exit_status_parts(status: std::process::ExitStatus) -> (Option<i32>, Option<i32>) {
    use std::os::unix::process::ExitStatusExt;
    (status.code(), status.signal())
}

pub fn now_unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

pub struct SessionManager {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionManager {
    pub fn new() -> Self {
        SessionManager {
            sessions: Mutex::new(HashMap::new()),
        }
    }

    pub fn open(&self, params: OpenParams) -> io::Result<Arc<Session>> {
        let id = Uuid::new_v4().to_string();
        let session = Arc::new(Session::open(id.clone(), params)?);
        self.sessions.lock().unwrap().insert(id, session.clone());
        Ok(session)
    }

    pub fn get(&self, id: &str) -> Option<Arc<Session>> {
        self.sessions.lock().unwrap().get(id).cloned()
    }

    pub fn list(&self) -> Vec<Arc<Session>> {
        self.sessions.lock().unwrap().values().cloned().collect()
    }

    /// Remove and close a session. `kill` additionally signals the child;
    /// without it, `close` just stops tracking it here (used for sessions
    /// that already exited on their own).
    pub fn close(&self, id: &str, kill: bool) -> io::Result<bool> {
        let session = self.sessions.lock().unwrap().get(id).cloned();
        match session {
            Some(session) => {
                session.close(kill)?;
                self.sessions.lock().unwrap().remove(id);
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// All sessions currently tracked, for reporting at shutdown.
    pub fn ids(&self) -> Vec<String> {
        self.sessions.lock().unwrap().keys().cloned().collect()
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn cloexec_pipe_is_not_inherited_by_later_child() {
        let (read, write) = cloexec_pipe().unwrap();
        let inherited_fd = read.as_raw_fd();
        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            format!("test ! -e /proc/self/fd/{inherited_fd}"),
        ];
        let mut spawned = pty::spawn(SpawnParams {
            argv: &argv,
            cwd: None,
            env: &[],
            cols: 80,
            rows: 24,
        })
        .unwrap();
        let status = spawned.child.wait().unwrap();
        assert!(status.success(), "later child inherited fd {inherited_fd}");
        drop((read, write, spawned.master));
    }

    #[test]
    fn reader_reaps_child_that_closes_pty_before_exit() {
        let temp = tempfile::tempdir().unwrap();
        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "exec </dev/null >/dev/null 2>&1; sleep 0.1; exit 7".to_string(),
        ];
        let PtySession { master, child } = pty::spawn(SpawnParams {
            argv: &argv,
            cwd: None,
            env: &[],
            cols: 80,
            rows: 24,
        })
        .unwrap();
        let (wake_r, wake_w) = cloexec_pipe().unwrap();
        let inner = Arc::new(Inner {
            master,
            child: Mutex::new(ChildState { child, exit: None }),
            wal: Mutex::new(WalStore::open(temp.path().join("wal")).unwrap()),
            attachments: Mutex::new(HashMap::new()),
            status: Mutex::new(SessionStatus::Running),
            last_size: Mutex::new((80, 24)),
            wake_w,
            reader_handle: Mutex::new(None),
        });

        let reader_inner = inner.clone();
        let reader = std::thread::spawn(move || reader_loop(reader_inner, wake_r));
        for _ in 0..100 {
            if matches!(*inner.status.lock().unwrap(), SessionStatus::Exited { .. }) {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }

        assert_eq!(
            *inner.status.lock().unwrap(),
            SessionStatus::Exited {
                code: Some(7),
                signal: None,
            }
        );
        assert_eq!(inner.child.lock().unwrap().exit, Some((Some(7), None)));
        reader.join().unwrap();
    }
}
