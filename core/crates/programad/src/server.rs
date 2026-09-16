//! Connection handling and method dispatch for the v2 JSON-lines protocol.

use std::collections::HashSet;
use std::os::fd::OwnedFd;
use std::sync::Arc;

use base64::Engine;
use programa_proto::{
    ErrorBody, ErrorCode, Request, Response, IMPLEMENTATION_NAME, IMPLEMENTATION_VERSION,
    IMPLEMENTED_METHODS,
};
use serde_json::{json, Value};
use tokio::net::UnixStream;
use uuid::Uuid;

use crate::fdpass::{MsgStream, ReadFrameError};
use crate::session::{OpenParams, SessionManager, SessionStatus};

pub struct AppState {
    pub sessions: SessionManager,
    /// `None` means no password is configured: every method is allowed
    /// without `auth.login`, matching the local-only "off" access mode.
    /// `Some(password)` requires a successful `auth.login` first, matching
    /// the app's password mode (`docs/v2-api-migration.md`, `auth_required`
    /// / `auth_unconfigured` codes).
    pub password: Option<String>,
}

impl AppState {
    pub fn new(password: Option<String>) -> Self {
        AppState {
            sessions: SessionManager::new(),
            password,
        }
    }
}

const B64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::STANDARD;
const MAX_READ_BYTES: usize = 1024 * 1024;
const MAX_WRITE_BYTES: usize = 1024 * 1024;

/// Result of dispatching one request: the JSON to send back, plus an
/// optional input-pipe fd to hand off via `SCM_RIGHTS` immediately after
/// (only `session.attach` ever populates the fd).
struct Dispatched {
    result: Value,
    fd: Option<OwnedFd>,
    attachment: Option<(String, Uuid)>,
}

impl From<Value> for Dispatched {
    fn from(result: Value) -> Self {
        Dispatched {
            result,
            fd: None,
            attachment: None,
        }
    }
}

