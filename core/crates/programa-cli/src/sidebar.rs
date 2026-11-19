//! The sidebar metadata commands, as on macOS (CLI/Commands/SidebarCommands.swift): status
//! entries, the log, the progress bar and `sidebar-state`, with the same flags and output.

use serde_json::{Map, Value};

use super::{
    items, no_positionals, one_positional, parse_opts, put, str_or_empty, target, Command, Env,
    UsageError, WORKSPACE_ENV,
};

pub(crate) const LEVELS: [&str; 5] = ["info", "progress", "success", "warning", "error"];

pub(crate) fn params(
    command: Command,
    args: &[String],
    env: Env,
) -> Result<Map<String, Value>, UsageError> {
    let name = command.name();
    let mut params = Map::new();
    let opts = match command {
        Command::SetStatus => {
            let opts = parse_opts(
                command,
                args,
                &[
                    "--icon",
                    "--color",
                    "--url",
                    "--link",
                    "--priority",
                    "--format",
                    "--pid",
                    "--workspace",
                ],
                &[],
            )?;
            let [key, value @ ..] = opts.positionals.as_slice() else {
                return Err(UsageError(format!("{name}: missing status key or value")));
            };
            if value.is_empty() {
                return Err(UsageError(format!("{name}: missing status key or value")));
            }
            put(&mut params, "key", Some(key.clone()));
            put(&mut params, "value", Some(value.join(" ")));
            put(&mut params, "icon", opts.value("--icon"));
            put(&mut params, "color", opts.value("--color"));
            put(
                &mut params,
                "url",
                opts.value("--url").or(opts.value("--link")),
            );
            if let Some(raw) = opts.value("--priority") {
                let priority = raw.parse::<i64>().map_err(|_| {
                    UsageError(format!(
                        "{name}: --priority must be an integer, not '{raw}'"
                    ))
                })?;
                params.insert("priority".into(), Value::from(priority.clamp(-9999, 9999)));
            }
            if let Some(raw) = opts.value("--format") {
                let format = match raw.to_lowercase().as_str() {
                    "plain" => "plain",
                    "markdown" | "md" => "markdown",
                    _ => {
                        return Err(UsageError(format!(
                            "{name}: --format must be plain or markdown"
                        )))
                    }
                };
                put(&mut params, "format", Some(format.to_owned()));
            }
            if let Some(raw) = opts.value("--pid") {
                let pid = raw
                    .parse::<u32>()
                    .ok()
                    .filter(|pid| *pid > 0)
                    .ok_or_else(|| {
                        UsageError(format!("{name}: --pid must be a positive integer"))
                    })?;
                params.insert("pid".into(), Value::from(pid));
            }
            opts
        }
        Command::ClearStatus => {
            let opts = parse_opts(command, args, &["--workspace"], &[])?;
            let key = one_positional(command, &opts, "status key")?;
            put(&mut params, "key", Some(key));
            opts
        }
        Command::SetProgress => {
            let opts = parse_opts(command, args, &["--label", "--workspace"], &[])?;
            let raw = one_positional(command, &opts, "progress value")?;
            let value = raw
                .parse::<f64>()
                .ok()
                .filter(|v| v.is_finite())
                .ok_or_else(|| {
                    UsageError(format!(
                        "{name}: invalid progress value '{raw}', must be 0.0 to 1.0"
                    ))
                })?;
            params.insert("value".into(), Value::from(value.clamp(0.0, 1.0)));
            put(&mut params, "label", opts.value("--label"));
            opts
        }
        Command::Log => {
            let opts = parse_opts(command, args, &["--level", "--source", "--workspace"], &[])?;
            if opts.positionals.is_empty() {
                return Err(UsageError(format!("{name}: missing message")));
            }
            let level = opts.value("--level").unwrap_or_else(|| "info".to_owned());
            if !LEVELS.contains(&level.as_str()) {
                return Err(UsageError(format!(
                    "{name}: unknown level '{level}', use: info, progress, success, warning, error"
                )));
            }
            put(&mut params, "message", Some(opts.positionals.join(" ")));
            put(&mut params, "level", Some(level));
            put(&mut params, "source", opts.value("--source"));
            opts
        }
        Command::ListLog => {
            let opts = parse_opts(command, args, &["--limit", "--workspace"], &[])?;
            no_positionals(command, &opts)?;
            if let Some(raw) = opts.value("--limit") {
                let limit = raw.parse::<u64>().map_err(|_| {
                    UsageError(format!("{name}: --limit must be a number, not '{raw}'"))
                })?;
                params.insert("limit".into(), Value::from(limit));
            }
            opts
        }
        _ => {
            let opts = parse_opts(command, args, &["--workspace"], &[])?;
            no_positionals(command, &opts)?;
            opts
        }
    };
    put(
        &mut params,
        "workspace_id",
        target(&opts, "--workspace", WORKSPACE_ENV, env),
    );
    Ok(params)
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    let lines: Vec<String> = match command {
        Command::ListStatus => {
            let entries = items(result, "entries");
            if entries.is_empty() {
                return "No status entries\n".to_owned();
            }
            entries.iter().map(status_line).collect()
        }
        Command::ListLog => {
            let entries = items(result, "entries");
            if entries.is_empty() {
                return "No log entries\n".to_owned();
            }
            entries.iter().map(log_line).collect()
        }
        Command::SidebarState => state_lines(result),
        _ => return "OK\n".to_owned(),
    };
    lines.join("\n") + "\n"
}

