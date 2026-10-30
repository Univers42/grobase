/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   caller_keys.rs                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 16:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 16:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! D1 (ADR 0023) — each data-plane caller signs with its own key, and the key
//! that verifies is the caller class. The legacy `INTERNAL_SERVICE_TOKEN` is
//! held by about nine services, the tenant-code host among them; these keys are
//! held by one caller each. `DATA_PLANE_CALLER_POLICY` rolls the class checks
//! out (`off` default, `shadow`, `enforce`) independently of
//! `DATA_PLANE_INBOUND_AUTH`.

use data_plane_pool::service_auth::{KeyRing, ServiceAuthDenial, SignedRequest};

use super::inbound_auth::{InboundAuth, InboundAuthMode};
use crate::environment::{CallerKeyProblem, ConfigError};

pub(crate) const CALLER_POLICY_KEY: &str = "DATA_PLANE_CALLER_POLICY";
pub(crate) const QUERY_ROUTER_KEY: &str = "DATA_PLANE_KEY_QUERY_ROUTER";
pub(crate) const QUERY_ROUTER_PREV_KEY: &str = "DATA_PLANE_KEY_QUERY_ROUTER_PREV";
pub(crate) const TENANT_CONTROL_KEY: &str = "DATA_PLANE_KEY_TENANT_CONTROL";
pub(crate) const TENANT_CONTROL_PREV_KEY: &str = "DATA_PLANE_KEY_TENANT_CONTROL_PREV";
pub(crate) const LEGACY_KEY: &str = "INTERNAL_SERVICE_TOKEN";
pub(crate) const LEGACY_PREV_KEY: &str = "INTERNAL_SERVICE_TOKEN_PREV";
const MIN_KEY_BYTES: usize = 32;

/// The same off|shadow|enforce rollout as G1a, read from its own variable.
pub type CallerPolicyMode = InboundAuthMode;

/// Who signed a call, decided by the key that verified it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallerClass {
    QueryRouter,
    TenantControl,
    /// The shared `INTERNAL_SERVICE_TOKEN` (or its `_PREV`).
    Legacy,
}

impl CallerClass {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::QueryRouter => "query_router",
            Self::TenantControl => "tenant_control",
            Self::Legacy => "legacy",
        }
    }
}

/// Read once at startup; `Debug` reports which keys are set, never a value.
#[derive(Clone, Default)]
pub struct CallerPolicy {
    pub mode: CallerPolicyMode,
    pub query_router: String,
    pub query_router_prev: String,
    pub tenant_control: String,
    pub tenant_control_prev: String,
}

impl std::fmt::Debug for CallerPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CallerPolicy")
            .field("mode", &self.mode)
            .field("query_router_set", &!self.query_router.is_empty())
            .field("query_router_prev_set", &!self.query_router_prev.is_empty())
            .field("tenant_control_set", &!self.tenant_control.is_empty())
            .field(
                "tenant_control_prev_set",
                &!self.tenant_control_prev.is_empty(),
            )
            .finish()
    }
}

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_default()
}

/// Ring position → class: legacy current, legacy prev, then each caller's pair.
const CLASS_AT: [CallerClass; 6] = [
    CallerClass::Legacy,
    CallerClass::Legacy,
    CallerClass::QueryRouter,
    CallerClass::QueryRouter,
    CallerClass::TenantControl,
    CallerClass::TenantControl,
];

impl CallerPolicy {
    /// An unknown mode reads as `off` here; `ServerConfig::try_from_env` refuses it.
    #[must_use]
    pub fn from_env() -> Self {
        Self {
            mode: CallerPolicyMode::parse(&env(CALLER_POLICY_KEY)).unwrap_or_default(),
            query_router: env(QUERY_ROUTER_KEY),
            query_router_prev: env(QUERY_ROUTER_PREV_KEY),
            tenant_control: env(TENANT_CONTROL_KEY),
            tenant_control_prev: env(TENANT_CONTROL_PREV_KEY),
        }
    }

    /// The class of the key that verifies `request`, every key compared. The
    /// legacy prev is dropped when the legacy current is unset, as G1a did.
    ///
    /// # Errors
    /// The [`ServiceAuthDenial`] when no configured key verifies.
    pub(crate) fn identify<'h>(
        &self,
        legacy: &str,
        auth: &InboundAuth,
        header: impl Fn(&str) -> Option<&'h str>,
        request: &SignedRequest<'_>,
    ) -> Result<CallerClass, ServiceAuthDenial> {
        let legacy_prev = if legacy.is_empty() {
            ""
        } else {
            &auth.prev_token
        };
        let keys = [
            legacy,
            legacy_prev,
            &self.query_router,
            &self.query_router_prev,
            &self.tenant_control,
            &self.tenant_control_prev,
        ];
        let ring = KeyRing {
            keys: &keys,
            hmac: auth.hmac,
            skew_secs: auth.skew_secs,
        };
        ring.identify(header, request, super::inbound_auth::unix_now())
            .map(|at| CLASS_AT[at])
    }

    /// K8: in every mode a set key is unpadded and at least 32 bytes, because
    /// G1a accepts it as a credential even under off. Under shadow or enforce
    /// both current keys must also be set and no two keys (legacy included)
    /// may be equal.
    ///
    /// # Errors
    /// `ConfigError::CallerKey` naming the first variable that fails.
    pub fn validate(&self, legacy: &str, legacy_prev: &str) -> Result<(), ConfigError> {
        let policy_on = self.mode != CallerPolicyMode::Off;
        let named = [
            (QUERY_ROUTER_KEY, self.query_router.as_str()),
            (TENANT_CONTROL_KEY, self.tenant_control.as_str()),
            (QUERY_ROUTER_PREV_KEY, self.query_router_prev.as_str()),
            (TENANT_CONTROL_PREV_KEY, self.tenant_control_prev.as_str()),
        ];
        for (at, (key, value)) in named.iter().enumerate() {
            check_shape(key, value, policy_on && at < 2)?;
        }
        if !policy_on {
            return Ok(());
        }
        let legacy_keys = [(LEGACY_KEY, legacy), (LEGACY_PREV_KEY, legacy_prev)];
        for (at, (key, value)) in named.iter().enumerate() {
            let others = named[at + 1..].iter().chain(legacy_keys.iter());
            check_distinct(key, value, others)?;
        }
        Ok(())
    }
}

fn refuse(key: &'static str, problem: CallerKeyProblem) -> Result<(), ConfigError> {
    Err(ConfigError::CallerKey { key, problem })
}

/// An empty key is refused only when `required`. A padded one is refused even
/// when all whitespace: the keyring would hold it verbatim as a live short key.
fn check_shape(key: &'static str, value: &str, required: bool) -> Result<(), ConfigError> {
    if value.is_empty() {
        return if required {
            refuse(key, CallerKeyProblem::Unset)
        } else {
            Ok(())
        };
    }
    if value != value.trim() {
        return refuse(key, CallerKeyProblem::Padded);
    }
    if value.len() < MIN_KEY_BYTES {
        return refuse(key, CallerKeyProblem::TooShort);
    }
    Ok(())
}

fn check_distinct<'a>(
    key: &'static str,
    value: &str,
    others: impl Iterator<Item = &'a (&'static str, &'a str)>,
) -> Result<(), ConfigError> {
    if value.is_empty() {
        return Ok(());
    }
    for (other, other_value) in others {
        if value == *other_value {
            return refuse(key, CallerKeyProblem::SameAs(other));
        }
    }
    Ok(())
}
