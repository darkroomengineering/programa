//! Per-session write-ahead log (WAL) of PTY output.
//!
//! One file per session at `<state_root>/sessions/<id>/wal`, appended to
//! continuously by the session's single PTY reader thread so the WAL is
//! always current, whether or not a client is attached. This is what makes
//! a session survive client death by construction: the daemon, not the
//! client, is the sole reader of the PTY master, so output is captured
//! regardless of who (if anyone) is attached.
//!
//! Offsets are a monotonically increasing byte counter since the session
//! was created (never reset by truncation), matching the "replay from
//! offset" semantics `session.read`/`session.attach` expose. A sidecar
//! `wal.meta` file persists `base_offset` (bytes dropped by truncation) and
//! `total_len` (bytes ever written) as `{"base_offset":N,"total_len":N}` so
//! offsets stay valid across a daemon restart. Metadata writes use a synced
//! temporary file and atomic rename. Compaction additionally persists an
//! intent record before replacing the live data file; startup completes that
//! transaction if the process stopped between the data and metadata renames.
//!
//! **Truncation rule**: when the on-disk file would exceed `max_bytes`
//! (default 8 MiB) after an append, the oldest half of the file is dropped:
//! an atomic replacement keeps only its last `max_bytes / 2` bytes, and
//! `base_offset` advances by however many bytes were dropped. A read for an
//! offset older than `base_offset` is satisfied starting at `base_offset`
//! instead of erroring, with the actual start offset reported back to the
//! caller — the same "best effort tail" contract tmux/screen give when
//! their scrollback has aged content out.
//!
//! **fsync**: debounced, at most once per `fsync_interval` (default 200ms)
//! of wall time, matching the "fsync debounced" requirement. A final fsync
//! always happens on `Drop`/`close` so a clean shutdown never loses the
//! last write.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

pub const DEFAULT_MAX_BYTES: u64 = 8 * 1024 * 1024;
pub const DEFAULT_FSYNC_INTERVAL: Duration = Duration::from_millis(200);

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
struct WalMeta {
    base_offset: u64,
    total_len: u64,
}

pub struct WalStore {
    data_path: PathBuf,
    meta_path: PathBuf,
    compact_data_path: PathBuf,
    compact_intent_path: PathBuf,
    file: File,
    meta: WalMeta,
    max_bytes: u64,
    fsync_interval: Duration,
    last_fsync: Instant,
    dirty: bool,
}

