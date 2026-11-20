//! `programa-mcp`: an MCP (Model Context Protocol) server over stdio that lets a coding agent drive
//! the running Programa through its control pipe, as the macOS server does (docs/mcp-server.md).
//! Each tool is a control method with `.` replaced by `_`; the methods that can move the user's
//! focus are named `focus_…` instead. Input schemas come from the v2 contract
//! (contracts/v2/methods.json), and the tool list from the running app's `system.capabilities`.

#[path = "transport.rs"]
mod transport;

use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

const CONTRACT: &str = include_str!("../../../../contracts/v2/methods.json");

/// App chrome the macOS server leaves out too.
// subscribe/unsubscribe stream frames on their connection, which a request/response tool cannot carry.
const EXCLUDED: &[&str] = &["markdown.open", "subscribe", "unsubscribe"];

/// Methods that can bring Programa forward or move focus, and their tool names.
const FOCUS_TOOLS: &[(&str, &str)] = &[
    ("window.focus", "focus_window"),
    ("workspace.select", "focus_workspace_select"),
    ("surface.focus", "focus_surface"),
    ("review.open", "focus_review_open"),
    ("worktree.open", "focus_worktree_open"),
];

/// Reads are capped like on macOS, so one call cannot pull an unbounded buffer into a context.
const MAX_LINES: u64 = 10_000;

fn main() {
    let path = socket_path(&|key| std::env::var(key).ok());
    eprintln!("programa-mcp: control pipe {path}");
    let contract: Value = serde_json::from_str(CONTRACT).unwrap_or_default();
    let mut out = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Value>(&line) {
            Ok(message) => handle(&message, &contract, &|method, params| {
                request(&path, method, params)
            }),
            Err(_) => Some(
                json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "parse error"}}),
            ),
        };
        if let Some(response) = response {
            let _ = writeln!(out, "{response}");
            let _ = out.flush();
        }
    }
}

/// A control request; the error is "code: message".
type Caller<'a> = &'a dyn Fn(&str, Value) -> Result<Value, String>;

/// One JSON-RPC message in, its response out (none for a notification).
fn handle(message: &Value, contract: &Value, call: Caller) -> Option<Value> {
    let id = message.get("id").cloned();
    let method = message
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let params = message.get("params").cloned().unwrap_or_else(|| json!({}));
    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or("2025-06-18"),
            "capabilities": {"tools": {}, "resources": {}},
            "serverInfo": {"name": "programa", "version": env!("CARGO_PKG_VERSION")},
            "instructions": "Drives the Programa terminal this agent runs in: workspaces, splits, terminals (send and read text), notifications, worktrees, reviews and layouts. Tools named focus_ move the user's focus; use them only when asked. Read programa://tree first to find ids.",
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools(&methods(contract, call), contract)})),
        "tools/call" => Ok(call_tool(&params, contract, call)),
        "resources/list" => Ok(json!({"resources": [{
            "uri": "programa://tree", "name": "tree", "mimeType": "application/json",
            "description": "Every window with its workspaces and surfaces. Start here to find ids.",
        }]})),
        "resources/templates/list" => Ok(json!({"resourceTemplates": [{
            "uriTemplate": "programa://surface/{surface_id}/text", "name": "surface text", "mimeType": "text/plain",
            "description": "Visible text and scrollback of one terminal; add ?lines=n to bound it (at most 10000).",
        }]})),
        "resources/read" => read_resource(
            params
                .get("uri")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            call,
        ),
        _ if id.is_none() => return None,
        _ => Err((-32601, format!("method not found: {method}"))),
    };
    let id = id?;
    Some(match result {
        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
        Err((code, message)) => {
            json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
        }
    })
}

/// The running app's methods, else the contract's when it cannot be asked.
fn methods(contract: &Value, call: Caller) -> Vec<String> {
    let listed = call("system.capabilities", json!({}))
        .ok()
        .and_then(|result| {
            result
                .get("methods")
                .and_then(Value::as_array)
                .map(|methods| {
                    methods
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                })
        });
    listed.unwrap_or_else(|| {
        contract
            .get("methods")
            .and_then(Value::as_object)
            .map(|methods| methods.keys().cloned().collect())
            .unwrap_or_default()
    })
}

