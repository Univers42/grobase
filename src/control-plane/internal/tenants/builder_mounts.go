/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   builder_mounts.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:58:25 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:58:27 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// createMount registers a mount for the CALLER's own tenant via the adapter-
// registry. The engine allowlist + max_mounts cap are enforced DOWNSTREAM by the
// adapter-registry against the EFFECTIVE (resolved+clamped) package — the SAME
// gate /connect uses — so the builder does not re-implement the tier check; it
// just forwards the caller-scoped registration. [scope: write]
func (b *builderAPI) createMount(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := b.selfAuthScope(w, r, "write")
	if !ok {
		return
	}
	if !b.requireAdapter(w, "mount registration") {
		return
	}
	req, ok := decodeMountSpec(w, r)
	if !ok {
		return
	}
	id, status, err := b.adapter.register(r.Context(), tenantID, req)
	if err != nil {
		writeAdapterError(w, err)
		return
	}
	code := http.StatusCreated
	if status == "exists" {
		code = http.StatusOK
	}
	httpx.WriteJSON(w, code, map[string]any{"id": id, "status": status, "engine": req.Engine, "name": req.Name})
}

// decodeMountSpec decodes the body and requires engine+name. ok=false means a
// 400 was written.
func decodeMountSpec(w http.ResponseWriter, r *http.Request) (MountSpec, bool) {
	var req MountSpec
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return MountSpec{}, false
	}
	if strings.TrimSpace(req.Engine) == "" || strings.TrimSpace(req.Name) == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "engine and name are required")
		return MountSpec{}, false
	}
	return req, true
}

// requireAdapter writes a clean 503 and returns false when the adapter-registry
// client is unset (ADAPTER_REGISTRY_URL unset).
func (b *builderAPI) requireAdapter(w http.ResponseWriter, action string) bool {
	if b.adapter != nil {
		return true
	}
	httpx.WriteError(w, http.StatusServiceUnavailable, "adapter_unavailable",
		action+" unavailable (ADAPTER_REGISTRY_URL not set)")
	return false
}

// writeAdapterError maps a register error to the right status: the adapter-
// registry maps an over-tier engine / mount-quota to 403 (surface its message),
// a transport/5xx surfaces as 502.
func writeAdapterError(w http.ResponseWriter, err error) {
	msg := err.Error()
	if strings.Contains(msg, "403") {
		httpx.WriteError(w, http.StatusForbidden, "mount_denied", msg)
		return
	}
	httpx.WriteError(w, http.StatusBadGateway, "adapter_error", msg)
}

// deleteMount deletes one of the caller's OWN mounts by id, CALLER-SCOPED. The
// adapter-registry's caller-scoped delete binds `AND tenant_id = $caller`, so a
// mount UUID is NEVER a bearer capability — a tenant can never delete another
// tenant's mount even by guessing the uuid. [scope: write]
func (b *builderAPI) deleteMount(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := b.selfAuthScope(w, r, "write")
	if !ok {
		return
	}
	if !b.requireAdapter(w, "mount deletion") {
		return
	}
	id, ok := mountIDParam(w, r)
	if !ok {
		return
	}
	deleted, err := b.adapter.deleteMount(r.Context(), tenantID, id)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "adapter_error", err.Error())
		return
	}
	if !deleted {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "no such mount for this tenant")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

// mountIDParam reads {mountId} as a UUID. PathValue is the UNESCAPED segment, so without
// this an id carrying %2F would splice extra path into the adapter-registry URL.
func mountIDParam(w http.ResponseWriter, r *http.Request) (string, bool) {
	id := r.PathValue("mountId")
	if !isUUID(id) {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "no such mount for this tenant")
		return "", false
	}
	return id, true
}

// patchMount updates one of the caller's OWN mounts by id, CALLER-SCOPED (the
// adapter-registry binds the update to the asserted tenant, so a mount UUID is
// NEVER a bearer capability). The body is forwarded VERBATIM — a decode/re-
// marshal round trip dropped fields in this codebase — and the registry's
// answer is relayed by writePatchResult. [scope: write]
func (b *builderAPI) patchMount(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := b.selfAuthScope(w, r, "write")
	if !ok {
		return
	}
	if !b.requireAdapter(w, "mount update") {
		return
	}
	id, ok := mountIDParam(w, r)
	if !ok {
		return
	}
	body, ok := readMountPatchBody(w, r)
	if !ok {
		return
	}
	status, respBody, err := b.adapter.patchMount(r.Context(), tenantID, id, body)
	if err != nil {
		httpx.WriteError(w, http.StatusBadGateway, "adapter_error", err.Error())
		return
	}
	writePatchResult(w, status, respBody)
}

// readMountPatchBody reads the raw body under a 64 KiB cap so its bytes can be
// forwarded untouched; ok=false means a 413/400 was written.
func readMountPatchBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err == nil {
		return body, true
	}
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		httpx.WriteError(w, http.StatusRequestEntityTooLarge, "payload_too_large", "body exceeds 64 KiB")
		return nil, false
	}
	httpx.WriteError(w, http.StatusBadRequest, "bad_request", "unreadable body")
	return nil, false
}

// writePatchResult relays the registry's answer: 200 and the safe 400/403/409
// {error,message} bodies pass through untouched, a 404 is the caller-scoped
// not_found, anything else is a 502 — an unexpected body is never relayed
// (it is not a shape the registry vetted as safe).
func writePatchResult(w http.ResponseWriter, status int, respBody json.RawMessage) {
	switch status {
	case http.StatusOK, http.StatusBadRequest, http.StatusForbidden, http.StatusConflict:
		httpx.WriteJSON(w, status, respBody)
	case http.StatusNotFound:
		httpx.WriteError(w, http.StatusNotFound, "not_found", "no such mount for this tenant")
	default:
		httpx.WriteError(w, http.StatusBadGateway, "adapter_error",
			fmt.Sprintf("adapter-registry returned %d", status))
	}
}
