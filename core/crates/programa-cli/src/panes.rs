//! Pane and workspace navigation commands, as on macOS (CLI/Commands/PaneCommands.swift and the
//! tmux-style commands in CLI/CLI+TmuxCompat.swift): list-panes, list-pane-surfaces, focus-pane,
//! new-pane, resize-pane, swap-pane, break-pane, join-pane, last-pane, next-window,
//! previous-window, last-window (workspaces, as tmux windows) and reorder-workspace.

use serde_json::{json, Map, Value};

use super::{
    field, items, no_positionals, parse_opts, parse_response, put, str_or_empty, target, transport,
    Command, Env, UsageError, ENDPOINT_KIND, WORKSPACE_ENV,
};

const DIRECTIONS: [&str; 4] = ["left", "right", "up", "down"];

pub(crate) fn params(
    command: Command,
    args: &[String],
    env: Env,
) -> Result<Map<String, Value>, UsageError> {
    let name = command.name();
    let mut params = Map::new();
    let workspace = |opts: &super::Opts| target(opts, "--workspace", WORKSPACE_ENV, env);
    match command {
        Command::ListPanes | Command::LastPane => {
            let opts = parse_opts(command, args, &["--workspace"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace_id", workspace(&opts));
        }
        Command::ListPaneSurfaces => {
            let opts = parse_opts(command, args, &["--workspace", "--pane"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "pane_id", opts.value("--pane"));
        }
        Command::FocusPane => {
            let opts = parse_opts(command, args, &["--workspace", "--pane"], &[])?;
            let pane = match (opts.value("--pane"), opts.positionals.as_slice()) {
                (Some(_), [_, ..]) => {
                    return Err(UsageError(format!("{name}: provide the pane once")))
                }
                (Some(pane), []) => pane,
                (None, [pane]) => pane.clone(),
                (None, []) => return Err(UsageError(format!("{name} requires --pane <id>"))),
                (None, [_, extra, ..]) => {
                    return Err(UsageError(format!("{name}: unexpected argument '{extra}'")))
                }
            };
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "pane_id", Some(pane));
        }
        Command::NewPane => {
            let opts = parse_opts(
                command,
                args,
                &["--type", "--direction", "--workspace"],
                &[],
            )?;
            no_positionals(command, &opts)?;
            if opts
                .value("--type")
                .is_some_and(|t| t.to_lowercase() != "terminal")
            {
                return Err(UsageError(format!("{name}: --type must be terminal")));
            }
            let direction = opts
                .value("--direction")
                .map_or_else(|| "right".to_owned(), |d| d.to_lowercase());
            if !DIRECTIONS.contains(&direction.as_str()) {
                return Err(UsageError(format!("{name}: invalid direction")));
            }
            put(&mut params, "direction", Some(direction));
            put(&mut params, "workspace_id", workspace(&opts));
        }
        Command::ResizePane => {
            let opts = parse_opts(
                command,
                args,
                &["--workspace", "--pane", "--amount"],
                &["-L", "-R", "-U", "-D"],
            )?;
            no_positionals(command, &opts)?;
            let cells = match opts.value("--amount") {
                None => 1,
                Some(raw) => raw.parse::<i64>().ok().filter(|n| *n > 0).ok_or_else(|| {
                    UsageError(format!("{name}: --amount must be greater than 0"))
                })?,
            };
            let direction = [
                ("-L", "left"),
                ("-R", "right"),
                ("-U", "up"),
                ("-D", "down"),
            ]
            .into_iter()
            .find(|(flag, _)| opts.has(flag))
            .map_or("right", |(_, direction)| direction);
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "pane_id", opts.value("--pane"));
            put(&mut params, "direction", Some(direction.to_owned()));
            params.insert("cells".into(), Value::from(cells));
        }
        Command::SwapPane => {
            let opts = parse_opts(
                command,
                args,
                &["--workspace", "--pane", "--target-pane"],
                &[],
            )?;
            no_positionals(command, &opts)?;
            let pane = opts
                .value("--pane")
                .ok_or_else(|| UsageError(format!("{name} requires --pane")))?;
            let target_pane = opts
                .value("--target-pane")
                .ok_or_else(|| UsageError(format!("{name} requires --target-pane")))?;
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "pane_id", Some(pane));
            put(&mut params, "target_pane_id", Some(target_pane));
        }
        Command::BreakPane | Command::JoinPane => {
            let mut flags = vec!["--workspace", "--pane", "--surface"];
            if command == Command::JoinPane {
                flags.push("--target-pane");
            }
            let opts = parse_opts(command, args, &flags, &["--no-focus"])?;
            no_positionals(command, &opts)?;
            if command == Command::JoinPane {
                let target_pane = opts
                    .value("--target-pane")
                    .ok_or_else(|| UsageError(format!("{name} requires --target-pane")))?;
                put(&mut params, "target_pane_id", Some(target_pane));
            }
            params.insert("focus".into(), Value::Bool(!opts.has("--no-focus")));
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "pane_id", opts.value("--pane"));
            put(&mut params, "surface_id", opts.value("--surface"));
        }
        Command::NextWindow | Command::PreviousWindow | Command::LastWindow => {
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
        }
        Command::ReorderWorkspace => {
            let opts = parse_opts(
                command,
                args,
                &[
                    "--workspace",
                    "--window",
                    "--before",
                    "--before-workspace",
                    "--after",
                    "--after-workspace",
                    "--index",
                ],
                &[],
            )?;
            let workspace_id = match (opts.value("--workspace"), opts.positionals.as_slice()) {
                (Some(id), []) => id,
                (None, [id]) => id.clone(),
                (Some(_), [extra, ..]) | (None, [_, extra, ..]) => {
                    return Err(UsageError(format!("{name}: unexpected argument '{extra}'")))
                }
                (None, []) => return Err(UsageError(format!("{name} requires --workspace <id>"))),
            };
            put(&mut params, "workspace_id", Some(workspace_id));
            put(&mut params, "window_id", opts.value("--window"));
            put(
                &mut params,
                "before_workspace_id",
                opts.value("--before").or(opts.value("--before-workspace")),
            );
            put(
                &mut params,
                "after_workspace_id",
                opts.value("--after").or(opts.value("--after-workspace")),
            );
            if let Some(raw) = opts.value("--index") {
                let index = raw
                    .parse::<i64>()
                    .map_err(|_| UsageError(format!("{name}: --index must be an integer")))?;
                params.insert("index".into(), Value::from(index));
            }
        }
        _ => unreachable!("not a pane command"),
    }
    Ok(params)
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    match command {
        Command::ListPanes => {
            let panes = items(result, "panes");
            if panes.is_empty() {
                return "No panes\n".to_owned();
            }
            panes
                .iter()
                .map(|pane| {
                    let focused = pane["focused"].as_bool() == Some(true);
                    let count = pane["surface_count"].as_u64().unwrap_or(0);
                    format!(
                        "{}{}  [{count} surface{}]{}\n",
                        if focused { "* " } else { "  " },
                        str_or_empty(pane, "id"),
                        if count == 1 { "" } else { "s" },
                        if focused { "  [focused]" } else { "" }
                    )
                })
                .collect()
        }
        Command::ListPaneSurfaces => {
            let surfaces = items(result, "surfaces");
            if surfaces.is_empty() {
                return "No surfaces in pane\n".to_owned();
            }
            surfaces
                .iter()
                .map(|surface| {
                    let selected = surface["selected"].as_bool() == Some(true);
                    format!(
                        "{}{}  {}{}\n",
                        if selected { "* " } else { "  " },
                        str_or_empty(surface, "id"),
                        str_or_empty(surface, "title"),
                        if selected { "  [selected]" } else { "" }
                    )
                })
                .collect()
        }
        Command::FocusPane => format!(
            "OK {} {}\n",
            field(result, "pane_id"),
            field(result, "workspace_id")
        ),
        Command::NewPane => format!(
            "OK {} {} {}\n",
            field(result, "surface_id"),
            field(result, "pane_id"),
            field(result, "workspace_id")
        ),
        Command::LastPane => format!("OK {}\n", field(result, "pane_id")),
        Command::NextWindow | Command::PreviousWindow | Command::LastWindow => {
            format!("OK {}\n", field(result, "workspace_id"))
        }
        Command::ReorderWorkspace => format!(
            "OK workspace={} window={} index={}\n",
            field(result, "workspace_id"),
            field(result, "window_id"),
            field(result, "index")
        ),
        _ => "OK\n".to_owned(),
    }
}

