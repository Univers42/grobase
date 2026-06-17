#![allow(clippy::doc_overindented_list_items)]
//! In-Rust ABAC / RBAC policy evaluator.
//!
//! Mirrors the SQL `public.has_permission(user, type, name, action)` function
//! that lives in the Postgres control plane, plus the field-mask resolution
//! step the NestJS `DecisionsService` performs. The goal: the data-plane
//! router can decide locally instead of round-tripping the permission-engine
//! over HTTP for every query.
//!
//! Selection algorithm (same as the SQL function):
//!   1. For every (role active for user, policy whose resource_type/name
//!      matches via exact or `*`, action is in policy.actions):
//!         a. Sort by priority DESC, then effect ASC ("deny" before "allow")
//!         b. If any matched policy has effect=deny → DENY
//!         c. Else if any matched policy has effect=allow → ALLOW
//!         d. Else → DENY (default)
//!
//! Mode:
//!   * `abac` — also evaluates the JSONB `conditions` per matched policy:
//!              today's contract only uses the `mask`/`field_mask` shape to
//!              produce per-field hide/redact rules on allow.
//!   * `rbac` — skips conditions entirely; allow is binary, no field masks.
//!
//! Bundle source: a JSON blob fed in via `DATA_PLANE_PERMISSION_BUNDLE` env
//! (literal JSON). A future slice can swap in an HTTP fetch + TTL refresh
//! from the permission-engine `/permissions/bundles/latest` endpoint.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Permission mode. Compose env `DATA_PLANE_PERMISSION_MODE` sets it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PermissionMode {
    Abac,
    Rbac,
}

impl PermissionMode {
    pub fn from_env_string(raw: &str) -> Self {
        if raw.trim().eq_ignore_ascii_case("rbac") {
            Self::Rbac
        } else {
            Self::Abac
        }
    }
}

