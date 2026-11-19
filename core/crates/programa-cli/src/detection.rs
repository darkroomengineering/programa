//! `agent-detection list|test|scaffold`, as on macOS (CLI/CLI+AgentDetection.swift): the screen
//! manifests the app has loaded, a classification of a surface's screen, and a starter manifest
//! written to `%USERPROFILE%\.config\programa\agent-detection\<agent-id>.json`.

use std::path::PathBuf;

use serde_json::{json, Map, Value};

use super::{
    items, no_positionals, parse_opts, parse_response, put, str_or_empty, target, transport,
    Command, Env, UsageError, ENDPOINT_KIND, SURFACE_ENV, WORKSPACE_ENV,
};

/// The bundled agent ids a scaffold refuses to shadow without `--force` (AgentManifestLoader).
const BUNDLED: [&str; 7] = [
    "claude-code",
    "codex",
    "gemini-cli",
    "opencode",
    "copilot-cli",
    "cursor-agent",
    "aider",
];

pub(crate) fn params(
    command: Command,
    args: &[String],
    env: Env,
) -> Result<Map<String, Value>, UsageError> {
    let name = command.name();
    let mut params = Map::new();
    match command {
        Command::AgentDetectionList => {
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
        }
        _ => {
            let switches: &[&'static str] = if command == Command::AgentDetectionScaffold {
                &["--force"]
            } else {
                &[]
            };
            let opts = parse_opts(command, args, &["--surface", "--workspace"], switches)?;
            let agent = match opts.positionals.as_slice() {
                [] if command == Command::AgentDetectionScaffold => {
                    return Err(UsageError(format!("{name} requires <agent-id>")))
                }
                [] => None,
                [agent] => Some(agent.clone()),
                [_, extra, ..] => {
                    return Err(UsageError(format!("{name}: unexpected arguments: {extra}")))
                }
            };
            if command == Command::AgentDetectionScaffold {
                let id = agent.as_deref().unwrap_or_default();
                if !id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
                {
                    return Err(UsageError(format!(
                        "{name}: <agent-id> must be lowercase letters, digits, and hyphens only"
                    )));
                }
                if opts.has("--force") {
                    params.insert("force".into(), Value::Bool(true));
                }
            }
            put(&mut params, "agent", agent);
            put(
                &mut params,
                "workspace_id",
                target(&opts, "--workspace", WORKSPACE_ENV, env),
            );
            put(
                &mut params,
                "surface_id",
                target(&opts, "--surface", SURFACE_ENV, env),
            );
        }
    }
    Ok(params)
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    if command == Command::AgentDetectionTest {
        let Some(agent) = result["agent"].as_str() else {
            return match result["requested_agent"].as_str() {
                Some(requested) => format!("No manifest loaded for '{requested}'\n"),
                None => "No loaded manifest recognized this screen\n".to_owned(),
            };
        };
        let display = result["display_name"].as_str().unwrap_or(agent);
        let Some(bucket) = result["bucket"].as_str() else {
            return format!(
                "{agent} ({display}) recognized, but no state pattern matched the current screen\n"
            );
        };
        return format!(
            "{agent} ({display}): {bucket}  [confidence={}, pattern={}]\n",
            result["confidence"].as_str().unwrap_or("?"),
            result["matched_pattern"].as_str().unwrap_or("?")
        );
    }
    let manifests = items(result, "manifests");
    if manifests.is_empty() {
        return "No agent-detection manifests loaded\n".to_owned();
    }
    manifests
        .iter()
        .map(|entry| {
            let agent = str_or_empty(entry, "agent");
            let processes: Vec<&str> = items(entry, "process_names")
                .iter()
                .filter_map(Value::as_str)
                .collect();
            let mut line = format!(
                "{agent}  ({}, source={}, process_names=[{}])",
                entry["display_name"].as_str().unwrap_or(agent),
                str_or_empty(entry, "source"),
                processes.join(", ")
            );
            if entry["shadows_bundled"].as_bool() == Some(true) {
                line.push_str("  [shadows bundled manifest]");
            }
            line + "\n"
        })
        .collect()
}

