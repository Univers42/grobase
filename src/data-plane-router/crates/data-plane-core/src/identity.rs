use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IdentitySource {
    SignedEnvelope,
    Jwt,
    ServiceToken,
    Test,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RequestIdentity {
    pub tenant_id: String,
    pub project_id: Option<String>,
    pub app_id: Option<String>,
    pub user_id: Option<String>,
    #[serde(default)]
    pub roles: Vec<String>,
    #[serde(default)]
    pub scopes: Vec<String>,
    pub source: IdentitySource,
}

impl RequestIdentity {
    #[must_use]
    pub fn is_tenant_scoped(&self) -> bool {
        !self.tenant_id.trim().is_empty()
    }

    /// The owner principal for per-request scoping: the authenticated user, or
    /// the tenant when there is no user. Borrowed (`&str`) so callers allocate
    /// only when they must — SQL/NoSQL owner stamps `.to_string()` it, the
    /// Postgres RLS GUC consumes it by reference. The single source of truth for
    /// the `user_id ?? tenant_id` rule (was reimplemented per engine adapter).
    #[must_use]
    pub fn owner_principal(&self) -> &str {
        self.user_id.as_deref().unwrap_or(self.tenant_id.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(user: Option<&str>, tenant: &str) -> RequestIdentity {
        RequestIdentity {
            tenant_id: tenant.to_string(),
            project_id: None,
            app_id: None,
            user_id: user.map(str::to_string),
            roles: vec![],
            scopes: vec![],
            source: IdentitySource::Test,
        }
    }

    #[test]
    fn owner_principal_prefers_user_then_falls_back_to_tenant() {
        assert_eq!(id(Some("u1"), "t1").owner_principal(), "u1");
        assert_eq!(id(None, "t1").owner_principal(), "t1");
        // an explicit empty user_id is still a present user (parity with the old
        // `.clone().unwrap_or_else(..)` — Some("") does not fall back to tenant).
        assert_eq!(id(Some(""), "t1").owner_principal(), "");
    }
}
