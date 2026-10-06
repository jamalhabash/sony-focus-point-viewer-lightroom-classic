//! `batch`: render many files into the cache in parallel, report in input
//! order, then prune the cache (LRU).

use crate::app::{self, RenderOpts};
use crate::cache;
use crate::output::Report;
use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;

pub struct BatchOpts<'a> {
    pub cache_dir: &'a Path,
    pub size: u32,
    pub crop_size: u32,
    pub jobs: usize,
    pub json: bool,
    pub cache_max_bytes: u64,
}

/// Default worker count: half the cores (each render uses two threads),
/// at least 2.
pub fn default_jobs() -> usize {
    let n = std::thread::available_parallelism().map_or(2, |n| n.get());
    (n / 2).max(2)
}

/// Input paths: one per line; a trailing CR is dropped, empty lines are
/// skipped.
pub fn parse_list(text: &str) -> Vec<String> {
    text.lines()
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

fn render_one(path: &str, opts: &BatchOpts) -> Report {
    let ropts = RenderOpts {
        out_dir: None,
        cache_dir: Some(opts.cache_dir),
        source: None,
        size: opts.size,
        crop_size: opts.crop_size,
        parallel: true,
    };
    // A bug in one file must not take the whole batch down.
    std::panic::catch_unwind(|| app::render_cmd(Path::new(path), &ropts)).unwrap_or_else(|_| {
        let mut r = Report::default();
        r.str("status", "error");
        r.str("message", "internal error while rendering (panic)");
        r
    })
}

fn block(path: &str, r: Report, json: bool) -> String {
    if json {
        let mut b = Report::default();
        b.str("file", path);
        b.fields.extend(r.fields);
        b.to_json()
    } else {
        let mut s = format!("file={}\n", crate::output::escape_kv(path));
        s.push_str(&r.to_kv());
        s.push_str("---\n");
        s
    }
}

/// Render `paths` with `opts.jobs` workers, writing one block per path to
/// `out` in input order as soon as it (and all before it) are done. Each
/// worker handles one file at a time, so memory stays bounded. Then prunes
/// the cache to `opts.cache_max_bytes`.
pub fn run(paths: &[String], opts: &BatchOpts, out: &mut dyn Write) -> std::io::Result<()> {
    let n = paths.len();
    let next = AtomicUsize::new(0);
    let (tx, rx) = mpsc::channel::<(usize, Report)>();
    let mut res = Ok(());
    if opts.json {
        res = out.write_all(b"[\n");
    }
    std::thread::scope(|s| {
        for _ in 0..opts.jobs.clamp(1, n.max(1)) {
            let tx = tx.clone();
            let next = &next;
            s.spawn(move || loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                if i >= n {
                    break;
                }
                if tx.send((i, render_one(&paths[i], opts))).is_err() {
                    break;
                }
            });
        }
        drop(tx);
        let mut pending: BTreeMap<usize, Report> = BTreeMap::new();
        let mut printed = 0;
        for (i, r) in rx {
            if res.is_err() {
                continue; // output gone: drain quickly
            }
            pending.insert(i, r);
            while let Some(r) = pending.remove(&printed) {
                let mut b = block(&paths[printed], r, opts.json);
                if opts.json && printed + 1 < n {
                    b.insert(b.len() - 1, ',');
                }
                printed += 1;
                res = out.write_all(b.as_bytes()).and_then(|()| out.flush());
                if res.is_err() {
                    next.store(n, Ordering::Relaxed); // stop handing out work
                    break;
                }
            }
        }
    });
    if opts.json && res.is_ok() {
        res = out.write_all(b"]\n").and_then(|()| out.flush());
    }
    if opts.cache_dir.is_dir() {
        if let Err(e) = cache::prune(opts.cache_dir, opts.cache_max_bytes) {
            eprintln!(
                "focuspoint: pruning cache {}: {e}",
                opts.cache_dir.display()
            );
        }
    }
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_parsing() {
        assert_eq!(
            parse_list("a.jpg\r\n\n/x/b c.ARW \n\r\nlast"),
            vec!["a.jpg", "/x/b c.ARW ", "last"]
        );
        assert!(parse_list("").is_empty());
    }

    #[test]
    fn json_blocks_form_an_array() {
        let d = std::env::temp_dir().join(format!("focuspoint-batch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let txt = d.join("t.txt");
        std::fs::write(&txt, b"text").unwrap();
        let paths = vec![
            txt.to_string_lossy().into_owned(),
            "/nonexistent/x.ARW".to_string(),
        ];
        let opts = BatchOpts {
            cache_dir: &d.join("cache"),
            size: 1600,
            crop_size: 800,
            jobs: 2,
            json: true,
            cache_max_bytes: 1 << 20,
        };
        let mut out = Vec::new();
        run(&paths, &opts, &mut out).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v[0]["file"], paths[0]);
        assert_eq!(v[0]["status"], "unsupported");
        assert_eq!(v[0]["cached"], false);
        assert_eq!(v[1]["status"], "error");
        let mut out = Vec::new();
        run(&[], &opts, &mut out).unwrap();
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v.as_array().unwrap().len(), 0);
        let _ = std::fs::remove_dir_all(&d);
    }
}