/// `key=value icon=… color=… url=… priority=N format=markdown`, leaving out defaults.
fn status_line(entry: &Value) -> String {
    let mut line = format!(
        "{}={}",
        str_or_empty(entry, "key"),
        str_or_empty(entry, "value")
    );
    for key in ["icon", "color", "url"] {
        if let Some(value) = entry.get(key).and_then(Value::as_str) {
            line.push_str(&format!(" {key}={value}"));
        }
    }
    if let Some(priority) = entry
        .get("priority")
        .and_then(Value::as_i64)
        .filter(|p| *p != 0)
    {
        line.push_str(&format!(" priority={priority}"));
    }
    if let Some(format) = entry
        .get("format")
        .and_then(Value::as_str)
        .filter(|f| *f != "plain")
    {
        line.push_str(&format!(" format={format}"));
    }
    line
}

/// `[level] message`, after `[source]` when there is one.
fn log_line(entry: &Value) -> String {
    let level = entry.get("level").and_then(Value::as_str).unwrap_or("info");
    let line = format!("[{level}] {}", str_or_empty(entry, "message"));
    match entry.get("source").and_then(Value::as_str) {
        Some(source) if !source.is_empty() => format!("[{source}] {line}"),
        _ => line,
    }
}

fn state_lines(state: &Value) -> Vec<String> {
    let text = |key: &str| state.get(key).and_then(Value::as_str);
    let mut lines = vec![
        format!("tab={}", text("workspace_id").unwrap_or("")),
        format!("color={}", text("color").unwrap_or("none")),
        format!("cwd={}", text("cwd").unwrap_or("")),
    ];
    match text("focused_cwd") {
        Some(cwd) => {
            lines.push(format!("focused_cwd={cwd}"));
            lines.push(format!(
                "focused_panel={}",
                text("focused_surface_id").unwrap_or("unknown")
            ));
        }
        None => lines.extend(["focused_cwd=unknown".into(), "focused_panel=unknown".into()]),
    }
    // Windows does not track a dirty tree: the branch alone then.
    lines.push(match state["git_branch"]["branch"].as_str() {
        Some(branch) => match state["git_branch"]["dirty"].as_bool() {
            Some(true) => format!("git_branch={branch} dirty"),
            Some(false) => format!("git_branch={branch} clean"),
            None => format!("git_branch={branch}"),
        },
        None => "git_branch=none".into(),
    });
    let pr = &state["pull_request"];
    match (
        pr["number"].as_u64(),
        pr["state"].as_str(),
        pr["url"].as_str(),
    ) {
        (Some(number), Some(status), Some(url)) => {
            lines.push(format!("pr=#{number} {status} {url}"));
            lines.push(format!("pr_label={}", pr["label"].as_str().unwrap_or("")));
            lines.push(format!(
                "pr_checks={}",
                pr["checks"].as_str().unwrap_or("none")
            ));
        }
        _ => lines.extend([
            "pr=none".into(),
            "pr_label=none".into(),
            "pr_checks=none".into(),
        ]),
    }
    let ports: Vec<String> = items(state, "ports").iter().map(Value::to_string).collect();
    lines.push(if ports.is_empty() {
        "ports=none".into()
    } else {
        format!("ports={}", ports.join(","))
    });
    lines.push(match state["progress"]["value"].as_f64() {
        Some(value) => format!(
            "progress={value:.2} {}",
            state["progress"]["label"].as_str().unwrap_or("")
        )
        .trim_end()
        .to_owned(),
        None => "progress=none".into(),
    });
    let entries = items(state, "status_entries");
    lines.push(format!("status_count={}", entries.len()));
    lines.extend(
        entries
            .iter()
            .map(|entry| format!("  {}", status_line(entry))),
    );
    let blocks = items(state, "metadata_blocks");
    lines.push(format!("meta_block_count={}", blocks.len()));
    lines.extend(blocks.iter().map(|block| {
        let mut line = format!(
            "  {}={}",
            str_or_empty(block, "key"),
            str_or_empty(block, "markdown").replace('\n', "\\n")
        );
        if let Some(priority) = block["priority"].as_i64().filter(|p| *p != 0) {
            line.push_str(&format!(" priority={priority}"));
        }
        line
    }));
    lines.push(format!(
        "log_count={}",
        state["log_count"].as_u64().unwrap_or(0)
    ));
    lines.extend(items(state, "recent_log_entries").iter().map(|entry| {
        format!(
            "  [{}] {}",
            entry["level"].as_str().unwrap_or("info"),
            str_or_empty(entry, "message")
        )
    }));
    lines
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::{parse_invocation, Invocation};

    fn call(list: &[&str], workspace: Option<&str>) -> Result<(Command, Value), String> {
        let args: Vec<String> = list.iter().map(|s| (*s).to_owned()).collect();
        let env = |key: &str| {
            (key == WORKSPACE_ENV)
                .then(|| workspace.map(str::to_owned))
                .flatten()
        };
        match parse_invocation(&args, &env) {
            Ok(Invocation::Call { request, .. }) => {
                Ok((request.command, Value::Object(request.params)))
            }
            Ok(other) => Err(format!("{other:?}")),
            Err(UsageError(message)) => Err(message),
        }
    }

    #[test]
    fn commands_take_the_macos_flags() {
        let (command, params) = call(
            &[
                "set-status",
                "build",
                "Compiling",
                "crates",
                "--icon",
                "hammer",
                "--link",
                "https://ci",
                "--priority",
                "20000",
                "--format",
                "MD",
                "--pid",
                "42",
            ],
            Some("ws-env"),
        )
        .unwrap();
        assert_eq!(command.method(), "workspace.set_status");
        assert_eq!(
            params,
            json!({"key": "build", "value": "Compiling crates", "icon": "hammer", "url": "https://ci", "priority": 9999, "format": "markdown", "pid": 42, "workspace_id": "ws-env"})
        );
        let (_, params) = call(
            &[
                "log",
                "--level",
                "error",
                "--source",
                "ci",
                "--workspace",
                "ws-1",
                "--",
                "-x",
                "failed",
            ],
            None,
        )
        .unwrap();
        assert_eq!(
            params,
            json!({"message": "-x failed", "level": "error", "source": "ci", "workspace_id": "ws-1"})
        );
        let (command, params) = call(&["set-progress", "1.5", "--label", "Done"], None).unwrap();
        assert_eq!(
            (command.method(), params),
            (
                "workspace.set_progress",
                json!({"value": 1.0, "label": "Done"})
            )
        );
        let (command, params) = call(&["list-log", "--limit", "3"], None).unwrap();
        assert_eq!(
            (command.method(), params),
            ("workspace.list_log", json!({"limit": 3}))
        );
        for (name, method) in [
            ("clear-status", "workspace.clear_status"),
            ("list-status", "workspace.list_status"),
            ("clear-progress", "workspace.clear_progress"),
            ("clear-log", "workspace.clear_log"),
            ("sidebar-state", "workspace.sidebar_state"),
        ] {
            let args: &[&str] = if name == "clear-status" {
                &[name, "build"]
            } else {
                &[name]
            };
            assert_eq!(call(args, None).unwrap().0.method(), method);
        }

        for (args, message) in [
            (
                &["set-status", "build"][..],
                "set-status: missing status key or value",
            ),
            (
                &["set-status", "k", "v", "--priority", "high"],
                "set-status: --priority must be an integer, not 'high'",
            ),
            (
                &["set-status", "k", "v", "--format", "html"],
                "set-status: --format must be plain or markdown",
            ),
            (
                &["set-progress", "half"],
                "set-progress: invalid progress value 'half', must be 0.0 to 1.0",
            ),
            (&["log"], "log: missing message"),
            (
                &["log", "--level", "debug", "x"],
                "log: unknown level 'debug', use: info, progress, success, warning, error",
            ),
            (&["clear-status"], "clear-status: missing status key"),
        ] {
            assert_eq!(call(args, None).unwrap_err(), message);
        }
    }

    #[test]
    fn output_matches_macos() {
        assert_eq!(render(Command::SetStatus, &json!({})), "OK\n");
        assert_eq!(
            render(Command::ListStatus, &json!({"entries": []})),
            "No status entries\n"
        );
        assert_eq!(
            render(Command::ListLog, &json!({"entries": []})),
            "No log entries\n"
        );
        assert_eq!(
            render(Command::ListStatus, &json!({"entries": [
                {"key": "build", "value": "ok", "icon": "hammer", "color": null, "url": "https://ci", "priority": 5, "format": "markdown"},
                {"key": "tests", "value": "42", "icon": null, "color": "#00ff00", "url": null, "priority": 0, "format": "plain"},
            ]})),
            "build=ok icon=hammer url=https://ci priority=5 format=markdown\ntests=42 color=#00ff00\n"
        );
        assert_eq!(
            render(
                Command::ListLog,
                &json!({"entries": [
                    {"message": "started", "level": "info", "source": null, "timestamp": 1.0},
                    {"message": "failed", "level": "error", "source": "ci", "timestamp": 2.0},
                ]})
            ),
            "[info] started\n[ci] [error] failed\n"
        );
        let state = json!({
            "workspace_id": "ws-1", "color": null, "cwd": "C:\\repo", "focused_cwd": "C:\\repo", "focused_surface_id": "s-1",
            "git_branch": {"branch": "main", "dirty": null}, "pull_request": null, "ports": [3000, 5173],
            "progress": {"value": 0.5, "label": "Building"},
            "status_entries": [{"key": "build", "value": "ok", "priority": 0, "format": "plain"}],
            "metadata_blocks": [{"key": "notes", "markdown": "# Hi\nthere", "priority": 2}],
            "log_count": 7, "recent_log_entries": [{"message": "done", "level": "success", "source": null}],
        });
        assert_eq!(
            render(Command::SidebarState, &state),
            "tab=ws-1\ncolor=none\ncwd=C:\\repo\nfocused_cwd=C:\\repo\nfocused_panel=s-1\ngit_branch=main\npr=none\npr_label=none\npr_checks=none\nports=3000,5173\nprogress=0.50 Building\nstatus_count=1\n  build=ok\nmeta_block_count=1\n  notes=# Hi\\nthere priority=2\nlog_count=7\n  [success] done\n"
        );
    }
}
