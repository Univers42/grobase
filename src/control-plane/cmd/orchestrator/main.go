// Package main is the consolidated Go orchestrator (R2).
//
// The BaaS shipped six small Node orchestrators (email / newsletter / gdpr /
// session / log / outbox-relay), each paying a ~50 MiB Node runtime tax for a
// few hundred lines of glue. R2 folds them into ONE Go binary: each becomes a
// `SubService` mounted on a shared router with a shared background runtime, so
// six runtimes collapse to one (~10–15 MiB total) — the −359 MiB / essential
// $13→$6.5 win in the master plan.
//
// Sub-services are ported one at a time and run in SHADOW (parity-checked
// against the Node original) before the Node container is retired — the same
// shadow→parity→cutover discipline as the data plane. Today: `log`. Selected
// via `ORCHESTRATOR_SERVICES` (comma list; default = every ported service).
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/metering"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/emailsvc"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/envelope"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/gdprsvc"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/logsvc"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/newslettersvc"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/outboxrelay"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/sessionsvc"
	"github.com/dlesieur/mini-baas/control-plane/internal/packages"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/spendcap"
	"github.com/dlesieur/mini-baas/control-plane/internal/telemetryexport"
)

// SubService is one consolidated orchestrator module. Mount registers its HTTP
// routes; Run is its (optional) background loop. Both share the host's process,
// router, and lifecycle.
type SubService interface {
	Name() string
	Mount(mux *http.ServeMux)
	Run(ctx context.Context)
}

// initializer is an optional SubService capability: a one-time bootstrap (e.g.
// schema migration) run before the service is mounted, mirroring onModuleInit.
type initializer interface {
	Init(ctx context.Context) error
}

