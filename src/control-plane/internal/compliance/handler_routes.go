package compliance

import (
	"errors"
	"net/http"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

func (rt *routes) verifyOne(w http.ResponseWriter, r *http.Request) {
	if !rt.admin(w, r) {
		return
	}
	rt.doVerify(w, r, r.PathValue("sid"))
}

// doVerify recomputes a snapshot's seals and writes the VerifyResult. It returns
// 200 whether the snapshot is intact or tampered — the CALLER acts on
// res.Intact. A tampered snapshot is a SUCCESSFUL verification that REPORTS the
// break, not a server error (the gate's load-bearing REJECT asserts intact==false
// + broken_section). A missing snapshot maps to 404.
func (rt *routes) doVerify(w http.ResponseWriter, r *http.Request, sid string) {
	res, err := rt.svc.Verify(r.Context(), sid)
	if err != nil {
		if errors.Is(err, errNoSnapshot) {
			httpx.WriteError(w, http.StatusNotFound, "not_found", "no compliance evidence snapshot")
			return
		}
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *routes) writeSnapshot(w http.ResponseWriter, sid string, rows []EvidenceRow, err error) {
	if err != nil {
		if errors.Is(err, errNoSnapshot) {
			httpx.WriteError(w, http.StatusNotFound, "not_found", "no compliance evidence snapshot")
			return
		}
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, buildResponse(sid, rows))
}

// buildResponse assembles the snapshot body + its verify summary from the sealed
// rows. The verify is recomputed over the SAME rows returned, so the consumer
// sees evidence + its integrity attestation atomically.
func buildResponse(sid string, rows []EvidenceRow) SnapshotResponse {
	var at time.Time
	if len(rows) > 0 {
		at = rows[0].CollectedAt
	}
	return SnapshotResponse{
		SnapshotID:  sid,
		CollectedAt: at,
		Count:       len(rows),
		Verify:      VerifySnapshot(sid, rows),
		Sections:    rows,
	}
}

// admin authorises by a control-plane service token ONLY. There is deliberately
// no tenant-self path: compliance evidence is platform-level and must never be
// reachable by a tenant credential.
func (rt *routes) admin(w http.ResponseWriter, r *http.Request) bool {
	if serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
	return false
}
