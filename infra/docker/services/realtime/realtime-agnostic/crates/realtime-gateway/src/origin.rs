//! Who may open a WebSocket to the realtime plane.
//!
//! A WebSocket handshake is not a CORS request. The browser sends it to
//! whatever origin a page names, no preflight happens, and no
//! `Access-Control-Allow-Origin` is ever consulted -- the server is the only
//! thing that can say no. A gateway's CORS list therefore protects every REST
//! door and none of this one: a page on any website could open a socket with
//! the public anon key and subscribe to whatever its namespaces allow.
//!
//! Found by serving a test bench from an origin the gateway does not allow:
//! every REST door refused it with a browser-side block, and the socket opened.
//!
//! EMPTY (the default) = byte-parity: no Origin is looked at, exactly as
//! before. Set `REALTIME_ALLOWED_ORIGINS` to a comma-separated list to enforce
//! it. A handshake carrying no Origin header at all is always allowed: only
//! browsers send one, and server-side clients must keep working.

use std::collections::HashSet;

/// The set of browser origins allowed to open a socket.
#[derive(Debug, Clone)]
pub struct OriginPolicy {
    allowed: HashSet<String>,
}

impl OriginPolicy {
    pub const ENV: &'static str = "REALTIME_ALLOWED_ORIGINS";

    /// `Some` only when the variable names at least one origin; `None` is the
    /// parity default and means "do not check".
    pub fn from_env() -> Option<Self> {
        Self::parse(&std::env::var(Self::ENV).ok()?)
    }

    pub fn parse(raw: &str) -> Option<Self> {
        let allowed: HashSet<String> = raw
            .split(',')
            .map(Self::normalize)
            .filter(|s| !s.is_empty())
            .collect();
        if allowed.is_empty() {
            None
        } else {
            Some(Self { allowed })
        }
    }

    /// An `Origin` header is an ASCII-serialized origin -- scheme://host[:port],
    /// never a path -- so it is compared as a whole string, lowercased, with a
    /// stray trailing slash tolerated. No prefix or suffix matching: an
    /// allow-list that matched suffixes would accept `app.example.com.evil.test`.
    fn normalize(s: &str) -> String {
        s.trim().trim_end_matches('/').to_ascii_lowercase()
    }

    pub fn allows(&self, origin: &str) -> bool {
        let o = Self::normalize(origin);
        self.allowed.contains("*") || self.allowed.contains(&o)
    }

    pub fn origins(&self) -> Vec<&str> {
        self.allowed.iter().map(String::as_str).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::OriginPolicy;

    #[test]
    fn nothing_configured_is_no_policy() {
        assert!(OriginPolicy::parse("").is_none());
        assert!(OriginPolicy::parse("   ").is_none());
        assert!(OriginPolicy::parse(" , ,").is_none());
    }

    #[test]
    fn only_the_exact_origins_listed() {
        let p = OriginPolicy::parse("http://localhost:5180, https://app.example.com").unwrap();
        assert!(p.allows("http://localhost:5180"));
        assert!(p.allows("http://LOCALHOST:5180/"), "case and a trailing slash are still the same origin");
        assert!(!p.allows("http://localhost:5181"), "a neighbouring port is a different origin");
        assert!(!p.allows("https://app.example.com.evil.test"), "a suffix is not a match");
        assert!(!p.allows("https://evil.test/?x=https://app.example.com"));
        assert!(!p.allows("null"), "a sandboxed iframe sends null and gets nothing");
        assert!(!p.allows(""));
    }

    #[test]
    fn a_wildcard_is_honoured_when_asked_for_explicitly() {
        let p = OriginPolicy::parse("*").unwrap();
        assert!(p.allows("https://anywhere.example"));
    }
}
