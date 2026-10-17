/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   smtp.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:36 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package loginotp

import (
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/smtpclient"
)

// smtp.go — the production email transport; dial, TLS and AUTH rules live in
// smtpclient. Tests inject a capturing `send` instead.

// smtpSend builds an RFC 5322 message and delivers it over SMTP.
func (s *Service) smtpSend(to, subject, body string) error {
	msg := buildMessage(s.smtp.From, to, subject, body)
	return smtpclient.Send(s.smtp, s.smtp.From, to, msg)
}

// buildMessage renders a minimal text/plain RFC 5322 message.
func buildMessage(from, to, subject, body string) []byte {
	return []byte(fmt.Sprintf(
		"From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\n%s\r\n",
		from, to, subject, body))
}