func main() {
	log := shared.NewLogger("orchestrator")

	cfg, err := shared.LoadConfig("ORCHESTRATOR")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	db, err := shared.NewPostgres(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Error("postgres connect failed", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	// quota-guard (Track-B B2) instance, so the dynamic builder (BUILDER_ENABLED)
	// resolver can be wired onto it before it is registered. Default (flag OFF) is
	// byte-parity: no resolver, the guard resolves the named tier via manifest.For
	// exactly as today.
	quotaGuard := metering.NewQuotaGuard(log, db)
	// Dynamic builder (BUILDER_ENABLED) — FLAG-GATED OFF = PARITY. When set, the
	// quota guard enforces against the EFFECTIVE per-tenant cap (custom entitlement
	// clamped to its ceiling) instead of the named tier's cap, matching what the
	// adapter-registry stamps. When unset (default) SetResolver is never called and
	// the over-quota decision is byte-identical to pre-builder. The whole guard is
	// ALSO gated by QUOTA_ENFORCEMENT (default OFF), so the builder bites only when
	// both flags are on. Reads public.tenant_entitlements (migration 062).
	if envBool("BUILDER_ENABLED") {
		manifest, mErr := packages.Load()
		if mErr != nil {
			log.Error("builder: package manifest load failed", "err", mErr)
			os.Exit(1)
		}
		quotaGuard.SetResolver(entitlements.NewResolver(manifest, entitlements.NewStore(db), true, log))
		log.Info("dynamic builder enabled for quota-guard (effective per-tenant cap) — BUILDER_ENABLED")
	}

	// The registry of ported sub-services. Adding one is a single line here
	// plus its package — no new binary, no new container.
	available := map[string]SubService{
		"log":          logsvc.New(log),
		"email":        emailsvc.New(log),
		"session":      sessionsvc.New(log, db),
		"newsletter":   newslettersvc.New(log, db),
		"gdpr":         gdprsvc.New(log, db),
		"outbox-relay": outboxrelay.New(log, db),
		// metering ingest (Track-B B1b): guarded internally by METERING_INGEST
		// (default OFF). Registered unconditionally is safe — when the flag is
		// off Init/Run are no-ops (no Redis subscribe, no consumer group), so the
		// orchestrator is byte-parity with today. The default-all selection thus
		// stays parity until the flag flips.
		"metering": metering.New(log, db),
		// quota enforcement (Track-B B2): guarded internally by QUOTA_ENFORCEMENT
		// (default OFF). Like metering, registered unconditionally is safe — when
		// the flag is off Init/Run are no-ops (no Redis, no evaluation, no
		// `quota:over` set written), so the orchestrator is byte-parity with today.
		"quota-guard": quotaGuard,
		// billing reporter (Track-B B3): guarded internally by BILLING_ENABLED
		// (default OFF). Like metering/quota, registered unconditionally is safe —
		// when the flag is off Init/Run are no-ops (no catalog, no Stripe client, no
		// meter event ever sent, billing_reported stays empty), so the orchestrator
		// is byte-parity with today. Consumes B1 tenant_usage + the 041
		// tenant_billing map; pushes per-window usage to Stripe billing meters.
		"billing": metering.NewBillingReporter(log, db),
		// spend-cap guard (Track-B B7.8): guarded internally by SPEND_CAPS_ENABLED
		// (default OFF). Like metering/quota/billing, registered unconditionally is
		// safe — when the flag is off Init/Run are no-ops (no Redis, no evaluation,
		// no `spend:over` set written, no alert fired), so the orchestrator is
		// byte-parity with today. Consumes B1 tenant_usage + the 045 tenant_budgets
		// table; publishes the over-budget set the data plane consults cheaply (the
		// same snapshot pattern as B2's quota:over) to HALT billable service before
		// a free-tier cost runaway, and fires a once-per-period 80% budget alert.
		"spend-cap": spendcap.NewGuard(log, db),
		// per-tenant telemetry export (Track-C C9): guarded internally by
		// TENANT_TELEMETRY_EXPORT_ENABLED (default OFF). Like metering/quota/billing/
		// spend-cap, registered unconditionally is safe — when the flag is off
		// Init/Run are no-ops (no tenant_telemetry_targets read, no outbound HTTP
		// connection ever opened, no cursor advanced), so the orchestrator is
		// byte-parity with today. Consumes B1 tenant_usage + the 046
		// tenant_telemetry_targets table; forwards each opted-in tenant's OWN
		// telemetry to that tenant's own customer-configured OTLP/log-drain collector,
		// attributed with tenant_id — cross-tenant export is impossible by
		// construction (each batch is scoped to one tenant_id and sent only to that
		// tenant's endpoint). The BYO-collector complement to B5 per-tenant obs.
		"telemetry-export": telemetryexport.New(log, db),
	}
	enabled := selectServices(available, os.Getenv("ORCHESTRATOR_SERVICES"))
	if len(enabled) == 0 {
		log.Error("no sub-services enabled (ORCHESTRATOR_SERVICES matched nothing)")
		os.Exit(1)
	}

	mux := shared.NewRouter("orchestrator", db)
	for _, svc := range enabled {
		// A sub-service may bootstrap state before serving (parity with the
		// Nest onModuleInit) — a failed Init is fatal, it cannot serve.
		if init, ok := svc.(initializer); ok {
			if err := init.Init(ctx); err != nil {
				log.Error("sub-service init failed", "service", svc.Name(), "err", err)
				os.Exit(1)
			}
		}
		svc.Mount(mux)
		go svc.Run(ctx)
		log.Info("sub-service mounted", "service", svc.Name())
	}

	srv := &http.Server{
		Addr: cfg.ListenAddr(),
		// envelope.Wrap mirrors the Node TransformInterceptor so a cutover is
		// transparent to clients (Track-2 A parity); WithMiddleware (logging,
		// request-id, metrics) wraps that so it still observes the real status.
		Handler:           shared.WithMiddleware(envelope.Wrap(mux), log),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		log.Info("listening", "addr", cfg.ListenAddr(), "mode", cfg.ProductMode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	log.Info("shutdown signal received")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
	}
	log.Info("stopped")
}

// selectServices returns the enabled sub-services in a stable order. An empty
// list means "all ported services" (the default).
func selectServices(available map[string]SubService, csv string) []SubService {
	if strings.TrimSpace(csv) == "" {
		out := make([]SubService, 0, len(available))
		for _, s := range available {
			out = append(out, s)
		}
		return out
	}
	var out []SubService
	for _, name := range strings.Split(csv, ",") {
		if s, ok := available[strings.TrimSpace(name)]; ok {
			out = append(out, s)
		}
	}
	return out
}

// envBool reads a truthy env flag (default OFF = parity), mirroring the
// tenant-control / adapter-registry main.go helpers.
func envBool(key string) bool {
	switch os.Getenv(key) {
	case "1", "true", "on", "TRUE", "True", "ON":
		return true
	default:
		return false
	}
}

func healthcheck(cfg shared.Config) int {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + cfg.Port + "/health/live")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}
