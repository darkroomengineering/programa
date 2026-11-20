//! `snapshot list` and `snapshot restore [<id>|latest]`, as on macOS (runSnapshotCommand in
//! CLI/programa.swift): the session history the app keeps at each launch.

use serde_json::{Map, Value};

use super::{items, no_positionals, parse_opts, put, str_or_empty, Command, UsageError};

pub(crate) fn params(command: Command, args: &[String]) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    let opts = parse_opts(command, args, &[], &[])?;
    if command == Command::SnapshotList {
        no_positionals(command, &opts)?;
        return Ok(params);
    }
    match opts.positionals.as_slice() {
        [] => {}
        [id] if id.eq_ignore_ascii_case("latest") => {}
        [id] => put(&mut params, "id", Some(id.clone())),
        _ => {
            return Err(UsageError(
                "snapshot restore takes at most one argument: <id>|latest".into(),
            ))
        }
    }
    Ok(params)
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    if command == Command::SnapshotRestore {
        let restored = &result["restored"];
        let count = |key: &str| restored[key].as_u64().unwrap_or(0);
        return format!(
            "OK restored windows={} workspaces={} panels={}\n",
            count("windows"),
            count("workspaces"),
            count("panels")
        );
    }
    let snapshots = items(result, "snapshots");
    if snapshots.is_empty() {
        return "No archived snapshots\n".to_owned();
    }
    snapshots
        .iter()
        .map(|entry| {
            let clean = match entry["clean_shutdown"].as_bool() {
                Some(true) => "clean",
                Some(false) => "unclean",
                None => "unknown",
            };
            let count = |key: &str| entry[key].as_u64().unwrap_or(0);
            format!(
                "{}  {}  {clean}  windows={} workspaces={} panels={}\n",
                str_or_empty(entry, "id"),
                str_or_empty(entry, "saved_at"),
                count("window_count"),
                count("workspace_count"),
                count("panel_count")
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::{parse_invocation, Invocation};

    fn call(list: &[&str]) -> Result<(String, Value), String> {
        let args: Vec<String> = list.iter().map(|s| (*s).to_owned()).collect();
        match parse_invocation(&args, &|_| None) {
            Ok(Invocation::Call { request, .. }) => Ok((
                request.command.method().to_owned(),
                Value::Object(request.params),
            )),
            Ok(other) => Err(format!("{other:?}")),
            Err(UsageError(message)) => Err(message),
        }
    }

    #[test]
    fn subcommands_and_output_match_macos() {
        assert_eq!(
            call(&["snapshot", "list"]).unwrap(),
            ("snapshot.list".into(), json!({}))
        );
        assert_eq!(
            call(&["snapshot", "restore"]).unwrap(),
            ("snapshot.restore".into(), json!({}))
        );
        assert_eq!(
            call(&["snapshot", "restore", "LATEST"]).unwrap(),
            ("snapshot.restore".into(), json!({}))
        );
        assert_eq!(
            call(&["snapshot", "restore", "20261119-093000-session"]).unwrap(),
            (
                "snapshot.restore".into(),
                json!({"id": "20261119-093000-session"})
            )
        );
        assert_eq!(
            call(&["snapshot"]).unwrap_err(),
            "snapshot requires a subcommand: list, restore"
        );
        assert_eq!(
            call(&["snapshot", "restore", "a", "b"]).unwrap_err(),
            "snapshot restore takes at most one argument: <id>|latest"
        );
        assert_eq!(
            call(&["snapshot", "list", "x"]).unwrap_err(),
            "snapshot list: unexpected argument 'x'"
        );

        assert_eq!(
            render(Command::SnapshotList, &json!({"snapshots": []})),
            "No archived snapshots\n"
        );
        assert_eq!(
            render(Command::SnapshotList, &json!({"snapshots": [
                {"id": "20261119-093000-session", "saved_at": "2026-11-19T09:30:00Z", "clean_shutdown": true, "window_count": 1, "workspace_count": 3, "panel_count": 5},
                {"id": "20261118-080000-session", "saved_at": "2026-11-18T08:00:00Z", "clean_shutdown": null, "window_count": 2, "workspace_count": 4, "panel_count": 6},
            ]})),
            "20261119-093000-session  2026-11-19T09:30:00Z  clean  windows=1 workspaces=3 panels=5\n20261118-080000-session  2026-11-18T08:00:00Z  unknown  windows=2 workspaces=4 panels=6\n"
        );
        assert_eq!(
            render(
                Command::SnapshotRestore,
                &json!({"restored": {"windows": 2, "workspaces": 4, "panels": 6}})
            ),
            "OK restored windows=2 workspaces=4 panels=6\n"
        );
    }
}
