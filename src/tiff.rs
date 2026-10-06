//! Minimal TIFF / IFD reader.
//!
//! Handles both byte orders, IFD chains, and arbitrary sub-directories (the
//! caller decides which tags point at sub-IFDs). Every read is bounds checked;
//! malformed data yields `None`/empty results rather than panics.

use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ByteOrder {
    Little,
    Big,
}

/// A TIFF stream: `data` starts at the TIFF header (`II*\0` / `MM\0*`).
/// All IFD offsets are relative to the start of `data`.
#[derive(Debug, Clone, Copy)]
pub struct Tiff<'a> {
    pub data: &'a [u8],
    pub order: ByteOrder,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub tag: u16,
    pub typ: u16,
    pub count: u32,
    /// Offset (relative to the TIFF header) of the value bytes. For values of
    /// four bytes or less this points into the IFD entry itself.
    pub value_offset: usize,
}

/// Byte size of one element of a TIFF field type.
pub fn type_size(typ: u16) -> Option<usize> {
    Some(match typ {
        1 | 2 | 6 | 7 => 1,   // BYTE, ASCII, SBYTE, UNDEFINED
        3 | 8 => 2,           // SHORT, SSHORT
        4 | 9 | 11 | 13 => 4, // LONG, SLONG, FLOAT, IFD
        5 | 10 | 12 => 8,     // RATIONAL, SRATIONAL, DOUBLE
        16..=18 => 8,         // LONG8, SLONG8, IFD8 (BigTIFF; tolerated)
        _ => return None,
    })
}

impl<'a> Tiff<'a> {
    /// Parse the 8-byte header. Returns the reader and the offset of IFD0.
    pub fn parse(data: &'a [u8]) -> Option<(Tiff<'a>, usize)> {
        if data.len() < 8 {
            return None;
        }
        let order = match &data[0..4] {
            b"II*\0" => ByteOrder::Little,
            b"MM\0*" => ByteOrder::Big,
            _ => return None,
        };
        let t = Tiff { data, order };
        let ifd0 = t.u32_at(4)? as usize;
        Some((t, ifd0))
    }

    pub fn with_order(data: &'a [u8], order: ByteOrder) -> Tiff<'a> {
        Tiff { data, order }
    }

    pub fn bytes(&self, off: usize, len: usize) -> Option<&'a [u8]> {
        let end = off.checked_add(len)?;
        self.data.get(off..end)
    }

    pub fn u16_at(&self, off: usize) -> Option<u16> {
        let b = self.bytes(off, 2)?;
        Some(match self.order {
            ByteOrder::Little => u16::from_le_bytes([b[0], b[1]]),
            ByteOrder::Big => u16::from_be_bytes([b[0], b[1]]),
        })
    }

    pub fn u32_at(&self, off: usize) -> Option<u32> {
        let b = self.bytes(off, 4)?;
        let a = [b[0], b[1], b[2], b[3]];
        Some(match self.order {
            ByteOrder::Little => u32::from_le_bytes(a),
            ByteOrder::Big => u32::from_be_bytes(a),
        })
    }

    /// Read the IFD at `off`. Returns its entries and the next-IFD offset
    /// (0 = end of chain). `None` if the IFD header is out of bounds.
    pub fn read_ifd(&self, off: usize) -> Option<(Vec<Entry>, usize)> {
        let n = self.u16_at(off)? as usize;
        if n == 0 || n > 1000 {
            return None;
        }
        let mut entries = Vec::with_capacity(n);
        for i in 0..n {
            let e = off + 2 + i * 12;
            let tag = self.u16_at(e)?;
            let typ = self.u16_at(e + 2)?;
            let count = self.u32_at(e + 4)?;
            let size = type_size(typ).and_then(|s| s.checked_mul(count as usize));
            let value_offset = match size {
                Some(s) if s <= 4 => e + 8,
                _ => self.u32_at(e + 8)? as usize,
            };
            entries.push(Entry {
                tag,
                typ,
                count,
                value_offset,
            });
        }
        let next = self.u32_at(off + 2 + n * 12).unwrap_or(0) as usize;
        Some((entries, next))
    }

    /// Follow an IFD chain from `first`, guarding against loops.
    pub fn ifd_chain(&self, first: usize, max: usize) -> Vec<(usize, Vec<Entry>)> {
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        let mut off = first;
        while off != 0 && out.len() < max && seen.insert(off) {
            match self.read_ifd(off) {
                Some((entries, next)) => {
                    out.push((off, entries));
                    off = next;
                }
                None => break,
            }
        }
        out
    }

