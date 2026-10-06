//! CLI tests. The `testdata_*` tests need the sample files from
//! `scripts/fetch-testdata.sh` and are ignored by default:
//!     cargo test -- --ignored

use std::path::{Path, PathBuf};
use std::process::Command;

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_focuspoint")
}

fn kv(out: &[u8]) -> std::collections::HashMap<String, String> {
    String::from_utf8_lossy(out)
        .lines()
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("focuspoint-it-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

#[test]
fn unsupported_file() {
    let d = tmp("unsupported");
    let f = d.join("x.txt");
    std::fs::write(&f, b"hello world, not an image").unwrap();
    let o = Command::new(bin())
        .args(["info", "--format", "kv"])
        .arg(&f)
        .output()
        .unwrap();
    assert!(o.status.success());
    let m = kv(&o.stdout);
    assert_eq!(m["status"], "unsupported");
    assert!(m.contains_key("message"));
}

#[test]
fn missing_file_is_error() {
    let o = Command::new(bin())
        .args(["info", "--format", "kv", "/nonexistent/file.ARW"])
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(kv(&o.stdout)["status"], "error");
}

#[test]
fn json_is_default() {
    let d = tmp("json");
    let f = d.join("x.bin");
    std::fs::write(&f, b"nope").unwrap();
    let o = Command::new(bin()).arg("info").arg(&f).output().unwrap();
    let v: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(v["status"], "unsupported");
}

/// A plain JPEG without Exif: renders as `no_focus` with an overview.
fn plain_jpeg(path: &Path, w: u32, h: u32) {
    let img = image::RgbImage::from_fn(w, h, |x, y| image::Rgb([x as u8, y as u8, 99]));
    std::fs::write(path, focuspoint::jpeg::encode(&img, 85).unwrap()).unwrap();
}

fn run(args: &[&str], paths: &[&Path], stdin: Option<&str>) -> std::process::Output {
    use std::io::Write;
    let mut c = Command::new(bin());
    c.args(args).args(paths);
    c.stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = c.spawn().unwrap();
    let mut si = child.stdin.take().unwrap();
    if let Some(t) = stdin {
        si.write_all(t.as_bytes()).unwrap();
    }
    drop(si);
    child.wait_with_output().unwrap()
}

fn kv_files(dir: &Path) -> usize {
    std::fs::read_dir(dir)
        .unwrap()
        .filter(|e| {
            e.as_ref()
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".kv")
        })
        .count()
}

#[test]
fn render_cache_hit_miss_and_bypass() {
    let d = tmp("cache");
    let cache = d.join("cache");
    let f = d.join("a.jpg");
    plain_jpeg(&f, 320, 200);
    let c = cache.to_str().unwrap();
    let o1 = run(&["render", "--format", "kv", "--cache-dir", c], &[&f], None);
    assert!(o1.status.success());
    let m1 = kv(&o1.stdout);
    assert_eq!(m1["status"], "no_focus");
    assert_eq!(m1["cached"], "false");
    let ov = PathBuf::from(&m1["overview"]);
    assert!(ov.is_file());
    assert_eq!(ov.parent().unwrap(), std::fs::canonicalize(&cache).unwrap());
    assert_eq!(kv_files(&cache), 1);

    // Hit: same block, cached=true, files untouched.
    let o2 = run(&["render", "--format", "kv", "--cache-dir", c], &[&f], None);
    let m2 = kv(&o2.stdout);
    assert_eq!(m2["cached"], "true");
    let mut m1c = m1.clone();
    m1c.insert("cached".into(), "true".into());
    assert_eq!(m2, m1c);
    let o3 = run(&["render", "--cache-dir", c], &[&f], None);
    let j: serde_json::Value = serde_json::from_slice(&o3.stdout).unwrap();
    assert_eq!(j["cached"], true);
    assert_eq!(j["source_width"], 320);

    // Other sizes or a modified file: a new entry.
    let o4 = run(
        &[
            "render",
            "--format",
            "kv",
            "--size",
            "100",
            "--cache-dir",
            c,
        ],
        &[&f],
        None,
    );
    assert_eq!(kv(&o4.stdout)["cached"], "false");
    plain_jpeg(&f, 300, 200);
    let o5 = run(&["render", "--format", "kv", "--cache-dir", c], &[&f], None);
    let m5 = kv(&o5.stdout);
    assert_eq!(m5["cached"], "false");
    assert_eq!(m5["source_width"], "300");
    assert_ne!(m5["overview"], m1["overview"]);
    assert_eq!(kv_files(&cache), 3);

    // --source bypasses the cache: unique names under <cache>/uncached.
    let src = d.join("src.jpg");
    plain_jpeg(&src, 150, 100);
    let o6 = run(
        &["render", "--format", "kv", "--cache-dir", c, "--source"],
        &[&src, &f],
        None,
    );
    let m6 = kv(&o6.stdout);
    assert_eq!(m6["cached"], "false");
    assert_eq!(m6["source"], "provided");
    assert!(m6["overview"].contains("/uncached/"));
    assert_eq!(kv_files(&cache), 3);

    // Without --cache-dir there is no `cached` key; one of the dirs is required.
    let o7 = run(
        &["render", "--format", "kv", "--out-dir", d.to_str().unwrap()],
        &[&f],
        None,
    );
    assert!(!kv(&o7.stdout).contains_key("cached"));
    let o8 = run(&["render", "--format", "kv"], &[&f], None);
    assert_eq!(o8.status.code(), Some(2));

    // Missing input with a cache dir: an error block, exit 1.
    let o9 = run(
        &["render", "--format", "kv", "--cache-dir", c],
        &[Path::new("/nonexistent/x.ARW")],
        None,
    );
    assert_eq!(o9.status.code(), Some(1));
    assert_eq!(kv(&o9.stdout)["status"], "error");
    let _ = std::fs::remove_dir_all(&d);
}

/// Split batch kv output into (file, block) pairs.
fn blocks(out: &[u8]) -> Vec<(String, std::collections::HashMap<String, String>)> {
    let text = String::from_utf8_lossy(out);
    assert!(text.is_empty() || text.ends_with("---\n"), "{text}");
    text.split_terminator("---\n")
        .map(|b| {
            let first = b.lines().next().unwrap();
            let file = first
                .strip_prefix("file=")
                .expect("file= first")
                .to_string();
            (file, kv(b.as_bytes()))
        })
        .collect()
}

#[test]
fn batch_order_and_per_file_errors() {
    let d = tmp("batch");
    let cache = d.join("cache");
    let c = cache.to_str().unwrap();
    let mut jpgs = Vec::new();
    for i in 0..6 {
        let p = d.join(format!("img{i}.jpg"));
        plain_jpeg(&p, 200 + 40 * i, 150);
        jpgs.push(p.to_string_lossy().into_owned());
    }
    let txt = d.join("notes.txt");
    std::fs::write(&txt, b"definitely not an image").unwrap();
    let txt = txt.to_string_lossy().into_owned();
    let missing = "/nonexistent/dir/DSC0001.ARW".to_string();
    let inputs = vec![
        jpgs[0].clone(),
        missing.clone(),
        jpgs[1].clone(),
        txt.clone(),
        jpgs[2].clone(),
        jpgs[3].clone(),
        jpgs[4].clone(),
        jpgs[5].clone(),
        jpgs[0].clone(),
    ];
    let list = inputs.join("\n") + "\n\n";
    let o = run(
        &["batch", "--cache-dir", c, "--jobs", "3"],
        &[],
        Some(&list),
    );
    assert_eq!(
        o.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&o.stderr)
    );
    let b = blocks(&o.stdout);
    let files: Vec<_> = b.iter().map(|(f, _)| f.clone()).collect();
    assert_eq!(files, inputs, "input order");
    for (f, m) in &b {
        let want = if *f == missing {
            "error"
        } else if *f == txt {
            "unsupported"
        } else {
            "no_focus"
        };
        assert_eq!(m["status"], want, "{f}: {m:?}");
        assert!(m.contains_key("cached"), "{f}");
        if want != "no_focus" {
            assert!(!m["message"].is_empty());
        } else {
            assert!(Path::new(&m["overview"]).is_file());
        }
    }
    assert_eq!(b[2].1["source_width"], "240");

    // Second run from --list: everything that rendered is now a hit.
    let lf = d.join("list.txt");
    std::fs::write(&lf, &list).unwrap();
    let o = run(
        &["batch", "--cache-dir", c, "--list", lf.to_str().unwrap()],
        &[],
        None,
    );
    assert!(o.status.success());
    let b = blocks(&o.stdout);
    assert_eq!(b.len(), inputs.len());
    for (f, m) in &b {
        if *f != missing {
            assert_eq!(m["cached"], "true", "{f}");
        }
    }

    // A render hit matches the batch block.
    let r = run(
        &["render", "--format", "kv", "--cache-dir", c],
        &[Path::new(&jpgs[3])],
        None,
    );
    let mut rm = kv(&r.stdout);
    rm.insert("file".into(), jpgs[3].clone());
    assert_eq!(rm, b[5].1);

    // Pruning to 0 MB empties the cache after the batch.
    let o = run(
        &["batch", "--cache-dir", c, "--cache-max-mb", "0"],
        &[],
        Some(&jpgs[0]),
    );
    assert!(o.status.success());
    assert_eq!(blocks(&o.stdout).len(), 1);
    assert_eq!(kv_files(&cache), 0);

    // Bad arguments.
    let o = run(
        &["batch", "--cache-dir", c, "--list", "/nonexistent/list"],
        &[],
        None,
    );
    assert_eq!(o.status.code(), Some(2));
    let o = run(&["batch"], &[], Some(""));
    assert_eq!(o.status.code(), Some(2));
    // Empty input: no output, success.
    let o = run(&["batch", "--cache-dir", c], &[], Some(""));
    assert!(o.status.success());
    assert!(o.stdout.is_empty());
    let _ = std::fs::remove_dir_all(&d);
}

