#ifndef session_escrow_shim_h
#define session_escrow_shim_h

#include <sys/types.h>
#include <sys/socket.h>

/// Issue #182 slice 1 (`Sources/SessionEscrow.swift`): tiny C shim for the
/// exactly-one-fd `SCM_RIGHTS` send/receive the escrow protocol needs.
///
/// Why this exists: Darwin's `<sys/socket.h>` `CMSG_*` macros
/// (`CMSG_SPACE`, `CMSG_LEN`, `CMSG_DATA`, `CMSG_FIRSTHDR`) are C
/// preprocessor macros and are not importable into Swift. A hand-rolled
/// Swift reimplementation of the control-message byte layout produced a
/// `sendmsg` that failed with `EINVAL` in practice (see the surrounding
/// commit/PR discussion) despite matching the macro arithmetic on paper --
/// marshalling `msghdr`/`cmsghdr` by hand from Swift across several nested
/// `withUnsafe...` closures is exactly the kind of detail that is easy to
/// get subtly wrong and hard to diagnose without a debugger attached to
/// the kernel call. Doing it here in plain C, using the real macros the
/// kernel headers define, removes that whole class of bug. This file is
/// intentionally minimal: two functions, one job each, no protocol
/// knowledge (framing/session bookkeeping/heartbeats all stay in Swift).

/// Sends `payloadLen` bytes from `payload` in one `sendmsg` call. If `fd`
/// is >= 0 it is attached as `SCM_RIGHTS` ancillary data (delivered
/// atomically with this exact message); if `fd` is negative, no ancillary
/// data is sent at all (used for the plain heartbeat frame).
///
/// Returns the number of payload bytes sent on success (compare against
/// `payloadLen` to detect a short write), or -1 on error with `errno` set
/// exactly as `sendmsg(2)` sets it.
ssize_t session_escrow_send(int socket_fd, int fd, const void *payload, size_t payload_len);

/// Receives up to `payload_len` bytes into `payload` in one `recvmsg`
/// call. If an `SCM_RIGHTS` ancillary fd is attached to the received
/// message, `*out_fd` is set to it; otherwise `*out_fd` is set to -1.
/// `out_fd` must not be NULL.
///
/// Returns the number of bytes read (may be less than `payload_len` --
/// callers must loop for exact framing), 0 on EOF, or -1 on error with
/// `errno` set exactly as `recvmsg(2)` sets it (including `EAGAIN`/
/// `EWOULDBLOCK` for a `SO_RCVTIMEO` timeout).
ssize_t session_escrow_recv(int socket_fd, void *payload, size_t payload_len, int *out_fd);

#endif /* session_escrow_shim_h */
