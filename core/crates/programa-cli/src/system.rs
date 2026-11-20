//! System and local commands, as on macOS: rpc (CLI/Commands/SystemCommands.swift), agent-event
//! (CLI/CLI+HookCommands.swift), config check (CLI/CLI+ConfigCheck.swift), themes
//! (CLI/CLI+Themes.swift) and welcome (CLI/programa.swift, CLI+WelcomeShortcuts.swift).
//!
//! `config check` and `themes` run the app binary headless (`--check-settings`, `--themes`), as
//! macOS does for the check, so both use the app's own settings.json reader and writer.

use serde_json::{json, Map, Value};

use super::{
    absolute, call, emit, items, non_empty, parse_opts, put, str_or_empty, Command, Env, Opts,
    UsageError, SURFACE_ENV, WORKSPACE_ENV,
};

pub(crate) const AGENT_EVENTS: [&str; 11] = [
    "session.started",
    "session.exited",
    "turn.started",
    "turn.completed",
    "turn.aborted",
    "request.opened",
    "request.resolved",
    "user-input.requested",
    "user-input.resolved",
    "item.started",
    "item.completed",
];

pub(crate) fn params(
    command: Command,
    args: &[String],
    env: Env,
) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    match command {
        Command::Rpc => {
            let (method, rest) = match args.split_first() {
                Some((method, rest)) if !method.trim().is_empty() => (method.trim(), rest),
                _ => {
                    return Err(UsageError(
                        "Usage: programa rpc <method> [json-params]".into(),
                    ))
                }
            };
            let raw = rest.join(" ");
            let call_params = if raw.trim().is_empty() {
                json!({})
            } else {
                match serde_json::from_str::<Value>(raw.trim()) {
                    Ok(object @ Value::Object(_)) => object,
                    Ok(_) => return Err(UsageError("rpc params must be a JSON object".into())),
                    Err(err) => {
                        return Err(UsageError(format!("rpc params must be valid JSON: {err}")))
                    }
                }
            };
            params.insert("method".into(), json!(method));
            params.insert("params".into(), call_params);
        }
        Command::AgentEvent => {
            let flags = [
                "--event",
                "--provider",
                "--session-id",
                "--turn-id",
                "--item-id",
                "--label",
                "--resolution",
                "--workspace",
                "--surface",
            ];
            let opts = parse_opts(command, args, &flags, &[])?;
            if !opts.positionals.is_empty() {
                return Err(UsageError(format!(
                    "agent-event: unexpected arguments: {}",
                    opts.positionals.join(" ")
                )));
            }
            let event = opts
                .value("--event")
                .ok_or_else(|| UsageError("agent-event: --event is required".into()))?;
            if !AGENT_EVENTS.contains(&event.as_str()) {
                let mut valid = AGENT_EVENTS.to_vec();
                valid.sort_unstable();
                return Err(UsageError(format!(
                    "agent-event: invalid --event '{event}' \u{2014} use one of: {}",
                    valid.join(", ")
                )));
            }
            // As on macOS, this terminal is the default only when no --workspace is given.
            let workspace = opts
                .value("--workspace")
                .or_else(|| env(WORKSPACE_ENV).and_then(non_empty));
            let surface = opts.value("--surface").or_else(|| {
                opts.value("--workspace")
                    .is_none()
                    .then(|| env(SURFACE_ENV).and_then(non_empty))
                    .flatten()
            });
            put(&mut params, "event_type", Some(event));
            put(&mut params, "workspace_id", workspace);
            put(&mut params, "surface_id", surface);
            for (flag, key) in [
                ("--provider", "provider"),
                ("--session-id", "session_id"),
                ("--turn-id", "turn_id"),
                ("--item-id", "item_id"),
                ("--label", "label"),
                ("--resolution", "resolution"),
            ] {
                put(&mut params, key, opts.value(flag));
            }
        }
        Command::ConfigCheck => {
            let opts = parse_opts(command, args, &["--file"], &[])?;
            check_only(&opts)?;
            put(&mut params, "file", opts.value("--file").map(absolute));
        }
        // Parsed by the app (`programa.exe --themes`), which reads and writes settings.json.
        Command::Themes => {
            params.insert("args".into(), json!(args));
        }
        Command::Welcome => {
            let opts = parse_opts(command, args, &[], &[])?;
            super::no_positionals(command, &opts)?;
        }
        _ => unreachable!("not a system command"),
    }
    Ok(params)
}

/// `config` takes the one word `check` (named with it, as `config check`).
fn check_only(opts: &Opts) -> Result<(), UsageError> {
    match opts.positionals.first() {
        None => Ok(()),
        Some(_) => Err(UsageError(
            "config: expected 'check'. Usage: programa config check [--file <path>]".into(),
        )),
    }
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    match command {
        Command::AgentEvent => format!(
            "{}\n",
            result
                .get("state")
                .and_then(Value::as_str)
                .unwrap_or("cleared")
        ),
        _ => String::new(),
    }
}

