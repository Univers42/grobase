//! Control-plane honor-set machinery (Track-B). A control-plane guard
//! periodically evaluates each tenant against some budget/policy and publishes a
//! SET of "denied" tenant ids to Redis; this module is the data plane's CHEAP
//! honor of that decision, reused VERBATIM for THREE distinct sets:
//!
//!   * `quota:over`       — B2 QuotaGuard: tenant over its tier usage quota → 402.
//!   * `spend:over`       — spend-cap guard (`internal/spendcap`, gate m89): tenant
//!     over its absolute spend cap → 402 (`spend_capped`).
//!   * `tenant:suspended` — abuse/KYC guard (`internal/abuseguard`, gate m90):
//!     tenant administratively suspended → 403 (`tenant_suspended`).
//!
//! For each set the data plane keeps:
//!
//!   * an in-memory snapshot ([`QuotaSet`]) of the listed tenant ids,
//!   * refreshed from Redis on the SAME periodic reaper tick the pool/limiter
//!     use (one `SMEMBERS` per refresh — NOT per request),
//!   * read on the hot path as a single `HashSet::contains` (no I/O).
//!
//! So a listed tenant is rejected without the request path ever doing a
//! synchronous DB or Redis read. The three sets share ONE [`QuotaSet`] /
//! [`QuotaRefresher`] type — only the SMEMBERS key differs (see
//! [`QuotaRefresher::new_for`]).
//!
//! **Flag-gated OFF = byte-parity.** When a set's flag is off (the default) its
//! snapshot is never built, its refresh is never scheduled, and its hot-path
//! check is skipped entirely (a `bool` short-circuit before any field access) —
//! the request path takes ZERO extra branches.
//!
//! **Fail-OPEN.** If Redis is unreachable a snapshot stays at its last value (or
//! empty at boot) and the refresh logs + retries next tick — enforcement must
//! never become an availability single-point-of-failure for the data path, the
//! same posture as the rate limiter's Redis backend. This applies IDENTICALLY to
//! all three sets: a Redis blip keeps the last snapshot, never halts the data
//! path.

use std::collections::HashSet;
use std::sync::RwLock;

/// The Redis SET key the control-plane QuotaGuard publishes over-quota tenant
/// ids to. FROZEN contract shared with `internal/metering/quotaguard.go`.
pub const QUOTA_OVER_SET: &str = "quota:over";

/// The Redis SET key the control-plane spend-cap guard publishes over-spend
/// tenant ids to. FROZEN contract shared with Go `internal/spendcap` (gate m89).
pub const SPEND_OVER_SET: &str = "spend:over";

/// The Redis SET key the control-plane abuse/KYC guard publishes administratively
/// suspended tenant ids to. FROZEN contract shared with Go `internal/abuseguard`
/// (gate m90).
pub const SUSPENDED_SET: &str = "tenant:suspended";

/// In-memory snapshot of the over-quota tenant ids. `contains` is the hot-path
/// check (a read-locked `HashSet` lookup, no I/O); `replace` swaps in a freshly
/// fetched set on the refresh tick. An empty set means "no tenant is over quota"
/// (the fail-open default — also what an absent Redis key yields).
#[derive(Default)]
pub struct QuotaSet {
    over: RwLock<HashSet<String>>,
}

impl QuotaSet {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Hot-path check: is this tenant currently over its quota? A read lock + a
    /// hash lookup, no allocation, no I/O. False for any tenant when the set is
    /// empty (fail-open / parity).
    #[must_use]
    pub fn is_over(&self, tenant: &str) -> bool {
        self.over
            .read()
            .map(|s| s.contains(tenant))
            .unwrap_or(false)
    }

    /// Swap in a freshly fetched over-quota set (called on the refresh tick).
    pub fn replace(&self, next: HashSet<String>) {
        if let Ok(mut s) = self.over.write() {
            *s = next;
        }
    }

    /// Number of over-quota tenants currently tracked — the `/metrics` gauge the
    /// enforcement story can watch.
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.over.read().map(|s| s.len()).unwrap_or(0)
    }
}

