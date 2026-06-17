//! binocle-one OAuth2/OIDC — the full provider matrix on ONE flow.
//!
//! PocketBase ships "30+ OAuth2 providers"; nearly all of them are presets
//! over the same authorization-code grant. We implement that grant ONCE —
//! with PKCE (S256), `state` CSRF protection, and a single-use pending store
//! — and ship a compiled-in preset table (Google, GitHub, GitLab, Discord,
//! Microsoft, Facebook, Twitch, Spotify, LinkedIn, Apple, Notion). The long tail is
//! covered by the `oidc` provider: point `ONE_OAUTH_OIDC_ISSUER` at ANY
//! OpenID Connect issuer and endpoints come from its discovery document.
//!
//! A provider is enabled by setting `ONE_OAUTH_<PROVIDER>_CLIENT_ID` (+
//! `_CLIENT_SECRET`). The callback URL to register with the provider is
//! `{ONE_PUBLIC_URL}/one/v1/auth/oauth/<provider>/callback`.
//!
//! Identity model: `(provider, subject)` rows in `one_user_identities` map to
//! local accounts. A first-time OAuth login links to an existing account by
//! **provider-verified email**, otherwise creates one (signup toggle applies).
//! OAuth-created accounts carry an unloginable password sentinel — argon2
//! verification fails closed on it, so password login can never hijack them.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Redirect};
use axum::routing::get;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::routes::{api_err, AppState};

/// An in-flight authorization is abandoned after 10 minutes.
const PENDING_TTL: Duration = Duration::from_secs(600);
/// Hard cap on concurrent in-flight authorizations (memory bound).
const PENDING_MAX: usize = 4096;

// ─── provider presets ────────────────────────────────────────────────────────

pub(crate) struct Preset {
    pub name: &'static str,
    pub auth_url: &'static str,
    pub token_url: &'static str,
    pub userinfo_url: &'static str,
    pub scopes: &'static str,
    /// Extra query params some providers require on the authorize URL
    /// (already URL-encoded, leading `&`).
    pub extra_auth: &'static str,
}

/// Presets prefer each provider's OIDC surface (stable `sub` + `email` +
/// `email_verified` claims); pure-OAuth2 providers fall back to their user
/// API and the generic `id`/`email` extraction below.
pub(crate) const PRESETS: &[Preset] = &[
    Preset {
        name: "google",
        auth_url: "https://accounts.google.com/o/oauth2/v2/auth",
        token_url: "https://oauth2.googleapis.com/token",
        userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
        scopes: "openid email",
        extra_auth: "",
    },
    Preset {
        name: "github",
        auth_url: "https://github.com/login/oauth/authorize",
        token_url: "https://github.com/login/oauth/access_token",
        userinfo_url: "https://api.github.com/user",
        scopes: "read:user user:email",
        extra_auth: "",
    },
    Preset {
        name: "gitlab",
        auth_url: "https://gitlab.com/oauth/authorize",
        token_url: "https://gitlab.com/oauth/token",
        userinfo_url: "https://gitlab.com/oauth/userinfo",
        scopes: "openid email",
        extra_auth: "",
    },
    Preset {
        name: "discord",
        auth_url: "https://discord.com/oauth2/authorize",
        token_url: "https://discord.com/api/oauth2/token",
        userinfo_url: "https://discord.com/api/users/@me",
        scopes: "identify email",
        extra_auth: "",
    },
    Preset {
        name: "microsoft",
        auth_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
        token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        userinfo_url: "https://graph.microsoft.com/oidc/userinfo",
        scopes: "openid email",
        extra_auth: "",
    },
    Preset {
        name: "facebook",
        auth_url: "https://www.facebook.com/v19.0/dialog/oauth",
        token_url: "https://graph.facebook.com/v19.0/oauth/access_token",
        userinfo_url: "https://graph.facebook.com/me?fields=id,email",
        scopes: "email",
        extra_auth: "",
    },
    Preset {
        name: "twitch",
        auth_url: "https://id.twitch.tv/oauth2/authorize",
        token_url: "https://id.twitch.tv/oauth2/token",
        userinfo_url: "https://id.twitch.tv/oauth2/userinfo",
        scopes: "openid user:read:email",
        // Twitch's OIDC userinfo only returns email when explicitly claimed.
        extra_auth: "&claims=%7B%22userinfo%22%3A%7B%22email%22%3Anull%2C%22email_verified%22%3Anull%7D%7D",
    },
    Preset {
        name: "spotify",
        auth_url: "https://accounts.spotify.com/authorize",
        token_url: "https://accounts.spotify.com/api/token",
        userinfo_url: "https://api.spotify.com/v1/me",
        scopes: "user-read-email",
        extra_auth: "",
    },
    Preset {
        name: "linkedin",
        auth_url: "https://www.linkedin.com/oauth/v2/authorization",
        token_url: "https://www.linkedin.com/oauth/v2/accessToken",
        userinfo_url: "https://api.linkedin.com/v2/userinfo",
        scopes: "openid email",
        extra_auth: "",
    },
    Preset {
        name: "apple",
        auth_url: "https://appleid.apple.com/auth/authorize",
        token_url: "https://appleid.apple.com/auth/token",
        userinfo_url: "",
        scopes: "name email",
        // Apple mandates form_post whenever scopes are requested — the
        // callback route also accepts POST for this.
        extra_auth: "&response_mode=form_post",
    },
    Preset {
        name: "notion",
        auth_url: "https://api.notion.com/v1/oauth/authorize",
        token_url: "https://api.notion.com/v1/oauth/token",
        userinfo_url: "",
        scopes: "",
        // Notion returns the user inside the token response (`owner.user`),
        // has no scopes, and requires `owner=user` on the authorize URL.
        extra_auth: "&owner=user",
    },
];

