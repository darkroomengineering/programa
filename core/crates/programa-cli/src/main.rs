//! `programa`: the command-line client for a running Programa. Each command
//! becomes one v2 protocol request (`{"id","method","params"}`) sent over the
//! app's named pipe (Windows) or Unix socket, and the result is printed either
//! as a short human line or, with `--json`, as the raw result.
//!
//! Everything except the transport is pure (argv + env in, request out;
//! result JSON in, text out) so it is unit tested without a server.

mod codex;
mod hook;
mod panes;
mod permission;
mod sidebar;
mod transport;
mod usage;

use std::collections::HashMap;
use std::io::Write;

use serde_json::{json, Map, Value};

use transport::{TransportError, ENDPOINT_KIND};

const USAGE: &str = r"programa - control a running Programa from the command line

Usage: programa [--json] [--socket PATH] <command> [args...]

Commands:
  ping                                  Check that Programa is running
  identify [--surface ID]               Print the surface and workspace ids
  tree                                  List workspaces and their surfaces
  list-workspaces                       List workspaces
  new-workspace [--cwd DIR] [--command CMD] [--name T]
  new-surface [--workspace ID] [--pane ID] [--cwd DIR] [--command CMD]
  new-split [left|right|up|down] [--surface ID] [--cwd DIR] [--command CMD]
  select-workspace <ID>
  close-workspace [--workspace ID]
  rename-workspace <TITLE> [--workspace ID]
  focus-surface <ID>
  close-surface [--surface ID]
  send [--surface ID] <TEXT>            Escapes: \n \r \t \e \\
  read-screen [--surface ID] [--lines N] [--scrollback]
  notify --title T [--subtitle S] [--body B] [--workspace ID] [--surface ID]
  list-notifications
  clear-notifications [--workspace ID]
  set-status <KEY> <VALUE> [--icon NAME] [--color #HEX] [--url URL] [--priority N]
             [--format plain|markdown] [--pid PID] [--workspace ID]
                                        Show a status entry in the workspace's sidebar row
  clear-status <KEY> [--workspace ID]
  list-status [--workspace ID]
  set-progress <0.0-1.0> [--label TEXT] [--workspace ID]
  clear-progress [--workspace ID]
  log [--level info|progress|success|warning|error] [--source NAME] [--workspace ID] [--] <MESSAGE>
  clear-log [--workspace ID]
  list-log [--limit N] [--workspace ID]
  sidebar-state [--workspace ID]        Everything the workspace's sidebar row shows
  list-panes [--workspace ID]           Panes in layout order, the focused one starred
  list-pane-surfaces [--workspace ID] [--pane ID]
  focus-pane <ID> | --pane ID [--workspace ID]
  new-pane [--direction left|right|up|down] [--type terminal] [--workspace ID]
  resize-pane [-L|-R|-U|-D] [--amount CELLS] [--pane ID] [--workspace ID]
  swap-pane --pane ID --target-pane ID  Swap the two panes' selected tabs
  break-pane [--pane ID] [--surface ID] [--workspace ID]
                                        Move a tab into a new workspace of its own
  join-pane --target-pane ID [--pane ID] [--surface ID]
                                        Move a tab (default: the pane's selected one) into another pane
  last-pane [--workspace ID]            Focus the other pane
  next-window | previous-window | last-window
                                        Select the next, previous or last selected workspace
  reorder-workspace <ID> (--index N | --before ID | --after ID) [--window ID]
  set-agent-state <working|blocked|idle|clear> [--surface ID] [--source NAME]
  list-ports                            List ports that terminals listen on
  stop-port <PORT> | --pid PID          Stop the process listening on a port
  worktree create <BRANCH> [--base REF] [--path DIR] [--repo DIR] [--focus]
  worktree open <PATH|BRANCH> [--repo DIR] [--focus] | worktree open --all [--repo DIR]
  worktree remove <PATH|BRANCH> [--repo DIR] [--force]
  worktree list [--repo DIR]            --repo defaults to the current directory
  wait-surface [--surface ID] (--pattern REGEX | --exit | --agent-state STATE | --program-state STATE)
               [--timeout SECONDS] [--lines N]
                                        Block until a surface meets the condition (default timeout 30 s)
  prompt-agent [--surface ID] [--timeout SECONDS] [--working-grace SECONDS] [--force]
               [--answer-prompt] [--] <TEXT>
                                        Send a prompt and wait for the agent to finish (default 120 s)
  routes                                Event routes from programa.json: counters, last errors, issues
  usage [--workspace ID]                Tokens each recorded Claude Code and Codex session used, by workspace
  codex install-integration [--yes]     Add Programa's hooks to Codex (hooks.json and their trust in config.toml)
  codex uninstall-integration [--yes]   Remove them
  watch-events [--agent-state] [--workspace-lifecycle] [--needs-input] [--output ID[,ID...]]
               [--no-reconnect]         Print pushed events as JSON lines until stopped
  move-surface [--surface ID] (--pane ID | --workspace ID | --window ID|new)
               [--before ID | --after ID | --index N] [--focus true|false]
                                        Move a tab to a pane, another workspace or window, or a new window
  storage scan                          Worktree and package cache disk usage, and what is removable
  storage clean [--dry-run] [--include-external] [--now] [--path DIR]...
                [--packages | --caches] [--item ID]...
                                        Remove merged, clean, idle worktrees (never --force, branches
                                        kept); caches only when --packages, --caches or --item is given
  layout save <NAME> [--force]          Save the selected workspace's panes and splits
  layout apply <NAME> [--workspace ID] [--cwd DIR]
  layout list
  markdown [open] <FILE> [--surface ID] [--direction right|down] [--focus]
  review open [--surface ID] [--mode worktree|branch] [--base-branch REF] [--direction D] [--focus]
  review refresh [--surface REVIEW]
  review comment add <FILE> <START>[-<END>] <TEXT> [--surface REVIEW]
  review comment remove <ID> [--surface REVIEW]
  review comment list [--surface REVIEW]
  review send [--surface REVIEW] [--preamble TEXT]
  resume [--surface ID] [--print] [--session ID [--provider claude|codex|opencode]] [--force]
  race <PROMPT> [--n 1-8] [--agent claude|opencode|codex] [--base REF] [--prefix P] [--layout NAME]
  worktree create also takes --layout NAME, and --from-issue N [--agent A] instead of a branch
  workspace-action <ACTION> [--workspace ID] [--title T] [--color NAME|#RRGGBB] [--description T]
      pin unpin rename clear-name set-description clear-description move-up move-down
      move-top close-others close-above close-below mark-read set-color clear-color
  list-windows | current-window | new-window
  focus-window --window ID | close-window --window ID
  move-workspace-to-window [--workspace ID] --window ID|new
  help                                  Show this help

Global flags:
  --json             Print the raw JSON result
  --socket PATH      Pipe or socket to connect to
  -h, --help         Show this help
  -V, --version      Show the version

Use `--` before an argument that starts with '-' (e.g. programa send -- -x).

Environment:
  PROGRAMA_SOCKET_PATH, PROGRAMA_SOCKET
      Pipe path when --socket is not given
      (default on Windows: \\.\pipe\programa-%USERNAME%)
  PROGRAMA_SURFACE_ID, PROGRAMA_WORKSPACE_ID
      Default --surface / --workspace (not used by new-workspace,
      list-* or tree); without them Programa uses the focused one
";

/// Environment lookup, injected so tests never read or mutate the process env.
type Env<'a> = &'a dyn Fn(&str) -> Option<String>;

const SURFACE_ENV: &str = "PROGRAMA_SURFACE_ID";
const WORKSPACE_ENV: &str = "PROGRAMA_WORKSPACE_ID";
const AGENT_STATES: [&str; 4] = ["working", "blocked", "idle", "clear"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Command {
    Ping,
    Identify,
    Tree,
    ListWorkspaces,
    NewWorkspace,
    NewSurface,
    NewSplit,
    SelectWorkspace,
    CloseWorkspace,
    RenameWorkspace,
    FocusSurface,
    CloseSurface,
    Send,
    ReadScreen,
    Notify,
    ListNotifications,
    ClearNotifications,
    SetAgentState,
    ListPorts,
    StopPort,
    WorktreeCreate,
    WorktreeOpen,
    WorktreeRemove,
    WorktreeList,
    LayoutSave,
    LayoutApply,
    LayoutList,
    MarkdownOpen,
    ReviewOpen,
    ReviewRefresh,
    ReviewCommentAdd,
    ReviewCommentRemove,
    ReviewCommentList,
    ReviewSend,
    Resume,
    Race,
    WorkspaceAction,
    ListWindows,
    CurrentWindow,
    NewWindow,
    FocusWindow,
    CloseWindow,
    MoveWorkspaceToWindow,
    StorageScan,
    StorageClean,
    MoveSurface,
    WaitSurface,
    PromptAgent,
    WatchEvents,
    Routes,
    Usage,
    SetStatus,
    ClearStatus,
    ListStatus,
    SetProgress,
    ClearProgress,
    Log,
    ClearLog,
    ListLog,
    SidebarState,
    ListPanes,
    ListPaneSurfaces,
    FocusPane,
    NewPane,
    ResizePane,
    SwapPane,
    BreakPane,
    JoinPane,
    LastPane,
    NextWindow,
    PreviousWindow,
    LastWindow,
    ReorderWorkspace,
}

impl Command {
    const ALL: [Command; 73] = [
        Command::Ping,
        Command::Identify,
        Command::Tree,
        Command::ListWorkspaces,
        Command::NewWorkspace,
        Command::NewSurface,
        Command::NewSplit,
        Command::SelectWorkspace,
        Command::CloseWorkspace,
        Command::RenameWorkspace,
        Command::FocusSurface,
        Command::CloseSurface,
        Command::Send,
        Command::ReadScreen,
        Command::Notify,
        Command::ListNotifications,
        Command::ClearNotifications,
        Command::SetAgentState,
        Command::ListPorts,
        Command::StopPort,
        Command::WorktreeCreate,
        Command::WorktreeOpen,
        Command::WorktreeRemove,
        Command::WorktreeList,
        Command::LayoutSave,
        Command::LayoutApply,
        Command::LayoutList,
        Command::MarkdownOpen,
        Command::ReviewOpen,
        Command::ReviewRefresh,
        Command::ReviewCommentAdd,
        Command::ReviewCommentRemove,
        Command::ReviewCommentList,
        Command::ReviewSend,
        Command::Resume,
        Command::Race,
        Command::WorkspaceAction,
        Command::ListWindows,
        Command::CurrentWindow,
        Command::NewWindow,
        Command::FocusWindow,
        Command::CloseWindow,
        Command::MoveWorkspaceToWindow,
        Command::StorageScan,
        Command::StorageClean,
        Command::MoveSurface,
        Command::WaitSurface,
        Command::PromptAgent,
        Command::WatchEvents,
        Command::Routes,
        Command::Usage,
        Command::SetStatus,
        Command::ClearStatus,
        Command::ListStatus,
        Command::SetProgress,
        Command::ClearProgress,
        Command::Log,
        Command::ClearLog,
        Command::ListLog,
        Command::SidebarState,
        Command::ListPanes,
        Command::ListPaneSurfaces,
        Command::FocusPane,
        Command::NewPane,
        Command::ResizePane,
        Command::SwapPane,
        Command::BreakPane,
        Command::JoinPane,
        Command::LastPane,
        Command::NextWindow,
        Command::PreviousWindow,
        Command::LastWindow,
        Command::ReorderWorkspace,
    ];

    fn from_name(name: &str) -> Option<Command> {
        Command::ALL.into_iter().find(|c| c.name() == name)
    }

    fn name(self) -> &'static str {
        match self {
            Command::Ping => "ping",
            Command::Identify => "identify",
            Command::Tree => "tree",
            Command::ListWorkspaces => "list-workspaces",
            Command::NewWorkspace => "new-workspace",
            Command::NewSurface => "new-surface",
            Command::NewSplit => "new-split",
            Command::SelectWorkspace => "select-workspace",
            Command::CloseWorkspace => "close-workspace",
            Command::RenameWorkspace => "rename-workspace",
            Command::FocusSurface => "focus-surface",
            Command::CloseSurface => "close-surface",
            Command::Send => "send",
            Command::ReadScreen => "read-screen",
            Command::Notify => "notify",
            Command::ListNotifications => "list-notifications",
            Command::ClearNotifications => "clear-notifications",
            Command::SetAgentState => "set-agent-state",
            Command::ListPorts => "list-ports",
            Command::StopPort => "stop-port",
            Command::WorktreeCreate => "worktree create",
            Command::WorktreeOpen => "worktree open",
            Command::WorktreeRemove => "worktree remove",
            Command::WorktreeList => "worktree list",
            Command::LayoutSave => "layout save",
            Command::LayoutApply => "layout apply",
            Command::LayoutList => "layout list",
            Command::MarkdownOpen => "markdown open",
            Command::ReviewOpen => "review open",
            Command::ReviewRefresh => "review refresh",
            Command::ReviewCommentAdd => "review comment add",
            Command::ReviewCommentRemove => "review comment remove",
            Command::ReviewCommentList => "review comment list",
            Command::ReviewSend => "review send",
            Command::Resume => "resume",
            Command::Race => "race",
            Command::WorkspaceAction => "workspace-action",
            Command::ListWindows => "list-windows",
            Command::CurrentWindow => "current-window",
            Command::NewWindow => "new-window",
            Command::FocusWindow => "focus-window",
            Command::CloseWindow => "close-window",
            Command::MoveWorkspaceToWindow => "move-workspace-to-window",
            Command::StorageScan => "storage scan",
            Command::StorageClean => "storage clean",
            Command::MoveSurface => "move-surface",
            Command::WaitSurface => "wait-surface",
            Command::PromptAgent => "prompt-agent",
            Command::WatchEvents => "watch-events",
            Command::Routes => "routes",
            Command::Usage => "usage",
            Command::SetStatus => "set-status",
            Command::ClearStatus => "clear-status",
            Command::ListStatus => "list-status",
            Command::SetProgress => "set-progress",
            Command::ClearProgress => "clear-progress",
            Command::Log => "log",
            Command::ClearLog => "clear-log",
            Command::ListLog => "list-log",
            Command::SidebarState => "sidebar-state",
            Command::ListPanes => "list-panes",
            Command::ListPaneSurfaces => "list-pane-surfaces",
            Command::FocusPane => "focus-pane",
            Command::NewPane => "new-pane",
            Command::ResizePane => "resize-pane",
            Command::SwapPane => "swap-pane",
            Command::BreakPane => "break-pane",
            Command::JoinPane => "join-pane",
            Command::LastPane => "last-pane",
            Command::NextWindow => "next-window",
            Command::PreviousWindow => "previous-window",
            Command::LastWindow => "last-window",
            Command::ReorderWorkspace => "reorder-workspace",
        }
    }

    fn method(self) -> &'static str {
        match self {
            Command::Ping => "system.ping",
            Command::Identify => "system.identify",
            Command::Tree | Command::ListWorkspaces => "workspace.list",
            Command::NewWorkspace => "workspace.create",
            Command::NewSurface => "surface.create",
            Command::NewSplit => "surface.split",
            Command::SelectWorkspace => "workspace.select",
            Command::CloseWorkspace => "workspace.close",
            Command::RenameWorkspace => "workspace.rename",
            Command::FocusSurface => "surface.focus",
            Command::CloseSurface => "surface.close",
            Command::Send => "surface.send_text",
            Command::ReadScreen => "surface.read_text",
            Command::Notify => "notification.create",
            Command::ListNotifications => "notification.list",
            Command::ClearNotifications => "notification.clear",
            Command::SetAgentState => "surface.report_agent_state",
            Command::ListPorts => "ports.list",
            Command::StopPort => "ports.stop",
            Command::WorktreeCreate => "worktree.create",
            Command::WorktreeOpen => "worktree.open",
            Command::WorktreeRemove => "worktree.remove",
            Command::WorktreeList => "worktree.list",
            Command::LayoutSave => "layout.save",
            Command::LayoutApply => "layout.apply",
            Command::LayoutList => "layout.list",
            Command::MarkdownOpen => "markdown.open",
            Command::ReviewOpen => "review.open",
            Command::ReviewRefresh => "review.refresh",
            Command::ReviewCommentAdd => "review.comment.add",
            Command::ReviewCommentRemove => "review.comment.remove",
            Command::ReviewCommentList => "review.comment.list",
            Command::ReviewSend => "review.send_comments",
            Command::Resume => "surface.resume_agent",
            Command::Race => "worktree.create",
            Command::WorkspaceAction => "workspace.action",
            Command::ListWindows => "window.list",
            Command::CurrentWindow => "window.current",
            Command::NewWindow => "window.create",
            Command::FocusWindow => "window.focus",
            Command::CloseWindow => "window.close",
            Command::MoveWorkspaceToWindow => "workspace.move_to_window",
            Command::StorageScan => "storage.scan",
            Command::StorageClean => "storage.clean",
            Command::MoveSurface => "surface.move",
            Command::WaitSurface => "surface.wait",
            Command::PromptAgent => "agent.prompt",
            Command::WatchEvents => "subscribe",
            Command::Routes => "routes.list",
            Command::Usage => "window.list",
            Command::SetStatus => "workspace.set_status",
            Command::ClearStatus => "workspace.clear_status",
            Command::ListStatus => "workspace.list_status",
            Command::SetProgress => "workspace.set_progress",
            Command::ClearProgress => "workspace.clear_progress",
            Command::Log => "workspace.log",
            Command::ClearLog => "workspace.clear_log",
            Command::ListLog => "workspace.list_log",
            Command::SidebarState => "workspace.sidebar_state",
            Command::ListPanes => "pane.list",
            Command::ListPaneSurfaces => "pane.surfaces",
            Command::FocusPane => "pane.focus",
            Command::NewPane => "pane.create",
            Command::ResizePane => "pane.resize",
            Command::SwapPane => "pane.swap",
            Command::BreakPane => "pane.break",
            Command::JoinPane => "pane.join",
            Command::LastPane => "pane.last",
            Command::NextWindow => "workspace.next",
            Command::PreviousWindow => "workspace.previous",
            Command::LastWindow => "workspace.last",
            Command::ReorderWorkspace => "workspace.reorder",
        }
    }
}

#[derive(Debug, PartialEq)]
struct Request {
    command: Command,
    params: Map<String, Value>,
}

impl Request {
    fn to_line(&self, id: u64) -> String {
        json!({
            "id": id,
            "method": self.command.method(),
            "params": Value::Object(self.params.clone()),
        })
        .to_string()
    }
}

#[derive(Debug, PartialEq)]
enum Invocation {
    Help,
    Version,
    Call {
        json: bool,
        socket: Option<String>,
        request: Request,
    },
}

#[derive(Debug, PartialEq)]
struct UsageError(String);

fn main() {
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    let env = |key: &str| std::env::var(key).ok();
    std::process::exit(run(&args, &env));
}

fn run(args: &[String], env: Env) -> i32 {
    if args.first().map(String::as_str) == Some("codex-hook") {
        let mut input = String::new();
        let _ = std::io::Read::read_to_string(
            &mut std::io::Read::take(std::io::stdin(), 1 << 20),
            &mut input,
        );
        let event = args.get(1).map_or("", String::as_str);
        usage::record_hook(usage::Agent::Codex, event, &input, env, now_seconds());
        let path = resolve_socket_path(None, env);
        for (line, _) in hook::codex_request_lines(event, &input, env) {
            let _ = transport::round_trip(&path, &line);
        }
        // Codex reads the hook's stdout; an empty JSON object asks for nothing.
        emit("{}\n");
        return 0;
    }
    if args.first().map(String::as_str) == Some("codex") {
        let yes = args.iter().any(|arg| arg == "--yes" || arg == "-y");
        let exe = std::env::current_exe()
            .map_or_else(|_| "programa".to_owned(), |path| path.display().to_string());
        return match args.get(1).map(String::as_str) {
            Some("install-integration") => codex::run(true, yes, env, &exe),
            Some("uninstall-integration") => codex::run(false, yes, env, &exe),
            _ => {
                eprintln!(
                    "Usage: programa codex <install-integration|uninstall-integration> [--yes]"
                );
                2
            }
        };
    }
    if args.first().map(String::as_str) == Some("claude-hook") {
        // Claude Code's hook input on stdin; never more than a few KB, capped in case.
        let mut input = String::new();
        let _ = std::io::Read::read_to_string(
            &mut std::io::Read::take(std::io::stdin(), 1 << 20),
            &mut input,
        );
        let event = args.get(1).map_or("", String::as_str);
        match event {
            "prompt-submit" | "stop" | "session-end" => permission::forget_session(&input, env),
            "permission-request" => permission::record(&input, env),
            "subagent-stop" => permission::forget_subagent(&input, env),
            _ => {}
        }
        // Another agent's prompt is still up in this pane: its stop for input goes on.
        if event == "post-tool-use" && !permission::tool_ends_stop(&input, env) {
            usage::record_hook(usage::Agent::Claude, event, &input, env, now_seconds());
            return 0;
        }
        let question = serde_json::from_str::<Value>(&input)
            .ok()
            .and_then(|value| value["session_id"].as_str().map(str::to_owned))
            .filter(|_| event == "notification")
            .and_then(|session| usage::pending_question(&session, env));
        usage::record_hook(usage::Agent::Claude, event, &input, env, now_seconds());
        let path = resolve_socket_path(None, env);
        for (line, fallback) in hook::request_lines(event, &input, env, question.as_deref()) {
            let refused = transport::round_trip(&path, &line)
                .map_err(|_| String::new())
                .and_then(|reply| parse_response(&reply))
                .is_err();
            if let (true, Some(fallback)) = (refused, fallback) {
                let _ = transport::round_trip(&path, &fallback);
            }
        }
        return 0;
    }
    let invocation = match parse_invocation(args, env) {
        Ok(invocation) => invocation,
        Err(UsageError(message)) => {
            eprintln!("Error: {message}");
            eprintln!("Run 'programa help' for usage.");
            return 2;
        }
    };
    let (json, socket, request) = match invocation {
        Invocation::Help => {
            emit(USAGE);
            return 0;
        }
        Invocation::Version => {
            emit(&format!("programa {}\n", env!("CARGO_PKG_VERSION")));
            return 0;
        }
        Invocation::Call {
            json,
            socket,
            request,
        } => (json, socket, request),
    };

    let path = resolve_socket_path(socket.as_deref(), env);
    if request.command == Command::WatchEvents {
        return run_watch_events(&path, &request.params);
    }
    if request.command == Command::Race {
        return run_race(&path, &request.params);
    }
    if request.command == Command::ResizePane {
        return panes::run_resize(&path, &request.params, json);
    }
    if request.command == Command::Usage {
        return run_usage(&path, &request.params, json, env);
    }
    if request.command == Command::WorktreeOpen && request.params.contains_key("all") {
        return run_open_all(&path, &request.params);
    }
    let mut request = request;
    if let Some(number) = request.params.remove("from_issue").and_then(|n| n.as_u64()) {
        let agent = request.params.remove("agent");
        let repo = text_param(&request.params, "repo")
            .unwrap_or(".")
            .to_owned();
        match issue_worktree(&repo, number, agent.as_ref().and_then(Value::as_str)) {
            Ok((branch, command)) => {
                if !request.params.contains_key("branch") {
                    request.params.insert("branch".to_owned(), json!(branch));
                }
                if let Some(command) = command {
                    request
                        .params
                        .insert("initial_command".to_owned(), json!(command));
                }
            }
            Err(message) => {
                eprintln!("Error: worktree create: {message}");
                return 1;
            }
        }
    }
    if let Some(port) = request.params.remove("port").and_then(|port| port.as_u64()) {
        // stop-port <PORT>: find the one process listening there first.
        let listed = Request {
            command: Command::ListPorts,
            params: Map::new(),
        };
        let pids = match transport::round_trip(&path, &listed.to_line(1))
            .map(|line| parse_response(&line))
        {
            Ok(Ok(result)) => pids_on_port(&result, port),
            Ok(Err(message)) => {
                eprintln!("Error: {message}");
                return 1;
            }
            Err(_) => {
                eprintln!("Error: Programa is not running (no {ENDPOINT_KIND} at {path})");
                return 1;
            }
        };
        match pids.as_slice() {
            [(pid, _)] => {
                request.params.insert("pid".to_owned(), json!(pid));
            }
            [] => {
                eprintln!("Error: nothing Programa started listens on port {port}");
                return 1;
            }
            many => {
                eprintln!("Error: several processes listen on port {port}; pick one with --pid:");
                for (pid, command) in many {
                    eprintln!("  pid {pid}  {command}");
                }
                return 1;
            }
        }
    }
    let line = match transport::round_trip(&path, &request.to_line(1)) {
        Ok(line) => line,
        Err(TransportError::NotRunning) => {
            eprintln!("Error: Programa is not running (no {ENDPOINT_KIND} at {path})");
            return 1;
        }
        Err(TransportError::Io(err)) => {
            eprintln!("Error: lost connection to Programa at {path}: {err}");
            return 1;
        }
    };
    match parse_response(&line) {
        Ok(result) if json => {
            let pretty = serde_json::to_string_pretty(&result).unwrap_or_default();
            emit(&format!("{pretty}\n"));
            0
        }
        Ok(result) => {
            emit(&render(request.command, &result));
            0
        }
        Err(message) => {
            eprintln!("Error: {message}");
            1
        }
    }
}

/// `programa watch-events`, as on macOS: subscribes, then prints every pushed frame as one JSON
/// line until stopped. A dropped connection resubscribes after 1, 2, 4… up to 30 seconds, unless
/// `--no-reconnect`; a refused subscribe ends it.
fn run_watch_events(path: &str, params: &Map<String, Value>) -> i32 {
    let mut params = params.clone();
    let reconnect = params.remove("no_reconnect").is_none();
    let request = json!({"id": 1, "method": "subscribe", "params": params}).to_string();
    let mut backoff = 1;
    loop {
        let mut acked = false;
        let mut refused = None;
        let result = transport::stream(path, &request, |line| {
            if acked {
                emit(&format!("{line}\n"));
                return true;
            }
            match parse_response(line) {
                Ok(_) => {
                    acked = true;
                    true
                }
                Err(message) => {
                    refused = Some(message);
                    false
                }
            }
        });
        if let Some(message) = refused {
            eprintln!("Error: {message}");
            return 1;
        }
        if !reconnect {
            return match result {
                Err(TransportError::NotRunning) => {
                    eprintln!("Error: Programa is not running (no {ENDPOINT_KIND} at {path})");
                    1
                }
                _ => 0,
            };
        }
        if acked {
            backoff = 1;
        }
        eprintln!("watch-events: disconnected; reconnecting in {backoff}s");
        std::thread::sleep(std::time::Duration::from_secs(backoff));
        backoff = (backoff * 2).min(30);
    }
}

/// `programa race`, as on macOS: one worktree and workspace per agent on `<prefix>/<n>`, numbered
/// after the branches that already exist, each starting the agent on the prompt. A failed index is
/// reported and the rest still start; the exit code is 1 if any failed.
fn run_race(path: &str, params: &Map<String, Value>) -> i32 {
    let text = |key: &str| params.get(key).and_then(Value::as_str).unwrap_or_default();
    let n = params.get("n").and_then(Value::as_u64).unwrap_or(3);
    let (agent, prefix) = (text("agent"), text("prefix"));
    let Some(repo) = git_output(None, &["rev-parse", "--show-toplevel"]) else {
        eprintln!("Error: race: the current directory is not inside a git repository");
        return 1;
    };
    let refs = git_output(
        Some(&repo),
        &[
            "for-each-ref",
            "--format=%(refname:short)",
            &format!("refs/heads/{prefix}/"),
        ],
    )
    .unwrap_or_default();
    let first = race_start(&refs, prefix);
    let launch = race_launch(agent, text("prompt"));
    let mut failed = Vec::new();
    for index in first..first + n {
        let branch = format!("{prefix}/{index}");
        let mut create = Map::new();
        put(&mut create, "repo", Some(repo.clone()));
        put(&mut create, "branch", Some(branch.clone()));
        put(
            &mut create,
            "base",
            params
                .get("base")
                .and_then(Value::as_str)
                .map(str::to_owned),
        );
        put(
            &mut create,
            "layout",
            params
                .get("layout")
                .and_then(Value::as_str)
                .map(str::to_owned),
        );
        put(&mut create, "initial_command", Some(launch.clone()));
        let request = Request {
            command: Command::Race,
            params: create,
        };
        let outcome = transport::round_trip(path, &request.to_line(1))
            .map_err(|_| format!("Programa is not running (no {ENDPOINT_KIND} at {path})"))
            .and_then(|line| parse_response(&line));
        match outcome {
            Ok(result) => emit(&format!(
                "[{index}] branch={branch} workspace={}\n",
                field(&result, "workspace_id")
            )),
            Err(message) => {
                emit(&format!("[{index}] branch={branch} FAILED: {message}\n"));
                failed.push(index.to_string());
            }
        }
    }
    let last = first + n - 1;
    let range = if n == 1 {
        format!("{prefix}/{first}")
    } else {
        format!("{prefix}/{first}..{prefix}/{last}")
    };
    if failed.is_empty() {
        emit(&format!("\nrace: started {n}/{n} agents on branches {range}. Watch with: programa list-workspaces\n"));
        0
    } else {
        emit(&format!(
            "\nrace: started {}/{n} agents; failed indexes: {}\n",
            n as usize - failed.len(),
            failed.join(", ")
        ));
        1
    }
}

fn now_seconds() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// `programa usage`: the tokens of every recorded Claude Code session, grouped by workspace, the
/// open ones (every window's, in order) named after the app's `window.list` and `workspace.list`.
fn run_usage(path: &str, params: &Map<String, Value>, json_output: bool, env: Env) -> i32 {
    let call = |method: &str, params: Value| {
        transport::round_trip(
            path,
            &json!({ "id": 1, "method": method, "params": params }).to_string(),
        )
        .map_err(|_| format!("Programa is not running (no {ENDPOINT_KIND} at {path})"))
        .and_then(|line| parse_response(&line))
    };
    let mut open: Vec<(String, String)> = Vec::new();
    let windows = match call("window.list", json!({})) {
        Ok(result) => result,
        Err(message) => {
            eprintln!("Error: {message}");
            return 1;
        }
    };
    for window in items(&windows, "windows") {
        let Ok(listed) = call(
            "workspace.list",
            json!({ "window_id": str_or_empty(window, "id") }),
        ) else {
            continue;
        };
        for workspace in items(&listed, "workspaces") {
            let id = str_or_empty(workspace, "id").to_owned();
            if !open.iter().any(|(known, _)| *known == id) {
                open.push((id, str_or_empty(workspace, "title").to_owned()));
            }
        }
    }
    let mut sessions = usage::known_sessions(env, now_seconds());
    if let Some(wanted) = text_param(params, "workspace") {
        let target = open
            .iter()
            .map(|(id, _)| id.as_str())
            .chain(
                sessions
                    .iter()
                    .filter_map(|session| session.workspace_id.as_deref()),
            )
            .find(|id| id.eq_ignore_ascii_case(wanted))
            .map(str::to_lowercase);
        let Some(target) = target else {
            eprintln!("Error: usage: workspace not found: {wanted}");
            return 1;
        };
        sessions.retain(|session| {
            session
                .workspace_id
                .as_deref()
                .map(str::to_lowercase)
                .as_deref()
                == Some(target.as_str())
        });
    }
    let report = usage::report(&open, &sessions, env);
    if json_output {
        emit(&format!(
            "{}\n",
            serde_json::to_string_pretty(&report).unwrap_or_default()
        ));
    } else {
        emit(&usage::format_report(&report));
    }
    0
}

/// `worktree open --all`, as on macOS: every worktree of the repo not open yet, one line each.
fn run_open_all(path: &str, params: &Map<String, Value>) -> i32 {
    let mut repo = Map::new();
    put(
        &mut repo,
        "repo",
        text_param(params, "repo").map(str::to_owned),
    );
    let call = |command: Command, params: Map<String, Value>| {
        transport::round_trip(path, &Request { command, params }.to_line(1))
            .map_err(|_| format!("Programa is not running (no {ENDPOINT_KIND} at {path})"))
            .and_then(|line| parse_response(&line))
    };
    let listed = match call(Command::WorktreeList, repo.clone()) {
        Ok(listed) => listed,
        Err(message) => {
            eprintln!("Error: {message}");
            return 1;
        }
    };
    let mut failed = false;
    for worktree in items(&listed, "worktrees") {
        let worktree_path = str_or_empty(worktree, "path");
        if worktree.get("is_open").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let mut open = repo.clone();
        put(&mut open, "path", Some(worktree_path.to_owned()));
        match call(Command::WorktreeOpen, open) {
            Ok(result) => emit(&format!(
                "OK {} {worktree_path}\n",
                field(&result, "workspace_id")
            )),
            Err(message) => {
                eprintln!("Error: {worktree_path}: {message}");
                failed = true;
            }
        }
    }
    i32::from(failed)
}

fn text_param<'a>(params: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str)
}

/// `worktree create --from-issue`, as on macOS: reads the issue with `gh issue view` in the repo,
/// names the branch `issue-<n>-<slug>`, and with an agent writes the issue to a prompt file the
/// agent is pointed at (the issue text is never typed into the shell).
fn issue_worktree(
    repo: &str,
    number: u64,
    agent: Option<&str>,
) -> Result<(String, Option<String>), String> {
    let output = std::process::Command::new("gh")
        .args([
            "issue",
            "view",
            &number.to_string(),
            "--json",
            "number,title,body,url",
        ])
        .current_dir(repo)
        .output()
        .map_err(|_| {
            "--from-issue needs the GitHub CLI (gh) on PATH; install it from https://cli.github.com"
                .to_owned()
        })?;
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stderr.contains("gh auth login") || output.status.code() == Some(4) {
        return Err("gh is not logged in to GitHub; run 'gh auth login' and try again".into());
    }
    if stderr.contains("Could not resolve to an issue") {
        return Err(format!(
            "issue #{number} not found for the repository at {repo}"
        ));
    }
    if !output.status.success() {
        let first = stderr.lines().next().unwrap_or_default();
        return Err(format!("'gh issue view {number}' failed: {first}"));
    }
    let issue: Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| format!("'gh issue view {number}' returned unexpected output"))?;
    let title = issue
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if title.trim().is_empty() {
        return Err(format!(
            "'gh issue view {number}' returned unexpected output"
        ));
    }
    let branch = issue_branch_name(number, title);
    let Some(agent) = agent else {
        return Ok((branch, None));
    };
    let file = write_issue_prompt(
        number,
        title,
        str_or_empty(&issue, "url"),
        str_or_empty(&issue, "body"),
    )?;
    let prompt = format!(
        "Work on GitHub issue #{number}. Its title, link and description are in {file}; read that file first."
    );
    Ok((branch, Some(race_launch(agent, &prompt))))
}

