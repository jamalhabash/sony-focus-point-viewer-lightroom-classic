//! High-level metadata extraction: make/model/orientation, Sony focus info
//! and the list of embedded JPEG images.

use crate::container::{self, Kind};
use crate::sony::{self, SonyInfo};
use crate::tiff::{find, Entry, Tiff};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EmbeddedJpeg {
    /// Absolute byte offset in the file.
    pub offset: usize,
    pub len: usize,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Default)]
pub struct Meta {
    pub kind: Option<Kind>,
    pub has_exif: bool,
    pub make: Option<String>,
    pub model: Option<String>,
    pub software: Option<String>,
    pub orientation: Option<u16>,
    pub has_makernote: bool,
    pub sony: Option<SonyInfo>,
    /// JPEGs embedded in a TIFF/ARW (previews, JpgFromRaw) or listed in a
    /// JPEG's MPF index (Sony: a 1616x1080 preview), largest first.
    pub jpegs: Vec<EmbeddedJpeg>,
    /// Dimensions of the file itself when it is a JPEG.
    pub image_dims: Option<(u32, u32)>,
}

const TAG_MAKE: u16 = 0x010f;
const TAG_MODEL: u16 = 0x0110;
const TAG_ORIENTATION: u16 = 0x0112;
const TAG_SOFTWARE: u16 = 0x0131;
const TAG_STRIP_OFFSETS: u16 = 0x0111;
const TAG_STRIP_BYTES: u16 = 0x0117;
const TAG_COMPRESSION: u16 = 0x0103;
const TAG_SUBIFDS: u16 = 0x014a;
const TAG_JPEG_OFFSET: u16 = 0x0201;
const TAG_JPEG_LENGTH: u16 = 0x0202;
const TAG_EXIF_IFD: u16 = 0x8769;
const TAG_MAKERNOTE: u16 = 0x927c;

/// Parse a whole file's bytes. Returns Err(message) for unsupported formats.
pub fn read(data: &[u8]) -> Result<Meta, String> {
    let kind = container::sniff(data)
        .ok_or("unrecognised file format (expected ARW/TIFF, JPEG or HEIF)")?;
    let mut m = Meta {
        kind: Some(kind),
        ..Default::default()
    };
    let (tiff_start, tiff_len) = match kind {
        Kind::Tiff => (0, data.len()),
        Kind::Jpeg => {
            m.image_dims = container::jpeg_dimensions(data);
            m.jpegs = mpf_previews(data, m.image_dims);
            match container::jpeg_exif_offset(data) {
                Some(off) => (off, data.len() - off),
                None => return Ok(m),
            }
        }
        Kind::Heif => match container::heif_exif_range(data) {
            Ok(r) => r,
            Err(e) => {
                if e.contains("no Exif item") {
                    return Ok(m);
                }
                return Err(e);
            }
        },
    };
    let tdata = &data[tiff_start..tiff_start + tiff_len];
    let Some((t, ifd0)) = Tiff::parse(tdata) else {
        if kind == Kind::Tiff {
            return Err("invalid TIFF header".into());
        }
        return Ok(m);
    };
    m.has_exif = true;
    let chain = t.ifd_chain(ifd0, 16);
    let mut exif_ifd = None;
    for (i, (_, entries)) in chain.iter().enumerate() {
        if i == 0 {
            m.make = find(entries, TAG_MAKE).and_then(|e| t.ascii(e));
            m.model = find(entries, TAG_MODEL).and_then(|e| t.ascii(e));
            m.software = find(entries, TAG_SOFTWARE).and_then(|e| t.ascii(e));
            m.orientation = find(entries, TAG_ORIENTATION)
                .and_then(|e| t.uint(e))
                .map(|v| v as u16)
                .filter(|v| (1..=8).contains(v));
            exif_ifd = find(entries, TAG_EXIF_IFD)
                .and_then(|e| t.uint(e))
                .map(|v| v as usize);
        }
        if kind == Kind::Tiff {
            collect_jpegs(&t, entries, tiff_start, data, &mut m.jpegs);
            if let Some(sub) = find(entries, TAG_SUBIFDS) {
                for off in t.uints(sub).into_iter().take(8) {
                    if let Some((se, _)) = t.read_ifd(off as usize) {
                        collect_jpegs(&t, &se, tiff_start, data, &mut m.jpegs);
                    }
                }
            }
        }
    }
    let model = m.model.clone().unwrap_or_default();
    if let Some(off) = exif_ifd {
        if let Some((exif, _)) = t.read_ifd(off) {
            if let Some(mn) = find(&exif, TAG_MAKERNOTE) {
                m.has_makernote = true;
                let is_sony = m
                    .make
                    .as_deref()
                    .map(|s| s.to_ascii_uppercase().starts_with("SONY"))
                    .unwrap_or(false);
                if is_sony {
                    m.sony = sony::parse_makernote(&t, mn.value_offset, mn.count as usize, &model);
                }
            }
        }
    }
    m.jpegs
        .sort_by_key(|j| std::cmp::Reverse((j.width as u64) * (j.height as u64)));
    m.jpegs.dedup_by_key(|j| j.offset);
    Ok(m)
}

