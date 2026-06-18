use crate::{DatabaseMount, IsolationLevel, RequestIdentity};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TxBeginRequest {
    pub identity: RequestIdentity,
    pub mount: DatabaseMount,
    pub isolation: Option<IsolationLevel>,
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TxState {
    Open,
    Committed,
    RolledBack,
    Reaped,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TxSession {
    pub tx_id: Uuid,
    pub tenant_id: String,
    pub mount_id: String,
    pub state: TxState,
    pub opened_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}
