//! Sony maker note decoding. Tag semantics and value names follow ExifTool's
//! `lib/Image/ExifTool/Sony.pm` (Sony::Main table, Tag9402).

use crate::tiff::{find, Entry, Tiff};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SonyInfo {
    /// 0x2027 FocusLocation: image width, height, focus x, focus y.
    pub focus_location: Option<[u32; 4]>,
    /// 0x204a FocusLocation2 (newer bodies; "same as FocusLocation within one pixel").
    pub focus_location2: Option<[u32; 4]>,
    /// 0x2037 FocusFrameSize: width, height, valid flag (non-zero = valid).
    pub focus_frame_size: Option<[u32; 3]>,
    /// 0x201b FocusMode (raw).
    pub focus_mode: Option<u32>,
    /// 0x201c AFAreaModeSetting (raw).
    pub af_area_mode_setting: Option<u32>,
    /// 0x201d FlexibleSpotPosition.
    pub flexible_spot_position: Option<[u32; 2]>,
    /// 0x201e AFPointSelected (raw).
    pub af_point_selected: Option<u32>,
    /// 0x2021 AFTracking (raw).
    pub af_tracking: Option<u32>,
    /// Tag9402 0x16 FocusMode (deciphered, masked with 0x7f).
    pub focus_mode_9402: Option<u32>,
    /// Tag9402 0x17 AFAreaMode (deciphered) - the AF area mode actually used.
    pub af_area_mode_9402: Option<u32>,
}

const HEADERS: [&[u8]; 2] = [b"SONY DSC \0\0\0", b"SONY CAM \0\0\0"];

/// Parse a Sony maker note whose value starts at `off` (relative to the TIFF
/// header of `t`), `len` bytes long. Offsets inside the maker note are
/// relative to the same TIFF header.
pub fn parse_makernote(t: &Tiff, off: usize, len: usize, model: &str) -> Option<SonyInfo> {
    let raw = t.bytes(off, len.min(t.data.len().saturating_sub(off)))?;
    let ifd_off = if HEADERS.iter().any(|h| raw.starts_with(h)) {
        off + 12
    } else if raw.starts_with(b"SONY") || raw.starts_with(b"VHAB") || raw.starts_with(b"PREMI") {
        // Other Sony/Hasselblad/Premier variants: not the plain-IFD layout we need.
        return None;
    } else {
        off
    };
    let (entries, _) = t.read_ifd(ifd_off)?;
    Some(decode(t, &entries, model))
}

fn arr<const N: usize>(t: &Tiff, e: Option<&Entry>) -> Option<[u32; N]> {
    to_arr(t.uints(e?))
}

fn to_arr<const N: usize>(v: Vec<u32>) -> Option<[u32; N]> {
    (v.len() >= N).then(|| {
        let mut a = [0u32; N];
        a.copy_from_slice(&v[..N]);
        a
    })
}

pub fn decode(t: &Tiff, entries: &[Entry], model: &str) -> SonyInfo {
    let mut s = SonyInfo {
        focus_location: arr(t, find(entries, 0x2027)),
        focus_location2: arr(t, find(entries, 0x204a)),
        // Stored as undef[6]; ExifTool reads it with Format => 'int16u'.
        focus_frame_size: find(entries, 0x2037).and_then(|e| {
            if e.typ == 3 {
                arr(t, Some(e))
            } else {
                to_arr(t.u16s_forced(e))
            }
        }),
        focus_mode: find(entries, 0x201b).and_then(|e| t.uint(e)),
        af_area_mode_setting: find(entries, 0x201c).and_then(|e| t.uint(e)),
        flexible_spot_position: arr(t, find(entries, 0x201d)),
        af_point_selected: find(entries, 0x201e).and_then(|e| t.uint(e)),
        af_tracking: find(entries, 0x2021).and_then(|e| t.uint(e)),
        ..Default::default()
    };
    // Tag9402 (enciphered). ExifTool: valid unless SLT/HV/ILCA, and the first
    // (enciphered) byte is not 0x05 or 0xff.
    if !(model.starts_with("SLT-") || model.starts_with("HV") || model.starts_with("ILCA-")) {
        if let Some(b) = find(entries, 0x9402).and_then(|e| t.value_bytes(e)) {
            if b.len() > 0x17 && b[0] != 0x05 && b[0] != 0xff {
                let d = decipher(&b[..0x18]);
                s.focus_mode_9402 = Some((d[0x16] & 0x7f) as u32);
                s.af_area_mode_9402 = Some(d[0x17] as u32);
            }
        }
    }
    s
}