fn testdata(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("testdata")
        .join(name)
}

/// (file, image_w, image_h, focus_x, focus_y, frame_w, frame_h) from
/// `exiftool -FocusLocation -FocusFrameSize`.
const SAMPLES: &[(&str, u32, u32, u32, u32, u32, u32)] = &[
    (
        "ILCE-7M4_DSC06677_FullFrame-Raw-Compressed.ARW",
        7008,
        4672,
        3504,
        2190,
        350,
        351,
    ),
    (
        "ILCE-7M4_DSC06681_APS-C-Raw-Compressed.ARW",
        4608,
        3072,
        2275,
        1516,
        230,
        231,
    ),
    (
        "ILCE-7M4_DSC06676_FullFrame-LossLess-Compressed-Small.ARW",
        7008,
        4672,
        3591,
        2306,
        350,
        351,
    ),
];

#[test]
#[ignore = "needs testdata/ (scripts/fetch-testdata.sh)"]
fn testdata_info_matches_exiftool() {
    for &(name, w, h, x, y, fw, fh) in SAMPLES {
        let f = testdata(name);
        assert!(
            f.exists(),
            "missing {} - run scripts/fetch-testdata.sh",
            f.display()
        );
        let o = Command::new(bin())
            .args(["info", "--format", "kv"])
            .arg(&f)
            .output()
            .unwrap();
        assert!(o.status.success());
        let m = kv(&o.stdout);
        assert_eq!(m["status"], "ok", "{name}: {m:?}");
        assert_eq!(m["make"], "SONY");
        assert_eq!(m["model"], "ILCE-7M4");
        assert_eq!(m["image_width"], w.to_string(), "{name}");
        assert_eq!(m["image_height"], h.to_string(), "{name}");
        assert_eq!(m["focus_x"], x.to_string(), "{name}");
        assert_eq!(m["focus_y"], y.to_string(), "{name}");
        assert_eq!(m["frame_width"], fw.to_string(), "{name}");
        assert_eq!(m["frame_height"], fh.to_string(), "{name}");
        assert_eq!(m["focus_mode"], "AF-C");
        assert_eq!(m["af_area_mode"], "Tracking: Wide");
        assert_eq!(m["af_area_mode_setting"], "Wide");
        assert_eq!(m["af_tracking"], "Lock On AF");
    }
}

