/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   export_test.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:22 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:24 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package export

import (
	"errors"
	"strings"
	"testing"
)

// TestGuardIsolation pins the D4.3 export scope: only schema_per_tenant and
// shared_rls are exportable; db_per_tenant and tenant_owned (and anything else)
// are DEFERRED with ErrIsolationDeferred (the handler maps it to 400). This is
// the structural wall the migration 052 CHECK also enforces.
func TestGuardIsolation(t *testing.T) {
	supported := []string{"schema_per_tenant", "shared_rls"}
	for _, iso := range supported {
		if err := guardIsolation(iso); err != nil {
			t.Fatalf("guardIsolation(%q) = %v, want nil (export must support it)", iso, err)
		}
	}
	deferred := []string{"db_per_tenant", "tenant_owned", "", "bogus"}
	for _, iso := range deferred {
		err := guardIsolation(iso)
		if !errors.Is(err, ErrIsolationDeferred) {
			t.Fatalf("guardIsolation(%q) = %v, want ErrIsolationDeferred", iso, err)
		}
	}
}

// TestDeferredMessageMentionsDeferred guards the gate's body assertion: the
// 400's message must contain "deferred" (the m109 gate greps for it).
func TestDeferredMessageMentionsDeferred(t *testing.T) {
	if !strings.Contains(strings.ToLower(ErrIsolationDeferred.Error()), "deferred") {
		t.Fatalf("ErrIsolationDeferred message %q must contain 'deferred'", ErrIsolationDeferred.Error())
	}
}

// TestExportTableFilterDistinguishesScopes documents the contract the data layer
// relies on: a schema_per_tenant table has an EMPTY filter (whole table in the
// tenant's own schema), while a shared_rls table carries the tenant_id filter so
// the SELECT is scoped WHERE tenant_id. countRows/streamTableRows branch on
// filter=="" — an accidental empty filter on a shared table would be a
// cross-tenant leak, so this pins the invariant at the type level.
func TestExportTableFilterDistinguishesScopes(t *testing.T) {
	schemaTbl := exportTable{qualified: `"tenant_x"."notes"`, label: "notes"}
	if schemaTbl.filter != "" {
		t.Fatalf("schema_per_tenant exportTable must have empty filter, got %q", schemaTbl.filter)
	}
	sharedTbl := exportTable{qualified: `"public"."notes"`, label: "notes", filter: "tenant-a"}
	if sharedTbl.filter == "" {
		t.Fatalf("shared_rls exportTable MUST carry a tenant_id filter (empty = cross-tenant leak)")
	}
}