/// Sony's substitution cipher for 0x94xx blocks: enciphered c = b^3 mod 249
/// for 2 <= b <= 247; all other byte values are unchanged.
pub fn decipher(data: &[u8]) -> Vec<u8> {
    let table = decipher_table();
    data.iter().map(|&c| table[c as usize]).collect()
}

fn decipher_table() -> [u8; 256] {
    let mut t = [0u8; 256];
    for (i, v) in t.iter_mut().enumerate() {
        *v = i as u8;
    }
    // Iterate in reverse so the first (smallest) plain value wins on
    // collisions, mirroring Perl's tr/// semantics.
    for b in (2u32..=247).rev() {
        let c = (b * b * b) % 249;
        t[c as usize] = b as u8;
    }
    t
}

#[cfg(test)]
pub fn encipher(data: &[u8]) -> Vec<u8> {
    data.iter()
        .map(|&b| {
            if (2..=247).contains(&b) {
                ((b as u32).pow(3) % 249) as u8
            } else {
                b
            }
        })
        .collect()
}

fn is_dsc_with_af_tags(model: &str) -> bool {
    [
        "DSC-RX10M4",
        "DSC-RX100M6",
        "DSC-RX100M7",
        "DSC-RX100M5A",
        "DSC-HX95",
        "DSC-HX99",
        "DSC-RX0M2",
        "DSC-RX1RM3",
    ]
    .iter()
    .any(|p| model.starts_with(p))
}

fn is_ilce_like(model: &str) -> bool {
    ["NEX-", "ILCE-", "ILME-", "ZV-"]
        .iter()
        .any(|p| model.starts_with(p))
        || is_dsc_with_af_tags(model)
}

/// 0x201b FocusMode / Tag9402 FocusMode.
pub fn focus_mode_str(v: u32) -> String {
    match v {
        0 => "Manual".into(),
        2 => "AF-S".into(),
        3 => "AF-C".into(),
        4 => "AF-A".into(),
        6 => "DMF".into(),
        7 => "AF-D".into(),
        _ => format!("Unknown ({v})"),
    }
}

/// 0x201c AFAreaModeSetting (model dependent).
pub fn af_area_mode_setting_str(v: u32, model: &str) -> Option<String> {
    let s = if model.starts_with("SLT-") || model.starts_with("HV") {
        match v {
            0 => "Wide",
            4 => "Local",
            8 => "Zone",
            9 => "Spot",
            _ => return Some(format!("Unknown ({v})")),
        }
    } else if is_ilce_like(model) {
        match v {
            0 => "Wide",
            1 => "Center",
            3 => "Flexible Spot",
            4 => "Flexible Spot (LA-EA4)",
            9 => "Center (LA-EA4)",
            11 => "Zone",
            12 => "Expanded Flexible Spot",
            13 => "Custom AF Area",
            _ => return Some(format!("Unknown ({v})")),
        }
    } else if model.starts_with("ILCA-") {
        match v {
            0 => "Wide",
            4 => "Flexible Spot",
            8 => "Zone",
            9 => "Center",
            12 => "Expanded Flexible Spot",
            _ => return Some(format!("Unknown ({v})")),
        }
    } else {
        return None;
    };
    Some(s.into())
}

/// Tag9402 0x17 AFAreaMode (the area mode actually used).
pub fn af_area_mode_str(v: u32) -> String {
    match v {
        0 => "Multi".into(),
        1 => "Center".into(),
        2 => "Spot".into(),
        3 => "Flexible Spot".into(),
        10 => "Selective (for Miniature effect)".into(),
        11 => "Zone".into(),
        12 => "Expanded Flexible Spot".into(),
        13 => "Custom AF Area".into(),
        14 => "Tracking".into(),
        15 => "Face Tracking".into(),
        20 => "Animal Eye Tracking".into(),
        21 => "Human Eye Tracking".into(),
        255 => "Manual".into(),
        _ => format!("Unknown ({v})"),
    }
}