fn provider_env(provider: &str, suffix: &str) -> Option<String> {
    std::env::var(format!(
        "ONE_OAUTH_{}_{suffix}",
        provider.to_uppercase().replace('-', "_")
    ))
    .ok()
    .filter(|v| !v.trim().is_empty())
}

/// A provider is enabled iff its client id is configured. Custom `oidc`
/// additionally needs the issuer URL; `apple` needs the ES256 signing
/// material for its self-minted client secret.
fn provider_enabled(provider: &str) -> bool {
    if provider_env(provider, "CLIENT_ID").is_none() {
        return false;
    }
    match provider {
        "oidc" => provider_env("oidc", "ISSUER").is_some(),
        "apple" => {
            provider_env("apple", "TEAM_ID").is_some()
                && provider_env("apple", "KEY_ID").is_some()
                && provider_env("apple", "PRIVATE_KEY").is_some()
        }
        _ => true,
    }
}

/// Apple has no static client secret: it is an ES256 JWT signed with the
/// developer's .p8 key, minted fresh per token exchange (5-minute TTL).
fn apple_client_secret() -> Result<String, String> {
    let team_id = provider_env("apple", "TEAM_ID").ok_or("ONE_OAUTH_APPLE_TEAM_ID not set")?;
    let key_id = provider_env("apple", "KEY_ID").ok_or("ONE_OAUTH_APPLE_KEY_ID not set")?;
    let pem = provider_env("apple", "PRIVATE_KEY").ok_or("ONE_OAUTH_APPLE_PRIVATE_KEY not set")?;
    let client_id = provider_env("apple", "CLIENT_ID").ok_or("ONE_OAUTH_APPLE_CLIENT_ID not set")?;
    let now = chrono::Utc::now().timestamp();
    let claims = serde_json::json!({
        "iss": team_id,
        "iat": now,
        "exp": now + 300,
        "aud": "https://appleid.apple.com",
        "sub": client_id,
    });
    let mut header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::ES256);
    header.kid = Some(key_id);
    let key = jsonwebtoken::EncodingKey::from_ec_pem(pem.replace("\\n", "\n").as_bytes())
        .map_err(|e| format!("apple private key unreadable: {e}"))?;
    jsonwebtoken::encode(&header, &claims, &key).map_err(|e| format!("apple secret mint failed: {e}"))
}

// ─── tiny codecs (no new deps) ───────────────────────────────────────────────

/// base64url without padding (RFC 4648 §5) — for the PKCE challenge.
fn b64url(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[n as usize & 63] as char);
        }
    }
    out
}

