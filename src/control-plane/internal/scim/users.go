/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   users.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:55:45 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:55:46 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package scim

import (
	"strings"
	"time"
)

// users.go — the SCIM 2.0 User resource shapes (RFC 7643 §4.1 / §8.2) and the
// mapping between a SCIM User and an org member. SCIM Users are the IdP's view;
// org_members is Grobase's. The mapping is deliberately thin: a SCIM User maps to
// exactly ONE org member (org_id from the token binding, user_id resolved from
// the SCIM userName/externalId), and active:false soft-deactivates that member.

// SCIM schema URIs (RFC 7643 §10 / RFC 7644 §3.4.2 / §3.12).
const (
	schemaUser         = "urn:ietf:params:scim:schemas:core:2.0:User"
	schemaListResponse = "urn:ietf:params:scim:api:messages:2.0:ListResponse"
	schemaError        = "urn:ietf:params:scim:api:messages:2.0:Error"
	resourceTypeUser   = "User"
	contentTypeSCIM    = "application/scim+json"
	defaultMemberRole  = "developer" // SCIM-provisioned members default to this org role
)

// SCIMEmail is one entry in a User's emails multi-valued attribute.
type SCIMEmail struct {
	Value   string `json:"value"`
	Type    string `json:"type,omitempty"`
	Primary bool   `json:"primary,omitempty"`
}

// SCIMName is the User name complex attribute (only the parts we surface).
type SCIMName struct {
	Formatted  string `json:"formatted,omitempty"`
	GivenName  string `json:"givenName,omitempty"`
	FamilyName string `json:"familyName,omitempty"`
}

// SCIMMeta is the resource metadata block.
type SCIMMeta struct {
	ResourceType string `json:"resourceType"`
	Created      string `json:"created,omitempty"`
	LastModified string `json:"lastModified,omitempty"`
	Location     string `json:"location,omitempty"`
}

// SCIMUser is the wire shape of a SCIM 2.0 User resource (the create body, the
// GET/PUT response). `id` is the SCIM resource id; `userName` is the unique
// login; `externalId` is the IdP's own id; `active` drives provision/deprovision.
type SCIMUser struct {
	Schemas     []string    `json:"schemas"`
	ID          string      `json:"id,omitempty"`
	ExternalID  string      `json:"externalId,omitempty"`
	UserName    string      `json:"userName"`
	Name        *SCIMName   `json:"name,omitempty"`
	DisplayName string      `json:"displayName,omitempty"`
	Emails      []SCIMEmail `json:"emails,omitempty"`
	Active      bool        `json:"active"`
	Meta        *SCIMMeta   `json:"meta,omitempty"`
}

// ListResponse is the SCIM ListResponse envelope (filter/list results).
type ListResponse struct {
	Schemas      []string   `json:"schemas"`
	TotalResults int        `json:"totalResults"`
	StartIndex   int        `json:"startIndex"`
	ItemsPerPage int        `json:"itemsPerPage"`
	Resources    []SCIMUser `json:"Resources"`
}

// scimError is the SCIM Error envelope (RFC 7644 §3.12).
type scimError struct {
	Schemas  []string `json:"schemas"`
	Detail   string   `json:"detail"`
	Status   string   `json:"status"` // SCIM carries status as a STRING
	SCIMType string   `json:"scimType,omitempty"`
}

// PatchOp is the SCIM PATCH body: a list of operations.
type PatchOp struct {
	Schemas    []string         `json:"schemas"`
	Operations []PatchOperation `json:"Operations"`
}

// PatchOperation is one PATCH op (op ∈ replace|add|remove; path optional).
type PatchOperation struct {
	Op    string      `json:"op"`
	Path  string      `json:"path,omitempty"`
	Value interface{} `json:"value,omitempty"`
}

// toSCIMUser projects a stored userRecord into the SCIM wire shape.
func (u userRecord) toSCIM() SCIMUser {
	emails := u.Emails
	if emails == nil {
		emails = []SCIMEmail{}
	}
	su := SCIMUser{
		Schemas:     []string{schemaUser},
		ID:          u.SCIMID,
		UserName:    u.UserName,
		DisplayName: u.DisplayName,
		Emails:      emails,
		Active:      u.Active,
		Meta:        &SCIMMeta{ResourceType: resourceTypeUser},
	}
	if !u.CreatedAt.IsZero() {
		su.Meta.Created = u.CreatedAt.UTC().Format(time.RFC3339)
	}
	if !u.UpdatedAt.IsZero() {
		su.Meta.LastModified = u.UpdatedAt.UTC().Format(time.RFC3339)
	}
	su.Meta.Location = "/scim/v2/Users/" + u.SCIMID
	return su
}

// primaryEmail returns the SCIM User's best email (primary, else first, else the
// userName when it looks like an email) — the value used as the org member id
// hint and the display fallback.
func (su SCIMUser) primaryEmail() string {
	for _, e := range su.Emails {
		if e.Primary && e.Value != "" {
			return e.Value
		}
	}
	if len(su.Emails) > 0 {
		return su.Emails[0].Value
	}
	if strings.Contains(su.UserName, "@") {
		return su.UserName
	}
	return ""
}

// resolveUserID derives the GoTrue user id this SCIM User maps to. The IdP's
// externalId is preferred (it is the IdP's stable user key); otherwise the
// userName is used. This is a control-plane identity hint — it never enters the
// data plane or the RLS GUCs. (A future enhancement could look the user up in
// gotrue; the membership row only needs a stable id string.)
func (su SCIMUser) resolveUserID() string {
	if id := strings.TrimSpace(su.ExternalID); id != "" {
		return id
	}
	return strings.TrimSpace(su.UserName)
}

// displayName picks the best human label for the User (displayName, else the
// formatted name, else the userName).
func (su SCIMUser) displayName() string {
	if su.DisplayName != "" {
		return su.DisplayName
	}
	if su.Name != nil && su.Name.Formatted != "" {
		return su.Name.Formatted
	}
	return su.UserName
}