/// 0x2021 AFTracking.
pub fn af_tracking_str(v: u32) -> String {
    match v {
        0 => "Off".into(),
        1 => "Face tracking".into(),
        2 => "Lock On AF".into(),
        _ => format!("Unknown ({v})"),
    }
}

/// 0x201e AFPointSelected for NEX/ILCE (zone names), when non-zero.
pub fn af_point_selected_str(v: u32) -> Option<&'static str> {
    Some(match v {
        1 => "Center Zone",
        2 => "Top Zone",
        3 => "Right Zone",
        4 => "Left Zone",
        5 => "Bottom Zone",
        6 => "Bottom Right Zone",
        7 => "Bottom Left Zone",
        8 => "Top Left Zone",
        9 => "Top Right Zone",
        _ => return None,
    })
}

/// Human-readable summary values derived from the raw tags.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Summary {
    pub focus_mode: Option<String>,
    /// Combined: "<AFAreaMode used>: <AFAreaModeSetting>" when they differ
    /// (e.g. "Tracking: Wide"), else the single value.
    pub af_area_mode: Option<String>,
    pub af_area_mode_setting: Option<String>,
    pub af_area_mode_used: Option<String>,
    pub af_tracking: Option<String>,
    pub face_eye: Option<String>,
    pub af_zone: Option<String>,
    pub flexible_spot_position: Option<[u32; 2]>,
}

