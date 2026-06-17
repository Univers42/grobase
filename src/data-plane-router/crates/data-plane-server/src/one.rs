//! binocle-one — "our PocketBase": the nano runtime + user accounts.
//!
//! Adds to nano, in the same single static binary:
//! - **Email/password accounts** (`one_users` in the meta DB) hashed with
//!   **argon2id** — passwords are low-entropy, so the memory-hard KDF that was
//!   deliberately skipped for the high-entropy API keys is exactly right here.
//!   Hash + verify run in `spawn_blocking` (they cost tens of ms by design).
//! - **HS256 JWT sessions** minted and verified in-process. The secret comes
//!   from `ONE_JWT_SECRET` or is generated once and persisted in `one_config`.
//! - **Opaque rotating refresh tokens** (`one_refresh`): stored as SHA-256
//!   digests, single-use (consumed + reissued on every refresh), 30-day TTL.
//! - **Per-user data isolation for free**: a verified JWT becomes the
//!   principal `user:<id>` with `IdentitySource::Jwt`, so the existing
//!   owner-scoping stamps and filters rows per user, and the compiled-in ABAC
//!   field masks apply — the same `/data/v1` door, no adapter changes.
//!
//! The admin escape hatch stays key-based: machine keys (incl. the boot admin
//! key) keep the stable `api-key:local` principal; an admin reads ACROSS users
//! via `/nano/v1/raw` (owner-scoping applies to the safe CRUD shape, not raw).

use std::sync::Arc;
use std::time::Duration;

use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use tower_http::trace::TraceLayer;

use crate::auth::VerifiedIdentity;
use crate::config::ServerConfig;
use crate::nano::NanoState;
use crate::routes::{api_err, AppState};

/// Access-token lifetime (seconds) — `ONE_JWT_TTL_SECS` overrides.
const DEFAULT_JWT_TTL_SECS: u64 = 3600;
/// Refresh-token lifetime: 30 days.
const REFRESH_TTL_SECS: i64 = 30 * 24 * 3600;

// ─── helpers ─────────────────────────────────────────────────────────────────

/// Extract a `Bearer` token from the Authorization header.
pub(crate) fn bearer_token(headers: &header::HeaderMap) -> Option<String> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer ").or_else(|| v.strip_prefix("bearer ")))
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

pub(crate) fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    let out = hasher.finalize();
    let mut hex = String::with_capacity(64);
    for b in out {
        use std::fmt::Write;
        let _ = write!(hex, "{b:02x}");
    }
    hex
}

fn ct_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub(crate) fn hash_password(password: &str) -> Result<String, String> {
    use argon2::password_hash::{PasswordHasher, SaltString};
    // 16 random bytes from the OS CSPRNG via uuid v4 (getrandom-backed) — no
    // extra rand_core dependency for one salt.
    let raw: [u8; 16] = *uuid::Uuid::new_v4().as_bytes();
    let salt = SaltString::encode_b64(&raw).map_err(|e| e.to_string())?;
    argon2::Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

pub(crate) fn verify_password(password: &str, stored: &str) -> bool {
    use argon2::password_hash::{PasswordHash, PasswordVerifier};
    PasswordHash::new(stored)
        .map(|parsed| {
            argon2::Argon2::default()
                .verify_password(password.as_bytes(), &parsed)
                .is_ok()
        })
        .unwrap_or(false)
}

// ─── user store ──────────────────────────────────────────────────────────────

#[derive(Serialize, Clone)]
pub(crate) struct UserPublic {
    pub(crate) id: String,
    pub(crate) email: String,
    pub(crate) verified: bool,
    pub(crate) created_at: String,
}

/// A stored file's metadata row (the bytes live on disk under
/// `{data_dir}/storage/{table}/{record}/{field}/{stored}`).
#[derive(Serialize, Clone)]
pub(crate) struct FileMeta {
    pub(crate) id: String,
    pub(crate) table_name: String,
    pub(crate) record_id: String,
    pub(crate) field: String,
    pub(crate) owner: String,
    pub(crate) filename: String,
    pub(crate) stored: String,
    pub(crate) content_type: String,
    pub(crate) size: i64,
    pub(crate) created_at: String,
}

impl FileMeta {
    fn from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: r.get(0)?,
            table_name: r.get(1)?,
            record_id: r.get(2)?,
            field: r.get(3)?,
            owner: r.get(4)?,
            filename: r.get(5)?,
            stored: r.get(6)?,
            content_type: r.get(7)?,
            size: r.get(8)?,
            created_at: r.get(9)?,
        })
    }
}

/// SQLite-backed account store, sharing the nano meta DB file. All calls are
/// sub-millisecond except argon2 (which callers wrap in `spawn_blocking`).
pub(crate) struct UserStore {
    conn: std::sync::Mutex<rusqlite::Connection>,
}

