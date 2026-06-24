/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_campaign.go                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:24 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:25 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package newslettersvc

import "context"

func (s *store) confirmedEmails(ctx context.Context) ([]Recipient, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT email, token FROM newsletter.subscriber WHERE is_active = true AND confirmed_at IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Recipient{}
	for rows.Next() {
		var r Recipient
		if err := rows.Scan(&r.Email, &r.Token); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *store) logSend(ctx context.Context, subject string, count int, sentBy *string) error {
	return s.pg.AdminExec(ctx,
		`INSERT INTO newsletter.send_log (subject, recipient_count, sent_by) VALUES ($1, $2, $3)`,
		subject, count, sentBy)
}

func (s *store) history(ctx context.Context, limit int) ([]SendLog, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id, subject, recipient_count, sent_at, sent_by
		 FROM newsletter.send_log ORDER BY sent_at DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SendLog{}
	for rows.Next() {
		var l SendLog
		if err := rows.Scan(&l.ID, &l.Subject, &l.RecipientCount, &l.SentAt, &l.SentBy); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}
