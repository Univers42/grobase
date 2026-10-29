/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   default_expr.rs                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! Allowlist grammar for caller-supplied DDL DEFAULT expressions.
//!
//! A DEFAULT clause cannot bind parameters, so every builder (PG ADD COLUMN /
//! SET DEFAULT / CREATE TABLE, MySQL, SQLite) interpolates it as text. A
//! blocklist of `;` / comments was not enough: `'x', DISABLE ROW LEVEL
//! SECURITY` appends a second ALTER action with neither. Only one literal or
//! one fixed niladic function is accepted, so the expression can never leave
//! the DEFAULT position.

use crate::{DataPlaneError, DataPlaneResult};

/// Longest accepted expression, in bytes. No seed, contract or test default
/// comes near it; it bounds the error echo and the DDL text.
const MAX_DEFAULT_LEN: usize = 1024;

/// How much of a rejected expression the error message echoes back.
const ECHO_CHARS: usize = 64;

/// Validates a DEFAULT expression against the allowlist: a numeric literal
/// (`-3.4e38`), a single-quoted string where `''` is the only escape, `NULL`,
/// `TRUE`, `FALSE`, or one of `CURRENT_TIMESTAMP`, `CURRENT_DATE`, `now()`,
/// `gen_random_uuid()`, `uuid_generate_v4()` (keywords case-insensitive).
///
/// Errors with [`DataPlaneError::InvalidRequest`] for anything else, including
/// arithmetic, casts, sub-selects and identifiers such as `current_user`.
pub fn validate_default_expr(expr: &str) -> DataPlaneResult<()> {
    let allowed = expr.len() <= MAX_DEFAULT_LEN
        && (is_niladic_default(expr) || is_numeric_literal(expr) || is_string_literal(expr));
    if allowed {
        return Ok(());
    }
    let echo: String = expr.chars().take(ECHO_CHARS).collect();
    Err(DataPlaneError::InvalidRequest {
        message: format!(
            "default expression '{echo}' is not allowed: use a number, a single-quoted \
             string ('' escapes a quote, no backslash), TRUE, FALSE, NULL, \
             CURRENT_TIMESTAMP, CURRENT_DATE, now(), gen_random_uuid() or \
             uuid_generate_v4() (at most {MAX_DEFAULT_LEN} bytes)"
        ),
    })
}

/// Keyword and zero-argument function defaults every engine path may emit.
fn is_niladic_default(expr: &str) -> bool {
    [
        "NULL",
        "TRUE",
        "FALSE",
        "CURRENT_TIMESTAMP",
        "CURRENT_DATE",
        "now()",
        "gen_random_uuid()",
        "uuid_generate_v4()",
    ]
    .iter()
    .any(|keyword| keyword.eq_ignore_ascii_case(expr))
}

/// `-?digits(.digits)?([eE][+-]?digits)?`
fn is_numeric_literal(expr: &str) -> bool {
    let unsigned = expr.strip_prefix('-').unwrap_or(expr);
    let (mantissa, exponent) = match unsigned.split_once(['e', 'E']) {
        Some((mantissa, exponent)) => (mantissa, Some(exponent)),
        None => (unsigned, None),
    };
    let (integer, fraction) = match mantissa.split_once('.') {
        Some((integer, fraction)) => (integer, Some(fraction)),
        None => (mantissa, None),
    };
    is_digits(integer)
        && fraction.is_none_or(is_digits)
        && exponent.is_none_or(|e| is_digits(e.strip_prefix(['+', '-']).unwrap_or(e)))
}

fn is_digits(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())
}

/// One single-quoted literal. A backslash is refused because MySQL reads `\'`
/// as an escaped quote, which would end the literal early there and nowhere else.
fn is_string_literal(expr: &str) -> bool {
    let Some(body) = expr
        .strip_prefix('\'')
        .and_then(|rest| rest.strip_suffix('\''))
    else {
        return false;
    };
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        let escaped_quote = c == '\'' && chars.next() == Some('\'');
        if (c == '\'' && !escaped_quote) || c == '\\' || c.is_control() {
            return false;
        }
    }
    true
}
