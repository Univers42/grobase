package passkeys

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers the passkey ceremony routes onto the shared mux (Track-D D2c).
// The caller mounts this ONLY when PASSKEYS_ENABLED is truthy (the parity gate),
// exactly like audit.Mount / backup.Mount / metering.Mount. When OFF, none of
// these routes exist and a request 404s — byte-identical to today; gotrue has no
// passkey support, so the proven-parity state is the routes NOT existing.
//
// Routes:
//
//	POST /v1/auth/passkeys/register/begin   -> {creation, challenge_id}
//	POST /v1/auth/passkeys/register/finish  -> {credential_id}
//	POST /v1/auth/passkeys/login/begin      -> {assertion, challenge_id}
//	POST /v1/auth/passkeys/login/finish     -> {access_token, ...} (a session JWT)
//
// AUTHZ for the BEGIN routes — who may START a ceremony for a given user:
//   - a control-plane service token (admin / a trusted edge), OR
//   - a matching tenant header (a tenant acting WITHIN its own tenant), the same
//     tokenOrSelf pattern audit/metering use.
//
// The FINISH routes need no separate authz: they consume a one-time, server-held
// challenge id minted by a (already-authorized) begin call, and the assertion
// itself is the cryptographic proof. A finish with an unknown/expired/forged
// challenge id 404s before any verification runs.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/auth/passkeys/register/begin", rt.registerBegin)
	mux.HandleFunc("POST /v1/auth/passkeys/register/finish", rt.registerFinish)
	mux.HandleFunc("POST /v1/auth/passkeys/login/begin", rt.loginBegin)
	mux.HandleFunc("POST /v1/auth/passkeys/login/finish", rt.loginFinish)
}

type routes struct {
	svc          *Service
	serviceToken string
}

// ── request / response bodies ──────────────────────────────────────────────

// BeginRegisterInput / BeginLoginInput are the typed ceremony inputs the service
// consumes (kept in the package so service.go has no handler dep).
type BeginRegisterInput struct {
	TenantID    string
	UserID      string
	Name        string
	DisplayName string
}
type BeginLoginInput struct {
	TenantID string
	UserID   string
}

// registerBeginRequest starts a registration ceremony for a user.
type registerBeginRequest struct {
	UserID      string `json:"user_id"`
	Name        string `json:"name"`         // login name / email
	DisplayName string `json:"display_name"` // optional human label
}

// finishRequest is the begin→finish bridge: the challenge id the begin returned
// PLUS the raw authenticator response (attestation for register, assertion for
// login) as a verbatim JSON object — passed straight to go-webauthn's parser.
type finishRequest struct {
	ChallengeID string          `json:"challenge_id"`
	Response    json.RawMessage `json:"response"`
}

// loginBeginRequest starts a login ceremony for a known user.
type loginBeginRequest struct {
	UserID string `json:"user_id"`
}

// ── handlers ───────────────────────────────────────────────────────────────

func (rt *routes) registerBegin(w http.ResponseWriter, r *http.Request) {
	var req registerBeginRequest
	if err := decodeJSON(r, &req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	tenantID := tenantOf(r)
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	if strings.TrimSpace(req.UserID) == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "user_id required")
		return
	}
	creation, challengeID, err := rt.svc.BeginRegister(r.Context(), BeginRegisterInput{
		TenantID: tenantID, UserID: req.UserID, Name: req.Name, DisplayName: req.DisplayName,
	})
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{
		"challenge_id": challengeID,
		"publicKey":    creation.Response, // the navigator.credentials.create options
	})
}

func (rt *routes) registerFinish(w http.ResponseWriter, r *http.Request) {
	req, ok := rt.decodeFinish(w, r)
	if !ok {
		return
	}
	credID, err := rt.svc.FinishRegister(r.Context(), req.ChallengeID, req.Response)
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{
		"verified":      true,
		"credential_id": credID,
	})
}

func (rt *routes) loginBegin(w http.ResponseWriter, r *http.Request) {
	var req loginBeginRequest
	if err := decodeJSON(r, &req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	tenantID := tenantOf(r)
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	if strings.TrimSpace(req.UserID) == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "user_id required")
		return
	}
	assertion, challengeID, err := rt.svc.BeginLogin(r.Context(), BeginLoginInput{
		TenantID: tenantID, UserID: req.UserID,
	})
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{
		"challenge_id": challengeID,
		"publicKey":    assertion.Response, // the navigator.credentials.get options
	})
}

func (rt *routes) loginFinish(w http.ResponseWriter, r *http.Request) {
	req, ok := rt.decodeFinish(w, r)
	if !ok {
		return
	}
	session, err := rt.svc.FinishLogin(r.Context(), req.ChallengeID, req.Response)
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusOK, session)
}

// helpers live in handler_helpers.go.
