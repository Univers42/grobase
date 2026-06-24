//! PocketBase filter-DSL parser → the engine-neutral [`Filter`] AST.
//!
//! Recursive descent over PB's grammar (`||` < `&&` < comparison, parens):
//!   field  = != > >= < <= ~ !~ ?= ?!= ?> ?>= ?< ?<= ?~ ?!~  literal
//! Literals: 'single'/"double" quoted strings (backslash escapes the next
//! char), numbers, `true`/`false`/`null`, and PB's datetime macros (`@now`,
//! `@todayStart`, …). `~`/`!~` follow PB exactly: lowered to a
//! case-insensitive LIKE, auto-wrapping the operand in `%…%` unless it
//! already contains a `%` wildcard.
//!
//! The `?`-prefixed "any of" forms parse to the same predicate as their plain
//! counterpart for now: until multi-value (relation/select) columns land in
//! the facade, every column holds one value and PB defines `?op` on a single
//! value as `op`. `@request.*` / `@collection.*` references and `:modifiers`
//! belong to the RULES engine (Phase K) and are rejected here with a clear
//! error — a plain record filter has no business reading request state.
//!
//! Output reuses [`Filter::parse`]'s invariants (field validation, `$`-free
//! names) by constructing the AST directly through the same public types.

use chrono::{Datelike, Timelike};
use data_plane_core::{CmpOp, Filter};
use serde_json::Value;

/// Maximum `(`-nesting, mirroring `MAX_FILTER_DEPTH` on the JSON grammar.
const MAX_PAREN_DEPTH: usize = 32;

pub fn parse_pb_filter(input: &str) -> Result<Filter, String> {
    // Plain record filters resolve nothing: any `@request...` reference errors.
    parse_pb_filter_with(input, &|_| None)
}

/// Rules-engine entry: `resolver` maps `@request.auth.<field>` references to
/// the caller's literal values. A reference the resolver declines (returns
/// `None` for) is an error — the rules engine fails CLOSED on it.
/// Left-side references const-fold: `@request.auth.id != ''` becomes
/// `And([])` (always true) or `Or([])` (always false), which `Filter::fold`
/// reports as tautology/contradiction.
pub fn parse_pb_filter_with(
    input: &str,
    resolver: &dyn Fn(&str) -> Option<Value>,
) -> Result<Filter, String> {
    let tokens = lex(input)?;
    if tokens.is_empty() {
        return Ok(Filter::And(vec![]));
    }
    let mut p = Parser { tokens, pos: 0 };
    let f = p.or_expr(0, resolver)?;
    match p.peek() {
        None => Ok(f),
        Some(t) => Err(format!("unexpected trailing token {t:?}")),
    }
}

// ─── lexer ───────────────────────────────────────────────────────────────────

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
}

