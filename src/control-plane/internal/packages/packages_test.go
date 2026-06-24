/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   packages_test.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:51:52 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:53 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package packages

import "testing"

func u32p(v uint32) *uint32 { return &v }

// ceilingPro is a representative ceiling for the builder tests: multi-engine,
// aggregate+batch+transactions ON, rps 400, max_mounts 10, two addons, baseline
// security. (It mirrors the pro tier shape.)
func ceilingPro() Package {
	return Package{
		Label:   "Pro",
		Engines: []string{"postgresql", "sqlite", "mysql", "mongodb"},
		Capabilities: map[string]bool{
			"read": true, "write": true, "aggregate": true,
			"batch": true, "transactions": true, "schema_ddl": false,
		},
		Limits:       Limits{RPS: 400, Burst: 800, MaxRows: u32p(50000), Quota: &Quota{Period: "month", QueryCount: 10_000_000}},
		PoolPolicy:   PoolPolicy{MaxConn: 10, MaxMounts: 10},
		SecurityMode: "baseline",
		Addons:       []string{"realtime", "analytics"},
	}
}

// TestClampNarrowsNeverWidens proves every axis can only narrow, and that a
// custom that asks for MORE than the ceiling is clamped DOWN to the ceiling.
func TestClampNarrowsNeverWidens(t *testing.T) {
	ceil := ceilingPro()

	// (1) capability can be turned OFF freely, never ON past the ceiling.
	custom := Package{
		Capabilities: map[string]bool{
			"aggregate":  false, // OFF — honored (narrow)
			"schema_ddl": true,  // ON, but ceiling has it OFF — must clamp to false
		},
		Limits:     Limits{RPS: 250},                // below ceiling 400 — honored
		PoolPolicy: PoolPolicy{MaxMounts: 3},        // below 10 — honored
		Engines:    []string{"postgresql", "redis"}, // redis not in ceiling — dropped
		Addons:     []string{"realtime", "storage"}, // storage not in ceiling — dropped
	}
	got := Clamp(custom, ceil)
	if got.Capabilities["aggregate"] {
		t.Error("aggregate turned OFF by custom must stay OFF after clamp")
	}
	if got.Capabilities["schema_ddl"] {
		t.Error("schema_ddl ON in custom but OFF in ceiling MUST clamp to false (never widen past ceiling)")
	}
	if got.Limits.RPS != 250 {
		t.Errorf("rps below ceiling honored: got %d want 250", got.Limits.RPS)
	}
	if got.PoolPolicy.MaxMounts != 3 {
		t.Errorf("max_mounts below ceiling honored: got %d want 3", got.PoolPolicy.MaxMounts)
	}
	if hasStr(got.Engines, "redis") {
		t.Error("engine not in ceiling (redis) must be dropped by clamp")
	}
	if !hasStr(got.Engines, "postgresql") {
		t.Error("engine in both must survive clamp")
	}
	if hasStr(got.Addons, "storage") {
		t.Error("addon not in ceiling (storage) must be dropped by clamp")
	}

	// (2) over-ceiling numeric values are clamped DOWN (the resolve-time backstop:
	// a stale over-ceiling row written before a downgrade must never widen).
	over := Package{
		Limits:       Limits{RPS: 9999, Burst: 9999, MaxRows: u32p(999999), Quota: &Quota{QueryCount: 99_000_000}},
		PoolPolicy:   PoolPolicy{MaxConn: 99, MaxMounts: 99},
		Capabilities: map[string]bool{"aggregate": true}, // ON, ceiling ON — honored
	}
	g2 := Clamp(over, ceil)
	if g2.Limits.RPS != 400 || g2.Limits.Burst != 800 {
		t.Errorf("over-ceiling rps/burst must clamp to 400/800, got %d/%d", g2.Limits.RPS, g2.Limits.Burst)
	}
	if g2.Limits.MaxRows == nil || *g2.Limits.MaxRows != 50000 {
		t.Errorf("over-ceiling max_rows must clamp to 50000, got %v", g2.Limits.MaxRows)
	}
	if g2.Limits.Quota == nil || g2.Limits.Quota.QueryCount != 10_000_000 {
		t.Errorf("over-ceiling quota must clamp to 10M, got %v", g2.Limits.Quota)
	}
	if g2.PoolPolicy.MaxConn != 10 || g2.PoolPolicy.MaxMounts != 10 {
		t.Errorf("over-ceiling pool must clamp to 10/10, got %d/%d", g2.PoolPolicy.MaxConn, g2.PoolPolicy.MaxMounts)
	}
}

