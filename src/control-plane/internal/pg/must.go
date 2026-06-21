/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   must.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:42 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:43 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pg

import (
	"context"
	"log/slog"
	"os"
)

// MustPostgres opens the pool or exits the process (the boot contract for a
// control-plane daemon: a binary that cannot reach its database has nothing to
// serve). Callers that must run their own cleanup before exit dial NewPostgres
// directly instead.
func MustPostgres(ctx context.Context, url string, log *slog.Logger) *Postgres {
	db, err := NewPostgres(ctx, url)
	if err != nil {
		log.Error("postgres connect failed", "err", err)
		os.Exit(1)
	}
	return db
}
