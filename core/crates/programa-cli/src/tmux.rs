//! The tmux-compatible commands, as on macOS (CLI/CLI+TmuxCompat.swift): capture-pane,
//! display-message, find-window, set-buffer, list-buffers, paste-buffer, pipe-pane,
//! respawn-pane, set-hook and wait-for. Buffers and hooks live in the CLI, in
//! `~/.programa/tmux-compat-store.json`; wait-for signals are files in
//! `~/.programa/run/wait-for`. pipe-pane runs its command in PowerShell (pwsh, else Windows
//! PowerShell) instead of zsh.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use super::{
    call, emit, items, non_empty, parse_opts, put, str_or_empty, usage, Command, Env, Opts,
    UsageError, SURFACE_ENV, WORKSPACE_ENV,
};

pub(crate) fn params(
    command: Command,
    args: &[String],
    env: Env,
) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    let env_workspace = || env(WORKSPACE_ENV).and_then(non_empty);
    // As on macOS: --workspace, else this terminal's workspace; the surface is only named
    // explicitly, so Programa uses that workspace's focused one.
    let workspace = |opts: &Opts| opts.value("--workspace").or_else(env_workspace);
    match command {
        Command::CapturePane => {
            let opts = parse_opts(
                command,
                args,
                &["--workspace", "--surface", "--lines"],
                &["--scrollback"],
            )?;
            super::no_positionals(command, &opts)?;
            // This terminal is the default only when no --workspace names another one.
            let surface = opts.value("--surface").or_else(|| {
                opts.value("--workspace")
                    .is_none()
                    .then(|| env(SURFACE_ENV).and_then(non_empty))
                    .flatten()
            });
            let lines = match opts.value("--lines") {
                None => None,
                Some(raw) => Some(raw.parse::<u32>().ok().filter(|n| *n > 0).ok_or_else(|| {
                    UsageError("capture-pane: --lines must be greater than 0".into())
                })?),
            };
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", surface);
            if opts.has("--scrollback") || lines.is_some() {
                params.insert("scrollback".into(), json!(true));
            }
            if let Some(lines) = lines {
                params.insert("lines".into(), json!(lines));
            }
        }
        // Free text: any word starting with '-' is a flag, never part of the message.
        Command::DisplayMessage => {
            let message = words(args);
            if message.is_empty() {
                return Err(UsageError("display-message requires text".into()));
            }
            let print = args.iter().any(|arg| arg == "-p" || arg == "--print");
            params.insert("message".into(), json!(message));
            params.insert("print".into(), json!(print));
        }
        Command::FindWindow => {
            let opts = parse_opts(command, args, &[], &["--content", "--select"])?;
            let query = opts.positionals.join(" ").trim().to_owned();
            if query.is_empty() {
                return Err(UsageError("find-window requires a query".into()));
            }
            params.insert("query".into(), json!(query));
            params.insert("content".into(), json!(opts.has("--content")));
            params.insert("select".into(), json!(opts.has("--select")));
        }
        Command::SetBuffer => {
            let opts = parse_opts(command, args, &["--name"], &[])?;
            let text = opts.positionals.join(" ").trim().to_owned();
            if text.is_empty() {
                return Err(UsageError("set-buffer requires text".into()));
            }
            let name = opts
                .value("--name")
                .filter(|name| !name.trim().is_empty())
                .unwrap_or_else(|| "default".into());
            params.insert("name".into(), json!(name));
            params.insert("text".into(), json!(text));
        }
        Command::ListBuffers => {
            let opts = parse_opts(command, args, &[], &[])?;
            super::no_positionals(command, &opts)?;
        }
        Command::PasteBuffer => {
            let opts = parse_opts(command, args, &["--name", "--workspace", "--surface"], &[])?;
            super::no_positionals(command, &opts)?;
            let name = opts.value("--name").unwrap_or_else(|| "default".into());
            params.insert("name".into(), json!(name));
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", opts.value("--surface"));
        }
        Command::PipePane | Command::RespawnPane => {
            let opts = parse_opts(
                command,
                args,
                &["--command", "--workspace", "--surface"],
                &[],
            )?;
            let text = opts
                .value("--command")
                .unwrap_or_else(|| opts.positionals.join(" "))
                .trim()
                .to_owned();
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", opts.value("--surface"));
            if command == Command::PipePane {
                if text.is_empty() {
                    return Err(UsageError(
                        "pipe-pane requires --command <shell-command>".into(),
                    ));
                }
                params.insert("command".into(), json!(text));
            } else {
                // ponytail: PowerShell has no `exec`, so the default starts a fresh shell inside
                // this one (macOS execs a new login shell in its place).
                let text = if text.is_empty() {
                    "& (Get-Process -Id $PID).Path -NoLogo".to_owned()
                } else {
                    text
                };
                params.insert("text".into(), json!(format!("{text}\n")));
            }
        }
        Command::SetHook => {
            let opts = parse_opts(command, args, &["--unset"], &["--list"])?;
            if opts.has("--list") {
                params.insert("list".into(), json!(true));
            } else if let Some(event) = opts.value("--unset") {
                params.insert("unset".into(), json!(event));
            } else {
                let [event, rest @ ..] = opts.positionals.as_slice() else {
                    return Err(UsageError("set-hook requires <event> <command>".into()));
                };
                let hook = rest.join(" ").trim().to_owned();
                if hook.is_empty() {
                    return Err(UsageError("set-hook requires <event> <command>".into()));
                }
                params.insert("event".into(), json!(event));
                params.insert("command".into(), json!(hook));
            }
        }
        Command::WaitFor => {
            let opts = parse_opts(command, args, &["--timeout"], &["-S", "--signal"])?;
            let [name] = opts.positionals.as_slice() else {
                return Err(UsageError("wait-for requires one name".into()));
            };
            let timeout = match opts.value("--timeout") {
                None => 30.0,
                Some(raw) => raw
                    .parse::<f64>()
                    .ok()
                    .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
                    .ok_or_else(|| {
                        UsageError("wait-for: --timeout must be finite and nonnegative".into())
                    })?,
            };
            params.insert("name".into(), json!(name));
            params.insert(
                "signal".into(),
                json!(opts.has("-S") || opts.has("--signal")),
            );
            params.insert("timeout".into(), json!(timeout));
        }
        _ => unreachable!("not a tmux command"),
    }
    Ok(params)
}