impl WalStore {
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        Self::open_with(path, DEFAULT_MAX_BYTES, DEFAULT_FSYNC_INTERVAL)
    }

    pub fn open_with(
        path: impl AsRef<Path>,
        max_bytes: u64,
        fsync_interval: Duration,
    ) -> io::Result<Self> {
        let data_path = path.as_ref().to_path_buf();
        let meta_path = {
            let mut p = data_path.clone();
            let name = format!(
                "{}.meta",
                p.file_name().and_then(|s| s.to_str()).unwrap_or("wal")
            );
            p.set_file_name(name);
            p
        };
        let compact_data_path = data_path.with_extension("compact-data");
        let compact_intent_path = data_path.with_extension("compact-intent");

        recover_compaction(
            &data_path,
            &meta_path,
            &compact_data_path,
            &compact_intent_path,
        )?;

        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .append(true)
            .open(&data_path)?;

        let mut meta = read_meta(&meta_path)?.unwrap_or_default();
        // Reconcile meta.total_len with actual file length in case of a
        // prior unclean shutdown between an append and its meta write.
        let file_len = file.metadata()?.len();
        let expected_len = meta.total_len.saturating_sub(meta.base_offset);
        if file_len != expected_len {
            meta.total_len = meta.base_offset + file_len;
        }

        Ok(WalStore {
            data_path,
            meta_path,
            compact_data_path,
            compact_intent_path,
            file,
            meta,
            max_bytes: max_bytes.max(4096),
            fsync_interval,
            last_fsync: Instant::now() - fsync_interval,
            dirty: false,
        })
    }

    /// Monotonic byte offset of the next byte that will be appended.
    pub fn tail_offset(&self) -> u64 {
        self.meta.total_len
    }

    /// Oldest offset still readable (bytes before this were truncated).
    pub fn base_offset(&self) -> u64 {
        self.meta.base_offset
    }

    pub fn append(&mut self, data: &[u8]) -> io::Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        self.file.write_all(data)?;
        self.meta.total_len += data.len() as u64;
        self.dirty = true;

        let file_len = self.meta.total_len - self.meta.base_offset;
        if file_len > self.max_bytes {
            self.truncate_head(file_len)?;
        }

        if self.last_fsync.elapsed() >= self.fsync_interval {
            self.flush()?;
        }
        Ok(())
    }

    /// Force a flush + fsync + meta persist regardless of the debounce
    /// window. Called on clean shutdown.
    pub fn flush(&mut self) -> io::Result<()> {
        self.file.flush()?;
        self.file.sync_data()?;
        write_meta(&self.meta_path, &self.meta)?;
        self.last_fsync = Instant::now();
        self.dirty = false;
        Ok(())
    }

    pub fn flush_due_in(&self) -> Option<Duration> {
        self.dirty.then(|| {
            self.fsync_interval
                .saturating_sub(self.last_fsync.elapsed())
        })
    }

    pub fn flush_if_due(&mut self) -> io::Result<bool> {
        if self.dirty && self.last_fsync.elapsed() >= self.fsync_interval {
            self.flush()?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn truncate_head(&mut self, file_len: u64) -> io::Result<()> {
        let keep = self.max_bytes / 2;
        let drop_bytes = file_len - keep;
        let new_meta = WalMeta {
            base_offset: self.meta.base_offset + drop_bytes,
            total_len: self.meta.total_len,
        };

        let mut buf = Vec::with_capacity(keep as usize);
        self.file.flush()?;
        self.file.seek(SeekFrom::Start(drop_bytes))?;
        self.file.read_to_end(&mut buf)?;

        // Never truncate the live WAL in place. A compacted replacement and
        // an intent record are synced first; recovery can then finish either
        // rename after a crash without guessing which offsets the data uses.
        let _ = std::fs::remove_file(&self.compact_data_path);
        let mut new_file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .read(true)
            .open(&self.compact_data_path)?;
        new_file.write_all(&buf)?;
        new_file.flush()?;
        new_file.sync_all()?;

        write_json_atomic(&self.compact_intent_path, &new_meta)?;
        std::fs::rename(&self.compact_data_path, &self.data_path)?;
        sync_parent(&self.data_path)?;
        write_meta(&self.meta_path, &new_meta)?;
        std::fs::remove_file(&self.compact_intent_path)?;
        sync_parent(&self.data_path)?;

        // Reopen in append mode positioned at the end, since the file we
        // just wrote to was opened write-only-from-start.
        self.file = OpenOptions::new()
            .create(true)
            .read(true)
            .append(true)
            .open(&self.data_path)?;

        self.meta = new_meta;
        Ok(())
    }

    /// Read up to `max_len` bytes starting at `offset` (clamped to
    /// `base_offset` if the requested offset has already aged out).
    /// Returns `(actual_start_offset, bytes)`.
    pub fn read_from(&self, offset: u64, max_len: usize) -> io::Result<(u64, Vec<u8>)> {
        let start = offset.max(self.meta.base_offset);
        if start >= self.meta.total_len {
            return Ok((start, Vec::new()));
        }
        let file_off = start - self.meta.base_offset;
        let avail = (self.meta.total_len - start) as usize;
        let want = avail.min(max_len.max(1));

        let mut f = File::open(&self.data_path)?;
        f.seek(SeekFrom::Start(file_off))?;
        let mut buf = vec![0u8; want];
        let n = f.read(&mut buf)?;
        buf.truncate(n);
        Ok((start, buf))
    }
}

impl Drop for WalStore {
    fn drop(&mut self) {
        if self.dirty {
            let _ = self.flush();
        }
    }
}

fn read_meta(path: &Path) -> io::Result<Option<WalMeta>> {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    serde_json::from_slice(&data).map(Some).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("invalid WAL metadata at {}: {error}", path.display()),
        )
    })
}

fn write_meta(path: &Path, meta: &WalMeta) -> io::Result<()> {
    write_json_atomic(path, meta)
}

fn write_json_atomic(path: &Path, meta: &WalMeta) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let temp = path.with_extension("new");
    let _ = std::fs::remove_file(&temp);
    let data = serde_json::to_vec(meta)?;
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&temp)?;
    file.write_all(&data)?;
    file.flush()?;
    file.sync_all()?;
    std::fs::rename(&temp, path)?;
    sync_parent(path)
}

