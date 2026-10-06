//! The `info` and `render` commands, producing a [`Report`].

use crate::container::Kind;
use crate::meta::{self, Focus, Meta};
use crate::output::{Report, Value};
use crate::render;
use crate::sony;
use image::DynamicImage;
use std::path::Path;

pub struct Analysis {
    pub report: Report,
    pub data: Vec<u8>,
    pub meta: Option<Meta>,
    pub focus: Option<Focus>,
}

fn status(r: &mut Report, s: &str, msg: Option<String>) {
    r.str("status", s);
    match msg {
        Some(m) => r.str("message", m),
        None => r.remove("message"),
    }
}

pub fn analyze(path: &Path) -> Analysis {
    let mut r = Report::default();
    r.str("status", "error");
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(e) => {
            status(
                &mut r,
                "error",
                Some(format!("cannot read {}: {e}", path.display())),
            );
            return Analysis {
                report: r,
                data: Vec::new(),
                meta: None,
                focus: None,
            };
        }
    };
    let m = match meta::read(&data) {
        Ok(m) => m,
        Err(e) => {
            status(&mut r, "unsupported", Some(e));
            return Analysis {
                report: r,
                data,
                meta: None,
                focus: None,
            };
        }
    };
    if let Some(k) = m.kind {
        r.str("file_type", k.name());
    }
    r.opt_str("make", m.make.clone());
    r.opt_str("model", m.model.clone());
    r.opt_str("software", m.software.clone());
    if let Some(o) = m.orientation {
        r.int("orientation", o);
    }
    let orientation = m.orientation.unwrap_or(1);
    let model = m.model.clone().unwrap_or_default();
    let is_sony = m
        .make
        .as_deref()
        .map(|s| s.to_ascii_uppercase().starts_with("SONY"))
        .unwrap_or(false);

    let mut focus = None;
    let outcome: Result<(), String> = (|| {
        if !m.has_exif {
            return Err("no Exif metadata in file".into());
        }
        if !is_sony {
            return Err(format!(
                "not a Sony camera file (make: {})",
                m.make.as_deref().unwrap_or("unknown")
            ));
        }
        if !m.has_makernote {
            let by = m
                .software
                .as_deref()
                .map(|s| format!(" (file written by {s})"))
                .unwrap_or_default();
            return Err(format!(
                "Sony maker note missing, probably stripped on export{by}"
            ));
        }
        let Some(s) = m.sony.as_ref() else {
            return Err("Sony maker note present but not readable".into());
        };
        let sum = sony::summarize(s, &model);
        r.opt_str("focus_mode", sum.focus_mode.clone());
        r.opt_str("af_area_mode", sum.af_area_mode.clone());
        r.opt_str("af_area_mode_setting", sum.af_area_mode_setting.clone());
        r.opt_str("af_tracking", sum.af_tracking.clone());
        r.opt_str("face_eye", sum.face_eye.clone());
        r.opt_str("af_zone", sum.af_zone.clone());
        if let Some([x, y]) = sum.flexible_spot_position {
            r.str("flexible_spot_position", format!("{x} {y}"));
        }
        if sum.focus_mode.as_deref() == Some("Manual") {
            return Err("manual focus: the camera recorded no AF point".into());
        }
        let Some(f) = meta::focus_from(s, orientation) else {
            return Err("no focus location recorded in the maker note".into());
        };
        focus = Some(f);
        Ok(())
    })();

    match outcome {
        Ok(()) => {
            let f = focus.expect("focus set on Ok");
            status(&mut r, "ok", None);
            r.int("image_width", f.image_width);
            r.int("image_height", f.image_height);
            r.int("focus_x", f.x);
            r.int("focus_y", f.y);
            if let Some((w, h)) = f.frame {
                r.int("frame_width", w);
                r.int("frame_height", h);
            }
            r.float("norm_x", f.norm_x);
            r.float("norm_y", f.norm_y);
            if let (Some(w), Some(h)) = (f.norm_w, f.norm_h) {
                r.float("norm_w", w);
                r.float("norm_h", h);
            }
        }
        Err(msg) => status(&mut r, "no_focus", Some(msg)),
    }
    Analysis {
        report: r,
        data,
        meta: Some(m),
        focus,
    }
}

