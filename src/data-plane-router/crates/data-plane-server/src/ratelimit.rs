//! Per-tenant token-bucket rate limiting (Phase 4 tiering).
//!
//! The tenant's package tier sets `rps` (sustained refill rate) + `burst`
//! (bucket capacity); these arrive per request inside the mount's
//! `capability_overrides` (the tier mask the query-router stamps from the
//! key-verify response). The limiter therefore keys on the tenant in the
//! TRUSTED envelope, not on anything Kong or the proxy compute — so it survives
//! the Phase-7 TS bypass unchanged, and Kong's coarse per-IP limit stays as the
//! outer shell.
//!
//! A tenant with no limit (no mask, or `rps == 0`) is UNLIMITED — the parity
//! path for untiered tenants, so this is a no-op until packages are assigned.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::Value;

/// The pure token-bucket step, shared by the in-process limiter AND mirrored by
/// the Redis Lua script (B4-limiter) so both backends admit identically. Given
/// the current `tokens`, the seconds `elapsed` since last access, the refill
/// `rps` and bucket `burst`, returns `(new_tokens, admitted)`.
#[must_use]
pub fn refill_and_take(tokens: f64, elapsed: f64, rps: u32, burst: u32) -> (f64, bool) {
    let cap = f64::from(burst.max(1));
    let refilled = (tokens + elapsed.max(0.0) * f64::from(rps)).min(cap);
    if refilled >= 1.0 {
        (refilled - 1.0, true)
    } else {
        (refilled, false)
    }
}

struct Bucket {
    tokens: f64,
    last: Instant,
}

/// In-process token-bucket store keyed by `tenant_id`. Cheap: one `f64` +
/// `Instant` per active tenant, refilled lazily on access (no background timer
/// per tenant). The map is bounded by [`TenantRateLimiter::evict_idle`], called
/// from the same periodic task as the pool reaper.
#[derive(Default)]
pub struct TenantRateLimiter {
    buckets: Mutex<HashMap<String, Bucket>>,
}

impl TenantRateLimiter {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Try to admit one request for `tenant`. `rps` is the sustained refill rate
    /// (tokens/second), `burst` the bucket capacity. Returns `true` to admit,
    /// `false` to reject (→ 429). `rps == 0` means unlimited (parity).
    pub fn allow(&self, tenant: &str, rps: u32, burst: u32) -> bool {
        if rps == 0 {
            return true;
        }
        let cap = f64::from(burst.max(1));
        let now = Instant::now();
        let mut map = self.buckets.lock().expect("rate limiter poisoned");
        let bucket = map.entry(tenant.to_string()).or_insert_with(|| Bucket {
            tokens: cap,
            last: now,
        });
        // Lazy refill: add tokens for the elapsed time, capped at the burst size.
        let elapsed = now.duration_since(bucket.last).as_secs_f64();
        let (new_tokens, admitted) = refill_and_take(bucket.tokens, elapsed, rps, burst);
        bucket.tokens = new_tokens;
        bucket.last = now;
        admitted
    }

    /// Best-effort eviction of buckets untouched for longer than `idle`. Bounds
    /// the map under N-tenant fan-out. A full, idle bucket loses nothing by being
    /// dropped (it re-creates full on next access).
    pub fn evict_idle(&self, idle: Duration) {
        let now = Instant::now();
        let mut map = self.buckets.lock().expect("rate limiter poisoned");
        map.retain(|_, b| now.duration_since(b.last) < idle);
    }

    /// Number of tenant buckets currently tracked — the `/metrics` gauge the
    /// scale experiments watch (B3): growth without matching `evict_idle`
    /// shrinkage under N-tenant fan-out means the map is becoming the leak.
    #[must_use]
    pub fn tracked(&self) -> usize {
        self.buckets.lock().expect("rate limiter poisoned").len()
    }
}

/// B4-limiter: the rate-limit backend the server actually calls. The in-process
/// token bucket is the single-node fast path (sub-µs, zero network) and the
/// DEFAULT — selected unless `DATA_PLANE_RATELIMIT_BACKEND=redis`. The Redis
/// backend makes the limit AUTHORITATIVE across replicas (N instances otherwise
/// each admit the full per-tenant rate, so a 3-replica deploy lets a tenant
/// burst 3× its tier). `allow` is async so the Redis EVAL fits; the in-process
/// arm is sync work in an async wrapper (no runtime cost).
pub enum RateLimiter {
    InProcess(TenantRateLimiter),
    #[cfg(feature = "ratelimit-redis")]
    Redis(RedisRateLimiter),
}