// TestClampInheritsOnEmpty proves an empty/zero custom inherits the ceiling
// (NOT "unlimited") so an unset field can never widen the cap.
func TestClampInheritsOnEmpty(t *testing.T) {
	ceil := ceilingPro()
	got := Clamp(Package{}, ceil) // wholly empty custom
	if got.Limits.RPS != 400 {
		t.Errorf("empty custom rps must inherit ceiling 400 (not 0/unlimited), got %d", got.Limits.RPS)
	}
	if got.PoolPolicy.MaxMounts != 10 {
		t.Errorf("empty custom max_mounts must inherit ceiling 10, got %d", got.PoolPolicy.MaxMounts)
	}
	if len(got.Engines) != len(ceil.Engines) {
		t.Errorf("empty custom engines must inherit ceiling (%d), got %d", len(ceil.Engines), len(got.Engines))
	}
}

// TestClampSecurityModeOnlyStricter proves security_mode can tighten but never
// loosen below the ceiling.
func TestClampSecurityModeOnlyStricter(t *testing.T) {
	baselineCeil := ceilingPro() // baseline
	// custom wants stricter (max) under a baseline ceiling → honored.
	g := Clamp(Package{SecurityMode: "max"}, baselineCeil)
	if g.SecurityMode != "max" {
		t.Errorf("stricter custom security_mode honored: got %q want max", g.SecurityMode)
	}
	// custom wants looser (baseline) under a MAX ceiling → clamped back to max.
	maxCeil := ceilingPro()
	maxCeil.SecurityMode = "max"
	g2 := Clamp(Package{SecurityMode: "baseline"}, maxCeil)
	if g2.SecurityMode != "max" {
		t.Errorf("looser custom security_mode must clamp to ceiling max, got %q", g2.SecurityMode)
	}
}

// TestValidateWithin covers each axis: a within-ceiling entitlement passes; an
// over-ceiling one fails with an axis-naming error.
func TestValidateWithin(t *testing.T) {
	ceil := ceilingPro()

	// within bounds on every axis → nil.
	ok := Package{
		Engines:      []string{"postgresql"},
		Capabilities: map[string]bool{"aggregate": true, "schema_ddl": false},
		Limits:       Limits{RPS: 100, Burst: 200, MaxRows: u32p(1000), Quota: &Quota{QueryCount: 1_000_000}},
		PoolPolicy:   PoolPolicy{MaxConn: 4, MaxMounts: 2},
		Addons:       []string{"realtime"},
		SecurityMode: "max", // stricter than baseline ceiling — allowed
	}
	if err := ValidateWithin(ok, ceil); err != nil {
		t.Errorf("within-ceiling entitlement must pass, got %v", err)
	}

	// each over-ceiling axis must error.
	axes := []struct {
		name string
		p    Package
	}{
		{"engine", Package{Engines: []string{"cassandra"}}},
		{"capability-ON-past-ceiling", Package{Capabilities: map[string]bool{"schema_ddl": true}}}, // ceiling OFF
		{"rps", Package{Limits: Limits{RPS: 9999}}},
		{"burst", Package{Limits: Limits{Burst: 9999}}},
		{"max_rows", Package{Limits: Limits{MaxRows: u32p(999999)}}},
		{"quota", Package{Limits: Limits{Quota: &Quota{QueryCount: 99_000_000}}}},
		{"max_conn", Package{PoolPolicy: PoolPolicy{MaxConn: 99}}},
		{"max_mounts", Package{PoolPolicy: PoolPolicy{MaxMounts: 99}}},
		{"addon", Package{Addons: []string{"storage"}}},
		{"security-looser", func() Package { c := Package{SecurityMode: "baseline"}; return c }()},
	}
	maxCeil := ceilingPro()
	maxCeil.SecurityMode = "max"
	for _, a := range axes {
		c := ceil
		if a.name == "security-looser" {
			c = maxCeil
		}
		if err := ValidateWithin(a.p, c); err == nil {
			t.Errorf("axis %q over ceiling must fail ValidateWithin, got nil", a.name)
		}
	}

	// turning a capability OFF that the ceiling has ON is WITHIN bounds.
	if err := ValidateWithin(Package{Capabilities: map[string]bool{"aggregate": false}}, ceil); err != nil {
		t.Errorf("turning a capability OFF must be within bounds, got %v", err)
	}
}

