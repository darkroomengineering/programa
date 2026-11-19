use std::borrow::Cow;
use std::collections::HashMap;
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use alacritty_terminal::event::{Event, EventListener, Notify, OnResize, WindowSize};
use alacritty_terminal::event_loop::{EventLoop, EventLoopSender, Msg, Notifier};
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::index::{Column, Line, Point, Side};
use alacritty_terminal::selection::{Selection, SelectionType};
use alacritty_terminal::sync::FairMutex;
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::color::Colors as TermColors;
use alacritty_terminal::term::{Config as TermConfig, Term, TermMode};
use alacritty_terminal::tty::{self, Options as PtyOptions, Shell};
use alacritty_terminal::vte::ansi::CursorShape;
use alacritty_terminal::vte::ansi::{Color, NamedColor};
use serde::{Deserialize, Serialize};

pub mod host;
mod program_status;
use program_status::ProgramStatus;

const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_FAILED: i32 = 2;
const MAX_COLUMNS: usize = 4096;
const MAX_ROWS: usize = 4096;
const MAX_CELLS: usize = 1_048_576;

#[repr(C)]
#[derive(Default)]
pub struct ProgramaTerminalBuffer {
    pub data: *mut u8,
    pub len: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TermSize {
    cols: usize,
    lines: usize,
    cell_width: u16,
    cell_height: u16,
}

impl Dimensions for TermSize {
    fn total_lines(&self) -> usize {
        self.lines
    }
    fn screen_lines(&self) -> usize {
        self.lines
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

impl TermSize {
    fn window_size(self) -> WindowSize {
        WindowSize {
            num_lines: self.lines as u16,
            num_cols: self.cols as u16,
            cell_width: self.cell_width,
            cell_height: self.cell_height,
        }
    }
}

fn validate_size(size: TermSize) -> Result<TermSize, String> {
    if size.cols < 2
        || size.lines < 2
        || size.cell_width == 0
        || size.cell_height == 0
        || size.cols > MAX_COLUMNS
        || size.lines > MAX_ROWS
        || size.cols.saturating_mul(size.lines) > MAX_CELLS
    {
        return Err(format!(
            "invalid terminal dimensions: {} columns by {} rows",
            size.cols, size.lines
        ));
    }
    Ok(size)
}

#[derive(Default)]
struct Signal {
    #[cfg(windows)]
    handle: usize,
}

impl Signal {
    fn new() -> Result<Self, String> {
        #[cfg(windows)]
        {
            let handle = unsafe {
                windows_sys::Win32::System::Threading::CreateEventW(ptr::null(), 1, 0, ptr::null())
            };
            if handle.is_null() {
                return Err(std::io::Error::last_os_error().to_string());
            }
            Ok(Self {
                handle: handle as usize,
            })
        }
        #[cfg(not(windows))]
        {
            Ok(Self {})
        }
    }

    fn set(&self) {
        #[cfg(windows)]
        unsafe {
            windows_sys::Win32::System::Threading::SetEvent(
                self.handle as windows_sys::Win32::Foundation::HANDLE,
            );
        }
    }

    fn reset(&self) {
        #[cfg(windows)]
        unsafe {
            windows_sys::Win32::System::Threading::ResetEvent(
                self.handle as windows_sys::Win32::Foundation::HANDLE,
            );
        }
    }

    fn raw(&self) -> *mut c_void {
        #[cfg(windows)]
        {
            self.handle as *mut c_void
        }
        #[cfg(not(windows))]
        {
            ptr::null_mut()
        }
    }
}

impl Drop for Signal {
    fn drop(&mut self) {
        #[cfg(windows)]
        if self.handle != 0 {
            unsafe {
                windows_sys::Win32::Foundation::CloseHandle(
                    self.handle as windows_sys::Win32::Foundation::HANDLE,
                );
            }
        }
    }
}

struct SharedState {
    generation: AtomicU64,
    terminated: AtomicBool,
    error: Mutex<Option<String>>,
    title: Mutex<Option<String>>,
    /// Text a program stored with OSC 52, waiting for the frontend to put it on the clipboard.
    clipboard: Mutex<Option<String>>,
    /// OSC 777/9 desktop notifications waiting for the frontend.
    notifications: Mutex<Vec<program_status::Notification>>,
    /// The working directory the shell last reported (OSC 7 or 9;9), and a counter that moves
    /// on every report, so a frontend notices a new prompt in the same directory.
    cwd: Mutex<Option<String>>,
    cwd_generation: AtomicU64,
    colors: Mutex<Colors>,
    program_status: Mutex<ProgramStatus>,
    program_status_generation: AtomicU64,
    signal: Signal,
    sender: Mutex<Option<EventLoopSender>>,
    /// The terminal host's copy of each output chunk, before it is parsed.
    tap: Mutex<Option<Tap>>,
    /// In the terminal host: the app's terminal answers the program's queries, not this one.
    quiet: bool,
    /// Bytes of past output still to come after a reattach, during which nothing is answered or
    /// notified again; `muted` while they are parsed.
    replay: AtomicU64,
    muted: AtomicBool,
}

/// Receives every chunk of a session's output (the terminal host forwards it to the app).
pub(crate) type Tap = Box<dyn FnMut(&[u8]) + Send>;

impl SharedState {
    fn changed(&self) {
        self.generation.fetch_add(1, Ordering::Release);
        self.signal.set();
    }

    fn fail(&self, message: String) {
        *lock(&self.error) = Some(message);
        self.changed();
    }

    /// The terminal's own answers (device reports, color queries, OSC 7501 probes); never what
    /// the person types, which goes straight to the notifier.
    fn write_to_pty(&self, bytes: Vec<u8>) {
        if self.quiet || self.muted.load(Ordering::Acquire) {
            return;
        }
        if let Some(sender) = lock(&self.sender).as_ref() {
            if let Err(error) = sender.send(Msg::Input(Cow::Owned(bytes))) {
                self.fail(error.to_string());
            }
        }
    }
}

#[derive(Clone)]
struct EventProxy(Arc<SharedState>);

impl EventListener for EventProxy {
    fn send_event(&self, event: Event) {
        match event {
            Event::Title(title) => {
                *lock(&self.0.title) = Some(title);
                self.0.changed();
            }
            Event::ResetTitle => {
                *lock(&self.0.title) = None;
                self.0.changed();
            }
            Event::Wakeup | Event::CursorBlinkingChange | Event::MouseCursorDirty => {
                self.0.changed()
            }
            Event::Exit | Event::ChildExit(_) => {
                self.0.terminated.store(true, Ordering::Release);
                self.0.changed();
            }
            Event::PtyWrite(text) => self.0.write_to_pty(text.into_bytes()),
            // OSC 10/11/4 queries. Agents ask for the background to pick a light or dark theme.
            // ponytail: answers from the configured colors, not colors the program itself set
            // with OSC 4/10/11 (the term is locked while this runs); rare enough to skip.
            Event::ColorRequest(index, format) => {
                let color = lock(&self.0.colors).query(index);
                let reply = format(alacritty_terminal::vte::ansi::Rgb {
                    r: color.r,
                    g: color.g,
                    b: color.b,
                });
                self.0.write_to_pty(reply.into_bytes());
            }
            // OSC 52 write; reading the clipboard (ClipboardLoad) stays denied, as in Ghostty.
            Event::ClipboardStore(_, text) => {
                *lock(&self.0.clipboard) = Some(text);
                self.0.changed();
            }
            _ => {}
        }
    }

    fn pty_output(&self, bytes: &[u8]) {
        // This runs before each chunk is parsed, so the flag covers that chunk's answers.
        let remaining = self.0.replay.load(Ordering::Acquire);
        let muted = remaining > 0;
        if muted {
            self.0.replay.store(
                remaining.saturating_sub(bytes.len() as u64),
                Ordering::Release,
            );
        }
        self.0.muted.store(muted, Ordering::Release);
        if let Some(tap) = lock(&self.0.tap).as_mut() {
            tap(bytes);
        }
        let result = lock(&self.0.program_status).feed(bytes);
        if result.changed {
            self.0
                .program_status_generation
                .fetch_add(1, Ordering::Release);
            self.0.changed();
        }
        if !result.reply.is_empty() {
            self.0.write_to_pty(result.reply);
        }
        if let Some(cwd) = result.cwd {
            *lock(&self.0.cwd) = Some(cwd);
            self.0.cwd_generation.fetch_add(1, Ordering::Release);
            self.0.changed();
        }
        if !result.notifications.is_empty() && !muted {
            let mut pending = lock(&self.0.notifications);
            pending.extend(result.notifications);
            // A frontend that stops reading must not grow this without bound.
            let excess = pending.len().saturating_sub(MAX_PENDING_NOTIFICATIONS);
            pending.drain(..excess);
            drop(pending);
            self.0.changed();
        }
    }
}

const MAX_PENDING_NOTIFICATIONS: usize = 64;

#[derive(Deserialize, Serialize, Default, Clone)]
pub(crate) struct CreateConfig {
    shell: Option<String>,
    #[serde(default)]
    args: Vec<String>,
    working_directory: Option<String>,
    #[serde(default)]
    env: HashMap<String, String>,
    cols: Option<u16>,
    rows: Option<u16>,
    cell_width: Option<u16>,
    cell_height: Option<u16>,
    #[serde(default)]
    colors: ColorsConfig,
    /// Start PowerShell with Programa's shell integration (working directory, prompt marks).
    #[serde(default)]
    shell_integration: bool,
    /// Output saved by session restore, shown as scrollback above the new shell.
    restore_text: Option<String>,
    /// Run the shell in the terminal host, reattaching to the session of this id when it is
    /// still running there (host.rs); without a reachable host the shell runs here.
    host: Option<host::HostConfig>,
}

/// Colors the frontend resolved from its theme. Each field overrides Ghostty's default.
#[derive(Deserialize, Serialize, Default, Clone)]
struct ColorsConfig {
    #[serde(default)]
    palette: HashMap<u8, [u8; 3]>,
    foreground: Option<[u8; 3]>,
    background: Option<[u8; 3]>,
    cursor: Option<[u8; 3]>,
}

#[derive(Clone, Copy)]
struct Colors {
    palette: [Rgba; 256],
    foreground: Rgba,
    background: Rgba,
    cursor: Rgba,
}

impl Default for Colors {
    /// Ghostty's defaults (src/config/Config.zig, src/terminal/color.zig): the macOS app's look.
    fn default() -> Self {
        let foreground = rgb([0xFF, 0xFF, 0xFF]);
        Self {
            palette: std::array::from_fn(|index| xterm(index as u8)),
            foreground,
            background: rgb([0x28, 0x2C, 0x34]),
            cursor: foreground,
        }
    }
}

impl ColorsConfig {
    fn resolve(&self) -> Colors {
        let mut colors = Colors::default();
        for (&index, &value) in &self.palette {
            colors.palette[usize::from(index)] = rgb(value);
        }
        colors.foreground = self.foreground.map_or(colors.foreground, rgb);
        colors.background = self.background.map_or(colors.background, rgb);
        colors.cursor = self.cursor.map_or(colors.foreground, rgb);
        colors
    }
}

impl Colors {
    /// Answer for an OSC 4/10/11/12 query: 0-255 are the palette, 256-258 the default
    /// foreground, background and cursor (vte's NamedColor numbering).
    fn query(&self, index: usize) -> Rgba {
        match index {
            0..=255 => self.palette[index],
            256 => self.foreground,
            257 => self.background,
            _ => self.cursor,
        }
    }

    /// A cell color, preferring what the program set with OSC 4/10/11 over the theme.
    fn resolve(&self, color: Color, overrides: &TermColors) -> Rgba {
        let index = match color {
            Color::Spec(value) => return rgb([value.r, value.g, value.b]),
            Color::Indexed(index) => usize::from(index),
            Color::Named(name) => match name {
                // Dim and bright foregrounds have no palette slot; dim is drawn translucent.
                NamedColor::DimForeground | NamedColor::BrightForeground => {
                    NamedColor::Foreground as usize
                }
                NamedColor::DimBlack => 0,
                NamedColor::DimRed => 1,
                NamedColor::DimGreen => 2,
                NamedColor::DimYellow => 3,
                NamedColor::DimBlue => 4,
                NamedColor::DimMagenta => 5,
                NamedColor::DimCyan => 6,
                NamedColor::DimWhite => 7,
                other => other as usize,
            },
        };
        overrides[index].map_or_else(
            || self.query(index),
            |value| rgb([value.r, value.g, value.b]),
        )
    }
}

fn rgb([r, g, b]: [u8; 3]) -> Rgba {
    Rgba { r, g, b, a: 255 }
}

pub struct ProgramaTerminalSession {
    /// The shell's process id (0 when unknown).
    shell_pid: u32,
    /// The terminal host running this session, when it runs there.
    host: Option<host::HostConfig>,
    term: Arc<FairMutex<Term<EventProxy>>>,
    notifier: Notifier,
    size: Mutex<TermSize>,
    state: Arc<SharedState>,
    io_thread: Mutex<
        Option<
            JoinHandle<(
                EventLoop<tty::Pty, EventProxy>,
                alacritty_terminal::event_loop::State,
            )>,
        >,
    >,
}

impl ProgramaTerminalSession {
    fn spawn(config: CreateConfig) -> Result<Self, String> {
        Self::spawn_with(config, None, false)
    }

    /// `tap` and `quiet` are the terminal host's: it forwards the output and leaves answering the
    /// program to the app's terminal.
    pub(crate) fn spawn_with(
        config: CreateConfig,
        tap: Option<Tap>,
        quiet: bool,
    ) -> Result<Self, String> {
        let size = validate_size(TermSize {
            cols: usize::from(config.cols.unwrap_or(80).max(2)),
            lines: usize::from(config.rows.unwrap_or(24).max(2)),
            cell_width: config.cell_width.unwrap_or(8).max(1),
            cell_height: config.cell_height.unwrap_or(16).max(1),
        })?;
        // In the terminal host when the app runs one, else (or when it cannot be reached) here.
        #[cfg(windows)]
        let remote = config.host.clone().and_then(|host| {
            remote_pty(&host, &config, size)
                .ok()
                .map(|remote| (host, remote))
        });
        #[cfg(not(windows))]
        let remote: Option<(host::HostConfig, (tty::Pty, u32, u64, bool))> = None;
        let (pty, shell_pid, replay, attached, host) = match remote {
            Some((host, (pty, pid, replay, attached))) => (pty, pid, replay, attached, Some(host)),
            None => {
                let (pty, pid) = local_pty(&config, size)?;
                (pty, pid, 0, false, None)
            }
        };
        let state = Arc::new(SharedState {
            generation: AtomicU64::new(1),
            terminated: AtomicBool::new(false),
            error: Mutex::new(None),
            title: Mutex::new(None),
            clipboard: Mutex::new(None),
            notifications: Mutex::new(Vec::new()),
            cwd: Mutex::new(None),
            cwd_generation: AtomicU64::new(0),
            colors: Mutex::new(config.colors.resolve()),
            program_status: Mutex::new(ProgramStatus::default()),
            program_status_generation: AtomicU64::new(0),
            signal: Signal::new()?,
            sender: Mutex::new(None),
            tap: Mutex::new(tap),
            quiet,
            replay: AtomicU64::new(replay),
            muted: AtomicBool::new(false),
        });
        let proxy = EventProxy(state.clone());
        let term_config = TermConfig {
            kitty_keyboard: true,
            ..TermConfig::default()
        };
        let term = Arc::new(FairMutex::new(Term::new(term_config, &size, proxy.clone())));
        // Before the event loop starts, so the shell's first output lands below it. A reattached
        // session replays its own output instead.
        if let Some(text) = config
            .restore_text
            .as_deref()
            .filter(|text| !text.is_empty() && !attached)
        {
            restore_output(&mut term.lock(), text);
        }
        let event_loop = EventLoop::new(term.clone(), proxy, pty, true, false)
            .map_err(|error| error.to_string())?;
        let notifier = Notifier(event_loop.channel());
        *lock(&state.sender) = Some(notifier.0.clone());
        let io_thread = event_loop.spawn();
        state.signal.set();
        Ok(Self {
            term,
            notifier,
            size: Mutex::new(size),
            state,
            io_thread: Mutex::new(Some(io_thread)),
            shell_pid,
            host,
        })
    }

    /// The terminal host types what its app sent.
    pub(crate) fn type_input(&self, bytes: &[u8]) {
        self.notifier.notify(Cow::Owned(bytes.to_vec()));
    }

    pub(crate) fn resize_to(&self, cols: u16, rows: u16, cell_width: u16, cell_height: u16) {
        if let Ok(size) = validate_size(TermSize {
            cols: usize::from(cols.max(2)),
            lines: usize::from(rows.max(2)),
            cell_width: cell_width.max(1),
            cell_height: cell_height.max(1),
        }) {
            self.resize(size);
        }
    }

    fn resize(&self, next: TermSize) {
        let mut size = lock(&self.size);
        if *size == next {
            return;
        }
        self.term.lock().resize(next);
        let mut notifier = Notifier(self.notifier.0.clone());
        notifier.on_resize(next.window_size());
        *size = next;
        self.state.changed();
    }

    fn display_point(&self, col: usize, row: usize) -> Point {
        let term = self.term.lock();
        let grid = term.grid();
        Point::new(
            viewport_line(
                row.min(grid.screen_lines().saturating_sub(1)),
                grid.display_offset(),
            ),
            Column(col.min(grid.columns().saturating_sub(1))),
        )
    }
}

impl Drop for ProgramaTerminalSession {
    fn drop(&mut self) {
        let _ = self
            .notifier
            .0
            .send(alacritty_terminal::event_loop::Msg::Shutdown);
        if let Some(thread) = lock(&self.io_thread).take() {
            // The shutdown message wakes Alacritty's poller immediately. Join
            // away from the UI thread so a slow child/ConPTY teardown cannot
            // stall tab or window close, while still owning cleanup to completion.
            let _ = std::thread::Builder::new()
                .name("terminal shutdown".to_owned())
                .spawn(move || {
                    let _ = thread.join();
                });
        }
    }
}

/// A ConPTY in this process, and its shell's process id.
fn local_pty(config: &CreateConfig, size: TermSize) -> Result<(tty::Pty, u32), String> {
    let (shell_path, args) = match config.shell.clone() {
        Some(shell) => (shell, config.args.clone()),
        None => default_shell(config.args.clone(), config.shell_integration),
    };
    let mut env = config.env.clone();
    // Same terminal identity as the macOS app (TerminalSurface.managedTerminalProgram), so
    // agents take their Ghostty paths: truecolor, kitty keyboard, Shift+Enter.
    for (key, value) in [
        ("TERM", "xterm-256color"),
        ("COLORTERM", "truecolor"),
        ("TERM_PROGRAM", "ghostty"),
    ] {
        env.entry(key.to_owned())
            .or_insert_with(|| value.to_owned());
    }
    let mut options = PtyOptions::default();
    options.shell = Some(Shell::new(shell_path, args));
    options.working_directory = config
        .working_directory
        .clone()
        .map(Into::into)
        .or_else(home_directory);
    options.drain_on_exit = true;
    options.env = env;
    let pty = tty::new(&options, size.window_size(), 0).map_err(|error| error.to_string())?;
    // The shell process, so the frontend can tell whether something is running in it.
    #[cfg(windows)]
    let shell_pid = pty
        .child_watcher()
        .pid()
        .map_or(0, std::num::NonZeroU32::get);
    #[cfg(not(windows))]
    let shell_pid = 0u32;
    Ok((pty, shell_pid))
}

/// The session `host.id` in the terminal host: reattached when it still runs there (sized to this
/// terminal, and with how many bytes of past output follow), else started there. The pty, the
/// shell's process id, the replay length, and whether it was reattached.
#[cfg(windows)]
fn remote_pty(
    host: &host::HostConfig,
    config: &CreateConfig,
    size: TermSize,
) -> std::io::Result<(tty::Pty, u32, u64, bool)> {
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE,
    };
    let (output, answer, attached) =
        match host::request(host, serde_json::json!({ "op": "attach", "id": host.id })) {
            Ok((output, answer)) => (output, answer, true),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let mut spawned = config.clone();
                spawned.host = None;
                spawned.restore_text = None;
                // The host was started by an earlier app: new shells get this app's environment.
                for (key, value) in std::env::vars() {
                    if !spawned
                        .env
                        .keys()
                        .any(|existing| existing.eq_ignore_ascii_case(&key))
                    {
                        spawned.env.insert(key, value);
                    }
                }
                let (output, answer) = host::request(
                    host,
                    serde_json::json!({ "op": "spawn", "id": host.id, "config": spawned }),
                )?;
                (output, answer, false)
            }
            Err(error) => return Err(error),
        };
    let pid = answer["pid"].as_u64().unwrap_or(0) as u32;
    let replay = answer["replay"].as_u64().unwrap_or(0);
    let (input, _) = host::request(host, serde_json::json!({ "op": "input", "id": host.id }))?;
    if attached {
        HostResize(host.clone()).on_resize(size.window_size());
    }
    let child = unsafe {
        OpenProcess(
            PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
            0,
            pid,
        )
    };
    if child.is_null() {
        return Err(std::io::Error::last_os_error());
    }
    let pty = tty::remote(
        output,
        input,
        child as _,
        Box::new(HostResize(host.clone())),
    )?;
    Ok((pty, pid, replay, attached))
}

/// Window size changes of a terminal whose ConPTY the host owns.
#[cfg(windows)]
struct HostResize(host::HostConfig);

#[cfg(windows)]
impl OnResize for HostResize {
    fn on_resize(&mut self, size: WindowSize) {
        let _ = host::request(
            &self.0,
            serde_json::json!({
                "op": "resize", "id": self.0.id, "cols": size.num_cols, "rows": size.num_lines,
                "cell_width": size.cell_width, "cell_height": size.cell_height,
            }),
        );
    }
}

#[derive(Serialize)]
struct Snapshot {
    generation: u64,
    columns: usize,
    rows: usize,
    display_offset: usize,
    cursor: CursorSnapshot,
    selection: Option<SelectionSnapshot>,
    cells: Vec<CellSnapshot>,
    terminated: bool,
    title: Option<String>,
}

#[derive(Serialize)]
struct CursorSnapshot {
    column: usize,
    row: usize,
    visible: bool,
    /// "block", "underline" or "beam", as the program set it with DECSCUSR.
    shape: &'static str,
}

#[derive(Serialize)]
struct SelectionSnapshot {
    start_column: usize,
    start_row: i32,
    end_column: usize,
    end_row: i32,
    block: bool,
}

#[derive(Serialize)]
struct CellSnapshot {
    column: usize,
    row: usize,
    text: String,
    width: u8,
    foreground: Rgba,
    explicit_foreground: bool,
    background: Rgba,
    explicit_background: bool,
    selected: bool,
    bold: bool,
    italic: bool,
    underline: bool,
    undercurl: bool,
    strikethrough: bool,
    /// SGR 2 (faint); drawn at half opacity like Ghostty's default `faint-opacity`.
    dim: bool,
}

#[derive(Clone, Copy, Serialize)]
struct Rgba {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
}

fn snapshot(session: &ProgramaTerminalSession) -> Snapshot {
    let term = session.term.lock();
    let grid = term.grid();
    let offset = grid.display_offset();
    let selection_range = term
        .selection
        .as_ref()
        .and_then(|selection| selection.to_range(&term));
    let selection = selection_range.map(|range| SelectionSnapshot {
        start_column: range.start.column.0,
        start_row: range.start.line.0 + offset as i32,
        end_column: range.end.column.0,
        end_row: range.end.line.0 + offset as i32,
        block: range.is_block,
    });
    let colors = *lock(&session.state.colors);
    let mut cells = Vec::with_capacity(grid.columns() * grid.screen_lines());
    for row in 0..grid.screen_lines() {
        let line = viewport_line(row, offset);
        for (column, cell) in grid[line].into_iter().enumerate() {
            let point = Point::new(line, Column(column));
            let spacer = cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER);
            let mut text = String::new();
            if !spacer {
                if cell.c != '\0' {
                    text.push(cell.c);
                }
                if let Some(extra) = cell.zerowidth() {
                    text.extend(extra);
                }
            }
            let mut foreground = colors.resolve(cell.fg, term.colors());
            let mut background = colors.resolve(cell.bg, term.colors());
            let inverse = cell.flags.contains(Flags::INVERSE);
            if inverse {
                std::mem::swap(&mut foreground, &mut background);
            }
            cells.push(CellSnapshot {
                column,
                row,
                text,
                width: if spacer {
                    0
                } else if cell.flags.contains(Flags::WIDE_CHAR) {
                    2
                } else {
                    1
                },
                foreground,
                explicit_foreground: inverse
                    || !matches!(cell.fg, Color::Named(NamedColor::Foreground)),
                background,
                explicit_background: inverse
                    || !matches!(cell.bg, Color::Named(NamedColor::Background)),
                selected: selection_range.is_some_and(|range| range.contains(point)),
                bold: cell.flags.contains(Flags::BOLD),
                italic: cell.flags.contains(Flags::ITALIC),
                underline: cell.flags.intersects(Flags::ALL_UNDERLINES),
                undercurl: cell.flags.contains(Flags::UNDERCURL),
                strikethrough: cell.flags.contains(Flags::STRIKEOUT),
                dim: cell.flags.contains(Flags::DIM),
            });
        }
    }
    let cursor_point = grid.cursor.point;
    Snapshot {
        generation: session.state.generation.load(Ordering::Acquire),
        columns: grid.columns(),
        rows: grid.screen_lines(),
        display_offset: offset,
        cursor: CursorSnapshot {
            column: cursor_point.column.0,
            row: cursor_point.line.0.max(0) as usize,
            visible: cursor_is_visible(offset, term.mode()),
            shape: match term.cursor_style().shape {
                CursorShape::Underline => "underline",
                CursorShape::Beam => "beam",
                _ => "block",
            },
        },
        selection,
        cells,
        terminated: session.state.terminated.load(Ordering::Acquire),
        title: lock(&session.state.title).clone(),
    }
}

