//! Agent session records and `programa usage`, as on macOS (docs/agent-usage.md).
//!
//! `claude-hook` keeps one record per live Claude Code session in
//! `~/.programa/claude-hook-sessions.json` (workspace, surface, directory and transcript), dropped
//! 7 days after its last update. `session-end` moves it to `~/.programa/agent-last-sessions.json`,
//! which keeps at most one ended session per pane and agent, 50 entries, for 7 days.
//!
//! `programa usage` sums what each recorded session's transcript says it used: every assistant
//! `message.usage`, each `message.id` counted once with its largest total, the session's subagent
//! transcripts included and `<synthetic>` messages skipped.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

use crate::Env;

const MAX_AGE_SECONDS: f64 = 7.0 * 24.0 * 3600.0;
const MAX_ENDED: usize = 50;

fn home(env: Env) -> PathBuf {
    env("USERPROFILE")
        .or_else(|| env("HOME"))
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// `variable` when set (a leading `~` is the home folder), else `~/.programa/<file>`.
fn store_path(env: Env, variable: &str, file: &str) -> PathBuf {
    match env(variable).map(|value| value.trim().to_owned()) {
        Some(path) if path == "~" => home(env),
        Some(path) if path.starts_with("~/") || path.starts_with("~\\") => {
            home(env).join(&path[2..])
        }
        Some(path) if !path.is_empty() => PathBuf::from(path),
        _ => home(env).join(".programa").join(file),
    }
}

/// The agents whose hooks keep session records.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Agent {
    Claude,
    Codex,
}

impl Agent {
    pub fn provider(self) -> &'static str {
        match self {
            Agent::Claude => "claude-code",
            Agent::Codex => "codex",
        }
    }

    /// Codex's always lives in `~/.programa/codex-hook-sessions.json`, as on macOS; `USERPROFILE`
    /// moves it with the home folder.
    fn store(self, env: Env) -> PathBuf {
        match self {
            Agent::Claude => live_store(env),
            Agent::Codex => home(env).join(".programa").join("codex-hook-sessions.json"),
        }
    }
}

fn live_store(env: Env) -> PathBuf {
    store_path(
        env,
        "PROGRAMA_CLAUDE_HOOK_STATE_PATH",
        "claude-hook-sessions.json",
    )
}

fn ended_store(env: Env) -> PathBuf {
    store_path(
        env,
        "PROGRAMA_AGENT_LAST_SESSIONS_PATH",
        "agent-last-sessions.json",
    )
}

// ---- Records

