package tenants

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// hasScope reports whether the credential carries the named scope, treating
// "admin" as a superset (an admin key may do anything a write/read key may).
func hasScope(scopes []string, want string) bool {
	for _, s := range scopes {
		if s == want || s == "admin" {
			return true
		}
	}
	return false
}

// scopesWithinCaller resolves the EFFECTIVE scopes a caller is asking to grant a
// new key (an empty request defaults to the service's {read,write}) and reports
// whether every one is a scope the caller itself holds (admin is a superset). It
// is the scope-containment guard that prevents a within-tenant privilege
// escalation — a write-only key requesting {admin}. Returns the effective scope
// set so the handler can pass it explicitly (no re-defaulting in the service).
func scopesWithinCaller(requested, held []string) ([]string, bool) {
	eff := requested
	if len(eff) == 0 {
		eff = []string{"read", "write"}
	}
	for _, s := range eff {
		if !hasScope(held, s) {
			return nil, false
		}
	}
	return eff, true
}

// requireScope enforces a write/admin scope, writing 403 and returning false on
// a read-only credential.
func (ss *selfServe) requireScope(w http.ResponseWriter, scopes []string, want string) bool {
	if hasScope(scopes, want) {
		return true
	}
	httpx.WriteError(w, http.StatusForbidden, "forbidden",
		"this credential lacks the required scope: "+want)
	return false
}
