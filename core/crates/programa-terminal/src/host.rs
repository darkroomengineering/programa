//! The terminal host, `programa-host.exe`: the process that owns each terminal's ConPTY and shell,
//! so they keep running when Programa quits or crashes, and the app reattaches to them on its
//! next launch (docs/plans/detached-sessions.md on macOS). It runs a session exactly as the app
//! did, keeps the last 4 MB of its output, and forwards that output to the attached app.
//!
//! Wire protocol, one named pipe (`PROGRAMA_HOST_PIPE`, a random name only the app knows), each
//! connection opening with one JSON line `{"token", "op", ...}` answered by one JSON line
//! `{"ok": true, ...}` or `{"ok": false, "error"}`:
//!
//! - `attach {id}` / `spawn {id, config}`: the output channel. After the answer (`pid`, and
//!   `replay`, how many bytes of past output follow), the host writes the session's output.
//! - `input {id}`: the input channel. After the answer, everything the app writes is typed.
//! - `resize {id, cols, rows, cell_width, cell_height}`, `kill {id}`, `retain {ids}`, `list`.
//!
//! Output and input use separate connections: Windows serializes reads and writes on one
//! synchronous handle, so a blocked read would hold up a write.

// The server is Windows-only; elsewhere only the client half and the replay buffer are used.
#![cfg_attr(not(windows), allow(dead_code))]

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
#[cfg(windows)]
use std::os::windows::fs::OpenOptionsExt;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Past output kept for a reattach.
pub const MAX_REPLAY: usize = 4 * 1024 * 1024;
/// How long the host waits with no session before it exits.
pub const IDLE_EXIT: Duration = Duration::from_secs(60);

/// What the app puts in a terminal's config to run it in the host.
#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct HostConfig {
    pub pipe: String,
    pub token: String,
    pub id: String,
}

/// One line, read a byte at a time so nothing after it is consumed. At most 4 MB.
pub fn read_line(stream: &mut impl Read) -> io::Result<String> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if stream.read(&mut byte)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the host closed the pipe",
            ));
        }
        if byte[0] == b'\n' {
            return String::from_utf8(line)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error));
        }
        line.push(byte[0]);
        if line.len() > 4 * 1024 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "request too long",
            ));
        }
    }
}

fn connect(pipe: &str) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    #[cfg(windows)]
    options.security_qos_flags(0x0001_0000); // SECURITY_IDENTIFICATION

    // Every instance busy (ERROR_PIPE_BUSY): the host makes the next one at once.
    for _ in 0..100 {
        match options.open(pipe) {
            Err(error) if error.raw_os_error() == Some(231) => {
                std::thread::sleep(Duration::from_millis(10))
            }
            other => return other,
        }
    }
    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "the terminal host is busy",
    ))
}

/// Sends a request; the stream (for `attach`, `spawn` and `input`, the channel) and the answer.
/// A refusal is an error whose kind is NotFound for a session the host does not have.
pub fn request(host: &HostConfig, mut body: Value) -> io::Result<(File, Value)> {
    let mut stream = connect(&host.pipe)?;
    body["token"] = json!(host.token);
    body["version"] = json!(1);
    stream.write_all(format!("{body}\n").as_bytes())?;
    let answer: Value = serde_json::from_str(&read_line(&mut stream)?)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if answer["ok"] != true {
        let error = answer["error"].as_str().unwrap_or("refused").to_owned();
        let kind = if error == "not_found" {
            io::ErrorKind::NotFound
        } else {
            io::ErrorKind::Other
        };
        return Err(io::Error::new(kind, error));
    }
    Ok((stream, answer))
}

/// A session's output: the replay buffer and the app receiving it.
#[derive(Default)]
struct Output {
    replay: VecDeque<u8>,
    client: Option<File>,
}

