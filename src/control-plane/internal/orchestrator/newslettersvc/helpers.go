/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   helpers.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:17 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package newslettersvc

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

func (s *Service) fail(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, errConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", "This email is already subscribed")
	case errors.Is(err, errNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "invalid token")
	default:
		s.log.Error("newsletter store error", "err", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "unexpected error")
	}
	return true
}

// httpEmailSender posts {to,subject,html,text} to <url>/send. A non-2xx is an
// error (counts as a campaign failure), matching the Node `r.value.ok` check.
func httpEmailSender(client *http.Client, url string) emailSender {
	endpoint := strings.TrimRight(url, "/") + "/send"
	return func(ctx context.Context, to, subject, html, text string) error {
		body, _ := json.Marshal(map[string]string{"to": to, "subject": subject, "html": html, "text": text})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			return errors.New("email-service returned " + resp.Status)
		}
		return nil
	}
}

func requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	_, ok := requireAdminUser(w, r)
	return ok
}

// requireAdminUser enforces service_role and returns the caller's user id (used
// as send_log.sent_by for campaigns).
func requireAdminUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	userID := r.Header.Get("X-Baas-User-Id")
	if userID == "" {
		userID = r.Header.Get("X-User-Id")
	}
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "missing verified identity")
		return "", false
	}
	if r.Header.Get("X-Baas-Role") != "service_role" {
		httpx.WriteError(w, http.StatusForbidden, "forbidden", "requires one of: service_role")
		return "", false
	}
	return userID, true
}

func newToken() string {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(buf)
}