impl RateLimiter {
    /// Build from `DATA_PLANE_RATELIMIT_BACKEND` (`memory` default | `redis`).
    /// The Redis URL comes from `DATA_PLANE_RATELIMIT_REDIS_URL` (falls back to
    /// `REDIS_URL`). An unknown/empty backend, or `redis` without the feature
    /// compiled, degrades to in-process (parity) — never a boot failure.
    #[must_use]
    pub fn from_env() -> Self {
        let backend = std::env::var("DATA_PLANE_RATELIMIT_BACKEND")
            .unwrap_or_default()
            .to_lowercase();
        #[cfg(feature = "ratelimit-redis")]
        if backend == "redis" {
            if let Ok(url) = std::env::var("DATA_PLANE_RATELIMIT_REDIS_URL")
                .or_else(|_| std::env::var("REDIS_URL"))
            {
                if !url.trim().is_empty() {
                    return Self::Redis(RedisRateLimiter::new(url));
                }
            }
            tracing::warn!("ratelimit backend=redis but no REDIS URL — using in-process");
        }
        let _ = backend;
        Self::InProcess(TenantRateLimiter::new())
    }

    /// Admit one request for `tenant`. `rps == 0` is unlimited (parity).
    pub async fn allow(&self, tenant: &str, rps: u32, burst: u32) -> bool {
        if rps == 0 {
            return true;
        }
        match self {
            Self::InProcess(rl) => rl.allow(tenant, rps, burst),
            #[cfg(feature = "ratelimit-redis")]
            Self::Redis(rl) => rl.allow(tenant, rps, burst).await,
        }
    }

    /// In-process: drop idle buckets. Redis: no-op (PEXPIRE reclaims keys).
    pub fn evict_idle(&self, idle: Duration) {
        match self {
            Self::InProcess(rl) => rl.evict_idle(idle),
            #[cfg(feature = "ratelimit-redis")]
            Self::Redis(_) => {}
        }
    }

    /// In-process: buckets tracked. Redis: 0 (state lives in Redis, not here).
    #[must_use]
    pub fn tracked(&self) -> usize {
        match self {
            Self::InProcess(rl) => rl.tracked(),
            #[cfg(feature = "ratelimit-redis")]
            Self::Redis(_) => 0,
        }
    }
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self::InProcess(TenantRateLimiter::new())
    }
}

/// The atomic Redis token bucket (B4-limiter). The Lua script mirrors
/// [`refill_and_take`] exactly so a tenant sees the same admit/deny whether the
/// limiter is in-process or Redis. State: one hash per tenant
/// (`drl:{tenant}` → `tokens`,`ts`), PEXPIRE'd so idle tenants self-evict.
///
/// **Fail-open:** if Redis is unreachable the limiter ADMITS (and logs) — the
/// rate limiter must never become an availability single-point-of-failure for
/// the data path. The same posture as Kong's outer per-IP shell still applying.
#[cfg(feature = "ratelimit-redis")]
pub struct RedisRateLimiter {
    url: String,
    conn: tokio::sync::OnceCell<redis_rl::aio::ConnectionManager>,
}

#[cfg(feature = "ratelimit-redis")]
impl RedisRateLimiter {
    // KEYS[1]=bucket; ARGV: rps, burst, now_ms. Returns 1 (admit) | 0 (deny).
    // Mirrors refill_and_take: refill by elapsed×rps capped at burst, take 1.
    const SCRIPT: &'static str = r"
        local rps = tonumber(ARGV[1])
        local burst = tonumber(ARGV[2])
        local now = tonumber(ARGV[3])
        local h = redis.call('HMGET', KEYS[1], 'tokens', 'ts')
        local tokens = tonumber(h[1])
        local ts = tonumber(h[2])
        if tokens == nil then tokens = burst; ts = now end
        local elapsed = math.max(0, now - ts) / 1000.0
        tokens = math.min(burst, tokens + elapsed * rps)
        local admit = 0
        if tokens >= 1 then tokens = tokens - 1; admit = 1 end
        redis.call('HMSET', KEYS[1], 'tokens', tokens, 'ts', now)
        redis.call('PEXPIRE', KEYS[1], 60000)
        return admit
    ";

