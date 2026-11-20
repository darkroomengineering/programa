//! `programa claude-hook <event>`: the Claude Code hooks that the PowerShell `claude` function
//! passes with `--settings` report to the Programa terminal they run in, as the macOS wrapper's do
//! when Claude does not report its own status. Every report carries Claude's session id, which is
//! what lets event routes trust it (docs/program-status.md, Authority):
//!
//! - `session-start`: `agent.event` `session.started` (resume picks the exact session), then `idle`.
//! - `prompt-submit`: `working`. `stop`: `idle`.
//! - `notification`: a permission request or a wait for the person is `agent.needs_input`
//!   (`permission` or `question`; an open AskUserQuestion is a question with its text); anything
//!   else is a notification and `idle`.
//! - `post-tool-use` (and PostToolUseFailure): a tool finished, so a stop for input is over:
//!   `working` and the workspace's notifications cleared, unless another agent in the pane still
//!   has a permission request open (`permission.rs`).
//! - `pre-tool-use` and `permission-request` report nothing; they keep the question and request
//!   records (`usage.rs`, `permission.rs`).
//! - `subagent-start` / `subagent-stop`: the helper in the sidebar's helpers popover
//!   (`agent.task.start` / `agent.task.finish`, with its task and final report).
//! - `session-end`: `agent.event` `session.exited`, the state cleared, and the session's helpers
//!   still running stopped.
//!
//! A hook never fails Claude: anything that goes wrong is ignored and the exit code is 0.

use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;

use serde_json::{json, Map, Value};

use crate::Env;

/// A request line, and the one to send instead when the server refuses it.
pub type HookRequest = (String, Option<String>);

