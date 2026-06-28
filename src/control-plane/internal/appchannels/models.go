/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   models.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package appchannels

// channelErr is the package's const-error type (errors.Is works; no package-level var).
type channelErr string

// Error returns the error message.
func (e channelErr) Error() string { return string(e) }

const (
	// ErrSameTenant rejects a channel whose two ends are the same app-tenant.
	ErrSameTenant channelErr = "a channel's two tenants must differ"
	// ErrNotFound is returned when there is no pending channel this caller may accept.
	ErrNotFound channelErr = "no pending channel to accept"
	// errNoSecret guards realtime-token minting when no JWT secret is configured.
	errNoSecret channelErr = "realtime token secret not configured"
)

// selectCols reads a full channel row; timestamps cast to text so a NULL accepted_at
// scans cleanly into *string. returningCols is the same projection for INSERT/UPDATE.
const (
	selectCols = `SELECT id::text, tenant_a, tenant_b, channel_id, status, opened_by,
		created_at::text, accepted_at::text FROM public.app_channels`
	returningCols = ` RETURNING id::text, tenant_a, tenant_b, channel_id, status, opened_by,
		created_at::text, accepted_at::text`
)

// Channel is a consented messaging link between two distinct app-tenants. channel_id is the
// opaque realtime namespace suffix (xapp:<channel_id>); it never carries a tenant slug.
type Channel struct {
	ID         string  `json:"id"`
	TenantA    string  `json:"tenant_a"`
	TenantB    string  `json:"tenant_b"`
	ChannelID  string  `json:"channel_id"`
	Status     string  `json:"status"`
	OpenedBy   string  `json:"opened_by"`
	CreatedAt  string  `json:"created_at"`
	AcceptedAt *string `json:"accepted_at,omitempty"`
}

// OpenRequest is the POST /v1/app-channels body: the tenant to open a channel to.
type OpenRequest struct {
	TargetTenant string `json:"target_tenant"`
}

// MintResponse is the POST /v1/realtime/token reply: a realtime JWT plus the namespaces it
// grants (always "*" for ordinary topics, plus one xapp:<id> per accepted channel).
type MintResponse struct {
	Token      string   `json:"token"`
	ExpiresAt  int64    `json:"expires_at"`
	Namespaces []string `json:"namespaces"`
}
