//! Image loading, orientation, focus-box drawing, cropping and JPEG output.

use anyhow::{anyhow, Context, Result};
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::metadata::Orientation;
use image::{DynamicImage, ImageFormat, Rgb, RgbImage};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

pub const GREEN: Rgb<u8> = Rgb([0, 255, 64]);
pub const DARK: Rgb<u8> = Rgb([0, 0, 0]);

pub fn decode_jpeg(bytes: &[u8]) -> Result<DynamicImage> {
    image::load_from_memory_with_format(bytes, ImageFormat::Jpeg).context("decoding JPEG")
}

pub fn apply_orientation(img: DynamicImage, o: u16) -> DynamicImage {
    let mut img = img;
    if let Some(or) = Orientation::from_exif(o as u8) {
        img.apply_orientation(or);
    }
    img
}

/// Box geometry in pixel space of a particular image.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PxBox {
    pub cx: f64,
    pub cy: f64,
    pub w: f64,
    pub h: f64,
}

/// Focus box for an image of `w`x`h` (display orientation) from normalised
/// coordinates. If the frame size is unknown, use a square ~4% of the long
/// edge.
pub fn px_box(w: u32, h: u32, nx: f64, ny: f64, nw: Option<f64>, nh: Option<f64>) -> PxBox {
    let long = w.max(h) as f64;
    let (bw, bh) = match (nw, nh) {
        (Some(a), Some(b)) => (a * w as f64, b * h as f64),
        _ => (0.04 * long, 0.04 * long),
    };
    // Never let the box shrink below something visible.
    let min = (long * 0.012).max(10.0);
    PxBox {
        cx: nx * w as f64,
        cy: ny * h as f64,
        w: bw.max(min),
        h: bh.max(min),
    }
}

fn put(img: &mut RgbImage, x: i64, y: i64, c: Rgb<u8>) {
    if x >= 0 && y >= 0 && (x as u32) < img.width() && (y as u32) < img.height() {
        img.put_pixel(x as u32, y as u32, c);
    }
}

fn fill_rect(img: &mut RgbImage, x0: i64, y0: i64, x1: i64, y1: i64, c: Rgb<u8>) {
    let x0 = x0.max(0);
    let y0 = y0.max(0);
    let x1 = x1.min(img.width() as i64);
    let y1 = y1.min(img.height() as i64);
    for y in y0..y1 {
        for x in x0..x1 {
            put(img, x, y, c);
        }
    }
}

/// Rectangle outline whose stroke occupies [x0-t/2, x0+t/2] etc.
fn stroke_rect(img: &mut RgbImage, x0: i64, y0: i64, x1: i64, y1: i64, t: i64, c: Rgb<u8>) {
    let h = t / 2;
    let t2 = t - h;
    fill_rect(img, x0 - h, y0 - h, x1 + t2, y0 + t2, c); // top
    fill_rect(img, x0 - h, y1 - h, x1 + t2, y1 + t2, c); // bottom
    fill_rect(img, x0 - h, y0 - h, x0 + t2, y1 + t2, c); // left
    fill_rect(img, x1 - h, y0 - h, x1 + t2, y1 + t2, c); // right
}

/// Draw the focus frame (green with a dark outline) and a small crosshair.
pub fn draw_focus(img: &mut RgbImage, b: PxBox) {
    let long = img.width().max(img.height()) as f64;
    let t = ((long / 300.0).round() as i64).clamp(3, 10); // green stroke
    let o = ((t + 1) / 2).max(2); // dark outline on each side
    let x0 = (b.cx - b.w / 2.0).round() as i64;
    let x1 = (b.cx + b.w / 2.0).round() as i64;
    let y0 = (b.cy - b.h / 2.0).round() as i64;
    let y1 = (b.cy + b.h / 2.0).round() as i64;
    stroke_rect(img, x0, y0, x1, y1, t + 2 * o, DARK);
    stroke_rect(img, x0, y0, x1, y1, t, GREEN);

    // Crosshair: a "+" in the centre, arms ~1/5 of the box (min a few px).
    let cx = b.cx.round() as i64;
    let cy = b.cy.round() as i64;
    let arm = ((b.w.min(b.h) / 5.0).min(long / 40.0).round() as i64).max(3 * t);
    let ct = ((t + 1) / 2).max(2); // thinner line
    let co = 1;
    let half = ct / 2;
    fill_rect(
        img,
        cx - arm - co,
        cy - half - co,
        cx + arm + co + 1,
        cy - half + ct + co,
        DARK,
    );
    fill_rect(
        img,
        cx - half - co,
        cy - arm - co,
        cx - half + ct + co,
        cy + arm + co + 1,
        DARK,
    );
    fill_rect(
        img,
        cx - arm,
        cy - half,
        cx + arm + 1,
        cy - half + ct,
        GREEN,
    );
    fill_rect(
        img,
        cx - half,
        cy - arm,
        cx - half + ct,
        cy + arm + 1,
        GREEN,
    );
}

/// Downscale so the long edge is at most `size` (never upscales).
pub fn fit_long_edge(img: &DynamicImage, size: u32) -> DynamicImage {
    let (w, h) = (img.width(), img.height());
    let long = w.max(h);
    if long <= size || size == 0 {
        return img.clone();
    }
    let scale = size as f64 / long as f64;
    let nw = ((w as f64 * scale).round() as u32).max(1);
    let nh = ((h as f64 * scale).round() as u32).max(1);
    img.resize_exact(nw, nh, FilterType::Triangle)
}