pub fn info(path: &Path) -> Report {
    analyze(path).report
}

#[derive(Clone, Copy)]
pub struct RenderOpts<'a> {
    pub out_dir: &'a Path,
    pub source: Option<&'a Path>,
    pub size: u32,
    pub crop_size: u32,
}

/// Expected display aspect ratio (w/h) of the full frame, if known.
fn expected_aspect(a: &Analysis) -> Option<f64> {
    let m = a.meta.as_ref()?;
    let o = m.orientation.unwrap_or(1);
    let (w, h) = if let Some(f) = &a.focus {
        (f.image_width, f.image_height)
    } else if let Some(j) = m.jpegs.first() {
        (j.width, j.height)
    } else {
        m.image_dims?
    };
    if w == 0 || h == 0 {
        return None;
    }
    let (w, h) = if meta::swaps_axes(o) { (h, w) } else { (w, h) };
    Some(w as f64 / h as f64)
}

/// An image the input file itself can provide.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SelfImg {
    Embedded(meta::EmbeddedJpeg),
    File,
}

/// The file's own images: (largest, cheapest one still >= `size` long edge
/// for the overview), plus the label for `source`/`crop_source`.
fn self_images(a: &Analysis, size: u32) -> Result<(SelfImg, SelfImg, &'static str), String> {
    let m = a.meta.as_ref().ok_or("no metadata")?;
    match m.kind {
        Some(Kind::Tiff) => {
            let largest = *m.jpegs.first().ok_or("no embedded preview JPEG found")?;
            let ov = m
                .jpegs
                .iter()
                .rev()
                .find(|j| j.width.max(j.height) >= size)
                .copied()
                .unwrap_or(largest);
            Ok((
                SelfImg::Embedded(largest),
                SelfImg::Embedded(ov),
                "embedded_preview",
            ))
        }
        Some(Kind::Jpeg) => Ok((SelfImg::File, SelfImg::File, "image")),
        Some(Kind::Heif) => {
            Err("rendering HEIF needs --source <JPEG> (HEVC decoding is not built in)".into())
        }
        None => Err("unknown file type".into()),
    }
}

/// Display-orientation dimensions of a self image, without decoding it.
fn self_dims(a: &Analysis, img: SelfImg) -> Option<(u32, u32)> {
    let m = a.meta.as_ref()?;
    let (w, h) = match img {
        SelfImg::Embedded(j) => (j.width, j.height),
        SelfImg::File => m.image_dims?,
    };
    Some(if meta::swaps_axes(m.orientation.unwrap_or(1)) {
        (h, w)
    } else {
        (w, h)
    })
}

/// Decode a self image and apply the EXIF orientation.
fn decode_self(a: &Analysis, img: SelfImg) -> Result<DynamicImage, String> {
    let m = a.meta.as_ref().ok_or("no metadata")?;
    let bytes = match img {
        SelfImg::Embedded(j) => a
            .data
            .get(j.offset..j.offset + j.len)
            .ok_or("embedded preview out of bounds")?,
        SelfImg::File => &a.data[..],
    };
    render::decode_jpeg(bytes)
        .map(|i| render::apply_orientation(i, m.orientation.unwrap_or(1)))
        .map_err(|e| match img {
            SelfImg::Embedded(_) => format!("embedded preview: {e:#}"),
            SelfImg::File => format!("{e:#}"),
        })
}

