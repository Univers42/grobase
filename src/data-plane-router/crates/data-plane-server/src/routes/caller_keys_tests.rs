/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   caller_keys_tests.rs                               :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 16:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 16:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! K8 (ADR 0023): the caller-key startup check, and that it names variables
//! and never values.

use super::caller_keys::{
    CallerPolicy, CallerPolicyMode, LEGACY_KEY, LEGACY_PREV_KEY, QUERY_ROUTER_KEY,
    QUERY_ROUTER_PREV_KEY, TENANT_CONTROL_KEY, TENANT_CONTROL_PREV_KEY,
};
use crate::environment::{CallerKeyProblem, ConfigError};

const QR: &str = "query-router-key-0123456789abcdef0123";
const TC: &str = "tenant-control-key-0123456789abcdef01";
const LEGACY: &str = "legacy-shared-token-0123456789abcdef";

fn enforced() -> CallerPolicy {
    CallerPolicy {
        mode: CallerPolicyMode::Enforce,
        query_router: QR.into(),
        tenant_control: TC.into(),
        ..CallerPolicy::default()
    }
}

fn refusal(policy: &CallerPolicy) -> Option<ConfigError> {
    policy.validate(LEGACY, "").err()
}

fn caller_key(key: &'static str, problem: CallerKeyProblem) -> Option<ConfigError> {
    Some(ConfigError::CallerKey { key, problem })
}

#[test]
fn k8_off_accepts_anything_and_a_sound_set_starts() {
    let off = CallerPolicy::default();
    assert_eq!(off.validate("", ""), Ok(()));
    assert_eq!(enforced().validate(LEGACY, ""), Ok(()));
}

#[test]
fn k8_unset_empty_or_short_keys_refuse_to_start() {
    let mut p = enforced();
    p.query_router = String::new();
    assert_eq!(
        refusal(&p),
        caller_key(QUERY_ROUTER_KEY, CallerKeyProblem::Unset)
    );
    p.query_router = "   ".into();
    assert_eq!(
        refusal(&p),
        caller_key(QUERY_ROUTER_KEY, CallerKeyProblem::Unset)
    );
    let mut p = enforced();
    p.mode = CallerPolicyMode::Shadow;
    p.tenant_control = "x".repeat(31);
    assert_eq!(
        refusal(&p),
        caller_key(TENANT_CONTROL_KEY, CallerKeyProblem::TooShort)
    );
    let mut p = enforced();
    p.query_router_prev = "short".into();
    assert_eq!(
        refusal(&p),
        caller_key(QUERY_ROUTER_PREV_KEY, CallerKeyProblem::TooShort)
    );
}

#[test]
fn k8_a_key_equal_to_another_or_to_the_legacy_token_refuses_to_start() {
    let mut p = enforced();
    p.tenant_control = QR.into();
    assert_eq!(
        refusal(&p),
        caller_key(
            QUERY_ROUTER_KEY,
            CallerKeyProblem::SameAs(TENANT_CONTROL_KEY)
        )
    );
    let mut p = enforced();
    p.query_router = LEGACY.into();
    assert_eq!(
        refusal(&p),
        caller_key(QUERY_ROUTER_KEY, CallerKeyProblem::SameAs(LEGACY_KEY))
    );
    let mut p = enforced();
    p.tenant_control_prev = QR.into();
    assert_eq!(
        refusal(&p),
        caller_key(
            QUERY_ROUTER_KEY,
            CallerKeyProblem::SameAs(TENANT_CONTROL_PREV_KEY)
        )
    );
    let p = enforced();
    assert_eq!(
        p.validate("legacy-current-0123456789abcdef0123", TC).err(),
        caller_key(
            TENANT_CONTROL_KEY,
            CallerKeyProblem::SameAs(LEGACY_PREV_KEY)
        )
    );
}

#[test]
fn k8_the_refusal_names_the_variable_never_the_value() {
    let mut p = enforced();
    p.tenant_control = QR.into();
    let err = refusal(&p).expect("refused");
    for rendered in [err.to_string(), format!("{err:?}")] {
        assert!(rendered.contains(QUERY_ROUTER_KEY), "{rendered}");
        assert!(!rendered.contains(QR), "{rendered}");
    }
    assert!(!format!("{p:?}").contains(QR), "Debug printed a key");
}