func hasStr(s []string, want string) bool {
	for _, v := range s {
		if v == want {
			return true
		}
	}
	return false
}

func TestLoadEmbedded(t *testing.T) {
	m, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	for _, want := range []string{"essential", "pro", "max"} {
		if _, ok := m.Packages[want]; !ok {
			t.Errorf("manifest missing package %q", want)
		}
	}
}

func TestForResolvesPlansAndAliases(t *testing.T) {
	m, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"nano":       "nano",      // v2 first-class package
		"basic":      "basic",     // direct package key
		"essential":  "essential", // direct package key
		"pro":        "pro",       // direct (also a legacy plan value)
		"max":        "max",       // direct
		"free":       "nano",      // v2 alias (was essential — pointed free at the $13/mo tier)
		"enterprise": "max",       // legacy alias
		"":           "essential", // empty → default
		"bogus":      "essential", // unknown → default
	}
	for plan, wantName := range cases {
		name, _ := m.For(plan)
		if name != wantName {
			t.Errorf("For(%q) = %q, want %q", plan, name, wantName)
		}
	}
}

func TestTierCapabilityLadder(t *testing.T) {
	m, _ := Load()
	// v2: basic is CRUD-only; essential differentiates by gaining aggregate
	// (a real capability, not just a higher rate — the v1 weakness was that
	// basic and essential were identical). pro adds batch + transactions +
	// multi-engine.
	_, basic := m.For("basic")
	if basic.Capabilities["aggregate"] || basic.Capabilities["batch"] {
		t.Error("basic is CRUD-only: no aggregate, no batch")
	}

	_, ess := m.For("essential")
	if !ess.Capabilities["aggregate"] {
		t.Error("essential MUST include aggregate (its differentiation from basic)")
	}
	if ess.Capabilities["batch"] || ess.Capabilities["transactions"] {
		t.Error("essential stops below pro: no batch/transactions")
	}
	if !ess.AllowsEngine("postgresql") || ess.AllowsEngine("mysql") {
		t.Error("essential allows postgresql, not mysql")
	}
	ov := ess.CapabilityOverrides()
	if ov["aggregate"] != true {
		t.Errorf("essential override aggregate=%v, want true", ov["aggregate"])
	}
	if ov["rps"] == nil || ov["burst"] == nil {
		t.Error("override must carry rps/burst for the token bucket")
	}

	_, pro := m.For("pro")
	if !pro.Capabilities["aggregate"] || !pro.Capabilities["transactions"] {
		t.Error("pro must include aggregate + transactions")
	}
	if !pro.AllowsEngine("mysql") || !pro.AllowsEngine("mongodb") {
		t.Error("pro must allow mysql + mongodb")
	}
}

func TestNanoTierExistsAsFreeShape(t *testing.T) {
	m, _ := Load()
	// v2 adds nano as a first-class package and maps free→nano (was free→
	// essential, which pointed the free plan at the ~$13/mo tier).
	_, nano := m.For("nano")
	if !nano.AllowsEngine("sqlite") || nano.AllowsEngine("postgresql") {
		t.Error("nano is the single-binary sqlite shape")
	}
	_, freed := m.For("free")
	if freed.Label != nano.Label {
		t.Errorf("free must resolve to nano, got %q", freed.Label)
	}
}

func TestMaxAllowsEverything(t *testing.T) {
	m, _ := Load()
	_, max := m.For("max")
	for _, eng := range []string{"postgresql", "mysql", "mariadb", "mongodb", "redis", "cockroachdb", "mssql", "http"} {
		if !max.AllowsEngine(eng) {
			t.Errorf("max must allow engine %q", eng)
		}
	}
	if max.PoolPolicy.MaxMounts < 50 {
		t.Errorf("max max_mounts = %d, want >= 50", max.PoolPolicy.MaxMounts)
	}
}