/// Operator tokens, longest first so `?!~` never lexes as `?` + `!~`.
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
                if ch.is_ascii_alphanumeric() || ch == '_' || ch == '.' || ch == ':' {
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

// ─── parser ──────────────────────────────────────────────────────────────────

struct Parser {
    tokens: Vec<Tok>,
    pos: usize,
}

impl Parser {
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

    fn or_expr(
        &mut self,
        depth: usize,
        resolver: &dyn Fn(&str) -> Option<Value>,
    ) -> Result<Filter, String> {
        let mut parts = vec![self.and_expr(depth, resolver)?];
        while self.peek() == Some(&Tok::OrOr) {
            self.next();
            parts.push(self.and_expr(depth, resolver)?);
        }
        Ok(if parts.len() == 1 { parts.pop().expect("len checked") } else { Filter::Or(parts) })
    }

    fn and_expr(
        &mut self,
        depth: usize,
        resolver: &dyn Fn(&str) -> Option<Value>,
    ) -> Result<Filter, String> {
        let mut parts = vec![self.atom(depth, resolver)?];
        while self.peek() == Some(&Tok::AndAnd) {
            self.next();
            parts.push(self.atom(depth, resolver)?);
        }
        Ok(if parts.len() == 1 { parts.pop().expect("len checked") } else { Filter::And(parts) })
    }

    fn atom(
        &mut self,
        depth: usize,
        resolver: &dyn Fn(&str) -> Option<Value>,
    ) -> Result<Filter, String> {
        if depth > MAX_PAREN_DEPTH {
            return Err(format!("filter nesting exceeds the {MAX_PAREN_DEPTH}-level limit"));
        }
        match self.next() {
            Some(Tok::LParen) => {
                let f = self.or_expr(depth + 1, resolver)?;
                match self.next() {
                    Some(Tok::RParen) => Ok(f),
                    _ => Err("missing ')'".into()),
                }
            }
            Some(Tok::Ident(field)) => self.comparison(field, resolver),
            Some(t) => Err(format!("expected a field or '(', got {t:?}")),
            None => Err("unexpected end of filter".into()),
        }
    }

    fn comparison(
        &mut self,
        field: String,
        resolver: &dyn Fn(&str) -> Option<Value>,
    ) -> Result<Filter, String> {
        // Left-side caller reference: resolve and const-fold the comparison.
        if field.starts_with("@request") {
            let Some(left) = resolver(&field) else {
                return Err(format!(
                    "'{field}' is only valid in collection API rules, not record filters"
                ));
            };
            let Some(Tok::Op(op)) = self.next() else {
                return Err(format!("expected an operator after '{field}'"));
            };
            let right = self.literal(resolver)?;
            let truth = const_compare(&left, op.strip_prefix('?').unwrap_or(op), &right)?;
            return Ok(if truth { Filter::And(vec![]) } else { Filter::Or(vec![]) });
        }
        if field.starts_with("@collection") {
            return Err(format!("'{field}' joins are not supported by this engine version"));
        }
        if field.contains(':') {
            return Err(format!("field modifiers are not supported: '{field}'"));
        }
        if field.starts_with('@') {
            return Err(format!("a datetime macro ('{field}') cannot be the left operand"));
        }
        let Some(Tok::Op(op)) = self.next() else {
            return Err(format!("expected an operator after '{field}'"));
        };
        let value = self.literal(resolver)?;
        // `?op` ≡ `op` while every facade column is single-valued (PB defines
        // the "any of" forms as plain `op` over each value).
        let plain = op.strip_prefix('?').unwrap_or(op);
        Ok(match plain {
            "=" if value.is_null() => Filter::IsNull { field, negate: false },
            "!=" if value.is_null() => Filter::IsNull { field, negate: true },
            "=" => cmp(field, CmpOp::Eq, value),
            "!=" => cmp(field, CmpOp::Ne, value),
            ">" => cmp(field, CmpOp::Gt, value),
            ">=" => cmp(field, CmpOp::Gte, value),
            "<" => cmp(field, CmpOp::Lt, value),
            "<=" => cmp(field, CmpOp::Lte, value),
            "~" => like(field, &value),
            "!~" => Filter::Not(Box::new(like(field, &value))),
            other => return Err(format!("unsupported operator '{other}'")),
        })
    }

    fn literal(&mut self, resolver: &dyn Fn(&str) -> Option<Value>) -> Result<Value, String> {
        match self.next() {
            Some(Tok::Str(s)) => Ok(Value::String(s)),
            Some(Tok::Num(n)) => Ok(serde_json::Number::from_f64(n)
                .map(Value::Number)
                .unwrap_or(Value::Null)),
            Some(Tok::Ident(w)) => match w.as_str() {
                "true" => Ok(Value::Bool(true)),
                "false" => Ok(Value::Bool(false)),
                "null" => Ok(Value::Null),
                m if m.starts_with("@request") => resolver(m)
                    .ok_or_else(|| format!("'{m}' is not available in this context")),
                m if m.starts_with('@') => datetime_macro(m),
                other => Err(format!(
                    "right operand must be a literal or datetime macro, got '{other}'"
                )),
            },
            t => Err(format!("expected a literal, got {t:?}")),
        }
    }
}

fn cmp(field: String, op: CmpOp, value: Value) -> Filter {
    Filter::Cmp { field, op, value }
}

/// Compare two resolved literals at parse time (left-side `@request.*`).
/// Supports the equality/ordering operators; `~` on two literals is rare
/// enough to refuse (fail closed) rather than approximate.
fn const_compare(left: &Value, op: &str, right: &Value) -> Result<bool, String> {
    let eq = || {
        left == right
            || matches!((left.as_f64(), right.as_f64()), (Some(a), Some(b)) if a == b)
            || matches!((left.as_str(), right.as_str()), (Some(a), Some(b)) if a == b)
            || (left.is_null() && right.as_str() == Some(""))
            || (right.is_null() && left.as_str() == Some(""))
    };
    let ord = || -> Option<std::cmp::Ordering> {
        if let (Some(a), Some(b)) = (left.as_f64(), right.as_f64()) {
            a.partial_cmp(&b)
        } else {
            Some(
                left.as_str()
                    .unwrap_or(&left.to_string())
                    .cmp(right.as_str().unwrap_or(&right.to_string())),
            )
        }
    };
    use std::cmp::Ordering::*;
    Ok(match op {
        "=" => eq(),
        "!=" => !eq(),
        ">" => matches!(ord(), Some(Greater)),
        ">=" => matches!(ord(), Some(Greater | Equal)),
        "<" => matches!(ord(), Some(Less)),
        "<=" => matches!(ord(), Some(Less | Equal)),
        other => return Err(format!("operator '{other}' is not supported on caller references")),
    })
}

/// PB `~`: case-insensitive LIKE; the operand is wrapped `%…%` unless the
/// caller placed a `%` wildcard themselves. Non-string operands stringify.
fn like(field: String, value: &Value) -> Filter {
    let raw = match value {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    let pattern = if raw.contains('%') { raw } else { format!("%{raw}%") };
    Filter::Like { field, pattern: Value::String(pattern), ci: true }
}

/// PB's datetime macros, evaluated at parse time. Datetimes render in PB's
/// canonical `YYYY-MM-DD HH:MM:SS.mmmZ` so string comparison orders correctly.
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
        "@second" => Value::Number(now.second().into()),
        "@minute" => Value::Number(now.minute().into()),
        "@hour" => Value::Number(now.hour().into()),
        "@day" => Value::Number(now.day().into()),
        "@month" => Value::Number(now.month().into()),
        "@weekday" => Value::Number(now.weekday().num_days_from_sunday().into()),
        "@year" => Value::Number(now.year().into()),
        other => return Err(format!("unknown datetime macro '{other}'")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(s: &str) -> Filter {
        parse_pb_filter(s).unwrap()
    }

    #[test]
    fn parses_simple_comparisons() {
        assert_eq!(
            f("status = 'active'"),
            Filter::Cmp { field: "status".into(), op: CmpOp::Eq, value: "active".into() }
        );
        assert_eq!(
            f("count > 5"),
            Filter::Cmp { field: "count".into(), op: CmpOp::Gt, value: serde_json::json!(5.0) }
        );
        assert_eq!(
            f("done = true"),
            Filter::Cmp { field: "done".into(), op: CmpOp::Eq, value: Value::Bool(true) }
        );
    }

    #[test]
    fn null_equality_lowers_to_is_null() {
        assert_eq!(f("deleted = null"), Filter::IsNull { field: "deleted".into(), negate: false });
        assert_eq!(f("deleted != null"), Filter::IsNull { field: "deleted".into(), negate: true });
    }

    #[test]
    fn tilde_wraps_in_wildcards_like_pb() {
        assert_eq!(
            f("title ~ 'abc'"),
            Filter::Like { field: "title".into(), pattern: "%abc%".into(), ci: true }
        );
        // an explicit wildcard is respected, not double-wrapped
        assert_eq!(
            f("title ~ 'ab%'"),
            Filter::Like { field: "title".into(), pattern: "ab%".into(), ci: true }
        );
        assert!(matches!(f("title !~ 'x'"), Filter::Not(_)));
    }

    #[test]
    fn boolean_composition_and_parens() {
        let got = f("a = 1 && (b = 2 || c = 3)");
        let Filter::And(parts) = got else { panic!("expected And") };
        assert_eq!(parts.len(), 2);
        assert!(matches!(&parts[1], Filter::Or(o) if o.len() == 2));
    }

    #[test]
    fn any_of_forms_parse_as_plain_ops() {
        assert_eq!(f("tag ?= 'x'"), f("tag = 'x'"));
        assert_eq!(f("n ?> 3"), f("n > 3"));
        assert_eq!(f("t ?!~ 'y'"), f("t !~ 'y'"));
    }

    #[test]
    fn datetime_macros_evaluate() {
        let Filter::Cmp { value, .. } = f("created >= @todayStart") else { panic!() };
        let s = value.as_str().unwrap();
        assert!(s.ends_with(" 00:00:00.000Z"), "got {s}");
        let Filter::Cmp { value, .. } = f("created < @now") else { panic!() };
        assert!(value.as_str().unwrap().ends_with('Z'));
    }

    #[test]
    fn escapes_quotes_and_rejects_garbage() {
        assert_eq!(
            f(r#"name = 'it\'s'"#),
            Filter::Cmp { field: "name".into(), op: CmpOp::Eq, value: "it's".into() }
        );
        assert!(parse_pb_filter("a = ").is_err());
        assert!(parse_pb_filter("= 'x'").is_err());
        assert!(parse_pb_filter("a = 'x' &&").is_err());
        assert!(parse_pb_filter("a = 'unterminated").is_err());
        assert!(parse_pb_filter("@now = 1").is_err(), "macro as left operand");
        assert!(parse_pb_filter("@request.auth.id = 'x'").is_err(), "rules-only ref");
        assert!(parse_pb_filter("a:isset = true").is_err(), "rules-only modifier");
    }

    #[test]
    fn empty_filter_constrains_nothing() {
        assert_eq!(f(""), Filter::And(vec![]));
        assert_eq!(f("   "), Filter::And(vec![]));
    }

    #[test]
    fn paren_depth_is_bounded() {
        let deep = format!("{}a=1{}", "(".repeat(40), ")".repeat(40));
        assert!(parse_pb_filter(&deep).is_err());
    }
}
