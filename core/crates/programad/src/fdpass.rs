//! Passing an attachment's write-only input pipe to a client over
//! `SCM_RIGHTS` ancillary data on the same Unix socket connection the
//! JSON-lines protocol runs on. The PTY master itself never leaves the daemon.
//!
//! Contract (documented in full in `README.md`): after `programad` writes
//! the JSON result line for `session.attach`, it performs exactly one
//! `sendmsg(2)` on the same socket carrying a raw NUL payload plus one
//! `SCM_RIGHTS` control message. A raw NUL cannot occur in valid JSON, so the
//! marker remains identifiable when a recvmsg call also returns JSON bytes.
//!
//! **The one rule that makes this safe**: ancillary data is bound to the
//! specific `recvmsg(2)` call that happens to read the byte range it rode
//! in on, not to any particular logical "message" the caller has in mind.
//! If anything on the receiving side ever does a plain `read()` (which is
//! exactly what a buffered reader like `tokio::io::BufReader` does under
//! the hood) instead of `recvmsg()`, and that `read()` happens to slurp up
//! the marker byte along with, say, the tail of the previous JSON line,
//! the kernel silently drops the ancillary data — no error, the fd is just
//! gone. [`MsgStream`] exists so *every* read on a connection that might
//! ever see an attach response goes through `recvmsg`, with any fd that
//! shows up along the way queued for [`MsgStream::take_fd`] to collect,
//! regardless of which line it happened to arrive alongside.

use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};

use nix::sys::socket::{self, ControlMessage, MsgFlags, UnixAddr};
use tokio::io::{AsyncWriteExt, Interest};
use tokio::net::UnixStream;

/// Raw NUL cannot occur in a valid JSON frame, so it is an unambiguous
/// ancillary-data marker even when the kernel coalesces bytes from an earlier
/// `write(2)` with this `sendmsg(2)` call.
const FD_MARKER: &[u8] = b"\0";
pub const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;
const MAX_QUEUED_FDS: usize = 16;
/// The most descriptors a single `sendmsg(2)` SCM_RIGHTS call can install on
/// any platform this daemon targets; a sender that tries to exceed it gets
/// `EINVAL` and nothing is installed. Measured empirically (see
/// `recv_with_fds`'s control-buffer comment): 253 succeeds, 300 fails, on
/// both Linux (documented `SCM_MAX_FD`) and macOS.
const MAX_FDS_PER_SENDMSG: usize = 253;
/// `usize` words for `recv_with_fds`'s ancillary buffer: enough to describe
/// `MAX_FDS_PER_SENDMSG` descriptors (CMSG_SPACE(253 * size_of::<RawFd>()) is
/// 1024 bytes on both target platforms) plus generous headroom.
const CONTROL_WORDS: usize =
    (MAX_FDS_PER_SENDMSG * std::mem::size_of::<RawFd>()) / std::mem::size_of::<usize>() + 32;

#[derive(Debug)]
pub enum ReadFrameError {
    Io(io::Error),
    InvalidUtf8,
    TooLarge,
}

impl From<io::Error> for ReadFrameError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Send one fd to the peer of `stream` as `SCM_RIGHTS` ancillary data on a
/// one-byte payload. `fd` is duplicated internally, so the caller keeps
/// ownership of whatever it passes in.
pub async fn send_fd(stream: &UnixStream, fd: RawFd) -> io::Result<()> {
    loop {
        stream.writable().await?;
        let result = stream.try_io(Interest::WRITABLE, || {
            let iov = [io::IoSlice::new(FD_MARKER)];
            let fds = [fd];
            let cmsg = [ControlMessage::ScmRights(&fds)];
            socket::sendmsg::<UnixAddr>(stream.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)
                .and_then(|written| {
                    if written == FD_MARKER.len() {
                        Ok(())
                    } else {
                        Err(nix::errno::Errno::EIO)
                    }
                })
                .map_err(io::Error::from)
        });
        match result {
            Ok(()) => return Ok(()),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
            Err(e) => return Err(e),
        }
    }
}