/// Minimal percent-encoding for query-string values (everything but
/// RFC 3986 unreserved).
fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => {
                use std::fmt::Write;
                let _ = write!(out, "%{b:02X}");
            }
        }
    }
    out
}

/// 64 hex chars of OS-CSPRNG entropy (uuid v4 is getrandom-backed).
fn random_token() -> String {
    format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
}

fn pkce_challenge(verifier: &str) -> String {
    b64url(&Sha256::digest(verifier.as_bytes()))
}

// ─── runtime state ───────────────────────────────────────────────────────────

#[derive(Clone)]
struct Endpoints {
    auth_url: String,
    token_url: String,
    userinfo_url: String,
}

struct Pending {
    provider: String,
    verifier: String,
    redirect: Option<String>,
    created: Instant,
}

/// Lives inside `OneState`; one per process.
pub struct OAuthRuntime {
    http: reqwest::Client,
    pending: Mutex<HashMap<String, Pending>>,
    /// Discovered endpoints for the custom `oidc` provider (fetched once,
    /// lazily — a duplicate fetch on a cold-start race is harmless).
    oidc: Mutex<Option<Endpoints>>,
}

impl Default for OAuthRuntime {
    fn default() -> Self {
        Self {
            // GitHub's API rejects requests without a User-Agent.
            http: reqwest::Client::builder()
                .user_agent("binocle-one")
                .timeout(Duration::from_secs(15))
                .build()
                .expect("reqwest client"),
            pending: Mutex::new(HashMap::new()),
            oidc: Mutex::new(None),
        }
    }
}

impl OAuthRuntime {
    fn stash(&self, state: String, p: Pending) -> Result<(), &'static str> {
        let mut pending = self.pending.lock().expect("oauth pending poisoned");
        pending.retain(|_, v| v.created.elapsed() < PENDING_TTL);
        if pending.len() >= PENDING_MAX {
            return Err("too many in-flight authorizations");
        }
        pending.insert(state, p);
        Ok(())
    }

    /// Single-use: a state is removed on first lookup, replay finds nothing.
    fn take(&self, state: &str) -> Option<Pending> {
        let mut pending = self.pending.lock().expect("oauth pending poisoned");
        let p = pending.remove(state)?;
        (p.created.elapsed() < PENDING_TTL).then_some(p)
    }

    async fn endpoints_for(&self, provider: &str) -> Result<(Endpoints, String, String), String> {
        if let Some(p) = PRESETS.iter().find(|p| p.name == provider) {
            return Ok((
                Endpoints {
                    auth_url: p.auth_url.to_string(),
                    token_url: p.token_url.to_string(),
                    userinfo_url: p.userinfo_url.to_string(),
                },
                p.scopes.to_string(),
                p.extra_auth.to_string(),
            ));
        }
        if provider == "oidc" {
            if let Some(e) = self.oidc.lock().expect("oidc cache poisoned").clone() {
                return Ok((e, "openid email".to_string(), String::new()));
            }
            let issuer = provider_env("oidc", "ISSUER").ok_or("ONE_OAUTH_OIDC_ISSUER not set")?;
            let url = format!("{}/.well-known/openid-configuration", issuer.trim_end_matches('/'));
            let doc: Value = self
                .http
                .get(&url)
                .send()
                .await
                .map_err(|e| format!("discovery fetch failed: {e}"))?
                .json()
                .await
                .map_err(|e| format!("discovery parse failed: {e}"))?;
            let need = |k: &str| -> Result<String, String> {
                doc.get(k)
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .ok_or_else(|| format!("discovery document missing {k}"))
            };
            let e = Endpoints {
                auth_url: need("authorization_endpoint")?,
                token_url: need("token_endpoint")?,
                userinfo_url: need("userinfo_endpoint")?,
            };
            *self.oidc.lock().expect("oidc cache poisoned") = Some(e.clone());
            return Ok((e, "openid email".to_string(), String::new()));
        }
        Err(format!("unknown provider '{provider}'"))
    }
}

fn public_url() -> String {
    std::env::var("ONE_PUBLIC_URL")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "http://127.0.0.1:8090".to_string())
        .trim_end_matches('/')
        .to_string()
}

