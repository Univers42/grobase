//! PB predicate AST — the full PocketBase filter/rule grammar, including the
//! constructs the engine-neutral [`data_plane_core::Filter`] cannot express:
//! `:modifiers` (`:isset/:length/:each/:lower`), multi-value any-of (`?op`
//! over JSON-array columns), and `geoDistance()`.
//!
//! Two lowerings:
//!   - [`PbExpr::to_engine_filter`] returns `Some(Filter)` when the whole
//!     predicate is SQL-expressible (the fast WHERE path — unchanged for the
//!     simple filters the certificate already covers);
//!   - [`PbExpr::eval`] evaluates the predicate IN MEMORY against a record
//!     (used when an advanced term is present: the caller fetches candidate
//!     rows with the SQL-expressible part, then filters in Rust). Outcome is
//!     PB-identical; only the advanced predicates pay the fetch-then-filter
//!     cost — the hot CRUD/filter path stays on SQL.
//!
//! `@collection.*` cross-collection joins are parsed but need an async
//! sub-query and are handled by the records layer (see `expand`-style
//! resolution); a plain record filter still rejects every `@`-reference.

use chrono::{Datelike, Timelike};
use data_plane_core::{CmpOp, Filter};
use serde_json::{json, Value};

const MAX_DEPTH: usize = 32;

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum PbExpr {
    And(Vec<PbExpr>),
    Or(Vec<PbExpr>),
    Cmp {
        left: Operand,
        op: Cmp,
        right: Operand,
        /// `?`-prefixed "any of": the comparison holds if ANY pair across the
        /// (possibly multi-value) operands satisfies it.
        any: bool,
    },
    /// Constant truth (an `@request.*`-only comparison folded at parse time).
    Const(bool),
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Operand {
    Field { name: String, modifier: Option<Mod> },
    Lit(Value),
    /// `geoDistance(lonA, latA, lonB, latB)` → km (haversine).
    Geo(Box<[Operand; 4]>),
    /// `@collection.NAME[:alias].FIELD` — a cross-collection join reference
    /// (resolved to a literal by the async resolver before eval; see
    /// records::resolve_collection_refs). Distinct aliases on the same
    /// collection are DIFFERENT join rows (PB semantics).
    Collection { collection: String, alias: Option<String>, field: String },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Mod {
    Isset,
    Length,
    Each,
    Lower,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Cmp {
    Eq,
    Ne,
    Lt,
    Lte,
    Gt,
    Gte,
    Like,
    NLike,
}

// ─── parse ───────────────────────────────────────────────────────────────────

/// Parse a PB filter/rule string. `resolver` maps `@request.*` references to
/// the caller's literal values (rules engine); a record filter passes a
/// resolver that returns `None`, so `@`-refs error.
pub(crate) fn parse(
    input: &str,
    resolver: &dyn Fn(&str) -> Option<Value>,
) -> Result<PbExpr, String> {
    let tokens = lex(input)?;
    if tokens.is_empty() {
        return Ok(PbExpr::And(vec![]));
    }
    let mut p = Parser { tokens, pos: 0, resolver };
    let e = p.or_expr(0)?;
    match p.peek() {
        None => Ok(e),
        Some(t) => Err(format!("unexpected trailing token {t:?}")),
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Ident(String),
    Str(String),
    Num(f64),
    Op(&'static str),
    AndAnd,
    OrOr,
    LParen,
    RParen,
    Comma,
}

const OPS: &[&str] = &[
    "?!~", "?!=", "?>=", "?<=", "?~", "?=", "?>", "?<", "!~", "!=", ">=", "<=", "~", "=", ">", "<",
];

fn lex(input: &str) -> Result<Vec<Tok>, String> {
    let b = input.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    'outer: while i < b.len() {
        let c = b[i] as char;
        if c.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        match c {
            '(' => { out.push(Tok::LParen); i += 1; continue; }
            ')' => { out.push(Tok::RParen); i += 1; continue; }
            ',' => { out.push(Tok::Comma); i += 1; continue; }
            '&' if b.get(i + 1) == Some(&b'&') => { out.push(Tok::AndAnd); i += 2; continue; }
            '|' if b.get(i + 1) == Some(&b'|') => { out.push(Tok::OrOr); i += 2; continue; }
            '\'' | '"' => {
                let quote = c;
                let mut s = String::new();
                i += 1;
                while i < b.len() {
                    let ch = b[i] as char;
                    if ch == '\\' && i + 1 < b.len() {
                        s.push(b[i + 1] as char);
                        i += 2;
                        continue;
                    }
                    if ch == quote {
                        i += 1;
                        out.push(Tok::Str(s));
                        continue 'outer;
                    }
                    s.push(ch);
                    i += 1;
                }
                return Err(format!("unterminated {quote}-quoted string"));
            }
            _ => {}
        }
        for op in OPS {
            if input[i..].starts_with(op) {
                out.push(Tok::Op(op));
                i += op.len();
                continue 'outer;
            }
        }
        if c.is_ascii_digit() || (c == '-' && b.get(i + 1).is_some_and(|n| n.is_ascii_digit())) {
            let start = i;
            i += 1;
            while i < b.len() && ((b[i] as char).is_ascii_digit() || b[i] == b'.') {
                i += 1;
            }
            let raw = &input[start..i];
            let n: f64 = raw.parse().map_err(|_| format!("bad number '{raw}'"))?;
            out.push(Tok::Num(n));
            continue;
        }
        if c.is_ascii_alphabetic() || c == '_' || c == '@' {
            let start = i;
            i += 1;
            while i < b.len() {
                let ch = b[i] as char;
                if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | ':') {
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(Tok::Ident(input[start..i].to_string()));
            continue;
        }
        return Err(format!("unexpected character '{c}' at byte {i}"));
    }
    Ok(out)
}

struct Parser<'a> {
    tokens: Vec<Tok>,
    pos: usize,
    resolver: &'a dyn Fn(&str) -> Option<Value>,
}

impl Parser<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.tokens.get(self.pos)
    }
    fn next(&mut self) -> Option<Tok> {
        let t = self.tokens.get(self.pos).cloned();
        if t.is_some() {
            self.pos += 1;
        }
        t
    }

    fn or_expr(&mut self, depth: usize) -> Result<PbExpr, String> {
        let mut parts = vec![self.and_expr(depth)?];
        while self.peek() == Some(&Tok::OrOr) {
            self.next();
            parts.push(self.and_expr(depth)?);
        }
        Ok(if parts.len() == 1 { parts.pop().unwrap() } else { PbExpr::Or(parts) })
    }

    fn and_expr(&mut self, depth: usize) -> Result<PbExpr, String> {
        let mut parts = vec![self.atom(depth)?];
        while self.peek() == Some(&Tok::AndAnd) {
            self.next();
            parts.push(self.atom(depth)?);
        }
        Ok(if parts.len() == 1 { parts.pop().unwrap() } else { PbExpr::And(parts) })
    }

    fn atom(&mut self, depth: usize) -> Result<PbExpr, String> {
        if depth > MAX_DEPTH {
            return Err(format!("filter nesting exceeds the {MAX_DEPTH}-level limit"));
        }
        if self.peek() == Some(&Tok::LParen) {
            self.next();
            let e = self.or_expr(depth + 1)?;
            match self.next() {
                Some(Tok::RParen) => return Ok(e),
                _ => return Err("missing ')'".into()),
            }
        }
        // comparison: operand op operand
        let left = self.operand()?;
        let Some(Tok::Op(op)) = self.next() else {
            return Err("expected a comparison operator".into());
        };
        let any = op.starts_with('?');
        let plain = op.strip_prefix('?').unwrap_or(op);
        let cmp = match plain {
            "=" => Cmp::Eq,
            "!=" => Cmp::Ne,
            ">" => Cmp::Gt,
            ">=" => Cmp::Gte,
            "<" => Cmp::Lt,
            "<=" => Cmp::Lte,
            "~" => Cmp::Like,
            "!~" => Cmp::NLike,
            other => return Err(format!("unsupported operator '{other}'")),
        };
        let right = self.operand()?;

        // Fold a comparison whose operands are BOTH constant (e.g. an
        // `@request.auth.id != ''` rule term) at parse time.
        if let (Some(l), Some(r)) = (left.const_value(), right.const_value()) {
            return Ok(PbExpr::Const(eval_cmp(&l, cmp, &r)));
        }
        Ok(PbExpr::Cmp { left, op: cmp, right, any })
    }

    fn operand(&mut self) -> Result<Operand, String> {
        match self.next() {
            Some(Tok::Str(s)) => Ok(Operand::Lit(Value::String(s))),
            Some(Tok::Num(n)) => Ok(Operand::Lit(
                serde_json::Number::from_f64(n).map(Value::Number).unwrap_or(Value::Null),
            )),
            Some(Tok::Ident(w)) => self.ident_operand(w),
            t => Err(format!("expected an operand, got {t:?}")),
        }
    }

    fn ident_operand(&mut self, w: String) -> Result<Operand, String> {
        match w.as_str() {
            "true" => return Ok(Operand::Lit(Value::Bool(true))),
            "false" => return Ok(Operand::Lit(Value::Bool(false))),
            "null" => return Ok(Operand::Lit(Value::Null)),
            "geoDistance" => return self.geo_call(),
            _ => {}
        }
        if let Some(macro_name) = w.strip_prefix('@') {
            // @request.* → resolve to a literal; @now/@todayStart → datetime;
            // @collection.* → rejected here (handled by the records layer).
            if w.starts_with("@request") {
                return (self.resolver)(&w)
                    .map(Operand::Lit)
                    .ok_or_else(|| format!("'{w}' is not available in this context"));
            }
            if let Some(rest) = w.strip_prefix("@collection.") {
                // NAME[:alias].FIELD
                let (head, field) = rest
                    .split_once('.')
                    .ok_or_else(|| format!("malformed collection ref '{w}'"))?;
                let (name, alias) = match head.split_once(':') {
                    Some((n, a)) => (n.to_string(), Some(a.to_string())),
                    None => (head.to_string(), None),
                };
                return Ok(Operand::Collection {
                    collection: name,
                    alias,
                    field: field.to_string(),
                });
            }
            if w.starts_with("@collection") {
                return Err(format!("malformed collection ref '{w}'"));
            }
            let _ = macro_name;
            return datetime_macro(&w).map(Operand::Lit);
        }
        // a field, optionally with a `:modifier`
        let (name, modifier) = match w.split_once(':') {
            Some((n, m)) => (n.to_string(), Some(parse_modifier(m)?)),
            None => (w, None),
        };
        Ok(Operand::Field { name, modifier })
    }

    fn geo_call(&mut self) -> Result<Operand, String> {
        if self.next() != Some(Tok::LParen) {
            return Err("geoDistance expects '('".into());
        }
        let mut args = Vec::with_capacity(4);
        loop {
            args.push(self.operand()?);
            match self.next() {
                Some(Tok::Comma) => continue,
                Some(Tok::RParen) => break,
                _ => return Err("geoDistance: expected ',' or ')'".into()),
            }
        }
        let arr: [Operand; 4] = args
            .try_into()
            .map_err(|_| "geoDistance takes exactly 4 arguments".to_string())?;
        Ok(Operand::Geo(Box::new(arr)))
    }
}

fn parse_modifier(m: &str) -> Result<Mod, String> {
    Ok(match m {
        "isset" => Mod::Isset,
        "length" => Mod::Length,
        "each" => Mod::Each,
        "lower" => Mod::Lower,
        other => return Err(format!("unsupported field modifier ':{other}'")),
    })
}

impl Operand {
    fn const_value(&self) -> Option<Value> {
        match self {
            Operand::Lit(v) => Some(v.clone()),
            _ => None,
        }
    }
}

// ─── lower to engine Filter (fast SQL path) ──────────────────────────────────

impl PbExpr {
    /// `Some(Filter)` when the whole predicate is plain-SQL-expressible —
    /// no modifiers, no `?`-any, no geoDistance. The records layer uses this
    /// for the WHERE clause; `None` forces the in-memory path.
    pub(crate) fn to_engine_filter(&self) -> Option<Filter> {
        match self {
            PbExpr::Const(true) => Some(Filter::And(vec![])),
            PbExpr::Const(false) => Some(Filter::Or(vec![])),
            PbExpr::And(parts) => parts
                .iter()
                .map(PbExpr::to_engine_filter)
                .collect::<Option<Vec<_>>>()
                .map(Filter::And),
            PbExpr::Or(parts) => parts
                .iter()
                .map(PbExpr::to_engine_filter)
                .collect::<Option<Vec<_>>>()
                .map(Filter::Or),
            PbExpr::Cmp { left, op, right, any } => {
                if *any {
                    return None;
                }
                let Operand::Field { name, modifier: None } = left else {
                    return None;
                };
                let Operand::Lit(v) = right else {
                    return None;
                };
                Some(match op {
                    Cmp::Eq if v.is_null() => Filter::IsNull { field: name.clone(), negate: false },
                    Cmp::Ne if v.is_null() => Filter::IsNull { field: name.clone(), negate: true },
                    Cmp::Eq => cmp(name, CmpOp::Eq, v.clone()),
                    Cmp::Ne => cmp(name, CmpOp::Ne, v.clone()),
                    Cmp::Gt => cmp(name, CmpOp::Gt, v.clone()),
                    Cmp::Gte => cmp(name, CmpOp::Gte, v.clone()),
                    Cmp::Lt => cmp(name, CmpOp::Lt, v.clone()),
                    Cmp::Lte => cmp(name, CmpOp::Lte, v.clone()),
                    Cmp::Like => like(name, v),
                    Cmp::NLike => Filter::Not(Box::new(like(name, v))),
                })
            }
        }
    }

    /// True if the predicate needs in-memory evaluation (an advanced term).
    pub(crate) fn needs_memory(&self) -> bool {
        self.to_engine_filter().is_none()
    }

    /// A SAFE narrowing pre-filter: the top-level AND conjuncts that are each
    /// SQL-expressible, as one engine [`Filter`]. The in-memory eval is still
    /// authoritative; this only reduces how many rows are fetched. `None`
    /// when nothing is expressible (the fetch then scans, capped).
    pub(crate) fn sql_prefilter(&self) -> Option<Filter> {
        match self {
            PbExpr::And(parts) => {
                let fs: Vec<Filter> = parts.iter().filter_map(PbExpr::to_engine_filter).collect();
                (!fs.is_empty()).then(|| Filter::And(fs))
            }
            other => other.to_engine_filter(),
        }
    }

    /// Does the predicate reference any `@collection.*` join?
    pub(crate) fn has_collection_refs(&self) -> bool {
        match self {
            PbExpr::Const(_) => false,
            PbExpr::And(parts) | PbExpr::Or(parts) => parts.iter().any(PbExpr::has_collection_refs),
            PbExpr::Cmp { left, right, .. } => {
                matches!(left, Operand::Collection { .. })
                    || matches!(right, Operand::Collection { .. })
            }
        }
    }

    /// Evaluate the predicate against one record, in memory.
    pub(crate) fn eval(&self, record: &Value) -> bool {
        match self {
            PbExpr::Const(b) => *b,
            PbExpr::And(parts) => parts.iter().all(|p| p.eval(record)),
            PbExpr::Or(parts) => parts.iter().any(|p| p.eval(record)),
            PbExpr::Cmp { left, op, right, any } => eval_compare(left, *op, right, *any, record),
        }
    }
}

/// Resolve a NON-collection operand to its single literal value against a
/// record (used to build a `@collection` EXISTS sub-filter). A Collection
/// operand returns Null (the resolver supplies the other side).
pub(crate) fn operand_literal(op: &Operand, record: &Value) -> Value {
    operand_values(op, record).into_iter().next().unwrap_or(Value::Null)
}

fn cmp(field: &str, op: CmpOp, value: Value) -> Filter {
    Filter::Cmp { field: field.to_string(), op, value }
}

fn like(field: &str, value: &Value) -> Filter {
    let raw = match value {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    let pattern = if raw.contains('%') { raw } else { format!("%{raw}%") };
    Filter::Like { field: field.to_string(), pattern: Value::String(pattern), ci: true }
}

// ─── in-memory evaluation ────────────────────────────────────────────────────

/// The set of values a modifier produces from a field. `:each` and a
/// multi-value column yield multiple values; everything else yields one.
fn operand_values(op: &Operand, record: &Value) -> Vec<Value> {
    match op {
        Operand::Lit(v) => vec![v.clone()],
        // an unresolved Collection ref evaluates as the zero value (the async
        // resolver replaces these with Const before eval; this is the safe
        // fail-closed fallback)
        Operand::Collection { .. } => vec![Value::Null],
        Operand::Geo(args) => vec![geo_distance(args, record)],
        Operand::Field { name, modifier } => {
            let raw = field_value(record, name);
            match modifier {
                None => vec![raw],
                Some(Mod::Isset) => {
                    let set = !matches!(&raw, Value::Null)
                        && raw.as_str() != Some("")
                        && !matches!(&raw, Value::Array(a) if a.is_empty());
                    vec![Value::Bool(set)]
                }
                Some(Mod::Length) => {
                    let n = match &raw {
                        Value::Array(a) => a.len(),
                        Value::String(s) => {
                            // a stringified JSON array still counts its elements
                            serde_json::from_str::<Vec<Value>>(s).map(|a| a.len()).unwrap_or(s.chars().count())
                        }
                        Value::Null => 0,
                        _ => 1,
                    };
                    vec![json!(n)]
                }
                Some(Mod::Lower) => vec![Value::String(value_to_string(&raw).to_lowercase())],
                Some(Mod::Each) => to_array(&raw),
            }
        }
    }
}

/// A field's value. Supports dotted paths for nested values (`place.lon` on a
/// geoPoint `{lon,lat}`) and parses a stringified JSON array/object back (the
/// engine stores multi-value + json columns as TEXT).
fn field_value(record: &Value, name: &str) -> Value {
    // PB field names are dot-free, so `a.b.c` is always a nested traversal.
    let mut cur = record.clone();
    for seg in name.split('.') {
        let mut next = cur.get(seg).cloned().unwrap_or(Value::Null);
        // a stringified JSON object/array mid-path is re-parsed so the next
        // segment can index into it
        if let Value::String(s) = &next {
            if s.starts_with('{') || s.starts_with('[') {
                if let Ok(parsed) = serde_json::from_str::<Value>(s) {
                    next = parsed;
                }
            }
        }
        cur = next;
    }
    cur
}

fn to_array(v: &Value) -> Vec<Value> {
    match v {
        Value::Array(a) => a.clone(),
        Value::Null => vec![],
        other => vec![other.clone()],
    }
}

/// PB comparison semantics (verified against PB v0.39.3):
/// - `field:each <op> v`   → ALL elements of the field's array satisfy `op`;
/// - `field:each ?<op> v`  → ANY element satisfies `op`;
/// - `field <op> v` / `field ?<op> v` (NO `:each`) → compare the field's
///   SINGLE stored value (a multi-value column is its serialized array, so
///   `tags = 'c'` is false but `tags ~ 'c'` matches the substring) — `?` does
///   NOT decompose a stored array.
fn eval_compare(left: &Operand, op: Cmp, right: &Operand, any: bool, record: &Value) -> bool {
    if let Operand::Field { name, modifier: Some(Mod::Each) } = left {
        let elems = to_array(&field_value(record, name));
        let rs = operand_values(right, record);
        let one = |l: &Value| rs.iter().any(|r| eval_cmp(l, op, r));
        return if any { elems.iter().any(one) } else { elems.iter().all(one) };
    }
    let l = operand_values(left, record).into_iter().next().unwrap_or(Value::Null);
    let r = operand_values(right, record).into_iter().next().unwrap_or(Value::Null);
    eval_cmp(&l, op, &r)
}

fn eval_cmp(a: &Value, op: Cmp, b: &Value) -> bool {
    use std::cmp::Ordering::*;
    match op {
        Cmp::Eq => loose_eq(a, b),
        Cmp::Ne => !loose_eq(a, b),
        Cmp::Like => like_match(value_to_string(a).as_str(), &like_pattern(b)),
        Cmp::NLike => !like_match(value_to_string(a).as_str(), &like_pattern(b)),
        Cmp::Lt | Cmp::Lte | Cmp::Gt | Cmp::Gte => {
            let ord = compare_ord(a, b);
            matches!(
                (op, ord),
                (Cmp::Lt, Some(Less))
                    | (Cmp::Lte, Some(Less | Equal))
                    | (Cmp::Gt, Some(Greater))
                    | (Cmp::Gte, Some(Greater | Equal))
            )
        }
    }
}

fn like_pattern(b: &Value) -> String {
    let raw = value_to_string(b);
    if raw.contains('%') { raw } else { format!("%{raw}%") }
}

fn loose_eq(a: &Value, b: &Value) -> bool {
    if a == b {
        return true;
    }
    if let (Some(x), Some(y)) = (a.as_f64(), b.as_f64()) {
        return x == y;
    }
    if let (Some(x), Some(y)) = (a.as_str(), b.as_str()) {
        return x == y;
    }
    (a.is_null() && b.as_str() == Some("")) || (b.is_null() && a.as_str() == Some(""))
}

fn compare_ord(a: &Value, b: &Value) -> Option<std::cmp::Ordering> {
    if let (Some(x), Some(y)) = (a.as_f64(), b.as_f64()) {
        return x.partial_cmp(&y);
    }
    Some(value_to_string(a).cmp(&value_to_string(b)))
}

fn value_to_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

fn like_match(text: &str, pattern: &str) -> bool {
    fn inner(t: &[char], p: &[char]) -> bool {
        match (t, p) {
            (_, []) => t.is_empty(),
            (_, ['%', rest @ ..]) => (0..=t.len()).any(|i| inner(&t[i..], rest)),
            ([], _) => false,
            ([tc, tr @ ..], [pc, pr @ ..]) => {
                (*pc == '_' || tc.eq_ignore_ascii_case(pc)) && inner(tr, pr)
            }
        }
    }
    let t: Vec<char> = text.to_lowercase().chars().collect();
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    inner(&t, &p)
}

/// Haversine distance in KILOMETRES between two lon/lat operands (PB's
/// geoDistance). Args: lonA, latA, lonB, latB.
fn geo_distance(args: &[Operand; 4], record: &Value) -> Value {
    let n = |o: &Operand| -> f64 {
        operand_values(o, record)
            .first()
            .and_then(|v| v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
            .unwrap_or(f64::NAN)
    };
    let (lon1, lat1, lon2, lat2) = (n(&args[0]), n(&args[1]), n(&args[2]), n(&args[3]));
    const R: f64 = 6371.0; // mean earth radius, km
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dphi = (lat2 - lat1).to_radians();
    let dlam = (lon2 - lon1).to_radians();
    let a = (dphi / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dlam / 2.0).sin().powi(2);
    let d = 2.0 * R * a.sqrt().atan2((1.0 - a).sqrt());
    serde_json::Number::from_f64(d).map(Value::Number).unwrap_or(Value::Null)
}

fn datetime_macro(name: &str) -> Result<Value, String> {
    let now = chrono::Utc::now();
    let dt = |t: chrono::DateTime<chrono::Utc>| {
        Value::String(t.format("%Y-%m-%d %H:%M:%S%.3fZ").to_string())
    };
    let day_start = now.date_naive().and_hms_opt(0, 0, 0).unwrap_or_default().and_utc();
    Ok(match name {
        "@now" => dt(now),
        "@todayStart" => dt(day_start),
        "@todayEnd" => dt(day_start + chrono::Duration::days(1) - chrono::Duration::milliseconds(1)),
        "@monthStart" => dt(now
            .date_naive()
            .with_day(1)
            .unwrap_or(now.date_naive())
            .and_hms_opt(0, 0, 0)
            .unwrap_or_default()
            .and_utc()),
        "@yearStart" => dt(chrono::NaiveDate::from_ymd_opt(now.year(), 1, 1)
            .unwrap_or(now.date_naive())
            .and_hms_opt(0, 0, 0)
            .unwrap_or_default()
            .and_utc()),
        "@second" => json!(now.second()),
        "@minute" => json!(now.minute()),
        "@hour" => json!(now.hour()),
        "@day" => json!(now.day()),
        "@month" => json!(now.month()),
        "@weekday" => json!(now.weekday().num_days_from_sunday()),
        "@year" => json!(now.year()),
        other => return Err(format!("unknown datetime macro '{other}'")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none(_: &str) -> Option<Value> {
        None
    }
    fn p(s: &str) -> PbExpr {
        parse(s, &none).unwrap()
    }

    #[test]
    fn simple_predicates_lower_to_sql() {
        // unchanged fast path
        assert!(p("status = 'active'").to_engine_filter().is_some());
        assert!(p("n > 3 && title ~ 'a'").to_engine_filter().is_some());
        assert!(p("deleted = null").to_engine_filter().is_some());
        assert!(!p("status = 'active'").needs_memory());
    }

    #[test]
    fn advanced_terms_force_memory() {
        assert!(p("tags:length > 2").needs_memory());
        assert!(p("name:lower = 'ada'").needs_memory());
        assert!(p("tags ?= 'x'").needs_memory());
        assert!(p("verified:isset = true").needs_memory());
        assert!(p("geoDistance(lon, lat, 2.3, 48.8) < 10").needs_memory());
    }

    #[test]
    fn modifier_isset_and_length() {
        let rec = json!({ "tags": "[\"a\",\"b\",\"c\"]", "title": "hi", "empty": "" });
        assert!(p("tags:length > 2").eval(&rec));
        assert!(!p("tags:length > 5").eval(&rec));
        assert!(p("tags:isset = true").eval(&rec));
        assert!(p("empty:isset = false").eval(&rec));
        assert!(p("missing:isset = false").eval(&rec));
    }

    #[test]
    fn modifier_lower_and_each() {
        let rec = json!({ "name": "ADA", "tags": "[\"x\",\"x\"]", "mixed": "[\"x\",\"y\"]" });
        assert!(p("name:lower = 'ada'").eval(&rec));
        assert!(p("tags:each = 'x'").eval(&rec));
        assert!(!p("mixed:each = 'x'").eval(&rec));
    }

    #[test]
    fn multivalue_each_semantics() {
        // verified against PB v0.39.3
        let rec = json!({ "tags": "[\"a\",\"b\",\"c\"]" });
        // :each ?= → ANY element equals
        assert!(p("tags:each ?= 'c'").eval(&rec));
        assert!(!p("tags:each ?= 'z'").eval(&rec));
        // :each = → ALL elements equal
        assert!(!p("tags:each = 'c'").eval(&rec));
        assert!(p(r#"tags:each ?!= 'z'"#).eval(&rec));
        // plain `?=` does NOT decompose: compares the serialized array
        assert!(!p("tags ?= 'c'").eval(&rec));
        // `~` matches the serialized array substring (the PB idiom)
        assert!(p("tags ~ 'c'").eval(&rec));
    }

    #[test]
    fn dotted_field_access_for_geopoint() {
        // geoPoint stored as a JSON object; place.lon traverses it
        let rec = json!({ "place": { "lon": 2.35, "lat": 48.85 } });
        let rec_str = json!({ "place": "{\"lon\":2.35,\"lat\":48.85}" });
        for r in [&rec, &rec_str] {
            assert!(p("geoDistance(place.lon, place.lat, 2.35, 48.85) < 1").eval(r));
        }
    }

    #[test]
    fn geo_distance_km() {
        // Paris (2.3522,48.8566) → London (-0.1276,51.5072) ≈ 344 km
        let rec = json!({ "lon": 2.3522, "lat": 48.8566 });
        assert!(p("geoDistance(lon, lat, -0.1276, 51.5072) < 400").eval(&rec));
        assert!(!p("geoDistance(lon, lat, -0.1276, 51.5072) < 300").eval(&rec));
    }

    #[test]
    fn folds_constant_request_terms() {
        let auth = |r: &str| (r == "@request.auth.id").then(|| json!("u1"));
        let e = parse("@request.auth.id != ''", &auth).unwrap();
        assert_eq!(e, PbExpr::Const(true));
        let e2 = parse("@request.auth.id = ''", &auth).unwrap();
        assert_eq!(e2, PbExpr::Const(false));
    }

    #[test]
    fn request_substitution_against_field() {
        let auth = |r: &str| (r == "@request.auth.id").then(|| json!("u1"));
        let e = parse("owner = @request.auth.id", &auth).unwrap();
        // owner = 'u1' → SQL-expressible
        assert!(e.to_engine_filter().is_some());
    }

    #[test]
    fn record_filter_rejects_request_refs() {
        assert!(parse("@request.auth.id = '1'", &none).is_err());
        assert!(parse("a = ", &none).is_err());
        assert!(parse("tags:nonsense = 1", &none).is_err());
    }
}
