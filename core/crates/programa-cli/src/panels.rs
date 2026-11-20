//! Panel and workspace commands, as on macOS: current-workspace
//! (CLI/Commands/WorkspaceCommands.swift), list-panels, focus-panel and recap
//! (CLI/Commands/PaneCommands.swift, CLI/CLI+Recap.swift), send-panel and send-key-panel
//! (CLI/Commands/TerminalIOCommands.swift) and handoff (CLI/CLI+Handoff.swift).

use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

use super::{
    absolute, call, decode_escapes, emit, field, git_output, items, no_positionals, non_empty,
    parse_opts, put, str_or_empty, Command, Env, Opts, UsageError, SURFACE_ENV, WORKSPACE_ENV,
};

/// As on macOS (PaneHandoffFormatter).
const HANDOFF_LINES: u32 = 200;
const HANDOFF_MAX_LINES: u32 = 1000;

pub(crate) fn params(
    command: Command,
    args: &[String],
    env: Env,
) -> Result<Map<String, Value>, UsageError> {
    let name = command.name();
    let mut params = Map::new();
    let workspace = |opts: &Opts| {
        opts.value("--workspace")
            .or_else(|| env(WORKSPACE_ENV).and_then(non_empty))
    };
    match command {
        Command::CurrentWorkspace => {
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
        }
        Command::ListPanels => {
            let opts = parse_opts(command, args, &["--workspace"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace_id", workspace(&opts));
        }
        Command::FocusPanel => {
            let opts = parse_opts(command, args, &["--panel", "--workspace"], &[])?;
            no_positionals(command, &opts)?;
            let panel = opts
                .value("--panel")
                .ok_or_else(|| UsageError(format!("{name} requires --panel")))?;
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", Some(panel));
        }
        Command::SendPanel | Command::SendKeyPanel => {
            let opts = parse_opts(
                command,
                args,
                &["--panel", "--workspace"],
                &["--force", "--answer-prompt"],
            )?;
            let panel = opts
                .value("--panel")
                .ok_or_else(|| UsageError(format!("{name} requires --panel")))?;
            if command == Command::SendPanel {
                let text = opts.positionals.join(" ");
                if text.is_empty() {
                    return Err(UsageError(format!("{name} requires text")));
                }
                params.insert("text".into(), json!(decode_escapes(&text)));
            } else {
                let key = match opts.positionals.as_slice() {
                    [key] if !key.is_empty() => key.clone(),
                    [_, extra, ..] => {
                        return Err(UsageError(format!("{name}: unexpected argument '{extra}'")))
                    }
                    _ => return Err(UsageError(format!("{name} requires a key"))),
                };
                params.insert("key".into(), json!(key));
            }
            for (flag, key) in [("--force", "force"), ("--answer-prompt", "answer_prompt")] {
                if opts.has(flag) {
                    params.insert(key.into(), json!(true));
                }
            }
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", Some(panel));
        }
        Command::Handoff => {
            let opts = parse_opts(
                command,
                args,
                &["--from", "--lines", "--note", "--to"],
                &["--force"],
            )?;
            no_positionals(command, &opts)?;
            let from = opts
                .value("--from")
                .ok_or_else(|| UsageError("handoff: --from is required".into()))?;
            let lines = match opts.value("--lines") {
                None => HANDOFF_LINES,
                Some(raw) => raw
                    .parse::<u32>()
                    .ok()
                    .filter(|n| (1..=HANDOFF_MAX_LINES).contains(n))
                    .ok_or_else(|| {
                        UsageError(format!(
                            "handoff: --lines must be between 1 and {HANDOFF_MAX_LINES}"
                        ))
                    })?,
            };
            let to = opts
                .value("--to")
                .or_else(|| env(SURFACE_ENV).and_then(non_empty))
                .ok_or_else(|| {
                    UsageError(
                        "handoff: no target pane; pass --to <id|ref> or run inside a Programa pane"
                            .into(),
                    )
                })?;
            put(&mut params, "from", Some(from));
            put(&mut params, "to", Some(to));
            params.insert("lines".into(), json!(lines));
            put(&mut params, "note", opts.value("--note"));
            if opts.has("--force") {
                params.insert("force".into(), json!(true));
            }
        }
        Command::RecapOpen => {
            let opts = parse_opts(command, args, &["--workspace", "--window"], &[])?;
            let slug = match opts.positionals.as_slice() {
                [slug] if !slug.is_empty() => slug.clone(),
                [_, extra, ..] => {
                    return Err(UsageError(format!(
                        "recap open: unexpected argument '{extra}'. Usage: programa recap open <slug>"
                    )))
                }
                _ => {
                    return Err(UsageError(
                        "recap open requires <slug>. Usage: programa recap open <slug> [--workspace <id|ref|index>] [--window <id|ref|index>]"
                            .into(),
                    ))
                }
            };
            put(&mut params, "slug", Some(slug));
            put(&mut params, "direction", Some("right".into()));
            // As on macOS, this terminal's workspace unless another workspace or a window is
            // named; Windows also needs this terminal to split beside it.
            match (opts.value("--workspace"), opts.value("--window")) {
                (Some(workspace), _) => put(&mut params, "workspace_id", Some(workspace)),
                (None, None) => {
                    put(
                        &mut params,
                        "workspace_id",
                        env(WORKSPACE_ENV).and_then(non_empty),
                    );
                    put(
                        &mut params,
                        "surface_id",
                        env(SURFACE_ENV).and_then(non_empty),
                    );
                }
                (None, Some(_)) => {}
            }
            put(&mut params, "window_id", opts.value("--window"));
        }
        Command::RecapList => {
            let opts = parse_opts(command, args, &["--workspace", "--window"], &[])?;
            if let Some(extra) = opts.positionals.first() {
                return Err(UsageError(format!(
                    "recap list: unexpected argument '{extra}'. Usage: programa recap list"
                )));
            }
        }
        _ => unreachable!("not a panel command"),
    }
    Ok(params)
}

/// `OK` and the surface and workspace the result names, as macOS's v2OKSummary.
fn ok_summary(result: &Value) -> String {
    let mut line = "OK".to_owned();
    for key in ["surface_id", "workspace_id"] {
        if let Some(id) = result.get(key).and_then(Value::as_str) {
            line.push(' ');
            line.push_str(id);
        }
    }
    line + "\n"
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    match command {
        Command::CurrentWorkspace => format!("{}\n", field(result, "workspace_id")),
        Command::ListPanels => {
            let surfaces = items(result, "surfaces");
            if surfaces.is_empty() {
                return "No surfaces\n".to_owned();
            }
            surfaces
                .iter()
                .map(|surface| {
                    let focused = surface["focused"].as_bool() == Some(true);
                    let title = str_or_empty(surface, "title");
                    format!(
                        "{}{}  {}{}{}\n",
                        if focused { "* " } else { "  " },
                        str_or_empty(surface, "id"),
                        str_or_empty(surface, "type"),
                        if focused { "  [focused]" } else { "" },
                        if title.is_empty() {
                            String::new()
                        } else {
                            format!("  \"{title}\"")
                        }
                    )
                })
                .collect()
        }
        _ => ok_summary(result),
    }
}

/// handoff and recap, which are not one request.
pub(crate) fn run(
    command: Command,
    path: &str,
    params: &Map<String, Value>,
    json_output: bool,
) -> Option<i32> {
    let outcome = match command {
        Command::Handoff => handoff(path, params, json_output),
        Command::RecapOpen => recap_open(path, params, json_output),
        Command::RecapList => recap_list(json_output),
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

/// Pastes the source pane's last lines into the target terminal's prompt, never pressing Return.
fn handoff(path: &str, params: &Map<String, Value>, json_output: bool) -> Result<String, String> {
    let text = |key: &str| params.get(key).and_then(Value::as_str).unwrap_or_default();
    let (source, target) = (text("from"), text("to"));
    let listed = call(path, "surface.list", json!({ "surface_id": target }))
        .map_err(|_| format!("handoff: target pane {target} not found"))?;
    let row = items(&listed, "surfaces")
        .iter()
        .find(|row| {
            row["id"]
                .as_str()
                .is_some_and(|id| id.eq_ignore_ascii_case(target))
        })
        .ok_or_else(|| format!("handoff: target pane {target} not found"))?;
    if row["type"].as_str() != Some("terminal") {
        return Err(format!("handoff: target pane {target} is not a terminal"));
    }
    if source.eq_ignore_ascii_case(target) {
        return Err(
            "handoff: --from and the target are the same pane; pick another pane with --from"
                .into(),
        );
    }
    let read = call(
        path,
        "surface.read_text",
        json!({ "surface_id": source, "lines": params["lines"] }),
    )?;
    // The source's title, from the target's listing when both are in one workspace.
    let source_listing = if listed["workspace_id"] == read["workspace_id"] {
        Some(listed.clone())
    } else {
        call(
            path,
            "surface.list",
            json!({ "workspace_id": read["workspace_id"] }),
        )
        .ok()
    };
    let title = source_listing.and_then(|listing| {
        items(&listing, "surfaces")
            .iter()
            .find(|row| row["id"] == read["surface_id"])
            .map(|row| str_or_empty(row, "title").trim().to_owned())
            .filter(|title| !title.is_empty())
    });
    let label = match title {
        Some(title) => format!("{title} ({source})"),
        None => source.to_owned(),
    };
    let mut paste = json!({
        "surface_id": row["id"],
        "text": handoff_text(&label, str_or_empty(&read, "text"), params.get("note").and_then(Value::as_str)),
    });
    if params.contains_key("force") {
        paste["force"] = json!(true);
    }
    let result = call(path, "surface.send_paste", paste)?;
    Ok(if json_output {
        pretty(&result)
    } else {
        "OK\n".to_owned()
    })
}

/// As macOS's PaneHandoffFormatter: trailing blank lines dropped, ends with a newline.
fn handoff_text(label: &str, text: &str, note: Option<&str>) -> String {
    let normalized = text.replace("\r\n", "\n");
    let mut lines: Vec<&str> = normalized.split('\n').collect();
    while lines.last().is_some_and(|line| line.trim().is_empty()) {
        lines.pop();
    }
    let body = if lines.is_empty() {
        "(no output)".to_owned()
    } else {
        lines.join("\n")
    };
    let mut result = format!("Context from {label}:\n{body}\n");
    if let Some(note) = note.map(str::trim).filter(|note| !note.is_empty()) {
        result.push_str(&format!("\nNote: {note}\n"));
    }
    result
}

/// `<repo root>/.programa/recaps`, the root from the current directory, as on macOS.
fn recaps_directory() -> Result<PathBuf, String> {
    let cwd = std::env::current_dir()
        .map(|dir| dir.display().to_string())
        .unwrap_or_default();
    let root = git_output(Some(&cwd), &["rev-parse", "--show-toplevel"])
        .filter(|root| !root.is_empty())
        .ok_or_else(|| format!("recap: '{cwd}' is not inside a git repository"))?;
    // git prints forward slashes; the app and the messages use the Windows form.
    let programa = PathBuf::from(absolute(root)).join(".programa");
    ignore_itself(&programa);
    Ok(programa.join("recaps"))
}

/// An existing `.programa` gets a `.gitignore` of `*`, so `git add -A` never sweeps it in.
fn ignore_itself(directory: &Path) {
    let ignore = directory.join(".gitignore");
    if directory.is_dir() && !ignore.exists() {
        let _ = std::fs::write(ignore, "*\n");
    }
}

fn recap_slugs(directory: &Path) -> Vec<String> {
    let mut slugs: Vec<String> = std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "md"))
        .filter_map(|path| Some(path.file_stem()?.to_string_lossy().into_owned()))
        .collect();
    slugs.sort();
    slugs
}

fn recap_list(json_output: bool) -> Result<String, String> {
    let directory = recaps_directory()?;
    let slugs = recap_slugs(&directory);
    Ok(if json_output {
        pretty(&json!({ "recaps": slugs }))
    } else if slugs.is_empty() {
        format!("No recaps found in {}\n", directory.display())
    } else {
        slugs.iter().map(|slug| format!("{slug}\n")).collect()
    })
}

fn recap_open(
    path: &str,
    params: &Map<String, Value>,
    json_output: bool,
) -> Result<String, String> {
    let slug = params["slug"].as_str().unwrap_or_default();
    let file = recaps_directory()?.join(format!("{slug}.md"));
    if !file.is_file() {
        return Err(format!(
            "recap open: no recap found for '{slug}' (looked at {}). Run 'programa recap list' to see available recaps.",
            file.display()
        ));
    }
    let mut open = params.clone();
    open.remove("slug");
    open.insert("path".into(), json!(file.display().to_string()));
    let result = call(path, "markdown.open", Value::Object(open))?;
    Ok(if json_output {
        pretty(&result)
    } else {
        format!(
            "OK surface={} pane={} path={}\n",
            result["surface_id"].as_str().unwrap_or("unknown"),
            result["pane_id"].as_str().unwrap_or("unknown"),
            file.display()
        )
    })
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
            (&["current-workspace"][..], "workspace.current", json!({})),
            (
                &["list-panels"],
                "surface.list",
                json!({"workspace_id": "ws-env"}),
            ),
            (
                &["focus-panel", "--panel", "s2"],
                "surface.focus",
                json!({"workspace_id": "ws-env", "surface_id": "s2"}),
            ),
            (
                &["send-panel", "--panel", "s2", "--force", "echo", "hi\\n"],
                "surface.send_text",
                json!({"workspace_id": "ws-env", "surface_id": "s2", "text": "echo hi\n", "force": true}),
            ),
            (
                &[
                    "send-key-panel",
                    "--panel",
                    "s2",
                    "--answer-prompt",
                    "--",
                    "ctrl+c",
                ],
                "surface.send_key",
                json!({"workspace_id": "ws-env", "surface_id": "s2", "key": "ctrl+c", "answer_prompt": true}),
            ),
            (
                &["handoff", "--from", "s1", "--lines", "50", "--note", "why?"],
                "surface.send_paste",
                json!({"from": "s1", "to": "s-env", "lines": 50, "note": "why?"}),
            ),
            (
                &["recap", "open", "demo"],
                "markdown.open",
                json!({"slug": "demo", "direction": "right", "workspace_id": "ws-env", "surface_id": "s-env"}),
            ),
            (
                &["recap", "open", "demo", "--window", "win-2"],
                "markdown.open",
                json!({"slug": "demo", "direction": "right", "window_id": "win-2"}),
            ),
            (&["recap", "list"], "", json!({})),
        ] {
            assert_eq!(call(args).unwrap(), (method.to_owned(), params), "{args:?}");
        }
        for (args, message) in [
            (&["focus-panel"][..], "focus-panel requires --panel"),
            (&["send-panel", "--panel", "s"], "send-panel requires text"),
            (&["send-panel", "hi"], "send-panel requires --panel"),
            (&["send-key-panel", "--panel", "s"], "send-key-panel requires a key"),
            (&["handoff"], "handoff: --from is required"),
            (
                &["handoff", "--from", "a", "--lines", "1001"],
                "handoff: --lines must be between 1 and 1000",
            ),
            (
                &["recap", "open"],
                "recap open requires <slug>. Usage: programa recap open <slug> [--workspace <id|ref|index>] [--window <id|ref|index>]",
            ),
            (
                &["recap", "list", "x"],
                "recap list: unexpected argument 'x'. Usage: programa recap list",
            ),
            (&["recap"], "Usage: programa recap open <slug>|list"),
        ] {
            assert_eq!(call(args).unwrap_err(), message, "{args:?}");
        }
    }

    #[test]
    fn output_matches_macos() {
        let listed = json!({"surfaces": [
            {"id": "s1", "type": "terminal", "title": "pwsh", "focused": true},
            {"id": "s2", "type": "markdown", "title": "", "focused": false},
        ]});
        assert_eq!(
            render(Command::ListPanels, &listed),
            "* s1  terminal  [focused]  \"pwsh\"\n  s2  markdown\n"
        );
        assert_eq!(
            render(Command::ListPanels, &json!({"surfaces": []})),
            "No surfaces\n"
        );
        assert_eq!(
            render(Command::CurrentWorkspace, &json!({"workspace_id": "w1"})),
            "w1\n"
        );
        assert_eq!(
            render(
                Command::SendKeyPanel,
                &json!({"surface_id": "s", "workspace_id": "w", "window_id": "x"})
            ),
            "OK s w\n"
        );
        assert_eq!(render(Command::SendPanel, &json!({})), "OK\n");
        assert_eq!(
            handoff_text("pwsh (s1)", "a\r\nb\n\n  \n", Some(" why? ")),
            "Context from pwsh (s1):\na\nb\n\nNote: why?\n"
        );
        assert_eq!(
            handoff_text("s1", "\n", None),
            "Context from s1:\n(no output)\n"
        );
    }

    #[test]
    fn recaps_are_the_markdown_files_sorted() {
        let dir = std::env::temp_dir().join(format!("programa-recaps-{}", std::process::id()));
        let recaps = dir.join("recaps");
        std::fs::create_dir_all(&recaps).unwrap();
        for file in ["b.md", "a.md", "notes.txt"] {
            std::fs::write(recaps.join(file), "x").unwrap();
        }
        assert_eq!(recap_slugs(&recaps), ["a", "b"]);
        ignore_itself(&dir);
        assert_eq!(
            std::fs::read_to_string(dir.join(".gitignore")).unwrap(),
            "*\n"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