/// The PowerShell integration (see the script), run after the profile with `-NoExit
/// -EncodedCommand`, which the script execution policy does not block.
#[cfg(windows)]
const POWERSHELL_INTEGRATION: &str = include_str!("powershell-integration.ps1");

#[cfg(windows)]
fn powershell_integration_args() -> Vec<String> {
    use base64::Engine;
    let utf16: Vec<u8> = POWERSHELL_INTEGRATION
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    vec![
        "-NoLogo".to_owned(),
        "-NoExit".to_owned(),
        "-EncodedCommand".to_owned(),
        base64::engine::general_purpose::STANDARD.encode(utf16),
    ]
}

/// PowerShell 7 when installed, then Windows PowerShell, then COMSPEC: the closest Windows
/// match to a macOS login shell. Default args only apply to a shell this function picked;
/// `integration` adds the shell integration to PowerShell.
fn default_shell(args: Vec<String>, integration: bool) -> (String, Vec<String>) {
    #[cfg(windows)]
    {
        let on_path = |name: &str| {
            std::env::var_os("PATH").and_then(|path| {
                std::env::split_paths(&path)
                    .map(|dir| dir.join(name))
                    .find(|candidate| candidate.is_file())
            })
        };
        let powershell = on_path("pwsh.exe").or_else(|| on_path("powershell.exe"));
        if let Some(path) = powershell {
            let args = match (args.is_empty(), integration) {
                (true, true) => powershell_integration_args(),
                (true, false) => vec!["-NoLogo".to_owned()],
                (false, _) => args,
            };
            return (path.to_string_lossy().into_owned(), args);
        }
        (
            std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_owned()),
            args,
        )
    }
    #[cfg(not(windows))]
    {
        let _ = integration;
        (
            std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned()),
            args,
        )
    }
}

