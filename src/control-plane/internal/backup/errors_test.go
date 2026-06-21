/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   errors_test.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:46 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:47 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestBackupErrError asserts the const error type's Error() returns its own
// string, and that the three sentinels carry their documented messages.
func TestBackupErrError(t *testing.T) {
	cases := []struct {
		err  backupErr
		want string
	}{
		{ErrNotOwned, "backup not found for tenant"},
		{ErrNotFound, "tenant not found"},
		{ErrIsolationDeferred, "isolation not supported for backup/restore (deferred)"},
	}
	for _, tc := range cases {
		if tc.err.Error() != tc.want {
			t.Fatalf("Error() = %q, want %q", tc.err.Error(), tc.want)
		}
	}
}

// TestSentinelsErrorsIs asserts the sentinels are matchable through %w wrapping
// (errors.Is) — the handler relies on this to map a wrapped service error, and
// that distinct sentinels do not match each other.
func TestSentinelsErrorsIs(t *testing.T) {
	wrapped := fmt.Errorf("context: %w", ErrNotOwned)
	if !errors.Is(wrapped, ErrNotOwned) {
		t.Fatalf("errors.Is(wrapped, ErrNotOwned) = false")
	}
	if errors.Is(wrapped, ErrIsolationDeferred) {
		t.Fatalf("ErrNotOwned matched ErrIsolationDeferred")
	}
	if errors.Is(ErrNotFound, ErrNotOwned) {
		t.Fatalf("ErrNotFound matched ErrNotOwned")
	}
}

// errBody is the JSON shape httpx.WriteError emits.
type errBody struct {
	Error      string `json:"error"`
	Message    string `json:"message"`
	StatusCode int    `json:"statusCode"`
}

// TestHandleBackupErr pins the service-error -> HTTP-status mapping that
// handleBackupErr owns: nil writes nothing (and returns false), ErrIsolationDeferred
// -> 400 isolation_unsupported, ErrNotOwned -> 404 not_found (opaque, never 403),
// and any other error -> 500. The wrapped cases prove it matches through %w.
func TestHandleBackupErr(t *testing.T) {
	cases := []struct {
		name        string
		err         error
		wantHandled bool
		wantStatus  int
		wantCode    string
	}{
		{"nil", nil, false, http.StatusOK, ""},
		{"isolation", ErrIsolationDeferred, true, http.StatusBadRequest, "isolation_unsupported"},
		{"isolation wrapped", fmt.Errorf("w: %w", ErrIsolationDeferred), true, http.StatusBadRequest, "isolation_unsupported"},
		{"not owned", ErrNotOwned, true, http.StatusNotFound, "not_found"},
		{"not owned wrapped", fmt.Errorf("w: %w", ErrNotOwned), true, http.StatusNotFound, "not_found"},
		{"other", errors.New("boom"), true, http.StatusInternalServerError, "internal_error"},
	}
	rt := &routes{}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			handled := rt.handleBackupErr(rec, tc.err)
			if handled != tc.wantHandled {
				t.Fatalf("handled = %v, want %v", handled, tc.wantHandled)
			}
			if !tc.wantHandled {
				if rec.Body.Len() != 0 {
					t.Fatalf("nil error wrote a body: %q", rec.Body.String())
				}
				return
			}
			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
			var body errBody
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Fatalf("decode body: %v (%q)", err, rec.Body.String())
			}
			if body.Error != tc.wantCode {
				t.Fatalf("error code = %q, want %q", body.Error, tc.wantCode)
			}
			if body.StatusCode != tc.wantStatus {
				t.Fatalf("body.statusCode = %d, want %d", body.StatusCode, tc.wantStatus)
			}
		})
	}
}

// TestHandleBackupErrNotOwnedIsOpaque is an explicit regression guard for the
// security contract: a wrong-tenant / unknown backup must map to 404 (so the
// existence of another tenant's backup is never confirmed), NOT 403.
func TestHandleBackupErrNotOwned404Not403(t *testing.T) {
	rec := httptest.NewRecorder()
	(&routes{}).handleBackupErr(rec, ErrNotOwned)
	if rec.Code == http.StatusForbidden {
		t.Fatalf("ErrNotOwned mapped to 403 — leaks existence; must be 404")
	}
	if rec.Code != http.StatusNotFound {
		t.Fatalf("ErrNotOwned status = %d, want 404", rec.Code)
	}
}
