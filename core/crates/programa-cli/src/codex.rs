//! `programa codex install-integration | uninstall-integration [--yes]`, as on macOS
//! (CLI/CLI+CodexConfig.swift): Programa's hooks in `%CODEX_HOME%\hooks.json` (default
//! `%USERPROFILE%\.codex`), trusted in `config.toml` between `# BEGIN programa` and `# END programa`,
//! since Codex skips a hook nobody trusted. Other hooks keep their positions, which Codex's trust
//! keys (`<hooks.json>:<event>:<group>:<handler>`) depend on.
//!
//! Codex runs a hook on Windows as `cmd.exe /C "<command>"`, so the command is cmd's
//! `if exist "<programa.exe>" "<programa.exe>" codex-hook <event>`: nothing happens once Programa is
//! gone, and `codex-hook` itself does nothing outside a Programa terminal.

use std::fs::{self, OpenOptions};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

use crate::Env;

const BLOCK_BEGIN: &str = "# BEGIN programa (managed by Programa, do not edit)";
const BLOCK_END: &str = "# END programa";
const MAXIMUM_BYTES: u64 = 16 * 1024 * 1024;

/// (Codex event, trust label, `codex-hook` event, timeout in seconds), as on macOS.
const SPECS: [(&str, &str, &str, i64); 5] = [
    ("SessionStart", "session_start", "session-start", 10),
    (
        "UserPromptSubmit",
        "user_prompt_submit",
        "prompt-submit",
        10,
    ),
    ("Stop", "stop", "stop", 10),
    (
        "PermissionRequest",
        "permission_request",
        "notification",
        10,
    ),
    ("SessionEnd", "session_end", "session-end", 1),
];

