#![cfg(unix)]

pub mod fdpass;
pub mod paths;
pub mod pty;
pub mod server;
pub mod session;
pub mod wal;

use std::io;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::os::unix::net::{UnixListener as StdUnixListener, UnixStream as StdUnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::net::UnixListener;

use server::AppState;

pub struct DaemonConfig {
    pub socket_path: PathBuf,
    pub password: Option<String>,
}

/// Bind the socket and serve connections until `shutdown` resolves.
/// Exposed as a library function (rather than living only in `main.rs`) so
/// both the real binary and integration tests can start a daemon on a
/// scratch socket path in-process.
pub async fn serve(
    config: DaemonConfig,
    shutdown: impl std::future::Future<Output = ()>,
) -> io::Result<Arc<AppState>> {
    let parent = config.socket_path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket path has no parent directory",
        )
    })?;
    paths::ensure_private_dir(parent)?;
    remove_stale_socket(&config.socket_path)?;

    let std_listener = bind_socket(&config.socket_path)?;
    let socket_identity = socket_identity(&config.socket_path)?;
    std_listener.set_nonblocking(true)?;
    let listener = UnixListener::from_std(std_listener)?;

    let state = Arc::new(AppState::new(config.password));

    tracing::info!(socket = %config.socket_path.display(), "programad listening");

    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _addr)) => {
                        let state = state.clone();
                        tokio::spawn(async move {
                            server::handle_connection(stream, state).await;
                        });
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, "accept failed");
                    }
                }
            }
            _ = &mut shutdown => {
                tracing::info!("shutdown requested");
                break;
            }
        }
    }

    remove_socket_if_same(&config.socket_path, socket_identity);
    Ok(state)
}

fn bind_socket(path: &Path) -> io::Result<StdUnixListener> {
    let listener = StdUnixListener::bind(path)?;
    // 0600: only this user can connect. The parent directory is already
    // 0700 (see `paths.rs`), so this is belt-and-suspenders.
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

fn remove_stale_socket(path: &Path) -> io::Result<()> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_socket() || metadata.uid() != nix::unistd::geteuid().as_raw() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("refusing to replace unsafe socket path {}", path.display()),
        ));
    }
    match StdUnixStream::connect(path) {
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            format!("another daemon is listening at {}", path.display()),
        )),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
            ) =>
        {
            std::fs::remove_file(path)
        }
        Err(error) => Err(error),
    }
}

fn socket_identity(path: &Path) -> io::Result<(u64, u64)> {
    let metadata = std::fs::symlink_metadata(path)?;
    Ok((metadata.dev(), metadata.ino()))
}

fn remove_socket_if_same(path: &Path, expected: (u64, u64)) {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return;
    };
    if metadata.file_type().is_socket()
        && metadata.uid() == nix::unistd::geteuid().as_raw()
        && (metadata.dev(), metadata.ino()) == expected
    {
        let _ = std::fs::remove_file(path);
    }
}