// Small helper so the `unsafe` construction below has one clearly named
// operation instead of a bare `OwnedFd::from_raw_fd`, and so a negative fd
// (unreachable given the kernel just produced it, but cheap to guard)
// can't silently construct a bogus owner.
fn owned_fd_from_raw_checked(raw: RawFd) -> io::Result<OwnedFd> {
    if raw < 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "received a negative file descriptor",
        ));
    }
    use nix::fcntl::{fcntl, FcntlArg, FdFlag};
    if let Err(error) = fcntl(raw, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC)) {
        // SAFETY: `raw` was just produced by the kernel via `SCM_RIGHTS`, and
        // this branch transfers it directly to `close` exactly once.
        unsafe { libc::close(raw) };
        return Err(io::Error::from(error));
    }
    // SAFETY: `raw` was just produced by the kernel via `SCM_RIGHTS`; after
    // setting CLOEXEC, this value becomes its sole owner.
    Ok(unsafe { std::os::fd::FromRawFd::from_raw_fd(raw) })
}

/// `recv_with_fds`'s result, `fd_guard` included: any descriptors in `fds`
/// were installed in our fd table while `SPAWN_FD_LOCK` was held (see the
/// lock's doc comment on `recv_with_fds` below), and they stay only
/// conditionally ours -- a caller that decides to reject this batch (too
/// many queued, a truncated control message) must close every descriptor
/// in `fds` *before* dropping `fd_guard`, not after. Returning the guard
/// as part of this struct, instead of letting `recv_with_fds` drop it on
/// return, is what makes that possible: it keeps the fork-inheritance
/// window closed for the caller's own rejection handling, not just for
/// `recv_with_fds`'s internal parsing.
struct RecvWithFds {
    received: usize,
    truncated: bool,
    fds: Vec<OwnedFd>,
    fd_guard: Option<std::sync::MutexGuard<'static, ()>>,
}