fn tool_name(method: &str) -> String {
    FOCUS_TOOLS
        .iter()
        .find(|(focus, _)| *focus == method)
        .map(|(_, name)| (*name).to_owned())
        .unwrap_or_else(|| method.replace('.', "_"))
}

fn tools(methods: &[String], contract: &Value) -> Vec<Value> {
    methods
        .iter()
        .filter(|method| !EXCLUDED.contains(&method.as_str()) && !method.starts_with("debug."))
        .map(|method| {
            let spec = contract
                .get("methods")
                .and_then(|methods| methods.get(method));
            let mut schema = spec
                .and_then(|spec| spec.get("params"))
                .cloned()
                .unwrap_or_else(|| json!({"type": "object"}));
            // Creating a worktree never moves focus; focus_worktree_open is the way to jump to it.
            if method == "worktree.create" {
                if let Some(properties) =
                    schema.get_mut("properties").and_then(Value::as_object_mut)
                {
                    properties.remove("focus");
                }
            }
            let mut description = spec
                .and_then(|spec| spec.get("description"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| format!("Programa control method {method}."));
            if tool_name(method).starts_with("focus_") {
                description.push_str(" Moves the user's focus; call it only when the user asks.");
            }
            json!({"name": tool_name(method), "description": description, "inputSchema": schema})
        })
        .collect()
}

fn call_tool(params: &Value, contract: &Value, call: Caller) -> Value {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mut arguments = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let Some(method) = methods(contract, call)
        .into_iter()
        .find(|method| tool_name(method) == name && !EXCLUDED.contains(&method.as_str()))
    else {
        return json!({"content": [{"type": "text", "text": format!("unknown tool: {name}")}], "isError": true});
    };
    if method == "worktree.create" {
        if let Some(arguments) = arguments.as_object_mut() {
            arguments.remove("focus");
        }
    }
    match call(&method, arguments) {
        Ok(result) => {
            json!({"content": [{"type": "text", "text": serde_json::to_string_pretty(&result).unwrap_or_default()}]})
        }
        Err(message) => {
            json!({"content": [{"type": "text", "text": format!("error: {message}")}], "isError": true})
        }
    }
}

fn read_resource(uri: &str, call: Caller) -> Result<Value, (i64, String)> {
    let failed = |message: String| (-32603, message);
    if uri == "programa://tree" {
        let windows = call("window.list", json!({})).map_err(failed)?;
        let mut tree = Vec::new();
        for window in windows
            .get("windows")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
        {
            let id = window.get("id").cloned().unwrap_or(Value::Null);
            let workspaces = call("workspace.list", json!({"window_id": id})).map_err(failed)?;
            tree.push(json!({"id": id, "selected": window.get("selected"), "workspaces": workspaces.get("workspaces")}));
        }
        let text = serde_json::to_string_pretty(&json!({"windows": tree})).unwrap_or_default();
        return Ok(
            json!({"contents": [{"uri": uri, "mimeType": "application/json", "text": text}]}),
        );
    }
    let (surface, lines) =
        surface_text_uri(uri).ok_or((-32602, format!("unknown resource: {uri}")))?;
    let read = call(
        "surface.read_text",
        json!({"surface_id": surface, "lines": lines, "scrollback": true}),
    )
    .map_err(failed)?;
    let text = read.get("text").and_then(Value::as_str).unwrap_or_default();
    Ok(json!({"contents": [{"uri": uri, "mimeType": "text/plain", "text": text}]}))
}

/// `programa://surface/<id>/text[?lines=n]` as the surface id and a line count of at most 10000.
fn surface_text_uri(uri: &str) -> Option<(String, u64)> {
    let rest = uri.strip_prefix("programa://surface/")?;
    let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
    let surface = path.strip_suffix("/text")?;
    if surface.is_empty() || surface.contains('/') {
        return None;
    }
    let lines = query
        .split('&')
        .find_map(|pair| pair.strip_prefix("lines="))
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(MAX_LINES)
        .min(MAX_LINES);
    Some((surface.to_owned(), lines))
}

fn request(path: &str, method: &str, params: Value) -> Result<Value, String> {
    let line = json!({"id": 1, "method": method, "params": params}).to_string();
    let reply = transport::round_trip(path, &line).map_err(|error| match error {
        transport::TransportError::NotRunning => format!(
            "transport_error: Programa is not running (no {} at {path})",
            transport::ENDPOINT_KIND
        ),
        transport::TransportError::Io(error) => format!("transport_error: {error}"),
    })?;
    let response: Value =
        serde_json::from_str(&reply).map_err(|error| format!("invalid response: {error}"))?;
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(response.get("result").cloned().unwrap_or_else(|| json!({})));
    }
    let error = response.get("error").cloned().unwrap_or_default();
    Err(format!(
        "{}: {}",
        error.get("code").and_then(Value::as_str).unwrap_or("error"),
        error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
    ))
}

