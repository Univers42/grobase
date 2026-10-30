/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   redirect.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The mount's `reqwest::Client`, which follows a redirect only to the mount's
//! own origin.
//!
//! reqwest's default `Policy::limited(10)` follows any host, and the SSRF pin
//! (`.resolve(host, addr)`) covers only the base URL's host name. So a public
//! upstream answering `302 Location: http://169.254.169.254/` led the client
//! past `guard_and_resolve`, and the body came back to the caller (G2-H1).
//! `Policy::none()` would be the lower rung. The custom policy exists only to
//! keep today's same-origin redirects (a trailing-slash 301, `/v1` → `/v2`)
//! working.

use data_plane_core::{DataPlaneError, DataPlaneResult};
use reqwest::redirect::Policy;
use reqwest::{Client, Url};
use std::net::SocketAddr;
use std::time::Duration;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_REDIRECTS: usize = 10;

/// Whether redirect number `hops` (1-based) to `next` may be followed: only to
/// the mount's own scheme, host and port, compared against the BASE URL and not
/// the previous hop, so a chain cannot walk off-origin one step at a time.
pub(super) fn redirect_allowed(origin: &Url, next: &Url, hops: usize) -> bool {
    hops <= MAX_REDIRECTS
        && next.scheme() == origin.scheme()
        && next.host_str() == origin.host_str()
        && next.port_or_known_default() == origin.port_or_known_default()
}

/// The pinned client for one mount. The redirect policy is installed on every
/// path, `DATA_PLANE_HTTP_ALLOW_INTERNAL=1` (`pinned == None`) included.
pub(super) fn build_client(
    base_url: &str,
    pinned: Option<(String, Vec<SocketAddr>)>,
) -> DataPlaneResult<Client> {
    let origin = Url::parse(base_url).map_err(|e| DataPlaneError::Backend {
        message: format!("http baseUrl parse: {e}"),
    })?;
    // `stop()` hands the 3xx back as a response, which `HttpPool::dispatch`
    // maps like any other non-2xx; an `error()` would surface as a transport error.
    let policy = Policy::custom(move |attempt| {
        if redirect_allowed(&origin, attempt.url(), attempt.previous().len()) {
            attempt.follow()
        } else {
            attempt.stop()
        }
    });
    let mut builder = Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .user_agent("mini-baas-data-plane-router/0.1")
        .redirect(policy);
    if let Some((host, addrs)) = pinned {
        for addr in addrs {
            builder = builder.resolve(&host, addr);
        }
    }
    builder.build().map_err(|e| DataPlaneError::Backend {
        message: format!("reqwest client init failed: {e}"),
    })
}

#[cfg(test)]
mod tests {
    use super::super::pool::HttpPool;
    use super::super::validate::parse_connection;
    use super::{build_client, redirect_allowed};
    use data_plane_core::{
        DataOperation, DataOperationKind, EnginePool, IdentitySource, RequestIdentity,
    };
    use reqwest::Url;
    use std::io::{ErrorKind, Read, Write};
    use std::net::TcpListener;
    use std::thread;

    fn url(raw: &str) -> Url {
        Url::parse(raw).unwrap()
    }

    #[test]
    fn redirect_allowed_only_to_the_mount_origin() {
        let origin = url("https://api.example.com/base");
        let cases: &[(&str, usize, bool)] = &[
            ("https://api.example.com/other", 1, true),
            ("https://API.example.com/x", 1, true),
            ("https://api.example.com:443/x", 1, true),
            ("https://api.example.com/x", 10, true),
            ("https://api.example.com/x", 11, false),
            ("https://evil.example.com/x", 1, false),
            ("https://api.example.com:8443/x", 1, false),
            ("http://api.example.com/x", 1, false),
            ("https://93.184.216.34/x", 1, false),
            ("https://api.example.com./x", 1, false),
            ("http://169.254.169.254/latest/meta-data", 1, false),
        ];
        for (next, hops, want) in cases {
            assert_eq!(
                redirect_allowed(&origin, &url(next), *hops),
                *want,
                "{next} hop {hops}"
            );
        }
        let plain = url("http://api.example.com/");
        assert!(!redirect_allowed(
            &plain,
            &url("https://api.example.com/"),
            1
        ));
        // A relative Location resolves against the current hop before the policy sees it.
        let relative = url("https://api.example.com/a/b").join("../c").unwrap();
        assert!(redirect_allowed(&origin, &relative, 1));
    }

    /// One request per connection, answered with the raw reply routed by its path.
    fn serve(listener: TcpListener, routes: Vec<(&'static str, String)>) {
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let mut buf = [0u8; 4096];
                let n = stream.read(&mut buf).unwrap_or(0);
                let head = String::from_utf8_lossy(&buf[..n]);
                let path = head.split_whitespace().nth(1).unwrap_or("/").to_owned();
                let reply = routes.iter().find(|(p, _)| *p == path).map_or_else(
                    || "HTTP/1.1 404 Not Found\r\n".to_owned(),
                    |(_, r)| r.clone(),
                );
                let _ = stream.write_all(reply.as_bytes());
            }
        });
    }

    fn redirect_to(location: &str) -> String {
        format!("HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }

    fn ok_json(body: &str) -> String {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    fn pool_for(base_url: &str) -> HttpPool {
        HttpPool {
            mount_id: "m".into(),
            tenant_id: "t".into(),
            shared_pool: false,
            // `None` is what DATA_PLANE_HTTP_ALLOW_INTERNAL=1 yields: the policy must hold there too.
            client: build_client(base_url, None).unwrap(),
            conn: parse_connection(base_url).unwrap(),
        }
    }

    fn list(resource: &str) -> DataOperation {
        DataOperation {
            op: DataOperationKind::List,
            resource: resource.into(),
            data: None,
            filter: None,
            sort: None,
            limit: None,
            offset: None,
            idempotency_key: None,
            expected_version: None,
            returning: None,
            aggregate: None,
            fields: None,
            search: None,
            vector: None,
        }
    }

    fn identity() -> RequestIdentity {
        RequestIdentity {
            tenant_id: "t".into(),
            project_id: None,
            app_id: None,
            user_id: None,
            roles: vec![],
            scopes: vec![],
            source: IdentitySource::Test,
        }
    }

    #[tokio::test]
    async fn a_cross_origin_redirect_is_never_followed() {
        let a = TcpListener::bind("127.0.0.1:0").unwrap();
        let b = TcpListener::bind("127.0.0.1:0").unwrap();
        let b_addr = b.local_addr().unwrap();
        let base = format!("http://{}", a.local_addr().unwrap());
        serve(
            a,
            vec![
                ("/items", redirect_to(&format!("http://{b_addr}/items"))),
                ("/same", redirect_to("/landed")),
                ("/landed", ok_json(r#"[{"id":1}]"#)),
            ],
        );
        let pool = pool_for(&base);

        let err = pool
            .execute(list("items"), identity())
            .await
            .expect_err("a 302 to another origin must not read as data");
        assert!(err.to_string().contains("302"), "{err}");
        b.set_nonblocking(true).unwrap();
        assert_eq!(
            b.accept().map(|_| ()).map_err(|e| e.kind()),
            Err(ErrorKind::WouldBlock),
            "the off-origin target must receive zero connections"
        );

        let same = pool
            .execute(list("same"), identity())
            .await
            .expect("a same-origin redirect is still followed");
        assert_eq!(same.rows.len(), 1);
    }
}