pub async fn handle_connection(stream: UnixStream, state: Arc<AppState>) {
    let mut authenticated = state.password.is_none();
    // (session_id, attach_id) pairs this connection attached; detached
    // automatically on disconnect. Detaching never kills the session — a
    // client going away is exactly the case detached sessions exist for.
    let mut my_attachments: HashSet<(String, Uuid)> = HashSet::new();

    // `MsgStream` reads exclusively via `recvmsg`, never a plain buffered
    // `read()`, so the `SCM_RIGHTS` fd `session.attach` sends right after
    // its JSON line is never silently dropped by a reader that happens to
    // slurp the marker byte into an ordinary line-buffered read — see
    // fdpass.rs's module doc for why that's a real (not theoretical) bug.
    let mut msg_stream = MsgStream::new_without_fd_receive(stream);

    loop {
        let line = match msg_stream.read_line().await {
            Ok(Some(l)) => l,
            Ok(None) => break, // EOF
            Err(ReadFrameError::InvalidUtf8) => {
                let response = Response::err(
                    None,
                    ErrorBody::new(ErrorCode::InvalidUtf8, "Invalid UTF-8"),
                );
                let _ = msg_stream.write_all(response.to_line().as_bytes()).await;
                break;
            }
            Err(ReadFrameError::TooLarge) => {
                let response = Response::err(
                    None,
                    ErrorBody::new(ErrorCode::PayloadTooLarge, "Request frame is too large"),
                );
                let _ = msg_stream.write_all(response.to_line().as_bytes()).await;
                break;
            }
            Err(ReadFrameError::Io(e)) => {
                tracing::debug!(error = %e, "connection read error");
                break;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let request = match Request::parse(&line) {
            Ok(r) => r,
            Err(error) => {
                let response_id = serde_json::from_str::<Value>(&line)
                    .ok()
                    .and_then(|value| value.get("id").cloned());
                let resp = Response::err(response_id, error);
                if msg_stream
                    .write_all(resp.to_line().as_bytes())
                    .await
                    .is_err()
                {
                    break;
                }
                continue;
            }
        };

        let id = request.id.clone();
        let method = request.method.clone();

        if !authenticated && method != "auth.login" {
            let resp = Response::err(
                id,
                ErrorBody::new(
                    ErrorCode::AuthRequired,
                    "Authentication required. Call auth.login first.",
                ),
            );
            if msg_stream
                .write_all(resp.to_line().as_bytes())
                .await
                .is_err()
            {
                break;
            }
            continue;
        }

        let outcome = dispatch(&request, &state, &mut authenticated, &mut my_attachments);

        let (resp_line, fd_to_send, pending_attachment) = match outcome {
            Ok(Dispatched {
                result,
                fd,
                attachment,
            }) => (Response::ok(id, result).to_line(), fd, attachment),
            Err(err) => (Response::err(id, err).to_line(), None, None),
        };

        if msg_stream.write_all(resp_line.as_bytes()).await.is_err() {
            rollback_attachment(&state, pending_attachment);
            break;
        }
        if let Some(fd) = fd_to_send {
            use std::os::fd::AsRawFd;
            let raw = fd.as_raw_fd();
            // Contract (README "fd handoff"): the input-only fd rides as
            // SCM_RIGHTS ancillary data on this same connection, sent
            // immediately after the session.attach JSON result line.
            if let Err(e) = msg_stream.send_fd(raw).await {
                tracing::debug!(error = %e, "fd handoff failed");
                rollback_attachment(&state, pending_attachment);
                break;
            }
            // `fd` (our dup) is dropped here; the kernel already copied it
            // into the peer's fd table via SCM_RIGHTS.
        }
        if let Some(attachment) = pending_attachment {
            my_attachments.insert(attachment);
        }
    }

    for (session_id, attach_id) in my_attachments.drain() {
        if let Some(session) = state.sessions.get(&session_id) {
            session.detach(attach_id);
        }
    }
}

fn rollback_attachment(state: &AppState, attachment: Option<(String, Uuid)>) {
    if let Some((session_id, attach_id)) = attachment {
        if let Some(session) = state.sessions.get(&session_id) {
            session.detach(attach_id);
        }
    }
}

fn dispatch(
    req: &Request,
    state: &Arc<AppState>,
    authenticated: &mut bool,
    attachments: &mut HashSet<(String, Uuid)>,
) -> Result<Dispatched, ErrorBody> {
    match req.method.as_str() {
        "system.ping" => Ok(json!({"pong": true}).into()),
        "system.capabilities" => Ok(json!({"methods": IMPLEMENTED_METHODS}).into()),
        "system.identify" => Ok(json!({
            "implementation": IMPLEMENTATION_NAME,
            "version": IMPLEMENTATION_VERSION,
        })
        .into()),
        "auth.login" => auth_login(req, state, authenticated).map(Into::into),
        "session.open" => session_open(req, state).map(Into::into),
        "session.list" => session_list(state).map(Into::into),
        "session.status" => session_status(req, state).map(Into::into),
        "session.resize" => session_resize(req, state, attachments).map(Into::into),
        "session.close" => session_close(req, state).map(Into::into),
        "session.write" => session_write(req, state).map(Into::into),
        "session.read" => session_read(req, state).map(Into::into),
        "session.detach" => session_detach(req, state, attachments).map(Into::into),
        "session.attach" => attach(req, state),
        _ => Err(ErrorBody::new(ErrorCode::MethodNotFound, "Unknown method")),
    }
}

fn require_str<'a>(params: &'a Value, key: &str) -> Result<&'a str, ErrorBody> {
    params.get(key).and_then(Value::as_str).ok_or_else(|| {
        ErrorBody::new(
            ErrorCode::InvalidParams,
            format!("Missing or invalid `{key}`"),
        )
    })
}

fn get_session<'a>(
    state: &'a AppState,
    id: &str,
) -> Result<Arc<crate::session::Session>, ErrorBody> {
    state
        .sessions
        .get(id)
        .ok_or_else(|| ErrorBody::new(ErrorCode::NotFound, "session not found"))
}

fn status_json(status: SessionStatus) -> Value {
    match status {
        SessionStatus::Running => json!({"state": "running"}),
        SessionStatus::Exited { code, signal } => {
            json!({"state": "exited", "code": code, "signal": signal})
        }
        SessionStatus::Failed { error } => json!({"state": "failed", "error": error}),
    }
}

fn auth_login(
    req: &Request,
    state: &Arc<AppState>,
    authenticated: &mut bool,
) -> Result<Value, ErrorBody> {
    if state.password.is_none() {
        *authenticated = true;
        return Ok(json!({"authenticated": true, "required": false}));
    }
    let provided = require_str(&req.params, "password")?;
    let expected = state.password.as_deref().unwrap();
    if provided == expected {
        *authenticated = true;
        Ok(json!({"authenticated": true, "required": true}))
    } else {
        Err(ErrorBody::new(ErrorCode::AuthFailed, "Incorrect password"))
    }
}