/// What the hook remembers for `event`; nothing outside a Programa terminal or without a session id.
pub fn record_hook(agent: Agent, event: &str, input: &str, env: Env, now: f64) {
    let (Some(surface), Some(workspace)) = (
        env("PROGRAMA_SURFACE_ID").filter(|id| !id.is_empty()),
        env("PROGRAMA_WORKSPACE_ID").filter(|id| !id.is_empty()),
    ) else {
        return;
    };
    let input: Value = serde_json::from_str(input).unwrap_or(Value::Null);
    let text = |key: &str| {
        input
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    let Some(session) = text("session_id") else {
        return;
    };
    let live = agent.store(env);
    let asking = input["tool_name"].as_str() == Some("AskUserQuestion");
    match event {
        "session-start" | "prompt-submit" | "stop" | "notification" => {
            let _ = update_live(&live, now, |sessions| {
                let record = sessions
                    .entry(session.clone())
                    .or_insert_with(|| json!({ "sessionId": session, "startedAt": now }));
                if let Some(record) = record.as_object_mut() {
                    record.insert("workspaceId".into(), json!(workspace));
                    record.insert("surfaceId".into(), json!(surface));
                    for (key, field) in [("cwd", "cwd"), ("transcriptPath", "transcript_path")] {
                        if let Some(value) = text(field) {
                            record.insert(key.into(), json!(value));
                        }
                    }
                    record.insert("updatedAt".into(), json!(now));
                }
                None::<()>
            });
        }
        // AskUserQuestion opens: its Notification arrives as a generic permission prompt, so the
        // question is kept until Claude moves on (another tool, its request, or a finished tool).
        "pre-tool-use" if asking => {
            let question = crate::hook::describe_question(&input);
            let _ = update_live(&live, now, |sessions| {
                let record = sessions
                    .entry(session.clone())
                    .or_insert_with(|| json!({ "sessionId": session, "startedAt": now, "workspaceId": workspace, "surfaceId": surface }));
                if let Some(record) = record.as_object_mut() {
                    record.insert("pendingQuestion".into(), json!(question));
                    record.insert("updatedAt".into(), json!(now));
                }
                None::<()>
            });
        }
        "pre-tool-use" | "post-tool-use" | "permission-request"
            if !(asking && event == "permission-request") =>
        {
            // Most tools have no question to clear: read first, lock only when there is one.
            if pending_question(&session, env).is_some() {
                let _ = update_live(&live, now, |sessions| {
                    sessions
                        .get_mut(&session)
                        .and_then(Value::as_object_mut)
                        .map(|record| record.remove("pendingQuestion"));
                    None::<()>
                });
            }
        }
        "session-end" => {
            let consumed = update_live(&live, now, |sessions| sessions.remove(&session))
                .ok()
                .flatten()
                .unwrap_or(Value::Null);
            // The record's directory wins: Claude Code finds a session by id from where it started.
            let field = |key: &str, fallback: Option<String>| {
                consumed
                    .get(key)
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                    .map(str::to_owned)
                    .or(fallback)
            };
            let mut entry = Map::new();
            entry.insert("provider".into(), json!(agent.provider()));
            entry.insert("sessionId".into(), json!(session));
            for (key, value) in [
                ("cwd", field("cwd", text("cwd"))),
                ("workspaceId", field("workspaceId", Some(workspace.clone()))),
                ("surfaceId", field("surfaceId", Some(surface.clone()))),
                (
                    "transcriptPath",
                    field("transcriptPath", text("transcript_path")),
                ),
            ] {
                if let Some(value) = value {
                    entry.insert(key.into(), json!(value));
                }
            }
            entry.insert("endedAt".into(), json!(now));
            let _ = record_ended(&ended_store(env), Value::Object(entry), now);
        }
        _ => {}
    }
}

/// The session's open AskUserQuestion, read without the lock (writers replace the file whole).
pub fn pending_question(session: &str, env: Env) -> Option<String> {
    let text = fs::read_to_string(live_store(env)).ok()?;
    let state: Value = serde_json::from_str(&text).ok()?;
    state["sessions"][session]["pendingQuestion"]
        .as_str()
        .map(str::to_owned)
}

/// Runs `body` on the live sessions under the store's lock, saving when they changed. An absent
/// file is an empty store; an unreadable one is kept as `.corrupt` rather than overwritten blind.
fn update_live<T>(
    path: &Path,
    now: f64,
    body: impl FnOnce(&mut Map<String, Value>) -> Option<T>,
) -> std::io::Result<Option<T>> {
    locked(path, || {
        let original = match fs::read_to_string(path) {
            Ok(text) => match serde_json::from_str::<Value>(&text) {
                Ok(value) if value.get("sessions").is_some_and(Value::is_object) => value,
                _ => {
                    let _ = fs::rename(path, path.with_extension("json.corrupt"));
                    json!({ "version": 1, "sessions": {} })
                }
            },
            Err(_) => json!({ "version": 1, "sessions": {} }),
        };
        let mut sessions = original["sessions"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        sessions.retain(|_, record| number(record, "updatedAt") >= now - MAX_AGE_SECONDS);
        let result = body(&mut sessions);
        let state = json!({ "version": 1, "sessions": sessions });
        if state != original {
            write_atomic(path, &state)?;
        }
        Ok(result)
    })?
}

/// Newest first, one entry per pane and agent, at most 50, none older than 7 days. Two panes in
/// one directory keep each other's sessions. An unreadable file is rebuilt: it only lists ids.
fn record_ended(path: &Path, entry: Value, now: f64) -> std::io::Result<()> {
    locked(path, || {
        let surface = entry.get("surfaceId").cloned();
        let id = entry.get("sessionId").cloned();
        let provider = entry.get("provider").cloned();
        let mut sessions = vec![entry];
        sessions.extend(read_ended(path).into_iter().filter(|existing| {
            existing.get("sessionId") != id.as_ref()
                && (surface.is_none()
                    || existing.get("surfaceId") != surface.as_ref()
                    || existing.get("provider") != provider.as_ref())
        }));
        let mut sessions = pruned(sessions, now);
        sessions.truncate(MAX_ENDED);
        write_atomic(path, &json!({ "version": 1, "sessions": sessions }))
    })?
}

fn read_ended(path: &Path) -> Vec<Value> {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.get("sessions").and_then(Value::as_array).cloned())
        .unwrap_or_default()
}

fn pruned(mut sessions: Vec<Value>, now: f64) -> Vec<Value> {
    sessions.retain(|session| number(session, "endedAt") >= now - MAX_AGE_SECONDS);
    sessions.sort_by(|a, b| number(b, "endedAt").total_cmp(&number(a, "endedAt")));
    sessions
}

fn number(value: &Value, key: &str) -> f64 {
    value.get(key).and_then(Value::as_f64).unwrap_or(0.0)
}

/// Holds `<path>.lock` while `body` runs, so two hooks never lose each other's update.
fn locked<T>(path: &Path, body: impl FnOnce() -> T) -> std::io::Result<T> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut lock_name = path.as_os_str().to_owned();
    lock_name.push(".lock");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(PathBuf::from(lock_name))?;
    lock.lock()?;
    let result = body();
    let _ = lock.unlock();
    Ok(result)
}

