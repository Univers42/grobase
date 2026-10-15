package main

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// The real boot path (mountSelfServe, which nests mountBuilder) registers the
// mount list exactly once whenever self-serve is on: a second registration of
// the same pattern panics at boot, and none leaves a self-serve tenant unable to
// read its mounts. With self-serve off, nothing under /v1/tenants/me exists.
func TestMountSelfServeRoutesTheMountListOnce(t *testing.T) {
	cases := []struct {
		selfServe, builder       string
		listRouted, createRouted bool
	}{
		{"1", "", true, false},
		{"1", "1", true, true},
		{"", "", false, false},
		{"", "1", false, false},
	}
	for _, c := range cases {
		t.Run("SELFSERVE="+c.selfServe+",BUILDER="+c.builder, func(t *testing.T) {
			t.Setenv("TENANT_SELFSERVE_ENABLED", c.selfServe)
			t.Setenv("BUILDER_ENABLED", c.builder)
			log := slog.New(slog.DiscardHandler)
			b := &bootCtx{log: log, svc: tenants.NewService(nil, log), mux: http.NewServeMux()}

			b.mountSelfServe()

			if got := routed(b.mux, http.MethodGet, "/v1/tenants/me/mounts"); got != c.listRouted {
				t.Errorf("GET /v1/tenants/me/mounts routed = %v, want %v", got, c.listRouted)
			}
			if got := routed(b.mux, http.MethodPost, "/v1/tenants/me/mounts"); got != c.createRouted {
				t.Errorf("POST /v1/tenants/me/mounts routed = %v, want %v", got, c.createRouted)
			}
		})
	}
}

func routed(mux *http.ServeMux, method, path string) bool {
	_, pattern := mux.Handler(httptest.NewRequest(method, path, nil))
	return pattern != ""
}
