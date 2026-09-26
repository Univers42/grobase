package push

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

// loopbackSink serves 204 on 127.0.0.1 — a private target the guard must refuse
// unless the operator allowlists it.
func loopbackSink(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestDeliverAllowlistedPrivateHost: PUSH_SSRF_ALLOW_HOSTS reaches the dial-time
// guard too — an allowlisted private host is delivered to; unlisted, it is refused.
func TestDeliverAllowlistedPrivateHost(t *testing.T) {
	srv := loopbackSink(t)
	d := newDispatcher()
	t.Setenv("PUSH_SSRF_ALLOW_HOSTS", "")
	if _, err := d.deliver(context.Background(), srv.URL, "", []byte("{}")); !errors.Is(err, ErrBlockedTarget) {
		t.Fatalf("deliver(unlisted loopback) = %v, want ErrBlockedTarget", err)
	}
	t.Setenv("PUSH_SSRF_ALLOW_HOSTS", "127.0.0.1")
	if code, err := d.deliver(context.Background(), srv.URL, "", []byte("{}")); err != nil || code != http.StatusNoContent {
		t.Fatalf("deliver(allowlisted loopback) = %d, %v; want 204, nil", code, err)
	}
}

// TestDialGuardWithoutAllowlist: the dial-time guard alone (guardTarget bypassed)
// refuses a private address the allowlist does not name — empty, or naming
// another host.
func TestDialGuardWithoutAllowlist(t *testing.T) {
	srv := loopbackSink(t)
	for _, allow := range []string{"", "other-sink"} {
		t.Setenv("PUSH_SSRF_ALLOW_HOSTS", allow)
		resp, err := newDispatcher().client.Get(srv.URL)
		if err == nil {
			_ = resp.Body.Close()
		}
		if !errors.Is(err, ErrBlockedTarget) {
			t.Fatalf("allowlist %q: dial to unlisted loopback = %v, want ErrBlockedTarget", allow, err)
		}
	}
}

// TestRedirectToUnlistedHostRefused: an allowlisted sink that redirects to a host
// the allowlist does not name is refused at that hop's dial.
func TestRedirectToUnlistedHostRefused(t *testing.T) {
	target := loopbackSink(t)
	hop := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://localhost:"+target.URL[len("http://127.0.0.1:"):], http.StatusTemporaryRedirect)
	}))
	t.Cleanup(hop.Close)
	t.Setenv("PUSH_SSRF_ALLOW_HOSTS", "127.0.0.1")
	if _, err := newDispatcher().deliver(context.Background(), hop.URL, "", []byte("{}")); !errors.Is(err, ErrBlockedTarget) {
		t.Fatalf("redirect to unlisted localhost = %v, want ErrBlockedTarget", err)
	}
}
