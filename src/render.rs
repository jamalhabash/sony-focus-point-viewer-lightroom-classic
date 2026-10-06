//! Image loading, orientation, focus-box drawing, cropping and JPEG output.

use crate::jpeg;
use anyhow::{anyhow, Context, Result};
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

/// Focus geometry as fractions of the displayed frame: (x, y, w, h).
pub type NormFocus = (f64, f64, Option<f64>, Option<f64>);

/// An image to render from.
#[derive(Clone, Copy)]
pub enum Source<'a> {
    /// Encoded JPEG in stored (sensor) orientation; the EXIF `orientation`
    /// is applied after decoding. `width`/`height` are the stored size.
    Jpeg {
        bytes: &'a [u8],
        width: u32,
        height: u32,
        orientation: u16,
    },
    /// Already decoded, in display orientation.
    Decoded(&'a RgbImage),
}

impl<'a> Source<'a> {
    /// A JPEG source; its size is read from the SOF header (no decoding).
    pub fn jpeg(bytes: &'a [u8], orientation: u16) -> Result<Self> {
        let (width, height) = crate::container::jpeg_dimensions(bytes)
            .ok_or_else(|| anyhow!("decoding JPEG: no frame header"))?;
        Ok(Source::Jpeg {
            bytes,
            width,
            height,
            orientation,
        })
    }

    /// Size in display orientation.
    pub fn display_dims(&self) -> (u32, u32) {
        match *self {
            Source::Jpeg {
                width,
                height,
                orientation,
                ..
            } => {
                if crate::meta::swaps_axes(orientation) {
                    (height, width)
                } else {
                    (width, height)
                }
            }
            Source::Decoded(img) => img.dimensions(),
        }
    }

    /// The whole frame in display orientation, long edge reduced to `size`
    /// (never upscaled). Big JPEGs are downscaled in the DCT domain first.
    pub fn overview(&self, size: u32) -> Result<RgbImage> {
        let (dw, dh) = self.display_dims();
        let (tw, th) = fit_dims(dw, dh, size);
        let img = match *self {
            Source::Jpeg {
                bytes, orientation, ..
            } => {
                let img = jpeg::decode(bytes, jpeg::Want::MinLongEdge(size))
                    .or_else(|_| fallback_decode(bytes))?;
                orient(img, orientation)
            }
            Source::Decoded(img) => {
                if img.dimensions() == (tw, th) {
                    return Ok(img.clone());
                }
                return resize(img, tw, th);
            }
        };
        if img.dimensions() == (tw, th) {
            Ok(img)
        } else {
            resize(&img, tw, th)
        }
    }

    /// A 1:1 region given in display coordinates.
    pub fn region(&self, x: u32, y: u32, w: u32, h: u32) -> Result<RgbImage> {
        match *self {
            Source::Jpeg {
                bytes,
                width,
                height,
                orientation,
            } => {
                let (sx, sy, sw, sh) = stored_rect(orientation, width, height, (x, y, w, h));
                let img = match jpeg::decode(bytes, jpeg::Want::Region(sx, sy, sw, sh)) {
                    Ok(img) => img,
                    Err(e) => {
                        let full = fallback_decode(bytes).map_err(|_| e)?;
                        if full.dimensions() != (width, height) {
                            return Err(anyhow!("decoding JPEG: unexpected size"));
                        }
                        image::imageops::crop_imm(&full, sx, sy, sw, sh).to_image()
                    }
                };
                Ok(orient(img, orientation))
            }
            Source::Decoded(img) => Ok(image::imageops::crop_imm(img, x, y, w, h).to_image()),
        }
    }
}

/// Decoder of last resort (CMYK, arithmetic coding, ...): the `image` crate.
fn fallback_decode(bytes: &[u8]) -> Result<RgbImage> {
    Ok(decode_jpeg(bytes)?.into_rgb8())
}

/// Apply an EXIF orientation to an RGB image.
pub fn orient(img: RgbImage, o: u16) -> RgbImage {
    if o <= 1 || o > 8 {
        return img;
    }
    apply_orientation(DynamicImage::ImageRgb8(img), o).into_rgb8()
}