/// Read and validate `--source`. Returns the image, or a warning.
fn load_provided(a: &Analysis, src: &Path) -> Result<DynamicImage, String> {
    let img = std::fs::read(src)
        .map_err(|e| format!("cannot read --source {}: {e}", src.display()))
        .and_then(|b| render::decode_jpeg(&b).map_err(|e| format!("--source: {e:#}")))
        .map_err(|e| format!("{e}; used embedded image instead"))?;
    let aspect = img.width() as f64 / img.height().max(1) as f64;
    match expected_aspect(a) {
        Some(exp) if (aspect / exp - 1.0).abs() > 0.03 => Err(format!(
            "--source aspect {aspect:.3} does not match the frame ({exp:.3}); used embedded image instead"
        )),
        _ => Ok(img),
    }
}

pub fn render_cmd(path: &Path, opts: &RenderOpts) -> Report {
    let a = analyze(path);
    let mut r = a.report.clone();
    let st = match r.get("status") {
        Some(Value::Str(s)) => s.clone(),
        _ => "error".into(),
    };
    if st == "error" || st == "unsupported" {
        return r;
    }
    match render_inner(&a, opts, path, &mut r) {
        Ok(()) => {}
        Err(e) => status(&mut r, "error", Some(e)),
    }
    r
}