/// `agent-detection scaffold`: reads the surface's screen (and, forced over a bundled agent, its
/// manifest's states) from the app, then writes the starter manifest here.
pub(crate) fn run_scaffold(
    path: &str,
    params: &Map<String, Value>,
    json_output: bool,
    env: Env,
) -> i32 {
    let call = |method: &str, params: Value| {
        transport::round_trip(
            path,
            &json!({ "id": 1, "method": method, "params": params }).to_string(),
        )
        .map_err(|_| format!("Programa is not running (no {ENDPOINT_KIND} at {path})"))
        .and_then(|line| parse_response(&line))
    };
    let agent = params["agent"].as_str().unwrap_or_default().to_owned();
    let force = params.contains_key("force");
    let folder = PathBuf::from(env("USERPROFILE").unwrap_or_default())
        .join(".config")
        .join("programa")
        .join("agent-detection");
    let file = folder.join(format!("{agent}.json"));
    let result = (|| -> Result<bool, String> {
        let mut seed = None;
        if BUNDLED.contains(&agent.as_str()) {
            if !force {
                return Err(format!("agent-detection scaffold: '{agent}' is one of programa's bundled agents. A user override at {} fully replaces its bundled manifest (no merge) -- and a freshly scaffolded manifest starts with empty patterns, so screen-based detection for '{agent}' would silently stop working until you fill them back in. Pass --force to proceed anyway; the bundled manifest's existing patterns will be seeded into the new file so you start from a working copy, not a blank one.", file.display()));
            }
            let listed = call("agent.detection.list", json!({}))?;
            seed = items(&listed, "manifests")
                .iter()
                .find(|entry| entry["agent"].as_str() == Some(agent.as_str()))
                .map(|entry| items(entry, "states").to_vec());
        }
        let mut read = Map::new();
        for key in ["workspace_id", "surface_id"] {
            if let Some(value) = params.get(key) {
                read.insert(key.to_owned(), value.clone());
            }
        }
        let screen = call("surface.read_text", Value::Object(read))?;
        if !force && file.exists() {
            return Err(format!(
                "agent-detection scaffold: {} already exists (use --force to overwrite)",
                file.display()
            ));
        }
        std::fs::create_dir_all(&folder).map_err(|error| {
            format!(
                "agent-detection scaffold: failed to create {}: {error}",
                folder.display()
            )
        })?;
        let text = scaffold_json(&agent, str_or_empty(&screen, "text"), seed.as_deref());
        std::fs::write(&file, text).map_err(|error| {
            format!(
                "agent-detection scaffold: failed to write {}: {error}",
                file.display()
            )
        })?;
        Ok(seed.is_some())
    })();
    match result {
        Ok(seeded) if json_output => {
            super::emit(&format!(
                "{}\n",
                json!({"path": file.display().to_string(), "agent": agent, "seeded_from_bundled": seeded})
            ));
            0
        }
        Ok(seeded) => {
            let mut out = format!("Wrote starter manifest: {}\n", file.display());
            if seeded {
                out.push_str(&format!("Seeded from the bundled '{agent}' manifest's existing patterns -- review them, they were verified against the bundled agent's UI, not necessarily yours.\n"));
            }
            out.push_str(&format!("Next: review/fill in its \"patterns\" arrays, then run 'programa agent-detection test {agent}' to check them against the live screen.\n"));
            super::emit(&out);
            0
        }
        Err(message) => {
            eprintln!("Error: {message}");
            1
        }
    }
}

