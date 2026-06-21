/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   handler.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:19 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:20 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package trust

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// Mount registers the read-only Trust Center routes onto the shared mux (D4.6).
// The caller mounts this ONLY when TRUST_CENTER_ENABLED is truthy (the parity
// gate), exactly like compliance.Mount / audit.Mount. When OFF, none of these
// routes exist and a request 404s — byte-identical to today.
//
// PUBLIC-READABLE BY DESIGN: a trust center is the public half of the security
// story (what controls exist + which gate/wiki proves each). There are NO secrets
// in the manifest and NO tenant data, so these routes need NO auth — a prospect
// or auditor can read the posture without a credential, the same way a status page
// is public. (A service-token POST /v1/trust/attest that seals the manifest into
// the D4.1 compliance store was DEFERRED to keep this slice independent of the
// compliance package.)
//
//	GET /v1/trust            -> 200, the full posture manifest (envelope + controls)
//	GET /v1/trust/controls   -> 200, just the controls array (sorted by category,id)
//
// The manifest is loaded ONCE at Mount (boot) — it is immutable config, not
// per-request state — so a malformed manifest fails boot fast on this opt-in path
// rather than returning a degraded posture at request time.
func Mount(mux *http.ServeMux, m *Manifest) {
	rt := &routes{manifest: m}
	mux.HandleFunc("GET /v1/trust", rt.posture)
	mux.HandleFunc("GET /v1/trust/controls", rt.controls)
}

type routes struct {
	manifest *Manifest
}

// posture serves the whole manifest (envelope + controls), controls sorted for a
// stable, glanceable response. It copies the envelope and replaces controls with
// the sorted view.
func (rt *routes) posture(w http.ResponseWriter, _ *http.Request) {
	out := *rt.manifest
	out.Controls = SortControls(rt.manifest.Controls)
	httpx.WriteJSON(w, http.StatusOK, out)
}

// controls serves just the controls array (the same payload the m112 gate counts
// against config/trust/posture.json to prove the endpoint reflects the file).
func (rt *routes) controls(w http.ResponseWriter, _ *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"count":    len(rt.manifest.Controls),
		"controls": SortControls(rt.manifest.Controls),
	})
}