/// Map a rectangle in display coordinates to the stored (pre-orientation)
/// image of `w`x`h`.
pub fn stored_rect(o: u16, w: u32, h: u32, r: (u32, u32, u32, u32)) -> (u32, u32, u32, u32) {
    let (w, h) = (w as i64, h as i64);
    let map = |x: i64, y: i64| match o {
        2 => (w - x, y),
        3 => (w - x, h - y),
        4 => (x, h - y),
        5 => (y, x),
        6 => (y, h - x),
        7 => (w - y, h - x),
        8 => (w - y, x),
        _ => (x, y),
    };
    let (x0, y0) = map(r.0 as i64, r.1 as i64);
    let (x1, y1) = map((r.0 + r.2) as i64, (r.1 + r.3) as i64);
    let (xa, xb) = (x0.min(x1), x0.max(x1));
    let (ya, yb) = (y0.min(y1), y0.max(y1));
    (xa as u32, ya as u32, (xb - xa) as u32, (yb - ya) as u32)
}

/// Size with the long edge reduced to `size` (never upscaled).
pub fn fit_dims(w: u32, h: u32, size: u32) -> (u32, u32) {
    let long = w.max(h);
    if long <= size || size == 0 {
        return (w, h);
    }
    let scale = size as f64 / long as f64;
    (
        ((w as f64 * scale).round() as u32).max(1),
        ((h as f64 * scale).round() as u32).max(1),
    )
}

/// Bilinear (triangle) resampling, SIMD-accelerated.
pub fn resize(img: &RgbImage, w: u32, h: u32) -> Result<RgbImage> {
    use fast_image_resize as fir;
    let src = fir::images::ImageRef::new(
        img.width(),
        img.height(),
        img.as_raw(),
        fir::PixelType::U8x3,
    )?;
    let mut dst = fir::images::Image::new(w, h, fir::PixelType::U8x3);
    let opts = fir::ResizeOptions::new()
        .resize_alg(fir::ResizeAlg::Convolution(fir::FilterType::Bilinear));
    fir::Resizer::new().resize(&src, &mut dst, &opts)?;
    RgbImage::from_raw(w, h, dst.into_vec()).ok_or_else(|| anyhow!("resize: bad buffer"))
}

static TMP_COUNTER: AtomicU32 = AtomicU32::new(0);

/// Write `bytes` to `path` atomically: a temporary file in the same
/// directory, then rename (concurrent writers of the same path are fine).
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let name = path
        .file_name()
        .ok_or_else(|| anyhow!("bad output path {}", path.display()))?
        .to_string_lossy();
    let n = TMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp = path.with_file_name(format!("{name}.{}-{n}.tmp", std::process::id()));
    let res = std::fs::write(&tmp, bytes)
        .and_then(|()| std::fs::rename(&tmp, path))
        .with_context(|| format!("writing {}", path.display()));
    if res.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    res
}

pub const OVERVIEW_QUALITY: u8 = 88;
pub const CROP_QUALITY: u8 = 90;

/// Write the overview: whole frame, long edge `size`, focus box if known.
/// Returns the size of the written image.
pub fn render_overview(
    src: &Source,
    focus: Option<NormFocus>,
    size: u32,
    path: &Path,
) -> Result<(u32, u32)> {
    let (w, h) = src.display_dims();
    if w == 0 || h == 0 {
        return Err(anyhow!("empty source image"));
    }
    let mut ov = src.overview(size)?;
    if let Some((nx, ny, nw, nh)) = focus {
        let b = px_box(ov.width(), ov.height(), nx, ny, nw, nh);
        draw_focus(&mut ov, b);
    }
    write_atomic(path, &jpeg::encode(&ov, OVERVIEW_QUALITY)?)?;
    Ok(ov.dimensions())
}

