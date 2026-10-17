package authz

import (
	"fmt"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// MaxBatchObjects bounds one check-batch.
const MaxBatchObjects = 1000

type checkRequest struct {
	Subject    string `json:"subject"`
	Permission string `json:"permission"`
	Object     string `json:"object"`
	Strict     bool   `json:"strict"`
}

type batchRequest struct {
	Subject    string   `json:"subject"`
	Permission string   `json:"permission"`
	Objects    []string `json:"objects"`
	Strict     bool     `json:"strict"`
}

type decisionJSON struct {
	Object  string `json:"object,omitempty"`
	Allowed bool   `json:"allowed"`
	Cut     bool   `json:"cut"`
}

// userID extracts the id from a "user:<id>" subject; a check is always for one
// concrete user, so the wildcard and usersets are refused.
func userID(subject string) (string, error) {
	s, err := ParseSubject(subject)
	if err != nil {
		return "", err
	}
	if s.Type != UserType || s.IsWildcard() {
		return "", fmt.Errorf("%w: subject must be user:<id>", ErrInvalidName)
	}
	return s.ID, nil
}

func (rt *routes) check(w http.ResponseWriter, r *http.Request) {
	app, ok := rt.app(w, r, ScopeRead)
	if !ok {
		return
	}
	var req checkRequest
	if !decodeBody(w, r, &req) {
		return
	}
	ds, ok := rt.run(w, r, app, req.Subject, req.Permission, []string{req.Object})
	if !ok || !rt.strictOK(w, req.Strict, ds) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, decisionJSON{Allowed: ds[0].Allowed, Cut: ds[0].Cut})
}

func (rt *routes) checkBatch(w http.ResponseWriter, r *http.Request) {
	app, ok := rt.app(w, r, ScopeRead)
	if !ok {
		return
	}
	var req batchRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if len(req.Objects) == 0 || len(req.Objects) > MaxBatchObjects {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error",
			fmt.Sprintf("objects needs 1 to %d entries", MaxBatchObjects))
		return
	}
	ds, ok := rt.run(w, r, app, req.Subject, req.Permission, req.Objects)
	if !ok || !rt.strictOK(w, req.Strict, ds) {
		return
	}
	out := make([]decisionJSON, len(ds))
	for i, d := range ds {
		out[i] = decisionJSON{Object: d.Object.String(), Allowed: d.Allowed, Cut: d.Cut}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"results": out})
}

// parseQuery turns the wire strings into a Query.
func parseQuery(app, subject, perm string, objects []string) (Query, error) {
	uid, err := userID(subject)
	if err != nil {
		return Query{}, err
	}
	if !ValidName(perm) {
		return Query{}, fmt.Errorf("%w: permission %q", ErrInvalidName, perm)
	}
	refs := make([]Ref, len(objects))
	for i, o := range objects {
		if refs[i], err = ParseRef(o); err != nil {
			return Query{}, err
		}
	}
	return Query{App: app, UserID: uid, Name: perm, Objects: refs}, nil
}

// run evaluates the request; on any failure it has already answered.
func (rt *routes) run(w http.ResponseWriter, r *http.Request, app, subject, perm string, objects []string) ([]Decision, bool) {
	q, err := parseQuery(app, subject, perm, objects)
	if err == nil {
		var ds []Decision
		if ds, err = rt.Svc.Check(r.Context(), q); err == nil {
			return ds, true
		}
	}
	rt.fail(w, err)
	return nil, false
}

// strictOK implements the caller's opt-in to hear about limits: with strict, a
// deny caused by a cut is a 503 (N8: an enforcing caller must never turn a
// limit into a 403). Without it the cut is reported in the body only.
func (rt *routes) strictOK(w http.ResponseWriter, strict bool, ds []Decision) bool {
	if !strict {
		return true
	}
	for _, d := range ds {
		if d.Cut {
			rt.fail(w, ErrUnavailable)
			return false
		}
	}
	return true
}