/// What a hook sends, in order; empty when there is nothing to report (another event, or not in a
/// Programa terminal). `question` is the session's open AskUserQuestion, for `notification`.
pub fn request_lines(
    event: &str,
    input: &str,
    env: Env,
    question: Option<&str>,
) -> Vec<HookRequest> {
    let (Some(surface), Some(workspace)) = (
        env("PROGRAMA_SURFACE_ID").filter(|id| !id.is_empty()),
        env("PROGRAMA_WORKSPACE_ID").filter(|id| !id.is_empty()),
    ) else {
        return Vec::new();
    };
    let input: Value = serde_json::from_str(input).unwrap_or(Value::Null);
    let text = |key: &str| {
        input
            .get(key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    };
    let target = || {
        let mut params = Map::new();
        params.insert("workspace_id".to_owned(), json!(workspace));
        params.insert("surface_id".to_owned(), json!(surface));
        if let Some(session) = text("session_id") {
            params.insert("session_id".to_owned(), json!(session));
        }
        params
    };
    let line = |method: &str, params: Map<String, Value>| {
        json!({ "id": 1, "method": method, "params": params }).to_string()
    };
    let only = |line: String| (line, None);
    let session_event = |event_type: &str| {
        let mut params = target();
        params.insert("event_type".to_owned(), json!(event_type));
        params.insert("provider".to_owned(), json!("claude"));
        if let Some(path) = text("transcript_path") {
            params.insert("transcript_path".to_owned(), json!(path));
        }
        line("agent.event", params)
    };
    let state = |state: &str| {
        let mut params = target();
        params.insert("state".to_owned(), json!(state));
        params.insert("source".to_owned(), json!("hooks"));
        params.insert("provider".to_owned(), json!("claude-code"));
        line("surface.report_agent_state", params)
    };
    match event {
        "session-start" => vec![only(session_event("session.started")), only(state("idle"))],
        "prompt-submit" => vec![only(state("working"))],
        "stop" => vec![only(state("idle"))],
        "post-tool-use" => {
            let mut resume = target();
            resume.insert("state".to_owned(), json!("working"));
            resume.insert("source".to_owned(), json!("hooks"));
            resume.insert("provider".to_owned(), json!("claude-code"));
            resume.insert("resumed".to_owned(), json!(true));
            let mut clear = Map::new();
            clear.insert("workspace_id".to_owned(), json!(workspace));
            vec![
                only(line("surface.report_agent_state", resume)),
                only(line("notification.clear", clear)),
            ]
        }
        "session-end" => {
            let mut lines = vec![only(session_event("session.exited")), only(state("clear"))];
            if let Some(session) = text("session_id") {
                lines.push(only(line(
                    "agent.task.finish_session",
                    json_map(json!({ "host": "claude", "session": session, "state": "cancelled" })),
                )));
            }
            lines
        }
        "notification" => {
            let message = text("message").unwrap_or("Claude Code needs your input");
            let (subtitle, kind, body) = match question {
                // Claude Code reports its question dialog as a generic permission prompt.
                Some(question) => ("Waiting", Some("question"), question),
                None => {
                    let (subtitle, kind) =
                        classify(text("notification_type").unwrap_or(""), message);
                    (subtitle, kind, message)
                }
            };
            let body: String = body.chars().take(180).collect();
            let mut params = target();
            params.insert("provider".to_owned(), json!("claude-code"));
            params.insert("title".to_owned(), json!("Claude Code"));
            params.insert("subtitle".to_owned(), json!(subtitle));
            params.insert("body".to_owned(), json!(body));
            match kind {
                Some(kind) => {
                    params.insert("kind".to_owned(), json!(kind));
                    vec![only(line("agent.needs_input", params))]
                }
                None => {
                    params.remove("session_id");
                    params.remove("provider");
                    vec![
                        only(line("notification.create", params)),
                        only(state("idle")),
                    ]
                }
            }
        }
        "subagent-start" | "subagent-stop" => {
            let Some(agent) = text("agent_id") else {
                return Vec::new();
            };
            let id = task_id(text("session_id").unwrap_or(&workspace), agent);
            let agent_type = text("agent_type");
            let session_transcript = text("transcript_path").map(PathBuf::from);
            let subagent_transcript = |extension: &str| {
                session_transcript.as_ref().and_then(|path| {
                    let stem = path.to_string_lossy().strip_suffix(".jsonl")?.to_owned();
                    let name = if agent.starts_with("agent-") {
                        agent.to_owned()
                    } else {
                        format!("agent-{agent}")
                    };
                    Some(PathBuf::from(format!("{stem}/subagents/{name}{extension}")))
                })
            };
            // The short description the parent gave the Agent tool, kept next to the transcript.
            let description = |meta: Option<PathBuf>| {
                let meta = meta?;
                let object: Value =
                    serde_json::from_str(&std::fs::read_to_string(meta).ok()?).ok()?;
                object["description"]
                    .as_str()
                    .map(str::trim)
                    .filter(|text| !text.is_empty())
                    .map(str::to_owned)
            };
            let start = |state: &str, summary: Option<&str>, task: Option<String>| {
                let mut params = json_map(json!({
                    "agent_id": id, "workspace_id": workspace, "surface_id": surface,
                    "host": "claude", "placement": "runs_with_parent", "state": state,
                }));
                put(&mut params, "session", text("session_id"));
                put(&mut params, "role", agent_type);
                put(&mut params, "task", task.as_deref().or(agent_type));
                put(&mut params, "summary", summary);
                line("agent.task.start", params)
            };
            if event == "subagent-start" {
                let task = description(subagent_transcript(".meta.json"));
                let mut update = json_map(json!({ "agent_id": id, "state": "working" }));
                put(&mut update, "session", text("session_id"));
                put(&mut update, "role", agent_type);
                put(&mut update, "task", task.as_deref().or(agent_type));
                return vec![(
                    start("working", None, task.clone()),
                    Some(line("agent.task.update", update)),
                )];
            }
            let transcript = text("agent_transcript_path")
                .map(PathBuf::from)
                .or_else(|| subagent_transcript(".jsonl"));
            let task = description(transcript.as_ref().and_then(|path| {
                let name = path.to_string_lossy();
                name.strip_suffix(".jsonl")
                    .map(|stem| PathBuf::from(format!("{stem}.meta.json")))
            }));
            let report = transcript
                .as_ref()
                .and_then(|path| handback(path))
                .or_else(|| text("last_assistant_message").map(str::to_owned));
            // The socket caps a summary at 16 KiB; cut on a character boundary.
            let summary = report.map(|report| {
                let mut end = report.len().min(16_000);
                while !report.is_char_boundary(end) {
                    end -= 1;
                }
                report[..end].to_owned()
            });
            let mut finish = json_map(json!({ "agent_id": id, "state": "completed" }));
            put(&mut finish, "task", task.as_deref());
            put(&mut finish, "summary", summary.as_deref());
            // Claude Code's internal forks fire SubagentStop with no agent type and no SubagentStart;
            // they get no row. Any other helper never seen starting is added finished.
            let fallback = agent_type.map(|_| start("completed", summary.as_deref(), task.clone()));
            vec![(line("agent.task.finish", finish), fallback)]
        }
        _ => Vec::new(),
    }
}

/// `programa codex-hook <event>`, which `programa codex install-integration` registers: the macOS
/// Codex reports, with provider `codex`. Codex's PermissionRequest arrives as `notification`.
pub fn codex_request_lines(event: &str, input: &str, env: Env) -> Vec<HookRequest> {
    let (Some(surface), Some(workspace)) = (
        env("PROGRAMA_SURFACE_ID").filter(|id| !id.is_empty()),
        env("PROGRAMA_WORKSPACE_ID").filter(|id| !id.is_empty()),
    ) else {
        return Vec::new();
    };
    let input: Value = serde_json::from_str(input).unwrap_or(Value::Null);
    let text = |value: &Value| {
        value
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    };
    let mut target = json_map(json!({ "workspace_id": workspace, "surface_id": surface }));
    put(
        &mut target,
        "session_id",
        text(&input["session_id"]).as_deref(),
    );
    let line = |method: &str, params: Map<String, Value>| {
        json!({ "id": 1, "method": method, "params": params }).to_string()
    };
    let session_event = |event_type: &str| {
        let mut params = target.clone();
        params.insert("event_type".into(), json!(event_type));
        params.insert("provider".into(), json!("codex"));
        put(
            &mut params,
            "transcript_path",
            text(&input["transcript_path"]).as_deref(),
        );
        (line("agent.event", params), None)
    };
    let state = |state: &str| {
        let mut params = target.clone();
        params.insert("state".into(), json!(state));
        params.insert("source".into(), json!("hooks"));
        params.insert("provider".into(), json!("codex"));
        (line("surface.report_agent_state", params), None)
    };
    match event {
        "session-start" => vec![session_event("session.started"), state("idle")],
        "prompt-submit" => vec![state("working")],
        "stop" => vec![state("idle")],
        "session-end" => vec![session_event("session.exited"), state("clear")],
        "notification" => {
            let tool = &input["tool_input"];
            let (subtitle, kind, body) = if input["hook_event_name"] == "PermissionRequest"
                || input["tool_name"].is_string()
            {
                let body = text(&tool["description"])
                    .or_else(|| {
                        text(&tool["command"])
                            .map(|command| format!("Codex wants to run {command}"))
                    })
                    .unwrap_or_else(|| {
                        format!(
                            "Codex needs your permission to use {}",
                            text(&input["tool_name"]).unwrap_or_else(|| "a tool".into())
                        )
                    });
                ("Permission", Some("permission"), body)
            } else {
                let message =
                    text(&input["message"]).unwrap_or_else(|| "Codex needs your input".into());
                let (subtitle, kind) = classify(
                    text(&input["notification_type"]).as_deref().unwrap_or(""),
                    &message,
                );
                (subtitle, kind, message)
            };
            let mut params = target.clone();
            params.insert("provider".into(), json!("codex"));
            params.insert("title".into(), json!("Codex"));
            params.insert("subtitle".into(), json!(subtitle));
            params.insert(
                "body".into(),
                json!(body.chars().take(180).collect::<String>()),
            );
            match kind {
                Some(kind) => {
                    params.insert("kind".into(), json!(kind));
                    vec![(line("agent.needs_input", params), None)]
                }
                None => {
                    params.remove("session_id");
                    params.remove("provider");
                    vec![(line("notification.create", params), None), state("idle")]
                }
            }
        }
        _ => Vec::new(),
    }
}

/// `programa opencode-hook <event> [--cwd DIR] [--session ID] [--workspace ID] [--surface ID]`, run
/// by Programa's OpenCode plugin: the macOS OpenCode reports, with provider `opencode`. The plugin
/// reports `notification` only for a permission prompt, so it is always one.
pub fn opencode_request_lines(args: &[String], env: Env) -> Vec<HookRequest> {
    let flag = |name: &str| {
        args.iter()
            .position(|arg| arg == name)
            .and_then(|index| args.get(index + 1))
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
    };
    let from_env = |key: &str| env(key).filter(|id| !id.is_empty());
    // As on macOS, nothing is reported outside a Programa terminal.
    if from_env("PROGRAMA_SURFACE_ID").is_none() {
        return Vec::new();
    }
    let (Some(surface), Some(workspace)) = (
        flag("--surface").or_else(|| from_env("PROGRAMA_SURFACE_ID")),
        flag("--workspace").or_else(|| from_env("PROGRAMA_WORKSPACE_ID")),
    ) else {
        return Vec::new();
    };
    let mut target = json_map(json!({ "workspace_id": workspace, "surface_id": surface }));
    put(&mut target, "session_id", flag("--session").as_deref());
    let line = |method: &str, mut params: Map<String, Value>, extra: Value| {
        params.extend(json_map(extra));
        (
            json!({ "id": 1, "method": method, "params": params }).to_string(),
            None,
        )
    };
    let session_event = |event_type: &str| {
        line(
            "agent.event",
            target.clone(),
            json!({ "event_type": event_type, "provider": "opencode" }),
        )
    };
    let state = |state: &str| {
        line(
            "surface.report_agent_state",
            target.clone(),
            json!({ "state": state, "source": "hooks", "provider": "opencode" }),
        )
    };
    match args.first().map(|event| event.to_lowercase()).as_deref() {
        Some("session-start") => vec![session_event("session.started"), state("idle")],
        Some("prompt-submit") => vec![state("working")],
        Some("stop") => vec![state("idle")],
        Some("session-end") => vec![session_event("session.exited"), state("clear")],
        Some("notification" | "notify") => vec![line(
            "agent.needs_input",
            target.clone(),
            json!({
                "provider": "opencode", "title": "OpenCode", "subtitle": "Permission",
                "body": "OpenCode needs your attention", "kind": "permission",
            }),
        )],
        _ => Vec::new(),
    }
}

fn json_map(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

fn put(params: &mut Map<String, Value>, key: &str, value: Option<&str>) {
    if let Some(value) = value {
        params.insert(key.to_owned(), json!(value));
    }
}

/// A stable helper id for one subagent of a session, in UUID form.
pub fn task_id(scope: &str, agent: &str) -> String {
    let key = format!("claude:{scope}:{agent}");
    // 32 hex digits from two hashes, shaped as a version-5 UUID.
    let hex = format!(
        "{}{}",
        crate::permission::hash(&key),
        crate::permission::hash(&format!("{key}#"))
    );
    format!(
        "{}-{}-5{}-a{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[13..16],
        &hex[17..20],
        &hex[20..32]
    )
    .to_uppercase()
}

/// In auto mode a subagent delivers its report through a `SubagentHandback` call; the last one wins.
fn handback(transcript: &PathBuf) -> Option<String> {
    let mut reader = BufReader::new(File::open(transcript).ok()?);
    let mut message = None;
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if !line
            .windows(18)
            .any(|window| window == b"\"SubagentHandback\"")
        {
            continue;
        }
        let Ok(object) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        for block in object["message"]["content"]
            .as_array()
            .into_iter()
            .flatten()
        {
            if block["type"] == "tool_use" && block["name"] == "SubagentHandback" {
                if let Some(text) = block["input"]["message"].as_str() {
                    message = Some(text.to_owned());
                }
            }
        }
    }
    message
}

/// AskUserQuestion's first question (or header) and its options, as the notification shows it.
pub fn describe_question(input: &Value) -> String {
    let first = &input["tool_input"]["questions"][0];
    let mut parts = Vec::new();
    if let Some(question) = first["question"].as_str().filter(|text| !text.is_empty()) {
        parts.push(question.to_owned());
    } else if let Some(header) = first["header"].as_str().filter(|text| !text.is_empty()) {
        parts.push(header.to_owned());
    }
    let labels: Vec<String> = first["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|option| option["label"].as_str().map(|label| format!("[{label}]")))
        .collect();
    if !labels.is_empty() {
        parts.push(labels.join(" "));
    }
    if parts.is_empty() {
        "Asking a question".to_owned()
    } else {
        parts.join("\n")
    }
}

/// The macOS classification: a permission request or a wait for input stops the agent for the
/// person (`needs_input` kind); an error or a finish is only news.
fn classify(signal: &str, message: &str) -> (&'static str, Option<&'static str>) {
    let lower = format!("{signal} {message}").to_lowercase();
    let has = |words: &[&str]| words.iter().any(|word| lower.contains(word));
    if has(&["permission", "approve", "approval"]) {
        ("Permission", Some("permission"))
    } else if has(&["error", "failed", "exception"]) {
        ("Error", None)
    } else if has(&["complet", "finish", "done", "success"]) {
        ("Completed", None)
    } else if has(&["idle", "wait", "input"]) {
        ("Waiting", Some("question"))
    } else {
        ("Attention", Some("question"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(key: &str) -> Option<String> {
        match key {
            "PROGRAMA_SURFACE_ID" => Some("surface-1".to_owned()),
            "PROGRAMA_WORKSPACE_ID" => Some("workspace-1".to_owned()),
            _ => None,
        }
    }

    fn requests(event: &str, input: &str) -> Vec<Value> {
        request_lines(event, input, &env, None)
            .iter()
            .map(|(line, _)| serde_json::from_str(line).unwrap())
            .collect()
    }

    #[test]
    fn session_start_reports_the_session_then_idle() {
        let sent = requests(
            "session-start",
            r#"{"session_id":"abc-123","transcript_path":"C:\\t.jsonl","cwd":"C:\\repo"}"#,
        );
        assert_eq!(sent[0]["method"], "agent.event");
        assert_eq!(sent[0]["params"]["event_type"], "session.started");
        assert_eq!(sent[0]["params"]["session_id"], "abc-123");
        assert_eq!(sent[0]["params"]["transcript_path"], "C:\\t.jsonl");
        // agent.event takes no cwd (additionalProperties: false).
        assert!(sent[0]["params"].get("cwd").is_none());
        assert_eq!(sent[1]["method"], "surface.report_agent_state");
        assert_eq!(sent[1]["params"]["state"], "idle");
        assert_eq!(sent[1]["params"]["session_id"], "abc-123");
    }

    #[test]
    fn turns_and_tools_report_states_with_the_session() {
        let submit = &requests("prompt-submit", r#"{"session_id":"s"}"#)[0];
        assert_eq!(submit["params"]["state"], "working");
        assert_eq!(submit["params"]["session_id"], "s");
        assert!(submit["params"].get("route_only").is_none());
        assert_eq!(
            requests("stop", r#"{"session_id":"s"}"#)[0]["params"]["state"],
            "idle"
        );
        // A finished tool resumes the agent everywhere and clears what asked for the person.
        let tool = requests("post-tool-use", r#"{"session_id":"s"}"#);
        assert_eq!(tool[0]["params"]["state"], "working");
        assert_eq!(tool[0]["params"]["resumed"], true);
        assert!(tool[0]["params"].get("route_only").is_none());
        assert_eq!(tool[1]["method"], "notification.clear");
        assert_eq!(tool[1]["params"]["workspace_id"], "workspace-1");
        let end = requests("session-end", r#"{"session_id":"s"}"#);
        assert_eq!(end[0]["params"]["event_type"], "session.exited");
        assert_eq!(end[1]["params"]["state"], "clear");
        assert_eq!(end[2]["method"], "agent.task.finish_session");
        assert_eq!(
            end[2]["params"],
            json!({ "host": "claude", "session": "s", "state": "cancelled" })
        );
    }

    #[test]
    fn notifications_are_needs_input_or_news() {
        let permission = &requests(
            "notification",
            r#"{"session_id":"s","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#,
        )[0];
        assert_eq!(permission["method"], "agent.needs_input");
        assert_eq!(permission["params"]["kind"], "permission");
        assert_eq!(permission["params"]["session_id"], "s");
        let waiting = &requests(
            "notification",
            r#"{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#,
        )[0];
        assert_eq!(waiting["params"]["kind"], "question");
        let done = requests("notification", r#"{"message":"Task completed"}"#);
        assert_eq!(done[0]["method"], "notification.create");
        assert_eq!(done[1]["params"]["state"], "idle");
        // An open AskUserQuestion turns Claude's generic permission prompt into that question.
        let asked = request_lines(
            "notification",
            r#"{"session_id":"s","notification_type":"permission_prompt","message":"Claude needs your permission"}"#,
            &env,
            Some("Which branch?\n[main] [dev]"),
        );
        let asked: Value = serde_json::from_str(&asked[0].0).unwrap();
        assert_eq!(asked["params"]["kind"], "question");
        assert_eq!(asked["params"]["body"], "Which branch?\n[main] [dev]");
        let question = json!({ "tool_input": { "questions": [{ "question": "Which branch?", "options": [{ "label": "main" }, { "label": "dev" }] }] } });
        assert_eq!(describe_question(&question), "Which branch?\n[main] [dev]");
        assert_eq!(describe_question(&json!({})), "Asking a question");
    }

    #[test]
    fn subagents_become_helpers_with_their_task_and_report() {
        let dir =
            std::env::temp_dir().join(format!("programa-hook-subagent-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("s1").join("subagents")).unwrap();
        let session = dir.join("s1.jsonl");
        std::fs::write(
            dir.join("s1/subagents/agent-a7.meta.json"),
            r#"{"description":"Find the flaky test"}"#,
        )
        .unwrap();
        let handback = json!({ "message": { "content": [{ "type": "tool_use", "name": "SubagentHandback", "input": { "message": "It was the clock." } }] } });
        std::fs::write(
            dir.join("s1/subagents/agent-a7.jsonl"),
            format!("{{}}\n{handback}\n"),
        )
        .unwrap();
        let input = json!({ "session_id": "s1", "agent_id": "a7", "agent_type": "Explore", "transcript_path": session, "last_assistant_message": "done" }).to_string();

        let started = request_lines("subagent-start", &input, &env, None);
        let start: Value = serde_json::from_str(&started[0].0).unwrap();
        assert_eq!(start["method"], "agent.task.start");
        assert_eq!(start["params"]["task"], "Find the flaky test");
        assert_eq!(start["params"]["role"], "Explore");
        assert_eq!(start["params"]["host"], "claude");
        assert_eq!(start["params"]["surface_id"], "surface-1");
        let update: Value = serde_json::from_str(started[0].1.as_ref().unwrap()).unwrap();
        assert_eq!(update["method"], "agent.task.update");
        let id = start["params"]["agent_id"].as_str().unwrap().to_owned();
        assert_eq!(id.len(), 36);
        assert_eq!(
            id,
            task_id("s1", "a7"),
            "the same subagent always gets the same id"
        );
        assert_ne!(id, task_id("s2", "a7"));

        let stopped = request_lines("subagent-stop", &input, &env, None);
        let finish: Value = serde_json::from_str(&stopped[0].0).unwrap();
        assert_eq!(finish["method"], "agent.task.finish");
        assert_eq!(finish["params"]["agent_id"], id.as_str());
        assert_eq!(
            finish["params"]["summary"], "It was the clock.",
            "the handback wins over the closing text"
        );
        assert_eq!(finish["params"]["task"], "Find the flaky test");
        let fallback: Value = serde_json::from_str(stopped[0].1.as_ref().unwrap()).unwrap();
        assert_eq!(
            (
                fallback["method"].as_str(),
                fallback["params"]["state"].as_str()
            ),
            (Some("agent.task.start"), Some("completed"))
        );
        // An internal fork (no agent type) gets no row of its own.
        let fork = request_lines(
            "subagent-stop",
            r#"{"session_id":"s1","agent_id":"x"}"#,
            &env,
            None,
        );
        assert!(fork[0].1.is_none());
        assert!(request_lines("subagent-start", r#"{"session_id":"s1"}"#, &env, None).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn codex_reports_its_session_turns_and_permission_requests() {
        let lines = |event: &str, input: &str| -> Vec<Value> {
            codex_request_lines(event, input, &env)
                .iter()
                .map(|(line, _)| serde_json::from_str(line).unwrap())
                .collect()
        };
        let start = lines(
            "session-start",
            r#"{"session_id":"thr_1","transcript_path":"C:\\r.jsonl","cwd":"C:\\w","hook_event_name":"SessionStart","source":"startup"}"#,
        );
        assert_eq!(start[0]["params"]["provider"], "codex");
        assert_eq!(start[0]["params"]["event_type"], "session.started");
        assert_eq!(start[0]["params"]["transcript_path"], "C:\\r.jsonl");
        assert_eq!(
            (
                start[1]["params"]["state"].as_str(),
                start[1]["params"]["provider"].as_str()
            ),
            (Some("idle"), Some("codex"))
        );
        assert_eq!(
            lines("prompt-submit", r#"{"session_id":"thr_1"}"#)[0]["params"]["state"],
            "working"
        );
        let asked = &lines(
            "notification",
            r#"{"session_id":"thr_1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":null}}"#,
        )[0];
        assert_eq!(asked["method"], "agent.needs_input");
        assert_eq!(asked["params"]["kind"], "permission");
        assert_eq!(asked["params"]["body"], "Codex wants to run rm -rf build");
        assert_eq!(
            lines("session-end", r#"{"session_id":"thr_1","reason":"other"}"#)[1]["params"]
                ["state"],
            "clear"
        );
        assert!(codex_request_lines("stop", "{}", &|_: &str| None).is_empty());
    }

    #[test]
    fn opencode_reports_its_session_turns_and_permission_prompts() {
        let requests = |args: &[&str]| -> Vec<Value> {
            let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
            opencode_request_lines(&args, &env)
                .into_iter()
                .map(|(line, _)| serde_json::from_str(&line).unwrap())
                .collect()
        };
        let start = requests(&["session-start", "--cwd", "C:\\repo", "--session", "ses_1"]);
        assert_eq!(start[0]["method"], "agent.event");
        assert_eq!(start[0]["params"]["event_type"], "session.started");
        assert_eq!(start[0]["params"]["provider"], "opencode");
        assert_eq!(start[0]["params"]["session_id"], "ses_1");
        assert_eq!(start[1]["params"]["state"], "idle");
        assert_eq!(
            requests(&["prompt-submit"])[0]["params"]["state"],
            "working"
        );
        let asked = &requests(&["NOTIFICATION", "--session", "ses_1"])[0];
        assert_eq!(asked["method"], "agent.needs_input");
        assert_eq!(asked["params"]["kind"], "permission");
        assert_eq!(asked["params"]["body"], "OpenCode needs your attention");
        assert_eq!(requests(&["session-end"])[1]["params"]["state"], "clear");
        assert!(requests(&["unknown"]).is_empty());
        let outside = ["stop".to_owned()];
        assert!(opencode_request_lines(&outside, &|_: &str| None).is_empty());
    }

    #[test]
    fn other_events_and_other_terminals_report_nothing() {
        assert!(request_lines("pre-tool-use", "{}", &env, None).is_empty());
        assert!(request_lines("permission-request", "{}", &env, None).is_empty());
        assert!(request_lines("stop", "{}", &|_: &str| None, None).is_empty());
        // Unreadable input still reports, without a session id.
        let (line, _) = &request_lines("stop", "not json", &env, None)[0];
        assert!(!line.contains("session_id"));
    }
}