/// The starter manifest, laid out as the macOS scaffold writes it: empty patterns with a TODO in
/// each state's notes (an empty list matches nothing), or the bundled states when seeded.
pub(crate) fn scaffold_json(agent: &str, screen: &str, seed: Option<&[Value]>) -> String {
    let quote = |text: &str| Value::String(text.to_owned()).to_string();
    let display: String = agent
        .split('-')
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map_or(String::new(), |first| {
                first.to_uppercase().chain(chars).collect()
            })
        })
        .collect::<Vec<_>>()
        .join(" ");
    let lines: Vec<&str> = screen.split('\n').collect();
    let kept = lines[lines.len().saturating_sub(30)..].join("\n");
    let reference = if kept.is_empty() {
        "No screen text was captured (surface appeared empty at scaffold time).".to_owned()
    } else {
        format!(
            "Captured screen (last {} lines) for reference, delete once patterns are reviewed:\n{kept}",
            kept.split('\n').count()
        )
    };
    let block = |bucket: &str,
                 priority: i64,
                 anchor: i64,
                 patterns: &str,
                 confidence: &str,
                 notes: &str| {
        format!(
            "    {{\n      \"bucket\": {},\n      \"priority\": {priority},\n      \"anchor_last_n_lines\": {anchor},\n      \"patterns\": {patterns},\n      \"confidence\": {},\n      \"source_notes\": {}\n    }}",
            quote(bucket),
            quote(confidence),
            quote(notes)
        )
    };
    let states: Vec<String> = match seed.filter(|states| !states.is_empty()) {
        Some(states) => states
            .iter()
            .map(|state| {
                let patterns = Value::Array(items(state, "patterns").to_vec()).to_string();
                block(
                    state["bucket"].as_str().unwrap_or("idle"),
                    state["priority"].as_i64().unwrap_or(0),
                    state["anchor_last_n_lines"].as_i64().unwrap_or(6),
                    &patterns,
                    state["confidence"].as_str().unwrap_or("low"),
                    &format!("SEEDED from the bundled '{agent}' manifest (forced override) -- review these, they were verified against the bundled agent's UI, not necessarily yours. {reference}"),
                )
            })
            .collect(),
        None => [
            ("blocked", 100, 12, format!("Add regex patterns that appear when {display} is waiting on you -- a y/n confirmation, a permission prompt, etc.")),
            ("working", 50, 6, format!("Add regex patterns that appear while {display} is actively working -- a spinner, \"Thinking\", token counters, etc.")),
            ("idle", 0, 4, format!("Add regex patterns that match {display}'s prompt when it's idle and ready for the next instruction.")),
        ]
        .iter()
        .map(|(bucket, priority, anchor, hint)| {
            block(bucket, *priority, *anchor, "[]", "low", &format!("TODO: {hint} Patterns are intentionally empty -- an empty list matches nothing (never everything; see AgentManifest.classify). {reference}"))
        })
        .collect(),
    };
    format!(
        "{{\n  \"version\": 1,\n  \"agent\": {},\n  \"display_name\": {},\n  \"recognize\": {{\n    \"process_names\": [{}],\n    \"screen_patterns\": []\n  }},\n  \"states\": [\n{}\n  ]\n}}",
        quote(agent),
        quote(&display),
        quote(agent),
        states.join(",\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parse_invocation, Invocation};

    fn call(list: &[&str]) -> Result<(String, Value), String> {
        let args: Vec<String> = list.iter().map(|s| (*s).to_owned()).collect();
        match parse_invocation(&args, &|key| {
            (key == SURFACE_ENV).then(|| "s-env".to_owned())
        }) {
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
            call(&["agent-detection", "list"]).unwrap(),
            ("agent.detection.list".into(), json!({}))
        );
        assert_eq!(
            call(&["agent-detection", "test", "aider"]).unwrap(),
            (
                "agent.detection.classify".into(),
                json!({"agent": "aider", "surface_id": "s-env"})
            )
        );
        assert_eq!(
            call(&["agent-detection"]).unwrap_err(),
            "agent-detection requires a subcommand: list, scaffold, test"
        );
        assert_eq!(
            call(&["agent-detection", "scaffold"]).unwrap_err(),
            "agent-detection scaffold requires <agent-id>"
        );
        assert_eq!(call(&["agent-detection", "scaffold", "My_Agent"]).unwrap_err(), "agent-detection scaffold: <agent-id> must be lowercase letters, digits, and hyphens only");

        assert_eq!(
            render(Command::AgentDetectionList, &json!({"manifests": []})),
            "No agent-detection manifests loaded\n"
        );
        assert_eq!(
            render(
                Command::AgentDetectionList,
                &json!({"manifests": [{"agent": "aider", "display_name": "Aider", "source": "override", "process_names": ["aider"], "shadows_bundled": true}]})
            ),
            "aider  (Aider, source=override, process_names=[aider])  [shadows bundled manifest]\n"
        );
        assert_eq!(
            render(
                Command::AgentDetectionTest,
                &json!({"agent": "aider", "display_name": "Aider", "bucket": "blocked", "confidence": "low", "matched_pattern": "\\(y/n\\)"})
            ),
            "aider (Aider): blocked  [confidence=low, pattern=\\(y/n\\)]\n"
        );
        assert_eq!(
            render(
                Command::AgentDetectionTest,
                &json!({"agent": null, "requested_agent": null})
            ),
            "No loaded manifest recognized this screen\n"
        );
        assert_eq!(
            render(
                Command::AgentDetectionTest,
                &json!({"agent": "aider", "display_name": "Aider", "bucket": null})
            ),
            "aider (Aider) recognized, but no state pattern matched the current screen\n"
        );
    }

    #[test]
    fn a_scaffold_is_a_manifest_the_app_reads() {
        let blank: Value =
            serde_json::from_str(&scaffold_json("my-agent", "line one\n$ ", None)).unwrap();
        assert_eq!(blank["display_name"], "My Agent");
        assert_eq!(blank["recognize"]["process_names"], json!(["my-agent"]));
        assert_eq!(blank["states"].as_array().unwrap().len(), 3);
        assert_eq!(blank["states"][0]["patterns"], json!([]));
        assert!(blank["states"][2]["source_notes"]
            .as_str()
            .unwrap()
            .ends_with(
                "(last 2 lines) for reference, delete once patterns are reviewed:\nline one\n$ "
            ));
        let seeded: Value = serde_json::from_str(&scaffold_json("aider", "", Some(&[json!({"bucket": "blocked", "priority": 100, "anchor_last_n_lines": 12, "patterns": ["\\(y/n\\)"], "confidence": "low"})]))).unwrap();
        assert_eq!(seeded["states"][0]["patterns"], json!(["\\(y/n\\)"]));
        assert!(seeded["states"][0]["source_notes"]
            .as_str()
            .unwrap()
            .starts_with("SEEDED from the bundled 'aider' manifest"));
    }
}