fn session_open(req: &Request, state: &Arc<AppState>) -> Result<Value, ErrorBody> {
    let params = &req.params;
    let argv: Vec<String> = if let Some(arr) = params.get("argv").and_then(Value::as_array) {
        arr.iter()
            .map(|value| value.as_str().map(str::to_string))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| {
                ErrorBody::new(ErrorCode::InvalidParams, "`argv` must contain only strings")
            })?
    } else if let Some(cmd) = params.get("command").and_then(Value::as_str) {
        vec![
            crate::pty::login_shell(),
            "-lc".to_string(),
            cmd.to_string(),
        ]
    } else {
        vec![crate::pty::login_shell(), "-l".to_string()]
    };
    if argv.is_empty() || argv.iter().any(|s| s.is_empty()) {
        return Err(ErrorBody::new(
            ErrorCode::InvalidParams,
            "`argv` must be non-empty strings",
        ));
    }
    let cwd = params
        .get("cwd")
        .and_then(Value::as_str)
        .map(std::path::PathBuf::from);
    let mut env: Vec<(String, String)> = std::env::vars()
        .filter(|(key, _)| !is_auth_environment(key))
        .collect();
    if let Some(obj) = params.get("env").and_then(Value::as_object) {
        for (k, v) in obj {
            if is_auth_environment(k) {
                continue;
            }
            let value = v.as_str().ok_or_else(|| {
                ErrorBody::new(
                    ErrorCode::InvalidParams,
                    "environment values must be strings",
                )
            })?;
            env.push((k.clone(), value.to_string()));
        }
    } else if params.get("env").is_some() {
        return Err(ErrorBody::new(
            ErrorCode::InvalidParams,
            "`env` must be an object",
        ));
    }
    let cols = parse_dimension(params, "cols", 80)?;
    let rows = parse_dimension(params, "rows", 24)?;

    let session = state
        .sessions
        .open(OpenParams {
            argv,
            cwd,
            env,
            cols,
            rows,
        })
        .map_err(|e| ErrorBody::new(ErrorCode::InternalError, format!("spawn failed: {e}")))?;

    Ok(json!({
        "id": session.id,
        "pid": session.pid(),
        "cols": cols,
        "rows": rows,
    }))
}

fn is_auth_environment(key: &str) -> bool {
    matches!(
        key,
        "PROGRAMAD_PASSWORD"
            | "PROGRAMAD_AUTH_TOKEN"
            | "PROGRAMA_SOCKET_PASSWORD"
            | "PROGRAMA_SOCKET_AUTH_TOKEN"
    )
}

fn parse_dimension(params: &Value, key: &str, default: u16) -> Result<u16, ErrorBody> {
    let Some(value) = params.get(key) else {
        return Ok(default);
    };
    let value = value
        .as_u64()
        .filter(|value| (1..=u16::MAX as u64).contains(value));
    value.map(|value| value as u16).ok_or_else(|| {
        ErrorBody::new(
            ErrorCode::InvalidParams,
            format!("`{key}` must be 1...65535"),
        )
    })
}

fn session_list(state: &Arc<AppState>) -> Result<Value, ErrorBody> {
    let list: Vec<Value> = state
        .sessions
        .list()
        .into_iter()
        .map(|s| {
            let (cols, rows) = s.current_size();
            json!({
                "id": s.id,
                "argv": s.argv,
                "cwd": s.cwd,
                "pid": s.pid(),
                "status": status_json(s.status()),
                "cols": cols,
                "rows": rows,
                "attachments": s.attachment_count(),
                "wal_tail_offset": s.wal_tail_offset(),
            })
        })
        .collect();
    Ok(json!({"sessions": list}))
}

fn session_status(req: &Request, state: &Arc<AppState>) -> Result<Value, ErrorBody> {
    let id = require_str(&req.params, "id")?;
    let session = get_session(state, id)?;
    let (cols, rows) = session.current_size();
    Ok(json!({
        "id": session.id,
        "pid": session.pid(),
        "status": status_json(session.status()),
        "cols": cols,
        "rows": rows,
        "attachments": session.attachment_count(),
        "wal_tail_offset": session.wal_tail_offset(),
        "wal_base_offset": session.wal_base_offset(),
    }))
}

fn parse_attach_id(req: &Request) -> Result<Uuid, ErrorBody> {
    let s = require_str(&req.params, "attach_id")?;
    Uuid::parse_str(s).map_err(|_| ErrorBody::new(ErrorCode::InvalidParams, "invalid attach_id"))
}

fn session_resize(
    req: &Request,
    state: &Arc<AppState>,
    attachments: &HashSet<(String, Uuid)>,
) -> Result<Value, ErrorBody> {
    let id = require_str(&req.params, "id")?;
    let attach_id = parse_attach_id(req)?;
    if !attachments.contains(&(id.to_string(), attach_id)) {
        return Err(ErrorBody::new(
            ErrorCode::InvalidParams,
            "attachment is not owned by this connection",
        ));
    }
    let cols = parse_dimension(&req.params, "cols", 80)?;
    let rows = parse_dimension(&req.params, "rows", 24)?;
    let session = get_session(state, id)?;
    let resized = session.resize(attach_id, cols, rows).map_err(|error| {
        ErrorBody::new(ErrorCode::InternalError, format!("resize failed: {error}"))
    })?;
    if !resized {
        return Err(ErrorBody::new(ErrorCode::NotFound, "attachment not found"));
    }
    let (eff_cols, eff_rows) = session.current_size();
    Ok(json!({"cols": eff_cols, "rows": eff_rows}))
}