/// Crop rectangle (x, y, w, h) of at most `size`x`size` source pixels centred
/// on (cx, cy) and clamped to the image bounds. 1:1 pixels, never upscaled.
pub fn crop_rect(img_w: u32, img_h: u32, cx: f64, cy: f64, size: u32) -> (u32, u32, u32, u32) {
    let w = size.min(img_w).max(1);
    let h = size.min(img_h).max(1);
    let x = (cx - w as f64 / 2.0).round().clamp(0.0, (img_w - w) as f64) as u32;
    let y = (cy - h as f64 / 2.0).round().clamp(0.0, (img_h - h) as f64) as u32;
    (x, y, w, h)
}

static COUNTER: AtomicU32 = AtomicU32::new(0);

/// A unique file name stem for this invocation.
pub fn unique_stem(input: &Path) -> String {
    let stem = input
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image".into());
    let stem: String = stem
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .take(64)
        .collect();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{stem}-{}-{nanos}-{n}", std::process::id())
}

pub fn save_jpeg(img: &RgbImage, path: &Path, quality: u8) -> Result<()> {
    let f = std::fs::File::create(path).with_context(|| format!("creating {}", path.display()))?;
    let mut w = std::io::BufWriter::new(f);
    JpegEncoder::new_with_quality(&mut w, quality)
        .encode_image(img)
        .with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

pub fn absolute(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| {
        if p.is_absolute() {
            p.to_path_buf()
        } else {
            std::env::current_dir()
                .map(|d| d.join(p))
                .unwrap_or_else(|_| p.to_path_buf())
        }
    })
}

pub struct Rendered {
    pub overview: PathBuf,
    pub crop: Option<PathBuf>,
}

/// Render the overview (box drawn if `focus` is given) and, when both
/// `focus` and `crop_src` are given, the 1:1 crop. Both images must be in
/// display orientation and show the same full frame; they may differ in
/// resolution (e.g. a Lightroom preview for the overview and the full-size
/// embedded JPEG for the crop).
pub fn render(
    overview_src: &DynamicImage,
    crop_src: Option<&DynamicImage>,
    focus: Option<(f64, f64, Option<f64>, Option<f64>)>,
    out_dir: &Path,
    stem: &str,
    size: u32,
    crop_size: u32,
) -> Result<Rendered> {
    std::fs::create_dir_all(out_dir).with_context(|| format!("creating {}", out_dir.display()))?;
    let out_dir = absolute(out_dir);
    if overview_src.width() == 0 || overview_src.height() == 0 {
        return Err(anyhow!("empty source image"));
    }

    let mut ov = fit_long_edge(overview_src, size).to_rgb8();
    if let Some((nx, ny, nw, nh)) = focus {
        let b = px_box(ov.width(), ov.height(), nx, ny, nw, nh);
        draw_focus(&mut ov, b);
    }
    let overview = out_dir.join(format!("{stem}-overview.jpg"));
    save_jpeg(&ov, &overview, 88)?;

    let mut crop = None;
    if let (Some((nx, ny, nw, nh)), Some(crop_src)) = (focus, crop_src) {
        let (sw, sh) = (crop_src.width(), crop_src.height());
        if sw == 0 || sh == 0 {
            return Err(anyhow!("empty crop source image"));
        }
        let b = px_box(sw, sh, nx, ny, nw, nh);
        let (x, y, w, h) = crop_rect(sw, sh, b.cx, b.cy, crop_size);
        let mut c = crop_src.crop_imm(x, y, w, h).to_rgb8();
        draw_focus(
            &mut c,
            PxBox {
                cx: b.cx - x as f64,
                cy: b.cy - y as f64,
                ..b
            },
        );
        let p = out_dir.join(format!("{stem}-crop.jpg"));
        save_jpeg(&c, &p, 90)?;
        crop = Some(p);
    }
    Ok(Rendered { overview, crop })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crop_is_clamped() {
        assert_eq!(
            crop_rect(7008, 4672, 3504.0, 2336.0, 800),
            (3104, 1936, 800, 800)
        );
        assert_eq!(crop_rect(7008, 4672, 10.0, 10.0, 800), (0, 0, 800, 800));
        assert_eq!(
            crop_rect(7008, 4672, 7000.0, 4670.0, 800),
            (6208, 3872, 800, 800)
        );
        // Source smaller than crop size: whole image, no upscale.
        assert_eq!(crop_rect(600, 400, 300.0, 200.0, 800), (0, 0, 600, 400));
    }

    #[test]
    fn draws_green_box() {
        let mut img = RgbImage::from_pixel(200, 100, Rgb([128, 128, 128]));
        let b = px_box(200, 100, 0.5, 0.5, Some(0.2), Some(0.4));
        draw_focus(&mut img, b);
        // Left edge of the box at x=80, y=50 should be green.
        assert_eq!(*img.get_pixel(80, 50), GREEN);
        assert_eq!(*img.get_pixel(77, 50), DARK);
        // Centre crosshair.
        assert_eq!(*img.get_pixel(100, 50), GREEN);
        // Far corner untouched.
        assert_eq!(*img.get_pixel(0, 0), Rgb([128, 128, 128]));
        // Drawing a box partly outside the image must not panic.
        let b = px_box(200, 100, 0.99, 0.01, None, None);
        draw_focus(&mut img, b);
    }

    #[test]
    fn render_writes_files() {
        let dir = std::env::temp_dir().join(format!("focuspoint-test-{}", std::process::id()));
        let img = DynamicImage::ImageRgb8(RgbImage::from_pixel(1200, 800, Rgb([40, 40, 40])));
        let r = render(
            &img,
            Some(&img),
            Some((0.25, 0.5, None, None)),
            &dir,
            "t",
            600,
            400,
        )
        .unwrap();
        let ov = image::open(&r.overview).unwrap();
        assert_eq!((ov.width(), ov.height()), (600, 400));
        let c = image::open(r.crop.as_ref().unwrap()).unwrap();
        assert_eq!((c.width(), c.height()), (400, 400));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