fn recv_with_fds(socket_fd: RawFd, bytes: &mut [u8], accept_fds: bool) -> io::Result<RecvWithFds> {
    // macOS lacks MSG_CMSG_CLOEXEC. Serialize the recvmsg-to-fcntl window
    // with every daemon fork and other non-atomic CLOEXEC allocation. Held
    // past this function's own return (see `RecvWithFds` above) so a
    // caller that rejects this batch can close it before any fork can
    // observe the still-open descriptors.
    let fd_guard = accept_fds.then(|| {
        crate::pty::SPAWN_FD_LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    });

    let mut iov = libc::iovec {
        iov_base: bytes.as_mut_ptr().cast(),
        iov_len: bytes.len(),
    };
    // Sized (CONTROL_WORDS) so a hostile peer can never get the kernel to
    // install more descriptors in our fd table than this buffer can
    // enumerate (and therefore close). A buffer sized only for the
    // legitimate case (one fd) would still let MSG_CTRUNC fire under
    // attack, and a truncated SCM_RIGHTS message installs descriptors
    // beyond what CMSG_NXTHDR can walk, which are then unrecoverably leaked
    // because nothing in the ancillary data identifies their fd numbers.
    // usize supplies at least cmsghdr alignment on supported Unix targets.
    let mut control = [0usize; CONTROL_WORDS];
    // SAFETY: zero is the required initialization for unused msghdr fields;
    // all pointers installed below remain valid for the recvmsg call.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    if accept_fds {
        message.msg_control = control.as_mut_ptr().cast();
        message.msg_controllen = std::mem::size_of_val(&control) as _;
    }

    // SAFETY: socket_fd is the live UnixStream descriptor; message points to
    // writable byte/control buffers whose lifetimes cover this call.
    let received = unsafe { libc::recvmsg(socket_fd, &mut message, 0) };
    if received < 0 {
        return Err(io::Error::last_os_error());
    }
    if !accept_fds {
        // With no control buffer, the kernel discards and closes any incoming
        // SCM_RIGHTS descriptors. MSG_CTRUNC is expected in that case.
        return Ok(RecvWithFds {
            received: received as usize,
            truncated: false,
            fds: Vec::new(),
            fd_guard,
        });
    }

    let mut fds = Vec::new();
    let control_start = message.msg_control as usize;
    let control_end = control_start.saturating_add(message.msg_controllen as usize);
    // SAFETY: recvmsg initialized the control buffer and msg_controllen.
    let mut header = unsafe { libc::CMSG_FIRSTHDR(&message) };
    while !header.is_null() {
        let header_start = header as usize;
        let header_size = std::mem::size_of::<libc::cmsghdr>();
        if header_start < control_start || header_start.saturating_add(header_size) > control_end {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid ancillary header bounds",
            ));
        }

        // SAFETY: the complete cmsghdr was bounds-checked above.
        let header_ref = unsafe { &*header };
        // SAFETY: CMSG_LEN(0) only computes the platform header alignment.
        let minimum_len = unsafe { libc::CMSG_LEN(0) as usize };
        let declared_len = header_ref.cmsg_len as usize;
        if declared_len < minimum_len {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid ancillary message length",
            ));
        }
        let declared_end = header_start.saturating_add(declared_len);

        if header_ref.cmsg_level == libc::SOL_SOCKET && header_ref.cmsg_type == libc::SCM_RIGHTS {
            // Parse every complete descriptor that the kernel copied even if
            // MSG_CTRUNC is set, so all installed descriptors become OwnedFd
            // values and are closed on the error path below.
            // SAFETY: header is valid and CMSG_DATA computes its payload start.
            let data_start = unsafe { libc::CMSG_DATA(header) } as usize;
            let data_end = declared_end.min(control_end);
            if data_start > data_end {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "invalid SCM_RIGHTS payload bounds",
                ));
            }
            let complete_bytes = data_end - data_start;
            let count = complete_bytes / std::mem::size_of::<RawFd>();
            for index in 0..count {
                // SAFETY: each RawFd lies wholly inside the checked payload.
                let raw =
                    unsafe { std::ptr::read_unaligned((data_start as *const RawFd).add(index)) };
                fds.push(owned_fd_from_raw_checked(raw)?);
            }
        }

        if declared_end > control_end {
            break;
        }
        // SAFETY: the current header and overall msghdr passed all bounds
        // checks required by CMSG_NXTHDR.
        header = unsafe { libc::CMSG_NXTHDR(&message, header) };
    }

    let truncated = message.msg_flags & libc::MSG_CTRUNC != 0;
    Ok(RecvWithFds {
        received: received as usize,
        truncated,
        fds,
        fd_guard,
    })
}

/// A `tokio::net::UnixStream` wrapper whose every read goes through
/// `recvmsg(2)` instead of a plain `read()`/buffered reader, so an
/// `SCM_RIGHTS` fd sent alongside ordinary protocol bytes is never
/// silently dropped by over-reading past it (see the module doc). Used on
/// both ends of any connection where `session.attach` might happen: the
/// daemon's connection handler, and any Rust client (the integration
/// test's `Client`; a real client in another language does its own
/// `recvmsg`-based read loop instead, e.g. Python's `socket.recvmsg`).
pub struct MsgStream {
    stream: UnixStream,
    buf: Vec<u8>,
    fds: VecDeque<OwnedFd>,
    accept_fds: bool,
}

impl MsgStream {
    pub fn new(stream: UnixStream) -> Self {
        MsgStream {
            stream,
            buf: Vec::new(),
            fds: VecDeque::new(),
            accept_fds: true,
        }
    }

    /// Construct a protocol stream for a server connection. Incoming
    /// SCM_RIGHTS are discarded by the kernel because clients never send FDs.
    pub fn new_without_fd_receive(stream: UnixStream) -> Self {
        MsgStream {
            stream,
            buf: Vec::new(),
            fds: VecDeque::new(),
            accept_fds: false,
        }
    }

    pub fn get_ref(&self) -> &UnixStream {
        &self.stream
    }