    /// Raw value bytes of an entry (bounds checked).
    pub fn value_bytes(&self, e: &Entry) -> Option<&'a [u8]> {
        let size = type_size(e.typ)?.checked_mul(e.count as usize)?;
        self.bytes(e.value_offset, size)
    }

    /// Integer values of an entry (BYTE/SHORT/LONG and signed variants).
    pub fn uints(&self, e: &Entry) -> Vec<u32> {
        let n = (e.count as usize).min(4096);
        let mut v = Vec::with_capacity(n);
        for i in 0..n {
            let x = match e.typ {
                1 | 6 | 7 => self.data.get(e.value_offset + i).map(|&b| b as u32),
                3 | 8 => self.u16_at(e.value_offset + i * 2).map(u32::from),
                4 | 9 | 13 => self.u32_at(e.value_offset + i * 4),
                _ => None,
            };
            match x {
                Some(x) => v.push(x),
                None => break,
            }
        }
        v
    }

    /// Value bytes reinterpreted as int16u regardless of the declared type
    /// (ExifTool's `Format => 'int16u'`).
    pub fn u16s_forced(&self, e: &Entry) -> Vec<u32> {
        let Some(b) = self.value_bytes(e) else {
            return Vec::new();
        };
        b.chunks_exact(2)
            .map(|c| match self.order {
                ByteOrder::Little => u16::from_le_bytes([c[0], c[1]]) as u32,
                ByteOrder::Big => u16::from_be_bytes([c[0], c[1]]) as u32,
            })
            .collect()
    }

    pub fn uint(&self, e: &Entry) -> Option<u32> {
        self.uints(e).first().copied()
    }

    /// ASCII value, trimmed at the first NUL and of surrounding whitespace.
    pub fn ascii(&self, e: &Entry) -> Option<String> {
        let b = self.value_bytes(e)?;
        let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
        let s = String::from_utf8_lossy(&b[..end]).trim().to_string();
        (!s.is_empty()).then_some(s)
    }
}

pub fn find(entries: &[Entry], tag: u16) -> Option<&Entry> {
    entries.iter().find(|e| e.tag == tag)
}

#[cfg(test)]
pub mod build {
    //! Tiny TIFF writer for synthetic test data.

    use super::ByteOrder;

    pub enum Val {
        Short(Vec<u16>),
        Long(Vec<u32>),
        Ascii(&'static str),
        Undef(Vec<u8>),
        Byte(Vec<u8>),
        /// Entry pointing at data already in the buffer: (type, count, offset).
        Ref(u16, u32, u32),
    }

    pub struct Builder {
        pub order: ByteOrder,
        pub buf: Vec<u8>,
    }

    impl Builder {
        pub fn new(order: ByteOrder) -> Self {
            let mut buf = Vec::new();
            match order {
                ByteOrder::Little => buf.extend_from_slice(b"II*\0"),
                ByteOrder::Big => buf.extend_from_slice(b"MM\0*"),
            }
            buf.extend_from_slice(&[0, 0, 0, 0]);
            Builder { order, buf }
        }

        pub fn u16b(&self, v: u16) -> [u8; 2] {
            match self.order {
                ByteOrder::Little => v.to_le_bytes(),
                ByteOrder::Big => v.to_be_bytes(),
            }
        }

        pub fn u32b(&self, v: u32) -> [u8; 4] {
            match self.order {
                ByteOrder::Little => v.to_le_bytes(),
                ByteOrder::Big => v.to_be_bytes(),
            }
        }

        pub fn set_u32(&mut self, at: usize, v: u32) {
            let b = self.u32b(v);
            self.buf[at..at + 4].copy_from_slice(&b);
        }

        pub fn append(&mut self, bytes: &[u8]) -> usize {
            if self.buf.len() % 2 == 1 {
                self.buf.push(0);
            }
            let off = self.buf.len();
            self.buf.extend_from_slice(bytes);
            off
        }

        /// Write an IFD at the end of the buffer (entries sorted by caller).
        /// Returns (ifd offset, offset of the next-IFD pointer).
        pub fn ifd(&mut self, entries: &[(u16, Val)]) -> (usize, usize) {
            self.ifd_with_prefix(&[], entries)
        }

