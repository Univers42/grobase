/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   respond.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:36 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package httpx

import (
	"encoding/json"
	"net/http"
	"regexp"
)

// RedactDSN replaces any DSN-shaped substring (scheme://[creds@]host…, e.g.
// postgres://user:pass@db:5432/app or redis://:secret@cache:6379) with a
// placeholder, so credentials reflected in an upstream error body never leak
// into a ResourceResult.Error or a log line.
func RedactDSN(s string) string {
	// perf: regex compiled per call — error-response path only (cold; runs on
	// upstream failures, not per request), so no shared package-level var.
	dsnRe := regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'\\]+`)
	return dsnRe.ReplaceAllString(s, "[redacted-dsn]")
}

// WriteJSON serializes v as a JSON response with the given status code.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError emits a structured JSON error.
func WriteError(w http.ResponseWriter, status int, code, message string) {
	WriteJSON(w, status, map[string]any{"error": code, "message": message, "statusCode": status})
}