fn recover_compaction(
    data_path: &Path,
    meta_path: &Path,
    compact_data_path: &Path,
    compact_intent_path: &Path,
) -> io::Result<()> {
    let Some(meta) = read_meta(compact_intent_path)? else {
        // A replacement without a synced intent was never eligible to commit.
        let _ = std::fs::remove_file(compact_data_path);
        return Ok(());
    };
    let expected_len = meta
        .total_len
        .checked_sub(meta.base_offset)
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "invalid WAL compaction offsets")
        })?;

    if compact_data_path.exists() {
        if compact_data_path.metadata()?.len() != expected_len {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "incomplete WAL compaction replacement",
            ));
        }
        std::fs::rename(compact_data_path, data_path)?;
        sync_parent(data_path)?;
    } else if data_path.metadata().map(|m| m.len()).unwrap_or(u64::MAX) != expected_len {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "WAL compaction intent does not match stored data",
        ));
    }

    write_meta(meta_path, &meta)?;
    std::fs::remove_file(compact_intent_path)?;
    sync_parent(data_path)
}

fn sync_parent(path: &Path) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "WAL path has no parent"))?;
    File::open(parent)?.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn append_and_read_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let mut wal = WalStore::open(dir.path().join("wal")).unwrap();
        wal.append(b"hello ").unwrap();
        wal.append(b"world").unwrap();
        assert_eq!(wal.tail_offset(), 11);
        let (start, data) = wal.read_from(0, 1024).unwrap();
        assert_eq!(start, 0);
        assert_eq!(data, b"hello world");
    }

    #[test]
    fn read_from_middle_offset() {
        let dir = tempfile::tempdir().unwrap();
        let mut wal = WalStore::open(dir.path().join("wal")).unwrap();
        wal.append(b"0123456789").unwrap();
        let (start, data) = wal.read_from(5, 1024).unwrap();
        assert_eq!(start, 5);
        assert_eq!(data, b"56789");
    }

    #[test]
    fn truncation_advances_base_offset_and_keeps_tail_readable() {
        let dir = tempfile::tempdir().unwrap();
        // Tiny max so a handful of appends forces truncation.
        let mut wal =
            WalStore::open_with(dir.path().join("wal"), 4096, Duration::from_secs(3600)).unwrap();
        let chunk = vec![b'a'; 1024];
        for _ in 0..10 {
            wal.append(&chunk).unwrap();
        }
        assert!(wal.base_offset() > 0, "expected truncation to have run");
        assert_eq!(wal.tail_offset(), 10 * 1024);

        // A read for an offset older than base_offset clamps forward
        // instead of erroring.
        let (start, data) = wal.read_from(0, 8192).unwrap();
        assert_eq!(start, wal.base_offset());
        assert_eq!(data.len() as u64, wal.tail_offset() - wal.base_offset());
    }

    #[test]
    fn meta_survives_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wal");
        {
            let mut wal = WalStore::open(&path).unwrap();
            wal.append(b"persisted").unwrap();
            wal.flush().unwrap();
        }
        let wal2 = WalStore::open(&path).unwrap();
        assert_eq!(wal2.tail_offset(), 9);
        let (start, data) = wal2.read_from(0, 100).unwrap();
        assert_eq!(start, 0);
        assert_eq!(data, b"persisted");
    }

    #[test]
    fn open_completes_interrupted_compaction_transaction() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wal");
        let meta_path = dir.path().join("wal.meta");
        let compact_data = dir.path().join("wal.compact-data");
        let compact_intent = dir.path().join("wal.compact-intent");
        {
            let mut wal = WalStore::open(&path).unwrap();
            wal.append(b"0123456789").unwrap();
            wal.flush().unwrap();
        }

        std::fs::write(&compact_data, b"56789").unwrap();
        write_json_atomic(
            &compact_intent,
            &WalMeta {
                base_offset: 5,
                total_len: 10,
            },
        )
        .unwrap();

        let wal = WalStore::open(&path).unwrap();
        assert_eq!(wal.base_offset(), 5);
        assert_eq!(wal.tail_offset(), 10);
        assert_eq!(wal.read_from(0, 100).unwrap(), (5, b"56789".to_vec()));
        assert!(!compact_data.exists());
        assert!(!compact_intent.exists());
        assert!(meta_path.exists());
    }

    #[test]
    fn quiet_dirty_wal_becomes_due_without_another_append() {
        let dir = tempfile::tempdir().unwrap();
        let mut wal =
            WalStore::open_with(dir.path().join("wal"), 4096, Duration::from_millis(10)).unwrap();
        wal.append(b"seed").unwrap();
        wal.append(b"quiet tail").unwrap();
        std::thread::sleep(Duration::from_millis(20));
        assert!(wal.flush_if_due().unwrap());
        assert_eq!(wal.flush_due_in(), None);
    }
}