fn render_inner(
    a: &Analysis,
    opts: &RenderOpts,
    path: &Path,
    r: &mut Report,
) -> Result<(), String> {
    let mut warning = None;
    let provided = match opts.source.map(|s| load_provided(a, s)) {
        Some(Ok(img)) => Some(img),
        Some(Err(w)) => {
            warning = Some(w);
            None
        }
        None => None,
    };
    let with_warning = |e: String, w: &Option<String>| match w {
        Some(w) => format!("{e} ({w})"),
        None => e,
    };
    let selfs = self_images(a, opts.size);
    if provided.is_none() {
        // Need the file's own image for the overview at least.
        if let Err(e) = &selfs {
            return Err(with_warning(e.clone(), &warning));
        }
    }
    if let Some(w) = &warning {
        r.str("warning", w.clone());
    }

    // Crop source: the highest-resolution image available (embedded/file
    // preferred on a tie with --source). Only needed when there is a focus point.
    let want_crop = a.focus.is_some();
    let px = |d: (u32, u32)| d.0 as u64 * d.1 as u64;
    let crop_from_self = match (&selfs, &provided) {
        (Ok((largest, _, _)), Some(p)) => self_dims(a, *largest)
            .map(|d| px(d) >= px((p.width(), p.height())))
            .unwrap_or(false),
        (Ok(_), None) => true,
        (Err(_), _) => false,
    };

    let mut self_large: Option<DynamicImage> = None;
    let mut crop_label = None;
    if want_crop {
        if crop_from_self {
            let (largest, _, label) = selfs.as_ref().map_err(|e| e.clone())?;
            match decode_self(a, *largest) {
                Ok(img) => {
                    self_large = Some(img);
                    crop_label = Some(*label);
                }
                Err(e) if provided.is_some() => {
                    r.str("warning", format!("{e}; crop taken from --source"));
                    crop_label = Some("provided");
                }
                Err(e) => return Err(e),
            }
        } else {
            crop_label = Some("provided");
        }
    }

    // Overview source: --source if usable, else the file's cheapest
    // sufficiently large image (re-using the decoded crop source if same).
    let ov_owned;
    let (ov_img, ov_label): (&DynamicImage, &str) = if let Some(p) = provided.as_ref() {
        (p, "provided")
    } else {
        let (largest, ov, label) = selfs.as_ref().map_err(|e| e.clone())?;
        match &self_large {
            Some(img) if ov == largest => (img, *label),
            _ => {
                ov_owned = decode_self(a, *ov)?;
                (&ov_owned, *label)
            }
        }
    };
    let crop_img: Option<&DynamicImage> = match crop_label {
        Some("provided") => provided.as_ref(),
        Some(_) => self_large.as_ref(),
        None => None,
    };

    let focus = a.focus.map(|f| (f.norm_x, f.norm_y, f.norm_w, f.norm_h));
    let stem = render::unique_stem(path);
    let out = render::render(
        ov_img,
        crop_img,
        focus,
        opts.out_dir,
        &stem,
        opts.size,
        opts.crop_size,
    )
    .map_err(|e| format!("render failed: {e:#}"))?;
    r.str("overview", out.overview.to_string_lossy());
    r.str("source", ov_label);
    r.int("source_width", ov_img.width());
    r.int("source_height", ov_img.height());
    if let (Some(c), Some(img), Some(label)) = (out.crop, crop_img, crop_label) {
        r.str("crop", c.to_string_lossy());
        r.str("crop_source", label);
        r.int("crop_source_width", img.width());
        r.int("crop_source_height", img.height());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sony::encipher;
    use crate::tiff::build::{Builder, Val};
    use crate::tiff::ByteOrder;
    use image::{codecs::jpeg::JpegEncoder, Rgb, RgbImage};

    fn jpeg(w: u32, h: u32) -> Vec<u8> {
        let img = RgbImage::from_pixel(w, h, Rgb([90, 120, 150]));
        let mut out = Vec::new();
        JpegEncoder::new_with_quality(&mut out, 80)
            .encode_image(&img)
            .unwrap();
        out
    }

    /// A minimal ARW-like TIFF: IFD0 with Make/Model/Orientation, an
    /// embedded JPEG preview and an Exif IFD with a Sony maker note.
    fn synthetic_arw(order: ByteOrder, orientation: u16, preview: (u32, u32)) -> Vec<u8> {
        let mut b = Builder::new(order);
        let jpg = jpeg(preview.0, preview.1);
        let jpg_off = b.append(&jpg);
        let mut blk = vec![0u8; 0x40];
        blk[0] = 0x25;
        blk[0x16] = 0x83; // AF-C (+128)
        blk[0x17] = 21; // Human Eye Tracking
        let frame: Vec<u8> = [700u16, 700, 257]
            .iter()
            .flat_map(|x| match order {
                ByteOrder::Little => x.to_le_bytes(),
                ByteOrder::Big => x.to_be_bytes(),
            })
            .collect();
        let (mn, _) = b.ifd_with_prefix(
            b"SONY DSC \0\0\0",
            &[
                (0x201b, Val::Byte(vec![3])),
                (0x201c, Val::Byte(vec![11])),
                (0x2021, Val::Byte(vec![1])),
                (0x2027, Val::Short(vec![7008, 4672, 1752, 1168])),
                (0x2037, Val::Undef(frame)),
                (0x9402, Val::Undef(encipher(&blk))),
            ],
        );
        let mn_len = (b.buf.len() - mn) as u32;
        let (exif, _) = b.ifd(&[(0x927c, Val::Ref(7, mn_len, mn as u32))]);
        let (ifd0, _) = b.ifd(&[
            (0x010f, Val::Ascii("SONY")),
            (0x0110, Val::Ascii("ILCE-7M4")),
            (0x0112, Val::Short(vec![orientation])),
            (0x0201, Val::Long(vec![jpg_off as u32])),
            (0x0202, Val::Long(vec![jpg.len() as u32])),
            (0x8769, Val::Long(vec![exif as u32])),
        ]);
        b.set_u32(4, ifd0 as u32);
        b.buf
    }

    fn tmpdir(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("focuspoint-app-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn s<'a>(r: &'a Report, k: &str) -> &'a str {
        match r.get(k) {
            Some(Value::Str(s)) => s,
            other => panic!("{k}: {other:?}"),
        }
    }

    fn i(r: &Report, k: &str) -> i64 {
        match r.get(k) {
            Some(Value::Int(v)) => *v,
            other => panic!("{k}: {other:?}"),
        }
    }

    fn f(r: &Report, k: &str) -> f64 {
        match r.get(k) {
            Some(Value::Float(v)) => *v,
            other => panic!("{k}: {other:?}"),
        }
    }

    #[test]
    fn synthetic_arw_info_and_render() {
        let dir = tmpdir("arw");
        for order in [ByteOrder::Little, ByteOrder::Big] {
            let path = dir.join(format!("x-{order:?}.ARW"));
            std::fs::write(&path, synthetic_arw(order, 6, (900, 600))).unwrap();
            let r = info(&path);
            assert_eq!(s(&r, "status"), "ok", "{r:?}");
            assert_eq!(s(&r, "model"), "ILCE-7M4");
            assert_eq!(i(&r, "orientation"), 6);
            assert_eq!(i(&r, "focus_x"), 1752);
            assert_eq!(i(&r, "frame_width"), 700);
            assert_eq!(s(&r, "focus_mode"), "AF-C");
            assert_eq!(s(&r, "af_area_mode"), "Human Eye Tracking: Zone");
            assert_eq!(s(&r, "face_eye"), "Human Eye");
            assert_eq!(s(&r, "af_tracking"), "Face tracking");
            // Rotate 90 CW: (0.25, 0.25) -> (0.75, 0.25)
            assert!((f(&r, "norm_x") - 0.75).abs() < 1e-6);
            assert!((f(&r, "norm_y") - 0.25).abs() < 1e-6);

            // Embedded only: overview + crop from the (rotated) preview.
            let out = dir.join("out");
            let opts = RenderOpts {
                out_dir: &out,
                source: None,
                size: 400,
                crop_size: 200,
            };
            let r = render_cmd(&path, &opts);
            assert_eq!(s(&r, "status"), "ok", "{r:?}");
            assert_eq!(s(&r, "source"), "embedded_preview");
            assert_eq!((i(&r, "source_width"), i(&r, "source_height")), (600, 900));
            assert_eq!(s(&r, "crop_source"), "embedded_preview");
            let ov = image::open(s(&r, "overview")).unwrap();
            assert_eq!((ov.width(), ov.height()), (267, 400));
            let c = image::open(s(&r, "crop")).unwrap();
            assert_eq!((c.width(), c.height()), (200, 200));

            // A bigger --source wins the crop; a smaller one only the overview.
            let big = dir.join("big.jpg");
            std::fs::write(&big, jpeg(1200, 1800)).unwrap();
            let opts_big = RenderOpts {
                source: Some(&big),
                ..opts
            };
            let r = render_cmd(&path, &opts_big);
            assert_eq!(s(&r, "source"), "provided");
            assert_eq!(s(&r, "crop_source"), "provided");
            assert_eq!(i(&r, "crop_source_width"), 1200);
            let small = dir.join("small.jpg");
            std::fs::write(&small, jpeg(400, 600)).unwrap();
            let opts_small = RenderOpts {
                source: Some(&small),
                ..opts
            };
            let r = render_cmd(&path, &opts_small);
            assert_eq!(s(&r, "source"), "provided");
            assert_eq!(s(&r, "crop_source"), "embedded_preview");
            assert_eq!(i(&r, "crop_source_width"), 600);
            // Wrong aspect (not rotated) -> ignored with a warning.
            let wrong = dir.join("wrong.jpg");
            std::fs::write(&wrong, jpeg(1800, 1200)).unwrap();
            let opts_wrong = RenderOpts {
                source: Some(&wrong),
                ..opts
            };
            let r = render_cmd(&path, &opts_wrong);
            assert_eq!(s(&r, "source"), "embedded_preview");
            assert!(s(&r, "warning").contains("aspect"));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn stripped_jpeg_is_no_focus() {
        let dir = tmpdir("stripped");
        let path = dir.join("plain.jpg");
        std::fs::write(&path, jpeg(300, 200)).unwrap();
        let r = info(&path);
        assert_eq!(s(&r, "status"), "no_focus");
        let out = dir.join("out");
        let r = render_cmd(
            &path,
            &RenderOpts {
                out_dir: &out,
                source: None,
                size: 1600,
                crop_size: 800,
            },
        );
        assert_eq!(s(&r, "status"), "no_focus");
        assert_eq!(s(&r, "source"), "image");
        assert!(r.get("crop").is_none());
        assert!(std::path::Path::new(s(&r, "overview")).is_file());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