impl Output {
    fn push(&mut self, bytes: &[u8]) {
        self.replay.extend(bytes);
        if self.replay.len() > MAX_REPLAY {
            // Drop whole lines from the front, so the replay starts at a line, not mid-sequence.
            let excess = self.replay.len() - MAX_REPLAY;
            let cut = self
                .replay
                .iter()
                .skip(excess)
                .position(|&byte| byte == b'\n')
                .map_or(excess, |offset| excess + offset + 1);
            self.replay.drain(..cut.min(self.replay.len()));
        }
        if let Some(client) = self.client.as_mut() {
            if client.write_all(bytes).is_err() {
                self.client = None;
            }
        }
    }
}

struct Hosted {
    session: crate::ProgramaTerminalSession,
    output: Arc<Mutex<Output>>,
}

type Sessions = Arc<Mutex<HashMap<String, Arc<Hosted>>>>;

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The host's main loop: a pipe instance per connection, a thread each; exits a minute after its
/// last session ended.
#[cfg(windows)]
pub fn serve(pipe: &str, token: &str, idle_exit: Option<Duration>) -> io::Result<()> {
    use std::os::windows::io::FromRawHandle;
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_PIPE_CONNECTED, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX,
    };
    use windows_sys::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS,
        PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
    };

    let sessions: Sessions = Arc::default();
    watch(sessions.clone(), idle_exit);
    let name: Vec<u16> = pipe.encode_utf16().chain(std::iter::once(0)).collect();
    let mut first = true;
    loop {
        // The first instance must be ours: a pipe someone else made already is refused.
        let flags = PIPE_ACCESS_DUPLEX
            | if first {
                FILE_FLAG_FIRST_PIPE_INSTANCE
            } else {
                0
            };
        let handle = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                flags,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                65536,
                65536,
                0,
                std::ptr::null(),
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            if first {
                return Err(io::Error::last_os_error());
            }
            std::thread::sleep(Duration::from_millis(100));
            continue;
        }
        first = false;
        let connected = unsafe { ConnectNamedPipe(handle, std::ptr::null_mut()) } != 0
            || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        if !connected {
            unsafe { CloseHandle(handle) };
            continue;
        }
        let stream = unsafe { File::from_raw_handle(handle as _) };
        let (sessions, token) = (sessions.clone(), token.to_owned());
        std::thread::spawn(move || {
            let _ = handle_connection(stream, &sessions, &token);
        });
    }
}

/// Drops sessions whose shell exited (closing their app's output channel), and exits the process
/// once there has been no session for a minute.
fn watch(sessions: Sessions, idle_exit: Option<Duration>) {
    std::thread::spawn(move || {
        let mut idle_since = Instant::now();
        loop {
            std::thread::sleep(Duration::from_millis(500));
            let mut map = lock(&sessions);
            map.retain(|_, hosted| !hosted.session.state.terminated.load(Ordering::Acquire));
            if !map.is_empty() {
                idle_since = Instant::now();
            } else if idle_exit.is_some_and(|limit| idle_since.elapsed() > limit) {
                std::process::exit(0);
            }
        }
    });
}

fn answer(stream: &mut File, value: Value) -> io::Result<()> {
    stream.write_all(format!("{value}\n").as_bytes())
}

