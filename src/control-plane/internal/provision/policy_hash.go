/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   policy_hash.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:31 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:32 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package provision

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// MountKey is the identity of a data mount resource.
func MountKey(slug, engine, name string) string {
	return "mount:" + slug + ":" + engine + ":" + name
}

// SchemaKey is the identity of a per-tenant schema resource.
func SchemaKey(slug, mountName string) string {
	return "schema:" + slug + ":" + mountName
}

// policyContentHash is a deterministic digest of a policy's semantic content so
// the same policy re-declared maps to the same identity (idempotent diff). It
// sorts actions so ordering doesn't change identity, and folds conditions in via
// their CANONICAL JSON — the EXACT bytes EnsurePolicy binds to `$5::jsonb`
// (Go marshals map keys sorted). Deriving the identity key and the stored DB
// value from one canonical form avoids drift (e.g. float64-vs-int JSON
// round-tripping, nested-value nondeterminism from the old `%v` formatting).
func policyContentHash(p PolicySpec) string {
	actions := append([]string(nil), p.Actions...)
	sort.Strings(actions)
	var b strings.Builder
	b.WriteString(p.ResourceType)
	b.WriteByte('|')
	b.WriteString(p.ResourceName)
	b.WriteByte('|')
	b.WriteString(strings.Join(actions, ","))
	b.WriteByte('|')
	b.WriteString(p.Effect)
	b.WriteByte('|')
	fmt.Fprintf(&b, "%d|", p.Priority)
	b.Write(canonicalConditionsJSON(p.Conditions))
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:8])
}

// canonicalConditionsJSON returns the canonical JSON for a policy's conditions,
// matching EnsurePolicy's `$5::jsonb` bind byte-for-byte (nil → "{}"; Go's
// encoding/json sorts map keys, giving a stable digest). Marshal of a
// map[string]any never errors, so a failure degrades to "{}" deterministically.
func canonicalConditionsJSON(conds map[string]any) []byte {
	if conds == nil {
		conds = map[string]any{}
	}
	out, err := json.Marshal(conds)
	if err != nil {
		return []byte("{}")
	}
	return out
}
