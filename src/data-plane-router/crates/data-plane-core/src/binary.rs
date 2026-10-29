/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   binary.rs                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 18:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 18:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The one text form of a binary value on the wire: `\x` + lowercase hex,
//! which is what Postgres `to_jsonb` already prints for `bytea`. Every engine
//! renders binary cells this way, so a value read from one engine writes back
//! to another unchanged.

use std::fmt::Write as _;

/// `[0xde, 0xad]` → `\xdead`.
#[must_use]
pub fn hex_bytes(bytes: &[u8]) -> String {
    bytes.iter().fold(String::from("\\x"), |mut hex, byte| {
        let _ = write!(hex, "{byte:02x}");
        hex
    })
}

/// `\xdead` (either case) → its bytes; `None` when the text is not that form.
#[must_use]
pub fn parse_hex_bytes(text: &str) -> Option<Vec<u8>> {
    let digits = text.strip_prefix("\\x")?.as_bytes();
    // from_str_radix alone would take "+1" as a byte.
    if digits.len() % 2 != 0 || !digits.iter().all(u8::is_ascii_hexdigit) {
        return None;
    }
    digits
        .chunks(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips_every_byte() {
        let all: Vec<u8> = (0..=255).collect();
        assert_eq!(parse_hex_bytes(&hex_bytes(&all)), Some(all));
        assert_eq!(hex_bytes(&[]), "\\x");
        assert_eq!(parse_hex_bytes("\\x"), Some(vec![]));
        assert_eq!(parse_hex_bytes("\\xDEad"), Some(vec![0xde, 0xad]));
    }

    #[test]
    fn non_hex_text_is_not_binary() {
        for text in ["dead", "\\xabc", "\\xzz", "\\x+1", "blob:3 bytes"] {
            assert_eq!(parse_hex_bytes(text), None, "{text}");
        }
    }
}
