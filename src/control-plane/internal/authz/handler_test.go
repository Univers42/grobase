package authz

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// fakeKeys authenticates "Bearer mbk_<app>.<scope,scope>" without a database.
type fakeKeys struct{}

func (fakeKeys) AuthenticateAPIKey(w http.ResponseWriter, r *http.Request) (string, []string, bool) {
	raw := httpx.APIKeyFromRequest(r)
	if raw == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "no key")
		return "", nil, false
	}
	app, scopes, _ := strings.Cut(strings.TrimPrefix(raw, "mbk_"), ".")
	return app, strings.Split(scopes, ","), true
}

type fakeSvc struct {
	apps   []string
	checks []Query
	ds     []Decision
	err    error
	model  []byte
}

func (f *fakeSvc) Check(_ context.Context, q Query) ([]Decision, error) {
	f.apps, f.checks = append(f.apps, q.App), append(f.checks, q)
	if f.err != nil {
		return nil, f.err
	}
	if f.ds != nil {
		return f.ds, nil
	}
	out := make([]Decision, len(q.Objects))
	for i, o := range q.Objects {
		out[i] = Decision{Object: o, Allowed: true}
	}
	return out, nil
}

func (f *fakeSvc) GetModel(context.Context, string) ([]byte, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.model, nil
}

func (f *fakeSvc) PutModel(_ context.Context, app string, _ []byte) error {
	f.apps = append(f.apps, app)
	return f.err
}

func (f *fakeSvc) ReplaceTuples(_ context.Context, app string, _ TuplesRequest) (int, error) {
	f.apps = append(f.apps, app)
	return 3, f.err
}

func serve(svc Service, auth KeyAuth) *http.ServeMux {
	mux := http.NewServeMux()
	Mount(mux, Deps{Svc: svc, Auth: auth, Log: slog.Default()})
	return mux
}