    #[must_use]
    pub fn new(url: String) -> Self {
        Self {
            url,
            conn: tokio::sync::OnceCell::new(),
        }
    }

    async fn allow(&self, tenant: &str, rps: u32, burst: u32) -> bool {
        let mgr = self
            .conn
            .get_or_try_init(|| async {
                let client = redis_rl::Client::open(self.url.as_str())?;
                redis_rl::aio::ConnectionManager::new(client).await
            })
            .await;
        let Ok(mgr) = mgr else {
            tracing::warn!("ratelimit redis connect failed — admitting (fail-open)");
            return true;
        };
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let mut conn = mgr.clone();
        let res: redis_rl::RedisResult<i64> = redis_rl::cmd("EVAL")
            .arg(Self::SCRIPT)
            .arg(1)
            .arg(format!("drl:{tenant}"))
            .arg(rps)
            .arg(burst)
            .arg(now_ms)
            .query_async(&mut conn)
            .await;
        match res {
            Ok(v) => v == 1,
            Err(e) => {
                tracing::warn!("ratelimit redis EVAL failed — admitting (fail-open): {e}");
                true
            }
        }
    }
}

/// Extract `(rps, burst)` from a mount's tier mask (`capability_overrides`).
/// `burst` defaults to `2 × rps` when the mask omits it. Returns `None` (→
/// unlimited) when there is no mask or no `rps` key — the parity path.
#[must_use]
pub fn tier_rate(overrides: Option<&Value>) -> Option<(u32, u32)> {
    let obj = overrides?.as_object()?;
    let rps = u32::try_from(obj.get("rps")?.as_u64()?).ok()?;
    if rps == 0 {
        return None;
    }
    let burst = obj
        .get("burst")
        .and_then(Value::as_u64)
        .and_then(|b| u32::try_from(b).ok())
        .unwrap_or(rps.saturating_mul(2));
    Some((rps, burst))
}

