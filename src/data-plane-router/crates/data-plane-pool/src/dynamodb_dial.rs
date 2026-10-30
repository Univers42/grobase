/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dynamodb_dial.rs                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 11:45:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 11:45:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! G2 dial guard for DynamoDB (ADR 0019, devil C12). The SDK re-resolves the
//! endpoint name for every new connection, so a check at open alone lets a
//! name that moves later reach a denied address. Under a scope the client gets
//! a connector built like the SDK default (rustls aws-lc, proxy from env) with
//! a resolver that vets every lookup: enforce turns a denied record into a DNS
//! error, shadow logs and returns the records. TLS still checks the endpoint
//! name. hyper skips the resolver for an IP-literal endpoint, so `precheck`
//! vets the endpoint host at open. A Tenant mount without both static keys
//! would fall back to the default credential chain (IMDS is an IP literal), so
//! it is refused under enforce and logged under shadow.
//! Caveat: with `HTTPS_PROXY` set the resolver vets the proxy's name, not the
//! endpoint's. The resolver is given no port, so every log line carries the
//! endpoint's port. A refusal after open surfaces as the SDK's dispatch
//! failure; the `dial_guard deny` line names the class.

use crate::dial_guard::classify::DenyClass;
use crate::dial_guard::scope::{DialScope, Refusal};
use aws_smithy_http_client::proxy::ProxyConfig;
use aws_smithy_http_client::tls::{self, rustls_provider::CryptoMode};
use aws_smithy_http_client::{Builder, ConnectorBuilder};
use aws_smithy_runtime_api::client::dns::{DnsFuture, ResolveDns, ResolveDnsError};
use aws_smithy_runtime_api::client::http::SharedHttpClient;
use data_plane_core::{DataPlaneError, DataPlaneResult};
use std::fmt;
use std::net::IpAddr;
use std::sync::Arc;

/// Where the mount dials: real AWS (no `endpoint=`), a host, or an endpoint
/// with no host to vet.
#[derive(Debug, PartialEq, Eq)]
enum Target {
    Aws,
    Host(String),
    Unparsed,
}

pub(crate) struct DynamoGuard {
    scope: Arc<DialScope>,
    target: Target,
    port: u16,
}

impl DynamoGuard {
    pub(crate) fn new(scope: DialScope, endpoint: Option<&str>) -> Self {
        let (target, port) = target_of(endpoint);
        Self {
            scope: Arc::new(scope),
            target,
            port,
        }
    }

    /// Reports every refusal at open; enforce returns the first.
    pub(crate) async fn precheck(&self, has_static_keys: bool) -> DataPlaneResult<()> {
        let mut refusals = Vec::new();
        if !has_static_keys {
            let class = DenyClass::DefaultCredentials;
            refusals.push(Refusal::new(class, None, self.host_label(), self.port));
        }
        if let Err(refusal) = self.vet_target().await {
            refusals.push(refusal);
        }
        for refusal in &refusals {
            self.scope.report(refusal);
        }
        match refusals.first() {
            Some(refusal) if self.scope.enforcing() => Err(self.scope.refused(refusal)),
            _ => Ok(()),
        }
    }

    /// The SDK default connector with the vetting resolver in place of getaddrinfo.
    pub(crate) fn http_client(&self) -> SharedHttpClient {
        let resolver = VettingResolver {
            scope: Arc::clone(&self.scope),
            port: self.port,
        };
        Builder::new().build_with_connector_fn(move |settings, components| {
            let provider = tls::Provider::Rustls(CryptoMode::AwsLc);
            let mut connector = ConnectorBuilder::default().tls_provider(provider);
            connector.set_connector_settings(settings.cloned());
            if let Some(components) = components {
                connector.set_sleep_impl(components.sleep_impl());
            }
            connector.set_proxy_config(Some(ProxyConfig::from_env()));
            connector.build_with_resolver(resolver.clone())
        })
    }

    /// Real AWS names are vetted by the resolver on every connection.
    async fn vet_target(&self) -> Result<(), Refusal> {
        match &self.target {
            Target::Aws => Ok(()),
            Target::Host(host) => self.scope.vet_host(host, self.port).await.map(drop),
            Target::Unparsed => Err(Refusal::new(DenyClass::Unresolved, None, "-", self.port)),
        }
    }

    fn host_label(&self) -> &str {
        match &self.target {
            Target::Host(host) => host,
            Target::Aws => "aws",
            Target::Unparsed => "-",
        }
    }
}

/// `endpoint=` as the SDK reads it; real AWS is https on 443.
fn target_of(endpoint: Option<&str>) -> (Target, u16) {
    let Some(endpoint) = endpoint else {
        return (Target::Aws, 443);
    };
    match reqwest::Url::parse(endpoint) {
        Ok(url) => {
            let port = url.port_or_known_default().unwrap_or(443);
            match url.host_str() {
                Some(host) => (Target::Host(host.to_string()), port),
                None => (Target::Unparsed, port),
            }
        }
        Err(_) => (Target::Unparsed, 443),
    }
}

#[derive(Clone)]
pub(crate) struct VettingResolver {
    scope: Arc<DialScope>,
    port: u16,
}

impl fmt::Debug for VettingResolver {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("VettingResolver")
            .field("port", &self.port)
            .finish_non_exhaustive()
    }
}

impl ResolveDns for VettingResolver {
    fn resolve_dns<'a>(&'a self, name: &'a str) -> DnsFuture<'a> {
        DnsFuture::new(async move { self.lookup(name).await.map_err(ResolveDnsError::new) })
    }
}

impl VettingResolver {
    #[cfg(test)]
    pub(crate) fn of(guard: &DynamoGuard) -> Self {
        Self {
            scope: Arc::clone(&guard.scope),
            port: guard.port,
        }
    }

    /// Shadow re-resolves after a refusal, so it returns what off would.
    async fn lookup(&self, name: &str) -> Result<Vec<IpAddr>, DataPlaneError> {
        let refusal = match self.scope.vet_host(name, self.port).await {
            Ok(ips) => return Ok(ips),
            Err(refusal) => refusal,
        };
        self.scope.report(&refusal);
        if self.scope.enforcing() {
            return Err(self.scope.refused(&refusal));
        }
        self.scope
            .resolve(name, self.port)
            .await
            .map_err(|_| DataPlaneError::Backend {
                message: "dynamodb endpoint name did not resolve".to_string(),
            })
    }
}
