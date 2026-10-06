//! Persistent render cache (`render --cache-dir`, `batch`).
//!
//! An entry is three files sharing a key: `<key>.kv` (the kv block as
//! printed), `<key>-overview.jpg` and `<key>-crop.jpg` (when there is a
//! focus point). The images are written first and the `.kv` last, each via
//! temp file + rename, so a present `.kv` means a complete entry. The `.kv`
//! mtime is the LRU timestamp (touched on every hit).

use crate::output::Report;
use crate::render::write_atomic;
use anyhow::Result;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// Bump when the rendered output changes, to invalidate old entries.
pub const RENDER_VERSION: u32 = 2;

/// Length of a key: 16 lowercase hex digits.
const KEY_LEN: usize = 16;

/// Unique-name renders made with `--source` while a cache dir is in use go
/// here (they are not cache entries); `batch` prunes them after this age.
pub const UNCACHED_DIR: &str = "uncached";
const UNCACHED_MAX_AGE: Duration = Duration::from_secs(3600);
/// Temp files and orphaned images older than this are debris from a
/// crashed writer.
const DEBRIS_MAX_AGE: Duration = Duration::from_secs(600);

/// 64-bit FNV-1a, finished with a splitmix64 mix. Stable across builds and
/// platforms (unlike `std`'s `DefaultHasher`).
fn hash64(parts: &[&[u8]]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for p in parts {
        for &b in *p {
            h ^= b as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        // Separator so ("ab","c") != ("a","bc").
        h ^= 0xff;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h ^= h >> 30;
    h = h.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    h ^= h >> 27;
    h = h.wrapping_mul(0x94d0_49bb_1331_11eb);
    h ^ (h >> 31)
}

#[cfg(unix)]
fn path_bytes(p: &Path) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    p.as_os_str().as_bytes().to_vec()
}

#[cfg(not(unix))]
fn path_bytes(p: &Path) -> Vec<u8> {
    p.to_string_lossy().as_bytes().to_vec()
}

/// Identity of an input file version: canonical path, size, mtime.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileId {
    pub path: PathBuf,
    pub len: u64,
    pub mtime_ns: i128,
}

impl FileId {
    pub fn of(path: &Path) -> std::io::Result<FileId> {
        let path = std::fs::canonicalize(path)?;
        let md = std::fs::metadata(&path)?;
        let mtime_ns = match md.modified()?.duration_since(SystemTime::UNIX_EPOCH) {
            Ok(d) => d.as_nanos() as i128,
            Err(e) => -(e.duration().as_nanos() as i128),
        };
        Ok(FileId {
            path,
            len: md.len(),
            mtime_ns,
        })
    }
}

/// Cache key for a file version rendered with the given sizes.
pub fn key(id: &FileId, size: u32, crop_size: u32) -> String {
    let h = hash64(&[
        b"focuspoint-render",
        &RENDER_VERSION.to_le_bytes(),
        &path_bytes(&id.path),
        &id.len.to_le_bytes(),
        &id.mtime_ns.to_le_bytes(),
        &size.to_le_bytes(),
        &crop_size.to_le_bytes(),
    ]);
    format!("{h:016x}")
}

/// File paths of a cache entry.
pub struct Entry {
    pub kv: PathBuf,
    pub overview: PathBuf,
    pub crop: PathBuf,
}

pub fn entry(dir: &Path, key: &str) -> Entry {
    Entry {
        kv: dir.join(format!("{key}.kv")),
        overview: dir.join(format!("{key}-overview.jpg")),
        crop: dir.join(format!("{key}-crop.jpg")),
    }
}

/// Look up a complete entry. On a hit, touch the `.kv` (LRU) and return
/// the stored report. Entries whose image files are gone count as misses.
pub fn lookup(dir: &Path, key: &str) -> Option<Report> {
    let e = entry(dir, key);
    let text = std::fs::read_to_string(&e.kv).ok()?;
    let r = Report::from_kv(&text);
    for k in ["overview", "crop"] {
        if let Some(p) = r.get_str(k) {
            if !Path::new(p).is_file() {
                return None;
            }
        }
    }
    touch(&e.kv);
    Some(r)
}

