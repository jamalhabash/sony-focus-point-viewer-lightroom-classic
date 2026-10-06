//! Fast JPEG decoding and encoding via libjpeg-turbo (the `mozjpeg-sys`
//! build, compiled statically from source).
//!
//! What makes it fast for our use:
//! * region decoding: `jpeg_skip_scanlines` + `jpeg_crop_scanline` only run
//!   the IDCT/colour conversion for the rows/columns of the crop, and stop
//!   reading entropy-coded data after the crop's last row;
//! * DCT-domain downscaling (`scale_num/8`) for overviews from big images;
//! * a baseline encoder without mozjpeg's slow trellis/progressive extras.
//!
//! libjpeg reports fatal errors through `error_exit`, which must not return;
//! we unwind out of it (the C code is built with `-fexceptions`) and catch
//! the unwind at the API boundary below.

use anyhow::{anyhow, Result};
use image::RgbImage;
use mozjpeg_sys::*;
use std::os::raw::{c_ulong, c_void};
use std::panic::{catch_unwind, resume_unwind, AssertUnwindSafe};

extern "C-unwind" {
    // libjpeg-turbo >= 1.5 API; present in mozjpeg but not in the bindings.
    fn jpeg_skip_scanlines(cinfo: &mut jpeg_decompress_struct, num_lines: JDIMENSION)
        -> JDIMENSION;
    fn jpeg_crop_scanline(
        cinfo: &mut jpeg_decompress_struct,
        xoffset: *mut JDIMENSION,
        width: *mut JDIMENSION,
    );
}

extern "C" {
    fn free(p: *mut c_void);
}

/// Payload of the unwind started in [`error_exit`].
struct JpegError(String);

unsafe extern "C-unwind" fn error_exit(cinfo: &mut jpeg_common_struct) {
    let mut msg = String::from("libjpeg error");
    if let Some(err) = cinfo.err.as_mut() {
        if let Some(fmt) = err.format_message {
            let buf = [0u8; 80];
            fmt(cinfo, &buf);
            let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            msg = String::from_utf8_lossy(&buf[..end]).into_owned();
        }
    }
    // resume_unwind skips the panic hook: no "thread panicked" noise.
    resume_unwind(Box::new(JpegError(msg)));
}

unsafe extern "C-unwind" fn silent(_cinfo: &mut jpeg_common_struct) {}

fn catch<T>(f: impl FnOnce() -> T) -> Result<T> {
    catch_unwind(AssertUnwindSafe(f)).map_err(|e| match e.downcast::<JpegError>() {
        Ok(j) => anyhow!("decoding JPEG: {}", j.0),
        Err(other) => resume_unwind(other),
    })
}

fn new_err() -> Box<jpeg_error_mgr> {
    // SAFETY: plain C struct; jpeg_std_error fills every field.
    let mut err: Box<jpeg_error_mgr> = Box::new(unsafe { std::mem::zeroed() });
    unsafe { jpeg_std_error(&mut err) };
    err.error_exit = Some(error_exit);
    err.output_message = Some(silent); // warnings (corrupt data) stay quiet
    err
}

/// What to decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Want {
    /// The whole image at full resolution.
    Full,
    /// The whole image, DCT-downscaled by the largest factor `n/8` that
    /// keeps the long edge at least this many pixels.
    MinLongEdge(u32),
    /// A region (x, y, w, h) at full resolution.
    Region(u32, u32, u32, u32),
}

/// Decode a JPEG to RGB.
pub fn decode(data: &[u8], want: Want) -> Result<RgbImage> {
    let mut err = new_err();
    // SAFETY: zeroed is the documented initial state before jpeg_create_*.
    let mut ci: Box<jpeg_decompress_struct> = Box::new(unsafe { std::mem::zeroed() });
    ci.common.err = &mut *err;
    let created = catch(|| unsafe { jpeg_create_decompress(&mut *ci) });
    created?;
    let res = catch(|| unsafe { decode_inner(&mut ci, data, want) }).and_then(|r| r);
    // SAFETY: ci was created above; destroy frees all libjpeg memory, also
    // after an error unwound out of the middle of decoding.
    unsafe { jpeg_destroy_decompress(&mut ci) };
    drop(err);
    res
}