impl UserStore {
    fn open(path: &std::path::Path) -> anyhow::Result<Self> {
        let conn = rusqlite::Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "busy_timeout", 5000)?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS one_users (
                id         TEXT PRIMARY KEY,
                email      TEXT UNIQUE NOT NULL,
                pass_hash  TEXT NOT NULL,
                verified   INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS one_refresh (
                id         TEXT PRIMARY KEY,
                user_id    TEXT NOT NULL,
                digest     TEXT NOT NULL,
                expires_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS one_config (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS one_user_identities (
                provider   TEXT NOT NULL,
                subject    TEXT NOT NULL,
                user_id    TEXT NOT NULL,
                email      TEXT,
                created_at TEXT NOT NULL,
                PRIMARY KEY (provider, subject)
            );
            CREATE TABLE IF NOT EXISTS one_codes (
                purpose    TEXT NOT NULL,
                email      TEXT NOT NULL,
                digest     TEXT NOT NULL,
                expires_at INTEGER NOT NULL,
                attempts   INTEGER NOT NULL DEFAULT 0,
                issued_at  INTEGER NOT NULL,
                PRIMARY KEY (purpose, email)
            );
            CREATE TABLE IF NOT EXISTS one_totp (
                user_id    TEXT PRIMARY KEY,
                secret     TEXT NOT NULL,
                enabled    INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS one_recovery (
                user_id TEXT NOT NULL,
                digest  TEXT NOT NULL,
                PRIMARY KEY (user_id, digest)
            );
            CREATE TABLE IF NOT EXISTS one_files (
                id           TEXT PRIMARY KEY,
                table_name   TEXT NOT NULL,
                record_id    TEXT NOT NULL,
                field        TEXT NOT NULL,
                owner        TEXT NOT NULL,
                filename     TEXT NOT NULL,
                stored       TEXT NOT NULL,
                content_type TEXT NOT NULL,
                size         INTEGER NOT NULL,
                created_at   TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS one_files_record
                ON one_files (table_name, record_id);",
        )?;
        Ok(Self {
            conn: std::sync::Mutex::new(conn),
        })
    }

    fn config_get(&self, key: &str) -> Option<String> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.query_row("SELECT value FROM one_config WHERE key = ?1", [key], |r| r.get(0))
            .ok()
    }

    fn config_set(&self, key: &str, value: &str) -> anyhow::Result<()> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute(
            "INSERT INTO one_config (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value],
        )?;
        Ok(())
    }

    fn create_user(&self, email: &str, pass_hash: &str) -> anyhow::Result<String> {
        let id = uuid::Uuid::new_v4().simple().to_string();
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute(
            "INSERT INTO one_users (id, email, pass_hash, created_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![id, email, pass_hash, chrono::Utc::now().to_rfc3339()],
        )?;
        Ok(id)
    }

    fn find_by_email(&self, email: &str) -> Option<(String, String)> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.query_row(
            "SELECT id, pass_hash FROM one_users WHERE email = ?1",
            [email],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .ok()
    }

    pub(crate) fn get_user(&self, id: &str) -> Option<UserPublic> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.query_row(
            "SELECT id, email, verified, created_at FROM one_users WHERE id = ?1",
            [id],
            |r| {
                Ok(UserPublic {
                    id: r.get(0)?,
                    email: r.get(1)?,
                    verified: r.get::<_, i64>(2)? != 0,
                    created_at: r.get(3)?,
                })
            },
        )
        .ok()
    }

