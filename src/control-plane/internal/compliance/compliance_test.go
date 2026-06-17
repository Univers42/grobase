package compliance

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// buildSnapshot seals n section rows the SAME way Service.Collect does (SealHash
// over section + collected_at + payload), so a test can tamper a stored row and
// assert VerifySnapshot catches it at exactly that section. This mirrors the live
// seal path, which makes the test load-bearing rather than circular.
func buildSnapshot(t *testing.T) []EvidenceRow {
	t.Helper()
	at := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	rows := make([]EvidenceRow, 0, len(Sections()))
	for i, s := range Sections() {
		payload := json.RawMessage(`{"control_type":"` + s + `","n":` + itoa(i) + `}`)
		rows = append(rows, EvidenceRow{
			ID:          "id-" + s,
			SnapshotID:  "snap-1",
			CollectedAt: at,
			Section:     s,
			Payload:     payload,
			Hash:        SealHash(s, at, payload),
		})
	}
	return rows
}

func itoa(i int) string { return string(rune('0' + i%10)) }

func TestVerifySnapshot_Intact(t *testing.T) {
	rows := buildSnapshot(t)
	res := VerifySnapshot("snap-1", rows)
	if !res.Intact {
		t.Fatalf("freshly sealed snapshot must be intact, got broken_section=%s", res.BrokenSection)
	}
	if !res.Complete {
		t.Fatalf("snapshot with all sections must be complete, missing=%v", res.Missing)
	}
	if res.Count != len(Sections()) {
		t.Fatalf("expected count=%d (one row per canonical section), got %d", len(Sections()), res.Count)
	}
}

// THE load-bearing test: tamper a STORED row's payload (as a DB-level tamperer
// would) WITHOUT recomputing its hash. VerifySnapshot must report INTACT=false
// at exactly that section. A vacuous verifier that always says intact fails this.
func TestVerifySnapshot_TamperedPayload(t *testing.T) {
	rows := buildSnapshot(t)
	rows[1].Payload = json.RawMessage(`{"control_type":"access","tampered":true}`)
	res := VerifySnapshot("snap-1", rows)
	if res.Intact {
		t.Fatal("tampered payload must break the seal — vacuous verify rejected")
	}
	if res.BrokenSection != SectionAccess {
		t.Fatalf("expected break at section=access, got %s", res.BrokenSection)
	}
}

// Tampering the section label (e.g. relabeling a row) must also break the seal.
func TestVerifySnapshot_TamperedSection(t *testing.T) {
	rows := buildSnapshot(t)
	rows[0].Section = SectionChangeMgmt // relabel ci -> change_mgmt, leave stale hash
	res := VerifySnapshot("snap-1", rows)
	if res.Intact {
		t.Fatal("relabeled section must break the seal")
	}
}

// A missing section must be reported incomplete even if the present rows verify.
func TestVerifySnapshot_Incomplete(t *testing.T) {
	full := buildSnapshot(t)
	sections := Sections()
	dropped := sections[len(sections)-1] // drop the last canonical section
	rows := full[:len(full)-1]
	res := VerifySnapshot("snap-1", rows)
	if !res.Intact {
		t.Fatalf("present rows still seal intact, got broken=%s", res.BrokenSection)
	}
	if res.Complete {
		t.Fatalf("a snapshot missing %s must be incomplete", dropped)
	}
	if len(res.Missing) != 1 || res.Missing[0] != dropped {
		t.Fatalf("expected missing=[%s], got %v", dropped, res.Missing)
	}
}

// Key order in a payload must not change the seal (canonicalJSON), but a real
// value change must.
func TestSealHash_PayloadKeyOrderStable(t *testing.T) {
	at := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	h1 := SealHash("ci", at, []byte(`{"x":1,"y":2}`))
	h2 := SealHash("ci", at, []byte(`{"y":2,"x":1}`))
	if h1 != h2 {
		t.Fatalf("key order must not change the seal: %s != %s", h1, h2)
	}
	if h1 == SealHash("ci", at, []byte(`{"x":1,"y":3}`)) {
		t.Fatal("a payload value change must change the seal")
	}
}

// Microsecond truncation: a nanosecond-precision time and its µs-floor must seal
// identically (postgres timestamptz round-trips at µs).
func TestSealHash_MicrosecondStable(t *testing.T) {
	ns := time.Date(2026, 6, 15, 12, 0, 0, 123456789, time.UTC)
	us := ns.Truncate(time.Microsecond)
	if SealHash("ci", ns, []byte(`{}`)) != SealHash("ci", us, []byte(`{}`)) {
		t.Fatal("ns and its µs-floor must seal identically (pgx floors ns->µs)")
	}
}

