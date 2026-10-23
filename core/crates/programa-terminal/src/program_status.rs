//! OSC 7501 Program Status Protocol: the PTY output scanner, the report parser and the
//! per-terminal record store. Validation matches Ghostty's parser and the store matches
//! `ProgramStatusStore` in the macOS app, so both apps keep the same records for the same
//! output. See docs/program-status.md.
//!
//! vte drops OSC numbers it does not know before they reach the alacritty handler, so the
//! scanner reads the raw PTY output alongside it.

use std::collections::BTreeMap;

use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};
use base64::Engine;
use serde::Serialize;

/// The longest whole sequence, from `ESC ]` through a two-byte terminator.
const MAX_SEQUENCE_BYTES: usize = 4096;
const MAX_PAYLOAD_BYTES: usize = MAX_SEQUENCE_BYTES - 4;
const MAX_BODY_BYTES: usize = MAX_SEQUENCE_BYTES - b"\x1b]7501;".len() - 2;
const MAX_KEY_BYTES: usize = 16;
const MAX_NAME_BYTES: usize = 32;
const MAX_ID_BYTES: usize = 128;
const MAX_ID_SEGMENTS: usize = 8;
const MAX_TITLE_ENCODED_BYTES: usize = 256;
const MAX_TITLE_BYTES: usize = 192;
const MAX_MSG_ENCODED_BYTES: usize = 2732;
const MAX_MSG_BYTES: usize = 2048;
pub(crate) const CAPACITY: usize = 256;

