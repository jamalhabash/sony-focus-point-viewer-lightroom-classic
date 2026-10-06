//! Ordered key/value report, printable as `key=value` lines or JSON.

use std::borrow::Cow;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Float(f64),
    Bool(bool),
}

#[derive(Debug, Default, Clone)]
pub struct Report {
    pub fields: Vec<(Cow<'static, str>, Value)>,
}

/// Keys whose values are integers / floats / booleans (for [`Report::from_kv`]).
const INT_KEYS: &[&str] = &[
    "orientation",
    "image_width",
    "image_height",
    "focus_x",
    "focus_y",
    "frame_width",
    "frame_height",
    "source_width",
    "source_height",
    "crop_source_width",
    "crop_source_height",
];
const FLOAT_KEYS: &[&str] = &["norm_x", "norm_y", "norm_w", "norm_h"];
const BOOL_KEYS: &[&str] = &["cached"];

impl Report {
    pub fn set(&mut self, key: &'static str, v: Value) {
        self.set_cow(Cow::Borrowed(key), v);
    }
    fn set_cow(&mut self, key: Cow<'static, str>, v: Value) {
        if let Some(slot) = self.fields.iter_mut().find(|(k, _)| *k == key) {
            slot.1 = v;
        } else {
            self.fields.push((key, v));
        }
    }
    pub fn bool(&mut self, key: &'static str, v: bool) {
        self.set(key, Value::Bool(v));
    }
    pub fn str(&mut self, key: &'static str, v: impl Into<String>) {
        self.set(key, Value::Str(v.into()));
    }
    pub fn int(&mut self, key: &'static str, v: impl Into<i64>) {
        self.set(key, Value::Int(v.into()));
    }
    pub fn float(&mut self, key: &'static str, v: f64) {
        self.set(key, Value::Float((v * 1e6).round() / 1e6));
    }
    pub fn opt_str(&mut self, key: &'static str, v: Option<impl Into<String>>) {
        if let Some(v) = v {
            self.str(key, v);
        }
    }
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.fields.iter().find(|(k, _)| *k == key).map(|(_, v)| v)
    }
    pub fn remove(&mut self, key: &str) {
        self.fields.retain(|(k, _)| *k != key);
    }
    /// String value of `key`, if it is a string.
    pub fn get_str(&self, key: &str) -> Option<&str> {
        match self.get(key) {
            Some(Value::Str(s)) => Some(s),
            _ => None,
        }
    }

    /// Parse a block printed by [`Report::to_kv`] (value types by key name).
    pub fn from_kv(text: &str) -> Report {
        let mut r = Report::default();
        for line in text.lines() {
            let Some((k, v)) = line.split_once('=') else {
                continue;
            };
            let v = unescape_kv(v);
            let val = if INT_KEYS.contains(&k) {
                v.parse().map(Value::Int).ok()
            } else if FLOAT_KEYS.contains(&k) {
                v.parse().map(Value::Float).ok()
            } else if BOOL_KEYS.contains(&k) {
                v.parse().map(Value::Bool).ok()
            } else {
                None
            }
            .unwrap_or(Value::Str(v));
            r.set_cow(Cow::Owned(k.to_string()), val);
        }
        r
    }

    pub fn to_kv(&self) -> String {
        let mut s = String::new();
        for (k, v) in &self.fields {
            let val = match v {
                Value::Str(x) => escape_kv(x),
                Value::Int(i) => i.to_string(),
                Value::Float(f) => format_float(*f),
                Value::Bool(b) => b.to_string(),
            };
            s.push_str(k);
            s.push('=');
            s.push_str(&val);
            s.push('\n');
        }
        s
    }

    pub fn to_json(&self) -> String {
        let mut s = String::from("{\n");
        for (i, (k, v)) in self.fields.iter().enumerate() {
            let val = match v {
                Value::Str(x) => serde_json::to_string(x).unwrap_or_else(|_| "\"\"".into()),
                Value::Int(n) => n.to_string(),
                Value::Float(f) => format_float(*f),
                Value::Bool(b) => b.to_string(),
            };
            s.push_str(&format!(
                "  {}: {}",
                serde_json::to_string(k.as_ref()).unwrap_or_default(),
                val
            ));
            s.push_str(if i + 1 < self.fields.len() {
                ",\n"
            } else {
                "\n"
            });
        }
        s.push_str("}\n");
        s
    }
}

fn format_float(f: f64) -> String {
    if !f.is_finite() {
        return "0".into();
    }
    let s = format!("{f:.6}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() || s == "-0" {
        "0".into()
    } else {
        s.to_string()
    }
}

/// Escape `\` as `\\` and newlines as `\n` (and CR as `\r`).
pub fn escape_kv(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            c => o.push(c),
        }
    }
    o
}

/// Inverse of [`escape_kv`].
pub fn unescape_kv(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            o.push(c);
            continue;
        }
        match it.next() {
            Some('n') => o.push('\n'),
            Some('r') => o.push('\r'),
            Some(c) => o.push(c),
            None => o.push('\\'),
        }
    }
    o
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kv_and_json() {
        let mut r = Report::default();
        r.str("status", "ok");
        r.str("message", "a\\b\nc");
        r.int("focus_x", 3504);
        r.float("norm_x", 0.5);
        r.float("norm_y", 1.0 / 3.0);
        let kv = r.to_kv();
        assert_eq!(
            kv,
            "status=ok\nmessage=a\\\\b\\nc\nfocus_x=3504\nnorm_x=0.5\nnorm_y=0.333333\n"
        );
        let j: serde_json::Value = serde_json::from_str(&r.to_json()).unwrap();
        assert_eq!(j["status"], "ok");
        assert_eq!(j["message"], "a\\b\nc");
        assert_eq!(j["focus_x"], 3504);
        assert_eq!(j["norm_x"], 0.5);
        r.str("status", "error");
        assert_eq!(r.fields.len(), 5);
    }

    #[test]
    fn kv_roundtrip() {
        let mut r = Report::default();
        r.str("status", "ok");
        r.str("message", "a\\b\nc\rd \\n");
        r.int("focus_x", 3504);
        r.float("norm_x", 0.25);
        r.str("model", "123");
        r.bool("cached", false);
        let back = Report::from_kv(&r.to_kv());
        assert_eq!(back.fields, r.fields);
        assert_eq!(back.to_json(), r.to_json());
        let j: serde_json::Value = serde_json::from_str(&r.to_json()).unwrap();
        assert_eq!(j["cached"], false);
        assert_eq!(j["model"], "123");
    }
}
