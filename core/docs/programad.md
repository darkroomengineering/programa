# programad foundation

`programad` is a local, per-user Unix daemon that owns PTYs and captures their
output in bounded per-session write-ahead logs. It implements the Programa v2
JSON-lines envelope and is currently a standalone foundation: the Programa UI
does not select it as its terminal backend yet.

## Build and run

```sh
cargo build --release
target/release/programad
```

The default endpoint is `$XDG_RUNTIME_DIR/programad.sock`, or
`~/.local/state/programa/programad.sock` when no runtime directory is set. A
custom endpoint can be selected with `--socket /absolute/private/dir/name.sock`.
The socket directory must be a real directory owned by the current user; the
daemon makes it mode `0700`, and the socket is mode `0600`. Each endpoint has a
sibling lock file, so different custom endpoints can run independently.

Set `PROGRAMAD_PASSWORD` or pass `--password-file PATH` to require
`auth.login`. Authentication secrets (`PROGRAMAD_PASSWORD`,
`PROGRAMAD_AUTH_TOKEN`, `PROGRAMA_SOCKET_PASSWORD`, and
`PROGRAMA_SOCKET_AUTH_TOKEN`) are removed from child environments, including
values supplied through `session.open.params.env`.

## Wire contract

Requests and responses are UTF-8 JSON objects terminated by `\n`:

```json
{"id":1,"method":"system.ping","params":{}}
{"id":1,"ok":true,"result":{"pong":true}}
```

Frames are limited to 8 MiB. Blank whitespace-only frames are ignored. A
request method is trimmed and must be non-empty; `params`, when present, must
be an object. Malformed JSON, invalid request shapes, invalid UTF-8, and large
frames produce distinct `parse_error`, `invalid_request`, `invalid_utf8`, and
`payload_too_large` errors. Invalid UTF-8 and oversized frames close the
connection after the error response.

The implemented methods are:

- `system.ping`, `system.capabilities`, `system.identify`
- `auth.login`
- `session.open`, `session.list`, `session.status`, `session.resize`
- `session.write`, `session.read`, `session.attach`, `session.detach`,
  `session.close`

With no configured password, `auth.login` succeeds without a password and
returns `{"authenticated":true,"required":false}`. With a password, all
methods except `auth.login` require successful authentication on that
connection.

Columns and rows must be integers from 1 through 65535. `session.read.max_len`
is capped at 1 MiB, as is decoded `session.write.data`. `session.close` defaults
to terminating the child; `kill:false` is rejected because dropping daemon PTY
ownership cannot truthfully preserve the process.
Close sends `SIGHUP`; if the child has not exited after 500 ms, the request
returns `timeout` and the session remains tracked rather than being orphaned.

## Attach and file-descriptor handoff

`session.attach` returns an attachment ID and then sends one descriptor with
`SCM_RIGHTS` on the same socket. The ancillary payload is one raw NUL byte,
which cannot occur in a valid JSON frame. Receivers must use `recvmsg(2)` for
every socket read, remove one NUL marker per received descriptor, reject
truncated ancillary data, and set `FD_CLOEXEC`.

The handed-off descriptor is `fd_mode: "write_only_input"`: it is the write end
of a pipe, not the PTY master. Writing it supplies low-latency terminal input;
reading it fails with `EBADF`. The daemon is the only PTY master reader for the
session's lifetime and writes all output to the WAL. Clients consume output
with `session.read`. This prevents the daemon and a client from racing to drain
the same PTY bytes.

Attachment IDs belong to the connection that created them. Only that
connection may resize or detach them. Disconnect automatically detaches all of
its attachments. The effective PTY size is the smallest requested columns and
rows across current attachments; with none attached, the last size remains.
If the JSON response or descriptor handoff fails, the pending attachment is
rolled back.

## WAL and lifecycle

The daemon drains PTY output continuously, including while no client is
attached. Each session WAL is capped at 8 MiB and compacts to its newest 4 MiB.
Absolute offsets remain monotonic. WAL data and metadata are fsynced on a
debounced 200 ms interval and at clean close. Compaction writes a replacement,
syncs it, records a recovery intent, and uses atomic renames; startup completes
an interrupted transaction before opening the WAL. Append or flush failure
places the session in a visible `failed` state and sends the child `SIGHUP`.

Client disconnect does not terminate a session. Daemon shutdown does terminate
tracked children. `--keep-sessions` is explicitly unsupported and exits with an
error: surviving daemon exit needs a separate persistent fd keeper and restart
recovery, which this foundation does not implement.

## Verification

`cargo check --all-targets`, `cargo build`, and `cargo fmt --all -- --check` are
the local static gates. Runtime tests live in `crates/programad/tests` and unit
test modules; `tests/smoke.py` exercises a running daemon without third-party
Python packages. Project policy runs tests in CI or a VM rather than locally.

On 2026-09-16, `cargo test --locked` passed all 16 tests with none ignored in
an isolated Ubuntu ARM64 VM using Rust 1.97.1. The Python smoke flow also passed
against the VM's daemon. This verifies Linux session/attachment replay, descriptor
cleanup, child reaping, and WAL behavior; macOS runtime tests remain unrun.

Remote networking is not implemented. [docs/remote-transport.md](docs/remote-transport.md)
records the future transport boundary without expanding this daemon's current
trust model.