/// `resize-pane`: the pane's cell size (pane.list) turns the cells into the points pane.resize takes.
pub(crate) fn run_resize(path: &str, params: &Map<String, Value>, json_output: bool) -> i32 {
    let call = |method: &str, params: Value| {
        transport::round_trip(
            path,
            &json!({ "id": 1, "method": method, "params": params }).to_string(),
        )
        .map_err(|_| format!("Programa is not running (no {ENDPOINT_KIND} at {path})"))
        .and_then(|line| parse_response(&line))
    };
    let mut lookup = Map::new();
    for key in ["workspace_id", "pane_id"] {
        if let Some(value) = params.get(key) {
            lookup.insert(key.to_owned(), value.clone());
        }
    }
    let direction = params["direction"].as_str().unwrap_or("right");
    let cells = params["cells"].as_i64().unwrap_or(1);
    let result = call("pane.list", Value::Object(lookup)).and_then(|listed| {
        let panes = items(&listed, "panes");
        let pane = match params.get("pane_id").and_then(Value::as_str) {
            Some(id) => panes.iter().find(|pane| pane["id"].as_str() == Some(id)),
            None => panes
                .iter()
                .find(|pane| pane["focused"].as_bool() == Some(true)),
        }
        .ok_or_else(|| "resize-pane: pane not found".to_owned())?;
        let amount = points(pane, direction, cells);
        call(
            "pane.resize",
            json!({
                "workspace_id": listed["workspace_id"],
                "pane_id": pane["id"],
                "direction": direction,
                "amount": amount,
            }),
        )
    });
    match result {
        Ok(result) if json_output => {
            super::emit(&format!("{result}\n"));
            0
        }
        Ok(_) => {
            super::emit("OK\n");
            0
        }
        Err(message) => {
            eprintln!("Error: {message}");
            1
        }
    }
}