// ── collector reality test: a gate WITHOUT a PASS marker is recorded passing:false ──

// fakeRows is a tiny in-memory pgxRows for the access-review query.
type fakeRows struct {
	data [][]any
	i    int
}

func (f *fakeRows) Next() bool { f.i++; return f.i <= len(f.data) }
func (f *fakeRows) Err() error { return nil }
func (f *fakeRows) Close()     {}
func (f *fakeRows) Scan(dest ...any) error {
	row := f.data[f.i-1]
	for j := range dest {
		*(dest[j].(*string)) = row[j].(string)
	}
	return nil
}

type fakeAccessDB struct{ rows [][]any }

func (d fakeAccessDB) AdminQuery(_ context.Context, _ string, _ ...any) (pgxRows, error) {
	return &fakeRows{data: d.rows}, nil
}

// THE collector reality test: seed a gates dir with one PASSING gate (has the
// =PASS marker) and one FAILING gate (a stub without the marker). The CI section
// must record gates_passing=1, all_passing=false, and the failing gate as
// passing:false — proving the collector reflects REALITY, not a green stub.
func TestCollector_CISection_ReflectsFailingControl(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "m200-good.sh"),
		"#!/usr/bin/env bash\n"+`log_event GATE --gate "m200=PASS" --outcome pass`+"\n")
	// A stub gate: no PASS marker -> must be recorded passing:false.
	writeFile(t, filepath.Join(dir, "m201-stub.sh"),
		"#!/usr/bin/env bash\necho 'not implemented'\nexit 0\n")

	c := &Collector{db: fakeAccessDB{}, gatesDir: dir, now: func() time.Time { return time.Unix(0, 0).UTC() }}
	raw, err := c.collectCI()
	if err != nil {
		t.Fatalf("collectCI: %v", err)
	}
	var ci struct {
		GatesTotal   int  `json:"gates_total"`
		GatesPassing int  `json:"gates_passing"`
		AllPassing   bool `json:"all_passing"`
		Gates        []struct {
			Gate    string `json:"gate"`
			Passing bool   `json:"passing"`
		} `json:"gates"`
	}
	if err := json.Unmarshal(raw, &ci); err != nil {
		t.Fatalf("unmarshal ci payload: %v", err)
	}
	if ci.GatesTotal != 2 {
		t.Fatalf("expected 2 gates, got %d", ci.GatesTotal)
	}
	if ci.GatesPassing != 1 {
		t.Fatalf("expected exactly 1 passing gate (the stub must be failing), got %d", ci.GatesPassing)
	}
	if ci.AllPassing {
		t.Fatal("all_passing must be false when a stub gate lacks its PASS marker — collector must not report vacuous green")
	}
	for _, g := range ci.Gates {
		if g.Gate == "m201" && g.Passing {
			t.Fatal("the stub gate m201 must be recorded passing:false (reality), not green")
		}
		if g.Gate == "m200" && !g.Passing {
			t.Fatal("the real gate m200 (with =PASS marker) must be recorded passing:true")
		}
	}
}

// The change-mgmt section must reflect the actual commit trail it is given, and
// be honest ("trail_available":false) when no trail file is configured.
func TestCollector_ChangeMgmt_ReflectsTrail(t *testing.T) {
	// no trail configured -> honest empty, not fabricated green.
	c := &Collector{gitLogPath: ""}
	raw, err := c.collectChangeMgmt()
	if err != nil {
		t.Fatalf("collectChangeMgmt empty: %v", err)
	}
	if got := jsonField(t, raw, "trail_available"); got != false {
		t.Fatalf("no trail file must report trail_available=false, got %v", got)
	}

	// with a trail file -> the commits + authors are recorded.
	dir := t.TempDir()
	logp := filepath.Join(dir, "gitlog.txt")
	writeFile(t, logp, "abc123|Alice|feat: add thing\ndef456|Bob|fix: bug\n")
	c2 := &Collector{gitLogPath: logp}
	raw2, err := c2.collectChangeMgmt()
	if err != nil {
		t.Fatalf("collectChangeMgmt with trail: %v", err)
	}
	if got := jsonField(t, raw2, "trail_available"); got != true {
		t.Fatalf("a 2-commit trail must report trail_available=true, got %v", got)
	}
	if got := jsonField(t, raw2, "commits_total"); got != float64(2) {
		t.Fatalf("expected commits_total=2, got %v", got)
	}
}

