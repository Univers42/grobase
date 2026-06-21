/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   collect_posture.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:44 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:41:45 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package compliance

import (
	"context"
	"encoding/json"
)

// accessGrant is one observed role grant: which role can do what on which
// sensitive control table.
type accessGrant struct {
	Role      string `json:"role"`
	Table     string `json:"table"`
	Privilege string `json:"privilege"`
}

// accessReviewSQL reads role grants on the sensitive control tables from the
// live catalog — the actual, observable access posture (not an assertion). It
// scopes to the platform's control tables so the review is meaningful and small,
// and now covers the newer enterprise-control surface (audit trail, GDPR erasure
// receipts, WebAuthn credentials, SSO/SCIM, CMEK-bearing mounts, ABAC policies)
// so the access section evidences the broader certification surface.
//
// The list is a FIXED, in-query allowlist of ACTUAL table names verified against
// the migrations (047/048/050/051/053/054 create their tables; CMEK lives as
// columns on public.tenant_databases (061) and ABAC conditions on
// public.resource_policies (063), so those real tables are listed rather than
// the non-existent "tenant_database_cmek"/"permission_conditions"). It is
// engine-agnostic ANSI SQL over information_schema.
const accessReviewSQL = `
SELECT grantee, table_name, privilege_type
  FROM information_schema.role_table_grants
 WHERE table_schema = 'public'
   AND table_name IN (
     'compliance_evidence','tenant_audit_log','tenants',
     'tenant_usage','tenant_billing','tenant_backups',
     'erasure_receipts','webauthn_credentials',
     'sso_connections','scim_tokens','scim_users',
     'tenant_databases','resource_policies')
   AND grantee NOT IN ('PUBLIC')
 ORDER BY grantee, table_name, privilege_type`

func (c *Collector) collectAccess(ctx context.Context) (json.RawMessage, error) {
	grants, err := c.scanGrants(ctx)
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{
		"control_type":             "access_review",
		"grants_total":             len(grants),
		"grants":                   grants,
		"evidence_is_service_only": !authedCanReadEvidence(grants),
	})
}

// scanGrants reads the role grants on the sensitive control tables from the
// live catalog into the observed access posture.
func (c *Collector) scanGrants(ctx context.Context) ([]accessGrant, error) {
	grants := []accessGrant{}
	rows, err := c.db.AdminQuery(ctx, accessReviewSQL)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var g accessGrant
		if err := rows.Scan(&g.Role, &g.Table, &g.Privilege); err != nil {
			return nil, err
		}
		grants = append(grants, g)
	}
	return grants, rows.Err()
}

// authedCanReadEvidence reports whether the authenticated role can SELECT
// compliance_evidence — an invariant that MUST be false (evidence is
// service-only), surfaced as explicit, checkable evidence.
func authedCanReadEvidence(grants []accessGrant) bool {
	for _, g := range grants {
		if g.Role == "authenticated" && g.Table == "compliance_evidence" && g.Privilege == "SELECT" {
			return true
		}
	}
	return false
}