fn collect_jpegs(
    t: &Tiff,
    entries: &[Entry],
    base: usize,
    file: &[u8],
    out: &mut Vec<EmbeddedJpeg>,
) {
    let mut cands = Vec::new();
    let off = find(entries, TAG_JPEG_OFFSET).and_then(|e| t.uint(e));
    let len = find(entries, TAG_JPEG_LENGTH).and_then(|e| t.uint(e));
    if let (Some(o), Some(l)) = (off, len) {
        cands.push((o as usize, l as usize));
    }
    // Strip-based JPEG (compression 6/7, single strip).
    let comp = find(entries, TAG_COMPRESSION).and_then(|e| t.uint(e));
    if matches!(comp, Some(6) | Some(7)) {
        let so = find(entries, TAG_STRIP_OFFSETS)
            .map(|e| t.uints(e))
            .unwrap_or_default();
        let sb = find(entries, TAG_STRIP_BYTES)
            .map(|e| t.uints(e))
            .unwrap_or_default();
        if so.len() == 1 && sb.len() == 1 {
            cands.push((so[0] as usize, sb[0] as usize));
        }
    }
    for (o, l) in cands {
        let abs = base + o;
        let Some(bytes) = abs.checked_add(l).and_then(|end| file.get(abs..end)) else {
            continue;
        };
        if !bytes.starts_with(&[0xFF, 0xD8]) {
            continue;
        }
        if let Some((w, h)) = container::jpeg_dimensions(bytes) {
            out.push(EmbeddedJpeg {
                offset: abs,
                len: l,
                width: w,
                height: h,
            });
        }
    }
}

const TAG_MP_ENTRY: u16 = 0xb002;

/// Extra images of a JPEG listed in its MPF (APP2 "MPF\0") index whose
/// aspect ratio matches the main image (`dims`) within 1%, so they show the
/// same frame (camera previews; not e.g. stale previews of a cropped edit).
fn mpf_previews(data: &[u8], dims: Option<(u32, u32)>) -> Vec<EmbeddedJpeg> {
    let mut out = Vec::new();
    let Some((mw, mh)) = dims else {
        return out;
    };
    let main_aspect = mw as f64 / mh.max(1) as f64;
    for (marker, off, len) in container::jpeg_segments(data) {
        if marker != 0xE2 || len < 12 || !data[off..].starts_with(b"MPF\0") {
            continue;
        }
        // MPF offsets are relative to the TIFF header after "MPF\0".
        let base = off + 4;
        let Some((t, ifd0)) = Tiff::parse(&data[base..off + len]) else {
            continue;
        };
        let Some((entries, _)) = t.read_ifd(ifd0) else {
            continue;
        };
        let Some(e) = find(&entries, TAG_MP_ENTRY) else {
            continue;
        };
        // 16 bytes per image: attributes, size, offset, 2 dependents.
        // Entry 0 is the primary image itself.
        for i in 1..(e.count as usize / 16).min(16) {
            let at = e.value_offset + i * 16;
            let (Some(size), Some(rel)) = (t.u32_at(at + 4), t.u32_at(at + 8)) else {
                continue;
            };
            let (abs, l) = (base + rel as usize, size as usize);
            let Some(bytes) = abs.checked_add(l).and_then(|end| data.get(abs..end)) else {
                continue;
            };
            if !bytes.starts_with(&[0xFF, 0xD8]) {
                continue;
            }
            let Some((w, h)) = container::jpeg_dimensions(bytes) else {
                continue;
            };
            if ((w as f64 / h.max(1) as f64) / main_aspect - 1.0).abs() > 0.01 {
                continue;
            }
            out.push(EmbeddedJpeg {
                offset: abs,
                len: l,
                width: w,
                height: h,
            });
        }
    }
    out.sort_by_key(|j| std::cmp::Reverse((j.width as u64) * (j.height as u64)));
    out
}

