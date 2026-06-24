/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service_test.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:58 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

import (
	"errors"
	"fmt"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestIsUniqueViolation(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"plain error", errors.New("boom"), false},
		{"direct 23505", &pgconn.PgError{Code: "23505"}, true},
		// The bug: pgx surfaces the 23505 wrapped, during row scan.
		{"wrapped 23505", fmt.Errorf("scan: %w", &pgconn.PgError{Code: "23505"}), true},
		{"other pg code", &pgconn.PgError{Code: "23503"}, false},
	}
	for _, c := range cases {
		if got := pg.IsUniqueViolation(c.err); got != c.want {
			t.Errorf("%s: isUniqueViolation = %v, want %v", c.name, got, c.want)
		}
	}
}