/// Written whole, then moved over the old file, so a reader never sees half of it.
fn write_atomic(path: &Path, value: &Value) -> std::io::Result<()> {
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(".tmp");
    let temporary = PathBuf::from(temporary);
    fs::write(
        &temporary,
        serde_json::to_string_pretty(value).unwrap_or_default(),
    )?;
    fs::rename(&temporary, path)
}

// ---- Sessions and tokens

#[derive(Debug, Clone)]
pub struct Session {
    pub agent: Agent,
    pub session_id: String,
    pub workspace_id: Option<String>,
    pub live: bool,
    pub transcript: Option<String>,
    pub updated: f64,
}

/// Live records first; an ended record of the same session only fills the gap.
pub fn known_sessions(env: Env, now: f64) -> Vec<Session> {
    let text = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    let mut sessions: Vec<Session> = Vec::new();
    for agent in [Agent::Claude, Agent::Codex] {
        let live = fs::read_to_string(agent.store(env))
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .and_then(|value| value.get("sessions").and_then(Value::as_object).cloned())
            .unwrap_or_default();
        for (id, record) in live {
            if number(&record, "updatedAt") >= now - MAX_AGE_SECONDS {
                sessions.push(Session {
                    agent,
                    session_id: text(&record, "sessionId").unwrap_or(id),
                    workspace_id: text(&record, "workspaceId"),
                    live: true,
                    transcript: text(&record, "transcriptPath"),
                    updated: number(&record, "updatedAt"),
                });
            }
        }
    }
    for entry in pruned(read_ended(&ended_store(env)), now) {
        let Some(id) = text(&entry, "sessionId") else {
            continue;
        };
        let agent = match text(&entry, "provider").as_deref() {
            Some("claude-code") => Agent::Claude,
            Some("codex") => Agent::Codex,
            _ => continue,
        };
        if sessions
            .iter()
            .any(|session| session.agent == agent && session.session_id == id)
        {
            continue;
        }
        sessions.push(Session {
            agent,
            session_id: id,
            workspace_id: text(&entry, "workspaceId"),
            live: false,
            transcript: text(&entry, "transcriptPath"),
            updated: number(&entry, "endedAt"),
        });
    }
    sessions
}

/// Input (not cached), output, cache read and cache write.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Tokens {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
}

impl Tokens {
    fn total(self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write
    }

    fn add(self, other: Tokens) -> Tokens {
        Tokens {
            input: self.input + other.input,
            output: self.output + other.output,
            cache_read: self.cache_read + other.cache_read,
            cache_write: self.cache_write + other.cache_write,
        }
    }

    fn json(self) -> Value {
        json!({
            "input": self.input, "output": self.output, "cache_read": self.cache_read,
            "cache_write": self.cache_write, "total": self.total(),
        })
    }
}

/// None when the main transcript cannot be opened; a subagent file that cannot is skipped.
pub fn claude_tokens(transcript: &Path) -> Option<Tokens> {
    let mut per_message: HashMap<String, Tokens> = HashMap::new();
    let mut files = vec![transcript.to_path_buf()];
    files.extend(subagent_transcripts(transcript));
    for (index, path) in files.iter().enumerate() {
        let Ok(file) = File::open(path) else {
            if index == 0 {
                return None;
            }
            continue;
        };
        let mut reader = BufReader::new(file);
        let mut line = Vec::new();
        loop {
            line.clear();
            match reader.read_until(b'\n', &mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            if !line.windows(7).any(|window| window == b"\"usage\"") {
                continue;
            }
            let Ok(object) = serde_json::from_slice::<Value>(&line) else {
                continue;
            };
            let message = &object["message"];
            let (Some(usage), Some(id)) = (message["usage"].as_object(), message["id"].as_str())
            else {
                continue;
            };
            if message["model"].as_str() == Some("<synthetic>") {
                continue;
            }
            let count = |key: &str| {
                usage
                    .get(key)
                    .and_then(|value| value.as_i64().or_else(|| value.as_f64().map(|n| n as i64)))
                    .unwrap_or(0)
            };
            let counted = Tokens {
                input: count("input_tokens"),
                output: count("output_tokens"),
                cache_read: count("cache_read_input_tokens"),
                cache_write: count("cache_creation_input_tokens"),
            };
            if counted.total() > per_message.get(id).map_or(-1, |tokens| tokens.total()) {
                per_message.insert(id.to_owned(), counted);
            }
        }
    }
    Some(
        per_message
            .into_values()
            .fold(Tokens::default(), Tokens::add),
    )
}

/// `<dir>/<session>.jsonl` keeps its subagents in `<dir>/<session>/subagents/**/agent-*.jsonl`.
fn subagent_transcripts(transcript: &Path) -> Vec<PathBuf> {
    let name = transcript.to_string_lossy();
    let Some(stem) = name.strip_suffix(".jsonl") else {
        return Vec::new();
    };
    let mut found = Vec::new();
    let mut pending = vec![PathBuf::from(format!("{stem}/subagents"))];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = entry.file_name().to_string_lossy().into_owned();
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                pending.push(path);
            } else if file_name.starts_with("agent-") && file_name.ends_with(".jsonl") {
                found.push(path);
            }
        }
    }
    found.sort();
    found
}