/// Stable mode bits for `programa_terminal_mode`, independent of alacritty's TermMode layout.
const MODE_APP_CURSOR: u32 = 1;
const MODE_MOUSE_REPORTING: u32 = 1 << 1;
const MODE_FOCUS_EVENTS: u32 = 1 << 2;
const MODE_KITTY_DISAMBIGUATE: u32 = 1 << 3;
const MODE_ALT_SCREEN: u32 = 1 << 4;

fn mode_bits(mode: &TermMode) -> u32 {
    [
        (TermMode::APP_CURSOR, MODE_APP_CURSOR),
        (TermMode::MOUSE_MODE, MODE_MOUSE_REPORTING),
        (TermMode::FOCUS_IN_OUT, MODE_FOCUS_EVENTS),
        (TermMode::DISAMBIGUATE_ESC_CODES, MODE_KITTY_DISAMBIGUATE),
        (TermMode::ALT_SCREEN, MODE_ALT_SCREEN),
    ]
    .into_iter()
    .filter(|(flag, _)| mode.intersects(*flag))
    .fold(0, |bits, (_, bit)| bits | bit)
}

const MOUSE_PRESS: u32 = 0;
const MOUSE_RELEASE: u32 = 1;
const MOUSE_MOTION: u32 = 2;
const MOUSE_MOD_SHIFT: u32 = 1;
const MOUSE_MOD_ALT: u32 = 2;
const MOUSE_MOD_CTRL: u32 = 4;

