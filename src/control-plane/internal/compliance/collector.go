package compliance

import (
	"context"
	"encoding/json"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
)

// Collector snapshots the evidence sections from REALITY into the sealed store.
// It is deliberately NOT a "report compliant" stub: each section reads a real,
// observable source so a missing/failing/disabled control shows up as failing —
// the gate's load-bearing REJECT seeds exactly that and asserts it is recorded
// honestly (not green).
//
// Sources (all configurable so the gate can point them at controlled fixtures):
//   - CI/gate posture   ← the verify-gate script directory (SOC2_EVIDENCE_GATES_DIR,
//     default scripts/verify). Each mNN-*.sh is a CONTROL; a gate that emits a
//     `GATE ... mNN=PASS` marker is recorded passing:true, one that does not is
//     passing:false. PLUS the CI job names parsed from a CI workflow file
//     (SOC2_EVIDENCE_CI_WORKFLOW, optional).
//   - Access review     ← the LIVE postgres: role grants on the sensitive control
//     tables (information_schema.role_table_grants) — who can read/write what.
//   - Change mgmt       ← a git change-log file (SOC2_EVIDENCE_GITLOG): recent
//     commits + their authors as the change record. (git is not in the distroless
//     runtime, so the trail is provided as a snapshot file the deploy mounts.)
//   - GDPR rights       ← the process env flags (HARD_ERASE_ENABLED /
//     TENANT_EXPORT_ENABLED): whether the Art.17 erase + Art.20 export routes are
//     mounted. A disabled control records enabled:false — never "compliant".
//   - Crypto posture    ← the process env (CMEK_ENABLED, SECURITY_MODE): whether
//     CMEK/BYOK envelope is on and the transport security mode the process runs.
//   - Backup posture    ← the process env (PG_BACKUP_PITR / backup retention),
//     falling back to the static mechanism fact (m87 backup / m99 restore) so the
//     section is never vacuous even when no backup env is observable.
//
// The last three read ENV the running process sees (configurable so the gate can
// drive both an enabled and a disabled posture), recording the OBSERVED truth.
type Collector struct {
	db         accessDB
	gatesDir   string
	ciWorkflow string
	gitLogPath string
	getenv     func(string) string // env source (indirected so tests/gate drive it)
	now        func() time.Time
}

// accessDB is the minimal Postgres surface the access-review section needs.
// *pg.Postgres satisfies it; a fake satisfies it in unit tests.
type accessDB interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (pgxRows, error)
}

// pgxRows mirrors the subset of pgx.Rows the access query uses, so the package
// can be unit-tested with a fake without importing pgx into the test.
type pgxRows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
	Close()
}

// NewCollector builds a collector reading its sources from env (with the gate
// fixtures overriding for the test). All paths default to the in-repo layout but
// the gate points them at controlled fixtures so the load-bearing reject can
// seed a FAILING control.
func NewCollector(db accessDB) *Collector {
	gatesDir := config.EnvStr("SOC2_EVIDENCE_GATES_DIR", "scripts/verify")
	return &Collector{
		db:         db,
		gatesDir:   gatesDir,
		ciWorkflow: os.Getenv("SOC2_EVIDENCE_CI_WORKFLOW"),
		gitLogPath: os.Getenv("SOC2_EVIDENCE_GITLOG"),
		getenv:     os.Getenv,
		now:        func() time.Time { return time.Now().UTC() },
	}
}

// SectionPayload is the (section, payload) pair the store seals + persists.
type SectionPayload struct {
	Section string
	Payload json.RawMessage
}

// Snapshot is the sealed-ready section payloads for one collection run, stamped
// with the run instant. It carries len(Sections) sections (the canonical set).
type Snapshot struct {
	CollectedAt time.Time
	Sections    []SectionPayload
}

// env reads one environment variable through the collector's indirected source,
// tolerating a zero-value Collector (e.g. Collector{} in a unit test) by falling
// back to os.Getenv. Returns "" for an unset/empty var.
func (c *Collector) env(key string) string {
	if c.getenv != nil {
		return c.getenv(key)
	}
	return os.Getenv(key)
}

// Collect reads every section from its real source and returns the payloads to
// seal + persist. It returns the SAME collected_at for all of them so they
// belong to one snapshot. It never invents "compliant" — each section carries
// the observed truth (including failing/absent/disabled controls). Each entry
// in the collectors table pairs a canonical section with its collector, in the
// fixed canonical Sections order, so a freshly collected snapshot is complete.
func (c *Collector) Collect(ctx context.Context) (Snapshot, error) {
	at := c.now()
	collectors := []struct {
		section string
		fn      func() (json.RawMessage, error)
	}{
		{SectionCI, c.collectCI},
		{SectionAccess, func() (json.RawMessage, error) { return c.collectAccess(ctx) }},
		{SectionChangeMgmt, c.collectChangeMgmt},
		{SectionGDPRRights, c.collectGDPRRights},
		{SectionCryptoPosture, c.collectCryptoPosture},
		{SectionBackupPosture, c.collectBackupPosture},
	}
	sections := make([]SectionPayload, 0, len(collectors))
	for _, col := range collectors {
		payload, err := col.fn()
		if err != nil {
			return Snapshot{}, err
		}
		sections = append(sections, SectionPayload{Section: col.section, Payload: payload})
	}
	return Snapshot{CollectedAt: at, Sections: sections}, nil
}

// ───────────────────────── CI / gate posture ─────────────────────────────────
//
// The CI section's two regexes are compiled per call in collect_ci.go:
//   - gatePassRe `m([0-9]+)=PASS`   — a verify gate's self-attested PASS marker
//     (the gate-authored anchor; a script lacking it is recorded passing:false).
//   - gateFileRe `^m([0-9]+)-.*\.sh$` — extracts the milestone id from a gate
//     filename mNN-*.sh.
// Both run only during compliance EVIDENCE COLLECTION (a cold/admin path), so a
// per-call MustCompile is fine and keeps them out of package state.