unsafe fn decode_inner(
    ci: &mut jpeg_decompress_struct,
    data: &[u8],
    want: Want,
) -> Result<RgbImage> {
    if data.is_empty() {
        return Err(anyhow!("decoding JPEG: empty data"));
    }
    jpeg_mem_src(ci, data.as_ptr(), data.len() as c_ulong);
    jpeg_read_header(ci, 1);
    ci.out_color_space = J_COLOR_SPACE::JCS_RGB;
    ci.dct_method = J_DCT_METHOD::JDCT_ISLOW;
    let (iw, ih) = (ci.image_width, ci.image_height);
    if iw == 0 || ih == 0 {
        return Err(anyhow!("decoding JPEG: zero size"));
    }
    if let Want::MinLongEdge(min) = want {
        let long = iw.max(ih) as u64;
        // Smallest n in 1..=8 with ceil(long * n / 8) >= min.
        let n = (1..=8u64)
            .find(|n| (long * n).div_ceil(8) >= min as u64)
            .unwrap_or(8);
        ci.scale_num = n as u32;
        ci.scale_denom = 8;
    }
    jpeg_start_decompress(ci);
    let (ow, oh) = (ci.output_width, ci.output_height);
    if ci.output_components != 3 {
        return Err(anyhow!(
            "decoding JPEG: unexpected {} output components",
            ci.output_components
        ));
    }
    let (rx, ry, rw, rh) = match want {
        Want::Region(x, y, w, h) => {
            if w == 0 || h == 0 || x.saturating_add(w) > ow || y.saturating_add(h) > oh {
                return Err(anyhow!(
                    "decoding JPEG: region {x},{y} {w}x{h} outside {ow}x{oh}"
                ));
            }
            (x, y, w, h)
        }
        _ => (0, 0, ow, oh),
    };
    // Crop horizontally: libjpeg widens the window to iMCU boundaries.
    let (mut cx, mut cw) = (rx, rw);
    if rw < ow {
        jpeg_crop_scanline(ci, &mut cx, &mut cw);
    }
    let dx = (rx - cx) as usize;
    if ry > 0 && jpeg_skip_scanlines(ci, ry) != ry {
        return Err(anyhow!("decoding JPEG: truncated data"));
    }
    let row_len = cw as usize * 3;
    let mut row = vec![0u8; row_len];
    let mut out = vec![0u8; rw as usize * rh as usize * 3];
    let out_row = rw as usize * 3;
    let mut y = 0usize;
    while y < rh as usize {
        let mut p = row.as_mut_ptr();
        if jpeg_read_scanlines(ci, &mut p, 1) != 1 {
            return Err(anyhow!("decoding JPEG: truncated data"));
        }
        out[y * out_row..(y + 1) * out_row].copy_from_slice(&row[dx * 3..dx * 3 + out_row]);
        y += 1;
    }
    if rh == oh {
        jpeg_finish_decompress(ci);
    } else {
        jpeg_abort_decompress(ci);
    }
    RgbImage::from_raw(rw, rh, out).ok_or_else(|| anyhow!("decoding JPEG: bad buffer"))
}

