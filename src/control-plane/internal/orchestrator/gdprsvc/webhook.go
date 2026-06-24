/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   webhook.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:48:53 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:54 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package gdprsvc

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
)

/* ─────── webhook seams ─────── */

// httpExport GETs <url>?userId=<id> and returns the JSON body as app data. A
// missing URL, non-2xx, or transport error yields an empty map (parity with the
// Node behavior: warn + empty export).
func httpExport(client *http.Client, rawURL string, log *slog.Logger) exportFn {
	return func(ctx context.Context, userID string) map[string]any {
		empty := map[string]any{}
		if rawURL == "" {
			log.Warn("GDPR_EXPORT_WEBHOOK_URL not configured — returning empty export")
			return empty
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, exportURL(rawURL, userID), nil)
		if err != nil {
			log.Error("export webhook build failed", "err", err)
			return empty
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			log.Error("export webhook failed", "err", err)
			return empty
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			log.Warn("export webhook non-2xx", "status", resp.StatusCode)
			return empty
		}
		return decodeExport(resp.Body, empty)
	}
}

// exportURL appends userId to rawURL, preserving any existing query string.
func exportURL(rawURL, userID string) string {
	sep := "?"
	if strings.ContainsRune(rawURL, '?') {
		sep = "&"
	}
	return rawURL + sep + "userId=" + url.QueryEscape(userID)
}

// decodeExport reads up to 8 MiB of body as a JSON object, returning empty on
// any read/parse error (parity: warn + empty export).
func decodeExport(body io.Reader, empty map[string]any) map[string]any {
	var data map[string]any
	raw, _ := io.ReadAll(io.LimitReader(body, 8<<20))
	if err := json.Unmarshal(raw, &data); err != nil {
		return empty
	}
	return data
}

// httpDeletion POSTs {userId, action:"delete_user_data"} to the erasure webhook;
// failures are logged and swallowed (parity with the Node try/catch).
func httpDeletion(client *http.Client, rawURL string, log *slog.Logger) deletionFn {
	return func(ctx context.Context, userID string) {
		if rawURL == "" {
			log.Warn("GDPR_DELETION_WEBHOOK_URL not configured — skipping deletion callback")
			return
		}
		body, _ := json.Marshal(map[string]string{"userId": userID, "action": "delete_user_data"})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, rawURL, bytes.NewReader(body))
		if err != nil {
			log.Error("deletion webhook build failed", "err", err)
			return
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			log.Error("deletion webhook failed", "err", err)
			return
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			log.Error("deletion webhook non-2xx", "status", resp.StatusCode)
		}
	}
}