fn handle_connection(mut stream: File, sessions: &Sessions, token: &str) -> io::Result<()> {
    let request: Value = serde_json::from_str(&read_line(&mut stream)?).unwrap_or(Value::Null);
    if request["token"].as_str() != Some(token) {
        return answer(&mut stream, json!({ "ok": false, "error": "unauthorized" }));
    }
    if request["version"] != 1 {
        return answer(
            &mut stream,
            json!({ "ok": false, "error": "unsupported version" }),
        );
    }
    let id = request["id"].as_str().unwrap_or_default().to_owned();
    let find = || lock(sessions).get(&id).cloned();
    match request["op"].as_str().unwrap_or_default() {
        "spawn" => {
            if find().is_some() {
                return answer(&mut stream, json!({ "ok": false, "error": "exists" }));
            }
            let output = Arc::new(Mutex::new(Output::default()));
            let tap_output = output.clone();
            let config: crate::CreateConfig =
                match serde_json::from_value(request["config"].clone()) {
                    Ok(config) => config,
                    Err(error) => {
                        return answer(
                            &mut stream,
                            json!({ "ok": false, "error": error.to_string() }),
                        )
                    }
                };
            let tap: crate::Tap = Box::new(move |bytes: &[u8]| lock(&tap_output).push(bytes));
            let session = match crate::ProgramaTerminalSession::spawn_with(config, Some(tap), true)
            {
                Ok(session) => session,
                Err(error) => return answer(&mut stream, json!({ "ok": false, "error": error })),
            };
            let hosted = Arc::new(Hosted { session, output });
            lock(sessions).insert(id, hosted.clone());
            attach(&hosted, stream)
        }
        "attach" => match find() {
            Some(hosted) => attach(&hosted, stream),
            None => answer(&mut stream, json!({ "ok": false, "error": "not_found" })),
        },
        "input" => {
            let Some(hosted) = find() else {
                return answer(&mut stream, json!({ "ok": false, "error": "not_found" }));
            };
            answer(&mut stream, json!({ "ok": true }))?;
            let mut buffer = [0u8; 65536];
            loop {
                let read = stream.read(&mut buffer)?;
                if read == 0 {
                    return Ok(());
                }
                hosted.session.type_input(&buffer[..read]);
            }
        }
        "resize" => {
            let Some(hosted) = find() else {
                return answer(&mut stream, json!({ "ok": false, "error": "not_found" }));
            };
            let number = |key: &str, fallback: u16| {
                request[key]
                    .as_u64()
                    .map_or(fallback, |value| value.min(u64::from(u16::MAX)) as u16)
            };
            hosted.session.resize_to(
                number("cols", 80),
                number("rows", 24),
                number("cell_width", 8),
                number("cell_height", 16),
            );
            answer(&mut stream, json!({ "ok": true }))
        }
        "kill" => {
            lock(sessions).remove(&id);
            answer(&mut stream, json!({ "ok": true }))
        }
        "retain" => {
            let keep: HashSet<String> = request["ids"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            let mut map = lock(sessions);
            let before = map.len();
            map.retain(|id, _| keep.contains(id));
            let killed = before - map.len();
            drop(map);
            answer(&mut stream, json!({ "ok": true, "killed": killed }))
        }
        "list" => {
            let listed: Vec<Value> = lock(sessions)
                .iter()
                .map(|(id, hosted)| json!({ "id": id, "pid": hosted.session.shell_pid, "attached": lock(&hosted.output).client.is_some() }))
                .collect();
            answer(&mut stream, json!({ "ok": true, "sessions": listed }))
        }
        _ => answer(&mut stream, json!({ "ok": false, "error": "unknown op" })),
    }
}

/// Makes `stream` the session's output channel: the answer, the past output, then live output,
/// all under the output lock so nothing is missed or sent twice. An earlier app's channel closes.
fn attach(hosted: &Hosted, mut stream: File) -> io::Result<()> {
    let mut output = lock(&hosted.output);
    let replay: Vec<u8> = output.replay.iter().copied().collect();
    answer(
        &mut stream,
        json!({ "ok": true, "pid": hosted.session.shell_pid, "replay": replay.len() }),
    )?;
    stream.write_all(&replay)?;
    output.client = Some(stream);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_replay_keeps_the_newest_output_from_a_line_start() {
        let mut output = Output::default();
        let line = "x".repeat(1023) + "\n";
        for _ in 0..(MAX_REPLAY / 1024 + 10) {
            output.push(line.as_bytes());
        }
        assert!(output.replay.len() <= MAX_REPLAY);
        assert_eq!(output.replay.front(), Some(&b'x'));
        assert_eq!(
            output.replay.len() % 1024,
            0,
            "only whole lines are dropped"
        );
    }
}