fn callback_url(provider: &str) -> String {
    format!("{}/one/v1/auth/oauth/{provider}/callback", public_url())
}

// ─── userinfo extraction ─────────────────────────────────────────────────────

struct RemoteUser {
    subject: String,
    email: Option<String>,
    email_verified: bool,
}

/// Generic claim extraction: `sub` (OIDC) or `id` (OAuth2 user APIs; numbers
/// stringified), `email`, and `email_verified`/`verified` — absent verified
/// claims default to true because the big pure-OAuth2 providers (Spotify,
/// LinkedIn pre-OIDC) only return deliverable addresses.
fn extract_user(provider: &str, info: &Value) -> Result<RemoteUser, String> {
    let subject = info
        .get("sub")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| info.get("id").and_then(Value::as_str).map(str::to_string))
        .or_else(|| info.get("id").and_then(Value::as_i64).map(|n| n.to_string()))
        .ok_or("userinfo has no sub/id")?;
    let email = info
        .get("email")
        .and_then(Value::as_str)
        .filter(|e| e.contains('@'))
        .map(|e| e.trim().to_lowercase());
    let email_verified = info
        .get("email_verified")
        .or_else(|| info.get("verified"))
        .and_then(Value::as_bool)
        .unwrap_or(true);
    Ok(RemoteUser {
        subject: format!("{provider}:{subject}"),
        email,
        email_verified,
    })
}

// ─── handlers ────────────────────────────────────────────────────────────────

fn one_of(state: &AppState) -> Result<std::sync::Arc<crate::one::OneState>, axum::response::Response> {
    state.one.clone().ok_or_else(|| {
        api_err(
            StatusCode::SERVICE_UNAVAILABLE,
            "one_unavailable",
            "one runtime not initialised",
        )
    })
}

/// GET /one/v1/auth/oauth/providers — which providers this deployment enables.
async fn providers(State(state): State<AppState>) -> axum::response::Response {
    if let Err(r) = one_of(&state) {
        return r;
    }
    let enabled: Vec<&str> = PRESETS
        .iter()
        .map(|p| p.name)
        .chain(std::iter::once("oidc"))
        .filter(|name| provider_enabled(name))
        .collect();
    Json(json!({ "providers": enabled })).into_response()
}

#[derive(Deserialize)]
struct StartQuery {
    /// `json=1` returns `{auth_url, state}` for SPAs instead of a 302.
    json: Option<String>,
    /// Where to send the browser after the callback (tokens in the fragment).
    redirect: Option<String>,
}

async fn start(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    Query(q): Query<StartQuery>,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    if !provider_enabled(&provider) {
        return api_err(
            StatusCode::NOT_FOUND,
            "provider_not_configured",
            "this OAuth provider is not enabled (set ONE_OAUTH_<PROVIDER>_CLIENT_ID)",
        );
    }
    let client_id = provider_env(&provider, "CLIENT_ID").unwrap_or_default();
    let (endpoints, scopes, extra) = match one.oauth.endpoints_for(&provider).await {
        Ok(v) => v,
        Err(e) => return api_err(StatusCode::BAD_GATEWAY, "provider_discovery_failed", &e),
    };
    // Only same-deployment redirect targets: an open redirect after auth is a
    // token-exfiltration primitive.
    if let Some(r) = &q.redirect {
        if !r.starts_with('/') && !r.starts_with(&public_url()) {
            return api_err(
                StatusCode::BAD_REQUEST,
                "invalid_redirect",
                "redirect must be a relative path or under ONE_PUBLIC_URL",
            );
        }
    }
    let csrf_state = random_token();
    let verifier = random_token();
    let challenge = pkce_challenge(&verifier);
    if let Err(m) = one.oauth.stash(
        csrf_state.clone(),
        Pending {
            provider: provider.clone(),
            verifier,
            redirect: q.redirect.clone(),
            created: Instant::now(),
        },
    ) {
        return api_err(StatusCode::TOO_MANY_REQUESTS, "oauth_backpressure", m);
    }
    let sep = if endpoints.auth_url.contains('?') { '&' } else { '?' };
    let auth_url = format!(
        "{}{sep}response_type=code&client_id={}&redirect_uri={}&scope={}&state={}&code_challenge={}&code_challenge_method=S256{extra}",
        endpoints.auth_url,
        urlencode(&client_id),
        urlencode(&callback_url(&provider)),
        urlencode(&scopes),
        csrf_state,
        challenge,
    );
    if q.json.as_deref() == Some("1") {
        return Json(json!({ "provider": provider, "auth_url": auth_url, "state": csrf_state }))
            .into_response();
    }
    Redirect::temporary(&auth_url).into_response()
}

