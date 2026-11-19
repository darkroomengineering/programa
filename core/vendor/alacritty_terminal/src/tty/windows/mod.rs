use std::ffi::OsStr;
use std::io::{self, Result};
use std::iter::once;
use std::os::windows::ffi::OsStrExt;
use std::sync::Arc;
use std::sync::mpsc::TryRecvError;

use crate::event::{OnResize, WindowSize};
use crate::tty::windows::child::ChildExitWatcher;
use crate::tty::{ChildEvent, EventedPty, EventedReadWrite, Options, Shell};

mod blocking;
mod child;
mod conpty;

use blocking::{UnblockedReader, UnblockedWriter};


use polling::{Event, Poller};

pub const PTY_CHILD_EVENT_TOKEN: usize = 1;
pub const PTY_READ_WRITE_TOKEN: usize = 2;

// Programa: boxed, so a pseudoconsole kept by another process (`remote`) can stand in for ConPTY.
type ReadPipe = UnblockedReader<Box<dyn io::Read + Send>>;
type WritePipe = UnblockedWriter<Box<dyn io::Write + Send>>;

/// The local pseudoconsole, or one another process owns, which this end resizes through `resize`.
pub enum Backend {
    Conpty(Backend0),
    Remote(Box<dyn OnResize + Send>),
}

type Backend0 = conpty::Conpty;

impl From<Backend0> for Backend {
    fn from(conpty: Backend0) -> Self {
        Backend::Conpty(conpty)
    }
}

impl OnResize for Backend {
    fn on_resize(&mut self, window_size: WindowSize) {
        match self {
            Backend::Conpty(conpty) => conpty.on_resize(window_size),
            Backend::Remote(remote) => remote.on_resize(window_size),
        }
    }
}

pub struct Pty {
    // XXX: Backend is required to be the first field, to ensure correct drop order. Dropping
    // `conout` before `backend` will cause a deadlock (with Conpty).
    backend: Backend,
    conout: ReadPipe,
    conin: WritePipe,
    child_watcher: ChildExitWatcher,
}

pub fn new(config: &Options, window_size: WindowSize, _window_id: u64) -> Result<Pty> {
    conpty::new(config, window_size)
}

/// Programa: a terminal whose pseudoconsole lives in another process. Output arrives on `conout`,
/// input leaves on `conin`, `resize` forwards window size changes, and `child` is the shell's
/// process handle (opened by this process), whose exit ends the terminal.
pub fn remote(
    conout: impl io::Read + Send + 'static,
    conin: impl io::Write + Send + 'static,
    child: windows_sys::Win32::Foundation::HANDLE,
    resize: Box<dyn OnResize + Send>,
) -> Result<Pty> {
    let conout: Box<dyn io::Read + Send> = Box::new(conout);
    let conin: Box<dyn io::Write + Send> = Box::new(conin);
    Ok(Pty::new(
        Backend::Remote(resize),
        UnblockedReader::new(conout, crate::event_loop::READ_BUFFER_SIZE),
        UnblockedWriter::new(conin, crate::event_loop::READ_BUFFER_SIZE),
        ChildExitWatcher::new(child)?,
    ))
}

impl Pty {
    fn new(
        backend: impl Into<Backend>,
        conout: impl Into<ReadPipe>,
        conin: impl Into<WritePipe>,
        child_watcher: ChildExitWatcher,
    ) -> Self {
        Self { backend: backend.into(), conout: conout.into(), conin: conin.into(), child_watcher }
    }

    pub fn child_watcher(&self) -> &ChildExitWatcher {
        &self.child_watcher
    }
}

fn with_key(mut event: Event, key: usize) -> Event {
    event.key = key;
    event
}

impl EventedReadWrite for Pty {
    type Reader = ReadPipe;
    type Writer = WritePipe;

    #[inline]
    unsafe fn register(
        &mut self,
        poll: &Arc<Poller>,
        interest: polling::Event,
        poll_opts: polling::PollMode,
    ) -> io::Result<()> {
        self.conin.register(poll, with_key(interest, PTY_READ_WRITE_TOKEN), poll_opts);
        self.conout.register(poll, with_key(interest, PTY_READ_WRITE_TOKEN), poll_opts);
        self.child_watcher.register(poll, with_key(interest, PTY_CHILD_EVENT_TOKEN));

        Ok(())
    }

    #[inline]
    fn reregister(
        &mut self,
        poll: &Arc<Poller>,
        interest: polling::Event,
        poll_opts: polling::PollMode,
    ) -> io::Result<()> {
        self.conin.register(poll, with_key(interest, PTY_READ_WRITE_TOKEN), poll_opts);
        self.conout.register(poll, with_key(interest, PTY_READ_WRITE_TOKEN), poll_opts);
        self.child_watcher.register(poll, with_key(interest, PTY_CHILD_EVENT_TOKEN));

        Ok(())
    }

