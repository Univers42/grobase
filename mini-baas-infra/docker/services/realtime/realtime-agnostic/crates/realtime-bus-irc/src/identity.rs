//! Derive a valid IRC nickname from a platform identity.
//!
//! RFC 2812 limits a nickname to a letter-or-special first character followed by
//! letters, digits, specials, or '-'. The IRC server advertises a max length of
//! 9, so nicks are capped short — we keep a sanitized prefix of the handle plus a
//! short, stable suffix hashed from the user id, so two users who share a handle
//! prefix still get distinct, deterministic nicks without a server round-trip.

/// Default maximum nickname length (matches the IRC server's advertised limit).
pub const DEFAULT_NICK_MAX: usize = 9;

const fn is_special(c: char) -> bool {
    matches!(c, '[' | ']' | '\\' | '`' | '_' | '^' | '{' | '|' | '}')
}

const fn is_nick_start(c: char) -> bool {
    c.is_ascii_alphabetic() || is_special(c)
}

const fn is_nick_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '-' || is_special(c)
}

/// Small, stable 64-bit string hash (no dependencies).
fn fnv1a(s: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in s.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// Render a number as a fixed-width lowercase base-36 string.
fn base36(mut n: u64, len: usize) -> String {
    const ALPHABET: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = vec![b'0'; len];
    for slot in out.iter_mut().rev() {
        *slot = ALPHABET[(n % 36) as usize];
        n /= 36;
    }
    String::from_utf8(out).unwrap_or_default()
}

/// Derive a deterministic, RFC-2812-valid nickname for a platform user.
///
/// `handle` is the preferred display name (may be empty); `user_id` is the
/// stable account id used for the uniqueness suffix. The result is at most
/// `max_len` characters, starts with a letter or special char, and contains
/// only nick-legal characters.
#[must_use]
pub fn to_irc_nick(user_id: &str, handle: &str, max_len: usize) -> String {
    let max = max_len.max(1);
    let suffix_len = match max {
        0..=1 => 0,
        2..=3 => 1,
        _ => 3,
    };
    let suffix = base36(fnv1a(user_id), suffix_len);

    let base = if handle.trim().is_empty() {
        user_id
    } else {
        handle
    };
    let prefix_len = max - suffix_len;
    let prefix: String = base
        .chars()
        .filter(|&c| is_nick_char(c))
        .take(prefix_len)
        .collect();

    let mut nick = format!("{prefix}{suffix}");
    if nick.is_empty() {
        nick = "user".chars().take(max).collect();
    }
    let first = nick.chars().next().unwrap_or('u');
    if !is_nick_start(first) {
        // Prepend a legal starting char and re-cap to max_len.
        nick = format!("u{nick}").chars().take(max).collect();
    }
    nick
}

#[cfg(test)]
mod tests {
    use super::{is_nick_char, is_nick_start, to_irc_nick, DEFAULT_NICK_MAX};

    fn valid(nick: &str, max: usize) -> bool {
        !nick.is_empty()
            && nick.chars().count() <= max
            && is_nick_start(nick.chars().next().unwrap_or(' '))
            && nick.chars().all(is_nick_char)
    }

    #[test]
    fn plain_handle_is_valid_and_capped() {
        let n = to_irc_nick("user-123", "alice", DEFAULT_NICK_MAX);
        assert!(valid(&n, DEFAULT_NICK_MAX), "{n}");
        assert!(n.starts_with("alice"));
    }

    #[test]
    fn deterministic() {
        let a = to_irc_nick("u1", "bob", DEFAULT_NICK_MAX);
        let b = to_irc_nick("u1", "bob", DEFAULT_NICK_MAX);
        assert_eq!(a, b);
    }

    #[test]
    fn same_handle_different_users_differ() {
        let a = to_irc_nick("user-1", "sam", DEFAULT_NICK_MAX);
        let b = to_irc_nick("user-2", "sam", DEFAULT_NICK_MAX);
        assert_ne!(a, b);
    }

    #[test]
    fn sanitizes_illegal_chars() {
        let n = to_irc_nick("uid", "a.b c@d!", DEFAULT_NICK_MAX);
        assert!(valid(&n, DEFAULT_NICK_MAX), "{n}");
    }

    #[test]
    fn digit_leading_handle_gets_legal_start() {
        let n = to_irc_nick("uid", "9lives", DEFAULT_NICK_MAX);
        assert!(is_nick_start(n.chars().next().unwrap_or(' ')), "{n}");
    }

    #[test]
    fn empty_handle_falls_back_to_user_id() {
        let n = to_irc_nick("acct-xyz", "", DEFAULT_NICK_MAX);
        assert!(valid(&n, DEFAULT_NICK_MAX), "{n}");
    }
}
