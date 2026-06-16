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
}
