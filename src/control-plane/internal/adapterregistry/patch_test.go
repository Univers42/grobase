/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   patch_test.go                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 20:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 20:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

func patchString(value string) *string { return &value }

func TestPatchDatabaseRequestValidate(t *testing.T) {
	name := patchString("renamed")
	dsn := patchString("postgres://user:pass@example.com/db")
	ref := &CredentialRefInput{Provider: "vault", Reference: "mounts/current"}
	tests := []struct {
		name    string
		req     PatchDatabaseRequest
		wantErr bool
	}{
		{"empty body", PatchDatabaseRequest{}, true},
		{"empty name", PatchDatabaseRequest{Name: patchString("")}, true},
		{"name too long", PatchDatabaseRequest{Name: patchString(strings.Repeat("n", 65))}, true},
		{"both credentials", PatchDatabaseRequest{ConnectionString: dsn, CredentialRef: ref}, true},
		{"empty dsn", PatchDatabaseRequest{ConnectionString: patchString("")}, true},
		{"ref missing provider", PatchDatabaseRequest{CredentialRef: &CredentialRefInput{Reference: "ref"}}, true},
		{"ref missing reference", PatchDatabaseRequest{CredentialRef: &CredentialRefInput{Provider: "vault"}}, true},
		{"name only", PatchDatabaseRequest{Name: name}, false},
		{"inline credential", PatchDatabaseRequest{ConnectionString: dsn}, false},
		{"credential reference", PatchDatabaseRequest{CredentialRef: ref}, false},
		{"name and credential", PatchDatabaseRequest{Name: name, CredentialRef: ref}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.req.Validate()
			if (err != nil) != tc.wantErr {
				t.Fatalf("Validate() error = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}

func TestPatchValidateNothingToChangeMessage(t *testing.T) {
	err := (PatchDatabaseRequest{}).Validate()
	if err == nil || err.Error() != "nothing to change" {
		t.Fatalf("Validate() error = %v, want nothing to change", err)
	}
}

func TestPatchRequiresServiceTokenBeforeService(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	rt := &routes{serviceToken: testToken, rotation: serviceauth.NewRotationNotice(nil, nil)}
	r := httptest.NewRequest(http.MethodPatch, "/databases/mount-1", strings.NewReader(`{"name":"renamed"}`))
	r.Header.Set("X-Baas-User-Id", "user-1")
	w := httptest.NewRecorder()
	rt.patch(w, r)
	message := assertPatchError(t, w, http.StatusUnauthorized, "unauthorized")
	if message != "service token required" {
		t.Fatalf("message = %q, want service token required", message)
	}
}

func TestPatchRejectsEmptyChange(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	t.Setenv("SERVICE_TOKEN_MODE", "")
	t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", "")
	rt := &routes{serviceToken: testToken, rotation: serviceauth.NewRotationNotice(nil, nil)}
	r := httptest.NewRequest(http.MethodPatch, "/databases/mount-1", strings.NewReader(`{}`))
	r.Header.Set("X-Service-Token", testToken)
	r.Header.Set("X-Baas-User-Id", "user-1")
	w := httptest.NewRecorder()
	rt.patch(w, r)
	assertPatchError(t, w, http.StatusBadRequest, "validation_error")
}

func TestWritePatchErrorMapsSentinels(t *testing.T) {
	tests := []struct {
		err    error
		status int
		code   string
	}{
		{ErrNotFound, http.StatusNotFound, "not_found"},
		{ErrConflict, http.StatusConflict, "conflict"},
		{ErrCredentialModeMismatch, http.StatusConflict, "credential_mode_mismatch"},
		{ErrCMEKUnavailable, http.StatusConflict, "cmek_unavailable"},
		{ErrRevisionConflict, http.StatusConflict, "revision_conflict"},
		{ErrPlatformMount, http.StatusForbidden, "platform_mount"},
		{ErrPlaintextDsnForbidden, http.StatusForbidden, "plaintext_dsn_forbidden"},
	}
	for _, tc := range tests {
		t.Run(tc.code, func(t *testing.T) {
			w := httptest.NewRecorder()
			writePatchError(w, tc.err)
			assertPatchError(t, w, tc.status, tc.code)
		})
	}
}

func TestWritePatchErrorHidesInternalError(t *testing.T) {
	w := httptest.NewRecorder()
	writePatchError(w, errors.New("driver text: postgres://user:secret@example.com/db"))
	raw := w.Body.String()
	if strings.Contains(raw, "driver text") || strings.Contains(raw, "secret") {
		t.Fatal("500 response leaked internal error")
	}
	message := assertPatchError(t, w, http.StatusInternalServerError, "internal_error")
	if message != "internal server error" {
		t.Fatalf("message = %q, want fixed internal server error", message)
	}
}

func assertPatchError(t *testing.T, w *httptest.ResponseRecorder, status int, code string) string {
	t.Helper()
	if w.Code != status {
		t.Fatalf("status = %d, want %d", w.Code, status)
	}
	var body struct {
		Error   string `json:"error"`
		Message string `json:"message"`
	}
	if err := json.NewDecoder(w.Body).Decode(&body); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if body.Error != code {
		t.Fatalf("error code = %q, want %q", body.Error, code)
	}
	return body.Message
}
