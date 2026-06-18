package packages

// ─── Dynamic builder (BUILDER_ENABLED): Clamp + ValidateWithin ──────────────
//
// The dynamic builder lets a tenant COMPOSE its own effective package (narrowed
// capabilities, fewer mounts, a lower rps, a subset of engines, …) and lets an
// operator MINT a custom entitlement, all WITHIN a CEILING (the paid tier or an
// operator-set ceiling_plan). The ceiling is a PRIVILEGE BOUNDARY: a tenant may
// never grant itself MORE than the ceiling allows.
//
// Two pure functions enforce that boundary at two distinct points:
//
//   - ValidateWithin(custom, ceiling) — COMPOSE-time check. Returns a clean
//     error naming the FIRST axis a custom entitlement exceeds the ceiling, so a
//     PATCH /me/entitlements can refuse with a 403 BEFORE persisting. It is the
//     friendly gate.
//   - Clamp(custom, ceiling) — RESOLVE-time BACKSTOP. ALWAYS returns a package
//     that is ≤ the ceiling on every axis, silently lowering any field that
//     exceeds it. It NEVER trusts the stored row: a row written over the ceiling
//     (e.g. an operator set it high, then the tenant was downgraded) is clamped
//     on every single resolve. Clamp is the load-bearing one — even if
//     ValidateWithin were skipped, Clamp guarantees the stamp never exceeds the
//     ceiling.
//
// Clamp semantics (each axis, the ceiling is the cap):
//   - Label:        taken from custom if set, else the ceiling's (cosmetic).
//   - Engines:      custom ∩ ceiling (a custom engine not in the ceiling is
//     dropped — never added).
//   - Capabilities: a capability may be turned OFF freely, but turning it ON is
//     only honored when the ceiling also has it ON (false ceiling clamps to
//     false). Capabilities ABSENT from custom inherit the ceiling's value.
//   - rps/burst/max_rows/quota.query.count: min(custom, ceiling); a custom value
//     of 0/absent means "inherit the ceiling" (NOT "unlimited"), so a tenant can
//     never widen an unset field past the cap.
//   - max_conn/max_mounts: min(custom, ceiling), same inherit-on-0 rule.
//   - Addons:       custom ∩ ceiling.
//   - SecurityMode: only ALLOWED to become STRICTER (baseline→max). A custom
//     attempt to LOOSEN max→baseline is clamped back to the ceiling's mode.

// securityRank ranks security_mode from loosest to strictest. A higher rank is
// stricter. Unknown modes rank as baseline (the safe floor) so a typo never
// silently loosens enforcement.
func securityRank(mode string) int {
	switch mode {
	case "max":
		return 1
	default:
		return 0
	}
}

// Clamp returns an EFFECTIVE package that is ≤ ceiling on every axis. It is the
// resolve-time backstop: a custom entitlement is overlaid onto the ceiling but
// can only ever NARROW, never widen. See the block comment above for per-axis
// semantics. Pure (no I/O); the ceiling is treated as immutable.
func Clamp(custom, ceiling Package) Package {
	out := Package{
		Label:        ceiling.Label,
		Capabilities: mergeCapabilities(custom.Capabilities, ceiling.Capabilities),
		Limits:       clampLimits(custom.Limits, ceiling.Limits),
		PoolPolicy:   clampPoolPolicy(custom.PoolPolicy, ceiling.PoolPolicy),
		SecurityMode: clampSecurityMode(custom.SecurityMode, ceiling.SecurityMode),
		Engines:      intersectOrInherit(custom.Engines, ceiling.Engines),
		Addons:       intersectOrInherit(custom.Addons, ceiling.Addons),
	}
	if custom.Label != "" {
		out.Label = custom.Label
	}
	return out
}

// intersectOrInherit returns custom ∩ ceiling, preserving custom's order. An
// empty custom list inherits a copy of the ceiling list (no narrowing requested),
// so an entitlement that only caps rps does not accidentally strip every entry.
// Shared by the Engines and Addons axes (identical semantics).
func intersectOrInherit(custom, ceiling []string) []string {
	if len(custom) == 0 {
		return append([]string(nil), ceiling...)
	}
	allowed := make(map[string]bool, len(ceiling))
	for _, c := range ceiling {
		allowed[c] = true
	}
	var out []string
	for _, c := range custom {
		if allowed[c] {
			out = append(out, c)
		}
	}
	return out
}

// mergeCapabilities starts from the ceiling, then applies custom: a true is only
// honored when the ceiling is also true (clamp ON→OFF when over ceiling); OFF is
// always honored; keys absent from custom keep the ceiling's value.
func mergeCapabilities(custom, ceiling map[string]bool) map[string]bool {
	out := make(map[string]bool, len(ceiling))
	for k, v := range ceiling {
		out[k] = v
	}
	for k, v := range custom {
		out[k] = v && ceiling[k]
	}
	return out
}
