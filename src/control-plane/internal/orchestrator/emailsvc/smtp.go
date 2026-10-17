/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   smtp.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:48:06 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package emailsvc

import "github.com/dlesieur/mini-baas/control-plane/internal/smtpclient"

// Healthy reports SMTP reachability (NOOP handshake), mirroring the Node
// readiness probe. Exposed for callers that want an SMTP-aware readiness.
func (s *Service) Healthy() bool { return smtpclient.Ping(s.smtp) == nil }

// smtpSend is the production transport; dial, TLS and AUTH rules live in smtpclient.
func (s *Service) smtpSend(m *message) error {
	return smtpclient.Send(s.smtp, m.from, m.to, m.bytes())
}
