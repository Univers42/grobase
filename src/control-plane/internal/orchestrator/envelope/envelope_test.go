package envelope

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func handler(status int, ct, body string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if ct != "" {
			w.Header().Set("Content-Type", ct)
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	})
}

func TestWrapsSuccessJSON(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/subscribe?x=1", nil)
	Wrap(handler(201, "application/json", `{"subscribed":true,"id":7}`)).ServeHTTP(rec, req)

	if rec.Code != 201 {
		t.Fatalf("status %d != 201", rec.Code)
	}
	var env map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &env); err != nil {
		t.Fatalf("body not JSON: %v\n%s", err, rec.Body.String())
	}
	for _, k := range []string{"success", "statusCode", "message", "data", "path", "timestamp"} {
		if _, ok := env[k]; !ok {
			t.Fatalf("envelope missing %q: %s", k, rec.Body.String())
		}
	}
	if string(env["message"]) != `"Resource created successfully"` {
		t.Fatalf("POST 201 message = %s", env["message"])
	}
	if string(env["path"]) != `"/subscribe?x=1"` {
		t.Fatalf("path = %s (want /subscribe?x=1)", env["path"])
	}
	// data must be the verbatim payload (not re-parsed/re-ordered).
	if string(env["data"]) != `{"subscribed":true,"id":7}` {
		t.Fatalf("data not verbatim: %s", env["data"])
	}
}

func TestPassthroughNonSuccessAndNonJSONAndOps(t *testing.T) {
	cases := []struct {
		name             string
		method, path, ct string
		status           int
		body             string
	}{
		{"error-4xx", http.MethodGet, "/x", "application/json", 404, `{"error":"nope"}`},
		{"non-json", http.MethodGet, "/x", "text/plain", 200, "hello"},
		{"metrics", http.MethodGet, "/metrics", "text/plain", 200, "# HELP"},
		{"health", http.MethodGet, "/health/live", "application/json", 200, `{"status":"ok"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(tc.method, tc.path, nil)
			Wrap(handler(tc.status, tc.ct, tc.body)).ServeHTTP(rec, req)
			if rec.Body.String() != tc.body {
				t.Fatalf("%s should pass through verbatim, got %s", tc.name, rec.Body.String())
			}
		})
	}
}

func TestMethodMessages(t *testing.T) {
	for _, c := range []struct {
		method string
		status int
		want   string
	}{
		{http.MethodGet, 200, "Data retrieved successfully"},
		{http.MethodPost, 201, "Resource created successfully"},
		{http.MethodPost, 200, "Operation successful"},
		{http.MethodPut, 200, "Resource updated successfully"},
		{http.MethodPatch, 200, "Resource updated successfully"},
		{http.MethodDelete, 200, "Resource deleted successfully"},
		{http.MethodGet, 204, "Operation successful"}, // fallback
	} {
		if got := message(c.method, c.status); got != c.want {
			t.Fatalf("%s %d: %q != %q", c.method, c.status, got, c.want)
		}
	}
}