/// Write the 1:1 crop (at most `crop_size` square) around the focus point,
/// with the focus box drawn. Returns the size of the written image.
pub fn render_crop(
    src: &Source,
    focus: NormFocus,
    crop_size: u32,
    path: &Path,
) -> Result<(u32, u32)> {
    let (sw, sh) = src.display_dims();
    if sw == 0 || sh == 0 {
        return Err(anyhow!("empty crop source image"));
    }
    let (nx, ny, nw, nh) = focus;
    let b = px_box(sw, sh, nx, ny, nw, nh);
    let (x, y, w, h) = crop_rect(sw, sh, b.cx, b.cy, crop_size);
    let mut c = src.region(x, y, w, h)?;
    draw_focus(
        &mut c,
        PxBox {
            cx: b.cx - x as f64,
            cy: b.cy - y as f64,
            ..b
        },
    );
    write_atomic(path, &jpeg::encode(&c, CROP_QUALITY)?)?;
    Ok(c.dimensions())
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
        std::fs::create_dir_all(&dir).unwrap();
        let img = RgbImage::from_pixel(1200, 800, Rgb([40, 40, 40]));
        let focus = (0.25, 0.5, None, None);
        let ov = dir.join("t-overview.jpg");
        let cr = dir.join("t-crop.jpg");
        for src in [
            Source::Decoded(&img),
            Source::jpeg(&jpeg::encode(&img, 90).unwrap(), 1).unwrap(),
        ] {
            assert_eq!(
                render_overview(&src, Some(focus), 600, &ov).unwrap(),
                (600, 400)
            );
            assert_eq!(render_crop(&src, focus, 400, &cr).unwrap(), (400, 400));
            let o = image::open(&ov).unwrap();
            assert_eq!((o.width(), o.height()), (600, 400));
            let c = image::open(&cr).unwrap();
            assert_eq!((c.width(), c.height()), (400, 400));
        }
        // No temp files left behind.
        let names: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        assert!(names.iter().all(|n| !n.ends_with(".tmp")), "{names:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Cropping a region of the stored image and then orienting it must equal
    /// orienting first and cropping the display image, for all 8 orientations.
    #[test]
    fn region_matches_orient_then_crop() {
        let (w, h) = (48u32, 32u32);
        let stored = RgbImage::from_fn(w, h, |x, y| Rgb([x as u8, y as u8, 7]));
        for o in 1..=8u16 {
            let disp = orient(stored.clone(), o);
            let (dw, dh) = disp.dimensions();
            for &(x, y, cw, ch) in &[(0, 0, dw, dh), (3, 5, 10, 7), (dw - 4, dh - 6, 4, 6)] {
                let want = image::imageops::crop_imm(&disp, x, y, cw, ch).to_image();
                let (sx, sy, sw, sh) = stored_rect(o, w, h, (x, y, cw, ch));
                let got = orient(
                    image::imageops::crop_imm(&stored, sx, sy, sw, sh).to_image(),
                    o,
                );
                assert_eq!(got, want, "orientation {o} rect {x},{y} {cw}x{ch}");
            }
        }
    }

    #[test]
    fn jpeg_source_orientation_and_overview_size() {
        let stored = RgbImage::from_fn(320, 200, |x, _| {
            if x < 160 {
                Rgb([250, 10, 10])
            } else {
                Rgb([10, 10, 250])
            }
        });
        let bytes = jpeg::encode(&stored, 95).unwrap();
        // Orientation 6 (rotate 90 CW): stored left half ends up on top.
        let src = Source::jpeg(&bytes, 6).unwrap();
        assert_eq!(src.display_dims(), (200, 320));
        let ov = src.overview(100).unwrap();
        assert_eq!(ov.dimensions(), (63, 100));
        let top = src.region(50, 10, 100, 100).unwrap();
        assert_eq!(top.dimensions(), (100, 100));
        assert!(
            top.get_pixel(50, 50)[0] > 200,
            "{:?}",
            top.get_pixel(50, 50)
        );
        let bottom = src.region(50, 210, 100, 100).unwrap();
        assert!(bottom.get_pixel(50, 50)[2] > 200);
    }
}
