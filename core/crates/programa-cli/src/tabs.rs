//! Terminal input and tab commands, as on macOS (CLI/Commands/TerminalIOCommands.swift,
//! PaneCommands.swift and runTabAction in CLI/programa.swift): send-key, clear-history,
//! trigger-flash, refresh-surfaces, surface-health, reorder-surface, tab-action and rename-tab.

use serde_json::{Map, Value};

use super::{
    field, items, no_positionals, non_empty, parse_opts, put, str_or_empty, target, Command, Env,
    UsageError, SURFACE_ENV, WORKSPACE_ENV,
};

pub(crate) fn params(
    command: Command,
    args: &[String],
    env: Env,
) -> Result<Map<String, Value>, UsageError> {
    let name = command.name();
    let mut params = Map::new();
    let workspace = |opts: &super::Opts| target(opts, "--workspace", WORKSPACE_ENV, env);
    let surface = |opts: &super::Opts| target(opts, "--surface", SURFACE_ENV, env);
    match command {
        Command::SendKey => {
            let opts = parse_opts(
                command,
                args,
                &["--workspace", "--surface"],
                &["--force", "--answer-prompt"],
            )?;
            let key = match opts.positionals.as_slice() {
                [key] => key.clone(),
                [] => return Err(UsageError(format!("{name} requires a key"))),
                [_, extra, ..] => {
                    return Err(UsageError(format!("{name}: unexpected argument '{extra}'")))
                }
            };
            put(&mut params, "key", Some(key));
            if opts.has("--force") {
                params.insert("force".into(), Value::Bool(true));
            }
            if opts.has("--answer-prompt") {
                params.insert("answer_prompt".into(), Value::Bool(true));
            }
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", surface(&opts));
        }
        Command::ClearHistory | Command::TriggerFlash => {
            let opts = parse_opts(command, args, &["--workspace", "--surface"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace_id", workspace(&opts));
            put(&mut params, "surface_id", surface(&opts));
        }
        Command::RefreshSurfaces => {
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
        }
        Command::SurfaceHealth => {
            let opts = parse_opts(command, args, &["--workspace"], &[])?;
            no_positionals(command, &opts)?;
            put(&mut params, "workspace_id", workspace(&opts));
        }
        Command::ReorderSurface => {
            let opts = parse_opts(
                command,
                args,
                &[
                    "--surface",
                    "--workspace",
                    "--index",
                    "--before",
                    "--before-surface",
                    "--after",
                    "--after-surface",
                ],
                &[],
            )?;
            let surface_id = match (opts.value("--surface"), opts.positionals.as_slice()) {
                (Some(id), []) => id,
                (None, [id]) => id.clone(),
                (Some(_), [_, ..]) => {
                    return Err(UsageError(format!("{name}: provide the surface once")))
                }
                (None, [_, extra, ..]) => {
                    return Err(UsageError(format!("{name}: unexpected argument '{extra}'")))
                }
                (None, []) => return Err(UsageError(format!("{name} requires --surface <id>"))),
            };
            let before = opts.value("--before").or(opts.value("--before-surface"));
            let after = opts.value("--after").or(opts.value("--after-surface"));
            let index = opts.value("--index");
            if [before.is_some(), after.is_some(), index.is_some()]
                .iter()
                .filter(|set| **set)
                .count()
                != 1
            {
                return Err(UsageError(format!(
                    "{name} requires exactly one of --index, --before, or --after"
                )));
            }
            put(&mut params, "surface_id", Some(surface_id));
            put(&mut params, "before_surface_id", before);
            put(&mut params, "after_surface_id", after);
            if let Some(raw) = index {
                let index = raw.parse::<u64>().map_err(|_| {
                    UsageError(format!("{name}: --index must be a nonnegative integer"))
                })?;
                params.insert("index".into(), Value::from(index));
            }
            put(&mut params, "workspace_id", opts.value("--workspace"));
        }
        Command::TabAction | Command::RenameTab => {
            let mut flags = vec!["--workspace", "--tab", "--surface", "--title"];
            if command == Command::TabAction {
                flags.push("--action");
            }
            let opts = parse_opts(command, args, &flags, &[])?;
            let mut positionals = opts.positionals.clone();
            let action = if command == Command::RenameTab {
                "rename".to_owned()
            } else {
                match opts.value("--action") {
                    Some(action) => action,
                    None if !positionals.is_empty() => positionals.remove(0),
                    None => return Err(UsageError(format!("{name} requires --action <name>"))),
                }
                .to_lowercase()
                .replace('-', "_")
            };
            let title = opts
                .value("--title")
                .or_else(|| non_empty(positionals.join(" ").trim().to_owned()));
            if action == "rename" && title.is_none() {
                return Err(UsageError(if command == Command::RenameTab {
                    format!("{name} requires a title")
                } else {
                    format!("{name} rename requires --title <text> (or a trailing title)")
                }));
            }
            // A named workspace without a tab means its focused tab, not the calling terminal's.
            let explicit_workspace = opts.value("--workspace");
            let tab = opts.value("--tab").or(opts.value("--surface")).or_else(|| {
                explicit_workspace.is_none().then(|| {
                    env("PROGRAMA_TAB_ID")
                        .and_then(non_empty)
                        .or_else(|| env(SURFACE_ENV).and_then(non_empty))
                })?
            });
            put(&mut params, "action", Some(action));
            put(
                &mut params,
                "workspace_id",
                explicit_workspace.or_else(|| env(WORKSPACE_ENV).and_then(non_empty)),
            );
            put(&mut params, "surface_id", tab);
            put(&mut params, "title", title.map(|t| t.trim().to_owned()));
        }
        _ => unreachable!("not a tab command"),
    }
    Ok(params)
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    match command {
        Command::SendKey | Command::TriggerFlash => format!(
            "OK {} {}\n",
            field(result, "surface_id"),
            field(result, "workspace_id")
        ),
        Command::RefreshSurfaces => format!(
            "OK Refreshed {} surfaces\n",
            result["refreshed"].as_u64().unwrap_or(0)
        ),
        Command::SurfaceHealth => {
            let surfaces = items(result, "surfaces");
            if surfaces.is_empty() {
                return "No surfaces\n".to_owned();
            }
            surfaces
                .iter()
                .map(|surface| {
                    let in_window = surface["in_window"]
                        .as_bool()
                        .map_or(String::new(), |shown| format!(" in_window={shown}"));
                    format!(
                        "{}  type={}{in_window}\n",
                        str_or_empty(surface, "id"),
                        str_or_empty(surface, "type")
                    )
                })
                .collect()
        }
        Command::ReorderSurface => format!(
            "OK surface={} pane={} workspace={}\n",
            field(result, "surface_id"),
            field(result, "pane_id"),
            field(result, "workspace_id")
        ),
        Command::TabAction | Command::RenameTab => {
            let mut line = format!(
                "OK action={} tab={} workspace={}",
                field(result, "action"),
                field(result, "tab_id"),
                field(result, "workspace_id")
            );
            if let Some(closed) = result.get("closed") {
                line.push_str(&format!(" closed={closed}"));
            }
            if let Some(created) = result["created_tab_id"].as_str() {
                line.push_str(&format!(" created={created}"));
            }
            line + "\n"
        }
        _ => "OK\n".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::{parse_invocation, Invocation};

    fn call(list: &[&str], vars: &[(&str, &str)]) -> Result<(String, Value), String> {
        let args: Vec<String> = list.iter().map(|s| (*s).to_owned()).collect();
        let env = |key: &str| {
            vars.iter()
                .find(|(name, _)| *name == key)
                .map(|(_, value)| (*value).to_owned())
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
        let env = [(WORKSPACE_ENV, "ws-env"), (SURFACE_ENV, "s-env")];
        for (args, method, params) in [
            (
                &["send-key", "--force", "--", "ctrl+c"][..],
                "surface.send_key",
                json!({"key": "ctrl+c", "force": true, "workspace_id": "ws-env", "surface_id": "s-env"}),
            ),
            (
                &["clear-history", "--surface", "s1"],
                "surface.clear_history",
                json!({"workspace_id": "ws-env", "surface_id": "s1"}),
            ),
            (
                &["trigger-flash"],
                "surface.trigger_flash",
                json!({"workspace_id": "ws-env", "surface_id": "s-env"}),
            ),
            (&["refresh-surfaces"], "surface.refresh", json!({})),
            (
                &["surface-health"],
                "surface.health",
                json!({"workspace_id": "ws-env"}),
            ),
            (
                &["reorder-surface", "s2", "--after", "s1"],
                "surface.reorder",
                json!({"surface_id": "s2", "after_surface_id": "s1"}),
            ),
            (
                &["tab-action", "Close-Others"],
                "tab.action",
                json!({"action": "close_others", "workspace_id": "ws-env", "surface_id": "s-env"}),
            ),
            (
                &["tab-action", "pin", "--workspace", "w2"],
                "tab.action",
                json!({"action": "pin", "workspace_id": "w2"}),
            ),
            (
                &["rename-tab", "--", "agent", "run"],
                "tab.action",
                json!({"action": "rename", "title": "agent run", "workspace_id": "ws-env", "surface_id": "s-env"}),
            ),
        ] {
            assert_eq!(
                call(args, &env).unwrap(),
                (method.to_owned(), params),
                "{args:?}"
            );
        }
        for (args, message) in [
            (&["send-key"][..], "send-key requires a key"),
            (
                &["reorder-surface", "s"],
                "reorder-surface requires exactly one of --index, --before, or --after",
            ),
            (
                &["reorder-surface", "s", "--index", "-1"],
                "reorder-surface: --index must be a nonnegative integer",
            ),
            (
                &["reorder-surface", "--index", "1"],
                "reorder-surface requires --surface <id>",
            ),
            (&["tab-action"], "tab-action requires --action <name>"),
            (
                &["tab-action", "rename"],
                "tab-action rename requires --title <text> (or a trailing title)",
            ),
            (&["rename-tab"], "rename-tab requires a title"),
        ] {
            assert_eq!(call(args, &[]).unwrap_err(), message);
        }
    }

    #[test]
    fn output_matches_macos() {
        assert_eq!(
            render(
                Command::SendKey,
                &json!({"surface_id": "s", "workspace_id": "w"})
            ),
            "OK s w\n"
        );
        assert_eq!(
            render(Command::RefreshSurfaces, &json!({"refreshed": 3})),
            "OK Refreshed 3 surfaces\n"
        );
        assert_eq!(
            render(
                Command::SurfaceHealth,
                &json!({"surfaces": [{"id": "s1", "type": "terminal", "in_window": true}, {"id": "s2", "type": "markdown", "in_window": null}]})
            ),
            "s1  type=terminal in_window=true\ns2  type=markdown\n"
        );
        assert_eq!(
            render(Command::SurfaceHealth, &json!({"surfaces": []})),
            "No surfaces\n"
        );
        assert_eq!(
            render(
                Command::TabAction,
                &json!({"action": "close_others", "tab_id": "t", "workspace_id": "w", "closed": 2})
            ),
            "OK action=close_others tab=t workspace=w closed=2\n"
        );
        assert_eq!(
            render(
                Command::TabAction,
                &json!({"action": "new_terminal_right", "tab_id": "t", "workspace_id": "w", "created_tab_id": "n"})
            ),
            "OK action=new_terminal_right tab=t workspace=w created=n\n"
        );
        assert_eq!(render(Command::ClearHistory, &json!({})), "OK\n");
    }
}