/// The words that do not start with '-', joined and trimmed.
fn words(args: &[String]) -> String {
    args.iter()
        .filter(|arg| !arg.starts_with('-'))
        .cloned()
        .collect::<Vec<_>>()
        .join(" ")
        .trim()
        .to_owned()
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    match command {
        // As on macOS, the text and one newline.
        Command::CapturePane => format!("{}\n", str_or_empty(result, "text")),
        _ => "OK\n".to_owned(),
    }
}

/// Runs the commands that are not one request; None for those that are (capture-pane,
/// respawn-pane), which `run` sends and prints like any other.
pub(crate) fn run(
    command: Command,
    path: &str,
    params: &Map<String, Value>,
    json_output: bool,
    env: Env,
) -> Option<i32> {
    let text = |key: &str| params.get(key).and_then(Value::as_str).unwrap_or_default();
    let flag = |key: &str| params.get(key).and_then(Value::as_bool) == Some(true);
    let outcome: Result<String, String> = match command {
        Command::DisplayMessage if flag("print") => Ok(format!("{}\n", text("message"))),
        Command::DisplayMessage => call(
            path,
            "notification.create",
            json!({ "title": "Programa", "body": text("message") }),
        )
        .map(|result| {
            if json_output {
                pretty(&result)
            } else {
                format!("{}\n", text("message"))
            }
        }),
        Command::FindWindow => find_window(
            path,
            text("query"),
            flag("content"),
            flag("select"),
            json_output,
        ),
        Command::SetBuffer => update_store(env, |store| {
            store["buffers"][text("name")] = json!(text("text"));
        })
        .map(|()| "OK\n".to_owned()),
        Command::ListBuffers => {
            let store = load_store(env);
            let mut buffers: Vec<(&String, usize)> = store["buffers"]
                .as_object()
                .into_iter()
                .flatten()
                .map(|(name, value)| (name, value.as_str().unwrap_or_default().chars().count()))
                .collect();
            buffers.sort();
            Ok(if json_output {
                let rows: Vec<Value> = buffers
                    .iter()
                    .map(|(name, size)| json!({ "name": name, "size": size }))
                    .collect();
                pretty(&json!({ "buffers": rows }))
            } else if buffers.is_empty() {
                "No buffers\n".to_owned()
            } else {
                buffers
                    .iter()
                    .map(|(name, size)| format!("{name}\t{size}\n"))
                    .collect()
            })
        }
        Command::PasteBuffer => {
            let store = load_store(env);
            match store["buffers"][text("name")].as_str() {
                None => Err(format!("Buffer not found: {}", text("name"))),
                Some(buffer) => {
                    let mut request = params.clone();
                    request.remove("name");
                    request.insert("text".into(), json!(buffer));
                    call(path, "surface.send_text", Value::Object(request)).map(|result| {
                        if json_output {
                            pretty(&result)
                        } else {
                            "OK\n".to_owned()
                        }
                    })
                }
            }
        }
        Command::PipePane => pipe_pane(path, params, json_output),
        Command::SetHook => set_hook(params, json_output, env),
        Command::WaitFor => wait_for(
            path,
            text("name"),
            flag("signal"),
            params
                .get("timeout")
                .and_then(Value::as_f64)
                .unwrap_or(30.0),
            env,
        )
        .map(|()| "OK\n".to_owned()),
        _ => return None,
    };
    Some(match outcome {
        Ok(out) => {
            emit(&out);
            0
        }
        Err(message) => {
            eprintln!("Error: {message}");
            1
        }
    })
}

