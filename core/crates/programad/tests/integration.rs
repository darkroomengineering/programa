//! End-to-end test: start the daemon on a temp socket, open a session
//! running `sh -c 'echo MARK_$$; cat'`, attach and receive a write-only input
//! fd over SCM_RIGHTS, write through that fd, read the echo back through
//! the WAL (not through the fd — see the "single reader" note in
//! `session.rs`/README), detach, kill the client side, re-attach, and
//! replay from the WAL to prove the session (and its output) survived the
//! first client's death.

use std::os::fd::{AsRawFd, OwnedFd};
use std::sync::Mutex;
use std::time::Duration;

use base64::Engine;
use programad::fdpass::MsgStream;
use serde_json::{json, Value};
use tokio::net::UnixStream;

const B64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::STANDARD;

/// `paths::state_root` reads the process-global `XDG_STATE_HOME` env var,
/// and every test below sets it to its own tempdir so WAL files don't
/// collide with a real user's state or with each other. `cargo test` runs
/// tests in this binary on separate threads by default, so two tests
/// mutating that global concurrently would race and read each other's
/// tempdir. This lock serializes the env-mutating section of each test.
static ENV_LOCK: Mutex<()> = Mutex::new(());

struct Client {
    stream: MsgStream,
    next_id: u64,
}