    /// Read and consume one line (without its trailing `\n`/`\r\n`).
    /// Returns `Ok(None)` on a clean EOF with no partial line pending.
    pub async fn read_line(&mut self) -> Result<Option<String>, ReadFrameError> {
        loop {
            if let Some(pos) = self.buf.iter().position(|&b| b == b'\n') {
                if pos > MAX_FRAME_BYTES {
                    return Err(ReadFrameError::TooLarge);
                }
                let mut line: Vec<u8> = self.buf.drain(..=pos).collect();
                line.pop(); // trailing \n
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                return String::from_utf8(line)
                    .map(Some)
                    .map_err(|_| ReadFrameError::InvalidUtf8);
            }
            let n = self.fill_more().await?;
            if self.buf.len() > MAX_FRAME_BYTES {
                return Err(ReadFrameError::TooLarge);
            }
            if n == 0 {
                if self.buf.is_empty() {
                    return Ok(None);
                }
                let rest = std::mem::take(&mut self.buf);
                return String::from_utf8(rest)
                    .map(Some)
                    .map_err(|_| ReadFrameError::InvalidUtf8);
            }
        }
    }

    pub async fn write_all(&mut self, data: &[u8]) -> io::Result<()> {
        self.stream.write_all(data).await
    }

    /// Send one fd as `SCM_RIGHTS`, as documented at the top of this file.
    pub async fn send_fd(&self, fd: RawFd) -> io::Result<()> {
        send_fd(&self.stream, fd).await
    }

