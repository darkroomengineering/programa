//! Open Claude Code permission requests, as on macOS (`ClaudePermissionRequest`): one small file per
//! (session, agent) in `%TEMP%\programa-claude-permission-<surface hash>`, from the PermissionRequest
//! hook until that agent's next finished tool. A finished tool ends the pane's stop for input only
//! once no agent there still has a request open, so a subagent's tool never ends the main agent's
//! prompt. Only file names are read back. A folder that is a link or junction holds the stop.

use std::fs;
use std::path::PathBuf;

use serde_json::Value;

use crate::Env;

/// FNV-1a, 64-bit: the names only need to be stable, and the ids come from the environment.
pub fn hash(text: &str) -> String {
    let mut value: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        value ^= u64::from(byte);
        value = value.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{value:016x}")
}

struct Request {
    session: String,
    /// The payload's `agent_id` for a subagent, `main` for the main agent.
    owner: String,
}

impl Request {
    fn from(input: &str) -> Option<Request> {
        let object: Value = serde_json::from_str(input).ok().filter(Value::is_object)?;
        let text = |key: &str| {
            object
                .get(key)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
        };
        Some(Request {
            session: text("session_id").unwrap_or_default().to_owned(),
            owner: text("agent_id").unwrap_or("main").to_owned(),
        })
    }

    fn prefix(&self) -> String {
        format!("{}-", hash(&self.session))
    }

    fn file_name(&self) -> String {
        format!(
            "{}{}.json",
            self.prefix(),
            hash(&format!("{}\0{}", self.session, self.owner))
        )
    }
}

enum Folder {
    Missing,
    Untrusted,
    Trusted(PathBuf),
}

fn folder(env: Env, create: bool) -> Folder {
    let Some(surface) = env("PROGRAMA_SURFACE_ID").filter(|id| !id.is_empty()) else {
        return Folder::Missing;
    };
    let base = env("TEMP")
        .or_else(|| env("TMP"))
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let path = base.join(format!("programa-claude-permission-{}", hash(&surface)));
    if create {
        let _ = fs::create_dir(&path);
    }
    match fs::symlink_metadata(&path) {
        Err(_) => Folder::Missing,
        Ok(meta) if meta.is_dir() && !meta.file_type().is_symlink() && !is_junction(&meta) => {
            Folder::Trusted(path)
        }
        Ok(_) => Folder::Untrusted,
    }
}

#[cfg(windows)]
fn is_junction(meta: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    meta.file_attributes() & 0x400 != 0 // FILE_ATTRIBUTE_REPARSE_POINT
}

#[cfg(not(windows))]
fn is_junction(_: &fs::Metadata) -> bool {
    false
}

/// Record file names; None when the folder cannot be listed, which counts as a request still open.
fn records(path: &PathBuf) -> Option<Vec<String>> {
    let mut names = Vec::new();
    for entry in fs::read_dir(path).ok()? {
        let name = entry.ok()?.file_name().to_string_lossy().into_owned();
        if name.ends_with(".json") {
            names.push(name);
        }
    }
    Some(names)
}

/// PermissionRequest: this agent has a prompt open. A later request from it replaces the record:
/// its tools run one at a time, so the earlier one was answered.
pub fn record(input: &str, env: Env) {
    let (Some(request), Folder::Trusted(path)) = (Request::from(input), folder(env, true)) else {
        return;
    };
    let target = path.join(request.file_name());
    let temporary = path.join(format!(
        "{}.{}.tmp",
        request.file_name(),
        std::process::id()
    ));
    if fs::write(&temporary, b"{}").is_ok() && fs::rename(&temporary, &target).is_err() {
        let _ = fs::remove_file(&temporary);
    }
}

/// A tool finished: its agent moved past any request it raised, so its record goes; the stop ends
/// only when no agent's record is left. With no folder at all every finished tool ends it.
pub fn tool_ends_stop(input: &str, env: Env) -> bool {
    match folder(env, false) {
        Folder::Missing => true,
        Folder::Untrusted => false,
        Folder::Trusted(path) => {
            if let Some(request) = Request::from(input) {
                let _ = fs::remove_file(path.join(request.file_name()));
            }
            records(&path).is_some_and(|names| names.is_empty())
        }
    }
}

/// SubagentStop: the helper ended, so a request it raised (for a tool the person denied) is gone.
pub fn forget_subagent(input: &str, env: Env) {
    if let (Some(request), Folder::Trusted(path)) = (Request::from(input), folder(env, false)) {
        if request.owner != "main" {
            let _ = fs::remove_file(path.join(request.file_name()));
        }
    }
}

/// The prompt, the turn or the session ended: none of this session's requests is up. Only this
/// session's records go, so a nested `claude -p` in the same pane keeps its parent's.
pub fn forget_session(input: &str, env: Env) {
    let (Some(request), Folder::Trusted(path)) = (Request::from(input), folder(env, false)) else {
        return;
    };
    let prefix = request.prefix();
    for name in records(&path).unwrap_or_default() {
        if name.starts_with(&prefix) {
            let _ = fs::remove_file(path.join(name));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tool_ends_the_stop_only_when_no_agent_has_a_request_open() {
        let temp =
            std::env::temp_dir().join(format!("programa-permission-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp);
        fs::create_dir_all(&temp).unwrap();
        let temp_text = temp.to_string_lossy().into_owned();
        let env = move |key: &str| match key {
            "PROGRAMA_SURFACE_ID" => Some("surface-1".to_owned()),
            "TEMP" => Some(temp_text.clone()),
            _ => None,
        };
        let main = r#"{"session_id":"s1","tool_name":"Bash"}"#;
        let helper = r#"{"session_id":"s1","agent_id":"a7","tool_name":"Edit"}"#;
        assert!(tool_ends_stop(main, &env), "no request was ever recorded");
        record(main, &env);
        record(helper, &env);
        // The helper's tool finished, but the main agent's prompt is still up.
        assert!(!tool_ends_stop(helper, &env));
        assert!(tool_ends_stop(main, &env));
        // A helper that stopped with its request unanswered no longer holds the stop.
        record(helper, &env);
        forget_subagent(helper, &env);
        assert!(tool_ends_stop(main, &env));
        // The turn ending drops only that session's requests.
        record(main, &env);
        record(r#"{"session_id":"other"}"#, &env);
        forget_session(main, &env);
        assert!(
            !tool_ends_stop(r#"{"session_id":"s1"}"#, &env),
            "the nested session's request stays"
        );
        forget_session(r#"{"session_id":"other"}"#, &env);
        assert!(tool_ends_stop(main, &env));
        let _ = fs::remove_dir_all(&temp);
    }
}