const REPORT_PREFIX: &[u8] = b"7501;";
const PROMPT_PREFIX: &[u8] = b"133;A";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum State {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

impl State {
    fn is_active(self) -> bool {
        matches!(self, State::Working | State::Blocked)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Kind {
    Permission,
    Question,
    Auth,
}

/// One validated report. `state == None` is `clear`: it removes `id` and every descendant, or
/// every record when `id` is empty.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Report {
    pub state: Option<State>,
    pub id: String,
    pub kind: Option<Kind>,
    pub progress: Option<u8>,
    pub app: Option<String>,
    pub title: Option<String>,
    pub msg: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Terminator {
    Bel,
    St,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Command {
    /// `OSC 7501 ; ? ST`: the program asks whether the terminal supports the protocol.
    Query(Terminator),
    Report(Report),
}

/// Parses the bytes after `7501;`. Returns `None` when the report must be discarded whole.
pub(crate) fn parse(body: &[u8], terminator: Terminator) -> Option<Command> {
    if body.len() > MAX_BODY_BYTES {
        return None;
    }
    if body == b"?" {
        return Some(Command::Query(terminator));
    }

    let mut state = None;
    let mut id = None;
    let mut kind = None;
    let mut progress = None;
    let mut app = None;
    let mut title = None;
    let mut msg = None;
    for pair in body.split(|&byte| byte == b':') {
        let Some(eq) = pair.iter().position(|&byte| byte == b'=') else {
            continue;
        };
        let key = trim(&pair[..eq]);
        if key.len() > MAX_KEY_BYTES {
            return None;
        }
        let value = trim(&pair[eq + 1..]);
        if !value.iter().all(|&byte| is_value_byte(byte)) {
            if key == b"id" {
                return None;
            }
            continue;
        }
        // Every limit applies to each repeat, even one a later pair replaces.
        match key {
            b"state" => state = Some(value),
            b"id" => {
                if !is_valid_id(value) {
                    return None;
                }
                id = Some(value);
            }
            b"kind" => kind = Some(value),
            b"progress" => progress = Some(value),
            b"app" => {
                if value.len() > MAX_NAME_BYTES {
                    return None;
                }
                app = Some(value);
            }
            b"title" => {
                if value.len() > MAX_TITLE_ENCODED_BYTES {
                    return None;
                }
                title = Some(value);
            }
            b"msg" => {
                if value.len() > MAX_MSG_ENCODED_BYTES {
                    return None;
                }
                msg = Some(value);
            }
            _ => {}
        }
    }

    let state = match state? {
        b"idle" => Some(State::Idle),
        b"working" => Some(State::Working),
        b"done" => Some(State::Done),
        b"blocked" => Some(State::Blocked),
        b"error" => Some(State::Error),
        b"clear" => None,
        _ => return None,
    };
    let title = decode_text(title, MAX_TITLE_BYTES)?;
    let msg = decode_text(msg, MAX_MSG_BYTES)?;

    let kind = match (state, kind) {
        (Some(State::Blocked), Some(b"permission")) => Some(Kind::Permission),
        (Some(State::Blocked), Some(b"question")) => Some(Kind::Question),
        (Some(State::Blocked), Some(b"auth")) => Some(Kind::Auth),
        _ => None,
    };
    let progress = match state {
        Some(state) if state.is_active() => progress.and_then(parse_progress),
        _ => None,
    };
    let app = app.filter(|value| is_name(value)).map(ascii_string);

    Some(Command::Report(Report {
        state,
        id: id.map(ascii_string).unwrap_or_default(),
        kind,
        progress,
        app,
        title,
        msg,
    }))
}

fn trim(value: &[u8]) -> &[u8] {
    let is_space = |byte: &u8| matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c);
    let start = value
        .iter()
        .position(|byte| !is_space(byte))
        .unwrap_or(value.len());
    let end = value
        .iter()
        .rposition(|byte| !is_space(byte))
        .map_or(start, |index| index + 1);
    &value[start..end]
}

fn is_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'+' | b'-')
}

/// A pair whose value holds any other byte is skipped as malformed.
fn is_value_byte(byte: u8) -> bool {
    is_name_byte(byte) || matches!(byte, b',' | b'/' | b'=')
}

fn is_name(value: &[u8]) -> bool {
    !value.is_empty() && value.len() <= MAX_NAME_BYTES && value.iter().all(|&b| is_name_byte(b))
}

/// An invalid id discards the report instead of falling back to the root record: for `clear`,
/// that fallback would remove every record.
fn is_valid_id(value: &[u8]) -> bool {
    value.len() <= MAX_ID_BYTES
        && value.split(|&byte| byte == b'/').count() <= MAX_ID_SEGMENTS
        && value.split(|&byte| byte == b'/').all(is_name)
}

fn parse_progress(value: &[u8]) -> Option<u8> {
    if value.is_empty() {
        return None;
    }
    let mut number: u8 = 0;
    for &byte in value {
        if !byte.is_ascii_digit() {
            return None;
        }
        number = number.checked_mul(10)?.checked_add(byte - b'0')?;
        if number > 100 {
            return None;
        }
    }
    Some(number)
}

/// `Some(None)` for absent or empty text, `None` when the report must be discarded.
fn decode_text(encoded: Option<&[u8]>, max_bytes: usize) -> Option<Option<String>> {
    let Some(encoded) = encoded.filter(|value| !value.is_empty()) else {
        return Some(None);
    };
    let engine = if encoded.ends_with(b"=") {
        &STANDARD
    } else {
        &STANDARD_NO_PAD
    };
    let decoded = engine.decode(encoded).ok()?;
    if decoded.len() > max_bytes {
        return None;
    }
    let text = String::from_utf8(decoded).ok()?;
    if text
        .chars()
        .any(|ch| matches!(ch, '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}'))
    {
        return None;
    }
    Some(Some(text))
}

fn ascii_string(value: &[u8]) -> String {
    value.iter().map(|&byte| char::from(byte)).collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Record {
    pub state: State,
    pub kind: Option<Kind>,
    pub progress: Option<u8>,
    /// As the program sent it; `Store::resolved_app` walks the ancestors.
    pub app: Option<String>,
    pub title: Option<String>,
    pub msg: Option<String>,
}

/// Records for one terminal, keyed by id (`""` is the root). Never persisted.
#[derive(Default)]
pub(crate) struct Store {
    records: BTreeMap<String, Record>,
}

impl Store {
    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.records.len()
    }

    #[cfg(test)]
    pub(crate) fn get(&self, id: &str) -> Option<&Record> {
        self.records.get(id)
    }

    /// Returns true only when the stored records changed. A repeated report, a clear of a
    /// missing id, and a report discarded past `CAPACITY` all return false.
    pub(crate) fn apply(&mut self, report: Report) -> bool {
        let Some(state) = report.state else {
            return self.clear(&report.id);
        };
        let record = Record {
            state,
            kind: report.kind,
            progress: report.progress,
            app: report.app,
            title: report.title,
            msg: report.msg,
        };
        match self.records.get(&report.id) {
            Some(existing) if *existing == record => false,
            None if self.records.len() >= CAPACITY => false,
            _ => {
                self.records.insert(report.id, record);
                true
            }
        }
    }

    /// A shell prompt means the foreground program ended: drop working and blocked records at
    /// every depth. Returns true when anything was removed.
    pub(crate) fn drop_transient(&mut self) -> bool {
        let before = self.records.len();
        self.records.retain(|_, record| !record.state.is_active());
        self.records.len() != before
    }

    /// Full terminal reset (RIS). Returns true when anything was removed.
    pub(crate) fn reset_all(&mut self) -> bool {
        let had_records = !self.records.is_empty();
        self.records.clear();
        had_records
    }

    /// `a` removes `a/b`, not `ab`. Returns true when anything was removed.
    fn clear(&mut self, id: &str) -> bool {
        let before = self.records.len();
        if id.is_empty() {
            self.records.clear();
        } else {
            self.records.retain(|key, _| {
                key != id && !(key.starts_with(id) && key.as_bytes().get(id.len()) == Some(&b'/'))
            });
        }
        self.records.len() != before
    }

    /// The app of `id`'s record, or of its nearest ancestor that has one.
    pub(crate) fn resolved_app(&self, id: &str) -> Option<&str> {
        let mut current = id;
        loop {
            if let Some(app) = self.records.get(current).and_then(|r| r.app.as_deref()) {
                return Some(app);
            }
            if current.is_empty() {
                return None;
            }
            current = current.rfind('/').map_or("", |index| &current[..index]);
        }
    }

    pub(crate) fn snapshot(&self, generation: u64) -> StatusSnapshot {
        StatusSnapshot {
            generation,
            root: self
                .records
                .get("")
                .map(|record| self.record_snapshot("", record)),
            children: self
                .records
                .iter()
                .filter(|(id, _)| !id.is_empty())
                .map(|(id, record)| self.record_snapshot(id, record))
                .collect(),
        }
    }

    fn record_snapshot(&self, id: &str, record: &Record) -> RecordSnapshot {
        RecordSnapshot {
            id: id.to_owned(),
            state: record.state,
            kind: record.kind,
            progress: record.progress,
            app: self.resolved_app(id).map(str::to_owned),
            title: record.title.clone(),
            msg: record.msg.clone(),
        }
    }
}

#[derive(Debug, Serialize)]
pub(crate) struct StatusSnapshot {
    pub generation: u64,
    pub root: Option<RecordSnapshot>,
    pub children: Vec<RecordSnapshot>,
}

#[derive(Debug, Serialize)]
pub(crate) struct RecordSnapshot {
    pub id: String,
    pub state: State,
    pub kind: Option<Kind>,
    pub progress: Option<u8>,
    pub app: Option<String>,
    pub title: Option<String>,
    pub msg: Option<String>,
}

/// A sequence the scanner found in the output, in stream order.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Sequence<'a> {
    /// The payload of an OSC 7501 or OSC 133;A sequence, between `ESC ]` and the terminator.
    Osc(&'a [u8], Terminator),
    /// `ESC c`, a full terminal reset.
    Reset,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ScanState {
    Ground,
    Escape,
    Osc,
    /// Inside an OSC that is not 7501 or 133;A, or that outgrew the buffer.
    OscIgnore,
}

/// Finds OSC 7501, OSC 133;A and RIS in raw PTY output, across read boundaries. Follows the
/// VT500 state machine that vte and Ghostty use: ESC ends an OSC wherever it appears, and
/// CAN or SUB abort it.
pub(crate) struct Scanner {
    state: ScanState,
    payload: Vec<u8>,
}

impl Default for Scanner {
    fn default() -> Self {
        Self {
            state: ScanState::Ground,
            payload: Vec::new(),
        }
    }
}

impl Scanner {
    pub(crate) fn feed(&mut self, bytes: &[u8], mut on_sequence: impl FnMut(Sequence<'_>)) {
        let mut index = 0;
        while index < bytes.len() {
            match self.state {
                ScanState::Ground => match bytes[index..].iter().position(|&b| b == 0x1b) {
                    Some(offset) => {
                        index += offset + 1;
                        self.state = ScanState::Escape;
                    }
                    None => return,
                },
                ScanState::Escape => {
                    let byte = bytes[index];
                    index += 1;
                    self.state = match byte {
                        b']' => {
                            self.payload.clear();
                            ScanState::Osc
                        }
                        b'c' => {
                            on_sequence(Sequence::Reset);
                            ScanState::Ground
                        }
                        0x1b => ScanState::Escape,
                        _ => ScanState::Ground,
                    };
                }
                ScanState::Osc => {
                    let byte = bytes[index];
                    index += 1;
                    match byte {
                        0x07 => {
                            on_sequence(Sequence::Osc(&self.payload, Terminator::Bel));
                            self.state = ScanState::Ground;
                        }
                        0x1b => {
                            on_sequence(Sequence::Osc(&self.payload, Terminator::St));
                            self.state = ScanState::Escape;
                        }
                        0x18 | 0x1a => self.state = ScanState::Ground,
                        0x00..=0x1f => {}
                        _ => {
                            if self.payload.len() == MAX_PAYLOAD_BYTES {
                                self.state = ScanState::OscIgnore;
                                continue;
                            }
                            self.payload.push(byte);
                            let head = &self.payload[..self.payload.len().min(REPORT_PREFIX.len())];
                            if !REPORT_PREFIX.starts_with(head) && !PROMPT_PREFIX.starts_with(head)
                            {
                                self.state = ScanState::OscIgnore;
                            }
                        }
                    }
                }
                ScanState::OscIgnore => {
                    match bytes[index..]
                        .iter()
                        .position(|&b| matches!(b, 0x07 | 0x1b | 0x18 | 0x1a))
                    {
                        Some(offset) => {
                            let byte = bytes[index + offset];
                            index += offset + 1;
                            self.state = if byte == 0x1b {
                                ScanState::Escape
                            } else {
                                ScanState::Ground
                            };
                        }
                        None => return,
                    }
                }
            }
        }
    }
}

/// What one chunk of output changed.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct FeedResult {
    pub changed: bool,
    /// Query replies to write back to the PTY, in order.
    pub reply: Vec<u8>,
}

/// The scanner and the store for one terminal.
#[derive(Default)]
pub(crate) struct ProgramStatus {
    scanner: Scanner,
    pub store: Store,
}

impl ProgramStatus {
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> FeedResult {
        let mut result = FeedResult::default();
        let store = &mut self.store;
        self.scanner.feed(bytes, |sequence| match sequence {
            Sequence::Reset => result.changed |= store.reset_all(),
            Sequence::Osc(payload, terminator) => {
                if let Some(body) = payload.strip_prefix(REPORT_PREFIX) {
                    match parse(body, terminator) {
                        Some(Command::Query(Terminator::Bel)) => {
                            result.reply.extend_from_slice(b"\x1b]7501;?\x07")
                        }
                        Some(Command::Query(Terminator::St)) => {
                            result.reply.extend_from_slice(b"\x1b]7501;?\x1b\\")
                        }
                        Some(Command::Report(report)) => result.changed |= store.apply(report),
                        None => {}
                    }
                } else if is_prompt(payload) {
                    result.changed |= store.drop_transient();
                }
            }
        });
        result
    }
}

fn is_prompt(payload: &[u8]) -> bool {
    payload
        .strip_prefix(PROMPT_PREFIX)
        .is_some_and(|rest| rest.is_empty() || rest[0] == b';')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(body: &str) -> Option<Report> {
        match parse(body.as_bytes(), Terminator::St) {
            Some(Command::Report(report)) => Some(report),
            Some(Command::Query(_)) => panic!("unexpected query"),
            None => None,
        }
    }

    fn b64(text: &str) -> String {
        STANDARD.encode(text)
    }

    fn working(id: &str) -> Report {
        Report {
            state: Some(State::Working),
            id: id.to_owned(),
            kind: None,
            progress: None,
            app: None,
            title: None,
            msg: None,
        }
    }

    // Parser

    #[test]
    fn parses_every_key() {
        let body = format!(
            "state=blocked:kind=permission:progress=42:id=tf/plan:app=terraform:title={}:msg={}",
            b64("Plan"),
            b64("Apply 3 to add?")
        );
        let report = report(&body).unwrap();
        assert_eq!(report.state, Some(State::Blocked));
        assert_eq!(report.kind, Some(Kind::Permission));
        assert_eq!(report.progress, Some(42));
        assert_eq!(report.id, "tf/plan");
        assert_eq!(report.app.as_deref(), Some("terraform"));
        assert_eq!(report.title.as_deref(), Some("Plan"));
        assert_eq!(report.msg.as_deref(), Some("Apply 3 to add?"));
    }

    #[test]
    fn id_with_a_disallowed_byte_discards_the_report_instead_of_clearing_the_root() {
        assert!(report("state=clear:id=bad@id").is_none());
        assert!(report("state=clear:id=ok:id=bad@id").is_none());
    }

    #[test]
    fn minimal_report_targets_the_root() {
        let report = report("state=idle").unwrap();
        assert_eq!(report.state, Some(State::Idle));
        assert_eq!(report.id, "");
        assert_eq!(
            (
                report.kind,
                report.progress,
                report.app,
                report.title,
                report.msg
            ),
            (None, None, None, None, None)
        );
    }

    #[test]
    fn query_echoes_its_terminator() {
        assert_eq!(
            parse(b"?", Terminator::St),
            Some(Command::Query(Terminator::St))
        );
        assert_eq!(
            parse(b"?", Terminator::Bel),
            Some(Command::Query(Terminator::Bel))
        );
        assert_eq!(parse(b" ?", Terminator::St), None);
    }

    #[test]
    fn state_must_be_known() {
        for body in ["", "app=cargo", "state=sleeping", "state=", "state=IDLE"] {
            assert_eq!(report(body), None, "{body}");
        }
        assert_eq!(report("state=clear").unwrap().state, None);
    }

    #[test]
    fn whitespace_around_keys_and_values_is_trimmed() {
        let report = report(" state = working :\tapp=cargo\t: id = a/b ").unwrap();
        assert_eq!(report.state, Some(State::Working));
        assert_eq!(report.app.as_deref(), Some("cargo"));
        assert_eq!(report.id, "a/b");
    }

    #[test]
    fn last_value_wins() {
        let report = report("state=idle:app=a:state=done:app=b").unwrap();
        assert_eq!(report.state, Some(State::Done));
        assert_eq!(report.app.as_deref(), Some("b"));
    }

    #[test]
    fn malformed_pairs_and_unknown_keys_are_skipped() {
        let report = report("garbage:=x:Bad=1:app=b@d:future=yes:state=working:app=ok:::").unwrap();
        assert_eq!(report.state, Some(State::Working));
        assert_eq!(report.app.as_deref(), Some("ok"));
    }

    #[test]
    fn kind_and_progress_only_apply_to_some_states() {
        let r = report("state=working:kind=auth:progress=10").unwrap();
        assert_eq!((r.kind, r.progress), (None, Some(10)));
        let r = report("state=done:kind=auth:progress=10").unwrap();
        assert_eq!((r.kind, r.progress), (None, None));
        let r = report("state=blocked:kind=auth:progress=10").unwrap();
        assert_eq!((r.kind, r.progress), (Some(Kind::Auth), Some(10)));
        assert_eq!(report("state=blocked:kind=dance").unwrap().kind, None);
    }

    #[test]
    fn out_of_range_progress_is_absent() {
        for (value, expected) in [
            ("0", Some(0)),
            ("100", Some(100)),
            ("007", Some(7)),
            ("101", None),
            ("256", None),
            ("99999999999999999999", None),
            ("-1", None),
            ("+1", None),
            ("4.5", None),
            ("1_0", None),
            ("", None),
        ] {
            let r = report(&format!("state=working:progress={value}")).unwrap();
            assert_eq!(r.progress, expected, "{value}");
        }
    }

    #[test]
    fn invalid_app_is_ignored_but_an_overlong_app_discards() {
        assert_eq!(report("state=idle:app=a/b").unwrap().app, None);
        let long = "a".repeat(MAX_NAME_BYTES + 1);
        assert_eq!(report(&format!("state=idle:app={long}")), None);
        assert_eq!(report(&format!("state=idle:app={long}:app=ok")), None);
    }

    #[test]
    fn ids() {
        let segment = "a".repeat(MAX_NAME_BYTES);
        for id in ["a", "build/test", "A-Z_0.9+", &segment, "a/b/c/d/e/f/g/h"] {
            assert_eq!(report(&format!("state=clear:id={id}")).unwrap().id, id);
        }
        let long_segment = format!("{segment}a");
        let long_id = format!("{}a", format!("{}/", "a".repeat(31)).repeat(4));
        for id in [
            "",
            "/",
            "a/",
            "/a",
            "a//b",
            "a,b",
            "a=b",
            &long_segment,
            "a/b/c/d/e/f/g/h/i",
            &long_id,
        ] {
            assert_eq!(report(&format!("state=clear:id={id}")), None, "{id}");
        }
        assert_eq!(report("state=working:id=ok:id=a//b"), None);
    }

    #[test]
    fn base64_padding_is_optional() {
        assert_eq!(
            report("state=done:msg=UGxhbg").unwrap().msg.as_deref(),
            Some("Plan")
        );
        assert_eq!(
            report("state=done:msg=UGxhbg==").unwrap().msg.as_deref(),
            Some("Plan")
        );
        assert_eq!(
            report("state=done:msg=5a6J5YWo").unwrap().msg.as_deref(),
            Some("安全")
        );
    }

    #[test]
    fn text_must_decode_to_safe_utf8() {
        for body in [
            "state=done:msg=a",
            "state=done:msg=QQ=",
            "state=done:title=a",
            "state=done:msg=YQpi",
            "state=done:msg=wps=",
            "state=done:msg=/w==",
            "state=clear:msg=a",
        ] {
            assert_eq!(report(body), None, "{body}");
        }
        for control in ["\u{0}", "\u{1b}", "\u{1f}", "\u{7f}", "\u{80}", "\u{9f}"] {
            let body = format!("state=done:title={}", b64(&format!("x{control}y")));
            assert_eq!(report(&body), None, "{control:?}");
        }
    }

    #[test]
    fn empty_text_is_absent() {
        let r = report("state=done:msg=:title=").unwrap();
        assert_eq!((r.msg, r.title), (None, None));
    }

    #[test]
    fn limits_discard_the_whole_report() {
        let title = "QUFB".repeat(MAX_TITLE_ENCODED_BYTES / 4);
        let msg = format!("{}QUE", "QUFB".repeat(MAX_MSG_BYTES / 3));
        let fill = MAX_SEQUENCE_BYTES - "\x1b]7501;state=idle:".len() - 2;
        let cases = [
            (format!("state=idle:{}=1", "a".repeat(MAX_KEY_BYTES)), true),
            (
                format!("state=idle:{}=1", "a".repeat(MAX_KEY_BYTES + 1)),
                false,
            ),
            (format!("state=idle:title={title}"), true),
            (format!("state=idle:title={title}QUFB"), false),
            (format!("state=idle:msg={msg}"), true),
            (
                format!("state=idle:msg={}", "QUFB".repeat(MAX_MSG_BYTES / 3 + 1)),
                false,
            ),
            (format!("state=idle:{}", "x".repeat(fill)), true),
            (format!("state=idle:{}", "x".repeat(fill + 1)), false),
        ];
        for (body, accepted) in cases {
            assert_eq!(report(&body).is_some(), accepted, "{} bytes", body.len());
        }
    }

    // Store

    #[test]
    fn a_report_replaces_its_record() {
        let mut store = Store::default();
        store.apply(report("state=working:progress=40:app=cargo:msg=UGxhbg").unwrap());
        store.apply(report("state=done").unwrap());
        let root = store.get("").unwrap();
        assert_eq!(root.state, State::Done);
        assert_eq!(
            (root.progress, root.app.as_deref(), root.msg.as_deref()),
            (None, None, None)
        );
    }

    #[test]
    fn clear_removes_the_subtree_only() {
        let mut store = Store::default();
        for id in ["", "a", "a/b", "a/b/c", "ab", "b"] {
            store.apply(working(id));
        }
        store.apply(report("state=clear:id=a").unwrap());
        let ids: Vec<_> = store.records.keys().cloned().collect();
        assert_eq!(ids, ["", "ab", "b"]);
        store.apply(report("state=clear").unwrap());
        assert_eq!(store.len(), 0);
    }

    #[test]
    fn capacity_rejects_new_records_but_not_updates() {
        let mut store = Store::default();
        for index in 0..CAPACITY {
            assert!(store.apply(working(&format!("r{index}"))));
        }
        assert!(!store.apply(working("one-too-many")));
        assert_eq!(store.len(), CAPACITY);
        assert!(store.get("one-too-many").is_none());
        assert!(store.apply(report("state=done:id=r0").unwrap()));
        assert_eq!(store.get("r0").unwrap().state, State::Done);
    }

    #[test]
    fn apply_reports_no_change_for_repeats_and_missing_clears() {
        let mut store = Store::default();
        assert!(store.apply(report("state=working:id=a:progress=40").unwrap()));
        assert!(!store.apply(report("state=working:id=a:progress=40").unwrap()));
        assert!(store.apply(report("state=working:id=a:progress=41").unwrap()));
        assert!(!store.apply(report("state=clear:id=missing").unwrap()));
        assert!(!store.apply(report("state=clear:id=a/b").unwrap()));
        assert!(store.apply(report("state=clear:id=a").unwrap()));
        assert!(!store.apply(report("state=clear").unwrap()));
    }

    #[test]
    fn prompt_drops_working_and_blocked_at_every_depth() {
        let mut store = Store::default();
        store.apply(report("state=working").unwrap());
        store.apply(report("state=blocked:id=a/b").unwrap());
        store.apply(report("state=done:id=a").unwrap());
        store.apply(report("state=error:id=x").unwrap());
        store.apply(report("state=idle:id=y/z").unwrap());
        assert!(store.drop_transient());
        let ids: Vec<_> = store.records.keys().cloned().collect();
        assert_eq!(ids, ["a", "x", "y/z"]);
        assert!(!store.drop_transient());
    }

    #[test]
    fn reset_removes_everything() {
        let mut store = Store::default();
        store.apply(report("state=done").unwrap());
        store.apply(report("state=done:id=a").unwrap());
        assert!(store.reset_all());
        assert_eq!(store.len(), 0);
        assert!(!store.reset_all());
    }

    #[test]
    fn children_inherit_app_from_the_nearest_ancestor() {
        let mut store = Store::default();
        store.apply(report("state=working:app=deploy").unwrap());
        store.apply(report("state=working:id=eu:app=eu-tool").unwrap());
        store.apply(report("state=working:id=eu/fra/1").unwrap());
        store.apply(report("state=working:id=us/east").unwrap());
        assert_eq!(store.resolved_app("eu/fra/1"), Some("eu-tool"));
        assert_eq!(store.resolved_app("us/east"), Some("deploy"));
        let snapshot = store.snapshot(3);
        assert_eq!(snapshot.root.unwrap().app.as_deref(), Some("deploy"));
        let children: Vec<_> = snapshot
            .children
            .iter()
            .map(|c| (c.id.as_str(), c.app.as_deref()))
            .collect();
        assert_eq!(
            children,
            [
                ("eu", Some("eu-tool")),
                ("eu/fra/1", Some("eu-tool")),
                ("us/east", Some("deploy"))
            ]
        );
    }

    #[test]
    fn snapshot_serializes_the_wire_shape() {
        let mut store = Store::default();
        store.apply(report("state=blocked:kind=question:progress=5:app=claude").unwrap());
        let json = serde_json::to_value(store.snapshot(9)).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "generation": 9,
                "root": {
                    "id": "", "state": "blocked", "kind": "question", "progress": 5,
                    "app": "claude", "title": null, "msg": null
                },
                "children": []
            })
        );
    }

    // Scanner

    fn scan(chunks: &[&[u8]]) -> Vec<(Vec<u8>, Option<Terminator>)> {
        let mut scanner = Scanner::default();
        let mut found = Vec::new();
        for chunk in chunks {
            scanner.feed(chunk, |sequence| match sequence {
                Sequence::Osc(payload, terminator) => {
                    found.push((payload.to_vec(), Some(terminator)))
                }
                Sequence::Reset => found.push((b"RIS".to_vec(), None)),
            });
        }
        found
    }

    #[test]
    fn scanner_accepts_both_terminators() {
        assert_eq!(
            scan(&[b"\x1b]7501;state=idle\x07\x1b]7501;state=done\x1b\\"]),
            [
                (b"7501;state=idle".to_vec(), Some(Terminator::Bel)),
                (b"7501;state=done".to_vec(), Some(Terminator::St)),
            ]
        );
    }

    #[test]
    fn scanner_joins_a_sequence_split_across_reads() {
        let expected = [(b"7501;state=working".to_vec(), Some(Terminator::St))];
        assert_eq!(
            scan(&[b"out\x1b]75", b"01;state=work", b"ing\x1b", b"\\more"]),
            expected
        );
        assert_eq!(scan(&[b"\x1b", b"]7501;state=working\x1b\\"]), expected);
    }

    #[test]
    fn scanner_ignores_other_oscs_and_normal_output() {
        assert_eq!(
            scan(&[b"hello \x1b[31mred\x1b[0m \x1b]0;title\x07 \x1b]52;c;aGk=\x1b\\ \x1b]133;B\x07 \x1b]75010;x\x07"]),
            []
        );
        assert_eq!(
            scan(&[b"\x1b]133;A\x07\x1b]133;A;cl=m\x1b\\"]),
            [
                (b"133;A".to_vec(), Some(Terminator::Bel)),
                (b"133;A;cl=m".to_vec(), Some(Terminator::St)),
            ]
        );
    }

    #[test]
    fn scanner_drops_an_overlong_sequence() {
        let mut long = b"\x1b]7501;state=idle:".to_vec();
        long.resize(MAX_PAYLOAD_BYTES + 3, b'x');
        long.extend_from_slice(b"\x1b\\\x1b]7501;state=done\x07");
        assert_eq!(
            scan(&[&long]),
            [(b"7501;state=done".to_vec(), Some(Terminator::Bel))]
        );

        let mut fits = b"\x1b]".to_vec();
        fits.extend_from_slice(b"7501;");
        fits.resize(2 + MAX_PAYLOAD_BYTES, b'x');
        fits.extend_from_slice(b"\x1b\\");
        assert_eq!(scan(&[&fits]).len(), 1);
    }

    #[test]
    fn scanner_reports_reset_and_aborts_on_can() {
        assert_eq!(
            scan(&[b"a\x1bcb\x1b(c\x1b]7501;state=idle\x18\x1b]7501;state=done\x07"]),
            [
                (b"RIS".to_vec(), None),
                (b"7501;state=done".to_vec(), Some(Terminator::Bel)),
            ]
        );
    }

    #[test]
    fn scanner_skips_c0_bytes_inside_an_osc() {
        assert_eq!(
            scan(&[b"\x1b]7501;state=\x01done\x07"]),
            [(b"7501;state=done".to_vec(), Some(Terminator::Bel))]
        );
    }

    // End to end

    #[test]
    fn feed_applies_reports_prompts_and_resets_in_order() {
        let mut status = ProgramStatus::default();
        let out =
            status.feed(b"\x1b]7501;state=working:progress=10\x1b\\\x1b]7501;state=done:id=a\x07");
        assert!(out.changed);
        assert!(out.reply.is_empty());
        assert_eq!(status.store.len(), 2);

        assert!(status.feed(b"$ \x1b]133;A\x07").changed);
        assert!(status.store.get("").is_none());
        assert!(status.store.get("a").is_some());

        assert!(!status.feed(b"\x1b]133;A\x07plain output").changed);
        assert!(status.feed(b"\x1bc").changed);
        assert_eq!(status.store.len(), 0);

        assert!(!status.feed(b"\x1b]7501;state=working:id=a//b\x07").changed);
        assert_eq!(status.store.len(), 0);
    }

    /// `changed` is what bumps the session's status generation, so a no-op report must not set it.
    #[test]
    fn feed_reports_no_change_for_a_repeated_report_or_a_missing_clear() {
        let mut status = ProgramStatus::default();
        assert!(
            status
                .feed(b"\x1b]7501;state=working:id=a:msg=UGxhbg\x07")
                .changed
        );
        assert!(
            !status
                .feed(b"\x1b]7501;state=working:id=a:msg=UGxhbg\x07")
                .changed
        );
        assert!(!status.feed(b"\x1b]7501;state=clear:id=b\x07").changed);
        assert_eq!(status.store.len(), 1);
    }

    #[test]
    fn feed_answers_the_feature_query() {
        let mut status = ProgramStatus::default();
        let out = status.feed(b"\x1b]7501;?\x1b\\\x1b]7501;?\x07");
        assert!(!out.changed);
        assert_eq!(out.reply, b"\x1b]7501;?\x1b\\\x1b]7501;?\x07");
    }
}