/// Codex counts cached tokens inside `input_tokens`: each `token_usage_record` response once, or
/// with none, the largest running `token_count` total (docs/agent-usage.md).
pub fn codex_tokens(transcript: &Path) -> Option<Tokens> {
    let mut reader = BufReader::new(File::open(transcript).ok()?);
    let mut per_response: HashMap<String, Tokens> = HashMap::new();
    let mut largest: Option<(i64, Tokens)> = None;
    let count = |usage: &Value, key: &str| {
        usage[key]
            .as_i64()
            .or_else(|| usage[key].as_f64().map(|n| n as i64))
            .unwrap_or(0)
    };
    let tokens = |usage: &Value| {
        let cached = count(usage, "cached_input_tokens");
        Tokens {
            input: (count(usage, "input_tokens") - cached).max(0),
            output: count(usage, "output_tokens"),
            cache_read: cached,
            cache_write: count(usage, "cache_write_input_tokens"),
        }
    };
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let has = |needle: &[u8]| line.windows(needle.len()).any(|window| window == needle);
        if !has(b"token_usage_record") && !has(b"token_count") {
            continue;
        }
        let Ok(object) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        let payload = &object["payload"];
        if object["type"] == "token_usage_record" {
            if let (Some(id), true) = (
                payload["response_id"].as_str(),
                payload["usage"].is_object(),
            ) {
                per_response.insert(id.to_owned(), tokens(&payload["usage"]));
            }
        } else if payload["type"] == "token_count"
            && payload["info"]["total_token_usage"].is_object()
        {
            let running = &payload["info"]["total_token_usage"];
            let total = count(running, "total_tokens");
            if largest.is_none_or(|(most, _)| total > most) {
                largest = Some((total, tokens(running)));
            }
        }
    }
    Some(if per_response.is_empty() {
        largest.map(|(_, tokens)| tokens).unwrap_or_default()
    } else {
        per_response
            .into_values()
            .fold(Tokens::default(), Tokens::add)
    })
}

/// For a session recorded without a transcript path: Claude Code names the file after the session,
/// in one of `$CLAUDE_CONFIG_DIR` (default `~/.claude`) `projects` folders; Codex ends its rollout
/// file name with it, under `$CODEX_HOME` (default `~/.codex`) `sessions`.
fn derived_transcript(agent: Agent, session_id: &str, env: Env) -> Option<PathBuf> {
    if session_id.is_empty()
        || !session_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return None;
    }
    let folder = |variable: &str, fallback: &str| {
        env(variable)
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home(env).join(fallback))
    };
    if agent == Agent::Codex {
        let suffix = format!("-{session_id}.jsonl");
        let mut pending = vec![folder("CODEX_HOME", ".codex").join("sessions")];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(&directory).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    pending.push(path);
                } else if path.to_string_lossy().ends_with(&suffix) {
                    return Some(path);
                }
            }
        }
        return None;
    }
    fs::read_dir(folder("CLAUDE_CONFIG_DIR", ".claude").join("projects"))
        .ok()?
        .flatten()
        .map(|entry| entry.path().join(format!("{session_id}.jsonl")))
        .find(|path| path.is_file())
}

// ---- The report

