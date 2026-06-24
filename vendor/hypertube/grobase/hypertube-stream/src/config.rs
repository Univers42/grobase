//! Process configuration, read once from the environment at startup and injected
//! into the app state (no globals).

use std::env;

/// listen_default is the bind address when STREAM_ADDR is unset.
const LISTEN_DEFAULT: &str = "0.0.0.0:3083";
/// dataplane_default is the Kong gateway base when STREAM_DATAPLANE_URL is unset.
const DATAPLANE_DEFAULT: &str = "http://kong:8000";

/// Config holds the resolved runtime settings. Streaming works even when the
/// Grobase catalog vars are absent (resolve falls back to archive.org metadata),
/// so those are optional and only warned about.
#[derive(Debug, Clone)]
pub struct Config {
    pub addr: String,
    pub dataplane_url: String,
    pub db_id: Option<String>,
    pub app_api_key: Option<String>,
    pub anon_apikey: Option<String>,
}

impl Config {
    /// from_env reads STREAM_* vars, applying defaults for addr + dataplane and
    /// warning (not panicking) on absent optional secrets.
    pub fn from_env() -> Self {
        let cfg = Config {
            addr: env_or("STREAM_ADDR", LISTEN_DEFAULT),
            dataplane_url: env_or("STREAM_DATAPLANE_URL", DATAPLANE_DEFAULT),
            db_id: env::var("STREAM_DB_ID").ok().filter(|s| !s.is_empty()),
            app_api_key: env::var("STREAM_APP_API_KEY")
                .ok()
                .filter(|s| !s.is_empty()),
            anon_apikey: env::var("STREAM_ANON_APIKEY")
                .ok()
                .filter(|s| !s.is_empty()),
        };
        cfg.warn_missing();
        cfg
    }

    /// catalog_enabled reports whether a Grobase catalog lookup is possible (all
    /// three credential parts present); otherwise resolve uses archive.org only.
    #[inline]
    pub fn catalog_enabled(&self) -> bool {
        self.db_id.is_some() && self.app_api_key.is_some() && self.anon_apikey.is_some()
    }

    /// warn_missing logs each absent optional secret so operators see the
    /// degraded (archive.org-only) mode without a hard failure.
    fn warn_missing(&self) {
        for (name, present) in [
            ("STREAM_DB_ID", self.db_id.is_some()),
            ("STREAM_APP_API_KEY", self.app_api_key.is_some()),
            ("STREAM_ANON_APIKEY", self.anon_apikey.is_some()),
        ] {
            if !present {
                tracing::warn!("{name} unset — catalog lookup disabled, archive.org metadata only");
            }
        }
    }
}

/// env_or reads key or returns the default when unset or empty.
fn env_or(key: &str, default: &str) -> String {
    env::var(key)
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| default.to_string())
}
