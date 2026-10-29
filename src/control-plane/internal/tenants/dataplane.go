/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   dataplane.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:58:37 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:58:39 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/observability"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// DataPlane is a minimal client for the Rust data-plane-router's admin migrate
// endpoint, used to create a per-tenant schema for schema_per_tenant mounts.
type DataPlane struct {
	baseURL      string
	serviceToken string
	http         *http.Client
	relayHTTP    *http.Client
}

// adminRelayTimeout covers Kong's default 60 s upstream read timeout on
// /admin/v1/{migrate,rotate}; the 8 s provisioning client would cut off a
// migration that works through Kong today.
const adminRelayTimeout = 65 * time.Second

// dataPlaneMaxResp bounds how much of a data-plane response is read.
const dataPlaneMaxResp = 1 << 20

// NewDataPlane builds a client. baseURL e.g. http://data-plane-router-rust:4011.
func NewDataPlane(baseURL, serviceToken string) *DataPlane {
	return &DataPlane{
		baseURL:      strings.TrimRight(baseURL, "/"),
		serviceToken: serviceToken,
		http:         &http.Client{Timeout: 8 * time.Second},
		relayHTTP:    &http.Client{Timeout: adminRelayTimeout},
	}
}

// ensureSchema runs `CREATE SCHEMA IF NOT EXISTS <schema>` against the mount's
// database via POST /v1/admin/migrate (admin-gated, idempotent marker). `schema`
// must already be sanitized by [tenantSchema] — it is interpolated into the DDL.
// The migrate envelope carries the inline DSN, so the response is scrubbed of any
// echo of it.
func (dp *DataPlane) ensureSchema(ctx context.Context, slug, schema string, m MountSpec) error {
	envelope := map[string]any{
		"identity": map[string]any{
			"tenant_id": slug,
			"user_id":   "provision-control",
			"source":    "service_token",
			"roles":     []string{"service_role"},
		},
		"mount": map[string]any{
			"id":             "provision-" + slug,
			"tenant_id":      slug,
			"engine":         m.Engine,
			"name":           m.Name,
			"credential_ref": map[string]any{"provider": "inline", "reference": m.Name, "version": "1"},
			"inline_dsn":     m.ConnectionString,
		},
		"name":       "baas-ensure-schema-" + schema,
		"statements": []string{"CREATE SCHEMA IF NOT EXISTS " + schema},
	}
	return dp.postAdmin(ctx, "/v1/admin/migrate", envelope, "data-plane migrate", true)
}

// evictVerify clears the data plane's key-verify cache (B3): without it a
// revoked key keeps authenticating there for up to the cache TTL (~30s).
// Same in-network admin trust model as ensureSchema (body-borne service
// identity). Callers treat failures as best-effort — the TTL still bounds
// the exposure when the data plane is unreachable.
func (dp *DataPlane) evictVerify(ctx context.Context) error {
	envelope := map[string]any{
		"identity": map[string]any{
			"tenant_id": "tenant-control",
			"user_id":   "revoke-control",
			"source":    "service_token",
			"roles":     []string{"service_role"},
		},
	}
	return dp.postAdmin(ctx, "/v1/admin/evict-verify", envelope, "data-plane evict-verify", false)
}

// postAdmin marshals a service-identity envelope and POSTs it to an admin
// endpoint. A non-200 is an error labelled errLabel; redact scrubs any DSN echo
// from the body.
func (dp *DataPlane) postAdmin(ctx context.Context, path string, envelope map[string]any, errLabel string, redact bool) error {
	body, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	status, resp, err := dp.postSigned(ctx, dp.http, path, body)
	if err != nil {
		return err
	}
	return dataPlaneRespErr(status, resp, errLabel, redact)
}

// postSigned POSTs body to path with the service auth the receiver verifies and
// returns the status and up to dataPlaneMaxResp bytes of the response. It is the
// one signer for every data-plane call from tenant-control.
func (dp *DataPlane) postSigned(ctx context.Context, client *http.Client, path string, body []byte) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, dp.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	serviceauth.SignRequest(req, dp.serviceToken, body)
	observability.PropagateHeaders(ctx, req)
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	b, err := io.ReadAll(io.LimitReader(resp.Body, dataPlaneMaxResp))
	return resp.StatusCode, b, err
}

// dataPlaneRespErr returns nil on 200, else a labelled error built from the first
// 512 bytes of the body (DSN-redacted when redact is set).
func dataPlaneRespErr(status int, body []byte, errLabel string, redact bool) error {
	if status == http.StatusOK {
		return nil
	}
	if len(body) > 512 {
		body = body[:512]
	}
	msg := strings.TrimSpace(string(body))
	if redact {
		msg = httpx.RedactDSN(msg)
	}
	return fmt.Errorf("%s %d: %s", errLabel, status, msg)
}