/// `programa usage --json`: the open workspaces (id, title) in window order first, then the
/// closed ones a session still names, then sessions without a workspace.
pub fn report(open: &[(String, String)], sessions: &[Session], env: Env) -> Value {
    let mut skipped = Vec::new();
    let mut rows: HashMap<String, Vec<(&Session, Tokens)>> = HashMap::new();
    let mut spelled: HashMap<String, String> = HashMap::new();
    for session in sessions {
        let path = session
            .transcript
            .as_ref()
            .map(PathBuf::from)
            .or_else(|| derived_transcript(session.agent, &session.session_id, env));
        let counted = match session.agent {
            Agent::Claude => path.as_deref().and_then(claude_tokens),
            Agent::Codex => path.as_deref().and_then(codex_tokens),
        };
        let Some(tokens) = counted else {
            skipped.push(
                json!({ "provider": session.agent.provider(), "session_id": session.session_id }),
            );
            continue;
        };
        let key = session
            .workspace_id
            .clone()
            .unwrap_or_default()
            .to_lowercase();
        if let Some(id) = &session.workspace_id {
            spelled.insert(key.clone(), id.clone());
        }
        rows.entry(key).or_default().push((session, tokens));
    }
    let open_keys: Vec<String> = open.iter().map(|(id, _)| id.to_lowercase()).collect();
    let mut closed: Vec<String> = rows
        .keys()
        .filter(|key| !open_keys.contains(key))
        .cloned()
        .collect();
    closed.sort();
    let mut grand = Tokens::default();
    let mut workspaces = Vec::new();
    for key in open_keys.iter().chain(closed.iter()) {
        let Some(group) = rows.get_mut(key) else {
            continue;
        };
        group.sort_by(|(a, _), (b, _)| {
            (b.live, b.updated)
                .partial_cmp(&(a.live, a.updated))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let total = group
            .iter()
            .fold(Tokens::default(), |sum, (_, tokens)| sum.add(*tokens));
        grand = grand.add(total);
        let mut entry = Map::new();
        if let Some((id, title)) = open.iter().find(|(id, _)| id.to_lowercase() == *key) {
            entry.insert("id".into(), json!(id));
            entry.insert("title".into(), json!(title));
            entry.insert("open".into(), json!(true));
        } else {
            if !key.is_empty() {
                entry.insert("id".into(), json!(spelled.get(key).unwrap_or(key)));
            }
            entry.insert("open".into(), json!(false));
        }
        entry.insert(
            "sessions".into(),
            json!(group
                .iter()
                .map(|(session, tokens)| json!({
                    "provider": session.agent.provider(),
                    "session_id": session.session_id,
                    "state": if session.live { "live" } else { "ended" },
                    "tokens": tokens.json(),
                }))
                .collect::<Vec<_>>()),
        );
        entry.insert("tokens".into(), total.json());
        workspaces.push(Value::Object(entry));
    }
    json!({ "workspaces": workspaces, "tokens": grand.json(), "skipped": skipped })
}

/// The text form: a table per workspace, totals, and how many sessions were skipped.
pub fn format_report(report: &Value) -> String {
    let columns = |tokens: &Value| -> Vec<String> {
        ["input", "output", "cache_read", "cache_write"]
            .iter()
            .map(|key| grouped(tokens[key].as_i64().unwrap_or(0)))
            .collect()
    };
    let mut out = String::new();
    let workspaces = report["workspaces"].as_array().cloned().unwrap_or_default();
    if workspaces.is_empty() {
        out.push_str("No agent token usage recorded\n");
    }
    for workspace in &workspaces {
        let id = workspace["id"].as_str();
        let handle = match (workspace["open"].as_bool() == Some(true), id) {
            (true, Some(id)) => id.to_owned(),
            (false, Some(id)) => format!("{id} (closed)"),
            _ => "No workspace".to_owned(),
        };
        match workspace["title"]
            .as_str()
            .filter(|title| !title.is_empty())
        {
            Some(title) => out.push_str(&format!("{handle}  {title}\n")),
            None => out.push_str(&format!("{handle}\n")),
        }
        let mut lines: Vec<Vec<String>> = vec![[
            "AGENT",
            "SESSION",
            "STATE",
            "INPUT",
            "OUTPUT",
            "CACHE READ",
            "CACHE WRITE",
        ]
        .iter()
        .map(|cell| (*cell).to_owned())
        .collect()];
        let sessions = workspace["sessions"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        for session in &sessions {
            let mut line = vec![
                session["provider"].as_str().unwrap_or_default().to_owned(),
                session["session_id"]
                    .as_str()
                    .unwrap_or_default()
                    .to_owned(),
                session["state"].as_str().unwrap_or_default().to_owned(),
            ];
            line.extend(columns(&session["tokens"]));
            lines.push(line);
        }
        if sessions.len() > 1 {
            let mut line = vec!["total".to_owned(), String::new(), String::new()];
            line.extend(columns(&workspace["tokens"]));
            lines.push(line);
        }
        let widths: Vec<usize> = (0..lines[0].len())
            .map(|column| {
                lines
                    .iter()
                    .map(|line| line[column].chars().count())
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        for line in &lines {
            let cells: Vec<String> = line
                .iter()
                .enumerate()
                .map(|(column, cell)| {
                    let pad = " ".repeat(widths[column] - cell.chars().count());
                    if column < 3 {
                        format!("{cell}{pad}")
                    } else {
                        format!("{pad}{cell}")
                    }
                })
                .collect();
            out.push_str(&format!("  {}\n", cells.join("  ").trim_end()));
        }
    }
    if workspaces.len() > 1 {
        let totals = columns(&report["tokens"]);
        out.push_str(&format!(
            "All workspaces: input {}, output {}, cache read {}, cache write {}\n",
            totals[0], totals[1], totals[2], totals[3]
        ));
    }
    let skipped = report["skipped"].as_array().map_or(0, Vec::len);
    if skipped > 0 {
        out.push_str(&format!(
            "Skipped {skipped} session{} with a missing or unreadable transcript\n",
            if skipped == 1 { "" } else { "s" }
        ));
    }
    out
}

fn grouped(value: i64) -> String {
    let digits = value.to_string();
    let mut out = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("programa-usage-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn line(id: &str, input: i64, output: i64, read: i64, write: i64) -> String {
        json!({ "type": "assistant", "message": { "id": id, "model": "claude-x", "usage": {
            "input_tokens": input, "output_tokens": output,
            "cache_read_input_tokens": read, "cache_creation_input_tokens": write } } })
        .to_string()
    }

    #[test]
    fn counts_each_message_once_with_subagents_and_without_synthetic_lines() {
        let dir = temp("tokens");
        let main = dir.join("s1.jsonl");
        let synthetic =
            r#"{"message":{"id":"m9","model":"<synthetic>","usage":{"input_tokens":999}}}"#;
        // One response is written once per content block, the repeats with the same or zero usage.
        fs::write(
            &main,
            [
                line("m1", 10, 5, 100, 20),
                line("m1", 0, 0, 0, 0),
                line("m1", 10, 5, 100, 20),
                line("m2", 1, 2, 3, 4),
                synthetic.to_owned(),
                "not json \"usage\"".to_owned(),
            ]
            .join("\n"),
        )
        .unwrap();
        fs::create_dir_all(dir.join("s1").join("subagents").join("nested")).unwrap();
        fs::write(
            dir.join("s1/subagents/nested/agent-a.jsonl"),
            [line("m3", 7, 0, 0, 0), line("m2", 1, 2, 3, 4)].join("\n"),
        )
        .unwrap();
        fs::write(
            dir.join("s1/subagents/notes.jsonl"),
            line("m4", 1000, 0, 0, 0),
        )
        .unwrap();
        assert_eq!(
            claude_tokens(&main),
            Some(Tokens {
                input: 18,
                output: 7,
                cache_read: 103,
                cache_write: 24
            })
        );
        assert_eq!(claude_tokens(&dir.join("missing.jsonl")), None);
    }

    #[test]
    fn the_hook_records_live_and_ended_sessions() {
        let dir = temp("records");
        let live = dir.join("live.json");
        let ended = dir.join("ended.json");
        let (live_path, ended_path) = (
            live.to_string_lossy().into_owned(),
            ended.to_string_lossy().into_owned(),
        );
        let env = |surface: &'static str| {
            let (live_path, ended_path) = (live_path.clone(), ended_path.clone());
            move |key: &str| match key {
                "PROGRAMA_SURFACE_ID" => Some(surface.to_owned()),
                "PROGRAMA_WORKSPACE_ID" => Some("workspace-1".to_owned()),
                "PROGRAMA_CLAUDE_HOOK_STATE_PATH" => Some(live_path.clone()),
                "PROGRAMA_AGENT_LAST_SESSIONS_PATH" => Some(ended_path.clone()),
                _ => None,
            }
        };
        let pane_a = env("surface-a");
        record_hook(
            Agent::Claude,
            "session-start",
            r#"{"session_id":"s1","cwd":"C:\\src","transcript_path":"C:\\t\\s1.jsonl"}"#,
            &pane_a,
            1000.0,
        );
        record_hook(
            Agent::Claude,
            "stop",
            r#"{"session_id":"s1"}"#,
            &pane_a,
            1010.0,
        );
        record_hook(
            Agent::Claude,
            "session-start",
            r#"{"session_id":"s2"}"#,
            &pane_a,
            1020.0,
        );
        let sessions = known_sessions(&pane_a, 1030.0);
        assert_eq!(sessions.len(), 2);
        let s1 = sessions
            .iter()
            .find(|session| session.session_id == "s1")
            .unwrap();
        assert_eq!(
            (s1.live, s1.transcript.as_deref(), s1.updated),
            (true, Some("C:\\t\\s1.jsonl"), 1010.0)
        );

        record_hook(
            Agent::Claude,
            "session-end",
            r#"{"session_id":"s1"}"#,
            &pane_a,
            1040.0,
        );
        let ended_s1 = read_ended(&ended);
        assert_eq!(ended_s1[0]["cwd"], "C:\\src", "the start directory is kept");
        assert_eq!(ended_s1[0]["transcriptPath"], "C:\\t\\s1.jsonl");
        // A newer session ended in the same pane replaces it; another pane's stays.
        record_hook(
            Agent::Claude,
            "session-end",
            r#"{"session_id":"s2"}"#,
            &pane_a,
            1050.0,
        );
        record_hook(
            Agent::Claude,
            "session-end",
            r#"{"session_id":"s3"}"#,
            &env("surface-b"),
            1060.0,
        );
        let ids: Vec<_> = read_ended(&ended)
            .iter()
            .map(|entry| entry["sessionId"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(ids, ["s3", "s2"]);
        let known = known_sessions(&pane_a, 1070.0);
        assert!(known.iter().all(|session| !session.live));
        // A week later every record is gone.
        assert!(known_sessions(&pane_a, 1060.0 + MAX_AGE_SECONDS + 1.0).is_empty());
        // Outside Programa, nothing is written.
        let outside = |_: &str| None;
        record_hook(
            Agent::Claude,
            "session-start",
            r#"{"session_id":"s9"}"#,
            &outside,
            1.0,
        );
    }

    #[test]
    fn codex_sessions_are_recorded_and_counted_from_their_rollout() {
        let dir = temp("codex");
        let rollout = dir.join("sessions").join("2026").join("11").join("19");
        fs::create_dir_all(&rollout).unwrap();
        let usage = |input: i64, cached: i64, output: i64| json!({ "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "cache_write_input_tokens": 0, "total_tokens": input + output });
        let lines = [
            json!({ "type": "session_meta", "payload": { "id": "thr_1" } }).to_string(),
            json!({ "type": "token_usage_record", "payload": { "response_id": "r1", "usage": usage(1000, 800, 50) } }).to_string(),
            json!({ "type": "token_usage_record", "payload": { "response_id": "r1", "usage": usage(1000, 800, 50) } }).to_string(),
            json!({ "type": "token_usage_record", "payload": { "response_id": "r2", "usage": usage(300, 0, 20) } }).to_string(),
            json!({ "type": "event_msg", "payload": { "type": "token_count", "info": { "total_token_usage": usage(9999, 0, 0) } } }).to_string(),
        ];
        fs::write(
            rollout.join("rollout-2026-11-19T10-00-00-thr_1.jsonl"),
            lines.join("\n"),
        )
        .unwrap();
        // Records win over the running totals; input leaves out the cached part.
        assert_eq!(
            codex_tokens(&rollout.join("rollout-2026-11-19T10-00-00-thr_1.jsonl")),
            Some(Tokens {
                input: 500,
                output: 70,
                cache_read: 800,
                cache_write: 0
            })
        );
        let only_counts = rollout.join("counts.jsonl");
        fs::write(
            &only_counts,
            [
                lines[4].clone(),
                json!({ "type": "event_msg", "payload": { "type": "token_count", "info": null } })
                    .to_string(),
            ]
            .join("\n"),
        )
        .unwrap();
        assert_eq!(
            codex_tokens(&only_counts).map(|tokens| tokens.input),
            Some(9999)
        );

        let home = dir.to_string_lossy().into_owned();
        let codex_home = dir.to_string_lossy().into_owned();
        let env = move |key: &str| match key {
            "PROGRAMA_SURFACE_ID" => Some("surface-a".to_owned()),
            "PROGRAMA_WORKSPACE_ID" => Some("workspace-1".to_owned()),
            "USERPROFILE" => Some(home.clone()),
            "CODEX_HOME" => Some(codex_home.clone()),
            _ => None,
        };
        // A session without a transcript path is found by its id under CODEX_HOME.
        record_hook(
            Agent::Codex,
            "session-start",
            r#"{"session_id":"thr_1"}"#,
            &env,
            100.0,
        );
        assert!(dir
            .join(".programa")
            .join("codex-hook-sessions.json")
            .is_file());
        let sessions = known_sessions(&env, 110.0);
        assert_eq!((sessions.len(), sessions[0].agent), (1, Agent::Codex));
        let report = report(
            &[("workspace-1".to_owned(), "api".to_owned())],
            &sessions,
            &env,
        );
        assert_eq!(report["workspaces"][0]["sessions"][0]["provider"], "codex");
        assert_eq!(report["tokens"]["cache_read"], 800);
        record_hook(
            Agent::Codex,
            "session-end",
            r#"{"session_id":"thr_1"}"#,
            &env,
            120.0,
        );
        let ended = known_sessions(&env, 130.0);
        assert_eq!(
            (ended.len(), ended[0].live, ended[0].agent),
            (1, false, Agent::Codex)
        );
    }

    #[test]
    fn an_open_question_is_kept_until_claude_moves_on() {
        let dir = temp("question");
        let live = dir.join("live.json").to_string_lossy().into_owned();
        let env = move |key: &str| match key {
            "PROGRAMA_SURFACE_ID" => Some("surface-a".to_owned()),
            "PROGRAMA_WORKSPACE_ID" => Some("workspace-1".to_owned()),
            "PROGRAMA_CLAUDE_HOOK_STATE_PATH" => Some(live.clone()),
            _ => None,
        };
        let ask = r#"{"session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which branch?","options":[{"label":"main"}]}]}}"#;
        record_hook(Agent::Claude, "pre-tool-use", ask, &env, 10.0);
        assert_eq!(
            pending_question("s1", &env).as_deref(),
            Some("Which branch?\n[main]")
        );
        // Its own permission request keeps it; another tool's request or a finished tool ends it.
        record_hook(Agent::Claude, "permission-request", ask, &env, 11.0);
        assert!(pending_question("s1", &env).is_some());
        record_hook(
            Agent::Claude,
            "post-tool-use",
            r#"{"session_id":"s1","tool_name":"AskUserQuestion"}"#,
            &env,
            12.0,
        );
        assert!(pending_question("s1", &env).is_none());
        record_hook(Agent::Claude, "pre-tool-use", ask, &env, 13.0);
        record_hook(
            Agent::Claude,
            "pre-tool-use",
            r#"{"session_id":"s1","tool_name":"Bash"}"#,
            &env,
            14.0,
        );
        assert!(pending_question("s1", &env).is_none());
    }

    #[test]
    fn the_report_groups_by_workspace_and_formats_a_table() {
        let dir = temp("report");
        let transcript = |name: &str, lines: &[String]| {
            let path = dir.join(name);
            fs::write(&path, lines.join("\n")).unwrap();
            Some(path.to_string_lossy().into_owned())
        };
        let session = |id: &str,
                       workspace: Option<&str>,
                       live: bool,
                       transcript: Option<String>,
                       updated: f64| Session {
            agent: Agent::Claude,
            session_id: id.to_owned(),
            workspace_id: workspace.map(str::to_owned),
            live,
            transcript,
            updated,
        };
        let sessions = vec![
            session(
                "old",
                Some("workspace-A"),
                false,
                transcript("old.jsonl", &[line("x", 1000, 2000, 3_000_000, 4)]),
                1.0,
            ),
            session(
                "new",
                Some("workspace-a"),
                true,
                transcript("new.jsonl", &[line("y", 1, 2, 3, 4)]),
                2.0,
            ),
            session(
                "gone",
                Some("workspace-z"),
                false,
                transcript("gone.jsonl", &[line("z", 5, 0, 0, 0)]),
                3.0,
            ),
            session(
                "lost",
                Some("workspace-a"),
                false,
                Some(dir.join("nope.jsonl").to_string_lossy().into_owned()),
                4.0,
            ),
        ];
        let no_env = |_: &str| None;
        let report = report(
            &[
                ("workspace-a".to_owned(), "api".to_owned()),
                ("workspace-b".to_owned(), "web".to_owned()),
            ],
            &sessions,
            &no_env,
        );
        assert_eq!(
            report["workspaces"][0]["sessions"][0]["session_id"], "new",
            "live sessions first"
        );
        assert_eq!(report["workspaces"][1]["open"], false);
        assert_eq!(report["tokens"]["total"], 3_003_019);
        assert_eq!(report["skipped"][0]["session_id"], "lost");
        assert_eq!(
            format_report(&report),
            concat!(
                "workspace-a  api\n",
                "  AGENT        SESSION  STATE  INPUT  OUTPUT  CACHE READ  CACHE WRITE\n",
                "  claude-code  new      live       1       2           3            4\n",
                "  claude-code  old      ended  1,000   2,000   3,000,000            4\n",
                "  total                        1,001   2,002   3,000,003            8\n",
                "workspace-z (closed)\n",
                "  AGENT        SESSION  STATE  INPUT  OUTPUT  CACHE READ  CACHE WRITE\n",
                "  claude-code  gone     ended      5       0           0            0\n",
                "All workspaces: input 1,006, output 2,002, cache read 3,000,003, cache write 8\n",
                "Skipped 1 session with a missing or unreadable transcript\n",
            )
        );
        assert_eq!(
            format_report(&super::report(&[], &[], &no_env)),
            "No agent token usage recorded\n"
        );
    }
}