pub fn hook_command(exe: &str, event: &str) -> String {
    format!(r#"if exist "{exe}" "{exe}" codex-hook {event}"#)
}

/// A Programa handler: this one or the macOS one, for the event (Notification from older installs).
fn owned(handler: &Value, event: &str) -> bool {
    let command_event = match event {
        "Notification" => "notification",
        _ => match SPECS.iter().find(|spec| spec.0 == event) {
            Some(spec) => spec.2,
            None => return false,
        },
    };
    handler["command"].as_str().is_some_and(|command| {
        command.to_lowercase().contains("programa")
            && command
                .trim_end()
                .ends_with(&format!("codex-hook {command_event}"))
    })
}

fn handler(exe: &str, spec: &(&str, &str, &str, i64)) -> Value {
    json!({ "type": "command", "command": hook_command(exe, spec.2), "timeout": spec.3 })
}

/// hooks.json with Programa's handler for each event (install) or none (uninstall). The first
/// Programa handler of an event is rewritten where it stands, so the other hooks keep their positions.
pub fn rewrite_hooks(source: &Value, install: bool, exe: &str) -> Result<Value, String> {
    let mut root = source
        .as_object()
        .cloned()
        .ok_or("hooks.json must be a JSON object")?;
    let mut hooks = match root.get("hooks") {
        None if !install => return Ok(source.clone()),
        None => Map::new(),
        Some(Value::Object(hooks)) => hooks.clone(),
        Some(_) => return Err("hooks.json hooks must be an object".into()),
    };
    for (event, groups) in hooks.iter_mut() {
        let list = groups
            .as_array()
            .ok_or(format!("hooks.json event {event} must be an array"))?;
        let spec = SPECS
            .iter()
            .find(|spec| spec.0 == event)
            .filter(|_| install);
        let mut placed = false;
        let mut rewritten = Vec::new();
        for (index, group) in list.iter().enumerate() {
            let mut group = group.as_object().cloned().ok_or(format!(
                "hooks.json {event} group {index} must be an object"
            ))?;
            let handlers = group
                .get("hooks")
                .and_then(Value::as_array)
                .ok_or(format!(
                    "hooks.json {event} group {index}.hooks must be an array"
                ))?
                .clone();
            let mut kept = Vec::new();
            for item in &handlers {
                if !owned(item, event) {
                    kept.push(item.clone());
                } else if let (Some(spec), false) = (spec, placed) {
                    placed = true;
                    kept.push(handler(exe, spec));
                }
            }
            // A group holding only Programa's handler is replaced whole, so no stale matcher narrows it.
            if handlers.len() == 1 && kept.len() == 1 && owned(&kept[0], event) {
                rewritten.push(json!({ "hooks": kept }));
            } else if !kept.is_empty() {
                group.insert("hooks".into(), Value::Array(kept));
                rewritten.push(Value::Object(group));
            }
        }
        *groups = Value::Array(rewritten);
    }
    hooks.retain(|_, groups| groups.as_array().is_some_and(|groups| !groups.is_empty()));
    if install {
        for spec in &SPECS {
            let groups = hooks.entry(spec.0).or_insert_with(|| json!([]));
            let has = groups.as_array().into_iter().flatten().any(|group| {
                group["hooks"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|item| owned(item, spec.0))
            });
            if !has {
                groups
                    .as_array_mut()
                    .unwrap()
                    .push(json!({ "hooks": [handler(exe, spec)] }));
            }
        }
    }
    root.insert("hooks".into(), Value::Object(hooks));
    let rewritten = Value::Object(root);
    for spec in &SPECS {
        if foreign_positions(source, spec.0) != foreign_positions(&rewritten, spec.0) {
            return Err(format!(
                "rewriting {} would move another hook; refusing to reuse Codex trust positions",
                spec.0
            ));
        }
    }
    Ok(rewritten)
}

fn foreign_positions(root: &Value, event: &str) -> Vec<(usize, usize)> {
    let mut positions = Vec::new();
    for (group_index, group) in root["hooks"][event]
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
    {
        for (handler_index, item) in group["hooks"].as_array().into_iter().flatten().enumerate() {
            if !owned(item, event) {
                positions.push((group_index, handler_index));
            }
        }
    }
    positions
}

/// Codex's trust hash of one handler: SHA-256 of the event label and the normalized handler, as
/// JSON with sorted keys (macOS `codexTrustHash`; Codex `hook_hash`).
pub fn trust_hash(label: &str, group: &Value, item: &Value) -> Result<String, String> {
    let command = item["command"]
        .as_str()
        .filter(|_| item["type"] == "command")
        .ok_or(format!("Codex hook {label} must be a command handler"))?;
    let raw_timeout = item["timeout"]
        .as_i64()
        .unwrap_or(if label == "session_end" { 1 } else { 600 });
    let timeout = if label == "session_end" {
        raw_timeout.clamp(1, 3)
    } else {
        raw_timeout.max(1)
    };
    let asynchronous = item["async"].as_bool().unwrap_or(false);
    let mut text = format!(
        r#"{{"event_name":{},"hooks":[{{"async":{asynchronous},"command":{},"#,
        json!(label),
        json!(command)
    );
    if let Some(status) = item["statusMessage"].as_str() {
        text.push_str(&format!(r#""statusMessage":{},"#, json!(status)));
    }
    text.push_str(&format!(r#""timeout":{timeout},"type":"command"}}]"#));
    if !["user_prompt_submit", "stop"].contains(&label) {
        if let Some(matcher) = group["matcher"].as_str() {
            text.push_str(&format!(r#","matcher":{}"#, json!(matcher)));
        }
    }
    text.push('}');
    Ok(format!("sha256:{}", sha256_hex(text.as_bytes())))
}

/// `<hooks.json>:<label>:<group>:<handler>` to hash, for Programa's handler of each event.
pub fn expected_trust(hooks_path: &str, root: &Value) -> Result<Vec<(String, String)>, String> {
    let mut entries = Vec::new();
    for spec in &SPECS {
        let mut found = None;
        'groups: for (group_index, group) in root["hooks"][spec.0]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
        {
            for (handler_index, item) in group["hooks"].as_array().into_iter().flatten().enumerate()
            {
                if owned(item, spec.0) {
                    found = Some((group_index, handler_index, group, item));
                    break 'groups;
                }
            }
        }
        let (group_index, handler_index, group, item) =
            found.ok_or(format!("installed Codex hook for {} is missing", spec.0))?;
        entries.push((
            format!("{hooks_path}:{}:{group_index}:{handler_index}", spec.1),
            trust_hash(spec.1, group, item)?,
        ));
    }
    entries.sort();
    Ok(entries)
}

fn toml_quoted(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

/// config.toml with the Programa block holding `entries` (none removes it), rewritten where it
/// stands or appended. A trust entry the person wrote themselves is left alone, with a warning.
pub fn render_config(
    source: &str,
    entries: &[(String, String)],
) -> Result<(String, Vec<String>), String> {
    let newline = if source.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let mut lines: Vec<&str> = source.lines().collect();
    let mut at = None;
    if let Some(begin) = lines.iter().position(|line| line.trim_end() == BLOCK_BEGIN) {
        let end = lines[begin..]
            .iter()
            .position(|line| line.trim_end() == BLOCK_END)
            .map(|offset| begin + offset)
            .ok_or("config.toml has a Programa block without its end line; refusing to edit it")?;
        lines.drain(begin..=end);
        at = Some(begin);
    }
    // ponytail: a line scan, not a TOML parse; it refuses the forms that cannot take [hooks.state."…"] tables.
    let mut table = String::new();
    for line in &lines {
        let line = line.trim();
        if line.starts_with('[') {
            table = line
                .trim_matches(|c| c == '[' || c == ']')
                .trim()
                .to_owned();
        } else if (table.is_empty()
            && (line.starts_with("hooks ")
                || line.starts_with("hooks=")
                || line.starts_with("hooks.state")))
            || (table == "hooks" && (line.starts_with("state ") || line.starts_with("state=")))
        {
            return Err("cannot add Programa trust entries to config.toml: hooks is defined in a form that cannot be extended".into());
        }
    }
    let outside = lines.join("\n");
    let mut warnings = Vec::new();
    let mut block = Vec::new();
    for (key, hash) in entries {
        let header = format!("[hooks.state.{}]", toml_quoted(key));
        if outside.contains(&header) {
            warnings.push(format!("warning: config.toml already defines {header} outside the Programa block; leaving it unchanged and not trusting that hook"));
            continue;
        }
        if !block.is_empty() {
            block.push(String::new());
        }
        block.push(header);
        block.push(format!("trusted_hash = {}", toml_quoted(hash)));
    }
    if !block.is_empty() {
        block.insert(0, BLOCK_BEGIN.to_owned());
        block.push(BLOCK_END.to_owned());
    }
    let mut out: Vec<String> = lines.iter().map(|line| (*line).to_owned()).collect();
    match at {
        Some(index) => {
            out.splice(index..index, block);
        }
        None if !block.is_empty() => {
            if out.last().is_some_and(|line| !line.trim().is_empty()) {
                out.push(String::new());
            }
            out.extend(block);
        }
        None => {}
    }
    let mut text = out.join(newline);
    if !text.is_empty() {
        text.push_str(newline);
    }
    Ok((text, warnings))
}

fn read_limited(path: &Path) -> Result<Option<String>, String> {
    match fs::symlink_metadata(path) {
        Err(_) => Ok(None),
        Ok(meta) if meta.file_type().is_symlink() => Err(format!(
            "{} is a link; refusing to replace it",
            path.display()
        )),
        Ok(meta) if meta.len() > MAXIMUM_BYTES => {
            Err(format!("{} is larger than 16 MB", path.display()))
        }
        Ok(_) => fs::read_to_string(path)
            .map(Some)
            .map_err(|error| format!("{}: {error}", path.display())),
    }
}

fn write_atomic(path: &Path, text: &str) -> std::io::Result<()> {
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(".programa.tmp");
    fs::write(&temporary, text)?;
    fs::rename(&temporary, path)
}

/// Lines only in `old` with `-`, only in `new` with `+`, in order.
fn diff(old: &str, new: &str) -> String {
    let (old, new): (Vec<&str>, Vec<&str>) = (old.lines().collect(), new.lines().collect());
    let mut out = String::new();
    for line in old.iter().filter(|line| !new.contains(line)) {
        out.push_str(&format!("    - {line}\n"));
    }
    for line in new.iter().filter(|line| !old.contains(line)) {
        out.push_str(&format!("    + {line}\n"));
    }
    out
}

pub fn run(install: bool, yes: bool, env: Env, exe: &str) -> i32 {
    match apply(install, yes, env, exe) {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("Error: codex: {message}");
            1
        }
    }
}

fn apply(install: bool, yes: bool, env: Env, exe: &str) -> Result<(), String> {
    let home = env("CODEX_HOME")
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env("USERPROFILE").unwrap_or_default()).join(".codex"));
    fs::create_dir_all(&home).map_err(|error| format!("{}: {error}", home.display()))?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(home.join(".programa-hooks.lock"))
        .map_err(|error| error.to_string())?;
    lock.lock().map_err(|error| error.to_string())?;
    let (hooks_path, config_path) = (home.join("hooks.json"), home.join("config.toml"));
    let hooks_text = read_limited(&hooks_path)?;
    let previous: Value = match hooks_text.as_deref().map(str::trim) {
        None | Some("") => json!({}),
        Some(text) => serde_json::from_str(text)
            .map_err(|error| format!("{}: {error}", hooks_path.display()))?,
    };
    let next = rewrite_hooks(&previous, install, exe)?;
    let next_text = format!(
        "{}\n",
        serde_json::to_string_pretty(&next).unwrap_or_default()
    );
    let hooks_changed = if install {
        hooks_text.as_deref() != Some(next_text.as_str())
    } else {
        hooks_text.is_some() && next != previous
    };
    let entries = if install {
        expected_trust(&hooks_path.to_string_lossy(), &next)?
    } else {
        Vec::new()
    };
    let config_text = read_limited(&config_path)?.unwrap_or_default();
    let (rendered, warnings) = render_config(&config_text, &entries)?;
    let config_changed =
        rendered != config_text && !(config_text.is_empty() && rendered.is_empty());
    if !hooks_changed && !config_changed {
        println!(
            "{}",
            if install {
                "programa hooks are already installed. Nothing to change."
            } else {
                "No programa hooks found."
            }
        );
        return Ok(());
    }
    if hooks_changed {
        println!("  {}:", hooks_path.display());
        print!(
            "{}",
            if hooks_text.is_none() {
                "    (new file)\n".to_owned()
            } else {
                diff(hooks_text.as_deref().unwrap_or_default(), &next_text)
            }
        );
        println!();
    }
    if config_changed {
        println!("  {}:", config_path.display());
        if config_text.is_empty() {
            println!("    (new file)");
        }
        print!("{}", diff(&config_text, &rendered));
        println!();
    }
    for warning in &warnings {
        eprintln!("{warning}");
    }
    if !yes {
        print!("Apply these changes? [y/N] ");
        let _ = std::io::stdout().flush();
        let mut answer = String::new();
        let _ = std::io::stdin().lock().read_line(&mut answer);
        if !answer.trim().eq_ignore_ascii_case("y") && !answer.trim().eq_ignore_ascii_case("yes") {
            return Err("nothing changed".into());
        }
    }
    if hooks_changed {
        write_atomic(&hooks_path, &next_text)
            .map_err(|error| format!("{}: {error}", hooks_path.display()))?;
    }
    if config_changed {
        if let Err(error) = write_atomic(&config_path, &rendered) {
            // Put hooks.json back, so no hook is installed without its trust or the reverse.
            if let Some(original) = &hooks_text {
                let _ = write_atomic(&hooks_path, original);
            }
            return Err(format!("{}: {error}", config_path.display()));
        }
    }
    println!(
        "{}",
        if install {
            "Installed programa hooks for Codex. Start a new Codex session to load them."
        } else {
            "Removed programa hooks from Codex."
        }
    );
    Ok(())
}

/// SHA-256 (FIPS 180-4), hex.
pub fn sha256_hex(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&((data.len() as u64).wrapping_mul(8)).to_be_bytes());
    for chunk in message.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[i * 4],
                chunk[i * 4 + 1],
                chunk[i * 4 + 2],
                chunk[i * 4 + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let mut v = state;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let choice = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7]
                .wrapping_add(s1)
                .wrapping_add(choice)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let majority = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            v = [
                t1.wrapping_add(s0.wrapping_add(majority)),
                v[0],
                v[1],
                v[2],
                v[3].wrapping_add(t1),
                v[4],
                v[5],
                v[6],
            ];
        }
        for (word, add) in state.iter_mut().zip(v) {
            *word = word.wrapping_add(add);
        }
    }
    state.iter().map(|word| format!("{word:08x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXE: &str = r"C:\Users\Ada\AppData\Local\Programa\bin\programa.exe";

    #[test]
    fn sha256_matches_the_standard_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    #[test]
    fn install_keeps_other_hooks_in_place_and_uninstall_removes_only_ours() {
        let theirs =
            json!({ "type": "command", "command": "py -3 C:\\hooks\\guard.py", "timeout": 30 });
        let source = json!({ "description": "mine", "hooks": { "Stop": [{ "hooks": [theirs] }], "PreToolUse": [{ "matcher": "Bash", "hooks": [theirs] }] } });
        let installed = rewrite_hooks(&source, true, EXE).unwrap();
        assert_eq!(installed["description"], "mine");
        assert_eq!(
            installed["hooks"]["Stop"][0]["hooks"][0], theirs,
            "the other Stop hook keeps 0:0"
        );
        assert_eq!(
            installed["hooks"]["Stop"][1]["hooks"][0]["command"],
            hook_command(EXE, "stop")
        );
        assert_eq!(
            installed["hooks"]["PermissionRequest"][0]["hooks"][0]["command"],
            hook_command(EXE, "notification")
        );
        assert_eq!(
            installed["hooks"]["SessionEnd"][0]["hooks"][0]["timeout"],
            1
        );
        // Installing again changes nothing; uninstalling leaves only theirs.
        assert_eq!(rewrite_hooks(&installed, true, EXE).unwrap(), installed);
        let removed = rewrite_hooks(&installed, false, EXE).unwrap();
        assert_eq!(removed["hooks"], source["hooks"]);
        // An older macOS-style Programa handler is replaced where it stands.
        let old = json!({ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "programa codex-hook stop", "timeout": 10 }, theirs] }] } });
        let moved = rewrite_hooks(&old, true, EXE).unwrap();
        assert_eq!(
            moved["hooks"]["Stop"][0]["hooks"][0]["command"],
            hook_command(EXE, "stop")
        );
        assert_eq!(moved["hooks"]["Stop"][0]["hooks"][1], theirs);
    }

    #[test]
    fn trust_entries_hash_the_platform_command_and_render_in_one_block() {
        let installed = rewrite_hooks(&json!({}), true, EXE).unwrap();
        let entries = expected_trust(r"C:\Users\Ada\.codex\hooks.json", &installed).unwrap();
        assert_eq!(entries.len(), 5);
        assert_eq!(
            entries[0].0,
            r"C:\Users\Ada\.codex\hooks.json:permission_request:0:0"
        );
        let expected_text = format!(
            r#"{{"event_name":"stop","hooks":[{{"async":false,"command":{},"timeout":10,"type":"command"}}]}}"#,
            json!(hook_command(EXE, "stop"))
        );
        let stop = entries
            .iter()
            .find(|(key, _)| key.contains(":stop:"))
            .unwrap();
        assert_eq!(
            stop.1,
            format!("sha256:{}", sha256_hex(expected_text.as_bytes()))
        );
        assert_eq!(
            trust_hash(
                "session_end",
                &json!({}),
                &json!({ "type": "command", "command": "x", "timeout": 9 })
            )
            .unwrap(),
            trust_hash(
                "session_end",
                &json!({}),
                &json!({ "type": "command", "command": "x", "timeout": 3 })
            )
            .unwrap(),
            "SessionEnd waits 3 seconds at most"
        );

        let user = "model = \"o3\"\r\n\r\n[profiles.fast]\r\nmodel = \"mini\"\r\n";
        let (rendered, warnings) = render_config(user, &entries).unwrap();
        assert!(warnings.is_empty());
        assert!(
            rendered.starts_with(user),
            "the person's settings stay as they were"
        );
        assert!(rendered.contains("\r\n# BEGIN programa (managed by Programa, do not edit)\r\n[hooks.state.\"C:\\\\Users\\\\Ada\\\\.codex\\\\hooks.json:permission_request:0:0\"]\r\ntrusted_hash = \"sha256:"));
        // Rendering again replaces the block where it stands; no entries removes it.
        assert_eq!(render_config(&rendered, &entries).unwrap().0, rendered);
        assert_eq!(
            render_config(&rendered, &[]).unwrap().0,
            "model = \"o3\"\r\n\r\n[profiles.fast]\r\nmodel = \"mini\"\r\n\r\n"
        );
        // A trust entry written by hand is left alone; a hooks form that cannot take tables is refused.
        let own = format!(
            "[hooks.state.{}]\ntrusted_hash = \"sha256:mine\"\n",
            toml_quoted(&entries[0].0)
        );
        let (kept, warned) = render_config(&own, &entries).unwrap();
        assert_eq!(warned.len(), 1);
        assert_eq!(kept.matches("[hooks.state.").count(), 5);
        assert!(render_config("hooks = { state = {} }\n", &entries).is_err());
        assert!(render_config("[hooks]\nstate = {}\n", &entries).is_err());
    }
}
