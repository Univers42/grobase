package provision

import "strings"

// Normalize lowercases/defaults the spec so downstream logic never re-derives a
// literal. It is idempotent: Normalize(Normalize(x)) == Normalize(x).
func (s *StackSpec) Normalize() {
	d := defaultSpec()
	s.Tenant = strings.ToLower(strings.TrimSpace(s.Tenant))
	if s.Name == "" {
		s.Name = s.Tenant
	}
	if s.Plan == "" {
		s.Plan = d.Plan
	}
	if s.Isolation == "" {
		s.Isolation = d.Isolation
	}
	normalizeKeys(s, d)
	normalizeEngines(s, d)
	normalizeRoles(s, d)
}

// normalizeKeys defaults a missing key set to one named default key, then stamps
// each key's name and scopes.
func normalizeKeys(s *StackSpec, d Defaults) {
	if len(s.Keys) == 0 {
		s.Keys = []KeySpec{{Name: d.KeyName}}
	}
	for i := range s.Keys {
		if strings.TrimSpace(s.Keys[i].Name) == "" {
			s.Keys[i].Name = d.KeyName
		}
		if len(s.Keys[i].Scopes) == 0 {
			s.Keys[i].Scopes = append([]string(nil), d.KeyScopes...)
		}
	}
}

// normalizeEngines lowercases each mount engine + isolation, defaulting the
// isolation when absent.
func normalizeEngines(s *StackSpec, d Defaults) {
	for i := range s.Engines {
		s.Engines[i].Engine = strings.ToLower(strings.TrimSpace(s.Engines[i].Engine))
		if strings.TrimSpace(s.Engines[i].Isolation) == "" {
			s.Engines[i].Isolation = d.MountIsolation
		} else {
			s.Engines[i].Isolation = strings.ToLower(strings.TrimSpace(s.Engines[i].Isolation))
		}
	}
}

// normalizeRoles lowercases role names and defaults each policy's fields.
func normalizeRoles(s *StackSpec, d Defaults) {
	for i := range s.Roles {
		s.Roles[i].Name = strings.ToLower(strings.TrimSpace(s.Roles[i].Name))
		for j := range s.Roles[i].Policies {
			normalizePolicy(&s.Roles[i].Policies[j], d)
		}
	}
}

func normalizePolicy(p *PolicySpec, d Defaults) {
	if p.ResourceType == "" {
		p.ResourceType = d.RolePolicy.ResourceType
	}
	if p.ResourceName == "" {
		p.ResourceName = d.RolePolicy.ResourceName
	}
	if p.Effect == "" {
		p.Effect = d.RolePolicy.Effect
	}
	if len(p.Actions) == 0 {
		p.Actions = append([]string(nil), d.RolePolicy.Actions...)
	}
}