/// The commands that are not one request with a rendered result.
pub(crate) fn run(
    command: Command,
    path: &str,
    params: &Map<String, Value>,
    json_output: bool,
    env: Env,
) -> Option<i32> {
    match command {
        // As on macOS, rpc prints the raw result whether or not --json is given.
        Command::Rpc => Some(
            match call(
                path,
                params["method"].as_str().unwrap_or_default(),
                params["params"].clone(),
            ) {
                Ok(result) => {
                    emit(&format!(
                        "{}\n",
                        serde_json::to_string_pretty(&result).unwrap_or_default()
                    ));
                    0
                }
                Err(message) => {
                    eprintln!("Error: {message}");
                    1
                }
            },
        ),
        Command::ConfigCheck => {
            let mut args = vec!["--check-settings".to_owned()];
            args.extend(
                params
                    .get("file")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            );
            Some(run_app(&args, "the settings check"))
        }
        Command::Themes => {
            let mut args = vec!["--themes".to_owned()];
            if json_output {
                args.push("--json".to_owned());
            }
            args.extend(
                items(&Value::Object(params.clone()), "args")
                    .iter()
                    .filter_map(|arg| arg.as_str().map(str::to_owned)),
            );
            Some(run_app(&args, "themes"))
        }
        Command::Welcome => {
            emit(&welcome(&shortcut_bindings(path), dark_mode(env)));
            Some(0)
        }
        _ => None,
    }
}

/// `programa claude-teams [claude-args...]`: Claude Code with agent teams on, as on macOS, and the
/// programa MCP server and hooks that a Programa terminal's `claude` adds. Teammates run in
/// process: macOS opens them as Programa panes through a `tmux` shim, but Claude Code's tmux
/// backend runs a `tmux` executable and types POSIX shell command lines into the panes it opens,
/// which a PowerShell pane cannot run.
pub(crate) fn run_claude_teams(args: &[String], env: Env) -> i32 {
    // The first PATH folder with claude.exe (native install) or claude.cmd (npm), as a shell finds it.
    let path = std::env::var_os("PATH").unwrap_or_default();
    let Some(claude) = std::env::split_paths(&path)
        .flat_map(|dir| [dir.join("claude.exe"), dir.join("claude.cmd")])
        .find(|file| file.is_file())
    else {
        eprintln!("Error: Failed to launch claude: it is not on PATH");
        return 1;
    };
    let given = |flag: &str| {
        args.iter()
            .any(|arg| arg == flag || arg.starts_with(&format!("{flag}=")))
    };
    let mut command = std::process::Command::new(claude);
    if !given("--teammate-mode") {
        command.args(["--teammate-mode", "in-process"]);
    }
    for (variable, flag, other) in [
        ("PROGRAMA_MCP_CONFIG", "--mcp-config", "--strict-mcp-config"),
        ("PROGRAMA_CLAUDE_SETTINGS", "--settings", "--settings"),
    ] {
        let file = env(variable).filter(|file| std::path::Path::new(file).is_file());
        if let (Some(file), false) = (file, given(flag) || given(other)) {
            command.arg(format!("{flag}={file}"));
        }
    }
    ignore_ctrl_c();
    match command
        .args(args)
        .env("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "1")
        .status()
    {
        Ok(status) => status.code().unwrap_or(1),
        Err(err) => {
            eprintln!("Error: Failed to launch claude: {err}");
            1
        }
    }
}

/// Ctrl+C is Claude's while it runs: this process must not exit and hand the console back.
#[cfg(windows)]
fn ignore_ctrl_c() {
    #[link(name = "kernel32")]
    extern "system" {
        fn SetConsoleCtrlHandler(
            handler: Option<unsafe extern "system" fn(u32) -> i32>,
            add: i32,
        ) -> i32;
    }
    // Handled here rather than ignored (a null handler), which Claude would inherit.
    unsafe extern "system" fn handled(_: u32) -> i32 {
        1
    }
    // SAFETY: registers a handler that only returns TRUE, valid for the process lifetime.
    unsafe {
        SetConsoleCtrlHandler(Some(handled), 1);
    }
}

#[cfg(not(windows))]
fn ignore_ctrl_c() {}

/// The app this CLI ships with: `bin\programa.exe` sits in the app's folder.
fn app_executable() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let app = exe.parent()?.parent()?.join("programa.exe");
    app.is_file().then_some(app)
}