fn session_close(req: &Request, state: &Arc<AppState>) -> Result<Value, ErrorBody> {
    let id = require_str(&req.params, "id")?;
    let kill = req
        .params
        .get("kill")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    if !kill {
        return Err(ErrorBody::new(
            ErrorCode::Unsupported,
            "session.close with kill=false cannot preserve a PTY after daemon ownership ends",
        ));
    }
    let closed = state.sessions.close(id, kill).map_err(|error| {
        let code = if error.kind() == std::io::ErrorKind::TimedOut {
            ErrorCode::Timeout
        } else {
            ErrorCode::InternalError
        };
        ErrorBody::new(code, format!("close failed: {error}"))
    })?;
    if !closed {
        return Err(ErrorBody::new(ErrorCode::NotFound, "session not found"));
    }
    Ok(json!({"closed": true}))
}

fn session_write(req: &Request, state: &Arc<AppState>) -> Result<Value, ErrorBody> {
    let id = require_str(&req.params, "id")?;
    let data_b64 = require_str(&req.params, "data")?;
    let bytes = B64
        .decode(data_b64)
        .map_err(|_| ErrorBody::new(ErrorCode::InvalidParams, "`data` is not valid base64"))?;
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(ErrorBody::new(
            ErrorCode::PayloadTooLarge,
            "decoded session.write data exceeds 1 MiB",
        ));
    }
    let session = get_session(state, id)?;
    let n = session
        .write(&bytes)
        .map_err(|e| ErrorBody::new(ErrorCode::InternalError, format!("write failed: {e}")))?;
    Ok(json!({"written": n}))
}

fn session_read(req: &Request, state: &Arc<AppState>) -> Result<Value, ErrorBody> {
    let id = require_str(&req.params, "id")?;
    let offset = req
        .params
        .get("offset")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let max_len = match req.params.get("max_len") {
        None => 65536,
        Some(value) => value
            .as_u64()
            .filter(|length| *length <= MAX_READ_BYTES as u64)
            .map(|length| length as usize)
            .ok_or_else(|| {
                ErrorBody::new(
                    ErrorCode::InvalidParams,
                    "`max_len` must be an integer from 0 through 1048576",
                )
            })?,
    };
    let session = get_session(state, id)?;
    let (start, bytes) = session
        .read_wal(offset, max_len)
        .map_err(|e| ErrorBody::new(ErrorCode::InternalError, format!("read failed: {e}")))?;
    Ok(json!({
        "offset": start,
        "data": B64.encode(&bytes),
        "tail_offset": session.wal_tail_offset(),
    }))
}

fn session_detach(
    req: &Request,
    state: &Arc<AppState>,
    attachments: &mut HashSet<(String, Uuid)>,
) -> Result<Value, ErrorBody> {
    let id = require_str(&req.params, "id")?;
    let attach_id = parse_attach_id(req)?;
    if !attachments.remove(&(id.to_string(), attach_id)) {
        return Err(ErrorBody::new(
            ErrorCode::InvalidParams,
            "attachment is not owned by this connection",
        ));
    }
    let session = get_session(state, id)?;
    if !session.detach(attach_id) {
        return Err(ErrorBody::new(ErrorCode::NotFound, "attachment not found"));
    }
    Ok(json!({"detached": true}))
}

/// `session.attach` uniquely needs to hand a fd to the caller after this
/// JSON is written, so it returns a populated `Dispatched.fd` instead of
/// going through the plain `Result<Value, _>` methods above.
fn attach(req: &Request, state: &Arc<AppState>) -> Result<Dispatched, ErrorBody> {
    let id = require_str(&req.params, "id")?.to_string();
    let cols = parse_dimension(&req.params, "cols", 80)?;
    let rows = parse_dimension(&req.params, "rows", 24)?;

    let session = get_session(state, &id)?;
    let attach_id = Uuid::new_v4();
    let (replay_from, input_fd) = session
        .attach(attach_id, cols, rows)
        .map_err(|e| ErrorBody::new(ErrorCode::InternalError, format!("attach failed: {e}")))?;

    let result = json!({
        "session_id": session.id,
        "attach_id": attach_id.to_string(),
        "replay_from": replay_from,
        "tail_offset": session.wal_tail_offset(),
        "cols": cols,
        "rows": rows,
        "fd_follows": true,
        "fd_mode": "write_only_input",
    });

    Ok(Dispatched {
        result,
        fd: Some(input_fd),
        attachment: Some((id, attach_id)),
    })
}
