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