/// Runs the app headless with its output passed through; exits 2 when it cannot run, as macOS's
/// `config check` (1 is its "problems found").
fn run_app(args: &[String], what: &str) -> i32 {
    let Some(app) = app_executable() else {
        eprintln!(
            "Error: could not find the Programa app this CLI belongs to. Run the programa CLI that ships with Programa (bin\\programa.exe in its folder)."
        );
        return 2;
    };
    // Piped, not inherited: a GUI-subsystem app writes to pipes, not to a console it is not attached to.
    let output = std::process::Command::new(&app)
        .args(args)
        .stdin(std::process::Stdio::null())
        .output();
    match output {
        Ok(output) => {
            emit(&String::from_utf8_lossy(&output.stdout));
            eprint!("{}", String::from_utf8_lossy(&output.stderr));
            output.status.code().unwrap_or(2)
        }
        Err(err) => {
            eprintln!("Error: could not run {}: {err} ({what})", app.display());
            2
        }
    }
}

/// The welcome screen's shortcuts: the running app's bindings, else the Windows defaults.
const WELCOME_SHORTCUTS: [(&str, &str, &str); 8] = [
    ("new_workspace", "Ctrl+Shift+N", "New workspace"),
    ("new_tab", "Ctrl+Shift+T", "New tab"),
    ("go_to_workspace", "Ctrl+Alt+Shift+P", "Go to workspace"),
    ("split_vertical", "Ctrl+Shift+D", "Split right"),
    ("split_horizontal", "Ctrl+Shift+E", "Split down"),
    ("command_palette", "Ctrl+Shift+P", "Command palette"),
    ("rename_workspace", "Ctrl+Shift+R", "Rename workspace"),
    ("jump_to_unread", "Ctrl+Shift+U", "Jump to latest unread"),
];

