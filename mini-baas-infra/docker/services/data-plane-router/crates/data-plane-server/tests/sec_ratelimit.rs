//! Security: per-tenant token-bucket rate limiting blocks brute-force / key
//! spam. We exercise: burst-then-deny across many burst sizes; lazy refill
//! timing; `rps == 0` unlimited (parity); per-tenant bucket ISOLATION across
//! many tenants (one tenant exhausting its bucket cannot deny another);
//! `refill_and_take` boundary math (empty, exactly-1, cap clamp, NEGATIVE
//! elapsed clock-skew, huge elapsed); `tier_rate` / `tier_max_rows` parsing
//! edge cases; and bucket eviction.

use std::time::Duration;

use data_plane_server::ratelimit::{
    refill_and_take, tier_max_rows, tier_rate, TenantRateLimiter,
};
use serde_json::json;

// ── refill_and_take: the shared bucket math, at every boundary ──────────────

#[test]
fn refill_and_take_empty_bucket_no_time_denies() {
    // No tokens, no elapsed time → deny, tokens unchanged (no underflow).
    for (rps, burst) in [(1, 1), (10, 5), (100, 1000), (1, 0)] {
        let (tokens, admitted) = refill_and_take(0.0, 0.0, rps, burst);
        assert!(!admitted, "empty bucket must deny (rps={rps} burst={burst})");
        assert_eq!(tokens, 0.0, "no spurious tokens appear");
    }
}

#[test]
fn refill_and_take_exactly_one_token_admits_to_zero() {
    let (tokens, admitted) = refill_and_take(1.0, 0.0, 100, 5);
    assert!(admitted, "exactly one token admits");
    assert_eq!(tokens, 0.0, "spends down to exactly zero");
    // Just under one token → deny, no admit at the fractional boundary.
    let (t2, a2) = refill_and_take(0.999_999, 0.0, 100, 5);
    assert!(!a2, "0.999999 tokens must deny");
    assert!((t2 - 0.999_999).abs() < 1e-9, "tokens unchanged on deny");
}

#[test]
fn refill_and_take_caps_at_burst() {
    // 1s elapsed @100rps would add 100, but burst=5 clamps → 5, take 1 → 4 left.
    let (tokens, admitted) = refill_and_take(0.0, 1.0, 100, 5);
    assert!(admitted);
    assert_eq!(tokens, 4.0, "refill clamps to burst capacity");
    // A huge elapsed never overflows past burst.
    let (tokens, admitted) = refill_and_take(0.0, 1e9, 1000, 10);
    assert!(admitted);
    assert_eq!(tokens, 9.0, "huge elapsed still clamps to burst");
}

#[test]
fn refill_and_take_negative_elapsed_clock_skew_adds_nothing() {
    // A backwards clock (NTP step / VM migration) must not refill spuriously.
    for elapsed in [-0.001, -1.0, -1e9, f64::NEG_INFINITY] {
        let (tokens, admitted) = refill_and_take(0.0, elapsed, 100, 5);
        assert!(!admitted, "negative elapsed {elapsed} must not admit on an empty bucket");
        assert_eq!(tokens, 0.0, "negative elapsed adds zero tokens");
    }
    // With a partial token present, negative elapsed still doesn't push it over 1.
    let (_t, admitted) = refill_and_take(0.5, -10.0, 100, 5);
    assert!(!admitted, "0.5 token + clock skew still denies");
}

#[test]
fn refill_and_take_burst_zero_is_treated_as_capacity_one() {
    // burst.max(1): a burst of 0 still allows a single token to flow at the rate.
    let (tokens, admitted) = refill_and_take(0.0, 1.0, 10, 0);
    assert!(admitted, "burst 0 is clamped to capacity 1");
    assert_eq!(tokens, 0.0);
}

#[test]
fn refill_and_take_table_of_cases() {
    // (tokens, elapsed, rps, burst) -> (expected_tokens, expected_admit)
    let cases: &[(f64, f64, u32, u32, f64, bool)] = &[
        (5.0, 0.0, 10, 5, 4.0, true),    // full bucket admits, 4 left
        (0.0, 0.5, 10, 5, 4.0, true),    // 0.5s@10rps=5, clamp 5, take 1 -> 4
        (0.0, 0.05, 10, 5, 0.5, false),  // 0.05s@10rps=0.5 -> below 1, deny
        (2.0, 0.0, 10, 5, 1.0, true),    // 2 tokens, take 1 -> 1
        (0.0, 0.0, 0, 5, 0.0, false),    // rps 0 path NOT short-circuited here: no refill, deny
        (10.0, 0.0, 10, 5, 4.0, true),   // over-cap input clamps then takes
    ];
    for &(tokens, elapsed, rps, burst, exp_tokens, exp_admit) in cases {
        let (got_tokens, got_admit) = refill_and_take(tokens, elapsed, rps, burst);
        assert_eq!(got_admit, exp_admit, "admit for {tokens},{elapsed},{rps},{burst}");
        assert!(
            (got_tokens - exp_tokens).abs() < 1e-9,
            "tokens for {tokens},{elapsed},{rps},{burst}: got {got_tokens}, want {exp_tokens}"
        );
    }
}