fn pretty(value: &Value) -> String {
    format!(
        "{}\n",
        serde_json::to_string_pretty(value).unwrap_or_default()
    )
}

/// Workspaces whose title contains the query, ignoring case, or with --content whose selected
/// terminal's screen does; --select selects the first.
fn find_window(
    path: &str,
    query: &str,
    content: bool,
    select: bool,
    json_output: bool,
) -> Result<String, String> {
    let listed = call(path, "workspace.list", json!({}))?;
    let needle = query.to_lowercase();
    let mut matches = Vec::new();
    for workspace in items(&listed, "workspaces") {
        let mut hit = str_or_empty(workspace, "title")
            .to_lowercase()
            .contains(&needle);
        if !hit && content {
            // The selected tab's screen, as macOS reads the workspace's focused surface.
            let selected = items(workspace, "surfaces")
                .iter()
                .find(|surface| surface["selected"].as_bool() == Some(true));
            if let Some(surface) = selected {
                hit = call(
                    path,
                    "surface.read_text",
                    json!({ "surface_id": surface["id"] }),
                )
                .is_ok_and(|read| str_or_empty(&read, "text").to_lowercase().contains(&needle));
            }
        }
        if hit {
            matches.push(workspace.clone());
        }
    }
    if select {
        if let Some(first) = matches.first() {
            call(
                path,
                "workspace.select",
                json!({ "workspace_id": first["id"] }),
            )?;
        }
    }
    Ok(format_matches(&matches, json_output))
}

fn format_matches(matches: &[Value], json_output: bool) -> String {
    if json_output {
        return pretty(&json!({ "matches": matches }));
    }
    if matches.is_empty() {
        return "No matches\n".to_owned();
    }
    matches
        .iter()
        .map(|workspace| {
            format!(
                "{}  \"{}\"\n",
                str_or_empty(workspace, "id"),
                str_or_empty(workspace, "title")
            )
        })
        .collect()
}

