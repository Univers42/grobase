// Package telemetryexport (Track-C C9) is the control-plane PER-TENANT TELEMETRY
// EXPORTER. It ships a SINGLE tenant's own telemetry — its usage metrics (the B1
// public.tenant_usage rollups) wrapped as structured log records — OUT to THAT
// tenant's customer-configured OTLP/HTTP or log-drain collector, attributed with
// tenant_id. It is the BYO-collector complement to B5 (per-tenant observability):
// B5 makes tenant_id a queryable LOG FIELD inside Grobase's own Loki/Grafana; C9
// forwards one tenant's telemetry to that tenant's external sink.
//
// It CONSUMES the B1 metering store (public.tenant_usage) and the C9 targets table
// (public.tenant_telemetry_targets, migration 046) — it does NOT re-meter and it
// invents no new metric. On a periodic tick it reads, FOR EACH opted-in + enabled
// tenant, ONLY that tenant's usage rows newer than that tenant's last_cursor, builds
// one OTLP/ndjson batch tagged with tenant_id, POSTs it to ONLY that tenant's
// endpoint, then advances that tenant's cursor. Each tenant's batch is built from a
// query scoped to its own tenant_id and is sent to its own endpoint, so a tenant's
// telemetry can NEVER reach another tenant's collector — cross-tenant isolation by
// construction (the load-bearing C9 invariant).
//
// FLAG-GATED OFF = PARITY: the exporter runs only when TENANT_TELEMETRY_EXPORT_ENABLED
// is truthy (default OFF). With the flag off Init connects nothing, Run returns
// immediately, NO row of tenant_telemetry_targets is ever read, NO outbound HTTP
// connection is ever opened, and no cursor is advanced — byte-identical to today
// (the same no-behavior-change posture as the metering consumer / QuotaGuard /
// spend-cap guard). A tenant with no targets row, or with enabled=false, is never
// exported — the safe default that keeps the baseline silent until a customer opts in.
package telemetryexport

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/jackc/pgx/v5"
)

// rows is the minimal row-cursor the exporter consumes — exactly the four methods
// it calls. Narrowing it (rather than depending on the full pgx.Rows) lets a unit
// test return a trivial fake without implementing the whole driver surface, the
// same pattern internal/metering's read handler uses (handler.go `rows`).
type rows interface {
	Next() bool
	Scan(dest ...any) error
	Err() error
	Close()
}

// exportDB is the minimal Postgres surface the exporter needs: list the enabled
// targets (AdminQuery), read a tenant's usage since its cursor (AdminQuery), and
// advance its cursor (AdminExec). The real *shared.Postgres is adapted to it via
// pgPool below (the exporter runs as the BYPASSRLS control-plane role, like the
// QuotaGuard and the spend-cap guard); a fake satisfies it in unit tests so the
// batch-building and per-tenant scoping are provable without a database.
type exportDB interface {
	AdminQuery(ctx context.Context, sql string, args ...any) (rows, error)
	AdminExec(ctx context.Context, sql string, args ...any) error
}

// pgPool adapts *shared.Postgres (whose AdminQuery returns the concrete pgx.Rows)
// to the narrow exportDB interface, mirroring internal/metering's pgPool adapter.
// A pgx.Rows already satisfies the narrow `rows` interface, so the adaptation is a
// pure type-narrowing — no behavior change.
type pgPool struct{ db *shared.Postgres }