func do(mux *http.ServeMux, method, path, key, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if key != "" {
		req.Header.Set("X-API-Key", key)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

const (
	checkBody = `{"subject":"user:alice","permission":"read","object":"page:1"}`
	batchBody = `{"subject":"user:alice","permission":"read","objects":["page:1","page:2"]}`
	tupleBody = `{"source":"page_row","object":"page:1","tuples":[{"relation":"owner","subject":"user:alice"}]}`
)

func TestRoutesNeedTheRightScope(t *testing.T) {
	cases := []struct{ method, path, body, wrong, right string }{
		{"POST", "/v1/authz/check", checkBody, "mbk_osionos.authz:write", "mbk_osionos.authz:read"},
		{"POST", "/v1/authz/check-batch", batchBody, "mbk_osionos.authz:write", "mbk_osionos.authz:read"},
		{"POST", "/v1/authz/tuples", tupleBody, "mbk_osionos.authz:read", "mbk_osionos.authz:write"},
		{"PUT", "/v1/authz/model", pageModel, "mbk_osionos.authz:read", "mbk_osionos.authz:write"},
		{"GET", "/v1/authz/model", "", "mbk_osionos.authz:read", "mbk_osionos.authz:write"},
	}
	for _, c := range cases {
		t.Run(c.method+" "+c.path, func(t *testing.T) {
			mux := serve(&fakeSvc{model: []byte(`{}`)}, fakeKeys{})
			if got := do(mux, c.method, c.path, "", c.body).Code; got != 401 {
				t.Errorf("no key: %d, want 401", got)
			}
			if got := do(mux, c.method, c.path, c.wrong, c.body).Code; got != 403 {
				t.Errorf("wrong scope: %d, want 403", got)
			}
			if got := do(mux, c.method, c.path, "mbk_osionos.read,write", c.body).Code; got != 403 {
				t.Errorf("unrelated scopes: %d, want 403", got)
			}
			if got := do(mux, c.method, c.path, c.right, c.body).Code; got != 200 {
				t.Errorf("right scope: %d, want 200", got)
			}
			if got := do(mux, c.method, c.path, "mbk_osionos.admin", c.body).Code; got != 200 {
				t.Errorf("admin: %d, want 200", got)
			}
		})
	}
}

// A GoTrue JWT must not authenticate, even though Authenticate would accept it.
func TestJWTBearerIs401(t *testing.T) {
	mux := serve(&fakeSvc{}, tenants.NewSelfAuthenticator(nil, nil))
	for _, path := range []string{"/v1/authz/check", "/v1/authz/check-batch", "/v1/authz/tuples"} {
		req := httptest.NewRequest("POST", path, strings.NewReader(checkBody))
		req.Header.Set("Authorization", "Bearer eyJhbGciOiJIUzI1NiJ9.e30.sig")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != 401 {
			t.Errorf("%s with a JWT: %d, want 401", path, rec.Code)
		}
	}
}

func TestBodyAppIsRejectedAndNeverUsed(t *testing.T) {
	svc := &fakeSvc{}
	mux := serve(svc, fakeKeys{})
	key := "mbk_osionos.authz:read,authz:write"
	for _, field := range []string{"app", "app_id"} {
		for path, body := range map[string]string{
			"/v1/authz/check":       `{"` + field + `":"other","subject":"user:a","permission":"read","object":"page:1"}`,
			"/v1/authz/check-batch": `{"` + field + `":"other","subject":"user:a","permission":"read","objects":["page:1"]}`,
			"/v1/authz/tuples":      `{"` + field + `":"other","source":"s","object":"page:1","tuples":[]}`,
		} {
			if got := do(mux, "POST", path, key, body).Code; got != 400 {
				t.Errorf("%s with %s: %d, want 400", path, field, got)
			}
		}
		if got := do(mux, "PUT", "/v1/authz/model", key, `{"`+field+`":"other","types":{}}`).Code; got != 400 {
			t.Errorf("PUT model with %s: %d, want 400", field, got)
		}
	}
	if len(svc.apps) != 0 {
		t.Fatalf("service reached with %v despite a body app", svc.apps)
	}
}

func TestAppComesFromTheKey(t *testing.T) {
	svc := &fakeSvc{}
	mux := serve(svc, fakeKeys{})
	do(mux, "POST", "/v1/authz/check", "mbk_tenant-b.authz:read", checkBody)
	do(mux, "POST", "/v1/authz/tuples", "mbk_tenant-a.authz:write", tupleBody)
	if fmt.Sprint(svc.apps) != "[tenant-b tenant-a]" {
		t.Fatalf("apps = %v", svc.apps)
	}
}

func TestBadBodiesAre400(t *testing.T) {
	mux := serve(&fakeSvc{}, fakeKeys{})
	key := "mbk_x.authz:read"
	over := `{"subject":"user:a","permission":"read","objects":[` + strings.Repeat(`"page:1",`, MaxBatchObjects) + `"page:1"]}`
	cases := map[string]string{
		"/v1/authz/check:unknown field": `{"subject":"user:a","permission":"read","object":"page:1","x":1}`,
		"/v1/authz/check:not json":      `nope`,
		"/v1/authz/check:wildcard":      `{"subject":"user:*","permission":"read","object":"page:1"}`,
		"/v1/authz/check:userset":       `{"subject":"w:1#m","permission":"read","object":"page:1"}`,
		"/v1/authz/check:bad object":    `{"subject":"user:a","permission":"read","object":"page"}`,
		"/v1/authz/check:bad perm":      `{"subject":"user:a","permission":"Read","object":"page:1"}`,
		"/v1/authz/check:trailing":      checkBody + ` {}`,
		"/v1/authz/check-batch:empty":   `{"subject":"user:a","permission":"read","objects":[]}`,
		"/v1/authz/check-batch:1001":    over,
	}
	for k, body := range cases {
		path, _, _ := strings.Cut(k, ":")
		if got := do(mux, "POST", path, key, body).Code; got != 400 {
			t.Errorf("%s: %d, want 400", k, got)
		}
	}
}

func TestBatchAtTheLimitIsServed(t *testing.T) {
	mux := serve(&fakeSvc{}, fakeKeys{})
	body := `{"subject":"user:a","permission":"read","objects":[` + strings.Repeat(`"page:1",`, MaxBatchObjects-1) + `"page:1"]}`
	if got := do(mux, "POST", "/v1/authz/check-batch", "mbk_x.authz:read", body).Code; got != 200 {
		t.Fatalf("1000 objects: %d, want 200", got)
	}
}

func TestStoreFailuresAre503NeverAClean403(t *testing.T) {
	for _, err := range []error{ErrUnavailable, context.DeadlineExceeded} {
		rec := do(serve(&fakeSvc{err: err}, fakeKeys{}), "POST", "/v1/authz/check", "mbk_x.authz:read", checkBody)
		if rec.Code != 503 || !strings.Contains(rec.Body.String(), "authz_unavailable") {
			t.Errorf("%v: %d %s", err, rec.Code, rec.Body)
		}
	}
}

func TestCutIsReportedAndStrictMakesItA503(t *testing.T) {
	svc := &fakeSvc{ds: []Decision{{Object: Ref{"page", "1"}, Cut: true}}}
	mux := serve(svc, fakeKeys{})
	rec := do(mux, "POST", "/v1/authz/check", "mbk_x.authz:read", checkBody)
	var got decisionJSON
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if rec.Code != 200 || got.Allowed || !got.Cut {
		t.Fatalf("lenient: %d %s", rec.Code, rec.Body)
	}
	strict := `{"subject":"user:alice","permission":"read","object":"page:1","strict":true}`
	if rec := do(mux, "POST", "/v1/authz/check", "mbk_x.authz:read", strict); rec.Code != 503 {
		t.Fatalf("strict: %d %s", rec.Code, rec.Body)
	}
}

func TestModelErrors(t *testing.T) {
	key := "mbk_x.authz:write"
	rec := do(serve(&fakeSvc{err: &DroppedError{Relations: []string{"page#old"}}}, fakeKeys{}), "PUT", "/v1/authz/model", key, `{}`)
	if rec.Code != 409 || !strings.Contains(rec.Body.String(), "page#old") {
		t.Fatalf("dropped: %d %s", rec.Code, rec.Body)
	}
	if rec := do(serve(&fakeSvc{err: ErrInvalidModel}, fakeKeys{}), "PUT", "/v1/authz/model", key, `{}`); rec.Code != 400 {
		t.Fatalf("invalid: %d", rec.Code)
	}
	if rec := do(serve(&fakeSvc{err: ErrNoModel}, fakeKeys{}), "GET", "/v1/authz/model", key, ""); rec.Code != 404 {
		t.Fatalf("get without a model: %d", rec.Code)
	}
	if rec := do(serve(&fakeSvc{err: ErrNoModel}, fakeKeys{}), "POST", "/v1/authz/check", "mbk_x.authz:read", checkBody); rec.Code != 409 {
		t.Fatalf("check without a model: %d", rec.Code)
	}
	if rec := do(serve(&fakeSvc{err: ErrInvalidTuples}, fakeKeys{}), "POST", "/v1/authz/tuples", key, tupleBody); rec.Code != 400 {
		t.Fatalf("invalid tuples: %d", rec.Code)
	}
}

func TestTuplesAnswersChangedCount(t *testing.T) {
	rec := do(serve(&fakeSvc{}, fakeKeys{}), "POST", "/v1/authz/tuples", "mbk_x.authz:write", tupleBody)
	if rec.Code != 200 || strings.TrimSpace(rec.Body.String()) != `{"changed":3}` {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}
