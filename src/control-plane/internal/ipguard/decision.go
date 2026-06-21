/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   decision.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:45:50 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:45:51 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package ipguard

import (
	"context"
	"net"

	"github.com/jackc/pgx/v5"
)

// matchRules renders the edge decision for a tenant that HAS rules: allow=true
// iff the IP is contained in some rule's CIDR (in_allowlist), else 403
// (not_in_allowlist). A stored rule that no longer parses is skipped, never a
// silent allow — only rules that DO parse are matched.
func matchRules(tenantID string, ip net.IP, rules []Rule) Decision {
	for _, r := range rules {
		_, network, perr := net.ParseCIDR(r.CIDR)
		if perr != nil || network == nil {
			continue
		}
		if network.Contains(ip) {
			return Decision{TenantID: tenantID, IP: ip.String(), Allow: true, Restricted: true, Reason: "in_allowlist"}
		}
	}
	return Decision{TenantID: tenantID, IP: ip.String(), Allow: false, Restricted: true, Reason: "not_in_allowlist"}
}

// scanRules drains a rule result set into a slice (newest first, as ordered by
// the query). The caller owns closing the rows.
func scanRules(rows pgx.Rows) ([]Rule, error) {
	out := make([]Rule, 0)
	for rows.Next() {
		var r Rule
		if err := rows.Scan(&r.ID, &r.TenantID, &r.CIDR, &r.Note, &r.CreatedBy, &r.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// ruleExists reports whether a tenant-bound rule id exists. Both the existence
// check and the subsequent delete carry tenant_id — the cross-tenant wall — so a
// foreign id simply matches nothing.
func (s *Service) ruleExists(ctx context.Context, tenantID, ruleID string) (bool, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT 1 FROM public.tenant_ip_allowlist WHERE tenant_id=$1 AND id::text=$2`, tenantID, ruleID)
	if err != nil {
		return false, err
	}
	found := rows.Next()
	rows.Close()
	return found, nil
}
