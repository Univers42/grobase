/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   internal_error_test.go                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import (
	"bytes"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// m230: every 500 path of the registry hides a driver error that quotes its DSN,
// from the client and from the log.
func TestInternalErrorsHideTheCanaryFromBodyAndLog(t *testing.T) {
	var logs bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })

	driverErrs := []error{
		errors.New("dial postgresql://app:" + canary + "@db.example.com:5432/shop: refused"),
		errors.New("connect host=db password=" + canary + " failed"),
	}
	writers := map[string]func(http.ResponseWriter, error){
		"register": func(w http.ResponseWriter, err error) { writeRegisterError(w, RegisterDatabaseRequest{}, err) },
		"lookup":   func(w http.ResponseWriter, err error) { (&routes{}).handleLookupError(w, err) },
		"patch":    writePatchError,
		"list":     writeInternalError,
	}
	for name, write := range writers {
		for _, driverErr := range driverErrs {
			logs.Reset()
			w := httptest.NewRecorder()
			write(w, driverErr)
			if strings.Contains(w.Body.String(), canary) || strings.Contains(logs.String(), canary) {
				t.Fatalf("%s: canary leaked: body=%q log=%q", name, w.Body.String(), logs.String())
			}
			if message := assertPatchError(t, w, http.StatusInternalServerError, "internal_error"); message != "internal server error" {
				t.Fatalf("%s: message = %q", name, message)
			}
			if !strings.Contains(logs.String(), "[redacted") {
				t.Fatalf("%s: the error was not logged redacted: %q", name, logs.String())
			}
		}
	}
}