#[derive(Deserialize)]
struct CallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

async fn callback(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    Query(q): Query<CallbackQuery>,
) -> axum::response::Response {
    callback_inner(state, provider, q).await
}

/// Apple's `response_mode=form_post` delivers the callback as a POST with an
/// urlencoded body — identical handling.
async fn callback_post(
    State(state): State<AppState>,
    Path(provider): Path<String>,
    axum::extract::Form(q): axum::extract::Form<CallbackQuery>,
) -> axum::response::Response {
    callback_inner(state, provider, q).await
}

async fn callback_inner(
    state: AppState,
    provider: String,
    q: CallbackQuery,
) -> axum::response::Response {
    let one = match one_of(&state) {
        Ok(o) => o,
        Err(r) => return r,
    };
    if let Some(e) = q.error {
        let detail = q.error_description.unwrap_or_else(|| e.clone());
        return api_err(StatusCode::UNAUTHORIZED, "provider_denied", &detail);
    }
    let (Some(code), Some(csrf_state)) = (q.code, q.state) else {
        return api_err(StatusCode::BAD_REQUEST, "invalid_request", "code and state are required");
    };
    let Some(pending) = one.oauth.take(&csrf_state) else {
        return api_err(
            StatusCode::UNAUTHORIZED,
            "invalid_state",
            "unknown, expired or already-used state",
        );
    };
    if pending.provider != provider {
        return api_err(StatusCode::UNAUTHORIZED, "invalid_state", "state/provider mismatch");
    }
    let (endpoints, _, _) = match one.oauth.endpoints_for(&provider).await {
        Ok(v) => v,
        Err(e) => return api_err(StatusCode::BAD_GATEWAY, "provider_discovery_failed", &e),
    };
    let client_id = provider_env(&provider, "CLIENT_ID").unwrap_or_default();
    let client_secret = provider_env(&provider, "CLIENT_SECRET").unwrap_or_default();

    let token_body = match exchange_code(
        &one.oauth,
        &provider,
        &endpoints,
        &client_id,
        &client_secret,
        &code,
        &pending.verifier,
    )
    .await
    {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(provider = %provider, error = %e, "oauth token exchange failed");
            return api_err(StatusCode::BAD_GATEWAY, "token_exchange_failed", "provider token exchange failed");
        }
    };
    let remote = match resolve_remote_user(&one.oauth, &provider, &endpoints, &token_body).await {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!(provider = %provider, error = %e, "oauth userinfo failed");
            return api_err(StatusCode::BAD_GATEWAY, "userinfo_failed", "provider userinfo failed");
        }
    };

    // 3. Map to a local account: identity match > verified-email link > signup.
    let user_id = match one.oauth_login(&remote.subject, remote.email.as_deref(), remote.email_verified) {
        Ok(id) => id,
        Err(resp) => return resp,
    };
    let session = match one.issue_session(&user_id) {
        Ok(s) => s,
        Err(r) => return r,
    };
    tracing::info!(target: "audit", event = "oauth_login", provider = %provider, user = %user_id, "oauth session issued");

    if let Some(redirect) = pending.redirect {
        let token = session.get("token").and_then(Value::as_str).unwrap_or_default();
        let refresh = session.get("refresh").and_then(Value::as_str).unwrap_or_default();
        return Redirect::temporary(&format!("{redirect}#token={token}&refresh={refresh}"))
            .into_response();
    }
    Json(session).into_response()
}

