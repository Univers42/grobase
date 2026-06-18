package trust

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// loadEmbedded is the always-self-contained manifest the test exercises (the
// package embeds a byte-identical copy of config/trust/posture.json, the same
// discipline internal/packages uses). It works with only the Go module mounted.
func loadEmbedded(t *testing.T) *Manifest {
	t.Helper()
	m, err := EmbeddedManifest()
	if err != nil {
		t.Fatalf("EmbeddedManifest: %v", err)
	}
	return m
}

func TestEmbeddedManifest_Honest(t *testing.T) {
	m := loadEmbedded(t)
	if len(m.Controls) == 0 {
		t.Fatal("manifest has no controls")
	}
	for _, c := range m.Controls {
		if strings.TrimSpace(c.ID) == "" {
			t.Errorf("control with empty id: %+v", c)
		}
		if !isAllowedStatus(c.Status) {
			t.Errorf("control %q has status %q outside enum", c.ID, c.Status)
		}
		if strings.TrimSpace(c.Evidence) == "" {
			t.Errorf("control %q has an empty evidence pointer (every control must point somewhere)", c.ID)
		}
		// The honesty boundary (LoadManifest enforces it; assert it too).
		if c.Status == "implemented" && strings.TrimSpace(c.Evidence) == "" {
			t.Errorf("control %q is implemented but unproven", c.ID)
		}
	}
	// The headline gate-proven controls the trust narrative promises must be
	// present: audit(m104), erase(m105), export(m109), soc2(m108).
	want := map[string]bool{"m104": false, "m105": false, "m108": false, "m109": false}
	for _, c := range m.Controls {
		for k := range want {
			if strings.Contains(c.Evidence, k) {
				want[k] = true
			}
		}
	}
	for k, found := range want {
		if !found {
			t.Errorf("manifest is missing a control citing %s (the trust narrative promises it)", k)
		}
	}
}

// TestEmbeddedMatchesCanonical asserts the embedded copy stays byte-identical to
// config/trust/posture.json when that file is reachable (i.e. when the full repo
// is mounted, as in the converge build). If only the module is mounted, the
// canonical file is absent and the check is skipped — the embed alone is then the
// source of truth, which is the safe runtime default anyway.
func TestEmbeddedMatchesCanonical(t *testing.T) {
	p := filepath.Join("..", "..", "..", "..", "config", "trust", "posture.json")
	canon, err := os.ReadFile(p)
	if err != nil {
		t.Skipf("canonical %s not reachable (module-only mount): %v", p, err)
	}
	if string(canon) != string(embeddedManifest) {
		t.Errorf("embedded posture.json drifted from canonical %s — copy config/trust/posture.json into internal/trust/", p)
	}
}

func TestLoadManifest_RejectsImplementedWithoutEvidence(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "bad.json")
	bad := `{"product":"x","controls":[{"id":"c1","name":"n","category":"cat","status":"implemented","evidence":""}]}`
	if err := os.WriteFile(p, []byte(bad), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadManifest(p); err == nil {
		t.Fatal("expected LoadManifest to REJECT an implemented control with no evidence")
	}
}

func TestLoadManifest_RejectsBadStatus(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "bad.json")
	bad := `{"product":"x","controls":[{"id":"c1","name":"n","category":"cat","status":"green","evidence":"m1"}]}`
	if err := os.WriteFile(p, []byte(bad), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadManifest(p); err == nil {
		t.Fatal("expected LoadManifest to REJECT a status outside the enum")
	}
}

func TestLoadManifest_RejectsEmpty(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "empty.json")
	if err := os.WriteFile(p, []byte(`{"product":"x","controls":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadManifest(p); err == nil {
		t.Fatal("expected LoadManifest to REJECT a manifest with no controls")
	}
}

func TestEndpointReflectsManifestCount(t *testing.T) {
	m := loadEmbedded(t)
	mux := http.NewServeMux()
	Mount(mux, m)

	// GET /v1/trust/controls -> count == len(manifest.Controls).
	req := httptest.NewRequest(http.MethodGet, "/v1/trust/controls", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /v1/trust/controls: want 200 got %d", rec.Code)
	}
	var body struct {
		Count    int       `json:"count"`
		Controls []Control `json:"controls"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Count != len(m.Controls) {
		t.Errorf("served count %d != manifest controls %d (endpoint must reflect the file)", body.Count, len(m.Controls))
	}
	if len(body.Controls) != len(m.Controls) {
		t.Errorf("served controls %d != manifest controls %d", len(body.Controls), len(m.Controls))
	}

	// GET /v1/trust -> same controls count in the envelope.
	req = httptest.NewRequest(http.MethodGet, "/v1/trust", nil)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /v1/trust: want 200 got %d", rec.Code)
	}
	var full Manifest
	if err := json.Unmarshal(rec.Body.Bytes(), &full); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if len(full.Controls) != len(m.Controls) {
		t.Errorf("envelope controls %d != manifest %d", len(full.Controls), len(m.Controls))
	}
}