    pub(crate) fn find_user_id_by_email(&self, email: &str) -> Option<String> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.query_row("SELECT id FROM one_users WHERE email = ?1", [email], |r| r.get(0))
            .ok()
    }

    /// `subject` is already provider-prefixed (`<provider>:<remote id>`).
    fn find_identity(&self, provider: &str, subject: &str) -> Option<String> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.query_row(
            "SELECT user_id FROM one_user_identities WHERE provider = ?1 AND subject = ?2",
            [provider, subject],
            |r| r.get(0),
        )
        .ok()
    }

    fn link_identity(
        &self,
        provider: &str,
        subject: &str,
        user_id: &str,
        email: Option<&str>,
    ) -> anyhow::Result<()> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute(
            "INSERT INTO one_user_identities (provider, subject, user_id, email, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(provider, subject) DO NOTHING",
            rusqlite::params![provider, subject, user_id, email, chrono::Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub(crate) fn mark_verified(&self, user_id: &str) {
        let conn = self.conn.lock().expect("user store poisoned");
        let _ = conn.execute("UPDATE one_users SET verified = 1 WHERE id = ?1", [user_id]);
    }

    pub(crate) fn set_password(&self, user_id: &str, pass_hash: &str) -> anyhow::Result<()> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute(
            "UPDATE one_users SET pass_hash = ?2 WHERE id = ?1",
            [user_id, pass_hash],
        )?;
        Ok(())
    }

    /// Revoke every outstanding refresh token (used after a password reset).
    pub(crate) fn revoke_user_refresh(&self, user_id: &str) {
        let conn = self.conn.lock().expect("user store poisoned");
        let _ = conn.execute("DELETE FROM one_refresh WHERE user_id = ?1", [user_id]);
    }

    // ── short-lived email codes (verification / reset / OTP) ────────────────

    /// Issue an 8-digit code for `(purpose, email)` — replaces any previous
    /// one, 10-minute TTL, 30-second resend floor (anti mail-bomb).
    pub(crate) fn issue_code(&self, purpose: &str, email: &str) -> Result<String, &'static str> {
        let now = chrono::Utc::now().timestamp();
        let conn = self.conn.lock().expect("user store poisoned");
        let last: Option<i64> = conn
            .query_row(
                "SELECT issued_at FROM one_codes WHERE purpose = ?1 AND email = ?2",
                [purpose, email],
                |r| r.get(0),
            )
            .ok();
        if let Some(last) = last {
            if now - last < 30 {
                return Err("a code was just sent; wait before requesting another");
            }
        }
        let code = format!("{:08}", uuid::Uuid::new_v4().as_u128() % 100_000_000);
        conn.execute(
            "INSERT INTO one_codes (purpose, email, digest, expires_at, attempts, issued_at)
             VALUES (?1, ?2, ?3, ?4, 0, ?5)
             ON CONFLICT(purpose, email) DO UPDATE SET
               digest = excluded.digest, expires_at = excluded.expires_at,
               attempts = 0, issued_at = excluded.issued_at",
            rusqlite::params![purpose, email, sha256_hex(&code), now + 600, now],
        )
        .map_err(|_| "code store write failed")?;
        Ok(code)
    }

    /// Verify-and-consume: success burns the row; 5 failed attempts burn it
    /// too (no offline brute-force of an 8-digit space).
    pub(crate) fn consume_code(&self, purpose: &str, email: &str, code: &str) -> bool {
        let now = chrono::Utc::now().timestamp();
        let conn = self.conn.lock().expect("user store poisoned");
        let row: Option<(String, i64, i64)> = conn
            .query_row(
                "SELECT digest, expires_at, attempts FROM one_codes WHERE purpose = ?1 AND email = ?2",
                [purpose, email],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .ok();
        let Some((digest, expires_at, attempts)) = row else {
            return false;
        };
        if now >= expires_at || attempts >= 5 {
            let _ = conn.execute(
                "DELETE FROM one_codes WHERE purpose = ?1 AND email = ?2",
                [purpose, email],
            );
            return false;
        }
        if ct_eq(&sha256_hex(code), &digest) {
            let _ = conn.execute(
                "DELETE FROM one_codes WHERE purpose = ?1 AND email = ?2",
                [purpose, email],
            );
            true
        } else {
            let _ = conn.execute(
                "UPDATE one_codes SET attempts = attempts + 1 WHERE purpose = ?1 AND email = ?2",
                [purpose, email],
            );
            false
        }
    }

    // ── TOTP + recovery codes ────────────────────────────────────────────────

    /// Store a freshly generated secret, pending until the user confirms a
    /// valid code (so a lost QR can't lock anyone out).
    pub(crate) fn totp_set_pending(&self, user_id: &str, secret_b32: &str) -> anyhow::Result<()> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute(
            "INSERT INTO one_totp (user_id, secret, enabled, created_at) VALUES (?1, ?2, 0, ?3)
             ON CONFLICT(user_id) DO UPDATE SET secret = excluded.secret, enabled = 0",
            rusqlite::params![user_id, secret_b32, chrono::Utc::now().to_rfc3339()],
        )?;
        Ok(())
    }

    pub(crate) fn totp_secret(&self, user_id: &str) -> Option<(String, bool)> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.query_row(
            "SELECT secret, enabled FROM one_totp WHERE user_id = ?1",
            [user_id],
            |r| Ok((r.get(0)?, r.get::<_, i64>(1)? != 0)),
        )
        .ok()
    }

    pub(crate) fn totp_enable(&self, user_id: &str) {
        let conn = self.conn.lock().expect("user store poisoned");
        let _ = conn.execute("UPDATE one_totp SET enabled = 1 WHERE user_id = ?1", [user_id]);
    }

    pub(crate) fn totp_enabled(&self, user_id: &str) -> bool {
        self.totp_secret(user_id).map(|(_, on)| on).unwrap_or(false)
    }

    pub(crate) fn totp_remove(&self, user_id: &str) {
        let conn = self.conn.lock().expect("user store poisoned");
        let _ = conn.execute("DELETE FROM one_totp WHERE user_id = ?1", [user_id]);
        let _ = conn.execute("DELETE FROM one_recovery WHERE user_id = ?1", [user_id]);
    }

    pub(crate) fn recovery_store(&self, user_id: &str, digests: &[String]) -> anyhow::Result<()> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute("DELETE FROM one_recovery WHERE user_id = ?1", [user_id])?;
        for d in digests {
            conn.execute(
                "INSERT INTO one_recovery (user_id, digest) VALUES (?1, ?2)",
                [user_id, d],
            )?;
        }
        Ok(())
    }

    // ── admin surface (dashboard) ────────────────────────────────────────────

    pub(crate) fn list_users(&self, limit: u32) -> Vec<UserPublic> {
        let conn = self.conn.lock().expect("user store poisoned");
        let mut stmt = match conn.prepare(
            "SELECT id, email, verified, created_at FROM one_users ORDER BY created_at LIMIT ?1",
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        stmt.query_map([limit], |r| {
            Ok(UserPublic {
                id: r.get(0)?,
                email: r.get(1)?,
                verified: r.get::<_, i64>(2)? != 0,
                created_at: r.get(3)?,
            })
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    /// Remove an account and everything hanging off it (identities, refresh
    /// tokens, TOTP, recovery codes). File rows stay — bytes are data, not
    /// identity — still admin-readable/deletable via the files API.
    pub(crate) fn delete_user(&self, user_id: &str) -> bool {
        let conn = self.conn.lock().expect("user store poisoned");
        let n = conn.execute("DELETE FROM one_users WHERE id = ?1", [user_id]).unwrap_or(0);
        for sql in [
            "DELETE FROM one_user_identities WHERE user_id = ?1",
            "DELETE FROM one_refresh WHERE user_id = ?1",
            "DELETE FROM one_totp WHERE user_id = ?1",
            "DELETE FROM one_recovery WHERE user_id = ?1",
        ] {
            let _ = conn.execute(sql, [user_id]);
        }
        n > 0
    }

    pub(crate) fn files_all(&self, limit: u32) -> Vec<FileMeta> {
        let conn = self.conn.lock().expect("user store poisoned");
        let mut stmt = match conn.prepare(
            "SELECT id, table_name, record_id, field, owner, filename, stored, content_type, size, created_at
             FROM one_files ORDER BY created_at DESC LIMIT ?1",
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        stmt.query_map([limit], FileMeta::from_row)
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    // ── file metadata (binary payloads live under {data_dir}/storage) ───────

    pub(crate) fn file_insert(&self, f: &FileMeta) -> anyhow::Result<()> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute(
            "INSERT INTO one_files (id, table_name, record_id, field, owner, filename, stored, content_type, size, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            rusqlite::params![
                f.id, f.table_name, f.record_id, f.field, f.owner, f.filename, f.stored,
                f.content_type, f.size, f.created_at
            ],
        )?;
        Ok(())
    }

    pub(crate) fn file_get(&self, id: &str) -> Option<FileMeta> {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.query_row(
            "SELECT id, table_name, record_id, field, owner, filename, stored, content_type, size, created_at
             FROM one_files WHERE id = ?1",
            [id],
            FileMeta::from_row,
        )
        .ok()
    }

    pub(crate) fn file_list(&self, table: &str, record: &str) -> Vec<FileMeta> {
        let conn = self.conn.lock().expect("user store poisoned");
        let mut stmt = match conn.prepare(
            "SELECT id, table_name, record_id, field, owner, filename, stored, content_type, size, created_at
             FROM one_files WHERE table_name = ?1 AND record_id = ?2 ORDER BY created_at",
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        stmt.query_map([table, record], FileMeta::from_row)
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    pub(crate) fn file_delete(&self, id: &str) -> bool {
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute("DELETE FROM one_files WHERE id = ?1", [id])
            .map(|n| n > 0)
            .unwrap_or(false)
    }

    /// Single-use: a matching recovery code is deleted as it is accepted.
    pub(crate) fn recovery_consume(&self, user_id: &str, code: &str) -> bool {
        let digest = sha256_hex(code);
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute(
            "DELETE FROM one_recovery WHERE user_id = ?1 AND digest = ?2",
            [user_id, &digest],
        )
        .map(|n| n > 0)
        .unwrap_or(false)
    }

    /// Mint a refresh token: `nrt_<rowid>.<secret>`, digest-stored, 30-day TTL.
    fn mint_refresh(&self, user_id: &str) -> anyhow::Result<String> {
        let row_id = uuid::Uuid::new_v4().simple().to_string()[..12].to_string();
        let secret = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let raw = format!("nrt_{row_id}.{secret}");
        let expires = chrono::Utc::now().timestamp() + REFRESH_TTL_SECS;
        let conn = self.conn.lock().expect("user store poisoned");
        conn.execute(
            "INSERT INTO one_refresh (id, user_id, digest, expires_at) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![row_id, user_id, sha256_hex(&raw), expires],
        )?;
        Ok(raw)
    }

    /// Single-use consume: verify digest + expiry, DELETE the row, return the
    /// user id. A replayed (already-consumed) token finds no row → None.
    fn consume_refresh(&self, raw: &str) -> Option<String> {
        let row_id = raw.strip_prefix("nrt_")?.split_once('.')?.0.to_string();
        let conn = self.conn.lock().expect("user store poisoned");
        let (user_id, digest, expires_at): (String, String, i64) = conn
            .query_row(
                "SELECT user_id, digest, expires_at FROM one_refresh WHERE id = ?1",
                [&row_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .ok()?;
        // Consume unconditionally once looked up (single-use, even on mismatch
        // a guess burns the row it named — fail-closed).
        let _ = conn.execute("DELETE FROM one_refresh WHERE id = ?1", [&row_id]);
        if !ct_eq(&sha256_hex(raw), &digest) || chrono::Utc::now().timestamp() >= expires_at {
            return None;
        }
        Some(user_id)
    }
}

// ─── one state ───────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize)]
struct Claims {
    sub: String,
    email: String,
    exp: usize,
    iat: usize,
    typ: String,
}

pub struct OneState {
    pub(crate) users: UserStore,
    jwt_secret: Vec<u8>,
    jwt_ttl: u64,
    allow_signup: bool,
    /// OAuth2/OIDC flow state (PKCE pending store + provider endpoints).
    pub(crate) oauth: crate::one_oauth::OAuthRuntime,
    /// SMTP sender — None when ONE_SMTP_HOST is unset (email endpoints 503).
    pub(crate) mailer: Option<crate::one_email::Mailer>,
    /// Root of this deployment's data (file storage lives under `storage/`).
    pub(crate) data_dir: std::path::PathBuf,
}

impl OneState {
    pub fn open(data_dir: &std::path::Path) -> anyhow::Result<Self> {
        let users = UserStore::open(&data_dir.join("nano_meta.db"))?;
        // Secret precedence: env > persisted > generate-and-persist. The
        // generated secret survives restarts so issued tokens stay valid.
        let jwt_secret = match std::env::var("ONE_JWT_SECRET").ok().filter(|s| !s.trim().is_empty()) {
            Some(s) => s.into_bytes(),
            None => match users.config_get("jwt_secret") {
                Some(s) => s.into_bytes(),
                None => {
                    let s = format!(
                        "{}{}",
                        uuid::Uuid::new_v4().simple(),
                        uuid::Uuid::new_v4().simple()
                    );
                    users.config_set("jwt_secret", &s)?;
                    tracing::info!("one: generated + persisted a JWT secret (set ONE_JWT_SECRET to override)");
                    s.into_bytes()
                }
            },
        };
        let jwt_ttl = std::env::var("ONE_JWT_TTL_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_JWT_TTL_SECS);
        let allow_signup = !matches!(
            std::env::var("ONE_ALLOW_SIGNUP").unwrap_or_default().to_lowercase().as_str(),
            "0" | "false" | "off"
        );
        Ok(Self {
            users,
            jwt_secret,
            jwt_ttl,
            allow_signup,
            oauth: crate::one_oauth::OAuthRuntime::default(),
            mailer: crate::one_email::Mailer::from_env(),
            data_dir: data_dir.to_path_buf(),
        })
    }

    /// Short-lived (5 min) signed grant for ONE file — PocketBase-style
    /// protected-file access for `<img src>` and download links.
    pub(crate) fn mint_file_token(&self, file_id: &str) -> Result<String, String> {
        self.mint_typed(file_id, "", "file", 300)
    }

    pub(crate) fn verify_file_token(&self, token: &str) -> Option<String> {
        let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::HS256);
        validation.validate_exp = true;
        let data = jsonwebtoken::decode::<Claims>(
            token,
            &jsonwebtoken::DecodingKey::from_secret(&self.jwt_secret),
            &validation,
        )
        .ok()?;
        (data.claims.typ == "file").then_some(data.claims.sub)
    }

    /// Password (or email-OTP) factor passed — either finish with a session
    /// or, when the account has TOTP enabled, hand back a 5-minute MFA
    /// challenge token that `/one/v1/auth/totp/verify` upgrades.
    pub(crate) fn finish_login(
        &self,
        user_id: &str,
    ) -> Result<serde_json::Value, axum::response::Response> {
        if !self.users.totp_enabled(user_id) {
            return self.issue_session(user_id);
        }
        let user = self.users.get_user(user_id).ok_or_else(|| {
            api_err(StatusCode::UNAUTHORIZED, "unauthorized", "account no longer exists")
        })?;
        let token = self
            .mint_typed(&user.id, &user.email, "mfa", 300)
            .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, "jwt_failed", &e))?;
        Ok(json!({ "mfa_required": true, "mfa_token": token, "expires_in": 300 }))
    }

    /// Decode an MFA challenge token → the user id it vouches for.
    pub(crate) fn verify_mfa_token(&self, token: &str) -> Option<String> {
        let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::HS256);
        validation.validate_exp = true;
        let data = jsonwebtoken::decode::<Claims>(
            token,
            &jsonwebtoken::DecodingKey::from_secret(&self.jwt_secret),
            &validation,
        )
        .ok()?;
        (data.claims.typ == "mfa").then_some(data.claims.sub)
    }

    /// Mint the full session bundle (JWT + rotating refresh) for a known user.
    /// Shared by password login and the OAuth callback.
    pub(crate) fn issue_session(
        &self,
        user_id: &str,
    ) -> Result<serde_json::Value, axum::response::Response> {
        let user = self.users.get_user(user_id).ok_or_else(|| {
            api_err(StatusCode::UNAUTHORIZED, "unauthorized", "account no longer exists")
        })?;
        let (token, ttl) = self
            .mint_jwt(&user.id, &user.email)
            .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, "jwt_failed", &e))?;
        let refresh = self.users.mint_refresh(&user.id).map_err(|e| {
            api_err(StatusCode::INTERNAL_SERVER_ERROR, "refresh_failed", &e.to_string())
        })?;
        Ok(session_json(Some(&user), token, ttl, refresh))
    }

    /// Map a provider identity to a local account:
    /// identity match → verified-email link → signup (toggle permitting).
    /// OAuth-created accounts get an unloginable password sentinel — argon2
    /// parsing fails closed on it, so password login can never claim them.
    pub(crate) fn oauth_login(
        &self,
        subject: &str,
        email: Option<&str>,
        email_verified: bool,
    ) -> Result<String, axum::response::Response> {
        let provider = subject.split(':').next().unwrap_or_default().to_string();
        if let Some(uid) = self.users.find_identity(&provider, subject) {
            return Ok(uid);
        }
        if let Some(email) = email {
            if let Some(uid) = self.users.find_user_id_by_email(email) {
                if !email_verified {
                    return Err(api_err(
                        StatusCode::FORBIDDEN,
                        "email_unverified",
                        "the provider did not verify this email; cannot link it to an existing account",
                    ));
                }
                self.users
                    .link_identity(&provider, subject, &uid, Some(email))
                    .map_err(|e| {
                        api_err(StatusCode::INTERNAL_SERVER_ERROR, "link_failed", &e.to_string())
                    })?;
                self.users.mark_verified(&uid);
                tracing::info!(target: "audit", event = "oauth_linked", user = %uid, subject = %subject, "identity linked to existing account");
                return Ok(uid);
            }
        }
        if !self.allow_signup {
            return Err(api_err(
                StatusCode::FORBIDDEN,
                "signup_disabled",
                "signups are disabled (ONE_ALLOW_SIGNUP=0)",
            ));
        }
        // No password: the sentinel is not a PHC string, so verify_password
        // always returns false for it.
        let synth_email = email
            .map(str::to_string)
            .unwrap_or_else(|| format!("{}@users.noreply.binocle.local", subject.replace(':', ".")));
        let uid = self
            .users
            .create_user(&synth_email, "!oauth-only")
            .map_err(|e| api_err(StatusCode::CONFLICT, "signup_failed", &e.to_string()))?;
        if email.is_some() && email_verified {
            self.users.mark_verified(&uid);
        }
        self.users
            .link_identity(&provider, subject, &uid, email)
            .map_err(|e| api_err(StatusCode::INTERNAL_SERVER_ERROR, "link_failed", &e.to_string()))?;
        tracing::info!(target: "audit", event = "oauth_signup", user = %uid, subject = %subject, "account created via oauth");
        Ok(uid)
    }

    fn mint_typed(&self, user_id: &str, email: &str, typ: &str, ttl: u64) -> Result<String, String> {
        let now = chrono::Utc::now().timestamp() as usize;
        let claims = Claims {
            sub: user_id.to_string(),
            email: email.to_string(),
            iat: now,
            exp: now + ttl as usize,
            typ: typ.to_string(),
        };
        jsonwebtoken::encode(
            &jsonwebtoken::Header::new(jsonwebtoken::Algorithm::HS256),
            &claims,
            &jsonwebtoken::EncodingKey::from_secret(&self.jwt_secret),
        )
        .map_err(|e| e.to_string())
    }

    fn mint_jwt(&self, user_id: &str, email: &str) -> Result<(String, u64), String> {
        self.mint_typed(user_id, email, "auth", self.jwt_ttl)
            .map(|t| (t, self.jwt_ttl))
    }

    /// Verify a user JWT → the identity that flows through `/data/v1`:
    /// principal `user:<id>` + `IdentitySource::Jwt` → per-user owner-scoping
    /// and ABAC field masks, on the same door machine keys use.
    pub(crate) fn verify_jwt(
        &self,
        token: &str,
    ) -> Result<VerifiedIdentity, axum::response::Response> {
        let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::HS256);
        validation.validate_exp = true;
        let data = jsonwebtoken::decode::<Claims>(
            token,
            &jsonwebtoken::DecodingKey::from_secret(&self.jwt_secret),
            &validation,
        )
        .map_err(|_| api_err(StatusCode::UNAUTHORIZED, "unauthorized", "invalid or expired token"))?;
        if data.claims.typ != "auth" {
            return Err(api_err(StatusCode::UNAUTHORIZED, "unauthorized", "not an auth token"));
        }
        Ok(VerifiedIdentity {
            tenant_id: "local".to_string(),
            key_id: data.claims.sub.clone(),
            scopes: vec!["read".to_string(), "write".to_string()],
            principal: format!("user:{}", data.claims.sub),
            source: data_plane_core::IdentitySource::Jwt,
        })
    }
}

// ─── handlers ────────────────────────────────────────────────────────────────

pub(crate) fn one_of(state: &AppState) -> Result<Arc<OneState>, axum::response::Response> {
    state.one.clone().ok_or_else(|| {
        api_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "one_unavailable",
            "one runtime not initialised",
        )
    })
}

