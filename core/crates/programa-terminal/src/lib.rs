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
use alacritty_terminal::term::{Config as TermConfig, Term, TermMode};
use alacritty_terminal::tty::{self, Options as PtyOptions, Shell};
use alacritty_terminal::vte::ansi::{Color, NamedColor};
use serde::{Deserialize, Serialize};

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
    signal: Signal,
    sender: Mutex<Option<EventLoopSender>>,
}

impl SharedState {
    fn changed(&self) {
        self.generation.fetch_add(1, Ordering::Release);
        self.signal.set();
    }

    fn fail(&self, message: String) {
        *lock(&self.error) = Some(message);
        self.changed();
    }
}

#[derive(Clone)]
struct EventProxy(Arc<SharedState>);

impl EventListener for EventProxy {
    fn send_event(&self, event: Event) {
        match event {
            Event::Wakeup
            | Event::Title(_)
            | Event::ResetTitle
            | Event::CursorBlinkingChange
            | Event::MouseCursorDirty => self.0.changed(),
            Event::Exit | Event::ChildExit(_) => {
                self.0.terminated.store(true, Ordering::Release);
                self.0.changed();
            }
            Event::PtyWrite(text) => {
                if let Some(sender) = lock(&self.0.sender).as_ref() {
                    if let Err(error) = sender.send(Msg::Input(Cow::Owned(text.into_bytes()))) {
                        self.0.fail(error.to_string());
                    }
                }
            }
            _ => {}
        }
    }
}

#[derive(Deserialize, Default)]
struct CreateConfig {
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
}

pub struct ProgramaTerminalSession {
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
        let size = validate_size(TermSize {
            cols: usize::from(config.cols.unwrap_or(80).max(2)),
            lines: usize::from(config.rows.unwrap_or(24).max(2)),
            cell_width: config.cell_width.unwrap_or(8).max(1),
            cell_height: config.cell_height.unwrap_or(16).max(1),
        })?;
        let shell_path = config.shell.unwrap_or_else(default_shell);
        let mut env = config.env;
        env.entry("TERM".to_owned())
            .or_insert_with(|| "xterm-256color".to_owned());
        let mut options = PtyOptions::default();
        options.shell = Some(Shell::new(shell_path, config.args));
        options.working_directory = config
            .working_directory
            .map(Into::into)
            .or_else(home_directory);
        options.drain_on_exit = true;
        options.env = env;
        let pty = tty::new(&options, size.window_size(), 0).map_err(|error| error.to_string())?;
        let state = Arc::new(SharedState {
            generation: AtomicU64::new(1),
            terminated: AtomicBool::new(false),
            error: Mutex::new(None),
            signal: Signal::new()?,
            sender: Mutex::new(None),
        });
        let proxy = EventProxy(state.clone());
        let term = Arc::new(FairMutex::new(Term::new(
            TermConfig::default(),
            &size,
            proxy.clone(),
        )));
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
        })
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
}

#[derive(Serialize)]
struct CursorSnapshot {
    column: usize,
    row: usize,
    visible: bool,
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
            let mut foreground = resolve_color(cell.fg);
            let mut background = resolve_color(cell.bg);
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
        },
        selection,
        cells,
        terminated: session.state.terminated.load(Ordering::Acquire),
    }
}

fn default_shell() -> String {
    #[cfg(windows)]
    {
        std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".to_owned())
    }
    #[cfg(not(windows))]
    {
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned())
    }
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

