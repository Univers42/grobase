/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sslmode.rs                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 09:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 09:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! A DSN's `sslmode`, PARSED the way tokio-postgres 0.7 parses it.
//!
//! `conn.rs` used to find it with `contains("sslmode=…")`, which reads a
//! password holding `sslmode=verify-full` as the mode and `replace` then
//! rewrote the password. The realtime producer carries the same parser
//! (`realtime-db-postgres/src/producer/tls.rs`, ADR 0014); it is a separate
//! Cargo workspace and Docker context, so the code is copied, not shared.

use std::ops::Range;

/// The DSN's `sslmode` value, decoded; `None` when it carries none.
pub(super) fn sslmode(dsn: &str) -> Option<String> {
    find_sslmode(dsn).map(|(mode, _)| mode)
}

/// `dsn` with its `sslmode` VALUE replaced by `to` when `rewrite(value)`;
/// every other byte, the password included, is unchanged.
pub(super) fn rewrite_sslmode(dsn: &str, rewrite: impl Fn(&str) -> bool, to: &str) -> String {
    let mut out = dsn.to_owned();
    if let Some((mode, span)) = find_sslmode(dsn) {
        if rewrite(&mode) {
            out.replace_range(span, to);
        }
    }
    out
}

/// Where the effective `sslmode` sits: its decoded value and the byte span of
/// its raw text. The LAST occurrence wins, as tokio-postgres applies them in order.
fn find_sslmode(dsn: &str) -> Option<(String, Range<usize>)> {
    let Some(rest) = ["postgres://", "postgresql://"]
        .iter()
        .find_map(|scheme| dsn.strip_prefix(scheme))
    else {
        return find_in_key_values(dsn);
    };
    // tokio-postgres: credentials end at the FIRST '@', the query starts at
    // the first '?' after them. A '?' or '@' inside the password must be
    // percent-encoded, or tokio-postgres itself would split there.
    let authority = dsn.len() - rest.len() + rest.find('@').map_or(0, |at| at + 1);
    let query = authority + dsn[authority..].find('?')? + 1;
    let mut found = None;
    let mut pos = query;
    for pair in dsn[query..].split('&') {
        if let Some((key, value)) = pair.split_once('=') {
            if percent_decode(key) == "sslmode" {
                let start = pos + key.len() + 1;
                found = Some((percent_decode(value), start..start + value.len()));
            }
        }
        pos += pair.len() + 1;
    }
    found
}

/// The libpq `key = value` form: whitespace separates pairs, values may be
/// single-quoted, a backslash escapes the next character.
fn find_in_key_values(dsn: &str) -> Option<(String, Range<usize>)> {
    let bytes = dsn.as_bytes();
    let skip_space = |mut i: usize| {
        while bytes.get(i).is_some_and(u8::is_ascii_whitespace) {
            i += 1;
        }
        i
    };
    let mut found = None;
    let mut i = skip_space(0);
    while i < bytes.len() {
        let key_start = i;
        while bytes
            .get(i)
            .is_some_and(|b| !b.is_ascii_whitespace() && *b != b'=')
        {
            i += 1;
        }
        let key = &dsn[key_start..i];
        i = skip_space(i);
        if bytes.get(i) != Some(&b'=') {
            // Malformed; tokio-postgres refuses this DSN before any socket opens.
            return found;
        }
        let value_start = skip_space(i + 1);
        let (value, value_end) = read_value(bytes, value_start);
        if key == "sslmode" {
            found = Some((value, value_start..value_end));
        }
        i = skip_space(value_end);
    }
    found
}

/// One key=value value starting at `start`: its unescaped text and the index
/// just past it (past the closing quote when quoted).
fn read_value(bytes: &[u8], start: usize) -> (String, usize) {
    let quoted = bytes.get(start) == Some(&b'\'');
    let mut i = start + usize::from(quoted);
    let mut out = Vec::new();
    while let Some(&b) = bytes.get(i) {
        match b {
            b'\\' if i + 1 < bytes.len() => {
                out.push(bytes[i + 1]);
                i += 2;
            }
            b'\'' if quoted => return (String::from_utf8_lossy(&out).into_owned(), i + 1),
            b if !quoted && b.is_ascii_whitespace() => break,
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    (String::from_utf8_lossy(&out).into_owned(), i)
}

fn percent_decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = raw
            .get(i + 1..i + 3)
            .filter(|_| bytes[i] == b'%')
            .and_then(|h| u8::from_str_radix(h, 16).ok());
        if let Some(byte) = hex {
            out.push(byte);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::{rewrite_sslmode, sslmode};

    #[test]
    fn sslmode_is_parsed_not_matched() {
        let cases: &[(&str, Option<&str>)] = &[
            ("postgres://u:p@h/db?sslmode=require", Some("require")),
            (
                "postgresql://u:p@h/db?a=1&sslmode=verify-full&b=2",
                Some("verify-full"),
            ),
            ("host=h sslmode=require", Some("require")),
            ("host=h sslmode = require", Some("require")),
            ("host=h sslmode='verify-ca'", Some("verify-ca")),
            ("postgres://u:p%40ss@h/db?sslmode=require", Some("require")),
            ("postgres://u:p@h/db?ssl%6Dode=re%71uire", Some("require")),
            (
                "postgres://u:p@h/db?sslmode=disable&sslmode=require",
                Some("require"),
            ),
            ("postgres://u:p%3Fsslmode%3Dverify-full@h/db", None),
            ("host=h password='a sslmode=verify-full'", None),
            ("host=h password=a\\ sslmode=verify-full", None),
            ("postgres://u:p@h/db?application_name=sslmode", None),
            ("postgres://u:p@h/db", None),
            ("host=h dbname=d", None),
        ];
        for (dsn, want) in cases {
            assert_eq!(sslmode(dsn).as_deref(), *want, "{dsn}");
        }
    }

    #[test]
    fn rewrite_touches_only_the_sslmode_value() {
        let verify = |m: &str| m == "verify-full" || m == "verify-ca";
        let cases: &[(&str, &str)] = &[
            (
                "postgres://u:p@h/db?a=1&sslmode=verify-full&b=2",
                "postgres://u:p@h/db?a=1&sslmode=require&b=2",
            ),
            (
                "host=h sslmode = 'verify-ca' user=u",
                "host=h sslmode = require user=u",
            ),
            ("host=h sslmode=require", "host=h sslmode=require"),
            (
                "postgres://u:p%3Fsslmode%3Dverify-full@h/db",
                "postgres://u:p%3Fsslmode%3Dverify-full@h/db",
            ),
            (
                "host=h password='a sslmode=verify-full' sslmode=verify-full",
                "host=h password='a sslmode=verify-full' sslmode=require",
            ),
        ];
        for (dsn, want) in cases {
            assert_eq!(rewrite_sslmode(dsn, verify, "require"), *want, "{dsn}");
        }
    }
}
