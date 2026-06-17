package scim

import "strings"

// groups.go — the PATCH-operation interpreter (the IdP's primary deprovision
// signal arrives as PATCH replace active=false) plus the minimal SCIM Group
// shape. Grobase maps a SCIM User to an org member; SCIM Groups map to org roles
// conceptually, but the D2b MVP surfaces only Users (the deactivate/deprovision
// lifecycle), so the Group type here is the projection used by the read-only
// ServiceProviderConfig discovery, not a writable resource.

// patchedActive walks a PATCH body and returns the requested `active` value when
// the operations set it (the deprovision signal), plus ok=false if no op touched
// active. It tolerates the two shapes IdPs emit:
//
//	{"op":"replace","path":"active","value":false}
//	{"op":"replace","value":{"active":false}}   // path-less, value is an object
//
// Both Okta and Entra are accommodated. Any non-active op is ignored (we only
// act on the lifecycle signal SCIM provisioning needs).
func patchedActive(p PatchOp) (active bool, ok bool) {
	for _, op := range p.Operations {
		if !strings.EqualFold(op.Op, "replace") && !strings.EqualFold(op.Op, "add") {
			continue
		}
		// path == "active": value is the boolean directly.
		if strings.EqualFold(strings.TrimSpace(op.Path), "active") {
			if b, isBool := asBool(op.Value); isBool {
				return b, true
			}
			continue
		}
		// path-less: value is an object that may carry {"active": ...}.
		if strings.TrimSpace(op.Path) == "" {
			if m, isMap := op.Value.(map[string]interface{}); isMap {
				if v, present := m["active"]; present {
					if b, isBool := asBool(v); isBool {
						return b, true
					}
				}
			}
		}
	}
	return false, false
}

// asBool coerces the loosely-typed PATCH value into a bool. JSON booleans decode
// to bool; some IdPs send the strings "true"/"false".
func asBool(v interface{}) (bool, bool) {
	switch t := v.(type) {
	case bool:
		return t, true
	case string:
		switch strings.ToLower(strings.TrimSpace(t)) {
		case "true":
			return true, true
		case "false":
			return false, true
		}
	}
	return false, false
}

// SCIMGroup is the (read-only, discovery-only) Group projection. A Group maps to
// an org role; the D2b MVP does not provision Groups, so this shape exists only
// for the ServiceProviderConfig/ResourceTypes discovery surface.
type SCIMGroup struct {
	Schemas     []string  `json:"schemas"`
	ID          string    `json:"id,omitempty"`
	DisplayName string    `json:"displayName"`
	Meta        *SCIMMeta `json:"meta,omitempty"`
}