/// `issue-<n>-<slug>`: ASCII letters and digits of the lowercased title, every other run of
/// characters one `-`, at most 40 characters.
fn issue_branch_name(number: u64, title: &str) -> String {
    let mut slug = String::new();
    let mut separator = false;
    for c in title.to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            if separator && !slug.is_empty() {
                slug.push('-');
            }
            separator = false;
            slug.push(c);
        } else {
            separator = true;
        }
    }
    let slug: String = slug.chars().take(40).collect();
    let slug = slug.trim_end_matches('-');
    if slug.is_empty() {
        format!("issue-{number}")
    } else {
        format!("issue-{number}-{slug}")
    }
}

/// Writes the issue to `%TEMP%\programa-issue-prompts`, removing prompt files older than 7 days.
fn write_issue_prompt(number: u64, title: &str, url: &str, body: &str) -> Result<String, String> {
    let directory = std::env::temp_dir().join("programa-issue-prompts");
    std::fs::create_dir_all(&directory)
        .map_err(|err| format!("could not create {}: {err}", directory.display()))?;
    let week = std::time::Duration::from_secs(7 * 24 * 60 * 60);
    for entry in std::fs::read_dir(&directory)
        .into_iter()
        .flatten()
        .flatten()
    {
        let old = entry
            .metadata()
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age > week);
        if old {
            let _ = std::fs::remove_file(entry.path());
        }
    }
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|time| time.as_nanos())
        .unwrap_or_default();
    let file = directory.join(format!("issue-{number}-{:08x}.md", stamp as u32));
    std::fs::write(
        &file,
        format!("# {title}\n\nGitHub issue #{number}: {url}\n\n{body}\n"),
    )
    .map_err(|err| {
        format!(
            "could not write the issue prompt to {}: {err}",
            file.display()
        )
    })?;
    Ok(file.display().to_string())
}