/// The surface's text with its scrollback, piped to the command's stdin.
fn pipe_pane(path: &str, params: &Map<String, Value>, json_output: bool) -> Result<String, String> {
    let mut read = Map::new();
    read.insert("scrollback".into(), json!(true));
    for key in ["workspace_id", "surface_id"] {
        if let Some(value) = params.get(key) {
            read.insert(key.into(), value.clone());
        }
    }
    let result = call(path, "surface.read_text", Value::Object(read))?;
    let command = params
        .get("command")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let (status, stdout, stderr) = run_shell(command, str_or_empty(&result, "text"))?;
    if status != 0 {
        return Err(format!("pipe-pane command failed ({status}): {stderr}"));
    }
    Ok(if json_output {
        pretty(&json!({ "ok": true, "status": status, "stdout": stdout, "stderr": stderr }))
    } else {
        format!("{stdout}OK\n")
    })
}

/// Runs the command in PowerShell 7 when it is on PATH, else Windows PowerShell, with the text on
/// its stdin (`$input` in the command, or a native command's stdin); UTF-8 both ways.
fn run_shell(command: &str, input: &str) -> Result<(i32, String, String), String> {
    let shell = if on_path("pwsh.exe") {
        "pwsh"
    } else {
        "powershell"
    };
    // The command travels base64-encoded, so no quoting reaches cmd or PowerShell.
    let script: Vec<u8> = format!("$OutputEncoding = [Text.UTF8Encoding]::new($false)\n{command}")
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    let line = format!(
        "/d /s /c \"chcp 65001 >nul & {shell} -NoLogo -NoProfile -NonInteractive -EncodedCommand {}\"",
        base64(&script)
    );
    let mut shell = std::process::Command::new("cmd");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Its own console, without a window: the UTF-8 code page never reaches the caller's console.
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        shell.raw_arg(&line).creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    shell.arg(&line);
    let mut child = shell
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|err| format!("pipe-pane: could not start PowerShell: {err}"))?;
    let mut stdin = child.stdin.take().expect("piped stdin");
    let input = input.to_owned();
    // Written beside the wait so a command that never reads stdin cannot block on a full pipe.
    let feed = std::thread::spawn(move || {
        let _ = stdin.write_all(input.as_bytes());
    });
    let output = child
        .wait_with_output()
        .map_err(|err| format!("pipe-pane: {err}"))?;
    let _ = feed.join();
    Ok((
        output.status.code().unwrap_or(1),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    ))
}

fn on_path(file: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|path| std::env::split_paths(&path).any(|dir| dir.join(file).is_file()))
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, byte)| n | u32::from(*byte) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() {
                char::from(ALPHABET[(n >> (18 - 6 * i) & 63) as usize])
            } else {
                '='
            });
        }
    }
    out
}

fn set_hook(params: &Map<String, Value>, json_output: bool, env: Env) -> Result<String, String> {
    if params.contains_key("list") {
        let store = load_store(env);
        let hooks = store["hooks"].as_object().cloned().unwrap_or_default();
        if json_output {
            return Ok(pretty(&json!({ "hooks": hooks })));
        }
        if hooks.is_empty() {
            return Ok("No hooks configured\n".to_owned());
        }
        let mut lines: Vec<String> = hooks
            .iter()
            .map(|(event, hook)| format!("{event} -> {}\n", hook.as_str().unwrap_or_default()))
            .collect();
        lines.sort();
        return Ok(lines.concat());
    }
    if let Some(event) = params.get("unset").and_then(Value::as_str) {
        update_store(env, |store| {
            if let Some(hooks) = store["hooks"].as_object_mut() {
                hooks.remove(event);
            }
        })?;
        return Ok("OK\n".to_owned());
    }
    let event = params["event"].as_str().unwrap_or_default();
    let hook = params["command"].as_str().unwrap_or_default();
    update_store(env, |store| store["hooks"][event] = json!(hook))?;
    Ok("OK\n".to_owned())
}

fn store_path(env: Env) -> PathBuf {
    usage::home(env)
        .join(".programa")
        .join("tmux-compat-store.json")
}

