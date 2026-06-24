/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ident.rs                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:31:33 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:31:35 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

use data_plane_core::{DataPlaneError, DataPlaneResult};

/// Validates a SQL identifier (table or column name) to prevent injection.
///
/// Accepts an optional single schema qualifier: `schema.table`. Each segment
/// must start with a letter or underscore and contain only `[A-Za-z0-9_]`.
/// The returned string is safely double-quoted for interpolation.
#[cfg_attr(not(any(feature = "postgres", feature = "mongodb")), allow(dead_code))]
pub fn quote_ident(raw: &str) -> DataPlaneResult<String> {
    quote_with(raw, '"')
}

/// MySQL variant of [`quote_ident`]. MySQL uses backticks for identifier
/// quoting (`SELECT \`col\` FROM \`tbl\``); double quotes only work in
/// `ANSI_QUOTES` mode and we can't assume that on tenant DBs.
///
/// Marked `dead_code`-allowed because the MySQL adapter wires this in during
/// R7.2 (read path). The function is already covered by unit tests so the
/// quoting contract is locked in before the first caller appears.
#[allow(dead_code)]
pub fn quote_mysql_ident(raw: &str) -> DataPlaneResult<String> {
    quote_with(raw, '`')
}

fn quote_with(raw: &str, quote: char) -> DataPlaneResult<String> {
    let segments: Vec<&str> = raw.split('.').collect();
    if segments.is_empty() || segments.len() > 2 {
        return Err(invalid(raw));
    }
    let mut quoted = Vec::with_capacity(segments.len());
    for seg in segments {
        if !is_valid_segment(seg) {
            return Err(invalid(raw));
        }
        quoted.push(format!("{quote}{seg}{quote}"));
    }
    Ok(quoted.join("."))
}

fn is_valid_segment(seg: &str) -> bool {
    let mut chars = seg.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    seg.len() <= 63 && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn invalid(raw: &str) -> DataPlaneError {
    DataPlaneError::InvalidIdentifier {
        value: raw.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_plain_and_schema_qualified() {
        assert_eq!(quote_ident("users").unwrap(), "\"users\"");
        assert_eq!(quote_ident("public.users").unwrap(), "\"public\".\"users\"");
    }

    #[test]
    fn rejects_injection_attempts() {
        for bad in ["users; drop table", "a.b.c", "1abc", "", "us\"er", "u-v"] {
            assert!(quote_ident(bad).is_err(), "should reject {bad:?}");
        }
    }

    #[test]
    fn mysql_ident_uses_backticks() {
        assert_eq!(quote_mysql_ident("users").unwrap(), "`users`");
        assert_eq!(
            quote_mysql_ident("mini_baas.users").unwrap(),
            "`mini_baas`.`users`"
        );
    }

    #[test]
    fn mysql_ident_rejects_injection() {
        for bad in ["users; drop table", "a.b.c", "1abc", "", "us`er", "u-v"] {
            assert!(quote_mysql_ident(bad).is_err(), "should reject {bad:?}");
        }
    }
}
