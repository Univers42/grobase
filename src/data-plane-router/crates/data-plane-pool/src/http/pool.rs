/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   pool.rs                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:28:22 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The per-mount HTTP pool: owns a SSRF-pinned `reqwest::Client`, maps CRUD
//! operations onto HTTP verbs + paths, and dispatches the request upstream.

use super::convert::shape_response;
use super::query::{
    append_query, encode, join_url, route_or_default, scalar_id_from_filter,
    scalar_id_from_filter_or_data,
};
use super::validate::{validate_resource, HttpConnection};
use super::SUPPORTED_OPS;
use async_trait::async_trait;
use data_plane_core::{
    DataOperation, DataOperationKind, DataPlaneError, DataPlaneResult, DataResult, EnginePool,
    EngineProbe, RequestIdentity, TlsPosture, TxBeginRequest, TxHandle,
};
use reqwest::{header, Client, Method, StatusCode, Url};
use serde_json::Value;

pub struct HttpPool {
    pub(super) mount_id: String,
    pub(super) tenant_id: String,
    /// True for a SHARE_POOLS shared_rls pool: the single-owner guard is skipped
    /// (the per-request `x-owner-id` header carries isolation to the upstream).
    /// See `crate::pools_shared`.
    pub(super) shared_pool: bool,
    pub(super) client: Client,
    pub(super) conn: HttpConnection,
}

#[async_trait]
impl EnginePool for HttpPool {
    fn mount_id(&self) -> &str {
        &self.mount_id
    }

    async fn execute(
        &self,
        operation: DataOperation,
        identity: RequestIdentity,
    ) -> DataPlaneResult<DataResult> {
        // SHARE_POOLS shared_rls pool: multi-tenant by design, no single owner to
        // assert; the per-request `x-owner-id` header carries isolation upstream.
        if !self.shared_pool && identity.tenant_id != self.tenant_id {
            return Err(DataPlaneError::Backend {
                message: "identity tenant does not match pool tenant".into(),
            });
        }
        validate_resource(&operation.resource)?;
        if !SUPPORTED_OPS.contains(&operation.op) {
            return Err(DataPlaneError::NotImplemented {
                feature: format!("http operation {:?}", operation.op),
            });
        }

        let (method, path, body) = match operation.op {
            DataOperationKind::List => {
                let path =
                    route_or_default(&self.conn, "list", || format!("/{}", operation.resource));
                let path = append_query(&path, &operation);
                (Method::GET, path, None)
            }
            DataOperationKind::Get => {
                let id = scalar_id_from_filter(&operation)?;
                let path = route_or_default(&self.conn, "get", || {
                    format!("/{}/{}", operation.resource, encode(&id))
                });
                (Method::GET, path, None)
            }
            DataOperationKind::Insert => {
                let path =
                    route_or_default(&self.conn, "insert", || format!("/{}", operation.resource));
                (Method::POST, path, operation.data.clone())
            }
            DataOperationKind::Update => {
                let id = scalar_id_from_filter(&operation)?;
                let path = route_or_default(&self.conn, "update", || {
                    format!("/{}/{}", operation.resource, encode(&id))
                });
                (Method::PATCH, path, operation.data.clone())
            }
            DataOperationKind::Delete => {
                let id = scalar_id_from_filter(&operation)?;
                let path = route_or_default(&self.conn, "delete", || {
                    format!("/{}/{}", operation.resource, encode(&id))
                });
                (Method::DELETE, path, None)
            }
            DataOperationKind::Upsert => {
                let id = scalar_id_from_filter_or_data(&operation)?;
                let path = route_or_default(&self.conn, "upsert", || {
                    format!("/{}/{}", operation.resource, encode(&id))
                });
                (Method::PUT, path, operation.data.clone())
            }
            DataOperationKind::Batch | DataOperationKind::Aggregate => {
                return Err(DataPlaneError::NotImplemented {
                    feature: "http batch/aggregate operation (not implemented)".to_string(),
                });
            }
        };

        let url = join_url(&self.conn.base_url, &path)?;
        self.dispatch(method, &url, body.as_ref(), &identity, &operation)
            .await
    }

    async fn begin(&self, _request: TxBeginRequest) -> DataPlaneResult<Box<dyn TxHandle>> {
        Err(DataPlaneError::NotImplemented {
            feature: "http transactions are upstream-defined and not exposed by this adapter"
                .to_string(),
        })
    }