    /// Pop one fd received via `SCM_RIGHTS`, reading more from the socket
    /// if none is queued yet. Blocks (asynchronously) until one arrives or
    /// the connection closes.
    pub async fn take_fd(&mut self) -> io::Result<OwnedFd> {
        loop {
            if let Some(fd) = self.fds.pop_front() {
                return Ok(fd);
            }
            let n = self.fill_more().await?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed before an fd arrived",
                ));
            }
        }
    }

    /// One `recvmsg` call's worth of bytes appended to `self.buf`, with
    /// any fds it carried queued in `self.fds`. Returns the byte count (0
    /// = EOF).
    async fn fill_more(&mut self) -> io::Result<usize> {
        loop {
            self.stream.readable().await?;
            let stream = &self.stream;
            let mut chunk = [0u8; 4096];
            let result = stream.try_io(Interest::READABLE, || {
                recv_with_fds(stream.as_raw_fd(), &mut chunk, self.accept_fds)
            });
            match result {
                Ok(RecvWithFds {
                    received: n,
                    truncated,
                    fds: received_fds,
                    fd_guard,
                }) => {
                    if truncated {
                        // Close every installed descriptor while fd_guard is
                        // still held, so a concurrent fork can't inherit one
                        // between recv_with_fds's own return and ours (the
                        // bug this struct exists to close -- see its doc
                        // comment).
                        drop(received_fds);
                        drop(fd_guard);
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "truncated SCM_RIGHTS control message",
                        ));
                    }
                    if self.fds.len() + received_fds.len() > MAX_QUEUED_FDS {
                        drop(received_fds);
                        drop(fd_guard);
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "too many queued file descriptors",
                        ));
                    }
                    let mut markers_to_remove = received_fds.len();
                    for byte in &chunk[..n] {
                        if *byte == FD_MARKER[0] && markers_to_remove > 0 {
                            markers_to_remove -= 1;
                        } else {
                            self.buf.push(*byte);
                        }
                    }
                    if markers_to_remove != 0 {
                        // Same reasoning as the two rejections above: this
                        // batch is being closed (received_fds's Drop runs
                        // here, at the return), not kept, so fd_guard must
                        // still be held when it happens.
                        drop(received_fds);
                        drop(fd_guard);
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "SCM_RIGHTS message did not include its marker byte",
                        ));
                    }
                    // Every remaining path keeps received_fds (queued into
                    // self.fds next), so there's nothing left for fd_guard
                    // to protect.
                    drop(fd_guard);
                    self.fds.extend(received_fds);
                    return Ok(n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
                Err(e) => return Err(e),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;

    #[tokio::test]
    async fn coalesced_json_and_fd_marker_preserve_json() {
        let (sender, receiver) = UnixStream::pair().unwrap();
        let file = std::fs::File::open("/dev/null").unwrap();
        let payload = b"{\"id\":1,\"ok\":true}\n\0";
        let iov = [io::IoSlice::new(payload)];
        let fds = [file.as_raw_fd()];
        let cmsg = [ControlMessage::ScmRights(&fds)];
        socket::sendmsg::<UnixAddr>(sender.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)
            .unwrap();

        let mut stream = MsgStream::new(receiver);
        assert_eq!(
            stream.read_line().await.unwrap().unwrap(),
            r#"{"id":1,"ok":true}"#
        );
        let received = stream.take_fd().await.unwrap();
        assert!(received.as_raw_fd() >= 0);
        let flags = nix::fcntl::fcntl(received.as_raw_fd(), nix::fcntl::FcntlArg::F_GETFD).unwrap();
        assert!(
            nix::fcntl::FdFlag::from_bits_truncate(flags).contains(nix::fcntl::FdFlag::FD_CLOEXEC)
        );
    }

    #[tokio::test]
    async fn fragmented_json_is_reassembled() {
        let (mut sender, receiver) = UnixStream::pair().unwrap();
        sender.write_all(b"{\"id\":").await.unwrap();
        sender.write_all(b"1}\n").await.unwrap();
        let mut stream = MsgStream::new(receiver);
        assert_eq!(stream.read_line().await.unwrap().unwrap(), r#"{"id":1}"#);
    }

    // Isolated from the default `cargo test` run and re-run alone (see the
    // shared-core CI step: `cargo test -p programad --locked --lib --
    // --ignored --test-threads=1`). `RecvWithFds` (above `recv_with_fds`)
    // fixed the production bug this test's EPIPE check used to be exposed
    // to: `MsgStream::fill_more` now closes a rejected batch while
    // `recv_with_fds`'s `SPAWN_FD_LOCK` guard is still held, instead of
    // after it, so a concurrent fork can no longer inherit a not-yet-closed
    // duplicate from *this* rejection path. Kept isolated anyway as
    // defense in depth: the EPIPE assertion below is still, structurally,
    // sensitive to *any* process anywhere holding the pipe's read end, not
    // just this one -- see `too_many_descriptors_are_closed_before_the_reject_returns`
    // below for a regression test that instead counts this process's own
    // fd table, which is robust against other processes by construction
    // and is the one that would have caught the fixed bug directly.
    #[tokio::test]
    #[ignore = "must run alone: see the shared-core CI step for why"]
    async fn max_sendmsg_descriptors_close_without_leak() {
        let (sender, receiver) = UnixStream::pair().unwrap();
        // Keep the fixture's pipe fds out of a concurrent session test's
        // fork window from creation through our own `drop(read)` below.
        // `fork(2)` copies the fd table regardless of CLOEXEC (CLOEXEC only
        // takes effect at `exec`), so a session test that forks in that
        // window could transiently inherit `read`, keeping a duplicate of
        // it alive past our own `drop(read)` and making the EPIPE check
        // below see a live reader that isn't us -- write() then returns Ok
        // instead of EPIPE, which is exactly the false failure this guard
        // exists to prevent.
        //
        // The guard must NOT still be held once we call `read_line()`
        // below: `recv_with_fds` (the receive half, invoked from there)
        // takes this same `SPAWN_FD_LOCK` itself for its own CLOEXEC race
        // window, and `std::sync::Mutex` isn't reentrant -- holding it
        // across that call would deadlock this test against itself.
        let spawn_guard = crate::pty::SPAWN_FD_LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (read, write) = nix::unistd::pipe().unwrap();
        crate::pty::set_cloexec(&read).unwrap();
        crate::pty::set_cloexec(&write).unwrap();

        // MAX_FDS_PER_SENDMSG is the most descriptors a single sendmsg(2)
        // call can ever install (the kernel rejects more with EINVAL at the
        // sender), and recv_with_fds's control buffer is sized to enumerate
        // that many, so this can never trigger MSG_CTRUNC. It exceeds
        // MAX_QUEUED_FDS instead, which is the protocol-level rejection this
        // exercises: every descriptor the kernel installs for this call must
        // still be enumerable and closed, none left invisible beyond the
        // ancillary buffer. Repeating one descriptor keeps the fixture
        // small; any leaked duplicate still prevents EPIPE below.
        let raw_fds = vec![read.as_raw_fd(); MAX_FDS_PER_SENDMSG];
        let payload = [FD_MARKER[0]];
        let iov = [io::IoSlice::new(&payload)];
        let cmsg = [ControlMessage::ScmRights(&raw_fds)];
        socket::sendmsg::<UnixAddr>(sender.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)
            .unwrap();
        drop(read);
        drop(spawn_guard);

        let mut stream = MsgStream::new(receiver);
        assert!(matches!(
            stream.read_line().await,
            Err(ReadFrameError::Io(error)) if error.kind() == io::ErrorKind::InvalidData
        ));
        drop(stream);

        assert_eq!(
            nix::unistd::write(&write, b"x").unwrap_err(),
            nix::errno::Errno::EPIPE,
            "a received SCM_RIGHTS descriptor leaked after the too-many-fds rejection"
        );
    }

    /// This process's own open descriptor count, via `/proc/self/fd` on
    /// Linux and `/dev/fd` on macOS (both list one entry per open fd,
    /// including the directory handle this call itself briefly opens --
    /// consistent overhead on both sides of a before/after comparison, so
    /// it cancels out).
    fn open_fd_count() -> usize {
        let dir = if cfg!(target_os = "linux") {
            "/proc/self/fd"
        } else {
            "/dev/fd"
        };
        std::fs::read_dir(dir)
            .map(|entries| entries.filter_map(Result::ok).count())
            .unwrap_or(0)
    }

    /// Regression test for the production bug fixed alongside this test:
    /// `recv_with_fds` used to drop its `SPAWN_FD_LOCK` guard on its own
    /// return, before `MsgStream::fill_more` (the caller) actually closed
    /// a rejected batch -- see `RecvWithFds`'s doc comment. Unlike
    /// `max_sendmsg_descriptors_close_without_leak` above, this doesn't
    /// infer leak-freedom from a side effect (a write returning EPIPE)
    /// that's sensitive to what *any* process holds open; it counts this
    /// process's own fd table directly, which only reflects what we
    /// ourselves have open. Isolated (`#[ignore]`, see the shared-core CI
    /// step) purely so a concurrent test's own fd churn can't produce a
    /// false failure -- this assertion doesn't depend on isolation for
    /// correctness the way the EPIPE test above does, only for precision.
    #[tokio::test]
    #[ignore = "must run alone: see the shared-core CI step for why"]
    async fn too_many_descriptors_are_closed_before_the_reject_returns() {
        let before = open_fd_count();

        let (sender, receiver) = UnixStream::pair().unwrap();
        let (read, write) = nix::unistd::pipe().unwrap();
        crate::pty::set_cloexec(&read).unwrap();
        crate::pty::set_cloexec(&write).unwrap();

        // Same fixture shape as max_sendmsg_descriptors_close_without_leak
        // above: exceed MAX_QUEUED_FDS (not MAX_FDS_PER_SENDMSG, so this
        // never trips MSG_CTRUNC) to exercise the "too many queued file
        // descriptors" rejection specifically.
        let raw_fds = vec![read.as_raw_fd(); MAX_FDS_PER_SENDMSG];
        let payload = [FD_MARKER[0]];
        let iov = [io::IoSlice::new(&payload)];
        let cmsg = [ControlMessage::ScmRights(&raw_fds)];
        socket::sendmsg::<UnixAddr>(sender.as_raw_fd(), &iov, &cmsg, MsgFlags::empty(), None)
            .unwrap();
        drop(read);

        let mut stream = MsgStream::new(receiver);
        assert!(matches!(
            stream.read_line().await,
            Err(ReadFrameError::Io(error)) if error.kind() == io::ErrorKind::InvalidData
        ));
        drop(stream);
        drop(write);
        drop(sender);

        let after = open_fd_count();
        assert_eq!(
            after, before,
            "process fd count changed across a too-many-fds rejection (before={before}, \
             after={after}): a received SCM_RIGHTS descriptor leaked"
        );
    }
}