// The access section must surface evidence_is_service_only=false when the
// access review observes authenticated holding SELECT on compliance_evidence —
// i.e. it reflects a REAL misconfiguration, not a hardcoded pass.
func TestCollector_Access_DetectsAuthenticatedLeak(t *testing.T) {
	// Good posture: authenticated has no grant on compliance_evidence.
	good := &Collector{db: fakeAccessDB{rows: [][]any{{"service_role", "compliance_evidence", "SELECT"}}}}
	raw, err := good.collectAccess(context.Background())
	if err != nil {
		t.Fatalf("collectAccess good: %v", err)
	}
	if got := jsonField(t, raw, "evidence_is_service_only"); got != true {
		t.Fatalf("service-only posture must report evidence_is_service_only=true, got %v", got)
	}
	// Bad posture: authenticated CAN read compliance_evidence -> must be flagged.
	bad := &Collector{db: fakeAccessDB{rows: [][]any{{"authenticated", "compliance_evidence", "SELECT"}}}}
	raw2, err := bad.collectAccess(context.Background())
	if err != nil {
		t.Fatalf("collectAccess bad: %v", err)
	}
	if got := jsonField(t, raw2, "evidence_is_service_only"); got != false {
		t.Fatalf("a real authenticated-can-read leak must report evidence_is_service_only=false, got %v", got)
	}
}

