//! Filesystem layout: runtime socket dir and state (WAL) dir.
//!
//! - Socket: `$XDG_RUNTIME_DIR/programad.sock` if `XDG_RUNTIME_DIR` is set
//!   (the Linux convention: a tmpfs directory private to the user, mode
//!   0700, wiped on logout), else `~/.local/state/programa/programad.sock`
//!   (macOS has no `XDG_RUNTIME_DIR` by default).
//! - State / WAL root: `$XDG_STATE_HOME/programa` if set, else
//!   `~/.local/state/programa`.
//!
//! Both the runtime dir (if we create it) and the state dir are created with
//! mode 0700 so only the owning user can read session output.

use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn home_dir() -> io::Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not an absolute path"))
}

/// Directory that owns the daemon's Unix socket and single-instance lock
/// file. Created with 0700 if missing.
pub fn runtime_dir() -> io::Result<PathBuf> {
    let dir = if let Some(xdg) = std::env::var_os("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg)
    } else {
        state_root()?
    };
    ensure_private_dir(&dir)?;
    Ok(dir)
}

pub fn socket_path() -> io::Result<PathBuf> {
    Ok(runtime_dir()?.join("programad.sock"))
}

pub fn lock_path() -> io::Result<PathBuf> {
    Ok(runtime_dir()?.join("programad.lock"))
}

/// `$XDG_STATE_HOME/programa`, defaulting to `~/.local/state/programa`.
pub fn state_root() -> io::Result<PathBuf> {
    let dir = if let Some(xdg) = std::env::var_os("XDG_STATE_HOME") {
        PathBuf::from(xdg).join("programa")
    } else {
        home_dir()?.join(".local").join("state").join("programa")
    };
    ensure_private_dir(&dir)?;
    Ok(dir)
}

pub fn sessions_dir() -> io::Result<PathBuf> {
    let dir = state_root()?.join("sessions");
    ensure_private_dir(&dir)?;
    Ok(dir)
}

pub fn session_dir(session_id: &str) -> io::Result<PathBuf> {
    if session_id.is_empty()
        || session_id == "."
        || session_id == ".."
        || session_id.contains(std::path::MAIN_SEPARATOR)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid session id path component",
        ));
    }
    let dir = sessions_dir()?.join(session_id);
    ensure_private_dir(&dir)?;
    Ok(dir)
}

pub fn wal_path(session_id: &str) -> io::Result<PathBuf> {
    Ok(session_dir(session_id)?.join("wal"))
}

pub fn ensure_private_dir(dir: &Path) -> io::Result<()> {
    if !dir.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "private directory path must be absolute",
        ));
    }
    match fs::symlink_metadata(dir) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("{} is not a real directory", dir.display()),
                ));
            }
            if metadata.uid() != nix::unistd::geteuid().as_raw() {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!("{} is not owned by the current user", dir.display()),
                ));
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)?;
        }
        Err(error) => return Err(error),
    }
    let metadata = fs::symlink_metadata(dir)?;
    if metadata.file_type().is_symlink()
        || !metadata.is_dir()
        || metadata.uid() != nix::unistd::geteuid().as_raw()
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "{} is not a private directory owned by the current user",
                dir.display()
            ),
        ));
    }
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