// ── TenantRateLimiter: burst-then-deny across many burst sizes ──────────────

#[test]
fn burst_then_deny_across_many_burst_sizes() {
    for burst in [1u32, 2, 3, 5, 8, 13, 20, 50, 100] {
        let rl = TenantRateLimiter::new();
        // The first `burst` requests admit immediately (rps high so refill within
        // the loop is negligible but present — assert at least burst admit).
        let mut admits = 0;
        for _ in 0..burst {
            if rl.allow("t", 1, burst) {
                admits += 1;
            }
        }
        assert_eq!(admits, burst, "burst={burst}: first {burst} requests admit");
        // The next request (rps=1, so ~no refill in microseconds) is denied.
        assert!(
            !rl.allow("t", 1, burst),
            "burst={burst}: request {} exceeds the bucket -> deny",
            burst + 1
        );
    }
}

#[test]
fn refill_admits_again_after_waiting() {
    let rl = TenantRateLimiter::new();
    // Exhaust a burst of 5 at 100 rps.
    for _ in 0..5 {
        assert!(rl.allow("t", 100, 5));
    }
    assert!(!rl.allow("t", 100, 5), "exhausted");
    // After ~30ms at 100rps, ~3 tokens refill → admits again.
    std::thread::sleep(Duration::from_millis(30));
    assert!(rl.allow("t", 100, 5), "refilled bucket admits after the wait");
}

#[test]
fn rps_zero_is_unlimited_for_any_burst() {
    let rl = TenantRateLimiter::new();
    for burst in [0u32, 1, 5, 100] {
        for _ in 0..500 {
            assert!(rl.allow("unlimited", 0, burst), "rps=0 is unlimited (burst={burst})");
        }
    }
    // An unlimited tenant should not even allocate a bucket (rps==0 short-circuit).
    assert_eq!(rl.tracked(), 0, "rps=0 never creates a bucket");
}

// ── per-tenant bucket ISOLATION across many tenants ─────────────────────────

#[test]
fn tenants_are_isolated_one_exhausted_does_not_deny_another() {
    let rl = TenantRateLimiter::new();
    let tenants: Vec<String> = (0..50).map(|i| format!("tenant-{i}")).collect();
    // Each tenant gets its own burst of 3 at rps=1.
    for t in &tenants {
        for _ in 0..3 {
            assert!(rl.allow(t, 1, 3), "{t} within its own burst");
        }
        assert!(!rl.allow(t, 1, 3), "{t} exhausts its OWN bucket");
    }
    // Now every tenant is exhausted independently — none of them admit (proving
    // the buckets did not share state), and exactly 50 buckets are tracked.
    for t in &tenants {
        assert!(!rl.allow(t, 1, 3), "{t} stays exhausted (independent bucket)");
    }
    assert_eq!(rl.tracked(), tenants.len(), "one bucket per distinct tenant");
}

#[test]
fn one_tenant_spamming_keys_cannot_starve_neighbours() {
    // Brute-force scenario: a noisy tenant hammers the limiter while a quiet
    // neighbour makes a few requests — the neighbour must always be admitted.
    let rl = TenantRateLimiter::new();
    // Noisy tenant burns through its burst of 5 and is denied thereafter.
    for _ in 0..200 {
        let _ = rl.allow("attacker", 5, 5);
    }
    assert!(!rl.allow("attacker", 5, 5), "attacker is rate-limited");
    // Victim's first 10 (burst) requests still go through, unaffected.
    let mut victim_admits = 0;
    for _ in 0..10 {
        if rl.allow("victim", 100, 10) {
            victim_admits += 1;
        }
    }
    assert_eq!(victim_admits, 10, "the victim's bucket is untouched by the attacker");
}

#[test]
fn distinct_tenant_strings_are_distinct_buckets() {
    // Tenant identity is the trusted envelope value, taken verbatim — even
    // weird/injection-looking strings get their own isolated bucket, never
    // collapsed together.
    let rl = TenantRateLimiter::new();
    let ids = ["a", "A", "a ", " a", "a;b", "a' OR '1", "../etc", "🔥", "a\0b"];
    for id in ids {
        assert!(rl.allow(id, 1, 1), "{id:?} first request admits");
        assert!(!rl.allow(id, 1, 1), "{id:?} second request denied (own burst=1)");
    }
    assert_eq!(rl.tracked(), ids.len(), "each distinct string is its own bucket");
}

// ── eviction: idle buckets are reclaimed; active ones survive ───────────────