        /// Like `ifd`, but writes `prefix` bytes (e.g. "SONY DSC \0\0\0")
        /// immediately before the IFD. Returns (prefix offset, next ptr).
        pub fn ifd_with_prefix(&mut self, prefix: &[u8], entries: &[(u16, Val)]) -> (usize, usize) {
            // Encode values first.
            let mut encoded: Vec<(u16, u16, u32, Vec<u8>)> = Vec::new();
            let mut refs: Vec<(u16, u16, u32, u32)> = Vec::new();
            for (tag, v) in entries {
                let (typ, count, bytes) = match v {
                    Val::Short(xs) => (
                        3u16,
                        xs.len() as u32,
                        xs.iter().flat_map(|&x| self.u16b(x)).collect(),
                    ),
                    Val::Long(xs) => (
                        4u16,
                        xs.len() as u32,
                        xs.iter().flat_map(|&x| self.u32b(x)).collect(),
                    ),
                    Val::Ascii(s) => {
                        let mut b = s.as_bytes().to_vec();
                        b.push(0);
                        (2u16, b.len() as u32, b)
                    }
                    Val::Undef(b) => (7u16, b.len() as u32, b.clone()),
                    Val::Byte(b) => (1u16, b.len() as u32, b.clone()),
                    Val::Ref(typ, count, off) => {
                        refs.push((*tag, *typ, *count, *off));
                        continue;
                    }
                };
                encoded.push((*tag, typ, count, bytes));
            }
            if self.buf.len() % 2 == 1 {
                self.buf.push(0);
            }
            // Ref entries: encode offset as the value (marked by an empty Vec
            // and patched below).
            let ref_start = encoded.len();
            for (tag, typ, count, _) in &refs {
                encoded.push((*tag, *typ, *count, Vec::new()));
            }
            let prefix_off = self.buf.len();
            self.buf.extend_from_slice(prefix);
            let ifd_off = self.buf.len();
            let n = encoded.len();
            let data_start = ifd_off + 2 + n * 12 + 4;
            let mut data = Vec::new();
            let mut table = Vec::new();
            table.extend_from_slice(&self.u16b(n as u16));
            for (i, (tag, typ, count, bytes)) in encoded.iter().enumerate() {
                table.extend_from_slice(&self.u16b(*tag));
                table.extend_from_slice(&self.u16b(*typ));
                table.extend_from_slice(&self.u32b(*count));
                if i >= ref_start {
                    table.extend_from_slice(&self.u32b(refs[i - ref_start].3));
                } else if bytes.len() <= 4 {
                    let mut v = bytes.clone();
                    v.resize(4, 0);
                    table.extend_from_slice(&v);
                } else {
                    let off = data_start + data.len();
                    table.extend_from_slice(&self.u32b(off as u32));
                    data.extend_from_slice(bytes);
                    if data.len() % 2 == 1 {
                        data.push(0);
                    }
                }
            }
            let next_ptr = ifd_off + 2 + n * 12;
            table.extend_from_slice(&[0, 0, 0, 0]);
            self.buf.extend_from_slice(&table);
            self.buf.extend_from_slice(&data);
            let start = if prefix.is_empty() {
                ifd_off
            } else {
                prefix_off
            };
            (start, next_ptr)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::build::*;
    use super::*;

    fn roundtrip(order: ByteOrder) {
        let mut b = Builder::new(order);
        let (ifd0, next0) = b.ifd(&[
            (0x010f, Val::Ascii("SONY")),
            (0x0112, Val::Short(vec![6])),
            (0x2027, Val::Short(vec![7008, 4672, 3504, 2336])),
        ]);
        b.set_u32(4, ifd0 as u32);
        let (ifd1, _) = b.ifd(&[(0x0201, Val::Long(vec![1234]))]);
        b.set_u32(next0, ifd1 as u32);

        let (t, first) = Tiff::parse(&b.buf).unwrap();
        assert_eq!(t.order, order);
        let chain = t.ifd_chain(first, 10);
        assert_eq!(chain.len(), 2);
        let e = &chain[0].1;
        assert_eq!(t.ascii(find(e, 0x010f).unwrap()).as_deref(), Some("SONY"));
        assert_eq!(t.uint(find(e, 0x0112).unwrap()), Some(6));
        assert_eq!(
            t.uints(find(e, 0x2027).unwrap()),
            vec![7008, 4672, 3504, 2336]
        );
        assert_eq!(t.uint(find(&chain[1].1, 0x0201).unwrap()), Some(1234));
    }

    #[test]
    fn little_endian() {
        roundtrip(ByteOrder::Little);
    }

    #[test]
    fn big_endian() {
        roundtrip(ByteOrder::Big);
    }

    #[test]
    fn rejects_garbage_and_loops() {
        assert!(Tiff::parse(b"nope").is_none());
        assert!(Tiff::parse(b"II*\0\x08\0\0\0").is_some());
        // IFD that points to itself.
        let mut b = Builder::new(ByteOrder::Little);
        let (ifd0, next0) = b.ifd(&[(0x0112, Val::Short(vec![1]))]);
        b.set_u32(4, ifd0 as u32);
        b.set_u32(next0, ifd0 as u32);
        let (t, first) = Tiff::parse(&b.buf).unwrap();
        assert_eq!(t.ifd_chain(first, 10).len(), 1);
        // Truncated buffer.
        let short = &b.buf[..b.buf.len() - 6];
        let (t, first) = Tiff::parse(short).unwrap();
        let chain = t.ifd_chain(first, 10);
        assert!(chain.len() <= 1);
    }
}