/// The first free index after the `<prefix>/<number>` branches listed one per line.
fn race_start(refs: &str, prefix: &str) -> u64 {
    refs.lines()
        .filter_map(|name| {
            name.trim()
                .strip_prefix(prefix)?
                .strip_prefix('/')?
                .parse::<u64>()
                .ok()
        })
        .max()
        .unwrap_or(0)
        + 1
}

/// The PowerShell line that starts the agent on the prompt; OpenCode takes it with `--prompt`.
fn race_launch(agent: &str, prompt: &str) -> String {
    let quoted = format!("'{}'", prompt.replace('\'', "''"));
    if agent == "opencode" {
        format!("opencode --prompt {quoted}")
    } else {
        format!("{agent} {quoted}")
    }
}

fn git_output(directory: Option<&str>, args: &[&str]) -> Option<String> {
    let mut git = std::process::Command::new("git");
    if let Some(directory) = directory {
        git.arg("-C").arg(directory);
    }
    let output = git.args(args).output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Writes to stdout, ignoring a closed pipe (e.g. `programa tree | head -1`).
fn emit(text: &str) {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(text.as_bytes());
    let _ = out.flush();
}

fn non_empty(value: String) -> Option<String> {
    (!value.is_empty()).then_some(value)
}

/// `--socket` > `PROGRAMA_SOCKET_PATH` > `PROGRAMA_SOCKET` > platform default.
fn resolve_socket_path(flag: Option<&str>, env: Env) -> String {
    flag.map(str::to_owned)
        .and_then(non_empty)
        .or_else(|| env("PROGRAMA_SOCKET_PATH").and_then(non_empty))
        .or_else(|| env("PROGRAMA_SOCKET").and_then(non_empty))
        .unwrap_or_else(|| default_socket_path(env))
}

#[cfg(windows)]
fn default_socket_path(env: Env) -> String {
    match env("USERNAME").and_then(non_empty) {
        Some(user) => format!(r"\\.\pipe\programa-{user}"),
        None => r"\\.\pipe\programa".to_owned(),
    }
}

#[cfg(not(windows))]
fn default_socket_path(env: Env) -> String {
    let home = env("HOME").unwrap_or_default();
    format!("{home}/Library/Application Support/programa/programa.sock")
}

/// Splits global flags (accepted anywhere before a `--`) from the command and
/// its arguments, then builds the request for that command.
fn parse_invocation(args: &[String], env: Env) -> Result<Invocation, UsageError> {
    let mut json = false;
    let mut socket = None;
    let mut help = false;
    let mut version = false;
    let mut rest = Vec::new();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--" => {
                rest.push(arg.clone());
                rest.extend(iter.by_ref().cloned());
            }
            "--json" => json = true,
            "-h" | "--help" => help = true,
            "-V" | "--version" => version = true,
            "--socket" => match iter.next() {
                Some(path) => socket = Some(path.clone()),
                None => return Err(UsageError("--socket needs a path".into())),
            },
            other => match other.strip_prefix("--socket=") {
                Some(path) => socket = Some(path.to_owned()),
                None => rest.push(arg.clone()),
            },
        }
    }
    if help {
        return Ok(Invocation::Help);
    }
    if version {
        return Ok(Invocation::Version);
    }
    let Some((name, command_args)) = rest.split_first() else {
        return Ok(Invocation::Help);
    };
    if name == "help" {
        return Ok(Invocation::Help);
    }
    // `worktree <subcommand>` and `layout <subcommand>` are one command named by both words.
    let (name, command_args) = match (name.as_str(), command_args.split_first()) {
        ("worktree" | "layout" | "storage", Some((sub, rest))) if !sub.starts_with('-') => {
            (format!("{name} {sub}"), rest)
        }
        ("review", Some((sub, rest))) if sub == "comment" => match rest.split_first() {
            Some((action, rest)) if !action.starts_with('-') => {
                (format!("review comment {action}"), rest)
            }
            _ => {
                return Err(UsageError(
                    "review comment: missing action (add, remove or list)".into(),
                ))
            }
        },
        ("review", Some((sub, rest))) if !sub.starts_with('-') => (format!("review {sub}"), rest),
        ("review", _) => {
            return Err(UsageError(
                "review: missing subcommand (open, refresh, comment or send)".into(),
            ))
        }
        // `markdown <path>` is short for `markdown open <path>`, as on macOS.
        ("markdown", Some((sub, rest))) if sub == "open" => ("markdown open".to_owned(), rest),
        ("markdown", _) => ("markdown open".to_owned(), command_args),
        ("worktree", _) => {
            return Err(UsageError(
                "worktree: missing subcommand (create, open, remove or list)".into(),
            ))
        }
        ("storage", _) => {
            return Err(UsageError(
                "storage: missing subcommand (scan or clean)".into(),
            ))
        }
        ("layout", _) => {
            return Err(UsageError(
                "layout: missing subcommand (save, apply or list)".into(),
            ))
        }
        _ => (name.clone(), command_args),
    };
    let name = &name;
    let command = match Command::from_name(name) {
        Some(command) => command,
        None if name.starts_with('-') => {
            return Err(UsageError(format!("unknown option '{name}'")));
        }
        None => return Err(UsageError(format!("unknown command '{name}'"))),
    };
    let params = build_params(command, command_args, env)?;
    Ok(Invocation::Call {
        json,
        socket,
        request: Request { command, params },
    })
}

#[derive(Debug, Default)]
struct Opts {
    values: HashMap<&'static str, String>,
    switches: Vec<&'static str>,
    positionals: Vec<String>,
}

impl Opts {
    fn value(&self, flag: &str) -> Option<String> {
        self.values.get(flag).cloned().and_then(non_empty)
    }

    fn has(&self, switch: &str) -> bool {
        self.switches.contains(&switch)
    }
}

/// Parses a command's own flags. `value_flags` take a value (`--flag v` or
/// `--flag=v`), `switches` take none; anything else starting with `-` is an
/// error, and everything after `--` is positional.
fn parse_opts(
    command: Command,
    args: &[String],
    value_flags: &[&'static str],
    switches: &[&'static str],
) -> Result<Opts, UsageError> {
    let name = command.name();
    let mut opts = Opts::default();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--" {
            opts.positionals.extend(iter.by_ref().cloned());
            break;
        }
        if arg.len() < 2 || !arg.starts_with('-') {
            opts.positionals.push(arg.clone());
            continue;
        }
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value)),
            _ => (arg.as_str(), None),
        };
        if let Some(&known) = value_flags.iter().find(|f| **f == flag) {
            let value = match inline {
                Some(value) => value.to_owned(),
                None => iter
                    .next()
                    .cloned()
                    .ok_or_else(|| UsageError(format!("{name}: {known} needs a value")))?,
            };
            opts.values.insert(known, value);
        } else if let Some(&known) = switches.iter().find(|f| **f == flag) {
            if inline.is_some() {
                return Err(UsageError(format!("{name}: {known} takes no value")));
            }
            opts.switches.push(known);
        } else {
            return Err(UsageError(format!("{name}: unknown option '{flag}'")));
        }
    }
    Ok(opts)
}

fn no_positionals(command: Command, opts: &Opts) -> Result<(), UsageError> {
    match opts.positionals.first() {
        Some(extra) => Err(UsageError(format!(
            "{}: unexpected argument '{extra}'",
            command.name()
        ))),
        None => Ok(()),
    }
}

/// Exactly one positional, named `what` in the error message.
fn one_positional(command: Command, opts: &Opts, what: &str) -> Result<String, UsageError> {
    match opts.positionals.as_slice() {
        [only] => Ok(only.clone()),
        [] => Err(UsageError(format!("{}: missing {what}", command.name()))),
        [_, extra, ..] => Err(UsageError(format!(
            "{}: unexpected argument '{extra}'",
            command.name()
        ))),
    }
}

/// The explicit flag value, else the environment default.
fn target(opts: &Opts, flag: &str, env_var: &str, env: Env) -> Option<String> {
    opts.value(flag)
        .or_else(|| env(env_var).and_then(non_empty))
}

/// A positive number of seconds from a flag, or None when the flag is absent.
fn seconds(opts: &Opts, flag: &str, command: &str) -> Result<Option<f64>, UsageError> {
    match opts.value(flag) {
        None => Ok(None),
        Some(raw) => match raw.parse::<f64>() {
            Ok(value) if value.is_finite() && value > 0.0 => Ok(Some(value)),
            _ => Err(UsageError(format!(
                "{command}: {flag} must be a positive number of seconds"
            ))),
        },
    }
}

fn put(params: &mut Map<String, Value>, key: &str, value: Option<String>) {
    if let Some(value) = value {
        params.insert(key.to_owned(), Value::String(value));
    }
}