/// `{"buffers": {...}, "hooks": {...}}`, empty when the file is missing or unreadable.
fn load_store(env: Env) -> Value {
    let mut store = std::fs::read_to_string(store_path(env))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    for key in ["buffers", "hooks"] {
        if !store[key].is_object() {
            store[key] = json!({});
        }
    }
    store
}

/// Changes the store under an exclusive lock on `<store>.lock`, as macOS does with flock.
fn update_store(env: Env, change: impl FnOnce(&mut Value)) -> Result<(), String> {
    let path = store_path(env);
    let parent = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent).map_err(|err| format!("{}: {err}", parent.display()))?;
    let lock_path = path.with_extension("json.lock");
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)
        .map_err(|_| {
            format!(
                "Failed to open tmux compatibility state lock: {}",
                lock_path.display()
            )
        })?;
    lock.lock().map_err(|_| {
        format!(
            "Failed to lock tmux compatibility state: {}",
            lock_path.display()
        )
    })?;
    let mut store = load_store(env);
    change(&mut store);
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, serde_json::to_vec(&store).unwrap_or_default())
        .and_then(|()| std::fs::rename(&temporary, &path))
        .map_err(|err| format!("{}: {err}", path.display()))
}

/// `~/.programa/run/wait-for/<socket hash>-<name>-<name hash>.sig`: one signal per name and
/// Programa instance.
fn signal_path(env: Env, socket: &str, name: &str) -> PathBuf {
    let sanitized: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    // ponytail: the user profile is already private, so no 0700/0600 checks as on macOS.
    usage::home(env)
        .join(".programa")
        .join("run")
        .join("wait-for")
        .join(format!(
            "{:016x}-{sanitized}-{:016x}.sig",
            fnv1a(socket),
            fnv1a(name)
        ))
}

