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

    /// Whether this caller is an administrator — a role/scope that an
    /// owner-scope bypass (F2, `DATA_PLANE_ADMIN_BYPASS`) honours so an admin
    /// reads/updates/deletes across owners. True when `roles` contains `admin`
    /// or `scopes` carries `admin` / `apikey:admin` (the projected API-key admin
    /// scope). Pure over the already-verified identity — the bypass that
    /// consults it is itself flag-gated OFF by default, so this never widens
    /// access on its own.
    #[must_use]
    pub fn is_admin(&self) -> bool {
        self.roles.iter().any(|r| r == "admin")
            || self.scopes.iter().any(|s| s == "admin" || s == "apikey:admin")
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

    #[test]
    fn is_admin_reads_roles_and_scopes() {
        let mut base = id(Some("u1"), "t1");
        assert!(!base.is_admin(), "no role/scope → not admin (parity default)");
        base.roles = vec!["admin".to_string()];
        assert!(base.is_admin(), "role=admin");
        let mut by_scope = id(Some("u1"), "t1");
        by_scope.scopes = vec!["apikey:admin".to_string()];
        assert!(by_scope.is_admin(), "scope=apikey:admin");
        let mut other = id(Some("u1"), "t1");
        other.roles = vec!["authenticated".to_string()];
        other.scopes = vec!["read".to_string(), "write".to_string()];
        assert!(!other.is_admin(), "ordinary client is never admin");
    }
}