#[derive(Deserialize)]
struct Credentials {
    email: String,
    password: String,
}

fn validate_credentials(c: &Credentials) -> Result<(), &'static str> {
    let email = c.email.trim();
    if email.len() < 3 || email.len() > 254 || !email.contains('@') {
        return Err("a valid email is required");
    }
    if c.password.len() < 8 {
        return Err("password must be at least 8 characters");
    }
    Ok(())
}

/// Token bundle response (register / login / refresh all share it).
fn session_json(user: Option<&UserPublic>, token: String, ttl: u64, refresh: String) -> serde_json::Value {
    let mut v = json!({
        "token": token,
        "token_type": "Bearer",
        "expires_in": ttl,
        "refresh": refresh,
    });
    if let Some(u) = user {
        v["user"] = serde_json::to_value(u).unwrap_or_default();
    }
    v
}

async fn register(
    State(state): State<AppState>,
    Json(req): Json<Credentials>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    if !one.allow_signup {
        return api_err(StatusCode::FORBIDDEN, "signup_disabled", "signups are disabled (ONE_ALLOW_SIGNUP=0)");
    }
    if let Err(m) = validate_credentials(&req) {
        return api_err(StatusCode::BAD_REQUEST, "invalid_request", m);
    }
    let email = req.email.trim().to_lowercase();
    let password = req.password;
    // argon2id costs tens of ms by design — off the async runtime.
    let hash = match tokio::task::spawn_blocking(move || hash_password(&password)).await {
        Ok(Ok(h)) => h,
        _ => return api_err(StatusCode::INTERNAL_SERVER_ERROR, "hash_failed", "password hashing failed"),
    };
    let user_id = match one.users.create_user(&email, &hash) {
        Ok(id) => id,
        Err(_) => return api_err(StatusCode::CONFLICT, "email_taken", "an account with this email already exists"),
    };
    let (token, ttl) = match one.mint_jwt(&user_id, &email) {
        Ok(t) => t,
        Err(e) => return api_err(StatusCode::INTERNAL_SERVER_ERROR, "jwt_failed", &e),
    };
    let refresh = match one.users.mint_refresh(&user_id) {
        Ok(r) => r,
        Err(e) => return api_err(StatusCode::INTERNAL_SERVER_ERROR, "refresh_failed", &e.to_string()),
    };
    let user = one.users.get_user(&user_id);
    tracing::info!(target: "audit", event = "user_registered", user = %user_id, "one account created");
    (StatusCode::CREATED, Json(session_json(user.as_ref(), token, ttl, refresh))).into_response()
}

