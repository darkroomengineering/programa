//! `programad`: a headless daemon that owns PTYs, sessions, and a WAL for
//! Programa, speaking the v2 socket protocol. See `README.md` for the
//! method list and what this does not do yet.
//!
//! Unix-only: the daemon owns PTYs and hands off file descriptors over
//! `SCM_RIGHTS`, neither of which has a Windows equivalent (`core/ABI.md`
//! "Process layer"). The `unix` module below holds the real implementation;
//! on any other target the binary still links (so `cargo build --workspace`
//! and `cargo test --workspace` succeed on Windows CI) but only prints a
//! clear "not supported" message and exits.

#[cfg(unix)]
fn main() -> std::process::ExitCode {
    unix::main()
}

#[cfg(not(unix))]
fn main() -> std::process::ExitCode {
    eprintln!("programad is not supported on Windows yet");
    std::process::ExitCode::FAILURE
}

#[cfg(unix)]
mod unix {
    use std::fs::OpenOptions;
    use std::path::PathBuf;
    use std::process::ExitCode;

    use nix::fcntl::{Flock, FlockArg};

    struct Args {
        socket_path: Option<PathBuf>,
        password: Option<String>,
        keep_sessions: bool,
    }

    fn parse_args() -> Result<Args, String> {
        let mut args = Args {
            socket_path: None,
            password: std::env::var("PROGRAMAD_PASSWORD").ok(),
            keep_sessions: false,
        };
        let mut it = std::env::args().skip(1);
        while let Some(arg) = it.next() {
            match arg.as_str() {
                "--socket" => {
                    let v = it.next().ok_or("--socket requires a path")?;
                    args.socket_path = Some(PathBuf::from(v));
                }
                "--password-file" => {
                    let v = it.next().ok_or("--password-file requires a path")?;
                    let contents = std::fs::read_to_string(&v)
                        .map_err(|e| format!("failed to read --password-file {v}: {e}"))?;
                    args.password = Some(contents.trim_end_matches(['\n', '\r']).to_string());
                }
                "--keep-sessions" => {
                    return Err(
                        "--keep-sessions is unsupported: preserving PTYs across daemon exit requires a persistent fd keeper"
                            .to_string(),
                    );
                }
                "--help" | "-h" => {
                    print_help();
                    std::process::exit(0);
                }
                other => return Err(format!("unrecognized argument: {other}")),
            }
        }
        Ok(args)
    }

    fn print_help() {
        println!(
            "programad — headless PTY/session daemon for Programa\n\n\
             USAGE:\n    programad [OPTIONS]\n\n\
             OPTIONS:\n\
             \x20   --socket <path>         Unix socket path (default: $XDG_RUNTIME_DIR/programad.sock\n\
             \x20                           or ~/.local/state/programa/programad.sock)\n\
             \x20   --password-file <path>  Require auth.login with this password before any other\n\
             \x20                           method (default: no password required, matching local-only use)\n\
             \x20   --keep-sessions         Unsupported until a persistent fd keeper can preserve PTYs\n\
             \x20                           across daemon exit; passing it exits with an error.\n\
             \x20   --help                  Print this message\n"
        );
    }

    pub fn main() -> ExitCode {
        tracing_subscriber::fmt()
            .with_writer(std::io::stderr)
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
            )
            .init();

        let args = match parse_args() {
            Ok(a) => a,
            Err(e) => {
                eprintln!("programad: {e}");
                return ExitCode::FAILURE;
            }
        };

        let socket_path = match args
            .socket_path
            .clone()
            .map(Ok)
            .unwrap_or_else(programad::paths::socket_path)
        {
            Ok(p) => p,
            Err(e) => {
                eprintln!("programad: could not resolve socket path: {e}");
                return ExitCode::FAILURE;
            }
        };

        let Some(socket_parent) = socket_path.parent() else {
            eprintln!("programad: socket path has no parent directory");
            return ExitCode::FAILURE;
        };
        if let Err(error) = programad::paths::ensure_private_dir(socket_parent) {
            eprintln!("programad: unsafe socket directory: {error}");
            return ExitCode::FAILURE;
        }

        let _lock = match acquire_single_instance_lock(&socket_path) {
            Ok(lock) => lock,
            Err(e) => {
                eprintln!("programad: {e}");
                return ExitCode::FAILURE;
            }
        };

        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                eprintln!("programad: failed to start tokio runtime: {e}");
                return ExitCode::FAILURE;
            }
        };

        let keep_sessions = args.keep_sessions;
        let result = runtime.block_on(run(socket_path, args.password, keep_sessions));

        match result {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("programad: {e}");
                ExitCode::FAILURE
            }
        }
    }

    async fn run(
        socket_path: PathBuf,
        password: Option<String>,
        keep_sessions: bool,
    ) -> std::io::Result<()> {
        let config = programad::DaemonConfig {
            socket_path,
            password,
        };

        let shutdown = async {
            let mut sigterm =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("failed to install SIGTERM handler");
            let mut sigint =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())
                    .expect("failed to install SIGINT handler");
            tokio::select! {
                _ = sigterm.recv() => tracing::info!("received SIGTERM"),
                _ = sigint.recv() => tracing::info!("received SIGINT"),
            }
        };

        let state = programad::serve(config, shutdown).await?;

        let ids = state.sessions.ids();
        if !keep_sessions {
            tracing::info!(
                count = ids.len(),
                "terminating sessions (pass --keep-sessions to skip this)"
            );
            for id in ids {
                let _ = state.sessions.close(&id, true);
            }
        } else if !ids.is_empty() {
            tracing::warn!(
                count = ids.len(),
                "exiting with sessions left running; see --help for the fd-escrow caveat"
            );
        }
        Ok(())
    }

    struct InstanceLock {
        _flock: Flock<std::fs::File>,
    }

    fn acquire_single_instance_lock(socket_path: &std::path::Path) -> Result<InstanceLock, String> {
        use std::os::unix::fs::OpenOptionsExt;
        let name = socket_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or("socket path has no valid file name")?;
        let path = socket_path.with_file_name(format!("{name}.lock"));
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&path)
            .map_err(|e| format!("failed to open lock file {}: {e}", path.display()))?;
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let metadata = file
            .metadata()
            .map_err(|e| format!("failed to inspect lock file {}: {e}", path.display()))?;
        if metadata.uid() != nix::unistd::geteuid().as_raw()
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err(format!(
                "unsafe lock file permissions at {}",
                path.display()
            ));
        }

        let flock = Flock::lock(file, FlockArg::LockExclusiveNonblock).map_err(|_| {
            format!(
                "another programad instance already holds the lock at {}",
                path.display()
            )
        })?;

        Ok(InstanceLock { _flock: flock })
    }
}