/// A bundle of policies + user→role assignments served by the permission
/// control plane. Fed verbatim into the evaluator at startup.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct PolicyBundle {
    #[serde(default)]
    pub user_roles: Vec<UserRole>,
    #[serde(default)]
    pub policies: Vec<Policy>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct UserRole {
    pub user_id: String,
    pub role_id: String,
    #[serde(default)]
    pub expires_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Policy {
    pub role_id: String,
    pub resource_type: String,
    pub resource_name: String,
    pub actions: Vec<String>,
    pub effect: PolicyEffect,
    #[serde(default)]
    pub priority: i32,
    #[serde(default)]
    pub conditions: Option<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PolicyEffect {
    Allow,
    Deny,
}

/// Per-field mask returned alongside an allow decision.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct FieldMask {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hide: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub redact: BTreeMap<String, String>,
}

impl FieldMask {
    pub fn is_empty(&self) -> bool {
        self.hide.is_empty() && self.redact.is_empty()
    }
}

/// Apply a field mask to query rows IN PLACE — mirrors the query-router's
/// `applyFieldMask`: `hide` removes the key entirely; `redact` replaces an
/// EXISTING field's value with the mask string. Only JSON objects are touched;
/// scalar/array rows pass through unchanged.
pub fn apply_field_mask(rows: &mut [Value], mask: &FieldMask) {
    if mask.is_empty() {
        return;
    }
    for row in rows.iter_mut() {
        let Some(obj) = row.as_object_mut() else {
            continue;
        };
        for field in &mask.hide {
            obj.remove(field);
        }
        for (field, replacement) in &mask.redact {
            if let Some(v) = obj.get_mut(field) {
                *v = Value::String(replacement.clone());
            }
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Decision {
    pub allow: bool,
    pub reason: String,
    pub mode: PermissionMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mask: Option<FieldMask>,
}

/// Stateless evaluator over a `PolicyBundle`. Cheap to clone (Arc internally
/// would be redundant — bundles are typically <1MB).
#[derive(Debug, Clone)]
pub struct Evaluator {
    bundle: PolicyBundle,
    mode: PermissionMode,
}

impl Evaluator {
    pub fn new(bundle: PolicyBundle, mode: PermissionMode) -> Self {
        Self { bundle, mode }
    }

    pub fn mode(&self) -> PermissionMode {
        self.mode
    }

    pub fn bundle_size(&self) -> (usize, usize) {
        (self.bundle.user_roles.len(), self.bundle.policies.len())
    }

    /// Mirrors `public.has_permission(user_id, type, name, action)`.
    pub fn decide(
        &self,
        user_id: &str,
        resource_type: &str,
        resource_name: &str,
        action: &str,
    ) -> Decision {
        let now = Utc::now();
        // Active roles for this user.
        let active_role_ids: Vec<&str> = self
            .bundle
            .user_roles
            .iter()
            .filter(|ur| ur.user_id == user_id)
            .filter(|ur| ur.expires_at.map(|t| t > now).unwrap_or(true))
            .map(|ur| ur.role_id.as_str())
            .collect();
        if active_role_ids.is_empty() {
            return Decision {
                allow: false,
                reason: format!(
                    "Denied by {} policy (no active roles for user)",
                    self.mode_str()
                ),
                mode: self.mode,
                mask: None,
            };
        }

        // Matching policies.
        let mut matched: Vec<&Policy> = self
            .bundle
            .policies
            .iter()
            .filter(|p| active_role_ids.contains(&p.role_id.as_str()))
            .filter(|p| match_resource(&p.resource_type, resource_type))
            .filter(|p| match_resource(&p.resource_name, resource_name))
            .filter(|p| p.actions.iter().any(|a| a == action))
            .collect();
        // priority DESC, then deny-before-allow at the same priority.
        matched.sort_by(|a, b| {
            b.priority
                .cmp(&a.priority)
                .then(effect_order(&a.effect).cmp(&effect_order(&b.effect)))
        });

        let mut found_allow = false;
        for pol in &matched {
            match pol.effect {
                PolicyEffect::Deny => {
                    return Decision {
                        allow: false,
                        reason: format!("Denied by {} policy", self.mode_str()),
                        mode: self.mode,
                        mask: None,
                    };
                }
                PolicyEffect::Allow => {
                    found_allow = true;
                }
            }
        }

        if !found_allow {
            return Decision {
                allow: false,
                reason: format!("Denied by {} policy (no matching allow)", self.mode_str()),
                mode: self.mode,
                mask: None,
            };
        }

        let mask = if self.mode == PermissionMode::Abac {
            resolve_field_mask(&matched)
        } else {
            None
        };
        Decision {
            allow: true,
            reason: format!("Allowed by {} policy", self.mode_str()),
            mode: self.mode,
            mask,
        }
    }

    fn mode_str(&self) -> &'static str {
        match self.mode {
            PermissionMode::Abac => "ABAC",
            PermissionMode::Rbac => "RBAC",
        }
    }
}

fn match_resource(pattern: &str, value: &str) -> bool {
    pattern == "*" || pattern == value
}

fn effect_order(e: &PolicyEffect) -> u8 {
    // Deny first at the same priority.
    match e {
        PolicyEffect::Deny => 0,
        PolicyEffect::Allow => 1,
    }
}

/// Walks the highest-priority allow policy's conditions object for a
/// `mask`/`field_mask` key and lifts it into a typed `FieldMask`.
fn resolve_field_mask(matched: &[&Policy]) -> Option<FieldMask> {
    let pol = matched
        .iter()
        .find(|p| p.effect == PolicyEffect::Allow)?;
    let conditions = pol.conditions.as_ref()?;
    let mask_value = conditions.get("mask").or_else(|| conditions.get("field_mask"))?;
    let mask_obj = mask_value.as_object()?;
    let mut mask = FieldMask::default();
    if let Some(hide) = mask_obj.get("hide").and_then(|v| v.as_array()) {
        for v in hide {
            if let Some(s) = v.as_str() {
                if !s.is_empty() {
                    mask.hide.push(s.to_string());
                }
            }
        }
    }
    if let Some(redact) = mask_obj.get("redact").and_then(|v| v.as_object()) {
        for (k, v) in redact {
            if let Some(s) = v.as_str() {
                mask.redact.insert(k.clone(), s.to_string());
            }
        }
    }
    if mask.is_empty() {
        None
    } else {
        Some(mask)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture_bundle() -> PolicyBundle {
        PolicyBundle {
            user_roles: vec![
                UserRole {
                    user_id: "u-1".into(),
                    role_id: "r-user".into(),
                    expires_at: None,
                },
                UserRole {
                    user_id: "u-2".into(),
                    role_id: "r-admin".into(),
                    expires_at: None,
                },
            ],
            policies: vec![
                Policy {
                    role_id: "r-user".into(),
                    resource_type: "*".into(),
                    resource_name: "*".into(),
                    actions: vec!["select".into(), "insert".into()],
                    effect: PolicyEffect::Allow,
                    priority: 0,
                    conditions: Some(json!({
                        "mask": { "hide": ["secret"], "redact": { "email": "***" } }
                    })),
                },
                Policy {
                    role_id: "r-user".into(),
                    resource_type: "audit_log".into(),
                    resource_name: "*".into(),
                    actions: vec!["select".into()],
                    effect: PolicyEffect::Deny,
                    priority: 100,
                    conditions: None,
                },
                Policy {
                    role_id: "r-admin".into(),
                    resource_type: "*".into(),
                    resource_name: "*".into(),
                    actions: vec!["select".into(), "insert".into(), "update".into(), "delete".into()],
                    effect: PolicyEffect::Allow,
                    priority: 0,
                    conditions: None,
                },
            ],
        }
    }

    #[test]
    fn field_mask_hides_and_redacts_only_existing() {
        let mask = FieldMask {
            hide: vec!["secret".into()],
            redact: BTreeMap::from([("email".to_string(), "***".to_string())]),
        };
        let mut rows = vec![
            json!({ "id": 1, "secret": "x", "email": "a@b.com", "name": "n" }),
            json!({ "id": 2, "name": "no-email-or-secret" }),
        ];
        apply_field_mask(&mut rows, &mask);
        assert!(rows[0].get("secret").is_none(), "hide removes the key");
        assert_eq!(rows[0]["email"], "***", "redact replaces the value");
        assert_eq!(rows[0]["name"], "n", "untouched field survives");
        assert_eq!(rows[0]["id"], 1);
        // redact only touches fields that exist; row 2 keeps its shape
        assert!(rows[1].get("email").is_none());
        assert_eq!(rows[1]["name"], "no-email-or-secret");
    }

    #[test]
    fn allows_user_on_own_resource() {
        let ev = Evaluator::new(fixture_bundle(), PermissionMode::Abac);
        let d = ev.decide("u-1", "postgresql", "users", "select");
        assert!(d.allow);
        assert!(d.mask.is_some());
    }

    #[test]
    fn deny_beats_allow_at_higher_priority() {
        let ev = Evaluator::new(fixture_bundle(), PermissionMode::Abac);
        let d = ev.decide("u-1", "audit_log", "events", "select");
        assert!(!d.allow);
    }

    #[test]
    fn no_role_no_access() {
        let ev = Evaluator::new(fixture_bundle(), PermissionMode::Abac);
        let d = ev.decide("u-unknown", "postgresql", "users", "select");
        assert!(!d.allow);
    }

    #[test]
    fn admin_gets_full_crud() {
        let ev = Evaluator::new(fixture_bundle(), PermissionMode::Abac);
        for action in ["select", "insert", "update", "delete"] {
            assert!(ev.decide("u-2", "any", "thing", action).allow, "{action}");
        }
    }

    #[test]
    fn rbac_mode_returns_no_mask_even_on_allow() {
        let ev = Evaluator::new(fixture_bundle(), PermissionMode::Rbac);
        let d = ev.decide("u-1", "postgresql", "users", "select");
        assert!(d.allow);
        assert!(d.mask.is_none(), "RBAC must skip field-mask resolution");
    }

    #[test]
    fn expired_role_is_inactive() {
        let mut b = fixture_bundle();
        b.user_roles[0].expires_at = Some(Utc::now() - chrono::Duration::seconds(60));
        let ev = Evaluator::new(b, PermissionMode::Abac);
        let d = ev.decide("u-1", "postgresql", "users", "select");
        assert!(!d.allow);
    }

    #[test]
    fn action_not_in_policy_denies() {
        let ev = Evaluator::new(fixture_bundle(), PermissionMode::Abac);
        // r-user has no `delete` policy
        let d = ev.decide("u-1", "postgresql", "users", "delete");
        assert!(!d.allow);
    }

    #[test]
    fn mode_from_env_string() {
        assert_eq!(PermissionMode::from_env_string("rbac"), PermissionMode::Rbac);
        assert_eq!(PermissionMode::from_env_string("RBAC"), PermissionMode::Rbac);
        assert_eq!(PermissionMode::from_env_string("abac"), PermissionMode::Abac);
        assert_eq!(PermissionMode::from_env_string(""), PermissionMode::Abac);
        assert_eq!(PermissionMode::from_env_string("xyz"), PermissionMode::Abac);
    }
}