/// Focus geometry in both the maker-note (sensor) space and normalised
/// display space.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Focus {
    pub image_width: u32,
    pub image_height: u32,
    pub x: u32,
    pub y: u32,
    pub frame: Option<(u32, u32)>,
    /// Fractions of the displayed (orientation-applied) frame.
    pub norm_x: f64,
    pub norm_y: f64,
    pub norm_w: Option<f64>,
    pub norm_h: Option<f64>,
}

/// Map a normalised point from stored (sensor) orientation to display
/// orientation for EXIF orientation `o`.
pub fn orient_point(o: u16, x: f64, y: f64) -> (f64, f64) {
    match o {
        2 => (1.0 - x, y),
        3 => (1.0 - x, 1.0 - y),
        4 => (x, 1.0 - y),
        5 => (y, x),
        6 => (1.0 - y, x),
        7 => (1.0 - y, 1.0 - x),
        8 => (y, 1.0 - x),
        _ => (x, y),
    }
}

pub fn swaps_axes(o: u16) -> bool {
    (5..=8).contains(&o)
}

pub fn focus_from(s: &SonyInfo, orientation: u16) -> Option<Focus> {
    let loc = s.focus_location.or(s.focus_location2)?;
    let [w, h, x, y] = loc;
    if w == 0 || h == 0 || (x == 0 && y == 0) || x > w || y > h {
        return None;
    }
    let frame = s
        .focus_frame_size
        .filter(|f| f[2] != 0 && f[0] > 0 && f[1] > 0)
        .map(|f| (f[0], f[1]));
    let (nx, ny) = orient_point(orientation, x as f64 / w as f64, y as f64 / h as f64);
    let (nw, nh) = match frame {
        Some((fw, fh)) => {
            let (a, b) = (fw as f64 / w as f64, fh as f64 / h as f64);
            if swaps_axes(orientation) {
                (Some(b), Some(a))
            } else {
                (Some(a), Some(b))
            }
        }
        None => (None, None),
    };
    Some(Focus {
        image_width: w,
        image_height: h,
        x,
        y,
        frame,
        norm_x: nx,
        norm_y: ny,
        norm_w: nw,
        norm_h: nh,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orientation_mapping() {
        // Point near top-left of the sensor image.
        let (x, y) = (0.1, 0.2);
        assert_eq!(orient_point(1, x, y), (0.1, 0.2));
        // Rotate 90 CW: top-left goes to top-right.
        let (dx, dy) = orient_point(6, x, y);
        assert!((dx - 0.8).abs() < 1e-9 && (dy - 0.1).abs() < 1e-9);
        // Rotate 270 CW: top-left goes to bottom-left.
        let (dx, dy) = orient_point(8, x, y);
        assert!((dx - 0.2).abs() < 1e-9 && (dy - 0.9).abs() < 1e-9);
        let (dx, dy) = orient_point(3, x, y);
        assert!((dx - 0.9).abs() < 1e-9 && (dy - 0.8).abs() < 1e-9);
    }

    #[test]
    fn focus_geometry() {
        let s = SonyInfo {
            focus_location: Some([7008, 4672, 3504, 1168]),
            focus_frame_size: Some([350, 351, 257]),
            ..Default::default()
        };
        let f = focus_from(&s, 1).unwrap();
        assert!((f.norm_x - 0.5).abs() < 1e-9 && (f.norm_y - 0.25).abs() < 1e-9);
        assert!((f.norm_w.unwrap() - 350.0 / 7008.0).abs() < 1e-9);
        let f = focus_from(&s, 6).unwrap();
        assert!((f.norm_x - 0.75).abs() < 1e-9 && (f.norm_y - 0.5).abs() < 1e-9);
        assert!((f.norm_w.unwrap() - 351.0 / 4672.0).abs() < 1e-9);

        let zero = SonyInfo {
            focus_location: Some([7008, 4672, 0, 0]),
            ..Default::default()
        };
        assert!(focus_from(&zero, 1).is_none());
        let invalid_frame = SonyInfo {
            focus_location: Some([7008, 4672, 10, 10]),
            focus_frame_size: Some([350, 351, 0]),
            ..Default::default()
        };
        assert_eq!(focus_from(&invalid_frame, 1).unwrap().frame, None);
    }
}