/// The refresher: a lazily-connected Redis client that `SMEMBERS <set_key>` on
/// each tick and swaps the result into the shared [`QuotaSet`]. Reuses the
/// `redis-rl` crate the rate limiter already compiles (only present under the
/// `ratelimit-redis` feature). On a build WITHOUT that feature the refresher is a
/// no-op shell, so honor-set enforcement is simply unavailable there (nano/one),
/// never a compile break.
///
/// The SMEMBERS key is parameterized ([`Self::new_for`]) so the SAME refresher
/// serves all three honor sets ([`QUOTA_OVER_SET`], [`SPEND_OVER_SET`],
/// [`SUSPENDED_SET`]) — only the key differs.
pub struct QuotaRefresher {
    #[cfg(feature = "ratelimit-redis")]
    url: String,
    /// The Redis SET key this refresher reads (`quota:over` / `spend:over` /
    /// `tenant:suspended`). Lets one type serve all three honor sets verbatim.
    #[cfg(feature = "ratelimit-redis")]
    set_key: &'static str,
    #[cfg(feature = "ratelimit-redis")]
    conn: tokio::sync::OnceCell<redis_rl::aio::ConnectionManager>,
}

impl QuotaRefresher {
    /// Build a refresher for the given Redis URL reading the quota-over set
    /// (`quota:over`). Back-compat shim over [`Self::new_for`] so existing B2
    /// call sites are untouched. An empty URL yields a refresher that never
    /// connects (it logs once and leaves the set empty = fail-open).
    #[must_use]
    pub fn new(url: String) -> Self {
        Self::new_for(url, QUOTA_OVER_SET)
    }

    /// Build a refresher for the given Redis URL reading the given SET key — the
    /// generalization that lets `quota:over`, `spend:over`, and
    /// `tenant:suspended` share ONE refresher type. An empty URL yields a
    /// refresher that never connects (logs once, leaves the set empty =
    /// fail-open). `_url`/`_set_key` are unused without the `ratelimit-redis`
    /// feature (the no-op shell).
    #[must_use]
    pub fn new_for(_url: String, _set_key: &'static str) -> Self {
        Self {
            #[cfg(feature = "ratelimit-redis")]
            url: _url,
            #[cfg(feature = "ratelimit-redis")]
            set_key: _set_key,
            #[cfg(feature = "ratelimit-redis")]
            conn: tokio::sync::OnceCell::new(),
        }
    }

    /// Fetch `SMEMBERS <set_key>` and swap it into `set`. Fail-OPEN: on any Redis
    /// error the previous snapshot is kept (the set is left unchanged) and a warn
    /// is logged — enforcement never becomes an availability SPOF (a Redis blip
    /// keeps the last snapshot, never halts the data path). Identical posture for
    /// all three honor sets.
    #[cfg(feature = "ratelimit-redis")]
    pub async fn refresh(&self, set: &QuotaSet) {
        if self.url.trim().is_empty() {
            return;
        }
        let mgr = self
            .conn
            .get_or_try_init(|| async {
                let client = redis_rl::Client::open(self.url.as_str())?;
                redis_rl::aio::ConnectionManager::new(client).await
            })
            .await;
        let Ok(mgr) = mgr else {
            tracing::warn!(
                set = self.set_key,
                "honor-set refresh: redis connect failed — keeping prior snapshot (fail-open)"
            );
            return;
        };
        let mut conn = mgr.clone();
        let res: redis_rl::RedisResult<Vec<String>> = redis_rl::cmd("SMEMBERS")
            .arg(self.set_key)
            .query_async(&mut conn)
            .await;
        match res {
            Ok(members) => {
                let next: HashSet<String> = members.into_iter().collect();
                let n = next.len();
                set.replace(next);
                tracing::debug!(
                    set = self.set_key,
                    listed_tenants = n,
                    "honor-set snapshot refreshed"
                );
            }
            Err(e) => {
                tracing::warn!(
                    set = self.set_key,
                    "honor-set refresh: SMEMBERS failed — keeping prior snapshot (fail-open): {e}"
                );
            }
        }
    }