/// Exchange the authorization code (+ PKCE verifier) for an access token.
/// Notion wants Basic auth + a JSON body; everyone else takes the standard
/// urlencoded form.
async fn exchange_code(
    rt: &OAuthRuntime,
    provider: &str,
    endpoints: &Endpoints,
    client_id: &str,
    client_secret: &str,
    code: &str,
    verifier: &str,
) -> Result<Value, String> {
    let redirect_uri = callback_url(provider);
    // Apple substitutes its self-minted ES256 JWT for the client secret.
    let minted_secret;
    let client_secret = if provider == "apple" {
        minted_secret = apple_client_secret()?;
        minted_secret.as_str()
    } else {
        client_secret
    };
    let resp = if provider == "notion" {
        rt.http
            .post(&endpoints.token_url)
            .basic_auth(client_id, Some(client_secret))
            .json(&json!({
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect_uri,
            }))
            .send()
            .await
    } else {
        rt.http
            .post(&endpoints.token_url)
            .header("Accept", "application/json")
            .form(&[
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirect_uri.as_str()),
                ("client_id", client_id),
                ("client_secret", client_secret),
                ("code_verifier", verifier),
            ])
            .send()
            .await
    };
    let body: Value = resp
        .map_err(|e| format!("token request failed: {e}"))?
        .json()
        .await
        .map_err(|e| format!("token response parse failed: {e}"))?;
    if body.get("access_token").and_then(Value::as_str).is_none() {
        return Err("provider returned no access_token".to_string());
    }
    Ok(body)
}

