//! One request/response round trip over Programa's control endpoint: a named
//! pipe on Windows, a Unix domain socket elsewhere. Framing is the v2
//! protocol's: one JSON object per line in each direction.

use std::io::{self, BufRead, BufReader, Read, Write};

/// What `round_trip` can fail with. `NotRunning` means the endpoint could not
/// be opened at all, which the caller reports as "Programa is not running".
#[derive(Debug)]
pub enum TransportError {
    NotRunning,
    Io(io::Error),
}

/// The word the "not running" message uses for the endpoint.
#[cfg(windows)]
pub const ENDPOINT_KIND: &str = "pipe";
#[cfg(not(windows))]
pub const ENDPOINT_KIND: &str = "socket";

/// Connects to `path`, writes `request_line` plus a newline, and returns the
/// first line the server sends back (without its line terminator).
pub fn round_trip(path: &str, request_line: &str) -> Result<String, TransportError> {
    let stream = connect(path).map_err(|_| TransportError::NotRunning)?;
    exchange(stream, request_line).map_err(TransportError::Io)
}

/// Sends one request and hands every line the server sends after it to `on_line`
/// (without its terminator) until `on_line` returns false or the connection
/// ends: the long-lived read `watch-events` needs after `subscribe`.
// programa-mcp shares this module and never streams.
#[allow(dead_code)]
pub fn stream(
    path: &str,
    request_line: &str,
    mut on_line: impl FnMut(&str) -> bool,
) -> Result<(), TransportError> {
    let mut stream = connect(path).map_err(|_| TransportError::NotRunning)?;
    stream
        .write_all(format!("{request_line}\n").as_bytes())
        .and_then(|()| stream.flush())
        .map_err(TransportError::Io)?;
    let mut reader = BufReader::new(stream);
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader
            .read_until(b'\n', &mut line)
            .map_err(TransportError::Io)?
            == 0
        {
            return Ok(());
        }
        while matches!(line.last(), Some(b'\n' | b'\r')) {
            line.pop();
        }
        if !on_line(&String::from_utf8_lossy(&line)) {
            return Ok(());
        }
    }
}

/// Writes one framed request to `stream` and reads one framed response.
/// Generic over the stream so the framing is testable without a server.
pub fn exchange<S: Read + Write>(mut stream: S, request_line: &str) -> io::Result<String> {
    let mut frame = String::with_capacity(request_line.len() + 1);
    frame.push_str(request_line);
    frame.push('\n');
    stream.write_all(frame.as_bytes())?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    let mut line = Vec::new();
    reader.read_until(b'\n', &mut line)?;
    if line.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "connection closed before a response arrived",
        ));
    }
    while matches!(line.last(), Some(b'\n' | b'\r')) {
        line.pop();
    }
    String::from_utf8(line)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "response was not valid UTF-8"))
}

/// Opens the named pipe as a file. Every pipe instance may be busy serving
/// another client (ERROR_PIPE_BUSY); the server creates a fresh instance
/// right after accepting, so a short retry loop covers that window.
#[cfg(windows)]
fn connect(path: &str) -> io::Result<std::fs::File> {
    use std::os::windows::fs::OpenOptionsExt;

    const ERROR_PIPE_BUSY: i32 = 231;
    const MAX_RETRIES: u32 = 20;
    // A server at the configured pipe can identify this client without impersonating it.
    const SECURITY_IDENTIFICATION: u32 = 1 << 16;
    let mut retries = 0;
    loop {
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .security_qos_flags(SECURITY_IDENTIFICATION)
            .open(path)
        {
            Ok(file) => return Ok(file),
            Err(err) if err.raw_os_error() == Some(ERROR_PIPE_BUSY) && retries < MAX_RETRIES => {
                retries += 1;
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(err) => return Err(err),
        }
    }
}

#[cfg(unix)]
fn connect(path: &str) -> io::Result<std::os::unix::net::UnixStream> {
    std::os::unix::net::UnixStream::connect(path)
}

#[cfg(not(any(unix, windows)))]
fn connect(_path: &str) -> io::Result<std::fs::File> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "no Programa transport on this platform",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// A fake duplex stream: reads come from `input`, writes land in `output`.
    struct Duplex<'a> {
        input: Cursor<Vec<u8>>,
        output: &'a mut Vec<u8>,
    }

    impl Read for Duplex<'_> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.input.read(buf)
        }
    }

    impl Write for Duplex<'_> {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.output.write(buf)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn exchange_frames_request_and_reads_one_line() {
        let mut written = Vec::new();
        let stream = Duplex {
            input: Cursor::new(b"{\"id\":1,\"ok\":true,\"result\":{}}\r\n{\"extra\":1}\n".to_vec()),
            output: &mut written,
        };
        let response = exchange(stream, r#"{"id":1,"method":"system.ping"}"#).unwrap();
        assert_eq!(response, r#"{"id":1,"ok":true,"result":{}}"#);
        assert_eq!(written, b"{\"id\":1,\"method\":\"system.ping\"}\n");
    }

    #[test]
    fn exchange_reports_a_closed_connection() {
        let mut written = Vec::new();
        let stream = Duplex {
            input: Cursor::new(Vec::new()),
            output: &mut written,
        };
        let err = exchange(stream, "{}").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[cfg(windows)]
    #[test]
    fn missing_pipe_is_not_running() {
        let path = format!(r"\\.\pipe\programa-cli-test-missing-{}", std::process::id());
        assert!(matches!(
            round_trip(&path, "{}"),
            Err(TransportError::NotRunning)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn unix_socket_round_trip() {
        use std::os::unix::net::UnixListener;

        let dir = std::env::temp_dir().join(format!("programa-cli-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s.sock");
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut stream = stream;
            stream
                .write_all(b"{\"id\":1,\"ok\":true,\"result\":{\"pong\":true}}\n")
                .unwrap();
            line
        });
        let response = round_trip(path.to_str().unwrap(), r#"{"id":1}"#).unwrap();
        assert_eq!(response, r#"{"id":1,"ok":true,"result":{"pong":true}}"#);
        assert_eq!(server.join().unwrap(), "{\"id\":1}\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn missing_socket_is_not_running() {
        let path = std::env::temp_dir().join(format!(
            "programa-cli-test-missing-{}.sock",
            std::process::id()
        ));
        assert!(matches!(
            round_trip(path.to_str().unwrap(), "{}"),
            Err(TransportError::NotRunning)
        ));
    }
}