/// xterm mouse report for the program's current mouse mode, or None when it is not listening.
/// `button` is 0 left, 1 middle, 2 right, 64 wheel up, 65 wheel down; `col`/`row` are 0-based.
fn mouse_report(
    mode: &TermMode,
    button: u32,
    action: u32,
    col: usize,
    row: usize,
    mods: u32,
) -> Option<Vec<u8>> {
    // Button 3 is "no button held", only meaningful for any-event motion (mode 1003).
    let valid = matches!(button, 0..=2 | 64 | 65) || (button == 3 && action == MOUSE_MOTION);
    if !valid || !mode.intersects(TermMode::MOUSE_MODE) {
        return None;
    }
    let motion_mode = if button == 3 {
        TermMode::MOUSE_MOTION
    } else {
        TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION
    };
    if action == MOUSE_MOTION && !mode.intersects(motion_mode) {
        return None;
    }
    let mut code = button;
    if action == MOUSE_MOTION {
        code += 32;
    }
    if mods & MOUSE_MOD_SHIFT != 0 {
        code += 4;
    }
    if mods & MOUSE_MOD_ALT != 0 {
        code += 8;
    }
    if mods & MOUSE_MOD_CTRL != 0 {
        code += 16;
    }
    let (x, y) = (col + 1, row + 1);
    if mode.contains(TermMode::SGR_MOUSE) {
        let suffix = if action == MOUSE_RELEASE { 'm' } else { 'M' };
        return Some(format!("\x1b[<{code};{x};{y}{suffix}").into_bytes());
    }
    // X10/normal encoding has no release button; it reports 3 instead.
    if action == MOUSE_RELEASE {
        code = (code & !3) | 3;
    }
    let mut out = b"\x1b[M".to_vec();
    out.push(32 + code as u8);
    for position in [x, y] {
        if mode.contains(TermMode::UTF8_MOUSE) {
            let value = char::from_u32(32 + position.min(2015) as u32)?;
            out.extend(value.to_string().as_bytes());
        } else {
            out.push((32 + position.min(223)) as u8);
        }
    }
    Some(out)
}

/// What a wheel step does: a mouse report when the program listens, arrow keys in an
/// alternate-screen program that allows alternate scroll, otherwise local scrollback.
enum Wheel {
    Report(Vec<u8>),
    Arrows(Vec<u8>),
    Scrollback(i32),
}

fn wheel_action(mode: &TermMode, lines: i32, col: usize, row: usize, mods: u32) -> Wheel {
    let steps = lines.unsigned_abs() as usize;
    let button = if lines > 0 { 64 } else { 65 };
    if let Some(report) = mouse_report(mode, button, MOUSE_PRESS, col, row, mods) {
        return Wheel::Report(report.repeat(steps));
    }
    if mode.contains(TermMode::ALT_SCREEN | TermMode::ALTERNATE_SCROLL) {
        let arrow = match (lines > 0, mode.contains(TermMode::APP_CURSOR)) {
            (true, true) => b"\x1bOA",
            (true, false) => b"\x1b[A",
            (false, true) => b"\x1bOB",
            (false, false) => b"\x1b[B",
        };
        return Wheel::Arrows(arrow.repeat(steps));
    }
    Wheel::Scrollback(lines)
}

fn home_directory() -> Option<std::path::PathBuf> {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(Into::into)
}

fn viewport_line(row: usize, display_offset: usize) -> Line {
    Line(row as i32 - display_offset as i32)
}

fn cursor_is_visible(display_offset: usize, mode: &TermMode) -> bool {
    display_offset == 0 && mode.contains(TermMode::SHOW_CURSOR)
}

/// Returns the view to the live screen; true when it had been scrolled back.
fn scroll_to_bottom<T: EventListener>(term: &mut Term<T>) -> bool {
    if term.grid().display_offset() == 0 {
        return false;
    }
    term.scroll_display(Scroll::Bottom);
    true
}

fn paste_bytes(data: &[u8], requested: bool, mode: &TermMode) -> Vec<u8> {
    let enabled = requested && mode.contains(TermMode::BRACKETED_PASTE);
    if !enabled {
        return data.to_vec();
    }
    // Inside a bracket the payload must not be able to end it early: drop every
    // C0 control byte except tab, CR and LF. That removes ESC, so an embedded
    // `ESC[201~` cannot close the bracket and inject terminal input.
    let mut output = Vec::with_capacity(data.len() + 12);
    output.extend_from_slice(b"\x1b[200~");
    output.extend(
        data.iter()
            .copied()
            .filter(|byte| !matches!(byte, 0x00..=0x08 | 0x0b | 0x0c | 0x0e..=0x1f)),
    );
    output.extend_from_slice(b"\x1b[201~");
    output
}

/// True when pasting `data` unbracketed could run commands the user did not
/// see: the program has not enabled bracketed paste and the text holds a line
/// break or another C0 control byte (tab excepted). Frontends confirm before
/// pasting such text.
fn paste_needs_confirmation(data: &[u8], mode: &TermMode) -> bool {
    !mode.contains(TermMode::BRACKETED_PASTE)
        && data
            .iter()
            .any(|byte| matches!(byte, 0x00..=0x08 | 0x0a..=0x1f | 0x7f))
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn xterm(index: u8) -> Rgba {
    const BASE: [(u8, u8, u8); 16] = [
        (29, 31, 33),
        (204, 102, 102),
        (181, 189, 104),
        (240, 198, 116),
        (129, 162, 190),
        (178, 148, 187),
        (138, 190, 183),
        (197, 200, 198),
        (102, 102, 102),
        (213, 78, 83),
        (185, 202, 74),
        (231, 197, 71),
        (122, 166, 218),
        (195, 151, 216),
        (112, 192, 177),
        (234, 234, 234),
    ];
    let (r, g, b) = if index < 16 {
        BASE[index as usize]
    } else if index <= 231 {
        let value = u32::from(index) - 16;
        let scale = |part: u32| if part == 0 { 0 } else { (55 + part * 40) as u8 };
        (scale(value / 36), scale((value % 36) / 6), scale(value % 6))
    } else {
        let value = 8 + (u32::from(index) - 232) * 10;
        (value as u8, value as u8, value as u8)
    };
    Rgba { r, g, b, a: 255 }
}

unsafe fn bytes<'a>(data: *const u8, len: usize) -> Result<&'a [u8], i32> {
    if len == 0 {
        return Ok(&[]);
    }
    if data.is_null() || len > isize::MAX as usize {
        return Err(STATUS_INVALID_ARGUMENT);
    }
    Ok(slice::from_raw_parts(data, len))
}

unsafe fn session<'a>(
    value: *mut ProgramaTerminalSession,
) -> Result<&'a ProgramaTerminalSession, i32> {
    value.as_ref().ok_or(STATUS_INVALID_ARGUMENT)
}

fn set_buffer(out: *mut ProgramaTerminalBuffer, value: Vec<u8>) -> Result<(), i32> {
    if out.is_null() {
        return Err(STATUS_INVALID_ARGUMENT);
    }
    let boxed = value.into_boxed_slice();
    let len = boxed.len();
    let data = Box::into_raw(boxed) as *mut u8;
    unsafe {
        *out = ProgramaTerminalBuffer { data, len };
    }
    Ok(())
}

unsafe fn clear_buffer(out: *mut ProgramaTerminalBuffer) -> Result<(), i32> {
    if out.is_null() {
        return Err(STATUS_INVALID_ARGUMENT);
    }
    *out = ProgramaTerminalBuffer::default();
    Ok(())
}

fn ffi_status(operation: impl FnOnce() -> Result<(), i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(code)) => code,
        Err(_) => STATUS_FAILED,
    }
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_create(
    config: *const u8,
    config_len: usize,
    error: *mut ProgramaTerminalBuffer,
) -> *mut ProgramaTerminalSession {
    if !error.is_null() {
        *error = ProgramaTerminalBuffer::default();
    }
    match catch_unwind(AssertUnwindSafe(|| {
        let config = bytes(config, config_len).map_err(|_| "invalid config buffer".to_owned())?;
        let config = if config.is_empty() {
            CreateConfig::default()
        } else {
            serde_json::from_slice(config).map_err(|e| e.to_string())?
        };
        ProgramaTerminalSession::spawn(config)
    })) {
        Ok(Ok(value)) => Box::into_raw(Box::new(value)),
        Ok(Err(message)) => {
            let _ = set_buffer(error, message.into_bytes());
            ptr::null_mut()
        }
        Err(_) => {
            let _ = set_buffer(error, b"terminal initialization panicked".to_vec());
            ptr::null_mut()
        }
    }
}

/// Ends the shell when the terminal host runs it: the tab was closed, not the app. Freeing a
/// session only detaches from the host, so the shell keeps running across a quit.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_kill(value: *mut ProgramaTerminalSession) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        if let Some(host) = &value.host {
            let _ = host::request(host, serde_json::json!({ "op": "kill", "id": host.id }));
        }
        Ok(())
    })
}

