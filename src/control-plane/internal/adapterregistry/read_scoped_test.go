/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   read_scoped_test.go                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:38:49 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:38:51 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import "testing"

// TestMergeReadScopedParity pins the byte-parity contract: a mount that did NOT
// opt into read_scoped (false, the column default) leaves CapabilityOverrides
// untouched, while an opted-in mount stamps the reserved key the data plane reads
// — even when the tier mask is nil (PACKAGE_ENFORCEMENT off), which forces the
// map to be allocated.
func TestMergeReadScopedParity(t *testing.T) {
	if got := mergeReadScoped(ConnectionResult{}, false); got.CapabilityOverrides != nil {
		t.Fatalf("read_scoped=false must leave CapabilityOverrides nil, got %v", got.CapabilityOverrides)
	}

	got := mergeReadScoped(ConnectionResult{}, true)
	if got.CapabilityOverrides["read_scoped"] != true {
		t.Fatalf("read_scoped=true must stamp the reserved key, got %#v", got.CapabilityOverrides["read_scoped"])
	}

	withMask := ConnectionResult{CapabilityOverrides: map[string]any{"aggregate": true}}
	merged := mergeReadScoped(withMask, true)
	if merged.CapabilityOverrides["aggregate"] != true {
		t.Fatalf("existing tier mask key dropped during read_scoped merge")
	}
	if merged.CapabilityOverrides["read_scoped"] != true {
		t.Fatalf("read_scoped not merged onto an existing mask")
	}
}

// TestMergeReadScopedCoexistsWithSharedResources proves the two per-mount
// overrides stack: a mount declaring BOTH carries shared_resources AND
// read_scoped in one CapabilityOverrides map (the order stampMountOverrides
// applies them in).
func TestMergeReadScopedCoexistsWithSharedResources(t *testing.T) {
	r := mergeReadScoped(mergeSharedResources(ConnectionResult{}, []string{"catalog"}), true)
	if _, ok := r.CapabilityOverrides["shared_resources"]; !ok {
		t.Fatalf("shared_resources dropped when read_scoped also set")
	}
	if r.CapabilityOverrides["read_scoped"] != true {
		t.Fatalf("read_scoped dropped when shared_resources also set")
	}
}