    async fn close(&self) -> DataPlaneResult<()> {
        Ok(())
    }

    /// Read-only probe: no request is sent (devil G4 P5) — the posture follows the base URL.
    async fn probe(&self) -> DataPlaneResult<EngineProbe> {
        Ok(EngineProbe {
            server_version: "unknown".into(),
            tls: url_posture(&self.conn.base_url),
            tls_version: None,
        })
    }
}

impl HttpPool {
    async fn dispatch(
        &self,
        method: Method,
        url: &str,
        body: Option<&Value>,
        identity: &RequestIdentity,
        operation: &DataOperation,
    ) -> DataPlaneResult<DataResult> {
        let mut req = self
            .client
            .request(method.clone(), url)
            .header(header::ACCEPT, "application/json");

        if let Some(extra) = &self.conn.headers {
            for (k, v) in extra {
                req = req.header(k.as_str(), v.as_str());
            }
        }
        let owner = identity
            .user_id
            .clone()
            .unwrap_or_else(|| identity.tenant_id.clone());
        req = req.header("x-owner-id", owner);
        if let Some(idem) = &operation.idempotency_key {
            req = req.header("idempotency-key", idem.as_str());
        }
        if let Some(b) = body {
            req = req
                .header(header::CONTENT_TYPE, "application/json")
                .body(serde_json::to_vec(b).unwrap_or_default());
        }

        let resp = req.send().await.map_err(|e| DataPlaneError::Backend {
            message: format!(
                "http upstream {method} {}: {}",
                quotable(url),
                e.without_url()
            ),
        })?;

        let status = resp.status();
        // A missing id is an empty read on every other engine; a REST upstream says 404.
        if status == StatusCode::NO_CONTENT
            || (status == StatusCode::NOT_FOUND && operation.op == DataOperationKind::Get)
        {
            return Ok(DataResult::new(vec![], 0));
        }
        // A 3xx is here only when the redirect policy refused it (`redirect.rs`);
        // its body is not the resource and must not be read as data.
        if !status.is_success() {
            return Err(DataPlaneError::Backend {
                message: format!("http upstream {method} {} returned {status}", quotable(url)),
            });
        }

        let text = resp.text().await.unwrap_or_default();
        if text.is_empty() {
            return Ok(DataResult::new(vec![], 0));
        }
        let parsed: Value = serde_json::from_str(&text).unwrap_or(Value::String(text));
        Ok(shape_response(parsed))
    }
}

/// The URL as an error message may quote it: that message is logged on every
/// failed request, so a base URL's `user:password@` is dropped (m230).
fn quotable(url: &str) -> String {
    match Url::parse(url) {
        Ok(mut parsed) => {
            let _ = parsed.set_username("");
            let _ = parsed.set_password(None);
            parsed.to_string()
        }
        Err(_) => "<unparsable url>".to_string(),
    }
}

/// The TLS posture implied by the base URL scheme: `https://` counts as verified
/// (reqwest uses rustls with webpki roots and nothing in this crate disables
/// verification), `http://` as plaintext, anything else as unknown.
fn url_posture(base_url: &str) -> TlsPosture {
    let lower = base_url.to_ascii_lowercase();
    if lower.starts_with("https://") {
        TlsPosture::Verified
    } else if lower.starts_with("http://") {
        TlsPosture::Plaintext
    } else {
        TlsPosture::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_error_quotes_the_url_without_its_userinfo() {
        let canary = "Canary-pw_7f3a";
        let quoted = quotable(&format!(
            "https://app:{canary}@api.example.com:8443/v1/items?x=1"
        ));
        assert_eq!(quoted, "https://api.example.com:8443/v1/items?x=1");
        assert_eq!(quotable(&format!("http://:{canary}@h/")), "http://h/");
        assert_eq!(quotable("not a url"), "<unparsable url>");
    }

    #[test]
    fn url_posture_follows_the_scheme_case_insensitively() {
        assert_eq!(url_posture("https://x"), TlsPosture::Verified);
        assert_eq!(url_posture("HTTPS://x"), TlsPosture::Verified);
        assert_eq!(url_posture("http://x"), TlsPosture::Plaintext);
        assert_eq!(url_posture("ftp://x"), TlsPosture::Unknown);
    }
}