fn paste_bytes(data: &[u8], requested: bool, mode: &TermMode) -> Vec<u8> {
    let enabled = requested && mode.contains(TermMode::BRACKETED_PASTE);
    let mut output = Vec::with_capacity(data.len() + if enabled { 12 } else { 0 });
    if enabled {
        output.extend_from_slice(b"\x1b[200~");
    }
    output.extend_from_slice(data);
    if enabled {
        output.extend_from_slice(b"\x1b[201~");
    }
    output
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

fn resolve_color(color: Color) -> Rgba {
    match color {
        Color::Spec(rgb) => Rgba {
            r: rgb.r,
            g: rgb.g,
            b: rgb.b,
            a: 255,
        },
        Color::Indexed(index) => xterm(index),
        Color::Named(name) => match name {
            NamedColor::Foreground => Rgba {
                r: 220,
                g: 220,
                b: 220,
                a: 255,
            },
            NamedColor::Background => Rgba {
                r: 20,
                g: 20,
                b: 24,
                a: 255,
            },
            NamedColor::Cursor | NamedColor::BrightForeground => Rgba {
                r: 255,
                g: 255,
                b: 255,
                a: 255,
            },
            NamedColor::DimForeground => Rgba {
                r: 150,
                g: 150,
                b: 150,
                a: 255,
            },
            NamedColor::Black | NamedColor::DimBlack => xterm(0),
            NamedColor::Red | NamedColor::DimRed => xterm(1),
            NamedColor::Green | NamedColor::DimGreen => xterm(2),
            NamedColor::Yellow | NamedColor::DimYellow => xterm(3),
            NamedColor::Blue | NamedColor::DimBlue => xterm(4),
            NamedColor::Magenta | NamedColor::DimMagenta => xterm(5),
            NamedColor::Cyan | NamedColor::DimCyan => xterm(6),
            NamedColor::White | NamedColor::DimWhite => xterm(7),
            NamedColor::BrightBlack => xterm(8),
            NamedColor::BrightRed => xterm(9),
            NamedColor::BrightGreen => xterm(10),
            NamedColor::BrightYellow => xterm(11),
            NamedColor::BrightBlue => xterm(12),
            NamedColor::BrightMagenta => xterm(13),
            NamedColor::BrightCyan => xterm(14),
            NamedColor::BrightWhite => xterm(15),
        },
    }
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

fn set_buffer(out: *mut ProgramaTerminalBuffer, value: Vec<u8>) -> i32 {
    if out.is_null() {
        return STATUS_INVALID_ARGUMENT;
    }
    let boxed = value.into_boxed_slice();
    let len = boxed.len();
    let data = Box::into_raw(boxed) as *mut u8;
    unsafe {
        *out = ProgramaTerminalBuffer { data, len };
    }
    STATUS_OK
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
        value.notifier.notify(Cow::Owned(data.to_vec()));
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
pub unsafe extern "C" fn programa_terminal_scroll_to_bottom(
    value: *mut ProgramaTerminalSession,
) -> i32 {
    ffi_status(|| {
        let value = session(value)?;
        value.term.lock().scroll_display(Scroll::Bottom);
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
        match set_buffer(out, encoded) {
            STATUS_OK => Ok(()),
            code => Err(code),
        }
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

#[no_mangle]
pub unsafe extern "C" fn programa_terminal_application_cursor(
    value: *mut ProgramaTerminalSession,
) -> bool {
    catch_unwind(AssertUnwindSafe(|| {
        session(value)
            .map(|value| value.term.lock().mode().contains(TermMode::APP_CURSOR))
            .unwrap_or(false)
    }))
    .unwrap_or(false)
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
        match set_buffer(out, text.into_bytes()) {
            STATUS_OK => Ok(()),
            code => Err(code),
        }
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
        let output = paste_bytes(data, bracketed, value.term.lock().mode());
        value.notifier.notify(Cow::Owned(output));
        Ok(())
    })
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
        match set_buffer(out, message.into_bytes()) {
            STATUS_OK => Ok(()),
            code => Err(code),
        }
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

    fn term() -> Term<EventProxy> {
        let state = Arc::new(SharedState {
            generation: AtomicU64::new(0),
            terminated: AtomicBool::new(false),
            error: Mutex::new(None),
            signal: Signal::new().unwrap(),
            sender: Mutex::new(None),
        });
        Term::new(
            TermConfig::default(),
            &TermSize {
                cols: 8,
                lines: 3,
                cell_width: 8,
                cell_height: 16,
            },
            EventProxy(state),
        )
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

        #[cfg(windows)]
        let input = "echo %PROGRAMA_TEST_MARKER%\r\nexit\r\n";
        #[cfg(unix)]
        let input = "echo \"$PROGRAMA_TEST_MARKER\"\nexit\n";
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
            marker_seen |= visible_text.contains(MARKER);
            terminated |= unsafe { programa_terminal_is_terminated(session.0) };
            if !(marker_seen && terminated) {
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        assert!(marker_seen, "PTY output never contained the marker");
        assert!(terminated, "PTY termination event was not observed");
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
