/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   trust.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:29 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:30 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package trust serves a read-only, public-readable security/compliance posture
// (Track-D D4.6, "Trust Center"). It is FILE-BACKED: a single machine-readable
// manifest (config/trust/posture.json) is the SINGLE SOURCE the endpoint serves,
// and that same manifest is the narrative spine of wiki/trust-center.md.
//
// There is NO database, NO migration, NO secrets here — the posture is the public
// half of the security story (what controls exist, which gate/wiki proves each).
// Every claim is an honest pointer: a control may be implemented|partial|planned,
// and an "implemented" claim MUST carry an evidence pointer (a mNN gate or a
// wiki/ doc). The m112 gate enforces exactly that honesty boundary, so the trust
// page can never silently go "all green".
//
// FLAG-GATED OFF = PARITY: Mount is called by main.go ONLY when
// TRUST_CENTER_ENABLED is truthy. When OFF (the default) Mount is never called, so
// /v1/trust* 404s — byte-identical to today.
package trust

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// embeddedManifest is a byte-identical copy of the canonical posture manifest at
// config/trust/posture.json, embedded so the control-plane binary needs no
// mounted file when TRUST_MANIFEST is unset (the same discipline internal/packages
// uses for packages.json). The m112 gate mounts the canonical file RO and asserts
// the served count == the file's count; this embed is the safe default + what the
// package unit test always exercises.
//
//go:embed posture.json
var embeddedManifest []byte

// EmbeddedManifest parses + validates the embedded posture copy. main.go falls
// back to this when TRUST_MANIFEST is unset, so the trust posture is always
// available without an operator mounting a file.
func EmbeddedManifest() (*Manifest, error) {
	return parseManifest(embeddedManifest, "<embedded posture.json>")
}

// Control is one posture line: a named security/compliance control, its category,
// its honest status, and a pointer to the evidence that proves it (a gate id like
// "m104" or a wiki path like "wiki/scale-slo.md"). Detail is optional prose.
type Control struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Status   string `json:"status"`
	Evidence string `json:"evidence"`
	Detail   string `json:"detail,omitempty"`
}

// Manifest is the whole posture document: a small envelope plus the controls
// array. Generated/version fields are descriptive only; controls is the payload.
type Manifest struct {
	Product   string    `json:"product"`
	Version   string    `json:"version,omitempty"`
	Note      string    `json:"note,omitempty"`
	Generated string    `json:"generated,omitempty"`
	Controls  []Control `json:"controls"`
}

// LoadManifest reads + validates the posture manifest from path. It is strict on
// purpose: a missing file, malformed JSON, an empty controls array, a control
// missing an id/status, a status outside the enum, or — the load-bearing honesty
// rule — a control claiming status "implemented" WITHOUT a non-empty evidence
// pointer, all return an error. A dishonest "implemented but unproven" claim must
// never boot.
func LoadManifest(path string) (*Manifest, error) {
	raw, err := os.ReadFile(path) //nolint:gosec // path is an operator-supplied fixture/config, not user input
	if err != nil {
		return nil, fmt.Errorf("trust: read manifest %q: %w", path, err)
	}
	return parseManifest(raw, path)
}

// parseManifest validates the manifest bytes (shared by LoadManifest and
// EmbeddedManifest). src is a label used in error messages.
func parseManifest(raw []byte, src string) (*Manifest, error) {
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("trust: parse manifest %q: %w", src, err)
	}
	if len(m.Controls) == 0 {
		return nil, fmt.Errorf("trust: manifest %q has no controls", src)
	}
	seen := make(map[string]bool, len(m.Controls))
	for i, c := range m.Controls {
		if err := validateControl(i, c, seen); err != nil {
			return nil, err
		}
	}
	return &m, nil
}

// validateControl enforces one control's honesty rules and records its id in seen
// (mutated). It rejects an empty/duplicate id, a status outside the enum, or — the
// load-bearing honesty boundary — an "implemented" claim with no evidence pointer:
// an unproven control may be partial/planned, never implemented-without-evidence.
func validateControl(i int, c Control, seen map[string]bool) error {
	id := strings.TrimSpace(c.ID)
	if id == "" {
		return fmt.Errorf("trust: control #%d has an empty id", i)
	}
	if seen[id] {
		return fmt.Errorf("trust: duplicate control id %q", id)
	}
	seen[id] = true
	if !isAllowedStatus(c.Status) {
		return fmt.Errorf("trust: control %q has invalid status %q (want implemented|partial|planned)", id, c.Status)
	}
	if c.Status == "implemented" && strings.TrimSpace(c.Evidence) == "" {
		return fmt.Errorf("trust: control %q is status=implemented but has NO evidence pointer (an unproven claim must be partial/planned)", id)
	}
	return nil
}

// SortControls returns the controls ordered by (category, id) for a stable,
// human-glanceable response. It copies, never mutating the manifest.
func SortControls(in []Control) []Control {
	out := make([]Control, len(in))
	copy(out, in)
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Category != out[j].Category {
			return out[i].Category < out[j].Category
		}
		return out[i].ID < out[j].ID
	})
	return out
}