#[test]
fn evict_idle_drops_stale_buckets_only() {
    let rl = TenantRateLimiter::new();
    assert!(rl.allow("a", 100, 3));
    assert!(rl.allow("b", 100, 3));
    assert_eq!(rl.tracked(), 2);
    std::thread::sleep(Duration::from_millis(10));
    // Touch "b" again so it is no longer idle.
    assert!(rl.allow("b", 100, 3));
    rl.evict_idle(Duration::from_millis(5));
    assert_eq!(rl.tracked(), 1, "only the idle bucket (a) is evicted");
    // Evicting with a huge idle window keeps everything.
    rl.evict_idle(Duration::from_secs(3600));
    assert_eq!(rl.tracked(), 1, "fresh bucket survives a long idle window");
}

#[test]
fn evicted_bucket_recreates_full() {
    let rl = TenantRateLimiter::new();
    for _ in 0..3 {
        assert!(rl.allow("a", 100, 3));
    }
    assert!(!rl.allow("a", 100, 3), "exhausted before eviction");
    std::thread::sleep(Duration::from_millis(5));
    rl.evict_idle(Duration::from_millis(1));
    assert_eq!(rl.tracked(), 0);
    // Re-creating the bucket starts full again (a full idle bucket loses nothing).
    assert!(rl.allow("a", 100, 3), "re-created bucket starts full");
}

// ── tier_rate parsing edge cases ────────────────────────────────────────────

#[test]
fn tier_rate_none_and_no_rps_are_unlimited() {
    assert_eq!(tier_rate(None), None);
    assert_eq!(tier_rate(Some(&json!({}))), None, "empty object -> no rps -> unlimited");
    assert_eq!(tier_rate(Some(&json!({ "aggregate": false }))), None, "no rps key");
    assert_eq!(tier_rate(Some(&json!({ "rps": 0 }))), None, "rps 0 -> unlimited");
}

#[test]
fn tier_rate_burst_defaults_to_twice_rps() {
    assert_eq!(tier_rate(Some(&json!({ "rps": 20 }))), Some((20, 40)));
    assert_eq!(tier_rate(Some(&json!({ "rps": 1 }))), Some((1, 2)));
    assert_eq!(tier_rate(Some(&json!({ "rps": 1000 }))), Some((1000, 2000)));
    // Explicit burst overrides the default.
    assert_eq!(tier_rate(Some(&json!({ "rps": 200, "burst": 250 }))), Some((200, 250)));
    assert_eq!(tier_rate(Some(&json!({ "rps": 10, "burst": 1 }))), Some((10, 1)));
}

#[test]
fn tier_rate_rejects_non_object_and_garbage_shapes() {
    for v in [json!(42), json!("x"), json!([1, 2]), json!(true), json!(null)] {
        assert_eq!(tier_rate(Some(&v)), None, "non-object {v:?} -> unlimited");
    }
    // Negative / non-integer / string rps are not valid u64 -> None.
    assert_eq!(tier_rate(Some(&json!({ "rps": -5 }))), None, "negative rps -> None");
    assert_eq!(tier_rate(Some(&json!({ "rps": "20" }))), None, "string rps -> None");
    assert_eq!(tier_rate(Some(&json!({ "rps": 1.5 }))), None, "float rps -> None");
}

#[test]
fn tier_rate_huge_rps_overflowing_u32_is_rejected() {
    // A value beyond u32::MAX cannot be a rate -> None (no panic, no wraparound).
    let huge = u64::from(u32::MAX) + 1;
    assert_eq!(tier_rate(Some(&json!({ "rps": huge }))), None);
    // u32::MAX itself is accepted; default burst saturates rather than overflowing.
    let max = u64::from(u32::MAX);
    assert_eq!(tier_rate(Some(&json!({ "rps": max }))), Some((u32::MAX, u32::MAX)));
}

// ── tier_max_rows parsing edge cases ────────────────────────────────────────

#[test]
fn tier_max_rows_parsing() {
    assert_eq!(tier_max_rows(None), None);
    assert_eq!(tier_max_rows(Some(&json!({}))), None, "no max_rows -> unlimited");
    assert_eq!(tier_max_rows(Some(&json!({ "rps": 20 }))), None, "no max_rows key");
    assert_eq!(tier_max_rows(Some(&json!({ "max_rows": 0 }))), None, "0 -> unlimited");
    assert_eq!(tier_max_rows(Some(&json!(42))), None, "non-object -> unlimited");
    assert_eq!(tier_max_rows(Some(&json!("x"))), None);
    assert_eq!(tier_max_rows(Some(&json!({ "max_rows": 1 }))), Some(1));
    assert_eq!(tier_max_rows(Some(&json!({ "max_rows": 1000 }))), Some(1000));
    // Out-of-u32-range / negative / float caps are rejected (no clamp surprise).
    assert_eq!(tier_max_rows(Some(&json!({ "max_rows": u64::from(u32::MAX) + 1 }))), None);
    assert_eq!(tier_max_rows(Some(&json!({ "max_rows": -1 }))), None);
    assert_eq!(tier_max_rows(Some(&json!({ "max_rows": 1.5 }))), None);
    // u32::MAX is accepted verbatim.
    assert_eq!(tier_max_rows(Some(&json!({ "max_rows": u64::from(u32::MAX) }))), Some(u32::MAX));
}
