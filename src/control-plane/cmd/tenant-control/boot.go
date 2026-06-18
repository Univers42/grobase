package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// bootCtx carries the dependencies every Mount block needs, so each block is a
// short method instead of one 600-line main(). Field set is byte-identical to
// the locals main() previously held.
type bootCtx struct {
	log         *slog.Logger
	m           *observability.Metrics
	cfg         config.Config
	db          *pg.Postgres
	svc         *tenants.Service
	perm        provision.PermissionEngine
	reconciler  *provision.Reconciler
	jwtVerifier *tenants.JWTVerifier
	jwtSecret   string
	mux         *http.ServeMux
}

// setupClients wires the optional adapter-registry, data-plane, and
// permission-engine seams, then builds the declarative reconciler — verbatim the
// behavior of the corresponding main() blocks.
func (b *bootCtx) setupClients(ctx context.Context) {
	if arURL := os.Getenv("ADAPTER_REGISTRY_URL"); arURL != "" {
		b.svc.SetAdapterRegistry(tenants.NewAdapterRegistry(arURL, b.cfg.ServiceToken))
		b.log.Info("adapter-registry client enabled", "url", arURL)
	} else {
		b.log.Warn("ADAPTER_REGISTRY_URL not set — /v1/provision will not register mounts")
	}
	if dpURL := os.Getenv("RUST_DATA_PLANE_URL"); dpURL != "" {
		b.svc.SetDataPlane(tenants.NewDataPlane(dpURL, b.cfg.ServiceToken))
		b.log.Info("data-plane client enabled", "url", dpURL)
	}
	permURL := os.Getenv("PERMISSION_ENGINE_URL")
	b.perm = provision.NewSQLBackend(b.db, permURL, b.cfg.ServiceToken)
	b.svc.SetPermissionEngine(b.perm)
	if permURL != "" {
		b.log.Info("permission-engine self-verify enabled", "url", permURL)
	} else {
		b.log.Warn("PERMISSION_ENGINE_URL not set — provision Decide() self-verify disabled (role/policy seeding still works via SQL)")
	}
	b.reconciler = b.svc.BuildReconciler(b.perm, b.log)
}

// setupJWT initializes the optional GoTrue JWT verifier; without a secret the
// /v1/tenants/me/bootstrap endpoint stays disabled (returns 501). An init error
// is fatal (same log + os.Exit(1) as the original main()).
func (b *bootCtx) setupJWT() {
	b.jwtSecret = envFirst("GOTRUE_JWT_SECRET", "JWT_SECRET")
	if b.jwtSecret == "" {
		b.log.Warn("no GOTRUE_JWT_SECRET/JWT_SECRET set — /v1/tenants/me/bootstrap disabled")
		return
	}
	v, err := tenants.NewJWTVerifier(b.jwtSecret, os.Getenv("GOTRUE_JWT_ISSUER"))
	if err != nil {
		b.log.Error("jwt verifier init failed", "err", err)
		os.Exit(1)
	}
	b.jwtVerifier = v
	b.log.Info("jwt verifier enabled", "issuer", os.Getenv("GOTRUE_JWT_ISSUER"))
}

// openDB connects Postgres and ensures the tenant schema — fatal on either error,
// preserving main()'s original log messages + os.Exit(1).
func (b *bootCtx) openDB(ctx context.Context) {
	b.db = pg.MustPostgres(ctx, b.cfg.DatabaseURL, b.log)
	b.svc = tenants.NewService(b.db, b.log)
	if err := b.svc.EnsureSchema(ctx); err != nil {
		b.log.Error("schema check failed", "err", err)
		os.Exit(1)
	}
}

// serve starts the HTTP server and blocks until ctx is done, then drains with a
// 10s graceful-shutdown deadline — verbatim main()'s original lifecycle.
func (b *bootCtx) serve(ctx context.Context, stop context.CancelFunc) {
	srv := &http.Server{
		Addr:              b.cfg.ListenAddr(),
		Handler:           httpx.WithMiddleware(b.mux, b.log, b.m),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		b.log.Info("listening", "addr", b.cfg.ListenAddr(), "mode", b.cfg.ProductMode)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			b.log.Error("server error", "err", err)
			stop()
		}
	}()
	<-ctx.Done()
	b.log.Info("shutdown signal received")
	httpx.GracefulShutdown(srv, b.log)
}