fn touch(p: &Path) {
    if let Ok(f) = std::fs::OpenOptions::new().append(true).open(p) {
        let _ = f.set_modified(SystemTime::now());
    }
}

/// Store the report (as printed) as the entry's `.kv`, atomically.
pub fn store(dir: &Path, key: &str, r: &Report) -> Result<()> {
    write_atomic(&entry(dir, key).kv, r.to_kv().as_bytes())
}

/// What a file in the cache dir is, by name.
#[derive(Debug, PartialEq, Eq)]
enum Kind<'a> {
    Kv(&'a str),
    Image(&'a str),
    Temp,
}

fn classify(name: &str) -> Option<Kind<'_>> {
    let is_key = |k: &str| k.len() == KEY_LEN && k.bytes().all(|b| b.is_ascii_hexdigit());
    let key = name.get(..KEY_LEN).filter(|k| is_key(k))?;
    let rest = &name[KEY_LEN..];
    match rest {
        ".kv" => Some(Kind::Kv(key)),
        "-overview.jpg" | "-crop.jpg" => Some(Kind::Image(key)),
        _ if rest.ends_with(".tmp") => Some(Kind::Temp),
        _ => None,
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct PruneStats {
    pub entries_before: usize,
    pub bytes_before: u64,
    pub entries_removed: usize,
    pub bytes_after: u64,
}

/// Delete least-recently-used entries (all files of a key together) until
/// the cache holds at most `max_bytes`. Also removes stale temp files,
/// orphaned images and old `--source` renders. Files that do not look like
/// ours are never touched.
pub fn prune(dir: &Path, max_bytes: u64) -> std::io::Result<PruneStats> {
    prune_at(dir, max_bytes, SystemTime::now())
}

fn prune_at(dir: &Path, max_bytes: u64, now: SystemTime) -> std::io::Result<PruneStats> {
    struct Group {
        kv_mtime: Option<SystemTime>,
        newest: SystemTime,
        bytes: u64,
        files: Vec<PathBuf>,
    }
    let age = |t: SystemTime| now.duration_since(t).unwrap_or_default();
    let mut groups: HashMap<String, Group> = HashMap::new();
    for de in std::fs::read_dir(dir)? {
        let Ok(de) = de else { continue };
        let name = de.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(kind) = classify(name) else { continue };
        let Ok(md) = de.metadata() else { continue };
        if !md.is_file() {
            continue;
        }
        let mtime = md.modified().unwrap_or(now);
        let key = match kind {
            Kind::Temp => {
                if age(mtime) > DEBRIS_MAX_AGE {
                    let _ = std::fs::remove_file(de.path());
                }
                continue;
            }
            Kind::Kv(k) | Kind::Image(k) => k,
        };
        let g = groups.entry(key.to_string()).or_insert(Group {
            kv_mtime: None,
            newest: SystemTime::UNIX_EPOCH,
            bytes: 0,
            files: Vec::new(),
        });
        if matches!(kind, Kind::Kv(_)) {
            g.kv_mtime = Some(mtime);
        }
        g.newest = g.newest.max(mtime);
        g.bytes += md.len();
        g.files.push(de.path());
    }
    // `.kv` first so that a concurrent reader sees a miss, not a dangling hit.
    let remove = |g: &Group| {
        let mut files = g.files.clone();
        files.sort_by_key(|p| p.extension().is_none_or(|e| e != "kv"));
        for f in files {
            let _ = std::fs::remove_file(f);
        }
    };
    let mut stats = PruneStats::default();
    let mut live: Vec<Group> = Vec::new();
    for (_, g) in groups {
        if g.kv_mtime.is_none() {
            // Images without a .kv: in-progress write, or debris.
            if age(g.newest) > DEBRIS_MAX_AGE {
                remove(&g);
                continue;
            }
        }
        live.push(g);
    }
    stats.entries_before = live.len();
    stats.bytes_before = live.iter().map(|g| g.bytes).sum();
    let mut total = stats.bytes_before;
    // Oldest first; in-progress groups (no .kv yet) count as newest.
    live.sort_by_key(|g| g.kv_mtime.unwrap_or(now + Duration::from_secs(1)));
    for g in &live {
        if total <= max_bytes {
            break;
        }
        if g.kv_mtime.is_none() {
            continue;
        }
        remove(g);
        total -= g.bytes;
        stats.entries_removed += 1;
    }
    stats.bytes_after = total;

    let unc = dir.join(UNCACHED_DIR);
    if let Ok(rd) = std::fs::read_dir(&unc) {
        for de in rd.flatten() {
            let old = de
                .metadata()
                .ok()
                .filter(|m| m.is_file())
                .and_then(|m| m.modified().ok())
                .is_some_and(|t| age(t) > UNCACHED_MAX_AGE);
            let ours = de
                .file_name()
                .to_str()
                .is_some_and(|n| n.ends_with(".jpg") || n.ends_with(".tmp"));
            if old && ours {
                let _ = std::fs::remove_file(de.path());
            }
        }
    }
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("focuspoint-cache-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn set_mtime(p: &Path, t: SystemTime) {
        let f = std::fs::OpenOptions::new().append(true).open(p).unwrap();
        f.set_modified(t).unwrap();
    }

    #[test]
    fn key_depends_on_every_input() {
        let d = tmpdir("key");
        let f = d.join("a.jpg");
        std::fs::write(&f, b"one").unwrap();
        let id = FileId::of(&f).unwrap();
        let k = key(&id, 1600, 800);
        assert_eq!(k.len(), KEY_LEN);
        assert!(classify(&format!("{k}.kv")).is_some());
        // Deterministic, and the relative path resolves to the same id.
        assert_eq!(key(&FileId::of(&f).unwrap(), 1600, 800), k);
        assert_ne!(key(&id, 1601, 800), k);
        assert_ne!(key(&id, 1600, 801), k);
        let mut other = id.clone();
        other.len += 1;
        assert_ne!(key(&other, 1600, 800), k);
        let mut other = id.clone();
        other.mtime_ns += 1;
        assert_ne!(key(&other, 1600, 800), k);
        let mut other = id.clone();
        other.path = d.join("b.jpg");
        assert_ne!(key(&other, 1600, 800), k);
        // Content change with a new mtime -> new key.
        std::fs::write(&f, b"two!").unwrap();
        set_mtime(&f, SystemTime::now() + Duration::from_secs(5));
        assert_ne!(key(&FileId::of(&f).unwrap(), 1600, 800), k);
        assert!(FileId::of(&d.join("missing")).is_err());
        let _ = std::fs::remove_dir_all(&d);
    }

    fn fake_entry(dir: &Path, key: &str, img_bytes: usize, with_crop: bool) {
        let e = entry(dir, key);
        std::fs::write(&e.overview, vec![1u8; img_bytes]).unwrap();
        let mut r = Report::default();
        r.str("status", "ok");
        r.str("overview", e.overview.to_string_lossy());
        if with_crop {
            std::fs::write(&e.crop, vec![2u8; img_bytes]).unwrap();
            r.str("crop", e.crop.to_string_lossy());
        }
        r.bool("cached", false);
        store(dir, key, &r).unwrap();
    }

    #[test]
    fn hit_miss_and_touch() {
        let d = tmpdir("hit");
        let k = "0123456789abcdef";
        assert!(lookup(&d, k).is_none());
        fake_entry(&d, k, 10, true);
        let e = entry(&d, k);
        let old = SystemTime::now() - Duration::from_secs(3600);
        set_mtime(&e.kv, old);
        let r = lookup(&d, k).expect("hit");
        assert_eq!(r.get_str("status"), Some("ok"));
        assert_eq!(r.get("cached"), Some(&crate::output::Value::Bool(false)));
        let touched = std::fs::metadata(&e.kv).unwrap().modified().unwrap();
        assert!(touched > old + Duration::from_secs(3000), "LRU touch");
        // A missing image file makes it a miss.
        std::fs::remove_file(&e.crop).unwrap();
        assert!(lookup(&d, k).is_none());
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn store_is_atomic_under_concurrency() {
        let d = tmpdir("atomic");
        let k = "fedcba9876543210";
        let mut r = Report::default();
        r.str("status", "ok");
        r.str("message", "x".repeat(200_000));
        let want = r.to_kv();
        std::thread::scope(|s| {
            for _ in 0..4 {
                s.spawn(|| {
                    for _ in 0..20 {
                        store(&d, k, &r).unwrap();
                    }
                });
            }
            s.spawn(|| {
                for _ in 0..200 {
                    // Readers never see a partial file.
                    if let Ok(t) = std::fs::read_to_string(entry(&d, k).kv) {
                        assert_eq!(t, want);
                    }
                }
            });
        });
        let names: Vec<_> = std::fs::read_dir(&d)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names, vec![format!("{k}.kv")]);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn prune_lru() {
        let d = tmpdir("prune");
        let now = SystemTime::now();
        let keys = ["000000000000000a", "000000000000000b", "000000000000000c"];
        for (i, k) in keys.iter().enumerate() {
            fake_entry(&d, k, 1000, true);
            // a oldest, c newest
            set_mtime(
                &entry(&d, k).kv,
                now - Duration::from_secs(100 - i as u64 * 10),
            );
        }
        // A foreign file and a fresh in-progress image are left alone; old
        // temp files and old orphans are removed.
        std::fs::write(d.join("notes.txt"), vec![0u8; 50_000]).unwrap();
        let fresh = d.join("00000000000000ff-overview.jpg");
        std::fs::write(&fresh, b"partial").unwrap();
        let orphan = d.join("00000000000000ee-crop.jpg");
        std::fs::write(&orphan, b"orphan").unwrap();
        set_mtime(&orphan, now - Duration::from_secs(7200));
        let tmp = d.join("000000000000000a.kv.123-0.tmp");
        std::fs::write(&tmp, b"t").unwrap();
        set_mtime(&tmp, now - Duration::from_secs(7200));
        let entry_bytes = std::fs::metadata(entry(&d, keys[0]).kv).unwrap().len() + 2000;

        // Under the limit: only debris goes.
        let s = prune_at(&d, 1 << 30, now).unwrap();
        assert_eq!(s.entries_removed, 0);
        assert!(!orphan.exists() && !tmp.exists() && fresh.exists());

        // Room for two entries (+ the in-progress file): the oldest goes.
        let s = prune_at(&d, 2 * entry_bytes + 100, now).unwrap();
        assert_eq!(s.entries_removed, 1, "{s:?}");
        assert!(!entry(&d, keys[0]).kv.exists());
        assert!(!entry(&d, keys[0]).overview.exists());
        assert!(!entry(&d, keys[0]).crop.exists());
        assert!(entry(&d, keys[1]).kv.exists() && entry(&d, keys[2]).kv.exists());

        // A hit refreshes b, so c is now the LRU one.
        assert!(lookup(&d, keys[1]).is_some());
        let s = prune_at(&d, entry_bytes + 100, SystemTime::now()).unwrap();
        assert_eq!(s.entries_removed, 1);
        assert!(entry(&d, keys[1]).kv.exists());
        assert!(!entry(&d, keys[2]).kv.exists());

        // Limit 0 empties it (but leaves foreign + in-progress files).
        prune_at(&d, 0, SystemTime::now()).unwrap();
        assert!(!entry(&d, keys[1]).kv.exists());
        assert!(d.join("notes.txt").exists() && fresh.exists());
        let _ = std::fs::remove_dir_all(&d);
    }
}