/// `PROGRAMA_SOCKET_PATH`, then `PROGRAMA_SOCKET`, then the user's default pipe, like the CLI.
fn socket_path(env: &dyn Fn(&str) -> Option<String>) -> String {
    let set = |key: &str| env(key).filter(|value| !value.is_empty());
    set("PROGRAMA_SOCKET_PATH")
        .or_else(|| set("PROGRAMA_SOCKET"))
        .unwrap_or_else(|| {
            if cfg!(windows) {
                format!(r"\\.\pipe\programa-{}", set("USERNAME").unwrap_or_default())
            } else {
                format!(
                    "{}/Library/Application Support/programa/programa.sock",
                    set("HOME").unwrap_or_default()
                )
            }
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn contract() -> Value {
        serde_json::from_str(CONTRACT).unwrap()
    }

    #[test]
    fn tools_are_named_after_methods_with_focus_ones_marked() {
        let methods = [
            "surface.send_text",
            "window.focus",
            "markdown.open",
            "worktree.create",
            "surface.resume_agent",
        ]
        .map(str::to_owned);
        let tools = tools(&methods, &contract());
        let names: Vec<&str> = tools
            .iter()
            .map(|tool| tool["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            [
                "surface_send_text",
                "focus_window",
                "worktree_create",
                "surface_resume_agent"
            ]
        );
        assert!(tools[0]["inputSchema"]["properties"].get("text").is_some());
        assert!(tools[1]["description"]
            .as_str()
            .unwrap()
            .contains("Moves the user's focus"));
        assert!(tools[2]["inputSchema"]["properties"].get("focus").is_none());
        assert_eq!(tools[3]["inputSchema"], json!({"type": "object"}));
    }

    #[test]
    fn calls_go_to_the_method_and_errors_come_back_as_tool_errors() {
        let call = |method: &str, params: Value| -> Result<Value, String> {
            match method {
                "system.capabilities" => {
                    Ok(json!({"methods": ["surface.read_text", "window.focus"]}))
                }
                "surface.read_text" => {
                    Ok(json!({"text": format!("read {}", params["surface_id"])}))
                }
                _ => Err("not_found: window 'w' was not found.".into()),
            }
        };
        let message = |name: &str| json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": name, "arguments": {"surface_id": "s"}}});
        let read = handle(&message("surface_read_text"), &contract(), &call).unwrap();
        assert!(read["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("read \\\"s\\\""));
        let failed = handle(&message("focus_window"), &contract(), &call).unwrap();
        assert_eq!(failed["result"]["isError"], json!(true));
        let unknown = handle(&message("markdown_open"), &contract(), &call).unwrap();
        assert_eq!(unknown["result"]["isError"], json!(true));
        // A notification gets no answer; an unknown request gets a JSON-RPC error.
        assert!(handle(
            &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            &contract(),
            &call
        )
        .is_none());
        let missing = handle(
            &json!({"jsonrpc": "2.0", "id": 1, "method": "nope"}),
            &contract(),
            &call,
        )
        .unwrap();
        assert_eq!(missing["error"]["code"], json!(-32601));
    }

    #[test]
    fn surface_text_uris_carry_a_bounded_line_count() {
        assert_eq!(
            surface_text_uri("programa://surface/s-1/text"),
            Some(("s-1".into(), 10_000))
        );
        assert_eq!(
            surface_text_uri("programa://surface/s-1/text?lines=200"),
            Some(("s-1".into(), 200))
        );
        assert_eq!(
            surface_text_uri("programa://surface/s-1/text?lines=99999"),
            Some(("s-1".into(), 10_000))
        );
        assert_eq!(surface_text_uri("programa://surface//text"), None);
        assert_eq!(surface_text_uri("programa://tree"), None);
    }
}
