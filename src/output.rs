//! Ordered key/value report, printable as `key=value` lines or JSON.

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Float(f64),
}

#[derive(Debug, Default, Clone)]
pub struct Report {
    pub fields: Vec<(&'static str, Value)>,
}

impl Report {
    pub fn set(&mut self, key: &'static str, v: Value) {
        if let Some(slot) = self.fields.iter_mut().find(|(k, _)| *k == key) {
            slot.1 = v;
        } else {
            self.fields.push((key, v));
        }
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

    pub fn to_kv(&self) -> String {
        let mut s = String::new();
        for (k, v) in &self.fields {
            let val = match v {
                Value::Str(x) => escape_kv(x),
                Value::Int(i) => i.to_string(),
                Value::Float(f) => format_float(*f),
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
            };
            s.push_str(&format!(
                "  {}: {}",
                serde_json::to_string(k).unwrap_or_default(),
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
}