func (p pgPool) AdminQuery(ctx context.Context, sql string, args ...any) (rows, error) {
	r, err := p.db.AdminQuery(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	return pgxRows{r}, nil
}

func (p pgPool) AdminExec(ctx context.Context, sql string, args ...any) error {
	return p.db.AdminExec(ctx, sql, args...)
}

// pgxRows narrows a pgx.Rows to the four methods the exporter uses.
type pgxRows struct{ pgx.Rows }

// sink delivers one tenant's serialized batch to its endpoint. The default is a
// real HTTP POST (httpSink); a fake captures deliveries in unit tests so the
// per-tenant routing is provable without a network. The contract is deliberately
// narrow — the exporter decides WHAT to send and to WHICH endpoint; the sink only
// performs the transport — so a test can intercept the (endpoint, tenant, body)
// triple and assert no cross-tenant leak.
type sink interface {
	// Deliver posts body to endpoint with the optional auth header. It returns an
	// error on a non-2xx response or a transport failure so the exporter can leave
	// the cursor unadvanced and retry that tenant next tick (at-least-once, never
	// silent data loss).
	Deliver(ctx context.Context, endpoint, authHeader, contentType string, body []byte) error
}

// Exporter reads each opted-in tenant's usage since its cursor and forwards it to
// that tenant's collector. Mirrors the spendcap.Guard / metering.QuotaGuard shape
// (Name/Mount/Init/Run) so the orchestrator registers it like any other
// sub-service.
type Exporter struct {
	log     *slog.Logger
	db      exportDB
	sink    sink
	enabled bool

	interval  time.Duration // how often to scan + forward
	batchRows int           // max usage rows shipped per tenant per tick (bounds one POST)
	timeout   time.Duration // per-delivery HTTP timeout
}

// New builds the exporter from env. TENANT_TELEMETRY_EXPORT_ENABLED gates
// everything; default OFF ⇒ parity. The exporter is engine-agnostic: it reads the
// engine-neutral public.tenant_usage aggregate (the same B1 truth every data-plane
// adapter feeds), so no per-engine wiring is needed.
func New(log *slog.Logger, db *shared.Postgres) *Exporter {
	return &Exporter{
		log:       log,
		db:        pgPool{db: db},
		sink:      &httpSink{client: &http.Client{}},
		enabled:   envBool("TENANT_TELEMETRY_EXPORT_ENABLED"),
		interval:  time.Duration(envInt("TENANT_TELEMETRY_EXPORT_INTERVAL_MS", 30_000)) * time.Millisecond,
		batchRows: envInt("TENANT_TELEMETRY_EXPORT_BATCH_ROWS", 500),
		timeout:   time.Duration(envInt("TENANT_TELEMETRY_EXPORT_TIMEOUT_MS", 5_000)) * time.Millisecond,
	}
}

// Name identifies the sub-service to the orchestrator.
func (e *Exporter) Name() string { return "telemetry-export" }

// Mount adds no HTTP routes — the exporter is a background forwarder.
func (e *Exporter) Mount(_ *http.ServeMux) {}

// SetSink overrides the default HTTP sink (used by the unit test to capture
// deliveries). Optional; called before Init.
func (e *Exporter) SetSink(s sink) {
	if s != nil {
		e.sink = s
	}
}

// Init validates config ONLY when enabled. Disabled ⇒ no connection, no read ⇒
// parity. The HTTP client carries the per-delivery timeout so a slow/hung customer
// collector can never wedge the export loop.
func (e *Exporter) Init(_ context.Context) error {
	if !e.enabled {
		e.log.Info("telemetry export disabled (TENANT_TELEMETRY_EXPORT_ENABLED off) — no export")
		return nil
	}
	if e.batchRows <= 0 {
		e.batchRows = 500
	}
	if e.timeout <= 0 {
		e.timeout = 5 * time.Second
	}
	if hs, ok := e.sink.(*httpSink); ok {
		hs.client.Timeout = e.timeout
	}
	e.log.Info("telemetry export enabled", "interval", e.interval,
		"batch_rows", e.batchRows, "timeout", e.timeout)
	return nil
}

// Run is the export loop: every interval, forward each opted-in tenant's new usage
// to its collector. Disabled ⇒ returns immediately ⇒ parity. Stops on ctx
// cancellation. An export error for one tenant is logged and that tenant's cursor
// is left unadvanced (retried next tick) — a transient blip on one tenant's
// collector never aborts the whole sweep nor wedges other tenants.
func (e *Exporter) Run(ctx context.Context) {
	if !e.enabled {
		return
	}
	e.exportOnce(ctx)
	t := time.NewTicker(e.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			e.exportOnce(ctx)
		}
	}
}

/* ─────── env helpers (mirroring spendcap / metering.consumer) ─────── */

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// envBool mirrors spendcap.envBool / the data-plane config.rs flag shape.
func envBool(key string) bool {
	switch os.Getenv(key) {
	case "1", "true", "on", "TRUE", "True", "ON":
		return true
	default:
		return false
	}
}