/// Whether the terminal host runs this session's shell (so it survives the app).
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_is_hosted(value: *mut ProgramaTerminalSession) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        session(value).is_ok_and(|value| value.host.is_some())
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_free(value: *mut ProgramaTerminalSession) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !value.is_null() {
            drop(Box::from_raw(value));
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_write(
    value: *mut ProgramaTerminalSession,
    data: *const u8,
    len: usize,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        let data = bytes(data, len)?;
        let scrolled = scroll_to_bottom(&mut value.term.lock());
        value.notifier.notify(Cow::Owned(data.to_vec()));
        if scrolled {
            value.state.changed();
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_resize(
    value: *mut ProgramaTerminalSession,
    cols: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
) -> i32 {
    ffi_status(|| {
        let size = validate_size(TermSize {
            cols: cols.into(),
            lines: rows.into(),
            cell_width,
            cell_height,
        })
        .map_err(|_| STATUS_INVALID_ARGUMENT)?;
        session(value)?.resize(size);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_scroll(
    value: *mut ProgramaTerminalSession,
    lines: i32,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        value.term.lock().scroll_display(Scroll::Delta(lines));
        value.state.changed();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_snapshot_json(
    value: *mut ProgramaTerminalSession,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        let encoded = serde_json::to_vec(&snapshot(session(value)?)).map_err(|_| STATUS_FAILED)?;
        set_buffer(out, encoded)
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_generation(value: *mut ProgramaTerminalSession) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        session(value)
            .map(|v| v.state.generation.load(Ordering::Acquire))
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_program_status_generation(
    value: *mut ProgramaTerminalSession,
) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        session(value)
            .map(|v| v.state.program_status_generation.load(Ordering::Acquire))
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`; `out` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_program_status_json(
    value: *mut ProgramaTerminalSession,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        let state = &session(value)?.state;
        let status = lock(&state.program_status);
        let generation = state.program_status_generation.load(Ordering::Acquire);
        let encoded =
            serde_json::to_vec(&status.store.snapshot(generation)).map_err(|_| STATUS_FAILED)?;
        drop(status);
        set_buffer(out, encoded)
    })
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_mode(value: *mut ProgramaTerminalSession) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        session(value)
            .map(|value| mode_bits(value.term.lock().mode()))
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_mouse(
    value: *mut ProgramaTerminalSession,
    button: u32,
    action: u32,
    col: usize,
    row: usize,
    mods: u32,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(value) = session(value) else {
            return false;
        };
        let mode = *value.term.lock().mode();
        match mouse_report(&mode, button, action, col, row, mods) {
            Some(report) => {
                value.notifier.notify(Cow::Owned(report));
                true
            }
            None => false,
        }
    }))
    .unwrap_or(false)
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_focus(
    value: *mut ProgramaTerminalSession,
    focused: bool,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        if value.term.lock().mode().contains(TermMode::FOCUS_IN_OUT) {
            let report: &[u8] = if focused { b"\x1b[I" } else { b"\x1b[O" };
            value.notifier.notify(Cow::Borrowed(report));
        }
        Ok(())
    })
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_wheel(
    value: *mut ProgramaTerminalSession,
    lines: i32,
    col: usize,
    row: usize,
    mods: u32,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        if lines == 0 {
            return Ok(());
        }
        let mut term = value.term.lock();
        let action = wheel_action(term.mode(), lines, col, row, mods);
        match action {
            Wheel::Report(bytes) | Wheel::Arrows(bytes) => {
                drop(term);
                value.notifier.notify(Cow::Owned(bytes));
            }
            Wheel::Scrollback(lines) => {
                term.scroll_display(Scroll::Delta(lines));
                drop(term);
                value.state.changed();
            }
        }
        Ok(())
    })
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`; `out` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_take_clipboard(
    value: *mut ProgramaTerminalSession,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        let text = lock(&session(value)?.state.clipboard).take();
        match text {
            Some(text) => set_buffer(out, text.into_bytes()),
            None => Ok(()),
        }
    })
}

/// The last `max_lines` lines of output, scrollback included, as plain text: soft-wrapped lines
/// joined and trailing blanks trimmed. Session restore saves it.
fn output_text<T>(term: &Term<T>, max_lines: usize) -> String {
    // Count back from the last line with text, not from the blank rows under the prompt.
    let mut bottom = term.bottommost_line();
    while bottom > term.topmost_line() && term.grid()[bottom].is_clear() {
        bottom -= 1;
    }
    let wanted = Line(bottom.0 - (max_lines.max(1) as i32 - 1));
    let top = wanted.max(term.topmost_line());
    term.bounds_to_string(
        Point::new(top, Column(0)),
        Point::new(bottom, term.last_column()),
    )
    .trim_end()
    .to_owned()
}

/// The most text a restore replays, so a damaged session file cannot stall startup.
const MAX_RESTORE_BYTES: usize = 1 << 20;

/// Replays saved output as scrollback: the lines are written, then the screen is erased, which
/// on the main screen moves them into history, and the cursor goes home for the new shell.
fn restore_output<T: EventListener>(term: &mut Term<T>, text: &str) {
    let start = text.len().saturating_sub(MAX_RESTORE_BYTES);
    let start = (start..=text.len())
        .find(|&index| text.is_char_boundary(index))
        .unwrap_or(text.len());
    let mut bytes = Vec::with_capacity(text.len() - start + 16);
    for line in text[start..].lines() {
        bytes.extend(
            line.chars()
                .filter(|c| !c.is_control())
                .collect::<String>()
                .as_bytes(),
        );
        bytes.extend_from_slice(b"\r\n");
    }
    bytes.extend_from_slice(b"\x1b[2J\x1b[H");
    alacritty_terminal::vte::ansi::Processor::<alacritty_terminal::vte::ansi::StdSyncHandler>::new(
    )
    .advance(term, &bytes);
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`; `out` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_text(
    value: *mut ProgramaTerminalSession,
    max_lines: u32,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        let text = output_text(&*session(value)?.term.lock(), max_lines as usize);
        set_buffer(out, text.into_bytes())
    })
}

/// Escapes `text` so the regex search matches it literally.
fn literal_pattern(text: &str) -> String {
    let mut pattern = String::with_capacity(text.len() * 2);
    for character in text.chars() {
        if "\\.+*?()|[]{}^$#&-~".contains(character) {
            pattern.push('\\');
        }
        pattern.push(character);
    }
    pattern
}

/// Selects the next match of `text` (literal, smart case: case-insensitive unless it has an
/// uppercase letter) after the current selection (`forward`) or before it, starting from the
/// bottom of the screen (backward) or the top of scrollback (forward) when nothing is selected.
fn find<T: EventListener>(term: &mut Term<T>, text: &str, forward: bool) -> bool {
    use alacritty_terminal::index::{Boundary, Direction};
    use alacritty_terminal::term::search::RegexSearch;
    let Ok(mut regex) = RegexSearch::new(&literal_pattern(text)) else {
        return false;
    };
    let range = term
        .selection
        .as_ref()
        .and_then(|selection| selection.to_range(term));
    let (origin, direction, side) = match (range, forward) {
        (Some(range), true) => (
            range.end.add(term, Boundary::None, 1),
            Direction::Right,
            Side::Left,
        ),
        (Some(range), false) => (
            range.start.sub(term, Boundary::None, 1),
            Direction::Left,
            Side::Right,
        ),
        (None, true) => (
            Point::new(term.topmost_line(), Column(0)),
            Direction::Right,
            Side::Left,
        ),
        (None, false) => (
            Point::new(term.bottommost_line(), term.last_column()),
            Direction::Left,
            Side::Right,
        ),
    };
    let Some(found) = term.search_next(&mut regex, origin, direction, side, None) else {
        return false;
    };
    let mut selection = Selection::new(SelectionType::Simple, *found.start(), Side::Left);
    selection.update(*found.end(), Side::Right);
    term.selection = Some(selection);
    term.scroll_to_point(*found.start());
    true
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`; `text` points to `len`
/// readable UTF-8 bytes.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_find(
    value: *mut ProgramaTerminalSession,
    text: *const u8,
    len: usize,
    forward: bool,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let (Ok(value), Ok(text)) = (session(value), bytes(text, len)) else {
            return false;
        };
        let Ok(text) = std::str::from_utf8(text) else {
            return false;
        };
        if text.is_empty() {
            return false;
        }
        let found = find(&mut value.term.lock(), text, forward);
        value.state.changed();
        found
    }))
    .unwrap_or(false)
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_shell_pid(value: *mut ProgramaTerminalSession) -> u32 {
    catch_unwind(AssertUnwindSafe(|| {
        session(value).map(|v| v.shell_pid).unwrap_or(0)
    }))
    .unwrap_or(0)
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_cwd_generation(
    value: *mut ProgramaTerminalSession,
) -> u64 {
    catch_unwind(AssertUnwindSafe(|| {
        session(value)
            .map(|v| v.state.cwd_generation.load(Ordering::Acquire))
            .unwrap_or(0)
    }))
    .unwrap_or(0)
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`; `out` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_cwd(
    value: *mut ProgramaTerminalSession,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        match lock(&session(value)?.state.cwd).clone() {
            Some(cwd) => set_buffer(out, cwd.into_bytes()),
            None => Ok(()),
        }
    })
}

/// The OSC 8 hyperlink of the visible cell at (`column`, `row`), if it has one.
fn link_at<T>(term: &Term<T>, column: usize, row: usize) -> Option<String> {
    let grid = term.grid();
    if row >= grid.screen_lines() || column >= grid.columns() {
        return None;
    }
    let line = Line(row as i32 - grid.display_offset() as i32);
    grid[line][Column(column)]
        .hyperlink()
        .map(|link| link.uri().to_owned())
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`; `out` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_link_at(
    value: *mut ProgramaTerminalSession,
    column: usize,
    row: usize,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        let link = link_at(&session(value)?.term.lock(), column, row);
        match link {
            Some(uri) => set_buffer(out, uri.into_bytes()),
            None => Ok(()),
        }
    })
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_selection_clear(
    value: *mut ProgramaTerminalSession,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        value.term.lock().selection = None;
        value.state.changed();
        Ok(())
    })
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_clear_scrollback(
    value: *mut ProgramaTerminalSession,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        value.term.lock().grid_mut().clear_history();
        value.state.changed();
        Ok(())
    })
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`; `out` is null or writable.
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_take_notifications(
    value: *mut ProgramaTerminalSession,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        let pending = std::mem::take(&mut *lock(&session(value)?.state.notifications));
        if pending.is_empty() {
            return Ok(());
        }
        set_buffer(
            out,
            serde_json::to_vec(&pending).map_err(|_| STATUS_FAILED)?,
        )
    })
}

/// # Safety
///
/// `value` is null or a live handle from `programa_terminal_create`; `colors` points to
/// `len` readable bytes of a JSON colors object (see the create config).
#[no_mangle]
pub unsafe extern "C" fn programa_terminal_set_colors(
    value: *mut ProgramaTerminalSession,
    colors: *const u8,
    len: usize,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        let config: ColorsConfig =
            serde_json::from_slice(bytes(colors, len)?).map_err(|_| STATUS_INVALID_ARGUMENT)?;
        *lock(&value.state.colors) = config.resolve();
        value.state.changed();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_event_handle(
    value: *mut ProgramaTerminalSession,
) -> *mut c_void {
    catch_unwind(AssertUnwindSafe(|| {
        session(value)
            .map(|v| v.state.signal.raw())
            .unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_acknowledge_generation(
    value: *mut ProgramaTerminalSession,
    generation: u64,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        value.state.signal.reset();
        if value.state.generation.load(Ordering::Acquire) != generation {
            value.state.signal.set();
        }
        Ok(())
    })
}

fn selection_type(mode: u32) -> Result<SelectionType, i32> {
    match mode {
        0 => Ok(SelectionType::Simple),
        1 => Ok(SelectionType::Block),
        2 => Ok(SelectionType::Semantic),
        3 => Ok(SelectionType::Lines),
        _ => Err(STATUS_INVALID_ARGUMENT),
    }
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_selection_begin(
    value: *mut ProgramaTerminalSession,
    col: usize,
    row: usize,
    mode: u32,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        let point = value.display_point(col, row);
        value.term.lock().selection =
            Some(Selection::new(selection_type(mode)?, point, Side::Left));
        value.state.changed();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_selection_update(
    value: *mut ProgramaTerminalSession,
    col: usize,
    row: usize,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        let point = value.display_point(col, row);
        if let Some(selection) = value.term.lock().selection.as_mut() {
            selection.update(point, Side::Right);
        }
        value.state.changed();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_selection_end(
    value: *mut ProgramaTerminalSession,
) -> i32 {
    ffi_status(|| {
        let _ = session(value)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_copy_selection(
    value: *mut ProgramaTerminalSession,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        let text = session(value)?
            .term
            .lock()
            .selection_to_string()
            .unwrap_or_default();
        set_buffer(out, text.into_bytes())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_paste(
    value: *mut ProgramaTerminalSession,
    data: *const u8,
    len: usize,
    bracketed: bool,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        let data = bytes(data, len)?;
        let mut term = value.term.lock();
        let output = paste_bytes(data, bracketed, term.mode());
        let scrolled = scroll_to_bottom(&mut term);
        drop(term);
        value.notifier.notify(Cow::Owned(output));
        if scrolled {
            value.state.changed();
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_paste_needs_confirmation(
    value: *mut ProgramaTerminalSession,
    data: *const u8,
    len: usize,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(value) = session(value) else {
            return false;
        };
        let Ok(data) = bytes(data, len) else {
            return false;
        };
        let mode = *value.term.lock().mode();
        paste_needs_confirmation(data, &mode)
    }))
    .unwrap_or(false)
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_is_terminated(
    value: *mut ProgramaTerminalSession,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        session(value)
            .map(|v| v.state.terminated.load(Ordering::Acquire))
            .unwrap_or(true)
    }))
    .unwrap_or(true)
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_last_error(
    value: *mut ProgramaTerminalSession,
    out: *mut ProgramaTerminalBuffer,
) -> i32 {
    ffi_status(|| {
        clear_buffer(out)?;
        let message = lock(&session(value)?.state.error)
            .clone()
            .unwrap_or_default();
        set_buffer(out, message.into_bytes())
    })
}

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_buffer_free(data: *mut u8, len: usize) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !data.is_null() {
            drop(Box::from_raw(slice::from_raw_parts_mut(data, len)));
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::vte::ansi::{Processor, StdSyncHandler};
    use std::time::{Duration, Instant};

    fn term_with_state() -> (Term<EventProxy>, Arc<SharedState>) {
        let state = Arc::new(SharedState {
            generation: AtomicU64::new(0),
            terminated: AtomicBool::new(false),
            error: Mutex::new(None),
            title: Mutex::new(None),
            clipboard: Mutex::new(None),
            notifications: Mutex::new(Vec::new()),
            cwd: Mutex::new(None),
            cwd_generation: AtomicU64::new(0),
            colors: Mutex::new(Colors::default()),
            program_status: Mutex::new(ProgramStatus::default()),
            program_status_generation: AtomicU64::new(0),
            signal: Signal::new().unwrap(),
            sender: Mutex::new(None),
            tap: Mutex::new(None),
            quiet: false,
            replay: AtomicU64::new(0),
            muted: AtomicBool::new(false),
        });
        let config = TermConfig {
            kitty_keyboard: true,
            ..TermConfig::default()
        };
        let size = TermSize {
            cols: 8,
            lines: 3,
            cell_width: 8,
            cell_height: 16,
        };
        (Term::new(config, &size, EventProxy(state.clone())), state)
    }

    fn term() -> Term<EventProxy> {
        term_with_state().0
    }

    fn feed(term: &mut Term<EventProxy>, bytes: &[u8]) {
        Processor::<StdSyncHandler>::new().advance(term, bytes);
    }

    #[test]
    fn mode_bits_track_what_programs_enable() {
        let mut term = term();
        assert_eq!(mode_bits(term.mode()), 0);
        // Kitty flags are per screen, so push after entering the alternate screen.
        feed(
            &mut term,
            b"\x1b[?1h\x1b[?1000h\x1b[?1004h\x1b[?1049h\x1b[>1u",
        );
        assert_eq!(
            mode_bits(term.mode()),
            MODE_APP_CURSOR
                | MODE_MOUSE_REPORTING
                | MODE_FOCUS_EVENTS
                | MODE_KITTY_DISAMBIGUATE
                | MODE_ALT_SCREEN
        );
        feed(&mut term, b"\x1b[<u\x1b[?1000l");
        assert_eq!(
            mode_bits(term.mode()) & (MODE_KITTY_DISAMBIGUATE | MODE_MOUSE_REPORTING),
            0
        );
    }

    #[test]
    fn osc8_links_are_found_by_cell() {
        let (mut term, _) = term_with_state();
        feed(
            &mut term,
            b"see \x1b]8;;https://example.com/a\x1b\\here\x1b]8;;\x1b\\ now",
        );
        assert_eq!(
            link_at(&term, 4, 0).as_deref(),
            Some("https://example.com/a")
        );
        assert_eq!(
            link_at(&term, 7, 0).as_deref(),
            Some("https://example.com/a")
        );
        assert_eq!(link_at(&term, 0, 0), None);
        assert_eq!(link_at(&term, 9, 0), None);
        assert_eq!(link_at(&term, 500, 0), None);
    }

    #[test]
    fn find_walks_matches_from_the_bottom_and_back() {
        let (mut term, _) = term_with_state();
        // Three lines on an 8x3 screen: "foo a", "x.y foo", "Foo b".
        feed(&mut term, b"foo a\r\nx.y foo\r\nFoo b");
        let selected = |term: &Term<EventProxy>| term.selection_to_string().unwrap_or_default();
        let start_line = |term: &Term<EventProxy>| {
            term.selection
                .as_ref()
                .unwrap()
                .to_range(term)
                .unwrap()
                .start
                .line
                .0
        };

        // Backward from the bottom: the newest match first; lowercase is case-insensitive.
        assert!(find(&mut term, "foo", false));
        assert_eq!((selected(&term), start_line(&term)), ("Foo".into(), 2));
        assert!(find(&mut term, "foo", false));
        assert_eq!(start_line(&term), 1);
        assert!(find(&mut term, "foo", true));
        assert_eq!(start_line(&term), 2);

        // An uppercase letter makes it case-sensitive, and regex characters are literal.
        term.selection = None;
        assert!(find(&mut term, "Foo", false));
        assert_eq!(start_line(&term), 2);
        assert!(find(&mut term, "x.y", false));
        assert_eq!(selected(&term), "x.y");
        assert!(!find(&mut term, "missing", false));
    }

    #[test]
    fn saved_output_restores_as_scrollback_above_an_empty_screen() {
        let (mut term, _) = term_with_state();
        feed(&mut term, b"one\r\ntwo\r\nthree\r\nfour\r\n");
        let saved = output_text(&term, 1000);
        assert_eq!(saved, "one\ntwo\nthree\nfour");
        // The blank row under the cursor does not count.
        assert_eq!(output_text(&term, 2), "three\nfour");

        let (mut restored, _) = term_with_state();
        // Escape bytes in a damaged session file are dropped, not interpreted.
        restore_output(&mut restored, &format!("{saved}\n\x1b[31mred"));
        assert_eq!(
            output_text(&restored, 1000),
            "one\ntwo\nthree\nfour\n[31mred"
        );
        // The screen is empty and the cursor home, so the new shell starts at the top.
        let screen = restored.bounds_to_string(
            Point::new(Line(0), Column(0)),
            Point::new(Line(2), restored.last_column()),
        );
        assert_eq!(screen.trim(), "");
        assert_eq!(restored.grid().cursor.point, Point::new(Line(0), Column(0)));
    }

    #[test]
    fn osc52_store_reaches_the_frontend_clipboard() {
        let (mut term, state) = term_with_state();
        feed(&mut term, b"\x1b]52;c;aGVsbG8=\x07");
        assert_eq!(lock(&state.clipboard).as_deref(), Some("hello"));
    }

    #[test]
    fn colors_default_to_ghostty_and_take_theme_overrides() {
        let rgb = |color: Rgba| (color.r, color.g, color.b);
        let defaults = Colors::default();
        assert_eq!(rgb(defaults.query(257)), (0x28, 0x2C, 0x34));
        assert_eq!(rgb(defaults.query(256)), (0xFF, 0xFF, 0xFF));
        assert_eq!(rgb(defaults.query(1)), (0xCC, 0x66, 0x66));

        let theme: ColorsConfig = serde_json::from_str(
            r#"{"palette":{"1":[1,2,3]},"foreground":[9,9,9],"background":[7,7,7]}"#,
        )
        .unwrap();
        let colors = theme.resolve();
        assert_eq!(rgb(colors.query(1)), (1, 2, 3));
        assert_eq!(rgb(colors.query(257)), (7, 7, 7));
        // An unset cursor follows the foreground, as in Ghostty.
        assert_eq!(rgb(colors.query(258)), (9, 9, 9));
    }

    #[test]
    fn cells_prefer_colors_the_program_set() {
        let (mut term, _) = term_with_state();
        let colors = Colors::default();
        let red = Color::Named(NamedColor::Red);
        assert_eq!(colors.resolve(red, term.colors()).r, 0xCC);
        // OSC 4 sets palette entry 1; the program's choice wins over the theme.
        feed(&mut term, b"\x1b]4;1;rgb:12/34/56\x07");
        let resolved = colors.resolve(red, term.colors());
        assert_eq!((resolved.r, resolved.g, resolved.b), (0x12, 0x34, 0x56));
    }

    #[test]
    fn mouse_reports_follow_the_requested_encoding() {
        let none = TermMode::empty();
        assert_eq!(mouse_report(&none, 0, MOUSE_PRESS, 0, 0, 0), None);

        let sgr = TermMode::MOUSE_REPORT_CLICK | TermMode::SGR_MOUSE;
        let report = |mode, button, action, mods| {
            String::from_utf8(mouse_report(&mode, button, action, 9, 4, mods).unwrap()).unwrap()
        };
        assert_eq!(report(sgr, 0, MOUSE_PRESS, 0), "\x1b[<0;10;5M");
        assert_eq!(report(sgr, 0, MOUSE_RELEASE, 0), "\x1b[<0;10;5m");
        assert_eq!(
            report(sgr, 2, MOUSE_PRESS, MOUSE_MOD_CTRL | MOUSE_MOD_SHIFT),
            "\x1b[<22;10;5M"
        );
        // Click-only tracking ignores motion; drag tracking reports it with +32.
        assert_eq!(mouse_report(&sgr, 0, MOUSE_MOTION, 9, 4, 0), None);
        let drag = sgr | TermMode::MOUSE_DRAG;
        assert_eq!(report(drag, 0, MOUSE_MOTION, 0), "\x1b[<32;10;5M");
        // Motion with no button only in any-event mode.
        assert_eq!(mouse_report(&drag, 3, MOUSE_MOTION, 9, 4, 0), None);
        assert_eq!(
            report(sgr | TermMode::MOUSE_MOTION, 3, MOUSE_MOTION, 0),
            "\x1b[<35;10;5M"
        );

        let x10 = TermMode::MOUSE_REPORT_CLICK;
        assert_eq!(
            mouse_report(&x10, 0, MOUSE_RELEASE, 9, 4, 0).unwrap(),
            b"\x1b[M#*%"
        );
    }

    #[test]
    fn wheel_reports_scrolls_or_sends_arrows_by_mode() {
        let normal = TermMode::ALTERNATE_SCROLL;
        assert!(matches!(
            wheel_action(&normal, 3, 0, 0, 0),
            Wheel::Scrollback(3)
        ));

        let alt = TermMode::ALT_SCREEN | TermMode::ALTERNATE_SCROLL;
        let Wheel::Arrows(bytes) = wheel_action(&alt, -2, 0, 0, 0) else {
            panic!("expected arrows")
        };
        assert_eq!(bytes, b"\x1b[B\x1b[B");
        let Wheel::Arrows(bytes) = wheel_action(&(alt | TermMode::APP_CURSOR), 1, 0, 0, 0) else {
            panic!("expected arrows")
        };
        assert_eq!(bytes, b"\x1bOA");

        let mouse = alt | TermMode::MOUSE_REPORT_CLICK | TermMode::SGR_MOUSE;
        let Wheel::Report(bytes) = wheel_action(&mouse, 2, 0, 0, 0) else {
            panic!("expected a report")
        };
        assert_eq!(bytes, b"\x1b[<64;1;1M\x1b[<64;1;1M");
    }

    #[test]
    fn ansi_inverse_and_combining_cells_are_preserved() {
        let mut term = term();
        let mut parser = Processor::<StdSyncHandler>::new();
        parser.advance(&mut term, b"\x1b[31;47mA\x1b[7mB\x1b[0me\xcc\x81");
        let grid = term.grid();
        assert_eq!(grid[Line(0)][Column(2)].zerowidth(), Some(&['\u{301}'][..]));
        assert!(grid[Line(0)][Column(1)].flags.contains(Flags::INVERSE));
    }

    #[test]
    fn selection_copy_uses_terminal_semantics() {
        let mut term = term();
        let mut parser = Processor::<StdSyncHandler>::new();
        parser.advance(&mut term, b"hello");
        let mut selection = Selection::new(
            SelectionType::Simple,
            Point::new(Line(0), Column(0)),
            Side::Left,
        );
        selection.update(Point::new(Line(0), Column(4)), Side::Right);
        term.selection = Some(selection);
        assert_eq!(term.selection_to_string().as_deref(), Some("hello"));
    }

    #[test]
    fn scrollback_coordinates_hide_the_live_cursor() {
        let mut mode = TermMode::SHOW_CURSOR;
        assert_eq!(viewport_line(0, 3), Line(-3));
        assert!(!cursor_is_visible(3, &mode));
        assert!(cursor_is_visible(0, &mode));
        mode.remove(TermMode::SHOW_CURSOR);
        assert!(!cursor_is_visible(0, &mode));
    }

    #[test]
    fn bracketed_paste_wraps_only_when_the_terminal_requests_it() {
        assert_eq!(paste_bytes(b"hello", true, &TermMode::empty()), b"hello");
        assert_eq!(
            paste_bytes(b"hello", true, &TermMode::BRACKETED_PASTE),
            b"\x1b[200~hello\x1b[201~"
        );
    }

    #[test]
    fn bracketed_paste_cannot_end_the_bracket_early() {
        let out = paste_bytes(
            b"a\x1b[201~rm -rf /\nb\tc\x03",
            true,
            &TermMode::BRACKETED_PASTE,
        );
        assert_eq!(out, b"\x1b[200~a[201~rm -rf /\nb\tc\x1b[201~");
        assert_eq!(out.windows(6).filter(|w| *w == b"\x1b[201~").count(), 1);
    }

    #[test]
    fn unbracketed_multi_line_or_control_paste_needs_confirmation() {
        let plain = TermMode::empty();
        assert!(!paste_needs_confirmation(b"echo hello", &plain));
        assert!(!paste_needs_confirmation(b"a\tb", &plain));
        assert!(!paste_needs_confirmation(b"", &plain));
        assert!(paste_needs_confirmation(b"dir\r\ndel /q *\r\n", &plain));
        assert!(paste_needs_confirmation(b"ls\n", &plain));
        assert!(paste_needs_confirmation(b"a\x1b[201~b", &plain));
        assert!(paste_needs_confirmation(b"a\x7fb", &plain));
        assert!(!paste_needs_confirmation(
            b"dir\r\ndel /q *\r\n",
            &TermMode::BRACKETED_PASTE
        ));
    }

    #[test]
    fn dimensions_are_bounded_before_grid_allocation() {
        let size = |cols, lines| TermSize {
            cols,
            lines,
            cell_width: 8,
            cell_height: 16,
        };
        assert!(validate_size(size(1024, 1024)).is_ok());
        assert!(validate_size(size(1025, 1024)).is_err());
        assert!(validate_size(size(MAX_COLUMNS + 1, 24)).is_err());
    }

    #[cfg(any(unix, windows))]
    #[test]
    fn public_abi_drives_a_real_pty_through_exit() {
        const MARKER: &str = "programa-pty-lifecycle-7e3c";

        #[cfg(windows)]
        let config = serde_json::json!({
            "shell": "cmd.exe",
            "args": ["/D", "/Q"],
            "env": { "PROGRAMA_TEST_MARKER": MARKER },
            "cols": 80,
            "rows": 24
        });
        #[cfg(unix)]
        let config = serde_json::json!({
            "shell": "/bin/sh",
            "env": { "PROGRAMA_TEST_MARKER": MARKER },
            "cols": 80,
            "rows": 24
        });

        let config = serde_json::to_vec(&config).unwrap();
        let mut error = ProgramaTerminalBuffer::default();
        let raw = unsafe { programa_terminal_create(config.as_ptr(), config.len(), &mut error) };
        let error_text = take_buffer(error);
        assert!(!raw.is_null(), "PTY spawn failed: {error_text}");
        let session = SessionGuard(raw);

        assert_eq!(
            unsafe { programa_terminal_resize(session.0, 100, 30, 8, 16) },
            STATUS_OK
        );

        // The echoed command line holds the variable names, so only the expanded output
        // contains MARKER-ghostty: proof the session exported TERM_PROGRAM.
        #[cfg(windows)]
        let input = "echo %PROGRAMA_TEST_MARKER%-%TERM_PROGRAM%\r\nexit\r\n";
        #[cfg(unix)]
        let input = "echo \"$PROGRAMA_TEST_MARKER-$TERM_PROGRAM\"\nexit\n";
        assert_eq!(
            unsafe { programa_terminal_write(session.0, input.as_ptr(), input.len()) },
            STATUS_OK
        );

        let deadline = Instant::now() + Duration::from_secs(10);
        let mut marker_seen = false;
        let mut terminated = false;
        while Instant::now() < deadline && !(marker_seen && terminated) {
            let mut output = ProgramaTerminalBuffer::default();
            assert_eq!(
                unsafe { programa_terminal_snapshot_json(session.0, &mut output) },
                STATUS_OK
            );
            let snapshot: serde_json::Value =
                serde_json::from_slice(take_buffer(output).as_bytes()).unwrap();
            let visible_text = snapshot["cells"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|cell| cell["text"].as_str())
                .collect::<String>();
            marker_seen |= visible_text.contains(&format!("{MARKER}-ghostty"));
            terminated |= unsafe { programa_terminal_is_terminated(session.0) };
            if !(marker_seen && terminated) {
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        assert!(marker_seen, "PTY output never contained the marker");
        assert!(terminated, "PTY termination event was not observed");
    }

    /// A shell in the terminal host keeps running when the app's session goes (a quit), and the
    /// next session of that id shows its past output and drives it; a kill ends it.
    #[cfg(windows)]
    #[test]
    fn the_terminal_host_keeps_a_shell_running_across_a_detach() {
        let pipe = format!(r"\\.\pipe\programa-host-test-{}", std::process::id());
        let token = "test-token".to_owned();
        let (served_pipe, served_token) = (pipe.clone(), token.clone());
        std::thread::spawn(move || host::serve(&served_pipe, &served_token, None));
        let host_config = host::HostConfig {
            pipe: pipe.clone(),
            token,
            id: "surface-1".to_owned(),
        };
        let list = || {
            host::request(&host_config, serde_json::json!({ "op": "list" }))
                .map(|(_, answer)| answer["sessions"].clone())
        };
        let started = Instant::now();
        while list().is_err() && started.elapsed() < Duration::from_secs(5) {
            std::thread::sleep(Duration::from_millis(20));
        }
        let config = serde_json::to_vec(&serde_json::json!({
            "shell": "cmd.exe", "args": ["/D", "/Q"], "cols": 80, "rows": 24, "host": host_config,
        }))
        .unwrap();
        let open = || {
            let mut error = ProgramaTerminalBuffer::default();
            let raw =
                unsafe { programa_terminal_create(config.as_ptr(), config.len(), &mut error) };
            assert!(!raw.is_null(), "create failed: {}", take_buffer(error));
            SessionGuard(raw)
        };
        let shows = |session: &SessionGuard, text: &str| {
            let deadline = Instant::now() + Duration::from_secs(10);
            while Instant::now() < deadline {
                let mut output = ProgramaTerminalBuffer::default();
                unsafe { programa_terminal_snapshot_json(session.0, &mut output) };
                let snapshot: serde_json::Value =
                    serde_json::from_slice(take_buffer(output).as_bytes()).unwrap();
                let visible: String = snapshot["cells"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter_map(|cell| cell["text"].as_str())
                    .collect();
                if visible.contains(text) {
                    return true;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            false
        };
        let type_line = |session: &SessionGuard, line: &str| unsafe {
            programa_terminal_write(session.0, line.as_ptr(), line.len())
        };

        let first = open();
        type_line(&first, "echo first-%COMSPEC:~0,0%marker\r\n");
        assert!(
            shows(&first, "first-marker"),
            "the hosted shell never answered"
        );
        assert_eq!(list().unwrap()[0]["attached"], true);
        drop(first);
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(
            list().unwrap().as_array().unwrap().len(),
            1,
            "the shell outlives the app's session"
        );

        let second = open();
        assert!(
            shows(&second, "first-marker"),
            "a reattach shows the past output"
        );
        type_line(&second, "echo second-%COMSPEC:~0,0%marker\r\n");
        assert!(
            shows(&second, "second-marker"),
            "a reattached shell takes input"
        );
        unsafe { programa_terminal_kill(second.0) };
        assert!(
            list().unwrap().as_array().unwrap().is_empty(),
            "a kill ends the shell"
        );
    }

    /// The default PowerShell with the integration reports its working directory at the first
    /// prompt, which proves the encoded script runs despite the script execution policy.
    #[cfg(windows)]
    #[test]
    fn powershell_integration_reports_the_working_directory() {
        let directory = std::env::temp_dir();
        let directory = directory
            .to_string_lossy()
            .trim_end_matches('\\')
            .to_owned();
        let config = serde_json::to_vec(&serde_json::json!({
            "working_directory": directory,
            "shell_integration": true,
            "cols": 120,
            "rows": 30
        }))
        .unwrap();
        let mut error = ProgramaTerminalBuffer::default();
        let raw = unsafe { programa_terminal_create(config.as_ptr(), config.len(), &mut error) };
        assert!(!raw.is_null(), "PTY spawn failed: {}", take_buffer(error));
        let session = SessionGuard(raw);
        // The shell is a live process the frontend can inspect.
        let pid = unsafe { programa_terminal_shell_pid(session.0) };
        assert!(pid != 0 && pid != std::process::id());

        let deadline = Instant::now() + Duration::from_secs(30);
        let mut cwd = String::new();
        while Instant::now() < deadline {
            let mut out = ProgramaTerminalBuffer::default();
            assert_eq!(
                unsafe { programa_terminal_cwd(session.0, &mut out) },
                STATUS_OK
            );
            cwd = take_buffer(out);
            if !cwd.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(
            cwd.eq_ignore_ascii_case(&directory),
            "reported {cwd:?}, expected {directory:?}"
        );
        assert!(unsafe { programa_terminal_cwd_generation(session.0) } >= 1);
    }

    #[cfg(unix)]
    #[test]
    fn public_abi_reports_program_status_from_pty_output() {
        let config = serde_json::to_vec(&serde_json::json!({
            "shell": "/bin/sh",
            "cols": 80,
            "rows": 24
        }))
        .unwrap();
        let mut error = ProgramaTerminalBuffer::default();
        let raw = unsafe { programa_terminal_create(config.as_ptr(), config.len(), &mut error) };
        let error_text = take_buffer(error);
        assert!(!raw.is_null(), "PTY spawn failed: {error_text}");
        let session = SessionGuard(raw);
        assert_eq!(
            unsafe { programa_terminal_program_status_generation(session.0) },
            0
        );

        let input = "printf '\\033]7501;state=working:progress=40:app=cargo\\033\\\\'; \
                     printf '\\033]7501;state=done:id=a/b\\007'\n";
        assert_eq!(
            unsafe { programa_terminal_write(session.0, input.as_ptr(), input.len()) },
            STATUS_OK
        );

        let deadline = Instant::now() + Duration::from_secs(10);
        let mut status = serde_json::Value::Null;
        while Instant::now() < deadline {
            let mut output = ProgramaTerminalBuffer::default();
            assert_eq!(
                unsafe { programa_terminal_program_status_json(session.0, &mut output) },
                STATUS_OK
            );
            status = serde_json::from_slice(take_buffer(output).as_bytes()).unwrap();
            if status["children"].as_array().is_some_and(|c| !c.is_empty()) {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }

        assert_eq!(status["root"]["state"], "working", "{status}");
        assert_eq!(status["root"]["progress"], 40);
        assert_eq!(status["root"]["app"], "cargo");
        assert_eq!(status["children"][0]["id"], "a/b");
        assert_eq!(status["children"][0]["state"], "done");
        assert_eq!(status["children"][0]["app"], "cargo");
        // One bump per changed PTY read, and both reports can arrive in a single read.
        assert!(status["generation"].as_u64().unwrap() >= 1);
        assert_eq!(
            unsafe { programa_terminal_program_status_generation(session.0) },
            status["generation"].as_u64().unwrap()
        );
    }

    struct SessionGuard(*mut ProgramaTerminalSession);

    impl Drop for SessionGuard {
        fn drop(&mut self) {
            unsafe { programa_terminal_free(self.0) };
        }
    }

    fn take_buffer(buffer: ProgramaTerminalBuffer) -> String {
        if buffer.data.is_null() || buffer.len == 0 {
            return String::new();
        }
        let bytes = unsafe { slice::from_raw_parts(buffer.data, buffer.len) };
        let value = String::from_utf8(bytes.to_vec()).unwrap();
        unsafe { programa_terminal_buffer_free(buffer.data, buffer.len) };
        value
    }
}
