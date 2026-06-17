package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/entitlements"
	"github.com/dlesieur/mini-baas/control-plane/internal/metering"
	"github.com/dlesieur/mini-baas/control-plane/internal/orchestrator/emailsvc"
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

// newQuotaGuard builds the quota-guard (Track-B B2). The dynamic builder
// (BUILDER_ENABLED) — FLAG-GATED OFF = PARITY — wires an effective per-tenant
// cap resolver (custom entitlement clamped to its ceiling, reading
// public.tenant_entitlements / migration 062); when unset SetResolver is never
// called and the over-quota decision is byte-identical to pre-builder. The guard
// is ALSO gated by QUOTA_ENFORCEMENT (default OFF), so the builder bites only
// when both flags are on.
func newQuotaGuard(log *slog.Logger, db *shared.Postgres) *metering.QuotaGuard {
	guard := metering.NewQuotaGuard(log, db)
	if !shared.EnvBool("BUILDER_ENABLED") {
		return guard
	}
	manifest, err := packages.Load()
	if err != nil {
		log.Error("builder: package manifest load failed", "err", err)
		os.Exit(1)
	}
	guard.SetResolver(entitlements.NewResolver(manifest, entitlements.NewStore(db), true, log))
	log.Info("dynamic builder enabled for quota-guard (effective per-tenant cap) — BUILDER_ENABLED")
	return guard
}

// availableServices is the registry of ported sub-services. Adding one is a
// single line here plus its package — no new binary, no new container. The
// cloud sub-services (metering / quota-guard / billing / spend-cap /
// telemetry-export) are registered unconditionally but each is guarded
// internally by its own flag (METERING_INGEST / QUOTA_ENFORCEMENT /
// BILLING_ENABLED / SPEND_CAPS_ENABLED / TENANT_TELEMETRY_EXPORT_ENABLED, all
// default OFF) — when off, Init/Run are no-ops, so the orchestrator stays
// byte-parity with today and the default-all selection stays parity.
func availableServices(log *slog.Logger, db *shared.Postgres, quotaGuard *metering.QuotaGuard) map[string]SubService {
	return map[string]SubService{
		"log":              logsvc.New(log),
		"email":            emailsvc.New(log),
		"session":          sessionsvc.New(log, db),
		"newsletter":       newslettersvc.New(log, db),
		"gdpr":             gdprsvc.New(log, db),
		"outbox-relay":     outboxrelay.New(log, db),
		"metering":         metering.New(log, db),
		"quota-guard":      quotaGuard,
		"billing":          metering.NewBillingReporter(log, db),
		"spend-cap":        spendcap.NewGuard(log, db),
		"telemetry-export": telemetryexport.New(log, db),
	}
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

// mountServices initialises (parity with Nest onModuleInit — a failed Init is
// fatal), mounts, and starts the background loop of each enabled sub-service.
func mountServices(ctx context.Context, mux *http.ServeMux, enabled []SubService, log *slog.Logger) {
	for _, svc := range enabled {
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
}