    #[inline]
    fn deregister(&mut self, _poll: &Arc<Poller>) -> io::Result<()> {
        self.conin.deregister();
        self.conout.deregister();
        self.child_watcher.deregister();

        Ok(())
    }

    #[inline]
    fn reader(&mut self) -> &mut Self::Reader {
        &mut self.conout
    }

    #[inline]
    fn writer(&mut self) -> &mut Self::Writer {
        &mut self.conin
    }
}

impl EventedPty for Pty {
    fn next_child_event(&mut self) -> Option<ChildEvent> {
        match self.child_watcher.event_rx().try_recv() {
            Ok(ev) => Some(ev),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => Some(ChildEvent::Exited(None)),
        }
    }
}

impl OnResize for Pty {
    fn on_resize(&mut self, window_size: WindowSize) {
        self.backend.on_resize(window_size)
    }
}

// Modified per stdlib implementation.
// https://github.com/rust-lang/rust/blob/6707bf0f59485cf054ac1095725df43220e4be20/library/std/src/sys/args/windows.rs#L174
fn push_escaped_arg(cmd: &mut String, arg: &str) {
    let arg_bytes = arg.as_bytes();
    let quote = arg_bytes.iter().any(|c| *c == b' ' || *c == b'\t') || arg_bytes.is_empty();
    if quote {
        cmd.push('"');
    }

    let mut backslashes: usize = 0;
    for x in arg.chars() {
        if x == '\\' {
            backslashes += 1;
        } else {
            if x == '"' {
                // Add n+1 backslashes to total 2n+1 before internal '"'.
                cmd.extend((0..=backslashes).map(|_| '\\'));
            }
            backslashes = 0;
        }
        cmd.push(x);
    }

    if quote {
        // Add n backslashes to total 2n before ending '"'.
        cmd.extend((0..backslashes).map(|_| '\\'));
        cmd.push('"');
    }
}

fn cmdline(config: &Options) -> String {
    let default_shell = Shell::new("powershell".to_owned(), Vec::new());
    let shell = config.shell.as_ref().unwrap_or(&default_shell);

    let mut cmd = String::new();
    cmd.push_str(&shell.program);

    for arg in &shell.args {
        cmd.push(' ');
        if config.escape_args {
            push_escaped_arg(&mut cmd, arg);
        } else {
            cmd.push_str(arg)
        }
    }
    cmd
}

/// Converts the string slice into a Windows-standard representation for "W"-
/// suffixed function variants, which accept UTF-16 encoded string values.
pub fn win32_string<S: AsRef<OsStr> + ?Sized>(value: &S) -> Vec<u16> {
    OsStr::new(value).encode_wide().chain(once(0)).collect()
}

#[cfg(test)]
mod test {
    use crate::tty::windows::{cmdline, push_escaped_arg};
    use crate::tty::{Options, Shell};

    #[test]
    fn test_escape() {
        let test_set = vec![
            // Basic cases - no escaping needed
            ("abc", "abc"),
            // Cases requiring quotes (space/tab)
            ("", "\"\""),
            (" ", "\" \""),
            ("ab c", "\"ab c\""),
            ("ab\tc", "\"ab\tc\""),
            // Cases with backslashes only (no spaces, no quotes) - no quotes added
            ("ab\\c", "ab\\c"),
            // Cases with quotes only (no spaces) - quotes escaped but no outer quotes
            ("ab\"c", "ab\\\"c"),
            ("\"", "\\\""),
            ("a\"b\"c", "a\\\"b\\\"c"),
            // Cases requiring both quotes and escaping (contains spaces)
            ("ab \"c", "\"ab \\\"c\""),
            ("a \"b\" c", "\"a \\\"b\\\" c\""),
            // Complex real-world cases
            ("C:\\Program Files\\", "\"C:\\Program Files\\\\\""),
            ("C:\\Program Files\\a.txt", "\"C:\\Program Files\\a.txt\""),
            (
                r#"sh -c "cd /home/user; ARG='abc' \""'${SHELL:-sh}" -i -c '"'echo hello'""#,
                r#""sh -c \"cd /home/user; ARG='abc' \\\"\"'${SHELL:-sh}\" -i -c '\"'echo hello'\"""#,
            ),
        ];

        for (input, expected) in test_set {
            let mut escaped_arg = String::new();
            push_escaped_arg(&mut escaped_arg, input);
            assert_eq!(escaped_arg, expected, "Failed for input: {}", input);
        }
    }

    #[test]
    fn test_cmdline() {
        let mut options = Options {
            shell: Some(Shell {
                program: "echo".to_string(),
                args: vec!["hello world".to_string()],
            }),
            working_directory: None,
            drain_on_exit: true,
            env: Default::default(),
            escape_args: false,
        };
        assert_eq!(cmdline(&options), "echo hello world");

        options.escape_args = true;
        assert_eq!(cmdline(&options), "echo \"hello world\"");
    }
}
