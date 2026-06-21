/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   compile.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:03 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:04 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package provision

import "sort"

// Compile expands a Normalized+Validated StackSpec into a DesiredState. Engines
// become mount (+ optional schema) resources; roles become role + policy
// resources. Resources are deduped by identity Key and topo-sorted by Kind.
//
// Identity keys (stable, content-derived where needed):
//
//	tenant:<slug>
//	key:<slug>:<name>
//	role:<slug>:<role>
//	policy:<roleKey>:<contentHash>
//	mount:<slug>:<engine>:<name>
//	schema:<slug>:<mountName>
func (s StackSpec) Compile() DesiredState {
	ds := DesiredState{Slug: s.Tenant, Name: s.Name, OwnerUser: s.OwnerUserID, Plan: s.Plan}
	seen := make(map[string]struct{})
	add := func(r Resource) {
		if _, dup := seen[r.Key]; dup {
			return
		}
		seen[r.Key] = struct{}{}
		ds.Resources = append(ds.Resources, r)
	}
	add(Resource{Kind: KindTenant, Key: TenantKey(s.Tenant)})
	s.compileKeys(add)
	s.compileRoles(add)
	s.compileEngines(add)
	sort.SliceStable(ds.Resources, func(i, j int) bool {
		return ds.Resources[i].Kind < ds.Resources[j].Kind
	})
	return ds
}

// compileKeys emits one KindKey resource per declared API key.
func (s StackSpec) compileKeys(add func(Resource)) {
	for _, k := range s.Keys {
		add(Resource{Kind: KindKey, Key: KeyKey(s.Tenant, k.Name), Key3: k})
	}
}

// compileRoles emits a KindRole resource per role plus a KindPolicy resource per
// policy declared under it.
func (s StackSpec) compileRoles(add func(Resource)) {
	for _, role := range s.Roles {
		roleKey := RoleKey(s.Tenant, role.Name)
		add(Resource{Kind: KindRole, Key: roleKey, Role: role})
		for _, p := range role.Policies {
			add(Resource{Kind: KindPolicy, Key: PolicyKey(roleKey, p), RoleRef: roleKey, Policy: p})
		}
	}
}

// compileEngines emits a KindMount resource per data mount plus a KindSchema
// resource when the mount uses schema_per_tenant isolation.
func (s StackSpec) compileEngines(add func(Resource)) {
	for _, e := range s.Engines {
		mountKey := MountKey(s.Tenant, e.Engine, e.Name)
		add(Resource{Kind: KindMount, Key: mountKey, Engine: e})
		if e.Isolation == "schema_per_tenant" {
			add(Resource{Kind: KindSchema, Key: SchemaKey(s.Tenant, e.Name), Key2: mountKey, Engine: e})
		}
	}
}