/// G-QoS sliceA — extract the rows-per-query cap from a mount's tier mask
/// (`capability_overrides`). Mirrors [`tier_rate`]: returns `None` (→ no cap,
/// unlimited) when there is no mask, no `max_rows` key, or `max_rows == 0` —
/// the parity path. A resolved cap clamps the operation's `limit` before the
/// adapter runs, engine-agnostically.
#[must_use]
pub fn tier_max_rows(overrides: Option<&Value>) -> Option<u32> {
    let obj = overrides?.as_object()?;
    let cap = u32::try_from(obj.get("max_rows")?.as_u64()?).ok()?;
    if cap == 0 {
        return None;
    }
    Some(cap)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn unlimited_when_rps_zero() {
        let rl = TenantRateLimiter::new();
        for _ in 0..1000 {
            assert!(rl.allow("t1", 0, 0), "rps=0 is unlimited");
        }
    }

    #[test]
    fn burst_then_deny_then_refill() {
        let rl = TenantRateLimiter::new();
        // burst capacity = 5 → first 5 admit immediately, 6th denied.
        for i in 0..5 {
            assert!(rl.allow("t1", 100, 5), "burst token {i} should admit");
        }
        assert!(!rl.allow("t1", 100, 5), "6th request exceeds burst → deny");
        // After ~20ms at 100rps, ~2 tokens refill → admits again.
        std::thread::sleep(Duration::from_millis(30));
        assert!(rl.allow("t1", 100, 5), "refilled bucket admits after wait");
    }

    #[test]
    fn tenants_are_isolated() {
        let rl = TenantRateLimiter::new();
        for _ in 0..3 {
            assert!(rl.allow("a", 100, 3));
        }
        assert!(!rl.allow("a", 100, 3), "tenant a exhausted");
        // tenant b has its own bucket, unaffected.
        assert!(rl.allow("b", 100, 3), "tenant b independent");
    }

    #[test]
    fn evict_idle_drops_stale_buckets() {
        let rl = TenantRateLimiter::new();
        assert!(rl.allow("a", 100, 3));
        assert_eq!(rl.tracked(), 1);
        std::thread::sleep(Duration::from_millis(5));
        rl.evict_idle(Duration::from_millis(1));
        assert_eq!(rl.tracked(), 0, "stale bucket evicted");
    }

    #[test]
    fn refill_and_take_is_the_shared_bucket_math() {
        // Empty bucket, no elapsed time → deny, tokens unchanged.
        assert_eq!(refill_and_take(0.0, 0.0, 100, 5), (0.0, false));
        // One token present → admit, leaving 0.
        assert_eq!(refill_and_take(1.0, 0.0, 100, 5), (0.0, true));
        // Refill caps at burst: 1s elapsed @100rps but burst=5 → capped at 5,
        // take 1 → 4 left, admit.
        assert_eq!(refill_and_take(0.0, 1.0, 100, 5), (4.0, true));
        // Negative elapsed (clock skew) is clamped to 0 → no spurious refill.
        assert_eq!(refill_and_take(0.0, -10.0, 100, 5), (0.0, false));
    }

    #[test]
    fn default_backend_is_in_process() {
        assert!(matches!(RateLimiter::default(), RateLimiter::InProcess(_)));
    }

    #[test]
    fn tier_rate_parsing() {
        assert_eq!(tier_rate(None), None);
        assert_eq!(
            tier_rate(Some(&json!({ "aggregate": false }))),
            None,
            "no rps → unlimited"
        );
        assert_eq!(
            tier_rate(Some(&json!({ "rps": 0 }))),
            None,
            "rps 0 → unlimited"
        );
        assert_eq!(
            tier_rate(Some(&json!({ "rps": 20 }))),
            Some((20, 40)),
            "burst defaults 2x"
        );
        assert_eq!(
            tier_rate(Some(&json!({ "rps": 200, "burst": 250 }))),
            Some((200, 250))
        );
    }

    #[test]
    fn tier_max_rows_parsing() {
        // No mask / no key / 0 all mean "unlimited" (parity — no clamp).
        assert_eq!(tier_max_rows(None), None);
        assert_eq!(
            tier_max_rows(Some(&json!({ "rps": 20 }))),
            None,
            "no max_rows → unlimited"
        );
        assert_eq!(
            tier_max_rows(Some(&json!({ "max_rows": 0 }))),
            None,
            "max_rows 0 → unlimited"
        );
        assert_eq!(
            tier_max_rows(Some(&json!(42))),
            None,
            "non-object → unlimited"
        );
        // A present positive cap is returned verbatim.
        assert_eq!(
            tier_max_rows(Some(&json!({ "max_rows": 1000 }))),
            Some(1000)
        );
    }

    // C1/m51 — the multi-instance correctness proof. Two RedisRateLimiter on the
    // SAME redis model two data-plane replicas: they MUST draw from one shared
    // bucket per tenant, else a tenant bursts its tier once PER replica. Skips
    // (not fails) without a live REDIS_URL so unit CI stays hermetic; the m51
    // gate runs it networked to mini-baas-redis.
    #[cfg(feature = "ratelimit-redis")]
    #[tokio::test]
    async fn redis_backend_is_one_global_bucket_across_instances() {
        let Ok(url) = std::env::var("REDIS_URL") else {
            eprintln!("SKIP redis_backend_is_one_global_bucket_across_instances: REDIS_URL unset");
            return;
        };
        let a = RedisRateLimiter::new(url.clone());
        let b = RedisRateLimiter::new(url);
        // Unique tenant per run → no collision with a prior run's 60s-TTL bucket.
        let tenant = format!(
            "m51-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let (rps, burst) = (1u32, 5u32);
        // 20 fast requests alternating instances. Sharing one bucket → only the
        // burst (~5) admits globally; per-instance buckets would admit ~2×5=10.
        let mut admits = 0;
        for i in 0..20 {
            let rl = if i % 2 == 0 { &a } else { &b };
            if rl.allow(&tenant, rps, burst).await {
                admits += 1;
            }
        }
        assert!(
            admits >= 1 && admits <= burst as i32 + 1,
            "two instances on one redis admitted {admits}; expected ≈ burst {burst} \
             (a shared global bucket), not a per-replica multiple"
        );
    }
}
