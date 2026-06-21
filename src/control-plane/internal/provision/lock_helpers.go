/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lock_helpers.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:53:15 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:53:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package provision

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// releaseLock builds the unlock closure: it drops the advisory lock on the SAME
// connection that holds it, THEN returns the connection to the pool. A fresh
// background ctx so unlock still runs when the request ctx is already cancelled;
// the session lock also drops on conn close, so this is belt-and-suspenders.
func releaseLock(conn PoolConn, slug string) func() {
	return func() {
		_, _ = conn.Exec(context.Background(), sqlAdvisoryUnlock, slug)
		conn.Release()
	}
}

// scanBool reduces a single-row boolean result, returning pgx.ErrNoRows on empty.
func scanBool(rows pgx.Rows, dst *bool) error {
	defer rows.Close()
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return rows.Scan(dst)
}