impl Client {
    async fn connect(path: &std::path::Path) -> Self {
        let stream = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Ok(s) = UnixStream::connect(path).await {
                    return s;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("daemon never accepted a connection");
        Client {
            stream: MsgStream::new(stream),
            next_id: 1,
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let response = self.call_response(method, params).await;
        assert_eq!(response["ok"], true, "{method} failed: {response}");
        response["result"].clone()
    }

    async fn call_response(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        let req = json!({"id": id, "method": method, "params": params});
        let mut line = serde_json::to_string(&req).unwrap();
        line.push('\n');
        self.stream.write_all(line.as_bytes()).await.unwrap();

        let resp_line = tokio::time::timeout(Duration::from_secs(5), self.stream.read_line())
            .await
            .expect("timed out waiting for response")
            .unwrap()
            .expect("connection closed while waiting for response");
        let resp: Value = serde_json::from_str(&resp_line)
            .unwrap_or_else(|e| panic!("bad JSON for {method}: {e}; raw line was {resp_line:?}"));
        assert_eq!(resp["id"], id, "response id mismatch for {method}: {resp}");
        resp
    }

    async fn recv_fd(&mut self) -> OwnedFd {
        tokio::time::timeout(Duration::from_secs(5), self.stream.take_fd())
            .await
            .expect("timed out waiting for fd handoff")
            .expect("no fd received")
    }
}

fn spawn_daemon(
    socket_path: std::path::PathBuf,
) -> (
    tokio::task::JoinHandle<()>,
    tokio::sync::oneshot::Sender<()>,
) {
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let handle = tokio::spawn(async move {
        let config = programad::DaemonConfig {
            socket_path,
            password: None,
        };
        let shutdown = async {
            let _ = rx.await;
        };
        programad::serve(config, shutdown)
            .await
            .expect("serve failed");
    });
    (handle, tx)
}

#[tokio::test]
async fn full_session_lifecycle_survives_client_disconnect() {
    let _env_guard = ENV_LOCK.lock().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let socket_path = dir.path().join("programad.sock");
    // Point the WAL under our own temp dir too, so the test doesn't touch
    // the real user's state dir and different test runs don't collide.
    std::env::set_var("XDG_STATE_HOME", dir.path());

    let (daemon_handle, shutdown_tx) = spawn_daemon(socket_path.clone());

    // --- First client: open, attach, write, verify via WAL. ---
    let mut client = Client::connect(&socket_path).await;

    let login = client.call("auth.login", json!({})).await;
    assert_eq!(login, json!({"authenticated": true, "required": false}));

    client.stream.write_all(b"[]\n").await.unwrap();
    let invalid_shape = client.stream.read_line().await.unwrap().unwrap();
    let invalid_shape: Value = serde_json::from_str(&invalid_shape).unwrap();
    assert_eq!(invalid_shape["error"]["code"], "invalid_request");

    // Blank frames are ignored and a fragmented request is reassembled. The
    // method is trimmed to match the app's v2 protocol implementation.
    client.stream.write_all(b"  \t\r\n").await.unwrap();
    client
        .stream
        .write_all(b"{\"id\":700,\"method\":\"  system.")
        .await
        .unwrap();
    client
        .stream
        .write_all(b"ping  \",\"params\":{}}\n")
        .await
        .unwrap();
    let fragmented = client.stream.read_line().await.unwrap().unwrap();
    let fragmented: Value = serde_json::from_str(&fragmented).unwrap();
    assert_eq!(fragmented["id"], 700);
    assert_eq!(fragmented["result"]["pong"], true);

    let caps = client.call("system.capabilities", json!({})).await;
    let methods = caps["methods"].as_array().unwrap();
    assert!(methods.iter().any(|m| m == "session.open"));

    let ident = client.call("system.identify", json!({})).await;
    assert_eq!(ident["implementation"], "programad");

    let open_result = client
        .call(
            "session.open",
            json!({"argv": ["/bin/sh", "-c", "echo MARK_$$; cat"], "cols": 80, "rows": 24}),
        )
        .await;
    let session_id = open_result["id"].as_str().unwrap().to_string();
    assert!(open_result["pid"].as_i64().unwrap() > 0);

    let attach_result = client
        .call(
            "session.attach",
            json!({"id": session_id, "cols": 80, "rows": 24}),
        )
        .await;
    assert_eq!(attach_result["fd_follows"], true);
    let attach_id = attach_result["attach_id"].as_str().unwrap().to_string();
    let master_fd = client.recv_fd().await;
    assert_eq!(attach_result["fd_mode"], "write_only_input");

    // The handed-off descriptor is enforceably input-only. Output is read
    // through session.read/WAL, so the daemon remains the sole PTY reader.
    let mut byte = [0u8; 1];
    assert_eq!(
        nix::unistd::read(master_fd.as_raw_fd(), &mut byte).unwrap_err(),
        nix::errno::Errno::EBADF
    );

    let invalid_resize = client
        .call_response(
            "session.resize",
            json!({"id": session_id, "attach_id": attach_id, "cols": 0, "rows": 24}),
        )
        .await;
    assert_eq!(invalid_resize["error"]["code"], "invalid_params");
    let resized = client
        .call(
            "session.resize",
            json!({"id": session_id, "attach_id": attach_id, "cols": 100, "rows": 30}),
        )
        .await;
    assert_eq!(resized, json!({"cols": 100, "rows": 30}));

    let mut unowned_client = Client::connect(&socket_path).await;
    let unowned_resize = unowned_client
        .call_response(
            "session.resize",
            json!({"id": session_id, "attach_id": attach_id, "cols": 90, "rows": 20}),
        )
        .await;
    assert_eq!(unowned_resize["error"]["code"], "invalid_params");
    let smaller = unowned_client
        .call(
            "session.attach",
            json!({"id": session_id, "cols": 60, "rows": 40}),
        )
        .await;
    let smaller_fd = unowned_client.recv_fd().await;
    let size = client
        .call("session.status", json!({"id": session_id}))
        .await;
    assert_eq!(
        (size["cols"].as_u64(), size["rows"].as_u64()),
        (Some(60), Some(30))
    );
    let resized = unowned_client
        .call(
            "session.resize",
            json!({"id": session_id, "attach_id": smaller["attach_id"], "cols": 120, "rows": 20}),
        )
        .await;
    assert_eq!(resized, json!({"cols": 100, "rows": 20}));
    unowned_client
        .call(
            "session.detach",
            json!({"id": session_id, "attach_id": smaller["attach_id"]}),
        )
        .await;
    drop(smaller_fd);
    let size = client
        .call("session.status", json!({"id": session_id}))
        .await;
    assert_eq!(
        (size["cols"].as_u64(), size["rows"].as_u64()),
        (Some(100), Some(30))
    );
    drop(unowned_client);

    // Wait for the shell to actually start and run its first command before
    // sending input. Without this, "hello from client A" below can reach
    // the PTY's input queue before the freshly-forked shell has run `echo
    // MARK_$$` (fork/exec/shell-startup racing the several RPC round trips
    // above is not bounded), and `cat` will echo back our queued input the
    // moment it starts, landing in the WAL ahead of the MARK line. The WAL
    // is a faithful FIFO of what actually happened on the PTY; ordering
    // between an external write and the child's own startup output is a
    // real race the daemon does not and should not paper over, so the test
    // synchronizes on it explicitly instead of assuming the child won a
    // race it was never guaranteed to win.
    for _ in 0..100 {
        let read = client
            .call("session.read", json!({"id": session_id, "offset": 0}))
            .await;
        let chunk = B64.decode(read["data"].as_str().unwrap()).unwrap();
        if chunk.windows(5).any(|w| w == b"MARK_") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    // Write through the handed-off fd directly (the low-latency input
    // path); the daemon's own reader thread is the sole reader of the
    // master and drains into the WAL regardless.
    {
        use std::io::Write;
        // SAFETY: dup returns a new descriptor owned by this File; dropping
        // it leaves the separately owned handed-off descriptor open.
        let mut file = unsafe {
            <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(
                nix::unistd::dup(master_fd.as_raw_fd()).unwrap(),
            )
        };
        file.write_all(b"hello from client A\n").unwrap();
        file.flush().unwrap();
    }

    // Poll the WAL until both the initial MARK line and our echoed input
    // show up (the shell's `cat` should have echoed our write back).
    let mut seen = String::new();
    let mut offset = 0u64;
    for _ in 0..100 {
        let read = client
            .call("session.read", json!({"id": session_id, "offset": offset}))
            .await;
        let chunk = B64.decode(read["data"].as_str().unwrap()).unwrap();
        offset = read["tail_offset"].as_u64().unwrap();
        seen.push_str(&String::from_utf8_lossy(&chunk));
        if seen.contains("hello from client A") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        seen.contains("MARK_"),
        "expected shell PID marker in WAL, got: {seen:?}"
    );
    assert!(
        seen.contains("hello from client A"),
        "expected our write to be echoed back into the WAL, got: {seen:?}"
    );

    let tail_before_detach = offset;

    client
        .call(
            "session.detach",
            json!({"id": session_id, "attach_id": attach_id}),
        )
        .await;

    // --- Kill the first client's connection (simulating client death). ---
    drop(client);
    drop(master_fd);
    tokio::time::sleep(Duration::from_millis(100)).await;

    // Session must still be tracked and running: client death does not
    // touch the child.
    let mut client2 = Client::connect(&socket_path).await;
    let status = client2
        .call("session.status", json!({"id": session_id}))
        .await;
    assert_eq!(
        status["status"]["state"], "running",
        "session should survive client death: {status}"
    );
    assert_eq!(
        (status["cols"].as_u64(), status["rows"].as_u64()),
        (Some(100), Some(30)),
        "last size is retained with no attachments"
    );

    // Write more output while nobody is attached, to prove the daemon's
    // own reader thread keeps draining independent of attachment state.
    let write_data = B64.encode(b"second write while detached\n");
    client2
        .call(
            "session.write",
            json!({"id": session_id, "data": write_data}),
        )
        .await;

    // --- Re-attach and replay from the offset returned by attach. ---
    let attach2 = client2
        .call(
            "session.attach",
            json!({"id": session_id, "cols": 100, "rows": 40}),
        )
        .await;
    let _second_fd = client2.recv_fd().await;
    let replay_from = attach2["replay_from"].as_u64().unwrap();
    assert!(
        replay_from <= tail_before_detach,
        "replay_from should cover prior output"
    );

    let mut replayed = String::new();
    let mut offset2 = replay_from;
    for _ in 0..100 {
        let read = client2
            .call("session.read", json!({"id": session_id, "offset": offset2}))
            .await;
        let chunk = B64.decode(read["data"].as_str().unwrap()).unwrap();
        offset2 = read["tail_offset"].as_u64().unwrap();
        replayed.push_str(&String::from_utf8_lossy(&chunk));
        if replayed.contains("second write while detached") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        replayed.contains("MARK_"),
        "replay should include the original marker: {replayed:?}"
    );
    assert!(
        replayed.contains("hello from client A"),
        "replay should include client A's write: {replayed:?}"
    );
    assert!(
        replayed.contains("second write while detached"),
        "replay should include the write made while nobody was attached: {replayed:?}"
    );

    // Cleanup: actually terminate the child this time.
    client2
        .call("session.close", json!({"id": session_id, "kill": true}))
        .await;

    let mut invalid_utf8_client = Client::connect(&socket_path).await;
    invalid_utf8_client
        .stream
        .write_all(&[0xff, b'\n'])
        .await
        .unwrap();
    let invalid_utf8 = invalid_utf8_client
        .stream
        .read_line()
        .await
        .unwrap()
        .unwrap();
    let invalid_utf8: Value = serde_json::from_str(&invalid_utf8).unwrap();
    assert_eq!(invalid_utf8["error"]["code"], "invalid_utf8");

    let _ = shutdown_tx.send(());
    let _ = tokio::time::timeout(Duration::from_secs(5), daemon_handle).await;
}

/// `workspace.*` links `programa-domain`'s state model into the daemon
/// socket (core/docs/programad.md "Process layer"): a client opens a
/// session (a PTY), creates a workspace whose one pane holds a surface
/// referencing that session, confirms `workspace.snapshot` reflects it, then
/// closes the session and confirms the surface is gone. "Gone" (not a
/// `terminated` flag) is the documented choice: `programa-domain` has no
/// terminated state today, and this matches what a client does when a
/// terminal exits.
#[tokio::test]
async fn workspace_dispatch_links_domain_surfaces_to_sessions_and_reconciles_on_close() {
    let _env_guard = ENV_LOCK.lock().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let socket_path = dir.path().join("programad.sock");
    std::env::set_var("XDG_STATE_HOME", dir.path());

    let (daemon_handle, shutdown_tx) = spawn_daemon(socket_path.clone());
    let mut client = Client::connect(&socket_path).await;
    client.call("auth.login", json!({})).await;

    // workspace.* is advertised in system.capabilities alongside the
    // session.* methods.
    let capabilities = client.call("system.capabilities", json!({})).await;
    let methods: Vec<&str> = capabilities["methods"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m.as_str().unwrap())
        .collect();
    assert!(methods.contains(&"workspace.snapshot"));
    assert!(methods.contains(&"workspace.dispatch"));

    // A command that names a session this daemon does not own is rejected
    // before it ever reaches programa-domain.
    let unknown_session = client
        .call_response(
            "workspace.dispatch",
            json!({
                "command": "create_workspace",
                "workspace_id": "w1",
                "pane_id": "p1",
                "surface_id": "s1",
                "session_id": "does-not-exist",
            }),
        )
        .await;
    assert_eq!(unknown_session["ok"], false);
    assert_eq!(unknown_session["error"]["code"], "not_found");

    // Open a real session (a PTY) to back the domain surface.
    let opened = client
        .call(
            "session.open",
            json!({"command": "cat", "cols": 80, "rows": 24}),
        )
        .await;
    let session_id = opened["id"].as_str().unwrap().to_string();

    // Create a workspace with one pane whose one surface references the
    // session, exactly the shape core/ABI.md documents for create_workspace.
    let dispatch_result = client
        .call(
            "workspace.dispatch",
            json!({
                "command": "create_workspace",
                "workspace_id": "w1",
                "pane_id": "p1",
                "surface_id": "s1",
                "session_id": session_id,
            }),
        )
        .await;
    assert_eq!(dispatch_result["snapshot"]["revision"], 1);
    assert_eq!(
        dispatch_result["snapshot"]["workspaces"][0]["panes"][0]["surfaces"][0]["session_id"],
        session_id
    );

    // workspace.snapshot reflects the same state a second call would.
    let snapshot = client.call("workspace.snapshot", json!({})).await;
    assert_eq!(snapshot["revision"], 1);
    let surfaces = snapshot["workspaces"][0]["panes"][0]["surfaces"]
        .as_array()
        .unwrap();
    assert_eq!(surfaces.len(), 1);
    assert_eq!(surfaces[0]["id"], "s1");
    assert_eq!(surfaces[0]["session_id"], session_id);

    // Closing the session removes the surface that referenced it.
    client
        .call("session.close", json!({"id": session_id, "kill": true}))
        .await;
    let after_close = client.call("workspace.snapshot", json!({})).await;
    assert_eq!(
        after_close["workspaces"].as_array().unwrap().len(),
        0,
        "closing the session's only surface should collapse its pane and \
         workspace, leaving the domain state empty: {after_close}"
    );
    assert_eq!(after_close["selected_workspace_id"], Value::Null);

    let _ = shutdown_tx.send(());
    let _ = tokio::time::timeout(Duration::from_secs(5), daemon_handle).await;
}