// fakeEnv builds a getenv func over a fixed map (unset keys -> "").
func fakeEnv(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

// The gdpr_rights section must reflect the OBSERVED route flags: a disabled
// control records enabled:false (never a vacuous green), and all_rights_available
// is true only when BOTH erase + export are observably on.
func TestCollector_GDPRRights_ReflectsFlags(t *testing.T) {
	// Both OFF (unset) -> disabled, not green.
	off := &Collector{getenv: fakeEnv(nil)}
	raw, err := off.collectGDPRRights()
	if err != nil {
		t.Fatalf("collectGDPRRights off: %v", err)
	}
	if got := jsonField(t, raw, "erase_enabled"); got != false {
		t.Fatalf("unset HARD_ERASE_ENABLED must record erase_enabled=false, got %v", got)
	}
	if got := jsonField(t, raw, "all_rights_available"); got != false {
		t.Fatalf("with both rights off, all_rights_available must be false, got %v", got)
	}
	// Both ON -> both enabled, all_rights_available true.
	on := &Collector{getenv: fakeEnv(map[string]string{
		"HARD_ERASE_ENABLED": "1", "TENANT_EXPORT_ENABLED": "true",
	})}
	raw2, err := on.collectGDPRRights()
	if err != nil {
		t.Fatalf("collectGDPRRights on: %v", err)
	}
	if got := jsonField(t, raw2, "erase_enabled"); got != true {
		t.Fatalf("HARD_ERASE_ENABLED=1 must record erase_enabled=true, got %v", got)
	}
	if got := jsonField(t, raw2, "export_enabled"); got != true {
		t.Fatalf("TENANT_EXPORT_ENABLED=true must record export_enabled=true, got %v", got)
	}
	if got := jsonField(t, raw2, "all_rights_available"); got != true {
		t.Fatalf("both rights on must record all_rights_available=true, got %v", got)
	}
}

// The crypto_posture section must reflect CMEK_ENABLED + SECURITY_MODE as
// observed — a disabled control reads cmek_enabled:false.
func TestCollector_CryptoPosture_ReflectsEnv(t *testing.T) {
	off := &Collector{getenv: fakeEnv(nil)}
	raw, err := off.collectCryptoPosture()
	if err != nil {
		t.Fatalf("collectCryptoPosture off: %v", err)
	}
	if got := jsonField(t, raw, "cmek_enabled"); got != false {
		t.Fatalf("unset CMEK_ENABLED must record cmek_enabled=false, got %v", got)
	}
	if got := jsonField(t, raw, "security_mode_set"); got != false {
		t.Fatalf("unset SECURITY_MODE must record security_mode_set=false, got %v", got)
	}
	on := &Collector{getenv: fakeEnv(map[string]string{
		"CMEK_ENABLED": "on", "SECURITY_MODE": "strict",
	})}
	raw2, err := on.collectCryptoPosture()
	if err != nil {
		t.Fatalf("collectCryptoPosture on: %v", err)
	}
	if got := jsonField(t, raw2, "cmek_enabled"); got != true {
		t.Fatalf("CMEK_ENABLED=on must record cmek_enabled=true, got %v", got)
	}
	if got := jsonField(t, raw2, "security_mode"); got != "strict" {
		t.Fatalf("SECURITY_MODE=strict must be recorded verbatim, got %v", got)
	}
}

// The backup_posture section is NON-VACUOUS: it always carries the static
// mechanism fact, but pitr_enabled/retention reflect REALITY (false/empty when
// unconfigured, set when configured).
func TestCollector_BackupPosture_ReflectsEnvButNonVacuous(t *testing.T) {
	off := &Collector{getenv: fakeEnv(nil)}
	raw, err := off.collectBackupPosture()
	if err != nil {
		t.Fatalf("collectBackupPosture off: %v", err)
	}
	if got := jsonField(t, raw, "pitr_enabled"); got != false {
		t.Fatalf("unset PG_BACKUP_PITR must record pitr_enabled=false, got %v", got)
	}
	if got := jsonField(t, raw, "retention_configured"); got != false {
		t.Fatalf("no retention env must record retention_configured=false, got %v", got)
	}
	// non-vacuous: the mechanism fact is always present.
	if got := jsonField(t, raw, "mechanism"); got == nil || got == "" {
		t.Fatalf("backup_posture must always carry a non-empty mechanism fact, got %v", got)
	}
	on := &Collector{getenv: fakeEnv(map[string]string{
		"PG_BACKUP_PITR": "true", "BACKUP_RETENTION": "30d",
	})}
	raw2, err := on.collectBackupPosture()
	if err != nil {
		t.Fatalf("collectBackupPosture on: %v", err)
	}
	if got := jsonField(t, raw2, "pitr_enabled"); got != true {
		t.Fatalf("PG_BACKUP_PITR=true must record pitr_enabled=true, got %v", got)
	}
	if got := jsonField(t, raw2, "retention"); got != "30d" {
		t.Fatalf("BACKUP_RETENTION=30d must be recorded, got %v", got)
	}
	if got := jsonField(t, raw2, "retention_configured"); got != true {
		t.Fatalf("a configured retention must record retention_configured=true, got %v", got)
	}
}

// Collect() must produce exactly one sealed-ready payload per canonical section
// (the full set), so a snapshot is COMPLETE — guarding the section count the
// m108 gate asserts. Each payload must be valid, sealable JSON.
func TestCollector_Collect_ProducesAllSections(t *testing.T) {
	c := &Collector{
		db:       fakeAccessDB{},
		gatesDir: t.TempDir(),
		getenv:   fakeEnv(nil),
		now:      func() time.Time { return time.Unix(0, 0).UTC() },
	}
	snap, err := c.Collect(context.Background())
	if err != nil {
		t.Fatalf("Collect: %v", err)
	}
	if len(snap.Sections) != len(Sections()) {
		t.Fatalf("Collect must produce %d sections (the canonical set), got %d", len(Sections()), len(snap.Sections))
	}
	got := map[string]bool{}
	for _, sp := range snap.Sections {
		got[sp.Section] = true
		if len(sp.Payload) == 0 {
			t.Fatalf("section %s has an empty payload", sp.Section)
		}
		// seal must not panic and must be deterministic over the payload.
		if SealHash(sp.Section, snap.CollectedAt, sp.Payload) == "" {
			t.Fatalf("section %s did not seal", sp.Section)
		}
	}
	for _, s := range Sections() {
		if !got[s] {
			t.Fatalf("Collect omitted canonical section %s", s)
		}
	}
}

// Tamper-detect for the NEW sections, mirroring the existing section tamper
// tests: a stored row sealed for gdpr_rights/crypto_posture/backup_posture, once
// its payload is mutated WITHOUT rehashing, must break the seal at exactly that
// section. A vacuous always-intact verify fails this.
func TestVerifySnapshot_TamperedNewSections(t *testing.T) {
	for _, sec := range []string{SectionGDPRRights, SectionCryptoPosture, SectionBackupPosture} {
		rows := buildSnapshot(t)
		// find the row for this section and tamper its payload.
		idx := -1
		for i := range rows {
			if rows[i].Section == sec {
				idx = i
				break
			}
		}
		if idx < 0 {
			t.Fatalf("buildSnapshot did not include section %s", sec)
		}
		rows[idx].Payload = json.RawMessage(`{"control_type":"` + sec + `","tampered":true}`)
		res := VerifySnapshot("snap-1", rows)
		if res.Intact {
			t.Fatalf("tampered %s payload must break the seal — vacuous verify rejected", sec)
		}
		if res.BrokenSection != sec {
			t.Fatalf("expected break at section=%s, got %s", sec, res.BrokenSection)
		}
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func jsonField(t *testing.T, raw json.RawMessage, key string) any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return m[key]
}
