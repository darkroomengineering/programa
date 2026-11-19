//! App commands, as on macOS: `shortcuts` (Settings at Keyboard Shortcuts), `list-shortcuts`
//! (each shortcut as the app resolves it), `reload-config` and `feedback`.

use serde_json::{Map, Value};

use super::{items, no_positionals, parse_opts, put, str_or_empty, Command, UsageError};

pub(crate) fn params(command: Command, args: &[String]) -> Result<Map<String, Value>, UsageError> {
    let name = command.name();
    let mut params = Map::new();
    match command {
        Command::ReloadConfig => {
            if let Some(unexpected) = args.first() {
                return Err(UsageError(format!(
                    "{name} does not accept arguments. Unexpected argument '{unexpected}'"
                )));
            }
        }
        Command::Feedback | Command::FeedbackSubmit => {
            let opts = parse_opts(command, args, &["--email", "--body", "--image"], &[])?;
            no_positionals(command, &opts)?;
            if command == Command::FeedbackSubmit {
                put(&mut params, "email", opts.value("--email"));
                put(&mut params, "body", opts.value("--body"));
            }
        }
        _ => {
            let opts = parse_opts(command, args, &[], &[])?;
            no_positionals(command, &opts)?;
            if command == Command::OpenShortcuts {
                put(&mut params, "target", Some("keyboardShortcuts".to_owned()));
            }
        }
    }
    Ok(params)
}

/// `feedback` with --email, --body or --image sends it (macOS refuses: submission is disabled).
pub(crate) fn sends_feedback(args: &[String]) -> bool {
    args.iter().any(|arg| {
        ["--email", "--body", "--image"]
            .iter()
            .any(|flag| arg == flag || arg.starts_with(&format!("{flag}=")))
    })
}

pub(crate) fn render(command: Command, result: &Value) -> String {
    match command {
        Command::ReloadConfig => "OK Reloaded config\n".to_owned(),
        Command::ListShortcuts => items(result, "shortcuts")
            .iter()
            .map(|shortcut| {
                format!(
                    "{}  {}\n",
                    str_or_empty(shortcut, "id"),
                    str_or_empty(shortcut, "display_string")
                )
            })
            .collect(),
        _ => "OK\n".to_owned(),
    }
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
    fn commands_and_output_match_macos() {
        assert_eq!(
            call(&["shortcuts"]).unwrap(),
            (
                "settings.open".into(),
                json!({"target": "keyboardShortcuts"})
            )
        );
        assert_eq!(
            call(&["list-shortcuts"]).unwrap(),
            ("shortcuts.list".into(), json!({}))
        );
        assert_eq!(
            call(&["reload-config"]).unwrap(),
            ("app.reload_config".into(), json!({}))
        );
        assert_eq!(
            call(&["reload-config", "now"]).unwrap_err(),
            "reload-config does not accept arguments. Unexpected argument 'now'"
        );
        assert_eq!(
            call(&["feedback"]).unwrap(),
            ("feedback.open".into(), json!({}))
        );
        assert_eq!(
            call(&["feedback", "--email", "a@b", "--body", "hi"]).unwrap(),
            (
                "feedback.submit".into(),
                json!({"email": "a@b", "body": "hi"})
            )
        );
        assert_eq!(
            render(Command::ReloadConfig, &json!({"reloaded": true})),
            "OK Reloaded config\n"
        );
        assert_eq!(
            render(
                Command::ListShortcuts,
                &json!({"shortcuts": [{"id": "new_workspace", "display_string": "Ctrl+Shift+N"}]})
            ),
            "new_workspace  Ctrl+Shift+N\n"
        );
        assert_eq!(render(Command::OpenShortcuts, &json!({})), "OK\n");
    }
}