/// FNV-1a, 64 bits: a stable name hash without a crypto dependency.
fn fnv1a(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// `-S` leaves the signal; a wait consumes it, polling every 50 ms until the timeout.
fn wait_for(path: &str, name: &str, signal: bool, timeout: f64, env: Env) -> Result<(), String> {
    let file = signal_path(env, path, name);
    if signal {
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|_| "Failed to create wait-for runtime directory".to_owned())?;
        }
        return match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&file)
        {
            Ok(mut created) => created
                .write_all(b"signal\n")
                .and_then(|()| created.sync_all())
                .map_err(|_| "Failed to write wait-for signal".to_owned()),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(_) => Err("Failed to create wait-for signal".to_owned()),
        };
    }
    let deadline = Instant::now() + Duration::from_secs_f64(timeout);
    loop {
        match std::fs::remove_file(&file) {
            Ok(()) => return Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err("Failed to consume wait-for signal".to_owned()),
        }
        if Instant::now() >= deadline {
            return Err(format!("wait-for timed out waiting for '{name}'"));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parse_invocation, Invocation};

    fn call(list: &[&str]) -> Result<(String, Value), String> {
        let args: Vec<String> = list.iter().map(|s| (*s).to_owned()).collect();
        let env = |key: &str| match key {
            WORKSPACE_ENV => Some("ws-env".to_owned()),
            SURFACE_ENV => Some("s-env".to_owned()),
            _ => None,
        };
        match parse_invocation(&args, &env) {
            Ok(Invocation::Call { request, .. }) => Ok((
                request.command.method().to_owned(),
                Value::Object(request.params),
            )),
            Ok(other) => Err(format!("{other:?}")),
            Err(UsageError(message)) => Err(message),
        }
    }

    #[test]
    fn commands_take_the_macos_flags() {
        for (args, method, params) in [
            (
                &["capture-pane"][..],
                "surface.read_text",
                json!({"workspace_id": "ws-env", "surface_id": "s-env"}),
            ),
            (
                &["capture-pane", "--workspace", "w2", "--lines", "20"],
                "surface.read_text",
                json!({"workspace_id": "w2", "scrollback": true, "lines": 20}),
            ),
            (
                &["display-message", "-p", "hello", "world"],
                "notification.create",
                json!({"message": "hello world", "print": true}),
            ),
            (
                &["find-window", "--content", "build"],
                "workspace.list",
                json!({"query": "build", "content": true, "select": false}),
            ),
            (
                &["set-buffer", "--name", " ", "--", "-x", "y"],
                "",
                json!({"name": "default", "text": "-x y"}),
            ),
            (
                &["paste-buffer", "--name", "b"],
                "surface.send_text",
                json!({"name": "b", "workspace_id": "ws-env"}),
            ),
            (
                &["pipe-pane", "Select-String", "error"],
                "surface.read_text",
                json!({"workspace_id": "ws-env", "command": "Select-String error"}),
            ),
            (
                &["respawn-pane", "--surface", "s2", "--command", "npm test"],
                "surface.send_text",
                json!({"workspace_id": "ws-env", "surface_id": "s2", "text": "npm test\n"}),
            ),
            (
                &["set-hook", "after-new-window", "echo", "hi"],
                "",
                json!({"event": "after-new-window", "command": "echo hi"}),
            ),
            (&["set-hook", "--unset", "e"], "", json!({"unset": "e"})),
            (
                &["wait-for", "-S", "done"],
                "",
                json!({"name": "done", "signal": true, "timeout": 30.0}),
            ),
        ] {
            assert_eq!(call(args).unwrap(), (method.to_owned(), params), "{args:?}");
        }
        for (args, message) in [
            (
                &["capture-pane", "--lines", "0"][..],
                "capture-pane: --lines must be greater than 0",
            ),
            (&["display-message", "-p"], "display-message requires text"),
            (&["set-buffer"], "set-buffer requires text"),
            (
                &["pipe-pane"],
                "pipe-pane requires --command <shell-command>",
            ),
            (&["set-hook", "e"], "set-hook requires <event> <command>"),
            (&["wait-for", "a", "b"], "wait-for requires one name"),
            (
                &["wait-for", "a", "--timeout", "-1"],
                "wait-for: --timeout must be finite and nonnegative",
            ),
        ] {
            assert_eq!(call(args).unwrap_err(), message, "{args:?}");
        }
    }

    #[test]
    fn buffers_hooks_and_signals_live_in_the_profile() {
        let home = std::env::temp_dir().join(format!("programa-tmux-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let profile = home.display().to_string();
        let env = move |key: &str| (key == "USERPROFILE").then(|| profile.clone());
        update_store(&env, |store| store["buffers"]["default"] = json!("héllo")).unwrap();
        update_store(&env, |store| store["hooks"]["e"] = json!("echo")).unwrap();
        let store = load_store(&env);
        assert_eq!(store["buffers"]["default"], "héllo");
        assert_eq!(store["hooks"]["e"], "echo");

        // A signal set before the wait is consumed by it; a second wait times out.
        wait_for("pipe-a", "build done", true, 0.0, &env).unwrap();
        wait_for("pipe-a", "build done", true, 0.0, &env).unwrap();
        assert!(signal_path(&env, "pipe-a", "build done")
            .to_string_lossy()
            .contains("-build_done-"));
        assert_ne!(
            signal_path(&env, "pipe-a", "x"),
            signal_path(&env, "pipe-b", "x")
        );
        wait_for("pipe-a", "build done", false, 1.0, &env).unwrap();
        assert_eq!(
            wait_for("pipe-a", "build done", false, 0.1, &env).unwrap_err(),
            "wait-for timed out waiting for 'build done'"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn output_matches_macos() {
        assert_eq!(
            render(Command::CapturePane, &json!({"text": "a\nb"})),
            "a\nb\n"
        );
        let matches = [json!({"id": "w1", "title": "build"})];
        assert_eq!(format_matches(&matches, false), "w1  \"build\"\n");
        assert_eq!(format_matches(&[], false), "No matches\n");
        assert_eq!(base64(b"Ma"), "TWE=");
        assert_eq!(base64(b"Man"), "TWFu");
        assert_eq!(base64(b"M"), "TQ==");
    }
}