    /// No-op refresh on builds without the `ratelimit-redis` feature (nano/one):
    /// honor-set enforcement is unavailable there, the set stays empty (parity).
    #[cfg(not(feature = "ratelimit-redis"))]
    pub async fn refresh(&self, _set: &QuotaSet) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_set_is_never_over() {
        let q = QuotaSet::new();
        assert!(
            !q.is_over("anyone"),
            "empty set → no tenant over quota (fail-open/parity)"
        );
        assert_eq!(q.tracked(), 0);
    }

    #[test]
    fn replace_then_membership() {
        let q = QuotaSet::new();
        let mut next = HashSet::new();
        next.insert("over-tenant".to_string());
        q.replace(next);
        assert!(
            q.is_over("over-tenant"),
            "tenant in the published set is over quota"
        );
        assert!(
            !q.is_over("under-tenant"),
            "tenant absent from the set is under quota"
        );
        assert_eq!(q.tracked(), 1);
    }

    #[test]
    fn replace_swaps_the_whole_set() {
        let q = QuotaSet::new();
        q.replace(["a".to_string()].into_iter().collect());
        assert!(q.is_over("a"));
        // A later publish that no longer lists "a" must clear it (under quota
        // again, e.g. period rollover) — replace is a SWAP, not a merge.
        q.replace(["b".to_string()].into_iter().collect());
        assert!(
            !q.is_over("a"),
            "prior over-quota tenant cleared by a new snapshot"
        );
        assert!(q.is_over("b"));
    }

    // The three honor sets share the SAME QuotaSet type — these mirror the quota
    // membership tests for the spend-cap and suspend sets, proving the generalized
    // snapshot behaves identically regardless of which control-plane set feeds it.
    #[test]
    fn spend_over_set_membership() {
        let s = QuotaSet::new();
        assert!(
            !s.is_over("anyone"),
            "empty spend:over set → no tenant capped (fail-open/parity)"
        );
        s.replace(["capped-tenant".to_string()].into_iter().collect());
        assert!(
            s.is_over("capped-tenant"),
            "tenant in spend:over is over its spend cap"
        );
        assert!(
            !s.is_over("ok-tenant"),
            "tenant absent from spend:over is under its spend cap"
        );
        assert_eq!(s.tracked(), 1);
    }

    #[test]
    fn suspended_set_membership() {
        let s = QuotaSet::new();
        assert!(
            !s.is_over("anyone"),
            "empty tenant:suspended set → no tenant suspended (fail-open/parity)"
        );
        s.replace(["bad-tenant".to_string()].into_iter().collect());
        assert!(
            s.is_over("bad-tenant"),
            "tenant in tenant:suspended is suspended"
        );
        assert!(
            !s.is_over("good-tenant"),
            "tenant absent from tenant:suspended is active"
        );
        // A later publish clearing it (e.g. KYC resolved) un-suspends — SWAP, not merge.
        s.replace(HashSet::new());
        assert!(
            !s.is_over("bad-tenant"),
            "lifted suspension cleared by a new snapshot"
        );
        assert_eq!(s.tracked(), 0);
    }

    // The three honor-set keys are DISTINCT frozen contracts — a mix-up would make
    // one guard's publishes silently honored by the wrong enforcement arm.
    #[test]
    fn honor_set_keys_are_distinct() {
        assert_eq!(QUOTA_OVER_SET, "quota:over");
        assert_eq!(SPEND_OVER_SET, "spend:over");
        assert_eq!(SUSPENDED_SET, "tenant:suspended");
        assert_ne!(QUOTA_OVER_SET, SPEND_OVER_SET);
        assert_ne!(QUOTA_OVER_SET, SUSPENDED_SET);
        assert_ne!(SPEND_OVER_SET, SUSPENDED_SET);
    }
}
