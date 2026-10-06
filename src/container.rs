//! File-format sniffing and extraction of the Exif TIFF block from JPEG,
//! TIFF/ARW and HEIF (ISOBMFF) containers, plus small JPEG helpers.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Tiff,
    Jpeg,
    Heif,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Tiff => "tiff",
            Kind::Jpeg => "jpeg",
            Kind::Heif => "heif",
        }
    }
}

pub fn sniff(data: &[u8]) -> Option<Kind> {
    if data.starts_with(b"II*\0") || data.starts_with(b"MM\0*") {
        return Some(Kind::Tiff);
    }
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(Kind::Jpeg);
    }
    if data.len() >= 12 && &data[4..8] == b"ftyp" {
        let brand = &data[8..12];
        let heif_brands: [&[u8; 4]; 8] = [
            b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx", b"mif1", b"msf1",
        ];
        if heif_brands.iter().any(|b| &b[..] == brand) {
            return Some(Kind::Heif);
        }
        // Check compatible brands too.
        let size = be32(data, 0).unwrap_or(0) as usize;
        let end = size.min(data.len());
        let mut i = 16;
        while i + 4 <= end {
            if heif_brands.iter().any(|b| b[..] == data[i..i + 4]) {
                return Some(Kind::Heif);
            }
            i += 4;
        }
    }
    None
}

fn be16(d: &[u8], off: usize) -> Option<u16> {
    let b = d.get(off..off.checked_add(2)?)?;
    Some(u16::from_be_bytes([b[0], b[1]]))
}