/// Bindings by action id from shortcuts.list; empty when Programa is not running.
fn shortcut_bindings(path: &str) -> Vec<(String, String)> {
    call(path, "shortcuts.list", json!({}))
        .map(|result| {
            items(&result, "shortcuts")
                .iter()
                .filter(|row| !str_or_empty(row, "display_string").is_empty())
                .map(|row| {
                    (
                        str_or_empty(row, "id").to_owned(),
                        str_or_empty(row, "display_string").to_owned(),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Whether Windows apps use the dark theme (AppsUseLightTheme is 0).
fn dark_mode(env: Env) -> bool {
    let _ = env;
    std::process::Command::new("reg")
        .args([
            "query",
            r"HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "/v",
            "AppsUseLightTheme",
        ])
        .output()
        .is_ok_and(|output| String::from_utf8_lossy(&output.stdout).contains("0x0"))
}

/// The macOS welcome screen: the logo and wordmark, the shortcuts and the links.
fn welcome(bindings: &[(String, String)], dark: bool) -> String {
    let reset = "\x1b[0m";
    let bold = "\x1b[1m";
    let rgb = |(r, g, b): (u8, u8, u8)| format!("\x1b[38;2;{r};{g};{b}m");
    let (rows, cursor, letters, tagline, subdued) = if dark {
        (
            [(255, 107, 82), (240, 64, 42), (220, 46, 30), (194, 31, 22)],
            (255, 138, 102),
            [
                (255, 107, 82),
                (248, 90, 62),
                (240, 74, 46),
                (230, 60, 36),
                (220, 46, 30),
                (210, 38, 26),
                (194, 31, 22),
                (194, 31, 22),
            ],
            rgb((140, 130, 136)),
            "\x1b[2m".to_owned(),
        )
    } else {
        (
            [(232, 68, 46), (212, 47, 31), (194, 31, 22), (162, 24, 17)],
            (232, 68, 46),
            [
                (232, 68, 46),
                (222, 56, 38),
                (212, 47, 31),
                (202, 39, 26),
                (194, 31, 22),
                (178, 27, 19),
                (162, 24, 17),
                (162, 24, 17),
            ],
            rgb((90, 90, 98)),
            rgb((100, 100, 108)),
        )
    };
    let wordmark: String = "programa"
        .chars()
        .zip(letters)
        .map(|(letter, color)| format!("{}{letter}", rgb(color)))
        .collect::<String>()
        + reset;
    let [r1, r2, r3, r4] = rows.map(rgb);
    let cursor = rgb(cursor);
    let mut out = String::from("\n");
    out += &format!("{r1}\u{2596}\u{2596} \u{2591}\u{2591} \u{2592}\u{2592} \u{2593}\u{2593}{reset}        {wordmark}\n");
    out += &format!(
        "{r2}\u{2591}\u{2591} \u{2592}\u{2592} \u{2593}\u{2593} \u{2588}\u{2588}{reset}\n"
    );
    out += &format!("{r3}\u{2592}\u{2592} \u{2593}\u{2593} \u{2588}\u{2588} \u{2588}\u{2588}{reset}        {tagline}the open source terminal{reset}\n");
    out += &format!("{r4}\u{2593}\u{2593} \u{2588}\u{2588} \u{2588}\u{2588} {cursor}\u{2588}\u{2588}{reset}        {tagline}built for coding agents{reset}\n");
    out += &format!("\n  {bold}Shortcuts{reset}\n\n");
    for (action, fallback, label) in WELCOME_SHORTCUTS {
        let keys = bindings
            .iter()
            .find(|(id, _)| id == action)
            .map_or(fallback, |(_, keys)| keys.as_str());
        let padding = " ".repeat(20usize.saturating_sub(keys.chars().count()).max(1));
        out += &format!("  {bold}{keys}{reset}{subdued}{padding}{label}{reset}\n");
    }
    out += "\n";
    for (name, link) in [
        (
            "Docs",
            "https://github.com/darkroomengineering/programa/tree/main/docs",
        ),
        ("X", "https://x.com/darkroomdevs"),
        (
            "GitHub",
            "https://github.com/darkroomengineering/programa (please leave a star \u{2b50})",
        ),
        (
            "Issues",
            "https://github.com/darkroomengineering/programa/issues",
        ),
    ] {
        let padding = " ".repeat(20 - name.len());
        out += &format!("  {bold}{name}{reset}{subdued}{padding}{link}{reset}\n");
    }
    out += "\n";
    for (command, what) in [
        ("programa --help", "for all commands."),
        ("programa shortcuts", "to edit shortcuts."),
        ("programa feedback", "to report a bug."),
    ] {
        out += &format!("  {subdued}Run {reset}{bold}{command}{reset}{subdued} {what}{reset}\n");
    }
    out + "\n"
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
                &["rpc", "surface.list", "{\"workspace_id\":", "\"w\"}"][..],
                "",
                json!({"method": "surface.list", "params": {"workspace_id": "w"}}),
            ),
            (
                &["rpc", "system.ping"],
                "",
                json!({"method": "system.ping", "params": {}}),
            ),
            (
                &[
                    "agent-event",
                    "--event",
                    "turn.started",
                    "--provider",
                    "codex",
                ],
                "agent.event",
                json!({"event_type": "turn.started", "provider": "codex", "workspace_id": "ws-env", "surface_id": "s-env"}),
            ),
            (
                &[
                    "agent-event",
                    "--event",
                    "session.exited",
                    "--workspace",
                    "w2",
                ],
                "agent.event",
                json!({"event_type": "session.exited", "workspace_id": "w2"}),
            ),
            (&["config", "check"], "", json!({})),
            (
                &["themes", "set", "--light", "Dracula"],
                "",
                json!({"args": ["set", "--light", "Dracula"]}),
            ),
            (&["welcome"], "shortcuts.list", json!({})),
        ] {
            assert_eq!(call(args).unwrap(), (method.to_owned(), params), "{args:?}");
        }
        for (args, message) in [
            (&["rpc"][..], "Usage: programa rpc <method> [json-params]"),
            (&["rpc", "m", "[1]"], "rpc params must be a JSON object"),
            (&["agent-event"], "agent-event: --event is required"),
            (
                &["agent-event", "--event", "x"],
                "agent-event: invalid --event 'x' \u{2014} use one of: item.completed, item.started, request.opened, request.resolved, session.exited, session.started, turn.aborted, turn.completed, turn.started, user-input.requested, user-input.resolved",
            ),
            (
                &["agent-event", "--event", "turn.started", "extra"],
                "agent-event: unexpected arguments: extra",
            ),
            (
                &["config"],
                "config: expected 'check'. Usage: programa config check [--file <path>]",
            ),
            (
                &["config", "lint"],
                "config: expected 'check'. Usage: programa config check [--file <path>]",
            ),
        ] {
            assert_eq!(call(args).unwrap_err(), message, "{args:?}");
        }
        assert!(call(&["rpc", "m", "{"])
            .unwrap_err()
            .starts_with("rpc params must be valid JSON: "));
    }

    #[test]
    fn output_matches_macos() {
        assert_eq!(
            render(Command::AgentEvent, &json!({"state": "working"})),
            "working\n"
        );
        assert_eq!(render(Command::AgentEvent, &json!({})), "cleared\n");
        let screen = welcome(&[("new_tab".into(), "Ctrl+T".into())], true);
        assert!(screen.contains("\x1b[1mCtrl+T\x1b[0m\x1b[2m              New tab"));
        assert!(screen.contains("Ctrl+Shift+N"));
        assert!(screen.contains("\x1b[38;2;255;107;82mp"));
    }
}