/// Cells across (left, right) or down (up, down) in points, at least one.
fn points(pane: &Value, direction: &str, cells: i64) -> i64 {
    let (key, fallback) = if direction == "left" || direction == "right" {
        ("cell_width", 8.0)
    } else {
        ("cell_height", 16.0)
    };
    let cell = pane[key].as_f64().filter(|c| *c > 0.0).unwrap_or(fallback);
    ((cells as f64) * cell).round().max(1.0) as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parse_invocation, Invocation};

    fn call(list: &[&str]) -> Result<(String, Value), String> {
        let args: Vec<String> = list.iter().map(|s| (*s).to_owned()).collect();
        let env = |key: &str| (key == WORKSPACE_ENV).then(|| "ws-env".to_owned());
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
                &["list-panes"][..],
                "pane.list",
                json!({"workspace_id": "ws-env"}),
            ),
            (
                &["list-pane-surfaces", "--pane", "p1"],
                "pane.surfaces",
                json!({"workspace_id": "ws-env", "pane_id": "p1"}),
            ),
            (
                &["focus-pane", "p2"],
                "pane.focus",
                json!({"workspace_id": "ws-env", "pane_id": "p2"}),
            ),
            (
                &["new-pane", "--direction", "UP"],
                "pane.create",
                json!({"workspace_id": "ws-env", "direction": "up"}),
            ),
            (
                &["resize-pane", "-L", "--amount", "5", "--pane", "p1"],
                "pane.resize",
                json!({"workspace_id": "ws-env", "pane_id": "p1", "direction": "left", "cells": 5}),
            ),
            (
                &["swap-pane", "--pane", "a", "--target-pane", "b"],
                "pane.swap",
                json!({"workspace_id": "ws-env", "pane_id": "a", "target_pane_id": "b"}),
            ),
            (
                &["break-pane", "--no-focus"],
                "pane.break",
                json!({"workspace_id": "ws-env", "focus": false}),
            ),
            (
                &["join-pane", "--target-pane", "b", "--surface", "s"],
                "pane.join",
                json!({"workspace_id": "ws-env", "target_pane_id": "b", "surface_id": "s", "focus": true}),
            ),
            (
                &["last-pane"],
                "pane.last",
                json!({"workspace_id": "ws-env"}),
            ),
            (&["next-window"], "workspace.next", json!({})),
            (&["previous-window"], "workspace.previous", json!({})),
            (&["last-window"], "workspace.last", json!({})),
            (
                &["reorder-workspace", "ws-2", "--before", "ws-1"],
                "workspace.reorder",
                json!({"workspace_id": "ws-2", "before_workspace_id": "ws-1"}),
            ),
        ] {
            assert_eq!(call(args).unwrap(), (method.to_owned(), params), "{args:?}");
        }
        for (args, message) in [
            (&["focus-pane"][..], "focus-pane requires --pane <id>"),
            (
                &["focus-pane", "--pane", "a", "b"],
                "focus-pane: provide the pane once",
            ),
            (
                &["new-pane", "--direction", "sideways"],
                "new-pane: invalid direction",
            ),
            (
                &["new-pane", "--type", "browser"],
                "new-pane: --type must be terminal",
            ),
            (
                &["resize-pane", "--amount", "0"],
                "resize-pane: --amount must be greater than 0",
            ),
            (
                &["swap-pane", "--pane", "a"],
                "swap-pane requires --target-pane",
            ),
            (&["join-pane"], "join-pane requires --target-pane"),
            (
                &["reorder-workspace"],
                "reorder-workspace requires --workspace <id>",
            ),
            (
                &["reorder-workspace", "w", "--index", "x"],
                "reorder-workspace: --index must be an integer",
            ),
        ] {
            assert_eq!(call(args).unwrap_err(), message);
        }
    }

    #[test]
    fn output_matches_macos_and_cells_become_points() {
        let panes = json!({"panes": [
            {"id": "p1", "focused": true, "surface_count": 2},
            {"id": "p2", "focused": false, "surface_count": 1},
        ]});
        assert_eq!(
            render(Command::ListPanes, &panes),
            "* p1  [2 surfaces]  [focused]\n  p2  [1 surface]\n"
        );
        assert_eq!(
            render(Command::ListPanes, &json!({"panes": []})),
            "No panes\n"
        );
        assert_eq!(
            render(
                Command::ListPaneSurfaces,
                &json!({"surfaces": [{"id": "s1", "title": "pwsh", "selected": true}, {"id": "s2", "title": "notes.md", "selected": false}]})
            ),
            "* s1  pwsh  [selected]\n  s2  notes.md\n"
        );
        assert_eq!(
            render(
                Command::NewPane,
                &json!({"surface_id": "s", "pane_id": "p", "workspace_id": "w"})
            ),
            "OK s p w\n"
        );
        assert_eq!(
            render(
                Command::ReorderWorkspace,
                &json!({"workspace_id": "w", "window_id": "win", "index": 2})
            ),
            "OK workspace=w window=win index=2\n"
        );
        assert_eq!(render(Command::SwapPane, &json!({})), "OK\n");

        let pane = json!({"cell_width": 8.4, "cell_height": 17.0});
        assert_eq!(points(&pane, "left", 5), 42);
        assert_eq!(points(&pane, "down", 2), 34);
        assert_eq!(points(&json!({}), "right", 1), 8);
    }
}