fn be32(d: &[u8], off: usize) -> Option<u32> {
    let b = d.get(off..off.checked_add(4)?)?;
    Some(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

fn be64(d: &[u8], off: usize) -> Option<u64> {
    let b = d.get(off..off.checked_add(8)?)?;
    let mut a = [0u8; 8];
    a.copy_from_slice(b);
    Some(u64::from_be_bytes(a))
}

/// Read a big-endian unsigned integer of 0, 4 or 8 bytes.
fn be_n(d: &[u8], off: usize, n: usize) -> Option<u64> {
    match n {
        0 => Some(0),
        4 => be32(d, off).map(u64::from),
        8 => be64(d, off),
        _ => None,
    }
}

/// Iterate JPEG marker segments up to (not including) SOS.
/// Yields (marker, payload_offset, payload_len).
pub fn jpeg_segments(data: &[u8]) -> Vec<(u8, usize, usize)> {
    let mut out = Vec::new();
    if !data.starts_with(&[0xFF, 0xD8]) {
        return out;
    }
    let mut i = 2;
    while i + 4 <= data.len() {
        if data[i] != 0xFF {
            break;
        }
        let marker = data[i + 1];
        if marker == 0xFF {
            i += 1; // fill byte
            continue;
        }
        if marker == 0xD8 || (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            i += 2;
            continue;
        }
        if marker == 0xD9 {
            break;
        }
        let len = match be16(data, i + 2) {
            Some(l) if l >= 2 => l as usize,
            _ => break,
        };
        let payload = i + 4;
        let plen = len - 2;
        if payload + plen > data.len() {
            break;
        }
        out.push((marker, payload, plen));
        if marker == 0xDA {
            break;
        }
        i = payload + plen;
    }
    out
}

/// Width and height from a JPEG's SOF segment.
pub fn jpeg_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    for (m, off, len) in jpeg_segments(data) {
        let is_sof = (0xC0..=0xCF).contains(&m) && m != 0xC4 && m != 0xC8 && m != 0xCC;
        if is_sof && len >= 5 {
            let h = be16(data, off + 1)? as u32;
            let w = be16(data, off + 3)? as u32;
            if w > 0 && h > 0 {
                return Some((w, h));
            }
        }
    }
    None
}

/// Offset of the TIFF header inside a JPEG's APP1 Exif segment.
pub fn jpeg_exif_offset(data: &[u8]) -> Option<usize> {
    jpeg_segments(data).into_iter().find_map(|(m, off, len)| {
        (m == 0xE1 && len > 14 && data[off..].starts_with(b"Exif\0\0")).then_some(off + 6)
    })
}

/// Location of the TIFF header (and its maximum length) in a HEIF file's
/// `Exif` item. Returns Err with a human-readable reason on failure.
pub fn heif_exif_range(data: &[u8]) -> Result<(usize, usize), String> {
    let meta = find_box(data, 0, data.len(), b"meta").ok_or("HEIF: no meta box")?;
    // meta is a FullBox: skip version/flags.
    let (mstart, mend) = (meta.0 + 4, meta.1);
    let iinf = find_box(data, mstart, mend, b"iinf").ok_or("HEIF: no iinf box")?;
    let iloc = find_box(data, mstart, mend, b"iloc").ok_or("HEIF: no iloc box")?;
    let idat = find_box(data, mstart, mend, b"idat");

    // iinf
    let (mut p, iend) = iinf;
    let ver = *data.get(p).ok_or("HEIF: bad iinf")?;
    p += 4;
    let count = if ver == 0 {
        let c = be16(data, p).ok_or("HEIF: bad iinf")? as usize;
        p += 2;
        c
    } else {
        let c = be32(data, p).ok_or("HEIF: bad iinf")? as usize;
        p += 4;
        c
    };
    let mut exif_id = None;
    for _ in 0..count.min(10_000) {
        let Some((bstart, bend, typ)) = read_box_header(data, p, iend) else {
            break;
        };
        if &typ == b"infe" {
            let v = data.get(bstart).copied().unwrap_or(0);
            let q = bstart + 4;
            if v >= 2 {
                let (id, q) = if v == 2 {
                    (be16(data, q).map(u32::from), q + 2)
                } else {
                    (be32(data, q), q + 4)
                };
                let item_type = data.get(q + 2..q + 6);
                if let (Some(id), Some(t)) = (id, item_type) {
                    if t == b"Exif" {
                        exif_id = Some(id);
                        break;
                    }
                }
            }
        }
        p = bend;
    }
    let exif_id = exif_id.ok_or("HEIF: no Exif item")?;

    // iloc
    let (mut p, _iend) = iloc;
    let ver = *data.get(p).ok_or("HEIF: bad iloc")?;
    p += 4;
    let b0 = *data.get(p).ok_or("HEIF: bad iloc")?;
    let b1 = *data.get(p + 1).ok_or("HEIF: bad iloc")?;
    p += 2;
    let offset_size = (b0 >> 4) as usize;
    let length_size = (b0 & 0xF) as usize;
    let base_offset_size = (b1 >> 4) as usize;
    let index_size = if ver == 1 || ver == 2 {
        (b1 & 0xF) as usize
    } else {
        0
    };
    let item_count = if ver < 2 {
        let c = be16(data, p).ok_or("HEIF: bad iloc")? as usize;
        p += 2;
        c
    } else {
        let c = be32(data, p).ok_or("HEIF: bad iloc")? as usize;
        p += 4;
        c
    };
    for _ in 0..item_count.min(100_000) {
        let id = if ver < 2 {
            let v = be16(data, p).map(u32::from);
            p += 2;
            v
        } else {
            let v = be32(data, p);
            p += 4;
            v
        }
        .ok_or("HEIF: bad iloc")?;
        let mut method = 0;
        if ver == 1 || ver == 2 {
            method = be16(data, p).ok_or("HEIF: bad iloc")? & 0xF;
            p += 2;
        }
        p += 2; // data_reference_index
        let base = be_n(data, p, base_offset_size).ok_or("HEIF: bad iloc")?;
        p += base_offset_size;
        let extents = be16(data, p).ok_or("HEIF: bad iloc")? as usize;
        p += 2;
        let mut first: Option<(u64, u64)> = None;
        for _ in 0..extents {
            p += index_size;
            let off = be_n(data, p, offset_size).ok_or("HEIF: bad iloc")?;
            p += offset_size;
            let len = be_n(data, p, length_size).ok_or("HEIF: bad iloc")?;
            p += length_size;
            if first.is_none() {
                first = Some((off, len));
            }
        }
        if id != exif_id {
            continue;
        }
        if extents != 1 {
            return Err(format!(
                "HEIF: Exif item has {extents} extents (unsupported)"
            ));
        }
        let (off, len) = first.ok_or("HEIF: bad iloc")?;
        let start = match method {
            0 => base + off,
            1 => {
                let (ds, _) = idat.ok_or("HEIF: idat missing")?;
                ds as u64 + base + off
            }
            _ => return Err("HEIF: unsupported iloc construction method".into()),
        } as usize;
        let len = if len == 0 {
            data.len().saturating_sub(start)
        } else {
            len as usize
        };
        let end = start
            .checked_add(len)
            .filter(|&e| e <= data.len())
            .ok_or("HEIF: Exif item out of bounds")?;
        // Exif item payload: u32 offset to TIFF header, then (usually "Exif\0\0") TIFF.
        let skip = be32(data, start).ok_or("HEIF: Exif item too short")? as usize;
        let tiff = start + 4 + skip;
        if tiff + 8 > end {
            return Err("HEIF: bad Exif item header".into());
        }
        // Be lenient: find the TIFF header near the expected position.
        for cand in [tiff, start + 4, start + 10] {
            if let Some(h) = data.get(cand..cand + 4) {
                if h == b"II*\0" || h == b"MM\0*" {
                    return Ok((cand, end - cand));
                }
            }
        }
        return Err("HEIF: Exif item has no TIFF header".into());
    }
    Err("HEIF: Exif item not found in iloc".into())
}

/// Read a box header at `p` (bounded by `end`). Returns (payload_start, box_end, type).
fn read_box_header(data: &[u8], p: usize, end: usize) -> Option<(usize, usize, [u8; 4])> {
    let size = be32(data, p)? as u64;
    let typ: [u8; 4] = data.get(p + 4..p + 8)?.try_into().ok()?;
    let (hdr, size) = match size {
        1 => (16, be64(data, p + 8)?),
        0 => (8, (end - p) as u64),
        s => (8, s),
    };
    if size < hdr as u64 {
        return None;
    }
    let bend = p.checked_add(size as usize)?;
    if bend > end {
        return None;
    }
    Some((p + hdr, bend, typ))
}

/// Find the first child box of type `want` within [start, end).
/// Returns (payload_start, box_end).
fn find_box(data: &[u8], start: usize, end: usize, want: &[u8; 4]) -> Option<(usize, usize)> {
    let mut p = start;
    while p + 8 <= end {
        let (ps, be, typ) = read_box_header(data, p, end)?;
        if &typ == want {
            return Some((ps, be));
        }
        p = be;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bx(typ: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut v = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(typ);
        v.extend_from_slice(payload);
        v
    }

    #[test]
    fn jpeg_segments_and_exif() {
        let mut j = vec![0xFF, 0xD8];
        // APP0
        j.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x04, 0xAA, 0xBB]);
        // APP1 Exif
        let mut app1 = b"Exif\0\0".to_vec();
        app1.extend_from_slice(b"II*\0\x08\0\0\0\0\0\0\0\0\0");
        j.extend_from_slice(&[0xFF, 0xE1]);
        j.extend_from_slice(&((app1.len() + 2) as u16).to_be_bytes());
        j.extend_from_slice(&app1);
        // SOF0: precision, h=480, w=640
        j.extend_from_slice(&[
            0xFF, 0xC0, 0x00, 0x0B, 8, 0x01, 0xE0, 0x02, 0x80, 1, 1, 0x11, 0,
        ]);
        j.extend_from_slice(&[0xFF, 0xD9]);
        assert_eq!(sniff(&j), Some(Kind::Jpeg));
        let off = jpeg_exif_offset(&j).unwrap();
        assert_eq!(&j[off..off + 4], b"II*\0");
        assert_eq!(jpeg_dimensions(&j), Some((640, 480)));
    }

    #[test]
    fn heif_exif_item() {
        let tiff = b"MM\0*\0\0\0\x08\0\0\0\0\0\0".to_vec();
        let mut exif_payload = 6u32.to_be_bytes().to_vec();
        exif_payload.extend_from_slice(b"Exif\0\0");
        exif_payload.extend_from_slice(&tiff);

        let ftyp = bx(b"ftyp", b"heic\0\0\0\0mif1heic");
        // infe v2: version/flags, item_ID u16, protection u16, type "Exif", name "\0"
        let mut infe1 = vec![2, 0, 0, 0, 0, 1, 0, 0];
        infe1.extend_from_slice(b"hvc1\0");
        let mut infe2 = vec![2, 0, 0, 0, 0, 2, 0, 0];
        infe2.extend_from_slice(b"Exif\0");
        let mut iinf_payload = vec![0, 0, 0, 0, 0, 2];
        iinf_payload.extend(bx(b"infe", &infe1));
        iinf_payload.extend(bx(b"infe", &infe2));
        let iinf = bx(b"iinf", &iinf_payload);

        // iloc v0, offset_size=4 length_size=4 base=0; 2 items, 1 extent each.
        let build_iloc = |exif_off: u32| {
            let mut p = vec![0, 0, 0, 0, 0x44, 0x00, 0, 2];
            p.extend_from_slice(&[0, 1, 0, 0, 0, 1]);
            p.extend_from_slice(&0u32.to_be_bytes());
            p.extend_from_slice(&0u32.to_be_bytes());
            p.extend_from_slice(&[0, 2, 0, 0, 0, 1]);
            p.extend_from_slice(&exif_off.to_be_bytes());
            p.extend_from_slice(&(exif_payload.len() as u32).to_be_bytes());
            bx(b"iloc", &p)
        };
        let hdlr = bx(b"hdlr", &[0u8; 24]);
        let meta_len = 8 + 4 + hdlr.len() + iinf.len() + build_iloc(0).len();
        let exif_off = (ftyp.len() + meta_len) as u32;
        let mut meta_payload = vec![0, 0, 0, 0];
        meta_payload.extend(hdlr);
        meta_payload.extend(iinf);
        meta_payload.extend(build_iloc(exif_off));
        let mut file = ftyp;
        file.extend(bx(b"meta", &meta_payload));
        assert_eq!(file.len() as u32, exif_off);
        file.extend_from_slice(&exif_payload);

        assert_eq!(sniff(&file), Some(Kind::Heif));
        let (start, len) = heif_exif_range(&file).unwrap();
        assert_eq!(&file[start..start + 4], b"MM\0*");
        assert_eq!(len, tiff.len());
    }

    #[test]
    fn sniff_unknown() {
        assert_eq!(sniff(b"GIF89a......"), None);
        assert_eq!(sniff(b""), None);
    }
}
