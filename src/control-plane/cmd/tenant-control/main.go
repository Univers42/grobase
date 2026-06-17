// Package main boots the tenant-control service.
//
// Owns:
//
//	POST /v1/tenants              create a tenant row
//	GET  /v1/tenants              list tenants (admin)
//	GET  /v1/tenants/:id          fetch (self or admin)
//	PATCH/DELETE /v1/tenants/:id  admin
//	POST /v1/tenants/:id/bootstrap   tenant + default role + first key
//	POST /v1/tenants/:id/keys     issue API key
//	GET  /v1/tenants/:id/keys     list keys (redacted)
//	DELETE /v1/tenants/:id/keys/:keyId   revoke
//	POST /v1/keys/verify          gateway-internal: cleartext key -> identity
package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func main() {
	log := shared.NewLogger("tenant-control")
	cfg, err := shared.LoadConfig("TENANT_CONTROL")
	if err != nil {
		log.Error("config error", "err", err)
		os.Exit(1)
	}
	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		os.Exit(healthcheck(cfg))
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	b := &bootCtx{log: log, cfg: cfg}
	b.openDB(ctx)
	defer b.db.Close()
	b.setupClients(ctx)
	b.setupJWT()
	b.mountAll(ctx)
	b.serve(ctx, stop)
}

// mountAll registers every route group, in the same order main() did. Each
// flag-gated block is OFF by default = byte-parity with the OSS edition.
func (b *bootCtx) mountAll(ctx context.Context) {
	b.mux = shared.NewRouter("tenant-control", b.db)
	b.mountCore()
	b.mountSelfServe()
	b.mountBackup()
	b.mountAbuse(ctx)
	b.mountAudit()
	b.mountErase()
	b.mountOrgs()
	b.mountIPGuard()
	b.mountCompliance(ctx)
	b.mountExport()
	b.mountPasskeys()
	b.mountSSO()
	b.mountSCIM()
	b.mountTrust()
	b.mountBranching()
	b.mountPush()
}

func envFirst(keys ...string) string {
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return ""
}

// splitCSV splits a comma-separated env value into trimmed, non-empty fields,
// trimming only ASCII space/tab (preserving the original semantics).
func splitCSV(s string) []string {
	out := []string{}
	for _, f := range strings.Split(s, ",") {
		if f = strings.Trim(f, " \t"); f != "" {
			out = append(out, f)
		}
	}
	return out
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