pub fn summarize(s: &SonyInfo, model: &str) -> Summary {
    let fm_applies = !model.starts_with("DSC-") || is_dsc_with_af_tags(model);
    let focus_mode = s
        .focus_mode
        .filter(|_| fm_applies)
        .or(s.focus_mode_9402)
        .map(focus_mode_str);
    let setting = s
        .af_area_mode_setting
        .and_then(|v| af_area_mode_setting_str(v, model));
    let used = s.af_area_mode_9402.map(af_area_mode_str);
    let af_area_mode = match (&used, &setting) {
        (Some(u), Some(st)) if u != st && !(u == "Multi" && st == "Wide") && u != "Manual" => {
            Some(format!("{u}: {st}"))
        }
        (_, Some(st)) => Some(st.clone()),
        (Some(u), None) => Some(u.clone()),
        (None, None) => None,
    };
    let af_tracking = s.af_tracking.filter(|_| fm_applies).map(af_tracking_str);
    let face_eye = match s.af_area_mode_9402 {
        Some(15) => Some("Face".to_string()),
        Some(20) => Some("Animal Eye".to_string()),
        Some(21) => Some("Human Eye".to_string()),
        _ if s.af_tracking == Some(1) => Some("Face".to_string()),
        _ => None,
    };
    let af_zone = if is_ilce_like(model) {
        s.af_point_selected
            .and_then(af_point_selected_str)
            .map(String::from)
    } else {
        None
    };
    let flexible_spot_position = s
        .flexible_spot_position
        .filter(|p| p != &[0, 0] && is_ilce_like(model));
    Summary {
        focus_mode,
        af_area_mode,
        af_area_mode_setting: setting,
        af_area_mode_used: used,
        af_tracking,
        face_eye,
        af_zone,
        flexible_spot_position,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tiff::build::*;
    use crate::tiff::ByteOrder;

    #[test]
    fn cipher_roundtrip() {
        let plain: Vec<u8> = (0..=255u8).collect();
        let enc = encipher(&plain);
        let dec = decipher(&enc);
        for b in 0..=255u8 {
            let collides = matches!(b, 0 | 1 | 82..=84 | 165..=167 | 248);
            if !collides {
                assert_eq!(dec[b as usize], b, "byte {b}");
            }
        }
        // Known value from ExifTool's comments: 0x25 (ILCE-7M4) enciphers to... decipher(encipher(x)) == x
        assert_eq!(decipher(&encipher(&[0x25]))[0], 0x25);
        // ExifTool table: plain 0x02 -> 0x08, 0x03 -> 0x1b.
        assert_eq!(encipher(&[2, 3]), vec![0x08, 0x1b]);
    }

    fn frame_bytes(order: ByteOrder, v: [u16; 3]) -> Vec<u8> {
        v.iter()
            .flat_map(|x| match order {
                ByteOrder::Little => x.to_le_bytes(),
                ByteOrder::Big => x.to_be_bytes(),
            })
            .collect()
    }

    pub fn sample_makernote_entries(
        order: ByteOrder,
        focus: [u16; 4],
        fm: u8,
        area: u8,
        track: u8,
        used: u8,
    ) -> Vec<(u16, Val)> {
        let mut blk = vec![0u8; 0x40];
        blk[0] = 0x25;
        blk[0x16] = fm | 0x80;
        blk[0x17] = used;
        vec![
            (0x201b, Val::Byte(vec![fm])),
            (0x201c, Val::Byte(vec![area])),
            (0x201d, Val::Short(vec![0, 0])),
            (0x2021, Val::Byte(vec![track])),
            (0x2027, Val::Short(focus.to_vec())),
            (0x2037, Val::Undef(frame_bytes(order, [350, 351, 257]))),
            (0x9402, Val::Undef(encipher(&blk))),
        ]
    }

    #[test]
    fn makernote_with_header_both_orders() {
        for order in [ByteOrder::Little, ByteOrder::Big] {
            let mut b = Builder::new(order);
            let entries = sample_makernote_entries(order, [7008, 4672, 3591, 2306], 3, 0, 2, 14);
            let (mn, _) = b.ifd_with_prefix(b"SONY DSC \0\0\0", &entries);
            let len = b.buf.len() - mn;
            let (t, _) = crate::tiff::Tiff::parse(&b.buf).unwrap();
            let s = parse_makernote(&t, mn, len, "ILCE-7M4").unwrap();
            assert_eq!(s.focus_location, Some([7008, 4672, 3591, 2306]));
            assert_eq!(s.focus_frame_size, Some([350, 351, 257]));
            assert_eq!(s.focus_mode_9402, Some(3));
            assert_eq!(s.af_area_mode_9402, Some(14));
            let sum = summarize(&s, "ILCE-7M4");
            assert_eq!(sum.focus_mode.as_deref(), Some("AF-C"));
            assert_eq!(sum.af_area_mode.as_deref(), Some("Tracking: Wide"));
            assert_eq!(sum.af_area_mode_setting.as_deref(), Some("Wide"));
            assert_eq!(sum.af_tracking.as_deref(), Some("Lock On AF"));
            assert_eq!(sum.face_eye, None);
        }
    }

    #[test]
    fn makernote_without_header() {
        let mut b = Builder::new(ByteOrder::Little);
        let entries =
            sample_makernote_entries(ByteOrder::Little, [6000, 4000, 100, 200], 2, 3, 1, 21);
        let (mn, _) = b.ifd(&entries);
        let len = b.buf.len() - mn;
        let (t, _) = crate::tiff::Tiff::parse(&b.buf).unwrap();
        let s = parse_makernote(&t, mn, len, "ILCE-7M3").unwrap();
        let sum = summarize(&s, "ILCE-7M3");
        assert_eq!(sum.focus_mode.as_deref(), Some("AF-S"));
        assert_eq!(
            sum.af_area_mode.as_deref(),
            Some("Human Eye Tracking: Flexible Spot")
        );
        assert_eq!(sum.af_tracking.as_deref(), Some("Face tracking"));
        assert_eq!(sum.face_eye.as_deref(), Some("Human Eye"));
    }

    #[test]
    fn same_area_mode_not_duplicated() {
        let s = SonyInfo {
            af_area_mode_setting: Some(11),
            af_area_mode_9402: Some(11),
            af_point_selected: Some(1),
            ..Default::default()
        };
        let sum = summarize(&s, "ILCE-7M4");
        assert_eq!(sum.af_area_mode.as_deref(), Some("Zone"));
        assert_eq!(sum.af_zone.as_deref(), Some("Center Zone"));
    }
}
