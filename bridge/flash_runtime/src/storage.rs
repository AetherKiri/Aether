use ruffle_core::backend::storage::StorageBackend;
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static SERIAL: AtomicU64 = AtomicU64::new(0);
const OBJECT: &str = "object.sol";

pub(super) struct Storage {
    local: PathBuf,
    legacy: Option<PathBuf>,
    movie_directory: Option<String>,
}

fn real_directory(path: &Path) -> io::Result<()> {
    if fs::symlink_metadata(path)?.is_dir() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Not a regular Flash save directory",
        ))
    }
}

fn read_regular(path: &Path) -> io::Result<Vec<u8>> {
    if !fs::symlink_metadata(path)?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Not a regular Flash save file",
        ));
    }
    fs::read(path)
}

fn unique_tag() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let serial = SERIAL.fetch_add(1, Ordering::Relaxed);
    format!("{}-{now}-{serial}", std::process::id())
}

impl Storage {
    pub(super) fn new(local: &Path, legacy: Option<&Path>, movie_url: &str) -> io::Result<Self> {
        fs::create_dir_all(local)?;
        real_directory(local)?;
        // movie_from_path supplies a percent-encoded file URL. Match Ruffle's
        // getLocal path handling, including drive-letter removal on Windows.
        let movie_directory = movie_url
            .strip_prefix("file://")
            .and_then(|url| url.split_once('/'))
            .map(|(_, path)| {
                let path = path.trim_end_matches('/');
                let path = if matches!(path.as_bytes(), [_, b':', b'/', ..]) {
                    &path[3..]
                } else {
                    path
                };
                path.rsplit_once('/')
                    .map_or("", |(directory, _)| directory)
                    .to_owned()
            });
        Ok(Self {
            local: local.to_owned(),
            legacy: legacy.map(Path::to_owned),
            movie_directory,
        })
    }

    fn key_directory(&self, name: &str) -> PathBuf {
        let mut hash = Sha256::new();
        if self.movie_directory.is_some() {
            if let Some(name) = name.strip_prefix("localhost//") {
                // Explicit localPath="/" is independent of directory depth.
                hash.update(b"file-root\0");
                hash.update(name.as_bytes());
                return self.local.join(format!("{:x}", hash.finalize()));
            }
        }
        if let (Some(mut scope), Some(key)) = (
            self.movie_directory.as_deref(),
            name.strip_prefix("localhost/"),
        ) {
            for depth in 0u32.. {
                let relative = if scope.is_empty() {
                    Some(key.trim_start_matches('/'))
                } else {
                    key.strip_prefix(scope)
                        .and_then(|suffix| suffix.strip_prefix('/'))
                };
                if let Some(relative) = relative {
                    // Keep movie-local and explicit folder scopes distinct,
                    // without using the absolute install path as a local key.
                    hash.update(b"file");
                    hash.update(depth.to_le_bytes());
                    hash.update(relative.as_bytes());
                    return self.local.join(format!("{:x}", hash.finalize()));
                }
                scope = scope.rsplit_once('/').map_or("", |(parent, _)| parent);
            }
        }
        hash.update(b"other\0");
        hash.update(name.as_bytes());
        self.local.join(format!("{:x}", hash.finalize()))
    }

    fn read_local(bank: &Path) -> io::Result<Vec<u8>> {
        real_directory(bank)?;
        read_regular(&bank.join(OBJECT))
    }

    fn publish(&self, bank: &Path, bytes: &[u8], replace: bool) -> io::Result<()> {
        let stage = self
            .local
            .join(format!(".aether-flash-stage-{}", unique_tag()));
        fs::create_dir(&stage)?;
        let pending = stage.join(OBJECT);
        let result = (|| {
            let mut out = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&pending)?;
            out.write_all(bytes)?;
            out.sync_all()?;
            drop(out);
            if replace {
                match real_directory(bank) {
                    Ok(()) => return fs::rename(&pending, bank.join(OBJECT)),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                    Err(error) => return Err(error),
                }
            }
            // An existing committed bank is nonempty. This cannot replace a
            // concurrently migrated or written object (including a tombstone).
            fs::rename(&stage, bank)
        })();
        let _ = fs::remove_file(pending);
        let _ = fs::remove_dir(stage);
        result
    }
}

impl StorageBackend for Storage {
    fn get(&self, name: &str) -> Option<Vec<u8>> {
        let bank = self.key_directory(name);
        match Self::read_local(&bank) {
            Ok(value) => return (!value.is_empty()).then_some(value),
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(_) => return None,
        }
        // Old .sol filenames are hashes of the exact object key: migrate on
        // lookup, never by copying all titles' SharedObjects into one game.
        let legacy = self.legacy.as_ref()?;
        real_directory(legacy).ok()?;
        let path = legacy.join(format!("{:x}.sol", Sha256::digest(name.as_bytes())));
        let value = read_regular(&path).ok()?;
        if value.is_empty() {
            return None;
        }
        if self.publish(&bank, &value, false).is_err() {
            match Self::read_local(&bank) {
                Ok(local) => return (!local.is_empty()).then_some(local),
                Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                Err(_) => return None,
            }
        }
        // If writing failed, leave the legacy file intact for a later retry.
        Some(value)
    }

    fn put(&mut self, name: &str, value: &[u8]) -> bool {
        self.publish(&self.key_directory(name), value, true).is_ok()
    }

    fn remove_key(&mut self, name: &str) {
        // Empty local objects are tombstones, not missing files.
        let _ = self.put(name, &[]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_one_object_without_resurrecting_old_copies() {
        let base = std::env::temp_dir().join(format!("aether-flash-save-{}", unique_tag()));
        fs::create_dir(&base).unwrap();
        struct Fixture(PathBuf);
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _fixture = Fixture(base.clone());
        let legacy = base.join("legacy");
        let local = base.join("original/savedata/flash");
        fs::create_dir(&legacy).unwrap();
        let key = "localhost/original/My%20Game.swf/progress";
        let old_file = legacy.join(format!("{:x}.sol", Sha256::digest(key.as_bytes())));
        fs::write(&old_file, b"legacy progress").unwrap();
        fs::write(legacy.join("unrelated.sol"), b"another game").unwrap();
        let mut storage =
            Storage::new(&local, Some(&legacy), "file:///original/My%20Game.swf").unwrap();
        assert_eq!(storage.get(key).as_deref(), Some(&b"legacy progress"[..]));
        assert_eq!(fs::read_dir(&local).unwrap().count(), 1);
        assert!(storage.put(key, b"local progress"));
        assert!(storage.put("localhost/original/shared", b"folder scope"));
        assert_eq!(fs::read(&old_file).unwrap(), b"legacy progress");
        fs::rename(base.join("original"), base.join("moved")).unwrap();
        let moved = base.join("moved/savedata/flash");
        let mut storage =
            Storage::new(&moved, Some(&legacy), "file:///moved/My%20Game.swf").unwrap();
        let moved_key = "localhost/moved/My%20Game.swf/progress";
        assert_eq!(
            storage.get(moved_key).as_deref(),
            Some(&b"local progress"[..])
        );
        assert_eq!(
            storage.get("localhost/moved/shared").as_deref(),
            Some(&b"folder scope"[..])
        );
        assert!(
            storage
                .get("localhost/moved/Another.swf/progress")
                .is_none()
        );
        storage.remove_key(moved_key);
        let storage =
            Storage::new(&moved, Some(&legacy), "file:///original/My%20Game.swf").unwrap();
        assert!(storage.get(key).is_none());
    }
}