/// Resolve the remote user behind an access token. Notion embeds it in the
/// token response (`owner.user`); everyone else exposes a userinfo/user API.
async fn resolve_remote_user(
    rt: &OAuthRuntime,
    provider: &str,
    endpoints: &Endpoints,
    token_body: &Value,
) -> Result<RemoteUser, String> {
    if provider == "apple" {
        // Apple has no userinfo endpoint; the claims live in the id_token.
        // The token came straight from Apple over TLS in the code exchange,
        // so the channel — not the signature — is the trust anchor here
        // (OIDC Core §3.1.3.7 sanctions this for the code flow).
        let id_token = token_body
            .get("id_token")
            .and_then(Value::as_str)
            .ok_or("apple token response missing id_token")?;
        let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::RS256);
        validation.insecure_disable_signature_validation();
        validation.validate_aud = false;
        let data = jsonwebtoken::decode::<Value>(
            id_token,
            &jsonwebtoken::DecodingKey::from_secret(&[]),
            &validation,
        )
        .map_err(|e| format!("apple id_token decode failed: {e}"))?;
        let claims = data.claims;
        let sub = claims
            .get("sub")
            .and_then(Value::as_str)
            .ok_or("apple id_token has no sub")?;
        // Apple serialises email_verified as bool OR the string "true".
        let verified = match claims.get("email_verified") {
            Some(Value::Bool(b)) => *b,
            Some(Value::String(s)) => s == "true",
            _ => true,
        };
        return Ok(RemoteUser {
            subject: format!("apple:{sub}"),
            email: claims
                .get("email")
                .and_then(Value::as_str)
                .filter(|e| e.contains('@'))
                .map(|e| e.trim().to_lowercase()),
            email_verified: verified,
        });
    }
    if provider == "notion" {
        let u = token_body
            .get("owner")
            .and_then(|o| o.get("user"))
            .ok_or("notion token response missing owner.user")?;
        let id = u
            .get("id")
            .and_then(Value::as_str)
            .ok_or("notion user has no id")?;
        return Ok(RemoteUser {
            subject: format!("notion:{id}"),
            email: u
                .get("person")
                .and_then(|p| p.get("email"))
                .and_then(Value::as_str)
                .map(|e| e.trim().to_lowercase()),
            email_verified: true,
        });
    }
    let access_token = token_body
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or("no access_token")?;
    let mut info: Value = rt
        .http
        .get(&endpoints.userinfo_url)
        .bearer_auth(access_token)
        .send()
        .await
        .map_err(|e| format!("userinfo request failed: {e}"))?
        .json()
        .await
        .map_err(|e| format!("userinfo parse failed: {e}"))?;
    // GitHub hides private emails on /user; the emails endpoint returns the
    // verified primary. Best-effort — extract_user copes with a null email.
    if provider == "github" && info.get("email").and_then(Value::as_str).is_none() {
        if let Ok(resp) = rt
            .http
            .get("https://api.github.com/user/emails")
            .bearer_auth(access_token)
            .send()
            .await
        {
            if let Ok(list) = resp.json::<Value>().await {
                let primary = list.as_array().and_then(|a| {
                    a.iter().find(|e| {
                        e.get("primary").and_then(Value::as_bool).unwrap_or(false)
                            && e.get("verified").and_then(Value::as_bool).unwrap_or(false)
                    })
                });
                if let Some(email) = primary.and_then(|e| e.get("email")).cloned() {
                    info["email"] = email;
                    info["email_verified"] = Value::Bool(true);
                }
            }
        }
    }
    extract_user(provider, &info)
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/one/v1/auth/oauth/providers", get(providers))
        .route("/one/v1/auth/oauth/:provider/start", get(start))
        .route(
            "/one/v1/auth/oauth/:provider/callback",
            get(callback).post(callback_post),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_challenge_matches_rfc7636_vector() {
        // RFC 7636 appendix B.
        assert_eq!(
            pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn b64url_is_unpadded_and_urlsafe() {
        assert_eq!(b64url(b""), "");
        assert_eq!(b64url(b"f"), "Zg");
        assert_eq!(b64url(b"fo"), "Zm8");
        assert_eq!(b64url(b"foo"), "Zm9v");
        assert_eq!(b64url(&[0xfb, 0xff]), "-_8");
    }

    #[test]
    fn urlencode_keeps_unreserved_only() {
        assert_eq!(urlencode("AZaz09-._~"), "AZaz09-._~");
        assert_eq!(urlencode("a b/c?d=e&f"), "a%20b%2Fc%3Fd%3De%26f");
        assert_eq!(urlencode("openid email"), "openid%20email");
    }

    #[test]
    fn pending_store_is_single_use() {
        let rt = OAuthRuntime::default();
        rt.stash(
            "state1".into(),
            Pending {
                provider: "oidc".into(),
                verifier: "v".into(),
                redirect: None,
                created: Instant::now(),
            },
        )
        .unwrap();
        assert!(rt.take("state1").is_some());
        assert!(rt.take("state1").is_none(), "second take must fail");
        assert!(rt.take("never-stashed").is_none());
    }

    #[test]
    fn pending_store_expires() {
        let rt = OAuthRuntime::default();
        rt.stash(
            "old".into(),
            Pending {
                provider: "oidc".into(),
                verifier: "v".into(),
                redirect: None,
                created: Instant::now() - PENDING_TTL - Duration::from_secs(1),
            },
        )
        .unwrap();
        assert!(rt.take("old").is_none(), "expired state must be rejected");
    }

    #[test]
    fn presets_are_well_formed() {
        let mut names = std::collections::HashSet::new();
        for p in PRESETS {
            assert!(names.insert(p.name), "duplicate preset {}", p.name);
            assert!(p.auth_url.starts_with("https://"), "{}", p.name);
            assert!(p.token_url.starts_with("https://"), "{}", p.name);
        }
        assert_eq!(PRESETS.len(), 11);
    }

    #[test]
    fn apple_needs_full_signing_material() {
        // CLIENT_ID alone must not enable apple (the ES256 secret needs
        // TEAM_ID + KEY_ID + PRIVATE_KEY too). Env is process-global, so this
        // only asserts the unset case.
        assert!(!provider_enabled("apple"));
        assert!(apple_client_secret().is_err());
    }

    #[test]
    fn extract_user_handles_oidc_and_oauth_shapes() {
        // OIDC shape.
        let u = extract_user(
            "google",
            &json!({"sub": "g123", "email": "A@B.c", "email_verified": true}),
        )
        .unwrap();
        assert_eq!(u.subject, "google:g123");
        assert_eq!(u.email.as_deref(), Some("a@b.c"));
        assert!(u.email_verified);
        // OAuth2 user-API shape (numeric id, `verified` flag).
        let u = extract_user("discord", &json!({"id": 42, "email": "x@y.z", "verified": false})).unwrap();
        assert_eq!(u.subject, "discord:42");
        assert!(!u.email_verified);
        // Missing identifiers are an error; missing verified defaults true.
        assert!(extract_user("p", &json!({"email": "x@y.z"})).is_err());
        assert!(extract_user("p", &json!({"sub": "s"})).unwrap().email_verified);
    }
}
