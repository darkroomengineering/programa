# Remote transport design boundary

This document is a design note. The current `programad` accepts only a private
local Unix socket and does not listen on TCP, manage SSH, pair devices, or
expose sessions to a network.

## Invariants to preserve

A future remote transport should terminate outside the PTY/session core and
forward the existing v2 request/response envelope through an authenticated,
encrypted channel. The local daemon should continue to own the PTY and remain
its sole output reader. Remote input should enter through the same bounded
write path as `session.write`; remote output should come from offset-based WAL
reads. `SCM_RIGHTS` is local-only and must not be emulated over the network.

Remote connections need an attachment lease bound to their authenticated
connection. Closing the transport must detach its leases, and resize/detach
must enforce that ownership exactly as the Unix connection does. Request-frame,
write, read, WAL, and attachment bounds remain in force before data reaches the
session manager.

## Proposed shape

1. A transport adapter authenticates the peer and creates a local connection
   identity. SSH stdio or a mutually authenticated TLS stream are suitable
   candidates; product requirements should decide between them.
2. The adapter carries length-bounded UTF-8 v2 frames. It maps attach to an
   input stream plus WAL offset, never to a remote file descriptor.
3. Reconnection presents a short-lived, scoped session capability and resumes
   WAL reads from the last acknowledged absolute offset.
4. Backpressure caps outstanding input and output per connection. A slow peer
   may lose aged WAL history according to the existing `base_offset` contract,
   but cannot block the daemon's PTY drain.
5. Audit events record authentication, attach/detach, rejected ownership
   checks, and session termination without recording terminal contents or
   credentials.

## Decisions required before implementation

- deployment and discovery model (existing SSH daemon, user service, or a new
  broker);
- organization identity and authorization policy;
- credential provisioning, rotation, and revocation;
- reconnect capability lifetime and whether multiple devices may attach;
- protocol version negotiation and upgrade compatibility;
- resource quotas per user, host, and session.

No remote listener should be added until these decisions have owners and a
threat model. This foundation deliberately leaves remote transport unbuilt.
