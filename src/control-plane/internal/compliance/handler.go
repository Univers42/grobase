/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:56 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:41:57 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package compliance

import (
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// Mount registers the SOC2-lite compliance evidence API onto the shared mux
// (D4.1). The caller mounts this ONLY when SOC2_EVIDENCE_ENABLED is truthy (the
// parity gate), exactly like audit.Mount / backup.Mount / abuseguard.Mount. When
// OFF, none of these routes exist and a request 404s — byte-identical to today.
//
// PLATFORM-LEVEL, ADMIN-ONLY: compliance evidence is about the Grobase platform,
// not any tenant, so every route requires a control-plane SERVICE TOKEN. There
// is NO tenant-self header path (unlike audit) — a tenant credential must never
// reach this surface. The 051 table is also service-role-only at the RLS layer,
// so a tenant could not read it even by direct DB access.
//
//	POST /v1/compliance/collect          run the collector → seal+persist a snapshot
//	GET  /v1/compliance/evidence         latest snapshot's sealed rows
//	GET  /v1/compliance/evidence/{sid}   one snapshot's sealed rows
//	GET  /v1/compliance/verify           recompute the latest snapshot's seals
//	GET  /v1/compliance/verify/{sid}     recompute one snapshot's seals
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/compliance/collect", rt.collect)
	mux.HandleFunc("GET /v1/compliance/evidence", rt.latest)
	mux.HandleFunc("GET /v1/compliance/evidence/{sid}", rt.bySnapshot)
	mux.HandleFunc("GET /v1/compliance/verify", rt.verifyLatest)
	mux.HandleFunc("GET /v1/compliance/verify/{sid}", rt.verifyOne)
}

type routes struct {
	svc          *Service
	serviceToken string
}

// SnapshotResponse is the collect / evidence body — the sealed section rows of a
// snapshot plus the verify summary (so a consumer can confirm completeness +
// integrity in one read).
type SnapshotResponse struct {
	SnapshotID  string        `json:"snapshot_id"`
	CollectedAt time.Time     `json:"collected_at,omitempty"`
	Count       int           `json:"count"`
	Verify      VerifyResult  `json:"verify"`
	Sections    []EvidenceRow `json:"sections"`
}

func (rt *routes) collect(w http.ResponseWriter, r *http.Request) {
	if !rt.admin(w, r) {
		return
	}
	sid, rows, err := rt.svc.Collect(r.Context())
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, buildResponse(sid, rows))
}

func (rt *routes) latest(w http.ResponseWriter, r *http.Request) {
	if !rt.admin(w, r) {
		return
	}
	sid, rows, err := rt.svc.Latest(r.Context())
	rt.writeSnapshot(w, sid, rows, err)
}

func (rt *routes) bySnapshot(w http.ResponseWriter, r *http.Request) {
	if !rt.admin(w, r) {
		return
	}
	sid, rows, err := rt.svc.BySnapshot(r.Context(), r.PathValue("sid"))
	rt.writeSnapshot(w, sid, rows, err)
}

func (rt *routes) verifyLatest(w http.ResponseWriter, r *http.Request) {
	if !rt.admin(w, r) {
		return
	}
	rt.doVerify(w, r, "")
}