async fn login(
    State(state): State<AppState>,
    Json(req): Json<Credentials>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let email = req.email.trim().to_lowercase();
    let password = req.password;
    let Some((user_id, stored)) = one.users.find_by_email(&email) else {
        // Burn comparable time so an unknown email is indistinguishable.
        let _ = tokio::task::spawn_blocking(move || hash_password(&password)).await;
        return api_err(StatusCode::UNAUTHORIZED, "unauthorized", "invalid email or password");
    };
    let ok = matches!(
        tokio::task::spawn_blocking(move || verify_password(&password, &stored)).await,
        Ok(true)
    );
    if !ok {
        return api_err(StatusCode::UNAUTHORIZED, "unauthorized", "invalid email or password");
    }
    // TOTP-enabled accounts get a challenge instead of a session.
    match one.finish_login(&user_id) {
        Ok(body) => (StatusCode::OK, Json(body)).into_response(),
        Err(r) => r,
    }
}

#[derive(Deserialize)]
struct RefreshRequest {
    refresh: String,
}

async fn refresh(
    State(state): State<AppState>,
    Json(req): Json<RefreshRequest>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let Some(user_id) = one.users.consume_refresh(&req.refresh) else {
        return api_err(StatusCode::UNAUTHORIZED, "unauthorized", "invalid, expired or already-used refresh token");
    };
    let Some(user) = one.users.get_user(&user_id) else {
        return api_err(StatusCode::UNAUTHORIZED, "unauthorized", "account no longer exists");
    };
    let (token, ttl) = match one.mint_jwt(&user.id, &user.email) {
        Ok(t) => t,
        Err(e) => return api_err(StatusCode::INTERNAL_SERVER_ERROR, "jwt_failed", &e),
    };
    let new_refresh = match one.users.mint_refresh(&user.id) {
        Ok(r) => r,
        Err(e) => return api_err(StatusCode::INTERNAL_SERVER_ERROR, "refresh_failed", &e.to_string()),
    };
    (StatusCode::OK, Json(session_json(Some(&user), token, ttl, new_refresh))).into_response()
}

