/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   shared_resources_test.go                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:39:12 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:39:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package adapterregistry

import "testing"

// TestMergeSharedResourcesParity pins the byte-parity contract: a mount with NO
// shared_resources leaves CapabilityOverrides untouched (nil stays nil), while a
// populated list is stamped under the reserved key the data plane reads — even
// when the tier mask is nil (PACKAGE_ENFORCEMENT off), which forces the map to be
// allocated.
func TestMergeSharedResourcesParity(t *testing.T) {
	if got := mergeSharedResources(ConnectionResult{}, nil); got.CapabilityOverrides != nil {
		t.Fatalf("nil shared list must leave CapabilityOverrides nil, got %v", got.CapabilityOverrides)
	}
	if got := mergeSharedResources(ConnectionResult{}, []string{}); got.CapabilityOverrides != nil {
		t.Fatalf("empty shared list must leave CapabilityOverrides nil, got %v", got.CapabilityOverrides)
	}

	got := mergeSharedResources(ConnectionResult{}, []string{"catalog", "regions"})
	arr, ok := got.CapabilityOverrides["shared_resources"].([]string)
	if !ok {
		t.Fatalf("shared_resources not stamped as []string: %#v", got.CapabilityOverrides["shared_resources"])
	}
	if len(arr) != 2 || arr[0] != "catalog" || arr[1] != "regions" {
		t.Fatalf("unexpected shared_resources: %v", arr)
	}

	withMask := ConnectionResult{CapabilityOverrides: map[string]any{"aggregate": true}}
	merged := mergeSharedResources(withMask, []string{"catalog"})
	if merged.CapabilityOverrides["aggregate"] != true {
		t.Fatalf("existing tier mask key dropped during merge")
	}
	if _, ok := merged.CapabilityOverrides["shared_resources"]; !ok {
		t.Fatalf("shared_resources not merged onto an existing mask")
	}
}

// TestDecodeSharedResources pins NULL/malformed JSONB → nil (parity) and a valid
// array → the named tables.
func TestDecodeSharedResources(t *testing.T) {
	if got := decodeSharedResources(nil); got != nil {
		t.Fatalf("NULL column must decode to nil, got %v", got)
	}
	if got := decodeSharedResources([]byte("not json")); got != nil {
		t.Fatalf("malformed JSONB must degrade to nil, got %v", got)
	}
	got := decodeSharedResources([]byte(`["catalog","regions"]`))
	if len(got) != 2 || got[0] != "catalog" || got[1] != "regions" {
		t.Fatalf("unexpected decode: %v", got)
	}
}

// TestValidateSharedResources rejects entries with whitespace, quotes, or
// semicolons while accepting plain (optionally schema-qualified) table names; an
// empty list is valid (no opt-in = parity).
func TestValidateSharedResources(t *testing.T) {
	cases := []struct {
		name    string
		names   []string
		wantErr bool
	}{
		{"empty ok", nil, false},
		{"plain names ok", []string{"catalog", "regions"}, false},
		{"schema qualified ok", []string{"public.catalog"}, false},
		{"underscore digits ok", []string{"shared_table_2"}, false},
		{"whitespace rejected", []string{"bad name"}, true},
		{"quote rejected", []string{`bad"name`}, true},
		{"semicolon rejected", []string{"drop;table"}, true},
		{"empty entry rejected", []string{""}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateSharedResources(tc.names)
			if tc.wantErr && err == nil {
				t.Fatalf("validateSharedResources(%v) = nil, want error", tc.names)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("validateSharedResources(%v) = %v, want nil", tc.names, err)
			}
		})
	}
}