fn build_params(
    command: Command,
    args: &[String],
    env: Env,
) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    let surface = |opts: &Opts| target(opts, "--surface", SURFACE_ENV, env);
    let workspace = |opts: &Opts| target(opts, "--workspace", WORKSPACE_ENV, env);
    match command {
        Command::SetStatus
        | Command::ClearStatus
        | Command::ListStatus
        | Command::SetProgress
        | Command::ClearProgress
        | Command::Log
        | Command::ClearLog
        | Command::ListLog
        | Command::SidebarState => return sidebar::params(command, args, env),
        Command::ListPanes
        | Command::ListPaneSurfaces
        | Command::FocusPane
        | Command::NewPane
        | Command::ResizePane
        | Command::SwapPane
        | Command::BreakPane
        | Command::JoinPane
        | Command::LastPane
        | Command::NextWindow
        | Command::PreviousWindow
        | Command::LastWindow
        | Command::ReorderWorkspace => return panes::params(command, args, env),
        Command::Ping
        | Command::Tree
        | Command::ListWorkspaces
        | Command::ListNotifications
        | Command::ListPorts
        | Command::Routes => {
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
        }
        Command::Usage => {
            // Only an explicit --workspace filters: the calling terminal's workspace is not a default.
            let opts = parse_opts(command, args, &["--workspace"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace", opts.value("--workspace"));
        }
        Command::Identify | Command::CloseSurface => {
            let opts = parse_opts(command, args, &["--surface"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "surface_id", surface(&opts));
        }
        Command::NewWorkspace => {
            let opts = parse_opts(
                command,
                args,
                &["--cwd", "--command", "--name", "--title"],
                &[],
            )?;
            no_positionals(command, &opts)?;
            put(&mut params, "cwd", opts.value("--cwd"));
            put(&mut params, "initial_command", opts.value("--command"));
            put(
                &mut params,
                "title",
                opts.value("--name").or(opts.value("--title")),
            );
        }
        Command::NewSurface => {
            let opts = parse_opts(
                command,
                args,
                &["--workspace", "--pane", "--cwd", "--command"],
                &[],
            )?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "pane_id", opts.value("--pane"));
            put(&mut params, "cwd", opts.value("--cwd"));
            put(&mut params, "initial_command", opts.value("--command"));
        }
        Command::NewSplit => {
            let opts = parse_opts(command, args, &["--surface", "--cwd", "--command"], &[])?;
            let direction = match opts.positionals.as_slice() {
                [] => "right".to_owned(),
                [direction] if ["left", "right", "up", "down"].contains(&direction.as_str()) => {
                    direction.clone()
                }
                [direction] => {
                    return Err(UsageError(format!(
                        "new-split: direction must be left, right, up or down, not '{direction}'"
                    )));
                }
                [_, extra, ..] => {
                    return Err(UsageError(format!(
                        "new-split: unexpected argument '{extra}'"
                    )));
                }
            };
            put(&mut params, "surface_id", surface(&opts));
            put(&mut params, "direction", Some(direction));
            put(&mut params, "cwd", opts.value("--cwd"));
            put(&mut params, "initial_command", opts.value("--command"));
        }
        Command::SelectWorkspace => {
            let opts = parse_opts(command, args, &[], &[])?;
            let id = one_positional(command, &opts, "workspace ID")?;
            put(&mut params, "workspace_id", Some(id));
        }
        Command::CloseWorkspace | Command::ClearNotifications => {
            let opts = parse_opts(command, args, &["--workspace"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace_id", workspace(&opts));
        }
        Command::RenameWorkspace => {
            let opts = parse_opts(command, args, &["--workspace"], &[])?;
            if opts.positionals.is_empty() {
                return Err(UsageError("rename-workspace: missing title".into()));
            }
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "title", Some(opts.positionals.join(" ")));
        }
        Command::FocusSurface => {
            let opts = parse_opts(command, args, &[], &[])?;
            let id = one_positional(command, &opts, "surface ID")?;
            put(&mut params, "surface_id", Some(id));
        }
        Command::Send => {
            let opts = parse_opts(command, args, &["--surface"], &[])?;
            if opts.positionals.is_empty() {
                return Err(UsageError("send: missing text".into()));
            }
            put(&mut params, "surface_id", surface(&opts));
            let text = decode_escapes(&opts.positionals.join(" "));
            put(&mut params, "text", Some(text));
        }
        Command::ReadScreen => {
            let opts = parse_opts(command, args, &["--surface", "--lines"], &["--scrollback"])?;
            no_positionals(command, &opts)?;
            put(&mut params, "surface_id", surface(&opts));
            if let Some(lines) = opts.value("--lines") {
                let count = lines
                    .parse::<u64>()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or_else(|| {
                        UsageError(format!(
                            "read-screen: --lines must be a positive integer, not '{lines}'"
                        ))
                    })?;
                params.insert("lines".into(), Value::from(count));
            }
            params.insert("scrollback".into(), Value::Bool(opts.has("--scrollback")));
        }
        Command::Notify => {
            let opts = parse_opts(
                command,
                args,
                &[
                    "--title",
                    "--subtitle",
                    "--body",
                    "--workspace",
                    "--surface",
                ],
                &[],
            )?;
            no_positionals(command, &opts)?;
            let title = opts
                .value("--title")
                .ok_or_else(|| UsageError("notify: --title is required".into()))?;
            put(&mut params, "title", Some(title));
            put(&mut params, "subtitle", opts.value("--subtitle"));
            put(&mut params, "body", opts.value("--body"));
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", surface(&opts));
        }
        Command::SetAgentState => {
            let opts = parse_opts(command, args, &["--surface", "--source"], &[])?;
            let state = one_positional(command, &opts, "state (working, blocked, idle or clear)")?;
            if !AGENT_STATES.contains(&state.as_str()) {
                return Err(UsageError(format!(
                    "set-agent-state: state must be working, blocked, idle or clear, not '{state}'"
                )));
            }
            put(&mut params, "surface_id", surface(&opts));
            put(&mut params, "state", Some(state));
            put(&mut params, "source", opts.value("--source"));
        }
        Command::WorktreeCreate
        | Command::WorktreeOpen
        | Command::WorktreeRemove
        | Command::WorktreeList => {
            let (values, switches): (&[&str], &[&str]) = match command {
                Command::WorktreeCreate => (
                    &[
                        "--repo",
                        "--base",
                        "--path",
                        "--layout",
                        "--from-issue",
                        "--agent",
                    ],
                    &["--focus"],
                ),
                Command::WorktreeOpen => (&["--repo"], &["--focus", "--all"]),
                Command::WorktreeRemove => (&["--repo"], &["--force"]),
                _ => (&["--repo"], &[]),
            };
            let opts = parse_opts(command, args, values, switches)?;
            // The repo defaults to the directory the command runs in, as on macOS.
            let repo = opts.value("--repo").or_else(|| {
                std::env::current_dir()
                    .ok()
                    .map(|dir| dir.to_string_lossy().into_owned())
            });
            put(&mut params, "repo", repo);
            match command {
                Command::WorktreeList => no_positionals(command, &opts)?,
                Command::WorktreeCreate => {
                    // --from-issue names the branch after the issue unless one is given;
                    // `run` reads the issue and resolves both before the request goes out.
                    let issue = match opts.value("--from-issue") {
                        Some(raw) => Some(raw.parse::<u64>().ok().filter(|n| *n > 0).ok_or_else(|| {
                            UsageError(format!(
                                "worktree create: --from-issue must be a positive issue number, got '{raw}'"
                            ))
                        })?),
                        None => None,
                    };
                    if let Some(agent) = opts.value("--agent") {
                        if issue.is_none() {
                            return Err(UsageError(
                                "worktree create: --agent requires --from-issue <number>".into(),
                            ));
                        }
                        if !["claude", "opencode", "codex"].contains(&agent.as_str()) {
                            return Err(UsageError(
                                "worktree create: --agent must be one of claude, opencode, codex"
                                    .into(),
                            ));
                        }
                        put(&mut params, "agent", Some(agent));
                    }
                    let branch = match (issue, opts.positionals.as_slice()) {
                        (Some(_), []) => None,
                        _ => Some(one_positional(command, &opts, "branch")?),
                    };
                    if let Some(number) = issue {
                        params.insert("from_issue".to_owned(), json!(number));
                    }
                    put(&mut params, "branch", branch);
                    put(&mut params, "base", opts.value("--base"));
                    put(&mut params, "path", opts.value("--path").map(absolute));
                    put(&mut params, "layout", opts.value("--layout"));
                }
                // `open --all` opens every worktree of the repo (`run` lists and opens them).
                Command::WorktreeOpen if opts.has("--all") => {
                    if !opts.positionals.is_empty() || opts.has("--focus") {
                        return Err(UsageError(
                            "worktree open: --all takes no worktree and no --focus".into(),
                        ));
                    }
                }
                _ => {
                    // An existing directory is a worktree path; anything else is a branch.
                    let target = one_positional(command, &opts, "worktree path or branch")?;
                    if std::path::Path::new(&target).is_dir() {
                        put(&mut params, "path", Some(absolute(target)));
                    } else {
                        put(&mut params, "branch", Some(target));
                    }
                }
            }
            for switch in switches {
                if opts.has(switch) {
                    params.insert(switch.trim_start_matches("--").to_owned(), json!(true));
                }
            }
        }
        Command::LayoutList => {
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
        }
        Command::ReviewOpen => {
            let opts = parse_opts(
                command,
                args,
                &["--surface", "--direction", "--mode", "--base-branch"],
                &["--focus"],
            )?;
            no_positionals(command, &opts)?;
            put(&mut params, "surface_id", surface(&opts));
            put(&mut params, "direction", opts.value("--direction"));
            // macOS's CLI calls the uncommitted mode "worktree".
            let mode = opts.value("--mode").map(|mode| match mode.as_str() {
                "worktree" => "uncommitted".to_owned(),
                _ => mode,
            });
            put(&mut params, "mode", mode);
            put(&mut params, "base_branch", opts.value("--base-branch"));
            if opts.has("--focus") {
                params.insert("focus".to_owned(), json!(true));
            }
        }
        // The other review commands name the review panel, never the calling terminal.
        Command::ReviewRefresh | Command::ReviewCommentList => {
            let opts = parse_opts(command, args, &["--surface"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "surface_id", opts.value("--surface"));
        }
        Command::ReviewCommentRemove => {
            let opts = parse_opts(command, args, &["--surface"], &[])?;
            let id = one_positional(command, &opts, "comment id")?;
            put(&mut params, "comment_id", Some(id));
            put(&mut params, "surface_id", opts.value("--surface"));
        }
        Command::ReviewCommentAdd => {
            let opts = parse_opts(command, args, &["--surface"], &[])?;
            let [file, range, text @ ..] = opts.positionals.as_slice() else {
                return Err(UsageError(
                    "review comment add: usage is <FILE> <START>[-<END>] <TEXT>".into(),
                ));
            };
            if text.is_empty() {
                return Err(UsageError(
                    "review comment add: missing comment text".into(),
                ));
            }
            let (start, end) = range.split_once('-').unwrap_or((range, range));
            let line = |value: &str| {
                value.parse::<u32>().map_err(|_| {
                    UsageError(format!("review comment add: '{range}' is not a line range"))
                })
            };
            put(&mut params, "file_path", Some(file.clone()));
            params.insert("start_line".to_owned(), json!(line(start)?));
            params.insert("end_line".to_owned(), json!(line(end)?));
            put(&mut params, "text", Some(text.join(" ")));
            put(&mut params, "surface_id", opts.value("--surface"));
        }
        Command::ReviewSend => {
            let opts = parse_opts(command, args, &["--surface", "--preamble"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "surface_id", opts.value("--surface"));
            put(&mut params, "preamble", opts.value("--preamble"));
        }
        Command::ListWindows | Command::NewWindow => {
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
        }
        Command::CurrentWindow => {
            let opts = parse_opts(command, args, &["--window"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "window_id", opts.value("--window"));
        }
        // As on macOS, these name the window with --window; a lone positional id works too.
        Command::FocusWindow | Command::CloseWindow => {
            let opts = parse_opts(command, args, &["--window"], &[])?;
            let window = match (opts.value("--window"), opts.positionals.as_slice()) {
                (Some(window), []) => window,
                (None, [window]) => window.clone(),
                _ => {
                    return Err(UsageError(format!(
                        "{}: --window <id> is required",
                        command.name()
                    )))
                }
            };
            put(&mut params, "window_id", Some(window));
        }
        Command::WaitSurface => {
            let opts = parse_opts(
                command,
                args,
                &[
                    "--workspace",
                    "--surface",
                    "--pattern",
                    "--agent-state",
                    "--program-state",
                    "--timeout",
                    "--lines",
                ],
                &["--exit"],
            )?;
            no_positionals(command, &opts)?;
            let given = ["--pattern", "--agent-state", "--program-state"]
                .into_iter()
                .filter(|flag| opts.value(flag).is_some())
                .count()
                + usize::from(opts.has("--exit"));
            if given != 1 {
                return Err(UsageError(
                    "wait-surface requires exactly one of --pattern <regex>, --exit, --agent-state <idle|working|blocked|any_change> or --program-state <state>".into(),
                ));
            }
            if let Some(state) = opts.value("--agent-state") {
                if !["idle", "working", "blocked", "any_change"].contains(&state.as_str()) {
                    return Err(UsageError(
                        "wait-surface: --agent-state must be one of idle, working, blocked, any_change"
                            .into(),
                    ));
                }
            }
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", surface(&opts));
            put(&mut params, "pattern", opts.value("--pattern"));
            put(&mut params, "agent_state", opts.value("--agent-state"));
            put(&mut params, "program_state", opts.value("--program-state"));
            if opts.has("--exit") {
                params.insert("exit".to_owned(), json!(true));
            }
            let timeout = seconds(&opts, "--timeout", "wait-surface")?.unwrap_or(30.0);
            params.insert(
                "timeout_ms".to_owned(),
                json!((timeout * 1000.0).round() as i64),
            );
            if let Some(lines) = opts.value("--lines") {
                match lines.parse::<u32>() {
                    Ok(count) if count > 0 => {
                        params.insert("lines".to_owned(), json!(count));
                    }
                    _ => {
                        return Err(UsageError(
                            "wait-surface: --lines must be greater than 0".into(),
                        ))
                    }
                }
            }
        }
        Command::PromptAgent => {
            let opts = parse_opts(
                command,
                args,
                &["--workspace", "--surface", "--timeout", "--working-grace"],
                &["--force", "--answer-prompt"],
            )?;
            let text = opts.positionals.join(" ");
            if text.trim().is_empty() {
                return Err(UsageError("prompt-agent requires the prompt text".into()));
            }
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", surface(&opts));
            params.insert("text".to_owned(), json!(text));
            if let Some(timeout) = seconds(&opts, "--timeout", "prompt-agent")? {
                params.insert(
                    "timeout_ms".to_owned(),
                    json!((timeout * 1000.0).round() as i64),
                );
            }
            if let Some(grace) = seconds(&opts, "--working-grace", "prompt-agent")? {
                params.insert(
                    "working_grace_ms".to_owned(),
                    json!((grace * 1000.0).round() as i64),
                );
            }
            for (flag, key) in [("--force", "force"), ("--answer-prompt", "answer_prompt")] {
                if opts.has(flag) {
                    params.insert(key.to_owned(), json!(true));
                }
            }
        }
        Command::WatchEvents => {
            let opts = parse_opts(
                command,
                args,
                &["--output"],
                &[
                    "--agent-state",
                    "--workspace-lifecycle",
                    "--needs-input",
                    "--no-reconnect",
                ],
            )?;
            no_positionals(command, &opts)?;
            let mut classes = Vec::new();
            for (flag, class) in [
                ("--agent-state", "agent_state"),
                ("--workspace-lifecycle", "workspace_lifecycle"),
                ("--needs-input", "needs_input"),
            ] {
                if opts.has(flag) {
                    classes.push(class);
                }
            }
            let surfaces: Vec<String> = opts
                .value("--output")
                .map(|ids| {
                    ids.split(',')
                        .map(str::trim)
                        .filter(|id| !id.is_empty())
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            if !surfaces.is_empty() {
                classes.push("output");
            }
            if classes.is_empty() {
                return Err(UsageError(
                    "watch-events requires at least one of --agent-state, --workspace-lifecycle, --needs-input, --output <surface_id[,surface_id...]>".into(),
                ));
            }
            params.insert("classes".to_owned(), json!(classes));
            if !surfaces.is_empty() {
                params.insert("surface_ids".to_owned(), json!(surfaces));
            }
            if opts.has("--no-reconnect") {
                params.insert("no_reconnect".to_owned(), json!(true));
            }
        }
        Command::MoveSurface => {
            let opts = parse_opts(
                command,
                args,
                &[
                    "--surface",
                    "--pane",
                    "--workspace",
                    "--window",
                    "--before",
                    "--before-surface",
                    "--after",
                    "--after-surface",
                    "--index",
                    "--focus",
                ],
                &[],
            )?;
            // As on macOS: --surface, else the first argument, else this terminal.
            let surface_id = opts
                .value("--surface")
                .or_else(|| opts.positionals.first().cloned())
                .or_else(|| env(SURFACE_ENV).and_then(non_empty))
                .ok_or_else(|| UsageError("move-surface requires --surface <id>".into()))?;
            put(&mut params, "surface_id", Some(surface_id));
            put(&mut params, "pane_id", opts.value("--pane"));
            put(&mut params, "workspace_id", opts.value("--workspace"));
            put(&mut params, "window_id", opts.value("--window"));
            put(
                &mut params,
                "before_surface_id",
                opts.value("--before").or(opts.value("--before-surface")),
            );
            put(
                &mut params,
                "after_surface_id",
                opts.value("--after").or(opts.value("--after-surface")),
            );
            if let Some(index) = opts.value("--index") {
                let index: i64 = index
                    .parse()
                    .map_err(|_| UsageError("--index must be an integer".into()))?;
                params.insert("index".to_owned(), json!(index));
            }
            if let Some(focus) = opts.value("--focus") {
                let focus = match focus.as_str() {
                    "true" => true,
                    "false" => false,
                    _ => return Err(UsageError("--focus must be true|false".into())),
                };
                params.insert("focus".to_owned(), json!(focus));
            }
        }
        Command::StorageScan => {
            let clean_only = [
                "--dry-run",
                "--include-external",
                "--now",
                "--xcode",
                "--android",
                "--packages",
                "--caches",
                "--item",
                "--path",
            ];
            if let Some(flag) = args
                .iter()
                .map(|arg| arg.split('=').next().unwrap_or(arg))
                .find(|flag| clean_only.contains(flag))
            {
                return Err(UsageError(format!(
                    "storage scan: {flag} only applies to 'storage clean'"
                )));
            }
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
        }
        Command::StorageClean => {
            // --item and --path repeat, so they are taken out before the single-value parser.
            let mut items = Vec::new();
            let mut paths = Vec::new();
            let mut rest = Vec::new();
            let mut iter = args.iter();
            while let Some(arg) = iter.next() {
                let (flag, inline) = match arg.split_once('=') {
                    Some((flag, value)) => (flag, Some(value.to_owned())),
                    None => (arg.as_str(), None),
                };
                let list = match flag {
                    "--item" => &mut items,
                    "--path" => &mut paths,
                    _ => {
                        rest.push(arg.clone());
                        continue;
                    }
                };
                match inline.or_else(|| iter.next().cloned()) {
                    Some(value) if !value.is_empty() => list.push(value),
                    _ => return Err(UsageError(format!("storage clean: {flag} needs a value"))),
                }
            }
            let opts = parse_opts(
                command,
                &rest,
                &[],
                &[
                    "--dry-run",
                    "--include-external",
                    "--now",
                    "--xcode",
                    "--android",
                    "--packages",
                    "--caches",
                ],
            )?;
            no_positionals(command, &opts)?;
            params.insert("dry_run".to_owned(), json!(opts.has("--dry-run")));
            params.insert(
                "include_external".to_owned(),
                json!(opts.has("--include-external")),
            );
            params.insert("ignore_grace_period".to_owned(), json!(opts.has("--now")));
            let categories: Vec<&str> = ["xcode", "android", "packages"]
                .into_iter()
                .filter(|category| opts.has(&format!("--{category}")) || opts.has("--caches"))
                .collect();
            params.insert("categories".to_owned(), json!(categories));
            params.insert("items".to_owned(), json!(items));
            let paths: Vec<String> = paths.into_iter().map(absolute).collect();
            params.insert("paths".to_owned(), json!(paths));
        }
        Command::MoveWorkspaceToWindow => {
            let opts = parse_opts(command, args, &["--workspace", "--window"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace_id", workspace(&opts));
            // "new" opens a window for it.
            let window = opts.value("--window").ok_or_else(|| {
                UsageError("move-workspace-to-window: --window <id|new> is required".into())
            })?;
            put(&mut params, "window_id", Some(window));
        }
        Command::WorkspaceAction => {
            let opts = parse_opts(
                command,
                args,
                &[
                    "--action",
                    "--workspace",
                    "--title",
                    "--color",
                    "--description",
                ],
                &[],
            )?;
            let action = match (opts.value("--action"), opts.positionals.as_slice()) {
                (Some(action), []) => action,
                (None, [action]) => action.clone(),
                _ => return Err(UsageError("workspace-action: give one action".into())),
            };
            // macOS spells actions with dashes (move-up); the method takes underscores.
            put(&mut params, "action", Some(action.replace('-', "_")));
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "title", opts.value("--title"));
            put(&mut params, "color", opts.value("--color"));
            put(&mut params, "description", opts.value("--description"));
        }
        Command::Race => {
            let opts = parse_opts(
                command,
                args,
                &["--n", "--agent", "--base", "--prefix", "--layout"],
                &[],
            )?;
            let prompt = opts.positionals.join(" ").trim().to_owned();
            if prompt.is_empty() {
                return Err(UsageError("race requires a <prompt>".into()));
            }
            let n = match opts.value("--n") {
                Some(raw) => raw
                    .parse::<u32>()
                    .ok()
                    .filter(|n| (1..=8).contains(n))
                    .ok_or_else(|| UsageError("race: --n must be between 1 and 8".into()))?,
                None => 3,
            };
            let agent = opts.value("--agent").unwrap_or_else(|| "claude".to_owned());
            if !["claude", "opencode", "codex"].contains(&agent.as_str()) {
                return Err(UsageError(
                    "race: --agent must be one of claude, opencode, codex".into(),
                ));
            }
            params.insert("n".to_owned(), json!(n));
            put(&mut params, "agent", Some(agent));
            put(&mut params, "prompt", Some(prompt));
            put(&mut params, "base", opts.value("--base"));
            put(
                &mut params,
                "prefix",
                Some(opts.value("--prefix").unwrap_or_else(|| "race".to_owned())),
            );
            put(&mut params, "layout", opts.value("--layout"));
        }
        Command::Resume => {
            let opts = parse_opts(
                command,
                args,
                &["--surface", "--session", "--provider"],
                &["--print", "--force"],
            )?;
            no_positionals(command, &opts)?;
            put(&mut params, "surface_id", surface(&opts));
            put(&mut params, "session", opts.value("--session"));
            put(&mut params, "provider", opts.value("--provider"));
            for switch in ["--print", "--force"] {
                if opts.has(switch) {
                    params.insert(switch.trim_start_matches("--").to_owned(), json!(true));
                }
            }
        }
        Command::MarkdownOpen => {
            let opts = parse_opts(command, args, &["--surface", "--direction"], &["--focus"])?;
            let path = one_positional(command, &opts, "file path")?;
            put(&mut params, "path", Some(absolute(path)));
            put(&mut params, "surface_id", surface(&opts));
            put(&mut params, "direction", opts.value("--direction"));
            if opts.has("--focus") {
                params.insert("focus".to_owned(), json!(true));
            }
        }
        Command::LayoutSave => {
            let opts = parse_opts(command, args, &[], &["--force"])?;
            put(
                &mut params,
                "name",
                Some(one_positional(command, &opts, "layout name")?),
            );
            if opts.has("--force") {
                params.insert("force".to_owned(), json!(true));
            }
        }
        Command::LayoutApply => {
            let opts = parse_opts(command, args, &["--workspace", "--cwd"], &[])?;
            put(
                &mut params,
                "name",
                Some(one_positional(command, &opts, "layout name")?),
            );
            put(&mut params, "workspace_id", opts.value("--workspace"));
            put(&mut params, "cwd", opts.value("--cwd").map(absolute));
        }
        Command::StopPort => {
            // `--pid` goes straight to ports.stop; a port is resolved to its pid in `run`.
            let opts = parse_opts(command, args, &["--pid"], &[])?;
            let (key, raw) = match (opts.value("--pid"), opts.positionals.as_slice()) {
                (Some(pid), []) => ("pid", pid),
                (None, [port]) => ("port", port.clone()),
                _ => return Err(UsageError("stop-port: give a port or --pid PID".into())),
            };
            let number: u32 = raw
                .parse()
                .map_err(|_| UsageError(format!("stop-port: '{raw}' is not a number")))?;
            params.insert(key.to_owned(), json!(number));
        }
    }
    Ok(params)
}

/// Interprets the `send` escapes: `\n`, `\r`, `\t`, `\e` (ESC) and `\\`.
/// Any other backslash sequence, and a trailing lone backslash, is kept as is.
fn decode_escapes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('e') => out.push('\u{1b}'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// Returns the `result` of a success envelope, or the error message of a
/// failure envelope.
fn parse_response(line: &str) -> Result<Value, String> {
    let response: Value = serde_json::from_str(line)
        .map_err(|err| format!("invalid response from Programa: {err}"))?;
    match response.get("ok").and_then(Value::as_bool) {
        Some(true) => Ok(response.get("result").cloned().unwrap_or(Value::Null)),
        Some(false) => {
            let error = response.get("error");
            let text = |key: &str| {
                error
                    .and_then(|e| e.get(key))
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
            };
            Err(text("message")
                .or_else(|| text("code"))
                .unwrap_or("request failed")
                .to_owned())
        }
        None => Err("invalid response from Programa: missing \"ok\"".to_owned()),
    }
}

/// A result field as display text: strings verbatim, other scalars as JSON,
/// missing or null as `-`.
fn field(value: &Value, key: &str) -> String {
    match value.get(key) {
        Some(Value::String(s)) => s.clone(),
        None | Some(Value::Null) => "-".to_owned(),
        Some(other) => other.to_string(),
    }
}

fn items<'a>(result: &'a Value, key: &str) -> &'a [Value] {
    result
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

fn str_or_empty<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}

/// Human output for a successful `command`.
fn render(command: Command, result: &Value) -> String {
    match command {
        Command::Ping => "PONG\n".to_owned(),
        Command::Identify => format!(
            "surface {}\nworkspace {}\n",
            field(result, "surface_id"),
            field(result, "workspace_id")
        ),
        Command::Tree => format_workspaces(result, true),
        Command::ListWorkspaces => format_workspaces(result, false),
        Command::NewWorkspace | Command::NewSurface | Command::NewSplit => format!(
            "OK {} {}\n",
            field(result, "surface_id"),
            field(result, "workspace_id")
        ),
        Command::ReadScreen => {
            let mut text = str_or_empty(result, "text").to_owned();
            if !text.is_empty() && !text.ends_with('\n') {
                text.push('\n');
            }
            text
        }
        Command::ListNotifications => format_notifications(result),
        Command::ListPorts => format_ports(result),
        Command::WorktreeCreate | Command::WorktreeOpen => format!(
            "OK {} {}\n",
            field(result, "workspace_id"),
            result
                .get("worktree")
                .map(|worktree| field(worktree, "path"))
                .unwrap_or_default()
        ),
        Command::WorktreeList => format_worktrees(result),
        Command::LayoutList => items(result, "layouts")
            .iter()
            .map(|layout| format!("{}\n", str_or_empty(layout, "name")))
            .collect(),
        Command::LayoutSave => format!("OK {}\n", field(result, "path")),
        Command::LayoutApply => format!("OK {}\n", field(result, "workspace_id")),
        Command::MarkdownOpen => format!("OK {}\n", field(result, "surface_id")),
        // `--print` prints the command; otherwise it was typed into the terminal.
        Command::Race => String::new(),
        Command::WorkspaceAction | Command::CloseWindow => "OK\n".to_owned(),
        Command::ListWindows => items(result, "windows")
            .iter()
            .map(|window| {
                let marker = if window.get("selected").and_then(Value::as_bool) == Some(true) {
                    "* "
                } else {
                    "  "
                };
                format!(
                    "{marker}{}  {} workspaces\n",
                    str_or_empty(window, "id"),
                    window
                        .get("workspace_count")
                        .and_then(Value::as_u64)
                        .unwrap_or(0)
                )
            })
            .collect(),
        Command::CurrentWindow | Command::NewWindow | Command::FocusWindow => {
            format!("{}\n", field(result, "window_id"))
        }
        Command::MoveWorkspaceToWindow => format!("OK {}\n", field(result, "window_id")),
        Command::Routes => format_routes(result),
        Command::Usage => String::new(),
        Command::SetStatus
        | Command::ClearStatus
        | Command::ListStatus
        | Command::SetProgress
        | Command::ClearProgress
        | Command::Log
        | Command::ClearLog
        | Command::ListLog
        | Command::SidebarState => sidebar::render(command, result),
        Command::ListPanes
        | Command::ListPaneSurfaces
        | Command::FocusPane
        | Command::NewPane
        | Command::ResizePane
        | Command::SwapPane
        | Command::BreakPane
        | Command::JoinPane
        | Command::LastPane
        | Command::NextWindow
        | Command::PreviousWindow
        | Command::LastWindow
        | Command::ReorderWorkspace => panes::render(command, result),
        Command::WaitSurface | Command::PromptAgent | Command::WatchEvents => {
            format_wait(command, result)
        }
        Command::StorageScan => format_storage_scan(result),
        Command::StorageClean => format_storage_clean(result),
        Command::MoveSurface => format!(
            "OK {} {} {}
",
            field(result, "surface_id"),
            field(result, "window_id"),
            field(result, "pane_id")
        ),
        Command::Resume => match result.get("sent").and_then(Value::as_bool) {
            Some(true) => "OK\n".to_owned(),
            _ => format!("{}\n", str_or_empty(result, "command")),
        },
        Command::ReviewOpen => format!(
            "OK {} ({} files)\n",
            field(result, "surface_id"),
            result
                .get("file_count")
                .and_then(Value::as_u64)
                .unwrap_or(0)
        ),
        Command::ReviewRefresh => format!(
            "OK {} files\n",
            result
                .get("file_count")
                .and_then(Value::as_u64)
                .unwrap_or(0)
        ),
        Command::ReviewCommentAdd => format!("OK {}\n", field(result, "comment_id")),
        Command::ReviewCommentRemove => "OK\n".to_owned(),
        Command::ReviewCommentList => items(result, "comments")
            .iter()
            .map(|comment| {
                let start = comment
                    .get("start_line")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let end = comment
                    .get("end_line")
                    .and_then(Value::as_u64)
                    .unwrap_or(start);
                let range = if start == end {
                    format!("{start}")
                } else {
                    format!("{start}-{end}")
                };
                format!(
                    "{}  {}:{range} \u{2014} {}\n",
                    str_or_empty(comment, "id"),
                    str_or_empty(comment, "file_path"),
                    str_or_empty(comment, "text")
                )
            })
            .collect(),
        Command::ReviewSend => format!(
            "OK sent {}\n",
            result
                .get("sent_count")
                .and_then(Value::as_u64)
                .unwrap_or(0)
        ),
        Command::SelectWorkspace
        | Command::CloseWorkspace
        | Command::RenameWorkspace
        | Command::FocusSurface
        | Command::CloseSurface
        | Command::Send
        | Command::Notify
        | Command::ClearNotifications
        | Command::SetAgentState
        | Command::StopPort
        | Command::WorktreeRemove => "OK\n".to_owned(),
    }
}

/// `worktree.list` as one line per worktree: path, branch (or detached), and whether it is open.
fn format_worktrees(result: &Value) -> String {
    items(result, "worktrees")
        .iter()
        .map(|worktree| {
            let branch = worktree
                .get("branch")
                .and_then(Value::as_str)
                .unwrap_or("(detached)");
            let open = worktree.get("is_open").and_then(Value::as_bool) == Some(true);
            format!(
                "{}  {branch}{}\n",
                str_or_empty(worktree, "path"),
                if open { "  [open]" } else { "" }
            )
        })
        .collect()
}

/// An absolute path for the app, which does not share the CLI's working directory.
fn absolute(path: String) -> String {
    std::path::absolute(&path)
        .map(|absolute| absolute.to_string_lossy().into_owned())
        .unwrap_or(path)
}

/// `ports.list` as one line per port, under its workspace, then the processes left running.
/// `wait-surface` prints what resolved it (the match, `exited`, the state), `prompt-agent` the
/// agent's final state or the warning; a surface that closed prints `closed`.
fn format_wait(command: Command, result: &Value) -> String {
    let text = |key: &str| result.get(key).and_then(Value::as_str);
    let line = if text("outcome") == Some("closed") {
        "closed"
    } else if command == Command::PromptAgent {
        text("warning").or(text("final_state")).unwrap_or("ok")
    } else {
        match text("condition") {
            Some("pattern") => text("match").unwrap_or("ok"),
            Some("exit") => "exited",
            Some("agent_state") => text("state").unwrap_or("ok"),
            Some("program_state") => text("program_state").unwrap_or("ok"),
            _ => "ok",
        }
    };
    format!("{line}\n")
}

/// `programa routes`: each loaded route with its counters and last error, then the ones that did not load.
fn format_routes(result: &Value) -> String {
    let routes = items(result, "routes");
    let mut out = String::new();
    if routes.is_empty() {
        out.push_str("No routes loaded\n");
    } else {
        let mut rows = vec![[
            "NAME",
            "ON",
            "ACTION",
            "MATCHED",
            "FIRED",
            "THROTTLED",
            "BUSY",
            "EXPIRED",
        ]
        .map(str::to_owned)
        .to_vec()];
        for route in routes {
            let mut row: Vec<String> = ["name", "on", "action"]
                .iter()
                .map(|key| str_or_empty(route, key).to_owned())
                .collect();
            for key in ["matched", "fired", "throttled", "busy", "expired"] {
                row.push(
                    route
                        .get(key)
                        .and_then(Value::as_u64)
                        .unwrap_or(0)
                        .to_string(),
                );
            }
            rows.push(row);
        }
        let widths: Vec<usize> = (0..8)
            .map(|column| {
                rows.iter()
                    .map(|row| row[column].chars().count())
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        for row in &rows {
            let line: Vec<String> = row
                .iter()
                .zip(&widths)
                .map(|(cell, width)| format!("{cell:width$}"))
                .collect();
            out.push_str(line.join("  ").trim_end());
            out.push('\n');
        }
        for route in routes {
            if let Some(error) = route.get("last_error").and_then(Value::as_str) {
                out.push_str(&format!("{}: {error}\n", str_or_empty(route, "name")));
            }
        }
    }
    let issues = items(result, "issues");
    if !issues.is_empty() {
        out.push_str(&format!("Not loaded ({}):\n", issues.len()));
        for issue in issues {
            let name = issue.get("name").and_then(Value::as_str).map_or_else(
                || {
                    issue
                        .get("index")
                        .and_then(Value::as_u64)
                        .map_or_else(|| "routes".to_owned(), |index| format!("#{}", index + 1))
                },
                str::to_owned,
            );
            out.push_str(&format!("  {name}: {}\n", str_or_empty(issue, "message")));
        }
    }
    out
}

/// "1.2 GB": decimal units, as the macOS CLI's file byte count.
fn storage_bytes(value: Option<&Value>) -> String {
    let bytes = value.and_then(Value::as_u64).unwrap_or(0);
    let units = ["bytes", "KB", "MB", "GB", "TB"];
    let mut size = bytes as f64;
    let mut unit = 0;
    while size >= 1000.0 && unit < units.len() - 1 {
        size /= 1000.0;
        unit += 1;
    }
    match unit {
        0 => format!("{bytes} bytes"),
        _ if size >= 100.0 => format!("{size:.0} {}", units[unit]),
        _ => format!("{} {}", (size * 10.0).round() / 10.0, units[unit]),
    }
}

fn storage_blocker(blocker: Option<&str>, message: Option<&str>) -> String {
    let text = match blocker {
        None => return "kept".to_owned(),
        Some("external") => "external (outside worktrees.directory)",
        Some("status_unknown") => "status unknown",
        Some("dirty") => "dirty (uncommitted or untracked changes)",
        Some("env_files") => "holds ignored .env files",
        Some("not_merged") => "not merged",
        Some("open_in_workspace") => "open in a workspace",
        Some("process_running") => "a process is running inside",
        Some("recently_used") => "recently used",
        Some("git_refused") => "git refused",
        Some(other) => other,
    };
    match message {
        Some(message) if !message.is_empty() => format!("{text}: {message}"),
        _ => text.to_owned(),
    }
}

/// `storage scan`, laid out as on macOS: a worktree table, totals, then caches by category.
fn format_storage_scan(result: &Value) -> String {
    let worktrees = items(result, "worktrees");
    let mut out = String::new();
    if worktrees.is_empty() {
        out.push_str("No git worktrees found\n");
    }
    let mut rows = vec![[
        "PATH".to_owned(),
        "BRANCH".to_owned(),
        "SIZE".to_owned(),
        "STATUS".to_owned(),
    ]];
    for worktree in worktrees {
        let partial = if worktree.get("size_partial").and_then(Value::as_bool) == Some(true) {
            "+"
        } else {
            ""
        };
        let status = if worktree.get("removable").and_then(Value::as_bool) == Some(true) {
            "removable".to_owned()
        } else {
            storage_blocker(worktree.get("blocker").and_then(Value::as_str), None)
        };
        let branch = worktree
            .get("branch")
            .and_then(Value::as_str)
            .unwrap_or("(detached)");
        rows.push([
            str_or_empty(worktree, "path").to_owned(),
            branch.to_owned(),
            storage_bytes(worktree.get("size_bytes")) + partial,
            status,
        ]);
    }
    let widths: Vec<usize> = (0..3)
        .map(|column| {
            rows.iter()
                .map(|row| row[column].chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    for row in &rows {
        for column in 0..3 {
            out.push_str(&format!("{:width$}  ", row[column], width = widths[column]));
        }
        out.push_str(&row[3]);
        out.push('\n');
    }
    out.push_str(&format!(
        "\nTotal: {} in {} worktree(s); reclaimable: {}\n",
        storage_bytes(result.get("total_bytes")),
        worktrees.len(),
        storage_bytes(result.get("reclaimable_bytes"))
    ));
    if worktrees
        .iter()
        .any(|worktree| worktree.get("size_partial").and_then(Value::as_bool) == Some(true))
    {
        out.push_str("+ size walk stopped early; the real size is larger\n");
    }
    let caches = items(result, "caches");
    for category in ["xcode", "android", "packages"] {
        let in_category: Vec<&Value> = caches
            .iter()
            .filter(|cache| cache.get("category").and_then(Value::as_str) == Some(category))
            .collect();
        if in_category.is_empty() {
            continue;
        }
        out.push_str(&format!("\n{category}:\n"));
        for cache in in_category {
            let status = match cache.get("blocker").and_then(Value::as_str) {
                Some(blocker) => format!("blocked: {blocker}"),
                None if cache.get("auto_cleanable").and_then(Value::as_bool) == Some(true) => {
                    "auto-clean".to_owned()
                }
                None => "manual only".to_owned(),
            };
            let partial = if cache.get("size_partial").and_then(Value::as_bool) == Some(true) {
                "+"
            } else {
                ""
            };
            out.push_str(&format!(
                "  {}  {}{partial}  {status}\n    {}  {}\n",
                str_or_empty(cache, "id"),
                storage_bytes(cache.get("size_bytes")),
                str_or_empty(cache, "title"),
                str_or_empty(cache, "path")
            ));
        }
    }
    out
}

/// `storage clean`: what was (or, with --dry-run, would be) removed, and what was kept and why.
fn format_storage_clean(result: &Value) -> String {
    let dry_run = result.get("dry_run").and_then(Value::as_bool) == Some(true);
    let removed: Vec<&str> = items(result, "removed")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    let kept = items(result, "kept");
    let bytes = storage_bytes(result.get("reclaimed_bytes"));
    let mut out = String::new();
    if removed.is_empty() {
        out.push_str(if dry_run {
            "Nothing to remove\n"
        } else {
            "Removed nothing\n"
        });
    } else {
        out.push_str(&if dry_run {
            format!("Would remove {} worktree(s), {bytes}:\n", removed.len())
        } else {
            format!(
                "Removed {} worktree(s), reclaimed {bytes}:\n",
                removed.len()
            )
        });
        for path in &removed {
            out.push_str(&format!("  {path}\n"));
        }
    }
    if !kept.is_empty() {
        out.push_str(&format!("Kept {}:\n", kept.len()));
        for item in kept {
            out.push_str(&format!(
                "  {}  {}\n",
                str_or_empty(item, "path"),
                storage_blocker(
                    item.get("blocker").and_then(Value::as_str),
                    item.get("message").and_then(Value::as_str)
                )
            ));
        }
    }
    let caches_removed = items(result, "caches_removed");
    if !caches_removed.is_empty() {
        out.push_str(&format!(
            "{} {} cache item(s), {}:\n",
            if dry_run { "Would remove" } else { "Removed" },
            caches_removed.len(),
            storage_bytes(result.get("caches_reclaimed_bytes"))
        ));
        for cache in caches_removed {
            out.push_str(&format!("  {}\n", str_or_empty(cache, "id")));
        }
    }
    let caches_kept = items(result, "caches_kept");
    if !caches_kept.is_empty() {
        out.push_str(&format!("Kept {} cache item(s):\n", caches_kept.len()));
        for cache in caches_kept {
            let blocker = cache
                .get("blocker")
                .and_then(Value::as_str)
                .unwrap_or("kept");
            out.push_str(&format!("  {}  {blocker}\n", str_or_empty(cache, "id")));
        }
    }
    out
}

fn format_ports(result: &Value) -> String {
    let mut out = String::new();
    for workspace in items(result, "workspaces") {
        out.push_str(&format!("{}\n", str_or_empty(workspace, "title")));
        for port in items(workspace, "ports") {
            out.push_str(&format!(
                "  :{}  {}  pid {}\n",
                port.get("port").and_then(Value::as_u64).unwrap_or(0),
                str_or_empty(port, "command"),
                port.get("pid").and_then(Value::as_u64).unwrap_or(0)
            ));
        }
    }
    let left = items(result, "left_running");
    if !left.is_empty() {
        out.push_str("Left running\n");
    }
    for process in left {
        let ports: Vec<String> = items(process, "ports")
            .iter()
            .filter_map(Value::as_u64)
            .map(|port| format!(":{port}"))
            .collect();
        out.push_str(&format!(
            "  {}  {}  pid {}  (was in {})\n",
            ports.join(" "),
            str_or_empty(process, "command"),
            process.get("pid").and_then(Value::as_u64).unwrap_or(0),
            str_or_empty(process, "workspace_title")
        ));
    }
    out
}

/// Every (pid, command) that `ports.list` reports listening on `port`.
fn pids_on_port(result: &Value, port: u64) -> Vec<(u64, String)> {
    let pid = |value: &Value| value.get("pid").and_then(Value::as_u64).unwrap_or(0);
    let mut pids: Vec<(u64, String)> = items(result, "workspaces")
        .iter()
        .flat_map(|workspace| items(workspace, "ports"))
        .filter(|entry| entry.get("port").and_then(Value::as_u64) == Some(port))
        .map(|entry| (pid(entry), str_or_empty(entry, "command").to_owned()))
        .chain(
            items(result, "left_running")
                .iter()
                .filter(|process| {
                    items(process, "ports")
                        .iter()
                        .any(|p| p.as_u64() == Some(port))
                })
                .map(|process| (pid(process), str_or_empty(process, "command").to_owned())),
        )
        .collect();
    pids.dedup_by_key(|(pid, _)| *pid);
    pids
}

/// `workspace.list` as one line per workspace (`* ` marks the selected one)
/// and, with `surfaces`, one indented line per surface.
fn format_workspaces(result: &Value, surfaces: bool) -> String {
    let mut out = String::new();
    for workspace in items(result, "workspaces") {
        let marker = if workspace.get("selected").and_then(Value::as_bool) == Some(true) {
            "* "
        } else {
            "  "
        };
        out.push_str(&format!(
            "{marker}{}  {}\n",
            str_or_empty(workspace, "title"),
            str_or_empty(workspace, "id")
        ));
        if !surfaces {
            continue;
        }
        for surface in items(workspace, "surfaces") {
            out.push_str(&format!(
                "    {}  {}",
                str_or_empty(surface, "title"),
                str_or_empty(surface, "id")
            ));
            if let Some(cwd) = surface.get("cwd").and_then(Value::as_str) {
                out.push_str(&format!("  {cwd}"));
            }
            out.push('\n');
        }
    }
    out
}

fn format_notifications(result: &Value) -> String {
    let mut out = String::new();
    for notification in items(result, "notifications") {
        let read = notification.get("is_read").and_then(Value::as_bool) == Some(true);
        out.push_str(if read { "[read] " } else { "[unread] " });
        out.push_str(str_or_empty(notification, "title"));
        let body = str_or_empty(notification, "body");
        if !body.is_empty() {
            out.push_str(" \u{2014} ");
            out.push_str(body);
        }
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_env(_: &str) -> Option<String> {
        None
    }

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn request_with(list: &[&str], env: Env) -> Request {
        match parse_invocation(&args(list), env) {
            Ok(Invocation::Call { request, .. }) => request,
            other => panic!("expected a call for {list:?}, got {other:?}"),
        }
    }

    fn request(list: &[&str]) -> Request {
        request_with(list, &no_env)
    }

    fn usage_error(list: &[&str]) -> String {
        match parse_invocation(&args(list), &no_env) {
            Err(UsageError(message)) => message,
            other => panic!("expected a usage error for {list:?}, got {other:?}"),
        }
    }

    fn params(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn storage_clean_takes_repeated_items_and_paths() {
        // An absolute path on the platform running the tests, so it is passed through as given.
        let path = if cfg!(windows) { r"C:\w\one" } else { "/w/one" };
        let clean = request(&[
            "storage",
            "clean",
            "--dry-run",
            "--caches",
            "--item",
            "packages.npm",
            "--item=packages.pnpm",
            "--path",
            path,
            "--now",
        ]);
        assert_eq!(clean.command.method(), "storage.clean");
        assert_eq!(clean.params["dry_run"], json!(true));
        assert_eq!(clean.params["ignore_grace_period"], json!(true));
        assert_eq!(clean.params["include_external"], json!(false));
        assert_eq!(
            clean.params["categories"],
            json!(["xcode", "android", "packages"])
        );
        assert_eq!(
            clean.params["items"],
            json!(["packages.npm", "packages.pnpm"])
        );
        assert_eq!(clean.params["paths"], json!([path]));
        // Without a cache flag, no cache is cleaned.
        assert_eq!(
            request(&["storage", "clean"]).params["categories"],
            json!([])
        );
        assert_eq!(
            usage_error(&["storage", "scan", "--dry-run"]),
            "storage scan: --dry-run only applies to 'storage clean'"
        );
        assert_eq!(
            usage_error(&["storage"]),
            "storage: missing subcommand (scan or clean)"
        );
        assert_eq!(
            usage_error(&["storage", "clean", "--item"]),
            "storage clean: --item needs a value"
        );
    }

    #[test]
    fn routes_lists_counters_errors_and_issues() {
        assert_eq!(request(&["routes"]).command.method(), "routes.list");
        let text = format_routes(&json!({
            "source": "file",
            "routes": [{"name": "tests-on-idle", "on": "agent/+/state/idle", "action": "run",
                        "matched": 3, "fired": 1, "throttled": 2, "busy": 0, "expired": 0,
                        "last_error": "exited with status 1"}],
            "issues": [{"index": 2, "name": null, "message": "'name' is required."}]
        }));
        assert_eq!(
            text,
            "NAME           ON                  ACTION  MATCHED  FIRED  THROTTLED  BUSY  EXPIRED\n\
             tests-on-idle  agent/+/state/idle  run     3        1      2          0     0\n\
             tests-on-idle: exited with status 1\n\
             Not loaded (1):\n  #3: 'name' is required.\n"
        );
    }

    #[test]
    fn automation_commands_take_the_macos_flags() {
        let wait = request(&[
            "wait-surface",
            "--surface",
            "s",
            "--pattern",
            "BUILD (OK|FAILED)",
            "--timeout",
            "1.5",
        ]);
        assert_eq!(wait.command.method(), "surface.wait");
        assert_eq!(
            Value::Object(wait.params),
            json!({"surface_id": "s", "pattern": "BUILD (OK|FAILED)", "timeout_ms": 1500})
        );
        assert_eq!(
            request(&["wait-surface", "--exit"]).params["exit"],
            json!(true)
        );
        assert!(usage_error(&["wait-surface", "--exit", "--pattern", "x"]).contains("exactly one"));
        assert!(usage_error(&["wait-surface", "--agent-state", "busy"]).contains("must be one of"));
        assert!(usage_error(&["wait-surface", "--exit", "--timeout", "0"]).contains("positive"));

        let prompt = request(&[
            "prompt-agent",
            "--surface",
            "s",
            "--working-grace",
            "2",
            "--force",
            "--",
            "fix",
            "the",
            "build",
        ]);
        assert_eq!(prompt.command.method(), "agent.prompt");
        assert_eq!(
            Value::Object(prompt.params),
            json!({"surface_id": "s", "text": "fix the build", "working_grace_ms": 2000, "force": true})
        );
        assert!(usage_error(&["prompt-agent"]).contains("prompt text"));

        let watch = request(&[
            "watch-events",
            "--needs-input",
            "--output",
            "a, b",
            "--no-reconnect",
        ]);
        assert_eq!(
            Value::Object(watch.params),
            json!({"classes": ["needs_input", "output"], "surface_ids": ["a", "b"], "no_reconnect": true})
        );
        assert!(usage_error(&["watch-events"]).contains("at least one"));

        assert_eq!(
            format_wait(
                Command::WaitSurface,
                &json!({"condition": "pattern", "match": "BUILD OK"})
            ),
            "BUILD OK\n"
        );
        assert_eq!(
            format_wait(Command::PromptAgent, &json!({"final_state": "idle"})),
            "idle\n"
        );
        assert_eq!(
            format_wait(
                Command::WaitSurface,
                &json!({"condition": "exit", "outcome": "closed"})
            ),
            "closed\n"
        );
    }

    #[test]
    fn move_surface_takes_the_macos_flags() {
        let moved = request(&[
            "move-surface",
            "s1",
            "--window",
            "w2",
            "--after",
            "s0",
            "--focus",
            "true",
        ]);
        assert_eq!(moved.command.method(), "surface.move");
        assert_eq!(
            Value::Object(moved.params),
            json!({"surface_id": "s1", "window_id": "w2", "after_surface_id": "s0", "focus": true})
        );
        let here = request_with(&["move-surface", "--pane", "p", "--index", "0"], &|key| {
            (key == SURFACE_ENV).then(|| "env-surface".to_owned())
        });
        assert_eq!(
            Value::Object(here.params),
            json!({"surface_id": "env-surface", "pane_id": "p", "index": 0})
        );
        assert_eq!(
            usage_error(&["move-surface", "s", "--focus", "yes"]),
            "--focus must be true|false"
        );
    }

    #[test]
    fn storage_output_matches_macos() {
        let scan = format_storage_scan(&json!({
            "worktrees": [
                {"path": r"C:\w\a", "branch": "feat", "size_bytes": 1_500_000, "size_partial": false, "removable": true, "blocker": null},
                {"path": r"C:\w\bb", "branch": null, "size_bytes": 12, "size_partial": true, "removable": false, "blocker": "dirty"}
            ],
            "total_bytes": 1_500_012, "reclaimable_bytes": 1_500_000,
            "caches": [{"id": "packages.npm", "category": "packages", "title": "npm", "path": r"C:\c\_cacache", "size_bytes": 250_000_000, "size_partial": false, "auto_cleanable": false, "blocker": null}]
        }));
        assert!(
            scan.contains(r"C:\w\a   feat        1.5 MB     removable"),
            "{scan}"
        );
        assert!(
            scan.contains(
                r"C:\w\bb  (detached)  12 bytes+  dirty (uncommitted or untracked changes)"
            ),
            "{scan}"
        );
        assert!(
            scan.contains("Total: 1.5 MB in 2 worktree(s); reclaimable: 1.5 MB"),
            "{scan}"
        );
        assert!(
            scan.contains(
                "packages:\n  packages.npm  250 MB  manual only\n    npm  C:\\c\\_cacache\n"
            ),
            "{scan}"
        );
        let clean = format_storage_clean(&json!({
            "dry_run": true, "removed": [r"C:\w\a"], "reclaimed_bytes": 1_500_000,
            "kept": [{"path": r"C:\w\bb", "blocker": "git_refused", "message": "in use"}],
            "caches_removed": [], "caches_kept": [], "caches_reclaimed_bytes": 0
        }));
        assert_eq!(clean, "Would remove 1 worktree(s), 1.5 MB:\n  C:\\w\\a\nKept 1:\n  C:\\w\\bb  git refused: in use\n");
    }

    #[test]
    fn decodes_send_escapes() {
        assert_eq!(decode_escapes(r"ls -la\n"), "ls -la\n");
        assert_eq!(decode_escapes(r"a\rb\tc"), "a\rb\tc");
        assert_eq!(decode_escapes(r"\e[A"), "\u{1b}[A");
        assert_eq!(decode_escapes(r"C:\\Users"), r"C:\Users");
        assert_eq!(decode_escapes(r"\x\q"), r"\x\q");
        assert_eq!(decode_escapes(r"end\"), r"end\");
        assert_eq!(decode_escapes(r"\\n"), r"\n");
        assert_eq!(decode_escapes("plain"), "plain");
    }

    #[test]
    fn send_decodes_text_and_joins_words() {
        let req = request(&["send", "echo", r"hi\n"]);
        assert_eq!(req.command.method(), "surface.send_text");
        assert_eq!(req.params, params(json!({"text": "echo hi\n"})));
        assert_eq!(usage_error(&["send"]), "send: missing text");
        let req = request(&["send", "--", "-x"]);
        assert_eq!(req.params, params(json!({"text": "-x"})));
    }

    #[test]
    fn new_split_defaults_to_right_and_validates_direction() {
        let req = request(&["new-split"]);
        assert_eq!(req.command.method(), "surface.split");
        assert_eq!(req.params, params(json!({"direction": "right"})));

        let req = request(&[
            "new-split",
            "down",
            "--cwd",
            "C:\\src",
            "--command",
            "git status",
        ]);
        assert_eq!(
            req.params,
            params(json!({"direction": "down", "cwd": "C:\\src", "initial_command": "git status"}))
        );

        assert!(usage_error(&["new-split", "sideways"]).contains("left, right, up or down"));
        assert_eq!(request(&["new-split", "left"]).params["direction"], "left");
        assert!(usage_error(&["new-split", "right", "down"]).contains("unexpected argument"));
    }

    #[test]
    fn surface_and_workspace_default_from_env() {
        let env = |key: &str| match key {
            "PROGRAMA_SURFACE_ID" => Some("surf-env".to_owned()),
            "PROGRAMA_WORKSPACE_ID" => Some("ws-env".to_owned()),
            _ => None,
        };
        let req = request_with(&["send", "x"], &env);
        assert_eq!(
            req.params,
            params(json!({"surface_id": "surf-env", "text": "x"}))
        );
        let req = request_with(&["send", "--surface", "surf-flag", "x"], &env);
        assert_eq!(req.params["surface_id"], "surf-flag");
        let req = request_with(&["send", "--surface=surf-eq", "x"], &env);
        assert_eq!(req.params["surface_id"], "surf-eq");

        let req = request_with(&["notify", "--title", "Done"], &env);
        assert_eq!(
            req.params,
            params(json!({"title": "Done", "workspace_id": "ws-env", "surface_id": "surf-env"}))
        );
        let req = request_with(&["close-workspace"], &env);
        assert_eq!(req.params, params(json!({"workspace_id": "ws-env"})));

        // new-workspace and listings never pick up the env defaults.
        assert!(request_with(&["new-workspace"], &env).params.is_empty());
        assert!(request_with(&["list-workspaces"], &env).params.is_empty());
        assert!(request_with(&["tree"], &env).params.is_empty());
        assert!(request_with(&["list-notifications"], &env)
            .params
            .is_empty());

        // Without env (or with an empty value) the target is omitted.
        let empty = |_: &str| Some(String::new());
        assert_eq!(request_with(&["close-surface"], &empty).params, Map::new());
        assert_eq!(request(&["close-surface"]).params, Map::new());
    }

    #[test]
    fn notify_requires_title() {
        assert_eq!(usage_error(&["notify"]), "notify: --title is required");
        assert_eq!(
            usage_error(&["notify", "--body", "x"]),
            "notify: --title is required"
        );
        assert_eq!(
            usage_error(&["notify", "--title"]),
            "notify: --title needs a value"
        );
        let req = request(&["notify", "--title", "T", "--subtitle", "S", "--body", "B"]);
        assert_eq!(req.command.method(), "notification.create");
        assert_eq!(
            req.params,
            params(json!({"title": "T", "subtitle": "S", "body": "B"}))
        );
    }

    #[test]
    fn maps_commands_to_methods_and_params() {
        let req = request(&[
            "new-workspace",
            "--cwd",
            "D:\\p",
            "--command",
            "npm test",
            "--title",
            "W",
        ]);
        assert_eq!(req.command.method(), "workspace.create");
        assert_eq!(
            req.params,
            params(json!({"cwd": "D:\\p", "initial_command": "npm test", "title": "W"}))
        );
        let req = request(&["new-surface", "--workspace", "w1", "--pane", "p1"]);
        assert_eq!(req.command.method(), "surface.create");
        assert_eq!(
            req.params,
            params(json!({"workspace_id": "w1", "pane_id": "p1"}))
        );
        let req = request(&["select-workspace", "w2"]);
        assert_eq!(req.command.method(), "workspace.select");
        assert_eq!(req.params, params(json!({"workspace_id": "w2"})));
        let req = request(&["rename-workspace", "My", "Work", "--workspace", "w3"]);
        assert_eq!(req.command.method(), "workspace.rename");
        assert_eq!(
            req.params,
            params(json!({"workspace_id": "w3", "title": "My Work"}))
        );
        let req = request(&["focus-surface", "s1"]);
        assert_eq!(req.command.method(), "surface.focus");
        assert_eq!(req.params, params(json!({"surface_id": "s1"})));
        let req = request(&["clear-notifications", "--workspace", "w4"]);
        assert_eq!(req.command.method(), "notification.clear");
        let req = request(&["read-screen", "--lines", "20", "--scrollback"]);
        assert_eq!(req.command.method(), "surface.read_text");
        assert_eq!(req.params, params(json!({"lines": 20, "scrollback": true})));
        assert_eq!(
            request(&["read-screen"]).params,
            params(json!({"scrollback": false}))
        );
        assert!(usage_error(&["read-screen", "--lines", "abc"]).contains("positive integer"));
        assert_eq!(request(&["ping"]).command.method(), "system.ping");
        assert_eq!(request(&["identify"]).command.method(), "system.identify");
        assert_eq!(
            usage_error(&["select-workspace"]),
            "select-workspace: missing workspace ID"
        );
        assert_eq!(
            usage_error(&["focus-surface", "a", "b"]),
            "focus-surface: unexpected argument 'b'"
        );
    }

    #[test]
    fn set_agent_state_validates_state() {
        let req = request(&["set-agent-state", "blocked", "--source", "claude"]);
        assert_eq!(req.command.method(), "surface.report_agent_state");
        assert_eq!(
            req.params,
            params(json!({"state": "blocked", "source": "claude"}))
        );
        assert!(usage_error(&["set-agent-state", "busy"]).contains("not 'busy'"));
        assert!(usage_error(&["set-agent-state"]).contains("missing state"));
    }

    #[test]
    fn global_flags_help_version_and_errors() {
        match parse_invocation(
            &args(&["--json", "--socket", r"\\.\pipe\x", "ping"]),
            &no_env,
        ) {
            Ok(Invocation::Call {
                json,
                socket,
                request,
            }) => {
                assert!(json);
                assert_eq!(socket.as_deref(), Some(r"\\.\pipe\x"));
                assert_eq!(request.command, Command::Ping);
            }
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(parse_invocation(&[], &no_env), Ok(Invocation::Help));
        assert_eq!(
            parse_invocation(&args(&["help"]), &no_env),
            Ok(Invocation::Help)
        );
        assert_eq!(
            parse_invocation(&args(&["-h"]), &no_env),
            Ok(Invocation::Help)
        );
        assert_eq!(
            parse_invocation(&args(&["-V"]), &no_env),
            Ok(Invocation::Version)
        );
        assert_eq!(usage_error(&["frobnicate"]), "unknown command 'frobnicate'");
        assert_eq!(usage_error(&["--bogus"]), "unknown option '--bogus'");
        assert_eq!(
            usage_error(&["ping", "--bogus"]),
            "ping: unknown option '--bogus'"
        );
        assert_eq!(usage_error(&["--socket"]), "--socket needs a path");
    }

    #[test]
    fn request_line_is_one_json_object() {
        let line = request(&["select-workspace", "w1"]).to_line(1);
        assert!(!line.contains('\n'));
        let value: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(
            value,
            json!({"id": 1, "method": "workspace.select", "params": {"workspace_id": "w1"}})
        );
    }

    #[test]
    fn socket_path_precedence() {
        let env = |key: &str| match key {
            "PROGRAMA_SOCKET_PATH" => Some("from-path".to_owned()),
            "PROGRAMA_SOCKET" => Some("from-socket".to_owned()),
            "USERNAME" => Some("ada".to_owned()),
            "HOME" => Some("/home/ada".to_owned()),
            _ => None,
        };
        assert_eq!(resolve_socket_path(Some("flag"), &env), "flag");
        assert_eq!(resolve_socket_path(None, &env), "from-path");
        let only_socket = |key: &str| (key == "PROGRAMA_SOCKET").then(|| "from-socket".to_owned());
        assert_eq!(resolve_socket_path(None, &only_socket), "from-socket");
        let only_user = |key: &str| match key {
            "USERNAME" => Some("ada".to_owned()),
            "HOME" => Some("/home/ada".to_owned()),
            _ => None,
        };
        #[cfg(windows)]
        assert_eq!(
            resolve_socket_path(None, &only_user),
            r"\\.\pipe\programa-ada"
        );
        #[cfg(not(windows))]
        assert_eq!(
            resolve_socket_path(None, &only_user),
            "/home/ada/Library/Application Support/programa/programa.sock"
        );
    }

    #[test]
    fn parses_success_and_error_envelopes() {
        assert_eq!(
            parse_response(r#"{"id":1,"ok":true,"result":{"a":1}}"#),
            Ok(json!({"a": 1}))
        );
        assert_eq!(
            parse_response(
                r#"{"id":1,"ok":false,"error":{"code":"not_found","message":"No such surface"}}"#
            ),
            Err("No such surface".to_owned())
        );
        assert_eq!(
            parse_response(r#"{"id":1,"ok":false,"error":{"code":"not_found","message":""}}"#),
            Err("not_found".to_owned())
        );
        assert!(parse_response("not json")
            .unwrap_err()
            .starts_with("invalid response"));
    }

    fn sample_workspaces() -> Value {
        json!({"workspaces": [
            {"id": "w1", "title": "main", "selected": true, "surfaces": [
                {"id": "s1", "title": "pwsh", "cwd": "C:\\src", "selected": true, "pane_id": "p1"},
                {"id": "s2", "title": "logs", "cwd": null, "selected": false, "pane_id": "p2"}
            ]},
            {"id": "w2", "title": "docs", "selected": false, "surfaces": []}
        ]})
    }

    #[test]
    fn formats_tree_and_workspace_list() {
        assert_eq!(
            render(Command::Tree, &sample_workspaces()),
            "* main  w1\n    pwsh  s1  C:\\src\n    logs  s2\n  docs  w2\n"
        );
        assert_eq!(
            render(Command::ListWorkspaces, &sample_workspaces()),
            "* main  w1\n  docs  w2\n"
        );
        assert_eq!(render(Command::Tree, &json!({"workspaces": []})), "");
    }

    #[test]
    fn formats_other_results() {
        assert_eq!(render(Command::Ping, &json!({"pong": true})), "PONG\n");
        assert_eq!(
            render(
                Command::Identify,
                &json!({"surface_id": "s1", "workspace_id": "w1"})
            ),
            "surface s1\nworkspace w1\n"
        );
        assert_eq!(
            render(
                Command::NewSplit,
                &json!({"surface_id": "s9", "workspace_id": "w1"})
            ),
            "OK s9 w1\n"
        );
        assert_eq!(render(Command::Notify, &json!({})), "OK\n");
        assert_eq!(
            render(Command::ReadScreen, &json!({"text": "a\nb"})),
            "a\nb\n"
        );
        assert_eq!(render(Command::ReadScreen, &json!({"text": "a\n"})), "a\n");
        assert_eq!(
            render(
                Command::ListNotifications,
                &json!({"notifications": [
                    {"id": "n1", "is_read": false, "title": "Build", "subtitle": "", "body": "passed"},
                    {"id": "n2", "is_read": true, "title": "Agent", "subtitle": "", "body": ""}
                ]})
            ),
            "[unread] Build \u{2014} passed\n[read] Agent\n"
        );
    }

    #[test]
    fn stop_port_takes_a_port_or_a_pid() {
        assert_eq!(
            request_with(&["stop-port", "3000"], &no_env).params,
            params(json!({"port": 3000}))
        );
        assert_eq!(
            request_with(&["stop-port", "--pid", "4242"], &no_env).params,
            params(json!({"pid": 4242}))
        );
        assert_eq!(
            usage_error(&["stop-port"]),
            "stop-port: give a port or --pid PID"
        );
        assert_eq!(
            usage_error(&["stop-port", "web"]),
            "stop-port: 'web' is not a number"
        );
    }

    #[test]
    fn finds_and_formats_listening_ports() {
        let result = json!({
            "workspaces": [{"title": "api", "ports": [
                {"port": 3000, "pid": 10, "command": "node"},
                {"port": 5173, "pid": 11, "command": "vite"}]}],
            "left_running": [{"pid": 12, "command": "node", "ports": [3000], "workspace_title": "web"}]
        });
        assert_eq!(
            pids_on_port(&result, 3000),
            vec![(10, "node".to_owned()), (12, "node".to_owned())]
        );
        assert!(pids_on_port(&result, 8080).is_empty());
        assert_eq!(
            format_ports(&result),
            "api\n  :3000  node  pid 10\n  :5173  vite  pid 11\nLeft running\n  :3000  node  pid 12  (was in web)\n"
        );
    }

    #[test]
    fn worktree_subcommands_are_one_command() {
        let request = request_with(
            &[
                "worktree",
                "create",
                "feature/x",
                "--repo",
                r"C:\src\app",
                "--base",
                "main",
                "--focus",
            ],
            &no_env,
        );
        assert_eq!(request.command, Command::WorktreeCreate);
        assert_eq!(
            request.params,
            params(
                json!({"repo": r"C:\src\app", "branch": "feature/x", "base": "main", "focus": true})
            )
        );
        let removed = request_with(
            &["worktree", "remove", "feature/x", "--repo", "r", "--force"],
            &no_env,
        );
        assert_eq!(
            removed.params,
            params(json!({"repo": "r", "branch": "feature/x", "force": true}))
        );
        assert_eq!(
            usage_error(&["worktree"]),
            "worktree: missing subcommand (create, open, remove or list)"
        );
        assert_eq!(
            format_worktrees(&json!({"worktrees": [
                {"path": "C:/src/app", "branch": "main", "is_open": true},
                {"path": "C:/wt/x", "branch": null, "is_open": false}]})),
            "C:/src/app  main  [open]\nC:/wt/x  (detached)\n"
        );
    }

    #[test]
    fn layout_subcommands_take_a_name() {
        let saved = request_with(&["layout", "save", "dev", "--force"], &no_env);
        assert_eq!(saved.command, Command::LayoutSave);
        assert_eq!(saved.params, params(json!({"name": "dev", "force": true})));
        let applied = request_with(&["layout", "apply", "dev", "--workspace", "w"], &no_env);
        assert_eq!(
            applied.params,
            params(json!({"name": "dev", "workspace_id": "w"}))
        );
        assert_eq!(
            usage_error(&["layout", "save"]),
            "layout save: missing layout name"
        );
        assert_eq!(
            usage_error(&["layout"]),
            "layout: missing subcommand (save, apply or list)"
        );
    }

    #[test]
    fn markdown_open_takes_a_path() {
        let opened = request_with(&["markdown", "notes.md", "--direction", "down"], &no_env);
        assert_eq!(opened.command, Command::MarkdownOpen);
        assert_eq!(opened.params["direction"], json!("down"));
        assert!(opened.params["path"]
            .as_str()
            .unwrap()
            .ends_with("notes.md"));
        let explicit = request_with(&["markdown", "open", "a.md", "--focus"], &no_env);
        assert_eq!(explicit.params["focus"], json!(true));
        assert_eq!(
            usage_error(&["markdown"]),
            "markdown open: missing file path"
        );
    }

    #[test]
    fn review_comments_take_a_file_a_range_and_text() {
        let added = request_with(
            &[
                "review",
                "comment",
                "add",
                "src/app.rs",
                "12-14",
                "add",
                "a",
                "guard",
            ],
            &no_env,
        );
        assert_eq!(added.command, Command::ReviewCommentAdd);
        assert_eq!(
            added.params,
            params(
                json!({"file_path": "src/app.rs", "start_line": 12, "end_line": 14, "text": "add a guard"})
            )
        );
        let one = request_with(&["review", "comment", "add", "a.rs", "7", "typo"], &no_env);
        assert_eq!(
            (
                one.params["start_line"].clone(),
                one.params["end_line"].clone()
            ),
            (json!(7), json!(7))
        );
        let opened = request_with(&["review", "open", "--mode", "worktree"], &no_env);
        assert_eq!(opened.params["mode"], json!("uncommitted"));
        assert_eq!(
            usage_error(&["review", "comment", "add", "a.rs", "x-y", "t"]),
            "review comment add: 'x-y' is not a line range"
        );
        assert_eq!(
            usage_error(&["review", "comment"]),
            "review comment: missing action (add, remove or list)"
        );
    }

    #[test]
    fn resume_targets_the_calling_terminal() {
        let env = |key: &str| (key == "PROGRAMA_SURFACE_ID").then(|| "surface-1".to_owned());
        let resumed = request_with(
            &[
                "resume",
                "--print",
                "--session",
                "abc",
                "--provider",
                "codex",
            ],
            &env,
        );
        assert_eq!(resumed.command, Command::Resume);
        assert_eq!(
            resumed.params,
            params(
                json!({"surface_id": "surface-1", "session": "abc", "provider": "codex", "print": true})
            )
        );
        assert_eq!(
            render(
                Command::Resume,
                &json!({"command": "claude --resume x", "sent": false})
            ),
            "claude --resume x\n"
        );
        assert_eq!(
            render(Command::Resume, &json!({"command": "c", "sent": true})),
            "OK\n"
        );
    }

    #[test]
    fn race_numbers_after_existing_branches_and_quotes_the_prompt() {
        let raced = request_with(
            &["race", "fix", "it's", "--n", "2", "--agent", "codex"],
            &no_env,
        );
        assert_eq!(raced.command, Command::Race);
        assert_eq!(raced.params["prompt"], json!("fix it's"));
        assert_eq!(raced.params["prefix"], json!("race"));
        assert_eq!(
            usage_error(&["race", "x", "--n", "9"]),
            "race: --n must be between 1 and 8"
        );
        assert_eq!(
            usage_error(&["race", "x", "--agent", "aider"]),
            "race: --agent must be one of claude, opencode, codex"
        );
        assert_eq!(race_start("race/1\nrace/3\nrace/x\nother/9\n", "race"), 4);
        assert_eq!(race_start("", "race"), 1);
        assert_eq!(race_launch("claude", "it's done"), "claude 'it''s done'");
        assert_eq!(race_launch("opencode", "go"), "opencode --prompt 'go'");
    }

    #[test]
    fn workspace_action_takes_dashed_names() {
        let moved = request_with(
            &["workspace-action", "move-up", "--workspace", "w"],
            &no_env,
        );
        assert_eq!(
            moved.params,
            params(json!({"action": "move_up", "workspace_id": "w"}))
        );
        let colored = request_with(
            &[
                "workspace-action",
                "--action",
                "set-color",
                "--color",
                "Blue",
            ],
            &no_env,
        );
        assert_eq!(
            colored.params,
            params(json!({"action": "set_color", "color": "Blue"}))
        );
        assert_eq!(
            usage_error(&["workspace-action"]),
            "workspace-action: give one action"
        );
    }

    #[test]
    fn window_commands_name_their_window() {
        let focused = request_with(&["focus-window", "--window", "window-2"], &no_env);
        assert_eq!(focused.command, Command::FocusWindow);
        assert_eq!(focused.params, params(json!({"window_id": "window-2"})));
        let closed = request_with(&["close-window", "window-3"], &no_env);
        assert_eq!(closed.params, params(json!({"window_id": "window-3"})));
        assert_eq!(
            usage_error(&["close-window"]),
            "close-window: --window <id> is required"
        );
        let env = |key: &str| (key == "PROGRAMA_WORKSPACE_ID").then(|| "workspace-1".to_owned());
        let moved = request_with(&["move-workspace-to-window", "--window", "new"], &env);
        assert_eq!(
            moved.params,
            params(json!({"workspace_id": "workspace-1", "window_id": "new"}))
        );
        assert_eq!(
            render(
                Command::ListWindows,
                &json!({"windows": [
                {"id": "window-1", "selected": true, "workspace_count": 2},
                {"id": "window-2", "selected": false, "workspace_count": 1}]})
            ),
            "* window-1  2 workspaces\n  window-2  1 workspaces\n"
        );
    }

    #[test]
    fn worktree_from_issue_names_the_branch_after_the_issue() {
        let created = request_with(
            &[
                "worktree",
                "create",
                "--from-issue",
                "42",
                "--agent",
                "claude",
                "--repo",
                "r",
            ],
            &no_env,
        );
        assert_eq!(
            created.params,
            params(json!({"repo": "r", "from_issue": 42, "agent": "claude"}))
        );
        assert_eq!(
            usage_error(&["worktree", "create", "x", "--agent", "claude", "--repo", "r"]),
            "worktree create: --agent requires --from-issue <number>"
        );
        assert_eq!(
            usage_error(&["worktree", "create", "--from-issue", "0", "--repo", "r"]),
            "worktree create: --from-issue must be a positive issue number, got '0'"
        );
        assert_eq!(
            issue_branch_name(42, "Fix: the *flaky* Login test (Windows)!"),
            "issue-42-fix-the-flaky-login-test-windows"
        );
        assert_eq!(issue_branch_name(7, "¡¿?!"), "issue-7");
        assert_eq!(
            issue_branch_name(1, &"a b ".repeat(30)),
            "issue-1-a-b-a-b-a-b-a-b-a-b-a-b-a-b-a-b-a-b-a-b"
        );
    }

    #[test]
    fn worktree_open_all_takes_no_target() {
        let all = request_with(&["worktree", "open", "--all", "--repo", "r"], &no_env);
        assert_eq!(all.params, params(json!({"repo": "r", "all": true})));
        assert_eq!(
            usage_error(&["worktree", "open", "--all", "x", "--repo", "r"]),
            "worktree open: --all takes no worktree and no --focus"
        );
    }
}
