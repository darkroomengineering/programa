//! Wire types for Programa's v2 socket protocol.
//!
//! This mirrors the JSON-lines protocol implemented by the macOS app's
//! `TerminalController` (see `docs/v2-api-migration.md` and
//! `tests_v2/cmux.py` in the `programa` repo, which this crate does not
//! depend on or import from at runtime). One JSON object per line, in both
//! directions, over a Unix domain socket:
//!
//! ```json
//! {"id":1,"method":"system.ping","params":{}}
//! {"id":1,"ok":true,"result":{}}
//! {"id":1,"ok":false,"error":{"code":"not_found","message":"..."}}
//! ```
//!
//! `id` is echoed back verbatim and may be a string, a number, or absent.
//! Error `code` values are stable short snake_case tokens (`not_found`,
//! `invalid_params`, `method_not_found`, `auth_required`, ...), matched
//! against the existing app's codes wherever an equivalent exists so a
//! client written against one server needs no changes to talk to the other.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// An incoming request, one per line.
#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    /// Echoed back verbatim in the response. Absent on notifications that
    /// expect no reply (none defined yet, but the field is optional to
    /// match the existing protocol's leniency).
    #[serde(default)]
    pub id: Option<Value>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

impl Request {
    /// Parse and validate one UTF-8 JSON request frame. The v2 protocol
    /// requires a JSON object, a non-empty string method (after trimming),
    /// and object-valued params when params is present.
    pub fn parse(frame: &str) -> Result<Self, ErrorBody> {
        let value: Value = serde_json::from_str(frame)
            .map_err(|_| ErrorBody::new(ErrorCode::ParseError, "Invalid JSON"))?;
        let object = value
            .as_object()
            .ok_or_else(|| ErrorBody::new(ErrorCode::InvalidRequest, "Expected JSON object"))?;

        let method = object
            .get("method")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|method| !method.is_empty())
            .ok_or_else(|| ErrorBody::new(ErrorCode::InvalidRequest, "Missing method"))?
            .to_string();

        let params = match object.get("params") {
            None => Value::Object(Default::default()),
            Some(Value::Object(params)) => Value::Object(params.clone()),
            Some(_) => {
                return Err(ErrorBody::new(
                    ErrorCode::InvalidRequest,
                    "params must be a JSON object",
                ));
            }
        };

        Ok(Request {
            id: object.get("id").cloned(),
            method,
            params,
        })
    }
}

/// A response, one per line. Serializes to exactly one of the two documented
/// shapes: `{"id","ok":true,"result"}` or `{"id","ok":false,"error"}`.
#[derive(Debug, Clone, Serialize)]
pub struct Response {
    pub id: Option<Value>,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorBody>,
}

impl Response {
    pub fn ok(id: Option<Value>, result: Value) -> Self {
        Response {
            id,
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: Option<Value>, err: ErrorBody) -> Self {
        Response {
            id,
            ok: false,
            result: None,
            error: Some(err),
        }
    }

    /// Serialize as one JSON line, terminated with `\n`, ready to write to
    /// the socket.
    pub fn to_line(&self) -> String {
        let mut s = serde_json::to_string(self).unwrap_or_else(|_| {
            r#"{"id":null,"ok":false,"error":{"code":"internal_error","message":"failed to serialize response"}}"#
                .to_string()
        });
        s.push('\n');
        s
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ErrorBody {
    pub code: ErrorCode,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl ErrorBody {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        ErrorBody {
            code,
            message: message.into(),
            data: None,
        }
    }

    pub fn with_data(mut self, data: Value) -> Self {
        self.data = Some(data);
        self
    }
}

/// Stable error codes. Matches the existing macOS app's `TerminalController`
/// codes (`docs/v2-api-migration.md`, `Sources/TerminalController.swift`)
/// wherever an equivalent situation exists, so an existing v2 client (the
/// CLI, `tests_v2/cmux.py`, the MCP bridge) needs no code changes to talk to
/// `programad` instead of the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    ParseError,
    InvalidUtf8,
    InvalidRequest,
    InvalidParams,
    PayloadTooLarge,
    MethodNotFound,
    NotFound,
    AuthRequired,
    AuthUnconfigured,
    AuthFailed,
    AlreadyAttached,
    Timeout,
    InternalError,
    Unsupported,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::ParseError => "parse_error",
            ErrorCode::InvalidUtf8 => "invalid_utf8",
            ErrorCode::InvalidRequest => "invalid_request",
            ErrorCode::InvalidParams => "invalid_params",
            ErrorCode::PayloadTooLarge => "payload_too_large",
            ErrorCode::MethodNotFound => "method_not_found",
            ErrorCode::NotFound => "not_found",
            ErrorCode::AuthRequired => "auth_required",
            ErrorCode::AuthUnconfigured => "auth_unconfigured",
            ErrorCode::AuthFailed => "auth_failed",
            ErrorCode::AlreadyAttached => "already_attached",
            ErrorCode::Timeout => "timeout",
            ErrorCode::InternalError => "internal_error",
            ErrorCode::Unsupported => "unsupported",
        }
    }
}

/// Methods `programad` implements, advertised verbatim by
/// `system.capabilities`. Kept as a plain list (not an enum) because the
/// method namespace is intentionally open-ended; see README for the
/// authoritative list alongside what the macOS app implements that
/// `programad` does not (yet).
pub const IMPLEMENTED_METHODS: &[&str] = &[
    "system.ping",
    "system.capabilities",
    "system.identify",
    "auth.login",
    "session.open",
    "session.list",
    "session.status",
    "session.resize",
    "session.close",
    "session.write",
    "session.read",
    "session.attach",
    "session.detach",
];

pub const IMPLEMENTATION_NAME: &str = "programad";
pub const IMPLEMENTATION_VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn response_ok_shape() {
        let r = Response::ok(Some(Value::from(1)), serde_json::json!({"pong": true}));
        let v: Value = serde_json::from_str(&r.to_line()).unwrap();
        assert_eq!(v["id"], 1);
        assert_eq!(v["ok"], true);
        assert!(v.get("error").is_none());
    }

    #[test]
    fn response_err_shape() {
        let r = Response::err(
            Some(Value::from("abc")),
            ErrorBody::new(ErrorCode::NotFound, "session not found"),
        );
        let v: Value = serde_json::from_str(&r.to_line()).unwrap();
        assert_eq!(v["id"], "abc");
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"]["code"], "not_found");
        assert!(v.get("result").is_none());
    }

    #[test]
    fn request_parses_numeric_and_string_ids() {
        let a = Request::parse(r#"{"id":1,"method":"system.ping","params":{}}"#).unwrap();
        assert_eq!(a.id, Some(Value::from(1)));
        let b = Request::parse(r#"{"id":"x","method":"  system.ping  "}"#).unwrap();
        assert_eq!(b.id, Some(Value::from("x")));
        assert_eq!(b.method, "system.ping");
        assert_eq!(b.params, serde_json::json!({}));
    }

    #[test]
    fn request_rejects_non_object_shape_and_params() {
        assert_eq!(
            Request::parse("[]").unwrap_err().code,
            ErrorCode::InvalidRequest
        );
        assert_eq!(
            Request::parse(r#"{"id":1,"method":"system.ping","params":[]}"#)
                .unwrap_err()
                .code,
            ErrorCode::InvalidRequest
        );
        assert_eq!(
            Request::parse(r#"{"id":1,"method":"   "}"#)
                .unwrap_err()
                .code,
            ErrorCode::InvalidRequest
        );
    }
}