async fn logout(
    State(state): State<AppState>,
    Json(req): Json<RefreshRequest>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    // consume == revoke (single-use semantics).
    let _ = one.users.consume_refresh(&req.refresh);
    StatusCode::NO_CONTENT.into_response()
}

async fn me(State(state): State<AppState>, headers: header::HeaderMap) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    let Some(token) = bearer_token(&headers) else {
        return api_err(StatusCode::UNAUTHORIZED, "unauthorized", "Bearer token required");
    };
    let id = match one.verify_jwt(&token) {
        Ok(id) => id,
        Err(r) => return r,
    };
    match one.users.get_user(&id.key_id) {
        Some(user) => Json(json!({ "user": user })).into_response(),
        None => api_err(StatusCode::UNAUTHORIZED, "unauthorized", "account no longer exists"),
    }
}

// ─── runtime ─────────────────────────────────────────────────────────────────

fn auth_routes() -> Router<AppState> {
    Router::new()
        .route("/one/v1/auth/register", post(register))
        .route("/one/v1/auth/login", post(login))
        .route("/one/v1/auth/refresh", post(refresh))
        .route("/one/v1/auth/logout", post(logout))
        .route("/one/v1/auth/me", get(me))
}

/// nano's full route set + accounts + OAuth + email codes + TOTP, one router.
pub fn router(state: AppState) -> Router {
    crate::nano::routes()
        .merge(auth_routes())
        .merge(crate::one_oauth::routes())
        .merge(crate::one_email::routes())
        .merge(crate::one_totp::routes())
        .merge(crate::one_files::routes())
        .merge(crate::one_admin::routes())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// Boot binocle-one: nano state + the account store, same reaper, same door.
pub async fn run(config: ServerConfig) -> anyhow::Result<()> {
    let data_dir = std::path::PathBuf::from(
        std::env::var("NANO_DATA_DIR").unwrap_or_else(|_| "./nano_data".to_string()),
    );
    std::fs::create_dir_all(&data_dir)?;

    let addr = format!("{}:{}", config.host, config.port);
    let mut state = AppState::new(config);
    state.nano = Some(Arc::new(NanoState::open(&data_dir)?));
    state.one = Some(Arc::new(OneState::open(&data_dir)?));

    let reaper_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(15));
        loop {
            interval.tick().await;
            reaper_state.reap_once().await;
        }
    });

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!(address = %addr, data_dir = %data_dir.display(), "binocle-one listening (accounts + data plane, single binary)");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(crate::signal::shutdown_signal())
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_hash_round_trip() {
        let h = hash_password("correct horse battery").unwrap();
        assert!(h.starts_with("$argon2"), "PHC string format: {h}");
        assert!(verify_password("correct horse battery", &h));
        assert!(!verify_password("wrong", &h));
    }

    #[test]
    fn refresh_tokens_are_single_use_and_expiring() {
        let dir = std::env::temp_dir().join(format!("one-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = UserStore::open(&dir.join("meta.db")).unwrap();
        let uid = store.create_user("a@b.c", "$argon2-fake").unwrap();

        let raw = store.mint_refresh(&uid).unwrap();
        assert!(raw.starts_with("nrt_"));
        assert_eq!(store.consume_refresh(&raw).as_deref(), Some(uid.as_str()));
        // Single-use: a second consume of the same token fails.
        assert!(store.consume_refresh(&raw).is_none());
        // A forged token with a valid shape fails (digest mismatch burns the row).
        let raw2 = store.mint_refresh(&uid).unwrap();
        let forged = format!("{}.{}", raw2.split_once('.').unwrap().0, "0".repeat(64));
        assert!(store.consume_refresh(&forged).is_none());
        assert!(store.consume_refresh(&raw2).is_none(), "mismatch burned the row");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn jwt_mint_verify_round_trip() {
        let dir = std::env::temp_dir().join(format!("one-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        std::env::remove_var("ONE_JWT_SECRET");
        let one = OneState::open(&dir).unwrap();
        let (token, ttl) = one.mint_jwt("u123", "a@b.c").unwrap();
        assert_eq!(ttl, DEFAULT_JWT_TTL_SECS);
        let id = one.verify_jwt(&token).expect("fresh token verifies");
        assert_eq!(id.principal, "user:u123");
        assert_eq!(id.tenant_id, "local");
        assert!(matches!(id.source, data_plane_core::IdentitySource::Jwt));
        assert!(one.verify_jwt("garbage").is_err());
        // A token signed with a DIFFERENT secret is rejected.
        let dir2 = std::env::temp_dir().join(format!("one-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir2).unwrap();
        let other = OneState::open(&dir2).unwrap();
        let (foreign, _) = other.mint_jwt("u123", "a@b.c").unwrap();
        assert!(one.verify_jwt(&foreign).is_err(), "cross-secret token rejected");
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&dir2);
    }

    #[test]
    fn oauth_login_links_and_creates() {
        let dir = std::env::temp_dir().join(format!("one-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let one = OneState::open(&dir).unwrap();
        let dave = one.users.create_user("dave@x.y", "$argon2-fake").unwrap();
        // First OAuth login with dave's provider-verified email LINKS, not duplicates.
        assert_eq!(one.oauth_login("oidc:s1", Some("dave@x.y"), true).unwrap(), dave);
        // Later logins match by identity alone (email not needed).
        assert_eq!(one.oauth_login("oidc:s1", None, true).unwrap(), dave);
        // An unverified email must NOT link to an existing account.
        one.users.create_user("eve@x.y", "h").unwrap();
        assert!(one.oauth_login("oidc:s2", Some("eve@x.y"), false).is_err());
        // Unknown identity + unknown email signs up a new account.
        let new = one.oauth_login("oidc:s3", Some("new@x.y"), true).unwrap();
        assert_ne!(new, dave);
        // The OAuth password sentinel can never pass password login.
        assert!(!verify_password("anything", "!oauth-only"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn user_store_email_uniqueness() {
        let dir = std::env::temp_dir().join(format!("one-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = UserStore::open(&dir.join("meta.db")).unwrap();
        store.create_user("dup@x.y", "h1").unwrap();
        assert!(store.create_user("dup@x.y", "h2").is_err(), "unique email enforced");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
