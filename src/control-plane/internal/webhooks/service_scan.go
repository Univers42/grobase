/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_scan.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:01:27 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:01:29 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package webhooks

import "encoding/json"

// scannable is the small surface common to pgx.Row and pgx.Rows.
type scannable interface {
	Scan(dest ...any) error
}

func scanSubscription(row scannable, sub *Subscription) error {
	var headersJSON string
	if err := row.Scan(&sub.ID, &sub.TenantID, &sub.Name, &sub.URL,
		&sub.EventTypes, &sub.Aggregates, &sub.Active, &headersJSON,
		&sub.MaxAttempts, &sub.TimeoutMs,
		&sub.CreatedAt, &sub.UpdatedAt); err != nil {
		return err
	}
	sub.Headers = map[string]string{}
	if headersJSON != "" {
		_ = json.Unmarshal([]byte(headersJSON), &sub.Headers)
	}
	return nil
}

// rowsScanner is the row-iterating surface (a subset of pgx.Rows) used to
// collect a Subscription set from a query.
type rowsScanner interface {
	scannable
	Next() bool
	Err() error
}

func collectSubscriptions(rows rowsScanner, out *[]Subscription) error {
	for rows.Next() {
		var sub Subscription
		if err := scanSubscription(rows, &sub); err != nil {
			return err
		}
		*out = append(*out, sub)
	}
	return rows.Err()
}