#[test]
#[ignore = "needs testdata/ (scripts/fetch-testdata.sh)"]
fn testdata_render() {
    let out = tmp("render");
    for &(name, ..) in SAMPLES {
        let f = testdata(name);
        let o = Command::new(bin())
            .args(["render", "--format", "kv", "--out-dir"])
            .arg(&out)
            .arg(&f)
            .output()
            .unwrap();
        assert!(
            o.status.success(),
            "{name}: {}",
            String::from_utf8_lossy(&o.stdout)
        );
        let m = kv(&o.stdout);
        assert_eq!(m["status"], "ok");
        assert_eq!(m["source"], "embedded_preview");
        assert_eq!(m["crop_source"], "embedded_preview");
        // a7 IV v2 firmware embeds a JpgFromRaw at full output size.
        assert!(m["crop_source_width"].parse::<u32>().unwrap() >= 3504);
        assert!(Path::new(&m["overview"]).is_file());
        assert!(Path::new(&m["crop"]).is_file());
        // Second invocation must produce different file names.
        let o2 = Command::new(bin())
            .args(["render", "--format", "kv", "--out-dir"])
            .arg(&out)
            .arg(&f)
            .output()
            .unwrap();
        assert_ne!(kv(&o2.stdout)["overview"], m["overview"]);
    }
}

