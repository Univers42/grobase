use thiserror::Error;

pub type DataPlaneResult<T> = Result<T, DataPlaneError>;

#[derive(Debug, Error)]
pub enum DataPlaneError {
    #[error("engine '{engine}' does not support requested capability '{capability}'")]
    UnsupportedCapability { engine: String, capability: String },

    /// The engine CAN serve this operation, but the tenant's package tier does
    /// not include it (the per-tenant capability mask narrowed it away).
    /// DISTINCT from `UnsupportedCapability` (the engine genuinely can't — 422):
    /// a tier denial is an authorization decision (403 Forbidden) — lifting it
    /// means upgrading the package, not changing the request.
    #[error("capability '{capability}' is not included in this tenant's package tier")]
    CapabilityGated { capability: String },

    #[error("mount '{mount_id}' was not found")]
    MountNotFound { mount_id: String },

    #[error("transaction '{tx_id}' was not found")]
    TransactionNotFound { tx_id: String },

    #[error("invalid identifier '{value}'")]
    InvalidIdentifier { value: String },

    #[error("credential for mount '{mount_id}' could not be resolved")]
    CredentialUnavailable { mount_id: String },

    /// A configured credential provider (Vault / adapter-registry) was reached
    /// but failed to return a usable credential (transport error, non-2xx, or a
    /// missing field in the response). Distinct from `CredentialUnavailable`,
    /// which means no source even produced an attempt (unknown provider /
    /// fail-closed). NEVER carries the DSN — only the provider name + mount id.
    #[error("credential provider '{provider}' failed for mount '{mount_id}'")]
    CredentialProviderFailed { provider: String, mount_id: String },

    #[error("backend error: {message}")]
    Backend { message: String },

    /// An integrity-constraint violation (unique/primary key, foreign key,
    /// not-null, check) — the client's write conflicts with existing data or a
    /// declared constraint. A client error (409 Conflict), distinct from
    /// `Backend` (an engine/transport failure, 5xx).
    #[error("conflict: {message}")]
    Conflict { message: String },

    /// The request itself is malformed or violates a safety rule (empty mutation
    /// filter, no updatable columns, wrong `data` shape). A client error (4xx),
    /// distinct from `Backend` (an engine/transport failure, 5xx).
    #[error("invalid request: {message}")]
    InvalidRequest { message: String },

    #[error("{feature} is not implemented in the Rust shadow data plane yet")]
    NotImplemented { feature: String },
}

impl DataPlaneError {
    /// Re-wraps an error's text with a context prefix (e.g. `batch item 3: `)
    /// while preserving the variant — and therefore the HTTP status the server
    /// maps it to. Variants whose payload is not free text pass through as-is.
    #[must_use]
    pub fn prefix_message(prefix: &str, err: DataPlaneError) -> DataPlaneError {
        match err {
            Self::Backend { message } => Self::Backend {
                message: format!("{prefix}{message}"),
            },
            Self::Conflict { message } => Self::Conflict {
                message: format!("{prefix}{message}"),
            },
            Self::InvalidRequest { message } => Self::InvalidRequest {
                message: format!("{prefix}{message}"),
            },
            Self::InvalidIdentifier { value } => Self::InvalidIdentifier {
                value: format!("{prefix}{value}"),
            },
            Self::NotImplemented { feature } => Self::NotImplemented {
                feature: format!("{prefix}{feature}"),
            },
            other => other,
        }
    }
}