/// Encode RGB as a baseline JPEG (libjpeg-turbo defaults, 4:2:0).
pub fn encode(img: &RgbImage, quality: u8) -> Result<Vec<u8>> {
    let (w, h) = img.dimensions();
    if w == 0 || h == 0 {
        return Err(anyhow!("encoding JPEG: empty image"));
    }
    let mut err = new_err();
    // SAFETY: as in `decode`.
    let mut c: Box<jpeg_compress_struct> = Box::new(unsafe { std::mem::zeroed() });
    c.common.err = &mut *err;
    catch(|| unsafe { jpeg_create_compress(&mut *c) })?;
    let mut buf: *mut u8 = std::ptr::null_mut();
    let mut size: c_ulong = 0;
    let res = catch(|| unsafe {
        jpeg_mem_dest(&mut c, &mut buf, &mut size);
        c.image_width = w;
        c.image_height = h;
        c.input_components = 3;
        c.in_color_space = J_COLOR_SPACE::JCS_RGB;
        jpeg_c_set_int_param(
            &mut c,
            J_INT_PARAM::JINT_COMPRESS_PROFILE,
            JCP_FASTEST as i32,
        );
        jpeg_set_defaults(&mut c);
        jpeg_set_quality(&mut c, quality.clamp(1, 100) as i32, 1);
        c.dct_method = J_DCT_METHOD::JDCT_ISLOW;
        c.optimize_coding = 0;
        jpeg_start_compress(&mut c, 1);
        let stride = w as usize * 3;
        let raw = img.as_raw();
        while c.next_scanline < h {
            let p = raw.as_ptr().add(c.next_scanline as usize * stride);
            jpeg_write_scanlines(&mut c, &p, 1);
        }
        jpeg_finish_compress(&mut c);
    });
    let out = if res.is_ok() && !buf.is_null() {
        // SAFETY: libjpeg wrote `size` bytes into `buf`.
        Some(unsafe { std::slice::from_raw_parts(buf, size as usize) }.to_vec())
    } else {
        None
    };
    // SAFETY: created above; jpeg_mem_dest's buffer is malloc'ed and ours.
    unsafe {
        jpeg_destroy_compress(&mut c);
        if !buf.is_null() {
            free(buf as *mut c_void);
        }
    }
    drop(err);
    res.map_err(|e| anyhow!("{}", e.to_string().replace("decoding", "encoding")))?;
    out.ok_or_else(|| anyhow!("encoding JPEG: no output"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgb;

    fn pattern(w: u32, h: u32) -> RgbImage {
        RgbImage::from_fn(w, h, |x, y| {
            Rgb([
                (x * 255 / w) as u8,
                (y * 255 / h) as u8,
                ((x / 40 + y / 40) % 2 * 200) as u8,
            ])
        })
    }

    fn close(a: &RgbImage, b: &RgbImage, tol: i32) -> bool {
        a.dimensions() == b.dimensions()
            && a.as_raw()
                .iter()
                .zip(b.as_raw())
                .all(|(&p, &q)| (p as i32 - q as i32).abs() <= tol)
    }

    #[test]
    fn roundtrip_full_scaled_region() {
        let img = pattern(640, 400);
        let bytes = encode(&img, 95).unwrap();
        assert_eq!(&bytes[..2], &[0xFF, 0xD8]);
        let full = decode(&bytes, Want::Full).unwrap();
        assert_eq!(full.dimensions(), (640, 400));
        let s = decode(&bytes, Want::MinLongEdge(150)).unwrap();
        assert_eq!(s.dimensions(), (160, 100)); // 2/8
        let s = decode(&bytes, Want::MinLongEdge(161)).unwrap();
        assert_eq!(s.dimensions(), (240, 150)); // 3/8
        let s = decode(&bytes, Want::MinLongEdge(5000)).unwrap();
        assert_eq!(s.dimensions(), (640, 400));
        // A region equals the same window of the full decode.
        for &(x, y, w, h) in &[(0, 0, 640, 400), (101, 37, 203, 150), (600, 390, 40, 10)] {
            let r = decode(&bytes, Want::Region(x, y, w, h)).unwrap();
            let f = image::imageops::crop_imm(&full, x, y, w, h).to_image();
            assert!(close(&r, &f, 3), "region {x},{y} {w}x{h}");
        }
        assert!(decode(&bytes, Want::Region(600, 0, 41, 10)).is_err());
    }

    #[test]
    fn errors_are_reported_not_fatal() {
        assert!(decode(b"", Want::Full).is_err());
        assert!(decode(b"\xFF\xD8\xFF\xE0garbage", Want::Full).is_err());
        let e = decode(b"not a jpeg at all", Want::Full).unwrap_err();
        assert!(e.to_string().contains("JPEG"), "{e}");
        // Truncated: libjpeg pads with grey and warns; must not crash.
        let bytes = encode(&pattern(64, 64), 80).unwrap();
        let _ = decode(&bytes[..bytes.len() / 2], Want::Full);
        // Still usable afterwards.
        assert!(decode(&bytes, Want::Full).is_ok());
    }
}