/// Varied AF modes (camera JPEGs from Wikimedia Commons + optional review
/// samples). Expected values from `exiftool -FocusLocation -FocusFrameSize
/// -FocusMode -AFAreaMode -AFAreaModeSetting -Orientation`.
/// (file, orientation, focus "W H X Y", frame "WxH" or "", focus_mode, af_area_mode)
const EXTRA: &[(&str, u32, &str, &str, &str, &str)] = &[
    (
        "sony_a7iv_commons_CNMP01_DMF_EyeTracking.jpg",
        1,
        "7008 4672 3755 759",
        "153x154",
        "DMF",
        "Human Eye Tracking: Wide",
    ),
    (
        "sony_a7iv_commons_PorkMomo_AFS_ExpFlexSpot.jpg",
        1,
        "6224 4672 3112 2336",
        "827x740",
        "AF-S",
        "Expanded Flexible Spot",
    ),
    (
        "sony_a7iv_commons_Bibimbap_AFA_TrackingWide.jpg",
        1,
        "7008 4672 3493 2326",
        "",
        "AF-A",
        "Tracking: Wide",
    ),
    (
        "sony_a7iv_commons_HYBookStore_Portrait_AFA_MultiWide.jpg",
        8,
        "7008 4672 3504 2336",
        "153x156",
        "AF-A",
        "Wide",
    ),
    (
        "sony_a7iv_photographyblog_Portrait_FaceTracking.jpg",
        8,
        "7008 4672 4807 1790",
        "1840x1842",
        "AF-A",
        "Face Tracking",
    ),
    (
        "sony_a7iv_photographyblog_RAW_AFA_FlexSpot.arw",
        1,
        "7008 4672 3504 2336",
        "416x370",
        "AF-A",
        "Flexible Spot",
    ),
];

#[test]
#[ignore = "needs testdata/extra (scripts/fetch-testdata.sh)"]
fn testdata_extra_matches_exiftool() {
    let mut seen = 0;
    for &(name, orient, loc, frame, fm, area) in EXTRA {
        let f = testdata("extra").join(name);
        if !f.exists() {
            eprintln!("skipping missing {}", f.display());
            continue;
        }
        seen += 1;
        let o = Command::new(bin())
            .args(["info", "--format", "kv"])
            .arg(&f)
            .output()
            .unwrap();
        let m = kv(&o.stdout);
        assert_eq!(m["status"], "ok", "{name}: {m:?}");
        assert_eq!(m["orientation"], orient.to_string(), "{name}");
        let got = format!(
            "{} {} {} {}",
            m["image_width"], m["image_height"], m["focus_x"], m["focus_y"]
        );
        assert_eq!(got, loc, "{name}");
        let got_frame = m
            .get("frame_width")
            .map(|w| format!("{w}x{}", m["frame_height"]))
            .unwrap_or_default();
        assert_eq!(got_frame, frame, "{name}");
        assert_eq!(m["focus_mode"], fm, "{name}");
        assert_eq!(m["af_area_mode"], area, "{name}");
    }
    assert!(seen > 0, "no extra samples - run scripts/fetch-testdata.sh");
}

#[test]
#[ignore = "needs testdata/ (scripts/fetch-testdata.sh)"]
fn testdata_batch() {
    let d = tmp("batch-testdata");
    let cache = d.join("cache");
    let mut list = String::new();
    for &(name, ..) in SAMPLES {
        list.push_str(&format!("{}\n", testdata(name).display()));
    }
    for _ in 0..2 {
        let o = run(
            &["batch", "--cache-dir", cache.to_str().unwrap()],
            &[],
            Some(&list),
        );
        assert!(o.status.success());
        let b = blocks(&o.stdout);
        assert_eq!(b.len(), SAMPLES.len());
        for (i, (f, m)) in b.iter().enumerate() {
            assert_eq!(*f, testdata(SAMPLES[i].0).display().to_string());
            assert_eq!(m["status"], "ok", "{f}: {m:?}");
            assert_eq!(m["crop_source"], "embedded_preview");
            assert!(Path::new(&m["crop"]).is_file());
            let img = image::open(&m["crop"]).unwrap();
            assert_eq!((img.width(), img.height()), (800, 800));
        }
    }
    let _ = std::fs::remove_dir_all(&d);
}
